-- Scene Info -- location, rules, and a corrected compass.
--
-- The compass is the interesting part. ShroudGetPlayerOrientation() is a
-- rounded Y euler angle in 0..360 in world space, but scenes are not all
-- aligned to world north: ShroudGetCurrentSceneOrientation() gives the scene's
-- compass offset in degrees. Subtracting it turns a world facing into the
-- heading the in-game map would agree with.
--
-- The level and skill caps come from ShroudGetSceneCap(), which is worth
-- surfacing because entering a capped scene silently limits what your
-- character can do.

return function(Core)
    local ui, layout, util, poll, log = Core.ui, Core.layout, Core.util, Core.poll, Core.log

    local addon = Core.addon.start({
        name = "Scene Info",
        slug = "scene-info",
        version = "1.0.0",
        settings = {
            windows = { default = {} },
            showCoordinates = { default = true, scope = "account" },
            showRawName = { default = false, scope = "account" },
        },
    })

    local view = {}

    local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

    local function heading()
        local facing = util.numberOr(ShroudGetPlayerOrientation and ShroudGetPlayerOrientation(), 0)
        local scene = poll.scene()
        -- Correct world facing into scene-relative compass space.
        local corrected = (facing - (scene and scene.orientation or 0)) % 360
        local index = math.floor((corrected + 22.5) / 45) % 8 + 1
        return COMPASS[index], corrected
    end

    local function render()
        if not view.window then return end
        local scene = poll.scene()

        if not scene then
            ui.setText(view.name, "unknown scene")
            return
        end

        ui.setText(view.name, util.ellipsize(scene.name, 30))
        if view.raw then
            ui.setText(view.raw, scene.raw or "")
        end

        -- Rule flags first; these change what you are allowed to do here.
        local flags = {}
        if scene.isPvp then flags[#flags + 1] = "PVP" end
        if scene.isPot then flags[#flags + 1] = "player town" end
        local cap = poll.sceneCap()
        if cap then
            if util.isValid(cap.level) and cap.level > 0 then
                flags[#flags + 1] = "level cap " .. cap.level
            end
            if util.isValid(cap.skill) and cap.skill > 0 then
                flags[#flags + 1] = "skill cap " .. cap.skill
            end
        end
        ui.setText(view.flags, #flags > 0 and table.concat(flags, "   ") or "no restrictions")
        ui.setColor(view.flags, scene.isPvp and "#FF7A6A" or "#A0A0A0")

        if scene.dungeon then
            ui.setText(view.dungeon, string.format("dungeon %s%s", scene.dungeon,
                scene.dungeonOwner and ("  by " .. scene.dungeonOwner) or ""))
        else
            ui.setText(view.dungeon, scene.maxPlayers > 0
                and ("holds up to " .. scene.maxPlayers .. " players") or "")
        end

        local compass, degrees = heading()
        if view.position then
            ui.setText(view.position, string.format("%s %d deg   %.0f, %.0f, %.0f",
                compass, degrees, ShroudPlayerX or 0, ShroudPlayerY or 0, ShroudPlayerZ or 0))
        else
            ui.setText(view.compass, string.format("facing %s (%d deg)", compass, degrees))
        end
    end

    addon.onStart(function()
        local window = layout.window({
            id = "scene",
            title = nil,
            x = 1600, y = 160, width = 230,
            resizable = "horizontal", minSize = 180, maxSize = 460,
        })
        if not window then return end

        view.window = window
        view.name = window:row("", { fontSize = 15 })
        if Core.settings.get("showRawName") then
            view.raw = window:row("", { fontSize = 9, color = "#707070" })
        end
        view.flags = window:row("", { fontSize = 11 })
        view.dungeon = window:row("", { fontSize = 10, color = "#A0A0A0" })
        if Core.settings.get("showCoordinates") then
            view.position = window:row("", { fontSize = 11, color = "#B0B0B0" })
        else
            view.compass = window:row("", { fontSize = 11, color = "#B0B0B0" })
        end
        window:fit()
    end)

    -- Position changes continuously; everything else changes on scene load. A
    -- few updates a second keeps the compass responsive without cost.
    addon.tick(0.25, render)

    -- Scene facts are cached per frame by poll, but the cache is dropped on a
    -- scene change anyway; render immediately so the panel never lags a load.
    addon.onSceneLoaded(function()
        render()
        local scene = poll.scene()
        if scene and scene.isPvp then
            log.info("this is a PVP scene")
        end
    end)

    addon.command("coords", function()
        local compass, degrees = heading()
        log.say(string.format("%.2f, %.2f, %.2f facing %s (%d deg) in %s",
            ShroudPlayerX or 0, ShroudPlayerY or 0, ShroudPlayerZ or 0,
            compass, degrees, ShroudGetCurrentSceneName and ShroudGetCurrentSceneName() or "?"))
    end)

    addon.command("where", function()
        local scene = poll.scene()
        if not scene then
            log.say("scene unknown")
            return
        end
        log.say(string.format("%s (%s)", scene.name, scene.raw))
        log.say(string.format("  pvp=%s  playerTown=%s  maxPlayers=%d",
            tostring(scene.isPvp), tostring(scene.isPot), scene.maxPlayers))
        local cap = poll.sceneCap()
        if cap then log.say(string.format("  caps: level %d, skill %d", cap.level, cap.skill)) end
        if scene.dungeon then
            log.say(string.format("  dungeon %q owned by %s", scene.dungeon, scene.dungeonOwner or "?"))
        end
    end)

    return { view = view, render = render, heading = heading }
end
