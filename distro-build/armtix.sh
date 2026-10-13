# ARMtix, aarch64 only.
#
# Not in upstream proot-distro's recipe set under that name -- their distro-build/artix.sh
# builds ARMtix and calls it Artix, which is how mainline Artix ended up looking unsupported
# when it simply publishes no rootfs tarball. Both facts are recorded in findings.md.
#
# ARMtix is an Artix fork for aarch64 and is the only member of that family that publishes
# real rootfs tarballs rather than installer ISOs, so it is the only one of the three that
# can be built without mounting an ISO. Mainline Artix is x86_64-only and ISO-only; that is
# a drop, not an oversight.
#
# The release assets are dated (armtix-openrc-<date>.tar.xz), so the version can be pinned.

# NOTE: deliberately no --acls/--xattrs on extraction. Those flags make GNU tar treat
# some tarballs as containing multiple concatenated archives and extract ZERO files,
# exiting with only "tar: Multiple archive files require '-M' option" -- a message that
# names nothing about the real cause. Confirmed on Gentoo stage3 (0 of 69373 members) and
# ARMtix (0 of 98731); plain extraction gets every one of them. Creating an archive still
# uses --acls/--xattrs in archive_rootfs, which is a different operation and works.
dist_name="ARMtix"
dist_version="20260921"
distro_arches="aarch64"

