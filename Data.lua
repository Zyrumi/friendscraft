-- FriendsCraft: data
-- One record per character (yours, your alts, your friends):
--   name, class, level, seen (time), mine (true for your own characters)
--   rev      = { prof = t, recipes = t, items = t, shop = t }  change times
--   prof     = { { line = skillLineID, name = "Herbalism", rank = 87, max = 150, icon = fileID }, ... }
--   recipes  = { ["Tailoring"] = { [recipeID] = outputItemID or 0 }, ... }
--   items    = { [itemID] = { bags, bank } }
--   shop     = { [itemID] = count wanted }
--   money    = copper carried
--
-- Each section is sent to friends as a short text (see Encode/Decode).

local ADDON_NAME, ns = ...

ns.SECTIONS = { "prof", "recipes", "items", "shop", "money" }

-------------------------------------------------------------------------------
-- Records
-------------------------------------------------------------------------------

function ns.Person(key, create)
    local p = ns.db.people[key]
    if not p and create then
        p = { rev = {}, prof = {}, recipes = {}, items = {}, shop = {}, money = 0 }
        ns.db.people[key] = p
        if ns.Changed then ns.Changed() end
    end
    return p
end

function ns.Me()
    return ns.Person(ns.me, true)
end

-- Searches are cached until something changes. Call ns.Changed() after
-- changing anyone's data, the crew or the hidden list.
local cache = {}
function ns.Changed()
    cache = {}
end

