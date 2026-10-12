# Manjaro.
#
# Modelled on termux/proot-distro's distro-build/manjaro.sh at commit 5bd8f4f, which builds
# aarch64 from the manjaro-arm/rootfs GitHub releases. x86_64 is now an OCI image rather
# than the pacstrap build an earlier version of this recipe used, and that change is the
# point of this rewrite.
#
# The pacstrap route failed repeatedly and expensively. Arch's bootstrap has no mirrorlist
# include for community/multilib, pacman 7 needs DisableSandbox because it sandboxes
# through an 'alpm' user and Landlock that do not exist in a bootstrap chroot, and -- the
# one that was never solved -- pacman refused transactions inside a chroot with 33 GB free
# reporting "not enough free disk space".
#
# `manjarolinux/base` is the image proot-distro v5 lists among those it recommends, it
# carries amd64 and arm64, and it needs none of that. Its manifest list was checked rather
# than assumed.
#
# There is no version to pin by name: the GitHub feed is rolling and its asset is named
# "Manjaro-ARM-aarch64-latest.tar.gz" under a dated tag, so the tag is the version.
#
# armv7 and i686 are not built: Manjaro publishes nothing for either. arm-stable carries
# aarch64 only, there is no i686 directory, and no manifest offers them.

dist_name="Manjaro"
dist_version="20261005"
ARCH_VERSION="2026.10.01"

# RedTerm has always offered Manjaro on aarch64 only, and now on x86_64 as well.
distro_arches="aarch64 x86_64"
MANJARO_BASE="docker.io/manjarolinux/base:20260322"

MANJARO_REPO="https://manjaro.ipacct.com/manjaro/stable"

# Point pacman.conf at Manjaro's repositories.
#
# Writing a mirrorlist file does NOT work, and the failure is obscure. Arch's bootstrap
# declares [core] and [extra] in pacman.conf and pulls their servers in with
# "Include = /etc/pacman.d/mirrorlist", so a mirrorlist that declares [core] as well
# registers the database twice:
#
#     error: could not register 'core' database (database already registered)
#     error: failed to synchronize all databases (no servers configured for repository)
#
# which names a missing server when the real problem is a duplicate section. So the
# Include lines are removed and each repository gets its Server inline.
#
# DisableSandbox is also needed: pacman 7 sandboxes downloads through an 'alpm' user and a
# Landlock LSM, neither of which exists in a bootstrap chroot:
#
#     error: restricting filesystem access failed because Landlock is not supported
#     error: switching to sandbox user 'alpm' failed!
manjaro_configure_pacman() {
	local conf="$1" d="$2"
	sudo sed -i 's|^Include = /etc/pacman.d/mirrorlist||' "$conf"
	sudo sed -i 's|#DisableSandbox|DisableSandbox|' "$conf"
	for repo in core extra community multilib; do
		sudo sed -i "s|^\[${repo}\]|[${repo}]\nServer = ${MANJARO_REPO}/${repo}/${d}|" "$conf"
	done
}

bootstrap_arm() {
	local arch rootfs_dir tarball

	arch="aarch64"
	rootfs_dir="manjaro-${arch}"
		tarball="${ROOTFS_DIR}/manjaro-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		curl --fail --location \
			--output "${WORKDIR}/Manjaro-ARM-aarch64-latest.tar.gz" \
			"https://github.com/manjaro-arm/rootfs/releases/download/${dist_version}/Manjaro-ARM-aarch64-latest.tar.gz"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}"
		sudo tar -xp \
			-f "${WORKDIR}/Manjaro-ARM-aarch64-latest.tar.gz" -C "${WORKDIR}/${rootfs_dir}"

		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		cat <<- EOF | sudo unshare -mpf bash -e -
			mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
			mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
			mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
			chroot "${WORKDIR}/${rootfs_dir}" pacman-key --init
			chroot "${WORKDIR}/${rootfs_dir}" pacman-key --populate archlinuxarm
			chroot "${WORKDIR}/${rootfs_dir}" pacman -Syu --noconfirm
			chroot "${WORKDIR}/${rootfs_dir}" pacman -S --noconfirm --needed bash
			sed -i 's/#DisableSandbox/DisableSandbox/' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		EOF

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/pacman/pkg"/* 2>/dev/null || true

		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
		"true"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "manjaro" "$arch" "${dist_version}" \
			"\"displayName\": \"Manjaro\"" \
			"\"packageManager\": \"pacman\"" \
			"\"rolling\": true" \
			"\"source\": \"manjaro-arm/rootfs ${dist_version}\"" \
			"\"recipe\": \"distro-build/manjaro.sh\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
	unset arch
}

bootstrap_x86_64() {
	local rootfs_dir tarball

	rootfs_dir="manjaro-x86_64"
	tarball="${ROOTFS_DIR}/manjaro-x86_64-rt-${CURRENT_VERSION}.tar.xz"

	OCI_ARCH="x86_64" "${SCRIPT_DIR}/oci-unpack.sh" \
		"${MANJARO_BASE}" "${WORKDIR}/${rootfs_dir}"

	sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
	sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

	"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
		"true"
	"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

	image_meta "$tarball" "manjaro" "x86_64" "20260322" \
		"\"displayName\": \"Manjaro\"" \
		"\"packageManager\": \"pacman\"" \
		"\"rolling\": true" \
		"\"sourceImage\": \"${MANJARO_BASE}\"" \
		"\"recipe\": \"distro-build/manjaro.sh\""

	archive_rootfs "$tarball" "$rootfs_dir"
	echo "[*] Built $tarball"
}

bootstrap_distribution() {
	bootstrap_arm
	bootstrap_x86_64
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/manjaro.sh instead.
		DISTRO_NAME="Manjaro"
		DISTRO_COMMENT="User-friendly Arch-based rolling release."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/manjaro-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/manjaro-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/manjaro.sh"
}
