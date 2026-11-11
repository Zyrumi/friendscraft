-- FriendsCraft: the book window, minimap button and item tooltips.
-- The book uses the game's own spellbook page art when the game has it,
-- and draws a plain parchment book otherwise. Built from plain frames so
-- it does not depend on Blizzard templates that change between versions.

local ADDON_NAME, ns = ...

-------------------------------------------------------------------------------
-- Sizes and colors
-------------------------------------------------------------------------------

local PAGE_H = 470          -- height of a page
local HEAD_H = 0            -- no bar above the pages (tabs sit on the side)
local HEADING_Y = -22       -- page heading, from the top of the page
local CONTROLS_Y = -50      -- search boxes etc.
local LIST_TOP = 84         -- first list row, from the top of the page
local LIST_BOTTOM = 52      -- room under the list for page numbers
local ROW_H = 20            -- text rows
local CREW_ROW_H = 26       -- crew rows (with icons)
local SLOTS = 6             -- profession icons per crew row
local GOLD_W = 84           -- gold column on the crew page
local PAGE_W = 330          -- width of a page (the art is fitted to it)
local INDEX_H = 24          -- profession rows on the Recipes index

local ART = {
    left = "spellbook-background-evergreen-left",
    tab = "common-sidetab",
    tabSelected = "common-sidetab-selected",
    tabHover = "common-sidetab-hover",
}

-- Dark ink for text on the pages (never gold on parchment).
local INK = { 0.20, 0.12, 0.05 }
local INK_DIM = { 0.30, 0.21, 0.12 }
local INK_GOOD = { 0.05, 0.36, 0.05 }
local INK_DIM_HEX = "|cff4d361f"
-- Game tooltips stay dark, so they keep light colors.
local INFO = { 0.5, 0.83, 1 }
local GOOD = { 0.4, 1, 0.4 }

local PW, INSET_X, CONTENT_W, LIST_H -- set in Layout()

-------------------------------------------------------------------------------
-- Art helpers
-------------------------------------------------------------------------------

local function AtlasInfo(name)
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, info = pcall(C_Texture.GetAtlasInfo, name)
        if ok then
            return info
        end
    end
    return nil
end

local function UseAtlas(tex, name)
    if AtlasInfo(name) then
        tex:SetAtlas(name)
        return true
    end
    return false
end

-- Sets a file texture; false when the game says it does not have it.
local function UseFile(tex, path)
    local ok, res = pcall(tex.SetTexture, tex, path)
    return ok and res ~= false
end

-- Shows an atlas mirrored left to right (side tabs, right page).
-- Loads the atlas's image file directly and flips its corner coordinates;
-- if anything is missing it shows the art unmirrored instead.
local function MirrorAtlas(tex, name)
    local info = AtlasInfo(name)
    local file = info and (info.file or info.filename)
    local l, r, t, b = info and info.leftTexCoord, info and info.rightTexCoord, info and info.topTexCoord, info and info.bottomTexCoord
    if file and l and r and t and b and info.width and info.height and UseFile(tex, file) then
        tex:SetSize(info.width, info.height)
        tex:SetTexCoord(r, l, t, b)
        return
    end
    tex:SetAtlas(name, true)
end

local function Layout()
    PW = PAGE_W
    INSET_X = 32
    CONTENT_W = PW - 2 * INSET_X
    LIST_H = PAGE_H - LIST_TOP - LIST_BOTTOM
end

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

local function ClassName(class)
    if not class or class == "" then
        return ""
    end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or (class:sub(1, 1) .. class:sub(2):lower())
end

local function SetClassIcon(tex, class)
    if type(class) ~= "string" or class == "" then
        tex:Hide()
        return
    end
    if UseAtlas(tex, "classicon-" .. class:lower()) then
        tex:Show()
        return
    end
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if c and UseFile(tex, "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES") then
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
        tex:Show()
        return
    end
    tex:Hide()
end

-- "12 g 34 s"; the copper is left out once there is gold.
local function MoneyText(copper, exact)
    copper = math.floor(tonumber(copper) or 0)
    if not exact and copper >= 10000 then
        copper = copper - copper % 100
    end
    if GetMoneyString then
        local ok, s = pcall(GetMoneyString, copper, true)
        if ok and type(s) == "string" then
            return s
        end
    end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then
        return c > 0 and string.format("%dg %ds %dc", g, s, c) or string.format("%dg %ds", g, s)
    elseif s > 0 then
        return string.format("%ds %dc", s, c)
    end
    return c .. "c"
end

-- "You", "Tom", "Tom (your alt)".
local function Who(key)
    if key == ns.me then
        return "You"
    end
    local p = ns.db.people[key]
    if p and p.mine then
        return ns.ShortName(key) .. " (your alt)"
    end
    return ns.ShortName(key)
end

-- "Tom 20 (15 in bank)"
local function HolderText(h)
    local text = Who(h.key) .. " " .. (h.bags + h.bank)
    if h.bank > 0 then
        text = text .. " (" .. h.bank .. " in bank)"
    end
    return text
end

