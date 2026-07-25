-- tests/mock/host.lua -- an offline stand-in for the Shroud* host.
--
-- The point of this file is to be wrong in exactly the ways the real host is
-- wrong. The reference calls its oddities "frozen quirks ... not bugs to work
-- around or report", so a mock that quietly does the sane thing would let
-- quirk-handling bugs through to the game. Reproduced deliberately:
--
--   * ShroudSetPosition stores a negated y; ShroudGetPosition negates it back.
--   * ShroudSetParent returns -1 whether or not it worked.
--   * ShroudPlaySound returns a 0-based channel while ShroudStopSound and
--     ShroudIsChannelPlaying take 1-based ones.
--   * Numeric failures return -999, names return "INVALID"/"None".
--   * ShroudSetToggleReadonly's argument is interactability.
--   * ShroudSetColor accepts unparseable hex and returns true.
--   * ShroudSetButtonColor resets the states it was not given.
--   * ShroudUnsetClickListener does not remove a live listener.
--   * ShroudSetSize refuses toggles and inputs; ShroudHideObject refuses them too.
--   * ShroudGetStatCount counts hidden stats that read back as sentinels.
--   * ShroudListPeriodics returns an enumerator, not a table.
--   * ShroudGetPartyMemberNamesInScene yields a single nil when not in a party.

local Host = {}

local INVALID = -999

----------------------------------------------------------------------
-- World state, freely mutable from tests
----------------------------------------------------------------------

local function freshWorld()
    return {
        apiVersion = 3,
        luaPath = "/game/Lua/",
        dataPath = "/game/Data/",
        time = 0,
        deltaTime = 1 / 60,
        realDeltaTime = 1 / 60,
        serverTime = "2026-07-25 12:00:00Z",
        screen = { x = 1920, y = 1080 },
        mouse = { x = 0, y = 0 },
        fullScreen = true,
        uiActive = true,

        player = {
            name = "Testcharacter",
            x = 10, y = 0, z = -20,
            health = 80, focus = 40, gold = 1234,
            combat = false,
            orientation = 90,
        },
        -- Index 2 is deliberately hidden: a naive 0..count-1 loop must trip on it.
        stats = {
            { name = "Strength", description = "Strength", value = 55 },
            { name = "Dexterity", description = "Dexterity", value = 48 },
            { name = "INVALID", description = "INVALID", value = INVALID, hidden = true },
            { name = "Intelligence", description = "Intelligence", value = 61 },
            { name = "Focus", description = "Focus", value = 120 },
        },
        experience = { pooledAdv = 5000, pooledProd = 250, totalAdv = 900000, totalProd = 42000,
                       attenuationAdv = false, attenuationProd = false },

        target = nil,      -- { name, id, dead, healthHidden, health, maxHealth, focus, maxFocus, buffs }
        playerBuffs = {},
        petBuffs = {},
        pet = nil,

        party = {},        -- { { name, health, maxHealth, focus, maxFocus, inScene } }

        inventory = {},    -- { { name, quantity, value, ... } }
        equipment = {},
        emotes = {},
        decks = {},

        scene = {
            name = "Solace Bridge", raw = "Novia_R1_Forest01",
            orientation = 0, maxPlayers = 24, isPvp = false, isPot = false,
            dungeon = "", dungeonOwner = "",
            cap = { Level = 30, Skill = 80 },
        },
        gameTime = { Day = 12, Hour = 14.5, Month = 3, Year = 452,
                     PeriodOfDay = "Day", Season = "Spring" },

        keysDown = {},
        keysPressed = {},
        keysReleased = {},

        textures = {},     -- path -> id
        sounds = {},
        channels = {},     -- 1-based, holds clip names

        savedVars = { character = {}, account = {} },
        inkVars = {},

        console = {},      -- every ShroudConsoleLog line
        periodics = {},    -- name -> { fn, period, repeating, due }
    }
end

----------------------------------------------------------------------
-- Widget registry
----------------------------------------------------------------------

local function freshWidgets()
    return {
        byKind = {},       -- kind -> array of widget tables (index = id + 1)
        calls = {},        -- every host UI call, for assertions
        canvasVisible = true,
    }
end

local world, widgets

local UIKind = { None = 0, Image = 1, Text = 2, Panel = 3, Button = 4, Toggle = 5, Input = 6 }

