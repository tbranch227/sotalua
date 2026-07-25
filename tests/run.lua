-- tests/run.lua -- entry point: lua tests/run.lua [pattern]

local ROOT = (function()
    local here = debug.getinfo(1, "S").source:sub(2)
    return here:match("^(.*)tests[/\\]run%.lua$") or "./"
end)()

local Runner = dofile(ROOT .. "tests/runner.lua")

-- Discovered rather than listed, so a new *_spec.lua file is picked up without
-- touching this file. `ls` keeps the dependency surface at zero.
local function specFiles()
    local files = {}
    local pipe = io.popen('ls "' .. ROOT .. 'tests"/*_spec.lua 2>/dev/null')
    if pipe then
        for line in pipe:lines() do files[#files + 1] = line end
        pipe:close()
    end
    table.sort(files)
    return files
end

local files = specFiles()
if #files == 0 then
    io.write("no spec files found under ", ROOT, "tests/\n")
    os.exit(1)
end

os.exit(Runner.run(files, arg and arg[1]) and 0 or 1)
