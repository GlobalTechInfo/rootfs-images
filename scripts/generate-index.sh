#!/usr/bin/env bash
##
## Write images/index.json, the catalogue the RedTerm app reads at runtime.
##
## This is what takes the distro list out of compiled-in Kotlin. The app falls back to
## its built-in table when the index cannot be fetched, so a device that is offline still
## installs what it always did.
##
## Every entry carries the sha256 of the image as built, the upstream version it was built
## from, and the recipe that produced it. Those last two are provenance: an image with no
## recorded version is a file, and a file is what makes a supply chain unauditable.
##
## Identity comes from the per-image sidecar a recipe writes (rootfs/.meta/*.json), not
## from the filename. Filenames cannot carry both an upstream version and a build version
## without being ambiguous to parse, and the first version of this script got it wrong:
## it read "alpine-aarch64-3.24.2" as distro=alpine-aarch64, arch=3.24.2.
##
## Usage: generate-index.sh [version]
##

set -euo pipefail

cd "$(dirname "$(realpath "$0")")/.."

VERSION="${1:-${ROOTFS_VERSION:-}}"
if [ -z "$VERSION" ]; then
	VERSION=$(git tag | sort -Vr | head -n1)
fi
if [ -z "$VERSION" ]; then
	echo "generate-index.sh: no version given and no tag found" >&2
	exit 1
fi

# The version is part of the path, not optional. Without it the emitted URLs are
# .../releases/download/alpine-aarch64-rt-v0.5.0.tar.xz, which is not a release asset URL
# at all -- a download that 404s while looking entirely well-formed.
RELEASE_BASE="${ROOTFS_RELEASE_URL:-https://github.com/GlobalTechInfo/rootfs-images/releases/download}/${VERSION}"

mkdir -p images

# Sorted by distro then arch, so an index whose content has not changed is itself
# byte-stable. Only images from this build version are published: a leftover tarball from
# a previous run would otherwise appear in the index pointing at a release that may not
# exist yet.
count=0
skipped=0
declare -a rows=()
for tarball in $(ls -1 rootfs/*.tar.xz | sort); do
	base=$(basename "$tarball")
	case "$base" in
		*-rt-"${VERSION}".tar.xz) ;;
		*) skipped=$(( skipped + 1 )); continue;;
	esac
	meta="rootfs/.meta/${base}.json"
	if [ ! -f "$meta" ]; then
		echo "generate-index.sh: no sidecar for ${base}, skipping" >&2
		skipped=$(( skipped + 1 ))
		continue
	fi
	count=$(( count + 1 ))
	rows+=("$(printf '%s\t%s' "$base" "$meta")")
done

if [ "$count" -eq 0 ]; then
	echo "generate-index.sh: no images for ${VERSION}" >&2
	exit 1
fi

{
	printf '{\n'
	printf '  "schema": 1,\n'
	printf '  "version": "%s",\n' "$VERSION"
	printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '  "images": [\n'
	first=1
	for row in "${rows[@]}"; do
		base="${row%%$'\t'*}"
		meta="${row##*$'\t'}"
		# The sidecar is our own JSON and every field comes from image_meta, so a sed
		# extraction is enough and jq is not required. `|| true` matters: a field that
		# is absent makes grep exit non-zero, and under `set -o pipefail` that makes the
		# whole pipeline non-zero, which under `set -e` kills the script from inside a
		# command substitution with no message. An optional field is normal, not fatal.
		field() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$meta" | head -1 | sed 's/.*: *"\(.*\)"/\1/' || true; }
		distro=$(field distro); arch=$(field arch); upstream=$(field upstreamVersion)
		recipe=$(field recipe); display=$(field displayName)
		size=$(stat -c '%s' "rootfs/${base}")
		sha=$(sha256sum "rootfs/${base}" | cut -d' ' -f1)
		[ -n "$display" ] || display="$distro"
		# The URL template the app substitutes {arch} into. Published rather than
		# reconstructed by the app: deriving it from concrete per-arch URLs means
		# guessing which part of the path is the architecture, and a wrong guess fails
		# as a download error that names nothing.
		template="${RELEASE_BASE}/${base//${arch}/\{arch\}}"
		[ "$first" -eq 1 ] || printf ',\n'
		first=0
		printf '    {'
		printf '"distro": "%s", ' "$distro"
		printf '"arch": "%s", ' "$arch"
		printf '"upstreamVersion": "%s", ' "$upstream"
		printf '"displayName": "%s", ' "$display"
		printf '"file": "%s", ' "$base"
		printf '"url": "%s/%s", ' "$RELEASE_BASE" "$base"
		printf '"baseUrlTemplate": "%s", ' "$template"
		printf '"sha256": "%s", ' "$sha"
		printf '"size": %s, ' "$size"
		printf '"buildVersion": "%s", ' "$VERSION"
		printf '"recipe": "%s"' "$recipe"
		printf '}'
	done
	printf '\n  ]\n'
	printf '}\n'
} > images/index.json.tmp

mv images/index.json.tmp images/index.json

python3 -c "
import json
seen = set()
d = json.load(open('images/index.json'))
assert d['schema'] == 1, d['schema']
for i in d['images']:
    assert i['distro'] and i['arch'] and i['sha256'] and len(i['sha256']) == 64, i
    assert i['url'].endswith(i['file']), i
    # The release version has to be in the path. A URL without it is still a
    # well-formed-looking string that 404s, and nothing downstream notices until a
    # device tries to install from it.
    assert '/releases/download/%s/' % d['version'] in i['url'], i
    # The template is the concrete URL with this architecture replaced by {arch}, so
    # substituting the architecture back must reproduce the concrete URL exactly.
    assert i['baseUrlTemplate'].replace('{arch}', i['arch']) == i['url'], i
    seen.add((i['distro'], i['arch']))
assert len(seen) == len(d['images']), 'duplicate distro/arch in index'
print('generate-index.sh: %d image(s), %d skipped' % (len(d['images']), $skipped))
print('  distros: %s' % ', '.join(sorted({i['distro'] for i in d['images']})))
"