# Research — ClassicAPI: what it could do for Aegis_SBR

**Status:** research only, no code written. **Source:** <https://github.com/brues-code/ClassicAPI>
(fetched 2026-07-19). **Verdict up front:** genuinely useful, but only for a handful of
things — and every one of them must be **presence-gated**, because ClassicAPI is
*Recommended*, not *Required*.

---

## What it actually is

A **compiled C++ DLL for WoW 1.12.1** — *"DLL for 1.12.1 to backport the modern Blizzard
API"* — not a Lua addon. It hooks FrameScript at boot and injects **250+ functions across
60+ namespaces** (`C_Timer`, `C_Spell`, `C_Item`, `C_Container`, `C_UnitAuras`,
`C_EncodingUtil`, `C_Map`, `C_QuestLog`, `C_EquipmentSet`, …) plus some frame methods
(`frame:HookScript`, `region:SetSize`) and custom events. Loaded via **VanillaFixes**
(`dlls.txt`), **32-bit Windows only**, GPLv3.

**What it does NOT change:** the Lua *language* is still **5.0**. Backporting Blizzard API
functions doesn't add `string.match`, `#`, or `%`. **Every hard constraint in `CLAUDE.md`
still applies**, and the single-pass loader is unchanged.

---

## ⚠️ The rule conflict this creates (needs a decision)

`CLAUDE.md` currently says, under Hard Constraints:

> **Do NOT use**: `#`, `%`, `string.match`/`gmatch`, **`C_*` namespaces**, retail widget
> APIs, …

That rule exists because those namespaces don't exist on a 1.12 client. ClassicAPI changes
that premise — *but only for players who installed it*. Since it sits in the **Recommended**
tier alongside SCRM (not Required like SuperWoW / Nampower / UnitXP_SP3), the addon **cannot
assume it is present**.

