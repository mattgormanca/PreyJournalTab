-- PreyJournalTab.lua
-- Adds a "Prey Hunts" tracking tab to the Adventure Guide (EncounterJournal).
-- The tab appears as the last tab on the window and is styled to feel native.
--
-- Usage: /prey       → open Adventure Guide and jump straight to the Prey tab
--        /prey reset → reset weekly counts

local ADDON_NAME = "PreyJournalTab"

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MAX_HUNTS          = { Normal = 4, Hard = 4, Nightmare = 4 }
local FULL_REWARD_CAP    = 4
local DIFFICULTIES       = { "Normal", "Hard", "Nightmare" }
local NIGHTMARISH_TITLE  = "A Nightmarish Task"

local COLORS = {
    Normal    = { r = 0.4, g = 0.8, b = 0.4 },
    Hard      = { r = 0.9, g = 0.6, b = 0.1 },
    Nightmare = { r = 0.8, g = 0.2, b = 0.2 },
}

-- EJ-matching gold
local GOLD = { 1.0, 0.82, 0.0 }

-- Content panel dimensions (sits centered inside the EJ frame)
local PANEL_W  = 420
local PANEL_H  = 310
local PAD      = 16
local ROW_H    = 32
local ACTIVE_H = 54
local FOOTER_H = 28

--------------------------------------------------------------------------------
-- SavedVariables helpers
--------------------------------------------------------------------------------

local function GetWeeklyResetTimestamp()
    local now = time()
    local t   = date("!*t", now)
    local daysSinceTuesday        = (t.wday - 3 + 7) % 7
    local secondsIntoDayPastReset = (t.hour - 15) * 3600 + t.min * 60 + t.sec
    local offset = daysSinceTuesday * 86400 + secondsIntoDayPastReset
    if offset < 0 then offset = offset + 7 * 86400 end
    return now - offset
end

local function InitDB()
    if not PreyJournalDB then PreyJournalDB = {} end
    local resetTime = GetWeeklyResetTimestamp()
    if not PreyJournalDB.lastReset or PreyJournalDB.lastReset < resetTime then
        PreyJournalDB.lastReset = resetTime
        PreyJournalDB.counts    = { Normal = 0, Hard = 0, Nightmare = 0 }
    end
    PreyJournalDB.counts = PreyJournalDB.counts or {}
    for _, diff in ipairs(DIFFICULTIES) do
        PreyJournalDB.counts[diff] = PreyJournalDB.counts[diff] or 0
    end
end

local function GetCount(diff)
    return PreyJournalDB.counts[diff] or 0
end
local function SetCount(diff, val)
    PreyJournalDB.counts[diff] = math.max(0, math.min(val, MAX_HUNTS[diff]))
end
local function GetTotalCompleted()
    local n = 0
    for _, d in ipairs(DIFFICULTIES) do n = n + GetCount(d) end
    return n
end

--------------------------------------------------------------------------------
-- Persistent logger  (must be defined before any function that calls it)
--------------------------------------------------------------------------------

local function PJTLog(category, msg)
    if not PreyJournalDB then return end
    PreyJournalDB.log = PreyJournalDB.log or {}
    if #PreyJournalDB.log >= 500 then
        table.remove(PreyJournalDB.log, 1)
    end
    table.insert(PreyJournalDB.log, string.format("[%s][%s] %s",
        date("%Y-%m-%d %H:%M:%S"), category, msg))
end

--------------------------------------------------------------------------------
-- Active hunt detection
--------------------------------------------------------------------------------

local function ParsePreyTitle(title)
    if not title or not title:find("^Prey:") then return nil, nil end
    for _, e in ipairs({
        { pat = "%(Normal%)$",    diff = "Normal"    },
        { pat = "%(Hard%)$",      diff = "Hard"      },
        { pat = "%(Nightmare%)$", diff = "Nightmare" },
    }) do
        if title:find(e.pat) then
            local target = title:match("^Prey:%s+(.-)%s+%(" .. e.diff .. "%)")
            return target, e.diff
        end
    end
    return nil, nil
end

local function GetZoneFromTaskQuest()
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.isTask and info.title
                and info.title:find("Prey") then
            local zoneID = C_TaskQuest and C_TaskQuest.GetQuestZoneID(info.questID)
            if zoneID and zoneID > 0 then
                local mi = C_Map.GetMapInfo(zoneID)
                if mi and mi.name and mi.name ~= "" then return mi.name end
            end
        end
    end
    return nil
end

local function ScanQuestLogForActiveHunt()
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isTask and info.title then
            local target, diff = ParsePreyTitle(info.title)
            if target then
                return target, diff, GetZoneFromTaskQuest(), info.questID
            end
        end
    end
    return nil, nil, nil, nil
end

-- Locate the weekly "A Nightmarish Task" quest in the log.
local function ScanNightmarishTask()
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.title == NIGHTMARISH_TITLE then
            local qid        = info.questID
            local isComplete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(qid)
            local objectives = (C_QuestLog.GetQuestObjectives
                                and C_QuestLog.GetQuestObjectives(qid)) or {}
            return {
                accepted   = true,
                questID    = qid,
                isComplete = isComplete and true or false,
                objectives = objectives,
            }
        end
    end
    return { accepted = false }
end

-- Format a copper value as "Ng Ms Kc" with Blizzard-ish colour tags.
local function FormatMoney(copper)
    if not copper or copper <= 0 then return nil end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then table.insert(parts, g .. "|cffffd700g|r") end
    if s > 0 then table.insert(parts, s .. "|cffc7c7cfs|r") end
    if g == 0 and c > 0 then table.insert(parts, c .. "|cffeda55fc|r") end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

