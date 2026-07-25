-- XP Tracker -- session experience, rate, and attenuation warning.
--
-- ShroudOnExperienceGain fires with ("Adventurer"|"Producer", amount) and the
-- amount is always positive. ShroudOnExperienceChanged is documented as an
-- alias of the same event, so core/events routes both names to one stream;
-- subscribing to both here would double every number.
--
-- Attenuation is the thing worth surfacing: while
-- ShroudGetAttenuationAdventurerStatus() is true you are earning at a reduced
-- rate, and the stock UI does not make that obvious.

return function(Core)
    local ui, layout, util, log = Core.ui, Core.layout, Core.util, Core.log

    local addon = Core.addon.start({
        name = "XP Tracker",
        slug = "xp-tracker",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            lifetime = { default = { adventurer = 0, producer = 0, seconds = 0 } },
            showProducer = { default = true, scope = "account" },
        },
    })

    local view = {}
    local session = {
        adventurer = 0,
        producer = 0,
        startedAt = nil,
        lastGainAt = nil,
        idleSeconds = 0,
    }

    --- Seconds of active play this session. Time spent with no experience at all
    --- still counts; this is wall-clock since login, not a combat timer.
    local function elapsed()
        if not session.startedAt then return 0 end
        return math.max((ShroudTime or 0) - session.startedAt, 0)
    end

    local function perHour(total)
        local seconds = elapsed()
        if seconds < 30 then return nil end   -- too little data to extrapolate
        return total / seconds * 3600
    end

    local function rateText(total)
        local rate = perHour(total)
        if not rate then return "measuring..." end
        return util.short(rate) .. "/hr"
    end

    local function render()
        if not view.window then return end

        local attenuatedAdv = ShroudGetAttenuationAdventurerStatus and
            ShroudGetAttenuationAdventurerStatus() or false
        local attenuatedProd = ShroudGetAttenuationProducerStatus and
            ShroudGetAttenuationProducerStatus() or false

        ui.setText(view.session, "session " .. util.duration(elapsed()))

        ui.setText(view.adventurer, string.format("adv  %s   %s",
            util.short(session.adventurer), rateText(session.adventurer)))
        ui.setColor(view.adventurer, attenuatedAdv and "#FF9A5C" or "#9FE08F")

        if view.producer then
            ui.setText(view.producer, string.format("prod %s   %s",
                util.short(session.producer), rateText(session.producer)))
            ui.setColor(view.producer, attenuatedProd and "#FF9A5C" or "#9FE08F")
        end

        local pooledAdv = util.numberOr(ShroudGetPooledAdventurerExperience and
            ShroudGetPooledAdventurerExperience(), 0)
        local pooledProd = util.numberOr(ShroudGetPooledProducerExperience and
            ShroudGetPooledProducerExperience(), 0)
        ui.setText(view.pooled, string.format("pool %s adv / %s prod",
            util.short(pooledAdv), util.short(pooledProd)))

        if attenuatedAdv or attenuatedProd then
            local which = attenuatedAdv and (attenuatedProd and "adventurer + producer" or "adventurer")
                or "producer"
            ui.setText(view.warning, "ATTENUATED: " .. which)
            ui.setColor(view.warning, "#FF7A4A")
        else
            ui.setText(view.warning, "")
        end

        local lifetime = Core.settings.get("lifetime") or {}
        ui.setText(view.lifetime, string.format("tracked total %s adv / %s prod",
            util.short((lifetime.adventurer or 0) + session.adventurer),
            util.short((lifetime.producer or 0) + session.producer)))
    end

    local function persist()
        Core.settings.update("lifetime", function(store)
            store.adventurer = (store.adventurer or 0) + session.adventurer
            store.producer = (store.producer or 0) + session.producer
            store.seconds = (store.seconds or 0) + elapsed()
        end)
        -- Fold into the stored totals and restart, so a later flush cannot
        -- double-count what was just written.
        session.adventurer, session.producer = 0, 0
        session.startedAt = ShroudTime or 0
    end

    addon.onStart(function()
        session.startedAt = ShroudTime or 0

        local window = layout.window({
            id = "xp",
            title = "XP Tracker",
            x = 20, y = 620, width = 240,
            resizable = "horizontal", minSize = 190, maxSize = 460,
        })
        if not window then return end

        view.window = window
        view.session = window:row("session 0s", { fontSize = 11, color = "#A0A0A0" })
        view.adventurer = window:row("adv  0", { fontSize = 13 })
        if Core.settings.get("showProducer") then
            view.producer = window:row("prod 0", { fontSize = 13 })
        end
        view.pooled = window:row("", { fontSize = 11, color = "#A0A0A0" })
        view.warning = window:row("", { fontSize = 12 })
        view.lifetime = window:row("", { fontSize = 10, color = "#808080" })
        window:fit()
    end)

    addon.onExperience(function(kind, amount)
        amount = tonumber(amount) or 0
        if amount <= 0 then return end
        if kind == "Producer" then
            session.producer = session.producer + amount
        else
            session.adventurer = session.adventurer + amount
        end
        session.lastGainAt = ShroudTime or 0
    end)

    addon.tick(0.5, render)

    -- Fold the session into the persisted lifetime totals at logout and on
    -- disable, the two moments the host is about to write saved variables.
    addon.onLogOut(persist)
    addon.onDisable(persist)

    addon.command("reset", function()
        session.adventurer, session.producer = 0, 0
        session.startedAt = ShroudTime or 0
        log.say("session experience reset")
    end)

    addon.command("clear", function()
        Core.settings.set("lifetime", { adventurer = 0, producer = 0, seconds = 0 })
        log.say("tracked lifetime totals cleared")
    end)

    addon.command("report", function()
        log.say(string.format("session %s: %s adventurer (%s), %s producer (%s)",
            util.duration(elapsed()),
            util.comma(session.adventurer), rateText(session.adventurer),
            util.comma(session.producer), rateText(session.producer)))
    end)

    return { session = session, view = view, render = render, persist = persist }
end
