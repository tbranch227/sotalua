#!/usr/bin/env python3
"""Bundle a plugin and its core dependencies into one distributable .lua file.

Why a bundler at all: the host has no require(). Every enabled addon shares one
MoonSharp environment, and the store's "Submit to Community" flow packages a
single .lua file. So code reuse has to happen at build time, and the shared
library has to end up file-local so it cannot collide with another author's
addon in the shared environment.

Output per plugin:
  dist/<slug>/<Name>.lua   the flat addon, ready to drop into the game's Lua/
  dist/<slug>/manifest.json  package metadata, for the store path
  dist/<slug>/icon.png       copied when the plugin ships one

Layout of the generated file, in this order:
  1. the five metadata locals the addon manager parses from the top of the file
  2. each core module, wrapped as a file-local so nothing reaches _G
  3. the plugin body
  4. the ShroudOn* globals, assigned last

Usage:
  python3 tools/build.py              # every plugin
  python3 tools/build.py target-frame # one plugin
"""

import hashlib
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, "core")
PLUGINS = os.path.join(ROOT, "plugins")
DIST = os.path.join(ROOT, "dist")

SLUG_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
VERSION_RE = re.compile(r"^(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})$")

MANIFEST_VERSION = 1
MAX_FILES = 16


class BuildError(Exception):
    pass


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def core_modules():
    """The load order, parsed out of core/modules.lua so it has one home."""
    text = read(os.path.join(CORE, "modules.lua"))
    return re.findall(r'^\s*"([a-z]+)"', text, re.M)


def lua_string(value):
    """Quote a Lua string literal safely."""
    escaped = (
        str(value)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )
    return '"%s"' % escaped


def validate(meta, slug):
    """Reject anything the store or the loader would reject, at build time."""
    problems = []

    if meta.get("slug") != slug:
        problems.append("slug %r does not match its directory %r" % (meta.get("slug"), slug))
    if not SLUG_RE.match(slug or ""):
        problems.append("slug %r must match ^[a-z][a-z0-9]*(-[a-z0-9]+)*$" % slug)
    if not 3 <= len(slug or "") <= 40:
        problems.append("slug must be 3-40 characters, got %d" % len(slug or ""))

    name = meta.get("name", "")
    if not 3 <= len(name) <= 60:
        problems.append("name must be 3-60 characters, got %d" % len(name))

    version = meta.get("version", "")
    if not VERSION_RE.match(version):
        problems.append(
            "version %r must be N.N.N with each part 0-9999 and no leading zeros" % version
        )

    if meta.get("permissions", []):
        problems.append("permissions must be empty; the field is reserved")

    min_api = meta.get("minApiVersion", 1)
    if not isinstance(min_api, int) or min_api < 1:
        problems.append("minApiVersion must be a positive integer")

    unknown = set(meta.get("modules", [])) - set(core_modules())
    if unknown:
        problems.append("unknown core modules: %s" % ", ".join(sorted(unknown)))

    if problems:
        raise BuildError("plugins/%s/plugin.json:\n  - %s" % (slug, "\n  - ".join(problems)))


def resolve_modules(requested):
    """Always emit the full core in declaration order.

    Tree-shaking by declaration was tempting, but the modules reference each
    other through the shared table at call time, so a plugin that pulls in
    layout transitively needs ui, settings, timers and events anyway. The whole
    core is roughly 40 KB of source; correctness is worth more than the bytes.
    """
    return core_modules()


def wrap_module(name, source):
    """Instantiate one core module as a file-local.

    Each module file is `return function(M) ... end`, so the wrapped form
    evaluates the file to get the factory and immediately applies it to the
    shared table. Identical to how tests/helper.lua builds the same graph.
    """
    return (
        "-- [core/%s.lua] ---------------------------------------------------\n"
        "__core.%s = (function()\n%s\nend)()(__core)\n" % (name, name, source.rstrip())
    )


