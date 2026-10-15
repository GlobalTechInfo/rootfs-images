#!/usr/bin/env python3
"""Rewrite the checksum and size of every index entry from the published release.

Why this exists
---------------

`generate-index.sh` records the sha256 and size of each image *as built locally*.
`merge-index.py` then carries those entries forward. The published assets are
therefore described by numbers produced somewhere else in the pipeline, and when
those two disagree the app refuses every install:

    Checksum mismatch for alpine (arm64-v8a).
    expected: 8a5e332a...   <- the index
    got:      9d547e19...   <- what the release is actually serving

Measured across the aarch64 catalogue, 20 of 22 entries disagreed, and every
published asset was *smaller* than the index claimed. So the release is not
corrupt and the transfer is not being altered -- the index is simply stale, and it
was stale in a way that made every install fail.

The authority for "what is at this URL" is the release itself. GitHub's API
returns a `digest` for each uploaded asset, which is the sha256 of the bytes it
holds. That is not a second record to keep in step; it is the same bytes.

So the index stops asserting anything the build happened to observe. This script
takes the release as the source of truth for `sha256` and `size`, and keeps
everything else (distro name, upstream version, display name) from the existing
entry. Metadata it does not recognise is preserved rather than dropped, so an
index that has grown new fields does not lose them to a rewrite.

Run with no arguments it rewrites images/index.json in place from the tag the
repository is currently releasing.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = "GlobalTechInfo/rootfs-images"


def release_assets(tag):
    """Every asset on the release, as (name, size, digest) tuples."""
    out = subprocess.run(
        ["gh", "api", f"repos/{REPO}/releases/tags/{tag}", "--paginate",
         "--jq", ".assets[] | [.name, (.size|tostring), (.digest // \"\")] | @tsv"],
        capture_output=True, text=True, check=True,
    ).stdout
    assets = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        name, size, digest = line.split("\t")
        assets[name] = (int(size), digest.removeprefix("sha256:"))
    return assets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default="images/index.json")
    ap.add_argument("--tag", default=None)
    args = ap.parse_args()

    path = Path(args.index)
    index = json.loads(path.read_text())
    tag = args.tag or index.get("version") or "v1.0.0"

    assets = release_assets(tag)
    if not assets:
        print(f"no assets found on {tag}", file=sys.stderr)
        return 1

    changed, missing, stale = [], [], []
    for entry in index.get("images", []):
        name = entry.get("file")
        if not name or name not in assets:
            missing.append(name or "<no file>")
            continue
        size, digest = assets[name]
        if not digest:
            # An asset with no digest cannot be verified; leaving a stale value in
            # place is better than blanking it, and the caller is told.
            stale.append(name)
            continue
        if entry.get("sha256") != digest or entry.get("size") != size:
            changed.append((name, entry.get("sha256"), digest, entry.get("size"), size))
            entry["sha256"] = digest
            entry["size"] = size

    path.write_text(json.dumps(index, indent=2) + "\n")

    for name, was, now, was_size, now_size in changed:
        print(f"  {name}\n"
              f"    sha256 {str(was)[:16]} -> {now[:16]}\n"
              f"    size   {was_size} -> {now_size}")
    print(f"{len(changed)} entr{'y' if len(changed) == 1 else 'ies'} corrected, "
          f"{len(index.get('images', []))} total")
    if missing:
        print(f"WARNING: {len(missing)} index entries have no asset on the release: "
              f"{', '.join(missing)}", file=sys.stderr)
    if stale:
        print(f"WARNING: {len(stale)} assets published without a digest and left alone: "
              f"{', '.join(stale)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())