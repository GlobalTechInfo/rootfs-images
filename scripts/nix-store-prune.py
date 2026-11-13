#!/usr/bin/env python3
"""
Prune a NixOS rootfs's /nix/store down to what a proot session actually runs.

The minimal ISO's store is the closure of a whole bootable system: two
kernels, module trees, initrds, and every service the configuration
pulls in. A proot session starts a shell, not a machine, so most of
that is dead weight on a phone. This walks the dynamic dependencies
(ELF NEEDED entries) of a curated tool set plus the system's etc tree,
and removes every store path the walk does not reach.

It is deliberately conservative in one direction: the keep-set is the
transitive closure of the listed tools, so nothing a kept binary can
load at runtime is dropped. What it cannot see is a file a binary
reads at run time (terminfo, locale archives, CA bundles), so those
are kept explicitly by name below.
"""

import os
import shutil
import struct
import sys

# Farm commands to keep, as the system-path farm names them. A name that
# is not in this image's farm is reported, not fatal.
KEEP_TOOLS = [
    "bash", "sh", "coreutils", "gawk", "sed", "grep", "find", "less", "nano",
    "vim", "vi", "sudo", "tar", "git", "gzip", "xz", "bzip2", "unzip",
    "which", "ps", "top", "curl", "ssh", "scp", "sftp", "ssh-keygen",
    "ip", "ss", "ping", "htop", "tree",
    # The nix package and its closure: the session must be able to install
    # packages, not only run a frozen tool set. All of these names ship in
    # the nix package's bin directory, so they resolve to one store path.
    "nix", "nix-env", "nix-build", "nix-channel", "nix-shell", "nix-store",
    "nix-hash", "nixos-rebuild",
]

# Kept by name, not reachable through any NEEDED entry.
KEEP_PATHS = [
    "nss-cacert",          # the CA bundle /etc/ssl/certs links into
    "terminfo",            # TERM database for less/vim
]

PT_LOAD = 1
PT_DYNAMIC = 2
DT_NEEDED = 1
DT_STRTAB = 5


def elf_needed(path):
    """DT_NEEDED sonames of an ELF, or None when it is not an ELF."""
    try:
        with open(path, "rb") as f:
            data = f.read(512)
            if len(data) < 52 or data[:4] != b"\x7fELF":
                return None
        is64 = data[4] == 2
        little = data[5] == 1
        end = "<" if little else ">"
        if is64:
            e_phoff = struct.unpack_from(end + "Q", data, 0x20)[0]
            e_phentsize = struct.unpack_from(end + "H", data, 0x36)[0]
            e_phnum = struct.unpack_from(end + "H", data, 0x38)[0]
        else:
            e_phoff = struct.unpack_from(end + "I", data, 0x1C)[0]
            e_phentsize = struct.unpack_from(end + "H", data, 0x2A)[0]
            e_phnum = struct.unpack_from(end + "H", data, 0x2C)[0]
        with open(path, "rb") as f:
            f.seek(e_phoff)
            phs = f.read(e_phnum * e_phentsize)
            loads = []
            dyn_off = dyn_sz = None
            for i in range(e_phnum):
                po = i * e_phentsize
                p_type = struct.unpack_from(end + "I", phs, po + 0)[0]
                if is64:
                    p_flags = struct.unpack_from(end + "I", phs, po + 4)[0]
                    p_offset = struct.unpack_from(end + "Q", phs, po + 8)[0]
                    p_vaddr = struct.unpack_from(end + "Q", phs, po + 16)[0]
                    p_filesz = struct.unpack_from(end + "Q", phs, po + 32)[0]
                else:
                    p_flags = struct.unpack_from(end + "I", phs, po + 4)[0]
                    p_offset = struct.unpack_from(end + "I", phs, po + 8)[0]
                    p_vaddr = struct.unpack_from(end + "I", phs, po + 16)[0]
                    p_filesz = struct.unpack_from(end + "I", phs, po + 28)[0]
                if p_type == PT_LOAD and p_flags & 4:
                    loads.append((p_vaddr, p_offset, p_filesz))
                elif p_type == PT_DYNAMIC:
                    dyn_off, dyn_sz = p_offset, p_filesz
            if dyn_off is None:
                return []
            f.seek(dyn_off)
            dyn = f.read(dyn_sz)
            ent = 16 if is64 else 8
            needed_off, strtab = [], None
            for j in range(0, len(dyn) - ent + 1, ent):
                if is64:
                    tag, val = struct.unpack_from(end + "qQ", dyn, j)
                else:
                    tag, val = struct.unpack_from(end + "iI", dyn, j)
                if tag == 0:
                    break
                if tag == DT_NEEDED:
                    needed_off.append(val)
                elif tag == DT_STRTAB:
                    strtab = val
            if strtab is None:
                return []
            foff = None
            for p_vaddr, p_offset, p_filesz in loads:
                if p_vaddr <= strtab < p_vaddr + p_filesz:
                    foff = p_offset + (strtab - p_vaddr)
                    break
            if foff is None:
                return []
            out = []
            for off in needed_off:
                f.seek(foff + off)
                name = b""
                while True:
                    c = f.read(1)
                    if c in (b"", b"\0"):
                        break
                    name += c
                out.append(name.decode("utf-8", "replace"))
            return out
    except (OSError, struct.error):
        return None


