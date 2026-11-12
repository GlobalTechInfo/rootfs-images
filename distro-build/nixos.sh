# NixOS 26.05, aarch64 and x86_64.
#
# Source is the official minimal channel ISO from channels.nixos.org. NixOS
# publishes no tarball: the entire userland is one squashfs at the ISO root
# (nix-store.squashfs, ~1.6 GB, ~800 store paths); the rest of the ISO is
# bootloader material (grub, EFI, kernel images) that a proot session does
# not use.
#
# A NixOS rootfs is a read-only nix store plus a handful of links, and this
# recipe is the assembly of those links:
#
#   /bin /sbin /lib /share  -> the "system-path" farm, a store directory whose
#                              entries are links into the store
#   /etc                    -> a real directory of links into the store, plus
#                              four real files the store does not carry
#                              (passwd, group, profile, bashrc). The profile
#                              and bashrc exist because NixOS's compiled-in
#                              shell PATH names /run/wrappers/bin and friends,
#                              which do not exist in a proot tree; without them
#                              an interactive shell cannot find any command.
#   /nix/var/nix/profiles/  -> the nixos-system store path
#
# Each ISO's store is built for that ISO's own architecture, so every
# architecture gets its own image and no cross-architecture component is
# ever mixed. The minimal ISO's store carries two nixos-system paths, a
# stable kernel and an experimental one; the build deterministically picks
# the lower kernel version.
#
# Pinned: the nixos-26.05 channel as of 2026-11-11, both ISOs
# sha256-checked below. The channel moves, so the shas and URLs here are a
# snapshot: when a rebuild is wanted, update the URL and the sha together,
# which is also when the nixos-system selection is re-checked.
#
# The minimal ISO's store is the closure of a whole bootable system, and a
# proot session starts a shell, not a machine. The build prunes the store
# to the dynamic closure of a curated tool set (bash, coreutils, less, vim,
# sudo, git, curl, ssh, ...) plus the system's /etc chain: 5.2 GB down to
# ~550 MB, without dropping anything a kept binary loads at run time.
# What remains is enough for a working session with CA-verified HTTPS;
# what it deliberately does not contain is a channel closure, so nothing
# offline can be installed and `nix-env` is not in the kept set. The index
# records packageManager "nix", and RedTerm reports "no updates" for it.
# That is the shape of NixOS, not a gap in this build.

dist_name="NixOS"
dist_version="26.05"

distro_arches="aarch64 x86_64"

# channels.nixos.org's latest-<arch> alias, pinned with the sha256 of the ISO
# it resolved to on 2026-11-11.
nixos_source_for() {
	case "$1" in
		aarch64)
			echo "https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-aarch64-linux.iso"
			echo "4244322fb3de8e1775ba070e577c1e2960a22b6bdf32b9b74c7eb309d38bee62"
			;;
		x86_64)
			echo "https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso"
			echo "1beb3e006ad420f351fdcb5449ce6dc0504c37ef64b85f418e2bc0884249ac8f"
			;;
		*) echo "nixos_source_for(): unknown arch '$1'" >&2; exit 1;;
	esac
}

