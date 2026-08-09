-- ============================================================
-- Class_Rogue  -  rogue module for Aegis_SBR
-- Turtle WoW 1.12 (SuperWoW). Assassination flavoured, configurable.
-- ============================================================
-- Model:
--  * A builder fills combo points (auto picks Noxious Assault if known,
--    else Sinister Strike, or a fixed choice from the profile).
--  * Slice and Dice and Envenom are optional self buffs kept alive by
--    their own timers, refreshed cheaply at 1 combo point or dumped with
--    Eviscerate above that, mirroring the proven ExAutoRogue logic.
--  * Eviscerate is the finisher once combo points reach the threshold.
--  * Riposte fires inside the parry window when learned and enabled.
--  * Surprise Attack fires inside the target's dodge window when learned and
--    enabled - a Combat capstone (20 Combat points), the mirror image of
--    Riposte: it reacts to the TARGET dodging OUR attack rather than us
--    parrying theirs. Guaranteed hit (unblockable/undodgeable/unparryable),
--    cheap (10 energy), and awards a combo point, so it is worth interrupting
--    the normal builder/finisher flow for whenever the window is open.
--  * Adrenaline Rush and Blade Flurry are off-GCD, cast on demand or
--    automatically against elite and boss targets.
-- ============================================================

local M = Aegis_SBR:NewClassModule("ROGUE")
M.uiTitle = "Rogue"
M.uiHeight = 574

-- Chat output is shared in the core; this shim keeps call sites unchanged.
local function msgOut(text, r, g, b) Aegis_SBR:Msg(text, r, g, b) end

-- Slice and Dice, Envenom and the Rupture proxy buff (Taste for Blood) are all
-- read straight off the real buff timer (GetPlayerBuffTimeLeft via
-- Aegis_SBR:BuffTime) - in-game /sbr trace confirmed all three resolve to a
-- live countdown, not just presence, so no stamped/estimated duration table
-- is needed for any of them (previously SnD and Envenom used a hardcoded
-- duration table stamped at cast time; that guess is gone now that the real
-- timer reads back reliably).
--
-- Reading the live timer is also why no duration table is maintained here any
-- more - but the underlying numbers still matter when reasoning about upkeep
-- cost, so they live in docs/turtle-mechanics.md (Rogue section) instead of
-- being re-derived. The one that bites: Turtle's SnD duration talent is called
-- **Improved Blade Tactics** (not "Improved Slice and Dice"), +45% at 3/3, and
-- the spell tooltip shows only the BASE duration - so a talented rogue's Slice
-- and Dice really lasts 13.05-30.45s, not the 9-21s the tooltip implies.
local TALENT_TASTE = "Taste for Blood"
-- Default renew window: seconds of remaining buff time at or below which Slice
-- and Dice / Envenom are re-applied. Overridable per profile via cfg.buffRenew.
-- This used to be 5, sized for the era when the remaining time was ESTIMATED
-- from a stamped duration table - a wide margin was right when the number could
-- be wrong. Now that the real timer is read (see the header), that justification
-- is gone and 5s was simply throwing away up to a sixth of the buff's life, and
-- with it the combo points that paid for it. Lower is more efficient; too low
-- risks dropping the buff, because at 0 combo points the refresh needs TWO
-- presses (a builder first), which on an energy-starved rogue can take several
-- seconds. 0 means "only once it has actually dropped" - hence the <= test at
-- the call site, so a fully expired buff (BuffTime returns 0) still qualifies.
-- 1 is measured, not guessed: a 2 minute press log at this setting refreshed
-- with an average of 0.64s left on the buff, never dropped Slice and Dice, and
-- lost Envenom only three times for ~2.4s combined (2% downtime) - far less
-- than the up-to-4s of buff life the old 5 threw away on every single refresh.
local BUFF_RENEW = 1
-- Taste for Blood gets a wider renew window than the other two buffs: Slice and
-- Dice and Envenom can be refreshed at any combo point, while Rupture waits for
-- its own (higher) point threshold, so its opportunity comes around far less
-- often. Renewing from roughly half the buff's life onward makes sure such a
-- moment falls inside the window instead of after the buff has already lapsed.
local TFB_RENEW = 10

-- Builder universe, used by the UI to offer only learned ones
M.BUILDERS = { "Sinister Strike", "Backstab", "Hemorrhage", "Noxious Assault", "Mutilate" }

