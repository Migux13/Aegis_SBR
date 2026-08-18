-- ============================================================
-- Aegis_SBR_Range  -  distance to target on a self-calibrating band scale
--
-- A small movable window: the exact distance, and a horizontal scale showing
-- which band you are in. Position, visibility and the learned band edges live in
-- AegisDB.range. Toggled from the minimap button's right-click panel or /sbr range.
--
-- WHY A SCALE. A text label ("melee" / "ranged") throws away the thing worth
-- seeing. A hunter has THREE zones, not two: melee reach, then a dead zone where
-- neither melee nor ranged works, then the ranged band. That gap is invisible in
-- text and obvious on a bar. Pure casters have one band and no melee zone, and
-- the same drawing code shows that correctly without a special case.
--
-- WHY IT CALIBRATES ITSELF. Hardcoding "melee = 5yd, ranged = 8..35yd" would be
-- wrong twice over: melee reach includes the TARGET's bounding radius, so it
-- differs per mob, and Turtle is free to rebalance any of it. There is also no
-- API that reports a spell's min/max range. But we can measure: UnitPosition
-- gives an exact distance and ClassicAPI gives an exact in-range verdict, so the
-- edges are learned by watching where the verdict flips and squeezing the
-- estimate toward it. Sensible vanilla defaults until the first observation.
--
-- WHAT IS AUTHORITATIVE. The zone drawing is context and may lag reality by a
-- frame or a mob size; the MARKER COLOUR comes straight from the live in-range
-- check. So the colour is never wrong even while the zones are still settling.
--
-- Fallback without ClassicAPI: the bar falls back to flat thresholds and says so
-- (a trailing dot on the label).
--
-- DISTANCE SOURCES, measured 2026-08-18 in BRS and not what was first assumed:
-- SuperWoW's UnitPosition resolves for PLAYERS only - every NPC target in a
-- 40-minute capture came back nil. The number you see on a mob therefore comes
-- from ClassicAPI's UnitDistanceSquared, which has no name collision and does
-- cover NPCs. So without ClassicAPI this window shows "?" against mobs and a real
-- distance only against players, and the band scale never calibrates (Calibrate
-- needs a distance). That is a degraded window, not a broken one - but it is NOT
-- the "works for everyone" fallback the first version of this comment claimed.
-- ============================================================

Aegis_SBR_Range = {}
local AR = Aegis_SBR_Range

local TICK = 0.1

-- Bar geometry.
local BAR_W   = 168
local BAR_H   = 9
local WIN_W   = 190
local WIN_H   = 84

-- Scale maximum in yards. 40 covers every vanilla range; it grows if a learned
-- ranged edge ever exceeds it, so a Turtle rebalance cannot run off the end.
local SCALE_DEFAULT = 40

-- Starting estimates, replaced by observation as soon as ClassicAPI answers.
local DEF_MELEE_MAX  = 5
local DEF_RANGED_MIN = 8
local DEF_RANGED_MAX = 35

local MELEE_FALLBACK  = 9.9
local RANGED_FALLBACK = 30

-- Probe abilities per class, never shown to the player - they exist only to make
-- the band edges exact. Ordered longest-reach first where ranges differ
-- (Lightning Bolt 30yd before Earth Shock 20yd) so the edge lands on the class's
-- real maximum.
--
-- Paladin's ranged probe is a heal on purpose: IsSpellInRange is documented as
-- range-only and does not reject a wrong-faction target, so a 40yd friendly
-- spell is a valid distance probe against an enemy - and vanilla paladins have
-- no offensive ranged ability to use instead.
local MELEE_PROBE = {
    WARRIOR = { "Heroic Strike", "Rend" },
    ROGUE   = { "Sinister Strike", "Backstab" },
    HUNTER  = { "Raptor Strike" },
    DRUID   = { "Maul", "Claw", "Shred" },
    SHAMAN  = { "Stormstrike" },
    PALADIN = { "Crusader Strike" },
}

local RANGED_PROBE = {
    HUNTER  = { "Auto Shot", "Arcane Shot", "Serpent Sting" },
    MAGE    = { "Frostbolt", "Fireball" },
    WARLOCK = { "Shadow Bolt", "Corruption" },
    PRIEST  = { "Smite", "Mind Blast", "Shadow Word: Pain" },
    DRUID   = { "Wrath", "Moonfire" },
    SHAMAN  = { "Lightning Bolt", "Earth Shock" },
    PALADIN = { "Holy Light" },
    ROGUE   = { "Throw" },
    WARRIOR = { "Throw", "Shoot Bow", "Shoot Gun" },
}