-- Pull item + money rewards for a quest log quest.
local function GetHuntRewards(questID)
    if not questID then return {}, 0 end
    if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        -- Rewards can be lazy-loaded; poke the API so the next refresh is populated.
        C_QuestLog.RequestLoadQuestByID(questID)
    end
    local items      = {}
    local numRewards = (GetNumQuestLogRewards and GetNumQuestLogRewards(questID)) or 0
    for i = 1, numRewards do
        local name, texture, quantity, _, _, _, _, _, _, _, quality
            = GetQuestLogRewardInfo(i, questID)
        if name then
            table.insert(items, {
                name     = name,
                icon     = texture,
                quantity = quantity or 1,
                quality  = quality or 1,
            })
        end
    end
    local money = (GetQuestLogRewardMoney and GetQuestLogRewardMoney(questID)) or 0
    return items, money
end

--------------------------------------------------------------------------------
-- UI state
--------------------------------------------------------------------------------

local preyPanel       -- content frame parented to EncounterJournal
local rows            -- difficulty row widget table
local preyFooterLabel
local nightmarishLabel  -- weekly "A Nightmarish Task" status line
local activeSection
local preyTabButton   -- the tab button we add to EJ
local preyTabIndex    -- which tab number we are


--------------------------------------------------------------------------------
-- Display update functions
--------------------------------------------------------------------------------

local function UpdateActiveHunt()
    if not activeSection then return end
    local target, diff, zone, questID = ScanQuestLogForActiveHunt()
    if target and diff then
        local c = COLORS[diff]
        activeSection.targetLabel:SetText(target)
        activeSection.diffLabel:SetText(diff)
        activeSection.diffLabel:SetTextColor(c.r, c.g, c.b)
        if zone then
            activeSection.zoneLabel:SetText(zone)
            activeSection.zoneLabel:Show()
        else
            activeSection.zoneLabel:Hide()
        end
        activeSection.noneLabel:Hide()
        activeSection.targetLabel:Show()
        activeSection.diffLabel:Show()

        -- Rewards line
        if activeSection.rewardLabel then
            local items, money = GetHuntRewards(questID)
            local parts = {}
            for _, it in ipairs(items) do
                local q = (it.quantity and it.quantity > 1) and ("x" .. it.quantity) or ""
                table.insert(parts, "|cffffd700" .. it.name .. q .. "|r")
            end
            local moneyStr = FormatMoney(money)
            if moneyStr then table.insert(parts, moneyStr) end
            if #parts > 0 then
                activeSection.rewardLabel:SetText("Reward: " .. table.concat(parts, ", "))
                activeSection.rewardLabel:Show()
            else
                activeSection.rewardLabel:SetText("Reward: |cff888888(loading…)|r")
                activeSection.rewardLabel:Show()
            end
        end
    else
        activeSection.noneLabel:Show()
        activeSection.targetLabel:Hide()
        activeSection.diffLabel:Hide()
        activeSection.zoneLabel:Hide()
        if activeSection.rewardLabel then activeSection.rewardLabel:Hide() end
    end
end

local function UpdateNightmarishTask()
    if not nightmarishLabel then return end
    local t = ScanNightmarishTask()
    if not t.accepted then
        nightmarishLabel:SetText(
            "|cffa9a9a9Weekly: " .. NIGHTMARISH_TITLE .. " — not accepted|r")
        return
    end
    if t.isComplete then
        nightmarishLabel:SetText(
            "|cff00ff00Weekly: " .. NIGHTMARISH_TITLE .. " — ready to turn in!|r")
        return
    end
    -- Assemble objective progress: "2/4 Nightmare hunts"
    local bits = {}
    for _, o in ipairs(t.objectives) do
        if o and o.text and o.text ~= "" then
            if o.numRequired and o.numRequired > 0 then
                table.insert(bits, string.format("%d/%d %s",
                    o.numFulfilled or 0, o.numRequired, o.text))
            else
                table.insert(bits, o.text)
            end
        end
    end
    if #bits == 0 then
        nightmarishLabel:SetText(
            "|cffd8b4feWeekly: " .. NIGHTMARISH_TITLE .. " — in progress|r")
    else
        nightmarishLabel:SetText(
            "|cffd8b4feWeekly:|r " .. table.concat(bits, "  |cff666666·|r  "))
    end
end

local function UpdateDisplay()
    if not rows then return end
    local total = GetTotalCompleted()
    for _, diff in ipairs(DIFFICULTIES) do
        local count = GetCount(diff)
        local max   = MAX_HUNTS[diff]
        local c     = COLORS[diff]
        local row   = rows[diff]

        row.countLabel:SetText(count .. " / " .. max)

        if count >= max then
            row.countLabel:SetTextColor(0.3, 1.0, 0.3)
            row.addBtn:SetAlpha(0.4) ; row.addBtn:Disable()
        else
            row.countLabel:SetTextColor(c.r, c.g, c.b)
            row.addBtn:SetAlpha(1.0) ; row.addBtn:Enable()
        end

        if count <= 0 then
            row.subBtn:SetAlpha(0.4) ; row.subBtn:Disable()
        else
            row.subBtn:SetAlpha(1.0) ; row.subBtn:Enable()
        end
    end

    local remain = math.max(0, FULL_REWARD_CAP - total)
    if remain > 0 then
        preyFooterLabel:SetText(string.format(
            "|cffffd700%d|r full-reward hunt%s remaining this week",
            remain, remain == 1 and "" or "s"))
    else
        preyFooterLabel:SetText("|cff00ff00Full weekly rewards claimed!|r")
    end

    UpdateNightmarishTask()