bootstrap_distribution() {
	local arch rootfs_dir tarball init

	for arch in ${distro_arches}; do
		rootfs_dir="armtix-${arch}"
		tarball="${ROOTFS_DIR}/armtix-${arch}-rt-${CURRENT_VERSION}.tar.xz"

		# ARMtix publishes one rootfs per init system. openrc is the one that works under
		# proot: systemd needs to be PID 1 and manage real cgroups, and a proot guest has
		# neither.
		init="openrc"

		curl --fail --location \
			--output "${WORKDIR}/armtix-${init}-${dist_version}.tar.xz" \
			"https://armtixlinux.org/images/armtix-runit-${dist_version}.tar.xz"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}"
		sudo mkdir -m 755 "${WORKDIR}/${rootfs_dir}"
		# -xJp with a separate -f. NOT -xJpf -f FILE: the 'f' in that flag cluster
		# consumes the next argument as the archive name, so the archive is called "-f"
		# and it reports "Cannot open: No such file or directory" -- which reads as a
		# missing file rather than a malformed command.
		sudo tar -xJp \
			-f "${WORKDIR}/armtix-${init}-${dist_version}.tar.xz" -C "${WORKDIR}/${rootfs_dir}"

		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/etc/resolv.conf"
		sudo tee "${WORKDIR}/${rootfs_dir}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"

		# The upstream image ships a known root password. An image that is downloaded,
		# published and installed on a phone should not arrive with one.
		sudo unshare -mpf bash -e -c "
			set -e
			mount --bind /dev '${WORKDIR}/${rootfs_dir}/dev'
			mount --bind /proc '${WORKDIR}/${rootfs_dir}/proc'
			mount --bind /sys '${WORKDIR}/${rootfs_dir}/sys'
			chroot '${WORKDIR}/${rootfs_dir}' bash -e -c '
				echo \"root:*\" | chpasswd -c || passwd root -l
				pacman-key --init
				# NOT --populate archlinux: ARMtix ships an Artix keyring at
				# /usr/share/pacman/keyrings/artix.gpg, and seeding the Arch one fails
				# because archlinux.gpg does not exist. It has its own signing key and
				# its own repository.
				pacman-key --populate artix
				sed -i \"s/^Server = .*/Server = https:\/\/armtix.artixlinux.org\/repos\/\\\$repo\/os\/\\\$arch/\" /etc/pacman.d/mirrorlist
				# No pacman transaction here. The image is the dated ARMtix release
				# tarball, so it is already current and there is nothing to upgrade. And
				# pacman cannot run one at all: it computes free space by
				# matching device numbers against /proc/self/mountinfo, and inside a
				# chroot the root device does not appear in it, so it reports
				# could-not-determine-root-mount-point and then not-enough-free-disk-space
				# with 33 GB free. bash is checked for below instead of installed.
				test -x /bin/bash
			'
		"

		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/var/cache/pacman/pkg"/* 2>/dev/null || true

		# pacman.conf, for the same three reasons Arch needs them, and all three are
		# device problems rather than build problems.
		#
		# DisableSandbox and DownloadUser: Android has never implemented Landlock, so
		# pacman refuses to sync at all, and proot has no working setuid, so dropping
		# to the alpm user fails too. ARMtix ships DownloadUser = alpm, which is the
		# second of those failures outright. Signature checking is untouched.
		sudo sed -i '/^\[options\]/a DisableSandbox' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*DownloadUser[[:space:]]*=.*/DownloadUser = root/' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# pacman's own downloader, replaced with curl. No -C -: it makes curl send
		# Range requests on retry, the mirror answers those with 404, and combined
		# with -f that is exit 22 -- pacman reporting a failed download for a file
		# that had arrived.
		sudo sed -i '/^[[:space:]]*XferCommand/d; /^[[:space:]]*#[[:space:]]*XferCommand/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a XferCommand = /usr/bin/curl -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 15 -o %o %u' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# Do not run ALPM hooks. Installing wget on a device printed
		#   (1/1) Creating system user accounts...
		#   Failed to chase and open directory '/etc/sysusers.d', ignoring:
		#     Protocol driver not attached
		#   Failed to load user database: Protocol driver not attached
		#   error: command failed to execute correctly
		# and every transaction ends that way. No systemd runs in these sessions, so
		# no hook has anything to do.
		# Remove the systemd ALPM hooks rather than repointing HookDir.
		#
		# `HookDir = /dev/null` is not a way to disable hooks. pacman scandir()s
		# whatever HookDir names, /dev/null is not a directory, and it aborts the
		# whole transaction:
		#
		#   error: could not open directory: /dev/null/: Not a directory
		#   error: failed to commit transaction (failed to run transaction hooks)
		#   Errors occurred, no packages were upgraded.
		#
		# That is strictly worse than the noise it was meant to remove, because the
		# hooks only ever failed *after* a successful install.
		#
		# The hooks are files, so deleting them is what stops them running, and it
		# leaves /usr/share/libalpm/hooks a valid directory.
		#
		# A package that owns one of these restores it on upgrade, which brings the
		# error lines back; the transaction still succeeds.
		sudo find "${WORKDIR}/$${rootfs_dir}/usr/share/libalpm/hooks" -maxdepth 1 -type f \
			-name '20-esysusers.hook' -o -name '21-etmpfiles.hook' -o -name '25-udev-hwdb.hook' -o -name '30-binfmt.hook' -o -name '30-sysctl.hook' -o -name '35-udev-reload.hook' -delete 2>/dev/null || true

		"${SCRIPT_DIR}/verify-rootfs.sh" "${WORKDIR}/${rootfs_dir}" "ARMtix"
		"${SCRIPT_DIR}/bake-first-start.sh" "${WORKDIR}/${rootfs_dir}" "true"
		"${SCRIPT_DIR}/trim-rootfs.sh" "${WORKDIR}/${rootfs_dir}"

		# 422M of the 1.1G tree is /usr/lib/firmware, and roughly 260M of that is x86
		# hardware: intel 123M, nvidia 105M, amdgpu 30M, i915 9.6M. None of it can
		# load on the aarch64 phone this image runs on -- there is no x86 GPU to
		# drive.
		#
		# It arrives because ARMtix packages the Arch linux-firmware blob wholesale,
		# which covers every board and GPU vendor Linux supports in one package. No
		# other distribution in this catalogue ships firmware at all, so this is
		# ARMtix's upstream packaging rather than anything the trim left behind.
		#
		# The ARM wireless firmware stays. mediatek, ath10k/11k/12k, brcm and rtw89
		# are what a phone's wifi and Bluetooth adapters load, and there is no
		# substitute for them inside a session short of reinstalling the package.
		#
		# Kept here rather than in trim-rootfs.sh on purpose: scripts/ changes select
		# all twenty recipes, and this rule is specific to an image that ships the
		# full firmware blob. Put in the shared script it would rebuild the whole
		# catalogue to change one distribution.
		if [ -d "${WORKDIR}/${rootfs_dir}/usr/lib/firmware" ]; then
			for v in intel nvidia amdgpu i915; do
				if [ -d "${WORKDIR}/${rootfs_dir}/usr/lib/firmware/$v" ]; then
					before=$(sudo du -sk "${WORKDIR}/${rootfs_dir}/usr/lib/firmware/$v" | cut -f1)
					sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/usr/lib/firmware/$v"
					echo "  armtix: dropped x86 firmware /$v ($(( before / 1024 )) MB)"
				fi
			done
		fi

		# Remove the package database the bake just synchronised.
		#
		# It is a cache, and shipping a cache pins the image to whatever upstream had
		# on the build day. ARMtix is a rolling release and moves quickly: an image
		# baked with git-2.55.0-1 resolved that version long after the mirror had
		# moved to 2.56.0-1 and deleted the old file, so `pacman -Syu` fetched a URL
		# that returned 404 --
		#
		#   error: failed retrieving file 'git-2.55.0-1-aarch64.pkg.tar.xz'
		#          from armtix.artixlinux.org : 404
		#
		# Every other package in the same transaction downloaded. Only the one whose
		# version had moved on failed, which is what makes it look like a broken
		# mirror rather than a stale snapshot.
		#
		# Deleted after the bake, not before it: the bake needs the database to install
		# anything. Removing it leaves a first `pacman -Sy` to fetch the current one.
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}"/var/lib/pacman/sync/*.db 2>/dev/null || true

		# pacman refuses to sync on a kernel without Landlock:
		#
		#   error: restricting filesystem access failed because Landlock is not
		#          supported by the kernel!
		#   error: switching to sandbox user 'alpm' failed!
		#   error: failed to synchronize all databases
		#
		# Android has never implemented Landlock, so both fire on every device.
		#
		# Set here rather than by the app, for the same reason as the openSUSE
		# repository rewrite: a repair in the app runs once, at first start, on
		# whichever build the user happens to have installed. An image installed with
		# an older app never gets it, and stays broken with nothing to indicate why.
		# An image that is broken until a particular app build repairs it is not a
		# working image.
		#
		# DisableSandbox covers Landlock. It says nothing about the second failure,
		# which is pacman dropping privileges to the alpm user -- that user exists in
		# the image, and the switch fails because proot has no working setuid.
		# DownloadUser = root is the other half. Signature checking is untouched.
		sudo sed -i '/^\[options\]/a DisableSandbox' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*DownloadUser[[:space:]]*=.*/DownloadUser = root/' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		image_meta "$tarball" "armtix" "$arch" "${dist_version}" \
			"\"displayName\": \"ARMtix\"" \
			"\"packageManager\": \"pacman\"" \
			"\"rolling\": true" \
			"\"recipe\": \"distro-build/armtix.sh\""

		archive_rootfs "$tarball" "$rootfs_dir"
		echo "[*] Built $tarball"
		unset init
	done
	unset arch
}

write_plugin() {
	local arch tarball sha
	{
		cat <<- EOF
		# Generated by bootstrap-rootfs.sh. Do not edit: it is rewritten on every
		# build. Edit distro-build/armtix.sh instead.
		DISTRO_NAME="ARMtix"
		DISTRO_COMMENT="Artix-lineage, aarch64. ${dist_version}."

		EOF
		for arch in ${distro_arches}; do
			tarball="${ROOTFS_DIR}/armtix-${arch}-rt-${CURRENT_VERSION}.tar.xz"
			if [ ! -f "$tarball" ]; then
				echo "[!] ${tarball} is missing, cannot write its sha256." >&2
				exit 1
			fi
			sha=$(sha256sum "$tarball" | awk '{ print $1}')
			echo "TARBALL_URL['${arch}']=\"${GIT_RELEASE_URL}/armtix-${arch}-rt-${CURRENT_VERSION}.tar.xz\""
			echo "TARBALL_SHA256['${arch}']=\"${sha}\""
		done
	} > "${PLUGIN_DIR}/armtix.sh"
}