-- Flat-dark theme, matching the config and Preview windows.
local COL_BG     = { 0.05, 0.05, 0.07, 0.92 }
-- Neutral border, used when there is no target and therefore no band to show.
-- Same value the pet window falls back to when there is no pet.
local COL_EDGE   = { 0.30, 0.30, 0.33, 0.9 }
local BORDER_W   = 2
local COL_TITLE  = { 0.55, 0.57, 0.62 }
local COL_TRACK  = { 0.13, 0.13, 0.16, 1 }
local COL_MELEE  = { 0.25, 0.70, 0.32, 1 }
local COL_RANGED = { 0.85, 0.68, 0.10, 1 }
local COL_DEAD   = { 0.45, 0.12, 0.12, 1 }
local COL_TXT_M  = { 0.40, 0.95, 0.45 }
local COL_TXT_R  = { 1, 0.82, 0.0 }
local COL_TXT_O  = { 0.95, 0.35, 0.30 }
local COL_IDLE   = { 0.45, 0.46, 0.50 }
local COL_TICK   = { 0.40, 0.41, 0.46 }

function AR:DB()
    if not AegisDB then return nil end
    if type(AegisDB.range) ~= "table" then AegisDB.range = {} end
    return AegisDB.range
end

function AR:Enabled()
    local db = self:DB()
    return db and db.shown and true or false
end

-- Display scale. Chosen by eye at the keyboard: half size loses too much of the
-- bar's detail, full size is bigger than a permanent HUD element needs.
local DEF_SCALE = 0.65
local MIN_SCALE = 0.3
local MAX_SCALE = 2.0

function AR:Scale()
    local db = self:DB()
    local s = db and db.scale
    if type(s) ~= "number" then s = DEF_SCALE end
    if s < MIN_SCALE then s = MIN_SCALE end
    if s > MAX_SCALE then s = MAX_SCALE end
    return s
end

-- Scaling MOVES the window unless it is compensated for: SetPoint offsets are
-- expressed in the FRAME's own scale, so at scale 0.5 a stored offset of 200
-- lands 100 UIParent units away. The stored offsets are therefore converted from
-- the old scale to the new one, which keeps the window visually put. Same trap
-- the Preview window's ApplyScale documents.
function AR:ApplyScale(scale)
    local f = self.win
    if not f then return end
    if scale < MIN_SCALE then scale = MIN_SCALE end
    if scale > MAX_SCALE then scale = MAX_SCALE end
    local old = f:GetScale() or 1
    local db = self:DB()
    if db then
        db.scale = scale
        if db.pos and old > 0 then
            db.pos.x = (db.pos.x or 0) * old / scale
            db.pos.y = (db.pos.y or 0) * old / scale
        end
    end
    f:SetScale(scale)
    if db and db.pos then
        f:ClearAllPoints()
        f:SetPoint(db.pos.point or "CENTER", UIParent, db.pos.relPoint or "CENTER",
            db.pos.x or 0, db.pos.y or 0)
    end
end

-- Learned band edges, per character.
function AR:Cal()
    local db = self:DB()
    if not db then return nil end
    if type(db.cal) ~= "table" then
        db.cal = { mMax = DEF_MELEE_MAX, rMin = DEF_RANGED_MIN, rMax = DEF_RANGED_MAX }
    end
    return db.cal
end

-- ============================================================
-- Measurement
-- ============================================================
-- Yards - the client's own unit. nil when it cannot be measured, shown as "?"
-- rather than guessed.
--
-- UnitPosition is SuperWoW's. ClassicAPI defines a same-named global with a
-- different shape and load order decides which is live, so the third return is
-- treated as optional - true of both shapes.
function AR:Distance()
    if not UnitExists("target") then return nil end
    if UnitPosition then
        local x1, y1, z1 = UnitPosition("player")
        local x2, y2, z2 = UnitPosition("target")
        if x1 and x2 then
            local dx, dy = x2 - x1, y2 - y1
            local dz = ((z1 and z2) and (z2 - z1)) or 0
            return math.sqrt(dx * dx + dy * dy + dz * dz)
        end
    end
    if UnitDistanceSquared then
        -- pcall'd: a differing arity must degrade to "no reading", never throw
        -- inside an OnUpdate.
        local ok, d = pcall(UnitDistanceSquared, "target")
        if ok and type(d) == "number" and d >= 0 then return math.sqrt(d) end
    end
    return nil
