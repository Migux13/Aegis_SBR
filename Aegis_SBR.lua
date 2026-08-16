-- ============================================================
-- Aegis: Single Button Rotation (Aegis_SBR)  -  configurable
-- one-button rotation, multi class. Turtle WoW 1.12 (SuperWoW).
-- Formerly AutoRota.
-- ============================================================
-- The core holds everything that is not class specific. Each class
-- ships a module (Class_<Name>.lua) that registers itself here. On
-- login the player class is detected and the matching module becomes
-- active, providing its templates, profile rules, rotation and UI.
-- ============================================================
-- Run with a bare macro, spam it:   /sbr
-- Configure per character:          /sbr ui
-- Other commands: list, use <name>, off, new <name> [template],
--   del <name>, check, reset, debug, trace, plus class commands.
-- /aegis is the long form; /ar stays as a legacy alias.
-- ============================================================

Aegis_SBR = {
    ver = "1.1.7",
    classes = {},     -- token -> module table
    active = nil,      -- the module for this character's class
    Loaded = false,
    lastMsg = 0,
}

-- A class module inherits every shared helper through __index, so inside
-- a module "self:Cast(...)" resolves to the core while "self.weaving" and
-- the like stay private to the module instance.
function Aegis_SBR:NewClassModule(token)
    local m = setmetatable({ classToken = token }, { __index = self })
    self.classes[token] = m
    return m
end

-- Shared chat output, inherited by every class module (so modules use
-- self:Msg(...) instead of redefining their own local printer).
function Aegis_SBR:Msg(text, r, g, b)
    DEFAULT_CHAT_FRAME:AddMessage("Aegis: " .. text, r or 1, g or 0.8, b or 0.0)
end

local function msgOut(text, r, g, b) Aegis_SBR:Msg(text, r, g, b) end

-- ============================================================
-- Shared rotation and utility helpers (class independent)
-- ============================================================

-- One pass over the spellbook builds a name -> slot index (last slot wins, so
-- the highest rank is kept, same as the old linear scan) plus a name -> max
-- rank table. Every later lookup is then a table read instead of a full scan.
-- The index is built lazily and dropped on SPELLS_CHANGED, so learning a spell
-- or a new rank triggers a rebuild on the next lookup.
function Aegis_SBR:BuildSpellIndex()
    local idx, ranks = {}, {}
    local i = 1
    while true do
        local n, rnk = GetSpellName(i, BOOKTYPE_SPELL)
        if not n then break end
        idx[n] = i
        local digits = string.gsub(rnk or "", "%D", "")
        local num = tonumber(digits) or 1
        if not ranks[n] or num > ranks[n] then ranks[n] = num end
        i = i + 1
    end
    Aegis_SBR.spellIndex = idx
    Aegis_SBR.spellRanks = ranks
end

function Aegis_SBR:InvalidateSpellIndex()
    Aegis_SBR.spellIndex = nil
    Aegis_SBR.spellRanks = nil
    Aegis_SBR.costCache  = nil   -- slots moved, and a talent may have changed a cost
    Aegis_SBR.radiusCache = nil
end

function Aegis_SBR:FindSpellSlot(name)
    if not Aegis_SBR.spellIndex then Aegis_SBR:BuildSpellIndex() end
    return Aegis_SBR.spellIndex[name]
end

-- Highest known rank number of a spell (0 if unknown). Used for downranking.
function Aegis_SBR:MaxRank(name)
    if not Aegis_SBR.spellRanks then Aegis_SBR:BuildSpellIndex() end
    return Aegis_SBR.spellRanks[name] or 0
end

function Aegis_SBR:KnowsSpell(name)
    return self:FindSpellSlot(name) ~= nil
end

-- ============================================================
-- Spell cost. Read from the spellbook tooltip rather than kept in a table:
-- talents change costs (Improved Sinister Strike, Improved Shred, ...), Turtle
-- rebalances them, and a hardcoded number that is wrong by 5 energy is worse
-- than no check at all - it would silently hold back an ability the character
-- can actually afford. The tooltip is what the client itself believes, so it is
-- right by construction on any server and at any talent build.
--
-- Cached per spell name and dropped with the spellbook index, which
-- SPELLS_CHANGED invalidates - and learning a rank or spending a talent point
-- fires exactly that.
--
-- Returns nil when the cost cannot be read (no tooltip line, unknown spell).
-- Callers must treat nil as "affordable": an unreadable cost may never be the
-- reason an ability does not fire.
-- ============================================================
local SCAN_TIP = "Aegis_SBR_ScanTip"
local scanTip

function Aegis_SBR:SpellCost(name)
    if not self.costCache then self.costCache = {} end
    local hit = self.costCache[name]
    if hit then return hit end
    local slot = self:FindSpellSlot(name)
    if not slot then return nil end          -- not cached: it may be learned later
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", SCAN_TIP, nil, "GameTooltipTemplate")
    end
    -- SetOwner is repeated before every read, not done once at creation: a
    -- tooltip that has been cleared or hidden in between can refuse to
    -- populate its lines without a live owner, and that failure is silent -
    -- it just reads back as "no cost".
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetSpell(slot, BOOKTYPE_SPELL)
    -- The cost sits on the left of the second line ("45 Energy"), but a spell
    -- without one puts something else there, so a few lines are checked. The
    -- pattern needs the WHOLE line to be a number and a single word, which is
    -- what keeps "30 yd range" and "6 sec cooldown" from being read as costs.
    local cost
    for i = 2, 4 do
        local fs = getglobal(SCAN_TIP .. "TextLeft" .. i)
        local txt = fs and fs:GetText()
        if txt then
            -- Four digit mana costs are printed with a thousands separator.
            txt = string.gsub(txt, ",", "")
            local _, _, num = string.find(txt, "^(%d+) %a+$")
            if num then cost = tonumber(num); break end
        end
    end
    -- Only SUCCESS is cached. A failed read is not necessarily a spell without
    -- a cost - it can equally be a tooltip that did not populate this once -
    -- and caching that would freeze the wrong answer in place until the next
    -- SPELLS_CHANGED, which is exactly the kind of intermittent, unreproducible
    -- behaviour that is worst to debug. Re-scanning costs one hidden tooltip.
    if cost then self.costCache[name] = cost end
    return cost
end

-- The radius a spell affects, in yards, or nil when the tooltip does not say.
--
-- Read rather than tabulated, for the same reason SpellCost is: a totem's reach
-- differs per totem and per rank (a Magma hits eight yards, an aura totem
-- twenty), and a guessed twenty would call a Magma "in range" from fifteen
-- yards away while it is hitting nothing at all.
--
-- The number lives in the description text, not in the range field on line two
-- - that one is how far you may CAST it, which for a totem is your own feet. So
-- the left-hand lines are scanned for the first "N yards"; scanning the left
-- side only is also what keeps the cast range on the right of line two out of
-- it. Pattern and approach follow Call of Elements, which does the same read.
function Aegis_SBR:SpellRadius(name)
    if not self.radiusCache then self.radiusCache = {} end
    local hit = self.radiusCache[name]
    if hit then return hit end
    local slot = self:FindSpellSlot(name)
    if not slot then return nil end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", SCAN_TIP, nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetSpell(slot, BOOKTYPE_SPELL)
    local radius
    for i = 2, 8 do
        local fs = getglobal(SCAN_TIP .. "TextLeft" .. i)
        local txt = fs and fs:GetText()
        if txt then
            local _, _, n = string.find(txt, "(%d+)%.?%d* +ya?r?ds?")
            if n then radius = tonumber(n); break end
        end
    end
    -- Only successful reads are cached, same as SpellCost: a tooltip that
    -- failed to populate once must not freeze "no radius" in place.
    if radius then self.radiusCache[name] = radius end
    return radius
