#!/usr/bin/env bash
##
## Drop mirrors from a pacman mirrorlist that cannot serve the image's own databases.
##
## ## The problem
##
## pacman tries mirrors in order and falls through when one fails, so a dead mirror is
## not an error -- it is just noise. With pacman's own downloader that noise is silent.
## With ours it is not, because our XferCommand is
##
##     XferCommand = /usr/bin/curl -fL --progress-bar ... -o %o %u
##
## and `-f` is required: without it a 404 response body is written into the target file
## and pacman installs a corrupt database. `-f` also means curl prints the failure and
## exits 22, so every ordinary failover prints this on the user's device, once per
## repository:
##
##     ################################################################### 100.0%
##     #=#=#   #                          curl: (22) The requested URL returned error: 404
##
## The user reads that as a broken install. It is not: the sync succeeds on the next
## mirror and every package resolves.
##
## ## Why this asks pacman rather than guessing a URL
##
## Because the path shape differs by distribution and a guessed one is wrong:
##
##     Arch           $repo/os/$arch     e.g. /core/os/aarch64
##     ArchLinuxARM   $arch/$repo         e.g. /aarch64/core
##
## A `curl` on a hand-assembled path 404s on a perfectly good mirror, which would have
## this script delete working mirrors. The image is built from
## danhunsaker/archlinuxarm, which uses the second form -- and the recipe header already
## records that ArchLinuxARM's mirrors refuse HTTPS, so their shape is not the
## upstream one either.
##
## So the only authoritative question is "does pacman manage to sync from this?", and
## that is what is asked: one mirror at a time, against a throwaway database path, so
## the test cannot be confused with the image's own cached state.
##
## ## What it will not do
##
## - **It never fails the build.** An upstream outage must not be able to block a
##   release. That is the trap that let one index commit fan out into twenty
##   distribution rebuilds.
## - **It refuses to empty the list.** An image with no mirror cannot install anything,
##   so that is the one condition treated as fatal.
## - **It leaves a file with no Server lines completely alone.** Manjaro's image ships
##   one live server and rewriting what it does not understand is how that mirrorlist was
##   once discarded.
## - **It preserves order.** Mirror order is a latency preference; the surviving ones
##   keep their sequence so a fast mirror stays first.
##
## Usage: prune-dead-mirrors.sh [--list-only] <rootfs-dir>
##
## --list-only prints the discovered mirrors and exits, without testing or touching
## anything. It exists so the selftest can cover extraction -- the part that decides
## which URLs get tested -- without needing a rootfs or a network.
##

set -euo pipefail

LIST_ONLY=0
if [ "${1:-}" = "--list-only" ]; then
	LIST_ONLY=1
	shift
fi

ROOTFS_DIR="${1:?usage: prune-dead-mirrors.sh [--list-only] <rootfs-dir>}"
MIRRORLIST="${ROOTFS_DIR}/etc/pacman.d/mirrorlist"

if [ ! -f "${MIRRORLIST}" ]; then
	echo "  mirrors: no /etc/pacman.d/mirrorlist, nothing to prune"
	exit 0
fi

# Preserve the file exactly, minus the Server lines we are about to drop, so comments
# and blank lines survive. Only rewritten if something actually fails.
servers=$(grep -oE '^[[:space:]]*Server[[:space:]]*=[[:space:]]*[^[:space:]]+' "${MIRRORLIST}" \
	| sed -E 's/^[[:space:]]*Server[[:space:]]*=[[:space:]]*//' || true)

if [ -z "${servers}" ]; then
	echo "  mirrors: mirrorlist has no Server lines, leaving it alone"
	exit 0
fi

if [ "${LIST_ONLY}" = 1 ]; then
	printf '%s\n' "${servers}"
	exit 0
fi

total=$(printf '%s\n' "${servers}" | wc -l | tr -d ' ')
echo "  mirrors: testing ${total} mirror(s) against the image's own databases"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# One mirror at a time, in the guest, against a throwaway dbpath so the image's own
# cached databases cannot make a broken mirror look good.
run_in_chroot() {
	sudo unshare -mpf bash -c "
		set -e
		mount --bind /dev '${ROOTFS_DIR}/dev'
		mount --bind /proc '${ROOTFS_DIR}/proc'
		chroot '${ROOTFS_DIR}' /bin/sh -c \"
			mkdir -p '${WORK}/db'
			cp /etc/pacman.conf '${WORK}/pacman.conf'
			sed -i 's|^Include *= *.*/mirrorlist.*||' '${WORK}/pacman.conf'
			sed -i 's|^#Include *= *.*/mirrorlist.*||' '${WORK}/pacman.conf'
			sed -i 's|^XferCommand *=.*||' '${WORK}/pacman.conf'
			printf '[core]\\nServer = %s\\n' '$1' >> '${WORK}/pacman.conf'
			pacman -Sy --dbpath '${WORK}/db' --config '${WORK}/pacman.conf' --noconfirm
		\"
	"
}

kept=""
dropped=0
kept_count=0
first_error=""

while IFS= read -r server; do
	[ -n "${server}" ] || continue
	if run_in_chroot "${server}" > "${WORK}/out" 2>&1; then
		kept="${kept}${server}"$'\n'
		kept_count=$((kept_count + 1))
	else
		dropped=$((dropped + 1))
		reason=$(grep -viE '^\s*$' "${WORK}/out" | tail -1 || true)
		echo "  mirrors: dropping ${server}" >&2
		echo "             ${reason}" >&2
		[ -n "${first_error}" ] || first_error="${server}: ${reason}"
	fi
done <<< "${servers}"

if [ "${kept_count}" -eq 0 ]; then
	echo "[!] every mirror failed, including: ${first_error}" >&2
	echo "[!] refusing to ship an image with an empty mirrorlist." >&2
	exit 1
fi

if [ "${dropped}" -eq 0 ]; then
	echo "  mirrors: all ${total} mirror(s) sync fine"
	exit 0
fi

# Rewrite, preserving everything that is not a Server line.
{
	grep -vE '^[[:space:]]*Server[[:space:]]*=' "${MIRRORLIST}" || true
	printf '%s' "${kept}"
} > "${WORK}/newlist"

sudo mkdir -p "$(dirname "${MIRRORLIST}")"
sudo cp "${WORK}/newlist" "${MIRRORLIST}"
sudo chmod 644 "${MIRRORLIST}"

echo "  mirrors: dropped ${dropped} of ${total}, kept ${kept_count}"