end

function AR:Probe(which)
    local key = "probe_" .. which
    if self[key] ~= nil then
        if self[key] == false then return nil end
        return self[key]
    end
    local _, cls = UnitClass("player")
    local list = (which == "melee" and MELEE_PROBE or RANGED_PROBE)[cls]
    if list and Aegis_SBR and Aegis_SBR.KnowsSpell then
        for i = 1, table.getn(list) do
            if Aegis_SBR:KnowsSpell(list[i]) then self[key] = list[i]; return list[i] end
        end
    end
    self[key] = false
    return nil
end

function AR:Exact()
    return (Aegis_SBR and Aegis_SBR.SpellInRange and Aegis_SBR:Capability("range")) and true or false
end

-- Squeeze the learned edges toward the observed flip point.
--   melee : true above the edge is impossible, so a true reading can only push
--           the edge out; a false reading below the edge pulls it in.
--   ranged: a true reading widens the band; a false reading INSIDE the band
--           means the band is too wide, so the nearer edge is pulled to here.
-- Converges in a few seconds of walking and needs no state beyond the estimate.
function AR:Calibrate(d, inMelee, inRanged)
    local c = self:Cal()
    if not c or not d then return end
    if inMelee ~= nil then
        if inMelee then
            if d > c.mMax then c.mMax = d end
        elseif d < c.mMax then
            c.mMax = d
        end
    end
    if inRanged ~= nil then
        if inRanged then
            if d < c.rMin then c.rMin = d end
            if d > c.rMax then c.rMax = d end
        elseif d >= c.rMin and d <= c.rMax then
            if (d - c.rMin) < (c.rMax - d) then c.rMin = d else c.rMax = d end
        end
    end
    if c.rMin < 0 then c.rMin = 0 end
    if c.mMax < 0 then c.mMax = 0 end
end

-- ============================================================
-- Frame
-- ============================================================
local function seg(parent, layer, col)
    local t = parent:CreateTexture(nil, layer)
    t:SetTexture(col[1], col[2], col[3], col[4] or 1)
    t:SetHeight(BAR_H)
    t:Hide()
    return t
end

function AR:Build()
    if self.win then return self.win end
    local f = CreateFrame("Frame", "Aegis_SBR_RangeFrame", UIParent)
    f:SetWidth(WIN_W); f:SetHeight(WIN_H)
    -- Background only, and a border built from four bars - the same construction
    -- the pet window uses. A backdrop edgeFile cannot be recoloured per band
    -- without also tinting the art, and it would sit under the frame as a second,
    -- thinner outline.
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    f:SetBackdropColor(COL_BG[1], COL_BG[2], COL_BG[3], COL_BG[4])

    local function edge(p1, p2, w, h)
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetPoint(p1, f, p1, 0, 0)
        t:SetPoint(p2, f, p2, 0, 0)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        return t
    end
    f.border = {
        edge("TOPLEFT", "TOPRIGHT", nil, BORDER_W),
        edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, BORDER_W),
        edge("TOPLEFT", "BOTTOMLEFT", BORDER_W, nil),
        edge("TOPRIGHT", "BOTTOMRIGHT", BORDER_W, nil),
    }
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local db = AR:DB()
        if db then
            local point, _, relPoint, x, y = this:GetPoint()
            db.pos = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 11, -6)
    title:SetText("Range")
    title:SetTextColor(COL_TITLE[1], COL_TITLE[2], COL_TITLE[3])
    -- Guarded exactly as the Preview window does: GetFont returns nothing when
    -- the font object failed to resolve, and SetFont with a nil path errors.
    local fp, _, ff = title:GetFont()
    if fp then title:SetFont(fp, 9, ff) end
    f.title = title

    local band = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    band:SetPoint("TOPRIGHT", f, "TOPRIGHT", -11, -6)
    band:SetText("")
    local bp, _, bf = band:GetFont()
    if bp then band:SetFont(bp, 9, bf) end
    f.bandText = band

    local dist = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dist:SetPoint("TOP", f, "TOP", 0, -17)
    dist:SetText("-")
    dist:SetTextColor(COL_IDLE[1], COL_IDLE[2], COL_IDLE[3])
    f.dist = dist

    -- The bar. An anchor frame carries the segments so every offset is measured
    -- from one left edge; positioning textures against the window directly would
    -- have to repeat the inset arithmetic per segment.
    local bar = CreateFrame("Frame", nil, f)
    bar:SetWidth(BAR_W); bar:SetHeight(BAR_H)
    bar:SetPoint("TOP", f, "TOP", 0, -44)
    f.bar = bar

    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetTexture(COL_TRACK[1], COL_TRACK[2], COL_TRACK[3], 1)
    track:SetAllPoints(bar)

    f.segDead   = seg(bar, "BORDER", COL_DEAD)
    f.segMelee  = seg(bar, "ARTWORK", COL_MELEE)
    f.segRanged = seg(bar, "ARTWORK", COL_RANGED)

    -- Position marker, drawn above the zones so it stays readable on any of them.
    local mark = bar:CreateTexture(nil, "OVERLAY")
    mark:SetTexture(1, 1, 1, 1)
    mark:SetWidth(2); mark:SetHeight(BAR_H + 6)
    mark:Hide()
    f.mark = mark

    -- Scale ticks every 10 yards. Rebuilt only when the scale maximum changes.
    f.ticks = {}
    for i = 0, 4 do
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local tp, _, tf = t:GetFont()
        if tp then t:SetFont(tp, 8, tf) end
        t:SetTextColor(COL_TICK[1], COL_TICK[2], COL_TICK[3])
        t:SetPoint("TOP", bar, "BOTTOMLEFT", (BAR_W / 4) * i, -2)
        f.ticks[i] = t
    end

    -- Scale before the anchor: the offsets below are read back by OnDragStop in
    -- this same scale, so setting it first keeps save and restore consistent.
    f:SetScale(self:Scale())

    local db = self:DB()
    if db and db.pos then
        f:SetPoint(db.pos.point or "CENTER", UIParent, db.pos.relPoint or "CENTER",
            db.pos.x or 0, db.pos.y or 0)
    else
        -- Divided by the scale so the default position lands where intended
        -- regardless of how small the window is drawn.
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -200 / self:Scale())
    end

    f:SetScript("OnUpdate", function() AR:OnTick() end)
    f:Hide()
    self.win = f
    return f
