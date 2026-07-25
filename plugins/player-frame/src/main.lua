-- Player Frame -- your own vitals, the ones the API makes hardest to draw.
--
-- Two problems the API creates here, neither of which the target or party
-- frames have:
--
-- 1. There is no ShroudPlayerMaxHealth. The per-frame globals give the CURRENT
--    health and focus and nothing else, while the target and party APIs both
--    offer explicit max getters. A bar needs a denominator, so the maximum has
--    to come from the stat table -- and the stat names are client data, not
--    published API. Rather than guess, this resolves them at runtime against a
--    list of plausible names, lets the player override the choice, and falls
--    back to a session high-water mark when nothing matches.
--
-- 2. ShroudPlayerCurrentHealth, CurrentFocus and Gold do not exist until their
--    value changes, and /lua reload puts them back into that state. Reading
--    them in ShroudOnStart therefore always yields nothing. Everything here
--    treats absence as "unknown" rather than as zero, and says so on screen.

return function(Core)
    local ui, layout, util, poll, log = Core.ui, Core.layout, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "Player Frame",
        slug = "player-frame",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            healthStat = { default = "", scope = "account" },
            focusStat = { default = "", scope = "account" },
            showGold = { default = true, scope = "account" },
            showPet = { default = true, scope = "account" },
            lowHealthPercent = { default = 35, scope = "account" },
        },
    })

    -- Ordered guesses at what the stat table calls the maxima. The first name
    -- that exists wins, so more specific candidates come first.
    local HEALTH_CANDIDATES = {
        "MaxHealth", "HealthMax", "MaximumHealth", "TotalHealth", "Health",
    }
    local FOCUS_CANDIDATES = {
        "MaxFocus", "FocusMax", "MaximumFocus", "TotalFocus", "Focus",
    }

    local view = {}
    local state = {
        -- Highest value ever observed, used as a denominator when the stat
        -- table yields nothing. Correct once the player has been at full.
        peakHealth = 0,
        peakFocus = 0,
        resolved = { health = nil, focus = nil, source = "unresolved" },
    }

    --- Find a usable maximum for a vital.
    --
    -- Returns the value and a short description of where it came from, so the
    -- player can tell a real stat reading from a high-water guess.
    local function resolveMax(kind, current)
        local override = Core.settings.get(kind == "health" and "healthStat" or "focusStat")
        local candidates = kind == "health" and HEALTH_CANDIDATES or FOCUS_CANDIDATES
        local peakKey = kind == "health" and "peakHealth" or "peakFocus"

        if type(override) == "string" and override ~= "" then
            local value = ShroudGetStatValueByName(override)
            if util.isValid(value) and value > 0 then
                return value, "stat " .. override
            end
        end

        for _, name in ipairs(candidates) do
            local value = ShroudGetStatValueByName(name)
            -- A max below the current reading is not a max; some stat tables
            -- expose a base value that buffs exceed.
            if util.isValid(value) and value > 0
                and (current == nil or value >= current) then
                return value, "stat " .. name
            end
        end

        if current and current > state[peakKey] then state[peakKey] = current end
        if state[peakKey] > 0 then
            return state[peakKey], "session peak"
        end
        return nil, "unknown"
    end

    local function renderVital(bar, current, kind, color)
        if current == nil then
            -- The global does not exist yet. A zero bar would read as "dead".
            layout.setBar(bar, nil, "waiting for the host")
            return
        end

        local maximum, source = resolveMax(kind, current)
        if not maximum then
            layout.setBar(bar, nil, string.format("%s (no maximum)", util.comma(current)))
            return
        end

        local ratio = util.ratio(current, maximum)
        layout.setBar(bar, ratio,
            string.format("%s / %s", util.short(current), util.short(maximum)),
            color or layout.vitalColor(ratio))
        return ratio, source
    end

    local function render()
        if not view.window then return end
        local player = poll.player()

        local name = util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), "Unknown")
        local inCombat = ShroudGetPlayerCombatMode and ShroudGetPlayerCombatMode() or false
        ui.setText(view.name, util.ellipsize(name, 24) .. (inCombat and "   [combat]" or ""))
        ui.setColor(view.name, inCombat and "#FF9A5C" or "#FFFFFF")

        local healthRatio, healthSource = renderVital(view.health, player.health, "health")
        local _, focusSource = renderVital(view.focus, player.focus, "focus", "#4C7AC8")
        state.resolved.source = healthSource or focusSource or "unknown"

        if healthRatio and healthRatio * 100 <= (Core.settings.get("lowHealthPercent") or 35) then
            ui.setColor(view.name, "#FF7A6A")
        end

        if view.gold then
            if player.gold == nil then
                -- Not zero: the player almost certainly has gold, the host just
                -- has not published the global since the last reload.
                ui.setText(view.gold, "gold  waiting for the host")
                ui.setColor(view.gold, "#808080")
            else
                ui.setText(view.gold, "gold  " .. util.comma(player.gold))
                ui.setColor(view.gold, "#FFD98A")
            end
        end

        if view.pet then
            local pet = poll.pet()
            if pet then
                local current = util.numberOr(pet.CurrentHealth, -1)
                local maximum = util.numberOr(pet.MaxHealth, -1)
                ui.setVisible(view.petLabel, true)
                ui.setText(view.petLabel, string.format("%s  lv %s%s",
                    util.ellipsize(tostring(pet.Name or "Pet"), 18),
                    tostring(pet.Level or "?"),
                    pet.isSummon and "  (summon)" or ""))
                local ratio = util.ratio(current, maximum)
                layout.setBar(view.pet, ratio,
                    string.format("%s / %s", util.short(current), util.short(maximum)),
                    layout.vitalColor(ratio))
            else
                ui.setVisible(view.petLabel, false)
                layout.setBar(view.pet, 0, "")
            end
        end
    end

    addon.onStart(function()
        local window = layout.window({
            id = "player",
            title = "Player",
            accentColor = "#4C9A5A",
            x = 280, y = 60, width = 220,
            resizable = "horizontal", minSize = 170, maxSize = 440,
        })
        if not window then
            log.error("could not create the player window")
            return
        end

        view.window = window
        view.name = window:row("", { fontSize = 15 })
        view.health = window:bar({ height = 16 })
        view.focus = window:bar({ height = 12, color = "#4C7AC8" })
        if Core.settings.get("showGold") then
            view.gold = window:row("", { fontSize = 12, color = "#FFD98A" })
        end
        if Core.settings.get("showPet") then
            view.petLabel = window:row("", { fontSize = 11, color = "#C89AE0" })
            view.pet = window:bar({ height = 8, color = "#9A6AC0" })
        end
        window:fit()

        -- Deliberately no attempt to read the player globals here: they do not
        -- exist immediately after a reload, so a baseline taken now is always
        -- empty. render() picks them up whenever the host publishes them.
    end)

    addon.tick(0.2, render)

    addon.command("maxstats", function()
        log.say("--- vital maxima ---")
        local player = poll.player()
        local health, healthSource = resolveMax("health", player.health)
        local focus, focusSource = resolveMax("focus", player.focus)
        log.say(string.format("health max %s  (%s)",
            health and util.comma(health) or "unknown", healthSource))
        log.say(string.format("focus  max %s  (%s)",
            focus and util.comma(focus) or "unknown", focusSource))
        log.say("stat names containing 'health' or 'focus':")
        local found = 0
        for _, statName, description, value in util.stats() do
            local lowered = statName:lower()
            if lowered:find("health") or lowered:find("focus") then
                found = found + 1
                log.say(string.format("  %-28s %-28s %s",
                    statName, description, util.comma(value)))
            end
        end
        if found == 0 then
            log.say("  none; bars fall back to the highest value seen this session")
        end
        log.say("override with: /lua _PlayerFrame_usestat health <StatName>")
    end)

    --- /lua _PlayerFrame_usestat health MaxHealth
    addon.command("usestat", function(which, statName)
        if which ~= "health" and which ~= "focus" then
            log.say("usage: /lua _PlayerFrame_usestat health|focus <StatName>")
            return
        end
        if type(statName) ~= "string" or statName == "" then
            Core.settings.set(which == "health" and "healthStat" or "focusStat", "")
            log.say(which .. " maximum reset to automatic detection")
            return
        end
        local value = ShroudGetStatValueByName(statName)
        if not util.isValid(value) then
            log.say(string.format("no stat named %q on this client; unchanged", statName))
            return
        end
        Core.settings.set(which == "health" and "healthStat" or "focusStat", statName)
        log.say(string.format("%s maximum now reads %s = %s",
            which, statName, util.comma(value)))
    end)

    addon.command("report", function()
        local player = poll.player()
        if not player.available then
            log.say("host has not published: " .. table.concat(player.missing, ", "))
        end
        log.say(string.format("health %s  focus %s  gold %s",
            player.health and util.comma(player.health) or "?",
            player.focus and util.comma(player.focus) or "?",
            player.gold and util.comma(player.gold) or "?"))
    end)

    return { view = view, state = state, render = render, resolveMax = resolveMax }
end