def build_plugin(slug, verbose=True):
    plugin_dir = os.path.join(PLUGINS, slug)
    meta_path = os.path.join(plugin_dir, "plugin.json")
    if not os.path.exists(meta_path):
        raise BuildError("plugins/%s/plugin.json not found" % slug)

    meta = json.loads(read(meta_path))
    validate(meta, slug)

    entry = os.path.join(plugin_dir, "src", "main.lua")
    if not os.path.exists(entry):
        raise BuildError("plugins/%s/src/main.lua not found" % slug)

    icon = meta.get("icon", "icon.png")
    has_icon = os.path.exists(os.path.join(plugin_dir, icon))

    parts = []

    # 1. The metadata locals, first thing in the file. The addon manager parses
    #    these from the beginning of the source, so nothing may precede them.
    parts.append("local ScriptName = %s" % lua_string(meta["name"]))
    parts.append("local Version = %s" % lua_string(meta["version"]))
    parts.append("local CreatorName = %s" % lua_string(meta.get("author", "")))
    parts.append("local Description = %s" % lua_string(meta.get("description", "")))
    if has_icon:
        # IconPath is resolved relative to the Lua folder, not the addon folder.
        parts.append("local IconPath = %s" % lua_string("%s/%s" % (slug, icon)))
    parts.append("")

    parts.append("-- %s v%s" % (meta["name"], meta["version"]))
    parts.append("--")
    parts.append("-- Generated by tools/build.py. Do not edit this file; edit")
    parts.append("-- plugins/%s/src/main.lua and rebuild." % slug)
    parts.append("--")
    parts.append("-- Everything below is file-local. Addons share one Lua environment,")
    parts.append("-- so the only globals this file creates are the ShroudOn* callbacks")
    parts.append("-- at the end and any slug-prefixed timer or command entry points.")
    parts.append("")

    # 2. Core, as file-locals.
    parts.append("local __core = {}")
    for name in resolve_modules(meta.get("modules")):
        parts.append(wrap_module(name, read(os.path.join(CORE, "%s.lua" % name))))
    # A content hash of everything that went into this bundle. Printed by
    # env.describe(), so "is the client running the build I just installed?" is
    # answerable from chat instead of inferred from whether a reload happened.
    digest = hashlib.sha256()
    for name in resolve_modules(meta.get("modules")):
        digest.update(read(os.path.join(CORE, "%s.lua" % name)).encode("utf-8"))
    digest.update(read(entry).encode("utf-8"))
    build_id = digest.hexdigest()[:8]

    parts.append("__core.buildId = %s" % lua_string(build_id))
    parts.append("local Core = __core")
    parts.append("")

    # 3. The plugin body, same factory shape as a core module.
    parts.append("-- [plugins/%s/src/main.lua] --------------------------------" % slug)
    parts.append("local __plugin = (function()\n%s\nend)()(Core)" % read(entry).rstrip())
    parts.append("")

    # 4. The callback globals. core/events.lua only returns names that actually
    #    have a subscriber, so an unused ShroudOnGUI is never installed.
    parts.append("-- Publish the callbacks the host looks up by name.")
    parts.append("for __name, __fn in pairs(Core.addon.handlers()) do")
    parts.append("    _G[__name] = __fn")
    parts.append("end")
    parts.append("")
    parts.append("return __plugin")

    output = "\n".join(parts) + "\n"

    out_dir = os.path.join(DIST, slug)
    os.makedirs(out_dir, exist_ok=True)

    lua_name = "%s.lua" % "".join(w.capitalize() for w in slug.split("-"))
    lua_path = os.path.join(out_dir, lua_name)
    with open(lua_path, "w", encoding="utf-8") as fh:
        fh.write(output)

    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "slug": slug,
        "name": meta["name"],
        "version": meta["version"],
        "description": meta.get("description", ""),
        "author": meta.get("author", ""),
        "files": [lua_name],
        "min_api_version": meta.get("minApiVersion", 1),
        "permissions": [],
    }
    if has_icon:
        manifest["icon"] = icon
        shutil.copy2(os.path.join(plugin_dir, icon), os.path.join(out_dir, icon))
    readme = os.path.join(plugin_dir, "README.md")
    if os.path.exists(readme):
        manifest["readme"] = "README.md"
        shutil.copy2(readme, os.path.join(out_dir, "README.md"))

    if len(manifest["files"]) > MAX_FILES:
        raise BuildError("a package may hold at most %d .lua files" % MAX_FILES)

    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")

    if verbose:
        print("built %-18s %6.1f KB  ->  dist/%s/%s" % (slug, len(output) / 1024, slug, lua_name))
    return lua_path


def discover():
    if not os.path.isdir(PLUGINS):
        return []
    return sorted(
        name
        for name in os.listdir(PLUGINS)
        if os.path.exists(os.path.join(PLUGINS, name, "plugin.json"))
    )


def main(argv):
    slugs = argv[1:] or discover()
    if not slugs:
        print("no plugins found under plugins/", file=sys.stderr)
        return 1

    failed = 0
    for slug in slugs:
        try:
            build_plugin(slug)
        except BuildError as exc:
            print("FAIL %s" % exc, file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
