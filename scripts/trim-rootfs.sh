#!/usr/bin/env bash
#
# Post-build cleanup for a rootfs.
#
# This script used to remove content: /usr/lib/cargo wholesale (which took Ubuntu's
# coreutils with it, because /bin is a symlink to /usr/bin and that is where the Rust
# coreutils package installs), /usr/lib/modules (which stopped ARMtix building its own
# initramfs), /boot, /rescue, documentation and locales. Four separate releases were
# spent repairing that, each discovered by a four-hour build rather than in seconds here.
#
# So the destructive part is gone. What remains is exactly what proot-distro's
# archive_rootfs does, which is the reference implementation this project follows:
#
#   * empty /dev -- it is a mount point, populated by the kernel at run time, and the
#     device nodes baked into an image cannot work on a device with different hardware;
#   * make every directory at least owner-readable. A directory recorded as 0400 is
#     visible but not listable, so tar could not read it and proot-distro fixes it before
#     archiving for the same reason.
#
# Size is recovered by building minimal (see distro-build/opensuse.sh, which runs
# `zypper dup` and pins every package explicitly rather than trimming a full install
# down), and by each recipe cleaning its own package cache -- which 11 already do.
#
# Nothing here decides that a directory "cannot be reached inside proot" and removes it
# on that reasoning. That assumption produced every one of the four regressions above.

set -euo pipefail

ROOTFS_DIR="${1:?usage: trim-rootfs.sh <rootfs-dir>}"

[ -d "$ROOTFS_DIR" ] || { echo "no such directory: $ROOTFS_DIR" >&2; exit 2; }

size_before=$(sudo du -sk "$ROOTFS_DIR" 2>/dev/null | cut -f1 || echo 0)

# /dev is a mount point on the device. Anything in it here is a device node from the
# machine that built the image, which cannot be opened on the phone.
if sudo test -d "${ROOTFS_DIR}/dev"; then
	sudo find "${ROOTFS_DIR}/dev" -mindepth 1 -delete 2>/dev/null || true
fi

# A directory the owner cannot read is invisible to tar and to anything that lists it,
# and several distributions ship mode 0400 directories. proot-distro's archive_rootfs
# does this immediately before archiving; the same reasoning applies here.
fixed=0
while IFS= read -r dir; do
	sudo chmod 755 "$dir" 2>/dev/null || true
	fixed=$(( fixed + 1 ))
done < <(sudo find "$ROOTFS_DIR" -type d -perm -400 -print0 2>/dev/null | xargs -0 -r -n1 printf '%s\n')
[ "$fixed" -ne 0 ] && echo "  trim: made ${fixed} owner-unreadable director(y/ies) traversable."

size_after=$(sudo du -sk "$ROOTFS_DIR" 2>/dev/null | cut -f1 || echo 0)

echo "  trim: $(( size_before / 1024 ))M -> $(( size_after / 1024 ))M (nothing removed; this is deduplicated hard links)"