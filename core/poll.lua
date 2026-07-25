-- core/poll.lua -- one snapshot per frame, shared by every consumer.
--
-- The reference is explicit that these reads are not free: "every call resolves
-- the target and every buff call snapshots the effect array", and the buff list
-- is "a fresh snapshot per call; build it once per frame rather than per
-- widget". Inventory is heavier still.
--
-- So nothing in this suite calls those getters directly. Everything reads
-- through here, which memoizes on ShroudTime for frame-scoped data and on a
-- staleness window for the expensive ones.

return function(M)
    local P = {}

    local INVENTORY_TTL = 5.0   -- seconds; inventory is polled, never per frame

    local frame = { at = -1 }   -- cleared whenever ShroudTime advances
    local slow = {}             -- key -> { at, value }

    local function now()
        return ShroudTime or 0
    end

    local function frameCache(key, produce)
        local at = now()
        if frame.at ~= at then
            frame = { at = at }
        end
        local hit = frame[key]
        if hit ~= nil then
            if hit == false then return nil end   -- cached "the host said nil"
            return hit
        end
        local value = produce()
        frame[key] = value == nil and false or value
        return value
    end

    local function slowCache(key, ttl, produce)
        local at = now()
        local hit = slow[key]
        if hit and at - hit.at < ttl then return hit.value end
        local value = produce()
        slow[key] = { at = at, value = value }
        return value
    end

    ----------------------------------------------------------------------
    -- Buffs
    ----------------------------------------------------------------------

    --- Player buffs grouped by rune, normalized to a plain array.
    --
    -- StackCount is documented as #Effects rather than a true stack count, so
    -- it is exposed as `effectCount` to stop callers reading it as stacks.
    local function normalizeRunes(raw)
        local out = {}
        for _, rune in ipairs(M.util.list(raw)) do
            out[#out + 1] = {
                name = M.util.nameOr(rune.RuneName, "Unknown"),
                id = rune.RuneId,
                isDebuff = rune.IsDebuff == true,
                iconId = M.env.HAS_ICONS and rune.IconId or -1,
                effectCount = rune.StackCount or 0,
                effects = M.util.list(rune.Effects),
                remaining = -1,
            }
        end
        -- The rune itself carries no duration; take the longest of its effects,
        -- which is what the stock buff bar shows.
        for _, rune in ipairs(out) do
            local longest = -1
            for _, effect in ipairs(rune.effects) do
                local d = effect.CurrentDuration
                if type(d) == "number" and d > longest then longest = d end
            end
            rune.remaining = longest
        end
        return out
    end

    function P.playerBuffs()
        return frameCache("playerBuffs", function()
            if not ShroudGetPlayerBuff then return {} end
            return normalizeRunes(ShroudGetPlayerBuff())
        end) or {}
    end

    function P.petBuffs()
        return frameCache("petBuffs", function()
            if not ShroudGetPetBuff then return {} end
            return normalizeRunes(ShroudGetPetBuff())
        end) or {}
    end

    function P.targetBuffs()
        return frameCache("targetBuffs", function()
            if not (M.env.HAS_TARGET and ShroudGetTargetBuff) then return {} end
            return normalizeRunes(ShroudGetTargetBuff())
        end) or {}
    end

    ----------------------------------------------------------------------
    -- Target
    ----------------------------------------------------------------------

    --- Current target as a flat table, or nil when nothing is targeted.
    --
    -- When health is hidden the host reports current == max, so `healthHidden`
    -- is surfaced and the bar should be drawn as unknown rather than full.
    function P.target()
        return frameCache("target", function()
            if not (M.env.HAS_TARGET and ShroudHasTarget) then return nil end
            if not ShroudHasTarget() then return nil end

            local hidden = ShroudIsTargetHealthHidden and ShroudIsTargetHealthHidden() or false
            return {
                id = ShroudGetTargetId and ShroudGetTargetId() or -1,
                name = M.util.nameOr(ShroudGetTargetName and ShroudGetTargetName(), "Unknown"),
                dead = ShroudIsTargetDead and ShroudIsTargetDead() or false,
                healthHidden = hidden,
                health = M.util.numberOr(ShroudGetTargetCurrentHealth and ShroudGetTargetCurrentHealth(), -1),
                maxHealth = M.util.numberOr(ShroudGetTargetMaxHealth and ShroudGetTargetMaxHealth(), -1),
                focus = M.util.numberOr(ShroudGetTargetCurrentFocus and ShroudGetTargetCurrentFocus(), -1),
                maxFocus = M.util.numberOr(ShroudGetTargetMaxFocus and ShroudGetTargetMaxFocus(), -1),
            }
        end)
    end

    ----------------------------------------------------------------------
    -- Party
    ----------------------------------------------------------------------

    --- Roster merged with live in-scene vitals.
    --
    -- The index getters cover the whole party; the InScene getters are keyed by
    -- name and only answer for members in the current scene. Members not in the
    -- scene are returned with inScene = false so a frame can dim them.
    function P.party()
        return frameCache("party", function()
            if not ShroudGetPartyMemberCount then return {} end
            local count = M.util.numberOr(ShroudGetPartyMemberCount(), 0)

            local present = {}
            if ShroudGetPartyMemberNamesInScene then
                for _, name in ipairs(M.util.list(ShroudGetPartyMemberNamesInScene())) do
                    if type(name) == "string" and name ~= "" then present[name:lower()] = true end
                end
            end

            local out = {}
            for i = 0, count - 1 do
                local name = M.util.nameOr(ShroudGetPartyMemberName(i), nil)
                if name then
                    local inScene = present[name:lower()] == true
                    local member = {
                        index = i,
                        name = name,
                        inScene = inScene,
                        health = M.util.numberOr(ShroudGetPartyMemberCurrentHealth(i), -1),
                        maxHealth = M.util.numberOr(ShroudGetPartyMemberMaxHealth(i), -1),
                        focus = M.util.numberOr(ShroudGetPartyMemberCurrentFocus(i), -1),
                        maxFocus = M.util.numberOr(ShroudGetPartyMemberMaxFocus(i), -1),
                    }
                    -- In-scene readings are the live ones; prefer them.
                    if inScene and ShroudGetPartyMemberCurrentHealthInScene then
                        member.health = M.util.numberOr(ShroudGetPartyMemberCurrentHealthInScene(name), member.health)
                        member.maxHealth = M.util.numberOr(ShroudGetPartyMemberMaxHealthInScene(name), member.maxHealth)
                        member.focus = M.util.numberOr(ShroudGetPartyMemberCurrentFocusInScene(name), member.focus)
                        member.maxFocus = M.util.numberOr(ShroudGetPartyMemberMaxFocusInScene(name), member.maxFocus)
                    end
                    out[#out + 1] = member
                end
            end
            return out
        end) or {}
    end

    ----------------------------------------------------------------------
    -- Inventory (slow path)
    ----------------------------------------------------------------------

    -- Positional layout of the 14-field inventory tuple. Fields 12-14 were
    -- appended so earlier indexes stay stable.
    local INVENTORY_FIELDS = {
        "name", "durability", "primaryDurability", "maxDurability",
        "weight", "quantity", "createdBy", "creationTime", "creationScene",
        "size", "value", "collectedBy", "collectedDate", "collectedZone",
    }
    local EQUIPMENT_FIELDS = {
        "name", "durability", "primaryDurability", "maxDurability",
        "weight", "quantity", "value",
    }

    local function tuples(raw, fields)
        local out = {}
        for _, row in ipairs(M.util.list(raw)) do
            local item = {}
            for i, field in ipairs(fields) do item[field] = row[i] end
            if type(item.name) == "string" and item.name ~= "" then
                item.quantity = M.util.numberOr(item.quantity, 1)
                item.value = M.util.numberOr(item.value, 0)
                out[#out + 1] = item
            end
        end
        return out
    end

    --- Inventory as named-field tables, cached for INVENTORY_TTL seconds.
    function P.inventory(force)
        if force then slow.inventory = nil end
        return slowCache("inventory", INVENTORY_TTL, function()
            if not ShroudGetInventory then return {} end
            return tuples(ShroudGetInventory(), INVENTORY_FIELDS)
        end) or {}
    end

    function P.equipment(force)
        if force then slow.equipment = nil end
        return slowCache("equipment", INVENTORY_TTL, function()
            if not ShroudGetEquipments then return {} end
            return tuples(ShroudGetEquipments(), EQUIPMENT_FIELDS)
        end) or {}
    end

    --- Collapse inventory into name -> total quantity, for session diffing.
    function P.inventoryCounts(force)
        local counts = {}
        for _, item in ipairs(P.inventory(force)) do
            counts[item.name] = (counts[item.name] or 0) + item.quantity
        end
        return counts
    end

    ----------------------------------------------------------------------
    -- Scene, pet, mouse
    ----------------------------------------------------------------------

    function P.scene()
        return frameCache("scene", function()
            if not ShroudGetCurrentSceneName then return nil end
            local orientation = ShroudGetCurrentSceneOrientation
            local maxPlayers = ShroudGetCurrentSceneMaxPlayerCount
            return {
                name = M.util.nameOr(ShroudGetCurrentSceneName(), "Unknown"),
                raw = ShroudGetCurrentSceneNameRaw and ShroudGetCurrentSceneNameRaw() or "",
                orientation = M.util.numberOr(orientation and orientation(), 0),
                maxPlayers = M.util.numberOr(maxPlayers and maxPlayers(), -1),
                isPvp = ShroudGetCurrentSceneIsPVP and ShroudGetCurrentSceneIsPVP() or false,
                isPot = ShroudGetCurrentSceneIsPOT and ShroudGetCurrentSceneIsPOT() or false,
                dungeon = M.util.nameOr(ShroudGetCurrentDungeonName and ShroudGetCurrentDungeonName(), nil),
                dungeonOwner = M.util.nameOr(ShroudGetCurrentDungeonOwner and ShroudGetCurrentDungeonOwner(), nil),
            }
        end)
    end

    --- Game time. Day and Month already carry the engine's +1, so callers must
    --- not add their own. A zeroed table means game time is unavailable.
    function P.gameTime()
        return frameCache("gameTime", function()
            if not ShroudGetGameTime then return nil end
            local t = ShroudGetGameTime()
            if not t or (t.Day == 0 and t.Month == 0) then return nil end
            return {
                day = t.Day, month = t.Month, year = t.Year,
                hour = t.Hour,
                period = t.PeriodOfDay, season = t.Season,
            }
        end)
    end

    function P.sceneCap()
        return frameCache("sceneCap", function()
            if not ShroudGetSceneCap then return nil end
            local cap = ShroudGetSceneCap()
            if not cap then return nil end
            return { level = cap.Level, skill = cap.Skill }
        end)
    end

    --- The per-frame player globals, with absence reported rather than hidden.
    --
    -- ShroudPlayerX/Y/Z, ShroudPlayerCurrentHealth, ShroudPlayerCurrentFocus
    -- and ShroudPlayerGold are documented as refreshed every frame, but on a
    -- real API 4 client none of them existed at all while the character stood
    -- still: the host pushes them with a dirty-check and had not pushed them
    -- yet. Reading them as `x or 0` is therefore wrong in a way that matters --
    -- a tracker that takes 0 as its opening gold balance reports the player's
    -- entire purse as profit the moment the global appears.
    --
    -- Fields are nil when unavailable. `available` is true only when every one
    -- is live; `missing` names the absent ones.
    function P.player()
        local fields = {
            x = ShroudPlayerX,
            y = ShroudPlayerY,
            z = ShroudPlayerZ,
            health = ShroudPlayerCurrentHealth,
            focus = ShroudPlayerCurrentFocus,
            gold = ShroudPlayerGold,
        }
        local missing = {}
        for _, name in ipairs({ "x", "y", "z", "health", "focus", "gold" }) do
            if type(fields[name]) ~= "number" then
                fields[name] = nil
                missing[#missing + 1] = name
            end
        end
        fields.missing = missing
        fields.available = #missing == 0
        fields.hasPosition = fields.x ~= nil and fields.y ~= nil and fields.z ~= nil
        return fields
    end

    function P.pet()
        return frameCache("pet", function()
            if not ShroudGetPetInfo then return nil end
            return ShroudGetPetInfo()
        end)
    end

    --- What the cursor is over. Nil unless the client is API 2 or newer.
    function P.underMouse()
        return frameCache("underMouse", function()
            if not (M.env.HAS_MOUSE and ShroudGetKindUnderMouse) then return nil end
            local kind = ShroudGetKindUnderMouse()
            if kind == nil or kind == "" or kind == "none" then return nil end
            return {
                kind = kind,
                name = ShroudGetNameUnderMouse and ShroudGetNameUnderMouse() or "",
                description = ShroudGetDescriptionUnderMouse and ShroudGetDescriptionUnderMouse() or "",
                id = M.util.numberOr(ShroudGetIdUnderMouse and ShroudGetIdUnderMouse(), -1),
            }
        end)
    end

    --- Drop every cache. Wired to scene load, where all of it goes stale.
    function P.invalidate()
        frame = { at = -1 }
        slow = {}
    end

    function P.install()
        M.events.on("ShroudOnSceneLoaded", P.invalidate, "poll.invalidateOnScene")
        return P
    end

    return P
end
