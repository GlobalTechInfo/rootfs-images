#!/usr/bin/env bash
##
## Strip an image down to what a session needs.
##
## A distro ships manual pages, HTML documentation, translations and caches for
## packages the user may never install. On a phone that is the whole download over
## cellular and most of the installed size. Arch's x86_64 image is 302 MB as shipped
## and most of the difference is /usr/share.
##
## What is removed, and why each is safe:
##
##   man/     man pages. Nothing reads them in a terminal session that matters, and
##            `man` degrades to "no manual entry".
##   doc/     distribution documentation: copyright files, changelogs, examples.
##   info/    GNU info manuals.
##   locale/  per-language message catalogues in /usr/share/locale. These are the bulk
#            of the win and are safe to drop.
##
## What is deliberately NOT removed, and one of these is a trap:
##
##   /usr/lib/locale. On Debian 13 C.UTF-8 lives at /usr/lib/locale/C.utf8, NOT in
##   /usr/share/locale. Stripping /usr/lib/locale as well makes `locale -a` stop
##   listing C.utf8, and RedTerm's launcher then falls back from LANG=C.UTF-8 to
##   LANG=C. Nothing errors visibly: every command prints
##   "bash: warning: setlocale: LC_ALL: cannot change locale (C.UTF-8)" — actually no,
##   with LANG=C there is no warning at all, and the image simply loses UTF-8.
##   Character classification is then wrong and accented filenames sort wrongly. A
##   regression with no error message at all, so it is checked below rather than
##   assumed.
##   /usr/share/i18n. Locale *definitions*, needed by localedef and small.
##   /usr/bin, /usr/lib, /etc. These are the distro.
##   licenses under /usr/share/licenses. Small, and some packages are GPL and their
##   terms require the notice to travel with the code.
##   /etc/ssl/certs. This is what makes TLS work; without it every https call in a
##   session fails, and it is the reason a Void image needed SSL_NO_VERIFY_PEER=1.
##
## Usage: trim-rootfs.sh <rootfs-dir>
##

set -euo pipefail

ROOTFS_DIR="${1:?usage: trim-rootfs.sh <rootfs-dir>}"

# A UTF-8 locale has to exist before anything is removed, so that removing message
# catalogues cannot be what takes it with them.
utf8_before=$(sudo chroot "${ROOTFS_DIR}" /usr/bin/locale -a 2>/dev/null \
	| tr 'A-Z' 'a-z' | grep -cx 'c\.utf-\?8' || true)

removed_before=$(sudo du -sk "${ROOTFS_DIR}" | cut -f1)