end

-- Can the player pay for this spell right now? UnitMana returns whichever
-- resource the class uses, so this is energy on a rogue, rage on a warrior and
-- mana everywhere else, with no per-class branch needed.
function Aegis_SBR:CanAfford(name)
    local cost = self:SpellCost(name)
    if not cost then return true end
    return (UnitMana("player") or 0) >= cost
end

-- ============================================================
-- Decide / Perform
--
-- A class module may split its rotation in two: Decide(cfg) works out what the
-- press should do and returns a PLAN without touching the game, and Perform
-- carries it out. Nothing else changes - Rotate stays the entry point and calls
-- both - but it lets anything else ask "what would happen if I pressed now?"
-- without a cast going out. That is what the upcoming-spell window uses.
--
-- A plan is:
--   spell   the one global-cooldown ability, or nil for a deliberate hold
--   extras  off-GCD casts to fire first, in order (Cold Blood, Adrenaline Rush)
--   queue   cast through the SuperWoW queue instead, for cast-time spells
--   reason  short human text, shown in the window
--
-- The rule that makes this worth doing: Decide must have NO side effects, so
-- calling it four times a second for a preview cannot disturb the rotation.
-- Timers stamped after a cast belong in Perform or in the caller, never in
-- Decide.
-- ============================================================
function Aegis_SBR:Perform(mod, plan)
    if not plan then return end
    -- Routed through the two-mode terminal operations, so a module that builds
    -- an explicit plan behaves the same under a preview as one that calls Pick
    -- directly in its body.
    if plan.extras then
        for i = 1, table.getn(plan.extras) do mod:PickExtra(plan.extras[i]) end
    end
    if not plan.spell then return end
    if plan.queue then mod:PickQueue(plan.spell, plan.reason)
    else mod:Pick(plan.spell, plan.reason) end
end

-- What the rotation would do right now, without doing it. nil when the active
-- class has not been converted yet, or when there is no profile.
-- ------------------------------------------------------------
-- One rotation body, two modes.
--
-- A module's priority list has to answer two questions: "do it" when the
-- button is pressed, and "what would you do" four times a second for the
-- preview window. Keeping two versions of a priority list would guarantee they
-- drift apart, and rewriting each list into one that returns a plan means
-- touching every branch of every class - which is exactly where a rotation
-- gets changed by accident.
--
-- So the SAME body runs in both modes and only the terminal operations differ:
--
--   Pick / PickQueue  the one global-cooldown ability. Casts, or records.
--   PickExtra         an off-GCD cast that does not end the press.
--   Later(fn)         a state change - a timer stamp, an expiry reset. Runs on
--                     a real press only; a preview must never mutate anything.
--
-- Pick returns exactly what Cast returned before it (false when the spell is
-- not known), so control flow through a priority list is untouched.
--
-- The flags live on Aegis_SBR itself, never on the module: modules inherit
-- from it, so a module reading self.deciding finds the core's value, and there
-- is only ever one mode in play.
-- ------------------------------------------------------------
function Aegis_SBR:Pick(name, reason)
    if not name or not self:KnowsSpell(name) then return false end
    if Aegis_SBR.deciding then
        local p = Aegis_SBR.decidePlan
        p.spell = name
        p.reason = reason
        return true
    end
    -- Counts real presses. The preview window uses it to know when the answer
    -- has legitimately changed, instead of redrawing on every sub-second wobble.
    Aegis_SBR.pressSeq = (Aegis_SBR.pressSeq or 0) + 1
    CastSpellByName(name)
    return true
end

function Aegis_SBR:PickQueue(name, reason)
    if not name or not self:KnowsSpell(name) then return false end
    if Aegis_SBR.deciding then
        local p = Aegis_SBR.decidePlan
        p.spell = name
        p.reason = reason
        p.queue = true
        return true
    end
    -- Counts real presses. The preview window uses it to know when the answer
    -- has legitimately changed, instead of redrawing on every sub-second wobble.
    Aegis_SBR.pressSeq = (Aegis_SBR.pressSeq or 0) + 1
    if QueueSpellByName then QueueSpellByName(name) else CastSpellByName(name) end
    return true
end

function Aegis_SBR:PickExtra(name)
    if not name or not self:KnowsSpell(name) then return false end
    if Aegis_SBR.deciding then
        table.insert(Aegis_SBR.decidePlan.extras, name)
        return true
    end
    CastSpellByName(name)
    return true
end

function Aegis_SBR:Later(fn)
    if Aegis_SBR.deciding then return end
    fn()
end

-- What the rotation would do right now, without doing it. nil when the class
-- has not been converted, when there is no profile, or when the run failed -
-- a preview that errors must never leave the mode flag set, or the next real
-- press would record instead of cast.
function Aegis_SBR:Preview()
    local mod = self.active
    if not mod or not mod.previewReady then return nil end
    local cfg = self:GetActiveProfile()
    if not cfg then return nil end
    -- The same preparation a real press does. Without it the preview reads
    -- stale buff and debuff data and takes different branches than the press
    -- it is supposed to be predicting - which shows up as the window flicking
    -- between abilities. Both snapshots are pure caches of the current game
    -- state, so refreshing them here costs nothing and changes nothing.
    self:SnapshotBuffs()
    self:SnapshotTargetDebuffs()
    Aegis_SBR.decidePlan = { extras = {} }
    Aegis_SBR.deciding = true
    local ok = pcall(function() mod:Rotate(cfg) end)
    Aegis_SBR.deciding = false
    local plan = Aegis_SBR.decidePlan
    Aegis_SBR.decidePlan = nil
    if not ok then return nil end
    return plan
end

function Aegis_SBR:Cast(name)
    if self:KnowsSpell(name) then CastSpellByName(name); return true end
    return false
end

function Aegis_SBR:IsReady(name)
    local slot = self:FindSpellSlot(name)
    if not slot then return false end
    local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
    if start == 0 then return true end
    return (start + dur - GetTime()) <= 0
end

-- Human readable cooldown state for tracing
function Aegis_SBR:CDInfo(name)
    local slot = self:FindSpellSlot(name)
    if not slot then return "unknown" end
    local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
    if start == 0 then return "ready" end
    local rem = start + dur - GetTime()
    if dur <= 1.55 then return string.format("gcd %.1fs", rem) end   -- only the global cooldown
    return string.format("cd %.1fs", rem)
end

-- True if the spell's OWN cooldown is free, ignoring the global cooldown.
-- A short reported duration (<= ~1.5s) means only the GCD is active, which
-- we treat as "ready" so a held priority spell does not lose the GCD-edge
-- race to the unconditional seal recast.
function Aegis_SBR:OwnCDReady(name)
    local slot = self:FindSpellSlot(name)
    if not slot then return false end
    local start, dur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
    if start == 0 then return true end
    if dur <= 1.55 then return true end
    return (start + dur - GetTime()) <= 0
end

-- ============================================================
-- Swing timer tracker. A plain white swing shows in the combat log as
-- "You hit/crit/miss ...", while a named ability or seal shows as
-- "Your <name> ...". Only plain swings move the timer. We predict the next
-- swing from the last one plus the main hand speed, the same idea AttackBar
-- uses. This is the foundation for seal twisting.
-- ============================================================
function Aegis_SBR:OnSwingMessage(msg)
    if not msg then return end
    if string.find(msg, "^Your ") then return end   -- a named ability or seal, not a white swing
    if string.find(msg, "^You ") then
        self.lastSwing = GetTime()
        local mh = UnitAttackSpeed("player")
        if mh and mh > 0 then self.swingSpeed = mh end
    end
