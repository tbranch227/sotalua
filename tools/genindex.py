#!/usr/bin/env python3
"""Generate docs/api-index.md and docs/api-index.json from the vendored reference.

The reference page is regular enough to parse directly: <h2> opens a category,
<h3> names a function, the <p><code> immediately after it holds the signature,
and the following <ul> carries parameter, return, and note lines.

The JSON output is the machine-readable source of truth for the sandbox
allowlist in tests/mock and for the global-leak check in tools/build.py, so that
those never drift from the published API.

Usage: python3 tools/genindex.py
"""

import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "docs", "vendor")

# Categories whose <h3> entries are prose, not callable functions.
PROSE_CATEGORIES = {"Data shapes", "Frozen quirks", "How to read this reference", "Categories"}

_TAG = re.compile(r"<[^>]+>")
_H = re.compile(r'<h([23])\s+id="[^"]*">(.*?)<a class="headerlink"', re.S)
# The signature is the first <code> of the first <p> after the heading. It is not
# always followed immediately by </p>: some entries append "(or nil)" or a whole
# prose sentence inside the same paragraph.
_SIG = re.compile(r"<p>\s*<code>(.*?)</code>", re.S)
_LI = re.compile(r"<li>(.*?)</li>", re.S)
# <h3>s that name a subsection rather than a symbol ("Per-frame values", "Gotchas").
_SYMBOL = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def plain(markup: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(_TAG.sub("", markup))).strip()


def parse_reference(markup: str):
    """Yield (category, name, signature, bullets) in document order."""
    headings = [(m.start(), m.group(1), plain(m.group(2))) for m in _H.finditer(markup)]
    category = None
    for i, (pos, level, title) in enumerate(headings):
        end = headings[i + 1][0] if i + 1 < len(headings) else len(markup)
        if level == "2":
            category = title
            continue
        if not _SYMBOL.match(title):
            continue
        body = markup[pos:end]
        sig_match = _SIG.search(body)
        signature = plain(sig_match.group(1)) if sig_match else ""
        bullets = [plain(b) for b in _LI.findall(body)]
        yield category, title, signature, bullets, plain(body)


def classify(category, name, signature, bullets, body):
    """Split an entry into its kind plus the fields the index cares about."""
    joined = body
    entry = {
        "name": name,
        "category": category,
        "signature": signature,
        "returns": next((b[len("Returns:") :].strip() for b in bullets if b.startswith("Returns:")), ""),
        "notes": next((b[len("Notes:") :].strip() for b in bullets if b.startswith("Notes:")), ""),
    }

    if category in PROSE_CATEGORIES:
        entry["kind"] = "shape" if category == "Data shapes" else "note"
    elif category == "Callbacks":
        entry["kind"] = "callback"
    elif "(" in signature and signature.startswith(name):
        entry["kind"] = "function"
    else:
        entry["kind"] = "global"

    # The reference marks version gates as "(API v3)", either trailing the
    # signature line or trailing the Returns bullet.
    gate = re.search(r"\(API v(\d+)\)", joined)
    if not gate:
        gate = re.search(r"ShroudLuaApiVersion\s*(?:>=|is at least)\s*(\d+)", joined)
    entry["min_api"] = int(gate.group(1)) if gate else 1
    entry["deprecated"] = bool(re.search(r"obsolete|deprecat|slated for removal", joined, re.I))
    entry["stub"] = bool(re.search(r"\bstub\b|always returns false|never switches", joined, re.I))
    return entry


def enums_from_reference(text: str):
    """Pull enum members out of the "Enums and helper types" block.

    Each line reads "Name - prose: Member, Member, Member." so the members are
    whatever follows the last colon. AudioType is special-cased because its line
    describes the practical subset in parentheses rather than a bare list.
    """
    start = text.find("Enums and helper types")
    if start < 0:
        return {}
    block = text[start : text.find("Examples¶", start)]

    found = {}
    for line in block.splitlines():
        m = re.match(r"^([A-Z][A-Za-z0-9]*)\s+—\s+(.*)$", line.strip())
        if not m:
            continue
        name, rest = m.group(1), m.group(2)
        if name.startswith("LuaVector"):
            continue  # a data shape, not an enum
        if ":" in rest:
            members = rest.rsplit(":", 1)[1]
        else:
            members = rest
        members = re.sub(r"\(.*?\)", " ", members)
        parts = [p.strip(" .") for p in re.split(r"[,;]| and ", members)]
        parts = [p for p in parts if re.match(r"^[A-Z][A-Za-z0-9]*$", p)]
        if parts:
            found[name] = sorted(set(parts))
    return found


