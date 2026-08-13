-- ============================================================
-- Aegis_SBR_Preview  -  "what would the next press do?"
--
-- A small movable window that shows the ability the rotation would fire right
-- now, with the condition that decided it. Toggled from the minimap button's
-- right-click panel; position and visibility live in AegisDB.preview.
--
-- It works by running the active module's rotation in DECIDE mode - the very
-- same body the real press runs - where the terminal operations record instead
-- of casting and state changes are skipped (see Aegis_SBR:Pick and :Later).
-- Preview and rotation therefore cannot disagree: there is only one priority
-- list. A module opts in by setting previewReady once its rotation is free of
-- casts and state changes that bypass those helpers.
--
-- ONE ability, not a queue. Follow-up rows were tried and removed: derived by
-- asking the priority list again with the chosen ability suppressed, they were
-- correct often enough but barely ever CHANGED, so they carried no information
-- and only made the window taller. Predicting properly would mean simulating
-- energy, the global cooldown and combo points, and the rotation reacts to
-- procs (Clearcasting, the parry window for Riposte, Nightfall) that cannot be
-- predicted even in principle.
-- ============================================================

Aegis_SBR_Preview = {}
local AP = Aegis_SBR_Preview

-- Refresh rate. The global cooldown is about a second, so a once-per-second
-- update looks visibly stuttery next to it; a quarter second reads as live.
-- The cost is one rotation pass, the same work a press already does.
local TICK = 0.25

-- The window is resized by SCALE, not by re-laying out its parts: the grip
-- then keeps the proportions by construction and there is nothing to get wrong
-- when the icon, the three text lines and the caption all have to grow
-- together. BASE_W is the unscaled width the grip measures against.
local BASE_W    = 190

-- How long a shown ability stays put before the display is allowed to change
-- on its own. Some rotations genuinely re-decide several times a second - a
-- hunter's weave hangs off the Auto Shot timer, which crosses its thresholds
-- continuously - and rendering that raw is unreadable. The window is meant to
-- answer "what will my next press do", and presses come about one global
-- cooldown apart, so holding an answer for roughly that long is both calmer
-- AND closer to the question. A real press refreshes it immediately, which is
-- when the answer has actually changed.
local MIN_SHOW = 1.0
local MIN_SCALE = 0.6
local MAX_SCALE = 2.0

-- Colours, matching the config window's flat-dark theme.
local COL_BG     = { 0.05, 0.05, 0.07, 0.92 }
local COL_EDGE   = { 0.25, 0.26, 0.30, 1 }
local COL_SPELL  = { 1, 0.82, 0.0 }
local COL_REASON = { 0.62, 0.64, 0.70 }
local COL_IDLE   = { 0.45, 0.46, 0.50 }
local COL_TITLE  = { 0.55, 0.57, 0.62 }
local COL_GRIP   = { 1, 0.82, 0.0 }

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Spell name -> icon path. The lookup walks the spellbook, so it is done once
-- per name and dropped whenever the spellbook index is (learning a rank moves
-- every slot after it).
local iconCache = {}
local iconEpoch = nil

local function SpellIcon(name)
    if not name then return FALLBACK_ICON end
    -- Tie the cache to the core's spell index: when that is rebuilt the slots
    -- have moved and every cached texture may belong to a different spell.
    if iconEpoch ~= Aegis_SBR.spellIndex then
        iconCache = {}
        iconEpoch = Aegis_SBR.spellIndex
    end
    local hit = iconCache[name]
    if hit then return hit end
    local slot = Aegis_SBR:FindSpellSlot(name)
    local tex = slot and GetSpellTexture(slot, BOOKTYPE_SPELL) or FALLBACK_ICON
    iconCache[name] = tex
    return tex
end

function AP:DB()
    if not AegisDB then return nil end
    if type(AegisDB.preview) ~= "table" then AegisDB.preview = {} end
    return AegisDB.preview
end

function AP:Enabled()
    local db = self:DB()
    return db and db.shown and true or false
end

