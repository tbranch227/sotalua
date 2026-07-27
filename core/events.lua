-- core/events.lua -- fan-in router for the host's single-slot callbacks.
--
-- The host looks up one global per callback name and captures it right after
-- the addon file runs, so an addon gets exactly one ShroudOnUpdate. Core owns
-- that global and dispatches to any number of subscribers, each wrapped so one
-- bad handler cannot silence the others.
--
-- Widget events (mouse over/out/click, input change, toggle change) arrive as
-- (id, kind) with no indication of which widget was meant, so they are routed
-- through a per-widget table that core/ui.lua populates.

return function(M)
    local E = {}

    -- The 18 callbacks the host looks up by name.
    E.NAMES = {
        "ShroudOnStart",
        "ShroudOnUpdate",
        "ShroudOnGUI",
        "ShroudOnConsoleInput",
        "ShroudOnExperienceGain",
        "ShroudOnExperienceChanged",
        "ShroudOnMouseOver",
        "ShroudOnMouseOut",
        "ShroudOnMouseClick",
        "ShroudOnInputChange",
        "ShroudOnToggleChange",
        "ShroudOnSceneLoaded",
        "ShroudOnSceneUnloaded",
        "ShroudOnLogOut",
        "ShroudOnPlaySound",
        "ShroudOnPlayFX",
        "ShroudOnPlayEmote",
        "ShroudOnDisableScript",
    }

    -- ShroudOnExperienceChanged is documented as an alias of
    -- ShroudOnExperienceGain. Defining both would double-count every XP event,
    -- so only the primary name is ever installed.
    E.ALIASES = { ShroudOnExperienceChanged = "ShroudOnExperienceGain" }

    local subscribers = {}   -- callback name -> ordered list of handlers
    local widgetHandlers = {}  -- "kind:id" -> { over, out, click, change, toggle }

    local function key(id, kind)
        return tostring(kind) .. ":" .. tostring(id)
    end

    -- Set once handlers() has run, i.e. once the host has been given the
    -- callbacks it will use for the rest of the session.
    local published = nil

    --- Subscribe to a host callback. Returns an unsubscribe function.
    function E.on(name, handler, label)
        name = E.ALIASES[name] or name
        local list = subscribers[name]

        -- Subscribing to a callback that was not published is silent and total:
        -- the host never calls a global that does not exist, so the handler
        -- simply never runs. That is what happens when a plugin subscribes
        -- during ShroudOnStart, which fires after the callbacks were captured.
        if published and not published[name] then
            M.log.warn(name, "subscribed too late to be installed; move the"
                .. " subscription to the plugin body, outside ShroudOnStart")
        end

        if not list then
            list = {}
            subscribers[name] = list
        end
        local wrapped = M.env.protect(label or name, handler)
        list[#list + 1] = wrapped
        return function()
            for i, fn in ipairs(list) do
                if fn == wrapped then
                    table.remove(list, i)
                    return true
                end
            end
            return false
        end
    end

    --- Fire every subscriber of `name`. Called by the installed globals and
    --- directly by the offline harness.
    function E.emit(name, ...)
        local list = subscribers[E.ALIASES[name] or name]
        if not list then return 0 end
        -- Iterate a copy: a handler may unsubscribe itself mid-dispatch.
        local snapshot = {}
        for i, fn in ipairs(list) do snapshot[i] = fn end
        for _, fn in ipairs(snapshot) do fn(...) end
        return #snapshot
    end

    function E.count(name)
        local list = subscribers[E.ALIASES[name] or name]
        return list and #list or 0
    end

    --- Register per-widget handlers. core/ui.lua calls this; plugins do not.
    -- `events` may hold onClick, onOver, onOut, onChange (input), onToggle.
    function E.bindWidget(id, kind, events)
        widgetHandlers[key(id, kind)] = events
    end

    function E.unbindWidget(id, kind)
        widgetHandlers[key(id, kind)] = nil
    end

    local function widgetEvent(field)
        return function(id, kind, payload)
            local entry = widgetHandlers[key(id, kind)]
            local fn = entry and entry[field]
            if fn then fn(id, kind, payload) end
        end
    end

    local dispatchOver = widgetEvent("onOver")
    local dispatchOut = widgetEvent("onOut")
    local dispatchClick = widgetEvent("onClick")

    -- The five callbacks that carry widget events.
    --
    -- These are always installed, even with no subscriber and no widget yet.
    -- The host captures an addon's callbacks once, right after the file body
    -- runs, but widgets are created later in ShroudOnStart -- so deciding at
    -- capture time whether any widget exists would always answer "no" and the
    -- host would have no ShroudOnMouseClick to call when the player clicks one.
    -- They cost nothing when idle: unlike ShroudOnUpdate and ShroudOnGUI, they
    -- only fire on an actual interaction with a Lua widget.
    local WIDGET_CALLBACKS = {
        ShroudOnMouseOver = true, ShroudOnMouseOut = true, ShroudOnMouseClick = true,
        ShroudOnInputChange = true, ShroudOnToggleChange = true,
    }

    --- Install the global callback functions the host will capture.
    --
    -- Returns the table of globals rather than assigning them, so the bundler
    -- controls exactly which names leak into the shared environment and the
    -- tests can drive the router without touching _G.
    --
    -- Per-frame callbacks are emitted only when something subscribes: defining
    -- an unused ShroudOnGUI would have the host call it on every IMGUI event
    -- for nothing, and an unused ShroudOnUpdate costs a call every frame. The
    -- widget callbacks are always emitted, for the reason given above.
    function E.handlers()
        local wanted = {}
        for _, name in ipairs(E.NAMES) do
            if not E.ALIASES[name] and (WIDGET_CALLBACKS[name] or E.count(name) > 0) then
                wanted[name] = true
            end
        end

        local out = {}
        for name in pairs(wanted) do
            out[name] = function(...) return E.emit(name, ...) end
        end

        -- Widget callbacks must reach both the per-widget binding and any
        -- plugin that subscribed to the raw stream, so they replace the plain
        -- forwarder above. Each is guarded separately: a plugin can subscribe
        -- to ShroudOnMouseOver alone without pulling in the other four.
        local overrides = {
            ShroudOnMouseOver = function(id, kind)
                dispatchOver(id, kind)
                E.emit("ShroudOnMouseOver", id, kind)
            end,
            ShroudOnMouseOut = function(id, kind)
                dispatchOut(id, kind)
                E.emit("ShroudOnMouseOut", id, kind)
            end,
            ShroudOnMouseClick = function(id, kind)
                dispatchClick(id, kind)
                E.emit("ShroudOnMouseClick", id, kind)
            end,
            -- Inputs and toggles report only their own id; the host passes no
            -- kind, so look them up under their known kind.
            ShroudOnInputChange = function(id, text)
                local entry = widgetHandlers[key(id, UI and UI.Input or "Input")]
                if entry and entry.onChange then entry.onChange(id, text) end
                E.emit("ShroudOnInputChange", id, text)
            end,
            ShroudOnToggleChange = function(id, isOn)
                local entry = widgetHandlers[key(id, UI and UI.Toggle or "Toggle")]
                if entry and entry.onToggle then entry.onToggle(id, isOn) end
                E.emit("ShroudOnToggleChange", id, isOn)
            end,
        }
        for name, fn in pairs(overrides) do
            if wanted[name] then out[name] = fn end
        end

        published = wanted
        return out
    end

    function E.reset()
        subscribers = {}
        widgetHandlers = {}
        published = nil
    end

    return E
end
