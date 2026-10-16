# Arch Linux, all four of RedTerm's architectures.
#
# Rewritten to use the two registry images proot-distro v5 lists among those it recommends:
# `archlinux/archlinux:base-<date>` for x86_64 and `danhunsaker/archlinuxarm:<date>` for
# aarch64 and arm. Manifest lists were checked: ArchLinuxARM carries arm and arm64, the
# official image is x86_64 only.
#
# This replaces two approaches that did not work:
#
#   * ArchLinuxARM's own mirrors over HTTP. Every one of them refuses HTTPS, archlinuxarm.org
#     302s to http://, and there is no published checksum, so the download could not be
#     verified at all. The registry image is fetched by digest over HTTPS.
#
#   * pacstrap from archlinux-bootstrap for x86_64 and i686. i686 is no longer offered at
#     all: Arch dropped 32-bit, and the image has no i386 manifest. RedTerm has always
#     listed Arch as available on all four of its ABIs; that was true of Termux's images
#     and is not true of Arch's. i686 is dropped rather than faked.
#
# `distro_arches` therefore has three entries, and DistroRegistry's copy of Arch must be
# narrowed to match or the app will offer an install that 404s.

dist_name="Arch Linux"
dist_version="2026.10.01"
ARCH_ARM_TAG="${ARCH_ARM_TAG:-latest}"

# aarch64 and arm come from ArchLinuxARM; x86_64 and i686 from pacstrap.
pacman_in_chroot() {
	local dir="$1"; shift
	cat <<- EOF | sudo unshare -mpf bash -e -
		mount --bind /dev "${dir}/dev"
		mount --bind /proc "${dir}/proc"
		mount --bind /sys "${dir}/sys"
		chroot "${dir}" bash -e -c '$*'
	EOF
}

ARCH_X86="docker.io/archlinux/archlinux:base-20260517.0.530531"
ARCH_ARM="docker.io/danhunsaker/archlinuxarm:20260517"

# Arch dropped 32-bit. See the header.
distro_arches="aarch64 arm x86_64"

