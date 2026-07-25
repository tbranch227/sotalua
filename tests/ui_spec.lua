-- tests/ui_spec.lua -- the widget layer, and the frozen quirks it absorbs.
--
-- The mock host reproduces each quirk faithfully, so a regression here means a
-- plugin would misbehave in the real client the same way.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

describe("ui", function()
    local M
    before_each(function()
        M = H.bootstrap()
        -- warn, not error: several assertions here check that the layer reports
        -- a problem the host would otherwise swallow.
        M.env.init({ name = "T", slug = "t", logLevel = "warn" })
        M.ui.install()
        H.installHandlers(M)
    end)
    after_each(H.teardown)

    it("round-trips a position despite the host negating y", function()
        local panel = M.ui.panel({ x = 30, y = 120, width = 100, height = 40 })
        local x, y = M.ui.getPosition(panel)
        assert_that.equal(30, x)
        assert_that.equal(120, y)
    end)

    it("applies pivot before position so the pivot cannot scale it", function()
        -- ShroudSetPivot multiplies the current anchored position. Setting the
        -- pivot after positioning would silently move the widget.
        local panel = M.ui.panel({ x = 200, y = 100, width = 50, height = 50, pivot = { 0.5, 0.5 } })
        local x, y = M.ui.getPosition(panel)
        assert_that.equal(200, x)
        assert_that.equal(100, y)
    end)

    it("refuses to create an image without a texture", function()
        assert_that.nil_(M.ui.image({ x = 0, y = 0 }))
        assert_that.nil_(M.ui.button({ x = 0, y = 0 }))
    end)

    it("routes button colors away from ShroudSetColor and fills all four states", function()
        H.host.world.textureFiles = { ["btn.png"] = true }
        local texture = M.ui.texture("btn.png")
        local button = M.ui.button({ x = 0, y = 0, texture = texture })

        M.ui.setColor(button, "#3366CC")

        -- ShroudSetButtonColor replaces the whole block each call, so all four
        -- states must be written in one pass or three of them end up zeroed.
        local widget = H.host.liveWidgets(UI.Button)[1]
        assert_that.truthy(widget.colors[ButtonMode.Disabled],
            "the last state written must survive; all four are set in sequence")
    end)

    it("names toggle interactability for what it does", function()
        local panel = M.ui.panel({ x = 0, y = 0 })
        local toggle = M.ui.toggle({ parent = panel, x = 0, y = 0 })

        -- The host call is ShroudSetToggleReadonly but its argument is
        -- interactability: true means the player CAN click it.
        M.ui.setToggleInteractable(toggle, false)
        assert_that.is_false(H.host.liveWidgets(UI.Toggle)[1].interactable)

        M.ui.setToggleInteractable(toggle, true)
        assert_that.is_true(H.host.liveWidgets(UI.Toggle)[1].interactable)
    end)

    it("guards the toggle setters against a negative id", function()
        -- The host only bounds-checks the upper end; a negative id indexes its
        -- backing list and throws.
        assert_that.errors(function() ShroudGetToggle(-1) end,
            "the mock must reproduce the host's throw")
        assert_that.no_error(function() M.ui.getToggle({ id = -1, kind = UI.Toggle }) end)
        assert_that.no_error(function() M.ui.setToggle({ id = -1, kind = UI.Toggle }, true) end)
    end)

    it("makes a panel draggable before making it resizable", function()
        -- ShroudSetResizable fails outright unless the drag component is
        -- already attached.
        local panel = M.ui.panel({ x = 0, y = 0, width = 200, height = 100 })
        assert_that.is_true(M.ui.setResizable(panel, "corner", 100, 600))

        local widget = H.host.liveWidgets(UI.Panel)[1]
        assert_that.is_true(widget.draggable)
        assert_that.equal("corner", widget.resizable)
    end)

    it("hides a toggle by hiding its parent panel", function()
        -- ShroudHideObject rejects toggles and inputs outright.
        local panel = M.ui.panel({ x = 0, y = 0, width = 100, height = 40 })
        local toggle = M.ui.toggle({ parent = panel, x = 4, y = 4 })

        assert_that.is_false(ShroudHideObject(toggle.id, UI.Toggle),
            "the mock must reproduce the host's refusal")
        assert_that.is_true(M.ui.setVisible(toggle, false))
        assert_that.is_false(H.host.liveWidgets(UI.Panel)[1].visible)
    end)

    it("skips resizing widgets the host will not resize", function()
        local panel = M.ui.panel({ x = 0, y = 0 })
        local input = M.ui.input({ parent = panel, x = 0, y = 0 })
        assert_that.is_false(M.ui.setSize(input, 200, 30))
    end)

    it("dispatches a click to the right widget", function()
        local clicked = 0
        local panel = M.ui.panel({ x = 0, y = 0, onClick = function() clicked = clicked + 1 end })
        local other = M.ui.panel({ x = 0, y = 60 })

        H.host.clickWidget(panel.id, UI.Panel)
        assert_that.equal(1, clicked)

        H.host.clickWidget(other.id, UI.Panel)
        assert_that.equal(1, clicked, "another widget's click must not reach this handler")
    end)

    it("dispatches hover enter and leave separately", function()
        local events = {}
        local panel = M.ui.panel({
            x = 0, y = 0,
            onOver = function() events[#events + 1] = "in" end,
            onOut = function() events[#events + 1] = "out" end,
        })

        H.host.hoverWidget(panel.id, UI.Panel)
        H.host.unhoverWidget(panel.id, UI.Panel)
        assert_that.same({ "in", "out" }, events)
    end)

    it("reports a toggle change to its own handler", function()
        local seen
        local panel = M.ui.panel({ x = 0, y = 0 })
        local toggle = M.ui.toggle({ parent = panel, x = 0, y = 0,
            onToggle = function(_, isOn) seen = isOn end })

        ShroudSetToggle(toggle.id, true)
        assert_that.is_true(seen)
    end)

    it("destroys every widget it created when the addon is disabled", function()
        local panel = M.ui.panel({ x = 0, y = 0, width = 200, height = 100 })
        M.ui.text({ parent = panel, text = "hello", x = 4, y = 4 })
        M.ui.text({ parent = panel, text = "world", x = 4, y = 24 })
        M.ui.toggle({ parent = panel, x = 4, y = 44 })

        assert_that.equal(4, H.host.liveWidgetCount())
        H.host.disable()
        assert_that.equal(0, H.host.liveWidgetCount(),
            "orphaned widgets stay on screen and ids climb on every /lua reload")
        assert_that.equal(0, M.ui.liveCount())
    end)

    it("reuses freed slots so ids do not climb across reloads", function()
        local first = M.ui.panel({ x = 0, y = 0 })
        local firstId = first.id
        M.ui.destroyAll()

        local second = M.ui.panel({ x = 0, y = 0 })
        assert_that.equal(firstId, second.id)
    end)

    it("reports a missing texture instead of returning a bad id", function()
        local id = M.ui.texture("does-not-exist.png")
        assert_that.equal(-1, id)
        assert_that.is_true(H.host.consoleContains("texture not found"))
    end)

    it("refuses a path that escapes the addon folder", function()
        H.host.world.textureFiles = { ["../../secrets.png"] = true }
        assert_that.equal(-1, M.ui.texture("../../secrets.png"))
    end)
end)

describe("layout", function()
    local M
    before_each(function()
        M = H.bootstrap()
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
        M.settings.define({ windows = { default = {} } })
        M.settings.install()
        M.ui.install()
        M.timers.install("_Test_pump", 0.05)
        M.layout.install({ poll = 0.1, debounce = 0.2 })
        H.installHandlers(M)
    end)
    after_each(function()
        M.layout.reset()
        H.teardown()
    end)

    it("builds a titled window with stacked rows", function()
        local window = M.layout.window({ id = "main", title = "Stats", x = 20, y = 20, width = 200 })
        window:row("Health: 80")
        window:row("Focus: 40")
        window:fit()

        assert_that.is_true(H.host.hasText("Stats"))
        assert_that.is_true(H.host.hasText("Health: 80"))
        assert_that.is_true(H.host.hasText("Focus: 40"))
    end)

    it("restores a saved position on the next session", function()
        ShroudSetSavedVar("windows", { main = { x = 640, y = 300, width = 200 } }, "character")

        local window = M.layout.window({ id = "main", x = 20, y = 20, width = 200 })
        local x, y = M.ui.getPosition(window.panel)
        assert_that.equal(640, x)
        assert_that.equal(300, y)
    end)

    it("persists a placement after the player stops dragging", function()
        local window = M.layout.window({ id = "main", x = 20, y = 20, width = 200 })

        H.host.frames(5, 0.05)          -- establish the baseline observation
        M.ui.setPosition(window.panel, 500, 400)
        H.host.frames(40, 0.05)         -- drag settles, debounce fires

        local stored = ShroudGetSavedVar("windows", "character")
        assert_that.truthy(stored and stored.main, "no placement was written")
        assert_that.equal(500, stored.main.x)
        assert_that.equal(400, stored.main.y)
    end)

    it("saves every window at logout", function()
        local a = M.layout.window({ id = "a", x = 10, y = 10 })
        M.layout.window({ id = "b", x = 20, y = 20 })
        M.ui.setPosition(a.panel, 111, 222)

        H.host.logout()

        local stored = ShroudGetSavedVar("windows", "character")
        assert_that.equal(111, stored.a.x)
        assert_that.equal(20, stored.b.y)
    end)

    it("draws an unknown bar rather than a full one", function()
        local window = M.layout.window({ id = "main", x = 0, y = 0, width = 200 })
        local bar = window:bar({ text = "??" })

        M.layout.setBar(bar, nil, "Hidden")
        -- A hidden-health target reports current == max; a full green bar would
        -- claim the enemy is untouched.
        assert_that.equal("#4A4A55", H.host.liveWidgets(UI.Panel)[3].color)
    end)

    it("scales a bar's fill to the ratio", function()
        local window = M.layout.window({ id = "main", x = 0, y = 0, width = 200 })
        local bar = window:bar({})

        M.layout.setBar(bar, 0.25, "25%")
        local fill = H.host.liveWidgets(UI.Panel)[3]
        assert_that.near(bar.width * 0.25, fill.width, 0.001)
    end)
end)