M.templates = {
    starter = {  -- valid for any rogue, only Slice and Dice upkeep
        builder = "", useSnd = true, useEnvenom = false, useRupture = false, useRiposte = false,
        useSurpriseAttack = false,
        useExecute = false, executeHpPct = 10, executeTTK = 4, executeMinCP = 1, refreshMaxCP = 5, evisExecuteOnly = false, ruptureCP = 3,
        cpFinish = 4, buffRenew = 1, useColdBlood = false, popCDs = false, autoCDElite = false,
    },
    assassination = {
        builder = "", useSnd = true, useEnvenom = true, useRupture = true, useRiposte = true,
        useSurpriseAttack = false,
        -- ruptureCP = 5 (not lower): Taste for Blood's magnitude is fixed at whatever combo
        -- points Rupture was cast with (2% per point) and a recast overwrites it outright, no
        -- keep-the-stronger-one logic - so anything below 5 risks replacing an existing 10%
        -- buff with a weaker one the moment Rupture comes due (Discord-reported, confirmed).
        useExecute = false, executeHpPct = 10, executeTTK = 4, executeMinCP = 1, refreshMaxCP = 5, evisExecuteOnly = false, ruptureCP = 5,
        cpFinish = 4, buffRenew = 1, useColdBlood = false, popCDs = false, autoCDElite = false,
    },
    combat = {
        builder = "", useSnd = true, useEnvenom = false, useRupture = false, useRiposte = false,
        useSurpriseAttack = true,
        useExecute = false, executeHpPct = 10, executeTTK = 4, executeMinCP = 1, refreshMaxCP = 5, evisExecuteOnly = false, ruptureCP = 3,
        cpFinish = 5, buffRenew = 1, useColdBlood = false, popCDs = false, autoCDElite = true,
    },
}

M.builderAlias = {
    sinister = "Sinister Strike", ss = "Sinister Strike",
    backstab = "Backstab", bs = "Backstab",
    hemorrhage = "Hemorrhage", hem = "Hemorrhage",
    noxious = "Noxious Assault", na = "Noxious Assault",
    mutilate = "Mutilate", mu = "Mutilate",
    auto = "", none = "",
}

-- Fills any missing field with a default
function M:NormalizeProfile(c)
    if c.builder == nil then c.builder = "" end
    if c.useSnd == nil then c.useSnd = true end
    if c.useEnvenom == nil then c.useEnvenom = false end
    if c.useRupture == nil then c.useRupture = false end
    if c.useRiposte == nil then c.useRiposte = false end
    if c.useSurpriseAttack == nil then c.useSurpriseAttack = false end
    -- Execute: finish with whatever combo points are on hand once the target
    -- is nearly dead, instead of risking them going to waste on a kill.
    -- Ruthlessness (Assassination talent, 100% at 3/3) guarantees at least 1
    -- combo point after any finisher, so there is always something to spend.
    if c.useExecute == nil then c.useExecute = false end
    if c.executeHpPct == nil then c.executeHpPct = 10 end
    -- Both combo-point floors default to 1, which is the behaviour that existed
    -- before them: no floor at all. They are opt-in tuning, not a new model.
    if c.executeMinCP == nil then c.executeMinCP = 1 end
    -- Highest combo point count a buff refresh is allowed to spend. Above it the
    -- surplus goes into Eviscerate first and the buff is refreshed on the next
    -- press with the point Ruthlessness hands back. 5 = no ceiling, which is
    -- what the rotation always did.
    if c.refreshMaxCP == nil then c.refreshMaxCP = 5 end
    -- Retired: a combo point FLOOR for refreshes. Measured over 1355 presses it
    -- pushed Envenom uptime from 84% down to 61% and pinned the rotation at
    -- 2 combo points, because reaching the floor costs a builder GCD during
    -- which the buff is simply not up. The ceiling above is the same knob
    -- turned the right way round. Do not reintroduce it without new evidence.
    c.refreshMinCP = nil
    -- Seconds-to-live that count as "about to die". When the core can measure
    -- how fast the target is losing health it is a far better trigger than a
    -- health percentage: 10% of a boss is a minute of fighting, 10% of a boar
    -- is already over. 0 turns the measurement off and leaves the health
    -- percentage in sole charge, exactly as before this setting existed.
    if c.executeTTK == nil then c.executeTTK = 4 end
    -- Rupture carries its OWN combo-point threshold, deliberately separate from
    -- Eviscerate's: only Rupture's payoff (the Taste for Blood damage buff)
    -- scales with the points spent, and sharing Eviscerate's higher threshold
    -- meant Rupture never got cast at all - buff refreshes reset the combo
    -- points long before that threshold was reached.
    if c.ruptureCP == nil then c.ruptureCP = 3 end
    -- Optionally reserve Eviscerate for the execute phase only, so every other
    -- combo point goes into the maintained buffs instead.
    if c.evisExecuteOnly == nil then c.evisExecuteOnly = false end
    if c.cpFinish == nil then c.cpFinish = 4 end
    -- Renew window for Slice and Dice / Envenom, in seconds of remaining time.
    -- Existing profiles are moved off the old hardcoded 5 deliberately: that
    -- value only ever existed to cover an estimated timer we no longer use.
    if c.buffRenew == nil then c.buffRenew = BUFF_RENEW end
    -- Cold Blood: opt-in. Rides along with Eviscerate only (see ColdBloodBefore).
    if c.useColdBlood == nil then c.useColdBlood = false end
    if c.popCDs == nil then c.popCDs = false end
    if c.autoCDElite == nil then c.autoCDElite = false end
    -- old keys from any earlier format are dropped silently
    c.poisonReminder = nil   -- retired: superseded by the Aegis_SBR_BuffUp poison Quick Bar / rebuff buttons
    return c