bootstrap_distribution() {
	local arch rootfs_dir tarball image

	for arch in ${distro_arches}; do
		case "$arch" in
			aarch64|arm) image="${ARCH_ARM}";;
			x86_64)      image="${ARCH_X86}";;
			*) echo "archlinux.sh: no image for $1" >&2; exit 1;;
		esac

		rootfs_dir="arch-${arch}"
		tarball="${ROOTFS_DIR}/arch-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		OCI_ARCH="$arch" "${SCRIPT_DIR}/oci-unpack.sh" "$image" "${WORKDIR}/${rootfs_dir}"

		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		# Arch's base image ships no /etc/os-release -- only a one-byte
		# /etc/arch-release -- and the trim does not remove it, so it was never there.
		#
		# RedTerm picks its first-start plan from ID=, so without this file Arch cannot
		# be identified at all: no ID means no branch is taken and no pacman setup runs.
		# Written only when absent, so a base that has a real one is left alone.
		if [ ! -s "${WORKDIR:?}/${rootfs_dir}/etc/os-release" ]; then
			sudo tee "${WORKDIR:?}/${rootfs_dir}/etc/os-release" > /dev/null <<-'RELEASE'
				NAME="Arch Linux"
				PRETTY_NAME="Arch Linux"
				ID=arch
				BUILD_ID=rolling
				ANSI_COLOR="38;2;23;147;209"
				HOME_URL="https://archlinux.org/"
				SUPPORT_URL="https://bbs.archlinux.org/"
			RELEASE
		fi

		# NO pacman invocation here, deliberately.
		#
		# The base images already carry bash, sh, glibc and 119 packages, and the
		# recipe only wanted bash, which is present. But every pacman transaction failed
		# with:
		#
		#   error: could not determine root mount point /
		#   error: not enough free disk space
		#   error: failed to commit transaction (not enough free disk space)
		#
		# with 33 GB free, which is what sent this down three wrong paths: pacstrap,
		# OCI images and mirrorlist configuration. The cause is pacman 7 computing free
		# space by walking /proc/self/mountinfo for the mount containing a path and
		# matching on device number. Inside a chroot the root's device is the chroot
		# directory's -- 2049 here -- while the mountinfo entry for / is the host's
		# overlay at 8:1. Nothing matches, so the check cannot run and reports the
		# result as no space.
		#
		# It is a host-layout artefact, not a recipe defect, and the honest fix is not to
		# need pacman. RedTerm's /root/.startup runs pacman on the device anyway, where
		# mountinfo describes the same filesystem.

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/pacman/pkg"/* 2>/dev/null || true

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Arch Linux"

		# Before the bake, so it syncs against a database path of its own rather than
		# anything the bake left behind.
		"${SCRIPT_DIR}/prune-dead-mirrors.sh" "${WORKDIR}/${rootfs_dir}"

		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" "true"
		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		# Remove the package database the bake just synchronised.
		#
		# It is a cache, and shipping a cache pins the image to whatever upstream had
		# on the build day. ARMtix is a rolling release and moves quickly: an image
		# baked with git-2.55.0-1 resolved that version long after the mirror had
		# moved to 2.56.0-1 and deleted the old file, so `pacman -Syu` fetched a URL
		# that returned 404 --
		#
		#   error: failed retrieving file 'git-2.55.0-1-aarch64.pkg.tar.xz'
		#          from armtix.artixlinux.org : 404
		#
		# Every other package in the same transaction downloaded. Only the one whose
		# version had moved on failed, which is what makes it look like a broken
		# mirror rather than a stale snapshot.
		#
		# Deleted after the bake, not before it: the bake needs the database to install
		# anything. Removing it leaves a first `pacman -Sy` to fetch the current one.
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}"/var/lib/pacman/sync/*.db 2>/dev/null || true

		# pacman refuses to sync on a kernel without Landlock:
		#
		#   error: restricting filesystem access failed because Landlock is not
		#          supported by the kernel!
		#   error: switching to sandbox user 'alpm' failed!
		#   error: failed to synchronize all databases
		#
		# Android has never implemented Landlock, so both fire on every device.
		#
		# Set here rather than by the app, for the same reason as the openSUSE
		# repository rewrite: a repair in the app runs once, at first start, on
		# whichever build the user happens to have installed. An image installed with
		# an older app never gets it, and stays broken with nothing to indicate why.
		# An image that is broken until a particular app build repairs it is not a
		# working image.
		#
		# DisableSandbox covers Landlock. It says nothing about the second failure,
		# which is pacman dropping privileges to the alpm user -- that user exists in
		# the image, and the switch fails because proot has no working setuid.
		# DownloadUser = root is the other half.
		sudo sed -i '/^\[options\]/a DisableSandbox' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*DownloadUser[[:space:]]*=.*/DownloadUser = root/' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# pacman's own downloader, replaced with curl.
		#
		# A retried transfer that gets a Range request answered with 404, combined
		# with -f, is exit 22 -- pacman then reports "failed to download" for a file
		# that had in fact arrived. So -C - is deliberately absent. --speed-limit and
		# --speed-time are absent too: they abort a transfer that merely slows down
		# instead of failing over, which on a mobile link killed downloads that were
		# still progressing.
		sudo sed -i '/^[[:space:]]*XferCommand/d; /^[[:space:]]*#[[:space:]]*XferCommand/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a XferCommand = /usr/bin/curl -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 15 -o %o %u' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# Stop asking for database signatures that do not exist.
		#
		# The base image ships `SigLevel = Required DatabaseOptional`, so pacman requests
		# `<repo>.db.sig` -- and no ArchLinuxARM mirror serves it. Measured across every
		# reachable mirror:
		#
		#     ca.us de3 de4 dk fl.us gr hu njus tw    core.db=200   core.db.sig=404
		#
		# The database is fine; the signature beside it is missing. With XferCommand set
		# to `curl -f` an absent *optional* signature is a hard error, so every pacman
		# command on every repo printed, and printed again on every database refresh:
		#
		#     ################################################################### 100.0%
		#     #=#=#   #          curl: (22) The requested URL returned error: 404
		#
		# `DatabaseNever` rather than dropping XferCommand, which is deliberate and
		# documented above and has nothing wrong with it. Nothing is given up here that is
		# verified today: there is no `.db.sig` on any mirror to verify against, so
		# `DatabaseOptional` was already verifying nothing. Package signatures stay
		# `Required`. If ArchLinuxARM ever ships database signatures this line is the
		# thing to revisit, and it is a one-word change.
		sudo sed -i '/^[[:space:]]*SigLevel[[:space:]]*=/d' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a SigLevel = Required DatabaseNever' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# Do not run ALPM hooks.
		#
		# Every pacman transaction on a device ran eleven systemd hooks, and none of
		# them can work under proot:
		#
		#   Failed to chase and open directory '/etc/sysusers.d', ignoring:
		#     Protocol driver not attached
		#   Failed to load user database: Protocol driver not attached
		#   ( 1/14) Creating system user accounts...
		#   error: command failed to execute correctly
		#
		# systemd-sysusers, tmpfiles, hwdb, catalog, sysctl, binfmt, the
		# daemon-reload and enqueue-marked pair, and udev-reload all fail the same
		# way, because there is no system manager and no udev to talk to. The
		# transaction itself succeeds; the hooks report an error on every install.
		#
		# No systemd ever runs in these sessions, so there is nothing for any of them
		# to do. What is given up is update-ca-trust and depmod: the trust store is
		# already populated by the build, and a session cannot load kernel modules.
		# Disable ALPM hooks by pointing HookDir at a real, empty directory.
		#
		# `HookDir = /dev/null` is not a way to do this: pacman scandir()s whatever
		# HookDir names, /dev/null is not a directory, and the transaction dies with
		#   error: could not open directory: /dev/null/: Not a directory
		#   error: failed to commit transaction (failed to run transaction hooks)
		# which is worse than the noise it was meant to remove.
		#
		# Deleting the hook files works too, but not for long: upgrading systemd
		# reinstalls all eleven, and they are back on the next transaction. An empty
		# directory survives that, and it also covers hooks from packages we have
		# never seen.
		#
		# Verified here that this replaces the backend directory rather than adding
		# to it: a probe hook placed in /usr/share/libalpm/hooks did not run, while the
		# transaction itself proceeded normally.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/pacman.d/hooks"
		sudo find "${WORKDIR}/${rootfs_dir}/etc/pacman.d/hooks" -mindepth 1 -delete 2>/dev/null || true
		sudo sed -i '/^[[:space:]]*#*[[:space:]]*HookDir[[:space:]]*=/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a HookDir = /etc/pacman.d/hooks' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# Do not extract man pages, documentation or locale catalogues.
		#
		# The trim removes them to keep the image small, but the packages still claim
		# them, so every upgrade of curl, systemd or anything else re-checks files that
		# are no longer there and prints one line per file:
		#
		#   warning: could not get file information for usr/share/man/man3/CURLOPT_MAXFILESIZE.3.gz
		#
		# hundreds of them, for a file nobody will ever read. NoExtract says the files
		# are not ours to begin with, so pacman neither writes them nor complains that
		# they are missing.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/pacman.d"
		sudo sed -i '/^[[:space:]]*#*[[:space:]]*NoExtract[[:space:]]*=/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a NoExtract = usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/locale/* usr/share/libalpm/hooks/*systemd*.hook usr/share/libalpm/hooks/20-esysusers.hook usr/share/libalpm/hooks/21-etmpfiles.hook usr/share/libalpm/hooks/25-udev-hwdb.hook usr/share/libalpm/hooks/30-binfmt.hook usr/share/libalpm/hooks/30-sysctl.hook usr/share/libalpm/hooks/35-udev-reload.hook' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		image_meta "$tarball" "arch" "$arch" "20260517" \
			"\"displayName\": \"Arch Linux\"" \
			"\"packageManager\": \"pacman\"" \
			"\"rolling\": true" \
			"\"sourceImage\": \"$image\"" \
			"\"recipe\": \"distro-build/archlinux.sh\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
		unset image
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/archlinux.sh instead.
		DISTRO_NAME="Arch Linux"
		DISTRO_COMMENT="Rolling release, latest packages."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/arch-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/arch-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/arch.sh"
}