def globals_from_reference(text: str):
    """Parse the per-frame value and set-once constant tables.

    These are the only symbols the reference documents as bare table rows rather
    than as their own <h3>, so they need their own pass. Each row is an
    identifier line followed by a type line ("number" / "string" / "boolean").
    """
    out = []
    sections = [
        ("Per-frame values¶", "Set-once constants¶", "per-frame"),
        ("Set-once constants¶", "Character and stats¶", "constant"),
    ]
    for begin, finish, updated in sections:
        start = text.find(begin)
        if start < 0:
            continue
        block = text[start : text.find(finish, start)]
        lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
        for i, line in enumerate(lines[:-1]):
            if _SYMBOL.match(line) and lines[i + 1] in ("number", "string", "boolean"):
                out.append(
                    {
                        "name": line,
                        "category": "Per-frame globals and constants",
                        "kind": "global",
                        "type": lines[i + 1],
                        "signature": "",
                        "returns": lines[i + 2] if i + 2 < len(lines) else "",
                        "notes": "",
                        "updated": updated,
                        "min_api": 1,
                        "deprecated": False,
                        "stub": False,
                    }
                )
    return out


def main() -> int:
    ref_html = os.path.join(VENDOR, "reference.html")
    if not os.path.exists(ref_html):
        print("docs/vendor/reference.html missing - run tools/scrape.py first", file=sys.stderr)
        return 1

    with open(ref_html, encoding="utf-8") as fh:
        markup = fh.read()
    with open(os.path.join(VENDOR, "reference.txt"), encoding="utf-8") as fh:
        text = fh.read()

    entries = [classify(*e) for e in parse_reference(markup) if e[0]]

    # An <h3> with no signature in a non-prose category is a subsection heading
    # ("Examples", "Gotchas"), not a symbol. Warn if a Shroud* name lands here -
    # that would mean the reference changed shape and we are dropping real API.
    kept = []
    for e in entries:
        if e["kind"] in ("function", "global") and not e["signature"]:
            if e["name"].startswith("Shroud"):
                print("WARN dropped %s: no signature parsed" % e["name"], file=sys.stderr)
            continue
        kept.append(e)
    entries = kept + globals_from_reference(text)
    callable_entries = [e for e in entries if e["kind"] in ("function", "callback", "global")]

    api_version = 3
    m = re.search(r"ShroudLuaApiVersion\)? is (\d+)", text)
    if m:
        api_version = int(m.group(1))

    data = {
        "source": "https://catnipgames.net/lua/reference.html",
        "api_version": api_version,
        "enums": enums_from_reference(text),
        "entries": entries,
    }
    with open(os.path.join(ROOT, "docs", "api-index.json"), "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write("\n")

    # Markdown view, grouped in the reference's own category order.
    order, seen = [], set()
    for e in entries:
        if e["category"] not in seen:
            seen.add(e["category"])
            order.append(e["category"])

    lines = [
        "# Shroud Lua API index",
        "",
        "Generated by `tools/genindex.py` from `docs/vendor/reference.html`.",
        "Do not edit by hand - re-run `python3 tools/scrape.py && python3 tools/genindex.py`.",
        "",
        "Current `ShroudLuaApiVersion`: **%d**" % api_version,
        "",
    ]
    for category in order:
        group = [e for e in entries if e["category"] == category]
        lines += ["## %s" % category, ""]
        if category in PROSE_CATEGORIES:
            lines += ["| Entry | Summary |", "| --- | --- |"]
            for e in group:
                lines.append("| `%s` | %s |" % (e["name"], (e["returns"] or e["notes"] or e["signature"]).replace("|", "\\|")))
        else:
            lines += ["| Symbol | Signature | Min API | Flags |", "| --- | --- | --- | --- |"]
            for e in group:
                flags = []
                if e["deprecated"]:
                    flags.append("deprecated")
                if e["stub"]:
                    flags.append("stub")
                lines.append(
                    "| `%s` | `%s` | %d | %s |"
                    % (e["name"], e["signature"].replace("|", "\\|"), e["min_api"], ", ".join(flags))
                )
        lines.append("")

    with open(os.path.join(ROOT, "docs", "api-index.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    kinds = {}
    for e in entries:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    print("api-index: %d entries (%s) across %d categories" % (
        len(entries),
        ", ".join("%s=%d" % kv for kv in sorted(kinds.items())),
        len(order),
    ))
    print("callable surface: %d symbols" % len(callable_entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
