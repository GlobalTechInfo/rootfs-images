#!/usr/bin/env bash
##
## Decide which distributions a build should produce, and write them to
## .build/list.txt, one per line.
##
## This is a script rather than inline YAML so it can be run and tested off
## GitHub. Getting it wrong is expensive in a specific way: a change to
## bootstrap-rootfs.sh affects every recipe, and a decision that skips the
## recipes it should rebuild publishes images built by the *old* builder with a
## fresh sha256, which is worse than not publishing at all.
##
## Usage:
##   select-distributions.sh --event push|pull_request [--base <ref>] [--input "<dists>"]
##
## Outputs the chosen list on stdout as well as in .build/list.txt, so a caller
## can see the decision without reading the file back.
##

set -euo pipefail

EVENT=""
BASE=""
INPUT=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--event) EVENT="$2"; shift 2;;
		--base)  BASE="$2";  shift 2;;
		--input) INPUT="$2"; shift 2;;
		*) echo "select-distributions.sh: unknown argument '$1'" >&2; exit 1;;
	esac
done

cd "$(dirname "$(realpath "$0")")/.."

mkdir -p .build

all_recipes() {
	ls -1 distro-build/*.sh | sed 's@.*/@@; s@\.sh$@@'
}

# The files this event touched. For a PR, the whole diff against the base branch
# rather than just the head commit: a PR of several commits, each touching a
# different recipe, would otherwise only build the last one.
if [ "$EVENT" = "pull_request" ]; then
	if [ -z "$BASE" ]; then
		echo "select-distributions.sh: --base is required for a pull_request." >&2
		exit 1
	fi
	git diff --name-only "${BASE}...HEAD" > .build/changed.txt
else
	git diff-tree --no-commit-id --name-only -r HEAD > .build/changed.txt
fi

if [ -n "$INPUT" ]; then
	# An explicit request wins over the diff. A manual run is meant to build
	# exactly what was asked for, including to re-run something unchanged.
	# shellcheck disable=SC2086
	set -- $INPUT
	printf '%s\n' "$@" | grep -v '^$' > .build/list.txt
elif grep -qx 'bootstrap-rootfs.sh' .build/changed.txt; then
	# Checked before the empty-list case below. The builder affects every recipe,
	# so a change to it invalidates all of them.
	echo "bootstrap-rootfs.sh changed; rebuilding all recipes." >&2
	all_recipes > .build/list.txt
elif grep -q '^scripts/' .build/changed.txt; then
	# A helper script only affects the recipes that call it.
	#
	# Every script under scripts/ used to land in the "we cannot account for this"
	# branch below, so fixing a helper -- adding mirror pruning, correcting a trim --
	# rebuilt all twenty distributions. The change was aimed at one recipe and paid for
	# twenty builds, each overwriting a published asset that had been verified on a real
	# device. That is the same shape as the index.json trap, one directory over.
	#
	# The mapping is not a guess: each recipe names the helpers it runs, so a changed
	# script selects exactly the recipes whose source mentions its name. A script no
	# recipe calls -- a selftest, or this file itself -- selects nothing, which is
	# correct, because running it changes no byte of any image.
	#
	# A *removed* script cannot be grepped for in the new tree, so its recipes are found
	# from the base commit instead. That is the case where getting it wrong would leave
	# an image built by a recipe whose helper no longer exists.
	: > .build/list.txt
	while read -r f; do
		[ -n "$f" ] || continue
		name=$(basename "$f")
		if [ -e "$f" ]; then
			hits=$(grep -l -- "$name" distro-build/*.sh 2>/dev/null || true)
		else
			hits=$(git grep -l -- "$name" "${BASE:-HEAD}" -- 'distro-build/*.sh' 2>/dev/null \
				| sed 's@^[^:]*:@@' || true)
		fi
		if [ -z "$hits" ]; then
			echo "${name}: called by no recipe, so no image is affected." >&2
			continue
		fi
		for h in $hits; do
			echo "${name}: rebuilds $(basename "$h" .sh)" >&2
			basename "$h" .sh >> .build/list.txt
		done
	done < <(grep '^scripts/' .build/changed.txt || true)
	sort -u -o .build/list.txt .build/list.txt
	if [ ! -s .build/list.txt ]; then
		echo "Only helpers that no recipe calls changed; nothing to rebuild." >&2
	fi
else
	sed -n 's@^distro-build/\(.*\)\.sh$@\1@p' .build/changed.txt | sort -u > .build/list.txt
	if [ ! -s .build/list.txt ]; then
		# Distinguish "this change cannot affect any image" from "we do not know
		# what this change affects".
		#
		# They were conflated, and every CI-only edit therefore rebuilt all twenty
		# distributions. A workflow file cannot alter a single byte of any image, so
		# treating it as a reason to rebuild everything meant that every fix to the
		# build itself cost a full build -- pure waste, each time.
		#
		# Only a change we genuinely cannot account for still rebuilds everything.
		if grep -qvE '^(\.github/|\.gitignore$|LICENSE$|README)' .build/changed.txt; then
			echo "Unrecognised change; rebuilding everything to be safe." >&2
			all_recipes > .build/list.txt
		else
			echo "Only CI or documentation changed; no image is affected." >&2
			echo "No recipes selected; nothing to rebuild." >&2
			: > .build/list.txt
		fi
	fi
fi

# A name with no recipe is an error, not something to skip: a typo in a manual
# dispatch otherwise produces a green build with no output and nothing says why.
missing=0
while read -r d; do
	[ -z "$d" ] && continue
	if [ ! -f "distro-build/${d}.sh" ]; then
		echo "select-distributions.sh: no such recipe: distro-build/${d}.sh" >&2
		missing=1
	fi
done < .build/list.txt

if [ "$missing" -ne 0 ]; then
	exit 1
fi

cat .build/list.txt