end

--------------------------------------------------------------------------------
-- Build content panel (rendered inside the EJ frame)
--------------------------------------------------------------------------------

local function MakeBtn(parent, text, w, h)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w, h) ; btn:SetText(text)
    return btn
end

-- Journeys-style divider: UI-Journeys-Renown-divider + glow (confirmed from panelscan)
local function MakeDivider(parent, yOff)
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetAtlas("UI-Journeys-Renown-divider", false)
    div:SetHeight(16)
    div:SetPoint("TOPLEFT",  parent, "TOPLEFT",  14, yOff)
    div:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, yOff)

    local glow = parent:CreateTexture(nil, "ARTWORK", nil, -1)
    glow:SetAtlas("UI-Journeys-Renown-divider-glow", false)
    glow:SetHeight(175)
    glow:SetPoint("TOPLEFT",  parent, "TOPLEFT",  40, yOff)
    glow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -40, yOff)
    return div
end

local function BuildPreyContent(parent)
    local W   = parent:GetWidth()
    local H   = parent:GetHeight()
    if W < 100 then W = 786 end
    if H < 100 then H = 430 end

    local PAD      = 14
    local availW   = W - PAD * 2
    local HEADER_H = 36

    -- ── Panel background: UI-Journeys-BG ─────────────────────────────────────
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("UI-Journeys-BG", false)
    bg:SetAllPoints(parent)

    -- ── Header ────────────────────────────────────────────────────────────────
    local title = parent:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 18, "")
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    title:SetText("Prey Hunts")
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -12)

    MakeDivider(parent, -HEADER_H)

    -- ── Active Hunt: UI-Journeys-Delve-Companion-button, no ring icon ─────────
    local ACTIVE_H = 100
    local ACTIVE_Y = -(HEADER_H + 20)
    local TX       = PAD + 56   -- pushed right to clear card frame edge

    local activeCard = CreateFrame("Frame", nil, parent)
    activeCard:SetSize(availW, ACTIVE_H)
    activeCard:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, ACTIVE_Y)

    local acBg = activeCard:CreateTexture(nil, "BACKGROUND")
    acBg:SetAtlas("UI-Journeys-Delve-Companion-button", false)
    acBg:SetAllPoints(activeCard)

    local ahLabel = nil -- removed

    local noneLabel = activeCard:CreateFontString(nil, "OVERLAY")
    noneLabel:SetFont("Fonts\\MORPHEUS.TTF", 16, "")
    noneLabel:SetJustifyH("CENTER")
    noneLabel:SetPoint("CENTER", activeCard, "CENTER", 0, 0)
    noneLabel:SetText("No hunt in progress")
    noneLabel:SetTextColor(0.55, 0.50, 0.38)

    local targetLabel = activeCard:CreateFontString(nil, "OVERLAY")
    targetLabel:SetFont("Fonts\\MORPHEUS.TTF", 20, "")
    targetLabel:SetJustifyH("LEFT")
    targetLabel:SetPoint("TOPLEFT", activeCard, "TOPLEFT", TX, -22)
    targetLabel:SetTextColor(0.98, 0.92, 0.72)
    targetLabel:SetShadowColor(0, 0, 0, 0.6) ; targetLabel:SetShadowOffset(1, -1)
    targetLabel:Hide()

    local diffLabel = activeCard:CreateFontString(nil, "OVERLAY")
    diffLabel:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    diffLabel:SetPoint("TOPLEFT", activeCard, "TOPLEFT", TX, -48)
    diffLabel:Hide()

    local zoneLabel = activeCard:CreateFontString(nil, "OVERLAY")
    zoneLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    zoneLabel:SetPoint("TOPLEFT", activeCard, "TOPLEFT", TX, -64)
    zoneLabel:SetTextColor(0.78, 0.70, 0.52)
    zoneLabel:Hide()

    local rewardLabel = activeCard:CreateFontString(nil, "OVERLAY")
    rewardLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    rewardLabel:SetJustifyH("LEFT")
    rewardLabel:SetWordWrap(false)
    rewardLabel:SetPoint("TOPLEFT",  activeCard, "TOPLEFT",  TX, -80)
    rewardLabel:SetPoint("TOPRIGHT", activeCard, "TOPRIGHT", -12, -80)
    rewardLabel:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    rewardLabel:Hide()

    activeSection = { noneLabel   = noneLabel,   targetLabel = targetLabel,
                      diffLabel   = diffLabel,   zoneLabel   = zoneLabel,
                      rewardLabel = rewardLabel }

    -- Divider between active hunt and difficulty row
    local divY = ACTIVE_Y - ACTIVE_H - 8
    MakeDivider(parent, divY)

    -- ── Difficulty row: 3 UI-Journeys-Delve-Card panes, text centered ─────────
    local CARD_H = 106
    local GAP    = 8
    local CARD_W = math.floor((availW - GAP * 2) / 3)
    local ROW_Y  = divY - 20
    rows = {}

    for i, diff in ipairs(DIFFICULTIES) do
        local c    = COLORS[diff]
        local xOff = PAD + (i - 1) * (CARD_W + GAP)

        local card = CreateFrame("Frame", nil, parent)
        card:SetSize(CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, ROW_Y)

        local cardBg = card:CreateTexture(nil, "BACKGROUND")
        cardBg:SetAtlas("UI-Journeys-Delve-Card", false)
        cardBg:SetAllPoints(card)

        local tint = card:CreateTexture(nil, "BACKGROUND", nil, 1)
        tint:SetColorTexture(c.r, c.g, c.b, 0.10)
        tint:SetAllPoints(card)

        local row = {}

        -- Difficulty name: Morpheus 22pt, centered horizontally
        local lbl = card:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\MORPHEUS.TTF", 22, "")
        lbl:SetJustifyH("CENTER")
        lbl:SetPoint("TOP", card, "TOP", 0, -14)
        lbl:SetText(diff)
        lbl:SetTextColor(c.r, c.g, c.b)
        lbl:SetShadowColor(0, 0, 0, 0.7) ; lbl:SetShadowOffset(1, -1)
        row.label = lbl

        -- Count: FRIZQT__ 16pt, centered
        local cnt = card:CreateFontString(nil, "OVERLAY")
        cnt:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
        cnt:SetJustifyH("CENTER")
        cnt:SetPoint("TOP", card, "TOP", 0, -42)
        cnt:SetTextColor(1, 1, 1)
        row.countLabel = cnt

        -- Buttons centered at bottom of card
        local sub = MakeBtn(card, "-", 24, 22)
        sub:SetPoint("BOTTOM", card, "BOTTOM", -16, 8)
        sub:SetScript("OnClick", function()
            SetCount(diff, GetCount(diff) - 1) ; UpdateDisplay()
        end)
        row.subBtn = sub

        local add = MakeBtn(card, "+", 24, 22)
        add:SetPoint("BOTTOM", card, "BOTTOM", 16, 8)
        add:SetScript("OnClick", function()
            SetCount(diff, GetCount(diff) + 1) ; UpdateDisplay()
        end)
        row.addBtn = add

        rows[diff] = row
    end

    -- ── Footer: full-width UI-Journeys-Delve-Card, same height as active hunt ──
    local footY    = ROW_Y - CARD_H - 10
    MakeDivider(parent, footY)

    local footCard = CreateFrame("Frame", nil, parent)
    footCard:SetSize(availW, ACTIVE_H)
    footCard:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, footY - 20)

    local footBg = footCard:CreateTexture(nil, "BACKGROUND")
    footBg:SetAtlas("UI-Journeys-Delve-Card", false)
    footBg:SetAllPoints(footCard)

    preyFooterLabel = footCard:CreateFontString(nil, "OVERLAY")
    preyFooterLabel:SetFont("Fonts\\MORPHEUS.TTF", 14, "")
    preyFooterLabel:SetPoint("TOP", footCard, "TOP", 0, -22)
    preyFooterLabel:SetJustifyH("CENTER")
    preyFooterLabel:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    preyFooterLabel:SetShadowColor(0, 0, 0, 0.6) ; preyFooterLabel:SetShadowOffset(1, -1)

    nightmarishLabel = footCard:CreateFontString(nil, "OVERLAY")
    nightmarishLabel:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    nightmarishLabel:SetJustifyH("CENTER")
    nightmarishLabel:SetWordWrap(false)
    nightmarishLabel:SetPoint("BOTTOMLEFT",  footCard, "BOTTOMLEFT",  12, 16)
    nightmarishLabel:SetPoint("BOTTOMRIGHT", footCard, "BOTTOMRIGHT", -12, 16)
    nightmarishLabel:SetShadowColor(0, 0, 0, 0.6) ; nightmarishLabel:SetShadowOffset(1, -1)
