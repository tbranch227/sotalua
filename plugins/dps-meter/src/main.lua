-- DPS Meter -- damage per second, solo and in a party.
--
-- Built on core/combat, which is the only source of damage information the API
-- offers: the combat log, as text. Two consequences follow from that and shape
-- everything here.
--
-- First, this can only measure what the log carries. Your own damage arrives on
-- the CombatSelf channel, confirmed. Whether a party member's damage reaches an
-- addon at all is a property of the client and the player's chat settings, not
-- something an addon can arrange, so the meter reports which channels it has
-- seen rather than pretending a silent party member did no damage.
--
-- Second, an "encounter" has to be inferred. There is no combat-start or
-- combat-end event, so a fight begins at the first damage after a quiet period
-- and ends once the log goes quiet again.

return function(Core)
    local ui, layout, util, poll, log, combat =
        Core.ui, Core.layout, Core.util, Core.poll, Core.log, Core.combat

    local addon = Core.addon.start({
        name = "DPS Meter",
        slug = "dps-meter",
        version = "1.0.0",
        store = { name = "dps", flushSeconds = 60 },
        settings = {
            windows = { default = {} },
            rows = { default = 6, scope = "account" },
            encounterGap = { default = 5, scope = "account" },
            includeUnknown = { default = false, scope = "account" },
            best = { default = { dps = 0 } },
        },
    })

    -- Damage inside this window feeds the "current" figure. Long enough to ride
    -- out a slow cast, short enough to still read as live.
    local LIVE_WINDOW = 10

    local view = { rows = {} }
    local state = {
        actors = {},        -- name -> { damage, hits, crits, source, last }
        events = {},        -- rolling { at, name, damage } for the live window
        startedAt = nil,
        lastAt = nil,
        total = 0,
        encounters = 0,
        excluded = 0,       -- damage from actors we deliberately do not count
        finished = nil,     -- summary of the fight just ended
    }

    local function now() return ShroudTime or 0 end

    local function gap() return Core.settings.get("encounterGap") or 5 end

    ----------------------------------------------------------------------
    -- Encounter bookkeeping
    ----------------------------------------------------------------------

    local function duration()
        if not state.startedAt then return 0 end
        return math.max((state.lastAt or state.startedAt) - state.startedAt, 0)
    end

    --- Close the current fight, record it, and clear for the next one.
    local function endEncounter()
        if not state.startedAt then return end

        local seconds = duration()
        local dps = seconds > 0 and (state.total / seconds) or 0

        -- A fight of a single hit has no meaningful duration, so its "dps"
        -- would be the whole hit divided by nearly zero. Not recorded.
        if seconds >= 1 and state.total > 0 then
            state.encounters = state.encounters + 1
            state.finished = { total = state.total, seconds = seconds, dps = dps }

            local breakdown = {}
            for name, actor in pairs(state.actors) do
                breakdown[name] = actor.damage
            end
            Core.store.append("encounter", {
                seconds = math.floor(seconds + 0.5),
                total = state.total,
                dps = math.floor(dps + 0.5),
                scene = (poll.scene() or {}).name or "",
                actors = breakdown,
            })

            local best = Core.settings.get("best") or { dps = 0 }
            if dps > (best.dps or 0) then
                Core.settings.set("best", {
                    dps = math.floor(dps + 0.5),
                    total = state.total,
                    seconds = math.floor(seconds + 0.5),
                    at = ShroudServerTime or "",
                })
                log.info(string.format("best fight so far: %s dps over %s",
                    util.comma(math.floor(dps)), util.duration(seconds)))
            end
        end

        state.actors = {}
        state.events = {}
        state.startedAt = nil
        state.lastAt = nil
        state.total = 0
    end

    ----------------------------------------------------------------------
    -- Recording
    ----------------------------------------------------------------------

    --- The label a hit should be filed under, or nil to ignore it.
    --
    -- Enemies hitting you appear in the same log with the same shape, so
    -- without this the meter would list every mob in the room as a damage
    -- dealer. Only you, your pet and party members count.
    local function actorFor(hit)
        local kind = combat.classify(hit.attacker)
        if kind == "self" then return "You", kind end
        if kind == "pet" then return (combat.petName() or "Pet"), kind end
        if kind == "party" then return hit.attacker, kind end
        if Core.settings.get("includeUnknown") then return hit.attacker, "other" end
        return nil
    end

    local function record(hit)
        local name, kind = actorFor(hit)
        if not name then
            state.excluded = state.excluded + 1
            -- Remembered so the window can say *who* was ignored. If the client
            -- writes your name differently from ShroudGetPlayerName(), every
            -- one of your own hits lands here and the meter looks broken.
            state.lastIgnored = hit.attacker
            return
        end

        local at = now()
        if state.startedAt and (at - (state.lastAt or at)) > gap() then
            endEncounter()
        end
        if not state.startedAt then
            state.startedAt = at
            state.finished = nil
        end
        state.lastAt = at

        local actor = state.actors[name]
        if not actor then
            actor = { damage = 0, hits = 0, crits = 0, source = kind }
            state.actors[name] = actor
        end
        actor.damage = actor.damage + hit.damage
        actor.hits = actor.hits + 1
        if hit.critical then actor.crits = actor.crits + 1 end
        actor.last = at

        state.total = state.total + hit.damage
        state.events[#state.events + 1] = { at = at, name = name, damage = hit.damage }
    end

    --- Damage in the last LIVE_WINDOW seconds, per actor and overall.
    local function liveWindow()
        local cutoff = now() - LIVE_WINDOW
        -- Trim from the front; the list is append-ordered by time.
        while state.events[1] and state.events[1].at < cutoff do
            table.remove(state.events, 1)
        end

        local perActor, total = {}, 0
        for _, event in ipairs(state.events) do
            perActor[event.name] = (perActor[event.name] or 0) + event.damage
            total = total + event.damage
        end
        return perActor, total
    end

    ----------------------------------------------------------------------
    -- Display
    ----------------------------------------------------------------------

    local SOURCE_COLOR = {
        self = "#9FE08F", pet = "#C89AE0", party = "#7FB8FF", other = "#A0A0A0",
    }

    --- What to show when there is nothing to show.
    --
    -- An empty meter has several quite different causes, and the player cannot
    -- tell them apart by looking. Since this client offers no `/lua` commands,
    -- the window is the only place a diagnosis can appear at all, so it says
    -- which stage is failing rather than an unhelpful "waiting".
    local function renderIdle()
        local lines, broken = combat.diagnose()

        -- combat.diagnose only sees as far as parsing. Damage that parsed and
        -- was then filtered out is this addon's own doing, so it explains it.
        if not broken and combat.stats.parsed > 0 and state.excluded > 0 then
            local mine = util.nameOr(ShroudGetPlayerName and ShroudGetPlayerName(), nil)
            lines = {
                { text = state.excluded .. " hit(s) ignored as not yours", color = "#E08A5C" },
                { text = "log says \"" .. util.ellipsize(state.lastIgnored or "?", 20)
                    .. "\"", color = "#909090" },
                { text = "you are \"" .. (mine or "unknown") .. "\"", color = "#909090" },
            }
        elseif not broken then
            lines = { { text = "waiting for combat...", color = "#808080" } }
        end

        for index, row in ipairs(view.rows) do
            local line = lines[index]
            ui.setText(row, line and line.text or "")
            if line then ui.setColor(row, line.color) end
        end
    end

    local function render()
        if not view.window then return end

        local seconds = duration()
        local live, liveTotal = liveWindow()
        local idle = state.lastAt and (now() - state.lastAt) or 0

        -- Close a finished fight even with no further damage arriving.
        if state.startedAt and idle > gap() then endEncounter() end

        local ranked = {}
        for name, actor in pairs(state.actors) do
            ranked[#ranked + 1] = {
                name = name,
                damage = actor.damage,
                hits = actor.hits,
                crits = actor.crits,
                source = actor.source,
                dps = seconds > 0 and (actor.damage / seconds) or 0,
                liveDps = (live[name] or 0) / LIVE_WINDOW,
            }
        end
        ranked = util.sortBy(ranked, function(item) return item.damage end, true)

        if state.startedAt then
            view.window:setTitle(string.format("DPS  %s over %s",
                util.short(seconds > 0 and state.total / seconds or 0), util.duration(seconds)))
        elseif state.finished then
            view.window:setTitle(string.format("DPS  last %s over %s",
                util.short(state.finished.dps), util.duration(state.finished.seconds)))
        else
            view.window:setTitle("DPS  idle")
        end

        for i, row in ipairs(view.rows) do
            local entry = ranked[i]
            if entry then
                local share = state.total > 0 and (entry.damage / state.total * 100) or 0
                ui.setText(row, string.format("%-12s %7s  %3d%%  %s",
                    util.ellipsize(entry.name, 12),
                    util.short(entry.dps),
                    math.floor(share + 0.5),
                    util.short(entry.damage)))
                ui.setColor(row, SOURCE_COLOR[entry.source] or "#FFFFFF")
            else
                ui.setText(row, "")
            end
        end

        if #ranked == 0 then renderIdle() end

        ui.setText(view.live, string.format("last %ds: %s dps",
            LIVE_WINDOW, util.short(liveTotal / LIVE_WINDOW)))

        local best = Core.settings.get("best") or {}
        ui.setText(view.footer, string.format("%d fight%s   best %s dps%s",
            state.encounters, state.encounters == 1 and "" or "s",
            util.short(best.dps or 0),
            state.excluded > 0 and ("   " .. state.excluded .. " ignored") or ""))
    end

    ----------------------------------------------------------------------
    -- Wiring
    ----------------------------------------------------------------------

    -- Subscribed at file scope, not inside ShroudOnStart. The host captures an
    -- addon's callbacks right after the body runs, and core/events only
    -- publishes a callback that something has subscribed to by then -- so a
    -- chat subscription made during ShroudOnStart arrives too late and
    -- ShroudOnConsoleInput is never installed at all.
    combat.install()
    combat.onDamage(function(hit) record(hit) end, "dps.record")

    addon.onStart(function()
        local rows = util.clamp(Core.settings.get("rows") or 6, 1, 12)
        local window = layout.window({
            id = "dps",
            title = "DPS",
            accentColor = "#E08A5C",
            x = 980, y = 320, width = 250,
            resizable = "horizontal", minSize = 200, maxSize = 500,
        })
        if not window then
            log.error("could not create the DPS window")
            return
        end

        view.window = window
        for _ = 1, rows do
            view.rows[#view.rows + 1] = window:row("", { fontSize = 12, height = 15, gap = 0 })
        end
        view.live = window:row("", { fontSize = 11, color = "#B0B0B0" })
        view.footer = window:row("", { fontSize = 10, color = "#808080" })
        window:fit()
    end)

    addon.tick(0.5, render)

    -- A fight that ends when the player walks away still has to be closed, and
    -- a scene change certainly ends it.
    addon.onSceneLoaded(endEncounter)
    addon.onLogOut(endEncounter)
    addon.onDisable(endEncounter)

    ----------------------------------------------------------------------
    -- Commands
    ----------------------------------------------------------------------

    addon.command("reset", function()
        state.actors, state.events = {}, {}
        state.startedAt, state.lastAt, state.total = nil, nil, 0
        state.encounters, state.excluded, state.finished = 0, 0, nil
        log.say("dps meter reset")
    end)

    addon.command("report", function()
        local seconds = duration()
        log.say("--- dps ---")
        if seconds <= 0 and not state.finished then
            log.say("no fight recorded yet")
        else
            local shown = state.finished or
                { total = state.total, seconds = seconds,
                  dps = seconds > 0 and state.total / seconds or 0 }
            log.say(string.format("%s damage over %s = %s dps",
                util.comma(shown.total), util.duration(shown.seconds),
                util.comma(math.floor(shown.dps))))
        end
        for name, actor in pairs(state.actors) do
            log.say(string.format("  %-16s %8s  %d hits, %d crit",
                name, util.comma(actor.damage), actor.hits, actor.crits))
        end
        local best = Core.settings.get("best") or {}
        if best.dps and best.dps > 0 then
            log.say(string.format("best: %s dps over %s",
                util.comma(best.dps), util.duration(best.seconds or 0)))
        end
    end)

    --- Which chat channels carry damage. Answers whether a party member's
    --- damage reaches addons at all on this client.
    addon.command("channels", function()
        log.say("--- combat log channels seen ---")
        local seen = combat.channels()
        if #seen == 0 then
            log.say("none yet; no chat has reached this addon")
            return
        end
        for _, channel in ipairs(seen) do
            log.say(string.format("  %-16s %d line(s)", channel.name, channel.count))
        end
        log.say(string.format("%d damage line(s) parsed, %d ignored as not yours"
            .. " or your party's", combat.stats.parsed, state.excluded))
        log.say("if a party member's damage is missing, their lines are not"
            .. " reaching addons; enable their combat channel in chat options")
    end)

    addon.command("everyone", function()
        local include = not Core.settings.get("includeUnknown")
        Core.settings.set("includeUnknown", include)
        log.say("counting " .. (include and "every attacker, including enemies"
            or "only you, your pet and your party"))
    end)

    return {
        view = view, state = state, render = render, record = record,
        endEncounter = endEncounter, liveWindow = liveWindow, actorFor = actorFor,
    }
end
