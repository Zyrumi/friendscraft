-- FriendsCraft: the main window, minimap button and item tooltips.
-- The window uses the game's own panel frame (with a round portrait) when
-- the game has it, and a plain dark panel otherwise. Pages are picked with
-- icon tabs on the left side, like the game's own side tabs. The window can
-- be moved and resized; lists scroll.

local ADDON_NAME, ns = ...

-------------------------------------------------------------------------------
-- Sizes and colors
-------------------------------------------------------------------------------

local ROW_H = 22            -- list rows
local DEFAULT_W, DEFAULT_H = 780, 500
local MIN_W, MIN_H = 640, 380
local MAX_W, MAX_H = 1400, 1000
local NAME_W = 236          -- crew: chevron, online mark, class icon, name, faction
local LEVEL_W = 44
local GOLD_W = 96
local SLOT_W = 50           -- one profession icon with its skill
local PRIM_SLOTS = 4        -- primary professions shown per row ("+N" when more)
-- Secondary professions get fixed columns, so they line up on every row.
local SECONDARY = {
    { line = 185, name = "Cooking", icon = "Interface\\Icons\\INV_Misc_Food_15" },
    { line = 129, name = "First Aid", icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
    { line = 356, name = "Fishing", icon = "Interface\\Icons\\Trade_Fishing" },
}
local PRIM_X = NAME_W + LEVEL_W + GOLD_W + 16
local SEC_X = PRIM_X + PRIM_SLOTS * SLOT_W + 12
local BASE_SCALE = 1.15     -- text and rows at the default window height
local MAX_SCALE = 1.9       -- taller windows grow the text up to this
local INDEX_W = 190         -- recipes: profession list
local ICON = "Interface\\Icons\\INV_Relics_LibramOfHope"

local ART = {
    tab = "common-sidetab",
    tabSelected = "common-sidetab-selected",
    tabHover = "common-sidetab-hover",
}

-- Light text on the dark panel.
local INK = { 0.93, 0.91, 0.86 }
local INK_DIM = { 0.68, 0.64, 0.56 }
local INK_GOOD = { 0.45, 0.9, 0.45 }
local INK_DIM_HEX = "|cffada38f"
local GOLD = { 1, 0.82, 0 }
local INFO = { 0.5, 0.83, 1 }
local GOOD = { 0.4, 1, 0.4 }
local FADE = 0.5            -- characters of the other faction

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

-------------------------------------------------------------------------------
-- Building blocks
-------------------------------------------------------------------------------

local function Ink(parent, template, text, color)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    local c = color or INK
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- A text box in the game's own style, with a grey hint while empty.
local function Input(parent, width, placeholder)
    local ok, e = pcall(CreateFrame, "EditBox", nil, parent, "InputBoxTemplate")
    if not ok or not e then
        e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        if e.SetBackdrop then
            e:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            e:SetBackdropColor(0, 0, 0, 0.6)
            e:SetBackdropBorderColor(0.5, 0.45, 0.35, 1)
        end
        e:SetTextInsets(6, 6, 0, 0)
    end
    e:SetSize(width, 22)
    e:SetAutoFocus(false)
    e:SetFontObject(ChatFontNormal)
    e:SetTextColor(1, 1, 1)
    local hint = Ink(e, "GameFontHighlightSmall", placeholder, INK_DIM)
    hint:SetPoint("LEFT", 4, 0)
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

local function CheckButton(parent)
    local ok, b = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if not ok or not b then
        b = CreateFrame("CheckButton", nil, parent)
        b:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        b:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        b:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        b:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    end
    return b
end

local function CheckSound(on)
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        pcall(PlaySound, on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
end

-- A small tick box with a label, used for the filters.
local function Toggle(parent, label, get, set)
    local b = CheckButton(parent)
    b:SetSize(24, 24)
    b.label = Ink(b, "GameFontHighlightSmall", label)
    b.label:SetPoint("LEFT", b, "RIGHT", 0, 1)
    b:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        set(on)
        CheckSound(on)
    end)
    b.SyncFilter = function() b:SetChecked(get() and true or false) end
    return b
end

local function FactionTexture(tex, faction)
    if faction == "Alliance" or faction == "Horde" then
        if UseFile(tex, "Interface\\FriendsFrame\\PlusManz-" .. faction) then
            tex:Show()
            return true
        end
    end
    tex:Hide()
    return false
end

-------------------------------------------------------------------------------
-- Scrolling list: rows are made to fill the height; the mouse wheel and the
-- bar on the right scroll. item = { text, color, tooltip = fn(tt),
-- onClick = fn(button) } for text rows; crew rows use their own items.
-------------------------------------------------------------------------------

local function RowScripts(row)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.04)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    if UseFile(hl, "Interface\\QuestFrame\\UI-QuestTitleHighlight") then
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.6)
    else
        hl:SetColorTexture(1, 1, 1, 0.1)
    end
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

