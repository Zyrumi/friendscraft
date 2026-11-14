-- FriendsCraft: talking to friends
-- Friends find each other by themselves. On login, and whenever a friend
-- comes online, we send a hidden hello to every online friend. Anyone who
-- answers has FriendsCraft and shows up in your crew.
--
-- Only friends: a hello is only accepted from someone on your friends list
-- (character friends or Battle.net friends). Both of you must have each
-- other as friends before any data is shared.
--
-- Two ways to reach a friend:
--   character friends   hidden addon whispers to "First Surname"
--   Battle.net friends  hidden Battle.net game data (works across rule sets)
--
-- People you hide in the book get nothing from you: no hello answer, no
-- updates. Showing them again says hello so they catch up.
--
-- Battle.net only tells us which character a friend is playing once they
-- answer, so the first hello to a Battle.net friend says nothing but your
-- name. The rest (level, class, faction, alts) follows once we know who
-- they are and that you have not hidden them.
--
-- Your list follows your friends lists: someone you are no longer friends
-- with (you removed them, or they ended a Battle.net friendship) leaves your
-- list together with what they shared.
--
-- Sharing with a friend is opt-in: a friend with FriendsCraft shows up as
-- "has FriendsCraft" with Share and Not now. Until you click Share they get
-- nothing but your name, and data flows only when both of you said yes.
--
-- Guild: only professions, skills and recipes, over the hidden guild
-- channel (never bags, gold or the shopping list):
--   GH  guild hello: ver^reply^full name^level^class^faction^rev prof^rev recipes
--   GQ  please send: name^"prof,recipes"
--   GS  section: name^section^rev^data
--
-- Messages (kind^payload):
--   HI  hello: ver^reply^level^class^full name^rev of each section^faction^tag
--   RQ  please send these sections: "prof,items"
--   SE  section: name^rev^data
--   AL  my other characters: name;level;class;faction;rev of each section~...
--   AR  please send these of your other characters: "name:prof,items~name:shop"
--   AS  one of my other characters: name^section^rev^data
-- Your other characters are passed on by whichever character you play, so
-- friends see all of them without adding each one as a friend.
--
-- Long messages are split in parts; sending is paced so the game's
-- addon-message limit is never hit, and pauses during combat.

local ADDON_NAME, ns = ...

local PREFIX = "FriendsCraft"
local MAX_LEN = 240       -- per addon whisper (the game allows 255)
local MAX_LEN_BNET = 3900 -- per Battle.net message (the game allows about 4000)
local HELLO_GAP = 60      -- seconds before the same friend gets another hello

ns.online = {}            -- [name] = true while we know they are on
local routes = {}         -- [name] = Battle.net game account ID to reach them
local bnetNames = {}      -- [game account ID] = name
local friendNames = {}    -- [name] = true for the character friends list
local friendFirst = {}    -- [first name] = true when the list only gives a first name
local friendsLoaded = false
local recentWhisper = {}  -- [target] = GetTime() of last whisper
local lastHello = {}      -- [target] = GetTime() of our last hello
local lastHeard = {}      -- [name] = GetTime() of their last hello
local lastPayload = {}    -- [name] = their last hello, to spot the same one by the other route
local bnetTags = {}       -- [battle tag, lower case] = true for every Battle.net friend
local bnetTagOf = {}      -- [game account ID] = battle tag of its owner
local bnetLoaded = false  -- the Battle.net friends list has been read
local slimTo = {}         -- [game account ID] = true after a name-only hello
ns.pending = {}           -- [name] = { tag, at } friends with FriendsCraft not yet answered
local announced = {}      -- [name] = true once we said so in chat this session
local GUILD = "@guild"    -- queue target for the guild channel
local GUILD_SECTIONS = { prof = true, recipes = true }
local FULL_HELLO_DELAY = 6 -- after their answer (the other side skips a second hello within 5 s)

local function Wipe(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local function Hidden(name)
    return name ~= nil and ns.IsHidden(name)
end

local function FirstName(name)
    return type(name) == "string" and (name:match("^[^%s%-]+") or ""):lower() or ""
end

-------------------------------------------------------------------------------
-- Sending (paced queue)
-------------------------------------------------------------------------------

local queue = {}
local tokens, MAX_TOKENS, REFILL = 6, 6, 1.0 -- messages; per second
local chunkId = 0

local function RawSend(item)
    local ok, res
    if item.bnet then
        if not BNSendGameData then
            return "drop"
        end
        ok, res = pcall(BNSendGameData, item.bnet, PREFIX, item.text)
    else
        if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
            return "drop"
        end
        if item.target == GUILD then
            ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, "GUILD")
        else
            ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, "WHISPER", item.target)
        end
    end
    if not ok then
        return "drop"
    end
    -- Newer clients return a result code; 3 and 8 mean "slow down".
    if res == 3 or res == 8 then
        return "retry"
    end
    return "sent"