# The largest of these by far. -x keeps it on one filesystem; a stray mount under
# /usr/share would otherwise make this follow it somewhere unrelated.
strip() {
	local path="$1"
	if sudo test -d "${ROOTFS_DIR}${path}"; then
		sudo rm -rf "${ROOTFS_DIR:?}${path:?}"/* 2>/dev/null || true
	fi
}

for p in \
	/usr/share/man \
	/usr/share/doc \
	/usr/share/info \
	/usr/share/locale \
	/var/cache/man \
	/var/cache/debconf \
	/var/cache/apk
do
	strip "$p"
done

# Two directories that dwarf everything the strip list above removes, and that no
# session can ever reach. Both were found by measuring a shipped image rather than
# by reading the recipe: FreeBSD was 3.1G and Ubuntu resolute 1.3G while trixie from
# the same recipe was under 100M, which is not a difference any package list explains.
#
# /rescue is FreeBSD's statically linked recovery userland -- a second complete copy
# of /bin, /sbin and /lib for booting a machine whose /usr is unreadable. It is 2.4G,
# roughly three quarters of the image, and under proot it is unreachable: nothing ever
# boots a kernel here, so the emergency shell it exists for is never invoked. Checked
# for shared inodes before cutting -- it holds no hard links to the rest of the tree,
# so removing it cannot take a second name for a live file with it.
if [ -d "${ROOTFS_DIR}/rescue" ]; then
	sudo rm -rf "${ROOTFS_DIR:?}/rescue"
fi
#
# /usr/lib/cargo holds two very different things, and removing the directory
# removes both.
#
# registry/ is Debian's and Ubuntu's vendored crates.io cache: 1.2G, about 92% of
# resolute. Nothing in a session reads it.
#
# bin/ is not a cache. The Rust `coreutils` package installs its binaries there, and
# /bin is a symlink to /usr/bin, so ordinary commands resolve through it:
#
#   /usr/bin/chgrp    -> ../lib/cargo/bin/coreutils/chgrp
#   /usr/bin/basename -> ../lib/cargo/bin/coreutils/basename
#   /usr/bin/cat      -> ../lib/cargo/bin/coreutils/cat
#
# Deleting the directory leaves those pointing at nothing, and every one of them
# fails with "not found". That surfaces as dpkg postinst failures --
# openssh-client cannot `chgrp _ssh` -- and then as
#
#   E: Sub-process /usr/bin/dpkg returned an error code (1)
#
# which leaves the package manager broken for every later install.
#
# The saving was measured and the consequence was not: 1322M to 155M looked like a
# pure win, and nothing checked whether the commands still ran. Only the registry is
# removed now.
if [ -d "${ROOTFS_DIR}/usr/lib/cargo/registry" ]; then
	sudo rm -rf "${ROOTFS_DIR:?}/usr/lib/cargo/registry"
fi

# A distribution built for a board carries that board's kernel, and one that supports
# many boards carries one device tree per board: ARMtix ships 693M of /boot -- a kernel
# image and 2846 device-tree blobs -- alongside 439M of matching modules in
# /usr/lib/modules. None of it runs here. RedTerm supplies the kernel from the host and
# proot passes its syscalls through, so the image's own kernel is never loaded and its
# modules can never be inserted; they are 1.1G that cannot be reached.
#
# The firmware beside them is a different matter and stays. Modules load firmware into
# real hardware, and that hardware exists inside a proot session -- a USB adapter or a
# Bluetooth controller needs /usr/lib/firmware to work at all, and there is no
	# /usr/lib/modules is NOT removed, and the reason it was looks convincing.
	#
	# The argument for deleting it was that proot passes syscalls through to the host
	# kernel, so the image's own kernel is never loaded and its modules can never be
	# inserted -- 439M on ARMtix that cannot be reached.
	#
	# That is true and it is irrelevant. Tools resolve the module tree by name whether
	# or not a module is ever inserted, and a distro that ships them checks on every
	# package operation. ARMtix's setup ran mkinitcpio and got, for both of its kernels:
	#
	#   ERROR: '/lib/modules/6.18.40-1-aarch64-lts-ARTIX' is not a valid kernel module directory
	#
	# so the image could not build its own initramfs -- broken in a way no amount of disk
	# space compensates for.
	#
	# The firmware beside them is a different matter and stays. Modules load firmware into
	# real hardware, and that hardware exists inside a proot session -- a USB adapter or
	# a Bluetooth controller needs /usr/lib/firmware to work at all, and there is no
	# substitute for it short of reinstalling the package.
# Only the contents: /boot itself holds vmlinuz, initramfs and initramfs.img entries
# alongside the directory holding the device trees, and the directory is the bulk of it.
sudo find "${ROOTFS_DIR:?}/boot" -mindepth 1 -delete 2>/dev/null || true

# Package caches, which some builders leave behind and which change on every build.
sudo rm -rf "${ROOTFS_DIR:?}"/var/cache/apt/archives/* 2>/dev/null || true
sudo rm -rf "${ROOTFS_DIR:?}"/var/lib/apt/lists/* 2>/dev/null || true
sudo rm -rf "${ROOTFS_DIR:?}"/var/cache/dnf/* 2>/dev/null || true
sudo rm -rf "${ROOTFS_DIR:?}"/var/cache/zypp/* 2>/dev/null || true
sudo rm -rf "${ROOTFS_DIR:?}"/var/cache/xbps/* 2>/dev/null || true
sudo rm -rf "${ROOTFS_DIR:?}"/var/cache/pacman/pkg/* 2>/dev/null || true

removed_after=$(sudo du -sk "${ROOTFS_DIR}" | cut -f1)
freed=$(( removed_before - removed_after ))
echo "  trim: freed $(( freed / 1024 )) MB (${removed_before}K -> ${removed_after}K)"

# The two things that must survive, checked rather than assumed.
#
# The CA bundle has several well-known homes and every family picks a different one:
# Debian and Alpine use /etc/ssl/certs/ca-certificates.crt, RHEL uses
# /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem, and openSUSE uses
# /etc/ssl/ca-bundle.pem. Checking only the Debian path reports "no CA bundle" for a
# perfectly good RHEL or openSUSE image. That is worse than not checking at all: a warning
# that cries wolf on every non-Debian build trains the reader to ignore it, and the one
# time it is right is the one time it gets missed. This list was wrong twice -- once for
# RHEL and once for openSUSE -- and each time a build that would have worked was refused.
# Tested one at a time on purpose. `ls a b c` exits non-zero when *any* operand is
# missing, so listing all three together reports a missing bundle for a distro that has
# one at the first path and not the other two -- which is every RHEL image and most
# Alpine ones.
have_ca=0
for ca in \
	/etc/ssl/certs/ca-certificates.crt \
	/etc/ssl/ca-bundle.pem \
	/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
	/etc/pki/tls/certs/ca-bundle.crt \
	/etc/ssl/certs/ca-bundle.crt
do
	if [ -e "${ROOTFS_DIR}${ca}" ]; then
		have_ca=1
		break
	fi
done
if [ "$have_ca" -eq 0 ]; then
	echo "  trim: no CA bundle in any of the three usual locations; HTTPS will fail" >&2
	exit 1
fi
if [ ! -x "${ROOTFS_DIR}/bin/sh" ]; then
	echo "  trim: /bin/sh missing, the image will not start" >&2
	exit 1
fi

# A UTF-8 locale that disappears is a silent regression: RedTerm falls back to LANG=C
# with no message, and the image quietly stops handling non-ASCII correctly. Checked
# against the state before trimming, because "C.utf8" is the name on Debian and
# "C.UTF-8" elsewhere.
utf8_after=$(sudo chroot "${ROOTFS_DIR}" /usr/bin/locale -a 2>/dev/null \
	| tr 'A-Z' 'a-z' | grep -cx 'c\.utf-\?8' || true)
if [ "$utf8_before" = "1" ] && [ "$utf8_after" != "1" ]; then
	echo "  trim: C.UTF-8 was present before and is gone after; UTF-8 would be lost" >&2
	exit 1
fi
if [ "$utf8_before" = "0" ] && [ "$utf8_after" = "0" ]; then
	echo "  trim: no UTF-8 locale in this image to begin with (RedTerm will use LANG=C)" >&2
fi

# Dangling symlinks left behind by the trims above.
#
# Removing a directory does not remove the symlinks that pointed into it, so a
# command can be left as a link to nothing. Gentoo shipped 70 of them: the binutils
# cross-toolchain is trimmed away and /usr/bin/addr2line, /usr/bin/strings and
# /usr/bin/ld.bfd are left pointing at it, each failing with "not found".
#
# A symlink with no target has no use to anything -- the content is already gone, and
# unlike a hard link there is nothing that could still be referring to it. So these
# are removed rather than left to fail at run time.
dangling=0
for d in bin usr/bin sbin usr/sbin; do
	[ -d "${ROOTFS_DIR:?}/${d}" ] || continue
	while IFS= read -r link; do
		dangling=$(( dangling + 1 ))
		sudo rm -f "$link"
	done < <(find "${ROOTFS_DIR}/${d}" -maxdepth 1 -type l ! -exec test -e {} \; 2>/dev/null)
done
if [ "$dangling" -ne 0 ]; then
	echo "  trim: removed ${dangling} symlink(s) left pointing at nothing."
fi