end

-- Predicted seconds until the next white swing, or nil if unknown.
function Aegis_SBR:SwingTimeLeft()
    if not self.lastSwing or not self.swingSpeed or self.swingSpeed <= 0 then return nil end
    local elapsed = GetTime() - self.lastSwing
    return self.swingSpeed - math.mod(elapsed, self.swingSpeed)
end

-- Throttled per-press trace, toggled with /sbr trace. Accepts any number of
-- lines; the throttle is checked once so multi-line traces are never half
-- swallowed (Lua 5.0 packs varargs into the implicit `arg` table).
-- ============================================================
-- Press log (AegisLog). The 1.12 Lua sandbox has no file access at all - no
-- io, no os - so the only way to get data off the client is a SavedVariable,
-- which the client serialises to
--   WTF\Account\<ACCOUNT>\<Realm>\<Char>\SavedVariables\Aegis_SBR.lua
-- on /reload or logout. It is therefore NOT live: nothing is on disk until
-- one of those happens. Kept in its own SavedVariable rather than inside
-- AegisDB so a big log can never bloat or endanger the profile data, and so
-- it can be cleared on its own.
--
-- A true ring buffer (write index that wraps) rather than append-and-trim:
-- table.remove(t, 1) would shift every entry on every press, which at a
-- multi-thousand cap is real work inside the rotation's hot path.
-- ============================================================
local LOG_MAX = 2000

function Aegis_SBR:LogInit(reset)
    if type(AegisLog) ~= "table" then AegisLog = {} end
    if reset or type(AegisLog.entries) ~= "table" then
        AegisLog.entries = {}
        AegisLog.pos = 0        -- entries written since the last clear (can exceed max)
        AegisLog.max = LOG_MAX
        AegisLog.started = date and date("%Y-%m-%d %H:%M:%S") or ""
        AegisLog.t0 = GetTime()
    end
    if not AegisLog.t0 then AegisLog.t0 = GetTime() end
    if not AegisLog.max then AegisLog.max = LOG_MAX end
    return AegisLog
end

-- Append one line. Timestamps are seconds since the log was (re)started, so
-- the file stays readable without needing wall-clock per entry.
function Aegis_SBR:LogWrite(text)
    if not text then return end
    local L = self:LogInit()
    L.pos = (L.pos or 0) + 1
    local slot = math.mod(L.pos - 1, L.max) + 1
    L.entries[slot] = string.format("%.2f|%s", GetTime() - (L.t0 or 0), text)
end

-- True when anything wants trace output - chat, the press log, or both. The
-- class modules build their trace strings inside a guard so the concatenation
-- is skipped entirely when nobody is listening; that guard MUST use this and
-- not self.trace, or enabling only the log records nothing (the string is
-- never built, so Trace is never even called).
function Aegis_SBR:Tracing()
    -- A preview runs the same body four times a second; letting it trace would
    -- bury the real presses in the log and make the press log useless.
    if Aegis_SBR.deciding then return false end
    return (self.trace or self.logging) and true or false
end

-- Chat trace and the press log are independent on purpose: the chat line is
-- throttled to stay readable while playing, but the log wants EVERY press or
-- the CP distribution it is meant to answer would be a biased sample.
-- Only the FIRST line is logged. Callers pass the per-press state line first and
-- any supplementary diagnostics after it; those extras are static for a whole
-- session (the rogue's "rank: ..." line, for instance, never changes while
-- playing), so recording them once per press doubled both the file size and the
-- number of ring slots burned, for nothing. They stay in the chat trace, which
-- is where they are actually useful.
function Aegis_SBR:Trace(...)
    if not self.trace and not self.logging then return end
    if self.logging and arg[1] then self:LogWrite(arg[1]) end
    if not self.trace then return end
    local now = GetTime()
    if now - (self.traceT or 0) < 0.4 then return end
    self.traceT = now
    for i = 1, arg.n do
        if arg[i] then DEFAULT_CHAT_FRAME:AddMessage("SBR: " .. arg[i], 0.6, 0.8, 1.0) end
    end
end

-- One pass over the player's buffs per rotation press. Every HasBuff/BuffTime
-- in the same press then reads this table instead of rescanning all 32 slots.
-- Keyed by GetTime(), which is constant within a frame, so the snapshot can
-- never be read stale.
function Aegis_SBR:SnapshotBuffs()
    if not GetPlayerBuff then return end
    local snap = {}
    for i = 0, 31 do
        local ix = GetPlayerBuff(i, "HELPFUL")
        if ix and ix ~= -1 then
            local id = GetPlayerBuffID and GetPlayerBuffID(ix)
            if id then
                if id < -1 then id = id + 65536 end
                local nm = SpellInfo and SpellInfo(id)
                if nm and not snap[nm] then
                    local tl = GetPlayerBuffTimeLeft(ix) or 0
                    local st = (GetPlayerBuffApplications and GetPlayerBuffApplications(ix)) or 1
                    snap[nm] = { tl, st }
                end
            end
        end
    end
    self.buffSnap = snap
    self.buffSnapT = GetTime()
end

function Aegis_SBR:ScanBuff(name)
    -- fresh snapshot from this frame: O(1) read
    if self.buffSnap and self.buffSnapT == GetTime() then
        local e = self.buffSnap[name]
        if e then return e[1], e[2] end
        return nil, 0
    end
    -- no snapshot (UI refresh, slash commands, etc.): full scan as before
    if not GetPlayerBuff then return nil, 0 end
    for i = 0, 31 do
        local ix = GetPlayerBuff(i, "HELPFUL")
        if ix and ix ~= -1 then
            local id = GetPlayerBuffID and GetPlayerBuffID(ix)
            if id then
                if id < -1 then id = id + 65536 end
                if SpellInfo and SpellInfo(id) == name then
                    local tl = GetPlayerBuffTimeLeft(ix) or 0
                    local st = (GetPlayerBuffApplications and GetPlayerBuffApplications(ix)) or 1
                    return tl, st
                end
            end
        end
    end
    return nil, 0
end

function Aegis_SBR:HasBuff(name)
    local tl = self:ScanBuff(name)
    return tl ~= nil
end

function Aegis_SBR:BuffTime(name)
    local tl, st = self:ScanBuff(name)
    return tl or 0, st or 0
end

-- ============================================================
-- Target debuff detection. One pass per press over the target's debuffs,
-- resolving each to its spell NAME through SuperWoW's spell id (the id is
-- returned by UnitDebuff and mapped with SpellInfo, the same id path the
-- player buff snapshot uses). Name matching is exact and rank/locale proof,
-- so it replaces the old icon-fragment guessing. The icon texture is kept in
-- the snapshot as a fallback for clients without SuperWoW (or ids we cannot
-- map), so detection degrades to the previous behaviour rather than breaking.
-- ============================================================
function Aegis_SBR:SnapshotTargetDebuffs()
    local byName, list = {}, {}
    if UnitExists("target") then
        for i = 1, 40 do
            -- vanilla returns (texture, applications, dispelType); SuperWoW
            -- appends the spell id. applications is always the 2nd return, so
            -- the id is the first NUMERIC value among the trailing returns
            -- (dispelType is a string or nil and is skipped naturally).
            local tex, stacks, d3, d4, d5 = UnitDebuff("target", i)
            if not tex then break end
            stacks = stacks or 0
            local id
            if type(d3) == "number" then id = d3
            elseif type(d4) == "number" then id = d4
            elseif type(d5) == "number" then id = d5 end
            if id and SpellInfo then
                if id < -1 then id = id + 65536 end
                local nm = SpellInfo(id)
                if nm and nm ~= "" and byName[nm] == nil then byName[nm] = stacks end
            end
            table.insert(list, { tex = tex, stacks = stacks })
        end
    end
    self.tdebuffSnap = { byName = byName, list = list }
    self.tdebuffSnapT = GetTime()
