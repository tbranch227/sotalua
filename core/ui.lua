-- core/ui.lua -- retained-mode widget wrapper.
--
-- This module exists to make the documented "frozen quirks" survivable. Those
-- are contract, not bugs: the reference states plainly that they will never be
-- fixed. Every one of them is absorbed here so no plugin has to remember it.
--
--   * ShroudSetPivot multiplies the current anchored position, so pivot must be
--     applied before position.
--   * ShroudSetColor silently accepts bad hex and paints transparent black, and
--     it rejects UI.Button outright.
--   * ShroudSetButtonColor installs a whole new color block, zeroing the three
--     states you did not pass.
--   * ShroudSetToggleReadonly takes interactability, the opposite of its name.
--   * The toggle, input and button-transition setters bounds-check only the
--     upper end; a negative id indexes a backing list and throws.
--   * ShroudUnsetClickListener has an inverted removal branch and
--     ShroudUnsetInOutListener tests for the drag component, so neither
--     actually removes a live listener. Destroy and recreate instead.
--   * Panels are created with a Mask attached; images are not.
--   * A panel must be draggable before resizable or min/max size take effect.
--   * ShroudHideObject does not accept toggles or inputs.
--   * ShroudSetSize rejects toggles and inputs.
--   * ShroudSetParent returns -1 whether or not it succeeded.
--   * Widget creation returns -1 on failure; images and buttons need a texture.

