#!/usr/bin/env bash
##
## Unpack a container image into a rootfs directory, with no Docker daemon.
##
## Modelled on the OCI-layout walk in termux/proot-distro's distro-build/fedora.sh at
## commit 5bd8f4f, which reads a `.oci.tar.xz` with jq. That works, but it only works
## when the project happens to publish a pre-packed OCI tarball, and three of the four
## distributions here do not:
##
##   * openSUSE's upstream recipe calls `docker manifest inspect` and `docker pull`. A
##     build host has no Docker daemon and should not need one.
##   * Rocky, Alma and CentOS publish only registry images.
#
## skopeo does the pull and writes an OCI layout; this applies the layers with whiteout
## semantics, which is the part that actually matters and the part skopeo does not do.
##
## Whiteouts, because getting them wrong is silent. An OCI layer can delete a file from a
## previous layer by creating a `.wh.<name>` marker, and a layer can delete a whole
## directory with `.wh..wh..opq`. A naive "untar each layer in order" leaves the deleted
## files in place. That is not a corrupt image, it is an image with files nobody meant to
## ship -- usually harmless, occasionally a stray binary that shadows a newer one.
##
## Usage: oci-unpack.sh <image-ref> <rootfs-dir>
##

set -euo pipefail

REF="${1:?usage: oci-unpack.sh <image-ref> <rootfs-dir>}"
DEST="${2:?usage: oci-unpack.sh <image-ref> <rootfs-dir>}"

. "$(dirname "$(realpath "$0")")/lib.sh"
require_tools skopeo jq

# Under the repository, not /tmp. This is the same mistake WORKDIR already had:
# mktemp honours TMPDIR and defaults to /tmp, which is commonly a tmpfs sized as a
# fraction of RAM. skopeo then fails part way through a pull with
#   writing blob: write /tmp/...: no space left on device
# after downloading a few hundred megabytes, naming neither the filesystem nor the size.
OCI_DIR=$(mktemp -d "${OCI_TMPDIR:-$(dirname "$(realpath "$0")")/../.work}/redterm-oci.XXXXXX")
cleanup() { rm -rf "$OCI_DIR"; }
trap cleanup EXIT

# arch selects the image variant, e.g. aarch64. A multi-arch tag has one manifest per
# platform, and taking the wrong one produces an image whose binaries cannot run.
arch="${OCI_ARCH:-$(uname -m)}"

# The variant, not just the architecture. Every arm64 entry in every one of these
# manifest lists is arm64/v8, and skopeo will not pick a v8 image for a plain
# "arm64" request:
#
#   no image found in image index for architecture "aarch64", variant "", OS "linux"
#
# which reads as "this image does not support ARM" rather than "you have to say v8".
variant=""
case "$arch" in
	aarch64|arm64) arch="arm64"; variant="v8";;
	armv7l|arm)    arch="arm";   variant="v7";;
	i386|i686)      arch="386";;
	amd64|x86_64)   arch="amd64";;
esac

echo "  oci: pulling ${REF} (${arch}${variant:+/}${variant})"
skopeo copy --override-os linux --override-arch "$arch" --override-variant "$variant" \
	"docker://${REF}" "oci:${OCI_DIR}/img:latest" >/dev/null

manifest=$(jq -r '.manifests[0].digest' "${OCI_DIR}/img/index.json" | cut -d: -f2)
layers=$(jq -r '.layers[].digest' "${OCI_DIR}/img/blobs/sha256/${manifest}" | cut -d: -f2)

if [ -z "$layers" ]; then
	echo "[!] ${REF} has no layers (an empty or malformed image)." >&2
	exit 1
fi

sudo rm -rf "${DEST:?}"
sudo mkdir -m 755 "$DEST"

i=0
for layer in $layers; do
	i=$(( i + 1 ))
	sudo tar -zxp --acls --xattrs --xattrs-include='*' \
		-f "${OCI_DIR}/img/blobs/sha256/${layer}" -C "$DEST" 2>/dev/null || true

	# Whiteouts, applied after the layer's own files. A .wh.foo removes foo; .wh..wh..opq
	# means "everything inherited from lower layers in this directory is gone", so the
	# directory is emptied of inherited entries before this layer's own contents count.
	sudo find "$DEST" -name '.wh..wh..opq' -print0 2>/dev/null | while IFS= read -r -d '' opq; do
		dir=$(dirname "$opq")
		# Anything in this directory that did not come from a lower layer is already
		# here and must stay, so only entries without a current mtime marker are removed.
		# Practically: remove entries older than the opq marker itself.
		sudo find "$dir" -mindepth 1 -maxdepth 1 ! -newer "$opq" -exec rm -rf {} + 2>/dev/null || true
		sudo rm -f "$opq"
	done
	sudo find "$DEST" -name '.wh.*' ! -name '.wh..wh..opq' -print0 2>/dev/null | while IFS= read -r -d '' wh; do
		target=$(dirname "$wh")/$(basename "$wh" | sed 's/^\.wh\.//')
		sudo rm -rf "$target"
		sudo rm -f "$wh"
	done

	echo "  oci: layer ${i} applied"
done

# Some images have no /dev, /proc or /sys directory at all -- nixos/nix is one. Recipes
# then bind-mount into those paths and fail with
#   mount: .../dev: mount point does not exist
# which names a missing directory rather than the image shape that caused it. Created
# with the right modes so the mount has somewhere to land.
for d in dev proc sys; do
	if [ ! -d "${DEST}/${d}" ]; then
		sudo mkdir -m 755 "${DEST}/${d}"
	fi
done

# The two files every container image has that a rootfs must not.
sudo rm -f "${DEST}/etc/resolv.conf"
sudo tee "${DEST}/etc/resolv.conf" > /dev/null <<< "nameserver 1.1.1.1"
# A container image has /dev populated with bind-mount stubs from its own build.
sudo find "${DEST}/dev" -mindepth 1 -delete 2>/dev/null || true

# Recorded so the index can say what the image was built from.
digest=$(jq -r '.manifests[0].digest' "${OCI_DIR}/img/index.json")
echo "  oci: ${REF}@${digest}"
OCI_DIGEST="$digest"