#!/usr/bin/env bash
##
## Selftest for prune-dead-mirrors.sh, on the parts that decide rather than on pacman.
##
## The mirror test itself needs a rootfs and a network, and runs in CI for real. What is
## tested here is everything that can go wrong without one: that a file it does not
## understand is left alone, that the right URLs are extracted, and that the safe paths
## are safe.
##
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "[!] $1" >&2
		echo "    expected: $3" >&2
		echo "    actual:   $2" >&2
	fi
}

# 1. No mirrorlist at all: untouched, exit 0.
out=$("${SCRIPT_DIR}/prune-dead-mirrors.sh" "${WORK}/nonexistent" 2>&1) && rc=0 || rc=$?
check "missing mirrorlist exits 0" "$rc" "0"
case "$out" in *"nothing to prune"*) r=yes;; *) r=no;; esac
check "missing mirrorlist says so" "$r" "yes"

# 2. A mirrorlist with no Server lines must not be rewritten. Manjaro ships exactly
#    this shape and had its mirrorlist discarded once already.
mkdir -p "${WORK}/a/etc/pacman.d"
printf '# a comment\n\n' > "${WORK}/a/etc/pacman.d/mirrorlist"
before=$(cat "${WORK}/a/etc/pacman.d/mirrorlist")
out=$("${SCRIPT_DIR}/prune-dead-mirrors.sh" "${WORK}/a" 2>&1) && rc=0 || rc=$?
check "serverless mirrorlist exits 0" "$rc" "0"
after=$(cat "${WORK}/a/etc/pacman.d/mirrorlist")
check "serverless mirrorlist is unchanged" "$after" "$before"
case "$out" in *"leaving it alone"*) r=yes;; *) r=no;; esac
check "serverless mirrorlist says so" "$r" "yes"

# 3. Every Server line is extracted, in order, and only those lines. This is the list
#    that gets tested, so getting it wrong would have good mirrors deleted.
mkdir -p "${WORK}/b/etc/pacman.d"
cat > "${WORK}/b/etc/pacman.d/mirrorlist" <<'LIST'
## Arch Linux ARM mirrorlist
# first is fastest

Server = https://a.example/$arch/$repo
Server = https://b.example/$arch/$repo
LIST
servers=$("${SCRIPT_DIR}/prune-dead-mirrors.sh" --list-only "${WORK}/b" 2>/dev/null)
check "extracts exactly the Server lines" "$(printf '%s\n' "$servers" | wc -l | tr -d ' ')" "2"
check "keeps them in order" "$(printf '%s\n' "$servers" | head -1)" 'https://a.example/$arch/$repo'
check "strips the Server prefix and nothing else" \
	"$(printf '%s\n' "$servers" | tail -1)" 'https://b.example/$arch/$repo'

# 4. --list-only must not touch the file. It is the mode the test above depends on.
check "list-only leaves the mirrorlist alone" \
	"$(cat "${WORK}/b/etc/pacman.d/mirrorlist" | md5sum)" \
	"$(printf '## Arch Linux ARM mirrorlist\n# first is fastest\n\nServer = https://a.example/$arch/$repo\nServer = https://b.example/$arch/$repo\n' | md5sum)"

echo
echo "prune-dead-mirrors selftest: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]