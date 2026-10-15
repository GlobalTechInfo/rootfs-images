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

		# Reuse the tarball when it is already here.
		#
		# ARMtix publishes exactly one file per release, 1.1 GB, from a single host with
		# no mirror. That host went down entirely -- connection refused on 443 and 80,
		# bare host and www, DNS still resolving -- and the download is the whole build.
		# Re-fetching it for every rebuild means an unrelated recipe change, or a retry
		# after any failure, needs that host to be up even though nothing about the
		# tarball changed.
		#
		# Size is checked as well as presence: a half-written file from an interrupted
		# download is still a file, and reusing one would produce an image missing
		# whatever was not fetched. The size is not pinned in the recipe, because the
		# release is dated and this is the same file that produced the last image.
		arball="${WORKDIR}/armtix-${init}-${dist_version}.tar.xz"
		if [ ! -s "$arball" ]; then
			curl --fail --location \
				--output "$arball" \
				"https://armtixlinux.org/images/armtix-runit-${dist_version}.tar.xz"
		elif ! tar -tJf "$arball" >/dev/null 2>&1; then
			echo "  armtix: cached tarball is truncated or unreadable, fetching it again" >&2
			rm -f "$arball"
			curl --fail --location \
				--output "$arball" \
				"https://armtixlinux.org/images/armtix-runit-${dist_version}.tar.xz"
		else
			echo "  armtix: reusing the cached $(basename "$arball")"
		fi

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

		# The chroot above runs pacman-key --init and --populate artix, which take
		# /var/lib/pacman/db.lck. It is released on a clean exit, and a build that is
		# interrupted or that fails on a later step leaves it behind. An image that
		# ships the lock cannot sync anything, and says only:
		#
		#   error: failed to synchronize all databases (unable to lock database)
		#
		# which names nothing a user can act on. pacman has no way to recover from it
		# either, so the image must not carry it.
		sudo rm -f "${WORKDIR:?}/${rootfs_dir}/var/lib/pacman/db.lck" 2>/dev/null || true

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
		# Disable ALPM hooks by pointing HookDir at a real, empty directory.
		#
		# `HookDir = /dev/null` is not a way to do this: pacman scandir()s whatever
		# HookDir names, /dev/null is not a directory, and the transaction dies with
		#   error: could not open directory: /dev/null/: Not a directory
		#   error: failed to commit transaction (failed to run transaction hooks)
		# which is worse than the noise it was meant to remove.
		#
		# Deleting the hook files works too, but not for long: upgrading systemd
		# reinstalls all eleven, and they are back on the next transaction. An empty
		# directory survives that, and it also covers hooks from packages we have
		# never seen.
		#
		# Verified here that this replaces the backend directory rather than adding
		# to it: a probe hook placed in /usr/share/libalpm/hooks did not run, while the
		# transaction itself proceeded normally.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/pacman.d/hooks"
		sudo find "${WORKDIR}/${rootfs_dir}/etc/pacman.d/hooks" -mindepth 1 -delete 2>/dev/null || true
		sudo sed -i '/^[[:space:]]*#*[[:space:]]*HookDir[[:space:]]*=/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a HookDir = /etc/pacman.d/hooks' "${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# Do not extract man pages, documentation or locale catalogues.
		#
		# The trim removes them to keep the image small, but the packages still claim
		# them, so every upgrade of curl, systemd or anything else re-checks files that
		# are no longer there and prints one line per file:
		#
		#   warning: could not get file information for usr/share/man/man3/CURLOPT_MAXFILESIZE.3.gz
		#
		# hundreds of them, for a file nobody will ever read. NoExtract says the files
		# are not ours to begin with, so pacman neither writes them nor complains that
		# they are missing.
		sudo mkdir -p "${WORKDIR}/${rootfs_dir}/etc/pacman.d"
		# Every hook, not a selection of them.
		#
		# The previous list named the systemd and sysusers hooks individually and left
		# the rest. On the device the transaction still printed, in full:
		#
		#   Creating system user accounts...
		#   Failed to chase and open directory '/etc/sysusers.d', ignoring:
		#     Protocol driver not attached
		#   error: command failed to execute correctly
		#   Updating linux initcpios...
		#   ==> ERROR: Cannot acquire used modules. Unable to use autodetection.
		#
		# which is 20-esysusers and 90-mkinitcpio-install. The second was never on the
		# list at all, and mkinitcpio is the loud one: it walks /sys/devices, which a
		# proot guest cannot read, so it retries and fails on every single transaction.
		#
		# A wildcard cannot go stale when a package adds a new hook, which is the
		# failure mode of enumerating them.
		sudo sed -i '/^[[:space:]]*#*[[:space:]]*NoExtract[[:space:]]*=/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
		sudo sed -i '/^\[options\]/a NoExtract = usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/locale/* usr/share/libalpm/hooks/*' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"

		# Remove them from the image as well.
		#
		# HookDir is supposed to be enough on its own, and a probe hook placed in the
		# backend directory did not run when the image was built. On a device they run
		# anyway, so the configuration alone is not carrying this. Deleting the files
		# makes it true regardless of what pacman does with HookDir, and NoExtract is
		# what stops the deletion from turning into a complaint: without it every
		# package that owns a hook re-checks a file that is no longer there and prints
		#   warning: could not get file information for usr/share/libalpm/hooks/...
		# which is what a previous app-side attempt produced, and which is why this is
		# done here at build time with NoExtract set first, rather than at session start.
		sudo rm -rf "${WORKDIR:?}/${rootfs_dir}/usr/share/libalpm/hooks"/* 2>/dev/null || true

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
		#
		# This pair used to be applied twice in this recipe, once here and once above
		# the XferCommand block. The earlier copy appended `DisableSandbox` after
		# [options] without first deleting an existing one, so the built image
		# carried it twice and pacman complained about the duplicate directive on
		# every command -- which is exactly the "two warnings on every pacman call"
		# that the app-side script works to avoid on Manjaro. Only this copy remains,
		# and it deletes before it inserts, so it is safe to move.
		sudo sed -i '/^[[:space:]]*#*[[:space:]]*DisableSandbox[[:space:]]*=/d' \
			"${WORKDIR}/${rootfs_dir}/etc/pacman.conf"
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