end

-- Returns up (bool), stacks. Tries the exact spell name first (SuperWoW id
-- path), then the optional icon-fragment fallback. Builds the snapshot on
-- demand when it is stale, so slash commands and the UI work outside a press.
function Aegis_SBR:ScanTargetDebuff(name, texFrag)
    if not (self.tdebuffSnap and self.tdebuffSnapT == GetTime()) then
        self:SnapshotTargetDebuffs()
    end
    local snap = self.tdebuffSnap
    if name and name ~= "" then
        local s = snap.byName[name]
        if s ~= nil then return true, s end
    end
    if texFrag and texFrag ~= "" then
        for i = 1, table.getn(snap.list) do
            local e = snap.list[i]
            if e.tex and string.find(e.tex, texFrag) then return true, e.stacks end
        end
    end
    return false, 0
end

function Aegis_SBR:TargetDebuffUp(name, texFrag)
    local up = self:ScanTargetDebuff(name, texFrag)
    return up
end

function Aegis_SBR:TargetDebuffStacks(name, texFrag)
    local up, st = self:ScanTargetDebuff(name, texFrag)
    if up then return st or 0 end
    return 0
end

-- True when SuperWoW's id->name path is available, so a debuff without a
-- known icon fragment can still be tracked exactly (used by modules to decide
-- between exact upkeep and a blind reapply timer).
function Aegis_SBR:CanResolveDebuffNames()
    return SpellInfo ~= nil
end

function Aegis_SBR:ManaPct()
    local mx = UnitManaMax("player")
    if mx and mx > 0 then return UnitMana("player") / mx * 100 end
    return 100
end

function Aegis_SBR:PlayerHPPct()
    local mx = UnitHealthMax("player")
    if mx and mx > 0 then return UnitHealth("player") / mx * 100 end
    return 100
end

function Aegis_SBR:TargetHPPct()
    local mx = UnitHealthMax("target")
    if mx and mx > 0 then return UnitHealth("target") / mx * 100 end
    return 100
end

-- ============================================================
-- Temporary weapon-enchant detection (SuperWoW / vanilla).
-- GetWeaponEnchantInfo returns, per hand: present flag, time remaining in
-- MILLISECONDS, charges, enchant id. slot is "main" or "off". Returns
-- has, msRemaining, charges (all nil/false when no SuperWoW or no enchant).
-- Read live every call on purpose: msRemaining is a running countdown, so a
-- cached-until-UNIT_INVENTORY_CHANGED value would report stale time-left.
-- Confirmed on Turtle 1.12 (2026-07-19): has=1, ms counts down, charges=0 for
-- a time-based enchant -- so gate upkeep on has/ms, NOT on charges.
-- ============================================================
function Aegis_SBR:WeaponEnchant(slot)
    if not GetWeaponEnchantInfo then return false, nil, nil end
    -- Six return values on 1.12, not seven: there is no enchant-id slot between
    -- the hands on this client. Reading a seventh put hasOH on the off-hand
    -- EXPIRATION, so WeaponEnchant("off") returned nonsense. Latent until now,
    -- because the only caller asks for the main hand, where both readings agree.
    -- The six-value form is the one Aegis_SBR_BuffUp uses and its charge counts
    -- are confirmed correct in game.
    local hasMH, mhMs, mhCh, hasOH, ohMs, ohCh = GetWeaponEnchantInfo()
    if slot == "off" then return (hasOH and true or false), ohMs, ohCh end
    return (hasMH and true or false), mhMs, mhCh
end

-- Optional identity: the enchant ID on a hand ("main"/"off"), or nil. Gated
-- separately on GetWeaponEnchantID (SuperWoW 2.1), which returns mh, oh.
-- Confirmed on Turtle 1.12 (2026-07-19): returns a small integer / nil.
function Aegis_SBR:WeaponEnchantId(slot)
    if not GetWeaponEnchantID then return nil end
    local mh, oh = GetWeaponEnchantID("player")
    if slot == "off" then return oh end
    return mh
end

-- The Attack action's bar slot is cached: one IsAttackAction call verifies it
-- each press, and the full 1..172 scan only runs when the cache is empty or
-- the button was moved/removed.
function Aegis_SBR:EnsureAutoAttack()
    local slot = self.attackSlot
    if not (slot and IsAttackAction(slot)) then
        slot = nil
        for z = 1, 172 do
            if IsAttackAction(z) then slot = z; break end
        end
        self.attackSlot = slot
    end
    if slot then
        -- Attack is on a bar: toggle it only when not already swinging, so this
        -- is a no-op if SCRM (or the player) already started the swing.
        if not IsCurrentAction(slot) then UseAction(slot) end
    elseif AttackTarget then
        -- No Attack on any bar (common on Warriors who never place it): the
        -- vanilla AttackTarget() starts the melee swing directly, no slot
        -- needed. It only begins a swing if one is not already going, so it is
        -- likewise safe to call every tick.
        AttackTarget()
    end
end

-- A stable id for the current target. SuperWoW returns the GUID as the second
-- value of UnitExists, which lets us tell apart two mobs that share a name.
function Aegis_SBR:TargetId()
    local _, guid = UnitExists("target")
    if guid then return guid end
    return UnitName("target") or ""
end

-- ============================================================
-- Time to kill (TTK)
-- How long the current target has left, in seconds, from how fast its health
-- is actually falling. Two rotation problems need it and neither can be solved
-- with a health PERCENTAGE alone: spending combo points before the mob dies
-- (5 CP at 20% is worth dumping on a dying trash mob and worth holding on a
-- boss), and not re-applying a DoT or a buff that will outlive the fight.
--
-- Percent per second, not damage per second: TargetHPPct is a ratio, so no
-- absolute health value is needed and the estimate works on mobs whose max
-- health we cannot read. It also means the number is directly comparable
-- across a level 4 boar and a raid boss.
--
-- Deliberately a plain rolling window rather than the recursive least squares
-- the TimeToKill addon uses. RLS earns its keep over a multi-minute boss with
-- phase changes; here the consumer only ever asks "less than a few seconds?",
-- a question a short window answers just as well and with no tuning constants
-- to get wrong.
--
-- TargetTTK returns nil, never a guess, until it has enough history. Every
-- consumer must treat nil as "not dying soon" - the same rule DotRemaining
-- follows, so an unknown can never suppress an ability.
-- ============================================================
local TTK_WINDOW   = 8      -- seconds of history kept
local TTK_MIN_SPAN = 3      -- seconds of history needed before answering
local TTK_MIN_STEP = 0.3    -- shortest gap between two samples
local TTK_MIN_N    = 4      -- samples needed before answering

function Aegis_SBR:ResetTTK()
    self.ttkId = nil
    self.ttkN  = 0
    self.ttkT  = {}
    self.ttkH  = {}
end

