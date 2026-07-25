# sotalua

A suite of Lua addons for Shroud of the Avatar, built on a shared core library
with an offline test harness.

Eleven addons across four groups, plus `core/`, a bundler, a mock host that
reproduces the client's documented quirks, and 116 specs that run without the
game.

## Quick start

```bash
./run.sh setup     # fetch a Lua interpreter into .tooling/ (no sudo needed)
./run.sh all       # build, syntax-check, lint, test
./run.sh install   # copy the bundles into the game's Lua/ folder
```

Then, in game: `/lua reload`, open the addon manager, and enable them. **New
addons always load disabled** — that is the client's behaviour, not a bug.

The installer needs to know where the game's `Lua/` folder is. The API docs
deliberately publish no path for it, so type `/lua path` in chat (or use the
manager's *Open Folder* button) and pass what it opens:

```bash
python3 tools/install.py --path '/mnt/c/.../Shroud of the Avatar/Lua'
```

It is remembered in `.sotalua.local` after that.

## The addons

### Development toolkit

| Addon | What it does |
| --- | --- |
| `api-probe` | Dumps live state to chat: stats, buffs, target, party, scene, inventory, registered periodics, API version. Nine slash commands, no UI. |
| `perf-monitor` | Frame times from the **unclamped** delta, hitch counter, heap readout, optional incremental GC assist. |
| `addon-inspector` | Name, kind, id and tooltip of whatever is under the cursor, with a pin key. Needs API 2. |

### Combat HUD

| Addon | What it does |
| --- | --- |
| `target-frame` | Target name, health and focus bars, dead and hidden-health states, rune timers. Detects target switches by id. |
| `buff-bars` | Player and pet runes sorted by time remaining, with real skill icons on API 3. |
| `party-frames` | Health and focus per member, out-of-scene members dimmed, low-health warning. |

### Progression

| Addon | What it does |
| --- | --- |
| `xp-tracker` | Session adventurer and producer XP, hourly rate, pooled vs total, attenuation warning. |
| `loot-tracker` | Session inventory deltas and gold, diffed on a timer rather than per frame. |
| `session-log` | Per-character session history: times, scenes visited, XP and gold earned. |

### World

| Addon | What it does |
| --- | --- |
| `world-clock` | In-game date, time, season, period of day, and server time. |
| `scene-info` | Scene name, level and skill caps, PvP and player-town flags, dungeon owner, orientation-corrected compass, coordinates. |

Every addon persists its window position and options, and every one has slash
commands: `/lua _TargetFrame_autohide`, `/lua _XpTracker_report`, and so on.

## How it is put together

The client's API constrains the design more than it might look:

- **The API is read-mostly.** There is no way to move, cast, target, loot,
  trade, or send chat, and `ShroudSwitchDeck` is a stub. Every addon here is a
  HUD, tracker, or overlay, because that is all that is possible.
- **Every enabled addon shares one MoonSharp environment.** A stray global can
  collide with another author's addon. So `core/` is bundled as file-locals and
  creates no globals at all; the only names that reach `_G` are the `ShroudOn*`
  callbacks and slug-prefixed entry points like `_LootTracker_pump`.
- **There is no `require()`,** even between files of one package, and the
  store's submission flow packages a single `.lua`. Code reuse therefore has to
  happen at build time, which is what `tools/build.py` does.
- **Callbacks are single-slot.** The host looks up one `ShroudOnUpdate` per
  addon, so `core/events.lua` owns it and fans out to any number of subscribers,
  each wrapped so one bad handler cannot silence the others.
- **A callback that runs over 1 second is killed, and 8 errors in 10 seconds
  disables the addon.** Nothing expensive runs in the frame loop: inventory is
  diffed on a periodic, buff snapshots are shared across all readers for one
  frame, and repeated errors collapse into a single report.

### Layout

```
core/            the shared library, bundled into each addon
plugins/<slug>/  plugin.json + src/main.lua
tools/           scrape, index, build, lint, install, get_lua
tests/           mock host, runner, specs
docs/vendor/     the scraped API documentation
docs/api-index.* generated symbol index (217 entries)
dist/            build output (gitignored)
```

Core modules, in load order: `util`, `log`, `env`, `settings`, `events`,
`timers`, `poll`, `ui`, `layout`, `addon`. Each is
`return function(Core) ... end`, so the bundler and the test harness build the
identical object graph.

`core/ui.lua` is where the client's [frozen
quirks](docs/vendor/reference.txt) are absorbed — the y negation, the pivot
side-effect, `ShroudSetToggleReadonly` meaning interactability, the button
colour block reset, the listeners that cannot be removed, and the setters that
throw on a negative id. The mock host in `tests/mock/host.lua` reproduces all of
them deliberately, so a quirk-handling regression fails a test instead of
reaching the game.

## Toolchain

A `lua` binary is the only hard dependency. Use the system one if you have it
(`sudo apt install lua5.4`), or `./run.sh setup` fetches one into `.tooling/`
without sudo or a compiler. The test runner and linter are written from scratch
precisely so that neither luarocks nor busted is needed. Python 3 drives the
scraper, bundler and installer.

**Optional:** `sudo apt install lua-check` (the Ubuntu package name for
luacheck; plain `luacheck` is not a package). `./run.sh lint` uses it when
present and says so when not. It earns its place by catching a misspelled
`Shroud*` name, which the in-repo linter cannot see and the mock host only
catches if a spec happens to execute that line. `.luacheckrc` is generated by
`tools/genglobals.py` from `docs/api-index.json` — 194 API symbols and six enums
with their member lists, so `UI.Panle` fails the same way a bad function name
does. It refreshes with `./run.sh scrape`, so it cannot drift from the docs.

Library code stays inside the Lua 5.2 subset MoonSharp implements — no `goto`,
no integer division, no `\u{}` escapes, and `table.unpack` resolved once against
`unpack` rather than selected inline.

## Working on it

```bash
./run.sh test                 # all specs
./run.sh test target          # only specs matching "target"
./run.sh build target-frame   # rebuild one addon
./run.sh lint                 # flag accidental globals
./run.sh scrape               # re-vendor the docs and regenerate the index
```

Adding an addon: create `plugins/<slug>/plugin.json` and
`plugins/<slug>/src/main.lua` returning `function(Core) ... end`, then build.
The bundler validates the slug pattern, version format, and manifest rules the
store enforces, so a bad manifest fails locally rather than at submission.

`docs/api-index.md` is generated from the vendored reference and lists all 217
documented symbols with signatures and minimum API version. Re-run
`./run.sh scrape` when the client's API changes.

## Testing in game

1. `./run.sh all && ./run.sh install`
2. `/lua reload`
3. Enable each addon in the manager. Watch chat for lines prefixed with the
   addon's name; if one vanishes, it hit the 8-errors-in-10-seconds auto-disable
   and needs another `/lua reload` after a fix.
4. Exercise the real triggers: take a target, gain a buff, join a party, earn
   XP, pick up loot, change scene, drag and resize a window, then log out and
   back in to confirm settings survived.
5. Watch `perf-monitor` with everything enabled and confirm no added hitches.
