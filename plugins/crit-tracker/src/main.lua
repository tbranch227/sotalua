-- Crit Tracker -- personal best critical hit per skill.
--
-- The API exposes no combat data at all. There is no damage event, no damage
-- getter, and nothing that attributes a hit to a skill; the only channel
-- carrying that information is ShroudOnConsoleInput, which delivers chat lines
-- as plain strings. So this is a log parser, and it is only as good as its
-- patterns.
--
-- The patterns below are candidates, not confirmed facts. The exact wording of
-- combat text is client data that is not published anywhere, so `capture` mode
-- exists to record real lines and `pattern` lets a confirmed format be added
-- without rebuilding. Until a pattern matches, this addon records nothing --
-- it will not invent numbers.
--
-- Diffing target health was considered as an alternative and rejected: it
-- cannot separate your damage from a party member's, from a damage-over-time
-- tick, or from a heal, and it cannot name the skill responsible.

return function(Core)
    local ui, fx, util, poll, log = Core.ui, Core.fx, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "Crit Tracker",
        slug = "crit-tracker",
        version = "1.0.0",
        store = { name = "crits", flushSeconds = 60 },
        settings = {
            windows = { default = {} },
            records = { default = {} },        -- skill -> best hit
            characterName = { default = "" },  -- override for combat-log matching
            extraPatterns = { default = {}, scope = "account" },
            capture = { default = false },
            alertSeconds = { default = 4, scope = "account" },
            minimumDamage = { default = 1, scope = "account" },
        },
    })

    ----------------------------------------------------------------------
    -- Parsing
    ----------------------------------------------------------------------

    -- The confirmed client format, captured from a live game:
    --
    --   Zealot attacks Death Metal Slime and hits, dealing 254 points of
    --   critical damage from Chaos Bolt.
    --
    -- Note "1 point" versus "254 points", and that the line names the attacker
    -- first. That last detail matters more than it looks: the same message is
    -- printed for everyone in the area, so a party member's critical would be
    -- filed as yours unless the attacker is checked.
    --
    -- Lua patterns, not regex: no alternation, no quantified groups. `captures`
    -- names each capture in order.
    local PATTERNS = {
        {
            pattern = "^(.-) attacks (.-) and hits, dealing (%d+) points? of critical damage from (.+)$",
            captures = { "attacker", "target", "damage", "skill" },
        },
        -- Fallback for a phrasing that omits the attacker clause entirely. Only
        -- tried when the line has no " attacks " in it, so a line naming an
        -- attacker we failed to parse is skipped rather than misattributed.
        {
            pattern = "dealing (%d+) points? of critical damage from (.+)$",
            captures = { "damage", "skill" },
            onlyWithoutAttacker = true,
        },
    }

    -- Cheap rejection before running any pattern. ShroudOnConsoleInput fires
    -- for every chat line, and combat is exactly when the volume is highest.
    local KEYWORDS = { "critical", "crit " }

    local function looksLikeCrit(message)
        local lowered = message:lower()
        for _, keyword in ipairs(KEYWORDS) do
            if lowered:find(keyword, 1, true) then return true end
        end
        return false
    end

    local function tidySkill(name)
        name = util.trim(tostring(name or ""))
        -- Strip leading articles and trailing punctuation the phrasing leaves.
        name = name:gsub("^[Tt]he%s+", ""):gsub("[%.,!:;]+$", "")
        if name == "" then return nil end
        if #name > 48 then return nil end        -- captured too much
        return name
    end

    --- Try every pattern, built-in then user-supplied.
    --
    -- Returns a table { skill, damage, attacker, target } or nil. A custom
    -- pattern added at runtime is assumed to capture skill then damage, which
    -- is the shape the command documents.
    local function parse(message)
        local hasAttacker = message:find(" attacks ", 1, true) ~= nil

        local candidates = {}
        for _, entry in ipairs(PATTERNS) do candidates[#candidates + 1] = entry end
        for _, raw in ipairs(Core.settings.get("extraPatterns") or {}) do
            candidates[#candidates + 1] = { pattern = raw, captures = { "skill", "damage" } }
        end

        for _, entry in ipairs(candidates) do
            if not (entry.onlyWithoutAttacker and hasAttacker) then
                local ok, a, b, c, d = pcall(string.match, message, entry.pattern)
                if ok and a then
                    local found = { a, b, c, d }
                    local fields = {}
                    for index, name in ipairs(entry.captures) do
                        fields[name] = found[index]
                    end

                    local damage = tonumber(fields.damage)
                    local skill = tidySkill(fields.skill)
                    if skill and damage and damage > 0 then
                        return {
                            skill = skill,
                            damage = damage,
                            attacker = fields.attacker and util.trim(fields.attacker) or nil,
                            target = fields.target and util.trim(fields.target) or nil,
                        }
                    end
                end
            end
        end
        return nil
    end

    --- Is this line describing the tracked character's own hit?
    --
    -- The combat log is broadcast for everyone nearby, so without this every
    -- party member's critical would land in your records. An override exists
    -- because ShroudGetPlayerName returns the display name, which need not be
    -- exactly the name the combat log prints.
    local function isSelf(attacker)
        if not attacker or attacker == "" then
            -- No attacker in the line: the fallback pattern only runs when the
            -- line named nobody, so there is no one else it could belong to.
            return true
        end

        local override = Core.settings.get("characterName")
        local mine = (type(override) == "string" and override ~= "")
            and override
            or util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), nil)
        if not mine then return false end

        local a, b = attacker:lower(), mine:lower()
        if a == b then return true end
        -- Tolerate one being a leading part of the other ("Zealot" against
        -- "Zealot Ravenmoor"), but only on a word boundary.
        return a:sub(1, #b + 1) == b .. " " or b:sub(1, #a + 1) == a .. " "
    end

    ----------------------------------------------------------------------
    -- Records
    ----------------------------------------------------------------------

    local view = { rows = {} }
    local state = { lastAlert = nil, parsed = 0, captured = 0, unmatched = 0, others = 0 }

    local function records()
        return Core.settings.get("records") or {}
    end

    local function sortedRecords()
        local out = {}
        for skill, entry in pairs(records()) do
            out[#out + 1] = { skill = skill, damage = entry.damage or 0,
                              at = entry.at, scene = entry.scene, target = entry.target }
        end
        return util.sortBy(out, function(item) return item.damage end, true)
    end

    --- Celebrate a new personal best.
    local function alert(skill, damage, previous)
        if not view.alertText then return end

        ui.setText(view.alertText, string.format("NEW BEST  %s  %s",
            util.ellipsize(skill, 22), util.comma(damage)))
        ui.setText(view.alertSub, previous
            and string.format("beat %s by %s", util.comma(previous), util.comma(damage - previous))
            or "first record")

        local width = ShroudGetScreenX and ShroudGetScreenX() or 1920
        local height = ShroudGetScreenY and ShroudGetScreenY() or 1080
        ui.setPosition(view.alertPanel, width * 0.5 - 160, height * 0.30)
        ui.setVisible(view.alertPanel, true)

        fx.scale(view.alertPanel, 0.7, 1.0, 0.4, fx.ease.outBack)
        fx.flash(view.alertBar, "#FFE9A8", "#C8A020", 0.5)
        fx.tween({
            from = 0, to = 1, duration = Core.settings.get("alertSeconds") or 4,
            onUpdate = function(_, eased)
                ui.setAlpha(view.alertPanel, eased < 0.7 and 1 or (1 - (eased - 0.7) / 0.3))
            end,
            onComplete = function() ui.setVisible(view.alertPanel, false) end,
        })

        log.say(string.format("New best critical: %s for %s%s",
            skill, util.comma(damage),
            previous and (" (was " .. util.comma(previous) .. ")") or ""))
    end

    --- Record a crit, alerting when it beats the stored best.
    local function record(hit, message)
        local skill, damage = hit.skill, hit.damage
        if damage < (Core.settings.get("minimumDamage") or 1) then return false end

        local scene = poll.scene()
        -- The target named in the line is authoritative: poll.target() is
        -- whatever is selected now, which during a fight is often something
        -- else by the time the message arrives.
        local target = hit.target or (poll.target() and poll.target().name) or ""

        Core.store.append("crit", {
            skill = skill, damage = damage,
            scene = scene and scene.name or "",
            target = target,
            line = message,
        })

        local stored = records()
        local previous = stored[skill] and stored[skill].damage or nil

        if previous and damage <= previous then return false end

        Core.settings.update("records", function(all)
            all[skill] = {
                damage = damage,
                at = ShroudServerTime or "",
                scene = scene and scene.name or "",
                target = target,
            }
        end)

        -- A first sighting is stored quietly; there is nothing to beat yet, and
        -- alerting on every new skill would fire constantly on a fresh install.
        if previous then
            state.lastAlert = { skill = skill, damage = damage, previous = previous }
            alert(skill, damage, previous)
        end
        return true
    end

    ----------------------------------------------------------------------
    -- Chat handling
    ----------------------------------------------------------------------

    addon.onChat(function(inputType, source, message)
        if type(message) ~= "string" or message == "" then return end

        if Core.settings.get("capture") then
            -- Discovery mode: record everything verbatim, with its type, so the
            -- real combat format can be read back offline.
            state.captured = state.captured + 1
            Core.store.append("chat", {
                inputType = tostring(inputType or ""),
                source = tostring(source or ""),
                line = message,
            })
            log.say(string.format("[%s] %s | %s",
                tostring(inputType), tostring(source), message))
        end

        if not looksLikeCrit(message) then return end

        local hit = parse(message)
        if not hit then
            state.unmatched = state.unmatched + 1
            -- Worth surfacing: a line that mentions a critical but matches no
            -- pattern is exactly the sample needed to fix the pattern.
            log.debug("unmatched crit line:", message)
            return
        end

        if not isSelf(hit.attacker) then
            -- Someone else's critical. The combat log is broadcast to everyone
            -- nearby, so this is the common case in a party.
            state.others = state.others + 1
            return
        end

        state.parsed = state.parsed + 1
        record(hit, message)
    end)

    ----------------------------------------------------------------------
    -- Window
    ----------------------------------------------------------------------

    local function render()
        if not view.window then return end
        local sorted = sortedRecords()

        view.window:setTitle(string.format("Crit Records  (%d)", #sorted))

        for i, row in ipairs(view.rows) do
            local entry = sorted[i]
            if entry then
                ui.setText(row, string.format("%-20s %8s",
                    util.ellipsize(entry.skill, 20), util.comma(entry.damage)))
            else
                ui.setText(row, "")
            end
        end

        if #sorted == 0 then
            ui.setText(view.rows[1] or view.status, "no records yet")
        end

        ui.setText(view.status, string.format("%d mine, %d others, %d unmatched%s",
            state.parsed, state.others, state.unmatched,
            Core.settings.get("capture") and "  [CAPTURING]" or ""))
    end

    addon.onStart(function()
        local window = Core.layout.window({
            id = "crits",
            title = "Crit Records",
            accentColor = "#C8A020",
            x = 980, y = 60, width = 250,
            resizable = "horizontal", minSize = 200, maxSize = 500,
        })
        if window then
            view.window = window
            for _ = 1, 8 do
                view.rows[#view.rows + 1] = window:row("", { fontSize = 12, height = 15, gap = 0 })
            end
            view.status = window:row("", { fontSize = 10, color = "#808080" })
            window:fit()
        end

        -- The alert lives outside the window so it can appear centre-screen.
        view.alertPanel = ui.panel({
            x = 0, y = 0, width = 320, height = 54,
            color = "#1A1508", alpha = 0.95,
        })
        if view.alertPanel then
            ui.setRaycast(view.alertPanel, false)
            view.alertBar = ui.panel({
                parent = view.alertPanel, x = 0, y = 0, width = 320, height = 3,
                color = "#C8A020",
            })
            view.alertText = ui.text({
                parent = view.alertPanel, text = "", x = 10, y = 10,
                width = 300, height = 22, fontSize = 17, color = "#FFE9A8",
            })
            view.alertSub = ui.text({
                parent = view.alertPanel, text = "", x = 10, y = 32,
                width = 300, height = 18, fontSize = 12, color = "#C0B080",
            })
            for _, widget in ipairs({ view.alertBar, view.alertText, view.alertSub }) do
                ui.setRaycast(widget, false)
            end
            ui.setVisible(view.alertPanel, false)
        end

        log.info("no combat API exists, so this parses chat."
            .. " If nothing appears during a fight, run /lua _CritTracker_capture")
    end)

    addon.tick(1.0, render)

    ----------------------------------------------------------------------
    -- Commands
    ----------------------------------------------------------------------

    addon.command("capture", function()
        local enabled = not Core.settings.get("capture")
        Core.settings.set("capture", enabled)
        if enabled then
            log.say("capturing every chat line to the console and the event log.")
            log.say("fight something, then run /lua _CritTracker_capture again to stop.")
        else
            log.say(string.format("capture off; %d line(s) recorded to the crits log",
                state.captured))
        end
    end)

    addon.command("records", function()
        local sorted = sortedRecords()
        if #sorted == 0 then
            log.say("no records yet")
            return
        end
        log.say(string.format("%d skill record(s):", #sorted))
        for _, entry in ipairs(sorted) do
            log.say(string.format("  %-24s %10s   %s%s",
                entry.skill, util.comma(entry.damage),
                entry.target ~= "" and ("vs " .. entry.target) or "",
                entry.scene ~= "" and ("  in " .. entry.scene) or ""))
        end
    end)

    --- Try a line against the patterns without waiting for combat.
    addon.command("test", function(...)
        local message = table.concat({ ... }, " ")
        if message == "" then
            log.say("usage: /lua _CritTracker_test <a line of combat text>")
            return
        end
        log.say("keyword match: " .. tostring(looksLikeCrit(message)))
        local hit = parse(message)
        if hit then
            log.say(string.format("skill=%q damage=%d attacker=%q target=%q",
                hit.skill, hit.damage, hit.attacker or "", hit.target or ""))
            log.say("counts as mine: " .. tostring(isSelf(hit.attacker)))
        else
            log.say("no pattern matched; add one with /lua _CritTracker_pattern")
        end
    end)

    --- Show, and optionally set, the name matched against the combat log.
    addon.command("whoami", function(...)
        local override = util.trim(table.concat({ ... }, " "))
        if override ~= "" then
            Core.settings.set("characterName", override)
            log.say("combat log lines will be matched against " .. override)
            return
        end
        local detected = util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), "(unknown)")
        local stored = Core.settings.get("characterName")
        log.say("ShroudGetPlayerName reports: " .. detected)
        log.say("override: " .. ((stored ~= "" and stored) or "(none)"))
        log.say("if other players' criticals are being recorded as yours,"
            .. " set it with /lua _CritTracker_whoami <YourName>")
    end)

    --- Add a Lua pattern capturing (skill, damage), in that order.
    addon.command("pattern", function(...)
        local raw = table.concat({ ... }, " ")
        if raw == "" then
            local extra = Core.settings.get("extraPatterns") or {}
            log.say(string.format("%d custom pattern(s):", #extra))
            for i, entry in ipairs(extra) do log.say("  " .. i .. ": " .. entry) end
            log.say("add: /lua _CritTracker_pattern <lua pattern with two captures>")
            return
        end
        local ok = pcall(string.match, "probe", raw)
        if not ok then
            log.say("that is not a valid Lua pattern")
            return
        end
        Core.settings.update("extraPatterns", function(list)
            list[#list + 1] = raw
        end)
        log.say("pattern added; test it with /lua _CritTracker_test <line>")
    end)

    addon.command("forget", function(skill)
        if not skill or skill == "" then
            log.say("usage: /lua _CritTracker_forget <SkillName>  (or: all)")
            return
        end
        if skill == "all" then
            Core.settings.set("records", {})
            log.say("all records cleared")
            return
        end
        Core.settings.update("records", function(all) all[skill] = nil end)
        log.say("cleared the record for " .. tostring(skill))
    end)

    return {
        view = view, state = state, parse = parse, record = record, isSelf = isSelf,
        records = records, sortedRecords = sortedRecords, looksLikeCrit = looksLikeCrit,
    }
end