-- Called once per press from RunRotation, which is the only place that reliably
-- fires while a fight is happening (there is no combat tick to hang this on).
-- Presses arrive at roughly the GCD, so the window holds about eight samples.
function Aegis_SBR:SampleTTK()
    local id  = self:TargetId()
    local now = GetTime()
    local hp  = self:TargetHPPct()
    if id ~= self.ttkId then self:ResetTTK(); self.ttkId = id end
    local n = self.ttkN or 0
    if n > 0 and (now - self.ttkT[n]) < TTK_MIN_STEP then return end
    -- Health going UP is never part of a kill curve: the mob was healed, or a
    -- different mob is reusing the id (the name fallback, when SuperWoW GUIDs
    -- are unavailable). Either way the stored samples describe a fight that is
    -- no longer happening, so start over rather than average across the jump.
    -- One percent of slack absorbs a mob's own health regeneration.
    if n > 0 and hp > self.ttkH[n] + 1 then
        n = 0
        self.ttkT = {}
        self.ttkH = {}
    end
    n = n + 1
    self.ttkT[n] = now
    self.ttkH[n] = hp
    -- Drop samples older than the window by shifting the rest down. n is single
    -- digits, so the copy costs nothing and avoids a wrapping ring index.
    local cut, first = now - TTK_WINDOW, 1
    while first < n and self.ttkT[first] < cut do first = first + 1 end
    if first > 1 then
        local k = 0
        for i = first, n do
            k = k + 1
            self.ttkT[k] = self.ttkT[i]
            self.ttkH[k] = self.ttkH[i]
        end
        for i = k + 1, n do self.ttkT[i] = nil; self.ttkH[i] = nil end
        n = k
    end
    self.ttkN = n
end

-- Seconds until the current target dies, or nil when it cannot be estimated
-- (too little history, or the target is not losing health).
function Aegis_SBR:TargetTTK()
    if not UnitExists("target") then return nil end
    if self:TargetId() ~= self.ttkId then return nil end
    local n = self.ttkN or 0
    if n < TTK_MIN_N then return nil end
    local span = self.ttkT[n] - self.ttkT[1]
    if span < TTK_MIN_SPAN then return nil end
    local drop = self.ttkH[1] - self.ttkH[n]
    if drop <= 0 then return nil end
    local hp = self:TargetHPPct()
    if hp <= 0 then return 0 end
    return hp / (drop / span)
end

-- "Will the target be dead within sec seconds?" The one form call sites should
-- use, because it answers false for an unknown TTK rather than making every
-- caller remember to nil-check.
function Aegis_SBR:TTKBelow(sec)
    if not sec or sec <= 0 then return false end
    local ttk = self:TargetTTK()
    if not ttk then return false end
    return ttk < sec
end

-- Best effort melee proximity. CheckInteractDistance index 3 is about 9.9
-- yards, a practical proxy for "close enough to fight". Used only to decide
-- whether we are still running in, so we can pre-cast the seal on the way.
function Aegis_SBR:InMeleeRange()
    if not UnitExists("target") then return false end
    return CheckInteractDistance("target", 3) and true or false
end

function Aegis_SBR:Throttle(text)
    local now = GetTime()
    if (now - (self.lastMsg or 0)) > 3 then
        DEFAULT_CHAT_FRAME:AddMessage("Aegis: " .. text, 1, 0.5, 0.3)
        self.lastMsg = now
    end
end

-- ============================================================
-- Talent dump: prints every talent's exact GetTalentInfo name and rank, tab by
-- tab. Used to verify the strings the class modules match against (e.g. the
-- paladin's "Vengeful Strikes"/"Righteous Strikes"), since a one-character
-- mismatch makes a talent read as rank 0.
-- ============================================================
function Aegis_SBR:Talents()
    DEFAULT_CHAT_FRAME:AddMessage("--- Aegis talents ---", 1, 0.8, 0.0)
    local tabs = GetNumTalentTabs and GetNumTalentTabs() or 0
    if tabs == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("no talent API available.", 1, 0.5, 0.3)
        return
    end
    for tab = 1, tabs do
        local tabName = GetTalentTabInfo and GetTalentTabInfo(tab) or ("Tab " .. tab)
        DEFAULT_CHAT_FRAME:AddMessage(tab .. " - " .. (tabName or ("Tab " .. tab)) .. ":", 1, 0.82, 0.0)
        for i = 1, GetNumTalents(tab) do
            local n, _, _, _, rank = GetTalentInfo(tab, i)
            if n then
                local r = rank or 0
                DEFAULT_CHAT_FRAME:AddMessage("    " .. n .. "  (" .. r .. ")",
                    (r > 0 and 0.6 or 0.7), (r > 0 and 1 or 0.7), (r > 0 and 0.6 or 0.7))
            end
        end
    end
end

-- ============================================================
-- Debug dump
-- ============================================================
function Aegis_SBR:Debug()
    DEFAULT_CHAT_FRAME:AddMessage("--- Aegis debug ---", 1, 0.8, 0.0)
    if UnitExists("target") then
        DEFAULT_CHAT_FRAME:AddMessage("Target debuffs (name / stacks / texture):", 1, 0.8, 0.0)
        local any = false
        for i = 1, 40 do
            local t, stacks, d3, d4, d5 = UnitDebuff("target", i)
            if not t then break end
            any = true
            local id
            if type(d3) == "number" then id = d3
            elseif type(d4) == "number" then id = d4
            elseif type(d5) == "number" then id = d5 end
            local nm = "?"
            if id and SpellInfo then
                if id < -1 then id = id + 65536 end
                nm = SpellInfo(id) or "?"
            end
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] " .. nm .. " / " .. (stacks or 0) .. " / " .. t)
        end
        if not any then DEFAULT_CHAT_FRAME:AddMessage("  (none)") end
        -- TTK only fills while the rotation button is being pressed, so a debug
        -- run on a fresh target legitimately reports "unknown".
        local ttk = self:TargetTTK()
        DEFAULT_CHAT_FRAME:AddMessage("Time to kill: "
            .. (ttk and (string.format("%.1f", ttk) .. "s") or "unknown")
            .. " (" .. (self.ttkN or 0) .. " samples)", 1, 0.8, 0.0)
    else
        DEFAULT_CHAT_FRAME:AddMessage("No target.", 1, 0.5, 0.5)
    end
    DEFAULT_CHAT_FRAME:AddMessage("Player buffs (name / time / stacks):", 1, 0.8, 0.0)
    if GetPlayerBuff then
        for i = 0, 31 do
            local ix = GetPlayerBuff(i, "HELPFUL")
            if ix and ix ~= -1 then
                local id = GetPlayerBuffID and GetPlayerBuffID(ix)
                local nm = "?"
                if id then
                    if id < -1 then id = id + 65536 end
                    if SpellInfo then nm = SpellInfo(id) or "?" end
                end
                local tl = GetPlayerBuffTimeLeft(ix) or 0
                local st = (GetPlayerBuffApplications and GetPlayerBuffApplications(ix)) or 1
                DEFAULT_CHAT_FRAME:AddMessage("  " .. nm .. " / " .. string.format("%.0f", tl) .. "s / " .. st)
            end
        end
    end
end

function Aegis_SBR:Tokenize(msg)
    local t = {}
    for w in string.gfind(msg or "", "%S+") do table.insert(t, w) end
    return t
end

-- Resolve an on/off command argument against the value it is changing.
--   (no argument) -> toggle, matching /sbr aoe and the other bare commands,
--                    which is what a keybind needs: one binding, both ways.
--   on / off      -> set absolutely, so a macro that passes one stays
--                    idempotent however often it fires.
--   anything else -> nil, so the caller can print usage and change NOTHING.
-- That last case is the bug this replaces: the old `(onoff or "") == "on"` sent
-- every unrecognised argument to FALSE, so both a bare `/sbr spell mark` and a
-- typo like `/sbr spell mark of` silently DISABLED the spell you were trying to
-- turn on, and reported it as though you had asked for that.
--
-- Callers must test the result with `== nil`, never `if not v` - false is a
-- legitimate return here and would otherwise be mistaken for the error case.
function Aegis_SBR:ToggleArg(current, arg)
    local a = string.lower(arg or "")
    if a == "" then return not current end
    if a == "on" then return true end
    if a == "off" then return false end
    return nil
