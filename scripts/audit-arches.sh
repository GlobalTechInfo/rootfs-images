#!/usr/bin/env bash
##
## Probe every architecture of every recipe against the network, and report what exists.
##
## Written after FreeBSD i386 was skipped for being "unavailable". It IS published, at
## 14.5, while amd64 and arm64 are on 15.1: probing only the current release makes a lagging
## port look exactly like a dropped one. So this resolves the URL each architecture would
## actually use and fetches it, rather than trusting a list written by hand.
##
## The recipe is sourced with curl and skopeo replaced by functions that print the URL and
## fail, so no download happens and no build runs. Nothing else from bootstrap-rootfs.sh is
## sourced, because sourcing it would start a build.
##
## Usage: audit-arches.sh [recipe-name ...]
##

set -uo pipefail
cd "$(dirname "$(realpath "$0")")/.."

REDTERM_ARCHES="aarch64 arm i686 x86_64"

# Accept bare names as well as paths, since that is how one types them.
recipes=()
for a in "$@"; do
	if [ -f "$a" ]; then recipes+=("$a")
	elif [ -f "distro-build/${a}.sh" ]; then recipes+=("distro-build/${a}.sh")
	elif [ -f "distro-build/${a}" ]; then recipes+=("distro-build/${a}")
	else echo "no such recipe: $a" >&2; fi
done
[ "${#recipes[@]}" -eq 0 ] && recipes=(distro-build/*.sh)

declare -A seen
for r in "${recipes[@]}"; do
	[ -f "$r" ] || continue
	name=$(basename "$r" .sh)
	echo "=== $name ==="

	arches=$(grep -m1 '^distro_arches=' "$r" | sed 's/distro_arches="//; s/"//')
	for arch in $REDTERM_ARCHES; do
		case " $arches " in
			*" $arch "*) ;;
			*) printf '  %-8s  --      not offered by this recipe\n' "$arch"; continue;;
		esac

		url=$(ARCH="$arch" bash -c '
			WORKDIR=/tmp/audit; ROOTFS_DIR=/tmp/audit/rootfs; SCRIPT_DIR=scripts
			ROOTFS_VERSION=audit; CURRENT_VERSION=audit; GIT_RELEASE_URL=x
			tab=$'"'"'\t'"'"'
			# Report the first URL or image reference the recipe would fetch, and stop.
			# Print whichever argument looks like a URL or image reference, wherever it
			# sits in the argv. Taking a fixed position was wrong twice: $2 is --fail in
			# curl and --location in the ones that spell it out.
			_pick() { for x in "$@"; do case "$x" in http://*|https://*|*://*) printf "%s\n" "$x"; return 0;; esac; done; return 1; }
			curl()  { _pick "$@"; exit 22; }
			skopeo() { _pick "$@"; exit 22; }
			sudo()  { "$@"; }
			mmdebstrap() { exit 22; }
			. "$1" >/dev/null 2>&1
			# Restrict the recipe to the one architecture under test. Without this the
			# stub fires on the first architecture and exits the whole function, so every
			# column reported the same URL.
			distro_arches="$ARCH"
			bootstrap_distribution
		' _ "$r" 2>/dev/null | grep -E '^(https?://|[a-z0-9.-]+/[^ ]*:)' | head -1)

		if [ -z "$url" ]; then
			printf '  %-8s  ?      recipe produced no URL to probe\n' "$arch"
			continue
		fi
		# An image reference rather than an http URL: ask the registry whether it has
		# this architecture, which is the same question a download would answer.
		case "$url" in
			http://*|https://*) ;;
			*)
				if command -v skopeo >/dev/null 2>&1 && timeout 120 skopeo inspect --raw "docker://${url}" >/dev/null 2>&1; then
					printf '  %-8s  OK     oci://%s\n' "$arch" "$url"
				else
					printf '  %-8s  oci    %s (not reachable)\n' "$arch" "$url"
				fi
				continue;;
		esac
		case "$url" in
			*xbps*|*pkg*) printf '  %-8s  --      no upstream fetch (installer path)\n' "$arch"; continue;;
		esac

		if [ -n "${seen[$url]:-}" ]; then
			code=${seen[$url]}
		else
			code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$url" 2>/dev/null)
			seen[$url]=$code
		fi
		[ "$code" = "200" ] && mark="OK" || mark="$code"
		printf '  %-8s  %-6s %s\n' "$arch" "$mark" "$url"
	done
	echo
done
