# Pardus, a Turkish Debian derivative.
#
# Not in upstream proot-distro's recipe set at commit 5bd8f4f; this one is new. Upstream
# has no Pardus recipe, and the research said it was a drop: the official site states "All
# editions are 64-bit (amd64)" and the only artefact is a Server ISO. That statement is
# about the *installer ISOs*, not the archive, and it is the reason this recipe exists:
# checking the archive rather than the marketing page is what turned it from a drop into
# a build.
#
# Verified: `Architectures: amd64 arm64 i386` in the Release file, with 68,196 packages for
# arm64 against amd64's 68,825. So arm64 is real.
#
# Three things about this archive are traps, all found by running mmdebstrap rather than
# by reading:
#
#   * The host is `depo.pardus.org.tr`, which 302s to `ulakbimdepo1.pardus.org.tr`.
#     `debian.pardus.org.tr` does not resolve at all (NXDOMAIN), which reads as "the
#     project has no APT archive".
#
#   * TWO suites are needed and the argument is the `-deb` one. `yirmibes` is the
#     Pardus-native suite and `yirmibes-deb` is its Debian-trixie base. Passing `yirmibes`
#     alone produces an essential set with no `dpkg` in it and fails with
#     "failed to run command 'dpkg'".
#
#   * --keyring is mandatory. Without it apt dies with NO_PUBKEY 026440E60FE45435, so the
#     keyring is fetched from the archive and extracted rather than assumed present.
#
# --variant=required, not important: `important` pulls dhcpcd-base, whose maintainer
# script fails inside mmdebstrap's unshared chroot.

dist_name="Pardus"
dist_version="yirmibes"
distro_arches="aarch64 x86_64"

PARDUS_REPO="http://ulakbimdepo1.pardus.org.tr/pardus"

pardus_deb_arch() {
	case "$1" in
		aarch64) echo "arm64";;
		x86_64) echo "amd64";;
		*) echo "pardus_deb_arch(): unknown arch '$1'" >&2; exit 1;;
	esac
}

bootstrap_distribution() {
	local arch deb_arch rootfs_dir tarball

	require_tools mmdebstrap

	for arch in ${distro_arches}; do
		deb_arch=$(pardus_deb_arch "$arch")
		rootfs_dir="pardus-${arch}"
		tarball="${ROOTFS_DIR}/pardus-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		# The keyring, fetched from the same archive and extracted. mmdebstrap will not
		# proceed without it.
		if [ ! -f "${WORKDIR}/pardus-archive-keyring.gpg" ]; then
			curl --fail --location \
				--output "${WORKDIR}/pardus-archive-keyring.deb" \
				"${PARDUS_REPO}/pool/main/p/pardus-archive-keyring/pardus-archive-keyring_2025.1_all.deb"
			sudo dpkg-deb --fsys-tarfile "${WORKDIR}/pardus-archive-keyring.deb" \
				| sudo tar -xO ./usr/share/keyrings/pardus-archive-keyring.gpg \
				> "${WORKDIR}/pardus-archive-keyring.gpg"
		fi

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"

		# The suite argument is ${dist_version}-deb. See the header: passing the native
		# suite yields an essential set with no dpkg in it.
		sudo mmdebstrap \
			--architectures="${deb_arch}" \
			--variant=required \
			--include="base-files,apt,libc6,dash,coreutils,ca-certificates,locales,sudo" \
			--keyring="${WORKDIR}/pardus-archive-keyring.gpg" \
			--format=directory \
			"${dist_version}-deb" \
			"${WORKDIR}/${rootfs_dir}" \
			"deb ${PARDUS_REPO} ${dist_version}-deb main" \
			"deb ${PARDUS_REPO} ${dist_version} main" \
			"deb ${PARDUS_REPO} ${dist_version} contrib non-free non-free-firmware"

		# mmdebstrap's --keyring is what let it verify the archive while bootstrapping, but
		# it does NOT leave that keyring in the image: /etc/apt/trusted.gpg.d comes out
		# holding only Debian's, and the first `apt-get update` then fails with
		# "The repository ... is not signed" for every Pardus suite. Install it here.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/apt/trusted.gpg.d"
		sudo cp "${WORKDIR}/pardus-archive-keyring.gpg" \
			"${WORKDIR}/${rootfs_dir}/etc/apt/trusted.gpg.d/pardus-archive-keyring.gpg"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/lib/apt/lists"/* 2>/dev/null || true
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/apt/archives"/* 2>/dev/null || true
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		# Security updates live in a separate repository, not in -updates under /pardus.
		cat <<- EOF | sudo unshare -mpf bash -e -
			mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
			mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
			mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
			chroot "${WORKDIR}/${rootfs_dir}" /bin/sh -e -c '
				echo "deb http://ulakbimdepo1.pardus.org.tr/guvenlik ${dist_version}-deb updates main" > /etc/apt/sources.list.d/pardus-security.list
				apt-get update
				apt-get -y upgrade
				apt-get clean
				rm -rf /var/lib/apt/lists/* /var/log/apt/*
			'
		EOF

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Pardus"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
		"true"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "pardus" "$arch" "${dist_version}" \
			"\"displayName\": \"Pardus\"" \
			"\"packageManager\": \"apt\"" \
			"\"source\": \"${PARDUS_REPO}\"" \
			"\"recipe\": \"distro-build/pardus.sh\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
		unset deb_arch
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/pardus.sh instead.
		DISTRO_NAME="Pardus"
		DISTRO_COMMENT="Turkish, Debian-derived, rolling security updates."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/pardus-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/pardus-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/pardus.sh"
}
