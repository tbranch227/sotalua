-- core/util.lua -- sentinel handling, list normalization, formatting.
--
-- Every core module is a factory taking the shared module table, so the bundler
-- and the test loader instantiate them identically. Dependencies are read
-- lazily (inside functions) so declaration order never matters.

return function(_M)
    local U = {}

    -- The host never returns nil for a failed numeric read; it returns -999.
    -- InvalidStatResult is the documented global holding it, but it only exists
    -- inside the game, so keep a literal fallback for offline use.
    U.INVALID_NUMBER = -999
    U.INVALID_NAMES = { INVALID = true, Invalid = true, None = true, none = true }

    function U.invalidNumber()
        return InvalidStatResult or U.INVALID_NUMBER
    end

    --- True when a host numeric read succeeded.
    function U.isValid(n)
        return type(n) == "number" and n ~= U.invalidNumber()
    end

    --- True when a host string read is a real name rather than a sentinel.
    function U.isValidName(s)
        return type(s) == "string" and s ~= "" and not U.INVALID_NAMES[s]
    end

    --- A valid number, or `fallback` when the host returned a sentinel.
    function U.numberOr(n, fallback)
        if U.isValid(n) then return n end
        return fallback
    end

    --- A valid name, or `fallback` when the host returned a sentinel.
    function U.nameOr(s, fallback)
        if U.isValidName(s) then return s end
        return fallback
    end

    --- Read a field from a host-returned object without risking an error.
    --
    -- The documented data shapes (RuneEffects, PetInfo, GameTime, SceneCap) are
    -- userdata, not tables. That difference matters: reading a missing key from
    -- a table yields nil, but reading a missing field from userdata *throws*.
    -- Clients disagree about which fields exist -- an older build has no
    -- RuneId or IconId on RuneEffects -- so every field read on a host object
    -- has to be guarded or the whole callback dies.
    function U.field(object, name, default)
        if object == nil then return default end
        local ok, value = pcall(function() return object[name] end)
        if not ok or value == nil then return default end
        return value
    end

    --- Read the first field that exists, for names that differ across clients.
    function U.firstField(object, names, default)
        for _, name in ipairs(names) do
            local value = U.field(object, name, nil)
            if value ~= nil then return value end
        end
        return default
    end

    function U.clamp(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    function U.round(v, places)
        local mult = 10 ^ (places or 0)
        return math.floor(v * mult + 0.5) / mult
    end

    --- Fraction in 0..1, guarding the max == 0 case the host can hand back.
    function U.ratio(current, maximum)
        if not U.isValid(current) or not U.isValid(maximum) or maximum <= 0 then
            return 0
        end
        return U.clamp(current / maximum, 0, 1)
    end

    --- Group a number with thousands separators: 1234567 -> "1,234,567".
    function U.comma(n)
        if type(n) ~= "number" then return tostring(n) end
        local sign = n < 0 and "-" or ""
        local whole = tostring(math.floor(math.abs(n)))
        local out = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        out = out:gsub("^,", "")
        return sign .. out
    end

    --- Compact magnitude for HUD text: 1500 -> "1.5k", 2400000 -> "2.4M".
    function U.short(n)
        if type(n) ~= "number" then return tostring(n) end
        local abs = math.abs(n)
        if abs >= 1e9 then return string.format("%.1fB", n / 1e9) end
        if abs >= 1e6 then return string.format("%.1fM", n / 1e6) end
        if abs >= 1e4 then return string.format("%.1fk", n / 1e3) end
        return U.comma(U.round(n))
    end

    --- Seconds to a short duration. The host uses -1 for "indefinite".
    function U.duration(seconds)
        if type(seconds) ~= "number" or seconds < 0 then return "--" end
        seconds = math.floor(seconds + 0.5)
        if seconds >= 3600 then
            return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
        end
        if seconds >= 60 then
            return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
        end
        return seconds .. "s"
    end

    --- Normalize any host "list" return into a plain dense array.
    --
    -- Three shapes come back from the API and they are not interchangeable:
    --   * a table indexable with ipairs (most getters),
    --   * a MoonSharp enumerator function (ShroudListPeriodics),
    --   * a table holding a single nil element, which is what the party getters
    --     return when you are not in a party.
    -- Callers should never have to know which one they got.
    function U.list(value)
        local out = {}
        if value == nil then return out end

        if type(value) == "function" then
            for item in value do
                if item ~= nil then out[#out + 1] = item end
            end
            return out
        end

        if type(value) ~= "table" and type(value) ~= "userdata" then
            return out
        end

        local ok, len = pcall(function() return #value end)
        if ok and len and len > 0 then
            for i = 1, len do
                local item = value[i]
                if item ~= nil then out[#out + 1] = item end
            end
            if #out > 0 then return out end
        end

        -- Fall back to ipairs for userdata that implements iteration but not #.
        local iterated = pcall(function()
            for _, item in ipairs(value) do
                if item ~= nil then out[#out + 1] = item end
            end
        end)
        if not iterated then return out end
        return out
    end

    --- Iterate only the stats the host actually exposes.
    --
    -- ShroudGetStatCount() counts hidden slots too, so a bare 0..count-1 loop
    -- walks straight into -999 / "INVALID" entries. Yields index, name,
    -- description, value.
    function U.stats()
        local count = ShroudGetStatCount and ShroudGetStatCount() or 0
        if not U.isValid(count) then count = 0 end
        local i = -1
        return function()
            while true do
                i = i + 1
                if i >= count then return nil end
                local name = ShroudGetStatNameByNumber(i)
                if U.isValidName(name) then
                    local value = ShroudGetStatValueByNumber(i)
                    if U.isValid(value) then
                        local desc = ShroudGetStatDescriptionByNumber(i)
                        return i, name, U.nameOr(desc, name), value
                    end
                end
            end
        end
    end

    --- Collect the visible stats into a name -> value table.
    function U.statTable()
        local out = {}
        for _, name, _, value in U.stats() do
            out[name] = value
        end
        return out
    end

    --- World position to widget space.
    --
    -- ShroudWorldToScreenPoint returns y in bottom-left screen space, the
    -- opposite of the top-left origin every widget uses. Returns nil when the
    -- point is behind the camera (z <= 0).
    function U.worldToScreen(x, y, z)
        if not ShroudWorldToScreenPoint then return nil end
        local v = ShroudWorldToScreenPoint(x, y, z)
        if not v or not v.x then return nil end
        if v.z and v.z <= 0 then return nil end
        return v.x, (ShroudGetScreenY and ShroudGetScreenY() or 0) - v.y, v.z
    end

    --- Colors must carry the leading '#'. An unparseable string still returns
    --- true from ShroudSetColor and silently paints transparent black, so
    --- normalize before handing anything to the host.
    function U.hex(color, fallback)
        fallback = fallback or "#FFFFFF"
        if type(color) ~= "string" then return fallback end
        local body = color:gsub("^#", "")
        if not body:match("^%x%x%x%x%x%x$") and not body:match("^%x%x%x%x%x%x%x%x$") then
            return fallback
        end
        return "#" .. body:upper()
    end

    --- Blend two hex colors; t=0 gives `from`, t=1 gives `to`.
    function U.mixHex(from, to, t)
        from, to = U.hex(from):sub(2, 7), U.hex(to):sub(2, 7)
        t = U.clamp(t, 0, 1)
        local out = "#"
        for i = 1, 5, 2 do
            local a = tonumber(from:sub(i, i + 1), 16)
            local b = tonumber(to:sub(i, i + 1), 16)
            out = out .. string.format("%02X", math.floor(a + (b - a) * t + 0.5))
        end
        return out
    end

    --- Strip the client's inline markup and channel prefix from a chat line.
    --
    -- Combat text arrives dressed for display, not for parsing:
    --
    --   " to everyone [CombatSelf]: Zealot attacks Practice Dummy and hits,
    --    dealing [FFEB04]64 points of critical damage[-] from Rapid Fire."
    --
    -- The [RRGGBB] and [-] pairs are colour markup, and they land in the middle
    -- of the sentence -- between "dealing" and the number -- so a pattern
    -- written against the visible text cannot match. The leading routing prefix
    -- would also be captured as the attacker's name.
    function U.stripMarkup(message)
        if type(message) ~= "string" then return "" end
        local out = message
            :gsub("%[%x%x%x%x%x%x%]", "")   -- colour open, e.g. [FFEB04]
            :gsub("%[%x%x%x%x%x%x%x%x%]", "")
            :gsub("%[%-%]", "")             -- colour close
        -- Drop a leading "... [Channel]: " routing prefix, but only up to the
        -- first one: a player could type "]: " in a message body.
        out = out:gsub("^%s*[^%[%]]*%[%w+%]:%s*", "")
        return U.trim(out)
    end

    function U.trim(s)
        return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    --- Truncate for fixed-width HUD rows, with an ellipsis when it does not fit.
    -- Plain ASCII dots rather than U+2026: the \u{} escape is Lua 5.3 syntax and
    -- MoonSharp targets 5.2.
    function U.ellipsize(s, maxChars)
        s = tostring(s or "")
        if #s <= maxChars then return s end
        if maxChars <= 3 then return s:sub(1, maxChars) end
        return s:sub(1, maxChars - 3) .. "..."
    end

    function U.split(s, sep)
        local out = {}
        for piece in tostring(s):gmatch("([^" .. (sep or ",") .. "]+)") do
            out[#out + 1] = piece
        end
        return out
    end

    function U.shallowCopy(t)
        local out = {}
        for k, v in pairs(t or {}) do out[k] = v end
        return out
    end

    --- Recursive copy. Used to detach settings tables from the live saved-var
    --- table, which ShroudGetSavedVar hands back by reference.
    function U.deepCopy(value, seen)
        if type(value) ~= "table" then return value end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local out = {}
        seen[value] = out
        for k, v in pairs(value) do
            out[U.deepCopy(k, seen)] = U.deepCopy(v, seen)
        end
        return out
    end

    function U.count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end

    function U.keysSorted(t)
        local out = {}
        for k in pairs(t or {}) do out[#out + 1] = k end
        table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
        return out
    end

    --- Stable sort by a key function. table.sort is not stable, so ties are
    --- broken by original index to stop HUD rows flickering between frames.
    function U.sortBy(list, keyOf, descending)
        local indexed = {}
        for i, item in ipairs(list) do
            indexed[i] = { item = item, key = keyOf(item), order = i }
        end
        table.sort(indexed, function(a, b)
            if a.key ~= b.key then
                if descending then return a.key > b.key end
                return a.key < b.key
            end
            return a.order < b.order
        end)
        local out = {}
        for i, wrapped in ipairs(indexed) do out[i] = wrapped.item end
        return out
    end

    --- Readable one-line dump for console debugging.
    function U.dump(value, depth)
        depth = depth or 2
        if type(value) ~= "table" then
            if type(value) == "string" then return string.format("%q", value) end
            return tostring(value)
        end
        if depth <= 0 then return "{...}" end
        local parts = {}
        for _, k in ipairs(U.keysSorted(value)) do
            parts[#parts + 1] = tostring(k) .. "=" .. U.dump(value[k], depth - 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    return U
end
