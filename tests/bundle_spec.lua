-- tests/bundle_spec.lua -- run the actual build output, not the sources.
--
-- Every other spec loads plugins/<slug>/src/main.lua directly. That verifies
-- the plugin but not the bundler: a mistake in the generated prologue, module
-- wrapping, or callback epilogue would pass everything else and still ship a
-- broken file. These specs execute dist/<slug>/<Name>.lua exactly as the host
-- would and check what lands in _G.
--
-- Skipped with a clear message when dist/ is empty, so `./run.sh test` before a
-- build does not look like a failure.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

local function bundles()
    local out = {}
    local pipe = io.popen('ls "' .. H.root .. 'dist"/*/*.lua 2>/dev/null')
    if pipe then
        for line in pipe:lines() do
            out[#out + 1] = { path = line, slug = line:match("dist/([^/]+)/") }
        end
        pipe:close()
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

local BUILT = bundles()

describe("bundled output", function()
    after_each(H.teardown)

    if #BUILT == 0 then
        pending("no bundles under dist/; run ./run.sh build first")
        return
    end

    for _, bundle in ipairs(BUILT) do
        it(bundle.slug .. " loads and publishes its callbacks", function()
            H.host.install()

            local chunk, err = loadfile(bundle.path)
            assert_that.truthy(chunk, "did not parse: " .. tostring(err))

            local ok, result = pcall(chunk)
            assert_that.truthy(ok, "failed to run: " .. tostring(result))

            -- The epilogue must have published at least ShroudOnStart, and the
            -- widget callbacks, which are always installed because widgets do
            -- not exist yet at capture time.
            assert_that.truthy(type(_G.ShroudOnMouseClick) == "function",
                "ShroudOnMouseClick was not published")

            H.host.start()
            H.host.frames(60, 1 / 30)
            H.host.loadScene("Etceter")
            H.host.logout()
            H.host.disable()

            for _, line in ipairs(H.host.console()) do
                assert_that.falsy(line:find("ERROR", 1, true),
                    bundle.slug .. " bundle errored: " .. line)
            end
            assert_that.equal(0, H.host.liveWidgetCount(),
                bundle.slug .. " bundle leaked widgets")
        end)
    end

    it("creates no globals beyond callbacks and slug-prefixed entry points", function()
        -- This is the property that makes it safe for these addons to coexist
        -- with other authors' addons in the one shared MoonSharp environment.
        H.host.install()

        local before = {}
        for name in pairs(_G) do before[name] = true end

        assert_that.no_error(function() dofile(BUILT[1].path) end)

        local leaked = {}
        for name in pairs(_G) do
            if not before[name]
                and not name:match("^ShroudOn")
                and not name:match("^_%u[%w]*_%w") then
                leaked[#leaked + 1] = name
            end
        end
        table.sort(leaked)
        assert_that.same({}, leaked,
            BUILT[1].slug .. " leaked globals into the shared environment")
    end)

    it("declares the five metadata locals before anything else", function()
        -- The addon manager parses these from the beginning of the file, so
        -- nothing may precede them.
        local file = io.open(BUILT[1].path, "r")
        local firstCode
        for line in file:lines() do
            if line:match("%S") then
                firstCode = line
                break
            end
        end
        file:close()
        assert_that.truthy(firstCode and firstCode:match("^local ScriptName ="),
            "first line was: " .. tostring(firstCode))
    end)
end)
