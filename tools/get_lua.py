#!/usr/bin/env python3
"""Fetch a Lua 5.4 interpreter into .tooling/ without sudo or a compiler.

This repo's only external dependency is a `lua` binary: the bundler, the mock
host, and the test runner are all plain Lua with no luarocks packages. If the
system already has one, use it. This script exists for machines that do not, and
where `sudo apt install lua5.4` is not an option.

It downloads the distro .deb packages and unpacks them in-process. A .deb is an
`ar` archive holding data.tar.{xz,gz,zst}; Python reads xz and gz natively but
has no zstd before 3.14, so Debian (which still ships xz) is preferred over
Ubuntu (which has moved to zstd). The interpreter needs liblua5.4-0 alongside
it, so both packages are fetched and a wrapper sets LD_LIBRARY_PATH.

Usage: python3 tools/get_lua.py  ->  .tooling/bin/lua
"""

import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, ".tooling")
PAYLOAD = os.path.join(DEST, "payload")

# Debian first: its data.tar is xz, which Python can read unaided.
MIRRORS = [
    "http://deb.debian.org/debian/pool/main/l/lua5.4/",
    "http://ftp.debian.org/debian/pool/main/l/lua5.4/",
    "http://archive.ubuntu.com/ubuntu/pool/universe/l/lua5.4/",
]
WANTED = ["lua5.4", "liblua5.4-0"]


def fetch(url: str, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "sotalua-tooling/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def read_ar(blob: bytes):
    """Yield (name, payload) for each member of an ar archive."""
    if not blob.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive")
    pos = 8
    while pos + 60 <= len(blob):
        header = blob[pos : pos + 60]
        name = header[0:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        start = pos + 60
        yield name, blob[start : start + size]
        pos = start + size + (size & 1)


def decompress(name: str, payload: bytes) -> bytes:
    if name.endswith(".zst"):
        unzstd = shutil.which("unzstd") or shutil.which("zstd")
        if not unzstd:
            raise RuntimeError("data.tar.zst needs an unzstd binary; none found")
        return subprocess.run(
            [unzstd, "-dc"], input=payload, stdout=subprocess.PIPE, check=True
        ).stdout
    return payload  # tarfile handles xz/gz/bz2 transparently


def newest(names, package: str):
    """Pick the highest-versioned amd64 .deb for a package from a mirror index."""
    pattern = re.compile(r"^%s_([^_]+)_(amd64|all)\.deb$" % re.escape(package))
    matches = [(n, pattern.match(n)) for n in names]
    matches = [(n, m.group(1)) for n, m in matches if m]
    if not matches:
        return None

    def key(item):
        return [int(p) if p.isdigit() else p for p in re.split(r"[.\-+~]", item[1])]

    try:
        return max(matches, key=key)[0]
    except TypeError:  # mixed int/str version segments; fall back to string sort
        return max(matches, key=lambda i: i[1])[0]


def unpack(package: str) -> bool:
    for mirror in MIRRORS:
        try:
            index = fetch(mirror, timeout=30).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - try the next mirror
            continue
        names = set(re.findall(r'href="([^"]+\.deb)"', index))
        chosen = newest(names, package)
        if not chosen:
            continue
        try:
            blob = fetch(mirror + chosen)
        except Exception as exc:  # noqa: BLE001
            print("  %s: %s" % (chosen, exc), file=sys.stderr)
            continue

        for name, member in read_ar(blob):
            if not name.startswith("data.tar"):
                continue
            try:
                data = decompress(name, member)
            except RuntimeError as exc:
                print("  %s: %s" % (chosen, exc), file=sys.stderr)
                break
            with tarfile.open(fileobj=io.BytesIO(data)) as tar:
                tar.extractall(PAYLOAD, filter="data")
            print("  unpacked %s" % chosen)
            return True
    return False


def find(predicate):
    for root, _dirs, files in os.walk(PAYLOAD):
        for fname in files:
            if predicate(fname):
                yield os.path.join(root, fname)


def main() -> int:
    local = os.path.join(DEST, "bin", "lua")
    if os.path.exists(local):
        print("already installed: %s" % local)
        return 0
    existing = shutil.which("lua") or shutil.which("lua5.4")
    if existing:
        print("system lua already available: %s" % existing)
        return 0

    os.makedirs(PAYLOAD, exist_ok=True)
    for package in WANTED:
        print("fetching %s" % package)
        if not unpack(package):
            print(
                "could not fetch %s.\nInstall Lua instead:  sudo apt install -y lua5.4"
                % package,
                file=sys.stderr,
            )
            return 1

    interpreters = sorted(find(lambda f: f in ("lua5.4", "lua")))
    if not interpreters:
        print("no lua interpreter inside the packages", file=sys.stderr)
        return 1

    bindir = os.path.join(DEST, "bin")
    libdir = os.path.join(DEST, "lib")
    os.makedirs(bindir, exist_ok=True)
    os.makedirs(libdir, exist_ok=True)

    real = os.path.join(bindir, "lua.bin")
    shutil.copy2(interpreters[0], real)
    os.chmod(real, 0o755)
    for lib in find(lambda f: f.startswith("liblua5.4.so")):
        shutil.copy2(lib, os.path.join(libdir, os.path.basename(lib)))

    # The interpreter links against liblua5.4.so.0, which is not on the default
    # search path here, so go through a wrapper rather than requiring callers to
    # export LD_LIBRARY_PATH themselves.
    wrapper = os.path.join(bindir, "lua")
    with open(wrapper, "w", encoding="utf-8") as fh:
        fh.write(
            '#!/bin/sh\n'
            'here=$(cd "$(dirname "$0")" && pwd)\n'
            'LD_LIBRARY_PATH="$here/../lib:$LD_LIBRARY_PATH" exec "$here/lua.bin" "$@"\n'
        )
    os.chmod(wrapper, os.stat(wrapper).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    out = subprocess.run([wrapper, "-v"], capture_output=True, text=True)
    banner = (out.stdout or out.stderr).strip()
    if out.returncode != 0:
        print("installed but not runnable:\n%s" % banner, file=sys.stderr)
        return 1
    print("installed %s\n%s" % (wrapper, banner))
    return 0


if __name__ == "__main__":
    sys.exit(main())
