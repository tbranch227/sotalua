-- Target Frame -- health, focus and runes for the current target.
--
-- Two things the API forces into the design:
--
-- 1. When ShroudIsTargetHealthHidden() is true the host reports current health
--    equal to max health. Drawing that as a full bar would claim an almost-dead
--    enemy is untouched, so a hidden-health target gets a flat grey bar and the
--    word "hidden" instead of a number.
--
-- 2. ShroudGetTargetId() is the only reliable way to notice a target switch:
--    two mobs of the same name are otherwise indistinguishable. Rune rows are
--    rebuilt on an id change so a stale debuff timer never carries over.

return function(Core)
    local ui, layout, util, poll, env, log = Core.ui, Core.layout, Core.util, Core.poll, Core.env, Core.log

    local addon = Core.addon.start({
        name = "Target Frame",
        slug = "target-frame",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            showFocus = { default = true, scope = "account" },
            runeRows = { default = 6, scope = "account" },
            hideWhenNoTarget = { default = true, scope = "account" },
        },
    })

    local view = { runes = {} }
    local state = { lastId = nil, visible = true }

    local function setVisible(visible)
        if state.visible == visible then return end
        state.visible = visible
        if view.window then view.window:setVisible(visible) end
    end

    local function renderVitals(target)
        local hidden = target.healthHidden
        if hidden then
            -- nil ratio draws the "unknown" bar rather than a full one.
            layout.setBar(view.health, nil, "health hidden")
        else
            local ratio = util.ratio(target.health, target.maxHealth)
            layout.setBar(view.health, ratio,
                string.format("%s / %s", util.short(target.health), util.short(target.maxHealth)),
                layout.vitalColor(ratio))
        end

        if view.focus then
            local hasFocus = util.isValid(target.maxFocus) and target.maxFocus > 0
            if hasFocus then
                local ratio = util.ratio(target.focus, target.maxFocus)
                layout.setBar(view.focus, ratio,
                    string.format("%s / %s", util.short(target.focus), util.short(target.maxFocus)),
                    "#4C7AC8")
            else
                layout.setBar(view.focus, 0, "")
            end
        end
    end

    -- Takes no argument: the rune list comes from the target the host already
    -- resolved, not from the caller's snapshot.
    local function renderRunes()
        local runes = env.HAS_TARGET and poll.targetBuffs() or {}
        -- Shortest remaining first: those are the ones about to matter.
        runes = util.sortBy(runes, function(rune)
            return rune.remaining < 0 and math.huge or rune.remaining
        end)

        for i, row in ipairs(view.runes) do
            local rune = runes[i]
            if rune then
                local timing = rune.remaining >= 0 and util.duration(rune.remaining) or "--"
                ui.setText(row, string.format("%-22s %6s", util.ellipsize(rune.name, 22), timing))
                ui.setColor(row, rune.isDebuff and "#E08A8A" or "#9FE08F")
            else
                ui.setText(row, "")
            end
        end

        if #runes > #view.runes then
            ui.setText(view.runeOverflow, string.format("+%d more", #runes - #view.runes))
        else
            ui.setText(view.runeOverflow, "")
        end
    end

    local function render()
        if not view.window then return end
        local target = poll.target()

        if not target then
            if Core.settings.get("hideWhenNoTarget") then
                setVisible(false)
                return
            end
            setVisible(true)
            ui.setText(view.name, "no target")
            ui.setColor(view.name, "#808080")
            layout.setBar(view.health, 0, "")
            if view.focus then layout.setBar(view.focus, 0, "") end
            for _, row in ipairs(view.runes) do ui.setText(row, "") end
            ui.setText(view.runeOverflow, "")
            state.lastId = nil
            return
        end

        setVisible(true)

        if target.id ~= state.lastId then
            state.lastId = target.id
            -- Clear rune rows immediately on a switch so the old target's
            -- timers never appear against the new one, even for one frame.
            for _, row in ipairs(view.runes) do ui.setText(row, "") end
        end

        ui.setText(view.name, util.ellipsize(target.name, 28) .. (target.dead and "  (dead)" or ""))
        ui.setColor(view.name, target.dead and "#909090" or "#FFFFFF")
        renderVitals(target)
        renderRunes()
    end

    addon.onStart(function()
        if not env.HAS_TARGET then
            log.error("this client is API " .. env.API .. "; Target Frame needs API 1 or newer")
            return
        end

        local rows = util.clamp(Core.settings.get("runeRows") or 6, 0, 12)
        local window = layout.window({
            id = "target",
            title = "Target",
            accentColor = "#B03030",
            x = 700, y = 60, width = 240,
            resizable = "horizontal", minSize = 180, maxSize = 480,
        })
        if not window then return end

        view.window = window
        view.name = window:row("no target", { fontSize = 15 })
        view.health = window:bar({ height = 16 })
        if Core.settings.get("showFocus") then
            view.focus = window:bar({ height = 10, color = "#4C7AC8" })
        end
        for _ = 1, rows do
            view.runes[#view.runes + 1] = window:row("", { fontSize = 11, height = 14, gap = 0 })
        end
        view.runeOverflow = window:row("", { fontSize = 10, color = "#808080" })
        window:fit()
    end)

    -- Ten times a second. Health bars do not need 120 Hz, and every target read
    -- re-resolves the target inside the host.
    addon.tick(0.1, render)

    addon.command("focus", function()
        local showing = not Core.settings.get("showFocus")
        Core.settings.set("showFocus", showing)
        log.say("focus bar " .. (showing and "on" or "off") .. "; /lua reload to apply")
    end)

    addon.command("autohide", function()
        local hiding = not Core.settings.get("hideWhenNoTarget")
        Core.settings.set("hideWhenNoTarget", hiding)
        log.say("auto-hide " .. (hiding and "on" or "off"))
    end)

    return { view = view, state = state, render = render }
end
