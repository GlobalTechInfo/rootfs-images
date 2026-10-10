# Adélie Linux, from the official rootfs-mini images.
#
# Modelled on termux/proot-distro's distro-build/adelie.sh at commit 5bd8f4f.
#
# The host changed. Upstream fetches from adelielinux.nic.cz, which now 404s for every
# rootfs-mini tarball -- the path moved to distfiles.adelielinux.org. Verified 200 for
# aarch64, armv7 and x86_64 there. Upstream's own commented-out alternative is the one that
# now works, which is a good reminder that a dead URL and a wrong URL look the same from
# the outside.
#
# Arch: aarch64, arm and x86_64, matching upstream and RedTerm. Adélie also publishes
# pmmx, ppc and ppc64 rootfs images, which RedTerm does not support.

dist_name="Adélie Linux"
dist_version="1.0-beta6"
# Two hosts serve the same tree. proot-distro fetches Adelie from the second of these,
# not the first, and using only one host is how a build dies where another would have
# worked: there is no fallback, so whichever single host is unreachable takes the whole
# recipe with it. Both are tried in turn and the first that actually has the file wins.
#
# Probed with a HEAD request rather than assumed, because a host that is up can still
# be missing the version being built, and a 404 here is indistinguishable from "no such
# distribution" unless something says which host answered.
ADELIE_HOSTS="https://adelielinux.nic.cz/adelie https://distfiles.adelielinux.org/adelie"

# Echoes the first host that serves $1, or fails naming every host tried.
adelie_pick_host() {
	local path="$1" host
	for host in ${ADELIE_HOSTS}; do
		if curl --fail --silent --head --output /dev/null "${host}/${path}"; then
			echo "${host}"
			return 0
		fi
	done
	echo "adelie: none of the hosts serve ${path}:" >&2
	for host in ${ADELIE_HOSTS}; do echo "  tried ${host}" >&2; done
	return 1
}
# The date is part of the filename and is NOT the same as dist_version. Bumping one
# without the other 404s with nothing to explain it.
ROOTFS_DATE="20241223"

distro_arches="aarch64 arm x86_64"

# Adelie's filenames use its own architecture names, and "arm" is not one of them: the
# 32-bit ARM image is armv7. Substituting our name into the filename gives
# adelie-rootfs-mini-arm-... and a 404 that looks like the release is missing.
adelie_upstream_arch() {
	case "$1" in
		aarch64) echo "aarch64";;
		arm)     echo "armv7";;
		x86_64)  echo "x86_64";;
		*) echo "adelie_upstream_arch(): unknown arch '$1'" >&2; exit 1;;
	esac
}

bootstrap_distribution() {
	local arch up_arch rootfs_dir tarball tgz

	for arch in ${distro_arches}; do
		up_arch=$(adelie_upstream_arch "$arch")
		rootfs_dir="adelie-${arch}"
		tgz="adelie-rootfs-mini-${up_arch}-${dist_version}-${ROOTFS_DATE}.txz"
		tarball="${ROOTFS_DIR}/adelie-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		host=$(adelie_pick_host "${dist_version}/iso/${tgz}") || return 1
		curl --fail --location --output "${WORKDIR}/${tgz}" "${host}/${dist_version}/iso/${tgz}"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}"
		sudo tar -Jxp -f "${WORKDIR}/${tgz}" -C "${WORKDIR}/${rootfs_dir}"

		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		# The mini image pins its repositories to the dated release. Point them at the
		# rolling current branches so an update is possible at all, exactly as upstream
		# does -- then upgrade, so the image is not a frozen beta snapshot.
		# Resolved here, not inside the heredoc below: that runs under `sudo unshare
		# bash`, a separate process which does not inherit this shell's functions and
		# cannot call adelie_pick_host. A function call in there fails with
		# "command not found" and the recipe stops with nothing naming a host.
		adelie_repo_host=$(adelie_pick_host "current/system/${up_arch}/APKINDEX.tar.gz") || return 1

		cat <<- EOF | sudo unshare -mpf bash -e -
			set -e
			sed -i -E 's/(.*)/#\1/g' "${WORKDIR}/${rootfs_dir}/etc/apk/repositories"
			echo "${adelie_repo_host}/current/system" >> "${WORKDIR}/${rootfs_dir}/etc/apk/repositories"
			echo "${adelie_repo_host}/current/user" >> "${WORKDIR}/${rootfs_dir}/etc/apk/repositories"
			mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
			mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
			mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
			chroot "${WORKDIR}/${rootfs_dir}" apk upgrade
			chroot "${WORKDIR}/${rootfs_dir}" apk add bash
		EOF

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/apk"/* 2>/dev/null || true
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/var/log/apk.log" 2>/dev/null || true

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Adélie Linux"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
			"apk upgrade --no-cache" \
			"apk add --no-cache bash"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "adelie" "$arch" "${dist_version}" \
			"\"displayName\": \"Adélie Linux\"" \
			"\"packageManager\": \"apk\"" \
			"\"rolling\": true" \
			"\"recipe\": \"distro-build/adelie.sh\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
		unset tgz
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/adelie.sh instead.
		DISTRO_NAME="Adélie Linux"
		DISTRO_COMMENT="Independent, apk-based. ${dist_version}."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/adelie-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/adelie-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/adelie.sh"
}