end

function M:AvailableBuildersOf()
    local out = {}
    for i = 1, table.getn(self.BUILDERS) do
        if self:KnowsSpell(self.BUILDERS[i]) then table.insert(out, self.BUILDERS[i]) end
    end
    return out
end

function M:ProfileValidity(cfg)
    local missing = {}
    
    -- Keep this: if they manually chose a specific builder they don't know, flag it
    if cfg.builder ~= "" and not self:KnowsSpell(cfg.builder) then table.insert(missing, cfg.builder) end
    
    -- Level-dependent upkeeps/cooldowns shouldn't render the whole profile un-activatable,
    -- as M:Rotate already degrades gracefully using self:KnowsSpell()
    -- if cfg.useSnd     and not self:KnowsSpell("Slice and Dice") then table.insert(missing, "Slice and Dice") end
    -- if cfg.useEnvenom and not self:KnowsSpell("Envenom")        then table.insert(missing, "Envenom")        end
    -- if cfg.useRiposte and not self:KnowsSpell("Riposte")        then table.insert(missing, "Riposte")        end
    -- if (cfg.popCDs or cfg.autoCDElite) and not self:KnowsSpell("Adrenaline Rush") and not self:KnowsSpell("Blade Flurry") then
    --     table.insert(missing, "Adrenaline Rush / Blade Flurry")
    -- end
    
    return (table.getn(missing) == 0), missing
end

-- Seconds left on Taste for Blood - the melee damage buff Rupture exists for.
-- Read straight from the buff, which carries a real timer: verified in game
-- that it resolves by name through the same GetPlayerBuffID -> SpellInfo path
-- the core's snapshot uses ("Taste for Blood 11.506"), and BuffTime returns 0
-- when it is absent. NOTE this tracks the PLAYER buff, not the target's bleed:
-- the talent grants the buff "regardless of successful application" and it
-- survives a target switch, so the target debuff is the wrong signal.
-- Deliberately NO estimated-duration fallback: an earlier version stamped an
-- expected duration on cast and preferred it whenever the buff read as absent,
-- which inverted the whole point - once the real buff had run out, the stale
-- stamp still claimed it was up, so Rupture never won at the threshold.
function M:TasteLeft()
    return self:BuffTime(TALENT_TASTE) or 0
end

-- Talent rank by name, cached; cleared when talents are respent (see the event
-- frame at the bottom of this file).
function M:TalentRank(name)
    if not self.talentCache then self.talentCache = {} end
    if self.talentCache[name] ~= nil then return self.talentCache[name] end
    local rank = 0
    local tabs = GetNumTalentTabs and GetNumTalentTabs() or 0
    for tab = 1, tabs do
        for i = 1, GetNumTalents(tab) do
            local n, _, _, _, r = GetTalentInfo(tab, i)
            if n == name then rank = r or 0; break end
        end
        if rank > 0 then break end
    end
    self.talentCache[name] = rank
    return rank
