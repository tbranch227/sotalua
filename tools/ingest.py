#!/usr/bin/env python3
"""Load the addons' event logs into SQLite, and query them.

This is the half of cross-session tracking that cannot live in Lua. The game's
sandbox permits no network access and MoonSharp cannot load a native library, so
there is no SQLite driver and no HTTP client inside an addon. What an addon
*can* do is append to a file under the Lua folder; this reads those files.

sqlite3 is in the Python standard library, so this needs nothing installed.

  python3 tools/ingest.py                 # ingest, then print a summary
  python3 tools/ingest.py --db my.db      # choose the database
  python3 tools/ingest.py --sql "SELECT ..."   # run a query
  python3 tools/ingest.py --export events.json # dump for an external API

Ingestion is idempotent: every record is keyed by a content hash, so re-running
after a partial session adds only what is new.
"""

import argparse
import glob
import hashlib
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, ".sotalua.local")
DEFAULT_DB = os.path.join(ROOT, "data", "sotalua.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id          TEXT PRIMARY KEY,     -- content hash, makes ingest idempotent
    type        TEXT NOT NULL,
    character   TEXT,
    server_time TEXT,                 -- ShroudServerTime, wall clock
    engine_time REAL,                 -- ShroudTime, seconds since client start
    payload     TEXT NOT NULL,        -- the full record as JSON
    source      TEXT                  -- file it came from
);
CREATE INDEX IF NOT EXISTS events_type ON events(type);
CREATE INDEX IF NOT EXISTS events_character ON events(character);

CREATE VIEW IF NOT EXISTS sessions AS
SELECT character,
       server_time,
       json_extract(payload, '$.seconds')    AS seconds,
       json_extract(payload, '$.adventurer') AS adventurer,
       json_extract(payload, '$.producer')   AS producer,
       json_extract(payload, '$.gold')       AS gold
FROM events WHERE type = 'session';

CREATE VIEW IF NOT EXISTS items AS
SELECT character,
       server_time,
       json_extract(payload, '$.item')  AS item,
       json_extract(payload, '$.delta') AS delta,
       json_extract(payload, '$.value') AS value,
       json_extract(payload, '$.scene') AS scene