end

-- Turn a config key into something worth printing: "useHuntersMark" -> "Hunters
-- Mark". Derived rather than kept in a lookup table because there are 47 spell
-- toggles across the three classes that have the command, and a table would be
-- one more place to forget when an ability is added. gsub (not match/gmatch,
-- which 5.0 lacks) is assigned to a local first so its second return, the
-- replacement count, cannot leak into a concatenation at the call site.
function Aegis_SBR:SpellLabel(key)
    local s = string.gsub(key or "", "^use", "")
    s = string.gsub(s, "(%l)(%u)", "%1 %2")
    if s == "" then return key or "" end
    -- Explicit sub/upper rather than a gsub with a function replacement: the
    -- paladin's keys carry no "use" prefix ("holyStrike"), so they arrive here
    -- starting lowercase and need capitalising, and this form does not depend on
    -- 5.0 accepting a function as the replacement argument.
    return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-- ============================================================
-- Saved variables and profiles (generic, schema comes from the module)
-- ============================================================
function Aegis_SBR:DeepCopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = self:DeepCopy(v) end
    return r
end

-- A full copy of a profile, then normalized by the active module. Every UI
-- save/activate commits through here, so the cached validity is dropped.
function Aegis_SBR:CopyProfile(p)
    self.validCacheName = nil
    local c = self:DeepCopy(p)
    if self.active and self.active.NormalizeProfile then self.active:NormalizeProfile(c) end
    return c
end

function Aegis_SBR:InitDB()
    if type(AegisDB) ~= "table" then AegisDB = {} end
    if type(AegisDB.profiles) ~= "table" then AegisDB.profiles = {} end
    if not self.active or not self.active.templates then return end
    if not next(AegisDB.profiles) then
        for name, tpl in pairs(self.active.templates) do
            AegisDB.profiles[name] = self:CopyProfile(tpl)
        end
    end
    -- migrate any already-stored profiles to the current format
    for _, cfg in pairs(AegisDB.profiles) do self.active:NormalizeProfile(cfg) end
end

function Aegis_SBR:GetActiveProfile()
    if not AegisDB or not AegisDB.active then return nil end
    return AegisDB.profiles[AegisDB.active]
end

-- Validity is a class rule. Without a module nothing is missing.
function Aegis_SBR:Validity(cfg)
    if self.active and self.active.ProfileValidity then return self.active:ProfileValidity(cfg) end
    return true, {}
end

-- ============================================================
-- Generic profile commands (the text interface, UI is primary)
-- ============================================================
function Aegis_SBR:CmdList()
    msgOut("Profiles:")
    local active = AegisDB.active
    local any = false
    for name, cfg in pairs(AegisDB.profiles) do
        any = true
        local ok, missing = self:Validity(cfg)
        local mark = (name == active) and " [active]" or ""
        local valid = ok and "valid" or ("INVALID, missing " .. table.concat(missing, ", "))
        msgOut("  " .. name .. mark .. " - " .. valid)
    end
    if not any then msgOut("  (none, use /sbr reset)") end
    if not active then msgOut("No profile is active.") end
end

function Aegis_SBR:CmdUse(name)
    local cfg = name and AegisDB.profiles[name]
    if not cfg then msgOut("profile '" .. tostring(name) .. "' not found.", 1, 0.5, 0.3); return end
    local ok, missing = self:Validity(cfg)
    if not ok then msgOut("cannot activate '" .. name .. "', missing " .. table.concat(missing, ", "), 1, 0.5, 0.3); return end
    AegisDB.active = name
    msgOut("activated '" .. name .. "'.")
end

function Aegis_SBR:CmdOff()
    AegisDB.active = nil
    msgOut("deactivated. No profile active.")
end

function Aegis_SBR:CmdNew(name, template)
    if not self.active or not self.active.templates then msgOut("no class module loaded.", 1, 0.5, 0.3); return end
    if not name then msgOut("usage: /sbr new <name> [template]", 1, 0.5, 0.3); return end
    if AegisDB.profiles[name] then msgOut("'" .. name .. "' already exists.", 1, 0.5, 0.3); return end
    if template == "" then template = nil end   -- the dispatcher lowercases t[3] or "", so a missing arg arrives as ""
    local tpl = self.active.templates[template or "starter"]
    if not tpl then msgOut("unknown template '" .. tostring(template) .. "'.", 1, 0.5, 0.3); return end
    AegisDB.profiles[name] = self:CopyProfile(tpl)
    msgOut("created '" .. name .. "' from template '" .. (template or "starter") .. "'.")
end

function Aegis_SBR:CmdDel(name)
    if not name or not AegisDB.profiles[name] then msgOut("profile not found.", 1, 0.5, 0.3); return end
    AegisDB.profiles[name] = nil
    if AegisDB.active == name then AegisDB.active = nil end
    msgOut("deleted '" .. name .. "'.")
end

function Aegis_SBR:CmdCheck()
    local cfg = self:GetActiveProfile()
    if not cfg then msgOut("no profile active."); return end
    local ok, missing = self:Validity(cfg)
    if ok then msgOut("active profile '" .. AegisDB.active .. "' is valid.")
    else msgOut("active profile invalid, missing " .. table.concat(missing, ", "), 1, 0.5, 0.3) end
end

function Aegis_SBR:CmdReset()
    if not self.active or not self.active.templates then msgOut("no class module loaded.", 1, 0.5, 0.3); return end
    AegisDB.profiles = {}
    for n, tpl in pairs(self.active.templates) do AegisDB.profiles[n] = self:CopyProfile(tpl) end
    AegisDB.active = nil
    msgOut("profile list reseeded from templates, nothing active.")
end

-- ============================================================
-- Rotation entry point
-- ============================================================
-- Targeting mode: three-way, mutually exclusive.
--   "auto"   - acquire the nearest enemy when you have none (the old default).
--   "manual" - never touch targeting; defer to you or a separate assist addon.
--   "assist" - continuously mirror AegisDB.assistTarget's current target.
-- Migrated transparently from the older acquire boolean (true/nil -> "auto",
-- false -> "manual") the first time this is read after upgrading.
-- ============================================================
function Aegis_SBR:TargetMode()
    if type(AegisDB) ~= "table" then return "auto" end
    local m = AegisDB.targetMode
    if m == "auto" or m == "manual" or m == "assist" then return m end
    local migrated = (AegisDB.acquire == false) and "manual" or "auto"
    AegisDB.targetMode = migrated
    return migrated
end

-- /sbr acquire on|off|assist <name> - set targeting mode (also on the minimap
-- right-click). "on"/"auto" and "off"/"manual"/"defer" keep their old
-- meaning; "assist <name>" is new and requires a party/raid member's name.
function Aegis_SBR:CmdAcquire(arg, arg2)
    local low = string.lower(arg or "")
    if low == "" then
        local mode = self:TargetMode()
        local desc = mode == "auto" and "auto (acquires nearest enemy)"
            or mode == "assist" and ("assist (mirrors " .. ((AegisDB and AegisDB.assistTarget) or "?") .. ")")
            or "manual (defers to you or an assist addon)"
        msgOut("targeting mode is " .. desc .. ". Use /sbr acquire on, off, or assist <name>.")
        return
    end
    if low == "on" or low == "self" or low == "auto" then
        if AegisDB then AegisDB.targetMode = "auto" end
        msgOut("targeting mode: auto. Aegis acquires the nearest enemy when it has no target.")
    elseif low == "off" or low == "manual" or low == "defer" then
        if AegisDB then AegisDB.targetMode = "manual" end
        msgOut("targeting mode: manual. Aegis leaves targeting to you or your assist addon.")
    elseif low == "assist" then
        if not arg2 or arg2 == "" then
            msgOut("usage: /sbr acquire assist <party/raid member name>.", 1, 0.5, 0.3)
            return
        end
        if AegisDB then
            AegisDB.targetMode = "assist"
            AegisDB.assistTarget = arg2
        end
        msgOut("targeting mode: assist. Mirroring " .. arg2 .. "'s target.")
    else
        msgOut("usage: /sbr acquire on or /sbr acquire off or /sbr acquire assist <name>.", 1, 0.5, 0.3)
    end