end

-- Does Rupture need (re)casting? Two different questions depending on the
-- talent, which is why the rank is read rather than assumed:
--   * WITH Taste for Blood, Rupture is maintained for the PLAYER buff, so the
--     buff's own remaining time decides.
--   * WITHOUT it there is no buff at all - Rupture is then just a bleed, so it
--     falls back to whether the DoT is on the TARGET. (Using the buff check
--     here would read "always missing" and re-cast Rupture every single time.)
function M:RuptureDue()
    if self:TalentRank(TALENT_TASTE) > 0 then
        return self:TasteLeft() < TFB_RENEW
    end
    return not self:TargetDebuffUp("Rupture", "Ability_Rogue_Rupture")
end

-- Fire Cold Blood immediately before the Eviscerate it is meant to turn into a
-- crit. Confirmed in game that it costs no global cooldown, so both go out in
-- the same press - and that is the whole point: the buff applies to the NEXT
-- Sinister Strike, Backstab, Ambush, Noxious Assault or Eviscerate, and
-- Noxious Assault is a BUILDER. Popped at any other moment it is eaten by the
-- next builder for a fraction of the payoff, so it is deliberately not a
-- priority step of its own - it only ever rides along with a finisher.
-- Gated on cpFinish rather than a threshold of its own: that setting already
-- means "enough points for Eviscerate to be worth it", and it keeps the 3
-- minute cooldown off the execute finisher, which fires with whatever is on
-- hand (often 1-2 points) and would waste the crit.
function M:ColdBloodBefore(cfg, cp)
    if not cfg.useColdBlood then return end
    if cp < (cfg.cpFinish or 4) then return end
    if not self:KnowsSpell("Cold Blood") then return end
    if not self:OwnCDReady("Cold Blood") then return end
    -- The energy check is not a nicety here, it protects a three minute
    -- cooldown. Cold Blood is free and off the GCD, so it always "succeeds";
    -- the Eviscerate behind it does not, and an Eviscerate that fails for
    -- want of energy leaves the buff sitting there to be eaten by the next
    -- Sinister Strike for a fraction of the payoff. Only arm it when the
    -- finisher it belongs to can actually be paid for.
    if not Aegis_SBR:CanAfford("Eviscerate") then return end
    CastSpellByName("Cold Blood")
end

-- Spend the surplus before refreshing a buff.
--
-- Slice and Dice and Envenom have fixed potency; only their DURATION scales
-- with the points spent. Duration is worth paying for exactly as long as the
-- fight lasts long enough to use it - and measured over 28 fights, a dungeon
-- pull runs 19s with 20s of downtime after it, during which the buff decays
-- to nothing. It carries into the next pull a median of 0.0 seconds. A 5-point
-- Slice and Dice buys 30s for the same 20 energy a 1-point one spends on 13s,
-- and on a 19 second fight the extra 17s is simply thrown away.
--
-- So above the ceiling the points go into Eviscerate instead, and the buff is
-- refreshed on the very next press with the point Ruthlessness returns. This
-- is the model experienced players describe, and it only holds while fights
-- are short - in a raid, where the buff runs its full length, the ceiling
-- belongs back at 5.
--
-- Never dumps when that would leave the buff down for nothing: an unaffordable
-- or unlearned Eviscerate, or evisExecuteOnly reserving it for the execute
-- phase, all fall through to the plain refresh.
-- Returns true when the press has been used up (Eviscerate cast, or
-- deliberately held), false when the caller should refresh the buff normally.
function M:DumpBeforeRefresh(cfg, cp, buffLeft)
    if cp <= (cfg.refreshMaxCP or 5) then return false end
    -- Structural reasons why the surplus could never reach Eviscerate. Refusing
    -- to refresh here would deadlock: the points have nowhere else to go and the
    -- buff would stay down forever. These fall through on purpose.
    if cfg.evisExecuteOnly then return false end
    if not self:KnowsSpell("Eviscerate") then return false end
    -- Being short of energy is NOT such a reason - it passes on its own. This
    -- used to fall through too, and that produced exactly the 5-point buff
    -- refresh the ceiling exists to prevent: measured at 21 energy against a
    -- cost of 30, which is nine energy, under a second of regeneration. So we
    -- hold the press instead and let the energy arrive.
    --
    -- The valve is the buff itself: once it has actually DROPPED there is
    -- nothing left to protect, and a buff that is down costs more than one
    -- refreshed above the ceiling. Until then, waiting is cheaper than paying
    -- five combo points for a duration this fight will not use.
    if not Aegis_SBR:CanAfford("Eviscerate") then
        if (buffLeft or 0) > 0 then return true end
        return false
    end
    self:ColdBloodBefore(cfg, cp)
    self:Cast("Eviscerate")
    return true
