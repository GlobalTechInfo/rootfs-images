#!/usr/bin/env bash
#
# Applies the working tree's trim to a published image and proves nothing usable
# was removed along the way.
#
# Why this exists
# ---------------
# Four changes reached CI before being found broken, each of which a local run
# would have caught in seconds:
#
#   * removing /usr/lib/cargo took Ubuntu's coreutils with it, because /bin is a
#     symlink to /usr/bin and that is where the Rust coreutils package installs;
#   * removing /usr/lib/modules stopped ARMtix building its own initramfs;
#   * find -xtype l flagged every Debian alternatives entry as broken, failing a
#     good build;
#   * writing /etc/os-release with a plain redirection was refused as root-owned.
#
# Each was a 4-hour build to discover and all four were visible in seconds here,
# from images that had already been extracted. So: extract, trim, assert.
#
# Usage
# -----
#   scripts/selftest-trim.sh <extracted-rootfs-dir> [label]
#
# The directory is copied first; the original is never modified.
#
# What it checks
# --------------
#   1. Every command that resolved before the trim still resolves after. This is
#      the check that would have caught the cargo deletion.
#   2. No symlink in a PATH directory is left pointing at nothing.
#   3. /usr/lib/modules is not removed when it was present. This is the check
#      that would have caught the modules deletion.
#   4. /etc/os-release survives, and still carries an ID= line if it had one.
#   5. bash is still executable, since every first-start plan is a bash script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: selftest-trim.sh <extracted-rootfs-dir> [label]}"
LABEL="${2:-$(basename "$SRC")}"

