-- ============================================================
-- Class_Rogue_UI  -  rogue window body for Aegis_SBR
-- Builds and binds only the rogue specific controls. The shared
-- window shell and profile management live in Aegis_SBR_UI.lua.
-- Uses the shell's scroll layout (M.useScrollLayout): BuildBody is
-- handed the scroll child and the cursor-based layout API places
-- everything; detail lives in tooltips so labels stay short.
-- ============================================================

local M = Aegis_SBR.classes.ROGUE
M.useScrollLayout = true

-- ============================================================
-- build body (rogue controls)
-- ============================================================
function M:BuildBody(ui, parent)
    local L = ui:NewLayout(parent)
    local function set(key) return function(v) if ui.buf then ui.buf[key] = v; ui:Refresh() end end end

    -- Surprise Attack belongs with the builders (it AWARDS a combo point), but
    -- it cannot go in the dropdown: that picks the builder you spam, while
    -- Surprise Attack is only castable inside the target's dodge window, so it
    -- rides on top of whichever builder is chosen rather than replacing it.
    L:Header("Rotation")
    self.builderDD = L:Dropdown("builder", "Builder", 170, set("builder"))
    self.saRow = L:Row{ key = "useSurpriseAttack", label = "Surprise Attack", spell = "Surprise Attack", onToggle = set("useSurpriseAttack") }

    -- Riposte spends no combo points and builds none - a pure reactive strike.
    L:Header("Reactives")
    self.ripRow = L:Row{ key = "useRiposte", label = "Riposte", spell = "Riposte", onToggle = set("useRiposte") }

    L:Header("Finishers")
    self.sndRow = L:Row{ key = "useSnd", label = "Slice and Dice", spell = "Slice and Dice", onToggle = set("useSnd") }
    self.envRow = L:Row{ key = "useEnvenom", label = "Envenom", spell = "Envenom", onToggle = set("useEnvenom") }
    self.renewRow = L:Row{ label = "Refresh the two above at",
        slider = { key = "buffRenew", min = 0, max = 2, step = 1, suffix = "s", onChange = set("buffRenew") } }
    self.rupRow = L:Row{ key = "useRupture", label = "Rupture at CP", spell = "Rupture", onToggle = set("useRupture"),
        slider = { key = "ruptureCP", min = 1, max = 5, step = 1, suffix = "", onChange = set("ruptureCP") } }
    self.cpRow = L:Row{ label = "Eviscerate at CP",
        slider = { key = "cpFinish", min = 1, max = 5, step = 1, suffix = "", onChange = set("cpFinish") } }
    self.evisOnlyRow = L:Row{ key = "evisExecuteOnly", label = "Eviscerate only in execute", onToggle = set("evisExecuteOnly") }
    self.execRow = L:Row{ key = "useExecute", label = "Execute low-HP targets", onToggle = set("useExecute"),
        slider = { key = "executeHpPct", min = 1, max = 30, step = 1, suffix = "%", onChange = set("executeHpPct") } }

    L:Header("Cooldowns")
    self.cbRow = L:Row{ key = "useColdBlood", label = "Cold Blood with Eviscerate", spell = "Cold Blood", onToggle = set("useColdBlood") }
    self.cdRow = L:Row{ key = "popCDs", label = "Pop cooldowns", onToggle = set("popCDs") }
    self.cdEliteRow = L:Row{ key = "autoCDElite", label = "Auto on elite", onToggle = set("autoCDElite") }

    -- Poisons: the poison-control settings (Quick Bar + rebuff) live in the
    -- shared Aegis_SBR_BuffUp module (global per character, not per profile), so
    -- their toggles write there directly. The pre-pull reminder stays a
    -- per-profile setting. Presets open a text dialog on click.
    L:Header("Poisons")
    local function abu(fn) return function(v) if Aegis_SBR_BuffUp then Aegis_SBR_BuffUp[fn](Aegis_SBR_BuffUp, v) end end end
    self.pcRow  = L:Row{ key = "abuPoisonControl", label = "Poison control (Quick Bar + rebuff)", onToggle = abu("SetPoisonControl") }
    self.pmhRow = L:Row{ key = "abuWatchMH", label = "Rebuff button: mainhand", onToggle = abu("SetWatchPoisonMH") }
    self.pohRow = L:Row{ key = "abuWatchOH", label = "Rebuff button: offhand", onToggle = abu("SetWatchPoisonOH") }
    self.qbRow  = L:Row{ key = "abuQuickBar", label = "Show poison Quick Bar", onToggle = abu("SetQuickBarEnabled") }
    self.presetBtns = {}
    local maxp = (Aegis_SBR_BuffUp and Aegis_SBR_BuffUp:MaxPresets()) or 4
    for i = 1, maxp do
        local idx = i
        self.presetBtns[idx] = L:Button{ label = "Preset " .. idx, onClick = function()
            local cur = ""
            if Aegis_SBR_BuffUp then cur = (Aegis_SBR_BuffUp:GetPreset(idx)) or "" end
            Aegis_SBR_UI:ShowDialog({
                prompt = "Poison type for preset " .. idx .. " (name only, no rank - e.g. Instant Poison)",
                withInput = true, initialText = cur, acceptLabel = "Save",
                onAccept = function(txt)
                    if Aegis_SBR_BuffUp then Aegis_SBR_BuffUp:SetPreset(idx, txt or "", "") end
                    ui:Refresh()
                end,
            })
        end }
    end

    L:Finish()

    ui:Tip(self.builderDD, "Builder", "The combo point builder you spam. Auto picks Noxious Assault if known, else Sinister Strike.")
    ui:Tip(self.saRow.cb, "Surprise Attack", "An extra builder on top of the one above: it awards a combo point, but is only castable right after the TARGET dodges you, inside a short window.", "Combat capstone (20 points). Guaranteed hit - can't be blocked, dodged or parried. Takes priority when the window is open, since missing it wastes the proc.")
    ui:Tip(self.ripRow.cb, "Riposte", "Cast right after a parry, inside the short Riposte window. Neither spends nor builds combo points.")
    ui:Tip(self.sndRow.cb, "Slice and Dice", "Kept up: refreshed cheaply at 1 combo point, dumped with Eviscerate above that.")
    ui:Tip(self.envRow.cb, "Envenom", "Kept up the same way as Slice and Dice (Turtle ability).")
    ui:Tip(self.renewRow.slider, "Refresh buffs at", "Seconds of remaining time at which Slice and Dice and Envenom are re-applied. Whatever is left on the buff at that moment is thrown away, so a lower value wastes fewer combo points.", "1 is the measured sweet spot: refreshes land with ~0.6s to spare and the buffs practically never drop. 2 buys a little more safety on low energy, where a refresh at 0 combo points needs TWO presses (a builder first). 0 waits for the buff to actually lapse - most efficient, but the downtime is real.")
    ui:Tip(self.rupRow.cb, "Rupture", "With the Assassination talent Taste for Blood it is kept up for that melee-damage BUFF (not the bleed) and takes priority over the other finishers. Without the talent it simply maintains the bleed on your target.", "The slider is its own combo-point threshold, separate from Eviscerate's on purpose: only Rupture's payoff scales with the points spent (2% damage per point), and sharing Eviscerate's higher threshold meant it never got cast at all.")
    ui:Tip(self.rupRow.slider, "Rupture at CP", "Combo points required before Rupture is cast. Lower = renewed more reliably but a weaker buff; higher = stronger buff but it may never be reached, since every buff refresh resets you to 1 point.", "Recommended: 5. A recast simply overwrites the buff at whatever combo points it was cast with, so anything below 5 risks replacing an existing 10% Taste for Blood buff with a weaker one the moment Rupture comes due.")
    ui:Tip(self.evisOnlyRow.cb, "Eviscerate only in execute", "Reserve Eviscerate for the execute phase, so every other combo point goes into maintaining your buffs instead of direct damage.", "Useful once you maintain several buffs: refreshes keep resetting your points, so a normal Eviscerate threshold is rarely reached anyway.")
    ui:Tip(self.cpRow.slider, "Finisher combo points", "Eviscerate is used once combo points reach this number.", "Greyed out while \"Eviscerate only in execute\" is on, since that setting bypasses this threshold entirely.")
    ui:Tip(self.execRow.cb, "Execute low-HP targets", "Below the health value on the right, Eviscerate fires with whatever combo points are on hand (at least 1) instead of waiting for the normal threshold.", "Ruthlessness guarantees a combo point after any finisher, so this rarely goes unused once a fight is underway.")
    ui:Tip(self.execRow.slider, "Execute below", "Target health percent under which Eviscerate finishes early rather than risk combo points going to waste on a kill.")
    ui:Tip(self.cbRow.cb, "Cold Blood with Eviscerate", "Fires Cold Blood in the same press, right before Eviscerate, so the guaranteed crit lands on your biggest hit. Costs no global cooldown.", "Deliberately tied to Eviscerate rather than used on cooldown: the buff is spent by the next Sinister Strike, Backstab, Ambush, Noxious Assault OR Eviscerate - and Noxious Assault is a builder, so a Cold Blood popped at any other moment is eaten by a builder for a fraction of the damage. Skipped when combo points are below the Eviscerate threshold, so the execute finisher cannot waste the 3 minute cooldown on 1-2 points.")
    ui:Tip(self.cdRow.cb, "Pop cooldowns", "Use Adrenaline Rush and Blade Flurry every press (off the global cooldown).")
    ui:Tip(self.cdEliteRow.cb, "Auto on elite", "Pop the cooldowns only against elite and boss targets.")
    ui:Tip(self.pcRow.cb, "Poison control", "Master switch for the poison Quick Bar and rebuff buttons (also in the minimap right-click menu). Applies to this character across all rogue profiles.", "Applying a poison needs a real click, so it is always button-driven, never cast from the rotation macro.")
    ui:Tip(self.pmhRow.cb, "Rebuff button: mainhand", "Show a click-to-apply button when the mainhand poison has fallen off.")
    ui:Tip(self.pohRow.cb, "Rebuff button: offhand", "Show a click-to-apply button when the offhand poison has fallen off.")
    ui:Tip(self.qbRow.cb, "Show poison Quick Bar", "A small movable bar of your poison presets: left-click a preset for mainhand, right-click for offhand.")
    for i = 1, table.getn(self.presetBtns) do
        ui:Tip(self.presetBtns[i], "Poison preset " .. i, "Click to set the poison type for this preset - just the name, NO rank (e.g. Instant Poison, not Instant Poison VI).", "Whatever rank of that poison is in your bags is found and applied automatically, so you never have to update the preset when you learn a higher rank.")
    end