end

-- ============================================================
-- Rotation. The core has already secured a target and ensured auto attack.
-- Cooldowns are off the global cooldown, so they may be cast in the same
-- press as one GCD ability. Everything else uses early returns so exactly
-- one GCD ability is chosen per press.
-- ============================================================
function M:Rotate(cfg)
    local cls = UnitClassification("target")
    local isElite = (cls == "worldboss" or cls == "elite" or cls == "rareelite")
    if cfg.popCDs or (cfg.autoCDElite and isElite) then
        self:Cast("Adrenaline Rush")
        self:Cast("Blade Flurry")
    end

    local builder = cfg.builder
    if builder == "" then
        builder = self:KnowsSpell("Noxious Assault") and "Noxious Assault" or "Sinister Strike"
    end
    local useSnd = cfg.useSnd and self:KnowsSpell("Slice and Dice")
    local useEnv = cfg.useEnvenom and self:KnowsSpell("Envenom")
    local useRup = cfg.useRupture and self:KnowsSpell("Rupture")
    local cpEvis = cfg.cpFinish or 4

    local cp = GetComboPoints("player", "target")
    local now = GetTime()

    -- Execute: once the target is nearly dead, finish with whatever combo
    -- points are on hand rather than risk them going to waste on the kill.
    -- Requires at least 1 combo point (Ruthlessness, 100% at 3/3, guarantees
    -- one is on hand after any finisher, so this is rarely blocked once a
    -- fight is underway).
    --
    -- The health percentage is the ONLY thing that starts the execute phase.
    -- Time to kill was briefly allowed to start it too and that was wrong: a
    -- normal mob's whole life is shorter than any sensible window, so "dies
    -- within 4 seconds" is true from the first measurement onward and the
    -- rotation dumped 1-point Eviscerates from full health. Time can only ever
    -- take the execute phase AWAY, never grant it.
    -- executeMinCP is the floor for the dump. At 1 (the default, and what the
    -- rotation always did) a single point is enough. Measured from a real log:
    -- 69 of 108 execute presses went out at 1 combo point, which costs a full
    -- Eviscerate's energy for a fraction of a builder's damage - so the floor
    -- exists to be raised, but raising it is the player's call.
    local execute = cfg.useExecute and cp >= (cfg.executeMinCP or 1)
        and self:TargetHPPct() <= (cfg.executeHpPct or 10)

    -- ...and it only takes away the CHEAP dump. Below cpFinish, execute is
    -- spending points early on the argument that the target is about to die -
    -- an argument a measured fifteen seconds of remaining life refutes, which
    -- is the "finishes too early" report: an elite parked at 8% collecting
    -- 1-point Eviscerates. At or above cpFinish the finisher is worth its
    -- points regardless of how long the target lives, so it is never held
    -- back - and that keeps "Eviscerate only in execute" working on a boss,
    -- which a blanket suppression would have switched off completely.
    -- Unknown TTK never suppresses.
    local ttk = Aegis_SBR:TargetTTK()
    local ttkWin = cfg.executeTTK or 0
    if execute and cp < cpEvis and ttkWin > 0 and ttk and ttk > ttkWin then
        execute = false
    end

    if self:Tracing() then
        self:Trace("cp=" .. cp
            .. " build=" .. builder
            .. " snd=" .. (useSnd and string.format("%.1fs", self:BuffTime("Slice and Dice")) or "-")
            .. " env=" .. (useEnv and string.format("%.1fs", self:BuffTime("Envenom")) or "-")
            .. " tfb=" .. (useRup and ((self:TalentRank(TALENT_TASTE) > 0)
                and string.format("%.0fs", self:TasteLeft())
                or (self:TargetDebuffUp("Rupture", "Ability_Rogue_Rupture") and "dot" or "no-dot")) or "-")
            .. " rip=" .. ((cfg.useRiposte and now < (self.riposteExpiry or 0)) and "Y" or "N")
            .. " sa=" .. ((cfg.useSurpriseAttack and now < (self.surpriseExpiry or 0)) and "Y" or "N")
            .. " en=" .. (UnitMana("player") or 0)
            .. "/" .. (Aegis_SBR:SpellCost("Eviscerate") or "?")
            .. " hp=" .. string.format("%.0f%%", self:TargetHPPct())
            .. " ttk=" .. (ttk and string.format("%.1fs", ttk) or "?")
            .. " exec=" .. (cfg.useExecute and (execute and "Y" or "N") or "-")
            .. " cap=" .. (cfg.refreshMaxCP or 5) .. "/" .. (cfg.executeMinCP or 1)
            .. " cb=" .. (cfg.useColdBlood and (self:KnowsSpell("Cold Blood")
                and (self:OwnCDReady("Cold Blood") and "rdy" or "cd") or "?") or "-")
            .. " elite=" .. (isElite and "Y" or "N"),
            -- Rogue never downranks (all ranks cost the same energy), so every
            -- Cast() below is a bare CastSpellByName(name) - vanilla resolves
            -- that to the highest known rank on its own. This line just
            -- surfaces the max rank on record for what would actually go out,
            -- so a bad rank pick would show up here instead of staying invisible.
            "rank: " .. builder .. "=R" .. self:MaxRank(builder)
            .. "  Eviscerate=R" .. self:MaxRank("Eviscerate")
            .. (useSnd and ("  SnD=R" .. self:MaxRank("Slice and Dice")) or "")
            .. (useEnv and ("  Envenom=R" .. self:MaxRank("Envenom")) or "")
            .. (useRup and ("  Rupture=R" .. self:MaxRank("Rupture")) or "")
            .. ((cfg.useRiposte and self:KnowsSpell("Riposte")) and ("  Riposte=R" .. self:MaxRank("Riposte")) or "")
            .. ((cfg.useSurpriseAttack and self:KnowsSpell("Surprise Attack")) and ("  SurpriseAttack=R" .. self:MaxRank("Surprise Attack")) or ""))
    end

    -- P1 Riposte, combo point independent, only inside the parry window
    if cfg.useRiposte and self:KnowsSpell("Riposte") and now < (self.riposteExpiry or 0) then
        CastSpellByName("Riposte")
        return
    end

    -- P1b Surprise Attack, combo point independent, only inside the target's
    -- dodge window. Guaranteed to land and cheap, so like Riposte it jumps the
    -- normal builder/finisher queue rather than waiting its turn - missing the
    -- window wastes the proc entirely.
    if cfg.useSurpriseAttack and self:KnowsSpell("Surprise Attack") and now < (self.surpriseExpiry or 0) then
        CastSpellByName("Surprise Attack")
        return
    end

    -- P2 no combo points, build (prevents an empty finisher)
    if cp == 0 then
        self:Cast(builder)
        return
    end

    -- How much life is left on each maintained buff - all three read straight
    -- off the real buff timer now (see the header comment above).
    local sndLeft = useSnd and self:BuffTime("Slice and Dice") or 0
    local envLeft = useEnv and self:BuffTime("Envenom") or 0
    -- 0 is a meaningful setting here ("wait until it has actually dropped"), and
    -- 0 is truthy in Lua, so the `or` fallback only fires for a genuinely unset
    -- field. The test is <= rather than < so that a lapsed buff, which reads as
    -- 0 seconds remaining, still counts as due when the window is set to 0.
    local renew = cfg.buffRenew or BUFF_RENEW
    local sndDue = useSnd and sndLeft <= renew
    local envDue = useEnv and envLeft <= renew
    local rupDue = useRup and self:RuptureDue()
    local rupCP = cfg.ruptureCP or 3

    -- ------------------------------------------------------------
    -- Execute first: on a dying target a fresh buff or bleed is wasted, so the
    -- points go straight into damage.
    -- ------------------------------------------------------------
    if execute then
        self:ColdBloodBefore(cfg, cp)
        self:Cast("Eviscerate")
        return
    end

    -- ------------------------------------------------------------
    -- P3 Rupture, at its OWN (lower) combo-point threshold. It goes first
    -- among the buffs because it is the only one whose strength scales with the
    -- points spent (2% melee damage per point via Taste for Blood), and the
    -- moment another buff comes due is exactly our combo-point peak - so that
    -- peak is worth spending here. Ruthlessness hands a point straight back,
    -- which lands the cheap refreshes below on the very next press.
    -- ------------------------------------------------------------
    if rupDue and cp >= rupCP then
        self:Cast("Rupture")   -- uptime is read back off the buff itself, nothing to stamp
        return
    end

    -- ------------------------------------------------------------
    -- P4/P5 Fixed-strength buffs. Their potency does not scale with combo
    -- points (only their duration does), so they are simply refreshed with
    -- whatever is on hand the moment they run low - no dumping a finisher
    -- first just to get back down to 1 point, which only burned energy and a
    -- global cooldown for nothing.
    -- ------------------------------------------------------------
    if sndDue then
        if self:DumpBeforeRefresh(cfg, cp, sndLeft) then return end
        self:Cast("Slice and Dice")   -- uptime is read back off the buff itself, nothing to stamp
        return
    end
    if envDue then
        if self:DumpBeforeRefresh(cfg, cp, envLeft) then return end
        self:Cast("Envenom")   -- uptime is read back off the buff itself, nothing to stamp
        return
    end

    -- ------------------------------------------------------------
    -- P6 Eviscerate as the surplus finisher: only once every maintained buff is
    -- healthy. Suppressed while Rupture is waiting for its threshold, so it can
    -- never steal the points Rupture is saving up for. Can be reserved for the
    -- execute phase entirely (evisExecuteOnly), which puts every other point
    -- into the buffs instead.
    -- ------------------------------------------------------------
    if not cfg.evisExecuteOnly and not rupDue and cp >= cpEvis then
        self:ColdBloodBefore(cfg, cp)
        self:Cast("Eviscerate")
        return
    end

    -- P7 otherwise build
    self:Cast(builder)