local function ScrollList(parent, rowH, makeRow, fillRow)
    local list = { rows = {}, items = {}, offset = 0, count = 0 }
    local f = CreateFrame("Frame", nil, parent)
    list.frame = f
    f:EnableMouseWheel(true)

    local bar = CreateFrame("Slider", nil, f)
    bar:SetWidth(10)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar:SetOrientation("VERTICAL")
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(0, 0, 0, 0.35)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.72, 0.64, 0.48, 0.85)
    thumb:SetSize(8, 30)
    bar:SetThumbTexture(thumb)
    list.thumb = thumb
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    list.bar = bar

    function list:Visible()
        local h = f:GetHeight()
        if type(h) ~= "number" or h <= 0 then
            h = 15 * rowH
        end
        return math.max(1, math.floor(h / rowH))
    end

    function list:Layout()
        self.count = self:Visible()
        for i = #self.rows + 1, self.count do
            local row = makeRow(f)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * rowH)
            row:SetPoint("RIGHT", bar, "LEFT", -4, 0)
            row:SetHeight(rowH)
            row.item = false
            self.rows[i] = row
        end
    end

    function list:Draw()
        for i, row in ipairs(self.rows) do
            local item = i <= self.count and self.items[self.offset + i]
            row.item = item or false
            if item then
                fillRow(row, item)
                if row.stripe then
                    row.stripe:SetShown((self.offset + i) % 2 == 0)
                end
                row:Show()
            else
                row:Hide()
            end
        end
        local max = math.max(0, #self.items - self.count)
        bar:SetMinMaxValues(0, max)
        bar:SetValue(self.offset)
        bar:SetShown(max > 0)
        local h = f:GetHeight()
        if max > 0 and type(h) == "number" and h > 0 then
            self.thumb:SetHeight(math.max(24, h * self.count / #self.items))
        end
    end

    function list:SetOffset(value)
        local max = math.max(0, #self.items - self.count)
        value = math.max(0, math.min(max, math.floor((value or 0) + 0.5)))
        if value ~= self.offset then
            self.offset = value
            self:Draw()
        end
    end

    function list:SetItems(items)
        self.items = items
        self:Layout()
        self.offset = math.max(0, math.min(self.offset, #items - self.count))
        self:Draw()
    end

    bar:SetScript("OnValueChanged", function(_, value) list:SetOffset(value) end)
    f:SetScript("OnMouseWheel", function(_, delta) list:SetOffset(list.offset + (delta > 0 and -3 or 3)) end)
    f:SetScript("OnSizeChanged", function() list:SetItems(list.items) end)
    return list
end

local function TextRow(parent)
    local row = CreateFrame("Button", nil, parent)
    RowScripts(row)
    row.text = Ink(row, "GameFontHighlight")
    row.text:SetPoint("LEFT", 6, 0)
    row.text:SetPoint("RIGHT", -4, 0)
    row.text:SetWordWrap(false)
    return row
end

local function FillTextRow(row, item)
    row.text:SetText(item.text or "")
    local c = item.color or INK
    row.text:SetTextColor(c[1], c[2], c[3])
end

-- The game's own search box (magnifier, grey hint, clear button); a plain
-- text box where the game doesn't have it.
local function SearchInput(parent, width, placeholder)
    local ok, e = pcall(CreateFrame, "EditBox", nil, parent, "SearchBoxTemplate")
    if not ok or not e or type(rawget(e, "Instructions")) ~= "table" then
        if ok and e then
            e:Hide()
        end
        return Input(parent, width, placeholder)
    end
    e:SetSize(width, 22)
    e:SetAutoFocus(false)
    e.Instructions:SetText(placeholder)
    e.UpdateHint = function()
        if SearchBoxTemplate_OnTextChanged then
            pcall(SearchBoxTemplate_OnTextChanged, e)
        end
    end
    return e
end

-- The game's own dropdown menu button (nil where the game has none).
-- generator(dropdown, root) fills the menu each time it opens.
local function Dropdown(parent, width, generator)
    if not MenuUtil then
        return nil
    end
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if not ok or not dd or type(rawget(dd, "SetupMenu")) ~= "function" then
        if ok and dd then
            dd:Hide()
        end
        return nil
    end
    dd:SetWidth(width)
    local okSetup = pcall(dd.SetupMenu, dd, generator)
    if not okSetup then
        dd:Hide()
        return nil
    end
    return dd
end

-- A column title in the style of the game's Who list.
local HEADER_H = 24
local function ColumnHeader(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, HEADER_H)
    local file = "Interface\\FriendsFrame\\WhoFrame-ColumnTabs"
    local left = b:CreateTexture(nil, "BACKGROUND")
    if UseFile(left, file) then
        left:SetTexCoord(0, 0.078125, 0, 0.75)
        left:SetSize(5, HEADER_H)
        left:SetPoint("TOPLEFT")
        local right = b:CreateTexture(nil, "BACKGROUND")
        UseFile(right, file)
        right:SetTexCoord(0.90625, 0.96875, 0, 0.75)
        right:SetSize(4, HEADER_H)
        right:SetPoint("TOPRIGHT")
        local mid = b:CreateTexture(nil, "BACKGROUND")
        UseFile(mid, file)
        mid:SetTexCoord(0.078125, 0.90625, 0, 0.75)
        mid:SetPoint("TOPLEFT", left, "TOPRIGHT")
        mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
    else
        left:SetAllPoints()
        left:SetColorTexture(1, 1, 1, 0.06)
    end
    if onClick then
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        if UseFile(hl, "Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight") then
            hl:SetBlendMode("ADD")
            hl:SetPoint("TOPLEFT", -2, 5)
            hl:SetPoint("BOTTOMRIGHT", 2, -7)
        else
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.08)
        end
        b:SetScript("OnClick", onClick)
    end
    b.label = Ink(b, "GameFontHighlightSmall", text or "")
    b.label:SetPoint("LEFT", 6, 1)
    return b
end

-- A gold heading line inside a list.
local function HeadingParts(row)
    row.hText = Ink(row, "GameFontNormal", "", GOLD)
    row.hText:SetPoint("BOTTOMLEFT", 6, 4)
    row.hRight = Ink(row, "GameFontHighlightSmall", "", INK_DIM)
    row.hRight:SetPoint("LEFT", row.hText, "RIGHT", 10, 0)
    row.hLine = row:CreateTexture(nil, "ARTWORK")
    row.hLine:SetHeight(1)
    row.hLine:SetPoint("BOTTOMLEFT", 4, 1)
    row.hLine:SetPoint("BOTTOMRIGHT", -4, 1)
    row.hLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
end

-- List row with an icon, a name and a dim note on the right; or a heading
-- (item.kind == "heading").
local function IconRow(parent)
    local row = CreateFrame("Button", nil, parent)
    RowScripts(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.right = Ink(row, "GameFontHighlightSmall", "", INK_DIM)
    row.right:SetPoint("RIGHT", -6, 0)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)
    row.text = Ink(row, "GameFontHighlight")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetPoint("RIGHT", row.right, "LEFT", -12, 0)
    row.text:SetWordWrap(false)
    HeadingParts(row)
    return row
end

local function FillIconRow(row, item)
    local heading = item.kind == "heading"
    row.hText:SetShown(heading)
    row.hRight:SetShown(heading)
    row.hLine:SetShown(heading)
    row.icon:SetShown(not heading)
    row.text:SetShown(not heading)
    row.right:SetShown(not heading)
    if row.stripe then
        row.stripe:SetAlpha(heading and 0 or 1)
    end
    if heading then
        row.hText:SetText(item.text or "")
        row.hRight:SetText(item.right or "")
        return
    end
    row.icon:SetTexture(item.icon or 134400)
    row.text:SetText(item.text or "")
    local c = item.color or INK
    row.text:SetTextColor(c[1], c[2], c[3])
    row.right:SetText(item.right or "")
end

-- Text color for an item's quality (white while unknown).
local function QualityColor(id)
    local q = ns.ItemQuality(id)
    local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if qc and qc.r then
        return { qc.r, qc.g, qc.b }
    end
    return INK
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local window, content, toolbar, tabs, currentTab
local pages = {}
local LIST_TOP = 0 -- where lists start inside a page (lower without the game's panel)

-- page.frame holds the page; page.bar is its strip of search boxes and
-- filters under the window title (where the game's own windows keep them).
local function NewPage(key)
    local page = { key = key }
    page.frame = CreateFrame("Frame", nil, content)
    page.frame:SetAllPoints()
    page.frame:Hide()
    page.bar = CreateFrame("Frame", nil, toolbar)
    page.bar:SetAllPoints()
    page.bar:Hide()
    pages[key] = page
    return page
end

-- A line of help text at the bottom of a page.
local function Status(page)
    local fs = Ink(page.frame, "GameFontHighlightSmall", "", INK_DIM)
    fs:SetPoint("BOTTOMLEFT", 4, 4)
    fs:SetPoint("RIGHT", -150, 0)
    fs:SetWordWrap(false)
    return fs
end

-------------------------------------------------------------------------------
-- Crew: everyone in one sortable table. A friend with several characters is
-- one line you can open (+) to see each character.
-------------------------------------------------------------------------------

local function ProfTooltip(slot)
    local e = slot.entry
    if not e then
        return
    end
    GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
    GameTooltip:SetText(e.name, 1, 1, 1)
    if slot.holders then
        -- A friend's line: everyone of theirs who has it, best first.
        for _, h in ipairs(slot.holders) do
            GameTooltip:AddLine(string.format("%s: %d / %d", ns.ShortName(h.key), h.rank, h.max), INFO[1], INFO[2], INFO[3])
        end
        GameTooltip:Show()
        return
    end
    local p = slot.person
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
    RowScripts(row)
    row.chevron = row:CreateTexture(nil, "ARTWORK")
    row.chevron:SetSize(14, 14)
    row.online = row:CreateTexture(nil, "ARTWORK")
    row.online:SetSize(12, 12)
    if not UseFile(row.online, "Interface\\FriendsFrame\\StatusIcon-Online") then
        row.online:SetColorTexture(0.1, 0.8, 0.1, 1)
        row.online:SetSize(7, 7)
    end
    row.class = row:CreateTexture(nil, "ARTWORK")
    row.class:SetSize(16, 16)
    row.name = Ink(row, "GameFontHighlight")
    row.name:SetWordWrap(false)
    row.faction = row:CreateTexture(nil, "ARTWORK")
    row.faction:SetSize(18, 18)
    row.faction:SetPoint("LEFT", NAME_W - 22, 0)
    row.level = Ink(row, "GameFontHighlight")
    row.level:SetPoint("LEFT", NAME_W, 0)
    row.level:SetWidth(LEVEL_W)
    row.gold = Ink(row, "GameFontHighlight")
    row.gold:SetJustifyH("RIGHT")
    row.gold:SetPoint("LEFT", NAME_W + LEVEL_W, 0)
    row.gold:SetWidth(GOLD_W)
    local function Slot(x)
        local s = CreateFrame("Button", nil, row)
        s:SetSize(18, 18)
        s:SetPoint("LEFT", x, 0)
        s.entry, s.person, s.holders = false, false, false
        s.icon = s:CreateTexture(nil, "ARTWORK")
        s.icon:SetAllPoints()
        s.num = Ink(s, "GameFontHighlightSmall")
        s.num:SetPoint("LEFT", s, "RIGHT", 3, 0)
        -- "!" = can learn the next rank (a mark, not just a color)
        s.mark = Ink(s, "GameFontNormal", "!", GOOD)
        s.mark:SetPoint("LEFT", s.num, "RIGHT", 1, 0)
        s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        s:SetScript("OnEnter", ProfTooltip)
        s:SetScript("OnLeave", function() GameTooltip:Hide() end)
        s:SetScript("OnClick", function(_, button)
            if row.item and row.item.onClick then
                row.item.onClick(button or "LeftButton")
            end
        end)
        return s
    end
    row.sec = {}
    for i = 1, #SECONDARY do
        row.sec[i] = Slot(SEC_X + (i - 1) * SLOT_W)
    end
    row.slots = {}
    for i = 1, PRIM_SLOTS do
        row.slots[i] = Slot(PRIM_X + (i - 1) * SLOT_W)
    end
    return row
end

local function SecondaryIndex(e)
    for i, sec in ipairs(SECONDARY) do
        if e.line == sec.line or e.name == sec.name then
            return i
        end
    end
    return nil
end

local function FillSlot(s, e, item, text)
    s.entry, s.person, s.key = e or false, item.person or false, item.key
    s.holders = item.holders and e and item.holders[e.name] or false
    if not e then
        s:Hide()
        return
    end
    s.icon:SetTexture(ns.ProfIcon(e))
    s.num:SetText(text or e.rank)
    s.mark:SetShown(not text and not item.group and ns.TrainerNow(e, item.person and item.person.level))
    s:Show()
end

local function FillCrewRow(row, item)
    local x = item.child and 18 or 0
    row.chevron:ClearAllPoints()
    row.chevron:SetPoint("LEFT", x + 2, 0)
    if item.group then
        UseFile(row.chevron, item.open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
        row.chevron:Show()
    else
        row.chevron:Hide()
    end
    row.online:ClearAllPoints()
    row.online:SetPoint("CENTER", row, "LEFT", x + 24, 0)
    row.online:SetShown(item.online)
    row.class:ClearAllPoints()
    row.class:SetPoint("LEFT", x + 32, 0)
    SetClassIcon(row.class, item.class)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", x + 52, 0)
    row.name:SetWidth(NAME_W - x - 52 - 24)
    row.name:SetText(item.name)
    local c = item.hidden and INK_DIM or (item.group and GOLD) or INK
    row.name:SetTextColor(c[1], c[2], c[3])
    -- The other faction: faded, with its crest so it is not shown by fading alone.
    row:SetAlpha(item.other and FADE or 1)
    if item.other then
        FactionTexture(row.faction, item.faction)
    else
        row.faction:Hide()
    end
    row.level:SetText(item.level and item.level > 0 and item.level or "")
    row.gold:SetText(item.gold and item.gold > 0 and MoneyText(item.gold) or "")
    -- Primary professions first, then the secondary ones in fixed columns.
    local sec, primary = {}, {}
    for _, e in ipairs(item.profs or {}) do
        local i = SecondaryIndex(e)
        if i then
            sec[i] = e
        else
            primary[#primary + 1] = e
        end
    end
    for i, s in ipairs(row.sec) do
        FillSlot(s, sec[i], item)
    end
    local fit = PRIM_SLOTS
    for i, s in ipairs(row.slots) do
        local e = i <= fit and primary[i] or nil
        local more = e and i == fit and #primary > fit and ("+" .. (#primary - fit + 1)) or nil
        FillSlot(s, e, item, more)
    end
end

local function CrewTooltip(tt, item)
    local p, key = item.person, item.key
    local r, g, b = ClassColor(p.class)
    tt:SetText(ns.LongName(key), r, g, b)
    if p.level and p.level > 0 then
        tt:AddLine("Level " .. p.level .. " " .. ClassName(p.class) .. (p.faction and (", " .. p.faction) or ""), 1, 1, 1)
    end
    if key == ns.me then
        tt:AddLine("This is you", INFO[1], INFO[2], INFO[3])
    elseif item.online then
        tt:AddLine("Online now", GOOD[1], GOOD[2], GOOD[3])
    elseif p.mine then
        tt:AddLine("Your alt, last played " .. ns.Ago(p.seen), INFO[1], INFO[2], INFO[3])
    elseif p.via then
        tt:AddLine("Shared by " .. ns.ShortName(p.via) .. " (same player)", 0.8, 0.8, 0.8)
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
    if not p.faction then
        tt:AddLine("Faction not known yet: it shows after this character's next login with FriendsCraft 0.3 or newer.", 0.8, 0.8, 0.8, true)
    end
    if item.hint then
        tt:AddLine(item.hint, 1, 0.82, 0, true)
    end
end

local function GroupTooltip(tt, item)
    tt:SetText(item.name, 1, 1, 1)
    tt:AddLine(string.format("%d characters, %d online", item.size, item.onlineCount), INFO[1], INFO[2], INFO[3])
    if item.gold and item.gold > 0 then
        tt:AddLine("Gold, all characters: " .. MoneyText(item.gold, true), 1, 1, 1)
    end
    for _, e in ipairs(item.profs) do
        tt:AddLine(string.format("%s %d / %d (%s)", e.name, e.rank, e.max, ns.ShortName(e.owner)), 0.9, 0.9, 0.9)
    end
    if item.hint then
        tt:AddLine(item.hint, 1, 0.82, 0, true)
    end
end

-- Hiding asks first, so a stray right-click does nothing.
local function AskToHide(key, label)
    local text
    local p = ns.db.people[key]
    if key:sub(1, 1) == "#" then
        text = "Hide " .. label .. " and all their characters?\n\nThey leave your list and stop getting your data. Use \"Show hidden\" on the Crew page to bring them back."
    elseif p and p.mine then
        text = "Hide your alt " .. ns.LongName(key) .. " from the list?\n\nUse \"Show hidden\" on the Crew page to bring it back."
    else
        text = "Hide " .. ns.LongName(key) .. "?\n\nThey leave your list and stop getting your data. Use \"Show hidden\" on the Crew page to bring them back."
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

-- Best skill in each profession over several characters.
local function BestProfs(keys)
    local best, holders = {}, {}
    for _, key in ipairs(keys) do
        local p = ns.db.people[key]
        for _, e in ipairs(p and p.prof or {}) do
            holders[e.name] = holders[e.name] or {}
            table.insert(holders[e.name], { key = key, rank = e.rank, max = e.max })
            if not best[e.name] or e.rank > best[e.name].rank then
                best[e.name] = { name = e.name, rank = e.rank, max = e.max, line = e.line, icon = e.icon, owner = key }
            end
        end
    end
    local list = {}
    for _, e in pairs(best) do
        list[#list + 1] = e
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.name < b.name
    end)
    for _, h in pairs(holders) do
        table.sort(h, function(a, b) return a.rank > b.rank end)
    end
    return list, holders
end

local function BuildCrewPage()
    local page = NewPage("crew")
    local view = ns.db.view
    view.sort = view.sort or "name"
    view.open = view.open or {}
    if view.alliance == nil then view.alliance = true end
    if view.horde == nil then view.horde = true end

    page.search = SearchInput(page.bar, 180, "Name or profession")
    page.search:SetPoint("LEFT", 8, 0)
    page.search:SetScript("OnTextChanged", function(self)
        self.UpdateHint()
        page.list.offset = 0
        page:Refresh()
    end)

    local function Redraw()
        page.list.offset = 0
        page:Refresh()
    end
    page.toggles = {
        Toggle(page.bar, "Online only", function() return view.onlineOnly end, function(on) view.onlineOnly = on; Redraw() end),
        Toggle(page.bar, "Alliance", function() return view.alliance end, function(on) view.alliance = on; Redraw() end),
        Toggle(page.bar, "Horde", function() return view.horde end, function(on) view.horde = on; Redraw() end),
    }
    page.toggles[1]:SetPoint("LEFT", page.search, "RIGHT", 14, 0)
    for i = 2, #page.toggles do
        page.toggles[i]:SetPoint("LEFT", page.toggles[i - 1].label, "RIGHT", 10, -1)
    end

    -- Profession filter: a menu where the game has one, otherwise each
    -- click picks the next profession.
    local function PickProf(name)
        page.prof = name
        Redraw()
    end
    page.profDrop = Dropdown(page.bar, 170, function(_, root)
        root:CreateRadio("Any profession", function() return page.prof == nil end, function() PickProf(nil) end)
        for _, name in ipairs(page.profNames or {}) do
            root:CreateRadio(name, function() return page.prof == name end, function() PickProf(name) end)
        end
    end)
    if page.profDrop then
        page.profDrop:SetPoint("LEFT", page.toggles[#page.toggles].label, "RIGHT", 16, 0)
    end
    page.profButton = not page.profDrop and Button(page.bar, "Profession: any", 160, function(self)
        local names = page.profNames or {}
        local function Pick(name)
            page.prof = name
            Redraw()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            local ok = pcall(MenuUtil.CreateContextMenu, self, function(_, root)
                root:CreateRadio("Any profession", function() return page.prof == nil end, function() Pick(nil) end)
                for _, name in ipairs(names) do
                    root:CreateRadio(name, function() return page.prof == name end, function() Pick(name) end)
                end
            end)
            if ok then
                return
            end
        end
        local nextName
        if page.prof == nil then
            nextName = names[1]
        else
            for i, name in ipairs(names) do
                if name == page.prof then nextName = names[i + 1] end
            end
        end
        Pick(nextName)
    end)
    if page.profButton then
        page.profButton:SetPoint("LEFT", page.toggles[#page.toggles].label, "RIGHT", 12, 0)
    end

    -- Column headers; click one to sort by it, again to flip the order.
    local header = CreateFrame("Frame", nil, page.frame)
    header:SetPoint("TOPLEFT", 0, LIST_TOP)
    header:SetPoint("RIGHT", -14, 0)
    header:SetHeight(HEADER_H)
    page.headers = {}
    local function Header(text, x, width, key)
        local b = ColumnHeader(header, text, width, key and function()
            if view.sort == key then
                view.desc = not view.desc
            else
                view.sort, view.desc = key, key ~= "name"
            end
            page:Refresh()
        end)
        b:SetPoint("LEFT", x, 0)
        b.sortKey = key
        page.headers[#page.headers + 1] = b
        return b
    end
    local nameHeader = Header("Name", 0, NAME_W, "name")
    nameHeader.label:SetPoint("LEFT", 30, 1)
    Header("Level", NAME_W, LEVEL_W, "level")
    local goldHeader = Header("Gold", NAME_W + LEVEL_W, PRIM_X - NAME_W - LEVEL_W, "gold")
    goldHeader.label:ClearAllPoints()
    goldHeader.label:SetPoint("RIGHT", -(PRIM_X - NAME_W - LEVEL_W - GOLD_W) - 2, 1)
    Header("Professions", PRIM_X, SEC_X - PRIM_X)
    -- One column per secondary profession, with its icon (hover for its name).
    for i, sec in ipairs(SECONDARY) do
        local b = ColumnHeader(header, "", SLOT_W)
        b:SetPoint("LEFT", SEC_X + (i - 1) * SLOT_W, 0)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", 2, 1)
        if not UseFile(icon, sec.icon) then
            icon:SetTexture(134400)
        end
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(sec.name, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    -- The rest of the width, so the header runs to the end.
    local filler = ColumnHeader(header, "", 10)
    filler:SetPoint("LEFT", SEC_X + #SECONDARY * SLOT_W, 0)
    filler:SetPoint("RIGHT", header, "RIGHT", 0, 0)

    page.list = ScrollList(page.frame, ROW_H, CrewRow, FillCrewRow)
    page.list.frame:SetPoint("TOPLEFT", 0, LIST_TOP - HEADER_H - 2)
    page.list.frame:SetPoint("BOTTOMRIGHT", 0, 22)

    page.status = Status(page)
    page.hiddenButton = Button(page.frame, "Show hidden", 140, function()
        page.showHidden = not page.showHidden
        page:Refresh()
    end)
    page.hiddenButton:SetPoint("BOTTOMRIGHT", -16, 0)

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

    local function Passes(key, p, text)
        if not Matches(key, p, text) then
            return false
        end
        if view.onlineOnly and key ~= ns.me and not ns.online[key] then
            return false
        end
        if (p.faction == "Alliance" and not view.alliance) or (p.faction == "Horde" and not view.horde) then
            return false
        end
        if page.prof then
            local has = false
            for _, e in ipairs(p.prof or {}) do
                if e.name == page.prof then has = true end
            end
            return has
        end
        return true
    end

    function page:Refresh()
        for _, t in ipairs(self.toggles) do
            t.SyncFilter()
        end
        local text = strtrim(self.search:GetText() or ""):lower()
        local myFaction = ns.Me().faction
        local function Other(p)
            return p.faction ~= nil and myFaction ~= nil and p.faction ~= myFaction
        end

        -- Group everyone by friend.
        local groups, order, profNames, seenProf = {}, {}, {}, {}
        for _, key in ipairs(ns.VisiblePeople(self.showHidden)) do
            local g = ns.GroupOf(key)
            if not groups[g] then
                groups[g] = { key = g, members = {} }
                order[#order + 1] = g
            end
            table.insert(groups[g].members, key)
            local p = ns.db.people[key]
            for _, e in ipairs(p and p.prof or {}) do
                if not seenProf[e.name] then
                    seenProf[e.name] = true
                    profNames[#profNames + 1] = e.name
                end
            end
        end
        table.sort(profNames)
        self.profNames = profNames
        if page.prof and not seenProf[page.prof] then
            page.prof = nil
        end
        if self.profButton then
            self.profButton:SetText("Profession: " .. (page.prof or "any"))
        end
        if self.profDrop and self.profDrop.GenerateMenu then
            pcall(self.profDrop.GenerateMenu, self.profDrop)
        end

        local function Sum(keys, field)
            local total = 0
            for _, k in ipairs(keys) do
                local p = ns.db.people[k]
                total = total + (p and tonumber(p[field]) or 0)
            end
            return total
        end
        local function MaxLevel(keys)
            local best = 0
            for _, k in ipairs(keys) do
                local p = ns.db.people[k]
                best = math.max(best, p and p.level or 0)
            end
            return best
        end
        local function Online(k)
            return k ~= ns.me and ns.online[k] == true
        end

        -- Sort value for a list of characters (one friend or one character).
        local function Value(keys)
            if view.sort == "level" then
                return MaxLevel(keys)
            elseif view.sort == "gold" then
                return Sum(keys, "money")
            end
            return nil
        end
        local function Before(aKeys, aName, bKeys, bName, aOnline, bOnline)
            local va, vb = Value(aKeys), Value(bKeys)
            if va and va ~= vb then
                if view.desc then return va > vb end
                return va < vb
            end
            if not va and aOnline ~= bOnline then
                return aOnline -- by name: friends online first
            end
            if view.desc and view.sort == "name" then
                return aName > bName
            end
            return aName < bName
        end

        local rows = {}
        local mine = ns.GroupOf(ns.me)
        local friends, friendsOnline, chars, hiddenCount = 0, 0, 0, 0
        for _, g in ipairs(order) do
            local grp = groups[g]
            grp.shown, grp.onlineCount = {}, 0
            for _, k in ipairs(grp.members) do
                local p = ns.db.people[k] or { rev = {}, prof = {} }
                if Online(k) then grp.onlineCount = grp.onlineCount + 1 end
                if Passes(k, p, text) then
                    grp.shown[#grp.shown + 1] = k
                end
            end
            if g ~= mine then
                friends = friends + 1
                if grp.onlineCount > 0 then friendsOnline = friendsOnline + 1 end
            end
            chars = chars + #grp.members
            -- Name: you, or the friend's character that is online or was seen last.
            local rep = grp.members[1]
            for _, k in ipairs(grp.members) do
                local p, r = ns.db.people[k], ns.db.people[rep]
                if Online(k) and not Online(rep) then
                    rep = k
                elseif Online(k) == Online(rep) and p and r and not p.via and ((p.seen or 0) > (r.seen or 0) or r.via) then
                    rep = k
                end
            end
            grp.rep = rep
            grp.label = g == mine and "You" or ns.ShortName(rep)
            if #grp.shown > 0 then
                rows[#rows + 1] = grp
            end
        end
        for key in pairs(ns.db.hidden) do
            local found = ns.db.people[key] or ns.db.crew[key]
            if not found and key:sub(1, 1) == "#" then
                for k in pairs(ns.db.people) do
                    if ns.GroupOf(k) == key then found = true end
                end
            end
            if found then hiddenCount = hiddenCount + 1 end
        end
        if hiddenCount == 0 then
            self.showHidden = false
        end
        self.hiddenButton:SetShown(hiddenCount > 0)
        self.hiddenButton:SetText(self.showHidden and "Hide them again" or ("Show hidden (" .. hiddenCount .. ")"))

        table.sort(rows, function(a, b)
            if a.key == mine then return true end
            if b.key == mine then return false end
            return Before(a.members, a.label, b.members, b.label, a.onlineCount > 0, b.onlineCount > 0)
        end)

        local function CharItem(k, child, group)
            local p = ns.db.people[k] or { rev = {}, prof = {} }
            local item = {
                key = k,
                person = p,
                child = child,
                online = Online(k),
                hidden = ns.IsHidden(k),
                class = p.class,
                faction = p.faction,
                other = Other(p),
                level = p.level,
                gold = p.money,
                profs = p.prof,
                name = ns.LongName(k) .. (ns.IsHidden(k) and " (hidden)" or ""),
            }
            if k ~= ns.me then
                if ns.db.hidden[k] then
                    item.hint = "Right-click to show again."
                elseif ns.IsHidden(k) then
                    item.hint = "Hidden with " .. group.label .. ". Right-click their line to show them again."
                else
                    item.hint = "Right-click to hide (asks first)."
                end
            end
            item.tooltip = function(tt) CrewTooltip(tt, item) end
            item.onClick = function(button)
                if button ~= "RightButton" or k == ns.me then
                    return
                end
                GameTooltip:Hide()
                if ns.db.hidden[k] then
                    ns.SetHidden(k, false)
                elseif not ns.IsHidden(k) then
                    AskToHide(k)
                end
            end
            return item
        end

        local items, anyHint = {}, false
        for _, grp in ipairs(rows) do
            local shown = grp.shown
            -- Characters: highest level first (or by the Gold column), then name.
            table.sort(shown, function(a, b)
                local pa, pb = ns.db.people[a] or {}, ns.db.people[b] or {}
                local va, vb
                if view.sort == "gold" then
                    va, vb = tonumber(pa.money) or 0, tonumber(pb.money) or 0
                else
                    va, vb = pa.level or 0, pb.level or 0
                end
                if va ~= vb then
                    if view.sort ~= "name" and not view.desc then return va < vb end
                    return va > vb
                end
                return ns.LongName(a) < ns.LongName(b)
            end)
            for _, k in ipairs(shown) do
                local p = ns.db.people[k]
                for _, e in ipairs(p and p.prof or {}) do
                    if ns.TrainerNow(e, p.level) then anyHint = true end
                end
            end
            if #grp.members == 1 then
                items[#items + 1] = CharItem(grp.members[1], false, grp)
            else
                local open = view.open[grp.key]
                if open == nil then open = grp.key == mine end
                if text ~= "" or page.prof or view.onlineOnly then open = true end
                local profs, holders = BestProfs(grp.members)
                local allOther = true
                for _, k in ipairs(grp.members) do
                    if not Other(ns.db.people[k] or {}) then allOther = false end
                end
                local rep = ns.db.people[grp.rep] or {}
                local hidden = ns.db.hidden[grp.key] == true
                local item = {
                    key = grp.key,
                    group = true,
                    open = open,
                    size = #grp.members,
                    onlineCount = grp.onlineCount,
                    online = grp.onlineCount > 0,
                    hidden = hidden,
                    class = rep.class,
                    faction = rep.faction,
                    other = allOther,
                    level = nil, -- level and gold only on character rows
                    gold = nil,
                    totalGold = Sum(grp.members, "money"),
                    profs = profs,
                    holders = holders,
                    name = grp.label .. "  " .. INK_DIM_HEX .. "(" .. #grp.members .. ")|r" .. (hidden and " (hidden)" or ""),
                }
                if grp.key == mine then
                    item.hint = "Click to open or close."
                else
                    item.hint = hidden and "Click to open or close. Right-click to show again."
                        or "Click to open or close. Right-click to hide (asks first)."
                end
                item.tooltip = function(tt)
                    GroupTooltip(tt, { name = grp.label, size = item.size, onlineCount = item.onlineCount, gold = item.totalGold, profs = profs, hint = item.hint })
                end
                item.onClick = function(button)
                    GameTooltip:Hide()
                    if button == "RightButton" then
                        if grp.key == mine then
                            return
                        elseif hidden then
                            ns.SetHidden(grp.key, false)
                        else
                            AskToHide(grp.key, grp.label)
                        end
                        return
                    end
                    view.open[grp.key] = not open
                    page:Refresh()
                end
                items[#items + 1] = item
                if open then
                    for _, k in ipairs(shown) do
                        items[#items + 1] = CharItem(k, true, grp)
                    end
                end
            end
        end

        for _, h in ipairs(self.headers) do
            local on = h.sortKey and h.sortKey == view.sort
            local c = on and { 1, 1, 1 } or GOLD
            h.label:SetTextColor(c[1], c[2], c[3])
        end

        if friends == 0 then
            self.status:SetText("No friends yet. Friends (press O) who have FriendsCraft show up here by themselves.")
        elseif #items == 0 then
            self.status:SetText("Nobody matches these filters.")
        else
            self.status:SetText(string.format("%d friend%s (%d online), %d characters.%s", friends, friends == 1 and "" or "s",
                friendsOnline, chars, anyHint and "  ! = can learn the next rank at a trainer" or ""))
        end
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Recipes: professions on the left, that profession's recipes on the right.
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
    row:SetSize(INDEX_W, 24)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    -- The chosen profession gets a shaded bar and a mark on the left,
    -- so it is not shown by color alone.
    row.chosen = row:CreateTexture(nil, "BACKGROUND")
    row.chosen:SetAllPoints()
    row.chosen:SetColorTexture(1, 0.82, 0, 0.15)
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetSize(3, 24)
    row.bar:SetPoint("LEFT")
    row.bar:SetColorTexture(1, 0.82, 0, 1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 8, 0)
    row.name = Ink(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", 32, 0)
    row.count = Ink(row, "GameFontHighlight", "", INK_DIM)
    row.count:SetPoint("RIGHT", -6, 0)
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
    local page = NewPage("recipes")
    page.search = SearchInput(page.bar, 220, "Search all recipes")
    page.search:SetPoint("LEFT", 8, 0)
    page.search:SetScript("OnTextChanged", function(self)
        self.UpdateHint()
        page.list.offset = 0
        page:Refresh()
    end)
    page.heading = Ink(page.frame, "GameFontNormalLarge", "", GOLD)
    page.heading:SetPoint("TOPLEFT", INDEX_W + 18, LIST_TOP - 6)
    page.headingCount = Ink(page.frame, "GameFontHighlightSmall", "", INK_DIM)
    page.headingCount:SetPoint("LEFT", page.heading, "RIGHT", 10, -1)
    local headLine = page.frame:CreateTexture(nil, "ARTWORK")
    headLine:SetHeight(1)
    headLine:SetPoint("TOPLEFT", INDEX_W + 14, LIST_TOP - 28)
    headLine:SetPoint("RIGHT", -14, 0)
    headLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
    page.status = Status(page)
    page.list = ScrollList(page.frame, ROW_H, IconRow, FillIconRow)
    page.list.frame:SetPoint("TOPLEFT", INDEX_W + 12, LIST_TOP - 32)
    page.list.frame:SetPoint("BOTTOMRIGHT", 0, 22)

    local function Choose(prof)
        page.chosen = prof
        page.search:SetText("")
        page.search:ClearFocus()
        page.search.UpdateHint()
        page.list.offset = 0
        page:Refresh()
    end
    page.index = {}
    for i = 1, 16 do
        local row = IndexRow(page.frame, Choose)
        row:SetPoint("TOPLEFT", 0, LIST_TOP - 4 - (i - 1) * 24)
        page.index[i] = row
    end
    local divider = page.frame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", INDEX_W + 4, LIST_TOP)
    divider:SetPoint("BOTTOMLEFT", INDEX_W + 4, 22)
    divider:SetWidth(1)
    divider:SetColorTexture(1, 0.82, 0, 0.25)

    -- "You, Tom, Mira": who can make it, you first.
    local function Makers(e)
        local names, you = {}, false
        for _, c in ipairs(e.crafters) do
            if c.key == ns.me then
                you = true
            else
                names[#names + 1] = Who(c.key)
            end
        end
        if you then
            table.insert(names, 1, "You")
        end
        if #names > 3 then
            return table.concat(names, ", ", 1, 3) .. " +" .. (#names - 3)
        end
        return table.concat(names, ", ")
    end

    function page:Refresh()
        local text = strtrim(self.search:GetText() or ""):lower()
        local all = ns.AllRecipes()
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
            self.heading:SetText("Search results")
        else
            source = groups[self.chosen] or {}
            self.heading:SetText(self.chosen or "Recipes")
        end
        self.headingCount:SetText(#source == 1 and "1 recipe" or (#source .. " recipes"))
        local items = {}
        for _, e in ipairs(source) do
            local prof = e.crafters[1] and e.crafters[1].prof
            items[#items + 1] = {
                text = e.name,
                icon = (e.out and e.out > 0) and ns.ItemIcon(e.out) or ProfIconByName(prof),
                color = (e.out and e.out > 0) and QualityColor(e.out) or INK,
                right = Makers(e),
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

local SHOP_ROW_H = 40
local SHOP_BAR_W = 140

-- A bar showing how many of the wanted amount someone has. The numbers are
-- always written on it, never color alone.
local function ProgressBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(SHOP_BAR_W, 16)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.55)
    local edge = bar:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0.45, 0.4, 0.3, 0.8)
    bar.text = Ink(bar, "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", 0, 0)
    bar.text:SetJustifyH("CENTER")
    -- above the fill and its background
    local holder = CreateFrame("Frame", nil, bar)
    holder:SetAllPoints()
    bar.text:SetParent(holder)
    return bar
end

local function SmallButton(parent, text, width, onClick)
    local b = Button(parent, text, width or 22, onClick)
    b:SetHeight(20)
    b:RegisterForClicks("LeftButtonUp")
    return b
end

-- A red cross button (the loot window's "pass" cross), "X" if the game
-- doesn't have that picture.
local function RemoveButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    if not UseFile(b.icon, "Interface\\Buttons\\UI-GroupLoot-Pass-Up") then
        b.icon:Hide()
        b.label = Ink(b, "GameFontNormal", "X", { 1, 0.35, 0.3 })
        b.label:SetPoint("CENTER")
    end
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    if not UseFile(hl, "Interface\\Buttons\\UI-GroupLoot-Pass-Highlight") then
        hl:SetColorTexture(1, 1, 1, 0.2)
    end
    hl:SetBlendMode("ADD")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove from your list", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- One row: either a person's heading or one item on their list.
local function ShopRow(parent)
    local row = CreateFrame("Button", nil, parent)
    RowScripts(row)

    -- heading
    row.hClass = row:CreateTexture(nil, "ARTWORK")
    row.hClass:SetSize(20, 20)
    row.hClass:SetPoint("BOTTOMLEFT", 6, 6)
    row.hText = Ink(row, "GameFontNormalLarge", "", GOLD)
    row.hText:SetPoint("LEFT", row.hClass, "RIGHT", 6, 0)
    row.hCount = Ink(row, "GameFontHighlightSmall", "", INK_DIM)
    row.hCount:SetPoint("LEFT", row.hText, "RIGHT", 10, -1)
    row.hLine = row:CreateTexture(nil, "ARTWORK")
    row.hLine:SetHeight(1)
    row.hLine:SetPoint("BOTTOMLEFT", 4, 1)
    row.hLine:SetPoint("BOTTOMRIGHT", -4, 1)
    row.hLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)

    -- item
    row.check = CheckButton(row)
    row.check:SetSize(26, 26)
    row.check:SetPoint("LEFT", 4, 0)
    row.check:SetScript("OnClick", function(self)
        local e = row.item and row.item.entry
        if e then
            local on = self:GetChecked() and true or false
            CheckSound(on)
            GameTooltip:Hide()
            ns.SetDone(e.id, on)
        end
    end)
    row.check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self:GetChecked() and "Open it again" or "Got it: tick it off", 1, 1, 1)
        GameTooltip:AddLine("Friends only see what is still open.", INK_DIM[1], INK_DIM[2], INK_DIM[3], true)
        GameTooltip:Show()
    end)
    row.check:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(30, 30)
    row.icon:SetPoint("LEFT", 34, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.iconEdge = row:CreateTexture(nil, "BORDER")
    row.iconEdge:SetPoint("TOPLEFT", row.icon, -1, 1)
    row.iconEdge:SetPoint("BOTTOMRIGHT", row.icon, 1, -1)
    row.iconEdge:SetColorTexture(0, 0, 0, 0.8)

    row.remove = RemoveButton(row, function()
        local e = row.item and row.item.entry
        if e then
            GameTooltip:Hide()
            ns.RemoveNeed(e.id)
        end
    end)
    row.remove:SetPoint("RIGHT", -6, 0)
    local function Change(delta)
        local e = row.item and row.item.entry
        if e then
            local step = IsShiftKeyDown and IsShiftKeyDown() and 5 or 1
            ns.SetNeed(e.id, math.max(1, math.min(9999, e.want + delta * step)))
        end
    end
    row.plus = SmallButton(row, "+", 22, function() Change(1) end)
    row.plus:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
    row.minus = SmallButton(row, "-", 22, function() Change(-1) end)
    row.minus:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
    for _, b in ipairs({ row.plus, row.minus }) do
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self == row.plus and "Want more" or "Want fewer", 1, 1, 1)
            GameTooltip:AddLine("Shift-click: 5 at a time.", INK_DIM[1], INK_DIM[2], INK_DIM[3])
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    row.bar = ProgressBar(row)
    row.bar:SetPoint("RIGHT", row.minus, "LEFT", -10, 0)

    row.name = Ink(row, "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.name:SetPoint("RIGHT", row.bar, "LEFT", -10, 0)
    row.name:SetWordWrap(false)
    row.sub = Ink(row, "GameFontHighlightSmall", "", INK_DIM)
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.sub:SetPoint("RIGHT", row.bar, "LEFT", -10, 0)
    row.sub:SetWordWrap(false)
    return row
end

local function FillShopRow(row, item)
    local heading = item.kind == "heading"
    for _, part in ipairs({ row.hClass, row.hText, row.hCount, row.hLine }) do
        part:SetShown(heading)
    end
    for _, part in ipairs({ row.check, row.icon, row.iconEdge, row.remove, row.plus, row.minus, row.bar, row.name, row.sub }) do
        part:SetShown(not heading)
    end
    if row.stripe then
        row.stripe:SetAlpha(heading and 0 or 1)
    end
    if heading then
        SetClassIcon(row.hClass, item.class)
        row.hText:SetText(item.text)
        row.hCount:SetText(item.count or "")
        return
    end

    local e = item.entry
    row.icon:SetTexture(ns.ItemIcon(e.id))
    row.icon:SetDesaturated(e.done)
    row.icon:SetAlpha(e.done and 0.6 or 1)
    local q = ns.ItemQuality(e.id)
    local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if e.done then
        row.name:SetText(e.name .. "  " .. INK_DIM_HEX .. "(got it)|r")
        row.name:SetTextColor(INK_DIM[1], INK_DIM[2], INK_DIM[3])
    else
        row.name:SetText(e.want .. " x " .. e.name)
        if qc then
            row.name:SetTextColor(qc.r, qc.g, qc.b)
        else
            row.name:SetTextColor(INK[1], INK[2], INK[3])
        end
    end
    row.sub:SetText(item.sub or "")

    row.check:SetShown(e.editable)
    row.check:SetChecked(e.done)
    row.remove:SetShown(e.editable)
    row.plus:SetShown(e.editable and not e.done)
    row.minus:SetShown(e.editable and not e.done)

    row.bar:SetShown(not e.done)
    if not e.done then
        local enough = e.have >= e.want
        row.bar:SetMinMaxValues(0, math.max(1, e.want))
        row.bar:SetValue(math.min(e.have, e.want))
        local c = enough and GOOD or INFO
        row.bar:SetStatusBarColor(c[1], c[2], c[3], 0.85)
        row.bar.text:SetText(enough and (e.have .. " / " .. e.want .. "  enough") or (e.have .. " / " .. e.want))
    end
end

local function BuildShopPage()
    local page = NewPage("shop")
    local addW, countW = 60, 80
    page.item = Input(page.bar, 260, "Item name, or shift-click it")
    page.item:SetPoint("LEFT", 12, 0)
    page.count = Input(page.bar, countW, "How many")
    page.count:SetPoint("LEFT", page.item, "RIGHT", 10, 0)
    page.count:SetNumeric(true)
    local add = Button(page.bar, "Add", addW, function()
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
    add:SetPoint("LEFT", page.count, "RIGHT", 8, 0)
    page.clear = Button(page.bar, "Clear ticked", 130, function() ns.ClearDone() end)
    page.clear:SetPoint("RIGHT", -8, 0)
    page.item:SetScript("OnEnterPressed", function() page.count:SetFocus() end)
    page.count:SetScript("OnEnterPressed", function() add:Click() end)
    page.item:SetScript("OnTextChanged", function(self) self.UpdateHint() end)
    page.count:SetScript("OnTextChanged", function(self) self.UpdateHint() end)
    page.status = Status(page)
    page.list = ScrollList(page.frame, SHOP_ROW_H, ShopRow, FillShopRow)
    page.list.frame:SetPoint("TOPLEFT", 0, LIST_TOP)
    page.list.frame:SetPoint("BOTTOMRIGHT", 0, 22)
    ns.shopItemBox = page.item

    -- "Gigi 12, Emoolia 3. Can make it: Tom"
    local function SubLine(e)
        local parts = {}
        if not e.mine then
            local mineHave = ns.HaveCount(ns.me, e.id)
            if mineHave > 0 then
                parts[#parts + 1] = "|cff66e066You have " .. mineHave .. "|r"
            end
        end
        local others = {}
        for _, h in ipairs(ns.Holders(e.id)) do
            if h.key ~= e.key and h.key ~= ns.me then
                others[#others + 1] = h
            end
        end
        if #others > 0 then
            parts[#parts + 1] = "Has some: " .. JoinHolders(others, 3)
        end
        local makers = {}
        for _, m in ipairs(ns.Crafters(e.id)) do
            if m.key ~= e.key then
                makers[#makers + 1] = Who(m.key)
            end
        end
        if #makers > 0 then
            parts[#parts + 1] = "Can make it: " .. table.concat(makers, ", ")
        end
        if #parts == 0 then
            return e.mine and not e.done and "Nobody else has any yet." or ""
        end
        return table.concat(parts, "   ")
    end

    local function Tooltip(e)
        return function(tt)
            tt:SetText(e.name, 1, 1, 1)
            if e.done then
                tt:AddLine("Ticked off. Friends no longer see it.", INK_DIM[1], INK_DIM[2], INK_DIM[3], true)
            else
                tt:AddLine(Who(e.key) .. " wants " .. e.want .. ", has " .. e.have .. ".", 1, 1, 1)
            end
            local others = {}
            for _, h in ipairs(ns.Holders(e.id)) do
                if h.key ~= e.key then others[#others + 1] = h end
            end
            if #others > 0 then
                tt:AddLine("Has some: " .. JoinHolders(others), INFO[1], INFO[2], INFO[3], true)
            end
            local makers = ns.Crafters(e.id)
            if #makers > 0 then
                local names = {}
                for _, m in ipairs(makers) do names[#names + 1] = Who(m.key) end
                tt:AddLine("Can make it: " .. table.concat(names, ", "), GOOD[1], GOOD[2], GOOD[3], true)
            end
        end
    end

    function page:Refresh()
        -- Everyone with something on their list: you first, then your
        -- alts, then friends.
        local people = {}
        for _, key in ipairs(ns.VisiblePeople()) do
            local p = ns.db.people[key]
            local entries = {}
            local editable = key == ns.me
            for id, want in pairs(p and p.shop or {}) do
                entries[#entries + 1] = { key = key, id = id, want = want, done = false }
            end
            if p and p.mine then
                for id, want in pairs(ns.DoneList(key)) do
                    if not (p.shop and p.shop[id]) then
                        entries[#entries + 1] = { key = key, id = id, want = want, done = true }
                    end
                end
            end
            if #entries > 0 then
                for _, e in ipairs(entries) do
                    e.name = ns.ItemName(e.id) or ("item " .. e.id)
                    e.have = ns.HaveCount(key, e.id)
                    e.mine = p and p.mine or key == ns.me
                    e.editable = editable
                end
                table.sort(entries, function(a, b)
                    if a.done ~= b.done then return not a.done end
                    if a.name ~= b.name then return a.name < b.name end
                    return a.id < b.id
                end)
                people[#people + 1] = { key = key, p = p, entries = entries,
                    rank = key == ns.me and 0 or (p and p.mine) and 1 or 2 }
            end
        end
        table.sort(people, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return Who(a.key) < Who(b.key)
        end)

        local items, ticked = {}, 0
        for _, person in ipairs(people) do
            local open = 0
            for _, e in ipairs(person.entries) do
                if not e.done then open = open + 1 end
                if e.done and person.key == ns.me then ticked = ticked + 1 end
            end
            local title
            if person.key == ns.me then
                title = "Your list"
            elseif person.p and person.p.mine then
                title = Who(person.key)
            else
                title = Who(person.key) .. " needs"
            end
            items[#items + 1] = {
                kind = "heading",
                text = title,
                class = person.p and person.p.class,
                count = open == 1 and "1 open" or (open .. " open"),
            }
            for _, e in ipairs(person.entries) do
                items[#items + 1] = { kind = "item", entry = e, sub = SubLine(e), tooltip = Tooltip(e) }
            end
        end
        page.clear:SetShown(ticked > 0)
        page.clear:SetText(ticked > 0 and ("Clear ticked (" .. ticked .. ")") or "Clear ticked")
        self.status:SetText(#items == 0
            and "Nothing on anyone's list yet. Add what you need above; friends see it."
            or "Tick what you've got. + and - change how many, the cross removes it. Friends see what is still open.")
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Who has it
-------------------------------------------------------------------------------

-- The item's type for grouping: trade goods by kind (Cloth, Herb, ...)
-- first, then everything else by type. Returns name, order.
local function ItemGroup(id)
    local get = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if get then
        local ok, _, itemType, subType, _, _, classID = pcall(get, id)
        if ok and not ns.IsSecret(itemType) and not ns.IsSecret(subType) then
            if classID == 7 and type(subType) == "string" and subType ~= "" then
                return subType, 0
            end
            if type(itemType) == "string" and itemType ~= "" then
                return itemType, 1
            end
        end
    end
    return "Other", 2
end

-- "Gigi 12, You 9, Emoolia 3 +2"
local function ShortHolders(holders, limit)
    local parts = {}
    for i, h in ipairs(holders) do
        if i > limit then
            parts[#parts + 1] = "+" .. (#holders - limit)
            break
        end
        parts[#parts + 1] = Who(h.key) .. " " .. (h.bags + h.bank)
    end
    return table.concat(parts, ", ")
end

local function BuildFindPage()
    local page = NewPage("find")
    page.search = SearchInput(page.bar, 260, "Search items, e.g. linen")
    page.search:SetPoint("LEFT", 8, 0)
    page.search:SetScript("OnTextChanged", function(self)
        self.UpdateHint()
        page.list.offset = 0
        page:Refresh()
    end)
    page.status = Status(page)
    page.list = ScrollList(page.frame, ROW_H, IconRow, FillIconRow)
    page.list.frame:SetPoint("TOPLEFT", 0, LIST_TOP)
    page.list.frame:SetPoint("BOTTOMRIGHT", 0, 22)

    function page:Refresh()
        local text = strtrim(self.search:GetText() or ""):lower()
        local searching = text ~= ""
        -- Everything someone in the crew holds (or what matches the search),
        -- grouped by type.
        local groups, order = {}, {}
        local count = 0
        for _, id in ipairs(ns.KnownItemIDs()) do
            local name = ns.ItemName(id)
            if (name or not searching) and (not searching or name:lower():find(text, 1, true)) then
                local holders = ns.Holders(id)
                if #holders > 0 then
                    local gname, rank = ItemGroup(id)
                    local g = groups[gname]
                    if not g then
                        g = { name = gname, rank = rank, list = {} }
                        groups[gname] = g
                        order[#order + 1] = g
                    end
                    local total = 0
                    for _, h in ipairs(holders) do total = total + h.bags + h.bank end
                    g.list[#g.list + 1] = { id = id, name = name or ("item " .. id), holders = holders, total = total }
                    count = count + 1
                end
            end
        end
        table.sort(order, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.name < b.name
        end)
        local items = {}
        for _, g in ipairs(order) do
            table.sort(g.list, function(a, b) return a.name < b.name end)
            items[#items + 1] = { kind = "heading", text = g.name, right = #g.list == 1 and "1 item" or (#g.list .. " items") }
            for _, e in ipairs(g.list) do
                items[#items + 1] = {
                    icon = ns.ItemIcon(e.id),
                    text = e.name .. "  " .. INK_DIM_HEX .. "x" .. e.total .. "|r",
                    color = QualityColor(e.id),
                    right = ShortHolders(e.holders, 3),
                    tooltip = function(tt)
                        tt:SetText(e.name, 1, 1, 1)
                        tt:AddLine(e.total .. " in the crew", INK_DIM[1], INK_DIM[2], INK_DIM[3])
                        for _, h in ipairs(e.holders) do
                            tt:AddLine(HolderText(h), 1, 1, 1)
                        end
                    end,
                }
            end
        end
        if count == 0 then
            self.status:SetText(searching and "Nobody in the crew has that."
                or "Nothing yet. Bags are shared as soon as friends log in; banks when they visit one.")
        else
            self.status:SetText((count == 1 and "1 item" or (count .. " items")) .. (searching and " found." or " in the crew's bags and banks.")
                .. " Hover one to see who has it.")
        end
        self.list:SetItems(items)
    end
    return page
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local function Checkbox(parent, label, note, get, set)
    local b = CheckButton(parent)
    b:SetSize(26, 26)
    b.label = Ink(b, "GameFontHighlight", label)
    b.label:SetPoint("LEFT", b, "RIGHT", 4, 1)
    b.note = Ink(b, "GameFontHighlightSmall", note, INK_DIM)
    b.note:SetPoint("TOPLEFT", b.label, "BOTTOMLEFT", 0, -3)
    b.note:SetWidth(300)
    b.note:SetWordWrap(true)
    b:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        set(on)
        CheckSound(on)
    end)
    b.Sync = function() b:SetChecked(get() and true or false) end
    return b
end

local function BuildSettingsPage()
    local page = NewPage("settings")
    local heading = Ink(page.frame, "GameFontNormal", "Settings", GOLD)
    heading:SetPoint("TOPLEFT", 8, -8)
    page.boxes = {
        Checkbox(page.frame, "Minimap button", "The FriendsCraft button on the minimap. Without it, type /fc to open the window.",
            function() return not ns.db.minimap.hide end,
            function(on)
                ns.db.minimap.hide = not on
                ns.UpdateMinimapButton()
            end),
        Checkbox(page.frame, "Crew lines on item tooltips", "\"Crew has\", \"needs\" and \"can make it\" when you hover an item.",
            function() return ns.db.tooltips end,
            function(on) ns.db.tooltips = on end),
    }
    for i, b in ipairs(page.boxes) do
        b:SetPoint("TOPLEFT", 8, -32 - (i - 1) * 60)
    end
    local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    if type(version) == "string" and version ~= "" then
        local v = Ink(page.frame, "GameFontHighlightSmall", "FriendsCraft " .. version, INK_DIM)
        v:SetPoint("BOTTOMLEFT", 8, 4)
    end
    local notesHeading = Ink(page.frame, "GameFontNormal", "Good to know", GOLD)
    notesHeading:SetPoint("TOPLEFT", 380, -8)
    local notes = Ink(page.frame, "GameFontHighlight", table.concat({
        "A friend's other characters show up by themselves once that friend logs in on any of them.",
        "Hidden people: on the Crew page, click \"Show hidden\" to see them and right-click to bring them back.",
        "Recipes: open each profession window once so your recipes are shared.",
        "Bank: updates when you visit a bank.",
        "Type /fc to open the window from anywhere. Drag the corner to make it bigger.",
    }, "\n\n"), INK)
    notes:SetPoint("TOPLEFT", 380, -32)
    notes:SetPoint("RIGHT", -16, 0)
    notes:SetWordWrap(true)

    function page:Refresh()
        for _, b in ipairs(self.boxes) do
            b.Sync()
        end
    end
    return page
end

-------------------------------------------------------------------------------
-- Window and tabs
-------------------------------------------------------------------------------

local TAB_NAMES = {}

local function SetWindowTitle(text)
    if window.SetTitle then
        pcall(window.SetTitle, window, text)
    elseif type(window.fcTitle) == "table" then
        window.fcTitle:SetText(text)
    end
end

local function ShowTab(name)
    currentTab = name
    for key, page in pairs(pages) do
        page.frame:SetShown(key == name)
        page.bar:SetShown(key == name)
    end
    for _, t in ipairs(tabs) do
        -- The open tab gets the glowing frame.
        t.selected:SetShown(t.key == name)
    end
    SetWindowTitle("FriendsCraft: " .. (TAB_NAMES[name] or ""))
    ns.RefreshUI(true)
end

-- A square icon tab on the left side of the window, like the game's own
-- side tabs. Hover shows its name.
local function Tab(key, text, icon)
    local b = CreateFrame("Button", nil, window)
    b.key = key
    b.tabName = text
    TAB_NAMES[key] = text
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

local function SavePlace()
    local point, _, relPoint, x, y = window:GetPoint()
    local w, h = window:GetWidth(), window:GetHeight()
    if point and type(w) == "number" then
        ns.db.window = { point = point, relPoint = relPoint, x = x, y = y, w = w, h = h }
    end
end

local function BuildWindow()
    -- The game's own panel with a round portrait, or a plain dark panel.
    local ok, f = pcall(CreateFrame, "Frame", "FriendsCraftFrame", UIParent, "ButtonFrameTemplate")
    local framed = ok and f
    if not framed then
        f = CreateFrame("Frame", "FriendsCraftFrame", UIParent, "BackdropTemplate")
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
        f.fcTitle = Ink(f, "GameFontNormal", "FriendsCraft", GOLD)
        f.fcTitle:SetPoint("TOP", 0, -16)
    end
    window = f
    local place = ns.db.window or {}
    local function Clamp(v, lo, hi, default)
        v = tonumber(v) or default
        return math.max(lo, math.min(hi, v))
    end
    f:SetSize(Clamp(place.w, MIN_W, MAX_W, DEFAULT_W), Clamp(place.h, MIN_H, MAX_H, DEFAULT_H))
    if place.point then
        f:SetPoint(place.point, UIParent, place.relPoint or place.point, tonumber(place.x) or 0, tonumber(place.y) or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetClampRectInsets(48, 0, 0, 0) -- keep the side tabs on screen
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePlace()
    end)
    f:Hide()
    tinsert(UISpecialFrames, "FriendsCraftFrame") -- Escape closes it

    if framed then
        if ButtonFrameTemplate_HideButtonBar then
            pcall(ButtonFrameTemplate_HideButtonBar, f)
        end
        if f.SetPortraitToAsset then
            pcall(f.SetPortraitToAsset, f, ICON)
        elseif type(f.portrait) == "table" and SetPortraitToTexture then
            pcall(SetPortraitToTexture, f.portrait, ICON)
        end
    end

    -- Drag the bottom right corner to resize.
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_W, MIN_H)
        f:SetMaxResize(MAX_W, MAX_H)
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SavePlace()
        ns.RefreshUI(true)
    end)

    content = CreateFrame("Frame", nil, f)
    -- Everything inside grows with the window's height (wider windows
    -- show more professions instead).
    local function ApplyScale()
        local h = f:GetHeight()
        if type(h) ~= "number" or h <= 0 then
            h = DEFAULT_H
        end
        content:SetScale(BASE_SCALE * math.max(1, math.min(MAX_SCALE / BASE_SCALE, h / DEFAULT_H)))
    end
    ApplyScale()
    f:SetScript("OnSizeChanged", function()
        ApplyScale()
        ns.RefreshUI()
    end)
    if framed and type(f.Inset) == "table" then
        content:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", 6, -6)
        content:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -6, 6)
    else
        content:SetPoint("TOPLEFT", 16, -40)
        content:SetPoint("BOTTOMRIGHT", -16, 16)
    end

    -- The strip between the title and the list area.
    toolbar = CreateFrame("Frame", nil, f)
    if framed and type(f.Inset) == "table" then
        toolbar:SetPoint("TOPLEFT", f, "TOPLEFT", 62, -26)
        toolbar:SetPoint("BOTTOMRIGHT", f.Inset, "TOPRIGHT", -6, 2)
        LIST_TOP = 0
    else
        toolbar:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        toolbar:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        toolbar:SetHeight(30)
        LIST_TOP = -34
    end
    toolbar:SetFrameLevel(f:GetFrameLevel() + 10)

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
        b:SetPoint("TOPRIGHT", window, "TOPLEFT", 0, -90 - (i - 1) * 52)
        tabs[i] = b
    end

    BuildCrewPage()
    BuildRecipesPage()
    BuildShopPage()
    BuildFindPage()
    BuildSettingsPage()
    f:SetScript("OnShow", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then
            pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_OPEN)
        end
        ns.RefreshUI(true)
    end)
    f:SetScript("OnHide", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then
            pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
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
