-- core/env.lua -- API feature detection and error containment.
--
-- ShroudLuaApiVersion, ShroudLuaPath and InvalidStatResult are written before
-- any addon body runs, so reading them at file scope is safe and is the
-- documented way to feature-detect.

return function(M)
    local E = {}

    E.API = ShroudLuaApiVersion or 0

    -- Version gates as published in the reference:
    --   1  target API              (#746)
    --   2  under-mouse API         (#1031)
    --   3  buff icons and tooltips
    E.HAS_TARGET = E.API >= 1
    E.HAS_MOUSE = E.API >= 2
    E.HAS_ICONS = E.API >= 3

    -- Read live, not snapshotted.
    --
    -- The reference says the set-once constants are written before any addon
    -- file runs, and ShroudLuaApiVersion does behave that way. ShroudLuaPath
    -- does not: on a real client it was still empty while the file body ran and
    -- only populated later, which turned a snapshot into "" and made a path
    -- built from it land at the filesystem root. Reading at call time costs a
    -- global lookup and is correct whenever the host gets round to setting it.
    function E.luaPath()
        return ShroudLuaPath or ""
    end

    function E.dataPath()
        return ShroudDataPath or ""
    end

    --- Join a filename onto the addon Lua folder, picking the right separator.
    -- Returns nil when the host has not published the path yet, so callers can
    -- report that rather than writing to an accidental absolute path.
    function E.luaFile(name)
        local base = E.luaPath()
        if base == "" then return nil end
        local separator = base:find("\\", 1, true) and "\\" or "/"
        if base:sub(-1) == separator then return base .. name end
        return base .. separator .. name
    end

    local state = {
        name = "addon",
        slug = "addon",
        version = "0.0.0",
        errors = 0,
        muted = {},
        started = false,
    }

    --- Called once from a plugin's entry point before anything else.
    function E.init(opts)
        state.name = opts.name or state.name
        state.slug = opts.slug or state.slug
        state.version = opts.version or state.version
        M.log.configure(state.name, opts.logLevel or "info")
        return E
    end

    function E.name() return state.name end
    function E.slug() return state.slug end
    function E.version() return state.version end
    function E.errorCount() return state.errors end

    --- True when the running client is at least `version`.
    function E.atLeast(version)
        return E.API >= version
    end

    --- Wrap a function so a bug inside it cannot take the addon down.
    --
    -- The host disables an addon after 8 errors in 10 seconds, so an exception
    -- thrown every frame is fatal within half a second. Each distinct call site
    -- reports once and is then muted; the wrapped function keeps being called
    -- but stops raising. Note this cannot catch a runaway loop:
    -- MoonSharpWatchdogException does not derive from InterpreterException and
    -- is deliberately not catchable by pcall.
    function E.protect(label, fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if ok then return err end
            state.errors = state.errors + 1
            if not state.muted[label] then
                state.muted[label] = true
                M.log.error(label, "failed:", err, "(further errors here are silenced)")
            end
            return nil
        end
    end

    --- Run `fn` once, reporting rather than propagating a failure.
    function E.try(label, fn, ...)
        return E.protect(label, fn)(...)
    end

    --- Clear the mute list so a fixed call site can report again after a reload.
    function E.resetErrors()
        state.errors = 0
        state.muted = {}
    end

    --- Guard a host call that may not exist on an older client.
    --
    -- Returns a function that yields `fallback` when the binding is missing, so
    -- a plugin can call ShroudGetBuffIcon unconditionally and simply get -1 on
    -- an API 2 client instead of a nil-call error.
    function E.optional(fnName, fallback)
        local fn = _G[fnName]
        if type(fn) == "function" then return fn end
        return function() return fallback end
    end

    --- A summary line for the api-probe addon and for test assertions.
    --
    -- The build id is a content hash the bundler injects. Without it there is
    -- no way to tell from in game whether a freshly installed file has actually
    -- been picked up, since /lua reload is what loads it and a stale build
    -- looks identical to a current one.
    function E.describe()
        return string.format(
            "%s v%s+%s (slug=%s) on Lua API %d [target=%s mouse=%s icons=%s]",
            state.name, state.version, M.buildId or "src", state.slug, E.API,
            tostring(E.HAS_TARGET), tostring(E.HAS_MOUSE), tostring(E.HAS_ICONS)
        )
    end

    return E
end
