-- tests/crit_spec.lua -- chat parsing and personal-best tracking.
--
-- The patterns under test are candidates: the real combat text format is client
-- data that is not published, so these specs pin the parser's behaviour for
-- each phrasing it claims to support rather than proving the game emits them.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

describe("crit-tracker", function()
    local M, plugin

    local function build(boot)
        M = H.bootstrap(boot or { world = function(w)
            w.luaPath = "/tmp/sotalua-crit-spec/"
            w.scene.name = "South Fetid Swamp"
            w.target = { name = "Obsidian Wolf", id = 7, dead = false,
                         healthHidden = false, health = 300, maxHealth = 300,
                         focus = 0, maxFocus = 0, buffs = {} }
        end })
        plugin = H.plugin("crit-tracker", M)
        H.installHandlers(M)
        H.host.start()
        return plugin
    end

    before_each(function() os.execute("mkdir -p /tmp/sotalua-crit-spec") end)
    after_each(function()
        H.teardown()
        os.execute("rm -rf /tmp/sotalua-crit-spec")
    end)

    it("rejects ordinary chat before running any pattern", function()
        -- ShroudOnConsoleInput fires for every line, and combat is when the
        -- volume peaks, so the cheap keyword test must come first.
        build()
        assert_that.is_false(plugin.looksLikeCrit("Pet Merchant: We have all the pets you need!"))
        assert_that.is_true(plugin.looksLikeCrit("Your Fireball critically hits for 300"))
    end)

    it("parses the phrasings it claims to support", function()
        build()
        local cases = {
            { "Your Fireball critically hits Obsidian Wolf for 342 damage", "Fireball", 342 },
            { "You critically hit Obsidian Wolf with Death Touch for 517 damage", "Death Touch", 517 },
            { "Critical Hit! Ice Arrow deals 208 damage", "Ice Arrow", 208 },
            { "You hit Obsidian Wolf with Blade Storm for 190 damage (Critical)", "Blade Storm", 190 },
        }
        for _, case in ipairs(cases) do
            local skill, damage = plugin.parse(case[1])
            assert_that.equal(case[2], skill, "skill from: " .. case[1])
            assert_that.equal(case[3], damage, "damage from: " .. case[1])
        end
    end)

    it("returns nothing rather than inventing a number", function()
        build()
        -- The whole point: an unrecognised format records nothing at all.
        assert_that.nil_(plugin.parse("Something critical happened somewhere"))
        assert_that.nil_(plugin.parse("You hit Obsidian Wolf for 40 damage"))
    end)

    it("stores the first sighting quietly", function()
        build()
        H.host.chat("Combat", "", "Your Fireball critically hits Obsidian Wolf for 342 damage")

        assert_that.equal(342, plugin.records()["Fireball"].damage)
        -- Nothing to beat yet; alerting here would fire for every new skill.
        assert_that.nil_(plugin.state.lastAlert)
    end)

    it("alerts only when a stored record is beaten", function()
        build()
        H.host.chat("Combat", "", "Your Fireball critically hits Obsidian Wolf for 342 damage")
        H.host.chat("Combat", "", "Your Fireball critically hits Obsidian Wolf for 200 damage")
        assert_that.nil_(plugin.state.lastAlert, "a weaker hit must not alert")
        assert_that.equal(342, plugin.records()["Fireball"].damage)

        H.host.chat("Combat", "", "Your Fireball critically hits Obsidian Wolf for 999 damage")
        assert_that.truthy(plugin.state.lastAlert)
        assert_that.equal(999, plugin.state.lastAlert.damage)
        assert_that.equal(342, plugin.state.lastAlert.previous)
        assert_that.equal(999, plugin.records()["Fireball"].damage)
        assert_that.is_true(H.host.hasText("NEW BEST"))
    end)

    it("keeps a separate record per skill", function()
        build()
        H.host.chat("Combat", "", "Your Fireball critically hits X for 300 damage")
        H.host.chat("Combat", "", "Your Ice Arrow critically hits X for 100 damage")
        assert_that.equal(300, plugin.records()["Fireball"].damage)
        assert_that.equal(100, plugin.records()["Ice Arrow"].damage)

        local sorted = plugin.sortedRecords()
        assert_that.equal("Fireball", sorted[1].skill, "records sort by damage")
    end)

    it("remembers where and against what", function()
        build()
        H.host.chat("Combat", "", "Your Fireball critically hits Obsidian Wolf for 342 damage")
        local entry = plugin.records()["Fireball"]
        assert_that.equal("South Fetid Swamp", entry.scene)
        assert_that.equal("Obsidian Wolf", entry.target)
    end)

    it("survives a reload with its records intact", function()
        build()
        H.host.chat("Combat", "", "Your Fireball critically hits X for 342 damage")
        H.host.logout()

        -- Saved variables persist; a fresh instance must see the old best and
        -- treat a smaller hit as no record.
        local reloaded = H.plugin("crit-tracker", M)
        H.installHandlers(M)
        H.host.start()
        assert_that.equal(342, reloaded.records()["Fireball"].damage)
    end)

    it("accepts a custom pattern at runtime", function()
        build()
        assert_that.nil_(plugin.parse("CRIT >> Whirlwind >> 1234"))

        M.settings.update("extraPatterns", function(list)
            list[#list + 1] = "CRIT >> (.-) >> (%d+)"
        end)
        local skill, damage = plugin.parse("CRIT >> Whirlwind >> 1234")
        assert_that.equal("Whirlwind", skill)
        assert_that.equal(1234, damage)
    end)

    it("ignores a malformed custom pattern instead of erroring", function()
        build()
        M.settings.update("extraPatterns", function(list)
            list[#list + 1] = "%f"          -- an incomplete pattern item
        end)
        assert_that.no_error(function()
            plugin.parse("Your Fireball critically hits X for 100 damage")
        end)
    end)

    it("logs every line verbatim in capture mode", function()
        build()
        M.settings.set("capture", true)
        H.host.chat("Say", "Bob", "hello there")
        assert_that.is_true(H.host.consoleContains("hello there"))
        assert_that.equal(1, plugin.state.captured)
    end)

    it("writes each crit to the durable log for later analysis", function()
        build()
        H.host.chat("Combat", "", "Your Fireball critically hits Obsidian Wolf for 342 damage")
        M.store.flush()

        local file = io.open("/tmp/sotalua-crit-spec/sotalua-crits.jsonl", "r")
        assert_that.truthy(file, "no crit log was written")
        local body = file:read("*a")
        file:close()
        assert_that.contains(body, '"skill":"Fireball"')
        assert_that.contains(body, '"damage":342')
        assert_that.contains(body, '"scene":"South Fetid Swamp"')
    end)

    it("rejects a capture that swallowed half the sentence", function()
        build()
        -- A greedy pattern can capture an entire clause as the "skill"; a
        -- 48-character ceiling keeps that out of the records table.
        assert_that.nil_(plugin.parse(
            "Your " .. string.rep("very ", 20) .. "long thing critically hits X for 5 damage"))
    end)
end)
