-- tests/crit_spec.lua -- chat parsing and personal-best tracking.
--
-- Every line used here was captured verbatim from a live client, so these are
-- fixtures rather than guesses. The format is:
--
--   Zealot attacks Death Metal Slime and hits, dealing 254 points of critical
--   damage from Chaos Bolt.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

-- Real lines, exactly as the game printed them.
local REAL = {
    "Zealot attacks Elite Obsidian Elf Archer and hits, dealing 347 points of critical damage from Lightning Storm.",
    "Zealot attacks Death Metal Slime and hits, dealing 48 points of critical damage from Lightning Storm.",
    "Zealot attacks Death Metal Slime and hits, dealing 1 point of critical damage from Fire Arrow.",
    "Zealot attacks Death Metal Slime and hits, dealing 254 points of critical damage from Chaos Bolt.",
    "Zealot attacks Death Metal Slime and hits, dealing 283 points of critical damage from Chaos Bolt.",
    "Zealot attacks Death Metal Slime and hits, dealing 85 points of critical damage from Lightning.",
}

describe("crit-tracker", function()
    local M, plugin

    local function build(boot)
        M = H.bootstrap(boot or { world = function(w)
            w.luaPath = "/tmp/sotalua-crit-spec/"
            w.scene.name = "South Fetid Swamp"
            w.player.name = "Zealot"
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

    it("parses every captured line", function()
        build()
        local expected = {
            { "Lightning Storm", 347, "Elite Obsidian Elf Archer" },
            { "Lightning Storm", 48, "Death Metal Slime" },
            { "Fire Arrow", 1, "Death Metal Slime" },
            { "Chaos Bolt", 254, "Death Metal Slime" },
            { "Chaos Bolt", 283, "Death Metal Slime" },
            { "Lightning", 85, "Death Metal Slime" },
        }
        for index, line in ipairs(REAL) do
            local hit = plugin.parse(line)
            assert_that.truthy(hit, "did not parse: " .. line)
            assert_that.equal(expected[index][1], hit.skill)
            assert_that.equal(expected[index][2], hit.damage)
            assert_that.equal(expected[index][3], hit.target)
            assert_that.equal("Zealot", hit.attacker)
        end
    end)

    it("handles the singular 'point'", function()
        build()
        -- "1 point" rather than "1 points"; a pattern demanding the s silently
        -- drops every 1-damage critical.
        local hit = plugin.parse(REAL[3])
        assert_that.equal(1, hit.damage)
        assert_that.equal("Fire Arrow", hit.skill)
    end)

    it("strips the sentence's trailing full stop from the skill", function()
        build()
        -- The skill sits at the end of the line, so the period comes with it.
        assert_that.equal("Chaos Bolt", plugin.parse(REAL[4]).skill)
        assert_that.equal("Lightning", plugin.parse(REAL[6]).skill)
    end)

    it("treats 'Lightning' and 'Lightning Storm' as different skills", function()
        build()
        H.host.chat("Combat", "", REAL[1])   -- Lightning Storm, 347
        H.host.chat("Combat", "", REAL[6])   -- Lightning, 85
        assert_that.equal(347, plugin.records()["Lightning Storm"].damage)
        assert_that.equal(85, plugin.records()["Lightning"].damage)
    end)

    it("returns nothing rather than inventing a number", function()
        build()
        -- An unrecognised format records nothing at all.
        assert_that.nil_(plugin.parse("Something critical happened somewhere"))
        assert_that.nil_(plugin.parse(
            "Zealot attacks Death Metal Slime and hits, dealing 40 points of damage from Thrust."))
    end)

    it("ignores another player's critical", function()
        -- The combat log is broadcast to everyone nearby, so without an
        -- attacker check a party member's record becomes yours.
        build()
        H.host.chat("Combat", "",
            "Grimwald attacks Death Metal Slime and hits, dealing 9000 points of critical damage from Chaos Bolt.")

        assert_that.nil_(plugin.records()["Chaos Bolt"], "recorded someone else's hit")
        assert_that.equal(1, plugin.state.others)
        assert_that.equal(0, plugin.state.parsed)
    end)

    it("matches a character whose log name is a prefix of the full name", function()
        build({ world = function(w)
            w.luaPath = "/tmp/sotalua-crit-spec/"
            w.player.name = "Zealot Ravenmoor"
        end })
        assert_that.is_true(plugin.isSelf("Zealot"))
        assert_that.is_false(plugin.isSelf("Zeal"), "a partial word must not match")
        assert_that.is_false(plugin.isSelf("Grimwald"))
    end)

    it("honours a manual name override", function()
        build()
        M.settings.set("characterName", "Grimwald")
        assert_that.is_true(plugin.isSelf("Grimwald"))
        assert_that.is_false(plugin.isSelf("Zealot"))
    end)

    it("stores the first sighting quietly", function()
        build()
        H.host.chat("Combat", "", REAL[4])   -- Chaos Bolt, 254

        assert_that.equal(254, plugin.records()["Chaos Bolt"].damage)
        -- Nothing to beat yet; alerting here would fire for every new skill.
        assert_that.nil_(plugin.state.lastAlert)
    end)

    it("alerts only when a stored record is beaten", function()
        build()
        H.host.chat("Combat", "", REAL[4])   -- 254
        H.host.chat("Combat", "",
            "Zealot attacks Death Metal Slime and hits, dealing 83 points of critical damage from Chaos Bolt.")
        assert_that.nil_(plugin.state.lastAlert, "a weaker hit must not alert")
        assert_that.equal(254, plugin.records()["Chaos Bolt"].damage)

        H.host.chat("Combat", "", REAL[5])   -- 283, a new best
        assert_that.truthy(plugin.state.lastAlert)
        assert_that.equal(283, plugin.state.lastAlert.damage)
        assert_that.equal(254, plugin.state.lastAlert.previous)
        assert_that.equal(283, plugin.records()["Chaos Bolt"].damage)
        assert_that.is_true(H.host.hasText("NEW BEST"))
    end)

    it("keeps a separate record per skill", function()
        build()
        H.host.chat("Combat", "", REAL[1])   -- Lightning Storm 347
        H.host.chat("Combat", "", REAL[4])   -- Chaos Bolt 254
        assert_that.equal(347, plugin.records()["Lightning Storm"].damage)
        assert_that.equal(254, plugin.records()["Chaos Bolt"].damage)

        local sorted = plugin.sortedRecords()
        assert_that.equal("Lightning Storm", sorted[1].skill, "records sort by damage")
    end)

    it("remembers the target named in the line, not the current selection", function()
        build()
        -- poll.target() reports Obsidian Wolf, but the line names the Archer.
        -- During a fight the selection has usually moved on by now.
        H.host.chat("Combat", "", REAL[1])
        local entry = plugin.records()["Lightning Storm"]
        assert_that.equal("South Fetid Swamp", entry.scene)
        assert_that.equal("Elite Obsidian Elf Archer", entry.target)
    end)

    it("survives a reload with its records intact", function()
        build()
        H.host.chat("Combat", "", REAL[1])
        H.host.logout()

        -- Saved variables persist; a fresh instance must see the old best and
        -- treat a smaller hit as no record.
        local reloaded = H.plugin("crit-tracker", M)
        H.installHandlers(M)
        H.host.start()
        assert_that.equal(347, reloaded.records()["Lightning Storm"].damage)
    end)

    it("keeps each character's records separate", function()
        -- One install serves any number of characters, and a personal best
        -- belongs to a build, not to the machine.
        build()
        H.host.chat("Combat", "", REAL[1])   -- Zealot: Lightning Storm 347
        assert_that.equal(347, plugin.records()["Lightning Storm"].damage)

        H.host.switchCharacter("Second Avatar")
        local other = H.plugin("crit-tracker", M)
        H.installHandlers(M)
        H.host.start()

        assert_that.nil_(other.records()["Lightning Storm"],
            "the new character inherited the previous one's records")

        -- A weaker hit is that character's own first record, not a failed
        -- attempt on somebody else's.
        H.host.chat("Combat", "", "Second Avatar attacks Death Metal Slime and hits,"
            .. " dealing 12 points of critical damage from Lightning Storm.")
        assert_that.equal(12, other.records()["Lightning Storm"].damage)
    end)

    it("keeps custom patterns shared across characters", function()
        -- Patterns describe the client's text format, not the character, so
        -- they are account-scoped and must survive a switch.
        build()
        M.settings.update("extraPatterns", function(list)
            list[#list + 1] = "CRIT >> (.-) >> (%d+)"
        end)

        H.host.switchCharacter("Second Avatar")
        local other = H.plugin("crit-tracker", M)
        H.installHandlers(M)
        H.host.start()

        local hit = other.parse("CRIT >> Whirlwind >> 50")
        assert_that.truthy(hit, "an account-scoped pattern was lost on switching")
        assert_that.equal("Whirlwind", hit.skill)
    end)

    it("accepts a custom pattern at runtime", function()
        build()
        assert_that.nil_(plugin.parse("CRIT >> Whirlwind >> 1234"))

        M.settings.update("extraPatterns", function(list)
            list[#list + 1] = "CRIT >> (.-) >> (%d+)"
        end)
        local hit = plugin.parse("CRIT >> Whirlwind >> 1234")
        assert_that.equal("Whirlwind", hit.skill)
        assert_that.equal(1234, hit.damage)
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

    it("logs every crit, not only the records, for later analysis", function()
        build()
        H.host.chat("Combat", "", REAL[4])   -- 254, a first sighting
        H.host.chat("Combat", "",
            "Zealot attacks Death Metal Slime and hits, dealing 73 points of critical damage from Chaos Bolt.")
        M.store.flush()

        -- The log is split per character; this one belongs to Zealot.
        local file = io.open("/tmp/sotalua-crit-spec/sotalua-crits-zealot.jsonl", "r")
        assert_that.truthy(file, "no crit log was written")
        local body = file:read("*a")
        file:close()

        -- Both hits are logged even though only the first set a record: the
        -- point of the durable log is the distribution, not the maximum.
        assert_that.contains(body, '"damage":254')
        assert_that.contains(body, '"damage":73')
        assert_that.contains(body, '"skill":"Chaos Bolt"')
        assert_that.contains(body, '"scene":"South Fetid Swamp"')
        assert_that.contains(body, '"target":"Death Metal Slime"')
    end)

    it("rejects a capture that swallowed half the sentence", function()
        build()
        -- A greedy capture can take an entire clause as the skill name; a
        -- 48-character ceiling keeps that out of the records table.
        local runaway = "Zealot attacks X and hits, dealing 5 points of critical damage from "
            .. string.rep("very ", 20) .. "long name."
        assert_that.nil_(plugin.parse(runaway))
    end)
end)
