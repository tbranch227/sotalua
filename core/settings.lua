-- core/settings.lua -- declarative persistence over the saved-variable API.
--
-- ShroudSetSavedVar only marks the store dirty; nothing reaches disk until a
-- flush, and the host flushes on logout, disable, unload and quit. Values are
-- namespaced per addon and per character (or per account) by the host, so keys
-- only need to be unique within one addon.
--
-- Two documented limits are enforced here rather than discovered at flush time:
-- keys are at most 128 characters with no control characters, slashes or
-- backslashes, and a single table larger than 256 KB of JSON is skipped by the
-- host and makes ShroudFlushSavedVars return false.

return function(M)
    local S = {}

    local MAX_KEY = 128
    local MAX_BYTES = 256 * 1024
    local SCOPES = { character = "character", account = "account" }

    local schema = {}   -- key -> { default, scope }
    local cache = {}    -- key -> current value
    local loaded = {}   -- key -> true once read through
    local dirty = false

    local function validKey(key)
        if type(key) ~= "string" or key == "" then return false, "key must be a non-empty string" end
        if #key > MAX_KEY then return false, "key longer than " .. MAX_KEY .. " characters" end
        if key:find("[/\\]") then return false, "key must not contain / or \\" end
        if key:find("%c") then return false, "key must not contain control characters" end
        return true
    end

    --- Rough JSON byte cost, used to reject oversized tables before the host
    --- silently drops them at flush time.
    local function approximateSize(value, seen)
        local kind = type(value)
        if kind == "string" then return #value + 2 end
        if kind == "number" or kind == "boolean" or kind == "nil" then return 8 end
        if kind ~= "table" then return 0 end
        seen = seen or {}
        if seen[value] then return 0 end
        seen[value] = true
        local total = 2
        for k, v in pairs(value) do
            total = total + approximateSize(k, seen) + approximateSize(v, seen) + 2
        end
        return total
    end

    --- Declare the keys a plugin persists, with defaults and scope.
    --
    --   settings.define{
    --     window = { default = { x = 40, y = 120 }, scope = "character" },
    --     theme  = { default = "dark", scope = "account" },
    --   }
    function S.define(spec)
        for key, entry in pairs(spec) do
            local ok, err = validKey(key)
            if not ok then
                M.log.error("settings.define rejected", key, "-", err)
            else
                schema[key] = {
                    default = entry.default,
                    scope = SCOPES[tostring(entry.scope or "character"):lower()] or "character",
                }
            end
        end
        return S
    end

    local function scopeOf(key)
        local entry = schema[key]
        return entry and entry.scope or "character"
    end

    --- Read a setting, falling back to its declared default.
    --
    -- The host hands stored tables back by reference to its in-memory copy, so
    -- tables are deep-copied on first read. Mutating what get() returns would
    -- otherwise change the saved state without ever marking it dirty.
    function S.get(key)
        if loaded[key] then return cache[key] end

        local entry = schema[key]
        local stored
        if ShroudGetSavedVar then
            stored = M.env.try("settings.get:" .. key, ShroudGetSavedVar, key, scopeOf(key))
        end

        if stored == nil then
            stored = entry and M.util.deepCopy(entry.default) or nil
        elseif type(stored) == "table" then
            stored = M.util.deepCopy(stored)
            -- Fill in keys added by a newer version of the plugin.
            if entry and type(entry.default) == "table" then
                for k, v in pairs(entry.default) do
                    if stored[k] == nil then stored[k] = M.util.deepCopy(v) end
                end
            end
        end

        cache[key] = stored
        loaded[key] = true
        return stored
    end

    --- Write a setting. Nothing reaches disk until flush().
    function S.set(key, value)
        local ok, err = validKey(key)
        if not ok then
            M.log.error("settings.set rejected", key, "-", err)
            return false
        end

        local kind = type(value)
        if kind == "function" or kind == "thread" or kind == "userdata" then
            M.log.error("settings.set rejected", key, "- cannot persist a", kind)
            return false
        end
        if kind == "table" then
            local size = approximateSize(value)
            if size > MAX_BYTES then
                M.log.error("settings.set rejected", key, "- roughly", size,
                    "bytes exceeds the host's 256 KB per-value limit")
                return false
            end
        end

        cache[key] = value
        loaded[key] = true
        dirty = true

        if ShroudSetSavedVar then
            M.env.try("settings.set:" .. key, ShroudSetSavedVar, key, value, scopeOf(key))
        end
        return true
    end

    --- Read-modify-write helper for table settings.
    function S.update(key, mutate)
        local value = S.get(key)
        if type(value) ~= "table" then value = {} end
        mutate(value)
        return S.set(key, value)
    end

    function S.delete(key)
        cache[key] = nil
        loaded[key] = nil
        dirty = true
        if ShroudDeleteSavedVar then
            M.env.try("settings.delete:" .. key, ShroudDeleteSavedVar, key, scopeOf(key))
        end
        return true
    end

    --- Restore every declared key to its default.
    function S.reset()
        for key, entry in pairs(schema) do
            S.set(key, M.util.deepCopy(entry.default))
        end
    end

    --- Force the host to write. Core wires this to logout and disable, so
    --- plugins rarely need to call it directly.
    function S.flush()
        if not dirty then return true end
        dirty = false
        if not ShroudFlushSavedVars then return true end
        local ok = M.env.try("settings.flush", ShroudFlushSavedVars)
        if ok == false then
            M.log.warn("saved variables were not written; a value may exceed the host size limit")
        end
        return ok ~= false
    end

    function S.isDirty() return dirty end

    --- Subscribe to the two events that must never lose state.
    function S.install()
        M.events.on("ShroudOnLogOut", S.flush, "settings.flushOnLogout")
        M.events.on("ShroudOnDisableScript", S.flush, "settings.flushOnDisable")
        return S
    end

    --- Drop in-memory state without touching the host. Tests only.
    function S.clearCache()
        schema, cache, loaded, dirty = {}, {}, {}, false
    end

    return S
end
