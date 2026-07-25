-- core/layout.lua -- composite widgets built on core/ui.
--
-- Panels that remember where the player dragged them, stacked text rows, and
-- fill bars. Every plugin in this suite is some arrangement of these three, so
-- the quirk handling and the saved-variable plumbing live here once.

return function(M)
    local L = {}

    local WINDOW_KEY = "windows"

    ----------------------------------------------------------------------
    -- Window: a draggable panel whose position persists
    ----------------------------------------------------------------------

    local Window = {}
    Window.__index = Window

    -- Title bar palette. Kept here rather than per-plugin so every window in
    -- the suite reads as part of one set.
    L.theme = {
        body = "#101014",
        header = "#1E1E2A",
        headerHover = "#33334A",
        accent = "#4C7AC8",
        title = "#FFD98A",
        grip = "#6A6A82",
    }

    local TITLE_HEIGHT = 22
    local ACCENT_HEIGHT = 2

    --- Create a titled, draggable, position-persisting panel.
    --
    -- opts: id (required, the saved-variable key), title, x, y, width, height,
    -- color, alpha, resizable, minSize, maxSize.
    --
    -- The whole panel is the drag handle, not just the title bar. Everything
    -- decorative is created with raycasting off so it cannot swallow the drag,
    -- which is what makes the grippable area the full window rather than
    -- whatever slivers of background the text rows leave uncovered.
    function L.window(opts)
        assert(opts and opts.id, "layout.window requires an id")

        local saved = M.settings.get(WINDOW_KEY) or {}
        local placement = saved[opts.id] or {}

        local panel = M.ui.panel({
            x = placement.x or opts.x or 40,
            y = placement.y or opts.y or 40,
            width = placement.width or opts.width or 240,
            height = placement.height or opts.height or 140,
            color = opts.color or L.theme.body,
            alpha = opts.alpha or 0.85,
            draggable = true,
            resizable = opts.resizable,
            minSize = opts.minSize,
            maxSize = opts.maxSize,
        })
        if not panel then return nil end

        local self = setmetatable({
            id = opts.id,
            panel = panel,
            padding = opts.padding or 8,
            rowHeight = opts.rowHeight or 18,
            nextY = opts.padding or 8,
            width = placement.width or opts.width or 240,
            children = {},
            theme = {
                header = opts.headerColor or L.theme.header,
                headerHover = opts.headerHoverColor or L.theme.headerHover,
                accent = opts.accentColor or L.theme.accent,
                title = opts.titleColor or L.theme.title,
            },
        }, Window)

        if opts.title then self:_buildHeader(opts) end

        -- Hover feedback on the whole window. There is no cursor API in the
        -- host -- nothing can turn the pointer into a move cursor -- so the
        -- title bar lighting up is the available way to say "grab me".
        M.ui.onHover(panel,
            function() self:setHovered(true) end,
            function() self:setHovered(false) end)

        L._register(self)
        return self
    end

    --- Build the title bar: background strip, title text, grip hint, accent rule.
    function Window:_buildHeader(opts)
        self.header = M.ui.panel({
            parent = self.panel,
            x = 0, y = 0,
            width = self.width, height = TITLE_HEIGHT,
            color = self.theme.header,
            alpha = 1.0,
        })
        -- Decoration only: input must reach the draggable parent underneath.
        M.ui.setRaycast(self.header, false)

        self.titleWidget = M.ui.text({
            parent = self.header,
            text = opts.title,
            x = 8, y = 3,
            width = self.width - 40, height = TITLE_HEIGHT - 4,
            fontSize = opts.titleFontSize or 13,
            color = self.theme.title,
        })
        M.ui.setRaycast(self.titleWidget, false)

        -- A plain ASCII grip mark; the font's coverage of box-drawing glyphs is
        -- not something this can rely on.
        self.gripWidget = M.ui.text({
            parent = self.header,
            text = ":::",
            x = self.width - 26, y = 3,
            width = 20, height = TITLE_HEIGHT - 4,
            fontSize = 12,
            color = L.theme.grip,
        })
        M.ui.setRaycast(self.gripWidget, false)

        self.accent = M.ui.panel({
            parent = self.panel,
            x = 0, y = TITLE_HEIGHT,
            width = self.width, height = ACCENT_HEIGHT,
            color = self.theme.accent,
            alpha = 1.0,
        })
        M.ui.setRaycast(self.accent, false)

        self.nextY = TITLE_HEIGHT + ACCENT_HEIGHT + self.padding
    end

    --- Brighten the title bar while the pointer is over the window.
    function Window:setHovered(hovered)
        if self.hovered == hovered then return end
        self.hovered = hovered
        if not self.header then return end
        M.ui.setColor(self.header, hovered and self.theme.headerHover or self.theme.header)
        if self.gripWidget then
            M.ui.setColor(self.gripWidget, hovered and self.theme.title or L.theme.grip)
        end
    end

    --- Change the title text after creation.
    function Window:setTitle(text)
        if not self.titleWidget then return false end
        return M.ui.setText(self.titleWidget, text)
    end

    --- Add a full-width text row and advance the cursor.
    --
    -- Rows do not take pointer input unless asked to. A Unity Text raycasts by
    -- default, so a stack of labels over a draggable panel turns the window
    -- into a set of dead zones separated by thin grabbable gaps. Pass
    -- `interactive = true` for a row that genuinely needs clicks.
    function Window:row(text, opts)
        opts = opts or {}
        local widget = M.ui.text({
            parent = self.panel,
            text = text or "",
            x = opts.x or self.padding,
            y = opts.y or self.nextY,
            width = opts.width or (self.width - self.padding * 2),
            height = opts.height or self.rowHeight,
            fontSize = opts.fontSize or 13,
            color = opts.color,
            align = opts.align,
        })
        M.ui.setRaycast(widget, opts.interactive == true)
        if not opts.y then
            self.nextY = self.nextY + (opts.height or self.rowHeight) + (opts.gap or 2)
        end
        self.children[#self.children + 1] = widget
        return widget
    end

    --- Add a labelled fill bar and advance the cursor.
    --
    -- Bars are two nested panels rather than images so they need no artwork:
    -- addons that ship no textures still get a usable HUD.
    function Window:bar(opts)
        opts = opts or {}
        local width = opts.width or (self.width - self.padding * 2)
        local height = opts.height or 14
        local y = opts.y or self.nextY

        local track = M.ui.panel({
            parent = self.panel,
            x = opts.x or self.padding, y = y,
            width = width, height = height,
            color = opts.trackColor or "#2A2A32", alpha = 0.9,
        })
        local fill = M.ui.panel({
            parent = track,
            x = 0, y = 0, width = width, height = height,
            color = opts.color or "#4C9A5A", alpha = 1.0,
        })
        local label = M.ui.text({
            parent = track,
            text = opts.text or "",
            x = 4, y = 0, width = width - 8, height = height,
            fontSize = opts.fontSize or 11,
            color = opts.textColor or "#FFFFFF",
        })

        -- A bar is three stacked widgets covering the full row width; leaving
        -- any of them raycasting would carve a dead stripe across the window.
        M.ui.setRaycast(track, false)
        M.ui.setRaycast(fill, false)
        M.ui.setRaycast(label, false)

        if not opts.y then
            self.nextY = self.nextY + height + (opts.gap or 3)
        end

        local bar = {
            track = track, fill = fill, label = label,
            width = width, height = height,
        }
        self.children[#self.children + 1] = track
        return bar
    end

    --- Update a bar built by Window:bar.
    --
    -- `ratio` is 0..1. Passing nil means "unknown", which is how a target with
    -- hidden health is drawn: the host reports current == max there, so a full
    -- bar would be a lie.
    function L.setBar(bar, ratio, text, color)
        if not bar then return end
        if ratio == nil then
            M.ui.setSize(bar.fill, bar.width, bar.height)
            M.ui.setColor(bar.fill, "#4A4A55")
        else
            local clamped = M.util.clamp(ratio, 0, 1)
            -- A zero-width panel can render as a sliver; collapse it instead.
            M.ui.setSize(bar.fill, math.max(clamped * bar.width, 0), bar.height)
            M.ui.setAlpha(bar.fill, clamped <= 0 and 0 or 1)
            if color then M.ui.setColor(bar.fill, color) end
        end
        if text ~= nil then M.ui.setText(bar.label, text) end
    end

    --- Health-style green to red gradient.
    function L.vitalColor(ratio)
        if ratio > 0.5 then
            return M.util.mixHex("#C8A020", "#4C9A5A", (ratio - 0.5) * 2)
        end
        return M.util.mixHex("#B03030", "#C8A020", ratio * 2)
    end

    --- Resize the panel to exactly fit the rows added so far.
    function Window:fit()
        M.ui.setSize(self.panel, self.width, self.nextY + self.padding)
        return self
    end

    function Window:setVisible(visible)
        self.visible = visible and true or false
        M.ui.setVisible(self.panel, self.visible)
        return self
    end

    function Window:isVisible()
        return self.visible ~= false
    end

    function Window:toggle()
        return self:setVisible(not self:isVisible())
    end

    --- Persist the current position and size.
    --
    -- Called on a debounce while dragging and unconditionally at logout, since
    -- writing a saved variable on every frame of a drag would be wasteful.
    function Window:savePlacement()
        local x, y = M.ui.getPosition(self.panel)
        if not x then return end
        M.settings.update(WINDOW_KEY, function(store)
            store[self.id] = { x = x, y = y, width = self.width }
        end)
    end

    ----------------------------------------------------------------------
    -- Placement persistence
    ----------------------------------------------------------------------

    local windows = {}

    function L._register(window)
        windows[#windows + 1] = window
    end

    function L.saveAll()
        for _, window in ipairs(windows) do
            M.env.try("layout.savePlacement", function() window:savePlacement() end)
        end
        return true
    end

    function L.windows() return windows end

    --- Watch for drags and persist placements shortly after they settle.
    function L.install(opts)
        opts = opts or {}
        local persist = M.timers.debounce("layout.persist", opts.debounce or 1.0, L.saveAll)

        local lastSeen = {}
        M.events.on("ShroudOnUpdate", M.timers.throttle(opts.poll or 0.5, function()
            for _, window in ipairs(windows) do
                local x, y = M.ui.getPosition(window.panel)
                if x then
                    local prev = lastSeen[window.id]
                    if not prev or prev.x ~= x or prev.y ~= y then
                        lastSeen[window.id] = { x = x, y = y }
                        if prev then persist() end   -- ignore the first observation
                    end
                end
            end
        end), "layout.watchDrag")

        M.events.on("ShroudOnLogOut", L.saveAll, "layout.saveOnLogout")
        M.events.on("ShroudOnDisableScript", L.saveAll, "layout.saveOnDisable")
        return L
    end

    function L.reset()
        windows = {}
    end

    return L
end
