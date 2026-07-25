-- World Clock -- in-game date and time beside server time.
--
-- ShroudGetGameTime returns Day, Hour (fractional), Month, Year, PeriodOfDay
-- and Season. Day and Month already carry the engine's +1, so adding another
-- would put every date one off; core/poll passes them through untouched and so
-- does this. When game time is unavailable the whole table comes back zeroed,
-- including Day = 0, which poll turns into nil so it can be told apart from a
-- real reading.

return function(Core)
    local ui, layout, util, poll, log = Core.ui, Core.layout, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "World Clock",
        slug = "world-clock",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            use24Hour = { default = true, scope = "account" },
            showServerTime = { default = true, scope = "account" },
        },
    })

    local view = {}

    -- One in-game day is 24 game hours; PeriodOfDay is the game's own label, so
    -- the boundaries here are only used for the countdown, never to relabel it.
    local PERIOD_STARTS = { 5, 8, 18, 21 }   -- dawn, day, dusk, night

    local PERIOD_COLOR = {
        Dawn = "#FFC58A", Day = "#FFE9A8", Dusk = "#E09A7A", Night = "#8AA8E0",
    }

    local function formatHour(hour)
        local whole = math.floor(hour) % 24
        local minutes = math.floor((hour % 1) * 60)
        if Core.settings.get("use24Hour") then
            return string.format("%02d:%02d", whole, minutes)
        end
        local suffix = whole >= 12 and "pm" or "am"
        local twelve = whole % 12
        if twelve == 0 then twelve = 12 end
        return string.format("%d:%02d%s", twelve, minutes, suffix)
    end

    --- Game hours until the next period boundary, converted to real seconds.
    local function untilNextPeriod(hour)
        local next_ = nil
        for _, start in ipairs(PERIOD_STARTS) do
            if start > hour then
                next_ = start
                break
            end
        end
        next_ = next_ or (PERIOD_STARTS[1] + 24)
        local gameHours = next_ - hour
        -- A Novia day is one real hour, so one game hour is 150 real seconds.
        return gameHours * 150
    end

    local function render()
        if not view.window then return end
        local time = poll.gameTime()

        if not time then
            ui.setText(view.time, "game time unavailable")
            ui.setColor(view.time, "#808080")
            ui.setText(view.date, "")
            ui.setText(view.period, "")
        else
            ui.setText(view.time, formatHour(time.hour or 0))
            ui.setColor(view.time, PERIOD_COLOR[time.period] or "#FFFFFF")
            -- Day and Month are used exactly as the host reports them.
            ui.setText(view.date, string.format("day %d, month %d, year %d",
                time.day or 0, time.month or 0, time.year or 0))
            ui.setText(view.period, string.format("%s   %s   next in %s",
                tostring(time.period or "?"), tostring(time.season or "?"),
                util.duration(untilNextPeriod(time.hour or 0))))
        end

        if view.server then
            ui.setText(view.server, "server " .. tostring(ShroudServerTime or "?"))
        end
    end

    addon.onStart(function()
        local window = layout.window({
            id = "clock",
            title = "Time",
            accentColor = "#FFC58A",
            x = 1600, y = 20, width = 210,
            resizable = "horizontal", minSize = 160, maxSize = 400,
        })
        if not window then return end

        view.window = window
        view.time = window:row("--:--", { fontSize = 20 })
        view.date = window:row("", { fontSize = 11, color = "#B0B0B0" })
        view.period = window:row("", { fontSize = 11, color = "#A0A0A0" })
        if Core.settings.get("showServerTime") then
            view.server = window:row("", { fontSize = 10, color = "#808080" })
        end
        window:fit()
    end)

    -- ShroudServerTime only changes once per whole second, and a game minute is
    -- 2.5 real seconds, so twice a second is more than enough resolution.
    addon.tick(0.5, render)

    addon.command("format", function()
        local use24 = not Core.settings.get("use24Hour")
        Core.settings.set("use24Hour", use24)
        log.say("clock is now " .. (use24 and "24-hour" or "12-hour"))
    end)

    addon.command("now", function()
        local time = poll.gameTime()
        if not time then
            log.say("game time unavailable")
            return
        end
        log.say(string.format("%s on day %d of month %d, year %d (%s, %s); server %s",
            formatHour(time.hour or 0), time.day, time.month, time.year,
            tostring(time.period), tostring(time.season), tostring(ShroudServerTime)))
    end)

    return { view = view, render = render, formatHour = formatHour }
end
