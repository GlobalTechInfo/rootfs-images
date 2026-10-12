# Alpine Linux, all four RedTerm architectures.
#
# Modelled on termux/proot-distro's distro-build/alpine.sh at commit 5bd8f4f.
# Differences from upstream, all deliberate:
#
#   * The four arches RedTerm ships. Upstream also builds riscv64, which RedTerm
#     does not support, so it is not built.
#   * dist_version is current stable: 3.24.2 (v3.24 branch, June 2026), supported
#     through June 2028. Upstream pinned 3.22.2.
#   * apk-tools is not pinned to a package version. Upstream's "apk-tools=2.14.9-r3"
#     would fail the moment that revision left the v3.24 repository, breaking the
#     build on a package availability change that has nothing to do with us.
#   * no `ln -sf /var/cache/apk /etc/apk/cache`: that is a runtime arrangement for
#     an interactive session, and we clear the apk cache immediately afterwards.
#
# `distro_arches` is the list this recipe builds. bootstrap-rootfs.sh reads it to
# decide what a full build means, so adding an architecture is one line here.

# NOTE: deliberately no --acls/--xattrs on extraction. Those flags make GNU tar treat
# some tarballs as containing multiple concatenated archives and extract ZERO files,
# exiting with only "tar: Multiple archive files require '-M' option" -- a message that
# names nothing about the real cause. Confirmed on Gentoo stage3 (0 of 69373 members) and
# ARMtix (0 of 98731); plain extraction gets every one of them. Creating an archive still
# uses --acls/--xattrs in archive_rootfs, which is a different operation and works.
dist_name="Alpine Linux"
dist_version="3.24.2"

# RedTerm's four architectures, in the order they are built.
distro_arches="aarch64 arm i686 x86_64"

# Alpine publishes these names; they are not the ones RedTerm uses.
alpine_arch_for() {
	case "$1" in
		aarch64) echo "aarch64";;
		arm) echo "armv7";;
		i686) echo "x86";;
		x86_64) echo "x86_64";;
		*) echo "alpine_arch_for(): unknown arch '$1'" >&2; exit 1;;
	esac
}

bootstrap_distribution() {
	local arch up_arch rootfs_arch rootfs_dir tarball
	for arch in ${distro_arches}; do
		up_arch=$(alpine_arch_for "$arch")
		rootfs_dir="alpine-${dist_version}-${arch}"
		tarball="${ROOTFS_DIR}/alpine-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		curl --fail --location \
			--output "${WORKDIR}/alpine-minirootfs-${dist_version}-${up_arch}.tar.gz" \
			"https://dl-cdn.alpinelinux.org/alpine/v${dist_version:0:4}/releases/${up_arch}/alpine-minirootfs-${dist_version}-${up_arch}.tar.gz"
		curl --fail --location \
			--output "${WORKDIR}/alpine-minirootfs-${dist_version}-${up_arch}.tar.gz.sha256" \
			"https://dl-cdn.alpinelinux.org/alpine/v${dist_version:0:4}/releases/${up_arch}/alpine-minirootfs-${dist_version}-${up_arch}.tar.gz.sha256"
		sha256sum -c "${WORKDIR}/alpine-minirootfs-${dist_version}-${up_arch}.tar.gz.sha256"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}"
		sudo tar -zxp \
			-f "${WORKDIR}/alpine-minirootfs-${dist_version}-${up_arch}.tar.gz" \
			-C "${WORKDIR}/${rootfs_dir}"

		# unshare -m for the bind mounts, -p so the chroot is PID 1 and its init
		# scripts behave, -f because we are not the parent of a forked tree.
		#
		# This runs under binfmt_misc + qemu-user when arch is not the host's, which
		# is why no emulator name appears: binfmt dispatches on the binary's own
		# header, so the same command works natively and under emulation.
		cat <<- EOF | sudo unshare -mpf bash -e -
			rm -f "${WORKDIR}/${rootfs_dir}/etc/resolv.conf"
			echo "nameserver 1.1.1.1" > "${WORKDIR}/${rootfs_dir}/etc/resolv.conf"
			mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
			mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
			mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
			chroot "${WORKDIR}/${rootfs_dir}" apk add --no-cache shadow-login
			chroot "${WORKDIR}/${rootfs_dir}" apk upgrade --no-cache
		EOF

		# The apk cache is a download cache: several MB of tarballs no session can
		# use. It also changes on every build, so it would break reproducibility.
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/apk"/* || true

		# /var/log/apk.log records the wall-clock time of every apk invocation, and
		# is the only thing in this image that differs between two builds of the same
		# recipe. Leaving it in means a published sha256 describes one build rather
		# than the recipe. Alpine recreates it on first use.
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/var/log/apk.log"

		# Bake what RedTerm would otherwise do on the user's first launch: the
		# system update, bash, the sudo shim, and the /root/.init_done marker.
		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Alpine Linux"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
		"true" \
			"apk add --no-cache bash"

		# Trim last, so the update's own downloads are removed and the reported size
		# is the size that ships.
		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "alpine" "$arch" "$dist_version" \
			"\"recipe\": \"distro-build/alpine.sh\"" \
			"\"suite\": \"${dist_version:0:4}\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
		unset up_arch
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/alpine.sh instead.
		DISTRO_NAME="Alpine Linux (${dist_version})"
		DISTRO_COMMENT="Minimal, fast, security-focused."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/alpine-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/alpine-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/alpine.sh"
}