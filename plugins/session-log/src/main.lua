-- Session Log -- a rolling history of play sessions.
--
-- Storage is a saved variable rather than a file. The sandbox does allow
-- io.open inside the Lua/ folder, but the host caps a single saved value at
-- 256 KB of JSON and drops anything larger silently, so the history is trimmed
-- to a bounded number of sessions instead of growing without limit. A file
-- would dodge the cap but lose the free per-character namespacing and the
-- automatic flush on logout.
--
-- ShroudServerTime is a formatted UTC string refreshed once per whole second,
-- which makes it the right stamp for something a human will read later;
-- ShroudTime is engine seconds since start and is used for durations.

return function(Core)
    local ui, layout, util, log = Core.ui, Core.layout, Core.util, Core.log

    local MAX_SESSIONS = 40
    local MAX_SCENES = 30

    local addon = Core.addon.start({
        name = "Session Log",
        slug = "session-log",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            sessions = { default = {} },
            showWindow = { default = true, scope = "account" },
        },
    })

    local view = {}
    local current = {
        startedAt = nil,
        startedWall = nil,
        scenes = {},        -- ordered, de-duplicated scene names
        sceneSeen = {},
        xpStart = nil,
        goldStart = nil,
    }

    local function xpTotal()
        local adv = util.numberOr(ShroudGetTotalAdventurerExperience and
            ShroudGetTotalAdventurerExperience(), 0)
        local prod = util.numberOr(ShroudGetTotalProducerExperience and
            ShroudGetTotalProducerExperience(), 0)
        return adv, prod
    end

    local function noteScene(name)
        if not name or name == "" or current.sceneSeen[name] then return end
        current.sceneSeen[name] = true
        current.scenes[#current.scenes + 1] = name
        -- Bound the list: a long session hopping scenes must not be the thing
        -- that pushes the saved value past the host's size limit.
        if #current.scenes > MAX_SCENES then
            table.remove(current.scenes, 1)
        end
    end

    --- Close the open session and append it to the stored history.
    local function closeSession()
        if not current.startedAt then return end

        local adv, prod = xpTotal()
        local entry = {
            started = current.startedWall,
            ended = ShroudServerTime,
            seconds = math.floor(math.max((ShroudTime or 0) - current.startedAt, 0)),
            scenes = util.shallowCopy(current.scenes),
            adventurer = math.max(adv - (current.xpStart and current.xpStart.adv or adv), 0),
            producer = math.max(prod - (current.xpStart and current.xpStart.prod or prod), 0),
            gold = (tonumber(ShroudPlayerGold) or 0) - (current.goldStart or 0),
            character = ShroudGetPlayerName and ShroudGetPlayerName() or "?",
        }

        Core.settings.update("sessions", function(store)
            store[#store + 1] = entry
            while #store > MAX_SESSIONS do table.remove(store, 1) end
        end)

        -- Start a fresh window rather than leaving a half-closed one, so a
        -- disable followed by a logout cannot write the same session twice.
        current.startedAt = ShroudTime or 0
        current.startedWall = ShroudServerTime
        current.xpStart = { adv = adv, prod = prod }
        current.goldStart = tonumber(ShroudPlayerGold) or 0
        current.scenes, current.sceneSeen = {}, {}
    end

    local function render()
        if not view.window then return end

        local elapsed = current.startedAt and ((ShroudTime or 0) - current.startedAt) or 0
        local adv, prod = xpTotal()
        local gainedAdv = current.xpStart and math.max(adv - current.xpStart.adv, 0) or 0
        local gainedProd = current.xpStart and math.max(prod - current.xpStart.prod, 0) or 0
        local gold = (tonumber(ShroudPlayerGold) or 0) - (current.goldStart or 0)

        ui.setText(view.duration, "this session " .. util.duration(elapsed))
        ui.setText(view.earned, string.format("%s adv  %s prod  %s%s gold",
            util.short(gainedAdv), util.short(gainedProd),
            gold >= 0 and "+" or "", util.comma(gold)))
        ui.setText(view.scenes, string.format("%d scene%s: %s",
            #current.scenes, #current.scenes == 1 and "" or "s",
            util.ellipsize(table.concat(current.scenes, ", "), 44)))

        local history = Core.settings.get("sessions") or {}
        local totalSeconds = 0
        for _, entry in ipairs(history) do totalSeconds = totalSeconds + (entry.seconds or 0) end
        ui.setText(view.history, string.format("%d past session%s, %s logged",
            #history, #history == 1 and "" or "s", util.duration(totalSeconds + elapsed)))
    end

    addon.onStart(function()
        local adv, prod = xpTotal()
        current.startedAt = ShroudTime or 0
        current.startedWall = ShroudServerTime
        current.xpStart = { adv = adv, prod = prod }
        current.goldStart = tonumber(ShroudPlayerGold) or 0
        noteScene(ShroudGetCurrentSceneName and ShroudGetCurrentSceneName() or nil)

        if not Core.settings.get("showWindow") then return end

        local window = layout.window({
            id = "session",
            title = "Session Log",
            x = 300, y = 620, width = 280,
            resizable = "horizontal", minSize = 220, maxSize = 540,
        })
        if not window then return end

        view.window = window
        view.duration = window:row("this session 0s", { fontSize = 13 })
        view.earned = window:row("", { fontSize = 12, color = "#FFD98A" })
        view.scenes = window:row("", { fontSize = 10, color = "#A0A0A0" })
        view.history = window:row("", { fontSize = 10, color = "#808080" })
        window:fit()
    end)

    addon.onSceneLoaded(function(sceneName)
        noteScene(sceneName)
    end)

    addon.tick(1.0, render)

    -- Both events are documented flush points, and either can be the last thing
    -- that happens before the addon stops running.
    addon.onLogOut(closeSession)
    addon.onDisable(closeSession)

    addon.command("history", function()
        local history = Core.settings.get("sessions") or {}
        if #history == 0 then
            log.say("no past sessions recorded yet")
            return
        end
        log.say(string.format("%d recorded session(s), newest last:", #history))
        for i = math.max(1, #history - 14), #history do
            local entry = history[i]
            log.say(string.format("  %s  %s  %s adv  %+d gold  [%s]",
                tostring(entry.started or "?"),
                util.duration(entry.seconds or 0),
                util.short(entry.adventurer or 0),
                entry.gold or 0,
                util.ellipsize(table.concat(entry.scenes or {}, ", "), 40)))
        end
    end)

    addon.command("clear", function()
        Core.settings.set("sessions", {})
        log.say("session history cleared")
    end)

    addon.command("close", function()
        closeSession()
        log.say("session closed and recorded")
    end)

    return { current = current, view = view, closeSession = closeSession, render = render }
end