def walk_needed(base):
    """All NEEDED sonames of every ELF under base."""
    needed = set()
    for dirpath, dirnames, filenames in os.walk(base):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            if os.path.islink(full):
                continue
            with open(full, "rb") as f:
                if f.read(4) != b"\x7fELF":
                    continue
            res = elf_needed(full)
            if res:
                needed.update(res)
    return needed


def main():
    rootfs = sys.argv[1]
    store = os.path.join(rootfs, "nix", "store")

    # The top-level entries link at /nix/store/..., which only exists inside
    # the tree: the host cannot stat through them, so the target string is
    # parsed instead of the link followed.
    def store_first_component(name):
        target = os.readlink(os.path.join(rootfs, name))
        if not target.startswith("/nix/store/"):
            raise SystemExit(f"[!] {name} does not link into the store: {target}")
        return target[len("/nix/store/"):].split("/")[0]

    farm = store_first_component("bin")
    system = store_first_component("nix/var/nix/profiles/default")
    paths = sorted(os.listdir(store))
    keep = {p for p in (system, farm) if p in paths}
    for needle in KEEP_PATHS:
        keep.update(p for p in paths if needle in p)

    # Extra keeps, passed by the caller for things only a config file
    # references: the registry's nixpkgs source, for instance, which the
    # link walk cannot see. Colons are not in store path names.
    if len(sys.argv) > 2:
        for extra in sys.argv[2].split(":"):
            extra = extra.strip()
            if extra:
                if extra not in paths:
                    print(f"[nix-prune] extra keep {extra} is not in the store; skipping")
                keep.add(extra)

    # Seed from the farm's own links: a tool's first hop is the store path
    # that carries it.
    # Second pass over everything outside the store: follow each link's
    # chain to its end and keep every store path it names. This is what
    # catches second-hop links the tool closure cannot see: /etc/pam.d/sudo
    # lands on a dedicated .pam content path, and PAM dlopens what that
    # config names at run time, which no NEEDED entry ever mentions.
    for dirpath, dirnames, filenames in os.walk(rootfs):
        rel = os.path.relpath(dirpath, rootfs)
        if rel == "nix":
            # The store is handled by the keep-set and the farm pruning;
            # walking it would be thousands of in-tree links for nothing.
            dirnames[:] = []
            continue
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            if not os.path.islink(full):
                continue
            cur = os.readlink(full)
            if not cur.startswith("/"):
                cur = os.path.normpath(os.path.join(os.path.dirname(full), cur))
            for _ in range(8):
                if not cur.startswith("/nix/store/"):
                    break
                keep.add(cur[len("/nix/store/"):].split("/")[0])
                in_tree = os.path.join(rootfs, "nix", "store",
                                       cur[len("/nix/store/"):])
                if not os.path.islink(in_tree):
                    break
                nxt = os.readlink(in_tree)
                if not nxt.startswith("/"):
                    nxt = os.path.join(os.path.dirname(cur), nxt)
                cur = nxt
    farmbin = os.path.join(store, farm, "bin")
    missing = []
    for tool in KEEP_TOOLS:
        link = os.path.join(farmbin, tool)
        if os.path.islink(link):
            target = os.readlink(link)
            if target.startswith("/nix/store/"):
                first = target[len("/nix/store/"):].split("/")[0]
                if first in paths:
                    keep.add(first)
                    # The tool's binary may itself be a link into another
                    # store path: per-system nix packages share one real
                    # binary, so the farm package's bin/nix links into the
                    # binary package. Keeping only the farm package ships
                    # a dangling link, and every nix command dies the
                    # first time it is run with No such file or directory.
                    real = os.path.join(store, first, "bin", tool)
                    while os.path.islink(real):
                        rt = os.readlink(real)
                        if not rt.startswith("/nix/store/"):
                            break
                        keep.add(rt.split("/")[3])
                        real = os.path.join(store, rt.split("/")[3], "bin", tool)
                    continue
        missing.append(tool)

    # Soname index over every path's shared-object files: the walk only
    # lists names, so the whole store costs a few seconds, and matching a
    # NEEDED entry against it is a dictionary lookup.
    soname_to_paths = {}
    for p in paths:
        base = os.path.join(store, p)
        for dirpath, dirnames, filenames in os.walk(base):
            for fn in filenames:
                if fn.endswith(".so") or ".so." in fn:
                    soname_to_paths.setdefault(fn, set()).add(p)

    needed_cache = {}
    changed = True
    while changed:
        changed = False
        for p in list(keep):
            if p not in needed_cache:
                needed_cache[p] = walk_needed(os.path.join(store, p))
            for soname in needed_cache[p]:
                for q in soname_to_paths.get(soname, ()):
                    if q not in keep:
                        keep.add(q)
                        changed = True

    # The kept config farms (the system's etc tree and the CA bundle) are
    # directories of links to dedicated content paths: pam.d/sudo lands on
    # a .pam file its own store path. Follow the links inside those kept
    # directories to a fixpoint. Deliberately not a general walk over the
    # kept set: the system path's kernel and initrd links would drag the
    # 800 MB boot artifacts back in, and the farm is the tool closure's
    # job, not this one.
    config_needles = ("-etc", "nss-cacert", "terminfo")
    changed = True
    while changed:
        changed = False
        for p in list(keep):
            if not any(needle in p for needle in config_needles):
                continue
            base = os.path.join(store, p)
            if not os.path.isdir(base) or os.path.islink(base):
                continue
            for dirpath, _, filenames in os.walk(base):
                for name in filenames:
                    full = os.path.join(dirpath, name)
                    if not os.path.islink(full):
                        continue
                    target = os.readlink(full)
                    if target.startswith("/nix/store/"):
                        first = target[len("/nix/store/"):].split("/")[0]
                        if first not in keep:
                            keep.add(first)
                            changed = True
    removed = 0
    for p in paths:
        if p in keep:
            continue
        base = os.path.join(store, p)
        try:
            if os.path.islink(base) or os.path.isfile(base):
                # A store path may be a single file, not a directory.
                os.unlink(base)
            else:
                # Deleting a child needs write on its parent, and the store
                # ships every directory 0555, so make the whole tree's
                # directories owner-writable before removing it.
                for dirpath, dirnames, _ in os.walk(base, topdown=True):
                    for dn in dirnames:
                        try:
                            os.chmod(os.path.join(dirpath, dn), 0o755)
                        except OSError:
                            pass
                os.chmod(base, 0o755)
                shutil.rmtree(base)
            removed += 1
        except OSError as e:
            print(f"[!] could not remove {p}: {e}", file=sys.stderr)

    for d in ("bin", "sbin", "lib", "etc", "share"):
        farmd = os.path.join(store, farm, d)
        if not os.path.isdir(farmd):
            continue
        os.chmod(farmd, 0o755)
        for name in os.listdir(farmd):
            full = os.path.join(farmd, name)
            if not os.path.islink(full):
                continue
            target = os.readlink(full)
            if target.startswith("/nix/store/"):
                first = target[len("/nix/store/"):].split("/")[0]
                if first not in keep:
                    os.unlink(full)

    print(f"[nix-prune] kept {len(keep)} of {len(paths)} store paths "
          f"({removed} removed)")
    print("[nix-prune] tools missing from this image's farm: "
          + (", ".join(missing) if missing else "none"))


if __name__ == "__main__":
    main()
