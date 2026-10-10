#!/usr/bin/env bash
##
## Refuse an unpacked tree that cannot start a shell.
##
## This exists because four separate sources passed a reachability check and turned out to
## be *package-manager installations* rather than systems:
##
##   releases.nixos.org/nix/nix-*.tar.xz   a nix store plus install scripts
##   docker.io/nixos/nix:*                 /bin/sh -> a store path not in the image
##   docker.io/termux/termux-docker:*      data/data/com.termux/files/usr/..., no /bin
##   ftp.gnu.org/gnu/guix/guix-binary-*   only etc, gnu and var; no /bin at all
##
## Every one of them was found by building, and each cost a full build cycle to discover.
## The test is one line and it distinguishes them from everything that works:
##
##   stage3 (Gentoo), base.txz (FreeBSD), Alpine minirootfs, and every registry image
##   have a /bin/sh that exists and resolves.
##
## Called before any other work so a bad source fails in seconds rather than after a
## download, a trim and a bake.
##
## Usage: verify-rootfs.sh <rootfs-dir> <what-this-source-is-called>
##

set -euo pipefail

ROOTFS_DIR="${1:?usage: verify-rootfs.sh <rootfs-dir> <label>}"
LABEL="${2:-the source}"

if [ ! -d "$ROOTFS_DIR" ]; then
	echo "[!] ${LABEL}: ${ROOTFS_DIR} does not exist." >&2
	exit 1
fi

# Follow symlinks the way an exec would, and require the target to be an executable file.
if [ ! -x "$ROOTFS_DIR/bin/sh" ]; then
	echo "[!] ${LABEL} is not a usable rootfs: /bin/sh is missing or dangling." >&2
	if [ -L "$ROOTFS_DIR/bin/sh" ]; then
		echo "[!]   /bin/sh -> $(readlink "$ROOTFS_DIR/bin/sh")" >&2
		echo "[!]   which does not resolve inside the image." >&2
	fi
	echo "[!]   Top level is: $(sudo ls "$ROOTFS_DIR" 2>/dev/null | tr '\n' ' ')" >&2
	echo "[!]   This source is a package-manager installation, not a system. Nothing built" >&2
	echo "[!]   from it will ever start a session." >&2
	exit 1
fi

if [ ! -r "$ROOTFS_DIR/etc/passwd" ]; then
	echo "[!] ${LABEL}: /etc/passwd missing; there is no user to log in as." >&2
	exit 1
fi

echo "  verify: ${LABEL} is a usable rootfs (/bin/sh resolves, /etc/passwd present)"
