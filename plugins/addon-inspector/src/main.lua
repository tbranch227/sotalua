-- Addon Inspector -- what is under the cursor.
--
-- Requires API 2 or newer, declared as min_api_version in the manifest so the
-- loader refuses to enable it on an older client rather than letting it fail at
-- runtime. The in-file check below covers the flat-addon install path, where
-- the manifest is not consulted.
--
-- All four under-mouse getters read one snapshot the host resolves once per
-- engine frame, resolving world objects before UI, so reading all four is no
-- more expensive than reading one.

return function(Core)
    local ui, layout, util, log, env, poll = Core.ui, Core.layout, Core.util, Core.log, Core.env, Core.poll

    local addon = Core.addon.start({
        name = "Addon Inspector",
        slug = "addon-inspector",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            pinKey = { default = "LeftAlt", scope = "account" },
        },
    })

    local view = {}
    local state = { pinned = nil, lastKind = nil }

    -- Colour by kind so a glance tells you what the host resolved.
    local KIND_COLOR = {
        player = "#7FB8FF", npc = "#FFD98A", item = "#9FE08F", container = "#C89AE0",
        deco = "#A0A0A0", object = "#A0A0A0", ui = "#FF9A7F", none = "#606060",
    }

    local function describe(hit)
        if not hit then return nil end
        local lines = {
            name = hit.name ~= "" and hit.name or "(no name)",
            kind = string.format("kind %s   id %d", hit.kind, hit.id),
            detail = hit.description,
        }
        return lines
    end

    local function render(hit)
        if not view.window then return end

        if not hit then
            ui.setText(view.name, "(nothing under the cursor)")
            ui.setColor(view.name, KIND_COLOR.none)
            ui.setText(view.kind, "")
            for i = 1, #view.detail do ui.setText(view.detail[i], "") end
            return
        end

        local lines = describe(hit)
        ui.setText(view.name, util.ellipsize(lines.name, 40))
        ui.setColor(view.name, KIND_COLOR[hit.kind] or "#FFFFFF")
        ui.setText(view.kind, lines.kind .. (state.pinned and "   [pinned]" or ""))

        -- The description is the full tooltip text, newlines and all. Split it
        -- across the fixed row set rather than letting one row overflow.
        local index = 0
        for line in tostring(lines.detail or ""):gmatch("[^\n]+") do
            index = index + 1
            if index > #view.detail then break end
            ui.setText(view.detail[index], util.ellipsize(util.trim(line), 44))
        end
        for i = index + 1, #view.detail do ui.setText(view.detail[i], "") end

        if view.copy then
            ui.setInputText(view.copy, string.format("%s|%s|%d", hit.name, hit.kind, hit.id))
        end
    end

    addon.onStart(function()
        if not env.HAS_MOUSE then
            -- Informational, not an error. This client does not provide
            -- ShroudGetKindUnderMouse and friends, so there is nothing to show;
            -- that is a fact about the build, not a fault.
            log.info("this client has no under-mouse API, so no window will be"
                .. " shown. Nothing else is affected.")
            return
        end

        local window = layout.window({
            id = "inspector",
            title = "Addon Inspector",
            x = 20, y = 220, width = 300,
            resizable = "horizontal", minSize = 220, maxSize = 640,
        })
        if not window then return end

        view.window = window
        view.name = window:row("(nothing under the cursor)", { fontSize = 14 })
        view.kind = window:row("", { fontSize = 12, color = "#B0B0B0" })
        view.detail = {}
        for _ = 1, 6 do
            view.detail[#view.detail + 1] = window:row("", { fontSize = 11, color = "#9A9A9A" })
        end
        view.copy = ui.input({
            parent = window.panel,
            x = 8, y = window.nextY + 2,
            width = window.width - 16, height = 20,
            placeholder = "name|kind|id",
            readonly = true,
        })
        window.nextY = window.nextY + 26
        window:fit()

        log.info("hold " .. (Core.settings.get("pinKey") or "LeftAlt")
            .. " to freeze the reading; /lua _AddonInspector_dump prints it")
    end)

    -- Polled a few times a second rather than every frame: the host refreshes
    -- the snapshot once per engine frame anyway, and this is a text update.
    addon.tick(0.15, function()
        if not view.window then return end

        local pinKey = Core.settings.get("pinKey") or "LeftAlt"
        if ShroudGetKeyDown(pinKey) then
            -- Freeze on the first frame the key goes down so you can move the
            -- cursor off the thing you are inspecting to read the panel.
            state.pinned = state.pinned or poll.underMouse()
            render(state.pinned)
            return
        end

        state.pinned = nil
        render(poll.underMouse())
    end)

    addon.command("dump", function()
        local hit = state.pinned or poll.underMouse()
        if not hit then
            log.say("nothing under the cursor")
            return
        end
        log.say(string.format("name=%q kind=%q id=%d", hit.name, hit.kind, hit.id))
        if hit.description ~= "" then
            for line in hit.description:gmatch("[^\n]+") do log.say("  " .. line) end
        end
    end)

    addon.command("pinkey", function()
        -- Cycle through a few sensible modifiers; there is no text entry for a
        -- KeyCode and an invalid name would just log "Keyname invalid".
        local options = { "LeftAlt", "LeftControl", "LeftShift", "Tab" }
        local current = Core.settings.get("pinKey")
        local index = 1
        for i, key in ipairs(options) do
            if key == current then index = i % #options + 1 end
        end
        Core.settings.set("pinKey", options[index])
        log.say("pin key is now " .. options[index])
    end)

    return { state = state, view = view }
end