end

-- Resolve a party/raid member's unit id by exact (case-insensitive) name.
-- Raid members are only enumerable while actually in a raid; a solo party
-- falls back to partyN + the player.
function Aegis_SBR:FindGroupUnitByName(name)
    if not name or name == "" then return nil end
    local want = string.lower(name)
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local n = UnitName("raid" .. i)
            if n and string.lower(n) == want then return "raid" .. i end
        end
        return nil
    end
    local pn = UnitName("player")
    if pn and string.lower(pn) == want then return "player" end
    for i = 1, 4 do
        local n = UnitName("party" .. i)
        if n and string.lower(n) == want then return "party" .. i end
    end
    return nil
end

-- Continuously mirror AegisDB.assistTarget's current target, matched by
-- GUID only. Name-only matching cannot tell two different mobs with the same
-- name apart (e.g. one tapped by a different nearby group), which in
-- practice meant silently attacking the wrong group's mob without ever
-- noticing - SuperWoW's GUID-aware UnitExists/TargetUnit avoids that
-- entirely by re-resolving the assist target's live target every call.
function Aegis_SBR:RunAssist()
    local name = AegisDB and AegisDB.assistTarget
    if not name or name == "" then return end
    local unit = self:FindGroupUnitByName(name)
    if not unit then
        self:Throttle("assist target '" .. name .. "' is not in your group.")
        return
    end
    local _, theirGUID = UnitExists(unit .. "target")
    if not theirGUID then
        -- They have no target: drop any stale target of our own rather than
        -- keep fighting whatever we had selected before they cleared theirs.
        if UnitExists("target") then ClearTarget() end
        return
    end
    if UnitIsDead(unit .. "target") or not UnitCanAttack("player", unit .. "target") then
        return
    end
    local _, myGUID = UnitExists("target")
    if myGUID ~= theirGUID then
        TargetUnit(theirGUID)
    end
end

function Aegis_SBR:RunRotation()
    if not self.active then self:Throttle("no module for your class yet."); return end
    local cfg = self:GetActiveProfile()
    if not cfg then
        self:Throttle("no profile active. Open /sbr ui or use /sbr use <name>.")
        return
    end
    -- Validity is cached per active profile, not recomputed every press: it only
    -- changes when a spell is learned (SPELLS_CHANGED clears it) or the active
    -- profile switches/saves (those paths clear it too).
    if self.validCacheName ~= AegisDB.active then
        local ok, missing = self:Validity(cfg)
        self.validCacheName = AegisDB.active
        self.validCacheOK = ok
        self.validCacheMissing = missing
    end
    if not self.validCacheOK then
        self:Throttle("active profile incomplete, missing " .. table.concat(self.validCacheMissing, ", ") .. ". Running with what is available.")
    end

    -- Support modules (e.g. the paladin heal mode) may run without an attackable
    -- target and must not be forced to grab one.
    local supportRun = self.active.RunsWithoutTarget and self.active:RunsWithoutTarget(cfg)

    -- Targeting: three mutually exclusive modes (see TargetMode). "assist"
    -- actively mirrors a chosen group/raid member's target every press, even
    -- while you already have some target selected, so it runs unconditionally
    -- here rather than only when you have none. "auto" only ever grabs when
    -- you have nothing, behind the same per-module opt-out as before
    -- (autoAcquireTarget == false, e.g. the Hunter, so a ranged class never
    -- grabs and pulls a random mob). "manual" defers entirely, only dropping
    -- a corpse so a separate assist addon can reassign you.
    local mode = self:TargetMode()
    if mode == "assist" then
        -- Unlike "auto" below, mirroring an ally's existing target is never a
        -- fresh pull, so it runs for support modules (e.g. the paladin heal
        -- mode) too - that's what lets a melee-holy healer's strike weaving
        -- (which needs an actual target) follow the tank hands-free.
        self:RunAssist()
    elseif not UnitExists("target") or UnitIsDead("target") then
        if mode == "auto" and self.active.autoAcquireTarget ~= false and not supportRun then
            TargetNearestEnemy()
        elseif UnitExists("target") and UnitIsDead("target") then
            ClearTarget()
        end
    end

    local hasEnemy = UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
    if not hasEnemy then
        -- No attackable target: a support module still runs (to heal); others hold.
        if supportRun then
            self:SnapshotBuffs()
            self:SnapshotTargetDebuffs()
            self.active:Rotate(cfg)
            UIErrorsFrame:Clear()
        end
        return
    end

    -- Keep the white swing going for melee classes. Runs whether or not
    -- SuperCleveRoidMacros is loaded: EnsureAutoAttack only toggles Attack when
    -- you are not already swinging, so it is a no-op if SCRM (or anything else)
    -- already started it. Gated on melee range so an accidentally targeted far
    -- enemy never starts a swing (no stray pull). meleeAutoAttack == false (e.g.
    -- the Druid) opts out and manages its own swing in the module.
    if self.active.meleeAutoAttack ~= false and self:InMeleeRange() then self:EnsureAutoAttack() end

    self:SnapshotBuffs()
    self:SnapshotTargetDebuffs()
    self:SampleTTK()
    self.active:Rotate(cfg)
    UIErrorsFrame:Clear()
end