end

--------------------------------------------------------------------------------
-- Show / hide our tab
--------------------------------------------------------------------------------

local chromeFrames     = {}
local isSetup          = false
local ejHookRegistered = false
local wasOnPreyTab     = false  -- restore prey panel when EJ reopens

-- Forward declarations — both are defined below but referenced by TryHookEJ
local SetupEncounterJournalTab
local ShowPreyTab

local function TryHookEJ()
    if ejHookRegistered then return end
    if not EncounterJournal then return end
    ejHookRegistered = true
    EncounterJournal:HookScript("OnShow", function()
        -- Defer one tick so Blizzard finishes hiding/showing its own tabs
        -- before we scan. Without this, transient shown states (e.g.
        -- EncounterJournalLootJournalTab briefly visible) inflate the count.
        C_Timer.After(0, function()
            SetupEncounterJournalTab()
            if wasOnPreyTab and preyPanel then
                ShowPreyTab()
            end
        end)
    end)
    PJTLog("SETUP", "Registered EJ OnShow hook")
    if EncounterJournal:IsShown() then
        SetupEncounterJournalTab()
    end
end

--------------------------------------------------------------------------------
-- Show / hide our content panel (no EJ children are ever hidden)
--------------------------------------------------------------------------------

ShowPreyTab = function()
    if not preyPanel then return end
    preyPanel:Show()
    wasOnPreyTab = true

    -- Deselect every button child of EJ that sits in the tab bar,
    -- then explicitly select only our tab.
    local ejBottom = select(2, EncounterJournal:GetCenter()) - EncounterJournal:GetHeight() / 2
    for _, child in ipairs({ EncounterJournal:GetChildren() }) do
        if child ~= preyTabButton and child.GetText then
            local _, cy = child:GetCenter()
            if cy and cy < (ejBottom + 60) then
                PanelTemplates_DeselectTab(child)
            end
        end
    end
    PanelTemplates_SelectTab(preyTabButton)

    PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 1116)
    InitDB()
    UpdateDisplay()
    UpdateActiveHunt()
    PJTLog("TAB", "Prey Hunts tab shown")
