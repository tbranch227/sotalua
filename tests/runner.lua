-- tests/runner.lua -- a dependency-free spec runner.
--
-- busted would be the obvious choice, but it needs luarocks and this repo's
-- whole point is that a bare `lua` binary is enough. describe/it/before_each
-- and an assertion table cover everything the specs here need.
--
-- Usage: lua tests/runner.lua [pattern]

local Runner = {}

local suites = {}
local current = nil
local failures = {}
local passed, skipped = 0, 0
local filter = nil

----------------------------------------------------------------------
-- Spec DSL
----------------------------------------------------------------------

function describe(name, body)
    local parent = current
    current = {
        name = parent and (parent.name .. " " .. name) or name,
        befores = {},
        afters = {},
        parent = parent,
    }
    -- Inherit the enclosing block's setup so nested describes compose.
    if parent then
        for _, fn in ipairs(parent.befores) do current.befores[#current.befores + 1] = fn end
        for _, fn in ipairs(parent.afters) do current.afters[#current.afters + 1] = fn end
    end
    suites[#suites + 1] = current
    body()
    current = parent
end

function before_each(fn)
    current.befores[#current.befores + 1] = fn
end

function after_each(fn)
    current.afters[#current.afters + 1] = fn
end

function it(name, body)
    local suite = current
    suite.tests = suite.tests or {}
    suite.tests[#suite.tests + 1] = { name = name, body = body }
end

function pending(name)
    local suite = current
    suite.tests = suite.tests or {}
    suite.tests[#suite.tests + 1] = { name = name, skip = true }
end

----------------------------------------------------------------------
-- Assertions
----------------------------------------------------------------------

local function stringify(value, depth)
    depth = depth or 3
    if type(value) ~= "table" then
        if type(value) == "string" then return string.format("%q", value) end
        return tostring(value)
    end
    if depth <= 0 then return "{...}" end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. stringify(value[k], depth - 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

assert_that = {}

function assert_that.is_true(value, message)
    if value ~= true then
        error((message or "expected true") .. ", got " .. stringify(value), 2)
    end
end

function assert_that.is_false(value, message)
    if value ~= false then
        error((message or "expected false") .. ", got " .. stringify(value), 2)
    end
end

function assert_that.truthy(value, message)
    if not value then
        error((message or "expected a truthy value") .. ", got " .. stringify(value), 2)
    end
end

function assert_that.falsy(value, message)
    if value then
        error((message or "expected a falsy value") .. ", got " .. stringify(value), 2)
    end
end

function assert_that.nil_(value, message)
    if value ~= nil then
        error((message or "expected nil") .. ", got " .. stringify(value), 2)
    end
end

function assert_that.equal(expected, actual, message)
    if expected ~= actual then
        error((message or "values differ") .. ": expected " .. stringify(expected)
            .. ", got " .. stringify(actual), 2)
    end
end

function assert_that.not_equal(unexpected, actual, message)
    if unexpected == actual then
        error((message or "values should differ") .. ": both " .. stringify(actual), 2)
    end
end

function assert_that.same(expected, actual, message)
    if not deepEqual(expected, actual) then
        error((message or "tables differ") .. ": expected " .. stringify(expected)
            .. ", got " .. stringify(actual), 2)
    end
end

function assert_that.near(expected, actual, tolerance, message)
    tolerance = tolerance or 1e-6
    if type(actual) ~= "number" or math.abs(expected - actual) > tolerance then
        error((message or "numbers differ") .. ": expected " .. stringify(expected)
            .. " +/- " .. tolerance .. ", got " .. stringify(actual), 2)
    end
end

function assert_that.contains(haystack, needle, message)
    if type(haystack) == "string" then
        if not haystack:find(needle, 1, true) then
            error((message or "string does not contain " .. stringify(needle))
                .. ": " .. stringify(haystack), 2)
        end
        return
    end
    for _, item in ipairs(haystack or {}) do
        if item == needle then return end
    end
    error((message or "list does not contain " .. stringify(needle))
        .. ": " .. stringify(haystack), 2)
end

function assert_that.errors(fn, message)
    local ok = pcall(fn)
    if ok then error(message or "expected the call to raise", 2) end
end

function assert_that.no_error(fn, message)
    local ok, err = pcall(fn)
    if not ok then error((message or "unexpected error") .. ": " .. tostring(err), 2) end
end

----------------------------------------------------------------------
-- Execution
----------------------------------------------------------------------

local RED, GREEN, YELLOW, DIM, RESET = "\27[31m", "\27[32m", "\27[33m", "\27[2m", "\27[0m"
if os.getenv("NO_COLOR") then RED, GREEN, YELLOW, DIM, RESET = "", "", "", "", "" end

local function runSuite(suite)
    if not suite.tests then return end
    io.write(DIM, suite.name, RESET, "\n")
    for _, test in ipairs(suite.tests) do
        if test.skip then
            skipped = skipped + 1
            io.write("  ", YELLOW, "- ", test.name, RESET, "\n")
        elseif filter and not (suite.name .. " " .. test.name):lower():find(filter, 1, true) then
            skipped = skipped + 1
        else
            for _, fn in ipairs(suite.befores) do fn() end
            local ok, err = xpcall(test.body, function(e)
                return tostring(e) .. "\n" .. debug.traceback("", 2)
            end)
            for _, fn in ipairs(suite.afters) do pcall(fn) end

            if ok then
                passed = passed + 1
                io.write("  ", GREEN, "ok ", RESET, test.name, "\n")
            else
                failures[#failures + 1] = { suite = suite.name, test = test.name, err = err }
                io.write("  ", RED, "FAIL ", RESET, test.name, "\n")
            end
        end
    end
end

function Runner.run(files, pattern)
    filter = pattern and pattern:lower() or nil

    for _, file in ipairs(files) do
        suites = {}
        local chunk, err = loadfile(file)
        if not chunk then
            failures[#failures + 1] = { suite = file, test = "load", err = err }
            io.write(RED, "FAIL ", RESET, file, ": ", tostring(err), "\n")
        else
            local ok, loadErr = xpcall(chunk, function(e)
                return tostring(e) .. "\n" .. debug.traceback("", 2)
            end)
            if not ok then
                failures[#failures + 1] = { suite = file, test = "load", err = loadErr }
                io.write(RED, "FAIL ", RESET, file, ": ", tostring(loadErr), "\n")
            else
                for _, suite in ipairs(suites) do runSuite(suite) end
            end
        end
    end

    io.write("\n")
    if #failures > 0 then
        io.write(RED, "Failures:", RESET, "\n\n")
        for i, failure in ipairs(failures) do
            io.write(i, ") ", failure.suite, " -> ", failure.test, "\n")
            io.write("   ", tostring(failure.err):gsub("\n", "\n   "), "\n\n")
        end
    end

    io.write(string.format("%s%d passed%s, %s%d failed%s, %d skipped\n",
        GREEN, passed, RESET, #failures > 0 and RED or "", #failures, RESET, skipped))
    return #failures == 0
end

return Runner