end

function AR:BorderColor(r, g, b, a)
    local f = self.win
    if not (f and f.border) then return end
    for i = 1, table.getn(f.border) do
        f.border[i]:SetTexture(r, g, b, a or 1)
    end
end

-- Place a segment between two yard values. Returns false when the span is empty
-- or off-scale, so the caller can hide it.
local function placeSeg(tex, bar, fromYd, toYd, scaleMax)
    if not fromYd or not toYd or toYd <= fromYd then tex:Hide(); return false end
    if fromYd >= scaleMax then tex:Hide(); return false end
    if toYd > scaleMax then toYd = scaleMax end
    local x1 = (fromYd / scaleMax) * BAR_W
    local x2 = (toYd / scaleMax) * BAR_W
    tex:ClearAllPoints()
    tex:SetPoint("LEFT", bar, "LEFT", x1, 0)
    tex:SetWidth(x2 - x1)
    tex:Show()
    return true
end

function AR:OnTick()
    local now = GetTime()
    if (now - (self.lastTick or 0)) < TICK then return end
    self.lastTick = now
    local f = self.win
    if not f then return end

    if not UnitExists("target") then
        f.dist:SetText("-")
        f.dist:SetTextColor(COL_IDLE[1], COL_IDLE[2], COL_IDLE[3])
        f.bandText:SetText("no target")
        f.bandText:SetTextColor(COL_IDLE[1], COL_IDLE[2], COL_IDLE[3])
        f.mark:Hide()
        self:BorderColor(COL_EDGE[1], COL_EDGE[2], COL_EDGE[3], COL_EDGE[4])
        return
    end

    local d = self:Distance()
    f.dist:SetText(d and string.format("%.1f", d) .. " yd" or "?")

    -- Live verdicts. These are the authority for the colour; the zones below are
    -- only context and may still be settling.
    local exact = self:Exact()
    local inMelee, inRanged
    if exact then
        local m = self:Probe("melee")
        local r = self:Probe("ranged")
        if m then inMelee = Aegis_SBR:SpellInRange(m, "target") end
        if r then inRanged = Aegis_SBR:SpellInRange(r, "target") end
        if d then self:Calibrate(d, inMelee, inRanged) end
    end

    local c = self:Cal() or { mMax = DEF_MELEE_MAX, rMin = DEF_RANGED_MIN, rMax = DEF_RANGED_MAX }
    local scaleMax = SCALE_DEFAULT
    if c.rMax and c.rMax + 5 > scaleMax then scaleMax = math.ceil((c.rMax + 5) / 10) * 10 end
    if self.scaleShown ~= scaleMax then
        self.scaleShown = scaleMax
        for i = 0, 4 do f.ticks[i]:SetText(tostring(math.floor(scaleMax / 4 * i))) end
    end

    local hasMelee  = self:Probe("melee") ~= nil
    local hasRanged = self:Probe("ranged") ~= nil

    if exact then
        -- Dead zone: the gap between melee reach and the ranged minimum. Drawn
        -- first so the two live bands paint over any overlap.
        if hasMelee and hasRanged and c.rMin > c.mMax then
            placeSeg(f.segDead, f.bar, c.mMax, c.rMin, scaleMax)
        else
            f.segDead:Hide()
        end
        if hasMelee then placeSeg(f.segMelee, f.bar, 0, c.mMax, scaleMax) else f.segMelee:Hide() end
        if hasRanged then placeSeg(f.segRanged, f.bar, c.rMin, c.rMax, scaleMax) else f.segRanged:Hide() end
    else
        -- Flat-threshold fallback: no dead zone is knowable, so none is drawn
        -- rather than invented.
        f.segDead:Hide()
        placeSeg(f.segMelee, f.bar, 0, MELEE_FALLBACK, scaleMax)
        placeSeg(f.segRanged, f.bar, MELEE_FALLBACK, RANGED_FALLBACK, scaleMax)
    end

    -- Marker.
    if d then
        local x = (d / scaleMax) * BAR_W
        if x < 0 then x = 0 elseif x > BAR_W then x = BAR_W end
        f.mark:ClearAllPoints()
        f.mark:SetPoint("CENTER", f.bar, "LEFT", x, 0)
        f.mark:Show()
    else
        f.mark:Hide()
    end

    -- Label and colour, from the live verdict where there is one.
    local label, col
    if exact and (inMelee ~= nil or inRanged ~= nil) then
        if inMelee then label, col = "melee", COL_TXT_M
        elseif inRanged then label, col = "ranged", COL_TXT_R
        elseif d and c.rMin and d < c.rMin then label, col = "too close", COL_TXT_O
        else label, col = "out of range", COL_TXT_O end
    else
        -- A trailing dot marks a threshold guess rather than the engine's own
        -- geometry, so an estimate is never mistaken for a measurement.
        if CheckInteractDistance("target", 3) then label, col = "melee .", COL_TXT_M
        elseif d and d <= RANGED_FALLBACK then label, col = "ranged .", COL_TXT_R
        else label, col = "out of range .", COL_TXT_O end
    end
    f.bandText:SetText(label)
    f.bandText:SetTextColor(col[1], col[2], col[3])
    f.dist:SetTextColor(col[1], col[2], col[3])
    -- The border carries the same verdict as the text, so the band is readable
    -- from peripheral vision without looking at the window directly - which is
    -- the point of a HUD element you keep on screen while fighting.
    self:BorderColor(col[1], col[2], col[3], 1)
end

function AR:SetShown(on)
    local db = self:DB()
    if db then db.shown = on and true or false end
    local f = self:Build()
    if on then f:Show() else f:Hide() end
    if Aegis_SBR_Minimap and Aegis_SBR_Minimap.RefreshPanel then
        Aegis_SBR_Minimap:RefreshPanel()
    end
end

function AR:Toggle()
    self:SetShown(not self:Enabled())
    return self:Enabled()
end

-- Drop the learned edges and the saved position. Useful after a weapon change
-- (a longer ranged weapon moves the outer edge) or if the window is lost
-- off-screen.
function AR:Reset()
    local db = self:DB()
    if not db then return end
    db.cal = nil
    db.pos = nil
    db.scale = nil
    self.scaleShown = nil
    if self.win then
        self.win:SetScale(self:Scale())
        self.win:ClearAllPoints()
        self.win:SetPoint("CENTER", UIParent, "CENTER", 0, -200 / self:Scale())
    end
end

-- Restore visibility after the saved variables are in. Called from the core's
-- ADDON_LOADED path via Aegis_SBR:OnAddonLoaded, same as Preview and Pet.
function AR:Restore()
    if self:Enabled() then self:SetShown(true) end
end
