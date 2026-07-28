-- tests/dps_spec.lua -- the shared combat parser and the DPS meter.
--
-- Fixtures are the live client's real format: channel prefix and colour markup
-- intact, since that is what the parser actually receives.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

local function line(attacker, target, damage, skill, critical)
    return string.format(
        " to everyone [CombatSelf]: %s attacks %s and hits, dealing %s%d points of %sdamage%s from %s.",
        attacker, target,
        critical and "[FFEB04]" or "", damage,
        critical and "critical " or "",
        critical and "[-]" or "", skill)
end

describe("combat parser", function()
    local M
    before_each(function()
        M = H.bootstrap({ world = function(w) w.player.name = "Zealot" end })
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
        M.combat.install()
        H.installHandlers(M)
    end)
    after_each(H.teardown)

    it("parses an ordinary hit", function()
        local hit = M.combat.parse(line("Zealot", "Practice Dummy", 48, "Disabling Shot"))
        assert_that.truthy(hit)
        assert_that.equal("Zealot", hit.attacker)
        assert_that.equal("Practice Dummy", hit.target)
        assert_that.equal(48, hit.damage)
        assert_that.equal("Disabling Shot", hit.skill)
        assert_that.is_false(hit.critical)
    end)

    it("parses a critical and marks it as one", function()
        local hit = M.combat.parse(line("Zealot", "Practice Dummy", 240, "Multi Shot", true))
        assert_that.equal(240, hit.damage)
        assert_that.is_true(hit.critical)
    end)

    it("keeps ordinary and critical phrasings distinct", function()
        -- "points of damage" must not match a line saying "points of critical
        -- damage", or every critical would be counted twice.
        local normal = M.combat.parse(line("Zealot", "X", 10, "Bow"))
        local crit = M.combat.parse(line("Zealot", "X", 10, "Bow", true))
        assert_that.is_false(normal.critical)
        assert_that.is_true(crit.critical)
    end)

    it("reads a damage number written with thousands separators", function()
        local hit = M.combat.parse(line("Zealot", "X", 0, "Rend")
            :gsub("dealing 0 points", "dealing 12,480 points"))
        assert_that.equal(12480, hit.damage)
    end)

    it("recovers a message delivered in an undocumented argument order", function()
        -- An older build passing the arguments differently would otherwise
        -- fail completely silently, which is the one outcome worth avoiding.
        H.host.rawChat(line("Zealot", "X", 77, "Bow"), "CombatSelf", nil)
        assert_that.equal(1, M.combat.stats.parsed)
    end)

    it("ignores chat that is not combat", function()
        assert_that.nil_(M.combat.parse(" to everyone [System]: Elrich is now online."))
        assert_that.nil_(M.combat.parse("Zealot: watch out"))
    end)

    it("classifies self, pet, party and everyone else", function()
        H.host.world.pet = H.host.shape({ Name = "Shadow", Level = 30 })
        H.host.world.party = {
            { name = "Alice", health = 10, maxHealth = 100, focus = 0, maxFocus = 0, inScene = true },
        }
        M.poll.invalidate()

        assert_that.equal("self", M.combat.classify("Zealot"))
        assert_that.equal("pet", M.combat.classify("Shadow"))
        assert_that.equal("pet", M.combat.classify("Zealot's pet"))
        assert_that.equal("party", M.combat.classify("Alice"))
        assert_that.equal("other", M.combat.classify("Obsidian Wolf"))
    end)

    it("counts the channels it has seen", function()
        H.host.chat("CombatSelf", "", line("Zealot", "X", 5, "Bow"))
        H.host.chat("CombatSelf", "", line("Zealot", "X", 5, "Bow"))
        H.host.chat("System", "", " to everyone [System]: hello")

        local channels = M.combat.channels()
        assert_that.equal("CombatSelf", channels[1].name)
        assert_that.equal(2, channels[1].count)
    end)

    it("dispatches to several subscribers", function()
        local a, b = 0, 0
        M.combat.onDamage(function(hit) a = a + hit.damage end)
        M.combat.onDamage(function(hit) b = b + hit.damage end)
        H.host.chat("CombatSelf", "", line("Zealot", "X", 30, "Bow"))
        assert_that.equal(30, a)
        assert_that.equal(30, b)
    end)
end)

