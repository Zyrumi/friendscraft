-- FriendsCraft: Professions tab in the guild window
--
-- Adds a tab under the game's own guild tabs (Roster, Info, ...) listing
-- every guild member by profession. Three sources, combined per member:
--   1. FriendsCraft's own data (you, your alts, friends and guild members
--      who run FriendsCraft): exact skill and recipes, usually the freshest.
--   2. FriendsCraftGuildData, from the optional FriendsCraft_Guild addon:
--      skill and recipes from Blizzard's armory for everyone it has.
--   3. The game's own guild profession list (GetGuildTradeSkillInfo): who
--      has which profession, for every member. Its skill number is always 1
--      on Forever, so it is never shown.
-- The tab is our own button and panel on top of the guild window. It never
-- changes the window's display mode, so the game's own tabs keep working.

local _, ns = ...

local TEST_PROFESSION = 2933 -- "Test Profession [DNT]", sent by the server
local CLASS_BY_ID = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
    [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [10] = "MONK", [11] = "DRUID",
    [12] = "DEMONHUNTER", [13] = "EVOKER" }
local GATHERING = { [182] = true, [186] = true, [393] = true }
local SECONDARY = { [185] = true, [129] = true, [356] = true }
local BLIZZ_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }
local NAME_W, LEVEL_W, BAR_W = 230, 30, 180 -- BAR_W: a bit wider than the Skills panel's 160
local ROW_H = 26     -- a bit taller than FriendsCraft's lists, for the game's skill bars
local OFFLINE = 0.7  -- offline names keep their class color, a bit darker
local CAN_MAKE_SHOWN = 4 -- "Can make" names this many, then "+N more"

local U -- ns.UI, set up when the guild window loads
local panel, tab, list, search, offlineBox, footer, foldAll
local recipeWin -- one member's recipes, opened by clicking them
local shownIds = {} -- profession ids on the page, for "Collapse all"
local folded = {} -- [profession id] = true while folded (this session only)
local refreshPending = false

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

local function Plain(v)
    if v == nil or ns.IsSecret(v) then
        return nil
    end
    return v
end

