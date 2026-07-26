-- tests/fx_spec.lua -- the animation engine and the event-driven effects.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

describe("fx", function()
    local M
    before_each(function()
        M = H.bootstrap()
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
        M.ui.install()
        M.fx.install()
        H.installHandlers(M)
    end)
    after_each(H.teardown)

    it("does nothing per frame when no tween is running", function()
        -- This hook is in ShroudOnUpdate, under the 1 second watchdog. Idle
        -- cost has to be a length check and nothing else.
        assert_that.equal(0, M.fx.activeCount())
        H.host.frames(600, 1 / 60)
        assert_that.equal(0, M.fx.activeCount())
    end)

    it("interpolates a value and lands exactly on the target", function()
        local seen = {}
        M.fx.tween({ from = 0, to = 100, duration = 1.0, ease = M.fx.ease.linear,
                     onUpdate = function(value) seen[#seen + 1] = value end })

        H.host.frames(30, 1 / 60)      -- half a second
        assert_that.truthy(seen[#seen] > 20 and seen[#seen] < 80,
            "midpoint was " .. tostring(seen[#seen]))

        H.host.frames(60, 1 / 60)
        assert_that.equal(100, seen[#seen], "a tween must finish on its target")
        assert_that.equal(0, M.fx.activeCount(), "a finished tween must remove itself")
    end)

    it("fires onComplete exactly once", function()
        local completions = 0
        M.fx.tween({ duration = 0.2, onComplete = function() completions = completions + 1 end })
        H.host.frames(120, 1 / 60)
        assert_that.equal(1, completions)
    end)

    it("repeats a looping tween the requested number of times", function()
        local completions = 0
        M.fx.tween({ duration = 0.1, loops = 3,
                     onComplete = function() completions = completions + 1 end })
        H.host.frames(120, 1 / 60)   -- two seconds, far past three loops
        assert_that.equal(1, completions, "onComplete fires once, after the last loop")
        assert_that.equal(0, M.fx.activeCount())
    end)

    it("returns a shaken widget to exactly where it started", function()
        -- A window the player positioned must not drift because an effect was
        -- interrupted or rounded.
        local panel = M.ui.panel({ x = 300, y = 200, width = 100, height = 50 })
        M.fx.shake(panel, 10, 0.3)

        H.host.frames(6, 1 / 60)
        local midX, midY = M.ui.getPosition(panel)
        assert_that.truthy(midX ~= 300 or midY ~= 200, "the shake never moved the widget")

        H.host.frames(120, 1 / 60)
        local x, y = M.ui.getPosition(panel)
        assert_that.equal(300, x)
        assert_that.equal(200, y)
    end)

    it("restores the resting colour after a flash", function()
        local panel = M.ui.panel({ x = 0, y = 0, color = "#101014" })
        M.fx.flash(panel, "#FF0000", "#101014", 0.3)
        H.host.frames(120, 1 / 60)
        assert_that.equal("#101014", H.host.liveWidgets(UI.Panel)[1].color)
    end)

    it("caps concurrent tweens rather than growing without bound", function()
        for _ = 1, 200 do
            M.fx.tween({ duration = 10 })
        end
        assert_that.truthy(M.fx.activeCount() <= 64,
            "active tweens grew to " .. M.fx.activeCount())
    end)

    it("cancels every tween when the addon is disabled", function()
        M.fx.tween({ duration = 10 })
        M.fx.tween({ duration = 10 })
        assert_that.equal(2, M.fx.activeCount())
        H.host.disable()
        assert_that.equal(0, M.fx.activeCount())
    end)

    it("paces from the clamped delta, so a stall does not skip the animation", function()
        local final
        M.fx.tween({ from = 0, to = 100, duration = 1.0, ease = M.fx.ease.linear,
                     onUpdate = function(value) final = value end })

        -- One enormous frame. ShroudDeltaTime clamps at ~0.1s, so the tween
        -- advances a tenth rather than jumping straight to the end.
        H.host.frame(2.0)
        assert_that.truthy(final < 50, "a stalled frame teleported the tween to " .. tostring(final))
    end)

    it("pingPong returns to where it began", function()
        assert_that.equal(0, M.fx.ease.pingPong(0))
        assert_that.equal(1, M.fx.ease.pingPong(0.5))
        assert_that.near(0, M.fx.ease.pingPong(1), 1e-9)
    end)
end)

describe("event-fx", function()
    local M, plugin

    local function build(boot)
        M = H.bootstrap(boot or {})
        plugin = H.plugin("event-fx", M)
        H.installHandlers(M)
        H.host.start()
        return plugin
    end

    after_each(H.teardown)

    it("floats a toast on an experience gain", function()
        build()
        H.host.gainExperience("Adventurer", 1234)
        assert_that.is_true(H.host.hasText("+1,234 adventurer"))
        assert_that.truthy(M.fx.activeCount() > 0, "the toast never animated")
    end)

    it("reuses its toast pool instead of creating widgets per event", function()
        build()
        local before = H.host.liveWidgetCount()
        for i = 1, 40 do H.host.gainExperience("Adventurer", i) end
        assert_that.equal(before, H.host.liveWidgetCount(),
            "widgets were created per event; ids would churn during a fight")
    end)

    it("shows a banner naming the scene on arrival", function()
        build()
        H.host.loadScene("South Fetid Swamp")
        assert_that.is_true(H.host.hasText("South Fetid Swamp"))
    end)

    it("announces entering and leaving combat", function()
        build()
        H.host.world.player.combat = true
        H.host.frames(30, 1 / 30)
        assert_that.is_true(H.host.hasText("IN COMBAT"))

        H.host.world.player.combat = false
        H.host.frames(30, 1 / 30)
        assert_that.is_false(H.host.hasText("IN COMBAT"))
    end)

    it("names a newly acquired target once", function()
        build()
        H.host.world.target = { name = "Obsidian Wolf", id = 42, dead = false,
                                healthHidden = false, health = 300, maxHealth = 300,
                                focus = 0, maxFocus = 0, buffs = {} }
        H.host.frames(30, 1 / 30)
        assert_that.is_true(H.host.hasText("Obsidian Wolf"))
    end)

    it("never lets an edge panel intercept clicks", function()
        build()
        -- These span the full width and height of the screen. A raycasting
        -- edge would eat every click along that strip, including the game's.
        for _, edge in ipairs(plugin.view.edges) do
            local found
            for _, widget in ipairs(H.host.liveWidgets(UI.Panel)) do
                if widget.id == edge.id then found = widget end
            end
            assert_that.truthy(found, "edge panel missing")
            assert_that.is_false(found.raycast)
        end
    end)

    it("respects a disabled effect", function()
        build()
        M.settings.set("xpToasts", false)
        H.host.gainExperience("Adventurer", 999)
        assert_that.is_false(H.host.hasText("+999 adventurer"))
    end)

    it("survives a full lifecycle with effects mid-flight", function()
        build()
        H.host.gainExperience("Adventurer", 500)
        H.host.loadScene("Etceter")
        plugin.pulseEdges(3)
        H.host.frames(10, 1 / 60)     -- interrupt while animating

        H.host.logout()
        H.host.disable()

        assert_that.equal(0, H.host.liveWidgetCount())
        assert_that.equal(0, M.fx.activeCount())
        for _, line in ipairs(H.host.console()) do
            assert_that.falsy(line:find("ERROR", 1, true), line)
        end
    end)
end)
