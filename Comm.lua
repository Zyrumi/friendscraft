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
-- Messages (kind^payload):
--   HI  hello: ver^reply^level^class^full name^rev of each section
--   RQ  please send these sections: "prof,items"
--   SE  section: name^rev^data
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

local function Wipe(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local function Hidden(name)
    return name ~= nil and ns.db.hidden[name] == true
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
        ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, "WHISPER", item.target)
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
        if not item.bnet then
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
    return table.concat(parts, "^")
end

local function SendSection(name, section)
    local me = ns.Me()
    ns.Send(name, "SE", section .. "^" .. (me.rev[section] or 0) .. "^" .. ns.Encode[section](me[section]), "SE" .. section)
end

-- Sends a changed section to every online crew member.
function ns.Broadcast(section)
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

local function HelloTo(target, bnet)
    local id = bnet and ("#" .. bnet) or target
    if lastHello[id] and GetTime() - lastHello[id] < HELLO_GAP then
        return
    end
    lastHello[id] = GetTime()
    Queue(target, bnet, "HI", HelloPayload(false))
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
    for i = 1, (BNGetNumFriends()) or 0 do
        for j = 1, B.GetFriendNumGameAccounts(i) or 0 do
            local g = B.GetFriendGameAccountInfo(i, j)
            local id = g and g.gameAccountID
            if id and not ns.IsSecret(id) and g.isOnline and g.clientProgram == wow then
                list[id] = true
            end
        end
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
        if not wasOnline[target] and not routes[target] and not Hidden(target) then
            HelloTo(target, nil)
        end
    end
    for id in pairs(bnet) do
        local label = "#" .. id
        nowOnline[label] = true
        if not wasOnline[label] and not Hidden(bnetNames[id]) then
            HelloTo(bnetNames[id] or label, id)
        end
    end
    wasOnline = nowOnline
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
    local now = GetTime()
    local again = lastHeard[name] and now - lastHeard[name] < 5
    lastHeard[name] = now
    if not ns.db.crew[name] then
        ns.db.crew[name] = true
        ns.Changed()
    end
    ns.online[name] = true
    local p = ns.Person(name, true)
    p.name = name
    p.level = tonumber(f[3]) or p.level
    p.class = (f[4] or ""):match("^%u+$") or p.class
    p.seen = time()
    if ns.RefreshUI then ns.RefreshUI() end
    if again or Hidden(name) then
        return -- the same hello by the other route
    end
    if f[2] ~= "1" then
        ns.Send(name, "HI", HelloPayload(true)) -- answer first, then ask
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

-- Hides or shows someone. Hidden people stop getting your data at once;
-- showing them again says hello so both sides catch up.
function ns.SetHidden(name, hide)
    if name == ns.me then
        return
    end
    ns.db.hidden[name] = hide and true or nil
    ns.Changed()
    if hide then
        ForgetQueued(name)
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
    if ns.RefreshUI then ns.RefreshUI(true) end
end

local function Handle(from, msg)
    local kind, payload = msg:match("^(%u%u)%^(.*)$")
    if not kind or not Handlers[kind] then
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
    Receive(sender, text, { raw = sender })
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
    end, "friends"))
end)

-- Also when a friend is added or removed: someone you remove stops
-- getting your data right away.
for _, event in ipairs({ "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE",
    "BN_FRIEND_ACCOUNT_OFFLINE", "BN_FRIEND_LIST_SIZE_CHANGED", "BN_CONNECTED", "BN_DISCONNECTED" }) do
    ns.On(event, UpdateFriendsSoon)
end