-- Characters shown in the window and tooltips: you, your alts, and your
-- crew. People you hid are left out unless includeHidden is set.
-- Returns a new list each time (safe to sort).
local function BuildVisible(includeHidden)
    local list = {}
    local function Shown(key)
        return key == ns.me or includeHidden or not ns.db.hidden[key]
    end
    for key, p in pairs(ns.db.people) do
        if (p.mine or ns.db.crew[key]) and Shown(key) then
            list[#list + 1] = key
        end
    end
    for key in pairs(ns.db.crew) do
        if not ns.db.people[key] and Shown(key) then
            list[#list + 1] = key -- friend we have no data from yet
        end
    end
    table.sort(list, function(a, b)
        if a == ns.me then return true end
        if b == ns.me then return false end
        return a < b
    end)
    return list
end

function ns.VisiblePeople(includeHidden)
    local slot = includeHidden and "visibleAll" or "visible"
    if not cache[slot] then
        cache[slot] = BuildVisible(includeHidden)
    end
    local copy = {}
    for i, key in ipairs(cache[slot]) do
        copy[i] = key
    end
    return copy
end

-------------------------------------------------------------------------------
-- Encoding: compact text, no "|" (the chat system treats it specially).
-------------------------------------------------------------------------------

local Encode, Decode = {}, {}

-- prof: line,name,rank,max,icon;...
function Encode.prof(prof)
    local parts = {}
    for _, e in ipairs(prof) do
        local name = (e.name or "?"):gsub("[,;%^|]", "")
        local icon = type(e.icon) == "number" and e.icon or 0
        parts[#parts + 1] = string.format("%d,%s,%d,%d,%d", e.line or 0, name, e.rank or 0, e.max or 0, icon)
    end
    return table.concat(parts, ";")
end

function Decode.prof(s)
    local out = {}
    for entry in s:gmatch("[^;]+") do
        local line, name, rank, max, icon = entry:match("^(%-?%d+),([^,]*),(%d+),(%d+),?(%d*)$")
        if line then
            out[#out + 1] = { line = tonumber(line), name = (name:gsub("|", "")), rank = tonumber(rank), max = tonumber(max),
                icon = tonumber(icon) ~= 0 and tonumber(icon) or nil }
        end
    end
    return out
end

-- recipes: Profession=recipeID/itemID,recipeID/itemID;Profession2=...
function Encode.recipes(recipes)
    local parts = {}
    local profs = {}
    for prof in pairs(recipes) do
        profs[#profs + 1] = prof
    end
    table.sort(profs)
    for _, prof in ipairs(profs) do
        local ids = {}
        for rid, out in pairs(recipes[prof]) do
            ids[#ids + 1] = rid .. "/" .. (out or 0)
        end
        table.sort(ids)
        parts[#parts + 1] = prof:gsub("[=,;/%^|]", "") .. "=" .. table.concat(ids, ",")
    end
    return table.concat(parts, ";")
end

function Decode.recipes(s)
    local out = {}
    for prof, list in s:gmatch("([^=;]+)=([^;]*)") do
        local t = {}
        for rid, item in list:gmatch("(%-?%d+)/(%d+)") do
            t[tonumber(rid)] = tonumber(item)
        end
        out[(prof:gsub("|", ""))] = t
    end
    return out
end

-- items: itemID,bags,bank;...
function Encode.items(items)
    local ids = {}
    for id in pairs(items) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        local c = items[id]
        parts[#parts + 1] = id .. "," .. (c[1] or 0) .. "," .. (c[2] or 0)
    end
    return table.concat(parts, ";")
end

function Decode.items(s)
    local out = {}
    for id, bags, bank in s:gmatch("(%d+),(%d+),(%d+)") do
        out[tonumber(id)] = { tonumber(bags), tonumber(bank) }
    end
    return out
end

-- shop: itemID,count;...
function Encode.shop(shop)
    local ids = {}
    for id in pairs(shop) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        parts[#parts + 1] = id .. "," .. shop[id]
    end
    return table.concat(parts, ";")
end

function Decode.shop(s)
    local out = {}
    for id, count in s:gmatch("(%d+),(%d+)") do
        out[tonumber(id)] = tonumber(count)
    end
    return out
end

-- money: copper as a whole number
function Encode.money(money)
    return string.format("%d", math.max(0, math.floor(tonumber(money) or 0)))
end

function Decode.money(s)
    return tonumber(s:match("^(%d+)$")) or 0
end

ns.Encode, ns.Decode = Encode, Decode

-------------------------------------------------------------------------------
-- Updating my own record
-------------------------------------------------------------------------------

-- Stores a new value for one of my sections. If it really changed, the
-- change time goes up and online friends get the new version.
local function SetMine(section, value)
    local me = ns.Me()
    if Encode[section](me[section]) == Encode[section](value) and me.rev[section] then
        return false
    end
    me[section] = value
    me.rev[section] = math.max(time(), (me.rev[section] or 0) + 1)
    ns.Changed()
    if ns.Broadcast then
        ns.Broadcast(section)
    end
    if ns.RefreshUI then
        ns.RefreshUI()
    end
    return true
end
ns.SetMine = SetMine

function ns.UpdateBasics()
    local me = ns.Me()
    me.mine = true
    me.name = ns.me
    me.level = UnitLevel("player")
    me.class = select(2, UnitClass("player"))
    me.seen = time()
end

-------------------------------------------------------------------------------
-- Professions
-------------------------------------------------------------------------------

function ns.ScanProfessions()
    if not GetProfessions or not GetProfessionInfo then
        return
    end
    local list = {}
    local indexes = { GetProfessions() }
    for i = 1, 6 do
        local index = indexes[i]
        if index then
            local name, icon, rank, max, _, _, line = GetProfessionInfo(index)
            if type(name) == "string" and not ns.IsSecret(name) then
                list[#list + 1] = { line = tonumber(line) or 0, name = name, rank = tonumber(rank) or 0,
                    max = tonumber(max) or 0, icon = type(icon) == "number" and icon or nil }
            end
        end
    end
    SetMine("prof", list)
end

-------------------------------------------------------------------------------
-- Recipes: the game only lists them while the profession window is open.
-------------------------------------------------------------------------------

local function ScanRecipesModern()
    local T = C_TradeSkillUI
    if not T or not T.GetAllRecipeIDs or not T.GetRecipeInfo then
        return false
    end
    -- Skip other players' linked professions and NPC crafting.
    if (T.IsTradeSkillLinked and T.IsTradeSkillLinked())
        or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
        or (T.IsNPCCrafting and T.IsNPCCrafting()) then
        return true
    end
    local info = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
    local prof = info and info.professionName
    if not prof or prof == "" then
        return true
    end
    local known = {}
    local okIDs, ids = pcall(T.GetAllRecipeIDs)
    for _, rid in ipairs(okIDs and ids or {}) do
        local ok, r = pcall(T.GetRecipeInfo, rid)
        if ok and r and r.learned and type(rid) == "number" then
            local out = 0
            local okS, schem = pcall(T.GetRecipeSchematic or error, rid, false)
            if okS and schem and type(schem.outputItemID) == "number" then
                out = schem.outputItemID
            end
            known[rid] = out
        end
    end
    if next(known) then
        local all = {}
        for k, v in pairs(ns.Me().recipes) do
            all[k] = v
        end
        all[prof] = known
        SetMine("recipes", all)
    end
    return true
end

-- Older-style profession window: no recipe IDs, so store items only
-- (negative IDs mark "made item, recipe unknown").
local function ScanRecipesClassic()
    if not GetNumTradeSkills or not GetTradeSkillLine then
        return
    end
    local prof = GetTradeSkillLine()
    if not prof or prof == "" or prof == "UNKNOWN" then
        return
    end
    local known = {}
    for i = 1, GetNumTradeSkills() do
        local _, kind = GetTradeSkillInfo(i)
        if kind ~= "header" then
            local link = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
            local id = link and tonumber(link:match("item:(%d+)"))
            if id then
                known[-id] = id
            end
        end
    end
    if next(known) then
        local all = {}
        for k, v in pairs(ns.Me().recipes) do
            all[k] = v
        end
        all[prof] = known
        SetMine("recipes", all)
    end
end

function ns.ScanRecipes()
    if not ScanRecipesModern() then
        ScanRecipesClassic()
    end
end

-------------------------------------------------------------------------------
-- Items in bags and bank
-------------------------------------------------------------------------------

local function BagIDs()
    local ids = { 0, 1, 2, 3, 4 }
    if Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag then
        ids[#ids + 1] = Enum.BagIndex.ReagentBag
    end
    return ids
end

local function BankIDs()
    local ids, seen = {}, {}
    for _, id in ipairs(BagIDs()) do
        seen[id] = true -- never count a carried bag as bank
    end
    local function Add(id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    Add(BANK_CONTAINER or -1)
    if Enum and Enum.BagIndex then
        for k, v in pairs(Enum.BagIndex) do
            if type(k) == "string" and k:find("Bank") and not k:find("Account") then
                Add(v)
            end
        end
    end
    local first = (NUM_BAG_SLOTS or 4) + 1
    for i = first, first + (NUM_BANKBAGSLOTS or 7) do
        Add(i)
    end
    return ids
end

local function CountContainers(ids, into, slot)
    local C = C_Container
    if not C or not C.GetContainerNumSlots then
        return
    end
    for _, bag in ipairs(ids) do
        local ok, n = pcall(C.GetContainerNumSlots, bag)
        if ok and n and n > 0 then
            for s = 1, n do
                local okI, info = pcall(C.GetContainerItemInfo, bag, s)
                info = okI and info
                if info and type(info.itemID) == "number" and not ns.IsSecret(info.itemID) then
                    local e = into[info.itemID]
                    if not e then
                        e = { 0, 0 }
                        into[info.itemID] = e
                    end
                    e[slot] = e[slot] + (tonumber(info.stackCount) or 1)
                end
            end
        end
    end
end

ns.bankOpen = false

-- Bags are always read; the bank only while it is open (otherwise the
-- last bank counts are kept).
function ns.ScanItems()
    local items = {}
    CountContainers(BagIDs(), items, 1)
    if ns.bankOpen then
        CountContainers(BankIDs(), items, 2)
    else
        for id, c in pairs(ns.Me().items) do
            if (c[2] or 0) > 0 then
                local e = items[id] or { 0, 0 }
                e[2] = c[2]
                items[id] = e
            end
        end
    end
    SetMine("items", items)
end

-------------------------------------------------------------------------------
-- Gold
-------------------------------------------------------------------------------

function ns.ScanMoney()
    local money = GetMoney and GetMoney()
    if type(money) == "number" and not ns.IsSecret(money) then
        SetMine("money", money)
    end
end

-------------------------------------------------------------------------------
-- Shopping list (each person keeps their own list of what they need)
-------------------------------------------------------------------------------

function ns.SetNeed(itemID, count)
    local shop = {}
    for id, c in pairs(ns.Me().shop) do
        shop[id] = c
    end
    if count and count > 0 then
        shop[itemID] = count
    else
        shop[itemID] = nil
    end
    SetMine("shop", shop)
end

-------------------------------------------------------------------------------
-- Item names (the game loads them on demand)
-------------------------------------------------------------------------------

function ns.ItemName(id)
    if not id or id <= 0 then
        return nil
    end
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if not name and GetItemInfo then
        name = GetItemInfo(id)
    end
    if not name and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(id)
    end
    return name
end

-- Finds an item ID from a link or a (part of a) name the crew knows about.
function ns.FindItem(text)
    if not text or text == "" then
        return nil
    end
    local id = tonumber(text:match("item:(%d+)"))
    if id then
        return id
    end
    text = text:lower()
    local best
    for _, candidate in ipairs(ns.KnownItemIDs()) do
        local name = ns.ItemName(candidate)
        if name then
            local lower = name:lower()
            if lower == text then
                return candidate
            elseif not best and lower:find(text, 1, true) then
                best = candidate
            end
        end
    end
    if not best and GetItemInfo then
        local _, link = GetItemInfo(text)
        best = link and tonumber(link:match("item:(%d+)"))
    end
    return best
end

-------------------------------------------------------------------------------
-- Recipes: names and materials
-------------------------------------------------------------------------------

-- Returns the recipe name, or the made item's name.
local recipeNames = {}
function ns.RecipeName(rid, out)
    if recipeNames[rid] then
        return recipeNames[rid]
    end
    if rid and rid > 0 and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, schem = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
        if ok and schem and type(schem.name) == "string" and schem.name ~= "" then
            recipeNames[rid] = schem.name
            return schem.name
        end
    end
    return ns.ItemName(out) or ("Recipe " .. tostring(rid))
end

-- Returns { { id = itemID, count = n }, ... } or an empty table.
function ns.Reagents(rid)
    local list = {}
    if not rid or rid <= 0 or not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then
        return list
    end
    local ok, schem = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
    if not ok or not schem or not schem.reagentSlotSchematics then
        return list
    end
    for _, slot in ipairs(schem.reagentSlotSchematics) do
        local r = slot.reagents and slot.reagents[1]
        if r and r.itemID and (slot.required == nil or slot.required) then
            list[#list + 1] = { id = r.itemID, count = slot.quantityRequired or 1 }
        end
    end
    return list
end

-------------------------------------------------------------------------------
-- Searching
-------------------------------------------------------------------------------

-- Every item ID the crew data mentions (for name search).
function ns.KnownItemIDs()
    local seen, list = {}, {}
    local function Add(id)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    for _, key in ipairs(ns.VisiblePeople()) do
        local p = ns.db.people[key]
        if p then
            for id in pairs(p.items or {}) do Add(id) end
            for id in pairs(p.shop or {}) do Add(id) end
            for _, recipes in pairs(p.recipes or {}) do
                for _, out in pairs(recipes) do Add(out) end
            end
        end
    end
    return list
end

-- Who holds an item: { { key, bags, bank }, ... } most first.
function ns.Holders(itemID)
    local list = {}
    for _, key in ipairs(ns.VisiblePeople()) do
        local p = ns.db.people[key]
        local c = p and p.items and p.items[itemID]
        if c and ((c[1] or 0) + (c[2] or 0)) > 0 then
            list[#list + 1] = { key = key, bags = c[1] or 0, bank = c[2] or 0 }
        end
    end
    table.sort(list, function(a, b) return a.bags + a.bank > b.bags + b.bank end)
    return list
end

-- Who needs an item: { { key, count, have }, ... }
function ns.Needs(itemID)
    local list = {}
    for _, key in ipairs(ns.VisiblePeople()) do
        local p = ns.db.people[key]
        local want = p and p.shop and p.shop[itemID]
        if want then
            local c = p.items and p.items[itemID]
            local have = c and ((c[1] or 0) + (c[2] or 0)) or 0
            list[#list + 1] = { key = key, count = want, have = have }
        end
    end
    return list
end

-- Who can make an item: { { key, prof, rid }, ... } (do not change it)
local NONE = {}
function ns.Crafters(itemID)
    if not cache.crafters then
        local index = {}
        for _, key in ipairs(ns.VisiblePeople()) do
            local p = ns.db.people[key]
            for prof, recipes in pairs(p and p.recipes or {}) do
                for rid, out in pairs(recipes) do
                    if out and out > 0 then
                        index[out] = index[out] or {}
                        table.insert(index[out], { key = key, prof = prof, rid = rid })
                    end
                end
            end
        end
        cache.crafters = index
    end
    return cache.crafters[itemID] or NONE
end

-- All recipes known in the crew, grouped by recipe:
-- { { rid, out, name, crafters = { { key, prof }, ... } }, ... }
function ns.AllRecipes()
    local byKey, list = {}, {}
    for _, key in ipairs(ns.VisiblePeople()) do
        local p = ns.db.people[key]
        for prof, recipes in pairs(p and p.recipes or {}) do
            for rid, out in pairs(recipes) do
                local k = rid > 0 and ("r" .. rid) or ("i" .. out)
                local e = byKey[k]
                if not e then
                    e = { rid = rid, out = out, crafters = {} }
                    byKey[k] = e
                    list[#list + 1] = e
                end
                e.crafters[#e.crafters + 1] = { key = key, prof = prof }
            end
        end
    end
    for _, e in ipairs(list) do
        e.name = ns.RecipeName(e.rid, e.out)
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-------------------------------------------------------------------------------
-- Profession hints for beginners (classic skill caps: 75/150/225/300)
-------------------------------------------------------------------------------

local NEXT_RANK = {
    [75] = { at = 50, name = "Journeyman", level = 10 },
    [150] = { at = 125, name = "Expert", level = 20 },
    [225] = { at = 200, name = "Artisan", level = 35 },
}
-- Cooking, First Aid and Fishing: no level rule shown for these.
local SECONDARY = { [185] = true, [129] = true, [356] = true }

-- e = profession entry, level = that character's level (may be nil).
function ns.ProfessionHint(e, level)
    local nextRank = NEXT_RANK[e.max]
    if not nextRank or e.rank < nextRank.at then
        return nil
    end
    local needLevel = not SECONDARY[e.line] and level and level > 0 and level < nextRank.level
    if needLevel then
        return "Next rank (" .. nextRank.name .. ") needs level " .. nextRank.level
    elseif e.rank >= e.max then
        return "Skill is capped: learn " .. nextRank.name .. " at a trainer to keep going"
    end
    return "Can learn " .. nextRank.name .. " at a trainer now"
end

-- True when the hint means "go to a trainer now" (the "!" mark).
function ns.TrainerNow(e, level)
    local hint = ns.ProfessionHint(e, level)
    return hint ~= nil and not hint:find("needs level", 1, true)
end

-- Icon for a profession entry: the one shared with it, else the game's own
-- icon for that skill line, else a question mark.
function ns.ProfIcon(e)
    if e.icon then
        return e.icon
    end
    local T = C_TradeSkillUI
    if e.line and e.line > 0 and T and T.GetTradeSkillTexture then
        local ok, icon = pcall(T.GetTradeSkillTexture, e.line)
        if ok and icon and not ns.IsSecret(icon) then
            return icon
        end
    end
    return 134400 -- question mark icon (Interface\\Icons\\INV_Misc_QuestionMark)
end

-------------------------------------------------------------------------------
-- Collecting my own data automatically
-------------------------------------------------------------------------------

local pendingItems = false
local function ScanItemsSoon()
    if pendingItems then
        return
    end
    pendingItems = true
    C_Timer.After(2, ns.Safe(function()
        pendingItems = false
        ns.ScanItems()
    end, "bags"))
end

-- Gold changes a lot while looting: send it at most every 10 seconds.
local pendingMoney = false
local function ScanMoneySoon()
    if pendingMoney then
        return
    end
    pendingMoney = true
    C_Timer.After(10, ns.Safe(function()
        pendingMoney = false
        ns.ScanMoney()
    end, "gold"))
end

ns.On("FC_READY", function()
    ns.UpdateBasics()
    ns.ScanProfessions()
    ns.ScanItems()
    ns.ScanMoney()
end)
ns.On("PLAYER_LEVEL_UP", function(level)
    ns.UpdateBasics()
    if type(level) == "number" then
        ns.Me().level = level -- UnitLevel can lag behind right after a level up
    end
    if ns.HelloOnline then
        ns.HelloOnline()
    end
end)
ns.On("PLAYER_MONEY", ScanMoneySoon)
ns.On("SKILL_LINES_CHANGED", function() ns.ScanProfessions() end)
-- The profession window fires many updates in a row: read it once a second.
local pendingRecipes = false
local function ScanRecipesSoon()
    if pendingRecipes then
        return
    end
    pendingRecipes = true
    C_Timer.After(1, ns.Safe(function()
        pendingRecipes = false
        ns.ScanRecipes()
        ns.ScanProfessions()
    end, "recipes"))
end
ns.On("TRADE_SKILL_SHOW", ScanRecipesSoon)
ns.On("TRADE_SKILL_LIST_UPDATE", ScanRecipesSoon)
ns.On("NEW_RECIPE_LEARNED", ScanRecipesSoon)
ns.On("BAG_UPDATE_DELAYED", ScanItemsSoon)
ns.On("PLAYERBANKSLOTS_CHANGED", ScanItemsSoon)
ns.On("BANKFRAME_OPENED", function()
    ns.bankOpen = true
    C_Timer.After(0.5, ns.Safe(ns.ScanItems, "bank")) -- read it before the bank closes again
end)
-- Read the bank one last time as it closes, so late changes are not lost.
local function BankClosed()
    if ns.bankOpen then
        pcall(ns.ScanItems)
        ns.bankOpen = false
    end
end
ns.On("BANKFRAME_CLOSED", BankClosed)
-- Newer clients open the bank through the interaction manager.
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
    if Enum and Enum.PlayerInteractionType and kind == Enum.PlayerInteractionType.Banker then
        ns.bankOpen = true
        C_Timer.After(0.5, ns.Safe(ns.ScanItems, "bank"))
    end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
    if Enum and Enum.PlayerInteractionType and kind == Enum.PlayerInteractionType.Banker then
        BankClosed()
    end
end)
ns.On("PLAYER_LOGOUT", function()
    if ns.me then
        ns.Me().seen = time()
    end
end)
