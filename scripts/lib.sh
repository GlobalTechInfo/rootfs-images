#!/usr/bin/env bash
##
## Shared helpers, sourced by the scripts in this directory.
##
## A sourced file rather than a copy in each script: `require_tools` in particular has to
## behave identically everywhere, and a second copy of it is a second thing to forget to
## update.

# Fails with a message naming what is missing and what wanted it.
#
# The message names the caller because the alternative -- a bare "command not found"
# deep inside a build -- says nothing about which of the dozen steps in a recipe needed
# the tool in the first place.
require_tools() {
	local tool
	for tool in "$@"; do
		if [ -z "$(command -v "$tool")" ]; then
			echo "[!] '${tool}' is required by $(basename "${BASH_SOURCE[1]:-?}") but is not installed." >&2
			exit 1
		fi
	done
}
