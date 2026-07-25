#!/usr/bin/env python3
"""Compare a client's real API surface against the documented one.

`/lua _ApiProbe_export` writes api-export.txt into the game's Lua folder. This
diffs it against docs/api-index.json to answer two questions the published
reference cannot:

  * what does this client have that the docs do not describe (new API), and
  * what do the docs describe that this client does not have (removed, or
    documentation ahead of the build).

Usage:
  python3 tools/diffapi.py                        # find the export automatically
  python3 tools/diffapi.py path/to/api-export.txt
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, "docs", "api-index.json")
CONFIG = os.path.join(ROOT, ".sotalua.local")


def find_export(explicit):
    if explicit:
        return explicit
    candidates = []
    if os.path.exists(CONFIG):
        with open(CONFIG, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("lua_dir="):
                    candidates.append(line.split("=", 1)[1].strip())
    # Both clients, since the export could have come from either.
    base = "/mnt/c/Users/tbran/AppData/Roaming/Portalarium"
    candidates += [
        os.path.join(base, "Shroud of the Avatar(DEV)", "Lua"),
        os.path.join(base, "Shroud of the Avatar", "Lua"),
    ]
    for directory in candidates:
        path = os.path.join(directory, "api-export.txt")
        if os.path.exists(path):
            return path
    return None


def parse_export(path):
    version, globals_, enums = None, {}, {}
    section = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith("# ShroudLuaApiVersion="):
                version = line.split("=", 1)[1].strip()
                continue
            if line.startswith("## "):
                section = line[3:].strip()
                continue
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if section == "globals" and len(parts) >= 2:
                globals_[parts[0]] = parts[1]
            elif section == "enums" and len(parts) >= 2:
                enums[parts[0]] = [m for m in parts[1].split(",") if m]
    return version, globals_, enums


def main(argv):
    path = find_export(argv[1] if len(argv) > 1 else None)
    if not path:
        print(
            "No api-export.txt found.\n"
            "In game, with API Probe enabled, run:  /lua _ApiProbe_export",
            file=sys.stderr,
        )
        return 1

    print("export: %s" % path)
    version, client, client_enums = parse_export(path)

    with open(INDEX, encoding="utf-8") as fh:
        data = json.load(fh)

    documented = {
        e["name"] for e in data["entries"]
        if e["kind"] in ("function", "global", "callback")
    }
    documented |= {"ConsoleLog", "GetStatCount", "GetStatValueByNumber",
                   "GetStatNameByNumber", "GetStatValueByName"}

    print("client API version: %s   documented: %s" % (version, data["api_version"]))
    print("client host globals: %d   documented symbols: %d" % (len(client), len(documented)))

    # Standard Lua names the host overrides. The exporter only captures
    # Shroud-prefixed symbols, so these would otherwise read as "missing" when
    # they are simply out of the export's scope.
    not_exported = {"print", "collectgarbage"}

    # Callbacks are defined by the addon, so they appear in _G because our own
    # bundles put them there. They are not evidence of client API.
    new = sorted(n for n in client if n not in documented and not n.startswith("ShroudOn"))
    missing = sorted(
        n for n in documented
        if n not in client and not n.startswith("ShroudOn") and n not in not_exported
    )

    print("\n=== UNDOCUMENTED: present in this client, absent from the docs (%d) ===" % len(new))
    for name in new:
        print("  %-45s %s" % (name, client[name]))
    if not new:
        print("  (none)")

    print("\n=== MISSING: documented but absent from this client (%d) ===" % len(missing))
    for name in missing:
        print("  %s" % name)
    if not missing:
        print("  (none)")

    print("\n=== ENUMS ===")
    for enum, members in sorted(client_enums.items()):
        known = set(data.get("enums", {}).get(enum, []))
        extra = sorted(set(members) - known)
        absent = sorted(known - set(members))
        note = ""
        if extra:
            note += "  NEW: %s" % ", ".join(extra)
        if absent:
            note += "  MISSING: %s" % ", ".join(absent)
        print("  %-14s %d members%s" % (enum, len(members), note))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
