#!/usr/bin/env bash
##
## Script for making rootfs creation easier.
##
## Vendored from termux/proot-distro at commit
## 5bd8f4f503727d21495fb22badf243a8db973094 (2025-11-30), the last revision
## before upstream replaced this shell builder with the Python/OCI one and stopped
## publishing images. Both projects are GPL-3.0, so this is a straight copy.
##
## Local modifications are marked "RedTerm:". Keep them minimal — re-syncing with
## upstream should stay a matter of reading a diff.
##

set -e -u

if [ "$(uname -o)" = "Android" ]; then
	echo "[!] This script cannot be executed on Android OS."
	exit 1
fi

# RedTerm: mmdebstrap is NOT checked here. It is only needed by the Debian-family
# recipes, and requiring it made a plain Alpine build fail on a host that has no
# reason to have it. A recipe declares what it needs via require_tools.
for i in curl git jq sudo tar xz; do
	if [ -z "$(command -v "$i")" ]; then
		echo "[!] '$i' is not installed."
		exit 1
	fi
done

# RedTerm: called from a recipe's bootstrap_distribution before it uses any
# non-baseline host tool, so the error names the recipe that needs it.
require_tools() {
	local tool
	for tool in "$@"; do
		if [ -z "$(command -v "$tool")" ]; then
			echo "[!] '$tool' is required by this recipe but is not installed."
			exit 1
		fi
	done
}

# Every recipe fetches its base over the network, and a build that dies on one
# unlucky connection wastes the hours already spent on the recipes before it.
#
# curl's default connect timeout is 300 seconds and it does not retry: a runner that
# cannot open a connection to a mirror for five minutes gets exit 28 and the run is
# over. That is not hypothetical. The first CI run failed on Adelie with
# "Failed to connect to distfiles.adelielinux.org port 443 after 134632 ms", while
# the same host answered in 0.18 seconds from elsewhere -- a runner-side blip, not a
# dead mirror. Retrying is the difference between a build that survives a bad minute
# and one that has to be re-run from the first recipe.
#
# --retry-all-errors covers exit 28 as well as the 5xx responses curl retries on by
# default; without it a timeout is still fatal on the first attempt.
#
# --ipv4 is not a preference, it is the fix for Adelie. distfiles.adelielinux.org
# publishes an AAAA record pointing at 2602:fcdb:0:2::1:11, where nothing answers:
# forced over v6 it returns no response and never completes a connect. curl prefers
# IPv6, so it goes there first and waits out the connect timeout. That is why the
# host answers in 0.18 seconds from a machine that falls back quickly and times out
# on every one of five retries from a GitHub runner, which has working IPv6 and so
# never falls back. Retrying cannot help when the DNS answer is the same every time.
#
# The cost is that a mirror reachable only over IPv6 would fail. None of these
# distributions publish one, and a broken AAAA record is a far more common way to
# be unreachable than a genuinely v6-only host.
curl() {
	command curl \
		--ipv4 \
		--retry 5 \
		--retry-all-errors \
		--retry-delay 10 \
		--connect-timeout 30 \
		"$@"
}

# Where to put generated plug-ins.
PLUGIN_DIR=$(dirname "$(realpath "$0")")/distro-plugins

# Where to look for distribution build recipes
BUILD_DIR=$(dirname "$(realpath "$0")")/distro-build

# Where to put generated rootfs tarballs.
ROOTFS_DIR=$(dirname "$(realpath "$0")")/rootfs

# Shared helpers recipes call: trim-rootfs.sh and bake-first-start.sh. Recipes source
# nothing from here, they just invoke these, so a recipe has one way to do each thing.
SCRIPT_DIR=$(dirname "$(realpath "$0")")/scripts

# Per-image sidecar metadata written by image_meta. generate-index.sh reads these
# rather than parsing filenames.
META_DIR="$ROOTFS_DIR/.meta"

# Working directory where chroots will be created.
#
# RedTerm: not under /tmp, and overridable.
#
# Upstream hardcodes /tmp/proot-distro-bootstrap. On a normal machine that is fine, but
# /tmp is very often a tmpfs sized as a fraction of RAM, and the workspace has to hold
# every chroot being built at once. Gentoo's stage3 is 1.2 GB unpacked per architecture,
# so four architectures need roughly 6 GB — more than a 2.9 GB /tmp. The failure that
# produces is "Cannot write: No space left on device" from tar, one line per file, with
# nothing to connect it to the workspace size.
#
# It sits next to the repository so it is on the same real filesystem as rootfs/, which
# is where the output goes anyway.
WORKDIR="${ROOTFS_WORKDIR:-$(dirname "$(realpath "$0")")/.work}"

# This is used to generate proot-distro plug-ins.
TAB=$'\t'

# RedTerm: these name OUR release series, not proot-distro's, and are overridable
# so a local build can be exercised without publishing anything. A build that
# cannot say which release it belongs to must not produce a plugin, because the
# plugin's URLs are derived from it.
CURRENT_VERSION="${ROOTFS_VERSION:-$(git tag | sort -Vr | head -n1)}"
if [ -z "$CURRENT_VERSION" ]; then
	echo "[!] Cannot detect a release version."
	echo "[!] Tag the repository, or set ROOTFS_VERSION=v0.0.0 for a throwaway build."
	exit 1
