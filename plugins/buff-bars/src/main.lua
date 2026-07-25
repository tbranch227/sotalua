-- Buff Bars -- rune timers for the player and pet.
--
-- Notes that shape this:
--
-- * ShroudGetPlayerBuff groups effects by rune, so its list is shorter than the
--   flat ShroudGetBuffCount. The grouped view is the one that matches the stock
--   buff bar, so it is what gets drawn.
-- * StackCount is documented as the number of grouped effect entries, "an upper
--   bound on true stacks", so it is labelled "effects" rather than "stacks".
-- * A rune carries no duration of its own; core/poll takes the longest of its
--   effects, which is what the game's own bar shows.
-- * Icons (IconId / ShroudGetBuffIcon) arrived in API 3. On an older client the
--   rows fall back to text only, so the addon still works at min_api_version 1.

return function(Core)
    local ui, layout, util, poll, env, log = Core.ui, Core.layout, Core.util, Core.poll, Core.env, Core.log

    local addon = Core.addon.start({
        name = "Buff Bars",
        slug = "buff-bars",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            rows = { default = 10, scope = "account" },
            showPet = { default = true, scope = "account" },
            expiringSeconds = { default = 10, scope = "account" },
        },
    })

    local view = { rows = {}, pet = {} }

    --- Colour a row by what it is and how close it is to falling off.
    local function rowColor(rune, expiring)
        if rune.remaining >= 0 and rune.remaining <= expiring then
            return "#FF8A5C"
        end
        return rune.isDebuff and "#E08A8A" or "#9FE08F"
    end

    local function formatRune(rune)
        local timing
        if rune.remaining < 0 then
            timing = "perm"   -- the host uses -1 for an indefinite effect
        else
            timing = util.duration(rune.remaining)
        end

        local suffix = ""
        if rune.effectCount > 1 then
            suffix = string.format(" (%d)", rune.effectCount)
        end
        return string.format("%-24s %6s", util.ellipsize(rune.name .. suffix, 24), timing)
    end

    local function renderInto(rows, runes, expiring, overflow)
        -- Sort by urgency, with indefinite effects last.
        runes = util.sortBy(runes, function(rune)
            return rune.remaining < 0 and math.huge or rune.remaining
        end)

        for i, row in ipairs(rows) do
            local rune = runes[i]
            if rune then
                ui.setText(row.text, formatRune(rune))
                ui.setColor(row.text, rowColor(rune, expiring))
                if row.icon then
                    -- IconId is -1 for creature and NPC runes that have no
                    -- skill icon; leave the slot blank rather than showing a
                    -- broken texture.
                    if rune.iconId and rune.iconId >= 0 then
                        ui.setTexture(row.icon, rune.iconId)
                        ui.setVisible(row.icon, true)
                    else
                        ui.setVisible(row.icon, false)
                    end
                end
            else
                ui.setText(row.text, "")
                if row.icon then ui.setVisible(row.icon, false) end
            end
        end

        if overflow then
            if #runes > #rows then
                ui.setText(overflow, string.format("+%d more", #runes - #rows))
            else
                ui.setText(overflow, "")
            end
        end
    end

    local function buildRows(window, count, withIcons)
        local rows = {}
        for _ = 1, count do
            local y = window.nextY
            local row = {}
            if withIcons then
                -- The icon needs a valid texture at creation time, so it is
                -- created from the first real icon id later; a placeholder image
                -- would need artwork this addon deliberately does not ship.
                row.iconY = y
            end
            row.text = window:row("", { fontSize = 12, height = 15, gap = 1,
                                        x = withIcons and 24 or 8,
                                        width = window.width - (withIcons and 32 or 16) })
            rows[#rows + 1] = row
        end
        return rows
    end

    addon.onStart(function()
        local rows = util.clamp(Core.settings.get("rows") or 10, 1, 20)

        local window = layout.window({
            id = "buffs",
            title = "Buffs",
            x = 20, y = 400, width = 250,
            resizable = "horizontal", minSize = 190, maxSize = 500,
        })
        if not window then return end

        view.window = window
        view.rows = buildRows(window, rows, false)
        view.overflow = window:row("", { fontSize = 10, color = "#808080" })

        if Core.settings.get("showPet") then
            view.petHeading = window:row("Pet", { fontSize = 12, color = "#C89AE0" })
            view.pet = buildRows(window, 4, false)
        end
        window:fit()

        if not env.HAS_ICONS then
            log.info("client is API " .. env.API .. "; skill icons need API 3, showing text rows")
        end
    end)

    -- Four times a second is plenty for second-resolution timers, and every
    -- buff call snapshots the whole effect array inside the host.
    addon.tick(0.25, function()
        if not view.window then return end
        local expiring = Core.settings.get("expiringSeconds") or 10

        renderInto(view.rows, poll.playerBuffs(), expiring, view.overflow)

        if view.petHeading then
            local petRunes = poll.petBuffs()
            local pet = poll.pet()
            ui.setText(view.petHeading, pet and ("Pet: " .. tostring(pet.Name)) or "Pet")
            ui.setVisible(view.petHeading, pet ~= nil)
            renderInto(view.pet, petRunes, expiring, nil)
        end
    end)

    addon.command("pet", function()
        local showing = not Core.settings.get("showPet")
        Core.settings.set("showPet", showing)
        log.say("pet buffs " .. (showing and "on" or "off") .. "; /lua reload to apply")
    end)

    addon.command("list", function()
        local runes = poll.playerBuffs()
        log.say(string.format("%d rune(s) active", #runes))
        for _, rune in ipairs(runes) do
            log.say("  " .. formatRune(rune) .. (rune.isDebuff and "  [debuff]" or ""))
        end
    end)

    return { view = view, formatRune = formatRune }
end
