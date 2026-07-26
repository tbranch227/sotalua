-- core/store.lua -- durable event log on disk, for data that outlives a session.
--
-- Why this exists rather than saved variables: ShroudSetSavedVar is a key-value
-- store the host caps at 256 KB per value and rewrites wholesale, which makes
-- it right for settings and wrong for history. A file under Lua/ has no such
-- cap and can be appended to forever.
--
-- Why this rather than a database or an API: neither is reachable. The sandbox
-- permits no network access at all, and MoonSharp is a pure C# interpreter with
-- no way to load a native library, so there is no SQLite binding and no HTTP.
-- The supported route off the machine is a file that an external process reads;
-- tools/ingest.py does exactly that, into a real SQLite database.
--
-- The format is JSON Lines: one self-contained JSON object per line. That
-- survives a partial write (a torn final line is discarded, not corrupting) and
-- can be appended without reading what came before.

return function(M)
    local S = {}

    local DEFAULT_MAX_BYTES = 1024 * 1024
    local MAX_BUFFER = 400          -- events held in memory between flushes

    local config = {
        name = "events",
        maxBytes = DEFAULT_MAX_BYTES,
        flushSeconds = 30,
    }

    local buffer = {}
    local stats = { appended = 0, written = 0, dropped = 0, failures = 0 }
    local installed = false

    -- One install serves any number of characters, so the log is split by
    -- character rather than tagged and shared. A shared file would let a busy
    -- character rotate away another's history, and would make handing one
    -- character's data to somebody else impossible.
    --
    -- The name is remembered rather than read at write time: ShroudGetPlayerName
    -- returns "none" once the player is gone, and the most valuable record of
    -- all -- the session summary -- is written at logout.
    local character = nil

    ----------------------------------------------------------------------
    -- JSON encoding
    ----------------------------------------------------------------------

    local ESCAPES = {
        ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
        ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
    }

    local function encodeString(value)
        local escaped = tostring(value):gsub('[%c"\\]', function(char)
            return ESCAPES[char] or string.format("\\u%04x", char:byte())
        end)
        return '"' .. escaped .. '"'
    end

    local function encodeNumber(value)
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"   -- NaN and infinity are not JSON
        end
        if value == math.floor(value) and math.abs(value) < 1e15 then
            return string.format("%d", value)
        end
        -- %.14g keeps enough precision to round-trip a double without the
        -- trailing noise that %f produces.
        return string.format("%.14g", value)
    end

    local encodeValue

    local function isArray(t)
        local count = 0
        for key in pairs(t) do
            if type(key) ~= "number" then return false end
            count = count + 1
        end
        return count == #t
    end

    encodeValue = function(value, depth)
        depth = (depth or 0) + 1
        if depth > 12 then return "null" end   -- cyclic or absurdly nested

        local kind = type(value)
        if value == nil then return "null" end
        if kind == "boolean" then return tostring(value) end
        if kind == "number" then return encodeNumber(value) end
        if kind == "string" then return encodeString(value) end
        if kind ~= "table" then return "null" end

        local parts = {}
        if isArray(value) then
            for _, item in ipairs(value) do
                parts[#parts + 1] = encodeValue(item, depth)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for _, key in ipairs(M.util.keysSorted(value)) do
            parts[#parts + 1] = encodeString(key) .. ":" .. encodeValue(value[key], depth)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    S.encode = encodeValue

    ----------------------------------------------------------------------
    -- Paths
    ----------------------------------------------------------------------

    --- Make a character name safe to embed in a filename.
    -- Names may contain spaces ("First Last") and are not otherwise constrained.
    local function slugify(name)
        local out = tostring(name or ""):gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
        if out == "" then return "unknown" end
        return out:lower():sub(1, 40)
    end

    --- The character currently being logged for.
    function S.character()
        return character or "unknown"
    end

    --- Adopt the live character, flushing anything still queued for the old one.
    --
    -- A player can log out and back in as somebody else without restarting the
    -- client, so this cannot be resolved once and forgotten. Called before every
    -- append, never from flush, so the two cannot recurse.
    local function syncCharacter()
        local live = M.util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), nil)
        if not live or live == character then return end
        if character and #buffer > 0 then
            -- Queued lines belong to the previous character's file.
            S.flush()
        end
        character = live
    end

    --- The log file's absolute path, or nil before the host publishes the path.
    --
    -- Flat in the Lua folder rather than a subdirectory: io.open cannot create
    -- directories, and writing to the Lua root is confirmed to work.
    function S.path(suffix)
        return M.env.luaFile(
            "sotalua-" .. config.name .. "-" .. slugify(character) .. (suffix or "") .. ".jsonl")
    end

    ----------------------------------------------------------------------
    -- Writing
    ----------------------------------------------------------------------

    function S.configure(opts)
        opts = opts or {}
        config.name = opts.name or config.name
        config.maxBytes = opts.maxBytes or config.maxBytes
        config.flushSeconds = opts.flushSeconds or config.flushSeconds
        return S
    end

    --- Queue an event. Nothing touches the disk until a flush.
    --
    -- Every record carries the wall-clock server time and the character, so a
    -- line remains meaningful after being merged with other characters' logs.
    function S.append(eventType, fields)
        syncCharacter()

        if #buffer >= MAX_BUFFER then
            -- Drop rather than grow without bound: an addon that cannot write
            -- must not become an addon that exhausts memory.
            stats.dropped = stats.dropped + 1
            return false
        end

        local record = {
            type = tostring(eventType),
            at = ShroudServerTime or "",
            t = ShroudTime or 0,
            -- The remembered name, not a fresh read: this record may be written
            -- at logout, when the live getter already reports no player.
            char = S.character(),
        }
        for key, value in pairs(fields or {}) do
            if record[key] == nil then record[key] = value end
        end

        buffer[#buffer + 1] = encodeValue(record)
        stats.appended = stats.appended + 1
        return true
    end

    --- Rotate when the file grows past the cap, keeping one previous generation.
    local function rotateIfNeeded(path)
        local file = io.open(path, "r")
        if not file then return end
        local size = file:seek("end")
        file:close()
        if size < config.maxBytes then return end

        local previous = S.path(".1")
        if previous then
            -- os.rename is permitted inside the Lua folder.
            pcall(os.remove, previous)
            local ok = pcall(os.rename, path, previous)
            if not ok then pcall(os.remove, path) end
        end
        M.log.debug("store: rotated", path)
    end

    --- Write buffered events to disk.
    function S.flush()
        if #buffer == 0 then return true end

        local path = S.path()
        if not path then
            -- ShroudLuaPath is not published immediately after a reload; keep
            -- the events queued and try again on the next flush.
            return false
        end

        rotateIfNeeded(path)

        local file = io.open(path, "a")
        if not file then
            -- Append is the normal case; fall back to a rewrite if the host
            -- refuses the mode rather than losing the data outright.
            local existing = ""
            local reader = io.open(path, "r")
            if reader then
                existing = reader:read("*a") or ""
                reader:close()
            end
            file = io.open(path, "w")
            if not file then
                stats.failures = stats.failures + 1
                M.log.warn("store: could not open", path)
                return false
            end
            file:write(existing)
        end

        local payload = table.concat(buffer, "\n") .. "\n"
        local ok = pcall(function() file:write(payload) end)
        file:close()

        if not ok then
            stats.failures = stats.failures + 1
            return false
        end

        stats.written = stats.written + #buffer
        buffer = {}
        return true
    end

    ----------------------------------------------------------------------
    -- Reading
    ----------------------------------------------------------------------

    --- Read back the last `limit` raw lines, newest last.
    function S.tail(limit)
        local path = S.path()
        if not path then return {} end
        local file = io.open(path, "r")
        if not file then return {} end

        local lines = {}
        for line in file:lines() do
            if line ~= "" then
                lines[#lines + 1] = line
                if limit and #lines > limit then table.remove(lines, 1) end
            end
        end
        file:close()
        return lines
    end

    function S.stats()
        local out = M.util.shallowCopy(stats)
        out.buffered = #buffer
        out.character = S.character()
        out.path = S.path() or "(path not published yet)"
        return out
    end

    --- Adopt a character explicitly. For the login path, where an addon knows
    --- who it is before the first event is appended.
    function S.setCharacter(name)
        local valid = M.util.nameOr(name, nil)
        if not valid or valid == character then return false end
        if character and #buffer > 0 then S.flush() end
        character = valid
        return true
    end

    --- Delete the log and its rotated generation.
    function S.clear()
        buffer = {}
        for _, suffix in ipairs({ "", ".1" }) do
            local path = S.path(suffix)
            if path then pcall(os.remove, path) end
        end
        return true
    end

    --- Flush periodically and at every documented shutdown point.
    function S.install()
        if installed then return S end
        installed = true
        M.timers.every("store.flush", config.flushSeconds, S.flush)
        M.events.on("ShroudOnLogOut", S.flush, "store.flushOnLogout")
        M.events.on("ShroudOnDisableScript", S.flush, "store.flushOnDisable")
        return S
    end

    return S
end
