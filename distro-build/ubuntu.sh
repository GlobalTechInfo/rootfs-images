# Ubuntu LTS (resolute).
#
# Split out of debian.sh so a fault in one does not rebuild the other. Debian is
# 4 images and Ubuntu 3, and a fix to one used to force a rebuild of both.
#
# Modelled on termux/proot-distro's distro-build/debian.sh at commit 5bd8f4f.
#
# Differences from upstream, all deliberate:
#
#   * Two Debian branches matter and neither is upstream's single pin. RedTerm
#     currently ships 'questing', which is Ubuntu 25.10 — an interim release. Ubuntu
#     26.04 LTS ('resolute') is what users should be on. So the recipe is written for
#     Ubuntu's codename too, and the suite name is the thing that varies.
#
#     Verified: deb.debian.org/dists/stable/Release -> Version: 13.7, Codename: trixie,
#     Date: Sat, 12 Sep 2026.
#     archive.ubuntu.com/ubuntu/dists/resolute/Release -> Version: 26.04, Date 2026-04-23.
#     archive.ubuntu.com/ubuntu/dists/questing/Release -> Version: 25.10, Date 2025-10-09.
#
#   * apt's package lists and cache are cleared. Upstream does not, so every Debian
#     image carries the full index for every configured repository, growing on each
#     upgrade. mmdebstrap leaves them behind.
#
#   * --include carries ca-certificates. Upstream has it, and it is what makes TLS work
#     inside the image — the same reason void.sh's SSL_NO_VERIFY_PEER=1 is a defect
#     rather than a style choice.
#
#   * The locale is configured at build time. Upstream defers it to distro_setup(), which
#     runs on the device and costs a dpkg-reconfigure on first launch. Phase 4 bakes
#     first-start work away; doing the cheap half of it here is the same idea.
#
# This recipe is Debian-family only: mmdebstrap + a suite name. Ubuntu differs in
# architecture support (no i686) and in needing its own apt sources, so it is a separate
# recipe rather than a flag here.

dist_name="Debian"

# Debian codenames RedTerm can build. 'trixie' is Debian 13; 'resolute' is Ubuntu
# 26.04 LTS. Kept here so bootstrap-rootfs.sh can build either by name.
#
# The suite name is what identifies the image, so it is what goes in the filename.
# There is deliberately no separate dist_version: the first version of this recipe
# used one and every Ubuntu image came out named `resolute-aarch64-trixie-...`,
# which is a filename that lies about what it contains.
distro_suites="resolute"

# i686 exists for Debian but Ubuntu has not shipped it since 18.04.
suites_i686() {
	case "$1" in
		trixie) echo "yes";;
		*) echo "no";;
	esac
}

# Display name per suite, so a user is told what they are installing.
suite_display_name() {
	case "$1" in
		trixie)  echo "Debian 13 (trixie)";;
		resolute) echo "Ubuntu 26.04 LTS (resolute)";;
		*) echo "unknown suite '$1'" >&2; exit 1;;
	esac
}

# Architectures for a suite, in RedTerm's names.
suite_arches() {
	if [ "$(suites_i686 "$1")" = "yes" ]; then
		echo "aarch64 x86_64 arm i686"
	else
		echo "aarch64 x86_64 arm"
	fi
}

