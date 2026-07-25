-- tests/helper.lua -- build the core module graph the way the bundler does.
--
-- Both paths instantiate each module as factory(sharedTable), so what the tests
-- exercise is structurally identical to what ships. The only difference is that
-- the bundler inlines the sources instead of reading them from disk.

local Helper = {}

local ROOT = (function()
    local here = debug.getinfo(1, "S").source:sub(2)
    return here:match("^(.*)tests[/\\]helper%.lua$") or "./"
end)()

Helper.root = ROOT
Helper.host = dofile(ROOT .. "tests/mock/host.lua")

local MODULES = dofile(ROOT .. "core/modules.lua")

--- Install the mock host and build a fresh core table.
--
-- Order matters here in one respect: the host globals must exist before
-- core/env.lua runs, because env reads ShroudLuaApiVersion at load time exactly
-- as it does in the game.
function Helper.bootstrap(opts)
    opts = opts or {}

    Helper.host.install()
    if opts.apiVersion then
        Helper.host.world.apiVersion = opts.apiVersion
        Helper.host.refreshGlobals()
    end
    if opts.world then opts.world(Helper.host.world) end

    local M = {}
    for _, name in ipairs(MODULES) do
        local factory = dofile(ROOT .. "core/" .. name .. ".lua")
        M[name] = factory(M)
    end

    Helper.core = M
    return M
end

--- Bootstrap and start an addon in one step, the common case for a spec.
function Helper.startAddon(spec)
    local M = Helper.bootstrap(spec.boot)
    local addon = M.addon.start({
        name = spec.name or "Test Addon",
        slug = spec.slug or "test-addon",
        version = spec.version or "1.0.0",
        settings = spec.settings,
        logLevel = spec.logLevel or "warn",
    })
    if spec.build then spec.build(M, addon) end
    Helper.installHandlers(M)
    return M, addon
end

--- Publish the ShroudOn* globals, as the bundler's epilogue does.
function Helper.installHandlers(M)
    for name, fn in pairs(M.addon.handlers()) do
        _G[name] = fn
    end
end

--- Load a plugin's source the way the bundler does and wire up its callbacks.
function Helper.loadPlugin(slug, boot)
    local M = Helper.bootstrap(boot)
    local factory = dofile(ROOT .. "plugins/" .. slug .. "/src/main.lua")
    local plugin = factory(M)
    Helper.installHandlers(M)
    return M, plugin
end

local HOST_GLOBALS = {
    ConsoleLog = true, InvalidStatResult = true, UI = true, TextAnchor = true,
    ButtonMode = true, Transition = true, ContentType = true, AudioType = true,
}

--- Remove every Shroud* and addon-owned global between specs so a leaked name
--- from one test cannot satisfy the next one.
--
-- The addon-owned pattern is deliberately narrow: "_Slug_name", the shape
-- core/addon.lua mints for timer pumps and commands. A looser "^_%u" would also
-- match _G itself.
function Helper.teardown()
    local doomed = {}
    for name in pairs(_G) do
        if type(name) == "string"
            and (name:match("^Shroud") or name:match("^_%u[%w]*_%w") or HOST_GLOBALS[name]) then
            doomed[#doomed + 1] = name
        end
    end
    for _, name in ipairs(doomed) do _G[name] = nil end
    Helper.core = nil
end

--- A rune table shaped like what ShroudGetPlayerBuff returns.
function Helper.rune(name, opts)
    opts = opts or {}
    local effects = {}
    for _, effect in ipairs(opts.effects or { { duration = opts.duration or 30 } }) do
        effects[#effects + 1] = {
            Description = effect.description or (name .. " effect"),
            Value = effect.value or 1,
            CurrentDuration = effect.duration or 30,
            TotalDuration = effect.total or effect.duration or 30,
            TotalTick = effect.ticks or 1,
        }
    end
    return {
        RuneName = name,
        RuneId = opts.id or 1,
        IsDebuff = opts.debuff or false,
        IconId = opts.icon or -1,
        StackCount = #effects,
        Effects = effects,
    }
end

--- An inventory item table the mock turns into a 14-field tuple.
function Helper.item(name, opts)
    opts = opts or {}
    return {
        name = name,
        quantity = opts.quantity or 1,
        value = opts.value or 0,
        weight = opts.weight or 1,
        createdBy = opts.createdBy or "",
        creationScene = opts.scene or "",
        size = opts.size or 0,
    }
end

return Helper