end

-- ============================================================
-- refresh body (rogue binding)
-- ============================================================
function M:RefreshBody(ui, buf)
    -- builder dropdown: Auto plus the builders the rogue actually knows
    local o = { { label = "Auto (spec based)", value = "" } }
    local avail = self:AvailableBuildersOf()
    for i = 1, table.getn(avail) do o[i + 1] = { label = avail[i], value = avail[i] } end
    local cur = buf.builder or ""
    local shown, c
    if cur == "" then shown, c = "Auto (spec based)", ui.COL.white
    elseif self:KnowsSpell(cur) then shown, c = cur, ui.COL.white
    else shown, c = cur .. " (not learned)", ui.COL.red end
    ui:SetDropdown(self.builderDD, o, cur, shown, c)

    ui:BindCheck(self.sndRow, buf.useSnd)
    ui:BindCheck(self.envRow, buf.useEnvenom)
    ui:BindCheck(self.rupRow, buf.useRupture)
    ui:BindCheck(self.ripRow, buf.useRiposte)
    ui:BindCheck(self.saRow, buf.useSurpriseAttack)
    ui:BindCheck(self.cbRow, buf.useColdBlood)
    ui:BindCheck(self.cdRow, buf.popCDs)
    ui:BindCheck(self.cdEliteRow, buf.autoCDElite)

    local cpv = buf.cpFinish or 4
    self.cpRow.slider:SetValue(cpv)
    if self.cpRow.slider.valText then self.cpRow.slider.valText:SetText(tostring(cpv)) end

    local rupv = buf.ruptureCP or 3
    self.rupRow.slider:SetValue(rupv)
    if self.rupRow.slider.valText then self.rupRow.slider.valText:SetText(tostring(rupv)) end

    -- 0 is a valid setting ("only once it has dropped"), so this must not use
    -- `or` with a non-zero fallback - that would silently turn 0 into 3.
    local renewv = buf.buffRenew
    if renewv == nil then renewv = 1 end
    self.renewRow.slider:SetValue(renewv)
    if self.renewRow.slider.valText then self.renewRow.slider.valText:SetText(renewv .. "s") end
    -- Only meaningful while at least one of the two buffs it governs is on.
    ui:SliderEnable(self.renewRow.slider, (buf.useSnd or buf.useEnvenom) and true or false)

    ui:BindCheck(self.evisOnlyRow, buf.evisExecuteOnly)
    ui:SliderEnable(self.cpRow.slider, not buf.evisExecuteOnly)

    ui:BindCheck(self.execRow, buf.useExecute)
    local execv = buf.executeHpPct or 10
    self.execRow.slider:SetValue(execv)
    if self.execRow.slider.valText then self.execRow.slider.valText:SetText(execv .. "%") end

    -- Poison-control rows bind to the global Aegis_SBR_BuffUp state, not the
    -- profile buffer, so they are set directly here.
    if Aegis_SBR_BuffUp then
        self.pcRow.cb:SetChecked(Aegis_SBR_BuffUp:PoisonControlEnabled())
        self.pmhRow.cb:SetChecked(Aegis_SBR_BuffUp:WatchPoisonMH())
        self.pohRow.cb:SetChecked(Aegis_SBR_BuffUp:WatchPoisonOH())
        self.qbRow.cb:SetChecked(Aegis_SBR_BuffUp:QuickBarEnabled())
        for i = 1, table.getn(self.presetBtns) do
            local nm = Aegis_SBR_BuffUp:GetPreset(i)
            self.presetBtns[i].value:SetText((nm and nm ~= "") and nm or "|cff666666(empty)|r")
        end
    end
end

-- Open the shared window for this class.
M.OpenConfig = function(mod)
    if not Aegis_SBR_UI then
        Aegis_SBR:Throttle("UI not ready yet, try again in a moment.")
        return
    end
    Aegis_SBR_UI:Toggle()
end