bootstrap_distribution() {
	local suite arch rootfs_dir tarball

	for suite in ${distro_suites}; do
		for arch in $(suite_arches "$suite"); do
			# Debian's own architecture names; translated to ours.
			case "$arch" in
				aarch64) local deb_arch=arm64;;
				arm)     local deb_arch=armhf;;
				i686)    local deb_arch=i386;;
				x86_64)  local deb_arch=amd64;;
				*) echo "unknown arch '$arch'" >&2; exit 1;;
			esac

			rootfs_dir="${suite}-${arch}"
			tarball="${ROOTFS_DIR}/${suite}-${arch}-rt-${CURRENT_VERSION}.tar.xz"

			# mmdebstrap is required here rather than globally, so an Alpine-only build
			# does not need it installed.
			require_tools mmdebstrap

			sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
			# mmdebstrap verifies InRelease with keyrings from the HOST, and its
			# default set is /etc/apt/trusted.gpg and /etc/apt/trusted.gpg.d. The
			# runner is Ubuntu and has no Debian or Ubuntu archive key in either
			# place, so mmdebstrap fails with NO_PUBKEY while creating the target.
			#
			# Both keys are fetched from the archives rather than taken from the
			# host. The host is Ubuntu 24.04 and its Debian keyring package is
			# bookworm-era, which does not sign trixie; copying it would verify
			# nothing and would look like it had worked. The key that matters is the
			# one belonging to the suite being built.
			#
			# This recipe builds two suites and they need two different keys:
			#   trixie    -- Debian 13, https://ftp-master.debian.org/keys/archive-key-13.asc
			#   resolute  -- Ubuntu 26.04, from ubuntu-keyring
			keydir="${WORKDIR}/keyrings"
			sudo rm -rf "${keydir:?}"
			sudo mkdir -p "${keydir}"

			case "$suite" in
			trixie)
				# Three files, not one. archive-key-13 signs the main archive,
				# archive-key-13-security signs security.debian.org, and release-13 signs
				# the release. Signing one archive with the previous archive's key was the
				# first attempt and failed for security.debian.org while deb.debian.org
				# succeeded, which is what identified the split.
				#
				# The debian-archive-keyring package is not used for this suite: the pool
				# only carries 2025.1, which predates trixie and contains bookworm,
				# bullseye and buster keys only.
				for k in archive-key-13 archive-key-13-security release-13; do
					curl --fail --silent --show-error --location \
						--output "${WORKDIR}/${k}.asc" \
						"https://ftp-master.debian.org/keys/${k}.asc" \
						|| { echo "  debian: could not fetch ${k}.asc" >&2; return 1; }
					gpg --batch --yes --dearmor --output "${WORKDIR}/${k}.gpg" \
						"${WORKDIR}/${k}.asc"
					sudo cp "${WORKDIR}/${k}.gpg" "${keydir}/${k}.gpg"
				done
				;;
			resolute)
				# Ubuntu's keyring is only distributed as a .deb, and the pool carries
				# several versions. Pinned deliberately: the version is named in the
				# message below so a failure says which one was wanted, rather than
				# reporting a missing key.
				curl --fail --silent --show-error --location \
					--output "${WORKDIR}/ubuntu-keyring.deb" \
					"http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/ubuntu-keyring_2026.08.18_all.deb" \
					|| { echo "  debian: could not fetch ubuntu-keyring 2026.08.18 for resolute" >&2; return 1; }
				sudo rm -rf "${WORKDIR}/uk"
				sudo dpkg-deb --extract "${WORKDIR}/ubuntu-keyring.deb" "${WORKDIR}/uk"
				sudo cp "${WORKDIR}/uk/usr/share/keyrings/ubuntu-archive-keyring.gpg" \
					"${keydir}/ubuntu-archive-keyring.gpg"
				;;
			esac

			echo "  debian: keyring for ${suite}: $(sudo ls "${keydir}" | tr '\n' ' ')"

			# The keyring package is named differently by each archive, and asking for
			# the wrong one is a hard failure rather than a warning:
			#
			#   E: Package 'debian-archive-keyring' has no installation candidate
			#
			# It exists in Debian's archive and not in Ubuntu's, so resolute failed on a
			# package that trixie needs. Hardcoded because the list was written for
			# trixie and the second suite was added to the same recipe later.
			case "$suite" in
			trixie)   keyring_pkg=debian-archive-keyring ;;
			resolute) keyring_pkg=ubuntu-keyring ;;
			*) echo "debian.sh: no keyring package for suite '$suite'" >&2; return 1 ;;
			esac

			# Components differ per archive and a wrong one is not an error at build
			# time -- it is written into sources.list and only fails later, in the
			# session:
			#
			#   W: Skipping acquire of configured file 'contrib/binary-arm64/Packages'
			#      as repository ... doesn't have the component 'contrib'
			#   E: Unable to locate package nodejs
			#
			# Ubuntu has no contrib at all. It has restricted, universe and multiverse
			# instead, and nodejs lives in universe -- so asking for main,contrib both
			# produced the warning and omitted the component the package is in.
			case "$suite" in
			trixie)   components="main,contrib,non-free" ;;
			resolute) components="main,restricted,universe,multiverse" ;;
			*) echo "debian.sh: no component set for suite '$suite'" >&2; return 1 ;;
			esac

			sudo mmdebstrap \
				--keyring="${keydir}" \
				--architectures="${deb_arch}" \
				--variant=minbase \
				--components="${components}" \
				--include="ca-certificates,locales,sudo,${keyring_pkg}" \
				--format=directory \
				"${suite}" \
				"${WORKDIR}/${rootfs_dir}"

			# Upstream does neither of these. The lists are a download cache: tens of MB
			# that no session can use, and they change whenever an upstream release
			# happens, so leaving them in makes the image both larger and less
			# reproducible.
			sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/lib/apt/lists"/* || true
			sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/apt/archives"/* || true

			# mmdebstrap writes resolv.conf itself; replace it with a plain one so the
			# image carries no build-host state.
			sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
			sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

			# apt does not trust /usr/share/keyrings by default. It consults
			# /etc/apt/trusted.gpg and /etc/apt/trusted.gpg.d, and uses a key in
			# /usr/share/keyrings only when the source line names it with signed-by.
			#
			# The debian-archive-keyring package installs its key to the share
			# directory and nothing else, so a target that has the package can still
			# fail to verify InRelease -- which is exactly what happened here under
			# emulation while working natively, because mmdebstrap's generated
			# sources.list is what normally supplies signed-by.
			#
			# Copying the key into trusted.gpg.d makes the target able to verify
			# regardless of how the sources.list turned out, and stops this depending
			# on a file mmdebstrap wrote rather than on one we control.
			echo "  debian: apt keyring state before bake:"
			sudo ls -l "${WORKDIR}/${rootfs_dir}/usr/share/keyrings/" 2>&1 | sed 's/^/    /' || true
			sudo ls -l "${WORKDIR}/${rootfs_dir}/etc/apt/trusted.gpg.d/" 2>&1 | sed 's/^/    /' || true
			sudo cat "${WORKDIR}/${rootfs_dir}/etc/apt/sources.list" 2>&1 | sed 's/^/    /' || true

			sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/apt/trusted.gpg.d"
			if [ -f "${WORKDIR}/${rootfs_dir}/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
				sudo cp "${WORKDIR}/${rootfs_dir}/usr/share/keyrings/debian-archive-keyring.gpg" \
					"${WORKDIR}/${rootfs_dir}/etc/apt/trusted.gpg.d/debian-archive-keyring.gpg"
				echo "  debian: installed the archive keyring into trusted.gpg.d."
			else
				echo "  debian: WARNING no /usr/share/keyrings/debian-archive-keyring.gpg to copy." >&2
			fi

			# unshare -m for the bind mounts, -p so the chroot is PID 1, -f because we are
			# not the parent of a forked tree.
			cat <<- EOF | sudo unshare -mpf bash -e -
				mount --bind /dev "${WORKDIR}/${rootfs_dir}/dev"
				mount --bind /proc "${WORKDIR}/${rootfs_dir}/proc"
				mount --bind /sys "${WORKDIR}/${rootfs_dir}/sys"
				chroot "${WORKDIR}/${rootfs_dir}" dpkg-reconfigure locales
				chroot "${WORKDIR}/${rootfs_dir}" apt-get clean
			EOF

			# Bake what RedTerm would otherwise do on the user's first launch: the
			# system update, bash, the sudo shim, and the /root/.init_done marker.
			# Without this the user's first terminal opens on a multi-minute
			# ">>> First-time distro setup".
			"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "Debian"
			"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" \
				"apt-get update && apt-get -y upgrade"

			# Trim last, so the update's own downloads are removed and the size
			# reported is the size that ships.
			"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

			# Debian and Ubuntu share a recipe, so the meta records which one this is.
			case "$suite" in
				trixie)  local meta_distro=debian; local meta_upstream="13";;
				resolute) local meta_distro=ubuntu; local meta_upstream="26.04";;
				*) echo "unknown suite '$suite'" >&2; exit 1;;
			esac
			# openssh-client's postinst does `chgrp _ssh`, and minbase has no such group.
		#
		# Not a build-time error: the image builds, verifies and trims. It appears the
		# first time anything pulls openssh-client in -- git recommends it -- and then
		# the package manager is left broken for every later install:
		#
		#   chgrp: bad group '_ssh'
		#   E: Sub-process /usr/bin/dpkg returned an error code (1)
		#
		# Created only when absent, so an image that already has it is untouched.
		if ! grep -q "^_ssh:" "${WORKDIR}/${rootfs_dir}/etc/group"; then
			if sudo chroot "${WORKDIR}/${rootfs_dir}" groupadd --system _ssh 2>/dev/null; then
				echo "  debian: created the _ssh system group for openssh's postinst."
			else
				sudo sed -i '1i _ssh:x:995:995::/run/sshd:/usr/sbin/nologin' \
					"${WORKDIR}/${rootfs_dir}/etc/group"
				echo "  debian: added the _ssh group to /etc/group directly."
			fi
		fi

		image_meta "$tarball" "$meta_distro" "$arch" "$meta_upstream" \
				"\"suite\": \"${suite}\"" \
				"\"displayName\": \"$(suite_display_name "$suite")\"" \
				"\"recipe\": \"distro-build/debian.sh\""

			archive_rootfs "$tarball" "$rootfs_dir"
			echo "[*] Built $tarball"
			unset deb_arch
		done
	done
	unset suite
}

write_plugin() {
	local suite arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/debian.sh instead.

		EOF
		for suite in ${distro_suites}; do
			echo "# $(suite_display_name "$suite")"
			for arch in $(suite_arches "$suite"); do
				tarball="${ROOTFS_DIR}/${suite}-${arch}-rt-${CURRENT_VERSION}.tar.xz"
				if [ ! -f "$tarball" ]; then
					echo "[!] ${tarball} is missing, cannot write its sha256." >&2
					exit 1
				fi
				sha=$(sha256sum "$tarball" | awk '{ print $1}')
				echo "TARBALL_URL['${suite}/${arch}']=\"${GIT_RELEASE_URL}/${suite}-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
				echo "TARBALL_SHA256['${suite}/${arch}']=\"${sha}\""
			done
			echo
		done
	} > "${PLUGIN_DIR}/debian.sh"
}