-- ============================================================
-- Command dispatch
-- ============================================================
function Aegis_SBR:EvalCommand(msg)
    local t = self:Tokenize(msg)
    local cmd = string.lower(t[1] or "")

    if cmd == "" then self:RunRotation(); return end
    if cmd == "list"  then self:CmdList(); return end
    if cmd == "use"   then self:CmdUse(t[2]); return end
    if cmd == "off" or cmd == "none" then self:CmdOff(); return end
    if cmd == "new"   then self:CmdNew(t[2], string.lower(t[3] or "")); return end
    if cmd == "del" or cmd == "delete" then self:CmdDel(t[2]); return end
    if cmd == "check" then self:CmdCheck(); return end
    if cmd == "reset" then self:CmdReset(); return end
    if cmd == "acquire" then self:CmdAcquire(t[2], t[3]); return end
    if cmd == "minimap" then
        if Aegis_SBR_Minimap and Aegis_SBR_Minimap.ToggleShown then
            local hidden = Aegis_SBR_Minimap:ToggleShown()
            msgOut("minimap button " .. (hidden and "hidden" or "shown") .. ".")
        else
            msgOut("minimap button not available.", 1, 0.5, 0.3)
        end
        return
    end
    if cmd == "debug" then self:Debug(); return end
    if cmd == "talents" then self:Talents(); return end
    if cmd == "trace" then
        self.trace = not self.trace
        msgOut("trace " .. (self.trace and "on (per-press log)" or "off"))
        return
    end
    if cmd == "log" then
        local sub = string.lower(t[2] or "")
        -- Read the current state WITHOUT creating the table: only "on" and
        -- "clear" may bring AegisLog into existence, so merely asking for the
        -- status never leaves a saved variable behind on a machine that has
        -- never recorded anything.
        local have = (type(AegisLog) == "table") and AegisLog or nil
        local cap = (have and have.max) or LOG_MAX
        local held = (have and have.pos) or 0
        if held > cap then held = cap end
        if sub == "on" then
            self:LogInit()
            self.logging = true
            AegisLog.enabled = true
            msgOut("press log ON - every press is recorded (chat trace is separate).")
            msgOut("Run your test, then /reload to write the file, then read it from:", 0.7, 0.7, 0.7)
            msgOut("WTF\\Account\\<ACCOUNT>\\<Realm>\\<Char>\\SavedVariables\\Aegis_SBR.lua", 0.7, 0.7, 0.7)
        elseif sub == "off" then
            self.logging = false
            if have then have.enabled = false end
            msgOut("press log OFF. " .. held .. " lines held - /reload to write them out.")
            msgOut("They are dropped on the load AFTER that, so the saved file does not keep them forever.", 0.7, 0.7, 0.7)
        elseif sub == "clear" then
            self:LogInit(true)
            msgOut("press log cleared.")
        else
            msgOut("press log is " .. (self.logging and "ON" or "off")
                .. ", holding " .. held .. " of " .. cap .. " lines"
                .. (((have and have.pos) or 0) > cap and " (oldest overwritten)" or "") .. ".")
            msgOut("usage: /sbr log on|off|clear  - NOT written to disk until /reload or logout.", 0.7, 0.7, 0.7)
        end
        return
    end
    if cmd == "ui" or cmd == "config" then
        if self.active and self.active.OpenConfig then self.active:OpenConfig()
        else msgOut("no configuration UI for this class yet.", 1, 0.5, 0.3) end
        return
    end
    -- class specific subcommands (e.g. seal, spell on the paladin). These can
    -- mutate the active profile in place, so the cached validity is dropped.
    if self.active and self.active.HandleCommand and self.active:HandleCommand(cmd, t) then
        self.validCacheName = nil
        return
    end

    -- `log` is intentionally absent from this list: it is a development aid for
    -- capturing a rotation trace to file, not something a player has any use
    -- for. It still works when typed, so it can be handed out on request when
    -- diagnosing a report ("/sbr log on, play a bit, /reload, send me the file").
    msgOut("commands: ui, list, use, off, new, del, check, reset, acquire, minimap, debug, talents, trace (plus class commands).")
end

-- ============================================================
-- Class detection and load
-- ============================================================
function Aegis_SBR:OnAddonLoaded()
    -- Phase 0 rebrand migration: adopt the old AutoRotaDB once, BEFORE InitDB
    -- can seed fresh templates over it. Both names stay listed in the .toc for
    -- the transition, so the old data still loads from disk; sharing the same
    -- table keeps the AutoRotaDB copy current as a rollback backup until the
    -- old name is dropped from the .toc a few versions from now.
    if (type(AegisDB) ~= "table" or not next(AegisDB)) and type(AutoRotaDB) == "table" then
        AegisDB = AutoRotaDB
        AegisDB._migratedFrom = "AutoRotaDB"
    end
    -- Press log: a development tool, not a player feature. It is deliberately
    -- NOT initialised here - AegisLog is created lazily, on the first /sbr log
    -- on. A player who never touches the command therefore never gets the
    -- variable created and never carries it in their saved file; the table
    -- below is only ever touched if one already exists from a previous session.
    --
    -- The log survives /reload on purpose: /reload is exactly what flushes it
    -- to disk, so clearing it there would destroy the recording at the moment
    -- the user is trying to save it. Entries are dropped one load AFTER
    -- logging is switched off, so a finished test does not linger forever.
    if type(AegisLog) == "table" then
        self.logging = AegisLog.enabled and true or false
        if not self.logging and type(AegisLog.entries) == "table" and next(AegisLog.entries) then
            self:LogInit(true)
        end
    end
    local _, class = UnitClass("player")
    self.active = self.classes[class]
    self:InitDB()
    -- Saved variables are in by now, so the preview window can restore whether
    -- it was open. Guarded because the file is optional in the load order.
    if Aegis_SBR_Preview then Aegis_SBR_Preview:Restore() end
end

-- Printed once at PLAYER_LOGIN, when the chat frame is ready. ADDON_LOADED
-- fires too early in the login for a banner to reliably show.
function Aegis_SBR:Banner()
    if self.Loaded then return end
    self.Loaded = true
    if not self.active then
        local _, class = UnitClass("player")
        self.active = self.classes[class]
    end
    if self.active then
        DEFAULT_CHAT_FRAME:AddMessage("Aegis SBR v" .. self.ver .. " loaded for " .. (self.active.uiTitle or "?")
            .. ". Configure with /sbr ui, run with a bare /sbr macro.", 1, 0.8, 0.0)
    else
        DEFAULT_CHAT_FRAME:AddMessage("Aegis SBR v" .. self.ver .. " loaded, but there is no module for your class yet.", 1, 0.6, 0.3)
    end
end

-- Slash commands. /sbr is primary, /aegis the long form; /ar stays as a
-- legacy alias from the AutoRota era. ONE handler key, so a command is
-- never double-processed (the paladin-era aliases are gone).
SLASH_AEGIS_SBR1 = "/sbr"
SLASH_AEGIS_SBR2 = "/aegis"
SLASH_AEGIS_SBR3 = "/ar"
SlashCmdList["AEGIS_SBR"] = function(msg) Aegis_SBR:EvalCommand(msg) end

-- Event wiring. The swing tracker runs on the active module so its state
-- stays with the class instance that reads it.
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("SPELLS_CHANGED")
-- A talent point can change a spell's cost without teaching anything (Improved
-- Sinister Strike and friends are passives), so the cached costs are dropped on
-- this too rather than trusting SPELLS_CHANGED to cover it.
ev:RegisterEvent("CHARACTER_POINTS_CHANGED")
ev:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
ev:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
-- SuperWoW fires UNIT_CASTEVENT on every registered cast: arg1 caster GUID,
-- arg2 target GUID, arg3 event type ("START"/"CAST"/"FAIL"/...), arg4 spell id,
-- arg5 cast duration. Modules that care (e.g. Shaman totem tracking) get the
-- resolved spell NAME via OnCastEvent. Guarded so clients without SuperWoW
-- (no such event) simply never receive it.
if SpellInfo then ev:RegisterEvent("UNIT_CASTEVENT") end
ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "Aegis_SBR" then
        Aegis_SBR:OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        Aegis_SBR:Banner()
    elseif event == "CHARACTER_POINTS_CHANGED" then
        Aegis_SBR.costCache = nil
        Aegis_SBR.radiusCache = nil
    elseif event == "SPELLS_CHANGED" then
        -- learning a spell or rank invalidates the spellbook index and any
        -- cached profile validity, both rebuilt lazily on the next use
        Aegis_SBR:InvalidateSpellIndex()
        Aegis_SBR.validCacheName = nil
    elseif event == "CHAT_MSG_COMBAT_SELF_HITS" or event == "CHAT_MSG_COMBAT_SELF_MISSES" then
        if Aegis_SBR.active then Aegis_SBR.active:OnSwingMessage(arg1) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if Aegis_SBR.active then Aegis_SBR.active.lastSwing = nil end
        -- Out of combat the kill curve is meaningless, and keeping it would let
        -- the last fight's rate answer the first press of the next one.
        Aegis_SBR:ResetTTK()
    elseif event == "UNIT_CASTEVENT" then
        -- Only successful casts ("CAST"), and only if the active module wants them.
        if arg3 == "CAST" and Aegis_SBR.active and Aegis_SBR.active.OnCastEvent then
            local sname
            if arg4 and SpellInfo then sname = SpellInfo(arg4) end
            if sname then Aegis_SBR.active:OnCastEvent(arg1, arg2, sname) end
        end
    end
end)