describe("dps-meter", function()
    local M, plugin

    local function build(boot)
        M = H.bootstrap(boot or { world = function(w)
            w.luaPath = "/tmp/sotalua-dps-spec/"
            w.player.name = "Zealot"
        end })
        plugin = H.plugin("dps-meter", M)
        H.installHandlers(M)
        H.host.start()
        return plugin
    end

    local function hit(attacker, damage, skill, critical)
        H.host.chat("CombatSelf", "", line(attacker, "Practice Dummy", damage,
            skill or "Bow", critical))
    end

    before_each(function() os.execute("mkdir -p /tmp/sotalua-dps-spec") end)
    after_each(function()
        H.teardown()
        os.execute("rm -rf /tmp/sotalua-dps-spec")
    end)

    it("accumulates your own damage", function()
        build()
        hit("Zealot", 100)
        H.host.frames(60, 1 / 30)     -- two seconds
        hit("Zealot", 100)

        assert_that.equal(200, plugin.state.total)
        assert_that.equal(200, plugin.state.actors["You"].damage)
        assert_that.equal(2, plugin.state.actors["You"].hits)
    end)

    it("counts criticals separately without double counting damage", function()
        build()
        hit("Zealot", 50)
        hit("Zealot", 240, "Multi Shot", true)

        local you = plugin.state.actors["You"]
        assert_that.equal(290, you.damage)
        assert_that.equal(2, you.hits)
        assert_that.equal(1, you.crits)
    end)

    it("attributes a pet's damage to the pet", function()
        build({ world = function(w)
            w.luaPath = "/tmp/sotalua-dps-spec/"
            w.player.name = "Zealot"
            w.pet = H.host.shape({ Name = "Shadow", Level = 30 })
        end })
        hit("Zealot", 100)
        hit("Shadow", 40)

        assert_that.equal(100, plugin.state.actors["You"].damage)
        assert_that.equal(40, plugin.state.actors["Shadow"].damage)
        assert_that.equal(140, plugin.state.total)
    end)

    it("includes party members", function()
        build({ world = function(w)
            w.luaPath = "/tmp/sotalua-dps-spec/"
            w.player.name = "Zealot"
            w.party = {
                { name = "Alice", health = 10, maxHealth = 100, focus = 0, maxFocus = 0, inScene = true },
            }
        end })
        hit("Zealot", 100)
        hit("Alice", 250)

        assert_that.equal(250, plugin.state.actors["Alice"].damage)
        assert_that.equal(350, plugin.state.total)
    end)

    it("ignores damage dealt to you by enemies", function()
        -- Enemies hitting you use the same sentence shape. Without filtering,
        -- every mob in the room would appear as a damage dealer.
        build()
        hit("Zealot", 100)
        hit("Obsidian Wolf", 999)

        assert_that.nil_(plugin.state.actors["Obsidian Wolf"])
        assert_that.equal(100, plugin.state.total)
        assert_that.equal(1, plugin.state.excluded)
    end)

    it("can be told to count everyone", function()
        build()
        M.settings.set("includeUnknown", true)
        hit("Obsidian Wolf", 999)
        assert_that.equal(999, plugin.state.actors["Obsidian Wolf"].damage)
    end)

    it("computes dps over the fight's duration", function()
        build()
        hit("Zealot", 500)
        -- Four seconds: inside the five-second gap, so this stays one fight.
        H.host.frames(120, 1 / 30)
        hit("Zealot", 500)

        local seconds = plugin.state.lastAt - plugin.state.startedAt
        assert_that.near(4, seconds, 0.5)
        assert_that.near(250, plugin.state.total / seconds, 30)
    end)

    it("splits a fight when the gap is exceeded", function()
        build()
        hit("Zealot", 500)
        H.host.frames(60, 1 / 30)     -- two seconds: same fight
        hit("Zealot", 500)

        H.host.frames(300, 1 / 30)    -- ten seconds: past the gap
        hit("Zealot", 300)

        -- The last hit opens a new fight rather than extending a ten-second one
        -- that was idle for most of its length.
        assert_that.equal(300, plugin.state.total)
        assert_that.equal(1, plugin.state.encounters, "the first fight was not recorded")
    end)

    it("ends a fight after the log goes quiet", function()
        build()
        hit("Zealot", 300)
        H.host.frames(60, 1 / 30)
        hit("Zealot", 300)

        -- Idle past the gap, then render, which closes the encounter.
        H.host.frames(300, 1 / 30)
        plugin.render()

        assert_that.nil_(plugin.state.startedAt, "the fight never ended")
        assert_that.equal(1, plugin.state.encounters)
        assert_that.equal(600, plugin.state.finished.total)
    end)

    it("starts a new fight rather than merging across a long gap", function()
        build()
        hit("Zealot", 100)
        H.host.frames(60, 1 / 30)
        plugin.endEncounter()

        hit("Zealot", 40)
        assert_that.equal(40, plugin.state.total, "the new fight inherited the old total")
    end)

    it("does not record a one-hit fight as infinite dps", function()
        -- A single hit has no duration, so total/seconds would be enormous.
        build()
        hit("Zealot", 5000)
        plugin.endEncounter()
        assert_that.equal(0, plugin.state.encounters)
        assert_that.equal(0, (M.settings.get("best") or {}).dps or 0)
    end)

    it("remembers the best fight", function()
        build()
        hit("Zealot", 1000)
        H.host.frames(150, 1 / 30)    -- five seconds
        hit("Zealot", 1000)
        plugin.endEncounter()

        local best = M.settings.get("best")
        assert_that.truthy(best.dps > 0)
        assert_that.equal(2000, best.total)
    end)

    it("writes each fight to the durable log", function()
        build()
        hit("Zealot", 600)
        H.host.frames(120, 1 / 30)
        hit("Zealot", 600)
        plugin.endEncounter()
        M.store.flush()

        local file = io.open("/tmp/sotalua-dps-spec/sotalua-dps-zealot.jsonl", "r")
        assert_that.truthy(file, "no encounter log was written")
        local body = file:read("*a")
        file:close()
        assert_that.contains(body, '"type":"encounter"')
        assert_that.contains(body, '"total":1200')
    end)

    it("keeps a live window that decays", function()
        build()
        hit("Zealot", 900)
        local _, immediate = plugin.liveWindow()
        assert_that.equal(900, immediate)

        H.host.frames(600, 1 / 30)    -- twenty seconds, past the ten-second window
        local _, later = plugin.liveWindow()
        assert_that.equal(0, later, "the live window never expired")
    end)

    it("closes the fight on a scene change", function()
        build()
        hit("Zealot", 400)
        H.host.frames(60, 1 / 30)
        hit("Zealot", 400)
        H.host.loadScene("Etceter")
        assert_that.nil_(plugin.state.startedAt)
        assert_that.equal(1, plugin.state.encounters)
    end)

    it("says so when no chat reaches it at all", function()
        build()
        plugin.render()
        assert_that.is_true(H.host.hasText("no chat is reaching this addon"))
    end)

    it("says so when chat arrives but nothing parses", function()
        build()
        H.host.chat("CombatSelf", "", " to everyone [CombatSelf]: Zealot"
            .. " obliterates Practice Dummy for 40 points of harm.")
        plugin.render()
        assert_that.is_true(H.host.hasText("no damage recognised"))
    end)

    it("names the attacker it ignored, and the name it knows you by", function()
        -- The failure that looks most like a broken addon: every one of your
        -- own hits filtered out because the log spells your name differently.
        build({ world = function(w)
            w.luaPath = "/tmp/sotalua-dps-spec/"
            w.player.name = "Zealot"
        end })
        hit("Zeal0t", 200)
        plugin.render()

        assert_that.equal(1, plugin.state.excluded)
        assert_that.is_true(H.host.hasText("ignored as not yours"))
        assert_that.is_true(H.host.hasText("Zeal0t"))
        assert_that.is_true(H.host.hasText("Zealot"), "it never says who it thinks you are")
    end)

    it("stops diagnosing once damage is flowing", function()
        build()
        hit("Zealot", 120)
        local _, broken = M.combat.diagnose()
        assert_that.is_false(broken)
    end)

    it("shows who is doing the damage", function()
        build({ world = function(w)
            w.luaPath = "/tmp/sotalua-dps-spec/"
            w.player.name = "Zealot"
            w.party = {
                { name = "Alice", health = 10, maxHealth = 100, focus = 0, maxFocus = 0, inScene = true },
            }
        end })
        hit("Zealot", 300)
        H.host.frames(60, 1 / 30)
        hit("Alice", 100)
        plugin.render()

        assert_that.is_true(H.host.hasText("You"))
        assert_that.is_true(H.host.hasText("Alice"))
    end)
end)