fi

# RedTerm: our own release assets. Overridable so a local build can point
# anywhere, including nothing.
GIT_RELEASE_URL="${ROOTFS_RELEASE_URL:-https://github.com/GlobalTechInfo/rootfs-images/releases/download/${CURRENT_VERSION}}"
echo "[*] Version:    ${CURRENT_VERSION}"
echo "[*] Release to: ${GIT_RELEASE_URL}"

# Normalize architecture names.
# Prefer aarch64, arm, i686, riscv64, x86_64 architecture names
# just like used by termux-packages.
# RedTerm: riscv64 is kept because Alpine publishes it and it costs nothing to
# recognise. RedTerm itself ships only aarch64/arm/i686/x86_64, so riscv64 output
# is simply never requested.
translate_arch() {
	case "$1" in
		aarch64|arm64|arm64v8) echo "aarch64";;
		arm|armel|armhf|armhfp|armv7|armv7l|armv7a|armv8l) echo "arm";;
		386|i386|i686|x86) echo "i686";;
		riscv64) echo "riscv64";;
		amd64|x86_64) echo "x86_64";;
		*)
			echo "translate_arch(): unknown arch '$1'" >&2
			exit 1
			;;
	esac
}

# Common way to archive the rootfs.
# Usage: archive_rootfs /path/to/rootfs.tar.xz rootfs-dir
# rootfs-dir is relative to $WORKDIR
# RedTerm: reproducibility is opt-out, not opt-in.
#
# Upstream defaults SOURCE_DATE_EPOCH to `date +%s`, which means every build
# produces a different archive even from an unchanged tree, and a published
# sha256 describes that one build rather than the recipe. Defaulting to 0 is
# reproducible, and a caller that genuinely wants "as now" can still say so.
# 0 rather than a fixed date because a recipe that should not change will not
# change; any fixed epoch has to be bumped by hand, and forgetting to is exactly
# the failure this prevents.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

archive_rootfs() {
	echo "SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}"

	sudo find "${2:?}/dev" -mindepth 1 -delete

	# RedTerm: replace upstream's permission repair, which does not work.
	#
	# Upstream: find "${2}" -type d -perm -400 -print0 | xargs -0 sudo chmod 755
	#
	# find parses a -perm mode as OCTAL, and 0400 is bit 8: the owner's EXECUTE
	# bit. (It is not setuid; setuid is 04000, which matches nothing.) So the
	# predicate selects every directory the owner can already traverse, and
	# chmods those to 755, leaving a 000 directory at 000. Measured on a tree
	# with 000/700/750/755 dirs: the 000 stayed 000 and 700 and 750 were widened
	# to 755. Measured again over /usr, which has 22197 directories and all
	# 22197 of them traversable:
	#
	#   find /usr -type d -perm -400   ->  22197 matches
	#   find /usr -type d -perm /0100  ->  22197 matches   (owner execute)
	#   find /usr -type d -perm /4000  ->      0 matches   (setuid)
	#
	# It did not repair the problem it names, and it loosened permissions on
	# directories that did not need touching.
	#
	# The two bits are both needed and both are checked: execute to reach into a
	# directory, read to list what is in it. Repairing only one leaves the
	# directory as invisible as not repairing it at all.
	#
	# `u+rx` rather than 755, so a directory that was deliberately 0700 stays 0700.
	sudo find "${2}" -type d \( ! -perm -400 -o ! -perm -100 \) -print0 \
		| xargs -0 -r sudo chmod u+rx

	# Files too. Upstream never repaired these, but a rootfs image is full of them:
	# /etc/shadow, /etc/gshadow, /etc/sudoers, and on Fedora several hundred mode
	# 000. An image whose /etc/shadow is unreadable boots to a login that cannot
	# work, and the failure appears as a permission error rather than as a bad image.
	sudo find "${2}" -type f ! -perm -400 -print0 \
		| xargs -0 -r sudo chmod u+r

	sudo rm -f "${1:?}.tmp"
	# RedTerm: --pax-option=delete=atime,delete=ctime is required, not optional.
	#
	# --mtime pins the mtime recorded in the header, but GNU tar writes a pax
	# extended header per member containing atime and ctime with nanosecond
	# precision, and those come from the filesystem at archive time. They are not
	# affected by --mtime. Two builds of an unchanged tree therefore produced
	# different archives and different sha256s, which makes a published sha256
	# worthless: it describes one build, not the recipe.
	#
	# Deleting those two keys leaves mtime, mode, owner, size and xattrs intact, so
	# the archive still describes the tree faithfully and now depends only on the
	# tree. Verified both ways: two builds of one tree are byte-identical, and a
	# single changed file still changes the hash.
	sudo tar \
		--directory="$WORKDIR" \
		--create \
		--format=pax \
		--pax-option="delete=atime,delete=ctime" \
		--sort=name \
		--hard-dereference \
		--mtime="@${SOURCE_DATE_EPOCH}" \
		--numeric-owner \
		--preserve-permissions \
		--acls \
		--xattrs \
		--xattrs-include='*' \
		--xz \
		--file="${1}.tmp" \
		"$2"
	sudo chown $(id -un):$(id -gn) "${1}.tmp"
	mv "${1}.tmp" "${1}"
}

