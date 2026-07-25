-- core/timers.lua -- periodics and per-frame throttling.
--
-- ShroudRegisterPeriodic takes the *name of a global function* and calls it
-- with no arguments, which means every timer needs a uniquely-named global in
-- the shared environment. Core mints exactly one such global per addon and
-- multiplexes all timers through it, so a plugin with six timers still leaks a
-- single name instead of six.
--
-- Periodics fire independently of frame rate and survive a reload but not a
-- host restart. Anything expensive belongs here rather than in ShroudOnUpdate,
-- which is bounded by the 1 second watchdog.

return function(M)
    local T = {}

    local MIN_PERIOD = 0.01   -- the host refuses to register anything shorter

    local timers = {}         -- name -> { fn, period, repeating }
    local hostName = nil      -- the global name registered with the host
    local pumpPeriod = nil

    local function now()
        return ShroudTime or 0
    end

    --- The single global the host calls. Runs every due timer.
    local function pump()
        for name, timer in pairs(timers) do
            if timer.due <= now() + 1e-6 then
                if timer.repeating then
                    timer.due = now() + timer.period
                else
                    timers[name] = nil
                end
                timer.fn()
            end
        end
    end

    --- Create the multiplexing global and register it once with the host.
    --
    -- `globalName` must be unique across every addon the player has enabled;
    -- the bundler derives it from the plugin slug.
    function T.install(globalName, tickPeriod)
        hostName = globalName
        pumpPeriod = math.max(tickPeriod or 0.25, MIN_PERIOD)
        _G[hostName] = M.env.protect("timers.pump", pump)
        if ShroudRegisterPeriodic then
            local ok = M.env.try("timers.install", ShroudRegisterPeriodic,
                hostName, hostName, pumpPeriod, true)
            if ok == false then
                M.log.warn("could not register the timer pump; periodic work is disabled")
            end
        end
        return T
    end

    --- Schedule `fn` every `period` seconds.
    --
    -- The pump only wakes every tickPeriod seconds, so a period shorter than
    -- that is rounded up in practice; ask for a finer pump if you need one.
    function T.every(name, period, fn)
        if period < MIN_PERIOD then
            M.log.warn("timer", name, "period raised to the host minimum of", MIN_PERIOD)
            period = MIN_PERIOD
        end
        timers[name] = {
            fn = M.env.protect("timer:" .. name, fn),
            period = period,
            repeating = true,
            due = now() + period,
        }
        return name
    end

    --- Run `fn` once after `delay` seconds.
    function T.after(name, delay, fn)
        timers[name] = {
            fn = M.env.protect("timer:" .. name, fn),
            period = delay,
            repeating = false,
            due = now() + math.max(delay, 0),
        }
        return name
    end

    function T.cancel(name)
        local existed = timers[name] ~= nil
        timers[name] = nil
        return existed
    end

    function T.active()
        return M.util.keysSorted(timers)
    end

    --- Tear down the host registration. Wired to ShroudOnDisableScript so a
    --- disabled addon leaves no periodic behind.
    function T.uninstall()
        timers = {}
        if hostName then
            if ShroudRemovePeriodic then
                M.env.try("timers.uninstall", ShroudRemovePeriodic, hostName)
            end
            _G[hostName] = nil
            hostName = nil
        end
    end

    --- Call `fn` at most once every `period` seconds.
    --
    -- For work that belongs in ShroudOnUpdate but should not run at 120 Hz,
    -- such as recomputing HUD text. Returns a function to call every frame.
    function T.throttle(period, fn)
        local last = -math.huge
        return function(...)
            local at = now()
            if at - last < period then return end
            last = at
            return fn(...)
        end
    end

    -- Resolved once: 5.1 and MoonSharp expose `unpack`, 5.2+ moved it to
    -- table.unpack. Selecting inline with `a and a(...) or b(...)` would be a
    -- trap, since unpacking an empty list yields nothing and falls through to
    -- the wrong branch.
    local unpackList = table.unpack or unpack

    --- Call `fn` only after `delay` seconds have passed with no further calls.
    --
    -- Used for reacting to a window drag once the player lets go, rather than
    -- writing a saved variable on every frame of the drag.
    function T.debounce(name, delay, fn)
        return function(...)
            local args = { ... }
            local n = select("#", ...)
            T.after(name, delay, function()
                fn(unpackList(args, 1, n))
            end)
        end
    end

    --- Drive the pump directly. Tests and the offline harness only.
    function T.pumpNow() pump() end

    return T
end
