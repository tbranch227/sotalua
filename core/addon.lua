-- core/addon.lua -- one-call bootstrap for a plugin.
--
-- Wires the core modules together in the order the host expects and returns the
-- table of ShroudOn* globals for the bundler to install. A plugin's whole
-- lifecycle setup is:
--
--   local addon = Core.addon.start{
--       name = "Target Frame", slug = "target-frame", version = "1.0.0",
--       settings = { window = { default = {} } },
--   }
--   addon.onStart(function() ... end)
--   addon.onUpdate(function() ... end)
--   return addon

return function(M)
    local A = {}

    --- Bring up every core subsystem for this addon.
    function A.start(opts)
        assert(opts and opts.slug, "addon.start requires a slug")

        M.env.init(opts)

        if opts.settings then M.settings.define(opts.settings) end
        M.settings.install()

        M.ui.install()
        M.poll.install()
        if opts.fx ~= false then M.fx.install() end

        -- One global per addon for the timer pump. Derived from the slug so two
        -- addons in the shared environment cannot collide.
        M.timers.install(A.timerGlobal(opts.slug), opts.tickPeriod)
        M.events.on("ShroudOnDisableScript", M.timers.uninstall, "timers.uninstallOnDisable")

        if opts.layout ~= false then M.layout.install(opts.layoutOptions) end

        local self = {
            name = opts.name,
            slug = opts.slug,
            version = opts.version,
        }

        -- Thin wrappers so a plugin never types a callback name as a string.
        function self.onStart(fn) return M.events.on("ShroudOnStart", fn, "plugin.onStart") end
        function self.onUpdate(fn) return M.events.on("ShroudOnUpdate", fn, "plugin.onUpdate") end
        function self.onGUI(fn) return M.events.on("ShroudOnGUI", fn, "plugin.onGUI") end
        function self.onChat(fn) return M.events.on("ShroudOnConsoleInput", fn, "plugin.onChat") end
        function self.onExperience(fn) return M.events.on("ShroudOnExperienceGain", fn, "plugin.onExperience") end
        function self.onSceneLoaded(fn) return M.events.on("ShroudOnSceneLoaded", fn, "plugin.onSceneLoaded") end
        function self.onSceneUnloaded(fn) return M.events.on("ShroudOnSceneUnloaded", fn, "plugin.onSceneUnloaded") end
        function self.onLogOut(fn) return M.events.on("ShroudOnLogOut", fn, "plugin.onLogOut") end
        function self.onDisable(fn) return M.events.on("ShroudOnDisableScript", fn, "plugin.onDisable") end
        function self.onEmote(fn) return M.events.on("ShroudOnPlayEmote", fn, "plugin.onEmote") end
        function self.onFX(fn) return M.events.on("ShroudOnPlayFX", fn, "plugin.onFX") end
        function self.onSound(fn) return M.events.on("ShroudOnPlaySound", fn, "plugin.onSound") end

        --- Register a slash-callable global: /lua <slug>_<name>
        function self.command(name, fn)
            local globalName = A.commandGlobal(opts.slug, name)
            _G[globalName] = M.env.protect("command:" .. name, fn)
            return globalName
        end

        --- Run `fn` every `period` seconds off the frame loop.
        function self.every(name, period, fn) return M.timers.every(name, period, fn) end

        --- Run `fn` in ShroudOnUpdate, but at most every `period` seconds.
        function self.tick(period, fn)
            return M.events.on("ShroudOnUpdate", M.timers.throttle(period, fn), "plugin.tick")
        end

        A.current = self
        return self
    end

    --- The unique global name for a slug's timer pump.
    -- "target-frame" -> "_TargetFrame_pump"
    function A.timerGlobal(slug)
        return "_" .. A.camel(slug) .. "_pump"
    end

    --- The unique global name for a slug's slash command.
    -- ("api-probe", "dump") -> "_ApiProbe_dump"
    function A.commandGlobal(slug, name)
        return "_" .. A.camel(slug) .. "_" .. name
    end

    --- "target-frame" -> "TargetFrame"
    function A.camel(slug)
        local out = ""
        for word in tostring(slug):gmatch("[^%-_]+") do
            out = out .. word:sub(1, 1):upper() .. word:sub(2)
        end
        return out
    end

    --- The ShroudOn* globals for the bundler to assign.
    function A.handlers()
        return M.events.handlers()
    end

    return A
end
