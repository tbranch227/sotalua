-- Party Frames -- vitals for everyone in the group.
--
-- The party API has two halves that must be combined. The index getters
-- (ShroudGetPartyMemberName(i) and friends) cover the whole roster, including
-- members in other scenes. The InScene getters are keyed by name and only
-- answer for members standing near you, but they are the live readings.
-- core/poll merges them and marks each member with inScene, which is what lets
-- this frame dim the ones it cannot report on accurately.
--
-- Everything fails soft: the whole party API is safe to call when you are not
-- in a party, and ShroudGetPartyMemberNamesInScene returns a list holding a
-- single nil element in that case rather than an empty one.

return function(Core)
    local ui, layout, util, poll, log = Core.ui, Core.layout, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "Party Frames",
        slug = "party-frames",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            maxMembers = { default = 7, scope = "account" },
            showFocus = { default = true, scope = "account" },
            lowHealthPercent = { default = 35, scope = "account" },
            hideWhenSolo = { default = true, scope = "account" },
        },
    })

    local view = { slots = {} }
    local state = { visible = true, lastCount = -1 }

    local function setVisible(visible)
        if state.visible == visible then return end
        state.visible = visible
        if view.window then view.window:setVisible(visible) end
    end

    local function renderSlot(slot, member, lowPercent)
        if not member then
            ui.setText(slot.name, "")
            layout.setBar(slot.health, 0, "")
            if slot.focus then layout.setBar(slot.focus, 0, "") end
            return
        end

        local ratio = util.ratio(member.health, member.maxHealth)
        local low = ratio * 100 <= lowPercent

        local label = util.ellipsize(member.name, 18)
        if not member.inScene then label = label .. "  (away)" end
        ui.setText(slot.name, label)
        -- Out-of-scene readings come from the roster getters and can be stale,
        -- so they are dimmed rather than presented as live.
        ui.setColor(slot.name, not member.inScene and "#707070"
            or (low and "#FF7A6A" or "#FFFFFF"))

        if member.inScene then
            layout.setBar(slot.health, ratio,
                string.format("%s / %s", util.short(member.health), util.short(member.maxHealth)),
                layout.vitalColor(ratio))
        else
            layout.setBar(slot.health, nil, "out of scene")
        end

        if slot.focus then
            if member.inScene and util.isValid(member.maxFocus) and member.maxFocus > 0 then
                layout.setBar(slot.focus, util.ratio(member.focus, member.maxFocus),
                    "", "#4C7AC8")
            else
                layout.setBar(slot.focus, 0, "")
            end
        end
    end

    local function render()
        if not view.window then return end
        local party = poll.party()

        if #party == 0 then
            if Core.settings.get("hideWhenSolo") then
                setVisible(false)
                return
            end
            setVisible(true)
            for _, slot in ipairs(view.slots) do renderSlot(slot, nil) end
            view.window:setTitle("Party  (solo)")
            return
        end

        setVisible(true)

        local inScene = 0
        for _, member in ipairs(party) do
            if member.inScene then inScene = inScene + 1 end
        end
        -- The counts live in the title bar rather than a body row: it is a
        -- label for the window, and it frees a row for an actual member.
        view.window:setTitle(string.format("Party  %d/%d here", inScene, #party))

        local lowPercent = Core.settings.get("lowHealthPercent") or 35
        for i, slot in ipairs(view.slots) do
            renderSlot(slot, party[i], lowPercent)
        end

        if #party > #view.slots then
            ui.setText(view.overflow, string.format("+%d not shown", #party - #view.slots))
        else
            ui.setText(view.overflow, "")
        end
    end

    addon.onStart(function()
        local slots = util.clamp(Core.settings.get("maxMembers") or 7, 1, 12)
        local showFocus = Core.settings.get("showFocus")

        local window = layout.window({
            id = "party",
            title = "Party",
            accentColor = "#4C9A5A",
            x = 20, y = 60, width = 220,
            resizable = "horizontal", minSize = 170, maxSize = 420,
        })
        if not window then return end

        view.window = window
        for _ = 1, slots do
            local slot = {}
            slot.name = window:row("", { fontSize = 12, height = 14, gap = 0 })
            slot.health = window:bar({ height = 10, gap = showFocus and 1 or 4 })
            if showFocus then
                slot.focus = window:bar({ height = 5, color = "#4C7AC8", gap = 5 })
            end
            view.slots[#view.slots + 1] = slot
        end
        view.overflow = window:row("", { fontSize = 10, color = "#808080" })
        window:fit()
    end)

    -- Party vitals move fast in a fight but not per-frame fast, and each read
    -- walks the roster inside the host.
    addon.tick(0.2, render)

    addon.command("focus", function()
        local showing = not Core.settings.get("showFocus")
        Core.settings.set("showFocus", showing)
        log.say("focus bars " .. (showing and "on" or "off") .. "; /lua reload to apply")
    end)

    addon.command("list", function()
        local party = poll.party()
        if #party == 0 then
            log.say("not in a party")
            return
        end
        for _, member in ipairs(party) do
            log.say(string.format("  %-20s %s  %s/%s", member.name,
                member.inScene and "here " or "away ",
                util.comma(member.health), util.comma(member.maxHealth)))
        end
    end)

    return { view = view, render = render }
end
