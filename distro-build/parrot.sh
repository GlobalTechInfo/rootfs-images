# Parrot OS, from the official apt archive with mmdebstrap.
#
# Not in upstream proot-distro's recipe set; this one is new. Parrot publishes no Docker
# image -- there is no parrotsec/parrot on the Hub -- so it is built the same way as Debian,
# Ubuntu, Pardus and Trisquel: mmdebstrap against the distro's own archive.
#
# Verified: dists/parrot, parrot-security, parrot-updates and parrot-backports all return
# 200, and the Release file carries
#
#     Architectures: amd64 arm64 armhf riscv64 i386
#
# so all four of RedTerm's architectures are real. The suite is named `parrot` even though
# the codename inside the Release file is `echo`; `echo` is one of several in-tree branches
# (echo, lory, parrot) and `parrot` is the one carrying the full desktop-and-security set.

dist_name="Parrot OS"
dist_version="parrot"
# i686 is NOT built, and the reason is in the archive rather than in this recipe.
# Parrot's Release lists Architectures: amd64 arm64 armhf riscv64 i386, so i386 is
# published -- but its base ships no /proc, /sys or /dev, so mmdebstrap warns
#   skipping mounting of proc because the /proc directory is missing in the target
# and then fails at `dpkg --install`. A setup hook is the obvious fix and is wrong: the
# mount decision is made before the hook runs. Pre-creating the directories does not work
# either, because mmdebstrap then refuses the target with
#   is not empty
# So the 32-bit Parrot tree cannot be bootstrapped by mmdebstrap as published. Dropped
# rather than shipped broken, and noted here rather than discovered on a device.
distro_arches="aarch64 arm x86_64"

# i386 and possibly others need --setup-hook='mkdir -p /proc /sys /dev'.
#
# Parrot's 32-bit base does not ship those directories, so mmdebstrap reports
#   skipping mounting of sysfs because the /sys directory is missing in the target
#   skipping mounting of proc because the /proc directory is missing in the target
# and then fails at `dpkg --install` with a truncated argument list. Nothing in those
# two warnings says the build cannot continue, and the failure that does stop it names
# neither /proc nor the architecture. The hook creates them before the setup phase, so
# there is something to mount onto. aarch64 and armhf include them already and are
# unaffected.

# A specific mirror, not deb.parrot.sh.
#
# deb.parrot.sh is a redirector that round-robins to a pool, and some of its mirrors are
# unreachable. When one is picked the failure is:
#
#   E: Failed to fetch .../libblkid1_..._armhf.deb  Cannot initiate the connection to
#      ftp2.osuosl.org
#   E: apt download failed
#   I: main() received signal PIPE: waiting for setup...      <- mmdebstrap's summary
#
# so the build dies on "signal PIPE" naming nothing about a mirror that would not connect,
# after aarch64 succeeded and arm did not -- which reads like an architecture problem.
#
# Several mirrors were checked for a live dists/parrot/Release; tuna, nju and aliyun all
# answer 200. tuna is used, and PARROT_FALLBACK is tried if it is down.
PARROT_REPO="${PARROT_REPO:-https://mirrors.tuna.tsinghua.edu.cn/parrot}"
PARROT_FALLBACK="https://mirror.nju.edu.cn/parrot"

if ! curl --fail --location --silent --max-time 25 \
		-o /dev/null "${PARROT_REPO}/dists/parrot/Release"; then
	echo "[!] ${PARROT_REPO} is not serving dists/parrot; falling back to ${PARROT_FALLBACK}" >&2
	PARROT_REPO="$PARROT_FALLBACK"
fi
# The pool lists 2024.12 as the newest keyring; the archive redirects to a mirror, which
# curl --location follows.
PARROT_KEYRING_DEB="parrot-archive-keyring_2024.12_all.deb"

parrot_deb_arch() {
	case "$1" in
		aarch64) echo "arm64";;
		arm)     echo "armhf";;
		i686)    echo "i386";;
		x86_64)  echo "amd64";;
		*) echo "parrot_deb_arch(): unknown arch '$1'" >&2; exit 1;;
	esac
}

