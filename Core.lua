-- FriendsCraft: core
-- Shared basics: saved settings, names, events, slash command.
--
-- Files:
--   Core.lua  this file
--   Data.lua  what we know about each character (professions, recipes,
--             items, shopping list), collecting it and searching it
--   Comm.lua  talking to friends' FriendsCraft (hidden whispers)
--   UI.lua    the window, settings, minimap button, item tooltips

local ADDON_NAME, ns = ...

ns.PROTOCOL = 2 -- 2: friends find each other by themselves (no invites)

local DEFAULTS = {
    crew = {},     -- [name] = true for friends found with FriendsCraft (see FullName)
    people = {},   -- [name] = record, see Data.lua
    hidden = {},   -- [name] = true for people you chose to hide
    minimap = { angle = 215, hide = false },
    tooltips = true, -- crew lines on item tooltips
    tag = false,     -- random tag shared by all your characters (see below)
    window = {},     -- size and place of the window
    view = {},       -- sort order and filters on the Crew page
    shopDone = {},   -- [your character] = { [itemID] = count } ticked off the shopping list (not shared)
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

function ns.Print(msg)
    print("|cff7fd4ffFriendsCraft:|r " .. msg)
end

-- Midnight-era clients can hand addons "secret" values; treat as unknown.
function ns.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

function ns.MyRealm()
    if GetNormalizedRealmName then
        local r = GetNormalizedRealmName()
        if r and r ~= "" then
            return r
        end
    end
    local r = ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "")
    return r
end

-- WoW Forever has no realms: every character has a first name and a
-- surname ("Tom Stonebrook"), and that pair is unique. The game shows this
-- by giving the surname as UnitName's second value. Set at login.
ns.forever = false

local function DetectForever()
    local _, surname = UnitName("player")
    ns.forever = type(surname) == "string" and not ns.IsSecret(surname) and surname ~= ""
end

-- Capitalize like the game does (only safe for a plain first letter).
local function Capitalize(n)
    if n:byte(1) and n:byte(1) < 128 then
        n = n:sub(1, 1):upper() .. n:sub(2):lower()
    end
    return n
end

-- Forever: "tom stonebrook" or "Tom-Stonebrook" -> "Tom Stonebrook".
--   A first name alone gives nil (we cannot guess the surname).
-- Other clients: "tom" -> "Tom-MyRealm". Keeps a realm the player typed.
function ns.FullName(name)
    if type(name) ~= "string" or ns.IsSecret(name) then
        return nil
    end
    -- Character names never hold digits or these marks; "|" would also
    -- let a name pose as colored text or a link.
    if name:find("[|%^,;:#=/~%d%c]") or #name > 60 then
        return nil
    end
    if ns.forever then
        local first, surname = strtrim(name):match("^([^%s%-]+)[%s%-]+([^%s%-]+)$")
        if not first then
            return nil
        end
        return Capitalize(first) .. " " .. Capitalize(surname)
    end
    name = name:gsub("%s+", "")
    if name == "" then
        return nil
    end
    local n, r = name:match("^([^%-]+)%-(.+)$")
    if not n then
        n, r = name, ns.MyRealm()
    end
    return Capitalize(n) .. "-" .. r
end

-- Like FullName, but a first name alone also works when exactly one
-- person we know (crew, own alts, or `extra` keys) has that first name.
function ns.ResolveName(name, extra)
    local key = ns.FullName(name)
    if key or not ns.forever or type(name) ~= "string" or ns.IsSecret(name) then
        return key
    end
    local first = strtrim(name):lower()
    local matches, count, found = {}, 0, nil
    local function Try(k)
        if not matches[k] and k:match("^(%S+)"):lower() == first then
            matches[k] = true
            count = count + 1
            found = k
        end
    end
    for k in pairs(ns.db.crew) do Try(k) end
    for k, p in pairs(ns.db.people) do
        if p.mine then Try(k) end
    end
    for k in pairs(extra or {}) do Try(k) end
    return count == 1 and found or nil
end

