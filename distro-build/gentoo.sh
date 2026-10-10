# Gentoo, from the official stage3 tarballs.
#
# Modelled on termux/proot-distro's recipe set at commit 5bd8f4f, which has no Gentoo
# recipe; this one is new.
#
# Gentoo is the best-behaved of the extra distributions:
#
#   * stage3 is a real minimal rootfs with a working @world already resolved, so there is
#     no desktop to strip and no installer ISO to mount.
#   * it is published for all four architectures RedTerm ships.
#   * autobuilds are dated, so a version can be pinned and given a stable sha256.
#
# Two things about the layout are traps:
#
#   * The 32-bit ports are NOT in directories named after them. There is no
#     .../releases/armhf/ and no .../releases/i686/ — both 404, which reads as "32-bit was
#     dropped". i686 lives under x86/ (the legacy port name) and armv7 under arm/.
#
#   * The autobuild timestamp differs per architecture, so the amd64 stamp 404s on arm64.
#     The "current-stage3-<profile>" symlink is the only portable way to ask.
#
# Usage of GENTOO_STAGE3_DATE: pins every architecture to one dated autobuild, so a
# release is reproducible across arches rather than being whatever each arch last built.

# NOTE: deliberately no --acls/--xattrs on extraction. Those flags make GNU tar treat
# some tarballs as containing multiple concatenated archives and extract ZERO files,
# exiting with only "tar: Multiple archive files require '-M' option" -- a message that
# names nothing about the real cause. Confirmed on Gentoo stage3 (0 of 69373 members) and
# ARMtix (0 of 98731); plain extraction gets every one of them. Creating an archive still
# uses --acls/--xattrs in archive_rootfs, which is a different operation and works.
dist_name="Gentoo"

# arch-dir is what upstream calls the port directory; profile is the stage3 profile.
#
# openrc, not systemd. proot cannot run systemd: it needs to be PID 1 and to manage real
# cgroups, and a proot guest has neither. An image built on the systemd profile would
# boot to a shell that works and a `systemctl` that does not, which is worse than never
# having offered it.
gentoo_port_for() {
	case "$1" in
		aarch64) echo "arm64 arm64-openrc";;
		arm)     echo "arm armv7a-openrc";;
		i686)    echo "x86 i686-openrc";;
		x86_64)  echo "amd64 amd64-openrc";;
		*) echo "gentoo_port_for(): unknown arch '$1'" >&2; exit 1;;
	esac
}

distro_arches="aarch64 arm i686 x86_64"

# The newest stage3 for a port, printed as its filename. Uses the current-stage3 symlink
# rather than guessing a date, because the per-arch timestamps differ and a guessed one
# 404s more often than not.
newest_stage3() {
	local port="$1" profile="$2" listing
	listing=$(curl --fail --location --silent \
		"https://distfiles.gentoo.org/releases/${port}/autobuilds/current-stage3-${profile}/")
	echo "$listing" \
		| grep -oE "stage3-${profile}-[0-9]{8}T[0-9]{6}Z\.tar\.xz" \
		| sort -u \
		| tail -n1
}

bootstrap_distribution() {
	local arch port profile stage3 stage3_url rootfs_dir tarball

	for arch in ${distro_arches}; do
		set -- $(gentoo_port_for "$arch")
		port="$1"; profile="$2"

		if [ -n "${GENTOO_STAGE3_DATE:-}" ]; then
			stage3="stage3-${profile}-${GENTOO_STAGE3_DATE}.tar.xz"
		else
			stage3=$(newest_stage3 "$port" "$profile")
		fi
		if [ -z "$stage3" ]; then
			echo "[!] no stage3 found for ${arch} (${port}/${profile})" >&2
			exit 1
		fi
		stage3_url="https://distfiles.gentoo.org/releases/${port}/autobuilds/current-stage3-${profile}/${stage3}"
		echo "[*] Gentoo ${arch}: ${stage3}"

		rootfs_dir="gentoo-${arch}"
		tarball="${ROOTFS_DIR}/gentoo-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		curl --fail --location --output "${WORKDIR}/${stage3}" "$stage3_url"
		# The .sha256 sidecar is published next to the tarball.
		curl --fail --location --output "${WORKDIR}/${stage3}.sha256" "${stage3_url}.sha256"
		# The sidecar is a clear-signed PGP message, not a plain sha256sum file, so
		# `sha256sum -c` on it warns "13 lines are improperly formatted" and passes on
		# luck. Take only the line for our own file and compare it directly.
		local want got
		want=$(grep -E "[[:space:]]\*?${stage3}\$" "${WORKDIR}/${stage3}.sha256" | head -1 | cut -d' ' -f1)
		got=$(sha256sum "${WORKDIR}/${stage3}" | cut -d' ' -f1)
		if [ -z "$want" ] || [ "$want" != "$got" ]; then
			echo "[!] ${stage3}: expected ${want}, got ${got}" >&2
			exit 1
		fi
		echo "[*] sha256 verified for ${stage3}"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}"
		# Plain extraction, no --acls/--xattrs. The Alpine tarball needs them, but
		# combining them here extracts ZERO files and exits 2 with only
		# "tar: Multiple archive files require '-M' option", which says nothing about the
		# real cause. Plain `tar -xf` extracts all 69373 members of this same stage3.
		sudo tar -xf "${WORKDIR}/${stage3}" -C "${WORKDIR}/${rootfs_dir}"

		# stage3 ships a resolv.conf pointing at whatever built it.
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		# Portage's cache is the same story as apk's and apt's: large, useless at runtime,
		# and it changes on every build.
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/edb" 2>/dev/null || true

		# proot-distro v5's release notes say the Gentoo stage3 image needs the portage
		# sandbox disabled, and they are right: sandboxing needs namespaces, which proot
		# does not provide, so `emerge` fails trying to set one up. Done before anything
		# invokes emerge, including the bash install below.
		sudo mkdir -p "${WORKDIR:?}/${rootfs_dir}/etc/portage"
		sudo tee -a "${WORKDIR}/${rootfs_dir}/etc/portage/make.conf" > /dev/null <<< 'FEATURES="-sandbox"'

		# No emerge update here: it would make the image depend on the day it was built,
		# which is the one thing the reproducibility work removed. The stage3 @world is
		# already resolved.
		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Gentoo"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
			"true" \
			"emerge --oneshot --nodeps bash || true"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		# Strip the stage3-<profile>- prefix and the .tar.xz suffix, so the recorded
		# version is the autobuild timestamp rather than a filename.
		local up="${GENTOO_STAGE3_DATE:-${stage3#stage3-${profile}-}}"
		up="${up%.tar.xz}"
		image_meta "$tarball" "Gentoo" "$arch" "$up" \
			"\"recipe\": \"distro-build/gentoo.sh\"" \
			"\"stage3\": \"${stage3}\"" \
			"\"packageManager\": \"portage\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
		unset port profile stage3
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/gentoo.sh instead.
		DISTRO_NAME="Gentoo"
		DISTRO_COMMENT="Source-based, minimal, four architectures."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/gentoo-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/gentoo-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/gentoo.sh"
}