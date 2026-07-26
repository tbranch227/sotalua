-- Event FX -- screen feedback driven by game events.
--
-- Which events are actually available shapes this entirely. The host pushes
-- four things an addon can react to directly (experience, chat, scene load,
-- emote/FX/sound notifications); everything else has to be *derived* by
-- watching polled state change between frames -- combat mode, health crossing
-- a threshold, a new target id.
--
-- Toast widgets are pooled rather than created per event. Widget ids come from
-- a per-kind free list, so churning them on every experience tick would mean
-- constant create/destroy traffic during a fight for no benefit.

return function(Core)
    local ui, fx, util, poll, log = Core.ui, Core.fx, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "Event FX",
        slug = "event-fx",
        version = "1.0.0",
        settings = {
            xpToasts = { default = true, scope = "account" },
            lowHealthPulse = { default = true, scope = "account" },
            combatFlash = { default = true, scope = "account" },
            sceneBanner = { default = true, scope = "account" },
            targetFlash = { default = true, scope = "account" },
            lowHealthPercent = { default = 30, scope = "account" },
        },
    })

    local TOAST_POOL = 6
    local TOAST_RISE = 70          -- pixels travelled while fading
    local TOAST_SECONDS = 1.8

    local view = { toasts = {}, edges = {} }
    local state = {
        nextToast = 1,
        inCombat = false,
        lastTargetId = nil,
        wasLow = false,
        lastHealth = nil,
    }

    local function screenWidth() return ShroudGetScreenX and ShroudGetScreenX() or 1920 end
    local function screenHeight() return ShroudGetScreenY and ShroudGetScreenY() or 1080 end

    ----------------------------------------------------------------------
    -- Floating text
    ----------------------------------------------------------------------

    --- Show a line of text that rises and fades from the centre of the screen.
    local function toast(text, color)
        local widget = view.toasts[state.nextToast]
        if not widget then return end
        state.nextToast = state.nextToast % TOAST_POOL + 1

        local startX = screenWidth() * 0.5 - 100
        local startY = screenHeight() * 0.45

        ui.setText(widget, text)
        ui.setColor(widget, color or "#FFFFFF")
        ui.setPosition(widget, startX, startY)
        ui.setVisible(widget, true)

        -- Rise and fade are one tween: the alpha is derived from progress, so
        -- the two can never drift out of step.
        fx.tween({
            from = 0, to = 1, duration = TOAST_SECONDS,
            ease = fx.ease.outCubic,
            onUpdate = function(_, eased)
                ui.setPosition(widget, startX, startY - TOAST_RISE * eased)
                -- Hold opacity for the first third, then fade out.
                local visible = eased < 0.33 and 1 or (1 - (eased - 0.33) / 0.67)
                ui.setAlpha(widget, util.clamp(visible, 0, 1))
            end,
            onComplete = function() ui.setVisible(widget, false) end,
        })
    end

    ----------------------------------------------------------------------
    -- Screen-edge pulse
    ----------------------------------------------------------------------

    --- Pulse a red frame around the screen edges.
    --
    -- Four thin panels rather than one big translucent one: a full-screen panel
    -- would tint the whole game view and sit over everything the player is
    -- trying to look at.
    local function pulseEdges(cycles)
        for _, edge in ipairs(view.edges) do
            ui.setVisible(edge, true)
            fx.pulse(edge, 0, 0.55, 0.7, cycles or 3)
        end
    end

    local function hideEdges()
        for _, edge in ipairs(view.edges) do
            ui.setAlpha(edge, 0)
        end
    end

    ----------------------------------------------------------------------
    -- Event wiring
    ----------------------------------------------------------------------

    addon.onExperience(function(kind, amount)
        if not Core.settings.get("xpToasts") then return end
        amount = tonumber(amount) or 0
        if amount <= 0 then return end
        toast(string.format("+%s %s", util.comma(amount),
            kind == "Producer" and "producer" or "adventurer"),
            kind == "Producer" and "#9FD8E0" or "#9FE08F")
    end)

    addon.onSceneLoaded(function(sceneName)
        if not Core.settings.get("sceneBanner") then return end
        if not view.banner then return end

        ui.setText(view.banner, tostring(sceneName or "?"))
        ui.setPosition(view.banner, screenWidth() * 0.5 - 200, screenHeight() * 0.18)
        ui.setVisible(view.banner, true)
        ui.setScale(view.banner, 0.8)

        -- Land rather than arrive: overshoot slightly, then settle.
        fx.scale(view.banner, 0.8, 1.0, 0.45, fx.ease.outBack)
        fx.tween({
            from = 0, to = 1, duration = 3.0,
            onUpdate = function(_, eased)
                ui.setAlpha(view.banner, eased < 0.6 and 1 or (1 - (eased - 0.6) / 0.4))
            end,
            onComplete = function() ui.setVisible(view.banner, false) end,
        })

        -- A scene change invalidates the derived state; nothing carries over.
        state.lastTargetId = nil
        state.wasLow = false
        state.lastHealth = nil
        hideEdges()
    end)

    -- Everything below is derived: the host has no event for entering combat,
    -- losing health, or switching target, so each is a state comparison.
    addon.tick(0.2, function()
        local player = poll.player()

        if Core.settings.get("combatFlash") then
            local inCombat = ShroudGetPlayerCombatMode and ShroudGetPlayerCombatMode() or false
            if inCombat ~= state.inCombat then
                state.inCombat = inCombat
                if view.combat then
                    ui.setText(view.combat, inCombat and "IN COMBAT" or "")
                    ui.setVisible(view.combat, inCombat)
                    if inCombat then
                        ui.setPosition(view.combat, screenWidth() * 0.5 - 60, screenHeight() * 0.28)
                        fx.scale(view.combat, 1.6, 1.0, 0.35, fx.ease.outBack)
                        fx.fade(view.combat, 0, 0.9, 0.35)
                    end
                end
            end
        end

        if Core.settings.get("lowHealthPulse") then
            -- Health has no maximum global, so the threshold is measured
            -- against the highest value seen rather than a true max.
            local health = player.health
            if health then
                state.peak = math.max(state.peak or 0, health)
                local ratio = state.peak > 0 and health / state.peak or 1
                local low = ratio * 100 <= (Core.settings.get("lowHealthPercent") or 30)
                if low and not state.wasLow then
                    pulseEdges(4)
                elseif not low and state.wasLow then
                    hideEdges()
                end
                state.wasLow = low
                state.lastHealth = health
            end
        end

        if Core.settings.get("targetFlash") then
            local target = poll.target()
            local id = target and target.id or nil
            if id ~= state.lastTargetId then
                state.lastTargetId = id
                if id and view.target then
                    ui.setText(view.target, util.ellipsize(target.name, 28))
                    ui.setPosition(view.target, screenWidth() * 0.5 - 100, screenHeight() * 0.34)
                    ui.setVisible(view.target, true)
                    fx.fade(view.target, 0, 1, 0.2, function()
                        fx.tween({
                            from = 1, to = 0, duration = 1.2,
                            onUpdate = function(value) ui.setAlpha(view.target, value) end,
                            onComplete = function() ui.setVisible(view.target, false) end,
                        })
                    end)
                end
            end
        end
    end)

    ----------------------------------------------------------------------
    -- Construction
    ----------------------------------------------------------------------

    addon.onStart(function()
        local width, height = screenWidth(), screenHeight()

        -- Toast pool. Parented to the canvas, not a window: these float over
        -- the game rather than belonging to a panel.
        for _ = 1, TOAST_POOL do
            local widget = ui.text({
                text = "", x = 0, y = 0, width = 200, height = 24, fontSize = 18,
                color = "#FFFFFF", align = TextAnchor and TextAnchor.MiddleCenter or nil,
            })
            if widget then
                ui.setRaycast(widget, false)
                ui.setVisible(widget, false)
                view.toasts[#view.toasts + 1] = widget
            end
        end

        view.banner = ui.text({
            text = "", x = 0, y = 0, width = 400, height = 34, fontSize = 26,
            color = "#FFD98A", align = TextAnchor and TextAnchor.MiddleCenter or nil,
        })
        view.combat = ui.text({
            text = "", x = 0, y = 0, width = 120, height = 22, fontSize = 16,
            color = "#FF7A4A", align = TextAnchor and TextAnchor.MiddleCenter or nil,
        })
        view.target = ui.text({
            text = "", x = 0, y = 0, width = 200, height = 22, fontSize = 15,
            color = "#E0C88A", align = TextAnchor and TextAnchor.MiddleCenter or nil,
        })
        for _, widget in ipairs({ view.banner, view.combat, view.target }) do
            if widget then
                ui.setRaycast(widget, false)
                ui.setVisible(widget, false)
            end
        end

        -- Edge panels: top, bottom, left, right.
        local thickness = 26
        local edges = {
            { x = 0, y = 0, w = width, h = thickness },
            { x = 0, y = height - thickness, w = width, h = thickness },
            { x = 0, y = 0, w = thickness, h = height },
            { x = width - thickness, y = 0, w = thickness, h = height },
        }
        for _, spec in ipairs(edges) do
            local panel = ui.panel({
                x = spec.x, y = spec.y, width = spec.w, height = spec.h,
                color = "#C02020", alpha = 0,
            })
            if panel then
                -- Critical: an edge panel spans the screen. Left raycasting it
                -- would swallow every click along that strip, including the
                -- game's own UI.
                ui.setRaycast(panel, false)
                view.edges[#view.edges + 1] = panel
            end
        end

        log.info("effects ready; /lua _EventFx_test to preview, /lua _EventFx_toggle <name> to switch one off")
    end)

    ----------------------------------------------------------------------
    -- Commands
    ----------------------------------------------------------------------

    addon.command("test", function()
        toast("+1,234 adventurer", "#9FE08F")
        pulseEdges(2)
        if view.banner then
            ui.setText(view.banner, "Effect Preview")
            ui.setPosition(view.banner, screenWidth() * 0.5 - 200, screenHeight() * 0.18)
            ui.setVisible(view.banner, true)
            ui.setAlpha(view.banner, 1)
            fx.scale(view.banner, 0.8, 1.0, 0.45, fx.ease.outBack)
            fx.tween({
                from = 0, to = 1, duration = 2.5,
                onUpdate = function(_, eased)
                    ui.setAlpha(view.banner, eased < 0.6 and 1 or (1 - (eased - 0.6) / 0.4))
                end,
                onComplete = function() ui.setVisible(view.banner, false) end,
            })
        end
        log.say("previewing: toast, edge pulse, banner")
    end)

    addon.command("toggle", function(name)
        local keys = {
            xp = "xpToasts", health = "lowHealthPulse", combat = "combatFlash",
            scene = "sceneBanner", target = "targetFlash",
        }
        local key = keys[tostring(name or ""):lower()]
        if not key then
            log.say("usage: /lua _EventFx_toggle xp|health|combat|scene|target")
            return
        end
        local enabled = not Core.settings.get(key)
        Core.settings.set(key, enabled)
        if key == "lowHealthPulse" and not enabled then hideEdges() end
        log.say(tostring(name) .. " effects " .. (enabled and "on" or "off"))
    end)

    addon.command("status", function()
        log.say(string.format("%d tween(s) running, %d toast slots",
            fx.activeCount(), #view.toasts))
        for _, key in ipairs({ "xpToasts", "lowHealthPulse", "combatFlash",
                               "sceneBanner", "targetFlash" }) do
            log.say(string.format("  %-16s %s", key,
                Core.settings.get(key) and "on" or "off"))
        end
    end)

    return { view = view, state = state, toast = toast, pulseEdges = pulseEdges }
end