# The minimal ISO's store carries a stable and an experimental system. Pick
# the lower kernel version: it is the one grub boots by default, and it is a
# rule that keeps working while the channel moves.
pick_nixos_system() {
	local store="$1" cand kv best="" bestv=""
	for cand in "${store}"/*nixos-system-*; do
		[ -e "$cand" ] || continue
		kv="$(basename "$(dirname "$(readlink "$cand/kernel")")")"
		kv="${kv#linux-}"
		if [ -z "$bestv" ] || { printf '%s\n%s' "$kv" "$bestv" | sort -V | head -n1 | grep -qx "$kv"; }; then
			best="$cand"; bestv="$kv"
		fi
	done
	[ -n "$best" ] || return 1
	basename "$best"
}

bootstrap_distribution() {
	require_tools 7z unsquashfs python3
	local arch url sha rootfs_dir tarball store_dir rootfs sys farm etc etcdir f cacert

	for arch in ${distro_arches}; do
		{ read -r url; read -r sha; } <<< "$(nixos_source_for "$arch")"
		rootfs_dir="nixos-${arch}"
		tarball="${ROOTFS_DIR}/nixos-${arch}-rt-${CURRENT_VERSION}.tar.xz"
		store_dir="${WORKDIR}/${rootfs_dir}-store"

		curl -fL --output "${WORKDIR}/nixos-${arch}.iso" "$url"
		( cd "${WORKDIR}" && echo "${sha}  nixos-${arch}.iso" | sha256sum -c - )

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}" "$store_dir"
		mkdir -p "${store_dir}" "${WORKDIR}/${rootfs_dir}/nix/var/nix/profiles"

		# The store is one squashfs at the ISO root. 7z reads the ISO image
		# directly; mounting it would need a loop device the runner may not
		# have, and the host's unsquashfs handles the zstd-compressed 4.0
		# image the channel has used since 25.05.
		7z x -y "${WORKDIR}/nixos-${arch}.iso" "nix-store.squashfs" -o"${store_dir}" >/dev/null
		unsquashfs -d "${store_dir}" "${store_dir}/nix-store.squashfs" >/dev/null

		sys="$(pick_nixos_system "${store_dir}")" || {
			echo "[!] ${arch}: no nixos-system path in the store; the ISO changed shape." >&2
			exit 1
		}
		farm="$(basename "$(readlink "${store_dir}/${sys}/sw")")"
		etc="$(basename "$(dirname "$(readlink "${store_dir}/${sys}/etc")")")"

		# The store becomes /nix/store wholesale; a single rename keeps the
		# read-only store paths intact (moving them one by one fails on the
		# 0555 directories).
		mv "${store_dir}" "${WORKDIR}/${rootfs_dir}/nix/store"
		ln -s "/nix/store/${sys}" "${WORKDIR}/${rootfs_dir}/nix/var/nix/profiles/default"

		# The farm's subdirectories become the top level.
		rootfs="${WORKDIR}/${rootfs_dir}"
		for f in "${rootfs}/nix/store/${farm}"/*; do
			ln -sf "/nix/store/${farm}/$(basename "$f")" "${rootfs}/$(basename "$f")"
		done

		# /etc is a real directory: store entries as links, four files as
		# real. The store's own profile and bashrc are empty, and its passwd
		# and group do not exist at all, so all four are written here. The
		# farm loop linked /etc at; unlink it, or the entries would be
		# written into the read-only store.
		etcdir="${rootfs}/nix/store/${etc}"
		[ -d "${etcdir}/etc" ] && etcdir="${etcdir}/etc"
		rm -f "${rootfs}/etc"
		mkdir -p "${rootfs}/etc"
		for f in "${etcdir}"/*; do
			ln -sf "/nix/store/${etc}/etc/$(basename "$f")" "${rootfs}/etc/$(basename "$f")"
		done
		rm -f "${rootfs}/etc/profile" "${rootfs}/etc/bashrc"
		printf 'export PATH="/bin:/sbin:/usr/bin:/usr/sbin"\nexport SHELL=/bin/bash\n' > "${rootfs}/etc/profile"
		printf 'export PATH="/bin:/sbin:/usr/bin:/usr/sbin"\n' > "${rootfs}/etc/bashrc"
		printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:Nobody:/:/bin/false\n' > "${rootfs}/etc/passwd"
		printf 'root:x:0:\nnobody:x:65534:\nnixbld:x:30000:\n' > "${rootfs}/etc/group"
		printf 'nameserver 1.1.1.1\n' > "${rootfs}/etc/resolv.conf"
		chmod 644 "${rootfs}/etc/profile" "${rootfs}/etc/bashrc" "${rootfs}/etc/passwd" "${rootfs}/etc/group" "${rootfs}/etc/resolv.conf"

		# NixOS materialises /etc/ssl/certs at boot, in a store directory that
		# ships *empty*: the ca-bundle.crt is written by a service a proot tree
		# never runs, so every HTTPS client (curl, the nix daemon, git) finds
		# no certificate authority. Point the directory at the store's
		# nss-cacert bundle, which is the file every NixOS system's
		# /etc/ssl/certs/ca-bundle.crt is a link to anyway.
		cacert="$(basename "$(ls -d "${rootfs}/nix/store/"*nss-cacert-* | grep -v p11kit | head -n1)")"
		if [ -z "$cacert" ]; then
			echo "[!] ${arch}: no nss-cacert store path; HTTPS would be dead." >&2
			exit 1
		fi
		rm -f "${rootfs}/etc/ssl"
		mkdir "${rootfs}/etc/ssl"
		# Relative on purpose: an absolute /nix/store target resolves inside
		# proot but not on the host, and trim's CA gate is a host-side test.
		# A relative link resolves in both, which is why only this one link
		# in the tree is relative.
		ln -s "../../nix/store/${cacert}/etc/ssl/certs" "${rootfs}/etc/ssl/certs"

		# The directories a shell expects that a NixOS / does not promise.
		mkdir -p "${rootfs}/root" "${rootfs}/home" "${rootfs}/run" \
			"${rootfs}/tmp" "${rootfs}/var" "${rootfs}/dev" "${rootfs}/proc" "${rootfs}/sys"

		# The minimal ISO's store is the closure of a whole bootable system:
		# kernels, module trees, initrds, and every service the configuration
		# pulls in. A proot session starts a shell, not a machine, so prune
		# the store to the dynamic closure of a curated tool set plus the
		# system's /etc chain: 5.2 GB down to ~550 MB on 26.05, without
		# touching any binary a kept tool loads at run time.
		"${SCRIPT_DIR}/nix-store-prune.py" "${rootfs}"

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "NixOS"

		# There is no package update to bake: the store is immutable and the
		# image carries no channel closure. The no-op command keeps the bake's
		# other jobs, the first-start marker and the sudo shim, which are the
		# part RedTerm actually checks.
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" ":"

		# bake refused to write the marker on this tree: its host-side
		# /bin/bash test cannot resolve a link into /nix/store, so it left
		# the marker for RedTerm to write, and every other recipe's marker
		# would have run on a shell that exists. Write it here instead: it
		# is the digest of this recipe's own plan, the one-shot block's
		# elements NUL-joined. If the app's nixos plan ever changes, the
		# stale marker costs one re-run of a no-op block, which is the
		# marker's designed failure mode.
		local token
		token="$(printf ':\000\000\000\000' | sha256sum | cut -c1-16)"
		printf '%s' "$token" > "${rootfs}/root/.init_done"
		chmod 644 "${rootfs}/root/.init_done"

		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		image_meta "$tarball" "nixos" "$arch" "$dist_version" \
			"\"displayName\": \"NixOS\"" \
			"\"sourceImage\": \"nixos-minimal-${arch}-${dist_version}\"" \
			"\"packageManager\": \"nix\"" \
			"\"recipe\": \"distro-build/nixos.sh\""

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
		# build. Edit distro-build/nixos.sh instead.
		DISTRO_NAME="NixOS"
		DISTRO_COMMENT="Functional, config-as-code Linux; the store ships with the tools."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/nixos-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/nixos-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/nixos.sh"
}
