# openSUSE Leap, from the official registry image.
#
# Modelled on termux/proot-distro's distro-build/opensuse.sh at commit 5bd8f4f, which
# calls `docker manifest inspect`, `docker pull` and `docker export`. All three are
# replaced by scripts/oci-unpack.sh: a build host has no Docker daemon, and `docker export`
# of a pulled image is not reproducible anyway. skopeo resolves the platform digest and
# the layers are applied with whiteout semantics, so the result is a plain directory that
# can be archived by the same archive_rootfs as every other recipe.
#
# Arch: aarch64 and x86_64. The upstream image is 64-bit only; openSUSE has not shipped
# 32-bit for some time.

dist_name="openSUSE"
dist_version="16.0"
distro_arches="aarch64 x86_64"

bootstrap_distribution() {
	local arch rootfs_dir tarball

	for arch in ${distro_arches}; do
		rootfs_dir="opensuse-${arch}"
		tarball="${ROOTFS_DIR}/opensuse-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		OCI_ARCH="$arch" "${SCRIPT_DIR}/oci-unpack.sh" \
			"docker.io/opensuse/leap:${dist_version}" "${WORKDIR}/${rootfs_dir}"

		# The container image has a machine-id of all zeros and a resolv.conf we have
		# already replaced. A container image also has no working /etc/zypp credentials
		# layout on some releases; refreshing proves the repositories are reachable and
		# writes the ones the image is missing.
		cat <<- EOF | sudo unshare -mpf bash -e -
			mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
			mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
			mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
			chroot "${WORKDIR}/${rootfs_dir}" zypper --non-interactive refresh
			chroot "${WORKDIR}/${rootfs_dir}" zypper --non-interactive install -y bash util-linux
			chroot "${WORKDIR}/${rootfs_dir}" zypper clean -a --all
			rm -f "${WORKDIR}/${rootfs_dir}"/var/log/zypper.log
			rm -f "${WORKDIR}/${rootfs_dir}"/var/log/zypp-history
		EOF

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "openSUSE"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
			"zypper --non-interactive refresh"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		# https, not http. Plain http adds a redirect hop for no benefit, and both were
		# measured serving the Leap 16.0 aarch64 repodata:
		#
		#   http://cdn.opensuse.org/...    200  0.95s
		#   https://cdn.opensuse.org/...   200  0.06s
		#
		# This is NOT a fix for `Curl error (28)`. That is a network timeout and has
		# nothing to do with configuration. The protocol is changed because https is
		# the better default, not because it was measured to rescue a failing refresh.
		for rdir in /etc/zypp/repos.d /usr/share/zypp/repos.d; do
			[ -d "${WORKDIR}/${rootfs_dir}${rdir}" ] || continue
			for r in "${WORKDIR}/${rootfs_dir}${rdir}"/*.repo; do
				[ -e "$r" ] || continue
				sudo sed -i -e 's|^baseurl=http://cdn\.opensuse\.org|baseurl=https://download.opensuse.org|' "$r"
				sudo sed -i -e 's|^gpgkey=http://cdn\.opensuse\.org|gpgkey=https://download.opensuse.org|' "$r"
			done
		done

		# Make zypp's cache writable, AND create the per-repository directories.
		#
		# The writability is the one problem that is real: a session runs as the app's
		# own uid while this build creates the cache as root, so a root-owned cache is a
		# directory the session cannot write into.
		#
		# The directory creation is here because libzypp creating it itself was believed
		# to work, and on a device it does not:
		#
		#   Error building the cache:
		#   Can't open solv-file: /var/cache/zypp/solv/openSUSE:repo-oss/solv
		#   Skipping repository 'repo-oss (16.0)' because of the above error.
		#
		# Run natively as root, `zypper refresh` against this very image succeeds and
		# builds that path without being asked to. As root it can always create a
		# directory; as the app's uid under proot it cannot, and the failure is silent
		# about the reason. So the directories are made here, where they can be created
		# as root, and left writable.
		#
		# The alias is the .repo file's section header, which is where the error names
		# it -- `[openSUSE:repo-oss]` becomes
		# `/var/cache/zypp/solv/openSUSE:repo-oss`. Rewriting the headers was tried and
		# removed; what is needed is for the path to exist, not for the name to change.
		#
		# Done here as well as in the app, for the same reason the pacman sandbox
		# settings are baked in: an image that is broken until a particular build of the
		# app happens to repair it is not a working image. Nothing in the cache is a
		# secret; it is re-downloadable repository metadata.
		sudo mkdir -p \
			"${WORKDIR:?}/${rootfs_dir}/var/cache/zypp/solv" \
			"${WORKDIR:?}/${rootfs_dir}/var/cache/zypp/raw" \
			"${WORKDIR:?}/${rootfs_dir}/var/cache/zypp/packages"
		for rdir in /etc/zypp/repos.d /usr/share/zypp/repos.d; do
			[ -d "${WORKDIR}/${rootfs_dir}${rdir}" ] || continue
			for r in "${WORKDIR}/${rootfs_dir}${rdir}"/*.repo; do
				[ -e "$r" ] || continue
				alias=$(sed -n 's/^\[\([^]]*\)\]$/\1/p' "$r" | head -1)
				[ -n "$alias" ] || continue
				sudo mkdir -p \
					"${WORKDIR:?}/${rootfs_dir}/var/cache/zypp/solv/${alias}" \
					"${WORKDIR:?}/${rootfs_dir}/var/cache/zypp/raw/${alias}"
			done
		done
		sudo chmod -R 777 "${WORKDIR:?}/${rootfs_dir}/var/cache/zypp"

		image_meta "$tarball" "opensuse" "$arch" "${dist_version}" \
			"\"displayName\": \"openSUSE Leap\"" \
			"\"sourceImage\": \"docker.io/opensuse/leap:${dist_version}\"" \
			"\"packageManager\": \"zypper\"" \
			"\"recipe\": \"distro-build/opensuse.sh\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/opensuse.sh instead.
		DISTRO_NAME="openSUSE Leap"
		DISTRO_COMMENT="Robust, flexible, enterprise-grade Linux."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/opensuse-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/opensuse-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/opensuse.sh"
}