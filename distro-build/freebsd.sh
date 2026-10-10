# FreeBSD, from the official base.txz.
#
# The answer to "NixOS has no buildable artefact". Both NixOS sources turn out to be nix
# *installer* bases rather than systems (see findings.md sections 20 and 25), and FreeBSD's
# base.txz is the same shape of thing as Gentoo's stage3: a real, minimal, versioned base
# system unpacked from one tarball.
#
# Verified to be a rootfs and not merely a tarball of things:
#
#     ./bin/sh  ./bin/csh  ./etc/passwd  ./etc/group  ./lib/libc.so.7  ./usr/bin/make
#
# with 29,541 members under bin/, lib/, usr/ and etc/. That is the check the two NixOS
# artefacts failed.
#
# Arch: aarch64, x86_64 and i686 -- three of RedTerm's four.
#
# i386 exists but LAGS: downloads.freebsd.org/releases/i386/ contains only 14.4 and 14.5,
# while amd64 and arm64 are on 15.1. Probing only the current release is how this was
# nearly missed -- i386 15.1-RELEASE/base.txz is a 404 that reads exactly like "FreeBSD
# dropped 32-bit", which it did for the mainline but not for i386 itself.
#
# There is genuinely no armv7: releases/arm/ does not exist at all, and no 32-bit ARM
# release has a base.txz. That is an absence of the port rather than a version to choose.
#
# IMPORTANT, and not proven: proot is a ptrace-based syscall translator and FreeBSD is not
# Linux, so a FreeBSD userland under proot on Android is not something this project has
# tested. The image is built and is structurally correct; whether a session starts is a
# question for a device. It is listed under its own key rather than folded into the Linux
# distros so that expectation is set correctly in the app.

dist_name="FreeBSD"
dist_version="15.1-RELEASE"
# i386 is a different, older release series. Probed across every published version rather
# than assumed from the mainline one.
dist_version_i386="14.5-RELEASE"

distro_arches="aarch64 i686 x86_64"

freebsd_arch_for() {
	case "$1" in
		aarch64) echo "arm64";;
		i686)    echo "i386";;
		x86_64)  echo "amd64";;
		*) echo "freebsd_arch_for(): unknown arch '$1'" >&2; exit 1;;
	esac
}

freebsd_version_for() {
	case "$1" in
		i686) echo "$dist_version_i386";;
		*)    echo "$dist_version";;
	esac
}

bootstrap_distribution() {
	local arch up_arch up_ver rootfs_dir tarball

	for arch in ${distro_arches}; do
		up_arch=$(freebsd_arch_for "$arch")
		up_ver=$(freebsd_version_for "$arch")
		rootfs_dir="freebsd-${arch}"
		tarball="${ROOTFS_DIR}/freebsd-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		echo "[*] FreeBSD ${arch}: ${up_ver}"
		curl --fail --location \
			--output "${WORKDIR}/base.txz" \
			"https://download.freebsd.org/releases/${up_arch}/${up_ver}/base.txz"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}"
		sudo tar -xJp --strip-components=1 -f "${WORKDIR}/base.txz" -C "${WORKDIR}/${rootfs_dir}"

		# FreeBSD does not use /etc/resolv.conf for resolution -- it reads
		# /etc/resolv.conf too, but a stock base image has none and no resolver
		# configuration at all, so /etc/resolv.conf is created and resolv.conf's sibling
		# /etc/hosts is left as shipped.
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		# FreeBSD uses ports and pkg, neither of which is in base.txz. The FreeBSD package
		# manager lives in /usr/local, which base.txz does not create, so the directories
		# pkg expects are made here. Nothing is installed: pkg would need a working
		# resolver and a configured ABI name, and whether either works under proot on
		# Android is exactly the untested part.
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}/usr/local/bin" "${WORKDIR}/${rootfs_dir}/usr/local/etc" \
			"${WORKDIR}/${rootfs_dir}/usr/local/share" "${WORKDIR}/${rootfs_dir}/usr/local/lib"

		# /usr is read-only-ish by convention and contains the package manager's databases
		# under /var; nothing else to do before trimming.
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache"/* 2>/dev/null || true

		# FreeBSD has no CA bundle location in base.txz. Copy the build host's, so a
		# session has roots if it ever gets far enough to make an https call.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/ssl/certs"
		sudo cp /etc/ssl/certs/ca-certificates.crt \
			"${WORKDIR}/${rootfs_dir}/etc/ssl/certs/ca-certificates.crt"

		# No bake: there is no Linux package manager here, and marking first-start setup
		# as done would suppress a repair step that is not in the image anyway.
		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "FreeBSD"
		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "freebsd" "$arch" "$up_ver" \
			"\"displayName\": \"FreeBSD\"" \
			"\"source\": \"https://download.freebsd.org/releases/${up_arch}/${up_ver}/base.txz\"" \
			"\"packageManager\": \"pkg\"" \
			"\"isLinux\": false" \
			"\"prootVerified\": false" \
			"\"recipe\": \"distro-build/freebsd.sh\""

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
		# build. Edit distro-build/freebsd.sh instead.
		DISTRO_NAME="FreeBSD"
		DISTRO_COMMENT="BSD, not Linux. Base system only; proot-on-Android support is untested."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/freebsd-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/freebsd-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/freebsd.sh"
}