##############################################################################

# RedTerm: record what an image is, alongside it.
#
# Filenames cannot carry this. An Alpine image legitimately has both an upstream
# version (3.24.2) and a build version (v0.4.0), and any scheme that packs both into
# `<name>-<arch>-rt-<version>.tar.xz` is ambiguous to parse — which is how the first
# index generator read "alpine-aarch64-3.24.2" as distro=alpine-aarch64,
# arch=3.24.2. The filename is for humans and is `<name>-<arch>-rt-<build>.tar.xz`;
# everything a machine needs is in this sidecar.
#
# Usage: image_meta <tarball> <distro> <arch> <upstream-version> [extra-json-field...]
image_meta() {
	local tarball="$1" distro="$2" arch="$3" upstream="$4"
	shift 4
	local meta="${META_DIR}/$(basename "$tarball").json"
	mkdir -p "$META_DIR"
	{
		printf '{"distro": "%s", "arch": "%s", "upstreamVersion": "%s"' \
			"$distro" "$arch" "$upstream"
		for pair in "$@"; do
			printf ', %s' "$pair"
		done
		printf '}\n'
	} > "$meta.tmp"
	mv "$meta.tmp" "$meta"
}

# Reset workspace. This also deletes any previously made rootfs tarballs.
# Anything still mounted under WORKDIR is from an interrupted run. mmdebstrap binds
# /dev, /proc and /sys into its target directory, so killing it — a cancelled CI job,
# a Ctrl-C — leaves those mounts in place. `rm -rf` then fails with "Device or resource
# busy", and every later run fails the same way with a message that says nothing about
# what is actually wrong. Unmount deepest-first: a mount has to be gone before its
# parent can be.
while read -r m; do
	[ -z "$m" ] && continue
	sudo umount -l "$m" 2>/dev/null || true
done < <(mount | awk -v w="${WORKDIR}" '$3 ~ "^" w {print $3}' | sort -r)

# RedTerm: refuse early with a message that names the cause. A full workspace otherwise
# surfaces as one tar error per file and no indication that the disk is the problem.
need_mb=$(df -Pm "$(dirname "${WORKDIR}")" | awk 'NR==2 {print $4}')
if [ "${need_mb}" -lt 1024 ]; then
	echo "[!] Only ${need_mb} MB free next to ${WORKDIR}; a build needs several GB." >&2
	echo "[!] Set ROOTFS_WORKDIR to somewhere with room." >&2
	exit 1
fi

sudo rm -rf "${WORKDIR:?}"
# RedTerm: PLUGIN_DIR is created rather than committed. Upstream keeps an empty
# distro-plugins/ in git only because Git will not track an empty directory, so a
# recipe write there never fails for them. Here a fresh clone has no such
# directory and the first recipe aborted on it.
mkdir -p "$ROOTFS_DIR" "$WORKDIR" "$PLUGIN_DIR"
cd "$WORKDIR"

# Build distribution. if no argument is supplied then all distributions will be built
if [ "$#" -gt 0 ]; then
	DISTRIBUTIONS="$*"
else
	DISTRIBUTIONS="$(cd ${BUILD_DIR}; ls -1 *.sh | sed 's/.sh//')"
fi

# Loop over to build a specified distribution
for distro in ${DISTRIBUTIONS}; do
	# A recipe that does not exist is an error, not something to skip past.
	#
	# Silently continuing is how a name that does not match a recipe produces a green
	# build with no output and nothing to explain it: this file is
	# distro-build/rocky.sh and builds the distro named "rocky", while an earlier version
	# was called rockylinux.sh, so `./bootstrap-rootfs.sh rocky` built nothing, printed
	# nothing, and exited 0. A caller who named a distribution wants that distribution.
	if [ ! -f "${BUILD_DIR}/${distro}.sh" ]; then
		echo "[!] No recipe for '${distro}': ${BUILD_DIR}/${distro}.sh does not exist." >&2
		echo "[!] Available: $(cd "${BUILD_DIR}" && ls -1 ./*.sh | sed 's@.*/@@; s@\.sh$@@' | tr '\n' ' ')" >&2
		exit 1
	fi

	. "${BUILD_DIR}/${distro}.sh"
	printf "\n[*] Building ${dist_name:=$distro}...\n"

	# Bootstrap step
	# If the function does not exists, abort to indicate there's an error occured during build
	if ! declare -F bootstrap_distribution &> /dev/null; then
		echo "[!] Failure to build rootfs ${distro}, missing bootstrap_distribution function. aborting..."
		exit 1
	fi
	bootstrap_distribution

	# Plugin generation step
	if ! declare -F write_plugin &> /dev/null; then
		echo "[!] Failure to generate plugin for ${distro}, missing write_plugin function. aborting..."
		exit 1
	fi
	write_plugin

	# Cleanup variables and functions
	unset dist_name	dist_version
	unset -f bootstrap_distribution write_plugin
done
