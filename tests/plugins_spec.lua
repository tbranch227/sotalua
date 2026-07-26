-- tests/plugins_spec.lua -- every plugin through a full lifecycle.
--
-- The generic pass below is the important one: load, start, run frames, change
-- scene, log out, disable. It asserts the two failure modes that are invisible
-- until they bite in game -- widgets that survive a disable (so ids climb on
-- every /lua reload and orphaned panels stay on screen) and errors logged
-- during normal operation (eight in ten seconds and the host disables the
-- addon).

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

local PLUGINS = {
    "addon-inspector", "api-probe", "buff-bars", "crit-tracker", "event-fx",
    "loot-tracker", "party-frames", "perf-monitor", "player-frame", "scene-info",
    "session-log", "target-frame", "world-clock", "xp-tracker",
}

--- A world with something in every system, so no plugin renders against nil.
local function populatedWorld(w)
    w.target = { name = "Obsidian Wolf", id = 42, dead = false, healthHidden = false,
                 health = 260, maxHealth = 400, focus = 30, maxFocus = 60,
                 buffs = { H.rune("Weakness", { debuff = true, duration = 12 }) } }
    w.playerBuffs = {
        H.rune("Shield of Air", { duration = 300, icon = 11 }),
        H.rune("Blood Lust", { duration = 8, icon = 12 }),
        H.rune("Chill", { debuff = true, duration = -1 }),
    }
    w.pet = { Name = "Wolf", Level = 30, CurrentHealth = 200, MaxHealth = 300, isSummon = false }
    w.petBuffs = { H.rune("Pet Ward", { duration = 60 }) }
    w.party = {
        { name = "Alice", health = 90, maxHealth = 200, focus = 20, maxFocus = 80, inScene = true },
        { name = "Bob", health = 150, maxHealth = 160, focus = 40, maxFocus = 90, inScene = false },
    }
    w.inventory = {
        H.item("Gold Ore", { quantity = 8, value = 40 }),
        H.item("Longsword", { quantity = 1, value = 900, createdBy = "Smith" }),
    }
    w.underMouse = { kind = "npc", name = "Guard Captain", description = "Guard\nLevel 40", id = 9 }
    w.emotes = { "wave", "bow" }
end