**Proposed amendment (user's call):** keep the ban as the default, with one carve-out —
`C_*` may be called only behind an explicit presence check, and only where the feature
degrades cleanly without it. Same discipline SuperWoW already gets
(`if SpellInfo then …`, `if GetWeaponEnchantInfo then …`):

```lua
-- capability probe, evaluated once
function Aegis_SBR:HasClassicAPI()
    return (C_Timer and C_Timer.After) and true or false
end
```

Nothing below should be built until that amendment is agreed.

---

## Where it genuinely helps (ranked)

### 1. ⭐ Enemy debuff **timers** — the biggest potential unlock
**Today's limitation:** Aegis can tell you a debuff *is up* and its *stack count*, but not
how long it has left. `docs/dependencies.md` records the constraint plainly: enemy-debuff
timers need pfUI libdebuff or Cursive. So the engine works around it everywhere:

| Module | Current workaround |
|---|---|
| Warlock | DoT remaining is *inferred from its own cast bookkeeping* (`DotRemaining`), scaled by Rapid Deterioration |
| Hunter | Stings reapply on a **blind interval** (`STING_DUR`) when the name path misses |
| Shaman | Flame Shock uses a blind `FLAMESHOCK_DUR = 12` reapply |
| Priest / Paladin | DoTs and judgement debuffs are "missing → recast", with a 1.5s dropout memory |

**If** `C_UnitAuras.GetAuraDataByIndex` / `GetUnitAuras` return real duration/expiration for
**hostile** units, all of that becomes exact: refresh a DoT in its true pandemic window
instead of after it has already fallen off. That would improve DoT uptime across four
classes and directly serve open audit items (Shaman S1's Molten Blast refresh window needs
Flame Shock's real remaining time; Mage M1's Hot Streak wants buff-stack timing).

**Unverified:** the repo's README is a function *list* — it does not document the returned
fields or whether hostile units are supported. **This is the single most important thing to
test in-game** (see the checklist below). If it only reports your own auras, the win
evaporates.

### 2. ⭐ Exact spell range — `C_Spell.IsSpellInRange`
**Today:** `InMeleeRange()` is `CheckInteractDistance("target", 3)` — an **~9.9yd proxy**,
not a real melee check, and Aegis says so in its own comments. It drives the Hunter's Auto
mode (ranged vs melee), the sting's "land it on the pull, stop once closed", the Paladin's
run-in seal pre-cast, and the Shaman imbue's "on approach" case.

A per-spell range test replaces a proxy with the truth. Bounded, easy to reason about, and it
sharpens a documented weak spot (`docs/audit-phase1-rotations.md` notes Auto mode's ~10yd
proxy). **Non-rotation** where it just fixes an existing gate — but changing *which* ability
fires at *what* range is a priority change, so it still goes through the sign-off gate.

### 3. ⭐ `C_EncodingUtil` — makes roadmap **Phase 3** almost free
Phase 3's profile import/export is currently specced as a hand-rolled, Lua-5.0-safe
serializer (`gsub`/`format`, no `string.match`) with a sandboxed `pcall` parser — the single
most error-prone item on the roadmap. ClassicAPI ships `SerializeJSON`, `CompressString`, and
`EncodeBase64`/`DecodeBase64`, which is exactly the "serialize → compress → make it survive a
chat channel" pipeline.

Because sharing profiles is inherently opt-in, gating this on ClassicAPI is **acceptable**:
users without it simply don't get import/export (with a clear message), rather than the
feature being broken.

### 4. `C_Timer.After` / `NewTicker` — real deferred callbacks
1.12 has no timer API, so Aegis hand-rolls throttles from `GetTime()` comparisons
(`Throttle`, `debuffThrottle`, `DUMP_THROTTLE`, `imbueWarnT`) and an `OnUpdate` frame for the
minimap picker's auto-close. Those work and shouldn't be rewritten for fashion. The real gain
is **things that are currently impossible**: "re-check this in 0.5s" without an OnUpdate
frame — useful for confirming a cast landed, or re-probing after the GCD.

*Caution:* the rotation is deliberately **synchronous and press-driven**. Deferred callbacks
that cast are a new failure mode (firing outside a press). Any use should be limited to
*bookkeeping*, never to issuing casts.

### 5. `frame:HookScript` — small, clean UI win
`Aegis_SBR_UI.lua` hand-chains handlers today: `Tip` captures `prevEnter`/`prevLeave`, and
`wireHover` does the same with `pe`/`pl`, precisely because 1.12 has no `HookScript`. Native
hooking would delete that pattern. **Low value** — the current code works and is verified;
worth doing only if that area is being touched anyway.

### 6. `C_Container.*` — possible help for the poison Quick Bar
The BuffUp poison Quick Bar finds "whatever rank is in your bags". If `GetContainerItemInfo`
returns richer data than the 1.12 originals, it could simplify that scan. Needs a look at the
actual BuffUp implementation before claiming a benefit.

---

## What it does NOT give us (avoid duplicate paths)

| ClassicAPI offers | Aegis already has it from | Verdict |
|---|---|---|
| `UnitGUID` | SuperWoW (`UnitExists` 2nd return) — **Required** | Keep SuperWoW's |
| `C_Spell.GetSpellInfo` | SuperWoW `SpellInfo(id)` — **Required** | Keep SuperWoW's |
| `UnitInLineOfSight` | UnitXP_SP3 — **Required** | Keep UnitXP's |

**Rule of thumb: never move an existing capability from a Required dependency onto a
Recommended one.** Use ClassicAPI only where 1.12 + the Required stack has *no* answer —
which is precisely items 1-4 above.

---

## Risks

- **Soft dependency.** Recommended-not-Required means every call site needs a guard and a
  degraded path. Two code paths per feature is a real maintenance cost — worth it for aura
  timers, probably not for cosmetics.
- **Platform limit.** 32-bit Windows via VanillaFixes. Players on other setups never get it.
- **Unverified return shapes.** The repo lists function *names*; the returns aren't
  documented. Building against an assumed signature is exactly the mistake the Turtle
  spell-name work taught us to avoid — probe first.
- **Divergence risk.** If a backported function subtly differs from the retail semantics it
  imitates, code written from retail memory will be wrong in ways that only show in combat.
- **Licensing.** ClassicAPI is GPLv3; Aegis is MIT. Calling a separately-distributed DLL's
  Lua API is not linking its source into ours, so this shouldn't affect Aegis's license — but
  if it were ever *bundled*, get a real opinion rather than mine.

---

## Verify in-game before building anything

Run these on a live client with ClassicAPI installed. **Item 1 decides whether the headline
feature is real.**

```lua
-- 0. Is it even loaded?
/run DEFAULT_CHAT_FRAME:AddMessage("ClassicAPI: " .. tostring(C_Timer and "yes" or "no"))

-- 1. THE BIG ONE: enemy debuff duration. Target a mob, apply a DoT, then:
/run local a=C_UnitAuras and C_UnitAuras.GetAuraDataByIndex("target",1); if a then for k,v in pairs(a) do DEFAULT_CHAT_FRAME:AddMessage(k.."="..tostring(v)) end else DEFAULT_CHAT_FRAME:AddMessage("no aura data") end
-- Looking for: name, duration, expirationTime, applications. Does it work on a HOSTILE unit?

-- 2. Spell range vs the CheckInteractDistance proxy
/run DEFAULT_CHAT_FRAME:AddMessage("inRange=" .. tostring(C_Spell and C_Spell.IsSpellInRange and C_Spell.IsSpellInRange("Sinister Strike","target")) .. " proxy=" .. tostring(CheckInteractDistance("target",3)))

-- 3. Timer actually fires
/run C_Timer.After(2, function() DEFAULT_CHAT_FRAME:AddMessage("timer fired") end)

-- 4. Serialization round-trip (Phase 3)
/run local s=C_EncodingUtil.SerializeJSON({a=1,b="x"}); DEFAULT_CHAT_FRAME:AddMessage(s .. " | b64=" .. C_EncodingUtil.EncodeBase64(s))
```

---

## Recommended sequence (if the user wants to proceed)

1. **Amend the `C_*` rule** in `CLAUDE.md` to the presence-gated carve-out above. *(Decision,
   not code.)*
2. **Add a capability probe** — `Aegis_SBR:HasClassicAPI()` plus per-feature probes. Ungated
   plumbing, inert on its own.
3. **Run the verification block.** Everything downstream depends on what item 1 returns.
4. **If hostile aura timers are real:** build a shared `Aegis_SBR:TargetDebuffRemaining(name)`
   that prefers ClassicAPI and falls back to today's blind timers. This is *plumbing*;
   actually changing a refresh window is a **rotation change → sign-off gate**.
5. **Spell range** as a second, independent batch.
6. **Phase 3 import/export** on `C_EncodingUtil`, gated with a clear "needs ClassicAPI"
   message.

Items 4-6 are each their own verified batch, in that order of value.
