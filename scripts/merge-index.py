#!/usr/bin/env python3
"""Merge a freshly generated index into the one already published.

A build can be incremental: change one recipe and only that recipe's images are
rebuilt. generate-index.sh can only see what is in rootfs/ right now, so on an
incremental run it produces an index listing only the recipes just built.

Publishing that would be worse than publishing nothing. The app reads this file
to decide which distributions exist, so every distribution missing from it stops
being offered -- silently, because nothing distinguishes "this distro was
dropped" from "this run did not rebuild it".

So the new entries are merged over the published ones, keyed by distro and arch.
An entry rebuilt now replaces the published one, which is what keeps sha256 and
size honest for that image; everything else is carried over untouched.

Old entries whose file is not in the new build are kept rather than dropped, for
the same reason: a partial build cannot distinguish "removed" from "not rebuilt
this time". Pruning belongs to a run that built everything.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: merge-index.py <published-index> <new-index>", file=sys.stderr)
        return 2

    published_path, new_path = sys.argv[1], sys.argv[2]

    with open(published_path, encoding="utf-8") as fh:
        published = json.load(fh)
    with open(new_path, encoding="utf-8") as fh:
        fresh = json.load(fh)

    if published.get("schema") != fresh.get("schema"):
        print(
            "merge-index.py: refusing to merge schema {} into {}".format(
                published.get("schema"), fresh.get("schema")
            ),
            file=sys.stderr,
        )
        return 1

    merged = {}
    for entry in published.get("images", []):
        merged[(entry.get("distro"), entry.get("arch"))] = entry

    # Counted properly, because the previous version reported a difference in totals
    # and called it "from this build". An incremental run replaces entries rather than
    # adding them, so the total does not move: a run that rebuilt four images printed
    # "0 from this build", which reads exactly like a run that built nothing at all.
    replaced = 0
    added = 0
    for entry in fresh.get("images", []):
        key = (entry.get("distro"), entry.get("arch"))
        if key in merged:
            replaced += 1
        else:
            added += 1
        merged[key] = entry

    fresh["images"] = [
        merged[key] for key in sorted(merged, key=lambda k: (str(k[0]), str(k[1])))
    ]

    with open(new_path, "w", encoding="utf-8") as fh:
        json.dump(fresh, fh, indent=2)
        fh.write("\n")

    print(
        "merge-index.py: {} images total ({} published before, "
        "{} replaced and {} added by this build)".format(
            len(fresh["images"]), len(published.get("images", [])), replaced, added
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())