local function JoinHolders(list, limit)
    local parts = {}
    for i, h in ipairs(list) do
        if limit and i > limit then
            parts[#parts + 1] = "+" .. (#list - limit) .. " more"
            break
        end
        parts[#parts + 1] = HolderText(h)
    end
    return table.concat(parts, ", ")
end

-- Text in dark ink, without the drop shadow (it smudges on parchment).
local function Ink(parent, template, text, color)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    local c = color or INK
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetShadowOffset(0, 0)
    return fs
end

local function Input(parent, width, placeholder)
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    e:SetSize(width, 24)
    e:SetAutoFocus(false)
    e:SetFontObject(ChatFontNormal)
    e:SetTextColor(INK[1], INK[2], INK[3])
    e:SetTextInsets(8, 8, 0, 0)
    if e.SetBackdrop then
        e:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        e:SetBackdropColor(0.99, 0.95, 0.85, 0.9)
        e:SetBackdropBorderColor(0.35, 0.25, 0.15, 1)
    end
    local hint = Ink(e, "GameFontHighlight", placeholder, INK_DIM)
    hint:SetPoint("LEFT", 9, 0)
    local function UpdateHint()
        hint:SetShown(e:GetText() == "" and not e:HasFocus())
    end
    e:SetScript("OnEditFocusGained", UpdateHint)
    e:SetScript("OnEditFocusLost", UpdateHint)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e.UpdateHint = UpdateHint
    return e
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-------------------------------------------------------------------------------
-- The book
-------------------------------------------------------------------------------

local window, tabs, currentTab, prevButton, nextButton, leftNumber, rightNumber
local pages = {}

-- One page of the drawn book: parchment with a shade toward the spine.
-- Everything is painted on the window itself, so it always stays under
-- the text and buttons.
local function DrawnPage(x, isLeft)
    local paper = window:CreateTexture(nil, "BACKGROUND", nil, 1)
    paper:SetPoint("TOPLEFT", x, -HEAD_H)
    paper:SetSize(PW, PAGE_H)
    paper:SetColorTexture(0.93, 0.86, 0.70, 1)
    local shade = window:CreateTexture(nil, "BACKGROUND", nil, 2)
    shade:SetSize(40, PAGE_H)
    shade:SetPoint("TOPLEFT", isLeft and (x + PW - 40) or x, -HEAD_H)
    shade:SetColorTexture(0.35, 0.24, 0.12, 0.25)
    if shade.SetGradient and CreateColor then
        local dark, clear = CreateColor(0.35, 0.24, 0.12, 0.45), CreateColor(0.35, 0.24, 0.12, 0)
        shade:SetColorTexture(1, 1, 1, 1)
        if not pcall(shade.SetGradient, shade, "HORIZONTAL", isLeft and clear or dark, isLeft and dark or clear) then
            shade:SetColorTexture(0.35, 0.24, 0.12, 0.25)
        end
    end
end

local function BuildArt()
    local useAtlas = AtlasInfo(ART.left)
    if useAtlas then
        local l = window:CreateTexture(nil, "BACKGROUND")
        l:SetPoint("TOPLEFT", 0, -HEAD_H)
        l:SetSize(PW, PAGE_H)
        l:SetAtlas(ART.left)
        local r = window:CreateTexture(nil, "BACKGROUND")
        r:SetPoint("TOPLEFT", PW, -HEAD_H)
        r:SetSize(PW, PAGE_H)
        -- The left page mirrored: the game's right page has a flourish at
        -- the top that runs into the text.
        MirrorAtlas(r, ART.left)
        r:SetSize(PW, PAGE_H)
    else
        -- Leather cover a little larger than the pages.
        local cover = window:CreateTexture(nil, "BACKGROUND", nil, -2)
        cover:SetPoint("TOPLEFT", -8, -HEAD_H + 8)
        cover:SetPoint("BOTTOMRIGHT", 8, -8)
        cover:SetColorTexture(0.28, 0.15, 0.07, 1)
        DrawnPage(0, true)
        DrawnPage(PW, false)
    end
end

-- Page-turn arrows: the spellbook's own buttons, or plain < > in ink.
local function Arrow(dir, onClick)
    local b = CreateFrame("Button", nil, window)
    b:SetSize(28, 28)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. (dir < 0 and "PrevPage" or "NextPage")
    local test = b:CreateTexture(nil, "ARTWORK")
    if UseFile(test, base .. "-Up") then
        test:SetAllPoints()
        b:SetNormalTexture(test)
        b:SetPushedTexture(base .. "-Down")
        b:SetDisabledTexture(base .. "-Disabled")
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    else
        test:Hide()
        local fs = Ink(b, "GameFontNormalLarge", dir < 0 and "<" or ">")
        fs:SetPoint("CENTER")
    end
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(dir < 0 and "Previous page" or "Next page", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function SetArrow(b, on)
    b:SetEnabled(on)
    b:SetAlpha(on and 1 or 0.35)
end

-- Page numbers and arrows for the list on the open tab.
local function UpdateFooter(list)
    local spread = list and list.spread or 0
    if not list then
        leftNumber:SetText("")
        rightNumber:SetText("")
    elseif list.single then
        local total = math.max(1, math.ceil(#list.items / list.perSpread))
        leftNumber:SetText("")
        rightNumber:SetText(total > 1 and ("Page " .. (spread + 1) .. " of " .. total) or "")
    else
        leftNumber:SetText("Page " .. (spread * 2 + 1))
        rightNumber:SetText("Page " .. (spread * 2 + 2))
    end
    SetArrow(prevButton, spread > 0)
    SetArrow(nextButton, list ~= nil and (spread + 1) * list.perSpread < #list.items)
end

local function TurnPage(delta)
    local page = pages[currentTab]
    local list = page and page.list
    if not list then
        return
    end
    local last = math.max(0, math.ceil(#list.items / list.perSpread) - 1)
    local spread = math.max(0, math.min(last, list.spread + delta))
    if spread ~= list.spread then
        list.spread = spread
        list:Draw()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_ABILITY_PAGE_TURN then
            pcall(PlaySound, SOUNDKIT.IG_ABILITY_PAGE_TURN)
        end
    end
end

-- A tab is one opened spread: page.left and page.right are the two pages.
local function NewPage(key, leftTitle, rightTitle)
    local page = { key = key }
    page.frame = CreateFrame("Frame", nil, window)
    page.frame:SetAllPoints()
    page.frame:Hide()
    for side = 1, 2 do
        local f = CreateFrame("Frame", nil, page.frame)
        f:SetPoint("TOPLEFT", (side == 1 and 0 or PW) + INSET_X, -HEAD_H)
        f:SetSize(CONTENT_W, PAGE_H)
        f:EnableMouseWheel(true)
        f:SetScript("OnMouseWheel", function(_, delta) TurnPage(delta > 0 and -1 or 1) end)
        local title = side == 1 and leftTitle or rightTitle
        f.heading = false
        if title then
            local h = Ink(f, "GameFontNormalLarge", title)
            h:SetPoint("TOPLEFT", 0, HEADING_Y)
            f.heading = h
        end
        if side == 1 then page.left = f else page.right = f end
    end
    pages[key] = page
    return page
end

-- A short note at the top of the right page, under its heading and clear
-- of the corner art. At most two lines, so it never runs into the list.
local function Status(page)
    local fs = Ink(page.right, "GameFontHighlight", "", INK_DIM)
    fs:SetPoint("TOPLEFT", 0, CONTROLS_Y + 2)
    fs:SetWidth(CONTENT_W)
    fs:SetWordWrap(true)
    if fs.SetMaxLines then
        fs:SetMaxLines(2)
    end
    return fs
end

-------------------------------------------------------------------------------
-- Lists. item = { text, color, indent, tooltip = fn(tt), onClick = fn(button) }
-------------------------------------------------------------------------------

local function RowScripts(row)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(0.45, 0.30, 0.10, 0.15)
    row:SetScript("OnEnter", function(self)
        if self.item and self.item.tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            self.item.tooltip(GameTooltip)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self, button)
        if self.item and self.item.onClick then
            self.item.onClick(button or "LeftButton")
        end
    end)
end

-- Fills the left page, then the right page, then turns to the next spread.
local function FlowList(page)
    local list = { items = {}, spread = 0, rows = {} }
    local perPage = math.floor(LIST_H / ROW_H)
    for side = 1, 2 do
        local parent = side == 1 and page.left or page.right
        for i = 1, perPage do
            local row = CreateFrame("Button", nil, parent)
            row:SetSize(CONTENT_W, ROW_H)
            row:SetPoint("TOPLEFT", 0, -(LIST_TOP + (i - 1) * ROW_H))
            row.text = Ink(row, "GameFontHighlight")
            row.text:SetPoint("LEFT", 2, 0)
            row.text:SetPoint("RIGHT", -2, 0)
            row.text:SetWordWrap(false)
            row.item = false
            RowScripts(row)
            list.rows[#list.rows + 1] = row
        end
    end
    list.perSpread = #list.rows

    function list:Draw()
        local first = self.spread * self.perSpread
        for i, row in ipairs(self.rows) do
            local item = self.items[first + i]
            row.item = item or false
            if item then
                row.text:SetPoint("LEFT", 2 + (item.indent or 0), 0)
                row.text:SetText(item.text or "")
                local c = item.color or INK
                row.text:SetTextColor(c[1], c[2], c[3])
                row:Show()
            else
                row:Hide()
            end
        end
        UpdateFooter(self)
    end

    function list:SetItems(items)
        self.items = items
        local last = math.max(0, math.ceil(#items / self.perSpread) - 1)
        self.spread = math.min(self.spread, last)
        self:Draw()
    end
    page.list = list
    return list
end

-------------------------------------------------------------------------------
-- Crew: a ledger across both pages, one line per character.
--   left page:  class icon, online mark, name, gold
--   right page: profession icons with skill (hover for details)
-------------------------------------------------------------------------------

local function ProfTooltip(slot)
    local e, p = slot.entry, slot.person
    if not e then
        return
    end
    GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
    GameTooltip:SetText(e.name, 1, 1, 1)
    GameTooltip:AddLine(string.format("Skill %d / %d", e.rank, e.max), INFO[1], INFO[2], INFO[3])
    local hint = ns.ProfessionHint(e, p and p.level)
    if hint then
        GameTooltip:AddLine(hint, GOOD[1], GOOD[2], GOOD[3], true)
    end
    local recipes = p and p.recipes and p.recipes[e.name]
    if recipes then
        local n = 0
        for _ in pairs(recipes) do n = n + 1 end
        GameTooltip:AddLine(n .. " recipes shared (see the Recipes tab)", 0.8, 0.8, 0.8)
    elseif slot.key == ns.me then
        GameTooltip:AddLine("Open this profession window once to share your recipes.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
end

local function CrewRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(PW + CONTENT_W, CREW_ROW_H)
    row.item = false
    RowScripts(row)
    row.class = row:CreateTexture(nil, "ARTWORK")
    row.class:SetSize(18, 18)
    row.class:SetPoint("LEFT", 0, 0)
    row.online = row:CreateTexture(nil, "ARTWORK")
    row.online:SetSize(12, 12)
    row.online:SetPoint("LEFT", 21, 0)
    if not UseFile(row.online, "Interface\\FriendsFrame\\StatusIcon-Online") then
        row.online:SetColorTexture(0.1, 0.6, 0.1, 1)
        row.online:SetSize(7, 7)
    end
    row.name = Ink(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", 36, 0)
    row.name:SetWidth(CONTENT_W - 36 - GOLD_W - 4)
    row.name:SetWordWrap(false)
    row.gold = Ink(row, "GameFontHighlight")
    row.gold:SetJustifyH("RIGHT")
    row.gold:SetPoint("RIGHT", row, "LEFT", CONTENT_W, 0)
    row.gold:SetWidth(GOLD_W)
    row.slots = {}
    local slotW = math.floor(CONTENT_W / SLOTS)
    for i = 1, SLOTS do
        local s = CreateFrame("Button", nil, row)
        s:SetSize(20, 20)
        s:SetPoint("LEFT", PW + (i - 1) * slotW, 0)
        s.entry = false
        s.icon = s:CreateTexture(nil, "ARTWORK")
        s.icon:SetAllPoints()
        s.num = Ink(s, "GameFontHighlight")
        s.num:SetPoint("LEFT", s, "RIGHT", 3, 0)
        -- "!" = can learn the next rank (a mark, not just a color)
        s.mark = Ink(s, "GameFontNormal", "!", INK_GOOD)
        s.mark:SetPoint("LEFT", s.num, "RIGHT", 1, 0)
        s:RegisterForClicks("RightButtonUp")
        s:SetScript("OnEnter", ProfTooltip)
        s:SetScript("OnLeave", function() GameTooltip:Hide() end)
        s:SetScript("OnClick", function(_, button)
            if row.item and row.item.onClick then
                row.item.onClick(button or "RightButton")
            end
        end)
        row.slots[i] = s
    end
    return row
end

local function FillCrewRow(row, item)
    local p, key = item.person, item.key
    SetClassIcon(row.class, p.class)
    row.online:SetShown(item.online)
    row.name:SetText(item.name)
    local c = item.hidden and INK_DIM or INK
    row.name:SetTextColor(c[1], c[2], c[3])
    row.gold:SetText(p.money and p.money > 0 and MoneyText(p.money) or "")
    local profs = p.prof or {}
    for i, s in ipairs(row.slots) do
        local e = profs[i]
        s.entry, s.person, s.key = e or false, p, key
        if e then
            s.icon:SetTexture(ns.ProfIcon(e))
            s.num:SetText(e.rank)
            s.mark:SetShown(ns.TrainerNow(e, p.level))
            s:Show()
        else
            s:Hide()
        end
    end
end

local function CrewTooltip(tt, item)
    local p, key = item.person, item.key
    local r, g, b = ClassColor(p.class)
    tt:SetText(ns.LongName(key), r, g, b)
    if p.level and p.level > 0 then
        tt:AddLine("Level " .. p.level .. " " .. ClassName(p.class), 1, 1, 1)
    end
    if key == ns.me then
        tt:AddLine("This is you", INFO[1], INFO[2], INFO[3])
    elseif item.online then
        tt:AddLine("Online now", GOOD[1], GOOD[2], GOOD[3])
    elseif p.mine then
        tt:AddLine("Your alt, last played " .. ns.Ago(p.seen), INFO[1], INFO[2], INFO[3])
    elseif not p.rev or not next(p.rev) then
        tt:AddLine("Waiting for their data", 0.8, 0.8, 0.8)
    else
        tt:AddLine("Offline, last seen " .. ns.Ago(p.seen), 0.8, 0.8, 0.8)
    end
    if p.money and p.money > 0 then
        tt:AddLine("Gold: " .. MoneyText(p.money, true), 1, 1, 1)
    end
    if not p.prof or #p.prof == 0 then
        tt:AddLine("No professions shared yet", 0.8, 0.8, 0.8)
    end
    if key ~= ns.me then
        if item.hidden then
            tt:AddLine("Hidden: they get none of your data.", 0.8, 0.8, 0.8)
            tt:AddLine("Right-click to show again.", 1, 0.82, 0)
        else
            tt:AddLine("Right-click to hide (asks first).", 1, 0.82, 0)
        end
    end
end

-- Hiding asks first, so a stray right-click does nothing.
local function AskToHide(key)
    local p = ns.db.people[key]
    local text
    if p and p.mine then
        text = "Hide your alt " .. ns.LongName(key) .. " from the book?\n\nUse \"Show hidden\" on the Crew page to bring it back."
    else
        text = "Hide " .. ns.LongName(key) .. "?\n\nThey leave your book and stop getting your data. Use \"Show hidden\" on the Crew page to bring them back."
    end
    if not StaticPopup_Show or not StaticPopupDialogs then
        ns.SetHidden(key, true)
        return
    end
    StaticPopupDialogs.FRIENDSCRAFT_HIDE = StaticPopupDialogs.FRIENDSCRAFT_HIDE or {
        text = "%s",
        button1 = "Hide",
        button2 = "Cancel",
        OnAccept = function(_, data)
            if data then
                ns.SetHidden(data, true)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("FRIENDSCRAFT_HIDE", text, nil, key)
end

local function BuildCrewPage()
    local page = NewPage("crew", "Crew", "Professions")
    page.filter = Input(page.left, CONTENT_W, "Filter by name or profession")
    page.filter:SetPoint("TOPLEFT", 0, CONTROLS_Y)
    page.filter:SetScript("OnTextChanged", function(self)
        self.UpdateHint()
        page.list.spread = 0
        page:Refresh()
    end)
    page.status = Status(page)
    page.hiddenButton = Button(page.right, "Show hidden", 128, function()
        page.showHidden = not page.showHidden
        page:Refresh()
    end)
    page.hiddenButton:SetPoint("TOPRIGHT", 0, HEADING_Y + 2)
    page.legend = Ink(page.right, "GameFontHighlightSmall", "! = can learn the next rank at a trainer", INK_DIM)
    page.legend:SetPoint("TOPLEFT", 0, -(LIST_TOP + LIST_H + 2))

    local list = { items = {}, spread = 0, rows = {}, single = true }
    list.perSpread = math.floor(LIST_H / CREW_ROW_H)
    for i = 1, list.perSpread do
        local row = CrewRow(page.left)
        row:SetPoint("TOPLEFT", 0, -(LIST_TOP + (i - 1) * CREW_ROW_H))
        list.rows[i] = row
    end
    function list:Draw()
        local first = self.spread * self.perSpread
        for i, row in ipairs(self.rows) do
            local item = self.items[first + i]
            row.item = item or false
            if item then
                FillCrewRow(row, item)
                row:Show()
            else
                row:Hide()
            end
        end
        UpdateFooter(self)
    end
    function list:SetItems(items)
        self.items = items
        local last = math.max(0, math.ceil(#items / self.perSpread) - 1)
        self.spread = math.min(self.spread, last)
        self:Draw()
    end
    page.list = list

    local function Matches(key, p, text)
        if text == "" or ns.LongName(key):lower():find(text, 1, true) then
            return true
        end
        for _, e in ipairs(p.prof or {}) do
            if e.name:lower():find(text, 1, true) then
                return true
            end
        end
        return false
    end

    function page:Refresh()
        local text = strtrim(self.filter:GetText() or ""):lower()
        local friends, online, hiddenCount = 0, 0, 0
        for key in pairs(ns.db.crew) do
            friends = friends + 1
            if ns.online[key] then online = online + 1 end
        end
        for key in pairs(ns.db.hidden) do
            if ns.db.people[key] or ns.db.crew[key] then
                hiddenCount = hiddenCount + 1
            end
        end
        if hiddenCount == 0 then
            self.showHidden = false
        end
        self.hiddenButton:SetShown(hiddenCount > 0)
        self.hiddenButton:SetText(self.showHidden and "Hide them again" or ("Show hidden (" .. hiddenCount .. ")"))

        -- You first, then your alts, then friends online, then the rest.
        local function Rank(key)
            local p = ns.db.people[key]
            if key == ns.me then return 0 end
            if p and p.mine then return 1 end
            if ns.online[key] then return 2 end
            return 3
        end
        local keys = ns.VisiblePeople(self.showHidden)
        table.sort(keys, function(a, b)
            local ra, rb = Rank(a), Rank(b)
            if ra ~= rb then return ra < rb end
            return a < b
        end)
        local items = {}
        for _, key in ipairs(keys) do
            local p = ns.db.people[key] or { rev = {}, prof = {} }
            if Matches(key, p, text) then
                local hidden = ns.db.hidden[key] == true
                local item = {
                    key = key,
                    person = p,
                    online = key ~= ns.me and ns.online[key] == true,
                    hidden = hidden,
                    name = ns.LongName(key) .. (hidden and " (hidden)" or ""),
                }
                item.tooltip = function(tt) CrewTooltip(tt, item) end
                if key ~= ns.me then
                    item.onClick = function(button)
                        if button ~= "RightButton" then
                            return
                        end
                        GameTooltip:Hide()
                        if ns.db.hidden[key] then
                            ns.SetHidden(key, false)
                            page:Refresh()
                        else
                            AskToHide(key)
                        end
                    end
                end
                items[#items + 1] = item
            end
        end
        local anyHint = false
        for _, item in ipairs(items) do
            for _, e in ipairs(item.person.prof or {}) do
                if ns.TrainerNow(e, item.person.level) then anyHint = true end
            end
        end
        self.legend:SetShown(anyHint)
        if friends == 0 then
            self.status:SetText("No friends yet. Friends (press O) who have FriendsCraft show up here.")
        elseif #items == 0 then
            self.status:SetText("Nobody matches that filter.")
        else
            self.status:SetText(string.format("%d friend%s, %d online. Hover an icon for details.",
                friends, friends == 1 and "" or "s", online))
        end
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Recipes
-------------------------------------------------------------------------------

local function ReagentTooltip(tt, e)
    tt:SetText(e.name, 1, 1, 1)
    local makers = {}
    for _, c in ipairs(e.crafters) do
        makers[#makers + 1] = Who(c.key) .. " (" .. c.prof .. ")"
    end
    tt:AddLine("Can make it: " .. table.concat(makers, ", "), GOOD[1], GOOD[2], GOOD[3], true)
    local reagents = ns.Reagents(e.rid)
    if #reagents > 0 then
        tt:AddLine(" ")
        tt:AddLine("Materials:", 1, 0.82, 0)
        for _, r in ipairs(reagents) do
            local holders = ns.Holders(r.id)
            local who = #holders > 0 and JoinHolders(holders, 3) or "nobody in the crew has any"
            tt:AddLine(r.count .. " x " .. (ns.ItemName(r.id) or ("item " .. r.id)) .. ":  " .. who, 1, 1, 1, true)
        end
    end
end

-- One list on the right page only, turned with the arrows.
local function RightList(page)
    local list = { items = {}, spread = 0, rows = {}, single = true }
    list.perSpread = math.floor(LIST_H / ROW_H)
    for i = 1, list.perSpread do
        local row = CreateFrame("Button", nil, page.right)
        row:SetSize(CONTENT_W, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(LIST_TOP + (i - 1) * ROW_H))
        row.text = Ink(row, "GameFontHighlight")
        row.text:SetPoint("LEFT", 2, 0)
        row.text:SetPoint("RIGHT", -2, 0)
        row.text:SetWordWrap(false)
        row.item = false
        RowScripts(row)
        list.rows[i] = row
    end
    function list:Draw()
        local first = self.spread * self.perSpread
        for i, row in ipairs(self.rows) do
            local item = self.items[first + i]
            row.item = item or false
            if item then
                row.text:SetText(item.text or "")
                row:Show()
            else
                row:Hide()
            end
        end
        UpdateFooter(self)
    end
    function list:SetItems(items)
        self.items = items
        local last = math.max(0, math.ceil(#items / self.perSpread) - 1)
        self.spread = math.min(self.spread, last)
        self:Draw()
    end
    page.list = list
    return list
end

-- Icon for a profession name, from anyone who shares it.
local function ProfIconByName(name)
    for _, key in ipairs(ns.VisiblePeople()) do
        local p = ns.db.people[key]
        for _, e in ipairs(p and p.prof or {}) do
            if e.name == name then
                return ns.ProfIcon(e)
            end
        end
    end
    return 134400
end

local function IndexRow(parent, onClick)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(CONTENT_W, INDEX_H)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(0.45, 0.30, 0.10, 0.15)
    -- The chosen profession gets a shaded bar and a mark on the left,
    -- so it is not shown by color alone.
    row.chosen = row:CreateTexture(nil, "BACKGROUND")
    row.chosen:SetAllPoints()
    row.chosen:SetColorTexture(0.45, 0.30, 0.10, 0.22)
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetSize(3, INDEX_H)
    row.bar:SetPoint("LEFT")
    row.bar:SetColorTexture(INK[1], INK[2], INK[3], 1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 8, 0)
    row.name = Ink(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", 32, 0)
    row.count = Ink(row, "GameFontHighlight", "", INK_DIM)
    row.count:SetPoint("RIGHT", -4, 0)
    row.count:SetJustifyH("RIGHT")
    row.prof = false
    row:SetScript("OnClick", function(self)
        if self.prof then
            onClick(self.prof)
        end
    end)
    return row
end

local function BuildRecipesPage()
    local page = NewPage("recipes", "Recipes", "Recipes")
    page.search = Input(page.left, CONTENT_W, "Search all recipes, e.g. bandage")
    page.search:SetPoint("TOPLEFT", 0, CONTROLS_Y)
    page.search:SetScript("OnTextChanged", function(self)
        self.UpdateHint()
        page.list.spread = 0
        page:Refresh()
    end)
    page.status = Status(page)
    RightList(page)

    local function Choose(prof)
        page.chosen = prof
        page.search:SetText("")
        page.search:ClearFocus()
        page.search.UpdateHint()
        page.list.spread = 0
        page:Refresh()
    end
    page.index = {}
    for i = 1, math.floor(LIST_H / INDEX_H) do
        local row = IndexRow(page.left, Choose)
        row:SetPoint("TOPLEFT", 0, -(LIST_TOP + (i - 1) * INDEX_H))
        page.index[i] = row
    end

    -- "Tom, Mira" for the others who can make it; your own name is left out
    -- (hover shows everyone).
    local function Others(e)
        local names = {}
        for _, c in ipairs(e.crafters) do
            if c.key ~= ns.me then
                names[#names + 1] = Who(c.key)
            end
        end
        return #names > 0 and ("   " .. INK_DIM_HEX .. table.concat(names, ", ") .. "|r") or ""
    end

    function page:Refresh()
        local text = strtrim(self.search:GetText() or ""):lower()
        local all = ns.AllRecipes()
        -- Group by profession.
        local groups, order = {}, {}
        for _, e in ipairs(all) do
            local prof = e.crafters[1] and e.crafters[1].prof or "?"
            if not groups[prof] then
                groups[prof] = {}
                order[#order + 1] = prof
            end
            local g = groups[prof]
            g[#g + 1] = e
        end
        table.sort(order)
        if not groups[self.chosen] then
            self.chosen = order[1]
        end
        local searching = text ~= ""
        for i, row in ipairs(self.index) do
            local prof = order[i]
            row.prof = prof or false
            if prof then
                row.icon:SetTexture(ProfIconByName(prof))
                row.name:SetText(prof)
                row.count:SetText(#groups[prof])
                local on = not searching and prof == self.chosen
                row.chosen:SetShown(on)
                row.bar:SetShown(on)
                row:Show()
            else
                row:Hide()
            end
        end

        local source = {}
        if searching then
            for _, e in ipairs(all) do
                if e.name:lower():find(text, 1, true) then
                    source[#source + 1] = e
                end
            end
            self.right.heading:SetText("Search results")
        else
            source = groups[self.chosen] or {}
            self.right.heading:SetText(self.chosen or "Recipes")
        end
        local items = {}
        for _, e in ipairs(source) do
            items[#items + 1] = {
                text = e.name .. Others(e),
                tooltip = function(tt) ReagentTooltip(tt, e) end,
            }
        end
        if #all == 0 then
            self.status:SetText("No recipes yet. Open your profession windows once to share them.")
        elseif #items == 0 then
            self.status:SetText("No recipe matches that search.")
        else
            self.status:SetText("Hover a recipe to see its materials and who has them.")
        end
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Shopping list
-------------------------------------------------------------------------------

local function BuildShopPage()
    local page = NewPage("shop", "Shopping list")
    local addW, countW = 52, 74
    page.item = Input(page.left, CONTENT_W - addW - countW - 8, "Item, or shift-click")
    page.item:SetPoint("TOPLEFT", 0, CONTROLS_Y)
    page.count = Input(page.left, countW, "How many")
    page.count:SetPoint("LEFT", page.item, "RIGHT", 4, 0)
    page.count:SetNumeric(true)
    local add = Button(page.left, "Add", addW, function()
        local id = ns.FindItem(strtrim(page.item:GetText() or ""))
        local count = tonumber(page.count:GetText()) or 1
        if not id then
            ns.Print("could not find that item. Try shift-clicking it from your bags, a chat link or the auction house.")
            return
        end
        ns.SetNeed(id, math.max(1, math.min(count, 9999)))
        page.item:SetText("")
        page.count:SetText("")
        page.item:ClearFocus()
        page.count:ClearFocus()
        page.item.UpdateHint()
        page.count.UpdateHint()
    end)
    add:SetPoint("LEFT", page.count, "RIGHT", 4, 0)
    page.item:SetScript("OnEnterPressed", function() page.count:SetFocus() end)
    page.count:SetScript("OnEnterPressed", function() add:Click() end)
    page.item:SetScript("OnTextChanged", function(self) self.UpdateHint() end)
    page.count:SetScript("OnTextChanged", function(self) self.UpdateHint() end)
    page.status = Status(page)
    FlowList(page)
    ns.shopItemBox = page.item

    function page:Refresh()
        local entries = {}
        for _, key in ipairs(ns.VisiblePeople()) do
            local p = ns.db.people[key]
            for id, want in pairs(p and p.shop or {}) do
                entries[#entries + 1] = { key = key, id = id, want = want, name = ns.ItemName(id) or ("item " .. id) }
            end
        end
        table.sort(entries, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return a.key < b.key
        end)
        local items = {}
        for _, e in ipairs(entries) do
            local have, others = 0, {}
            for _, h in ipairs(ns.Holders(e.id)) do
                if h.key == e.key then
                    have = h.bags + h.bank
                else
                    others[#others + 1] = h
                end
            end
            local done = have >= e.want
            local text
            if done then
                text = string.format("%s: %d %s (done)", Who(e.key), e.want, e.name)
            else
                text = string.format("%s: %d %s (%d to go)", Who(e.key), e.want, e.name, e.want - have)
            end
            local mine = e.key == ns.me
            items[#items + 1] = {
                text = text,
                color = done and INK_GOOD or INK,
                tooltip = function(tt)
                    tt:SetText(e.name, 1, 1, 1)
                    tt:AddLine(Who(e.key) .. " wants " .. e.want .. ", has " .. have .. ".", 1, 1, 1)
                    if #others > 0 then
                        tt:AddLine("Others who have some: " .. JoinHolders(others), INFO[1], INFO[2], INFO[3], true)
                    end
                    local makers = ns.Crafters(e.id)
                    if #makers > 0 then
                        local names = {}
                        for _, m in ipairs(makers) do names[#names + 1] = Who(m.key) end
                        tt:AddLine("Can make it: " .. table.concat(names, ", "), GOOD[1], GOOD[2], GOOD[3], true)
                    end
                    if mine then
                        tt:AddLine("Click to take it off your list.", 1, 0.82, 0)
                    end
                end,
                onClick = mine and function(button)
                    if button == "LeftButton" then
                        GameTooltip:Hide()
                        ns.SetNeed(e.id, 0)
                    end
                end or nil,
            }
        end
        self.status:SetText(#items == 0
            and "Nothing on anyone's list yet. Friends see what you add."
            or "Hover an item to see who has some. Click your own item to remove it.")
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Who has it
-------------------------------------------------------------------------------

local function BuildFindPage()
    local page = NewPage("find", "Who has it")
    page.search = Input(page.left, CONTENT_W, "Search items, e.g. linen")
    page.search:SetPoint("TOPLEFT", 0, CONTROLS_Y)
    page.search:SetScript("OnTextChanged", function(self)
        self.UpdateHint()
        page.list.spread = 0
        page:Refresh()
    end)
    page.status = Status(page)
    FlowList(page)

    function page:Refresh()
        local text = strtrim(self.search:GetText() or ""):lower()
        local items = {}
        if #text >= 2 then
            local found = {}
            for _, id in ipairs(ns.KnownItemIDs()) do
                local name = ns.ItemName(id)
                if name and name:lower():find(text, 1, true) then
                    local holders = ns.Holders(id)
                    if #holders > 0 then
                        found[#found + 1] = { id = id, name = name, holders = holders }
                    end
                end
            end
            table.sort(found, function(a, b) return a.name < b.name end)
            for _, e in ipairs(found) do
                local total = 0
                for _, h in ipairs(e.holders) do total = total + h.bags + h.bank end
                items[#items + 1] = {
                    text = e.name .. "   " .. INK_DIM_HEX .. total .. " in the crew|r",
                    tooltip = function(tt)
                        tt:SetText(e.name, 1, 1, 1)
                        for _, h in ipairs(e.holders) do
                            tt:AddLine(HolderText(h), 1, 1, 1)
                        end
                    end,
                }
            end
            self.status:SetText(#items == 0 and "Nobody in the crew has that."
                or "Hover to see who has it. Banks update on each bank visit.")
        else
            self.status:SetText("Type at least 2 letters of an item name.")
        end
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local function Checkbox(parent, label, note, get, set)
    local ok, b = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if not ok or not b then
        b = CreateFrame("CheckButton", nil, parent)
        b:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        b:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        b:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        b:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    end
    b:SetSize(26, 26)
    b.label = Ink(b, "GameFontHighlight", label)
    b.label:SetPoint("LEFT", b, "RIGHT", 4, 1)
    b.note = Ink(b, "GameFontHighlightSmall", note, INK_DIM)
    b.note:SetPoint("TOPLEFT", b.label, "BOTTOMLEFT", 0, -3)
    b.note:SetWidth(CONTENT_W - 32)
    b.note:SetWordWrap(true)
    b:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            pcall(PlaySound, self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end
    end)
    b.Sync = function() b:SetChecked(get() and true or false) end
    return b
end

local function BuildSettingsPage()
    local page = NewPage("settings", "Settings", "Good to know")
    page.boxes = {
        Checkbox(page.left, "Minimap button", "The book button on the minimap. Without it, type /fc to open the book.",
            function() return not ns.db.minimap.hide end,
            function(on)
                ns.db.minimap.hide = not on
                ns.UpdateMinimapButton()
            end),
        Checkbox(page.left, "Crew lines on item tooltips", "\"Crew has\", \"needs\" and \"can make it\" when you hover an item.",
            function() return ns.db.tooltips end,
            function(on) ns.db.tooltips = on end),
    }
    for i, b in ipairs(page.boxes) do
        b:SetPoint("TOPLEFT", 0, CONTROLS_Y - (i - 1) * 56)
    end
    local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    if type(version) == "string" and version ~= "" then
        local v = Ink(page.left, "GameFontHighlightSmall", "FriendsCraft " .. version, INK_DIM)
        v:SetPoint("TOPLEFT", 0, -(LIST_TOP + LIST_H))
    end
    local notes = Ink(page.right, "GameFontHighlight", table.concat({
        "Hidden people: on the Crew page, click \"Show hidden\" to see them and right-click to bring them back.",
        "Recipes: open each profession window once so your recipes are shared.",
        "Bank: updates when you visit a bank.",
        "Type /fc to open the book from anywhere.",
    }, "\n\n"), INK)
    notes:SetPoint("TOPLEFT", 0, CONTROLS_Y)
    notes:SetWidth(CONTENT_W)
    notes:SetWordWrap(true)

    function page:Refresh()
        for _, b in ipairs(self.boxes) do
            b.Sync()
        end
        UpdateFooter(nil)
    end
    return page
end

-------------------------------------------------------------------------------
-- Window and tabs
-------------------------------------------------------------------------------

local function ShowTab(name)
    currentTab = name
    for key, page in pairs(pages) do
        page.frame:SetShown(key == name)
    end
    for _, t in ipairs(tabs) do
        -- The open tab gets the glowing frame.
        t.selected:SetShown(t.key == name)
    end
    ns.RefreshUI(true)
end

-- A square icon tab on the left side of the book, like the game's own
-- side tabs. Hover shows its name.
local function Tab(key, text, icon)
    local b = CreateFrame("Button", nil, window)
    b.key = key
    b.tabName = text
    b:SetSize(43, 55)
    b:SetScale(0.8) -- a bit smaller than the game's own side tabs
    local useAtlas = AtlasInfo(ART.tab) and AtlasInfo(ART.tabSelected)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("CENTER")
    if useAtlas then
        MirrorAtlas(bg, ART.tab)
    else
        bg:SetSize(40, 44)
        bg:SetColorTexture(0.12, 0.08, 0.04, 0.95)
    end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(42, 42) -- fills the opening inside the tab frame
    b.icon:SetPoint("CENTER", 1, 0)
    if not UseFile(b.icon, "Interface\\Icons\\" .. icon) then
        b.icon:SetTexture(134400)
    end
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.selected = b:CreateTexture(nil, "OVERLAY")
    b.selected:SetPoint("CENTER")
    if useAtlas then
        MirrorAtlas(b.selected, ART.tabSelected)
    else
        b.selected:SetSize(44, 48)
        b.selected:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        b.selected:SetBlendMode("ADD")
    end
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("CENTER")
    if useAtlas and AtlasInfo(ART.tabHover) then
        MirrorAtlas(hl, ART.tabHover)
    else
        hl:SetSize(40, 44)
        hl:SetColorTexture(1, 1, 1, 0.12)
    end
    b:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
            pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB)
        end
        ShowTab(key)
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(text, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function BuildWindow()
    Layout()
    window = CreateFrame("Frame", "FriendsCraftFrame", UIParent)
    window:SetSize(PW * 2, HEAD_H + PAGE_H)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    window:SetClampRectInsets(48, -36, 0, 0) -- keep the side tabs and close button on screen
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:Hide()
    tinsert(UISpecialFrames, "FriendsCraftFrame") -- Escape closes it
    BuildArt()

    -- Close button just outside the top right corner of the book.
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPLEFT", window, "TOPRIGHT", 4, -2)

    tabs = {}
    local defs = {
        { key = "crew", text = "Crew", icon = "Achievement_GuildPerk_EverybodysFriend" },
        { key = "recipes", text = "Recipes", icon = "INV_Scroll_03" },
        { key = "shop", text = "Shopping list", icon = "INV_Misc_Note_06" },
        { key = "find", text = "Who has it", icon = "INV_Misc_Bag_08" },
        { key = "settings", text = "Settings", icon = "INV_Misc_Gear_01" },
    }
    for i, d in ipairs(defs) do
        local b = Tab(d.key, d.text, d.icon)
        b:SetPoint("TOPRIGHT", window, "TOPLEFT", 0, -24 - (i - 1) * 52)
        tabs[i] = b
    end

    prevButton = Arrow(-1, function() TurnPage(-1) end)
    prevButton:SetPoint("BOTTOMLEFT", INSET_X, 14)
    nextButton = Arrow(1, function() TurnPage(1) end)
    nextButton:SetPoint("BOTTOMRIGHT", -INSET_X, 14)
    prevButton:SetFrameLevel(window:GetFrameLevel() + 10)
    nextButton:SetFrameLevel(window:GetFrameLevel() + 10)
    leftNumber = Ink(window, "GameFontHighlightSmall", "", INK_DIM)
    leftNumber:SetPoint("BOTTOM", window, "BOTTOMLEFT", PW / 2, 22)
    rightNumber = Ink(window, "GameFontHighlightSmall", "", INK_DIM)
    rightNumber:SetPoint("BOTTOM", window, "BOTTOMLEFT", PW * 1.5, 22)

    BuildCrewPage()
    BuildRecipesPage()
    BuildShopPage()
    BuildFindPage()
    BuildSettingsPage()
    window:SetScript("OnShow", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_SPELLBOOK_OPEN then
            pcall(PlaySound, SOUNDKIT.IG_SPELLBOOK_OPEN)
        end
        ns.RefreshUI(true)
    end)
    window:SetScript("OnHide", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_SPELLBOOK_CLOSE then
            pcall(PlaySound, SOUNDKIT.IG_SPELLBOOK_CLOSE)
        end
    end)
    ShowTab("crew")
end

function ns.ToggleWindow()
    if not window then
        BuildWindow()
    end
    window:SetShown(not window:IsShown())
end

function ns.OpenSettings()
    if not window then
        BuildWindow()
    end
    window:Show()
    ShowTab("settings")
end

-- Redraws the open tab; many updates in a row are merged into one.
local refreshQueued = false
function ns.RefreshUI(now)
    if not window or not window:IsShown() or not currentTab then
        return
    end
    if now then
        pages[currentTab]:Refresh()
        return
    end
    if refreshQueued then
        return
    end
    refreshQueued = true
    C_Timer.After(0.3, ns.Safe(function()
        refreshQueued = false
        if window:IsShown() and currentTab then
            pages[currentTab]:Refresh()
        end
    end, "window"))
end

-- Item names arrive from the server a moment after we ask.
ns.On("GET_ITEM_INFO_RECEIVED", function() ns.RefreshUI() end)

-- Shift-clicking an item while our item box has focus puts it there.
local function OnInsertLink(link)
    local box = ns.shopItemBox
    if box and box:HasFocus() and type(link) == "string" then
        box:SetText(link)
        box:SetCursorPosition(0)
    end
end
if ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
end
if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
end

-------------------------------------------------------------------------------
-- Item tooltips: crew info on every item, anywhere in the game
-------------------------------------------------------------------------------

local function AddCrewLines(tooltip, itemID)
    if not ns.db or not ns.me or not itemID or ns.db.tooltips == false then
        return
    end
    local holders = ns.Holders(itemID)
    local needs = ns.Needs(itemID)
    local makers = ns.Crafters(itemID)
    if #holders == 0 and #needs == 0 and #makers == 0 then
        return
    end
    tooltip:AddLine(" ")
    if #holders > 0 then
        tooltip:AddLine("Crew has: " .. JoinHolders(holders, 4), INFO[1], INFO[2], INFO[3], true)
    end
    for _, n in ipairs(needs) do
        local left = n.count - n.have
        if left > 0 then
            tooltip:AddLine(Who(n.key) .. " needs " .. left .. " more", 1, 0.82, 0, true)
        end
    end
    if #makers > 0 then
        local names, seen = {}, {}
        for _, m in ipairs(makers) do
            if not seen[m.key] then
                seen[m.key] = true
                names[#names + 1] = Who(m.key)
            end
        end
        tooltip:AddLine("Can make it: " .. table.concat(names, ", "), GOOD[1], GOOD[2], GOOD[3], true)
    end
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
            return
        end
        local id = data and data.id
        if id and not ns.IsSecret(id) then
            pcall(AddCrewLines, tooltip, id)
        end
    end)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        local id = link and tonumber(link:match("item:(%d+)"))
        pcall(AddCrewLines, tooltip, id)
    end)
end

-------------------------------------------------------------------------------
-- Minimap button (drag it around the edge)
-------------------------------------------------------------------------------

local function PlaceMinimapButton(b)
    local angle = math.rad(ns.db.minimap.angle or 215)
    local radius = (Minimap:GetWidth() / 2) + 10
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
    local b = CreateFrame("Button", "FriendsCraftMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    -- Golden libram (the user's pick); the plain book if this game lacks it.
    if not UseFile(icon, "Interface\\Icons\\INV_Relics_LibramOfHope") then
        icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    end
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function() ns.ToggleWindow() end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PlaceMinimapButton(self)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("FriendsCraft", 1, 1, 1)
        GameTooltip:AddLine("Click to open. Drag to move.", INFO[1], INFO[2], INFO[3])
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimapButton(b)
    return b
end

-- Shows or hides the minimap button to match the setting.
function ns.UpdateMinimapButton()
    if not Minimap or not ns.db then
        return
    end
    local b = FriendsCraftMinimapButton
    if ns.db.minimap.hide then
        if b then
            b:Hide()
        end
        return
    end
    if not b then
        b = BuildMinimapButton()
    end
    b:Show()
end

ns.On("FC_READY", function() ns.UpdateMinimapButton() end)
