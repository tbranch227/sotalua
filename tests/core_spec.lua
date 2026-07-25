-- tests/core_spec.lua -- the core library against the mock host.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

describe("util", function()
    local M
    before_each(function() M = H.bootstrap() end)
    after_each(H.teardown)

    it("treats -999 as a failed numeric read", function()
        assert_that.is_false(M.util.isValid(-999))
        assert_that.is_false(M.util.isValid(InvalidStatResult))
        assert_that.is_true(M.util.isValid(0))
        assert_that.is_true(M.util.isValid(-1))
    end)

    it("treats the documented name sentinels as invalid", function()
        for _, sentinel in ipairs({ "INVALID", "Invalid", "None", "" }) do
            assert_that.is_false(M.util.isValidName(sentinel), sentinel .. " should be invalid")
        end
        assert_that.is_true(M.util.isValidName("Solace Bridge"))
    end)

    it("normalizes an enumerator into an array", function()
        local i = 0
        local enumerator = function()
            i = i + 1
            return ({ "a", "b", "c" })[i]
        end
        assert_that.same({ "a", "b", "c" }, M.util.list(enumerator))
    end)

    it("normalizes a table and drops nil holes", function()
        assert_that.same({ "a", "b" }, M.util.list({ "a", "b" }))
        assert_that.same({}, M.util.list(nil))
        assert_that.same({}, M.util.list({ nil }))
    end)

    it("skips hidden stats that read back as sentinels", function()
        local names = {}
        for _, name in M.util.stats() do names[#names + 1] = name end
        -- The mock's stat 2 is hidden, so a bare 0..count-1 loop would see it.
        assert_that.equal(5, ShroudGetStatCount())
        assert_that.equal(4, #names)
        for _, name in ipairs(names) do
            assert_that.not_equal("INVALID", name)
        end
    end)

    it("flips world-to-screen y into widget space", function()
        -- The host returns y in bottom-left space; util converts to top-left.
        local _, y = M.util.worldToScreen(1, 0, 5)
        local raw = ShroudWorldToScreenPoint(1, 0, 5)
        assert_that.equal(ShroudGetScreenY() - raw.y, y)
    end)

    it("forces a leading # onto colors and rejects garbage", function()
        assert_that.equal("#AABBCC", M.util.hex("aabbcc"))
        assert_that.equal("#AABBCC", M.util.hex("#AaBbCc"))
        assert_that.equal("#FFFFFF", M.util.hex("not-a-color"))
        assert_that.equal("#000000", M.util.hex(nil, "#000000"))
    end)

    it("formats durations and treats a negative as indefinite", function()
        assert_that.equal("45s", M.util.duration(45))
        assert_that.equal("2m05s", M.util.duration(125))
        assert_that.equal("1h01m", M.util.duration(3660))
        assert_that.equal("--", M.util.duration(-1))
    end)

    it("sorts stably so equal keys keep their order", function()
        local input = { { k = 1, tag = "a" }, { k = 1, tag = "b" }, { k = 0, tag = "c" } }
        local sorted = M.util.sortBy(input, function(x) return x.k end)
        assert_that.equal("c", sorted[1].tag)
        assert_that.equal("a", sorted[2].tag)
        assert_that.equal("b", sorted[3].tag)
    end)
end)

describe("env", function()
    local M
    after_each(H.teardown)

    it("derives feature flags from the client API version", function()
        M = H.bootstrap({ apiVersion = 3 })
        assert_that.is_true(M.env.HAS_TARGET)
        assert_that.is_true(M.env.HAS_MOUSE)
        assert_that.is_true(M.env.HAS_ICONS)
    end)

    it("gates v3 features off on an older client", function()
        M = H.bootstrap({ apiVersion = 2 })
        assert_that.is_true(M.env.HAS_MOUSE)
        assert_that.is_false(M.env.HAS_ICONS)
    end)

    it("reports a failing handler once and then stays quiet", function()
        M = H.bootstrap()
        M.env.init({ name = "T", slug = "t", logLevel = "debug" })
        local calls = 0
        local guarded = M.env.protect("boom", function()
            calls = calls + 1
            error("kaboom")
        end)

        for _ = 1, 20 do guarded() end

        assert_that.equal(20, calls, "the wrapped function should keep being called")
        local reported = 0
        for _, line in ipairs(H.host.console()) do
            if line:find("kaboom", 1, true) then reported = reported + 1 end
        end
        assert_that.equal(1, reported,
            "20 failures must not spend the host's 8-errors-in-10s budget")
    end)

    it("substitutes a fallback for a binding the client does not have", function()
        M = H.bootstrap()
        local missing = M.env.optional("ShroudNotARealFunction", -1)
        assert_that.equal(-1, missing())
        local present = M.env.optional("ShroudGetScreenX", -1)
        assert_that.equal(1920, present())
    end)
end)

describe("events", function()
    local M
    before_each(function()
        M = H.bootstrap()
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
    end)
    after_each(H.teardown)

    it("fans one host callback out to several subscribers", function()
        local seen = {}
        M.events.on("ShroudOnUpdate", function() seen[#seen + 1] = "a" end)
        M.events.on("ShroudOnUpdate", function() seen[#seen + 1] = "b" end)
        H.installHandlers(M)

        H.host.frame(0.016)
        assert_that.same({ "a", "b" }, seen)
    end)

    it("keeps the other subscribers alive when one throws", function()
        local reached = false
        M.events.on("ShroudOnUpdate", function() error("first handler is broken") end)
        M.events.on("ShroudOnUpdate", function() reached = true end)
        H.installHandlers(M)

        H.host.frame(0.016)
        assert_that.is_true(reached)
    end)

    it("does not double-fire the experience alias", function()
        local total = 0
        M.events.on("ShroudOnExperienceGain", function(_, amount) total = total + amount end)
        M.events.on("ShroudOnExperienceChanged", function(_, amount) total = total + amount end)
        H.installHandlers(M)

        -- Both names resolve to one stream, so two subscribers see one event each.
        H.host.gainExperience("Adventurer", 100)
        assert_that.equal(200, total)
        -- The alias global must not exist separately, or the host would call both.
        assert_that.nil_(rawget(_G, "ShroudOnExperienceChanged"))
    end)

    it("installs widget callbacks before any widget exists", function()
        -- The host captures an addon's callbacks once, right after the file
        -- body runs. Widgets are created later, in ShroudOnStart. So handlers()
        -- must publish the widget callbacks unconditionally: deciding by
        -- "does any widget have a binding" would always answer no at capture
        -- time and clicks would silently never arrive.
        local handlers = M.events.handlers()
        for _, name in ipairs({ "ShroudOnMouseClick", "ShroudOnMouseOver", "ShroudOnMouseOut",
                                "ShroudOnInputChange", "ShroudOnToggleChange" }) do
            assert_that.truthy(handlers[name], name .. " was not published")
        end
    end)

    it("omits per-frame callbacks nobody subscribed to", function()
        -- An unused ShroudOnGUI is called on every IMGUI event, several times a
        -- frame, across every enabled addon.
        local handlers = M.events.handlers()
        assert_that.nil_(handlers.ShroudOnGUI)
        assert_that.nil_(handlers.ShroudOnUpdate)

        M.events.on("ShroudOnUpdate", function() end)
        assert_that.truthy(M.events.handlers().ShroudOnUpdate)
    end)

    it("unsubscribes cleanly", function()
        local count = 0
        local off = M.events.on("ShroudOnUpdate", function() count = count + 1 end)
        H.installHandlers(M)

        H.host.frame(0.016)
        off()
        H.host.frame(0.016)
        assert_that.equal(1, count)
    end)
end)

describe("settings", function()
    local M
    before_each(function()
        M = H.bootstrap()
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
    end)
    after_each(H.teardown)

    it("falls back to the declared default", function()
        M.settings.define({ theme = { default = "dark" } })
        assert_that.equal("dark", M.settings.get("theme"))
    end)

    it("round-trips a value through the host store", function()
        M.settings.define({ count = { default = 0 } })
        M.settings.set("count", 7)
        assert_that.equal(7, ShroudGetSavedVar("count", "character"))
    end)

    it("honours the account scope", function()
        M.settings.define({ shared = { default = 1, scope = "account" } })
        M.settings.set("shared", 42)
        assert_that.equal(42, ShroudGetSavedVar("shared", "account"))
        assert_that.nil_(ShroudGetSavedVar("shared", "character"))
    end)

    it("detaches stored tables so mutation cannot corrupt saved state", function()
        M.settings.define({ window = { default = { x = 1 } } })
        ShroudSetSavedVar("window", { x = 5 }, "character")

        local copy = M.settings.get("window")
        copy.x = 999

        -- The host hands tables back by reference; get() must have copied.
        assert_that.equal(5, ShroudGetSavedVar("window", "character").x)
    end)

    it("backfills keys added by a newer plugin version", function()
        M.settings.define({ window = { default = { x = 1, y = 2, opacity = 0.9 } } })
        ShroudSetSavedVar("window", { x = 50 }, "character")

        local value = M.settings.get("window")
        assert_that.equal(50, value.x, "an existing key must win")
        assert_that.equal(2, value.y, "a new key must take the default")
        assert_that.equal(0.9, value.opacity)
    end)

    it("rejects keys the host would reject", function()
        M.settings.define({ ["bad/key"] = { default = 1 } })
        assert_that.is_false(M.settings.set("bad/key", 1))
        assert_that.is_false(M.settings.set(string.rep("k", 129), 1))
    end)

    it("refuses values that cannot be persisted", function()
        assert_that.is_false(M.settings.set("fn", function() end))
    end)

    it("flushes on logout and on disable", function()
        M.settings.define({ n = { default = 0 } })
        M.settings.install()
        H.installHandlers(M)

        M.settings.set("n", 1)
        assert_that.is_true(M.settings.isDirty())
        H.host.logout()
        assert_that.is_false(M.settings.isDirty())
        assert_that.equal(1, H.host.world.savedVarFlushes)
    end)
end)

describe("timers", function()
    local M
    before_each(function()
        M = H.bootstrap()
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
    end)
    after_each(H.teardown)

    it("registers exactly one global for any number of timers", function()
        M.timers.install("_Test_pump", 0.1)
        M.timers.every("a", 1, function() end)
        M.timers.every("b", 1, function() end)
        M.timers.every("c", 1, function() end)

        local registered = {}
        for name in ShroudListPeriodics() do registered[#registered + 1] = name end
        assert_that.same({ "_Test_pump" }, registered)
    end)

    it("fires a repeating timer on schedule", function()
        M.timers.install("_Test_pump", 0.05)
        local ticks = 0
        M.timers.every("tick", 0.5, function() ticks = ticks + 1 end)

        H.host.frames(60, 0.05)   -- three seconds
        assert_that.truthy(ticks >= 5, "expected at least 5 ticks, got " .. ticks)
    end)

    it("runs a one-shot timer once and forgets it", function()
        M.timers.install("_Test_pump", 0.05)
        local ran = 0
        M.timers.after("once", 0.2, function() ran = ran + 1 end)

        H.host.frames(40, 0.05)
        assert_that.equal(1, ran)
        assert_that.same({}, M.timers.active())
    end)

    it("throttles a per-frame function", function()
        local calls = 0
        local throttled = M.timers.throttle(0.5, function() calls = calls + 1 end)
        M.events.on("ShroudOnUpdate", throttled)
        H.installHandlers(M)

        H.host.frames(120, 1 / 60)   -- two seconds of frames
        assert_that.truthy(calls <= 6, "throttle let " .. calls .. " calls through")
        assert_that.truthy(calls >= 3, "throttle blocked too much: " .. calls)
    end)

    it("removes its host registration on uninstall", function()
        M.timers.install("_Test_pump", 0.1)
        M.timers.uninstall()

        local registered = {}
        for name in ShroudListPeriodics() do registered[#registered + 1] = name end
        assert_that.same({}, registered)
        assert_that.nil_(rawget(_G, "_Test_pump"))
    end)
end)

describe("poll", function()
    local M
    after_each(H.teardown)

    it("calls the expensive buff getter once per frame no matter the readers", function()
        M = H.bootstrap({ world = function(w)
            w.playerBuffs = { H.rune("Shield of Air") }
        end })

        local calls = 0
        local original = ShroudGetPlayerBuff
        _G.ShroudGetPlayerBuff = function() calls = calls + 1; return original() end

        for _ = 1, 10 do M.poll.playerBuffs() end
        assert_that.equal(1, calls, "10 readers in one frame must share one snapshot")

        H.host.frame(0.016)
        M.poll.playerBuffs()
        assert_that.equal(2, calls, "a new frame must re-read")
    end)

    it("surfaces a rune's longest effect as its remaining time", function()
        M = H.bootstrap({ world = function(w)
            w.playerBuffs = { H.rune("Multi", { effects = {
                { duration = 10 }, { duration = 45 }, { duration = 20 },
            } }) }
        end })

        local buffs = M.poll.playerBuffs()
        assert_that.equal(1, #buffs)
        assert_that.equal(45, buffs[1].remaining)
        assert_that.equal(3, buffs[1].effectCount)
    end)

    it("reports hidden target health rather than a full bar", function()
        M = H.bootstrap({ world = function(w)
            w.target = { name = "Lich", id = 7, maxHealth = 500, health = 120,
                         focus = 0, maxFocus = 0, healthHidden = true }
        end })

        local target = M.poll.target()
        assert_that.is_true(target.healthHidden)
        -- The host reports current == max when health is hidden. A consumer that
        -- ignored healthHidden would draw a full bar for a nearly dead enemy.
        assert_that.equal(500, target.health)
    end)

    it("merges in-scene vitals over the roster values", function()
        M = H.bootstrap({ world = function(w)
            w.party = {
                { name = "Alice", health = 10, maxHealth = 100, focus = 5, maxFocus = 50, inScene = true },
                { name = "Bob", health = 80, maxHealth = 100, focus = 5, maxFocus = 50, inScene = false },
            }
        end })

        local party = M.poll.party()
        assert_that.equal(2, #party)
        assert_that.is_true(party[1].inScene)
        assert_that.is_false(party[2].inScene)
    end)

    it("returns an empty party rather than a nil element when solo", function()
        M = H.bootstrap()
        assert_that.same({}, M.poll.party())
    end)

    it("maps the 14-field inventory tuple onto names", function()
        M = H.bootstrap({ world = function(w)
            w.inventory = {
                H.item("Gold Ore", { quantity = 12, value = 40 }),
                H.item("Sword", { quantity = 1, value = 900, createdBy = "Smith" }),
            }
        end })

        local items = M.poll.inventory()
        assert_that.equal(2, #items)
        assert_that.equal("Gold Ore", items[1].name)
        assert_that.equal(12, items[1].quantity)
        assert_that.equal("Smith", items[2].createdBy)
    end)

    it("does not re-read inventory every frame", function()
        M = H.bootstrap({ world = function(w) w.inventory = { H.item("Rock") } end })

        local calls = 0
        local original = ShroudGetInventory
        _G.ShroudGetInventory = function() calls = calls + 1; return original() end

        for _ = 1, 30 do
            H.host.frame(0.016)
            M.poll.inventory()
        end
        -- 30 frames is half a second; the TTL is five.
        assert_that.equal(1, calls, "inventory was polled " .. calls .. " times in half a second")
    end)

    it("hides the under-mouse API on a client older than API 2", function()
        M = H.bootstrap({ apiVersion = 1, world = function(w)
            w.underMouse = { kind = "npc", name = "Guard", description = "", id = 3 }
        end })
        assert_that.nil_(M.poll.underMouse())
    end)
end)