end

local pump = CreateFrame("Frame")
pump:SetScript("OnUpdate", function(_, elapsed)
    tokens = math.min(MAX_TOKENS, tokens + elapsed * REFILL)
    if #queue == 0 or tokens < 1 or InCombatLockdown() then
        return
    end
    -- Some places (e.g. boss fights in Midnight-era clients) block addon messages.
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    local item = table.remove(queue, 1)
    local result = RawSend(item)
    if result == "retry" then
        table.insert(queue, 1, item)
        tokens = 0
    else
        tokens = tokens - 1
        if not item.bnet and item.target ~= GUILD then
            recentWhisper[item.target] = GetTime()
        end
    end
end)

-- Queues a message, split in parts if needed. bnet = game account ID.
-- tag: a newer message with the same tag replaces an older one that has
-- not been sent yet (so fast bag changes do not pile up).
local function Queue(target, bnet, kind, payload, tag)
    if tag then
        for i = #queue, 1, -1 do
            if queue[i].tag == tag and queue[i].target == target then
                table.remove(queue, i)
            end
        end
    end
    local msg = kind .. "^" .. (payload or "")
    local max = bnet and MAX_LEN_BNET or MAX_LEN
    if #msg <= max then
        queue[#queue + 1] = { target = target, bnet = bnet, text = "S" .. msg, tag = tag }
        return
    end
    chunkId = (chunkId % 999) + 1
    local n = math.ceil(#msg / max)
    for i = 1, n do
        local part = msg:sub((i - 1) * max + 1, i * max)
        queue[#queue + 1] = { target = target, bnet = bnet, text = "C" .. chunkId .. ":" .. i .. ":" .. n .. ":" .. part, tag = tag }
    end
end

-- Sends to a crew member by name, over Battle.net when we can.
function ns.Send(name, kind, payload, tag)
    Queue(name, routes[name], kind, payload, tag)
end

-- Drops anything still waiting for someone (e.g. they went offline).
local function ForgetQueued(target)
    for i = #queue, 1, -1 do
        if queue[i].target == target then
            table.remove(queue, i)
        end
    end
end

-------------------------------------------------------------------------------
-- What we tell friends
-------------------------------------------------------------------------------

local function HelloPayload(reply)
    local me = ns.Me()
    local parts = { ns.PROTOCOL, reply and 1 or 0, me.level or 0, me.class or "", ns.me }
    for _, section in ipairs(ns.SECTIONS) do
        parts[#parts + 1] = me.rev[section] or 0
    end
    parts[#parts + 1] = me.faction or ""
    parts[#parts + 1] = ns.db.tag or ""
    return table.concat(parts, "^")
end

-- Tells a friend about your other characters and what they have.
local function SendAlts(name)
    local entries = {}
    for key, p in pairs(ns.db.people) do
        if p.mine and key ~= ns.me then
            local parts = { key, p.level or 0, p.class or "", p.faction or "" }
            for _, section in ipairs(ns.SECTIONS) do
                parts[#parts + 1] = p.rev and p.rev[section] or 0
            end
            entries[#entries + 1] = table.concat(parts, ";")
        end
    end
    if #entries > 0 then
        ns.Send(name, "AL", table.concat(entries, "~"), "AL")
    end
end

local function SendSection(name, section)
    local me = ns.Me()
    ns.Send(name, "SE", section .. "^" .. (me.rev[section] or 0) .. "^" .. ns.Encode[section](me[section]), "SE" .. section)
end

-- Sends a changed section to every online crew member.
function ns.Broadcast(section)
    if ns.GuildChanged then
        ns.GuildChanged(section)
    end
    for name in pairs(ns.db.crew) do
        if ns.online[name] and not Hidden(name) then
            SendSection(name, section)
        end
    end
end

-- Tells online crew members our new level (no answer needed).
function ns.HelloOnline()
    for name in pairs(ns.db.crew) do
        if ns.online[name] and not Hidden(name) then
            ns.Send(name, "HI", HelloPayload(true))
        end
    end
end

-- A hello with nothing but our name, for a Battle.net friend we can't tell
-- yet (could be someone you hid). Empty fields leave what they know as is.
local function SlimHello()
    local parts = { ns.PROTOCOL, 0, "", "", ns.me }
    for _ in ipairs(ns.SECTIONS) do
        parts[#parts + 1] = ""
    end
    parts[#parts + 1] = "" -- faction
    parts[#parts + 1] = "" -- tag
    return table.concat(parts, "^")
end

local function HelloTo(target, bnet, slim)
    local id = bnet and ("#" .. bnet) or target
    if lastHello[id] and GetTime() - lastHello[id] < HELLO_GAP then
        return
    end
    lastHello[id] = GetTime()
    if slim then
        if bnet then
            slimTo[bnet] = true
        end
        Queue(target, bnet, "HI", SlimHello())
    else
        Queue(target, bnet, "HI", HelloPayload(false))
    end
end

-------------------------------------------------------------------------------
-- Friends lists
-------------------------------------------------------------------------------

-- Character friends: fills friendNames, returns the targets that are online.
local function ReadFriends()
    local online = {}
    local F = C_FriendList
    if not F or not F.GetNumFriends or not F.GetFriendInfoByIndex then
        return online
    end
    Wipe(friendNames)
    Wipe(friendFirst)
    local n = F.GetNumFriends() or 0
    if n > 0 then
        friendsLoaded = true
    end
    for i = 1, n do
        local info = F.GetFriendInfoByIndex(i)
        local raw = info and info.name
        if type(raw) == "string" and not ns.IsSecret(raw) then
            local name = ns.FullName(raw)
            if name then
                friendNames[name] = true
            else
                friendFirst[FirstName(raw)] = true
            end
            if info.connected then
                online[#online + 1] = name or raw
            end
        end
    end
    return online
end

-- Battle.net friends: returns { [game account ID] = true } for those in WoW.
local function ReadBNet()
    local list = {}
    local B = C_BattleNet
    if not BNGetNumFriends or not B or not B.GetFriendNumGameAccounts or not B.GetFriendGameAccountInfo then
        return list
    end
    local wow = BNET_CLIENT_WOW or "WoW"
    local n = (BNGetNumFriends()) or 0
    Wipe(bnetTags)
    Wipe(bnetTagOf)
    for i = 1, n do
        local okA, acc = pcall(B.GetFriendAccountInfo or function() end, i)
        local tag = okA and type(acc) == "table" and acc.battleTag
        if type(tag) == "string" and not ns.IsSecret(tag) then
            tag = tag:lower()
            bnetTags[tag] = true
        else
            tag = nil
        end
        for j = 1, B.GetFriendNumGameAccounts(i) or 0 do
            local g = B.GetFriendGameAccountInfo(i, j)
            local id = g and g.gameAccountID
            if id and not ns.IsSecret(id) then
                bnetTagOf[id] = tag
                if g.isOnline and g.clientProgram == wow then
                    list[id] = true
                end
            end
        end
    end
    -- Only trust the list once it has someone on it, and never while
    -- Battle.net is down (the list then reads as empty).
    local connected = not BNConnected or BNConnected()
    if not connected then
        bnetLoaded = false
    elseif n > 0 then
        bnetLoaded = true
    end
    return list
end

local function IsFriend(name)
    if friendNames[name] or friendFirst[FirstName(name)] then
        return true
    end
    -- Friends list not loaded yet: trust people already in the crew.
    return not friendsLoaded and ns.db.crew[name] == true
end

local ready = false
local wasOnline = {} -- [target] = true for friends online at the last check

-- Still on one of our friends lists? Only answers no when every way we
-- know them by has been checked. People from before this check (not
-- marked yet) stay until we hear from them again.
local function StillFriend(name, p)
    local decided, keep = false, false
    if p.charFriend then
        if not friendsLoaded then
            return true
        end
        decided = true
        keep = keep or friendNames[name] or friendFirst[FirstName(name)] or false
    end
    if p.bnetTag then
        if not bnetLoaded then
            return true
        end
        decided = true
        keep = keep or bnetTags[p.bnetTag] or false
    end
    return keep or not decided
end

-- Takes someone (and the alts they passed on) off our list.
local function Forget(name)
    ns.db.crew[name] = nil
    ns.db.people[name] = nil
    ns.online[name] = nil
    routes[name] = nil
    lastHeard[name] = nil
    lastPayload[name] = nil
    ns.pending[name] = nil
    ForgetQueued(name)
    for id, n in pairs(bnetNames) do
        if n == name then
            bnetNames[id] = nil
        end
    end
    for key, q in pairs(ns.db.people) do
        if q.via == name then
            ns.db.people[key] = nil
        end
    end
end

local function PruneCrew()
    local gone = false
    for name in pairs(ns.db.crew) do
        local p = ns.db.people[name]
        if p and not p.mine and not StillFriend(name, p) then
            Forget(name)
            gone = true
        end
    end
    if gone then
        ns.Changed()
    end
end

local function UpdateFriends()
    if not ready then
        return
    end
    local chars = ReadFriends()
    local bnet = ReadBNet()
    local charOnline, charOnlineFirst = {}, {}
    for _, target in ipairs(chars) do
        charOnline[target] = true
        charOnlineFirst[FirstName(target)] = true
    end
    local function OnAsCharFriend(name)
        return charOnline[name] or charOnlineFirst[FirstName(name)]
    end
    -- Battle.net friends who logged off.
    for id, name in pairs(bnetNames) do
        if not bnet[id] then
            bnetNames[id] = nil
            if routes[name] == id then
                routes[name] = nil
                ForgetQueued(name)
                if not OnAsCharFriend(name) then
                    ns.online[name] = nil
                end
            end
        end
    end
    -- Character friends who logged off.
    for name in pairs(ns.online) do
        if not routes[name] and friendsLoaded and not OnAsCharFriend(name) then
            ns.online[name] = nil
            ForgetQueued(name)
        end
    end
    -- Say hello to friends who just came online (and to everyone at login).
    -- Friends without FriendsCraft never answer, so they are not asked again
    -- until they log in again.
    local nowOnline = {}
    for _, target in ipairs(chars) do
        nowOnline[target] = true
        if not wasOnline[target] and not routes[target] and not Hidden(target) and ns.Consent(target) ~= "no" then
            HelloTo(target, nil, ns.Consent(target) ~= "yes")
        end
    end
    for id in pairs(bnet) do
        local label = "#" .. id
        nowOnline[label] = true
        local known = bnetNames[id]
        if not wasOnline[label] and not Hidden(known) and not (known and ns.Consent(known) == "no") then
            HelloTo(known or label, id, known == nil or ns.Consent(known) ~= "yes")
        end
    end
    wasOnline = nowOnline
    PruneCrew()
    if ns.RefreshUI then ns.RefreshUI() end
end

local updateQueued = false
local function UpdateFriendsSoon()
    if updateQueued then
        return
    end
    updateQueued = true
    C_Timer.After(1, ns.Safe(function()
        updateQueued = false
        UpdateFriends()
    end, "friends"))
end

-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------

local function Split(s, sep)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
        out[#out + 1] = piece
    end
    return out
end

local Handlers = {}
local GuildHandlers = {}

-- from = { raw = whisper sender } or { bnet = game account ID }
function Handlers.HI(name, payload, from)
    local f = Split(payload, "^")
    if (tonumber(f[1]) or 0) < ns.PROTOCOL then
        return -- an older FriendsCraft that still uses invites
    end
    local claimed = ns.FullName(f[5])
    if from.bnet then
        -- Battle.net only delivers from Battle.net friends; check anyway.
        name = claimed
        if not name or not ReadBNet()[from.bnet] then
            return
        end
        bnetNames[from.bnet] = name
        routes[name] = from.bnet
    else
        if not name and claimed and FirstName(claimed) == FirstName(from.raw) then
            name = claimed -- the game gave only a first name
        end
        if not name or not IsFriend(name) then
            return -- not on our friends list: share nothing
        end
    end
    if name == ns.me then
        return
    end
    local theirTag = (f[12] or ""):match("^%x+$")
    if theirTag and #theirTag > 16 then
        theirTag = nil
    end
    local consent = ns.Consent(name) or (theirTag and ns.db.consent["#" .. theirTag])
    if consent ~= "yes" then
        -- Not shared with yet: remember them (once asked, "no" stays quiet).
        if consent == nil and not ns.db.crew[name] then
            local first = not ns.pending[name]
            ns.pending[name] = { tag = theirTag or (ns.pending[name] and ns.pending[name].tag), at = time(),
                class = (f[4] or ""):match("^%u+$") }
            if first then
                if not announced[name] then
                    announced[name] = true
                    ns.Print(ns.ShortName(name) .. " has FriendsCraft too. Open it (/fc) to choose whether to share with them.")
                end
                if ns.RefreshMinimapMark then ns.RefreshMinimapMark() end
                if ns.RefreshUI then ns.RefreshUI() end
            end
        end
        return
    end
    local now = GetTime()
    -- The same hello by the other route (whisper and Battle.net) within a
    -- few seconds. A different one (say, the full hello after a name-only
    -- one) is new.
    local again = lastHeard[name] and now - lastHeard[name] < 5 and lastPayload[name] == payload
    lastHeard[name] = now
    lastPayload[name] = payload
    if not ns.db.crew[name] then
        ns.db.crew[name] = true
        ns.Changed()
    end
    ns.online[name] = true
    local p = ns.Person(name, true)
    p.name = name
    p.via = nil -- heard from directly now
    p.level = tonumber(f[3]) or p.level
    p.class = (f[4] or ""):match("^%u+$") or p.class
    p.faction = (f[11] or ""):match("^%a+$") or p.faction
    local tag = (f[12] or ""):match("^%x+$")
    if tag and #tag <= 16 and tag ~= ns.db.tag and tag ~= p.tag then
        p.tag = tag
        ns.Changed()
    end
    p.seen = time()
    -- How we know them, so they leave the list when the friendship ends.
    if from.bnet then
        p.bnetTag = bnetTagOf[from.bnet] or p.bnetTag
    else
        p.charFriend = true
    end
    if ns.RefreshUI then ns.RefreshUI() end
    if again or Hidden(name) then
        return -- the same hello by the other route
    end
    if f[2] ~= "1" then
        ns.Send(name, "HI", HelloPayload(true)) -- answer first, then ask
        if from.bnet then
            slimTo[from.bnet] = nil
        end
    elseif from.bnet and slimTo[from.bnet] then
        -- They answered our name-only hello: now that we know who it is,
        -- tell them the rest.
        slimTo[from.bnet] = nil
        C_Timer.After(FULL_HELLO_DELAY, ns.Safe(function()
            if ns.online[name] and not Hidden(name) then
                ns.Send(name, "HI", HelloPayload(true))
            end
        end, "hello"))
    end
    local want = {}
    for i, section in ipairs(ns.SECTIONS) do
        local theirs = tonumber(f[5 + i]) or 0
        if theirs > (p.rev[section] or 0) then
            want[#want + 1] = section
        end
    end
    if #want > 0 then
        ns.Send(name, "RQ", table.concat(want, ","))
    end
    SendAlts(name)
end

-- A friend's other characters. Only taken for names that are not yours and
-- not friends you hear from directly, and only from the same friend.
function Handlers.AL(name, payload)
    local tag = ns.db.people[name] and ns.db.people[name].tag
    local want = {}
    for entry in payload:gmatch("[^~]+") do
        local f = Split(entry, ";")
        local alt = ns.FullName(f[1])
        local q = alt and ns.db.people[alt]
        local mineOrMe = alt == ns.me or (q and q.mine)
        local direct = q and not q.via and ns.db.crew[alt]
        local otherFriend = q and q.via and q.via ~= name and not (tag and q.tag == tag)
        if alt and alt ~= name and not mineOrMe and not direct and not otherFriend then
            q = ns.Person(alt, true)
            if q.via ~= name or q.tag ~= tag then
                q.via, q.tag = name, tag
                ns.Changed()
            end
            q.name = alt
            q.level = tonumber(f[2]) or q.level
            q.class = (f[3] or ""):match("^%u+$") or q.class
            q.faction = (f[4] or ""):match("^%a+$") or q.faction
            local need = {}
            for i, section in ipairs(ns.SECTIONS) do
                if (tonumber(f[4 + i]) or 0) > (q.rev[section] or 0) then
                    need[#need + 1] = section
                end
            end
            if #need > 0 then
                want[#want + 1] = alt .. ":" .. table.concat(need, ",")
            end
        end
    end
    if #want > 0 then
        ns.Send(name, "AR", table.concat(want, "~"))
    end
    if ns.RefreshUI then ns.RefreshUI() end
end

function Handlers.AR(name, payload)
    if Hidden(name) then
        return
    end
    for alt, list in payload:gmatch("([^:~]+):([^~]*)") do
        local p = ns.db.people[alt]
        if p and p.mine and alt ~= ns.me then
            for section in list:gmatch("[^,]+") do
                if ns.Encode[section] then
                    ns.Send(name, "AS", alt .. "^" .. section .. "^" .. (p.rev[section] or 0) .. "^"
                        .. ns.Encode[section](p[section] or {}), "AS" .. alt .. section)
                end
            end
        end
    end
end

function Handlers.AS(name, payload)
    local alt, section, rev, data = payload:match("^([^%^]+)%^(%a+)%^(%d+)%^(.*)$")
    local q = alt and ns.db.people[alt]
    if not q or q.via ~= name or not ns.Decode[section] then
        return
    end
    rev = tonumber(rev)
    if rev <= (q.rev[section] or 0) then
        return
    end
    local ok, value = pcall(ns.Decode[section], data)
    if ok and value then
        q[section] = value
        q.rev[section] = rev
        ns.Changed()
        if ns.RefreshUI then ns.RefreshUI() end
    end
end

function Handlers.RQ(name, payload)
    if Hidden(name) then
        return
    end
    for section in payload:gmatch("[^,]+") do
        if ns.Encode[section] then
            SendSection(name, section)
        end
    end
end

function Handlers.SE(name, payload)
    local section, rev, data = payload:match("^(%a+)%^(%d+)%^(.*)$")
    if not section or not ns.Decode[section] then
        return
    end
    local p = ns.Person(name, true)
    rev = tonumber(rev)
    if rev <= (p.rev[section] or 0) then
        return -- old news
    end
    local ok, value = pcall(ns.Decode[section], data)
    if ok and value then
        p[section] = value
        p.rev[section] = rev
        p.seen = time()
        ns.Changed()
        if ns.RefreshUI then ns.RefreshUI() end
    end
end

-- Hides or shows a character or a whole friend ("#tag"). Hidden people stop
-- getting your data at once; showing them again says hello so both sides
-- catch up.
function ns.SetHidden(key, hide)
    if key == ns.me or key == ns.GroupOf(ns.me) then
        return
    end
    ns.db.hidden[key] = hide and true or nil
    ns.Changed()
    local members = { key }
    if key:sub(1, 1) == "#" then
        members = {}
        for k in pairs(ns.db.people) do
            if ns.GroupOf(k) == key then
                members[#members + 1] = k
            end
        end
    end
    for _, name in ipairs(members) do
        ns.UpdateSharing(name, hide)
    end
    if ns.RefreshUI then ns.RefreshUI(true) end
end

function ns.UpdateSharing(name, hide)
    if hide then
        ForgetQueued(name)
    elseif ns.IsHidden(name) then
        return
    elseif ns.online[name] then
        ns.Send(name, "HI", HelloPayload(false))
    else
        -- We stopped saying hello while they were hidden: check the friends
        -- lists again so they get one now if they are online.
        for target in pairs(wasOnline) do
            if target == name or FirstName(target) == FirstName(name) then
                wasOnline[target] = nil
                lastHello[target] = nil
            end
        end
        for id, n in pairs(bnetNames) do
            if n == name then
                wasOnline["#" .. id] = nil
                lastHello["#" .. id] = nil
            end
        end
        UpdateFriendsSoon()
    end
end

local function Handle(from, msg)
    local kind, payload = msg:match("^(%u%u)%^(.*)$")
    if not kind then
        return
    end
    -- Guild messages only count on the guild channel, friend messages only
    -- in whispers and over Battle.net.
    if from.guild then
        if GuildHandlers[kind] and ns.db.guildShare then
            GuildHandlers[kind](from.raw, payload)
        end
        return
    end
    if not Handlers[kind] then
        return
    end
    local name
    if from.bnet then
        name = bnetNames[from.bnet]
    else
        name = ns.ResolveName(from.raw, friendNames)
    end
    if kind == "HI" then
        Handlers.HI(name, payload, from)
    elseif kind == "AR" and name and ns.online[name] and ns.db.crew[name] then
        Handlers.AR(name, payload)
    elseif name and ns.online[name] and ns.db.crew[name] then
        Handlers[kind](name, payload)
    end
end

local buffers = {}

local function Receive(label, text, from)
    local mark = text:sub(1, 1)
    if mark == "S" then
        Handle(from, text:sub(2))
    elseif mark == "C" then
        local id, i, n, part = text:match("^C(%d+):(%d+):(%d+):(.*)$")
        if not id then
            return
        end
        i, n = tonumber(i), tonumber(n)
        local key = label .. "#" .. id
        local b = buffers[key]
        if not b then
            b = { n = n, parts = {}, got = 0, t = GetTime() }
            buffers[key] = b
        end
        if not b.parts[i] then
            b.parts[i] = part
            b.got = b.got + 1
        end
        if b.got == b.n then
            buffers[key] = nil
            Handle(from, table.concat(b.parts))
        end
    end
    -- Throw away parts that never completed.
    for key, b in pairs(buffers) do
        if GetTime() - b.t > 120 then
            buffers[key] = nil
        end
    end
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX or ns.IsSecret(text) or ns.IsSecret(sender) then
        return
    end
    if type(text) ~= "string" or type(sender) ~= "string" or ns.FullName(sender) == ns.me then
        return
    end
    if channel == "GUILD" then
        Receive("G:" .. sender, text, { raw = sender, guild = true })
    elseif channel == "WHISPER" or channel == nil then
        Receive(sender, text, { raw = sender })
    end
end)

ns.On("BN_CHAT_MSG_ADDON", function(prefix, text, channel, senderID)
    if prefix ~= PREFIX or ns.IsSecret(text) or ns.IsSecret(senderID) then
        return
    end
    if type(text) ~= "string" or not senderID then
        return
    end
    Receive("#" .. tostring(senderID), text, { bnet = senderID })
end)

-------------------------------------------------------------------------------
-- A friend who just logged off: whispering them makes the game print "No
-- player named X is currently playing". Hide that line for our own hidden
-- whispers and note that they are offline.
-------------------------------------------------------------------------------

local function SystemFilter(_, _, msg, ...)
    if type(msg) ~= "string" or ns.IsSecret(msg) or not ERR_CHAT_PLAYER_NOT_FOUND_S then
        return false
    end
    local now = GetTime()
    for target, t in pairs(recentWhisper) do
        if now - t < 10 then
            local short = target:match("^[^%-]+")
            local first = target:match("^[^%s%-]+")
            if msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(target) or msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(short)
                or msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(first) then
                ns.online[target] = nil
                ForgetQueued(target)
                if ns.RefreshUI then ns.RefreshUI() end
                return true
            end
        end
    end
    return false
end

local AddFilter = ChatFrame_AddMessageEventFilter
    or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
if AddFilter then
    AddFilter("CHAT_MSG_SYSTEM", SystemFilter)
end

-------------------------------------------------------------------------------
-- Opt-in: Share or Not now for a friend who has FriendsCraft
-------------------------------------------------------------------------------

-- yes = share with them (and their other characters); no = stay quiet.
function ns.AcceptFriend(name, yes)
    local pend = ns.pending[name]
    local tag = (pend and pend.tag) or (ns.db.people[name] and ns.db.people[name].tag)
    local value = yes and "yes" or "no"
    ns.db.consent[name] = value
    if tag then
        ns.db.consent["#" .. tag] = value
    end
    ns.pending[name] = nil
    ns.Changed()
    if yes then
        -- Say hello properly now; if they said yes too, data flows.
        lastHello[name] = nil
        if routes[name] then
            lastHello["#" .. routes[name]] = nil
        end
        Queue(name, routes[name], "HI", HelloPayload(false))
    end
    if ns.RefreshMinimapMark then ns.RefreshMinimapMark() end
    if ns.RefreshUI then ns.RefreshUI(true) end
end

-- Friends who said no ("Not now"), by name.
function ns.Declined()
    local list = {}
    for key, v in pairs(ns.db.consent) do
        if v == "no" and key:sub(1, 1) ~= "#" then
            list[#list + 1] = key
        end
    end
    table.sort(list)
    return list
end

function ns.PendingList()
    local list = {}
    for name in pairs(ns.pending) do
        if not ns.db.crew[name] and ns.Consent(name) == nil then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end

-------------------------------------------------------------------------------
-- Guild: professions, skills and recipes only
-------------------------------------------------------------------------------

local lastGuildHello = 0
local lastGuildSection = {} -- [section] = GetTime() we last sent it to the guild

local function InGuild()
    return ns.db.guildShare and IsInGuild and IsInGuild() and ns.GuildName() ~= nil
end

local function GuildHello(reply)
    if not InGuild() then
        return
    end
    if reply and GetTime() - lastGuildHello < 30 then
        return -- answered someone a moment ago; they all heard it
    end
    lastGuildHello = GetTime()
    local me = ns.Me()
    Queue(GUILD, nil, "GH", table.concat({ ns.PROTOCOL, reply and 1 or 0, ns.me, me.level or 0, me.class or "",
        me.faction or "", me.rev.prof or 0, me.rev.recipes or 0 }, "^"), "GH")
end
ns.GuildHello = GuildHello

-- A name someone claims in a guild message, checked against the sender.
local function GuildName(claimed, sender)
    local name = ns.FullName(claimed)
    if name and FirstName(name) == FirstName(sender) and name ~= ns.me then
        return name
    end
    return nil
end

local function GuildPerson(name)
    local p = ns.Person(name, true)
    if p.mine then
        return nil
    end
    p.name = name
    if not ns.db.crew[name] then
        p.guildOf = ns.GuildName()
    end
    return p
end

function GuildHandlers.GH(sender, payload)
    local f = Split(payload, "^")
    if (tonumber(f[1]) or 0) < ns.PROTOCOL then
        return
    end
    local name = GuildName(f[3], sender)
    local p = name and GuildPerson(name)
    if not p then
        return
    end
    p.level = tonumber(f[4]) or p.level
    p.class = (f[5] or ""):match("^%u+$") or p.class
    p.faction = (f[6] or ""):match("^%a+$") or p.faction
    p.gseen = time()
    if not ns.db.crew[name] then
        p.seen = p.gseen
    end
    local want = {}
    if (tonumber(f[7]) or 0) > (p.rev.prof or 0) then want[#want + 1] = "prof" end
    if (tonumber(f[8]) or 0) > (p.rev.recipes or 0) then want[#want + 1] = "recipes" end
    if #want > 0 then
        Queue(GUILD, nil, "GQ", name .. "^" .. table.concat(want, ","), "GQ" .. name)
    end
    if f[2] ~= "1" then
        GuildHello(true)
    end
    ns.Changed()
    if ns.RefreshUI then ns.RefreshUI() end
end

function GuildHandlers.GQ(sender, payload)
    local target, list = payload:match("^([^%^]+)%^(.*)$")
    if ns.FullName(target) ~= ns.me or not InGuild() then
        return
    end
    local me = ns.Me()
    for section in (list or ""):gmatch("[^,]+") do
        if GUILD_SECTIONS[section] and GetTime() - (lastGuildSection[section] or 0) > 20 then
            lastGuildSection[section] = GetTime()
            Queue(GUILD, nil, "GS", ns.me .. "^" .. section .. "^" .. (me.rev[section] or 0) .. "^"
                .. ns.Encode[section](me[section] or {}), "GS" .. section)
        end
    end
end

function GuildHandlers.GS(sender, payload)
    local claimed, section, rev, data = payload:match("^([^%^]+)%^(%a+)%^(%d+)%^(.*)$")
    local name = claimed and GuildName(claimed, sender)
    if not name or not GUILD_SECTIONS[section] then
        return
    end
    local p = GuildPerson(name)
    rev = tonumber(rev)
    if not p or rev <= (p.rev[section] or 0) then
        return
    end
    local ok, value = pcall(ns.Decode[section], data)
    if ok and value then
        p[section] = value
        p.rev[section] = rev
        ns.Changed()
        if ns.RefreshUI then ns.RefreshUI() end
    end
end

-- Guildmates who left the guild (or a guild you left) drop off the list.
local function PruneGuild()
    local guild = ns.GuildName()
    if not guild or not GetNumGuildMembers or not GetGuildRosterInfo then
        return
    end
    local n = GetNumGuildMembers() or 0
    if n == 0 then
        return
    end
    local full, first = {}, {}
    for i = 1, n do
        local ok, raw = pcall(GetGuildRosterInfo, i)
        if ok and type(raw) == "string" and not ns.IsSecret(raw) then
            local name = ns.FullName(raw)
            if name then full[name] = true end
            first[FirstName(raw)] = true
        end
    end
    local gone = false
    for key, p in pairs(ns.db.people) do
        if ns.IsGuildOnly(key) and (p.guildOf ~= guild or not (full[key] or first[FirstName(key)])) then
            ns.db.people[key] = nil
            gone = true
        end
    end
    if gone then
        ns.Changed()
        if ns.RefreshUI then ns.RefreshUI() end
    end
end

-- Your professions or recipes changed: tell the guild the new versions.
function ns.GuildChanged(section)
    if GUILD_SECTIONS[section] then
        lastGuildHello = 0
        GuildHello(true)
    end
end

-- The guild setting was switched.
function ns.SetGuildShare(on)
    ns.db.guildShare = on and true or false
    ns.Changed()
    if on then
        lastGuildHello = 0
        GuildHello(false)
    else
        for i = #queue, 1, -1 do
            if queue[i].target == GUILD then
                table.remove(queue, i)
            end
        end
    end
    if ns.RefreshUI then ns.RefreshUI(true) end
end

ns.On("GUILD_ROSTER_UPDATE", function()
    if ready then
        PruneGuild()
    end
end)
ns.On("PLAYER_GUILD_UPDATE", function()
    if ready then
        C_Timer.After(3, ns.Safe(function() GuildHello(false) end, "guild"))
    end
end)

-------------------------------------------------------------------------------
-- Start-up and friends coming and going
-------------------------------------------------------------------------------

-- Register right away so no early message is missed.
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end

ns.On("FC_READY", function()
    if C_FriendList and C_FriendList.ShowFriends then
        C_FriendList.ShowFriends() -- asks the server for the friends list
    end
    -- Give the game a moment to settle, then say hello to friends.
    C_Timer.After(5, ns.Safe(function()
        ready = true
        UpdateFriends()
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            pcall(C_GuildInfo.GuildRoster)
        end
        GuildHello(false)
    end, "friends"))
end)

-- Also when a friend is added or removed: someone you remove stops
-- getting your data right away.
for _, event in ipairs({ "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE",
    "BN_FRIEND_ACCOUNT_OFFLINE", "BN_FRIEND_LIST_SIZE_CHANGED", "BN_CONNECTED", "BN_DISCONNECTED" }) do
    ns.On(event, UpdateFriendsSoon)
end
