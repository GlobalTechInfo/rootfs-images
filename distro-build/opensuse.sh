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

		# Rewrite the repository aliases so the image works on its own.
		#
		# Leap's .repo files are named and sectioned [openSUSE:repo-oss]. libzypp
		# cannot cache a solv file for an alias containing a colon:
		#
		#   Can't open solv-file: /var/cache/zypp/solv/openSUSE:repo-oss/solv
		#
		# so every repository is skipped, the cache never builds, and the session has
		# no packages at all -- "No provider of 'git' found" for everything.
		#
		# Done here rather than by the app: an image that is broken until a particular
		# version of the app repairs it is not a working image. Three things have to
		# change, not one -- the section header, the filename, and the parsed repo
		# list in RepoManager.db, which keeps serving the old aliases even after the
		# files are rewritten.
		for rdir in /etc/zypp/repos.d /usr/share/zypp/repos.d; do
			[ -d "${WORKDIR}/${rootfs_dir}${rdir}" ] || continue
			for r in "${WORKDIR}/${rootfs_dir}${rdir}"/*.repo; do
				[ -e "$r" ] || continue
sudo sed -i -e 's/^\[[^:]*:\(.*\)\]$/[\1]/' "$r"
			# Detach the repo from its libzypp service.
			#
			# This is the part that actually decides the alias, and rewriting the
			# section header above never had a chance against it. Every Leap .repo
			# ends with `service=openSUSE`, and libzypp namespaces a serviced repo
			# as `service:alias`. So the repository keeps the alias `openSUSE:repo-oss`
			# no matter what its section header or filename says -- which is exactly
			# what a session showed:
			#
			#   Looking for gpg keys in repository repo-oss (16.0).
			#   Error building the cache:
			#   Can't open solv-file: /var/cache/zypp/solv/openSUSE:repo-oss/solv
			#
			# The name= line above is why that looks contradictory: the display name
			# is clean while the alias is not. The files even say so at the top:
			# "Manual changes may be overwritten by a service refresh."
			#
			# With the service detached, the repo is an ordinary one, keeps the alias
			# in its own header, and no refresh can put the colon back.
			#
			# Before the rename below, because that moves the file out from under $r
			# and this sed would then fail on a path that no longer exists:
			#   sed: can't read .../openSUSE:repo-non-oss-debug.repo: No such file or directory
			sudo sed -i -e '/^[[:space:]]*service[[:space:]]*=/d' "$r"
			b=$(basename "$r")
			case "$b" in *:*) sudo mv "$r" "${WORKDIR}/${rootfs_dir}${rdir}/${b#*:}" ;; esac
			done
		done
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/var/lib/zypp/RepoManager.db"

		# The raw cache zypp creates read-only, so rm without this fails with
		# "Operation not permitted" and the stale raw files survive, still naming the
		# colon aliases. Removing the directory itself and letting it be recreated is
		# the only way it actually goes.
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/zypp"

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