[ -d "$SRC" ] || { echo "no such directory: $SRC" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOTFS_DIR="$WORK/rootfs"
DEST="$ROOTFS_DIR"

echo "=== trim selftest: $LABEL ==="

# sudo is needed to own the files the way the build does; without it the copy is
# made read-only enough that the trim's own rm calls fail for the wrong reason.
# rsync, excluding the pseudo-filesystems. A plain cp -a follows a /proc or /sys
# that happens to be mounted inside the source and tries to copy /proc/kcore, which
# fills the disk and fails on a permission error rather than on anything to do with
# the trim.
sudo mkdir -p "$DEST"
sudo mkdir -p "$DEST/dev" "$DEST/proc" "$DEST/sys"
sudo rsync -a --quiet \
	--exclude=/proc --exclude=/sys --exclude=/dev \
	--exclude=/run \
	"$SRC/" "$DEST/"

# A command is usable if the shell can run it. Resolving is what actually
# matters: /bin is a symlink to /usr/bin on Debian and Ubuntu, so a link in
# usr/bin can break /bin too, and the broken link is still present, which is why
# a file count and a checksum both pass.
# Must match verify-rootfs.sh, or this harness cannot see what verify-rootfs.sh sees.
#
# It originally used [ -e ], which resolved an absolute symlink target against the
# machine running the harness. That is how Ubuntu's sudo passed here and failed on a
# CI runner, and why the harness reported "0 already broken" on an image that the
# build called broken. The chain is walked instead, rebased onto the rootfs.
link_resolves() {
	local path="$1" target depth=0
	while [ -L "$path" ] && [ "$depth" -lt 40 ]; do
		target="$(readlink "$path" 2>/dev/null)" || return 1
		case "$target" in
			/*) path="${ROOTFS_DIR}${target}" ;;
			*)  path="$(dirname "$path")/${target}" ;;
		esac
		depth=$(( depth + 1 ))
	done
	[ -e "$path" ]
}

usable_commands() {
	local dir="$1"
	find "$dir/bin" "$dir/usr/bin" "$dir/sbin" "$dir/usr/sbin" \
		-maxdepth 1 -type l 2>/dev/null |
	while read -r link; do
		link_resolves "$link" && printf '%s\n' "$link"
	done | sort
}

dangling_links() {
	local dir="$1"
	find "$dir/bin" "$dir/usr/bin" "$dir/sbin" "$dir/usr/sbin" \
		-maxdepth 1 -type l 2>/dev/null |
	while read -r link; do
		link_resolves "$link" || printf '%s\n' "$link"
	done | sort
}

usable_commands "$DEST" > "$WORK/before.txt"
dangling_links "$DEST" > "$WORK/before-broken.txt"
had_modules=0
[ -d "$DEST/usr/lib/modules" ] && [ -n "$(ls -A "$DEST/usr/lib/modules" 2>/dev/null)" ] && had_modules=1
had_release=0
[ -s "$DEST/etc/os-release" ] && had_release=1

echo "  before: $(wc -l < "$WORK/before.txt") usable command(s)," \
	"$(wc -l < "$WORK/before-broken.txt") already broken, modules=$had_modules"

sudo "${SCRIPT_DIR}/trim-rootfs.sh" "$DEST" > "$WORK/trim.log" 2>&1 || {
	echo "  TRIM FAILED:" >&2
	sed 's/^/    /' "$WORK/trim.log" >&2
	exit 1
}

usable_commands "$DEST" > "$WORK/after.txt"
dangling_links "$DEST" > "$WORK/after-broken.txt"

fail=0

# 1. nothing that worked stopped working
lost="$(comm -23 "$WORK/before.txt" "$WORK/after.txt")"
if [ -n "$lost" ]; then
	echo "  FAIL: $(printf '%s\n' "$lost" | wc -l) command(s) stopped working:" >&2
	printf '%s\n' "$lost" | while read -r link; do
		echo "         ${link#"$DEST"/} -> $(readlink "$link" 2>/dev/null || echo '(gone)')" >&2
	done
	fail=1
else
	echo "  ok: no command that resolved before the trim stopped working"
fi

# 2. the trim leaves no dangling command behind
if [ -s "$WORK/after-broken.txt" ]; then
	echo "  FAIL: $(wc -l < "$WORK/after-broken.txt") command(s) left dangling:" >&2
	head -10 "$WORK/after-broken.txt" | while read -r link; do
		echo "         ${link#"$DEST"/} -> $(readlink "$link" 2>/dev/null || echo '(gone)')" >&2
	done
	fail=1
else
	echo "  ok: no command left pointing at nothing"
fi

# 3. kernel modules survive
if [ "$had_modules" -eq 1 ] && [ ! -d "$DEST/usr/lib/modules" ]; then
	echo "  FAIL: /usr/lib/modules was removed. mkinitcpio needs it to build an" >&2
	echo "         initramfs for a kernel whose directory is absent." >&2
	fail=1
elif [ "$had_modules" -eq 1 ]; then
	echo "  ok: /usr/lib/modules kept ($(ls -A "$DEST/usr/lib/modules" 2>/dev/null | wc -l) entries)"
else
	echo "  --  /usr/lib/modules was empty or absent before, nothing to protect"
fi

# 4. os-release survives and keeps its ID
if [ "$had_release" -eq 1 ] && [ ! -s "$DEST/etc/os-release" ]; then
	echo "  FAIL: /etc/os-release was removed by the trim." >&2
	fail=1
elif [ "$had_release" -eq 1 ] && ! grep -q '^ID=' "$DEST/etc/os-release"; then
	echo "  FAIL: /etc/os-release lost its ID= line. The app selects its plan from it." >&2
	fail=1
else
	echo "  ok: os-release $( [ "$had_release" -eq 1 ] && echo intact || echo 'not present, unchanged' )"
fi

# 5. bash still runs -- every first-start plan is a bash script, so an image that
#    cannot start bash cannot run the plan that configures it
if [ -e "$DEST/bin/bash" ] || [ -e "$DEST/usr/bin/bash" ]; then
	echo "  ok: bash present"
else
	echo "  FAIL: bash is gone; the first-start plan cannot run." >&2
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	echo "=== $LABEL: PASS ==="
else
	echo "=== $LABEL: FAIL ===" >&2
fi
exit "$fail"