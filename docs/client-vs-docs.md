# Where the client disagrees with its documentation

Observed on a **Shroud of the Avatar (DEV) client reporting
`ShroudLuaApiVersion = 4`**, 25 July 2026. The published reference at
<https://catnipgames.net/lua/> documents API **3** and was byte-identical to the
vendored copy at the time, so nothing below is described anywhere upstream.

Reproduce with `/lua _ApiProbe_export` (writes `api-export.txt` into the Lua
folder) then `python3 tools/diffapi.py`.

---

## 1. `ShroudPlaySoundChannel` exists and is undocumented

The only symbol present in the client but absent from the reference. Signature
unknown; presumably a channel-directed variant of `ShroudPlaySound(id, volume)`,
which returns a 0-based channel while `ShroudStopSound` takes a 1-based one.

**Not used by anything in this repo.** Sound is not part of the suite, and
guessing an undocumented signature is a poor trade against the 1-second
callback watchdog. If sound is ever added, probe it first.

## 2. The six per-frame player globals are absent after every reload

`ShroudPlayerX`, `ShroudPlayerY`, `ShroudPlayerZ`, `ShroudPlayerCurrentHealth`,
`ShroudPlayerCurrentFocus` and `ShroudPlayerGold` are **not created until their
value next changes**, and `/lua reload` puts them back into that state.

Observed sequence on one logged-in character:

| Event | State |
| --- | --- |
| shortly after a reload, standing still | all six absent from `_G` |
| after moving around the scene | all six present (`ShroudPlayerGold = 2648406`) |
| `/lua reload`, then standing still | **all six absent again**, still absent a minute later |

So this is not a one-off warm-up at login. Every reload returns the addon to a
state where the player's position, vitals and gold simply do not exist, for as
long as the character stands still.

The reference describes them as "refreshed by the host on every frame while at
least one addon is enabled" and notes parenthetically that "internally most use
a dirty-check and are only re-pushed when they change". The client takes that
literally: no change since the Lua environment was rebuilt means no global.

**Consequence for addon authors:** `ShroudOnStart` is the *worst* moment to read
these. An addon that captures a baseline there is guaranteed to capture nothing,
on every single reload.

**This is the most dangerous difference found**, because the obvious idiom
produces a confident wrong answer rather than an error:

```lua
local gold = tonumber(ShroudPlayerGold) or 0   -- 0 is not "unknown"
```

A session tracker that takes `0` as its opening balance reports the player's
entire purse as profit the instant the host publishes the real value. A
coordinate readout shows `0, 0, 0`, which reads as a real location at the world
origin rather than as missing data.

**How this repo handles it.** `core/poll.lua` exposes `poll.player()`, which
returns `nil` for any global the host has not published, plus `available`,
`hasPosition` and a `missing` list. Consumers defer their baselines until a real
reading arrives:

- `loot-tracker` shows `gold waiting` and does not set `goldStart` until gold exists
- `session-log` adopts the first real reading as its baseline
- `scene-info` shows `position pending` instead of `0, 0, 0`

`tests/mock/host.lua` models this with `world.playerGlobalsPending`, and
`tests/plugins_spec.lua` runs every plugin through a full lifecycle with the
globals never published.

## 3. `ShroudLuaPath` is not set before addon bodies run

The reference states the set-once constants "are written once, before any addon
file runs, so they are safe to read at the top level of an addon file".
`ShroudLuaApiVersion` does behave that way. `ShroudLuaPath` did not: a value
snapshotted at file scope was `""`, while the same global read later from a
command returned the real path.

Snapshotting it turned a path into `/api-export.txt` and the sandbox correctly
refused the write as outside the addon folder.

**How this repo handles it.** `core/env.lua` exposes `env.luaPath()`,
`env.dataPath()` and `env.luaFile(name)` as functions that read the global at
call time. There is no `env.LUA_PATH` constant.

## 4. A flat addon *can* write into the Lua folder

Confirmed rather than assumed: with a correct absolute path built from
`ShroudLuaPath`, `io.open(path, "w")` succeeds for a loose `.lua` addon
installed directly in `Lua/`. The sandbox's "addon folder" for a flat addon is
the `Lua/` folder itself, not a per-addon subdirectory.

The earlier denials were self-inflicted — a snapshotted empty `ShroudLuaPath`
produced `/api-export.txt`, which the sandbox correctly refused as outside the
folder.

## 5. Enum tables are not enumerable

`UI`, `TextAnchor`, `ButtonMode`, `Transition`, `ContentType` and `AudioType`
exist and their members resolve (`UI.Panel` works), but `pairs()` over them
yields nothing — they are MoonSharp registered-type proxies, not Lua tables.

Consequence: enum members cannot be discovered at runtime, so
`tools/diffapi.py` cannot verify them and reports no enum drift. Verifying a
suspected new member means testing `UI.NewKind ~= nil` explicitly.

---

## Not findings

`print` and `collectgarbage` appear as "missing" in a raw export diff only
because the exporter filters for `Shroud*` names. Both are present, and both are
overridden by the host as documented.