function AP:Build()
    if self.win then return self.win end
    local f = CreateFrame("Frame", "Aegis_SBR_PreviewFrame", UIParent)
    f:SetWidth(190); f:SetHeight(60)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(COL_BG[1], COL_BG[2], COL_BG[3], COL_BG[4])
    f:SetBackdropBorderColor(COL_EDGE[1], COL_EDGE[2], COL_EDGE[3], COL_EDGE[4])
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local db = AP:DB()
        if db then
            local point, _, relPoint, x, y = this:GetPoint()
            db.pos = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", f, "TOP", 0, -3)
    title:SetText("Next ability")
    title:SetTextColor(COL_TITLE[1], COL_TITLE[2], COL_TITLE[3])
    -- One step below the small font, so the caption stays a label rather than
    -- competing with the ability name. Guarded: GetFont returns nothing if the
    -- font object failed to resolve, and SetFont with a nil path errors.
    local fpath, _, fflags = title:GetFont()
    if fpath then title:SetFont(fpath, 9, fflags) end
    title:SetHeight(10)
    f.title = title

    -- Only as wide as the caption. Anchoring the line to the FontString's two
    -- corners would rely on it auto-sizing to its text, which is not something
    -- to trust after the font has just been changed underneath it - so the
    -- width is measured explicitly and re-measured once the frame is shown.
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOP", title, "BOTTOM", 0, -2)
    rule:SetTexture(COL_EDGE[1], COL_EDGE[2], COL_EDGE[3], 0.8)
    f.rule = rule

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(32); icon:SetHeight(32)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -17)
    icon:SetTexture(FALLBACK_ICON)
    f.icon = icon

    local spell = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spell:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
    spell:SetWidth(132); spell:SetJustifyH("LEFT")
    f.spellText = spell

    local reason = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    reason:SetPoint("TOPLEFT", spell, "BOTTOMLEFT", 0, -3)
    reason:SetWidth(132); reason:SetJustifyH("LEFT")
    reason:SetTextColor(COL_REASON[1], COL_REASON[2], COL_REASON[3])
    f.reasonText = reason

    -- Off-GCD extras (Cold Blood, Adrenaline Rush) ride along in the same
    -- press, so they belong on the same line rather than looking like a
    -- separate step in a queue.
    local extra = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    extra:SetPoint("TOPLEFT", reason, "BOTTOMLEFT", 0, -2)
    extra:SetWidth(132); extra:SetJustifyH("LEFT")
    extra:SetTextColor(0.45, 0.80, 1)
    f.extraText = extra

    local db = self:DB()
    if db and db.scale then f:SetScale(db.scale) end
    if db and db.pos then
        f:SetPoint(db.pos.point or "CENTER", UIParent, db.pos.relPoint or "CENTER",
                   db.pos.x or 0, db.pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -140)
    end

    -- Resize grip, bottom right. Dragging it sets the frame's SCALE from how
    -- far the cursor has moved horizontally, so width and height keep their
    -- ratio without any of the children being touched.
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16); grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(f:GetFrameLevel() + 2)
    -- Own texture, the way Quiver does it: the stock grabber art belongs to a
    -- later client and resolves to nothing here, and squares stacked along a
    -- diagonal come out visibly stepped. Icons/Grip.tga is a 32x32 image whose
    -- two strokes are drawn with soft edges, so shrinking it to 16 pixels reads
    -- as a clean line. Kept white in the file and tinted here, so the colour
    -- stays a decision in code.
    local gt = grip:CreateTexture(nil, "OVERLAY")
    gt:SetAllPoints(grip)
    gt:SetTexture("Interface\\AddOns\\Aegis_SBR\\Icons\\Grip")
    gt:SetVertexColor(COL_GRIP[1], COL_GRIP[2], COL_GRIP[3])
    grip:SetScript("OnEnter", function() this:SetAlpha(1) end)
    grip:SetScript("OnLeave", function() this:SetAlpha(0.75) end)
    grip:SetAlpha(0.75)
    grip:SetScript("OnMouseDown", function() AP:GripStart() end)
    grip:SetScript("OnMouseUp", function() AP:GripStop() end)
    grip:SetScript("OnHide", function() AP:GripStop() end)
    f.grip = grip

    f:SetScript("OnUpdate", function()
        -- The resize runs every frame while the grip is held; only the content
        -- refresh is throttled.
        if AP.gripping then AP:GripUpdate() end
        AP.elapsed = (AP.elapsed or 0) + (arg1 or 0)
        if AP.elapsed < TICK then return end
        AP.elapsed = 0
        AP:Refresh()
    end)

    f:Hide()
    self.win = f
    return f
end

-- Cursor position in UIParent units, which is the space frame scales live in.
local function cursorUI()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    if not s or s == 0 then return x, y end
    return x / s, y / s
end

-- Trim the caption's underline to the text. Called at build time and again on
-- show, because a FontString can report a stale width before it has been
-- laid out once.
function AP:SizeRule()
    local f = self.win
    if not f or not f.rule or not f.title then return end
    local w = f.title:GetStringWidth()
    if not w or w < 10 then w = 56 end   -- fallback: roughly "Next ability"
    f.rule:SetWidth(w + 12)
end

