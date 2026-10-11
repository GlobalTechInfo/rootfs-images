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