end

-- ============================================================
-- Class specific slash subcommands, dispatched from the core
-- ============================================================
function M:HandleCommand(cmd, t)
    if cmd == "cp" then
        local n = tonumber(t[2])
        local cfg = Aegis_SBR:GetActiveProfile()
        if cfg and n and n >= 1 and n <= 5 then
            cfg.cpFinish = n
            msgOut("finisher combo points = " .. n .. ".")
        else
            msgOut("usage: /sbr cp <1-5> (sets the active profile)", 1, 0.5, 0.3)
        end
        return true
    end
    return false
end

-- ============================================================
-- Parry window tracker for Riposte. Owned by the module, stays inert while
-- Riposte is not learned or the option is off. (The old pre-pull poison
-- reminder was retired: the poison Quick Bar / rebuff buttons in
-- Aegis_SBR_BuffUp already surface a missing poison on screen.)
-- ============================================================
local riposteFrame = CreateFrame("Frame")
riposteFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
riposteFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")   -- talents respent
riposteFrame:SetScript("OnEvent", function()
    if event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES" then
        if arg1 and string.find(string.lower(arg1), "parry") then
            M.riposteExpiry = GetTime() + 5.5
        end
    elseif event == "CHARACTER_POINTS_CHANGED" then
        M.talentCache = nil   -- Taste for Blood may have been (un)learned
    end
end)

-- ============================================================
-- Dodge window tracker for Surprise Attack - the mirror image of the parry
-- tracker above: OUR attack getting dodged by the target, not us parrying
-- theirs, so it listens on CHAT_MSG_COMBAT_SELF_MISSES instead. The 5.5s
-- window length is carried over from Riposte's (audit R1: Turtle's actual
-- Surprise Attack window is unconfirmed - verify in-game and adjust if it
-- turns out shorter/longer, e.g. by watching how often "sa=Y" in /sbr trace
-- goes stale before a press catches it).
-- ============================================================
local surpriseFrame = CreateFrame("Frame")
surpriseFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
surpriseFrame:SetScript("OnEvent", function()
    if event == "CHAT_MSG_COMBAT_SELF_MISSES" then
        if arg1 and string.find(string.lower(arg1), "dodge") then
            M.surpriseExpiry = GetTime() + 5.5
        end
    end
end)