local function record(name, ...)
    widgets.calls[#widgets.calls + 1] = { name = name, args = { ... } }
end

local function bucket(kind)
    widgets.byKind[kind] = widgets.byKind[kind] or {}
    return widgets.byKind[kind]
end

local function get(id, kind)
    if type(id) ~= "number" or id < 0 then return nil end
    local list = bucket(kind)
    local w = list[id + 1]
    if not w or w.destroyed then return nil end
    return w
end

local function create(kind, fields)
    local list = bucket(kind)
    -- Freed slots are reused, matching the host's per-kind free list.
    for i, existing in ipairs(list) do
        if existing.destroyed then
            fields.id = i - 1
            fields.kind = kind
            list[i] = fields
            return fields.id
        end
    end
    fields.id = #list
    fields.kind = kind
    list[#list + 1] = fields
    return fields.id
end

----------------------------------------------------------------------
-- Installation
----------------------------------------------------------------------

--- Install every Shroud* global into _G and reset the world.
function Host.install()
    world = freshWorld()
    widgets = freshWidgets()
    Host.world = world
    Host.widgets = widgets

    _G.UI = { None = UIKind.None, Image = UIKind.Image, Text = UIKind.Text,
              Panel = UIKind.Panel, Button = UIKind.Button,
              Toggle = UIKind.Toggle, Input = UIKind.Input }
    _G.TextAnchor = {
        UpperLeft = 0, UpperCenter = 1, UpperRight = 2,
        MiddleLeft = 3, MiddleCenter = 4, MiddleRight = 5,
        LowerLeft = 6, LowerCenter = 7, LowerRight = 8,
    }
    _G.ButtonMode = { None = 0, Normal = 1, Highlighted = 2, Pressed = 3, Disabled = 4 }
    _G.Transition = { None = 0, ColorTint = 1, SpriteSwap = 2 }
    _G.ContentType = { Standard = 0, Autocorrected = 1, IntegerNumber = 2, DecimalNumber = 3,
                       Alphanumeric = 4, Name = 5, EmailAddress = 6, Password = 7,
                       Pin = 8, Custom = 9 }
    _G.AudioType = { WAV = 20, OGGVORBIS = 14, MPEG = 13, AIFF = 2 }

    _G.InvalidStatResult = INVALID
    Host.refreshGlobals()

    for name, fn in pairs(Host.api) do
        _G[name] = fn
    end
    return Host
end

--- Push the per-frame globals, as the host does each frame.
function Host.refreshGlobals()
    _G.ShroudLuaApiVersion = world.apiVersion
    _G.ShroudLuaPath = world.luaPath
    _G.ShroudDataPath = world.dataPath
    _G.ShroudTime = world.time
    _G.ShroudDeltaTime = world.deltaTime
    _G.ShroudRealDeltaTime = world.realDeltaTime
    _G.ShroudServerTime = world.serverTime
    _G.ShroudMouseX = world.mouse.x
    _G.ShroudMouseY = world.mouse.y
    _G.ShroudPlayerX = world.player.x
    _G.ShroudPlayerY = world.player.y
    _G.ShroudPlayerZ = world.player.z
    _G.ShroudPlayerCurrentHealth = world.player.health
    _G.ShroudPlayerCurrentFocus = world.player.focus
    _G.ShroudPlayerGold = world.player.gold
end

----------------------------------------------------------------------
-- The API surface
----------------------------------------------------------------------

Host.api = {}
local api = Host.api

-- Character and stats -------------------------------------------------

function api.ShroudGetPlayerName() return world.player.name or "none" end
function api.ShroudGetPlayerCombatMode() return world.player.combat == true end
function api.ShroudGetPlayerOrientation() return world.player.orientation or 0 end
function api.ShroudGetStatCount() return #world.stats end

function api.ShroudGetStatValueByNumber(i)
    local stat = world.stats[(i or -1) + 1]
    if not stat or stat.hidden then return INVALID end
    return stat.value
end

function api.ShroudGetStatNameByNumber(i)
    local stat = world.stats[(i or -1) + 1]
    if not stat or stat.hidden then return "INVALID" end
    return stat.name
end

function api.ShroudGetStatDescriptionByNumber(i)
    local stat = world.stats[(i or -1) + 1]
    if not stat or stat.hidden then return "INVALID" end
    return stat.description
end

function api.ShroudGetStatValueByName(name)
    for _, stat in ipairs(world.stats) do
        if stat.name == name and not stat.hidden then return stat.value end
    end
    return INVALID
end

function api.ShroudGetPooledAdventurerExperience() return world.experience.pooledAdv end
function api.ShroudGetPooledProducerExperience() return world.experience.pooledProd end
function api.ShroudGetTotalAdventurerExperience() return world.experience.totalAdv end
function api.ShroudGetTotalProducerExperience() return world.experience.totalProd end
function api.ShroudGetAttenuationAdventurerStatus() return world.experience.attenuationAdv end
function api.ShroudGetAttenuationProducerStatus() return world.experience.attenuationProd end

-- Buffs ---------------------------------------------------------------

local function flatEffects(runes)
    local out = {}
    for _, rune in ipairs(runes or {}) do
        for _, effect in ipairs(rune.Effects or {}) do
            out[#out + 1] = { rune = rune, effect = effect }
        end
    end
    return out
end

function api.ShroudGetPlayerBuff()
    if not world.player.name then return nil end
    return world.playerBuffs
end

function api.ShroudGetPetBuff()
    if not world.pet then return nil end
    return world.petBuffs
end

function api.ShroudGetBuffCount() return #flatEffects(world.playerBuffs) end

function api.ShroudGetBuffName(i)
    local entry = flatEffects(world.playerBuffs)[(i or -1) + 1]
    return entry and entry.rune.RuneName or "Invalid"
end

function api.ShroudGetBuffDescription(i)
    local entry = flatEffects(world.playerBuffs)[(i or -1) + 1]
    return entry and entry.effect.Description or "Invalid"
end

function api.ShroudGetBuffTimeRemaining(i)
    local entry = flatEffects(world.playerBuffs)[(i or -1) + 1]
    return entry and entry.effect.CurrentDuration or -1
end

function api.ShroudGetBuffIcon(i)
    if world.apiVersion < 3 then return nil end
    local entry = flatEffects(world.playerBuffs)[(i or -1) + 1]
    return entry and (entry.rune.IconId or -1) or -1
end

function api.ShroudGetBuffTooltip(i)
    if world.apiVersion < 3 then return nil end
    local entry = flatEffects(world.playerBuffs)[(i or -1) + 1]
    if not entry then return "" end
    return entry.rune.RuneName .. "\n" .. (entry.effect.Description or "")
end

-- Target --------------------------------------------------------------

function api.ShroudHasTarget() return world.target ~= nil end
function api.ShroudGetTargetName() return world.target and world.target.name or "None" end
function api.ShroudGetTargetId() return world.target and world.target.id or -1 end
function api.ShroudIsTargetDead() return world.target and world.target.dead == true or false end
function api.ShroudIsTargetHealthHidden()
    return world.target and world.target.healthHidden == true or false
end

function api.ShroudGetTargetCurrentHealth()
    if not world.target then return -1 end
    -- Documented: reports max health when health is hidden.
    if world.target.healthHidden then return world.target.maxHealth end
    return world.target.health
end

function api.ShroudGetTargetMaxHealth()
    return world.target and world.target.maxHealth or -1
end

function api.ShroudGetTargetCurrentFocus() return world.target and world.target.focus or -1 end
function api.ShroudGetTargetMaxFocus() return world.target and world.target.maxFocus or -1 end
function api.ShroudGetTargetBuff() return world.target and world.target.buffs or nil end

function api.ShroudGetTargetBuffCount()
    if not world.target then return 0 end
    return #flatEffects(world.target.buffs)
end

function api.ShroudGetTargetBuffName(i)
    if not world.target then return "Invalid" end
    local entry = flatEffects(world.target.buffs)[(i or -1) + 1]
    return entry and entry.rune.RuneName or "Invalid"
end

function api.ShroudGetTargetBuffDescription(i)
    if not world.target then return "Invalid" end
    local entry = flatEffects(world.target.buffs)[(i or -1) + 1]
    return entry and entry.effect.Description or "Invalid"
end

function api.ShroudGetTargetBuffTimeRemaining(i)
    if not world.target then return -1 end
    local entry = flatEffects(world.target.buffs)[(i or -1) + 1]
    return entry and entry.effect.CurrentDuration or -1
end

function api.ShroudGetTargetBuffIcon(i)
    if world.apiVersion < 3 or not world.target then return -1 end
    local entry = flatEffects(world.target.buffs)[(i or -1) + 1]
    return entry and (entry.rune.IconId or -1) or -1
end

function api.ShroudGetTargetBuffTooltip(i)
    if world.apiVersion < 3 or not world.target then return "" end
    local entry = flatEffects(world.target.buffs)[(i or -1) + 1]
    return entry and entry.rune.RuneName or ""
end

function api.ShroudGetTargetStatValueByNumber() return INVALID end
function api.ShroudGetTargetStatValueByName() return INVALID end

-- Pet -----------------------------------------------------------------

function api.ShroudGetPetInfo() return world.pet end

-- Under the mouse -----------------------------------------------------

function api.ShroudGetKindUnderMouse()
    if world.apiVersion < 2 then return nil end
    return world.underMouse and world.underMouse.kind or "none"
end

function api.ShroudGetNameUnderMouse()
    if world.apiVersion < 2 then return nil end
    return world.underMouse and world.underMouse.name or ""
end

function api.ShroudGetDescriptionUnderMouse()
    if world.apiVersion < 2 then return nil end
    return world.underMouse and world.underMouse.description or ""
end

function api.ShroudGetIdUnderMouse()
    if world.apiVersion < 2 then return nil end
    return world.underMouse and world.underMouse.id or -1
end

-- Party ---------------------------------------------------------------

function api.ShroudGetPartyMemberCount() return #world.party end

local function member(i) return world.party[(i or -1) + 1] end

function api.ShroudGetPartyMemberName(i)
    local m = member(i)
    return m and m.name or "INVALID"
end

function api.ShroudGetPartyMemberCurrentHealth(i)
    local m = member(i); return m and m.health or INVALID
end
function api.ShroudGetPartyMemberMaxHealth(i)
    local m = member(i); return m and m.maxHealth or INVALID
end
function api.ShroudGetPartyMemberCurrentFocus(i)
    local m = member(i); return m and m.focus or INVALID
end
function api.ShroudGetPartyMemberMaxFocus(i)
    local m = member(i); return m and m.maxFocus or INVALID
end

function api.ShroudGetPartyMemberCountInScene()
    local n = 0
    for _, m in ipairs(world.party) do if m.inScene then n = n + 1 end end
    return n
end

function api.ShroudGetPartyMemberNamesInScene()
    local out = {}
    for _, m in ipairs(world.party) do
        if m.inScene then out[#out + 1] = m.name end
    end
    -- Documented: when not in a party the list holds a single nil element.
    if #world.party == 0 then return { nil } end
    return out
end

local function findMember(name)
    for _, m in ipairs(world.party) do
        if m.inScene and m.name:lower() == tostring(name):lower() then return m end
    end
    return nil
end

function api.ShroudGetPartyMemberCurrentHealthInScene(n)
    local m = findMember(n); return m and m.health or INVALID
end
function api.ShroudGetPartyMemberMaxHealthInScene(n)
    local m = findMember(n); return m and m.maxHealth or INVALID
end
function api.ShroudGetPartyMemberCurrentFocusInScene(n)
    local m = findMember(n); return m and m.focus or INVALID
end
function api.ShroudGetPartyMemberMaxFocusInScene(n)
    local m = findMember(n); return m and m.maxFocus or INVALID
end

-- Inventory, equipment, decks, emotes ---------------------------------

local INVENTORY_ORDER = { "name", "durability", "primaryDurability", "maxDurability",
                          "weight", "quantity", "createdBy", "creationTime", "creationScene",
                          "size", "value", "collectedBy", "collectedDate", "collectedZone" }
local EQUIPMENT_ORDER = { "name", "durability", "primaryDurability", "maxDurability",
                          "weight", "quantity", "value" }

local function toTuple(item, order)
    local row = {}
    for i, field in ipairs(order) do
        local value = item[field]
        if value == nil then
            value = (field == "name" or field:match("^c") or field == "creationTime") and "" or 0
        end
        row[i] = value
    end
    return row
end

function api.ShroudGetInventory()
    if not world.inventory then return nil end
    local out = {}
    for i, item in ipairs(world.inventory) do out[i] = toTuple(item, INVENTORY_ORDER) end
    return out
end

function api.ShroudGetEquipments()
    if not world.equipment then return nil end
    local out = {}
    for i, item in ipairs(world.equipment) do out[i] = toTuple(item, EQUIPMENT_ORDER) end
    return out
end

function api.ShroudEmoteList()
    if #world.emotes == 0 then return nil end
    return world.emotes
end

function api.ShroudPlayEmote(name)
    for _, e in ipairs(world.emotes) do
        if e == name then
            Host.fire("ShroudOnPlayEmote", name)
            return true
        end
    end
    return false
end

function api.ShroudCurrentDeck() return world.decks[1] end
function api.ShroudDeckList() return world.decks end
function api.ShroudGetDeckCardList() return {} end
function api.ShroudSwitchDeck() return false end   -- stub in the real host too

-- Scene and world -----------------------------------------------------

function api.ShroudGetCurrentSceneName() return world.scene.name end
function api.ShroudGetCurrentSceneNameRaw() return world.scene.raw end
function api.ShroudGetCurrentSceneOrientation() return world.scene.orientation end
function api.ShroudGetCurrentSceneMaxPlayerCount() return world.scene.maxPlayers end
function api.ShroudGetCurrentSceneIsPVP() return world.scene.isPvp end
function api.ShroudGetCurrentSceneIsPOT() return world.scene.isPot end
function api.ShroudGetCurrentDungeonName() return world.scene.dungeon end
function api.ShroudGetCurrentDungeonOwner() return world.scene.dungeonOwner end
function api.ShroudGetSceneCap() return world.scene.cap end
function api.ShroudGetGameTime() return world.gameTime end

-- World height is deliberately unused: the projection here only needs to put y
-- in bottom-left screen space, the opposite of widget space, so that callers
-- who forget to flip it are caught.
function api.ShroudWorldToScreenPoint(x, _worldY, z)
    return { x = x * 10, y = world.screen.y - (z or 0) * 10, z = 1 }
end

-- Screen and input ----------------------------------------------------

function api.ShroudGetScreenX() return world.screen.x end
function api.ShroudGetScreenY() return world.screen.y end
function api.ShroudGetFullScreen() return world.fullScreen end
function api.ShroudIsUIActive() return world.uiActive end
function api.ShroudIsCharacterSheetActive() return false end
function api.ShroudGetCharacterSheetPosition() return 0, 0 end
function api.ShroudGetKeyDown(k) return world.keysDown[k] == true end
function api.ShroudGetOnKeyDown(k) return world.keysPressed[k] == true end
function api.ShroudGetOnKeyUp(k) return world.keysReleased[k] == true end

-- Widgets: creation ---------------------------------------------------

local function newWidget(kind, x, y, w, h, extra)
    local fields = { x = x or 0, y = y or 0, width = w or 0, height = h or 0,
                     visible = true, alpha = 1, color = nil, parent = nil,
                     draggable = false, resizable = nil, clickListener = false,
                     hoverListener = false, destroyed = false }
    for k, v in pairs(extra or {}) do fields[k] = v end
    return create(kind, fields)
end

function api.ShroudUIPanel(x, y, w, h, tex, pid, pkind, depth)
    record("ShroudUIPanel", x, y, w, h, tex, pid, pkind, depth)
    -- Panels ship with a Mask already attached; images do not.
    return newWidget(UIKind.Panel, x, y, w, h, { texture = tex, masked = true,
                                                 parentId = pid, parentKind = pkind })
end

function api.ShroudUIImage(x, y, w, h, tex, pid, pkind, depth)
    record("ShroudUIImage", x, y, w, h, tex, pid, pkind, depth)
    if type(tex) ~= "number" or tex < 0 then return -1 end
    return newWidget(UIKind.Image, x, y, w, h, { texture = tex, masked = false,
                                                 parentId = pid, parentKind = pkind })
end

function api.ShroudUIText(text, fontSize, x, y, w, h, pid, pkind, depth)
    record("ShroudUIText", text, fontSize, x, y, w, h, pid, pkind, depth)
    return newWidget(UIKind.Text, x, y, w, h, { text = text, fontSize = fontSize,
                                                alignment = _G.TextAnchor.UpperLeft,
                                                parentId = pid, parentKind = pkind })
end

function api.ShroudUIButton(x, y, w, h, tex, pid, pkind, depth)
    record("ShroudUIButton", x, y, w, h, tex, pid, pkind, depth)
    if type(tex) ~= "number" or tex < 0 then return -1 end
    return newWidget(UIKind.Button, x, y, w, h, { texture = tex, colors = {},
                                                  parentId = pid, parentKind = pkind })
end

function api.ShroudUIInput(x, y, w, h, pid, pkind)
    record("ShroudUIInput", x, y, w, h, pid, pkind)
    return newWidget(UIKind.Input, x, y, w or 20, h or 20,
        { text = "", placeholder = "Enter text...", parentId = pid, parentKind = pkind })
end

function api.ShroudUIToggle(x, y, w, h, pid, pkind)
    record("ShroudUIToggle", x, y, w, h, pid, pkind)
    return newWidget(UIKind.Toggle, x, y, w or 20, h or 20,
        { on = false, interactable = true, parentId = pid, parentKind = pkind })
end

-- Widgets: transform --------------------------------------------------

function api.ShroudSetPosition(id, kind, x, y)
    local w = get(id, kind); if not w then return false end
    -- The host negates y internally; ShroudGetPosition negates it back.
    w.x, w.anchoredY = x, -y
    return true
end

function api.ShroudGetPosition(id, kind)
    local w = get(id, kind); if not w then return nil end
    return { x = w.x, y = -(w.anchoredY or -w.y) }
end

function api.ShroudSetSize(id, kind, width, height)
    -- Documented: toggles and inputs are not supported.
    if kind == UIKind.Toggle or kind == UIKind.Input then return false end
    local w = get(id, kind); if not w then return false end
    w.width, w.height = width, height
    return true
end

function api.ShroudSetScale(id, kind, scale)
    local w = get(id, kind); if not w then return false end
    w.scale = scale; return true
end

function api.ShroudSetPivot(id, kind, px, py)
    local w = get(id, kind); if not w then return false end
    -- Side effect: the current anchored position is multiplied by the new pivot.
    w.pivot = { px, py }
    w.x = w.x * px
    w.anchoredY = (w.anchoredY or 0) * py
    return true
end

function api.ShroudSetAnchorMin(id, kind, x, y)
    local w = get(id, kind); if not w then return false end
    w.anchorMin = { x, y }; return true
end

function api.ShroudSetAnchorMax(id, kind, x, y)
    local w = get(id, kind); if not w then return false end
    w.anchorMax = { x, y }; return true
end

function api.ShroudRotateObject(id, kind, degrees)
    local w = get(id, kind); if not w then return false end
    w.rotation = degrees; return true   -- absolute, not accumulated
end

function api.ShroudSetColor(id, kind, hexColor)
    -- Buttons are rejected outright; use ShroudSetButtonColor.
    if kind == UIKind.Button then return false end
    local w = get(id, kind); if not w then return false end
    -- Unparseable hex still returns true and paints transparent black.
    if type(hexColor) ~= "string" or not hexColor:match("^#%x%x%x%x%x%x") then
        w.color = "#00000000"
        return true
    end
    w.color = hexColor
    return true
end

function api.ShroudSetTransparency(id, kind, alpha)
    local w = get(id, kind); if not w then return false end
    w.alpha = alpha; return true
end

function api.ShroudModifyImage(id, kind, tex)
    if kind == UIKind.Text then return false end
    local w = get(id, kind); if not w then return false end
    w.texture = tex; return true
end

function api.ShroudModifyText(id, text)
    local w = get(id, UIKind.Text); if not w then return false end
    w.text = text; return true
end

function api.ShroudSetTextAlignment(id, anchor)
    local w = get(id, UIKind.Text)
    -- Documented: no upper bound check, an out-of-range id throws.
    if not w then error("ShroudSetTextAlignment: index out of range: " .. tostring(id)) end
    w.alignment = anchor; return true
end

function api.ShroudSetFontSize(id, kind, size)
    if kind ~= UIKind.Text and kind ~= UIKind.Input then return false end
    local w = get(id, kind); if not w then return false end
    w.fontSize = size; return true
end

function api.ShroudSetMask(id, kind)
    if kind ~= UIKind.Image and kind ~= UIKind.Panel then return false end
    local w = get(id, kind); if not w then return false end
    if w.masked then return false end   -- panels are already masked
    w.masked = true; return true
end

function api.ShroudUnsetMask(id, kind)
    local w = get(id, kind); if not w then return false end
    w.masked = false; return true
end

-- Widgets: parenting and behavior -------------------------------------

function api.ShroudSetParent(id, kind, parentId, parentKind)
    local w = get(id, kind)
    if w then w.parentId, w.parentKind = parentId, parentKind end
    return -1   -- always -1, success or not
end

api.ShroudSetPanelParent = function(id, p, pk) return api.ShroudSetParent(id, UIKind.Panel, p, pk) end
api.ShroudSetImageParent = function(id, p, pk) return api.ShroudSetParent(id, UIKind.Image, p, pk) end
api.ShroudSetTextParent = function(id, p, pk) return api.ShroudSetParent(id, UIKind.Text, p, pk) end
api.ShroudSetButtonParent = function(id, p, pk) return api.ShroudSetParent(id, UIKind.Button, p, pk) end

function api.ShroudGetParentID(id, kind)
    local w = get(id, kind); if not w then return -1 end
    return w.parentId or -1
end

function api.ShroudGetParentObjectKind(id, kind)
    local w = get(id, kind); if not w then return UIKind.None end
    return w.parentKind or UIKind.None
end

function api.ShroudSetDragguable(id, kind)
    if kind ~= UIKind.Panel and kind ~= UIKind.Image then return false end
    local w = get(id, kind); if not w then return false end
    w.draggable = true; return true
end

function api.ShroudUnsetDragguable(id, kind)
    local w = get(id, kind); if not w then return false end
    w.draggable = false; return true
end

function api.ShroudSetResizable(id, kind, direction)
    if kind ~= UIKind.Panel then return false end
    local w = get(id, kind); if not w then return false end
    -- Requires the drag component first.
    if not w.draggable then return false end
    w.resizable = tostring(direction):lower(); return true
end

function api.ShroudMinMaxSize(id, kind, min, max, direction)
    local w = get(id, kind); if not w then return false end
    w.minMax = { min = min, max = max, direction = direction }; return true
end

function api.ShroudSetInOutListener(id, kind)
    local w = get(id, kind); if not w then return false end
    w.hoverListener = true; return true
end

function api.ShroudUnsetInOutListener(id, kind)
    local w = get(id, kind); if not w then return false end
    -- Documented: tests for the drag component, not the listener, so it fails
    -- on a draggable widget and leaves the listener attached.
    if w.draggable then return false end
    w.hoverListener = false; return true
end

function api.ShroudSetClickListener(id, kind)
    local w = get(id, kind); if not w then return false end
    w.clickListener = true; return true
end

function api.ShroudUnsetClickListener(id, kind)
    if kind ~= UIKind.Image and kind ~= UIKind.Panel then return false end
    local w = get(id, kind); if not w then return false end
    -- Documented: the removal branch is inverted, so it only "removes" when no
    -- listener is present. A live listener survives.
    if not w.clickListener then return true end
    return false
end

function api.ShroudRaycastObject(id, kind, enable)
    local w = get(id, kind); if not w then return false end
    w.raycast = enable; return true
end

function api.ShroudHideObject(id, kind)
    -- Toggles and inputs cannot be hidden.
    if kind == UIKind.Toggle or kind == UIKind.Input then return false end
    local w = get(id, kind); if not w then return false end
    w.visible = false; return true
end

function api.ShroudShowObject(id, kind)
    if kind == UIKind.Toggle or kind == UIKind.Input then return false end
    local w = get(id, kind); if not w then return false end
    w.visible = true; return true
end

function api.ShroudHideLuaUI() widgets.canvasVisible = false; return true end
function api.ShroudShowLuaUI() widgets.canvasVisible = true; return true end

function api.ShroudDestroyObject(id, kind)
    local w = get(id, kind); if not w then return false end
    w.destroyed = true; return true
end

-- Widgets: buttons, inputs, toggles -----------------------------------

function api.ShroudSetButtonColor(id, mode, hexColor)
    local w = get(id, UIKind.Button); if not w then return false end
    if mode == _G.ButtonMode.None then return false end
    -- Documented: a fresh color block is assigned each call, zeroing the three
    -- states not mentioned.
    w.colors = { [mode] = hexColor }
    return true
end

function api.ShroudSetButtonImage(id, mode, tex)
    local w = get(id, UIKind.Button); if not w then return false end
    w.sprites = w.sprites or {}
    w.sprites[mode] = tex
    return true
end

function api.ShroudSetButtonTransition(id, transition)
    -- Documented: only the upper bound is checked, so a negative id throws.
    if type(id) ~= "number" or id < 0 then
        error("ShroudSetButtonTransition: negative index: " .. tostring(id))
    end
    local w = get(id, UIKind.Button); if not w then return false end
    w.transition = transition; return true
end

function api.ShroudGetInputText(id)
    local w = get(id, UIKind.Input); if not w then return nil end
    return w.text
end

function api.ShroudSetInputText(id, text)
    local w = get(id, UIKind.Input); if not w then return false end
    w.text = text
    Host.fire("ShroudOnInputChange", id, text)
    return true
end

function api.ShroudSetInputContentType(id, t)
    local w = get(id, UIKind.Input); if not w then return false end
    w.contentType = t; return true
end

function api.ShroudSetPlaceholderText(id, text)
    local w = get(id, UIKind.Input); if not w then return false end
    w.placeholder = text; return true
end

function api.ShroudSetInputBackgroundColor(id, hexColor)
    local w = get(id, UIKind.Input); if not w then return false end
    w.background = hexColor; return true
end

function api.ShroudSetInputCharacterLimit(id, limit)
    local w = get(id, UIKind.Input); if not w then return false end
    w.characterLimit = limit; return true
end

function api.ShroudSetInputReadonly(id, isOn)
    local w = get(id, UIKind.Input); if not w then return false end
    w.readonly = isOn; return true
end

function api.ShroudGetToggle(id)
    if type(id) ~= "number" or id < 0 then
        error("ShroudGetToggle: negative index: " .. tostring(id))
    end
    local w = get(id, UIKind.Toggle); if not w then return false end
    return w.on
end

function api.ShroudSetToggle(id, enabled)
    if type(id) ~= "number" or id < 0 then
        error("ShroudSetToggle: negative index: " .. tostring(id))
    end
    local w = get(id, UIKind.Toggle); if not w then return false end
    w.on = enabled
    Host.fire("ShroudOnToggleChange", id, enabled)
    return true
end

function api.ShroudSetToggleReadonly(id, enabled)
    if type(id) ~= "number" or id < 0 then
        error("ShroudSetToggleReadonly: negative index: " .. tostring(id))
    end
    local w = get(id, UIKind.Toggle); if not w then return false end
    -- The argument is interactability, the opposite of the name.
    w.interactable = enabled
    return true
end

-- Legacy immediate-mode -----------------------------------------------

function api.ShroudGUILabel(x, y, w, h, text) record("ShroudGUILabel", x, y, w, h, text); return true end
function api.ShroudButton(x, y, w, h, tex) record("ShroudButton", x, y, w, h, tex); return false end
function api.ShroudButtonRepeat(x, y, w, h, tex) record("ShroudButtonRepeat", x, y, w, h, tex); return false end
function api.ShroudDrawTexture(x, y, w, h, tex)
    record("ShroudDrawTexture", x, y, w, h, tex)
    return type(tex) == "number" and tex >= 0
end
function api.ShroudDrawTextureTooltip(x, y, w, h, tex, text)
    if world.apiVersion < 3 then return nil end
    record("ShroudDrawTextureTooltip", x, y, w, h, tex, text)
    return type(tex) == "number" and tex >= 0
end
function api.ShroudGUITooltip(x, y, w, h, text)
    if world.apiVersion < 3 then return nil end
    record("ShroudGUITooltip", x, y, w, h, text)
    return true
end

-- Textures and sound --------------------------------------------------

local nextTexture = 0

function api.ShroudLoadTexture(path)
    if type(path) ~= "string" or path:find("%.%.") then return -1 end
    local lower = path:lower()
    if world.textures[lower] then return world.textures[lower] end
    if not world.textureFiles or not world.textureFiles[path] then return -1 end
    nextTexture = nextTexture + 1
    world.textures[lower] = nextTexture
    return nextTexture
end

function api.ShroudGetTextureSize(id)
    for _, assigned in pairs(world.textures) do
        if assigned == id then return 64, 64 end
    end
    return nil
end

function api.ShroudSetTextureClamp() return true end

function api.ShroudLoadSound(path)
    if type(path) ~= "string" or path:find("%.%.") then return false end
    world.sounds[#world.sounds + 1] = path
    return true
end

function api.ShroudListSound() return world.sounds end

function api.ShroudListSoundReset()
    world.sounds, world.channels = {}, {}
    return true
end

function api.ShroudPlaySound(id)
    -- Clip ids are 1-based; the returned channel is 0-based.
    if type(id) ~= "number" or id < 1 or not world.sounds[id] then return -1 end
    for channel = 1, 5 do
        if not world.channels[channel] then
            world.channels[channel] = world.sounds[id]
            return channel - 1
        end
    end
    return -1
end

function api.ShroudStopSound(channel)
    -- Channels are 1-based here, unlike the value ShroudPlaySound returned.
    if type(channel) ~= "number" or channel < 1 or channel > 5 then return false end
    world.channels[channel] = nil
    return true
end

function api.ShroudIsChannelPlaying(channel)
    if type(channel) ~= "number" or channel < 1 or channel > 5 then return "" end
    return world.channels[channel] or ""
end

function api.ShroudStopUISound() return true end
function api.ShroudSceneMusic() return true end
function api.ShroudStopFX() return true end

-- Console, GC, timers -------------------------------------------------

function api.ShroudConsoleLog(message)
    if message == nil then return nil end
    for line in tostring(message):gmatch("[^\n]+") do
        world.console[#world.console + 1] = line
    end
    return message
end

api.ConsoleLog = api.ShroudConsoleLog

function api.ShroudUseLuaConsoleForPrint() return true end
function api.ShroudForceGC() return true end

function api.ShroudRegisterPeriodic(name, functionName, period, repeating)
    if type(period) ~= "number" or period < 0.01 then return false end
    if type(_G[functionName]) ~= "function" then return false end
    world.periodics[name] = {
        functionName = functionName,
        period = period,
        repeating = repeating and true or false,
        due = world.time + period,
    }
    return true
end

function api.ShroudRemovePeriodic(name)
    local existed = world.periodics[name] ~= nil
    world.periodics[name] = nil
    return existed
end

function api.ShroudListPeriodics()
    -- An enumerator, not a table: "drive it with a generic for".
    local names = {}
    for name in pairs(world.periodics) do names[#names + 1] = name end
    table.sort(names)
    local i = 0
    return function()
        i = i + 1
        return names[i]
    end
end

-- Saved variables -----------------------------------------------------

local function scopeStore(scope)
    scope = tostring(scope or "character"):lower()
    if scope ~= "account" then scope = "character" end
    return world.savedVars[scope], scope
end

function api.ShroudSetSavedVar(key, value, scope)
    if type(key) ~= "string" or key == "" or #key > 128 then return false end
    if key:find("[/\\]") or key:find("%c") then return false end
    local kind = type(value)
    if kind == "function" or kind == "thread" or kind == "userdata" then return false end
    local store = scopeStore(scope)
    store[key] = value
    world.savedVarsDirty = true
    return true
end

function api.ShroudGetSavedVar(key, scope)
    local store = scopeStore(scope)
    return store[key]   -- by reference, as documented
end

function api.ShroudDeleteSavedVar(key, scope)
    local store = scopeStore(scope)
    local existed = store[key] ~= nil
    store[key] = nil
    world.savedVarsDirty = true
    return existed
end

function api.ShroudFlushSavedVars()
    world.savedVarsDirty = false
    world.savedVarFlushes = (world.savedVarFlushes or 0) + 1
    return true
end

-- Ink bridge ----------------------------------------------------------

function api.ShroudSaveInkVariable(name, value)
    if type(name) ~= "string" or name == "" then return false end
    if type(value) == "boolean" then value = value and "1" or "0"
    elseif type(value) == "number" then
        value = value % 1 == 0 and string.format("%d", value) or tostring(value)
    else value = tostring(value) end
    if #value > 8192 then return false end
    world.inkVars[name] = value
    return true
end

function api.ShroudLoadInkVariable(name) return world.inkVars[name] end
function api.ShroudHasInkVariable(name) return world.inkVars[name] ~= nil end

function api.ShroudDeleteInkVariable(name)
    local existed = world.inkVars[name] ~= nil
    world.inkVars[name] = nil
    return existed
end

----------------------------------------------------------------------
-- Driving the harness
----------------------------------------------------------------------

--- Invoke a global callback the way the host would, if the addon defined it.
function Host.fire(name, ...)
    local fn = _G[name]
    if type(fn) == "function" then return fn(...) end
    return nil
end

--- Advance time by `dt` and run one frame: per-frame globals, due periodics,
--- then ShroudOnUpdate.
function Host.frame(dt)
    dt = dt or world.deltaTime
    world.time = world.time + dt
    world.deltaTime = math.min(dt, 0.1)   -- the host clamps at the max timestep
    world.realDeltaTime = dt
    Host.refreshGlobals()

    for name, timer in pairs(world.periodics) do
        if timer.due <= world.time then
            if timer.repeating then
                timer.due = world.time + timer.period
            else
                world.periodics[name] = nil
            end
            Host.fire(timer.functionName)
        end
    end

    Host.fire("ShroudOnUpdate")
end

function Host.frames(count, dt)
    for _ = 1, count do Host.frame(dt) end
end

--- The documented load sequence: saved vars are already populated, the file
--- body has run, and ShroudOnStart fires immediately after.
function Host.start()
    Host.fire("ShroudOnStart")
end

--- Disable the addon the way the manager does.
function Host.disable()
    Host.fire("ShroudOnDisableScript")
end

function Host.logout()
    Host.fire("ShroudOnLogOut")
end

function Host.loadScene(name)
    world.scene.name = name or world.scene.name
    Host.fire("ShroudOnSceneLoaded", world.scene.name)
end

function Host.chat(inputType, source, message)
    Host.fire("ShroudOnConsoleInput", inputType, source, message)
end

function Host.gainExperience(kind, amount)
    if kind == "Adventurer" then
        world.experience.pooledAdv = world.experience.pooledAdv + amount
        world.experience.totalAdv = world.experience.totalAdv + amount
    else
        world.experience.pooledProd = world.experience.pooledProd + amount
        world.experience.totalProd = world.experience.totalProd + amount
    end
    Host.fire("ShroudOnExperienceGain", kind, amount)
end

function Host.clickWidget(id, kind) Host.fire("ShroudOnMouseClick", id, kind) end
function Host.hoverWidget(id, kind) Host.fire("ShroudOnMouseOver", id, kind) end
function Host.unhoverWidget(id, kind) Host.fire("ShroudOnMouseOut", id, kind) end

----------------------------------------------------------------------
-- Inspection helpers for assertions
----------------------------------------------------------------------

--- Every widget of a kind that has not been destroyed.
function Host.liveWidgets(kind)
    local out = {}
    for k, list in pairs(widgets.byKind) do
        if kind == nil or k == kind then
            for _, w in ipairs(list) do
                if not w.destroyed then out[#out + 1] = w end
            end
        end
    end
    return out
end

function Host.liveWidgetCount(kind) return #Host.liveWidgets(kind) end

--- The text of every live text widget, in creation order.
function Host.texts()
    local out = {}
    for _, w in ipairs(Host.liveWidgets(UIKind.Text)) do out[#out + 1] = w.text end
    return out
end

--- True when any live text widget contains `needle`.
function Host.hasText(needle)
    for _, text in ipairs(Host.texts()) do
        if tostring(text):find(needle, 1, true) then return true end
    end
    return false
end

function Host.console() return world.console end

function Host.consoleContains(needle)
    for _, line in ipairs(world.console) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

function Host.callCount(name)
    local n = 0
    for _, call in ipairs(widgets.calls) do
        if call.name == name then n = n + 1 end
    end
    return n
end

return Host
