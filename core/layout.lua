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

    --- Create a titled, draggable, position-persisting panel.
    --
    -- opts: id (required, the saved-variable key), title, x, y, width, height,
    -- color, alpha, resizable, minSize, maxSize.
    function L.window(opts)
        assert(opts and opts.id, "layout.window requires an id")

        local saved = M.settings.get(WINDOW_KEY) or {}
        local placement = saved[opts.id] or {}

        local panel = M.ui.panel({
            x = placement.x or opts.x or 40,
            y = placement.y or opts.y or 40,
            width = placement.width or opts.width or 240,
            height = placement.height or opts.height or 140,
            color = opts.color or "#101014",
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
        }, Window)

        if opts.title then
            self.titleWidget = self:row(opts.title, { color = opts.titleColor or "#FFD98A", fontSize = 15 })
        end

        L._register(self)
        return self
    end

    --- Add a full-width text row and advance the cursor.
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
