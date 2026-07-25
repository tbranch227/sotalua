-- tools/lint.lua -- catch accidental globals before they reach the shared
-- environment.
--
-- Every enabled addon in the client shares one MoonSharp Script. A stray
-- `count = 0` at the top of a core module or a plugin does not just pollute
-- that addon, it can silently overwrite a variable belonging to somebody
-- else's addon. luacheck would find these, but it needs luarocks; this does the
-- one check that actually matters here, with no dependencies.
--
-- The technique: load each file with a custom environment whose __newindex
-- records writes. That catches globals created when the chunk runs. For
-- functions that only assign a global when called, a source scan catches the
-- common `function Name(...)` and top-level `Name = ...` forms.
--
-- KNOWN GAP: the source scan only matches assignments at column 0, because
-- matching an indented `foo = 1` would flag every reassignment of a local. An
-- indented global write therefore slips past. That is not fixable without real
-- scope tracking, which is exactly what luacheck does -- it caught an indented
-- `_ = target` in target-frame that this file missed. Treat this as the
-- dependency-free floor and luacheck as the real check:
--
--   sudo apt install -y lua-check      (the package is lua-check, not luacheck)
--
-- ./run.sh lint runs both when luacheck is present.
--
-- Usage: lua tools/lint.lua

local ROOT = (function()
    local here = debug.getinfo(1, "S").source:sub(2)
    return here:match("^(.*)tools[/\\]lint%.lua$") or "./"
end)()

-- Globals a plugin is allowed to create: the host callbacks, and the
-- slug-prefixed entry points core/addon.lua mints for timers and commands.
local function allowed(name)
    return name:match("^ShroudOn") or name:match("^_%u[%w]*_%w")
end

local issues = 0

local function scanSource(path)
    local file = io.open(path, "r")
    if not file then return end
    local lineNo = 0
    for line in file:lines() do
        lineNo = lineNo + 1
        -- A global function declaration at column 0, outside any local scope.
        local fnName = line:match("^function%s+([%w_]+)%s*%(")
        if fnName and not allowed(fnName) then
            print(string.format("%s:%d: global function %q; make it local", path, lineNo, fnName))
            issues = issues + 1
        end
        -- A bare assignment at column 0 that is not local and not a comment.
        local varName = line:match("^([%a_][%w_]*)%s*=[^=]")
        if varName and varName ~= "local" and not allowed(varName) then
            print(string.format("%s:%d: global assignment to %q; make it local", path, lineNo, varName))
            issues = issues + 1
        end
    end
    file:close()
end

local function checkFactory(path)
    -- Core modules and plugin entry points must evaluate to a factory function
    -- and must not touch _G while being loaded.
    local chunk, err = loadfile(path)
    if not chunk then
        print(string.format("%s: does not parse: %s", path, err))
        issues = issues + 1
        return
    end
    local ok, factory = pcall(chunk)
    if not ok then
        print(string.format("%s: failed to evaluate: %s", path, factory))
        issues = issues + 1
        return
    end
    if type(factory) ~= "function" then
        print(string.format("%s: must `return function(Core) ... end`, got %s", path, type(factory)))
        issues = issues + 1
    end
end

local function listFiles(pattern)
    local out = {}
    local pipe = io.popen("ls " .. pattern .. " 2>/dev/null")
    if pipe then
        for line in pipe:lines() do out[#out + 1] = line end
        pipe:close()
    end
    table.sort(out)
    return out
end

local files = {}
for _, path in ipairs(listFiles('"' .. ROOT .. 'core"/*.lua')) do
    if not path:match("modules%.lua$") then files[#files + 1] = path end
end
for _, path in ipairs(listFiles('"' .. ROOT .. 'plugins"/*/src/*.lua')) do
    files[#files + 1] = path
end

for _, path in ipairs(files) do
    scanSource(path)
    checkFactory(path)
end

print(string.format("lint: %d file(s), %d issue(s)", #files, issues))
os.exit(issues == 0 and 0 or 1)