-- Name for lists and tooltips. Forever: the first name, or the full name
-- when someone else we know has the same first name.
-- Other clients: "Tom-MyRealm" -> "Tom"; other realms keep their realm.
function ns.ShortName(full)
    if ns.forever then
        local first = (full or ""):match("^(%S+) ")
        if not first then
            return full or "?"
        end
        for k in pairs(ns.db and ns.db.people or {}) do
            if k ~= full and k:match("^(%S+)") == first then
                return full
            end
        end
        for k in pairs(ns.db and ns.db.crew or {}) do
            if k ~= full and k:match("^(%S+)") == first then
                return full
            end
        end
        return first
    end
    local n, r = (full or ""):match("^([^%-]+)%-(.+)$")
    if n and r == ns.MyRealm() then
        return n
    end
    return full or "?"
end

-- Name to show where people need the exact name (crew list, invites).
function ns.LongName(full)
    if ns.forever then
        return full or "?"
    end
    return ns.ShortName(full)
end

-- "3 h ago" style text for a past time() value.
function ns.Ago(t)
    if not t then
        return "never"
    end
    local s = time() - t
    if s < 120 then
        return "just now"
    elseif s < 3600 then
        return math.floor(s / 60) .. " min ago"
    elseif s < 86400 then
        return math.floor(s / 3600) .. " h ago"
    end
    return math.floor(s / 86400) .. " days ago"
end

-- Fills in missing settings without touching existing ones.
local function MergeDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            MergeDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-------------------------------------------------------------------------------
-- Events: other files register with ns.On("EVENT", function(...) end)
-------------------------------------------------------------------------------

local handlers = {}
local eventFrame = CreateFrame("Frame")

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if event ~= "FC_READY" then
            pcall(eventFrame.RegisterEvent, eventFrame, event)
        end
    end
    table.insert(handlers[event], fn)
end

-- Wraps a function so an error prints one line instead of a game error
-- popup (used for timers, which run outside our event handler).
function ns.Safe(fn, what)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            ns.Print("error in " .. (what or "timer") .. ": " .. tostring(err))
        end
    end
end

function ns.Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then
            ns.Print("error in " .. event .. ": " .. tostring(err))
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    -- Nothing works without our own name; wait for login.
    if not ns.me and event ~= "ADDON_LOADED" and event ~= "PLAYER_LOGIN" then
        return
    end
    ns.Fire(event, ...)
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
handlers.ADDON_LOADED = { function(name)
    if name ~= ADDON_NAME then
        return
    end
    FriendsCraftDB = MergeDefaults(DEFAULTS, FriendsCraftDB or {})
    ns.db = FriendsCraftDB
    -- A random tag, made once and the same for all your characters. Friends
    -- use it to put your characters together under one name. It says
    -- nothing about your account.
    if type(ns.db.tag) ~= "string" or not ns.db.tag:match("^%x+$") then
        local hex, seed = {}, math.floor((time and time() or 0) + (GetTime and GetTime() or 0) * 1000)
        for i = 1, 12 do
            hex[i] = string.format("%x", (math.random(0, 15) + seed + i * 7) % 16)
            seed = math.floor(seed / 3)
        end
        ns.db.tag = table.concat(hex)
    end
end }
handlers.PLAYER_LOGIN = { function()
    DetectForever()
    local first, second = UnitName("player")
    ns.me = ns.FullName(ns.forever and (tostring(first) .. " " .. tostring(second)) or first)
    if not ns.me then
        ns.Print("could not read your character name, so FriendsCraft is off for now. Try /reload.")
        return
    end
    if ns.forever then
        -- Version 0.1 saved names as "Name-Realm"; those keys are wrong here.
        for _, list in ipairs({ ns.db.people, ns.db.crew }) do
            for key in pairs(list) do
                if type(key) ~= "string" or key:find("-", 1, true) then
                    list[key] = nil
                end
            end
        end
    end
    ns.Fire("FC_READY")
end }

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------

SLASH_FRIENDSCRAFT1 = "/fc"
SLASH_FRIENDSCRAFT2 = "/friendscraft"
SlashCmdList.FRIENDSCRAFT = function(input)
    local cmd = strtrim(input or ""):lower()
    if cmd == "help" then
        ns.Print("/fc opens the window, /fc settings opens its settings. Friends with FriendsCraft show up by themselves when you are on each other's friends list.")
    elseif cmd == "settings" or cmd == "options" or cmd == "config" then
        ns.OpenSettings()
    else
        ns.ToggleWindow()
    end
end
