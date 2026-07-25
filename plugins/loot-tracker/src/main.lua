-- Loot Tracker -- session inventory and gold deltas.
--
-- There is no loot event in the API, so gains are found by diffing
-- ShroudGetInventory() against the previous snapshot. That call is expensive
-- (it builds a 14-field tuple per stack) and the reference is explicit that
-- heavy work belongs off the frame loop, so the diff runs on a periodic through
-- core/timers rather than in ShroudOnUpdate. Periodics fire on schedule even
-- when a frame stalls, which makes them the right tool here.
--
-- Gold is separate: ShroudPlayerGold is a per-frame global, so it costs nothing
-- to read and is sampled with the same tick.

return function(Core)
    local ui, layout, util, poll, log = Core.ui, Core.layout, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "Loot Tracker",
        slug = "loot-tracker",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            rows = { default = 10, scope = "account" },
            pollSeconds = { default = 3, scope = "account" },
            showLosses = { default = true, scope = "account" },
        },
    })

    local view = { rows = {} }
    local session = {
        baseline = nil,       -- name -> quantity at the last diff
        gained = {},          -- name -> net quantity this session
        goldStart = nil,
        gold = 0,
        value = 0,
        startedAt = nil,
    }

    --- Fold the current inventory into the running totals.
    local function diff()
        local counts = poll.inventoryCounts(true)

        if not session.baseline then
            -- The first observation is the starting point, not a haul.
            session.baseline = counts
            return
        end

        local prices = {}
        for _, item in ipairs(poll.inventory()) do prices[item.name] = item.value end

        for name, quantity in pairs(counts) do
            local delta = quantity - (session.baseline[name] or 0)
            if delta ~= 0 then
                session.gained[name] = (session.gained[name] or 0) + delta
                if delta > 0 then
                    session.value = session.value + delta * (prices[name] or 0)
                end
            end
        end
        for name, quantity in pairs(session.baseline) do
            if counts[name] == nil then
                session.gained[name] = (session.gained[name] or 0) - quantity
            end
        end

        session.baseline = counts
    end

    --- Track gold, but only once the host has actually published the global.
    --
    -- ShroudPlayerGold does not exist until the host first pushes it. Treating
    -- a missing value as 0 would set the opening balance to 0 and then report
    -- the player's whole purse as session profit the moment it appears.
    local function sampleGold()
        local gold = poll.player().gold
        if gold == nil then return end
        if not session.goldStart then
            session.goldStart = gold
        end
        session.gold = gold - session.goldStart
    end

    --- Net changes, biggest absolute movement first.
    local function movements()
        local out = {}
        local showLosses = Core.settings.get("showLosses")
        for name, delta in pairs(session.gained) do
            if delta ~= 0 and (showLosses or delta > 0) then
                out[#out + 1] = { name = name, delta = delta }
            end
        end
        return util.sortBy(out, function(entry) return math.abs(entry.delta) end, true)
    end

    local function render()
        if not view.window then return end

        local elapsed = session.startedAt and ((ShroudTime or 0) - session.startedAt) or 0
        ui.setText(view.heading, string.format("session %s", util.duration(elapsed)))

        local goldText
        if session.goldStart == nil then
            goldText = "waiting"   -- the host has not published the gold total
        else
            goldText = (session.gold >= 0 and "+" or "") .. util.comma(session.gold)
        end
        ui.setText(view.gold, string.format("gold %s   loot value ~%s",
            goldText, util.comma(math.floor(session.value))))
        ui.setColor(view.gold, session.gold < 0 and "#E08A8A" or "#FFD98A")

        local entries = movements()
        for i, row in ipairs(view.rows) do
            local entry = entries[i]
            if entry then
                ui.setText(row, string.format("%+5d  %s",
                    entry.delta, util.ellipsize(entry.name, 26)))
                ui.setColor(row, entry.delta > 0 and "#9FE08F" or "#C08A8A")
            else
                ui.setText(row, "")
            end
        end

        if #entries > #view.rows then
            ui.setText(view.overflow, string.format("+%d more item types", #entries - #view.rows))
        else
            ui.setText(view.overflow, "")
        end
    end

    addon.onStart(function()
        session.startedAt = ShroudTime or 0

        local rows = util.clamp(Core.settings.get("rows") or 10, 1, 20)
        local window = layout.window({
            id = "loot",
            title = "Loot Tracker",
            x = 300, y = 400, width = 260,
            resizable = "horizontal", minSize = 200, maxSize = 520,
        })
        if not window then return end

        view.window = window
        view.heading = window:row("session 0s", { fontSize = 11, color = "#A0A0A0" })
        view.gold = window:row("gold +0", { fontSize = 13, color = "#FFD98A" })
        for _ = 1, rows do
            view.rows[#view.rows + 1] = window:row("", { fontSize = 11, height = 14, gap = 0 })
        end
        view.overflow = window:row("", { fontSize = 10, color = "#808080" })
        window:fit()

        -- Take the opening snapshot once the world has settled, so items still
        -- streaming in at login are not mistaken for loot.
        addon.every("baseline", 2.0, function()
            diff()
            Core.timers.cancel("baseline")
        end)
    end)

    -- The expensive part, off the frame loop entirely.
    addon.onStart(function()
        local period = util.clamp(Core.settings.get("pollSeconds") or 3, 1, 60)
        addon.every("scan", period, function()
            diff()
            sampleGold()
        end)
    end)

    addon.tick(0.5, render)

    -- Inventory the player cannot have kept across a scene change is still
    -- theirs; only the cache is stale, so just force the next diff to re-read.
    addon.onSceneLoaded(function()
        poll.inventory(true)
    end)

    addon.command("reset", function()
        session.gained = {}
        session.baseline = nil
        session.value = 0
        session.goldStart = nil
        session.startedAt = ShroudTime or 0
        log.say("loot session reset")
    end)

    addon.command("report", function()
        local entries = movements()
        log.say(string.format("session %s: gold %+d, loot value ~%s, %d item type(s) changed",
            util.duration((ShroudTime or 0) - (session.startedAt or 0)),
            session.gold, util.comma(math.floor(session.value)), #entries))
        for i = 1, math.min(#entries, 25) do
            log.say(string.format("  %+5d  %s", entries[i].delta, entries[i].name))
        end
    end)

    return { session = session, view = view, diff = diff, movements = movements }
end
