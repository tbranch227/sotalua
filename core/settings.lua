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

    -- One install serves any number of characters, and a player can switch
    -- without restarting the client. The host swaps which file backs the
    -- character scope, but this module's cache would happily keep serving the
    -- previous character's values -- and write them back under the new one.
    local character = nil

    --- Drop cached values when the character changes.
    --
    -- Only a new *valid* name counts: ShroudGetPlayerName reports no player
    -- during logout, and treating that as a switch would clear the cache at
    -- exactly the moment the flush handlers need it.
    local function syncCharacter()
        local live = M.util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), nil)
        if not live then return end
        if character == nil then
            character = live
            return
        end
        if live ~= character then
            character = live
            cache, loaded = {}, {}
        end
    end

    ----------------------------------------------------------------------
    -- File-backed fallback
    --
    -- An older client provides no saved-variable API at all: no
    -- ShroudSetSavedVar, GetSavedVar, DeleteSavedVar or FlushSavedVars. Without
    -- a fallback every setting would silently reset each session, and a tracker
    -- whose whole purpose is remembering something across sessions would be
    -- pointless there.
    --
    -- Values are written as a Lua literal and read back with load(), rather
    -- than JSON, because that needs a serializer only -- no parser -- and the
    -- host's own saved variables were historically Lua source for the same
    -- reason.
    ----------------------------------------------------------------------

    local fileStore = nil     -- { account = {}, characters = { [name] = {} } }
    local fileDirty = false

    local function hostHasSavedVars()
        return type(ShroudSetSavedVar) == "function"
            and type(ShroudGetSavedVar) == "function"
    end

    local function filePath()
        return M.env.luaFile("sotalua-settings-" .. M.env.slug() .. ".lua")
    end

    local function serialize(value, depth)
        depth = (depth or 0) + 1
        if depth > 12 then return "nil" end
        local kind = type(value)
        if kind == "string" then return string.format("%q", value) end
        if kind == "number" or kind == "boolean" then return tostring(value) end
        if kind ~= "table" then return "nil" end

        local parts = {}
        for _, key in ipairs(M.util.keysSorted(value)) do
            local encodedKey
            if type(key) == "string" then
                encodedKey = "[" .. string.format("%q", key) .. "]"
            elseif type(key) == "number" then
                encodedKey = "[" .. tostring(key) .. "]"
            end
            if encodedKey then
                parts[#parts + 1] = encodedKey .. "=" .. serialize(value[key], depth)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    local function loadFileStore()
        if fileStore then return fileStore end
        fileStore = { account = {}, characters = {} }

        local path = filePath()
        if not path then return fileStore end
        local file = io.open(path, "r")
        if not file then return fileStore end
        local body = file:read("*a")
        file:close()

        local loader = load or loadstring
        if not loader or not body or body == "" then return fileStore end
        local ok, chunk = pcall(loader, body, "settings", "t", {})
        if ok and chunk then
            local decoded
            ok, decoded = pcall(chunk)
            if ok and type(decoded) == "table" then
                fileStore.account = decoded.account or {}
                fileStore.characters = decoded.characters or {}
            end
        end
        return fileStore
    end

    local function fileScope(scope)
        local store = loadFileStore()
        if scope == "account" then return store.account end
        local who = M.util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), nil)
            or character or "unknown"
        store.characters[who] = store.characters[who] or {}
        return store.characters[who]
    end

    local function writeFileStore()
        if not fileDirty or not fileStore then return true end
        local path = filePath()
        if not path then return false end   -- path not published yet; try later
        local file = io.open(path, "w")
        if not file then
            M.log.warn("could not write settings to", path)
            return false
        end
        file:write("return " .. serialize(fileStore) .. "\n")
        file:close()
        fileDirty = false
        return true
    end

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
        syncCharacter()
        if loaded[key] then return cache[key] end

        local entry = schema[key]
        local stored
        if hostHasSavedVars() then
            stored = M.env.try("settings.get:" .. key, ShroudGetSavedVar, key, scopeOf(key))
        else
            stored = fileScope(scopeOf(key))[key]
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
        syncCharacter()
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

        if hostHasSavedVars() then
            M.env.try("settings.set:" .. key, ShroudSetSavedVar, key, value, scopeOf(key))
        else
            fileScope(scopeOf(key))[key] = M.util.deepCopy(value)
            fileDirty = true
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
        if type(ShroudDeleteSavedVar) == "function" then
            M.env.try("settings.delete:" .. key, ShroudDeleteSavedVar, key, scopeOf(key))
        else
            fileScope(scopeOf(key))[key] = nil
            fileDirty = true
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
        if not hostHasSavedVars() then
            dirty = false
            return writeFileStore()
        end
        if not dirty then return true end
        dirty = false
        if type(ShroudFlushSavedVars) ~= "function" then return true end
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