bootstrap_distribution() {
	local arch deb_arch rootfs_dir tarball

	require_tools mmdebstrap

	for arch in ${distro_arches}; do
		deb_arch=$(parrot_deb_arch "$arch")
		rootfs_dir="parrot-${arch}"
		tarball="${ROOTFS_DIR}/parrot-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		if [ ! -f "${WORKDIR}/parrot-archive-keyring.gpg" ]; then
			# Resolved from the mirror's own pool rather than hardcoded, because the
			# filename differs between mirrors and a stale one 404s.
			local kr
			kr=$(curl --fail --location --silent \
				"${PARROT_REPO}/pool/main/p/parrot-archive-keyring/" \
				| grep -oE 'parrot-archive-keyring_[0-9.]+_all\.deb' | sort -u | tail -1)
			[ -n "$kr" ] || kr="$PARROT_KEYRING_DEB"
			curl --fail --location \
				--output "${WORKDIR}/parrot-archive-keyring.deb" \
				"${PARROT_REPO}/pool/main/p/parrot-archive-keyring/${kr}"
			sudo dpkg-deb --fsys-tarfile "${WORKDIR}/parrot-archive-keyring.deb" \
				| sudo tar -xO ./usr/share/keyrings/parrot-archive-keyring.gpg \
				> "${WORKDIR}/parrot-archive-keyring.gpg"
		fi

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"

		sudo mmdebstrap \
			--architectures="${deb_arch}" \
			--variant=minbase \
			--components="main,contrib,non-free,non-free-firmware" \
			--include="ca-certificates,locales,parrot-archive-keyring,passwd,sudo" \
			--keyring="${WORKDIR}/parrot-archive-keyring.gpg" \
			--format=directory \
			"${dist_version}" \
			"${WORKDIR}/${rootfs_dir}" \
			"deb ${PARROT_REPO} ${dist_version} main contrib non-free non-free-firmware" \
			"deb ${PARROT_REPO} ${dist_version}-updates main contrib non-free non-free-firmware" \
			"deb ${PARROT_REPO} ${dist_version}-security main contrib non-free non-free-firmware"

		# mmdebstrap's --keyring does not survive into the image, so the first apt-get
		# update otherwise fails with "not signed" for every suite.
		#
		# /etc/apt/keyrings, not /etc/apt/trusted.gpg.d. On Parrot the latter is a
		# DANGLING SYMLINK pointing at /etc/apt/trusted.gpg, which does not exist in a
		# minbase image, so `cp` there fails with "not writing through dangling symlink"
		# -- a message about a symlink where the problem is that the target does not
		# exist. /etc/apt/keyrings is a real directory on Debian 13 and is what apt reads.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/apt/keyrings"
		sudo cp "${WORKDIR}/parrot-archive-keyring.gpg" \
			"${WORKDIR}/${rootfs_dir}/etc/apt/keyrings/parrot-archive-keyring.gpg"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/lib/apt/lists"/* 2>/dev/null || true
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/apt/archives"/* 2>/dev/null || true
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		cat <<- EOF | sudo unshare -mpf bash -e -
			set -e
			mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
			mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
			mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
			chroot "${WORKDIR}/${rootfs_dir}" /bin/sh -e -c '
				export DEBIAN_FRONTEND=noninteractive
				apt-get update
				apt-get -y upgrade
				apt-get clean
				rm -rf /var/lib/apt/lists/* /var/log/apt/*
			'
		EOF

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Parrot OS"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
			"apt-get update && apt-get -y upgrade"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "parrot" "$arch" "${dist_version}" \
			"\"displayName\": \"Parrot OS\"" \
			"\"source\": \"${PARROT_REPO}\"" \
			"\"packageManager\": \"apt\"" \
			"\"rolling\": true" \
			"\"recipe\": \"distro-build/parrot.sh\""

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
		# build. Edit distro-build/parrot.sh instead.
		DISTRO_NAME="Parrot OS"
		DISTRO_COMMENT="Security-focused, Debian-derived. Rolling."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/parrot-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/parrot-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/parrot.sh"
}