describe("plugin lifecycle", function()
    after_each(H.teardown)

    for _, slug in ipairs(PLUGINS) do
        it(slug .. " survives load, play, scene change, logout and disable", function()
            local M = H.bootstrap({ world = populatedWorld })
            H.plugin(slug, M)
            H.installHandlers(M)

            H.host.start()
            H.host.frames(90, 1 / 30)      -- three seconds of play
            H.host.gainExperience("Adventurer", 450)
            H.host.gainExperience("Producer", 25)

            -- Buffs tick down; targets change; the world moves. Data shapes are
            -- read-only snapshots, as the host's userdata is, so the rune is
            -- replaced rather than edited in place.
            H.host.world.playerBuffs[2] = H.rune("Blood Lust", { duration = 2, icon = 12 })
            H.host.world.target.health = 40
            H.host.frames(90, 1 / 30)

            H.host.loadScene("Etceter")
            H.host.frames(60, 1 / 30)

            H.host.world.target = nil      -- target dies mid-fight
            H.host.frames(30, 1 / 30)

            H.host.logout()
            H.host.disable()

            local errors = {}
            for _, line in ipairs(H.host.console()) do
                if line:find("ERROR", 1, true) then errors[#errors + 1] = line end
            end
            assert_that.same({}, errors, slug .. " logged errors during normal play")

            assert_that.equal(0, H.host.liveWidgetCount(),
                slug .. " left widgets alive after disable")

            local periodics = {}
            for name in ShroudListPeriodics() do periodics[#periodics + 1] = name end
            assert_that.same({}, periodics, slug .. " left a periodic registered after disable")
        end)
    end

    for _, slug in ipairs(PLUGINS) do
        it(slug .. " starts cleanly in an empty world", function()
            -- No target, no party, no pet, no buffs, no inventory: every getter
            -- returns its sentinel. This is the state at a fresh login.
            local M = H.bootstrap()
            H.plugin(slug, M)
            H.installHandlers(M)

            H.host.start()
            H.host.frames(60, 1 / 30)
            H.host.disable()

            for _, line in ipairs(H.host.console()) do
                assert_that.falsy(line:find("ERROR", 1, true),
                    slug .. " errored in an empty world: " .. line)
            end
        end)
    end

    for _, slug in ipairs(PLUGINS) do
        it(slug .. " runs on an unversioned client with legacy data shapes", function()
            -- The live client: no ShroudLuaApiVersion, and RuneEffects without
            -- RuneId or IconId. Every addon must degrade rather than error.
            local M = H.bootstrap({
                publishApiVersion = false,
                world = function(w)
                    populatedWorld(w)
                    w.playerBuffs = {
                        H.rune("Shield of Air", { duration = 300, legacy = true }),
                        H.rune("Chill", { debuff = true, duration = -1, legacy = true }),
                    }
                    w.petBuffs = { H.rune("Pet Ward", { duration = 60, legacy = true }) }
                    w.target.buffs = { H.rune("Weakness", { debuff = true, duration = 12, legacy = true }) }
                end,
            })
            H.plugin(slug, M)
            H.installHandlers(M)

            H.host.start()
            H.host.frames(120, 1 / 30)
            H.host.loadScene("Etceter")
            H.host.frames(60, 1 / 30)
            H.host.logout()
            H.host.disable()

            for _, line in ipairs(H.host.console()) do
                assert_that.falsy(line:find("ERROR", 1, true),
                    slug .. " errored on the unversioned client: " .. line)
            end
        end)
    end

    it("registers no more than one periodic per plugin", function()
        -- ShroudRegisterPeriodic resolves a global by name, so a plugin that
        -- minted one global per timer would flood the shared environment.
        local M = H.bootstrap({ world = populatedWorld })
        local factory = dofile(H.root .. "plugins/loot-tracker/src/main.lua")
        factory(M)
        H.installHandlers(M)
        H.host.start()
        H.host.frames(30, 1 / 30)

        local periodics = {}
        for name in ShroudListPeriodics() do periodics[#periodics + 1] = name end
        assert_that.same({ "_LootTracker_pump" }, periodics)
    end)

    it("never reads inventory from the frame loop", function()
        -- ShroudGetInventory builds a 14-field tuple per stack. Calling it per
        -- frame is the single easiest way to blow the 1 second watchdog.
        local M = H.bootstrap({ world = populatedWorld })
        local calls = 0
        local original = ShroudGetInventory
        _G.ShroudGetInventory = function() calls = calls + 1; return original() end

        local factory = dofile(H.root .. "plugins/loot-tracker/src/main.lua")
        factory(M)
        H.installHandlers(M)
        H.host.start()
        H.host.frames(300, 1 / 60)      -- five seconds

        assert_that.truthy(calls <= 4,
            "inventory was read " .. calls .. " times in five seconds")
    end)
end)

describe("target-frame", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("target-frame", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("shows the target's name and health", function()
        plugin.render()
        assert_that.is_true(H.host.hasText("Obsidian Wolf"))
        assert_that.is_true(H.host.hasText("260"))
    end)

    it("says health is hidden rather than drawing a full bar", function()
        H.host.world.target.healthHidden = true
        M.poll.invalidate()
        plugin.render()
        -- The host reports current == max here, so a naive frame would show a
        -- full green bar for an enemy that may be nearly dead.
        assert_that.is_true(H.host.hasText("health hidden"))
    end)

    it("marks a dead target", function()
        H.host.world.target.dead = true
        M.poll.invalidate()
        plugin.render()
        assert_that.is_true(H.host.hasText("(dead)"))
    end)

    it("clears rune rows when the target id changes", function()
        plugin.render()
        assert_that.is_true(H.host.hasText("Weakness"))

        -- Same name, different creature: only the id distinguishes them.
        H.host.world.target = { name = "Obsidian Wolf", id = 43, dead = false,
                                healthHidden = false, health = 400, maxHealth = 400,
                                focus = 0, maxFocus = 0, buffs = {} }
        M.poll.invalidate()
        plugin.render()
        assert_that.is_false(H.host.hasText("Weakness"),
            "the previous target's debuff timer carried over")
    end)

    it("hides itself when there is no target", function()
        H.host.world.target = nil
        M.poll.invalidate()
        plugin.render()
        assert_that.is_false(plugin.view.window:isVisible())
    end)
end)

describe("buff-bars", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("buff-bars", M)
        H.installHandlers(M)
        H.host.start()
        H.host.frames(20, 1 / 30)
    end)
    after_each(H.teardown)

    it("lists player runes soonest-to-expire first", function()
        local texts = H.host.texts()
        local blood, shield
        for i, text in ipairs(texts) do
            if tostring(text):find("Blood Lust", 1, true) then blood = i end
            if tostring(text):find("Shield of Air", 1, true) then shield = i end
        end
        assert_that.truthy(blood, "Blood Lust row missing")
        assert_that.truthy(shield, "Shield of Air row missing")
        assert_that.truthy(blood < shield, "an 8s buff must sort above a 300s one")
    end)

    it("labels an indefinite effect rather than showing -1", function()
        assert_that.equal("Chill                      perm",
            plugin.formatRune({ name = "Chill", remaining = -1, effectCount = 1 }))
    end)

    it("shows the pet's runes under its name", function()
        assert_that.is_true(H.host.hasText("Pet: Wolf"))
        assert_that.is_true(H.host.hasText("Pet Ward"))
    end)
end)

describe("party-frames", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("party-frames", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("separates members who are here from members who are not", function()
        plugin.render()
        assert_that.is_true(H.host.hasText("Alice"))
        assert_that.is_true(H.host.hasText("Bob  (away)"))
        assert_that.is_true(H.host.hasText("out of scene"))
    end)

    it("hides itself when solo", function()
        H.host.world.party = {}
        M.poll.invalidate()
        plugin.render()
        assert_that.is_false(plugin.view.window:isVisible())
    end)
end)

describe("xp-tracker", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("xp-tracker", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("counts an experience gain exactly once", function()
        H.host.gainExperience("Adventurer", 1000)
        -- ShroudOnExperienceChanged is an alias of the same event; a plugin
        -- subscribing to both would report 2000 here.
        assert_that.equal(1000, plugin.session.adventurer)
    end)

    it("separates adventurer from producer", function()
        H.host.gainExperience("Adventurer", 500)
        H.host.gainExperience("Producer", 75)
        assert_that.equal(500, plugin.session.adventurer)
        assert_that.equal(75, plugin.session.producer)
    end)

    it("warns while experience is attenuated", function()
        H.host.world.experience.attenuationAdv = true
        plugin.render()
        assert_that.is_true(H.host.hasText("ATTENUATED"))
    end)

    it("folds the session into lifetime totals without double counting", function()
        H.host.gainExperience("Adventurer", 300)
        plugin.persist()
        plugin.persist()   -- a disable right after a logout must not re-add
        assert_that.equal(300, (M.settings.get("lifetime") or {}).adventurer)
    end)
end)

describe("loot-tracker", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("loot-tracker", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("treats the first snapshot as a baseline, not a haul", function()
        plugin.diff()
        assert_that.same({}, plugin.movements())
    end)

    it("reports items gained since the baseline", function()
        plugin.diff()
        H.host.world.inventory[#H.host.world.inventory + 1] =
            H.item("Elven Rune", { quantity = 3, value = 250 })
        H.host.frames(1, 1)
        plugin.diff()

        local moved = plugin.movements()
        assert_that.equal(1, #moved)
        assert_that.equal("Elven Rune", moved[1].name)
        assert_that.equal(3, moved[1].delta)
        assert_that.equal(750, plugin.session.value)
    end)

    it("reports items that left the bags as negative", function()
        plugin.diff()
        table.remove(H.host.world.inventory, 1)   -- the 8 Gold Ore
        H.host.frames(1, 1)
        plugin.diff()

        local moved = plugin.movements()
        assert_that.equal(1, #moved)
        assert_that.equal(-8, moved[1].delta)
    end)
end)

describe("late per-frame player globals", function()
    -- A real API 4 client published none of ShroudPlayerX/Y/Z, CurrentHealth,
    -- CurrentFocus or Gold while the character stood still. Anything that reads
    -- them as `x or 0` produces a confident wrong answer.
    after_each(H.teardown)

    it("poll.player reports which globals are absent", function()
        local M = H.bootstrap({ world = function(w) w.playerGlobalsPending = true end })
        local player = M.poll.player()
        assert_that.is_false(player.available)
        assert_that.is_false(player.hasPosition)
        assert_that.nil_(player.gold)
        assert_that.same({ "x", "y", "z", "health", "focus", "gold" }, player.missing)

        H.host.publishPlayerGlobals()
        local live = M.poll.player()
        assert_that.is_true(live.available)
        assert_that.equal(1234, live.gold)
    end)

    it("loot-tracker does not report the whole purse as profit", function()
        local M = H.bootstrap({ world = function(w)
            populatedWorld(w)
            w.playerGlobalsPending = true
        end })
        local plugin = H.plugin("loot-tracker", M)
        H.installHandlers(M)
        H.host.start()
        H.host.frames(240, 1 / 30)     -- eight seconds with no gold global

        assert_that.nil_(plugin.session.goldStart,
            "a baseline must not be taken from a missing global")

        H.host.publishPlayerGlobals()  -- the host finally pushes 1234 gold
        H.host.frames(240, 1 / 30)

        assert_that.equal(1234, plugin.session.goldStart)
        assert_that.equal(0, plugin.session.gold,
            "gold appearing is not income")

        H.host.world.player.gold = 1334
        H.host.publishPlayerGlobals()
        H.host.frames(240, 1 / 30)
        assert_that.equal(100, plugin.session.gold)
    end)

    it("scene-info says the position is pending rather than showing 0,0,0", function()
        local M = H.bootstrap({ world = function(w)
            populatedWorld(w)
            w.playerGlobalsPending = true
        end })
        local plugin = H.plugin("scene-info", M)
        H.installHandlers(M)
        H.host.start()
        plugin.render()

        assert_that.is_true(H.host.hasText("position pending"))
        assert_that.is_false(H.host.hasText("0, 0, 0"))
    end)

    it("session-log adopts the first real gold reading as its baseline", function()
        local M = H.bootstrap({ world = function(w)
            populatedWorld(w)
            w.playerGlobalsPending = true
        end })
        local plugin = H.plugin("session-log", M)
        H.installHandlers(M)
        H.host.start()
        assert_that.nil_(plugin.current.goldStart)

        H.host.publishPlayerGlobals()
        plugin.render()
        assert_that.equal(1234, plugin.current.goldStart)

        H.host.world.player.gold = 1000   -- spent some
        H.host.publishPlayerGlobals()
        plugin.closeSession()
        local history = M.settings.get("sessions") or {}
        assert_that.equal(-234, history[#history].gold)
    end)

    it("every plugin runs a full lifecycle with the globals never published", function()
        for _, slug in ipairs(PLUGINS) do
            local M = H.bootstrap({ world = function(w)
                populatedWorld(w)
                w.playerGlobalsPending = true
            end })
            H.plugin(slug, M)
            H.installHandlers(M)
            H.host.start()
            H.host.frames(90, 1 / 30)
            H.host.logout()
            H.host.disable()

            for _, line in ipairs(H.host.console()) do
                assert_that.falsy(line:find("ERROR", 1, true),
                    slug .. " errored without the player globals: " .. line)
            end
            H.teardown()
        end
    end)
end)

describe("player-frame", function()
    local M, plugin

    local function build(boot)
        M = H.bootstrap(boot or { world = populatedWorld })
        plugin = H.plugin("player-frame", M)
        H.installHandlers(M)
        H.host.start()
        return plugin
    end

    after_each(H.teardown)

    it("prefers a real max stat over guessing", function()
        build({ world = function(w)
            populatedWorld(w)
            w.player.health = 625
            w.stats[#w.stats + 1] = { name = "MaxHealth", description = "Max Health", value = 900 }
        end })
        plugin.render()

        local maximum, source = plugin.resolveMax("health", 625)
        assert_that.equal(900, maximum)
        assert_that.equal("stat MaxHealth", source)
        assert_that.is_true(H.host.hasText("625 / 900"))
    end)

    it("falls back to the highest value seen when no stat matches", function()
        build({ world = function(w)
            populatedWorld(w)
            -- No health-shaped stat at all, which is the case on a client whose
            -- stat names we have not confirmed.
            w.stats = { { name = "Strength", description = "Strength", value = 55 } }
            w.player.health = 400
        end })
        plugin.render()

        local maximum, source = plugin.resolveMax("health", 400)
        assert_that.equal(400, maximum)
        assert_that.equal("session peak", source)
    end)

    it("keeps the peak when health drops, so the bar drains", function()
        build({ world = function(w)
            populatedWorld(w)
            w.stats = { { name = "Strength", description = "Strength", value = 55 } }
            w.player.health = 400
        end })
        plugin.render()

        H.host.world.player.health = 100
        H.host.refreshGlobals()
        M.poll.invalidate()
        plugin.render()

        local maximum = plugin.resolveMax("health", 100)
        assert_that.equal(400, maximum, "the peak must not follow the value down")
        assert_that.is_true(H.host.hasText("100 / 400"))
    end)

    it("ignores a stat whose value is below current health", function()
        -- Some tables expose a base value that buffs exceed; using it would
        -- produce a bar permanently pinned past full.
        build({ world = function(w)
            populatedWorld(w)
            w.stats = { { name = "MaxHealth", description = "Max Health", value = 100 } }
            w.player.health = 625
        end })
        local maximum, source = plugin.resolveMax("health", 625)
        assert_that.equal(625, maximum)
        assert_that.equal("session peak", source)
    end)

    it("says it is waiting rather than showing an empty bar", function()
        build({ world = function(w)
            populatedWorld(w)
            w.playerGlobalsPending = true
        end })
        plugin.render()

        -- Absent globals are not zero. An empty red bar would read as "dead"
        -- and a zero gold total as "broke".
        assert_that.is_true(H.host.hasText("waiting for the host"))
        assert_that.is_true(H.host.hasText("gold  waiting for the host"))
    end)

    it("picks the globals up once the host publishes them", function()
        build({ world = function(w)
            populatedWorld(w)
            w.playerGlobalsPending = true
        end })
        plugin.render()
        assert_that.is_false(H.host.hasText("gold  1,234"))

        H.host.publishPlayerGlobals()
        M.poll.invalidate()
        plugin.render()
        assert_that.is_true(H.host.hasText("gold  1,234"))
    end)

    it("shows the combat indicator", function()
        build()
        H.host.world.player.combat = true
        plugin.render()
        assert_that.is_true(H.host.hasText("[combat]"))
    end)

    it("shows the pet with its level and health", function()
        build()
        plugin.render()
        assert_that.is_true(H.host.hasText("Wolf  lv 30"))
        assert_that.is_true(H.host.hasText("200 / 300"))
    end)

    it("hides the pet row when there is no pet", function()
        build({ world = function(w)
            populatedWorld(w)
            w.pet = nil
        end })
        plugin.render()
        assert_that.is_false(H.host.hasText("lv 30"))
    end)

    it("honours a manual stat override", function()
        build({ world = function(w)
            populatedWorld(w)
            w.stats[#w.stats + 1] = { name = "MaxHealth", description = "Max Health", value = 900 }
            w.stats[#w.stats + 1] = { name = "Vitality", description = "Vitality", value = 1200 }
        end })

        M.settings.set("healthStat", "Vitality")
        local maximum, source = plugin.resolveMax("health", 625)
        assert_that.equal(1200, maximum)
        assert_that.equal("stat Vitality", source)
    end)
end)

describe("world-clock", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("world-clock", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("uses the host's day and month without adding another +1", function()
        plugin.render()
        -- The mock reports Day 12 / Month 3, which already carry the engine's
        -- +1. Showing 13 or 4 would be the classic double-increment bug.
        assert_that.is_true(H.host.hasText("day 12, month 3, year 452"))
    end)

    it("formats a fractional hour in both conventions", function()
        assert_that.equal("14:30", plugin.formatHour(14.5))
        M.settings.set("use24Hour", false)
        assert_that.equal("2:30pm", plugin.formatHour(14.5))
    end)

    it("says so when game time is unavailable", function()
        -- A zeroed table is how the host reports "no game time".
        H.host.world.gameTime = { Day = 0, Hour = 0, Month = 0, Year = 0,
                                  PeriodOfDay = "", Season = "" }
        M.poll.invalidate()
        plugin.render()
        assert_that.is_true(H.host.hasText("game time unavailable"))
    end)
end)

describe("scene-info", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("scene-info", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("corrects the compass for the scene's orientation", function()
        H.host.world.player.orientation = 90
        H.host.world.scene.orientation = 90
        M.poll.invalidate()
        -- Facing world-east in a scene rotated 90 degrees is scene-north.
        local compass, degrees = plugin.heading()
        assert_that.equal("N", compass)
        assert_that.equal(0, degrees)
    end)

    it("flags a PVP scene", function()
        H.host.world.scene.isPvp = true
        M.poll.invalidate()
        plugin.render()
        assert_that.is_true(H.host.hasText("PVP"))
    end)

    it("shows the scene caps", function()
        plugin.render()
        assert_that.is_true(H.host.hasText("level cap 30"))
        assert_that.is_true(H.host.hasText("skill cap 80"))
    end)
end)

describe("session-log", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("session-log", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("records the scenes visited", function()
        H.host.loadScene("Etceter")
        H.host.loadScene("Brittany")
        H.host.loadScene("Etceter")   -- a revisit must not duplicate
        assert_that.same({ "Solace Bridge", "Etceter", "Brittany" }, plugin.current.scenes)
    end)

    it("writes one entry per session even if closed twice", function()
        H.host.frames(60, 1)
        plugin.closeSession()
        plugin.closeSession()   -- logout then disable

        local history = M.settings.get("sessions") or {}
        -- The second close covers a fresh, empty window; both are recorded but
        -- the first one's earnings are not counted again.
        assert_that.equal(2, #history)
        assert_that.equal(0, history[2].adventurer)
    end)

    it("keeps the stored history bounded", function()
        for _ = 1, 60 do plugin.closeSession() end
        local history = M.settings.get("sessions") or {}
        assert_that.truthy(#history <= 40,
            "history grew to " .. #history .. "; the host drops values over 256 KB")
    end)
end)

describe("perf-monitor", function()
    local M, plugin
    before_each(function()
        M = H.bootstrap({ world = populatedWorld })
        plugin = H.plugin("perf-monitor", M)
        H.installHandlers(M)
        H.host.start()
    end)
    after_each(H.teardown)

    it("counts a stall the clamped delta would have hidden", function()
        H.host.frames(30, 1 / 60)
        H.host.frame(0.4)     -- a 400ms hitch
        -- ShroudDeltaTime saturates at ~0.1s; only ShroudRealDeltaTime shows it.
        assert_that.equal(0.1, ShroudDeltaTime)
        assert_that.equal(0.4, ShroudRealDeltaTime)
        assert_that.equal(1, plugin.state.hitches)
        assert_that.near(0.4, plugin.state.worst, 0.001)
    end)

    it("does not count normal frames as hitches", function()
        H.host.frames(120, 1 / 60)
        assert_that.equal(0, plugin.state.hitches)
    end)
end)

describe("addon-inspector", function()
    after_each(H.teardown)

    it("reports what is under the cursor", function()
        local M = H.bootstrap({ world = populatedWorld })
        H.plugin("addon-inspector", M)
        H.installHandlers(M)
        H.host.start()
        H.host.frames(20, 1 / 30)

        assert_that.is_true(H.host.hasText("Guard Captain"))
        assert_that.is_true(H.host.hasText("kind npc   id 9"))
    end)

    it("refuses to run on a client older than API 2", function()
        local M = H.bootstrap({ apiVersion = 1, world = populatedWorld })
        H.plugin("addon-inspector", M)
        H.installHandlers(M)
        H.host.start()

        assert_that.is_true(H.host.consoleContains("needs API 2 or newer"))
        assert_that.equal(0, H.host.liveWidgetCount(),
            "no window should be built on an unsupported client")
    end)
end)