end

local function HidePreyTab()
    if preyPanel then preyPanel:Hide() end
    if preyTabButton then PanelTemplates_DeselectTab(preyTabButton) end
    -- Note: wasOnPreyTab is NOT reset here so reopening EJ restores the panel.
    -- It is reset below in the per-tab click hooks.
end

local function HidePreyTabFromClick()
    HidePreyTab()
    wasOnPreyTab = false
end

--------------------------------------------------------------------------------
-- Helpers: find EJ tabs
--------------------------------------------------------------------------------

local function GetAllEJTabs()
    local tabs = {}
    if not EncounterJournal then return tabs end

    -- Always scan children by position — the EJ's own tabs use names like
    -- EncounterJournalJourneysTab, not EncounterJournalTab{N}.
    -- The {N} globals are only our own previously-created tabs, which we exclude.
    local ejBottom = select(2, EncounterJournal:GetCenter()) - EncounterJournal:GetHeight() / 2
    for _, child in ipairs({ EncounterJournal:GetChildren() }) do
        -- Must be shown — hidden tabs (e.g. EncounterJournalLootJournalTab) sit at
        -- the same Y position but should not be counted or anchored against.
        if child:IsShown() and child.GetText then
            local txt = child:GetText()
            if txt and txt ~= "" then
                local _, cy = child:GetCenter()
                if cy and cy < (ejBottom + 60) then
                    table.insert(tabs, { index = #tabs + 1, frame = child, text = txt })
                end
            end
        end
    end

    table.sort(tabs, function(a, b)
        return (select(1, a.frame:GetCenter()) or 0) < (select(1, b.frame:GetCenter()) or 0)
    end)
    for idx, entry in ipairs(tabs) do entry.index = idx end
    return tabs
end

local function FindTabByText(tabs, needle)
    needle = needle:lower()
    for _, entry in ipairs(tabs) do
        if entry.text:lower():find(needle, 1, true) then return entry end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Hook into the Encounter Journal
--------------------------------------------------------------------------------

SetupEncounterJournalTab = function()
    if isSetup then return end
    if not EncounterJournal then return end

    -- On UI reload, our previously created frames still exist as globals.
    -- Detect them and rewire — but if the tab was created at a wrong index
    -- (e.g. index 8 due to the hidden-tab counting bug), discard it so the
    -- first-time path recreates it at the correct position.
    if _G["PreyJournalTabPanel"] then
        preyPanel = _G["PreyJournalTabPanel"]
        local n = 1
        while _G["EncounterJournalTab" .. n] do
            local t = _G["EncounterJournalTab" .. n]
            if (t:GetText() or "") == "Prey Hunts" then
                preyTabButton = t
                preyTabIndex  = n
                break
            end
            n = n + 1
        end

        if preyTabButton then
            -- Verify the index is correct: count shown tabs (excluding ours)
            -- to determine what index we should be at.
            local expectedIndex = 1
            for _, child in ipairs({ EncounterJournal:GetChildren() }) do
                if child ~= preyTabButton and child:IsShown() and child.GetText then
                    local txt = child:GetText()
                    local _, cy = child:GetCenter()
                    local ejCY2 = select(2, EncounterJournal:GetCenter())
                    local ejBot2 = ejCY2 - EncounterJournal:GetHeight() / 2
                    if txt and txt ~= "" and cy and cy < (ejBot2 + 60) then
                        expectedIndex = expectedIndex + 1
                    end
                end
            end

            if preyTabIndex == expectedIndex then
                -- Index is correct — just rewire
                isSetup = true
                preyTabButton:SetScript("OnClick", ShowPreyTab)
                if _G["EncounterJournal_ShowTab"] then
                    hooksecurefunc("EncounterJournal_ShowTab", HidePreyTabFromClick)
                end
                EncounterJournal:HookScript("OnHide", HidePreyTab)
                PJTLog("SETUP", "Reused existing tab on reload, index=" .. preyTabIndex)
                return
            else
                -- Index is stale — clear references so first-time setup reruns
                -- and repositions the button correctly.
                preyTabButton:ClearAllPoints()
                preyTabButton:Hide()
                preyTabButton = nil
                preyTabIndex  = nil
                PJTLog("SETUP", string.format(
                    "Stale tab at index %d (expected %d), recreating",
                    preyTabIndex or 0, expectedIndex))
            end
        end
    end

    isSetup = true
    PJTLog("SETUP", "SetupEncounterJournalTab running (first time)")

    -- ── 1. Find existing tabs, excluding any leftover Prey Hunts tab ─────────
    local existingTabs = {}
    for _, entry in ipairs(GetAllEJTabs()) do
        if entry.text ~= "Prey Hunts" then
            table.insert(existingTabs, entry)
        end
    end
    local lastTabNum = #existingTabs

    local tutorialsEntry = FindTabByText(existingTabs, "tutorial")
    local anchorTab      = tutorialsEntry and tutorialsEntry.frame
                        or (lastTabNum > 0 and existingTabs[lastTabNum].frame)
                        or nil

    preyTabIndex = lastTabNum + 1

    -- ── 2. Create tab button ─────────────────────────────────────────────────
    preyTabButton = CreateFrame(
        "Button",
        "EncounterJournalTab" .. preyTabIndex,
        EncounterJournal,
        "PanelTabButtonTemplate"
    )
    preyTabButton:SetText("Prey Hunts")
    preyTabButton:SetID(preyTabIndex)
    PanelTemplates_TabResize(preyTabButton, 0)
    PanelTemplates_DeselectTab(preyTabButton)   -- ensure it starts in unselected visual state

    if anchorTab then
        preyTabButton:SetPoint("LEFT", anchorTab, "RIGHT", 4, 0)
    else
        preyTabButton:SetPoint("BOTTOMLEFT", EncounterJournal, "BOTTOMLEFT", 10, -28)
    end

    PanelTemplates_SetNumTabs(EncounterJournal, preyTabIndex)

    -- ── 3. Content panel ────────────────────────────────────────────────────
    -- Background and content drawn inside BuildPreyContent using Journeys atlases.
    -- Inner border ring kept here to frame the panel correctly.
    preyPanel = CreateFrame("Frame", "PreyJournalTabPanel", EncounterJournal)
    preyPanel:SetPoint("TOPLEFT",     EncounterJournal, "TOPLEFT",     4, -60)
    preyPanel:SetPoint("BOTTOMRIGHT", EncounterJournal, "BOTTOMRIGHT", -4,  6)
    preyPanel:SetFrameLevel(EncounterJournal:GetFrameLevel() + 50)

    -- Inner border ring (EncounterJournalInset replica, confirmed from panelscan)
    local tl = preyPanel:CreateTexture(nil, "BORDER")
    tl:SetAtlas("UI-Frame-InnerTopLeft",       false) ; tl:SetSize(6,6)
    tl:SetPoint("TOPLEFT", preyPanel, "TOPLEFT", 0, 0)
    local tr = preyPanel:CreateTexture(nil, "BORDER")
    tr:SetAtlas("UI-Frame-InnerTopRight",      false) ; tr:SetSize(6,6)
    tr:SetPoint("TOPRIGHT", preyPanel, "TOPRIGHT", 0, 0)
    local bl = preyPanel:CreateTexture(nil, "BORDER")
    bl:SetAtlas("UI-Frame-InnerBotLeftCorner", false) ; bl:SetSize(6,6)
    bl:SetPoint("BOTTOMLEFT", preyPanel, "BOTTOMLEFT", 0, 0)
    local br = preyPanel:CreateTexture(nil, "BORDER")
    br:SetAtlas("UI-Frame-InnerBotRight",      false) ; br:SetSize(6,6)
    br:SetPoint("BOTTOMRIGHT", preyPanel, "BOTTOMRIGHT", 0, 0)
    local tt = preyPanel:CreateTexture(nil, "BORDER")
    tt:SetAtlas("_UI-Frame-InnerTopTile",  false) ; tt:SetHeight(3)
    tt:SetPoint("TOPLEFT",  preyPanel, "TOPLEFT",  6, 0)
    tt:SetPoint("TOPRIGHT", preyPanel, "TOPRIGHT", -6, 0)
    local tb = preyPanel:CreateTexture(nil, "BORDER")
    tb:SetAtlas("_UI-Frame-InnerBotTile",  false) ; tb:SetHeight(3)
    tb:SetPoint("BOTTOMLEFT",  preyPanel, "BOTTOMLEFT",  6, 0)
    tb:SetPoint("BOTTOMRIGHT", preyPanel, "BOTTOMRIGHT", -6, 0)
    local lt = preyPanel:CreateTexture(nil, "BORDER")
    lt:SetAtlas("!UI-Frame-InnerLeftTile",  false) ; lt:SetWidth(3)
    lt:SetPoint("TOPLEFT",    preyPanel, "TOPLEFT",    0, -6)
    lt:SetPoint("BOTTOMLEFT", preyPanel, "BOTTOMLEFT", 0,  6)
    local rt = preyPanel:CreateTexture(nil, "BORDER")
    rt:SetAtlas("!UI-Frame-InnerRightTile", false) ; rt:SetWidth(3)
    rt:SetPoint("TOPRIGHT",    preyPanel, "TOPRIGHT",    0, -6)
    rt:SetPoint("BOTTOMRIGHT", preyPanel, "BOTTOMRIGHT", 0,  6)

    preyPanel:Hide()
    BuildPreyContent(preyPanel)

    -- ── 4. Wire tab clicks ───────────────────────────────────────────────────
    preyTabButton:SetScript("OnClick", ShowPreyTab)

    -- Hide our panel (and clear restore flag) when another EJ tab is clicked
    for _, entry in ipairs(existingTabs) do
        entry.frame:HookScript("OnClick", HidePreyTabFromClick)
    end

    if _G["EncounterJournal_ShowTab"] then
        hooksecurefunc("EncounterJournal_ShowTab", HidePreyTabFromClick)
    end

    EncounterJournal:HookScript("OnHide", HidePreyTab)   -- close doesn't clear wasOnPreyTab

    PJTLog("SETUP", string.format("Tab created index=%d anchor=%s tabs=%d",
        preyTabIndex, anchorTab and (anchorTab:GetText() or "?") or "none", lastTabNum))
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function GetPreyDifficulty(questID)
    local title = C_QuestLog.GetTitleForQuestID(questID)
    local _, diff = ParsePreyTitle(title)
    return diff
end

local function ShowToast(diff)
    local c = COLORS[diff]
    local r, g, b = math.floor(c.r*255), math.floor(c.g*255), math.floor(c.b*255)
    print(string.format(
        "|cffff6060[PreyJournalTab]|r Auto-tracked |cff%02x%02x%02x%s|r hunt! (%d / %d this week)",
        r, g, b, diff, GetCount(diff), MAX_HUNTS[diff]))
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("QUEST_ACCEPTED")
eventFrame:RegisterEvent("QUEST_REMOVED")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("QUEST_DATA_LOAD_RESULT")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitDB()
            TryHookEJ()   -- EJ may already be loaded in Midnight (baked into FrameXML)
        elseif arg1 == "Blizzard_EncounterJournal" then
            TryHookEJ()   -- EJ just loaded as a separate addon (older client behaviour)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Final fallback: after all addons and UI load, hook EJ if we haven't yet
        TryHookEJ()

    elseif event == "QUEST_ACCEPTED" then
        C_Timer.After(0, UpdateActiveHunt)
        C_Timer.After(0, UpdateNightmarishTask)

    elseif event == "QUEST_REMOVED" then
        C_Timer.After(0, UpdateActiveHunt)
        C_Timer.After(0, UpdateNightmarishTask)

    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_DATA_LOAD_RESULT" then
        -- Only refresh if our panel is visible — these events fire often.
        if preyPanel and preyPanel:IsShown() then
            UpdateActiveHunt()
            UpdateNightmarishTask()
        end

    elseif event == "QUEST_TURNED_IN" then
        local diff = GetPreyDifficulty(arg1)
        if diff then
            SetCount(diff, GetCount(diff) + 1)
            if preyPanel and preyPanel:IsShown() then UpdateDisplay() end
            ShowToast(diff)
            PJTLog("QUEST", string.format("Auto-tracked %s hunt (%d/%d)", diff, GetCount(diff), MAX_HUNTS[diff]))
        end
        C_Timer.After(0, UpdateActiveHunt)
        C_Timer.After(0, UpdateNightmarishTask)
    end
end)

-- Dump all regions (textures + fontstrings) of a frame recursively up to maxDepth
-- into PreyJournalDB.log.
local function LogFrameRegions(frame, label, depth, maxDepth)
    if not frame or depth > maxDepth then return end
    local name = frame:GetName() or "(unnamed)"

    -- Regions on this frame
    for _, region in ipairs({ frame:GetRegions() }) do
        local rtype = region:GetObjectType()
        local rname = region:GetName() or "(unnamed)"
        local shown = region:IsShown() and "shown" or "hidden"
        local rw, rh = region:GetSize()

        if rtype == "Texture" then
            -- GetTextureFilePath returns the actual path string in retail
            local path = "(nil)"
            if region.GetTextureFilePath then
                path = region:GetTextureFilePath() or "(nil)"
            elseif region.GetTexture then
                path = tostring(region:GetTexture() or "(nil)")
            end
            -- Also check for atlas
            local atlas = "(none)"
            if region.GetAtlas then
                atlas = region:GetAtlas() or "(none)"
            end
            PJTLog(label, string.format(
                "%sTexture '%s' shown=%s size=%.0fx%.0f path=%s atlas=%s",
                string.rep("  ", depth), rname, shown, rw or 0, rh or 0, path, atlas))
        elseif rtype == "FontString" then
            local txt = region:GetText() or "(empty)"
            local font, size, flags = region:GetFont()
            PJTLog(label, string.format(
                "%sFontString '%s' shown=%s text='%s' font=%s size=%s",
                string.rep("  ", depth), rname, shown, txt,
                tostring(font or "(nil)"), tostring(size or "?")))
        end
    end

    -- Recurse into children
    for _, child in ipairs({ frame:GetChildren() }) do
        local cname = child:GetName() or "(unnamed)"
        local cw, ch = child:GetSize()
        PJTLog(label, string.format(
            "%sChild '%s' type=%s shown=%s size=%.0fx%.0f",
            string.rep("  ", depth), cname, child:GetObjectType(),
            child:IsShown() and "shown" or "hidden", cw or 0, ch or 0))
        LogFrameRegions(child, label, depth + 1, maxDepth)
    end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

SLASH_PREYJOURNALTAB1 = "/preyhunts"
SLASH_PREYJOURNALTAB2 = "/pjt"

SlashCmdList["PREYJOURNALTAB"] = function(msg)
    local cmd = strtrim(msg):lower()

    -- ── reset ────────────────────────────────────────────────────────────────
    if cmd == "reset" then
        PreyJournalDB.counts = { Normal = 0, Hard = 0, Nightmare = 0 }
        if preyPanel and preyPanel:IsShown() then UpdateDisplay() end
        PJTLog("CMD", "Counts reset by player")
        print("|cffff6060[PreyJournalTab]|r Counts reset.")

    -- ── inspect: dump immediate EJ children to chat ──────────────────────────
    elseif cmd == "inspect" then
        if not EncounterJournal then
            print("|cffff6060[PreyJournalTab]|r Open the Adventure Guide first.")
            return
        end
        local ejCX, ejCY = EncounterJournal:GetCenter()
        local ejW, ejH   = EncounterJournal:GetSize()
        local ejBottom   = ejCY - (ejH / 2)
        print(string.format("|cffff6060[PreyJournalTab]|r EJ size=%.0fx%.0f center=(%.0f,%.0f) strata=%s lvl=%d",
            ejW, ejH, ejCX, ejCY,
            EncounterJournal:GetFrameStrata(), EncounterJournal:GetFrameLevel()))
        local n = 0
        for _, child in ipairs({ EncounterJournal:GetChildren() }) do
            n = n + 1
            local cx, cy = child:GetCenter()
            local cw, ch = child:GetSize()
            print(string.format("  [%d] '%s' | %s | %s | strata=%s lvl=%d | %.0fx%.0f | dist=%.0f",
                n, child:GetName() or "(unnamed)", child:GetObjectType(),
                child:IsShown() and "SHOWN" or "hidden",
                child:GetFrameStrata() or "?", child:GetFrameLevel() or 0,
                cw or 0, ch or 0, (cy or 0) - ejBottom))
        end
        print(string.format("|cffff6060[PreyJournalTab]|r %d children total", n))

    -- ── panelscan: dump all currently-visible EJ content frame regions to log ──
    -- 1. Open Adventure Guide
    -- 2. Click the Dungeons (or Raids, Journeys, etc.) tab you want to scan
    -- 3. Run /preyhunts panelscan
    -- 4. Log out and open WTF/Account/<n>/SavedVariables/PreyJournalTab.lua
    -- The log will contain every texture path, atlas name, and font used
    -- by that panel — ready to replicate in BuildPreyContent.
    elseif cmd == "panelscan" then
        if not EncounterJournal then
            print("|cffff6060[PreyJournalTab]|r Open the Adventure Guide first.")
            return
        end
        PreyJournalDB.log = PreyJournalDB.log or {}
        local scanned = 0

        -- Candidate content frames: scan all direct EJ children that are
        -- currently SHOWN, large (>200px wide), and not our own preyPanel.
        -- This captures whichever panel Blizzard is rendering right now.
        local ejW, ejH = EncounterJournal:GetSize()
        for _, child in ipairs({ EncounterJournal:GetChildren() }) do
            if child ~= preyPanel and child:IsShown() then
                local cw, ch = child:GetSize()
                if cw > 200 and ch > 80 then
                    local label = "PANEL"
                    local cname = child:GetName() or "(unnamed)"
                    PJTLog(label, string.format(
                        "=== Frame '%s' size=%.0fx%.0f strata=%s level=%d ===",
                        cname, cw, ch,
                        child:GetFrameStrata() or "?",
                        child:GetFrameLevel() or 0))
                    LogFrameRegions(child, label, 0, 5)
                    PJTLog(label, "=== End Frame '" .. cname .. "' ===")
                    scanned = scanned + 1
                end
            end
        end

        local total = 0
        for _, e in ipairs(PreyJournalDB.log) do
            if e:find("%[PANEL%]") then total = total + 1 end
        end
        print(string.format(
            "|cffff6060[PreyJournalTab]|r Scanned %d frame(s), logged %d entries.",
            scanned, total))
        print("Log out → |cffffd700WTF/Account/<n>/SavedVariables/PreyJournalTab.lua|r")

    -- ── suggestinspect: deep-dump the SuggestFrame region tree to log ─────────
    -- Switch to Suggested Content tab first, then run this command.
    -- After running, log out and open:
    --   WTF/Account/<name>/SavedVariables/PreyJournalTab.lua
    -- The log array contains every texture path and atlas name used by the card UI.
    elseif cmd == "suggestinspect" then
        local target = _G["EncounterJournalSuggestFrame"]
        if not target then
            print("|cffff6060[PreyJournalTab]|r EncounterJournalSuggestFrame not found. Open Suggested Content tab first.")
            return
        end
        PreyJournalDB.log = PreyJournalDB.log or {}
        PJTLog("SUGGEST", "=== SuggestFrame region dump ===")
        PJTLog("SUGGEST", string.format("Frame shown=%s size=%.0fx%.0f",
            target:IsShown() and "yes" or "no",
            target:GetSize()))
        LogFrameRegions(target, "SUGGEST", 0, 4)
        PJTLog("SUGGEST", "=== End SuggestFrame dump ===")
        local count = 0
        for _, e in ipairs(PreyJournalDB.log) do
            if e:find("%[SUGGEST%]") then count = count + 1 end
        end
        print(string.format(
            "|cffff6060[PreyJournalTab]|r Logged %d entries to |cffffd700PreyJournalDB.log|r.",
            count))
        print("Log out and open: |cffffd700WTF/Account/<name>/SavedVariables/PreyJournalTab.lua|r")

    -- ── log: print recent log entries to chat ────────────────────────────────
    elseif cmd == "log" then
        local entries = PreyJournalDB.log or {}
        local start   = math.max(1, #entries - 19)  -- last 20 lines
        if #entries == 0 then
            print("|cffff6060[PreyJournalTab]|r Log is empty.")
        else
            print(string.format("|cffff6060[PreyJournalTab]|r Last %d log entries:", #entries - start + 1))
            for i = start, #entries do
                print("  " .. entries[i])
            end
        end

    -- ── clearlog ─────────────────────────────────────────────────────────────
    elseif cmd == "clearlog" then
        PreyJournalDB.log = {}
        print("|cffff6060[PreyJournalTab]|r Log cleared.")

    -- ── default: open EJ on our tab ──────────────────────────────────────────
    else
        LoadAddOn("Blizzard_EncounterJournal")
        TryHookEJ()
        if EncounterJournal then
            -- Only call ShowUIPanel if EJ is currently hidden — calling it on an
            -- already-visible EJ can toggle it closed in some panel configurations.
            if not EncounterJournal:IsShown() then
                ShowUIPanel(EncounterJournal)
            end
            -- Defer one frame so the EJ finishes showing before we run setup.
            C_Timer.After(0, function()
                SetupEncounterJournalTab()
                if preyPanel then
                    ShowPreyTab()
                end
            end)
            PJTLog("NAV", "Opened via /preyhunts command")
        else
            print("|cffff6060[PreyJournalTab]|r Could not load the Adventure Guide.")
        end
    end
end
