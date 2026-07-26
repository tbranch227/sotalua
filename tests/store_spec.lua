-- tests/store_spec.lua -- the durable event log.
--
-- These write real files, because the thing under test is file I/O. The mock
-- host's Lua path points at a scratch directory rather than the game folder.

local H = dofile((os.getenv("SOTALUA_ROOT") or "./") .. "tests/helper.lua")

local SCRATCH = "/tmp/sotalua-store-spec/"

describe("store", function()
    local M

    before_each(function()
        os.execute("rm -rf " .. SCRATCH .. " && mkdir -p " .. SCRATCH)
        M = H.bootstrap({ world = function(w) w.luaPath = SCRATCH end })
        M.env.init({ name = "T", slug = "t", logLevel = "error" })
        M.store.configure({ name = "test", flushSeconds = 1 })
        M.timers.install("_Test_pump", 0.1)
        M.store.install()
        H.installHandlers(M)
    end)

    after_each(function()
        H.teardown()
        os.execute("rm -rf " .. SCRATCH)
    end)

    local function readFile(name)
        local file = io.open(SCRATCH .. name, "r")
        if not file then return nil end
        local body = file:read("*a")
        file:close()
        return body
    end

    -- The default mock character is "Testcharacter".
    local function readAll()
        return readFile("sotalua-test-testcharacter.jsonl")
    end

    local function listFiles()
        local names = {}
        local pipe = io.popen("ls " .. SCRATCH .. " 2>/dev/null")
        if pipe then
            for line in pipe:lines() do names[#names + 1] = line end
            pipe:close()
        end
        table.sort(names)
        return names
    end

    it("writes one self-contained JSON object per line", function()
        M.store.append("session", { seconds = 120, gold = -50 })
        M.store.append("item", { item = "Gold Ore", delta = 3 })
        assert_that.is_true(M.store.flush())

        local body = readAll()
        assert_that.truthy(body, "nothing was written")

        local lines = {}
        for line in body:gmatch("[^\n]+") do lines[#lines + 1] = line end
        assert_that.equal(2, #lines)
        for _, line in ipairs(lines) do
            assert_that.equal("{", line:sub(1, 1))
            assert_that.equal("}", line:sub(-1))
        end
    end)

    it("stamps every record with type, character and server time", function()
        M.store.append("session", { seconds = 60 })
        M.store.flush()

        local body = readAll()
        assert_that.contains(body, '"type":"session"')
        assert_that.contains(body, '"char":"Testcharacter"')
        assert_that.contains(body, '"at":')
    end)

    it("appends rather than truncating across flushes", function()
        M.store.append("a", {})
        M.store.flush()
        M.store.append("b", {})
        M.store.flush()

        local body = readAll()
        assert_that.contains(body, '"type":"a"')
        assert_that.contains(body, '"type":"b"')
    end)

    it("escapes strings so a quote cannot corrupt the line", function()
        M.store.append("item", { item = 'Sword "of" \\Doom\\', note = "line\nbreak" })
        M.store.flush()

        local body = readAll()
        -- One record must still be exactly one line.
        local count = 0
        for _ in body:gmatch("[^\n]+") do count = count + 1 end
        assert_that.equal(1, count, "an embedded newline split the record")
        assert_that.contains(body, '\\"of\\"')
        assert_that.contains(body, "\\n")
    end)

    it("encodes numbers without precision noise", function()
        assert_that.equal("42", M.store.encode(42))
        assert_that.equal("-7", M.store.encode(-7))
        assert_that.contains(M.store.encode(3.5), "3.5")
        -- NaN and infinity are not representable in JSON.
        assert_that.equal("null", M.store.encode(0 / 0))
        assert_that.equal("null", M.store.encode(math.huge))
    end)

    it("distinguishes arrays from objects", function()
        assert_that.equal('["a","b"]', M.store.encode({ "a", "b" }))
        assert_that.equal('{"k":1}', M.store.encode({ k = 1 }))
        assert_that.equal("[]", M.store.encode({}))
    end)

    it("survives a cyclic table instead of recursing forever", function()
        local cyclic = { name = "loop" }
        cyclic.self = cyclic
        assert_that.no_error(function() M.store.encode(cyclic) end)
    end)

    it("keeps events queued when the host has not published the path", function()
        -- Right after a reload ShroudLuaPath is empty; the events must wait
        -- rather than being written somewhere arbitrary or dropped.
        H.host.world.luaPath = ""
        H.host.refreshGlobals()

        M.store.append("session", { seconds = 1 })
        assert_that.is_false(M.store.flush())
        assert_that.equal(1, M.store.stats().buffered)

        H.host.world.luaPath = SCRATCH
        H.host.refreshGlobals()
        assert_that.is_true(M.store.flush())
        assert_that.contains(readAll(), '"type":"session"')
    end)

    it("drops events rather than growing memory without bound", function()
        H.host.world.luaPath = ""     -- nothing can be written
        H.host.refreshGlobals()

        for i = 1, 1000 do M.store.append("spam", { i = i }) end
        local stats = M.store.stats()
        assert_that.truthy(stats.buffered <= 400, "buffered " .. stats.buffered)
        assert_that.truthy(stats.dropped > 0, "nothing was dropped")
    end)

    it("gives each character its own file", function()
        -- One install, many characters. A shared file would let a busy
        -- character rotate away another's history.
        M.store.append("a", { n = 1 })
        M.store.flush()

        H.host.switchCharacter("Second Avatar")
        M.store.append("b", { n = 2 })
        M.store.flush()

        assert_that.same(
            { "sotalua-test-second-avatar.jsonl", "sotalua-test-testcharacter.jsonl" },
            listFiles())
        assert_that.contains(readFile("sotalua-test-testcharacter.jsonl"), '"type":"a"')
        assert_that.contains(readFile("sotalua-test-second-avatar.jsonl"), '"type":"b"')
        assert_that.falsy(readFile("sotalua-test-second-avatar.jsonl"):find('"type":"a"', 1, true))
    end)

    it("flushes queued events to the old file before switching", function()
        M.store.append("belongs-to-first", {})    -- queued, not yet written
        H.host.switchCharacter("Second Avatar")
        M.store.append("belongs-to-second", {})
        M.store.flush()

        assert_that.contains(readFile("sotalua-test-testcharacter.jsonl"), "belongs-to-first")
        assert_that.contains(readFile("sotalua-test-second-avatar.jsonl"), "belongs-to-second")
    end)

    it("attributes a record written at logout to the character who earned it", function()
        -- ShroudGetPlayerName reports no player once logout has begun, and the
        -- session summary is written exactly then. Reading the name at write
        -- time would file it under "unknown".
        M.store.append("warmup", {})
        H.host.world.player.name = nil            -- logging out
        M.store.append("session", { seconds = 60 })
        M.store.flush()

        local body = readFile("sotalua-test-testcharacter.jsonl")
        assert_that.truthy(body, "the record went to the wrong file")
        assert_that.contains(body, '"char":"Testcharacter"')
        assert_that.falsy(body:find('"char":"unknown"', 1, true))
    end)

    it("sanitises a character name into a filename", function()
        H.host.switchCharacter("Sir Reginald The Third")
        M.store.append("x", {})
        M.store.flush()
        assert_that.contains(listFiles(), "sotalua-test-sir-reginald-the-third.jsonl")
    end)

    it("rotates the file once it passes its size cap", function()
        M.store.configure({ name = "test", maxBytes = 512 })
        for i = 1, 60 do
            M.store.append("filler", { index = i, padding = string.rep("x", 40) })
        end
        M.store.flush()
        M.store.append("after", {})
        M.store.flush()

        local rotated = io.open(SCRATCH .. "sotalua-test-testcharacter.1.jsonl", "r")
        assert_that.truthy(rotated, "no rotated generation was created")
        rotated:close()
        assert_that.contains(readAll(), '"type":"after"')
    end)

    it("flushes on logout and on disable", function()
        M.store.append("session", { seconds = 5 })
        H.host.logout()
        assert_that.contains(readAll() or "", '"type":"session"')
    end)

    it("reads its own tail back", function()
        for i = 1, 5 do M.store.append("tick", { i = i }) end
        M.store.flush()
        local lines = M.store.tail(3)
        assert_that.equal(3, #lines)
        assert_that.contains(lines[3], '"i":5')
    end)
end)
