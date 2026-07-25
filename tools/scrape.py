#!/usr/bin/env python3
"""Vendor the Shroud of the Avatar Lua addon documentation into docs/vendor/.

The reference page is ~160 KB of HTML. Summarizing fetchers truncate it around
the halfway mark and then invent functions that do not exist, so this tool does a
plain HTTP GET and keeps both the raw HTML and a tag-stripped .txt beside it.
Grep the .txt; treat the .html as the archival copy.

Usage: python3 tools/scrape.py [--offline]
"""

import argparse
import html
import os
import re
import sys
import urllib.request

BASE = "https://catnipgames.net/lua/"
PAGES = ["index", "guide", "reference", "internals", "agent"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "docs", "vendor")

_DROP_BLOCK = re.compile(r"<(script|style)\b.*?</\1>", re.S | re.I)
_BREAK = re.compile(r"</(p|div|li|tr|h[1-6]|pre|section|table|thead|tbody)>", re.I)
_TAG = re.compile(r"<[^>]+>")
_BLANKS = re.compile(r"\n{3,}")


def strip_tags(markup: str) -> str:
    text = _DROP_BLOCK.sub("", markup)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = _BREAK.sub("\n", text)
    text = _TAG.sub("", text)
    text = html.unescape(text)
    text = "\n".join(line.rstrip() for line in text.splitlines())
    return _BLANKS.sub("\n\n", text).strip() + "\n"


def fetch(page: str) -> str:
    url = BASE + page + ".html"
    req = urllib.request.Request(url, headers={"User-Agent": "sotalua-docs-scraper/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", errors="replace")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--offline",
        action="store_true",
        help="re-derive the .txt files from already-vendored .html without refetching",
    )
    args = ap.parse_args()

    os.makedirs(VENDOR, exist_ok=True)
    for page in PAGES:
        html_path = os.path.join(VENDOR, page + ".html")
        txt_path = os.path.join(VENDOR, page + ".txt")

        if args.offline:
            if not os.path.exists(html_path):
                print("skip %-11s (not vendored yet)" % page)
                continue
            with open(html_path, encoding="utf-8") as fh:
                markup = fh.read()
        else:
            try:
                markup = fetch(page)
            except Exception as exc:  # noqa: BLE001 - report and keep going
                print("FAIL %-11s %s" % (page, exc), file=sys.stderr)
                continue
            with open(html_path, "w", encoding="utf-8") as fh:
                fh.write(markup)

        text = strip_tags(markup)
        with open(txt_path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("ok   %-11s %7d bytes html  %7d bytes text" % (page, len(markup), len(text)))

    return 0


if __name__ == "__main__":
    sys.exit(main())