local function Key(name)
    name = Plain(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return ns.FullName(name) or name
end

-- The armory file, if it belongs to the guild you're in.
local function Armory()
    local d = FriendsCraftGuildData
    if type(d) ~= "table" or type(d.members) ~= "table" or type(d.guild) ~= "string" then
        return nil
    end
    local g = ns.GuildName()
    if not g or d.guild:lower() ~= g:lower() then
        return nil
    end
    return d
end

-- [key] = { level, zone, online, class, away = { years, months, days, hours } }
local function Roster()
    local out = {}
    if not GetNumGuildMembers or not GetGuildRosterInfo then
        return out
    end
    local total = tonumber(Plain((GetNumGuildMembers()))) or 0
    for i = 1, total do
        local name, _, _, level, _, zone, _, _, online, _, class = GetGuildRosterInfo(i)
        local key = Key(name)
        if key then
            local e = { level = tonumber(Plain(level)), zone = Plain(zone), online = Plain(online) and true or false,
                class = Plain(class) }
            if not e.online and GetGuildRosterLastOnline then
                local ok, y, mo, d, h = pcall(GetGuildRosterLastOnline, i)
                if ok then
                    e.away = { tonumber(Plain(y)) or 0, tonumber(Plain(mo)) or 0, tonumber(Plain(d)) or 0,
                        tonumber(Plain(h)) or 0 }
                end
            end
            out[key] = e
        end
    end
    return out
end

-- The game's own list: { { id, name, icon, members = { [key] = { class, online, zone } } } }
local function Native()
    local profs = {}
    if not GetNumGuildTradeSkill or not GetGuildTradeSkillInfo then
        return profs
    end
    -- Headings come folded; members are only listed under open ones.
    if ExpandGuildTradeSkillHeader then
        for i = (tonumber(GetNumGuildTradeSkill()) or 0), 1, -1 do
            local id, collapsed, _, header = GetGuildTradeSkillInfo(i)
            if Plain(header) and Plain(collapsed) and Plain(id) then
                pcall(ExpandGuildTradeSkillHeader, id)
            end
        end
    end
    local current
    for i = 1, (tonumber(GetNumGuildTradeSkill()) or 0) do
        local id, _, icon, header, _, _, _, name, _, _, online, zone, _, classFile = GetGuildTradeSkillInfo(i)
        id, header = tonumber(Plain(id)), Plain(header)
        if header then
            current = nil
            if id and id ~= TEST_PROFESSION and not tostring(header):find("[DNT]", 1, true) then
                current = { id = id, name = tostring(header), icon = Plain(icon), members = {} }
                profs[#profs + 1] = current
            end
        elseif current then
            local key = Key(name)
            if key then
                current.members[key] = { class = Plain(classFile), online = Plain(online) and true or false,
                    zone = Plain(zone) }
            end
        end
    end
    return profs
end

-- FriendsCraft's own data for one character: { [line] = { id, name, skill, max, recipes = { names } } }
local function OwnData(key)
    local p = ns.db and ns.db.people[key]
    if not p or ns.IsHidden(key) then
        return nil
    end
    local out = {}
    for _, e in ipairs(p.prof or {}) do
        if e.line and e.line > 0 then
            local recipes, items = {}, {}
            for rid, item in pairs((p.recipes or {})[e.name] or {}) do
                local name = ns.RecipeName(rid, item)
                recipes[#recipes + 1] = name
                items[name] = tonumber(item) ~= 0 and tonumber(item) or nil
            end
            out[e.line] = { id = e.line, name = e.name, skill = e.rank, max = e.max, recipes = recipes, items = items,
                icon = e.icon }
        end
    end
    return out
end

-- Best of both sources per profession: the higher skill wins (skills only
-- go up), FriendsCraft on a tie; recipes are the union. recipes[name] is
-- the crafted item's ID when FriendsCraft knows it, else true.
local function Merge(key, armory)
    local merged = {}
    local function Add(e, source, seen)
        local id = type(e) == "table" and tonumber(e.id)
        if not id then
            return
        end
        local m = merged[id]
        if not m then
            m = { id = id, name = e.name, recipes = {}, count = 0 }
            merged[id] = m
        end
        m.icon = m.icon or e.icon
        local skill = tonumber(e.skill)
        if skill and skill >= (m.skill or -1) then
            m.skill, m.max, m.source, m.seen = skill, tonumber(e.max), source, seen
        end
        for _, r in ipairs(e.recipes or {}) do
            if type(r) == "string" then
                if not m.recipes[r] then
                    m.count = m.count + 1
                end
                m.recipes[r] = (e.items and e.items[r]) or (type(m.recipes[r]) == "number" and m.recipes[r]) or true
            end
        end
    end
    local a = armory and armory.members[key]
    if type(a) == "table" then
        for _, e in ipairs(a.profs or {}) do
            Add(e, "armory", tonumber(a.seen))
        end
    end
    for _, e in pairs(OwnData(key) or {}) do
        Add(e, "fc")
    end
    return merged, type(a) == "table" and a or nil
end

local function SectionOrder(s)
    if SECONDARY[s.id] then
        return 3
    elseif GATHERING[s.id] then
        return 2
    end
    return 1
end

-- Everything the tab shows: sections (one per profession) with their rows.
local function Build()
    local armory = Armory()
    local roster = Roster()
    local rosterKnown = next(roster) ~= nil
    local showOffline = ns.db.guildOffline ~= false
    local sections, byId = {}, {}
    local function Section(id, name, icon)
        local s = byId[id]
        if not s then
            s = { id = id, name = name or ("Profession " .. id), icon = icon, members = {} }
            byId[id] = s
            sections[#sections + 1] = s
        end
        s.icon = s.icon or icon
        return s
    end

    local people = {}
    for _, p in ipairs(Native()) do
        local s = Section(p.id, p.name, p.icon)
        for key, m in pairs(p.members) do
            s.members[key] = { key = key, class = m.class, online = m.online, zone = m.zone }
            people[key] = true
        end
    end
    for key in pairs(roster) do
        people[key] = true
    end
    if armory then
        for key in pairs(armory.members) do
            if type(key) == "string" and (not rosterKnown or roster[key]) then
                people[key] = true
            end
        end
    end

    local total, known = 0, 0
    for key in pairs(people) do
        total = total + 1
        local merged, a = Merge(key, armory)
        local any = false
        for id, e in pairs(merged) do
            if e.skill then
                any = true
            end
            local s = Section(id, e.name, e.icon)
            local m = s.members[key]
            if not m then
                m = { key = key }
                s.members[key] = m
            end
            m.prof = e
            m.armory = a
        end
        if any then
            known = known + 1
        end
    end

    for _, s in ipairs(sections) do
        local rows, online = {}, 0
        for key, m in pairs(s.members) do
            local r = roster[key]
            if r then
                m.online, m.zone, m.away = r.online, r.zone, r.away
                m.level = r.level
                m.class = m.class or r.class
            end
            if m.armory then
                m.level = m.level or tonumber(m.armory.level)
                m.class = m.class or CLASS_BY_ID[tonumber(m.armory.class) or 0]
            end
            if m.online then
                online = online + 1
            end
            if showOffline or m.online then
                rows[#rows + 1] = m
            end
        end
        table.sort(rows, function(x, y)
            local sx, sy = x.prof and x.prof.skill or -1, y.prof and y.prof.skill or -1
            if sx ~= sy then
                return sx > sy
            end
            return x.key < y.key
        end)
        s.rows, s.online = rows, online
        s.count = 0
        for _ in pairs(s.members) do
            s.count = s.count + 1
        end
        s.icon = s.icon or ns.ProfIcon({ line = s.id })
    end
    table.sort(sections, function(x, y)
        local ox, oy = SectionOrder(x), SectionOrder(y)
        if ox ~= oy then
            return ox < oy
        end
        return x.name < y.name
    end)
    return sections, known, total, armory
end

-------------------------------------------------------------------------------
-- Text helpers
-------------------------------------------------------------------------------

local function Plural(n, one, many)
    return n .. " " .. (n == 1 and one or many)
end

local function Ago(ts)
    ts = tonumber(ts)
    local now = time and time() or nil
    if not ts or not now then
        return nil
    end
    local s = math.max(0, now - ts)
    if s < 3600 then
        return Plural(math.max(1, math.floor(s / 60)), "minute", "minutes") .. " ago"
    elseif s < 86400 * 2 then
        return Plural(math.floor(s / 3600), "hour", "hours") .. " ago"
    end
    return Plural(math.floor(s / 86400), "day", "days") .. " ago"
end

local function AwayText(away)
    if not away then
        return "Offline"
    end
    local y, mo, d, h = away[1], away[2], away[3], away[4]
    if y > 0 then
        return "Offline over a year"
    elseif mo > 0 then
        return "Offline " .. Plural(mo, "month", "months")
    elseif d > 0 then
        return "Offline " .. Plural(d, "day", "days")
    elseif h > 0 then
        return "Offline " .. Plural(h, "hour", "hours")
    end
    return "Offline"
end

local function CountText(s)
    if s.count == 0 then
        return "nobody yet"
    end
    return Plural(s.count, "member", "members") .. ", " .. (s.online > 0 and (s.online .. " online") or "nobody online")
end

-- Quality and item level of what a recipe makes; nil until the game has the
-- item (GET_ITEM_INFO_RECEIVED redraws when it arrives).
local function ItemStats(id)
    if not id then
        return nil, nil
    end
    local q, ilvl
    if GetItemInfo then
        local ok, name, _, quality, level = pcall(GetItemInfo, id)
        if ok and name then
            q, ilvl = Plain(quality), Plain(level)
        end
    end
    q = q or ns.ItemQuality(id)
    if not q and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    return tonumber(q), tonumber(ilvl)
end

-- Best first: the rarest crafted item, then the highest item level (a fair
-- stand-in for the skill a recipe needs), then by name. Recipes that make no
-- item (enchants, for one) go last, by name.
-- { { name, id, quality, level } }
local function RankedRecipes(prof)
    local out = {}
    for name, item in pairs(prof and prof.recipes or {}) do
        local id = type(item) == "number" and item or nil
        local q, ilvl = ItemStats(id)
        out[#out + 1] = { name = name, id = id, quality = q, level = ilvl }
    end
    table.sort(out, function(x, y)
        local qx, qy = x.quality or -1, y.quality or -1
        if qx ~= qy then
            return qx > qy
        end
        local lx, ly = x.level or -1, y.level or -1
        if lx ~= ly then
            return lx > ly
        end
        return x.name < y.name
    end)
    return out
end

local function SortedRecipes(prof)
    local out = {}
    for i, r in ipairs(RankedRecipes(prof)) do
        out[i] = r.name
    end
    return out
end

-------------------------------------------------------------------------------
-- Rows
-------------------------------------------------------------------------------

-- The bar from the game's own Skills panel (SkillsBarTemplate: blue fill,
-- number in the middle); FriendsCraft's plain bar where it's missing.
local function SkillBar(parent, w, h)
    for _, template in ipairs({ "SkillsBarTemplate", "ColoredProgressBarTemplate" }) do
        local ok, bar = pcall(CreateFrame, "StatusBar", nil, parent, template)
        if ok and bar and type(bar.SetFillPercent) == "function" then
            bar:SetSize(w, h)
            local types = ColoredProgressBarMixin and ColoredProgressBarMixin.ColorType
            if types and types.Blue and bar.SetFillTextureByColorType then
                pcall(bar.SetFillTextureByColorType, bar, types.Blue)
            end
            if bar.UpdateBarColor and WHITE_FONT_COLOR then
                pcall(bar.UpdateBarColor, bar, WHITE_FONT_COLOR)
            end
            bar.native = true
            return bar
        elseif ok and bar then
            bar:Hide()
        end
    end
    local bar = U.ProgressBar(parent)
    bar:SetSize(w, math.max(12, h - 8))
    bar:SetStatusBarColor(0.27, 0.55, 0.22)
    return bar
end

local function SetSkill(bar, skill, max)
    max = (max and max > 0) and max or math.max(skill, 1)
    local text = skill .. " / " .. max
    if bar.native then
        pcall(bar.SetFillPercent, bar, math.min(skill / max, 1))
        if bar.UpdateBarProgressText and bar.TryShowBarProgressText then
            pcall(bar.UpdateBarProgressText, bar, text)
            pcall(bar.TryShowBarProgressText, bar)
        elseif bar.SetText then
            pcall(bar.SetText, bar, text)
        end
    else
        bar:SetMinMaxValues(0, max)
        bar:SetValue(math.min(skill, max))
        bar.text:SetText(text)
    end
end

local function MakeRow(parent)
    local row = CreateFrame("Button", nil, parent)
    U.RowScripts(row)
    U.HeadingParts(row)
    row.hIcon = row:CreateTexture(nil, "ARTWORK")
    row.hIcon:SetSize(16, 16)
    row.hIcon:SetPoint("BOTTOMLEFT", 24, 3)
    -- The game's own +/- fold button look; plain text where it's missing.
    row.hFold = row:CreateTexture(nil, "ARTWORK")
    row.hFold:SetSize(14, 14)
    row.hFold:SetPoint("BOTTOMLEFT", 5, 4)
    row.hIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.hText:ClearAllPoints()
    row.hText:SetPoint("BOTTOMLEFT", 46, 4)

    row.classIcon = row:CreateTexture(nil, "ARTWORK")
    row.classIcon:SetSize(16, 16)
    row.classIcon:SetPoint("LEFT", 8, 0)
    row.name = U.Ink(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", 30, 0)
    row.name:SetWidth(NAME_W)
    row.name:SetWordWrap(false)
    row.level = U.Ink(row, "GameFontHighlightSmall")
    row.level:SetPoint("LEFT", 30 + NAME_W, 0)
    row.level:SetWidth(LEVEL_W)
    row.level:SetJustifyH("RIGHT")
    row.bar = SkillBar(row, BAR_W, ROW_H - 2)
    row.bar:SetPoint("LEFT", 30 + NAME_W + LEVEL_W + 16, 0)
    row.none = U.Ink(row, "GameFontHighlightSmall", "no skill info", U.INK_DIM)
    row.none:SetPoint("LEFT", row.bar, "LEFT", 4, 0)

    row.sub = U.Ink(row, "GameFontHighlightSmall", "", U.INK_DIM)
    row.sub:SetPoint("LEFT", 30, 0)
    row.sub:SetPoint("RIGHT", -6, 0)
    row.sub:SetWordWrap(false)
    return row
end

local function FillRow(row, item)
    local kind = item.kind
    local heading, member, sub = kind == "heading", kind == "member", kind == "sub"
    row.hText:SetShown(heading)
    row.hRight:SetShown(heading)
    row.hLine:SetShown(heading)
    row.hIcon:SetShown(heading)
    row.hFold:SetShown(heading)
    for _, part in ipairs({ row.classIcon, row.name, row.level, row.bar, row.none }) do
        part:SetShown(member)
    end
    row.sub:SetShown(sub)
    if row.stripe then
        row.stripe:SetAlpha(member and 1 or 0)
    end
    if heading then
        local s = item.section
        row.hIcon:SetTexture(s.icon or 134400)
        local fold = item.folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up"
        if U.UseFile(row.hFold, fold) then
            row.hText:SetText(s.name)
        else
            row.hFold:Hide()
            row.hText:SetText((item.folded and "+ " or "- ") .. s.name)
        end
        row.hRight:SetText(CountText(s))
        return
    end
    if sub then
        row.sub:SetText(item.text or "")
        return
    end
    local m = item.member
    U.SetClassIcon(row.classIcon, m.class)
    row.name:SetText(m.key)
    local r, g, b = U.ClassColor(m.class)
    local k = m.online and 1 or OFFLINE
    row.name:SetTextColor(r * k, g * k, b * k)
    row.level:SetText(m.level and tostring(m.level) or "")
    local p = m.prof
    if p and p.skill then
        SetSkill(row.bar, p.skill, p.max)
        row.none:Hide()
    else
        row.bar:Hide()
        row.none:Show()
    end
end

local function MemberTooltip(tt, s, m)
    local r, g, b = U.ClassColor(m.class)
    tt:SetText(m.key, r, g, b)
    -- Where they are lives here, not in a column.
    local where = m.online and (m.zone and m.zone ~= "" and ("Online, " .. m.zone) or "Online") or AwayText(m.away)
    tt:AddLine(where, U.INK_DIM[1], U.INK_DIM[2], U.INK_DIM[3])
    local p = m.prof
    if p and p.skill then
        tt:AddLine(s.name .. ": " .. p.skill .. (p.max and (" / " .. p.max) or ""), 1, 1, 1)
        if p.source == "fc" then
            tt:AddLine("From FriendsCraft", U.INK_DIM[1], U.INK_DIM[2], U.INK_DIM[3])
        else
            local ago = Ago(p.seen)
            tt:AddLine("From the armory" .. (ago and (", their last logout " .. ago) or ""),
                U.INK_DIM[1], U.INK_DIM[2], U.INK_DIM[3])
        end
        if p.count > 0 then
            tt:AddLine(" ")
            tt:AddLine(Plural(p.count, "recipe", "recipes") .. ". Click to see them.", U.INFO[1], U.INFO[2], U.INFO[3])
        end
    else
        tt:AddLine("No skill info yet.", U.INK_DIM[1], U.INK_DIM[2], U.INK_DIM[3])
        local how = Armory() and "It shows once they run FriendsCraft, or once the armory has them (level 10 and a logout)."
            or "It shows once they run FriendsCraft."
        tt:AddLine(how, 1, 1, 1, true)
    end
end

-------------------------------------------------------------------------------
-- The panel
-------------------------------------------------------------------------------

local function Refresh()
    if not panel or not panel:IsShown() then
        return
    end
    local sections, known, total, armory = Build()
    shownIds = {}
    local anyOpen = false
    for _, s in ipairs(sections) do
        shownIds[#shownIds + 1] = s.id
        anyOpen = anyOpen or not folded[s.id]
    end
    if foldAll then
        foldAll:SetText(anyOpen and "Collapse all" or "Expand all")
        foldAll.collapse = anyOpen
    end
    local q = search and strtrim(search:GetText() or ""):lower() or ""
    local items = {}
    for _, s in ipairs(sections) do
        local rows, hits = s.rows, {}
        if q ~= "" and not s.name:lower():find(q, 1, true) then
            rows = {}
            for _, m in ipairs(s.rows) do
                local found = {}
                for _, r in ipairs(SortedRecipes(m.prof)) do
                    if r:lower():find(q, 1, true) then
                        found[#found + 1] = r
                    end
                end
                if #found > 0 or m.key:lower():find(q, 1, true) then
                    rows[#rows + 1] = m
                    hits[m] = found
                end
            end
        end
        if q == "" or #rows > 0 then
            local fold = q == "" and folded[s.id]
            items[#items + 1] = {
                kind = "heading", section = s, folded = fold,
                onClick = function()
                    folded[s.id] = not folded[s.id]
                    Refresh()
                end,
            }
            if not fold then
                for _, m in ipairs(rows) do
                    items[#items + 1] = { kind = "member", member = m,
                        tooltip = function(tt) MemberTooltip(tt, s, m) end,
                        onClick = function() ns.GuildTab.OpenRecipes(s, m) end }
                    local found = hits[m]
                    if found and #found > 0 then
                        local shown = {}
                        for i = 1, math.min(#found, CAN_MAKE_SHOWN) do
                            shown[i] = found[i]
                        end
                        local more = #found > CAN_MAKE_SHOWN and (" +" .. (#found - CAN_MAKE_SHOWN) .. " more") or ""
                        items[#items + 1] = { kind = "sub", text = "Can make: " .. table.concat(shown, ", ") .. more }
                    end
                end
            end
        end
    end
    if #items == 0 then
        items[1] = { kind = "sub", text = q ~= "" and "Nobody in the guild matches that." or
            "The game hasn't sent the guild's professions yet." }
    end
    list:SetItems(items)
    local text = "Skill and recipes for " .. known .. " of " .. Plural(total, "member", "members") .. "."
    if armory then
        local ago = Ago(armory.fetched)
        text = text .. " Armory data from " .. (ago or "earlier") .. "."
    end
    footer:SetText(text)
    offlineBox.SyncFilter()
end

local function RefreshSoon()
    if refreshPending or not panel or not panel:IsShown() then
        return
    end
    refreshPending = true
    C_Timer.After(0.2, ns.Safe(function()
        refreshPending = false
        Refresh()
    end, "guild professions"))
end

-- Ask the server for fresh lists; GUILD_TRADESKILL_UPDATE and
-- GUILD_ROSTER_UPDATE redraw when they arrive.
local function Query()
    -- The game's profession list leaves offline members out unless asked
    -- (this is the old guild window's setting, not the roster's tick box).
    if SetGuildRosterShowOffline then
        pcall(SetGuildRosterShowOffline, ns.db.guildOffline ~= false)
    end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    elseif GuildRoster then
        pcall(GuildRoster)
    end
    if QueryGuildRecipes then
        pcall(QueryGuildRecipes)
    end
end

local function SetBlizzardTabsChecked(cf, checked)
    for _, n in ipairs(BLIZZ_TABS) do
        local t = cf[n]
        if t and t.SetChecked then
            t:SetChecked(checked)
        end
    end
end

-- The guild chat's scroll bar is drawn on the HIGH layer, above the whole
-- window, so no frame level covers it. While our page is open it moves down
-- to the window's own layer; leaving the page puts it back.
local chatBarStrata
local function ChatBar()
    local cf = CommunitiesFrame
    local chat = cf and cf.Chat
    return type(chat) == "table" and chat.ScrollBar or nil
end

local function LowerChatBar()
    local bar = ChatBar()
    if chatBarStrata or not bar or not bar.GetFrameStrata then
        return
    end
    local strata = bar:GetFrameStrata()
    if type(strata) == "string" then
        chatBarStrata = strata
        bar:SetFrameStrata(panel:GetFrameStrata() or "MEDIUM")
    end
end

local function RestoreChatBar()
    local bar = ChatBar()
    if chatBarStrata and bar then
        bar:SetFrameStrata(chatBarStrata)
    end
    chatBarStrata = nil
end

-- The roster page's buttons along the bottom edge (Invite Member, the
-- officers' Guild Control / Recruitment, Guild Log) sit outside our panel and
-- would stay on our page. They're faded out and made unclickable rather than
-- hidden, so the game stays in charge of when each one shows.
local BOTTOM_BUTTONS = { "InviteButton", "CommunitiesControlFrame", "GuildLogButton" }
local muted -- { [frame] = mouse was enabled }

local function Mute(f)
    if f.IsMouseEnabled and f.EnableMouse then
        muted[f] = f:IsMouseEnabled()
        f:EnableMouse(false)
    else
        muted[f] = false
    end
    if f.GetChildren then
        for _, child in ipairs({ f:GetChildren() }) do
            Mute(child)
        end
    end
end

local function MuteBottomButtons()
    local cf = CommunitiesFrame
    if muted or not cf then
        return
    end
    muted = {}
    for _, key in ipairs(BOTTOM_BUTTONS) do
        local f = rawget(cf, key)
        if type(f) == "table" and f.SetAlpha then
            f:SetAlpha(0)
            Mute(f)
        end
    end
    -- The roster's member popup belongs to the roster page.
    local detail = rawget(cf, "GuildMemberDetailFrame")
    if type(detail) == "table" and detail.Hide then
        detail:Hide()
    end
end

local function RestoreBottomButtons()
    local cf = CommunitiesFrame
    if not muted or not cf then
        return
    end
    for f, mouse in pairs(muted) do
        if mouse then
            f:EnableMouse(true)
        end
    end
    for _, key in ipairs(BOTTOM_BUTTONS) do
        local f = rawget(cf, key)
        if type(f) == "table" and f.SetAlpha then
            f:SetAlpha(1)
        end
    end
    muted = nil
end

local function HidePanel()
    if panel and panel:IsShown() then
        panel:Hide()
    end
    RestoreChatBar()
    RestoreBottomButtons()
    if recipeWin then
        recipeWin:Hide()
    end
    if tab then
        tab:SetChecked(false)
    end
end

local function ShowPanel()
    panel:Show()
    LowerChatBar()
    MuteBottomButtons()
    SetBlizzardTabsChecked(CommunitiesFrame, false)
    tab:SetChecked(true)
    Query()
    Refresh()
end

local function BuildPanel(cf)
    panel = CreateFrame("Frame", nil, cf)
    panel:Hide()
    panel:SetPoint("TOPLEFT", cf.CommunitiesList or cf, cf.CommunitiesList and "TOPRIGHT" or "TOPLEFT", 24, 0)
    panel:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -8, 26)
    -- Well above every page of the window: its chat page's member list and
    -- input box sit high and showed through at 400. The side tabs are
    -- outside the panel, so covering their level does no harm.
    panel:SetFrameLevel(math.min((cf:GetFrameLevel() or 0) + 3000, 9000))
    panel:EnableMouse(true)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.05, 1)

    search = U.SearchInput(panel, 260, "Search recipe, profession or member")
    search:SetPoint("TOPLEFT", 12, -8)
    search:HookScript("OnTextChanged", function() Refresh() end)

    offlineBox = U.Toggle(panel, "Show offline members",
        function() return ns.db.guildOffline ~= false end,
        function(on)
            ns.db.guildOffline = on
            Query()
            Refresh()
        end)
    offlineBox:SetPoint("LEFT", search, "RIGHT", 16, 0)

    -- One button: "Collapse all" while any profession is open, else "Expand all".
    local okBtn, b = pcall(CreateFrame, "Button", nil, panel, "UIPanelButtonTemplate")
    if okBtn and b then
        foldAll = b
        foldAll:SetSize(100, 22)
        foldAll:SetPoint("TOPRIGHT", -12, -8)
        foldAll:SetText("Collapse all")
        foldAll:SetScript("OnClick", function(self)
            local collapse = self.collapse ~= false
            for _, id in ipairs(shownIds) do
                folded[id] = collapse or nil
            end
            Refresh()
        end)
    end

    local cols = CreateFrame("Frame", nil, panel)
    cols:SetPoint("TOPLEFT", 8, -36)
    cols:SetPoint("TOPRIGHT", -8, -36)
    cols:SetHeight(18)
    local function Col(text, x)
        local fs = U.Ink(cols, "GameFontNormalSmall", text, U.GOLD)
        fs:SetPoint("LEFT", x, 0)
        return fs
    end
    Col("Name", 30)
    local lvl = Col("Lvl", 30 + NAME_W)
    lvl:SetWidth(LEVEL_W)
    lvl:SetJustifyH("RIGHT")
    Col("Skill", 30 + NAME_W + LEVEL_W + 16)
    local line = cols:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    line:SetColorTexture(U.GOLD[1], U.GOLD[2], U.GOLD[3], 0.35)

    list = U.ScrollList(panel, ROW_H, MakeRow, FillRow, { native = true })
    list.frame:SetPoint("TOPLEFT", 8, -58)
    list.frame:SetPoint("BOTTOMRIGHT", -6, 24)

    footer = U.Ink(panel, "GameFontHighlightSmall", "", U.INK_DIM)
    footer:SetPoint("BOTTOMLEFT", 12, 6)
    footer:SetPoint("BOTTOMRIGHT", -12, 6)
    footer:SetWordWrap(false)

    panel:SetScript("OnShow", function() list:SetItems(list.items) end)
end

local function MakeTab(cf)
    local ok, b = pcall(CreateFrame, "CheckButton", nil, cf, "CommunitiesFrameTabTemplate")
    if not ok or not b then
        -- Plain stand-in where the game's side tab look is missing.
        b = CreateFrame("CheckButton", nil, cf)
        b:SetSize(32, 32)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.7)
        b:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltip, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    b.tooltip = "Professions"
    local icon = rawget(b, "Icon") or rawget(b, "icon")
    if type(icon) ~= "table" then
        icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
    end
    if not U.UseFile(icon, "Interface\\Icons\\Trade_BlackSmithing") then
        icon:SetTexture(134400)
    end
    icon:Show()
    b:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
            pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB)
        end
        ShowPanel()
    end)
    b:Hide()
    return b
end

-- After the game lays out its tabs: ours goes under the last guild tab, and
-- only while a guild is selected.
local function PlaceTab(cf)
    if not tab then
        return
    end
    local guild = cf.GuildInfoTab and cf.GuildInfoTab:IsShown()
    if not guild then
        tab:Hide()
        HidePanel()
        return
    end
    local last
    for i = #BLIZZ_TABS, 2, -1 do
        local t = cf[BLIZZ_TABS[i]]
        if t and t:IsShown() then
            last = t
            break
        end
    end
    tab:ClearAllPoints()
    tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -20)
    tab:Show()
    if panel:IsShown() then
        SetBlizzardTabsChecked(cf, false)
        tab:SetChecked(true)
    else
        tab:SetChecked(false)
    end
end

local function Setup()
    local cf = CommunitiesFrame
    if tab or not cf or not ns.UI then
        return
    end
    U = ns.UI
    BuildPanel(cf)
    tab = MakeTab(cf)
    for _, n in ipairs(BLIZZ_TABS) do
        local t = cf[n]
        if t and t.HookScript then
            t:HookScript("OnClick", HidePanel)
        end
    end
    if type(cf.UpdateCommunitiesTabs) == "function" then
        hooksecurefunc(cf, "UpdateCommunitiesTabs", ns.Safe(function() PlaceTab(cf) end, "guild tabs"))
    end
    cf:HookScript("OnHide", HidePanel)
    PlaceTab(cf)
end

local function CommunitiesLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded("Blizzard_Communities")
    end
    return IsAddOnLoaded and IsAddOnLoaded("Blizzard_Communities")
end

ns.On("ADDON_LOADED", function(name)
    if name == "Blizzard_Communities" then
        Setup()
    end
end)
ns.On("FC_READY", function()
    if CommunitiesLoaded() then
        Setup()
    end
end)
ns.On("GUILD_TRADESKILL_UPDATE", RefreshSoon)
ns.On("GUILD_ROSTER_UPDATE", RefreshSoon)

-- Item qualities and levels arrive a moment after we ask; re-sort then.
local recipesPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
    if recipesPending or not recipeWin or not recipeWin:IsShown() then
        return
    end
    recipesPending = true
    C_Timer.After(0.3, ns.Safe(function()
        recipesPending = false
        if recipeWin:IsShown() then
            recipeWin:Fill()
        end
    end, "guild recipes"))
end)

-------------------------------------------------------------------------------
-- One member's recipes (click a member). The game's own "view their recipes"
-- is switched off on Forever, so this shows what FriendsCraft and the armory
-- know instead, searchable.
-------------------------------------------------------------------------------

local function BuildRecipeWindow()
    local ok, f = pcall(CreateFrame, "Frame", "FriendsCraftGuildRecipes", UIParent, "ButtonFrameTemplate")
    local framed = ok and f
    if not framed then
        f = CreateFrame("Frame", "FriendsCraftGuildRecipes", UIParent, "BackdropTemplate")
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        end
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
        f.fcTitle = U.Ink(f, "GameFontNormal", "", U.GOLD)
        f.fcTitle:SetPoint("TOP", 0, -16)
    end
    f.framed = framed
    f:SetSize(340, 470)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "FriendsCraftGuildRecipes") -- Escape closes it
    if framed and ButtonFrameTemplate_HideButtonBar then
        pcall(ButtonFrameTemplate_HideButtonBar, f)
    end

    local c = CreateFrame("Frame", nil, f)
    if framed and type(f.Inset) == "table" then
        c:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", 6, -6)
        c:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -6, 6)
    else
        c:SetPoint("TOPLEFT", 16, -40)
        c:SetPoint("BOTTOMRIGHT", -16, 16)
    end
    f.skill = SkillBar(c, 200, 26)
    f.skill:SetPoint("TOPLEFT", 4, -4)
    f.source = U.Ink(c, "GameFontHighlightSmall", "", U.INK_DIM)
    f.source:SetPoint("TOPLEFT", 4, -34)
    f.source:SetPoint("RIGHT", -4, 0)
    f.source:SetWordWrap(false)
    f.search = U.SearchInput(c, 300, "Search their recipes")
    f.search:SetPoint("TOPLEFT", 6, -52)
    f.search:SetPoint("RIGHT", -4, 0)
    f.search:HookScript("OnTextChanged", function() f:Fill() end)
    f.list = U.ScrollList(c, U.ROW_H, U.IconRow, U.FillIconRow, { native = true })
    f.list.frame:SetPoint("TOPLEFT", 0, -80)
    f.list.frame:SetPoint("BOTTOMRIGHT", 0, 26)
    f.count = U.Ink(c, "GameFontHighlightSmall", "", U.INK_DIM)
    f.count:SetPoint("BOTTOMLEFT", 4, 6)
    -- Common white and grey recipes out of the way; a search still finds them.
    f.best = U.Toggle(c, "Hide white and grey",
        function() return ns.db.guildHideCommon == true end,
        function(on)
            ns.db.guildHideCommon = on
            f:Fill()
        end)
    f.best:SetPoint("BOTTOMRIGHT", -112, 0)

    function f:SetTitleText(text)
        if self.SetTitle then
            pcall(self.SetTitle, self, text)
        elseif self.fcTitle then
            self.fcTitle:SetText(text)
        end
    end

    function f:Fill()
        local s, m = self.section, self.member
        if not s or not m then
            return
        end
        local p = m.prof or {}
        local q = strtrim(self.search:GetText() or ""):lower()
        local best = q == "" and ns.db.guildHideCommon == true
        self.best.SyncFilter()
        local items, hidden = {}, 0
        for _, r in ipairs(RankedRecipes(p)) do
            local name, id = r.name, r.id
            if best and r.quality and r.quality <= 1 then
                hidden = hidden + 1
            elseif q == "" or name:lower():find(q, 1, true) then
                items[#items + 1] = {
                    icon = id and ns.ItemIcon(id) or s.icon or 134400,
                    text = name,
                    color = id and U.QualityColor(id) or U.INK,
                    tooltip = function(tt)
                        if id and tt.SetItemByID then
                            tt:SetItemByID(id)
                        else
                            tt:SetText(name, 1, 1, 1)
                        end
                    end,
                }
            end
        end
        if #items == 0 then
            local text = q ~= "" and "No recipe matches that." or hidden > 0 and "Only white and grey recipes."
                or "No recipes known yet."
            items[1] = { icon = s.icon or 134400, text = text, color = U.INK_DIM }
        end
        self.list:SetItems(items)
        self.count:SetText(Plural(p.count or 0, "recipe", "recipes") .. (hidden > 0 and (", " .. hidden .. " hidden") or ""))
    end
    return f
end

local function OpenRecipes(s, m)
    if not U then
        return
    end
    recipeWin = recipeWin or BuildRecipeWindow()
    local f = recipeWin
    f.section, f.member = s, m
    f:SetTitleText(m.key .. ": " .. s.name)
    if f.framed then
        if f.SetPortraitToAsset then
            pcall(f.SetPortraitToAsset, f, s.icon or 134400)
        elseif type(f.portrait) == "table" and SetPortraitToTexture then
            pcall(SetPortraitToTexture, f.portrait, s.icon or 134400)
        end
    end
    local p = m.prof
    if p and p.skill then
        SetSkill(f.skill, p.skill, p.max)
        f.skill:Show()
        local ago = p.source ~= "fc" and Ago(p.seen)
        f.source:SetText(p.source == "fc" and "From FriendsCraft" or ("From the armory" .. (ago and (", their last logout " .. ago) or "")))
    else
        f.skill:Hide()
        f.source:SetText("No skill info yet")
    end
    f.search:SetText("")
    if not f.placed and CommunitiesFrame then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", CommunitiesFrame, "TOPRIGHT", 44, 0) -- clear of the side tabs
        f.placed = true
    end
    f:Show()
    f:Fill()
end

-- For the test rig.
ns.GuildTab = { Build = Build, Refresh = Refresh, Show = ShowPanel, Hide = HidePanel,
    Panel = function() return panel end, Tab = function() return tab end, List = function() return list end,
    Search = function() return search end, FoldAll = function() return foldAll end,
    OpenRecipes = OpenRecipes, RecipeWindow = function() return recipeWin end }
