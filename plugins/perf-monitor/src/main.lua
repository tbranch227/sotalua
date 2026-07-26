-- Perf Monitor -- frame pacing, hitches, and managed heap.
--
-- The important detail: ShroudDeltaTime is clamped at the project's Maximum
-- Allowed Timestep (~0.1s), so during a real stall it saturates and reports
-- nothing worse than 100ms. ShroudRealDeltaTime is the unclamped wall-clock
-- delta and is the only global that shows the true length of a long frame. Every
-- measurement here uses it.
--
-- The GC assist uses collectgarbage("step", ms), whose argument is a time
-- budget in milliseconds (default 3, clamped 0.1-50) rather than Lua's usual
-- KB step size. ShroudForceGC and a plain collectgarbage("collect") are full
-- blocking collections that stall for 140-190ms, so neither is used here.

return function(Core)
    local ui, layout, util, log = Core.ui, Core.layout, Core.util, Core.log

    local addon = Core.addon.start({
        name = "Perf Monitor",
        slug = "perf-monitor",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            hitchThreshold = { default = 0.05, scope = "account" },
            gcAssist = { default = false, scope = "account" },
            gcBudgetMs = { default = 3, scope = "account" },
        },
    })

    local SAMPLES = 120          -- roughly two seconds at 60 fps
    local BAR_COUNT = 40

    local state = {
        samples = {},
        cursor = 0,
        hitches = 0,
        worst = 0,
        sinceHitch = 0,
    }

    local view = {}

    local function record(dt)
        state.cursor = state.cursor % SAMPLES + 1
        state.samples[state.cursor] = dt
        if dt > state.worst then state.worst = dt end
    end

    local function summarize()
        local total, peak, count = 0, 0, 0
        for _, dt in ipairs(state.samples) do
            total = total + dt
            if dt > peak then peak = dt end
            count = count + 1
        end
        if count == 0 then return 0, 0, 0 end
        local mean = total / count
        return mean, peak, mean > 0 and (1 / mean) or 0
    end

    --- A coarse sparkline out of text, so the addon ships no artwork.
    local function sparkline()
        local mean = select(1, summarize())
        if mean <= 0 then return "" end
        local scale = math.max(mean * 3, 0.033)
        local out = {}
        local start = state.cursor
        for i = 1, BAR_COUNT do
            local index = (start - BAR_COUNT + i - 1) % SAMPLES + 1
            local dt = state.samples[index]
            if dt then
                local level = util.clamp(math.floor(dt / scale * 4) + 1, 1, 5)
                out[#out + 1] = ({ ".", ":", "|", "#", "@" })[level]
            else
                out[#out + 1] = " "
            end
        end
        return table.concat(out)
    end

    addon.onStart(function()
        local window = layout.window({
            id = "perf",
            title = "Perf Monitor",
            x = 20, y = 20, width = 260,
            resizable = "horizontal", minSize = 200, maxSize = 520,
        })
        if not window then
            log.error("could not create the perf window")
            return
        end

        view.window = window
        view.fps = window:row("fps --")
        view.frame = window:row("frame --")
        view.spark = window:row("", { fontSize = 12, color = "#7FB8FF" })
        view.hitch = window:row("hitches 0")
        view.heap = window:row("heap --")
        window:fit()
    end)

    -- Sampling has to run every frame to see every stall.
    addon.onUpdate(function()
        local dt = ShroudRealDeltaTime or ShroudDeltaTime or 0
        if dt <= 0 then return end
        record(dt)

        local threshold = Core.settings.get("hitchThreshold") or 0.05
        if dt > threshold then
            state.hitches = state.hitches + 1
            state.sinceHitch = 0
        else
            state.sinceHitch = state.sinceHitch + dt
        end
    end)

    -- Redrawing is throttled: updating five text widgets at 120 Hz would cost
    -- more than the thing being measured.
    addon.tick(0.25, function()
        if not view.window then return end
        local mean, peak, fps = summarize()

        ui.setText(view.fps, string.format("fps %.0f   (worst %.0f)", fps, peak > 0 and 1 / peak or 0))
        ui.setText(view.frame, string.format("frame %.1f ms   peak %.1f ms", mean * 1000, peak * 1000))
        ui.setText(view.spark, sparkline())
        ui.setText(view.hitch, string.format("hitches %d   last %s ago",
            state.hitches, util.duration(state.sinceHitch)))

        -- Lua 5.2 style: KB plus the remainder in bytes. The host overrides
        -- collectgarbage, and an older client returns nothing at all from
        -- "count", so this cannot be handed straight to math.floor.
        local kb = tonumber(collectgarbage("count"))
        ui.setText(view.heap, string.format("heap %s   worst frame %.0f ms",
            kb and (util.comma(math.floor(kb)) .. " KB") or "unavailable",
            state.worst * 1000))
    end)

    -- Donate a small, bounded slice of GC work. Incremental by design; a full
    -- collect would itself be a hitch.
    addon.every("gc", 1.0, function()
        if not Core.settings.get("gcAssist") then return end
        local budget = util.clamp(Core.settings.get("gcBudgetMs") or 3, 0.1, 50)
        collectgarbage("step", budget)
    end)

    addon.command("reset", function()
        state.samples, state.cursor = {}, 0
        state.hitches, state.worst, state.sinceHitch = 0, 0, 0
        log.say("perf counters reset")
    end)

    addon.command("gc", function()
        local enabled = not Core.settings.get("gcAssist")
        Core.settings.set("gcAssist", enabled)
        log.say("incremental GC assist " .. (enabled and "on" or "off"))
    end)

    addon.command("report", function()
        local mean, peak, fps = summarize()
        local kb = tonumber(collectgarbage("count"))
        log.say(string.format("fps %.1f, mean frame %.2f ms, peak %.2f ms, %d hitches, heap %s",
            fps, mean * 1000, peak * 1000, state.hitches,
            kb and (util.comma(math.floor(kb)) .. " KB") or "unavailable"))
    end)

    return { state = state, view = view }
end
