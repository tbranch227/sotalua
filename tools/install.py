#!/usr/bin/env python3
"""Copy built addons into the game's Lua folder.

The documentation deliberately publishes no OS-specific path for that folder,
telling you to discover it at runtime instead: type `/lua path` in chat, or use
the addon manager's "Open Folder" button. So the path is asked for once and
remembered in .sotalua.local, which is gitignored.

A few likely locations are probed first as a convenience. If none match, pass
--path with whatever `/lua path` opened.

Usage:
  python3 tools/install.py                      # install every built addon
  python3 tools/install.py target-frame         # install one
  python3 tools/install.py --path "/mnt/c/..."  # set and remember the folder
  python3 tools/install.py --flat               # loose .lua files, no subfolder
"""

import argparse
import glob
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
CONFIG = os.path.join(ROOT, ".sotalua.local")

# Candidate roots, checked for a Lua/ child. Covers a native Windows run and a
# WSL shell reaching the Windows filesystem through /mnt/c.
CANDIDATE_PATTERNS = [
    "/mnt/c/Users/*/Documents/Shroud of the Avatar",
    "/mnt/c/Users/*/AppData/Roaming/Portalarium/Shroud of the Avatar",
    "/mnt/c/Users/*/AppData/LocalLow/Portalarium/Shroud of the Avatar",
    os.path.expanduser("~/Documents/Shroud of the Avatar"),
    os.path.expanduser("~/.config/unity3d/Portalarium/Shroud of the Avatar"),
]


def load_config():
    if not os.path.exists(CONFIG):
        return {}
    out = {}
    with open(CONFIG, encoding="utf-8") as fh:
        for line in fh:
            if "=" in line and not line.strip().startswith("#"):
                key, value = line.split("=", 1)
                out[key.strip()] = value.strip()
    return out


def save_config(config):
    with open(CONFIG, "w", encoding="utf-8") as fh:
        fh.write("# Local machine settings for tools/install.py. Not committed.\n")
        for key, value in sorted(config.items()):
            fh.write("%s=%s\n" % (key, value))


def probe():
    """Look for a Lua/ folder under a known-plausible game data root."""
    for pattern in CANDIDATE_PATTERNS:
        for base in sorted(glob.glob(pattern)):
            candidate = os.path.join(base, "Lua")
            if os.path.isdir(candidate):
                return candidate
    return None


def resolve_lua_dir(explicit):
    config = load_config()

    if explicit:
        path = os.path.abspath(os.path.expanduser(explicit))
        if not os.path.isdir(path):
            raise SystemExit("not a directory: %s" % path)
        # Accept either the Lua folder itself or its parent.
        if os.path.basename(path).lower() != "lua" and os.path.isdir(os.path.join(path, "Lua")):
            path = os.path.join(path, "Lua")
        config["lua_dir"] = path
        save_config(config)
        print("remembered lua_dir=%s" % path)
        return path

    if config.get("lua_dir") and os.path.isdir(config["lua_dir"]):
        return config["lua_dir"]

    found = probe()
    if found:
        config["lua_dir"] = found
        save_config(config)
        print("found and remembered lua_dir=%s" % found)
        return found

    raise SystemExit(
        "Could not find the game's Lua folder.\n"
        "In game, type  /lua path  (or use the addon manager's Open Folder button),\n"
        "then re-run:  python3 tools/install.py --path '<that folder>'"
    )


def built_slugs():
    if not os.path.isdir(DIST):
        return []
    return sorted(
        name for name in os.listdir(DIST)
        if glob.glob(os.path.join(DIST, name, "*.lua"))
    )


def install(slug, lua_dir, flat):
    src_dir = os.path.join(DIST, slug)
    lua_files = glob.glob(os.path.join(src_dir, "*.lua"))
    if not lua_files:
        print("skip %s: nothing built; run ./run.sh build" % slug, file=sys.stderr)
        return False

    if flat:
        # Loose addons live directly in Lua/ and carry their metadata in the
        # five locals at the top of the file. This is the path the in-game
        # "Submit to Community" flow packages from.
        for path in lua_files:
            shutil.copy2(path, os.path.join(lua_dir, os.path.basename(path)))
        icon = os.path.join(src_dir, "icon.png")
        if os.path.exists(icon):
            # IconPath is resolved relative to Lua/, and the bundler wrote it as
            # "<slug>/icon.png", so the icon still goes in the subfolder.
            target = os.path.join(lua_dir, slug)
            os.makedirs(target, exist_ok=True)
            shutil.copy2(icon, os.path.join(target, "icon.png"))
        print("installed %-18s -> %s/" % (slug, lua_dir))
        return True

    target = os.path.join(lua_dir, slug)
    os.makedirs(target, exist_ok=True)
    for path in glob.glob(os.path.join(src_dir, "*")):
        shutil.copy2(path, os.path.join(target, os.path.basename(path)))
    print("installed %-18s -> %s/" % (slug, target))
    return True


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slugs", nargs="*", help="plugins to install; default is all built ones")
    parser.add_argument("--path", help="the game's Lua folder; remembered for next time")
    parser.add_argument("--flat", action="store_true",
                        help="install as loose .lua files rather than package folders")
    args = parser.parse_args(argv[1:])

    lua_dir = resolve_lua_dir(args.path)
    slugs = args.slugs or built_slugs()
    if not slugs:
        print("nothing built under dist/; run ./run.sh build first", file=sys.stderr)
        return 1

    installed = sum(1 for slug in slugs if install(slug, lua_dir, args.flat))
    if installed:
        print(
            "\n%d addon(s) installed. In game:\n"
            "  1. /lua reload\n"
            "  2. open the addon manager and enable them "
            "(new addons always load disabled)" % installed
        )
    return 0 if installed == len(slugs) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
