-- core/log.lua -- levelled console output with repeat suppression.
--
-- The host auto-disables an addon that raises 8 errors in 10 seconds, and every
-- line goes to the player's chat window. Both facts make unbounded logging
-- actively harmful, so repeated identical messages collapse into a count.

return function(M)
    local L = {}

    L.levels = { debug = 10, info = 20, warn = 30, error = 40, off = 100 }

    local state = {
        name = "addon",
        threshold = L.levels.info,
        seen = {},          -- message -> { count, firstAt, reportedAt }
        window = 30,        -- seconds before an identical message may repeat
        emitted = 0,
    }

    --- Called by core.env once the addon name is known.
    function L.configure(addonName, level)
        state.name = addonName or state.name
        if level then L.setLevel(level) end
    end

    function L.setLevel(level)
        if type(level) == "string" then level = L.levels[level] end
        if type(level) == "number" then state.threshold = level end
    end

    function L.getLevel()
        return state.threshold
    end

    local function now()
        return ShroudTime or os.time()
    end

    local function write(line)
        state.emitted = state.emitted + 1
        if ShroudConsoleLog then
            ShroudConsoleLog(line)
        else
            print(line)
        end
    end

    -- select() rather than table.pack: table.pack is a 5.2 addition and this
    -- code has to run under MoonSharp as well as the offline 5.4 harness.
    local function join(...)
        local chunks = {}
        for i = 1, select("#", ...) do
            local value = select(i, ...)
            if type(value) == "table" then
                chunks[#chunks + 1] = M.util.dump(value)
            else
                chunks[#chunks + 1] = tostring(value)
            end
        end
        return table.concat(chunks, " ")
    end

    local function emit(levelName, levelValue, ...)
        if levelValue < state.threshold then return end

        local body = join(...)
        local key = levelName .. "\1" .. body
        local at = now()

        local entry = state.seen[key]
        if entry then
            entry.count = entry.count + 1
            if at - entry.reportedAt < state.window then return end
            local suppressed = entry.count - entry.shown
            entry.reportedAt = at
            entry.shown = entry.count
            write(string.format("[%s] %s%s (x%d)", state.name, levelName == "info" and "" or levelName:upper() .. ": ", body, suppressed))
            return
        end

        state.seen[key] = { count = 1, shown = 1, reportedAt = at }
        write(string.format("[%s] %s%s", state.name, levelName == "info" and "" or levelName:upper() .. ": ", body))
    end

    function L.debug(...) emit("debug", L.levels.debug, ...) end
    function L.info(...) emit("info", L.levels.info, ...) end
    function L.warn(...) emit("warn", L.levels.warn, ...) end
    function L.error(...) emit("error", L.levels.error, ...) end

    --- Bypass suppression. For output the player explicitly asked for, such as
    --- a dump command, where collapsing duplicates would be wrong.
    function L.say(...)
        write(join(...))
    end

    --- Diagnostics for tests and the api-probe addon.
    function L.stats()
        return { emitted = state.emitted, distinct = M.util.count(state.seen) }
    end

    function L.reset()
        state.seen = {}
        state.emitted = 0
    end

    return L
end
