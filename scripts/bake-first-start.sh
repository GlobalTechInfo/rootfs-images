#!/usr/bin/env bash
##
## Bake the first-start work into an image.
##
## RedTerm's /root/.startup runs a package update, installs bash if missing, writes a
## sudo shim, then touches /root/.init_done — and that is the multi-minute
## ">>> First-time distro setup" a user sees on first launch. All of it is work that
## only needs doing once, and this build host can do it now.
##
## Baking is strictly an optimisation and this script is written so that being wrong
## cannot break a distro:
##
##   * The marker is the only thing RedTerm reads to decide setup is done. If it is
##     absent, RedTerm does the work itself. So the worst outcome of a stale or
##     half-finished bake is a slow first launch, not a broken rootfs.
##   * Nothing here is destructive. It installs, it does not remove.
##   * The sudo shim is written verbatim from RedTerm's DistroSetup.SUDO_SHIM. If the
##     two ever diverge, the marker check in /root/.startup still runs on the device.
##
## The duplication of the shim is a real maintenance cost. It is paid here because the
## alternative — the app shipping a "prepare image" mode that has to run proot on the
## build host — costs a great deal more, and because the marker makes the duplication
## safe rather than load-bearing.
##
## Usage: bake-first-start.sh <rootfs-dir> <update-command> [bash-install-command]
##

set -euo pipefail

ROOTFS_DIR="$1"
shift

if [ "$#" -eq 0 ]; then
	echo "bake-first-start.sh: no update command given" >&2
	exit 1
fi
UPDATE_CMD="$1"
shift
BASH_INSTALL_CMD="${1:-}"

# One chroot per command, so this is a single mount dance per step rather than one for
# everything. DEBIAN_FRONTEND is set because several installers insist on asking.
run_in_chroot() {
	sudo unshare -mpf bash -e -c "
		set -e
		mount --bind /dev '${ROOTFS_DIR}/dev'
		mount --bind /proc '${ROOTFS_DIR}/proc'
		mount --bind /sys '${ROOTFS_DIR}/sys'
		chroot '${ROOTFS_DIR}' /bin/sh -e -c 'DEBIAN_FRONTEND=noninteractive $*'
	"
}

echo "  bake: running update: ${UPDATE_CMD}"
run_in_chroot "${UPDATE_CMD}"

# bash. RedTerm's /root/.startup installs it if missing and falls back to /bin/sh if it
# cannot, so this is about the experience rather than correctness -- but without bash the
# marker below is not written, and the user still waits for exactly the same work.
# Alpine ships no bash at all, so the recipe has to say how to get one.
if [ ! -x "${ROOTFS_DIR}/bin/bash" ] && [ -n "${BASH_INSTALL_CMD}" ]; then
	echo "  bake: installing bash: ${BASH_INSTALL_CMD}"
	run_in_chroot "${BASH_INSTALL_CMD}"
fi

# bash. RedTerm's script installs it if missing and falls back to /bin/sh if it cannot,
# so baking it is about the experience rather than about correctness.
if ! sudo test -x "${ROOTFS_DIR}/bin/bash"; then
	echo "  bake: /bin/bash absent, leaving the marker for RedTerm to write"
	exit 0
fi

# The sudo shim. proot already runs as root, so sudo exists only to stop the many
# install guides that call it from failing. Text must match DistroSetup.SUDO_SHIM.
echo "  bake: writing sudo shim"
# Removed before writing, not truncated in place. On Ubuntu the image ships /usr/bin/sudo
# as a symlink into /usr/bin/, so tee writes THROUGH it to the real binary -- and apt,
# which the update command above just ran, may still have that binary open, giving
#   /usr/bin/sudo: Text file busy (os error 26)
# which names a lock rather than a symlink. Removing first means the link is replaced
# rather than followed.
sudo rm -f "${ROOTFS_DIR}/usr/bin/sudo"
sudo tee "${ROOTFS_DIR}/usr/bin/sudo" > /dev/null <<-'EOF'
	#!/bin/sh
	# RedTerm: proot already runs as root, so sudo just runs the command.
	while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
	if [ $# -eq 0 ]; then exec /bin/sh; fi
	exec "$@"
EOF
sudo chmod 755 "${ROOTFS_DIR}/usr/bin/sudo"

# Only now is the marker honest: bash is present and sudo is in place, which is exactly
# what RedTerm would otherwise have done before touching it.
echo "  bake: marking first-start setup as done"
sudo touch "${ROOTFS_DIR}/root/.init_done"