-- Scaling moves the window unless it is compensated for: SetPoint offsets are
-- expressed in the FRAME's own scale, so at scale 2 a stored offset of 140
-- lands 280 UIParent units away. The corner therefore ran off much faster than
-- the mouse. The fix is to freeze the top-left in UIParent units for the whole
-- drag and re-anchor after every scale change, dividing by the new scale.
function AP:ApplyScale(scale)
    local f = self.win
    if not f then return end
    if scale < MIN_SCALE then scale = MIN_SCALE end
    if scale > MAX_SCALE then scale = MAX_SCALE end
    f:SetScale(scale)
    if self.anchorL then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", self.anchorL / scale, self.anchorT / scale)
    end
end

function AP:GripStart()
    local f = self.win
    if not f then return end
    local s0 = f:GetScale() or 1
    local l, t = f:GetLeft(), f:GetTop()
    if not (l and t) then return end        -- never laid out; nothing to anchor to
    -- GetLeft/GetTop come back in the frame's own units, so multiplying by its
    -- scale gives UIParent units - the same space the cursor is read in.
    self.anchorL = l * s0
    self.anchorT = t * s0
    self.gripping = true
end

function AP:GripUpdate()
    local f = self.win
    if not (f and self.anchorL) then return end
    -- Width is taken straight from the cursor's distance to the frozen left
    -- edge, so the bottom-right corner sits under the mouse instead of merely
    -- following its movement.
    local x = cursorUI()
    self:ApplyScale((x - self.anchorL) / BASE_W)
end

function AP:GripStop()
    if not self.gripping then return end
    self.gripping = false
    local f = self.win
    local db = self:DB()
    if not (f and db) then return end
    db.scale = f:GetScale()
    local point, _, relPoint, x, y = f:GetPoint()
    db.pos = { point = point, relPoint = relPoint, x = x, y = y }
end


-- Set the window to an idle message rather than blanking it, so an empty
-- window is never mistaken for the addon having stopped.
function AP:Idle(text)
    self.shownSeq = nil
    local f = self.win
    f.icon:SetTexture(FALLBACK_ICON)
    f.spellText:SetText(text)
    f.spellText:SetTextColor(COL_IDLE[1], COL_IDLE[2], COL_IDLE[3])
    f.reasonText:SetText("")
    f.extraText:SetText("")
end

function AP:Refresh()
    local f = self.win
    if not f or not f:IsShown() then return end

    if not Aegis_SBR.active then self:Idle("no module for this class"); return end
    if not Aegis_SBR.active.previewReady then self:Idle("no preview for this class yet"); return end
    if not UnitExists("target") or UnitIsDead("target") then self:Idle("no target"); return end

    local now = GetTime()
    local seq = Aegis_SBR.pressSeq or 0
    -- Hold the current answer unless a press has happened or it has been up
    -- long enough. self.shownSeq is nil on the first pass, so the very first
    -- render is never delayed.
    if self.shownSeq ~= nil and seq == self.shownSeq
        and (now - (self.shownAt or 0)) < MIN_SHOW then
        return
    end

    local plan = Aegis_SBR:Preview()
    if not plan then self:Idle("no profile active"); return end
    self.shownSeq = seq
    self.shownAt = now

    if plan.spell then
        f.icon:SetTexture(SpellIcon(plan.spell))
        f.spellText:SetText(plan.spell)
        f.spellText:SetTextColor(COL_SPELL[1], COL_SPELL[2], COL_SPELL[3])
    else
        -- A deliberate hold: the rotation has decided to spend the press on
        -- nothing, which is a real decision and worth showing as one. It is
        -- also the normal state for a hunter between Auto Shots, where holding
        -- is exactly the point - so it says so rather than looking broken.
        f.icon:SetTexture(FALLBACK_ICON)
        f.spellText:SetText("hold")
        f.spellText:SetTextColor(COL_IDLE[1], COL_IDLE[2], COL_IDLE[3])
    end
    f.reasonText:SetText(plan.reason or (plan.spell and "" or "nothing due right now"))

    if plan.extras and table.getn(plan.extras) > 0 then
        local s = plan.extras[1]
        for i = 2, table.getn(plan.extras) do s = s .. " + " .. plan.extras[i] end
        f.extraText:SetText("+ " .. s)
    else
        f.extraText:SetText("")
    end
end

function AP:SetShown(on)
    local db = self:DB()
    if db then db.shown = on and true or false end
    local f = self:Build()
    if on then f:Show(); self:SizeRule(); self:Refresh() else f:Hide() end
end

function AP:Toggle()
    self:SetShown(not self:Enabled())
    return self:Enabled()
end

-- Restore visibility after the saved variables are in. Called from the core's
-- ADDON_LOADED path via Aegis_SBR:OnAddonLoaded.
function AP:Restore()
    if self:Enabled() then self:SetShown(true) end
end