return function(M)
    local UIx = {}

    local created = {}     -- ordered list of { id, kind } for teardown
    local meta = {}        -- "kind:id" -> bookkeeping

    local function kindName(kind)
        if UI then
            for name, value in pairs({
                Panel = UI.Panel, Image = UI.Image, Text = UI.Text,
                Button = UI.Button, Toggle = UI.Toggle, Input = UI.Input,
            }) do
                if value == kind then return name end
            end
        end
        return tostring(kind)
    end

    local function key(id, kind) return tostring(kind) .. ":" .. tostring(id) end

    local function track(id, kind, extra)
        if type(id) ~= "number" or id < 0 then return nil end
        created[#created + 1] = { id = id, kind = kind }
        meta[key(id, kind)] = extra or {}
        return id
    end

    --- A widget handle: a table carrying id and kind so plugins never pass the
    --- pair around by hand.
    local Widget = {}
    Widget.__index = Widget

    local function handle(id, kind)
        if type(id) ~= "number" or id < 0 then return nil end
        return setmetatable({ id = id, kind = kind }, Widget)
    end

    ----------------------------------------------------------------------
    -- Creation
    ----------------------------------------------------------------------

    local function parentArgs(parent)
        if parent then return parent.id, parent.kind end
        return -1, UI and UI.None or 0
    end

    --- Create a panel. Panels arrive masked and draggable-capable.
    function UIx.panel(opts)
        opts = opts or {}
        local pid, pkind = parentArgs(opts.parent)
        local id = ShroudUIPanel(opts.x or 0, opts.y or 0, opts.width or 200, opts.height or 100,
            opts.texture or -1, pid, pkind, opts.depth or 0)
        if not track(id, UI.Panel, { masked = true }) then
            M.log.error("failed to create panel")
            return nil
        end
        local w = handle(id, UI.Panel)
        UIx.apply(w, opts)
        return w
    end

    --- Create an image. Requires a valid texture id or the host returns -1.
    function UIx.image(opts)
        opts = opts or {}
        if type(opts.texture) ~= "number" or opts.texture < 0 then
            M.log.error("ui.image needs a texture id from ShroudLoadTexture")
            return nil
        end
        local pid, pkind = parentArgs(opts.parent)
        local id = ShroudUIImage(opts.x or 0, opts.y or 0, opts.width or 32, opts.height or 32,
            opts.texture, pid, pkind, opts.depth or 0)
        if not track(id, UI.Image, {}) then return nil end
        local w = handle(id, UI.Image)
        UIx.apply(w, opts)
        return w
    end

    function UIx.text(opts)
        opts = opts or {}
        local pid, pkind = parentArgs(opts.parent)
        local id = ShroudUIText(opts.text or "", opts.fontSize or 14,
            opts.x or 0, opts.y or 0, opts.width or 200, opts.height or 20,
            pid, pkind, opts.depth or 0)
        if not track(id, UI.Text, {}) then return nil end
        local w = handle(id, UI.Text)
        if opts.align then ShroudSetTextAlignment(id, opts.align) end
        UIx.apply(w, opts)
        return w
    end

    function UIx.button(opts)
        opts = opts or {}
        if type(opts.texture) ~= "number" or opts.texture < 0 then
            M.log.error("ui.button needs a texture id from ShroudLoadTexture")
            return nil
        end
        local pid, pkind = parentArgs(opts.parent)
        local id = ShroudUIButton(opts.x or 0, opts.y or 0, opts.width or 80, opts.height or 24,
            opts.texture, pid, pkind, opts.depth or 0)
        if not track(id, UI.Button, {}) then return nil end
        local w = handle(id, UI.Button)
        UIx.apply(w, opts)
        return w
    end

    --- Create an input. Inputs may only parent under an image or a panel, and
    --- they cannot be hidden directly, so callers that need to hide one should
    --- hide its parent panel.
    function UIx.input(opts)
        opts = opts or {}
        local pid, pkind = parentArgs(opts.parent)
        local id = ShroudUIInput(opts.x or 0, opts.y or 0, opts.width or 120, opts.height or 20, pid, pkind)
        if not track(id, UI.Input, {}) then return nil end
        local w = handle(id, UI.Input)
        if opts.placeholder then ShroudSetPlaceholderText(id, opts.placeholder) end
        if opts.text then ShroudSetInputText(id, opts.text) end
        if opts.contentType then ShroudSetInputContentType(id, opts.contentType) end
        if opts.characterLimit then ShroudSetInputCharacterLimit(id, opts.characterLimit) end
        if opts.readonly ~= nil then ShroudSetInputReadonly(id, opts.readonly) end
        if opts.backgroundColor then
            ShroudSetInputBackgroundColor(id, M.util.hex(opts.backgroundColor))
        end
        if opts.onChange then
            M.events.bindWidget(id, UI.Input, { onChange = M.env.protect("input.onChange", opts.onChange) })
        end
        return w
    end

    function UIx.toggle(opts)
        opts = opts or {}
        local pid, pkind = parentArgs(opts.parent)
        local id = ShroudUIToggle(opts.x or 0, opts.y or 0, opts.width or 20, opts.height or 20, pid, pkind)
        if not track(id, UI.Toggle, {}) then return nil end
        local w = handle(id, UI.Toggle)
        if opts.value ~= nil then UIx.setToggle(w, opts.value) end
        if opts.interactable ~= nil then UIx.setToggleInteractable(w, opts.interactable) end
        if opts.onToggle then
            M.events.bindWidget(id, UI.Toggle, { onToggle = M.env.protect("toggle.onToggle", opts.onToggle) })
        end
        return w
    end

    ----------------------------------------------------------------------
    -- Shared option application
    ----------------------------------------------------------------------

    --- Apply the options every visual widget shares, in the order the host
    --- requires: pivot and anchors first, then position and size, then paint.
    function UIx.apply(w, opts)
        if not w then return nil end
        -- Pivot multiplies the current anchored position, so it has to land
        -- before any call to ShroudSetPosition.
        if opts.pivot then ShroudSetPivot(w.id, w.kind, opts.pivot[1], opts.pivot[2]) end
        if opts.anchorMin then ShroudSetAnchorMin(w.id, w.kind, opts.anchorMin[1], opts.anchorMin[2]) end
        if opts.anchorMax then ShroudSetAnchorMax(w.id, w.kind, opts.anchorMax[1], opts.anchorMax[2]) end
        if opts.x and opts.y then UIx.setPosition(w, opts.x, opts.y) end
        if opts.width and opts.height then UIx.setSize(w, opts.width, opts.height) end
        if opts.color then UIx.setColor(w, opts.color) end
        if opts.alpha then ShroudSetTransparency(w.id, w.kind, opts.alpha) end
        if opts.scale then ShroudSetScale(w.id, w.kind, opts.scale) end
        if opts.rotation then ShroudRotateObject(w.id, w.kind, opts.rotation) end
        if opts.raycast ~= nil then ShroudRaycastObject(w.id, w.kind, opts.raycast) end
        if opts.draggable then UIx.setDraggable(w, true) end
        if opts.resizable then UIx.setResizable(w, opts.resizable, opts.minSize, opts.maxSize) end
        if opts.onClick then UIx.onClick(w, opts.onClick) end
        if opts.onOver or opts.onOut then UIx.onHover(w, opts.onOver, opts.onOut) end
        return w
    end

    ----------------------------------------------------------------------
    -- Transform
    ----------------------------------------------------------------------

    --- Set position in top-left widget space.
    --
    -- The host negates y internally and negates it back on read, so the value
    -- here round-trips through ShroudGetPosition unchanged. y grows downward.
    function UIx.setPosition(w, x, y)
        if not w then return false end
        return ShroudSetPosition(w.id, w.kind, x, y)
    end

    function UIx.getPosition(w)
        if not w then return nil end
        local v = ShroudGetPosition(w.id, w.kind)
        if not v then return nil end
        return v.x, v.y
    end

    --- Resize. Toggles and inputs are rejected by the host, so skip them rather
    --- than logging a failure the caller cannot act on.
    function UIx.setSize(w, width, height)
        if not w then return false end
        if w.kind == UI.Toggle or w.kind == UI.Input then return false end
        return ShroudSetSize(w.id, w.kind, width, height)
    end

    --- Set a color, routing buttons to the button-specific call.
    --
    -- ShroudSetColor rejects UI.Button, and ShroudSetButtonColor replaces the
    -- entire color block, so all four states are written in one pass to avoid
    -- zeroing the ones not mentioned.
    function UIx.setColor(w, color, states)
        if not w then return false end
        local hex = M.util.hex(color)
        if w.kind ~= UI.Button then
            return ShroudSetColor(w.id, w.kind, hex)
        end
        states = states or {}
        ShroudSetButtonColor(w.id, ButtonMode.Normal, M.util.hex(states.normal or hex))
        ShroudSetButtonColor(w.id, ButtonMode.Highlighted, M.util.hex(states.highlighted or M.util.mixHex(hex, "#FFFFFF", 0.25)))
        ShroudSetButtonColor(w.id, ButtonMode.Pressed, M.util.hex(states.pressed or M.util.mixHex(hex, "#000000", 0.25)))
        ShroudSetButtonColor(w.id, ButtonMode.Disabled, M.util.hex(states.disabled or M.util.mixHex(hex, "#808080", 0.6)))
        return true
    end

    function UIx.setAlpha(w, alpha)
        if not w then return false end
        return ShroudSetTransparency(w.id, w.kind, M.util.clamp(alpha, 0, 1))
    end

    --- Update a text widget's string. ShroudModifyText takes no kind argument.
    function UIx.setText(w, text)
        if not w or w.kind ~= UI.Text then return false end
        return ShroudModifyText(w.id, tostring(text))
    end

    function UIx.setTexture(w, textureId)
        if not w or w.kind == UI.Text then return false end
        return ShroudModifyImage(w.id, w.kind, textureId)
    end

    function UIx.setFontSize(w, size)
        if not w then return false end
        if w.kind ~= UI.Text and w.kind ~= UI.Input then return false end
        return ShroudSetFontSize(w.id, w.kind, size)
    end

    ----------------------------------------------------------------------
    -- Behavior
    ----------------------------------------------------------------------

    --- Make a panel or image draggable. Required before setResizable works.
    function UIx.setDraggable(w, enabled)
        if not w then return false end
        if w.kind ~= UI.Panel and w.kind ~= UI.Image then return false end
        local entry = meta[key(w.id, w.kind)]
        if entry then entry.draggable = enabled and true or false end
        -- The misspelling is frozen; a correctly spelled Draggable does not exist.
        if enabled then return ShroudSetDragguable(w.id, w.kind) end
        return ShroudUnsetDragguable(w.id, w.kind)
    end

    --- Make a panel resizable. `direction` is horizontal, vertical, corner or none.
    function UIx.setResizable(w, direction, minSize, maxSize)
        if not w or w.kind ~= UI.Panel then return false end
        local entry = meta[key(w.id, w.kind)] or {}
        if not entry.draggable then
            -- The host requires the drag component first; do it silently rather
            -- than failing in a way the caller has to debug.
            UIx.setDraggable(w, true)
        end
        if direction == true then direction = "corner" end
        local ok = ShroudSetResizable(w.id, w.kind, direction)
        if minSize and maxSize then
            ShroudMinMaxSize(w.id, w.kind, minSize, maxSize, direction)
        end
        return ok
    end

    --- Attach a click handler.
    --
    -- There is no working way to detach one afterwards: the host's
    -- ShroudUnsetClickListener has an inverted removal branch. Handlers are
    -- therefore routed through a mutable binding, so a plugin can swap the
    -- behavior even though the listener itself is permanent.
    function UIx.onClick(w, fn)
        if not w then return false end
        local entry = meta[key(w.id, w.kind)] or {}
        if not entry.clickListener then
            ShroudSetClickListener(w.id, w.kind)
            entry.clickListener = true
            meta[key(w.id, w.kind)] = entry
        end
        M.events.bindWidget(w.id, w.kind,
            UIx._merge(w, { onClick = M.env.protect("ui.onClick", fn) }))
        return true
    end

    function UIx.onHover(w, onOver, onOut)
        if not w then return false end
        local entry = meta[key(w.id, w.kind)] or {}
        if not entry.hoverListener then
            ShroudSetInOutListener(w.id, w.kind)
            entry.hoverListener = true
            meta[key(w.id, w.kind)] = entry
        end
        local bound = {}
        if onOver then bound.onOver = M.env.protect("ui.onOver", onOver) end
        if onOut then bound.onOut = M.env.protect("ui.onOut", onOut) end
        M.events.bindWidget(w.id, w.kind, UIx._merge(w, bound))
        return true
    end

    --- Merge new widget handlers over the existing binding.
    function UIx._merge(w, additions)
        local entry = meta[key(w.id, w.kind)] or {}
        entry.handlers = entry.handlers or {}
        for name, fn in pairs(additions or {}) do entry.handlers[name] = fn end
        meta[key(w.id, w.kind)] = entry
        return entry.handlers
    end

    ----------------------------------------------------------------------
    -- Visibility
    ----------------------------------------------------------------------

    --- Show or hide. Toggles and inputs cannot be hidden by the host, so their
    --- parent panel is hidden instead when there is one.
    function UIx.setVisible(w, visible)
        if not w then return false end
        if w.kind == UI.Toggle or w.kind == UI.Input then
            local parentId = ShroudGetParentID(w.id, w.kind)
            local parentKind = ShroudGetParentObjectKind(w.id, w.kind)
            if type(parentId) == "number" and parentId >= 0 then
                return UIx.setVisible({ id = parentId, kind = parentKind }, visible)
            end
            M.log.warn("cannot hide a", kindName(w.kind), "with no parent panel; parent it under one")
            return false
        end
        if visible then return ShroudShowObject(w.id, w.kind) end
        return ShroudHideObject(w.id, w.kind)
    end

    ----------------------------------------------------------------------
    -- Inputs and toggles
    ----------------------------------------------------------------------

    function UIx.getInputText(w)
        if not w or w.kind ~= UI.Input or w.id < 0 then return "" end
        return ShroudGetInputText(w.id) or ""
    end

    function UIx.setInputText(w, text)
        if not w or w.kind ~= UI.Input or w.id < 0 then return false end
        return ShroudSetInputText(w.id, tostring(text))
    end

    --- A negative id indexes the host's backing list and throws, and the host
    --- only bounds-checks the upper end, so guard here.
    function UIx.getToggle(w)
        if not w or w.kind ~= UI.Toggle or w.id < 0 then return false end
        return ShroudGetToggle(w.id) == true
    end

    function UIx.setToggle(w, value)
        if not w or w.kind ~= UI.Toggle or w.id < 0 then return false end
        return ShroudSetToggle(w.id, value and true or false)
    end

    --- Enable or disable player interaction with a toggle.
    --
    -- Named for what it does. The host call is ShroudSetToggleReadonly, whose
    -- argument is interactability: true lets the player click it.
    function UIx.setToggleInteractable(w, interactable)
        if not w or w.kind ~= UI.Toggle or w.id < 0 then return false end
        return ShroudSetToggleReadonly(w.id, interactable and true or false)
    end

    ----------------------------------------------------------------------
    -- Teardown
    ----------------------------------------------------------------------

    function UIx.destroy(w)
        if not w then return false end
        M.events.unbindWidget(w.id, w.kind)
        meta[key(w.id, w.kind)] = nil
        for i, entry in ipairs(created) do
            if entry.id == w.id and entry.kind == w.kind then
                table.remove(created, i)
                break
            end
        end
        return ShroudDestroyObject(w.id, w.kind)
    end

    --- Destroy every widget this addon created.
    --
    -- Wired to ShroudOnDisableScript. Without it, widget ids climb on every
    -- /lua reload and orphaned panels stay on screen. Children are destroyed
    -- before parents by walking the creation list backwards.
    function UIx.destroyAll()
        for i = #created, 1, -1 do
            local entry = created[i]
            M.events.unbindWidget(entry.id, entry.kind)
            meta[key(entry.id, entry.kind)] = nil
            M.env.try("ui.destroy", ShroudDestroyObject, entry.id, entry.kind)
        end
        created = {}
        return true
    end

    function UIx.liveCount() return #created end

    function UIx.install()
        M.events.on("ShroudOnDisableScript", UIx.destroyAll, "ui.destroyAllOnDisable")
        return UIx
    end

    ----------------------------------------------------------------------
    -- Textures
    ----------------------------------------------------------------------

    local textureCache = {}

    --- Load a texture from the addon folder. The host caches by path already,
    --- but memoizing here avoids the call entirely on repeat lookups and gives
    --- one place to report a bad path.
    function UIx.texture(path)
        if textureCache[path] ~= nil then return textureCache[path] end
        local id = -1
        if ShroudLoadTexture then
            id = M.env.try("ui.texture", ShroudLoadTexture, path) or -1
        end
        if id < 0 then
            M.log.warn("texture not found:", path, "(paths are confined to the addon folder)")
        end
        textureCache[path] = id
        return id
    end

    return UIx
end
