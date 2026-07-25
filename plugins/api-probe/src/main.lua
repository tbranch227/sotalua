-- API Probe -- read live game state into the chat window.
--
-- No UI. Everything is a slash-callable global, because the host's `/lua <fn>`
-- command invokes a named global on an enabled addon:
--
--   /lua _ApiProbe_api          client API version and feature flags
--   /lua _ApiProbe_stats        every visible stat
--   /lua _ApiProbe_buffs        player, pet and target runes
--   /lua _ApiProbe_target       the current target
--   /lua _ApiProbe_party        party roster with in-scene vitals
--   /lua _ApiProbe_scene        scene, cap, game time
--   /lua _ApiProbe_inventory    inventory totals
--   /lua _ApiProbe_mouse        what is under the cursor
--   /lua _ApiProbe_timers       periodics this client has registered

return function(Core)
    local log, poll, util, env = Core.log, Core.poll, Core.util, Core.env

    local addon = Core.addon.start({
        name = "API Probe",
        slug = "api-probe",
        version = "1.0.0",
        logLevel = "info",
        layout = false,   -- no windows, so skip the drag-watching update hook
    })

    local function heading(title)
        log.say("--- " .. title .. " ---")
    end

    addon.command("api", function()
        heading("API")
        log.say(env.describe())
        log.say("Lua folder: " .. (env.luaPath() ~= "" and env.luaPath() or "(not published yet)"))
        log.say("Data folder: " .. (env.dataPath() ~= "" and env.dataPath() or "(not published yet)"))

        -- The per-frame player globals are pushed lazily on this build, so
        -- report which are live rather than silently reading nil.
        local player = poll.player()
        log.say(string.format("player globals: %s",
            player.available and "all present" or ("MISSING " .. table.concat(player.missing, ", "))))
        log.say(string.format("Screen %dx%d, fullscreen=%s",
            ShroudGetScreenX(), ShroudGetScreenY(), tostring(ShroudGetFullScreen())))
    end)

    addon.command("stats", function()
        heading("Stats")
        local shown = 0
        -- util.stats skips the hidden slots that ShroudGetStatCount includes.
        for index, name, description, value in util.stats() do
            shown = shown + 1
            local label = description ~= name and (name .. " (" .. description .. ")") or name
            log.say(string.format("  [%d] %s = %s", index, label, util.comma(value)))
        end
        log.say(string.format("%d visible of %d slots", shown, ShroudGetStatCount()))
    end)

    local function dumpRunes(title, runes)
        log.say(title .. ": " .. #runes)
        for _, rune in ipairs(runes) do
            log.say(string.format("  %s%s  %s  icon=%d  effects=%d",
                rune.name,
                rune.isDebuff and " [debuff]" or "",
                util.duration(rune.remaining),
                rune.iconId or -1,
                #rune.effects))
            for _, effect in ipairs(rune.effects) do
                log.say(string.format("      %s value=%s %s/%s",
                    tostring(effect.Description),
                    tostring(effect.Value),
                    util.duration(effect.CurrentDuration),
                    util.duration(effect.TotalDuration)))
            end
        end
    end

    addon.command("buffs", function()
        heading("Buffs")
        dumpRunes("Player", poll.playerBuffs())
        dumpRunes("Pet", poll.petBuffs())
        dumpRunes("Target", poll.targetBuffs())
        -- The flat count is larger than the grouped list when one rune applies
        -- several effect components.
        log.say("Flat effect components: " .. tostring(ShroudGetBuffCount()))
    end)

    addon.command("target", function()
        heading("Target")
        local target = poll.target()
        if not target then
            log.say("no target")
            return
        end
        log.say(string.format("%s  id=%d%s", target.name, target.id, target.dead and "  DEAD" or ""))
        if target.healthHidden then
            log.say("  health is hidden; the host reports current == max")
        end
        log.say(string.format("  health %s/%s   focus %s/%s",
            util.comma(target.health), util.comma(target.maxHealth),
            util.comma(target.focus), util.comma(target.maxFocus)))
    end)

    addon.command("party", function()
        heading("Party")
        local party = poll.party()
        if #party == 0 then
            log.say("not in a party")
            return
        end
        for _, member in ipairs(party) do
            log.say(string.format("  [%d] %-20s %s  hp %s/%s  focus %s/%s",
                member.index, member.name,
                member.inScene and "in scene" or "elsewhere",
                util.comma(member.health), util.comma(member.maxHealth),
                util.comma(member.focus), util.comma(member.maxFocus)))
        end
    end)

    addon.command("scene", function()
        heading("Scene")
        local scene = poll.scene()
        if scene then
            log.say(string.format("%s (%s)", scene.name, scene.raw))
            log.say(string.format("  orientation=%d  maxPlayers=%d  pvp=%s  pot=%s",
                scene.orientation, scene.maxPlayers,
                tostring(scene.isPvp), tostring(scene.isPot)))
            if scene.dungeon then
                log.say(string.format("  dungeon %q owned by %s",
                    scene.dungeon, scene.dungeonOwner or "?"))
            end
        end
        local cap = poll.sceneCap()
        if cap then log.say(string.format("  cap: level %d, skill %d", cap.level, cap.skill)) end

        local time = poll.gameTime()
        if time then
            -- Day and Month already carry the engine's +1; do not add another.
            log.say(string.format("  game time: day %d month %d year %d, %s, %s, hour %.1f",
                time.day, time.month, time.year, time.period, time.season, time.hour))
        else
            log.say("  game time unavailable")
        end
        log.say(string.format("  position %.1f, %.1f, %.1f  facing %d",
            ShroudPlayerX, ShroudPlayerY, ShroudPlayerZ, ShroudGetPlayerOrientation()))
    end)

    addon.command("inventory", function()
        heading("Inventory")
        local items = poll.inventory(true)   -- force past the cache
        local totalValue, totalWeight = 0, 0
        for _, item in ipairs(items) do
            totalValue = totalValue + item.value * item.quantity
            totalWeight = totalWeight + (tonumber(item.weight) or 0) * item.quantity
        end
        log.say(string.format("%d stacks, %s gold of value, %.1f stones",
            #items, util.comma(totalValue), totalWeight))

        local sorted = util.sortBy(items, function(item) return item.value * item.quantity end, true)
        for i = 1, math.min(#sorted, 15) do
            local item = sorted[i]
            log.say(string.format("  %4dx %-32s %8s gold%s",
                item.quantity, util.ellipsize(item.name, 32), util.comma(item.value),
                item.createdBy ~= "" and ("  by " .. item.createdBy) or ""))
        end
        if #sorted > 15 then log.say(string.format("  ... and %d more", #sorted - 15)) end
    end)

    addon.command("mouse", function()
        heading("Under the mouse")
        if not env.HAS_MOUSE then
            log.say("this client is API " .. env.API .. "; the under-mouse API needs 2 or newer")
            return
        end
        local hit = poll.underMouse()
        if not hit then
            log.say("nothing under the cursor")
            return
        end
        log.say(string.format("%s  kind=%s  id=%d", hit.name, hit.kind, hit.id))
        if hit.description ~= "" then log.say("  " .. hit.description) end
    end)

    --- Write every host-provided global to a file for offline comparison.
    --
    -- The published reference documents API 3, but a client can report a higher
    -- ShroudLuaApiVersion, and there is no way to know what was added except to
    -- ask the running client. This enumerates _G and dumps anything that looks
    -- like host API, so the result can be diffed against docs/api-index.json.
    --
    -- The file goes in the Lua folder because the sandbox confines io.open
    -- there; a path outside it raises a Lua error.
    addon.command("export", function()
        local lines = {}
        local function add(line) lines[#lines + 1] = line end

        add("# ShroudLuaApiVersion=" .. tostring(ShroudLuaApiVersion))
        add("# generated by api-probe export")

        -- MoonSharp exposes _G, but guard anyway: without enumeration there is
        -- nothing useful to say, and a hard error would just disable the addon.
        --
        -- `names` is declared on its own line on purpose. A local is not in
        -- scope until its declaring statement finishes, so writing
        -- `local names, ok = {}, pcall(...)` would have the closure capture a
        -- *global* names while the local stayed empty.
        local names = {}
        local ok = pcall(function()
            for key, value in pairs(_G) do
                if type(key) == "string" then
                    names[#names + 1] = { name = key, kind = type(value) }
                end
            end
        end)
        if not ok then
            log.say("could not enumerate _G on this client; nothing exported")
            return
        end

        table.sort(names, function(a, b) return a.name < b.name end)

        add("")
        add("## globals")
        local hostCount = 0
        for _, entry in ipairs(names) do
            -- Host API is Shroud-prefixed, plus a handful of documented
            -- un-prefixed names and enum tables.
            if entry.name:match("^Shroud") or entry.name == "InvalidStatResult"
                or entry.name == "ConsoleLog" or entry.name:match("^Get%u") then
                hostCount = hostCount + 1
                local suffix = ""
                if entry.kind ~= "function" then
                    suffix = " = " .. util.ellipsize(tostring(_G[entry.name]), 60)
                end
                add(string.format("%s\t%s%s", entry.name, entry.kind, suffix))
            end
        end

        -- Enum tables, with their members, so a new member shows up too.
        add("")
        add("## enums")
        for _, enum in ipairs({ "UI", "TextAnchor", "ButtonMode", "Transition",
                               "ContentType", "AudioType" }) do
            local value = _G[enum]
            if type(value) == "table" or type(value) == "userdata" then
                local members = {}
                pcall(function()
                    for key in pairs(value) do members[#members + 1] = tostring(key) end
                end)
                table.sort(members)
                add(string.format("%s\t%s", enum, table.concat(members, ",")))
            else
                add(string.format("%s\t%s", enum, type(value)))
            end
        end

        local body = table.concat(lines, "\n") .. "\n"
        local path = env.luaFile("api-export.txt")
        if not path then
            log.say("the host has not published ShroudLuaPath yet; console output follows:")
            for _, line in ipairs(lines) do log.say(line) end
            return
        end

        local file, err = io.open(path, "w")
        if not file then
            log.say("could not write " .. path .. ": " .. tostring(err))
            log.say("falling back to console; " .. hostCount .. " host globals:")
            for _, line in ipairs(lines) do log.say(line) end
            return
        end
        file:write(body)
        file:close()
        log.say(string.format("wrote %d host globals to %s", hostCount, path))
    end)

    addon.command("timers", function()
        heading("Periodics")
        local count = 0
        -- ShroudListPeriodics hands back an enumerator, not a table.
        for name in ShroudListPeriodics() do
            count = count + 1
            log.say("  " .. name)
        end
        if count == 0 then log.say("  none registered") end
    end)

    addon.onStart(function()
        log.info(env.describe())
        log.info("commands: /lua _ApiProbe_api | _stats | _buffs | _target | _party"
            .. " | _scene | _inventory | _mouse | _timers | _export")
    end)

    return { name = "api-probe" }
end