FROM events WHERE type = 'item';
"""


def lua_dir():
    if os.path.exists(CONFIG):
        with open(CONFIG, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("lua_dir="):
                    return line.split("=", 1)[1].strip()
    return None


def find_logs(explicit_dir):
    """Every log file in the folder.

    Names look like sotalua-<stream>-<character>.jsonl, plus a .1 rotated
    generation. One install serves any number of characters, so a folder
    normally holds several files per stream.
    """
    directory = explicit_dir or lua_dir()
    if not directory or not os.path.isdir(directory):
        return []
    return sorted(
        glob.glob(os.path.join(directory, "sotalua-*.jsonl"))
        + glob.glob(os.path.join(directory, "sotalua-*.1.jsonl"))
    )


def ingest(conn, paths):
    added, skipped, malformed = 0, 0, 0
    for path in paths:
        source = os.path.basename(path)
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    # A torn final line from a session that ended mid-write.
                    # JSON Lines is chosen precisely so this costs one record.
                    malformed += 1
                    continue

                key = hashlib.sha256(line.encode("utf-8")).hexdigest()[:32]
                try:
                    conn.execute(
                        "INSERT INTO events (id, type, character, server_time,"
                        " engine_time, payload, source) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (
                            key,
                            record.get("type", "unknown"),
                            record.get("char"),
                            record.get("at"),
                            record.get("t"),
                            line,
                            source,
                        ),
                    )
                    added += 1
                except sqlite3.IntegrityError:
                    skipped += 1   # already ingested
    conn.commit()
    return added, skipped, malformed


def summarize(conn):
    def scalar(sql, default=0):
        row = conn.execute(sql).fetchone()
        return (row[0] if row and row[0] is not None else default)

    total = scalar("SELECT COUNT(*) FROM events")
    print("\n%d event(s) stored" % total)
    if total == 0:
        print("Nothing ingested yet. Play with Session Log and Loot Tracker enabled,")
        print("then run this again. Data is flushed on a timer and at logout.")
        return

    print("\nby type:")
    for kind, count in conn.execute(
        "SELECT type, COUNT(*) FROM events GROUP BY type ORDER BY COUNT(*) DESC"
    ):
        print("  %-12s %d" % (kind, count))

    sessions = scalar("SELECT COUNT(*) FROM sessions")
    if sessions:
        hours = scalar("SELECT SUM(seconds) FROM sessions") / 3600.0
        print("\n%d session(s), %.1f hours played" % (sessions, hours))
        print("  adventurer xp: %s" % f"{scalar('SELECT SUM(adventurer) FROM sessions'):,}")
        print("  producer xp:   %s" % f"{scalar('SELECT SUM(producer) FROM sessions'):,}")
        print("  net gold:      %s" % f"{scalar('SELECT SUM(gold) FROM sessions'):,}")

        print("\n  per character:")
        for row in conn.execute(
            "SELECT character, COUNT(*), SUM(seconds)/3600.0, SUM(adventurer)"
            " FROM sessions GROUP BY character ORDER BY SUM(seconds) DESC"
        ):
            print("    %-20s %3d sessions  %6.1f h  %12s xp"
                  % (row[0] or "?", row[1], row[2] or 0, f"{row[3] or 0:,}"))

    if scalar("SELECT COUNT(*) FROM items"):
        print("\ntop items gained:")
        for name, qty, value in conn.execute(
            "SELECT item, SUM(delta), SUM(delta * value) FROM items"
            " WHERE delta > 0 GROUP BY item ORDER BY SUM(delta) DESC LIMIT 10"
        ):
            print("    %6d x %-32s ~%s gold" % (qty, name[:32], f"{int(value or 0):,}"))

        print("\nmost productive scenes:")
        for scene, value in conn.execute(
            "SELECT scene, SUM(delta * value) FROM items WHERE delta > 0 AND scene != ''"
            " GROUP BY scene ORDER BY SUM(delta * value) DESC LIMIT 5"
        ):
            print("    %-32s ~%s gold" % (scene[:32], f"{int(value or 0):,}"))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--db", default=DEFAULT_DB, help="SQLite file to write")
    parser.add_argument("--dir", help="the game's Lua folder; defaults to .sotalua.local")
    parser.add_argument("--sql", help="run a query against the database and print rows")
    parser.add_argument("--export", help="write every event to a JSON file, for an external API")
    parser.add_argument("--no-ingest", action="store_true", help="query only")
    args = parser.parse_args(argv[1:])

    os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
    conn = sqlite3.connect(args.db)
    conn.executescript(SCHEMA)

    if not args.no_ingest:
        paths = find_logs(args.dir)
        if not paths:
            print("No sotalua-*.jsonl files found.", file=sys.stderr)
            print("Set the folder with: python3 tools/install.py --path '<Lua folder>'",
                  file=sys.stderr)
        else:
            added, skipped, malformed = ingest(conn, paths)
            print("read %d file(s): %d new, %d already stored%s"
                  % (len(paths), added, skipped,
                     ", %d malformed" % malformed if malformed else ""))

    if args.sql:
        cursor = conn.execute(args.sql)
        names = [d[0] for d in cursor.description or []]
        if names:
            print("\n" + " | ".join(names))
        for row in cursor.fetchall():
            print(" | ".join(str(v) for v in row))
        return 0

    if args.export:
        rows = conn.execute("SELECT payload FROM events ORDER BY server_time").fetchall()
        with open(args.export, "w", encoding="utf-8") as fh:
            json.dump([json.loads(r[0]) for r in rows], fh, indent=2)
        print("exported %d event(s) to %s" % (len(rows), args.export))
        return 0

    summarize(conn)
    print("\ndatabase: %s" % args.db)
    print("query it:  python3 tools/ingest.py --sql \"SELECT * FROM sessions\"")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
