#!/usr/bin/env bash
##
## Static checks over the recipes, because some mistakes are silent.
##
## Everything checked here produced a build that either failed with a message naming
## something other than the cause, or quietly produced nothing.
##
## Usage: lint.sh
##

set -uo pipefail
cd "$(dirname "$(realpath "$0")")/.."

fail=0
bad() { echo "  $1" >&2; fail=1; }

echo "lint: shell syntax"
for f in bootstrap-rootfs.sh scripts/*.sh distro-build/*.sh; do
	if ! bash -n "$f" 2>/tmp/lint.err; then
		bad "$(basename "$f"): $(head -1 /tmp/lint.err)"
	fi
done

# A flag cluster containing 'f' consumes the NEXT argument as the archive name.
# `tar -xJpf --strip-components=1 -f FILE` therefore archives a file literally called
# "--strip-components=1" and reports "Cannot open: No such file or directory". That is
# what an unreadable or missing file looks like, so it is checked rather than discovered.
# It has happened three times in this repository.
echo "lint: tar flag clusters containing 'f'"
# Comment lines are skipped, but only when the '#' comes before the tar. The first version
# skipped any line containing a '#' anywhere, which meant a fully commented-out example
# elsewhere in the file masked real ones -- the check did not fire on the exact line it was
# written for, which is the failure mode this whole file exists to prevent.
while IFS= read -r line; do
	# Comments are removed before the test rather than skipped by looking at where the '#'
	# is. This check's own prose quotes the offending command, and a line-start rule meant
	# that prose was flagged as if it were code -- the lint reporting itself for explaining
	# itself, which is the kind of noise that teaches people to ignore a linter.
	code=${line%%#*}
	# --? because a long option starts with two dashes. The first version used a single
	# '-', which matched `-x` but not `--strip-components=1`, so the check silently never
	# fired on the exact line it was written for.
	if printf '%s' "$code" | grep -qE 'tar -[a-zA-Z]+f[[:space:]]+--?[a-zA-Z]'; then
		bad "flag cluster with 'f' followed by another flag: $code"
	fi
done < <(cat bootstrap-rootfs.sh scripts/*.sh distro-build/*.sh 2>/dev/null)

# An armtix-style nested bash -c inside a double-quoted string. A comment quoting
# command output verbatim puts bare double quotes inside the outer string and the failure
# is 'unexpected EOF while looking for matching quote' pointing at a comment.
# Deliberately NOT checked: single quotes inside the outer double-quoted block. A first
# attempt flagged every legitimate ${WORKDIR} interpolation and reported nine false
# positives across two healthy recipes -- a linter that cries wolf is worse than none,
# since it teaches people to ignore it. `bash -n` above already catches an unbalanced
# quote, which is the case that actually mattered.
echo "lint: bare double quotes inside outer double-quoted chroot blocks"
for f in distro-build/*.sh; do
	inblock=0
	while IFS= read -r line; do
		case "$line" in
			*'unshare -mpf bash -e -c "'*) inblock=1; continue;;
		esac
		[ "$inblock" -eq 1 ] || continue
		stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
		[ "$stripped" = '"' ] && { inblock=0; continue; }
		case "$stripped" in '#'*) continue;; esac
		case "$line" in *'\"'*) continue;; esac
		case "$line" in *'"'*) bad "$(basename "$f"): bare double quote: $(printf '%.60s' "$stripped")";; esac
	done < "$f"
done

# NOT CHECKED: comments inside backslash-continued commands.
#
#   cmd \\
#     # note
#     --opt \\
#
# is not a command with a comment in it. The backslash removes the newline, so the '#'
# lands mid-line, comments out the rest of ITS line, and --opt becomes a command of its
# own. Every option after the comment silently vanishes. It cost a Parrot build whose only
# symptoms were "sources.list from standard input is empty" and "no known apt sources.list
# entry" -- neither of which mentions a truncated option list.
#
# An awk implementation is left out after three attempts: the heredoc-aware version skipped
# whole files whose heredoc end-tag it never matched, so the check silently stopped firing
# on a file I could reproduce the hazard in. `bash -n` does not catch it either.
#
# Not shipping it is the deliberate choice. A linter that cannot be demonstrated to work is
# worse than none, because it is one more thing to ignore. The hazard is now simply not
# introduced, and this note is what stops it being reintroduced unknowingly.

# A recipe that builds nothing is a green build with no output. bootstrap-rootfs.sh now
# errors on this, but a recipe that produces no image_meta is the same shape of mistake.
echo "lint: recipes define both functions and declare architectures"
for f in distro-build/*.sh; do
	n=$(basename "$f")
	grep -q 'bootstrap_distribution' "$f" || bad "$n: no bootstrap_distribution"
	grep -q 'write_plugin' "$f" || bad "$n: no write_plugin"
	grep -qE '^(distro_arches|distro_suites)=' "$f" || bad "$n: declares no architectures"
	grep -q 'image_meta' "$f" || bad "$n: records no image_meta, so the index cannot describe it"
done

if [ "$fail" -ne 0 ]; then
	echo "lint: FAILED" >&2
	exit 1
fi
echo "lint: clean"
