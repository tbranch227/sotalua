-- core/combat.lua -- the combat log, parsed once for everyone.
--
-- There is no combat API. No damage event, no damage getter, nothing that
-- attributes a hit to a skill or an actor. The only channel carrying any of it
-- is ShroudOnConsoleInput, so every combat feature in this suite is downstream
-- of the same fragile string parsing, and it lives here rather than being
-- copied into each addon that needs it.
--
-- The confirmed live format, markup and channel prefix intact:
--
--   " to everyone [CombatSelf]: Zealot attacks Practice Dummy and hits,
--    dealing [FFEB04]240 points of critical damage[-] from Multi Shot."

return function(M)
    local C = {}

    -- Names are matched with a restricted class rather than ".-" so a match
    -- cannot begin inside the channel prefix: "[CombatSelf]:" contains brackets
    -- and a colon, none of which this admits.
    local NAME = "[%a][%w%s'%-%.]-"

    -- Critical first: "points of critical damage" and "points of damage" are
    -- disjoint, but ordering makes the intent explicit rather than incidental.
    local PATTERNS = {
        {
            pattern = "(" .. NAME .. ") attacks (" .. NAME
                .. ") and hits, dealing ([%d,]+) points? of critical damage from (.+)$",
            captures = { "attacker", "target", "damage", "skill" },
            critical = true,
        },
        {
            pattern = "(" .. NAME .. ") attacks (" .. NAME
                .. ") and hits, dealing ([%d,]+) points? of damage from (.+)$",
            captures = { "attacker", "target", "damage", "skill" },
            critical = false,
        },
    }

    local extra = {}                -- runtime-added patterns
    local names = { character = nil, pet = nil, trackPet = true }
    local subscribers = {}
    local installed = false

    -- `calls` counts every invocation of the chat callback, `lines` only those
    -- that arrived with a usable string. The two are separate on purpose: if
    -- the host is calling us but nothing is being counted, the argument shape
    -- is wrong, and no amount of pattern work would ever fix it.
    C.stats = {
        calls = 0, lines = 0, parsed = 0, unmatched = 0, channels = {},
        argShape = nil,        -- types of the first call, as a string
        lastLine = nil,        -- last chat line seen, markup stripped
        lastDamageLine = nil,  -- last line that looked like damage but did not parse
    }

    ----------------------------------------------------------------------
    -- Parsing
    ----------------------------------------------------------------------

    local function tidySkill(name)
        name = M.util.trim(tostring(name or ""))
        name = name:gsub("^[Tt]he%s+", ""):gsub("[%.,!:;]+$", "")
        if name == "" or #name > 48 then return nil end
        return name
    end

    --- Parse one chat line into a damage event, or nil.
    --
    -- Returns { attacker, target, damage, skill, critical }.
    function C.parse(raw)
        local message = M.util.stripMarkup(raw)
        if message == "" then return nil end

        local candidates = {}
        for _, entry in ipairs(PATTERNS) do candidates[#candidates + 1] = entry end
        for _, entry in ipairs(extra) do candidates[#candidates + 1] = entry end

        for _, entry in ipairs(candidates) do
            local ok, a, b, c, d = pcall(string.match, message, entry.pattern)
            if ok and a then
                local found = { a, b, c, d }
                local fields = {}
                for index, name in ipairs(entry.captures) do fields[name] = found[index] end

                -- Thousands separators appear once hits get large enough, and
                -- dropping exactly the biggest hits is the worst possible
                -- failure for a meter that reports peaks.
                local digits = tostring(fields.damage or ""):gsub(",", "")
                local damage = tonumber(digits)
                local skill = tidySkill(fields.skill)
                if skill and damage and damage > 0 then
                    return {
                        attacker = fields.attacker and M.util.trim(fields.attacker) or nil,
                        target = fields.target and M.util.trim(fields.target) or nil,
                        damage = damage,
                        skill = skill,
                        critical = entry.critical == true,
                    }
                end
            end
        end
        return nil
    end

    --- Add a pattern at runtime. `captures` names each capture in order.
    function C.addPattern(pattern, captures, critical)
        local ok = pcall(string.match, "probe", pattern)
        if not ok then return false end
        extra[#extra + 1] = {
            pattern = pattern,
            captures = captures or { "skill", "damage" },
            critical = critical == true,
        }
        return true
    end

    ----------------------------------------------------------------------
    -- Attribution
    ----------------------------------------------------------------------

    --- Override the names used to classify an attacker.
    function C.setNames(opts)
        opts = opts or {}
        if opts.character ~= nil then names.character = opts.character end
        if opts.pet ~= nil then names.pet = opts.pet end
        if opts.trackPet ~= nil then names.trackPet = opts.trackPet end
    end

    local function myName()
        if names.character and names.character ~= "" then return names.character end
        return M.util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), nil)
    end

    --- The pet's name, remembered across the session.
    --
    -- ShroudGetPetInfo returns nil the moment a pet is dismissed or dies, and a
    -- damage line can still be in flight, so the last known name is kept.
    local rememberedPet = nil
    function C.petName()
        if names.pet and names.pet ~= "" then return names.pet end
        local pet = M.poll.pet()
        local live = pet and M.util.nameOr(M.util.field(pet, "Name", nil), nil)
        if live then rememberedPet = live end
        return rememberedPet
    end

    --- Classify an attacker as "self", "pet", "party" or "other".
    --
    -- Pet is tested before self: a possessive attacker like "Zealot's pet"
    -- begins with the player's own name and would otherwise be claimed as self.
    function C.classify(attacker)
        if not attacker or attacker == "" then return "self" end
        local lowered = attacker:lower()

        if names.trackPet then
            local pet = C.petName()
            if pet and lowered == pet:lower() then return "pet" end
            local mine = myName()
            if mine and lowered:sub(1, #mine + 2) == mine:lower() .. "'s" then
                return "pet"
            end
        end

        local mine = myName()
        if mine then
            local b = mine:lower()
            if lowered == b
                or lowered:sub(1, #b + 1) == b .. " "
                or b:sub(1, #lowered + 1) == lowered .. " " then
                return "self"
            end
        end

        for _, member in ipairs(M.poll.party()) do
            if member.name and member.name:lower() == lowered then return "party" end
        end

        return "other"
    end

    ----------------------------------------------------------------------
    -- Dispatch
    ----------------------------------------------------------------------

    --- The longest string among the arguments, or nil if there is none.
    --
    -- Used only to recover a message from a callback whose arguments did not
    -- arrive in the documented order. A chat line is far longer than a channel
    -- name or a player name, so "longest" identifies it reliably enough to be
    -- worth trying before giving up entirely.
    local function longestString(...)
        local best = nil
        for index = 1, select("#", ...) do
            local value = select(index, ...)
            if type(value) == "string" and (not best or #value > #best) then
                best = value
            end
        end
        return best
    end

    --- Subscribe to parsed damage events: fn(hit, inputType, rawLine).
    function C.onDamage(handler, label)
        local wrapped = M.env.protect(label or "combat.onDamage", handler)
        subscribers[#subscribers + 1] = wrapped
        return function()
            for i, fn in ipairs(subscribers) do
                if fn == wrapped then
                    table.remove(subscribers, i)
                    return true
                end
            end
            return false
        end
    end

    --- Subscribe to every chat line, parsed or not: fn(inputType, source, line).
    function C.onLine(handler, label)
        return M.events.on("ShroudOnConsoleInput", handler, label or "combat.onLine")
    end

    function C.install()
        if installed then return C end
        installed = true

        M.events.on("ShroudOnConsoleInput", function(inputType, source, message)
            C.stats.calls = C.stats.calls + 1
            if not C.stats.argShape then
                C.stats.argShape = table.concat({
                    type(inputType), type(source), type(message) }, ",")
            end

            -- The documented signature is (inputType, sourcePlayer, message),
            -- but an older build that passes them in another order would
            -- otherwise fail completely silently. Only consulted when the
            -- third argument is not a string, so a client that behaves as
            -- documented takes exactly the same path it always did.
            if type(message) ~= "string" then
                message = longestString(inputType, source, message)
            end
            if type(message) ~= "string" or message == "" then return end

            C.stats.lines = C.stats.lines + 1
            local channel = type(inputType) == "string" and inputType or "?"
            C.stats.channels[channel] = (C.stats.channels[channel] or 0) + 1

            local stripped = M.util.stripMarkup(message)
            C.stats.lastLine = stripped

            local hit = C.parse(message)
            if not hit then
                -- Only counted as unmatched when it looked like it should have
                -- parsed; ordinary conversation is not a failure.
                if stripped:find(" points of ", 1, true) then
                    C.stats.unmatched = C.stats.unmatched + 1
                    C.stats.lastDamageLine = stripped
                end
                return
            end

            C.stats.parsed = C.stats.parsed + 1
            local snapshot = {}
            for i, fn in ipairs(subscribers) do snapshot[i] = fn end
            for _, fn in ipairs(snapshot) do fn(hit, inputType, message) end
        end, "combat.router")

        return C
    end

    --- Why nothing is being recorded, as lines fit for display.
    --
    -- A combat feature built on chat text has exactly three ways to fail, and
    -- from the player's side they look identical: an empty window. This tells
    -- them apart. It matters most on clients with no `/lua` command support,
    -- where a window is the only channel an addon has to report anything.
    --
    -- Returns a list of { text, color } and a boolean: whether anything is
    -- actually wrong. Healthy means damage is parsing, whatever happens to it
    -- downstream.
    function C.diagnose()
        local dim, bad = "#909090", "#E08A5C"

        if C.stats.calls == 0 then
            return {
                { text = "no chat is reaching this addon", color = bad },
                { text = "this client may not call ShroudOnConsoleInput", color = dim },
            }, true
        end

        if C.stats.lines == 0 then
            return {
                { text = "chat arrives, but carries no text", color = bad },
                { text = "arguments came as (" .. tostring(C.stats.argShape) .. ")", color = dim },
            }, true
        end

        if C.stats.parsed == 0 then
            local out = {
                { text = C.stats.lines .. " chat line(s), no damage recognised", color = bad },
            }
            -- The exact wording of combat text is client data published
            -- nowhere, so showing a real line is the only way to learn it.
            local sample = C.stats.lastDamageLine or C.stats.lastLine
            if sample then
                out[#out + 1] = { text = M.util.ellipsize(sample, 44), color = dim }
            end
            if C.stats.unmatched > 0 then
                out[#out + 1] = { text = C.stats.unmatched
                    .. " line(s) mentioned damage but did not match", color = dim }
            end
            return out, true
        end

        return {}, false
    end

    --- Channels seen, most frequent first. Diagnostic: it answers whether a
    --- party member's damage reaches addons at all on this client.
    function C.channels()
        local out = {}
        for name, count in pairs(C.stats.channels) do
            out[#out + 1] = { name = name, count = count }
        end
        return M.util.sortBy(out, function(item) return item.count end, true)
    end

    return C
end
