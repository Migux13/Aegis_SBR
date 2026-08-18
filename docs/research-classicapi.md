# Research — ClassicAPI: what it could do for Aegis_SBR

**Status:** research + **in-game verification done**. No Aegis code written yet.
**Source:** <https://github.com/brues-code/ClassicAPI> — README fetched 2026-07-19,
full `docs/API.md` (14.5k lines) read from a local checkout of the 2026-08-16 tree.
**Verified in-game:** 2026-08-18, Turtle 1.18.1 / OctoWoW client,
`CLASSIC_API_VERSION = 10911`, alongside SuperWoW + Nampower + UnitXP_SP3.

**Verdict:** the headline capability is **real and confirmed** — enemy debuff timers with
caster attribution. Several things the July pass didn't know about close *open* Aegis items
outright. Everything still has to be **presence-gated**, because ClassicAPI is
*Recommended*, not *Required*.

---

## What it actually is

A **compiled C++ DLL for WoW 1.12.1** — not a Lua addon. It hooks FrameScript at boot and
injects 250+ functions across 60+ namespaces (`C_Timer`, `C_Spell`, `C_Item`,
`C_UnitAuras`, `C_EncodingUtil`, `C_Map`, …), some frame methods (`frame:HookScript`,
`region:SetSize`), custom events, and extra unit tokens (`nameplateN`, `focus`, `markN`).
Loaded via **VanillaFixes** (`dlls.txt`), **32-bit Windows only**, GPLv3. The companion
addon `!!!ClassicAPI` is compiled *into* the DLL — it needs no separate installation and
does not appear in `FrameXML.log`.

**What it does NOT change:** the Lua *language* is still **5.0**. Backporting Blizzard API
functions doesn't add `string.match`, `#`, or `%`. **Every hard constraint in `CLAUDE.md`
still applies**, and the single-pass loader is unchanged.

---

## ⚠️ The rule conflict this creates (still needs a decision)

`CLAUDE.md` bans `C_*` namespaces under Hard Constraints, because they don't exist on a
1.12 client. ClassicAPI changes that premise — *but only for players who installed it*.

**Proposed amendment (user's call, still open):** keep the ban as the default, with one
carve-out — `C_*` may be called only behind an explicit presence check, and only where the
feature degrades cleanly without it. Same discipline SuperWoW already gets
(`if SpellInfo then …`).

```lua
-- capability probe, evaluated once
function Aegis_SBR:HasClassicAPI()
    return CLASSIC_API_VERSION ~= nil
end
```

`CLASSIC_API_VERSION` is the right probe: the DLL sets it itself, and it is an integer, so a
future `>= N` gate works. Nothing below should be built until the amendment is agreed.

---

## Verification results (2026-08-18)

Run with the throwaway `CAPICheck` addon (`/capi`). Green unless noted.

| Check | Result |
|---|---|
| DLL loaded | OK — `CLASSIC_API_VERSION = 10911` |
| `C_Timer`, `C_UnitAuras`, `C_Spell`, `C_LossOfControl`, `C_EncodingUtil`, `GetTotemInfo`, `hooksecurefunc` | OK — all present |
| SuperWoW `SpellInfo()` still live | OK |
| SuperWoW GUID return from `UnitExists` still live | OK |
| UnitXP_SP3 still live | OK |
| **Hostile debuff with duration + caster** | OK — Serpent Sting: `dur=15 rest=7.8s src=player disp=Poison` |
| `HARMFUL` + `PLAYER` filter combination | OK — returns the own-cast subset |
| `C_EncodingUtil` JSON round-trip | OK — serialized and parsed back to an equal table |
| `C_Timer.After(2)` | OK — fired after 2.01s |
| **`C_Spell.IsSpellInRange` accuracy (ranged)** | OK — Serpent Sting while walking in: `false` far out, `true` through the mid band (proxy `false` throughout), then **`false` again at close range while the proxy read `true`**. The min-range dead zone is honoured — see §4. |
| `C_Spell.IsSpellInRange` accuracy (**melee**) | not yet tested — needs a melee spell (`/capi range Raptor Strike`); that is the case `InMeleeRange()` would actually be replaced by |
| `C_LossOfControl` data | present, not exercised (needs a stun/kick) |
| `GetTotemInfo` / `PLAYER_TOTEM_UPDATE` | present, not exercised (needs a Shaman) |
| Turtle-specific duration mods | not exercised (needs the relevant classes) |

**Coexistence is the important negative result:** nothing in the Required stack broke.
One known name collision exists — both ClassicAPI and SuperWoW define a global
`UnitPosition` with different shapes, and the last DLL registered wins. In this client's
`dlls.txt`, `SuperWoWhook.dll` loads *after* `ClassicAPI.dll`, so SuperWoW's shape stays
live. **Do not reorder `dlls.txt` without re-checking this.**

---

## Regression log — the Hunter Auto Shot incident (2026-08-18)

Worth reading before wiring any further capability into a gate; the lesson is
about the *shape* of an integration, not about ClassicAPI's data.

**Symptom:** after the first integration batch, the Hunter stopped attacking with
the ranged weapon while in ranged mode.

**Cause:** the sting integration let ClassicAPI **shorten the retry throttle**
(`STING_DUR` 15s → `STING_QUEUE_HOLD` 1.5s) while the *old* detection still
decided whether to cast. Whenever the two disagreed — ClassicAPI seeing a sting
`TargetDebuffUp` could not read — the sting was re-queued every 1.5s. A sting is
a ranged shot through the Nampower queue, so it clipped Auto Shot on every press.
`Class_Hunter.lua`'s own header warns about exactly this starvation mode.

**Fix:** invert the direction. ClassicAPI is now an authority for *"the debuff is
still up, so do NOT cast"*, never a modifier on a retry interval.

**The rule this establishes:**

> A capability wired into a gate must be able to **suppress** an action, never to
> add one. Suppression is structurally safe — however badly the two detection
> paths disagree, the worst case is a missed cast, never a loop. A capability
> that shortens a throttle, widens a window, or unblocks a gate can only produce
> *more* casts, and needs a play-test on the affected class before it ships.

Both changes were reverted together during diagnosis, so the melee-range change
(§4) is **not exonerated** — it was simply removed at the same time. It stays out
until the passive watcher data explains what `IsSpellInRange` does for a melee
ability. Do not re-apply it on the strength of the sting diagnosis.

**Known exception, deliberately taken:** the `markOK` fix (`DebuffUpAny`) *does*
unblock casts — a readable-only-via-ClassicAPI Hunter's Mark no longer blocks the
sting. That is the intended correction, but it is on the "adds casts" side of the
rule above and is flagged for play-test.

**Caster filtering is per debuff, not global.** Hunter's Mark does not stack and
its bonus applies to every attacker, so any hunter's copy counts and re-marking
over a raid mate's is waste — it is owner-*blind* on purpose. Stings and Lacerate
are our own damage and stay owner-filtered. `SHARED_DEBUFF` in `Class_Hunter.lua`
holds that distinction.

---

## Where it genuinely helps (ranked)

### 1. Enemy debuff **timers** — CONFIRMED, the biggest unlock
**Today's limitation:** Aegis can tell you a debuff *is up* and its *stack count*, but not
how long it has left, and cannot tell **whose** it is. `SnapshotTargetDebuffs()`
(`Aegis_SBR.lua:536`) resolves names via SuperWoW's spell id — no timing, no caster. So the
engine works around it everywhere:

| Module | Current workaround |
|---|---|
| Warlock | `M:DotRemaining` (`Class_Warlock.lua:509`) infers remaining time from its own cast bookkeeping, scaled by Rapid Deterioration |
| Hunter | Stings reapply on a blind `STING_DUR` interval when the name path misses |
| Shaman | Flame Shock uses a blind `FLAMESHOCK_DUR = 12` reapply |
| Priest / Paladin | DoTs and judgement debuffs are "missing → recast" with a 1.5s dropout memory |

`C_UnitAuras.GetUnitAuras(unit, filter)` / `GetAuraDataByIndex` return `AuraData` tables
carrying `duration`, `expirationTime`, `applications`, `spellId`, `dispelName`,
`sourceUnit` and `sourceGUID` — **on hostile units**, verified above.
`expirationTime - GetTime()` is the true remaining time.

The caster field is arguably as valuable as the timer: **in a group, another warlock's
Corruption currently reads as yours.** The `PLAYER` filter token fixes that, and it is
exactly the right shape for a shared helper.

**How it works** (this drives the caveats): the unit aura array stores only spell IDs. A
client-side `Aura::Source` cache co-hooks `SMSG_SPELL_GO` plus two aura callbacks and
caches `(targetGuid, spellId) → {casterGuid, expiration, duration}`.

**Documented limits — treat as design constraints, not bugs:**
- **Best-effort.** Only auras observed *after login* carry timing/caster. Pre-existing
  auras return `expirationTime = 0` and `sourceUnit = nil`.
- **Max-stack refresh is a blind spot.** A stacking debuff refreshed *at* max stacks emits
  no client-visible change, so the cached countdown runs to 0 and evicts while the aura is
  still up. Climbing stacks and single-stack recasts are fine.
- Out-of-range group members fall back to a spell-ID-only path (`applications` always 1).

→ **Implication for Aegis:** a shared `Aegis_SBR:TargetDebuffRemaining(name)` that prefers
ClassicAPI and falls back to today's blind timers. `nil`/`0` must keep meaning *"unknown,
therefore not urgent"* — the stance `DotRemaining` already takes. Building the helper is
plumbing; **changing an actual refresh window is a rotation change → sign-off gate.**

### 2. Turtle-specific server mechanics are already modelled — NEW since July
1.12 sends no packet when the server edits a DoT's remaining duration on *another* unit, so
even a perfect timer would go stale on refresh mechanics. ClassicAPI mirrors the server's
edit off the *triggering* cast, and ships the Turtle cases built in:

- **Molten Blast refreshes the caster's Flame Shock** — this is audit item **S1**, whose
  open question was literally "the Molten Blast refresh window needs Flame Shock's real
  remaining time".
- **Conflagrate shaves 3s off the caster's Immolate.**
- **Carnage's roll-gated Rip/Rake refresh** (druid).
- **Shadow Weaving at 5/5** (registered from Lua; deliberately not inferred below 5/5,
  because the client cannot see the server's roll).
- **Combo-point-accurate finisher durations out of the box** — Rupture at 4 CP reads 14s,
  not the 6s base; includes Turtle's reworked Rip, whose `SpellDuration` row exists
  server-side only.

`C_UnitAuras.RegisterAuraDurationModifierByTrigger(...)` is the escape hatch for anything
missing, keyed by spell family + school + family-flags (rank-proof).

**Combo-point + talent duration CONFIRMED in the field, 2026-08-18** (Rogue, Rupture at 5 CP,
3 casts captured):

| Reading | n | What it is |
|---|---:|---|
| `dur=22.0 rest=21.4` | 2 | the real, server-authoritative duration |
| `dur=6.0 rest=5.7` | 1 | the `Spell.dbc` base — a cache miss |

**22s is exactly right, and no client-side arithmetic could have produced it.** The client's
own tooltip says 16s at 5 CP; `docs/turtle-mechanics.md` records that Turtle's **Taste for
Blood extends Rupture by 6s**. 16 + 6 = 22. So ClassicAPI delivered the *caster-modified*
duration — combo points **and** a Turtle talent the tooltip does not fold in — which is
precisely the case 1.12 never transmits for a debuff on another unit.

The 6.0 reading is the documented cache-miss path, and seeing it matters more than the
successes: `rest=5.7` is `now + base duration`, the signature of the `OnAuraAdded` hook
stamping a cast whose `SMSG_SPELL_GO` was not observed. **Consequence for any consumer: a
value that looks like the base duration may be a miss, not a short debuff.** Three casts is
far too small to estimate a miss *rate* — do not read "1 in 3" as one — but the failure mode
is real and must degrade to "unknown", never to "about to expire".

This also settles a doubt about the probe itself: Rupture recorded `cp=5` correctly, so the
combo-point sampling is sound. The 113 Slice-and-Dice entries all reading `cp=1` are the
*intended* behaviour of the v1.1.8 "spend at most" cap, not a sampling bug.

### 3. `GetTotemInfo` + `PLAYER_TOTEM_UPDATE` — closes an open Phase 2 item — NEW
`Class_Shaman.lua` states outright: *"There is no API for the life of your own totem"*,
which is why `TOTEM_REDROP` is a hand-calibrated table of blind intervals and the Fire Nova
occupancy constant is *"calibrated from play"*.

`GetTotemInfo(slot)` returns `haveTotem, name, startTime, duration, icon, modRate, spellID`
per slot (1 Fire, 2 Earth, 3 Water, 4 Air), data-driven from `Spell.dbc` /
`SpellDuration.dbc` rather than hardcoded. `PLAYER_TOTEM_UPDATE` fires on drop, expiry
**and early destruction (killed / Totemic Recall)** — which is the open Phase 2 item
"Shaman totem-destruction detection", currently unsolved.

Two gotchas: `haveTotem` means *"you carry the totem tool item"*, **not** "a totem is out"
— test `name ~= ""`. And removal detection carries up to ~250 ms of latency.

**VERIFIED in game, 2026-08-18** (Shaman, 28 recorded slot changes). Totemic Recall emptied
both occupied slots at the *same* timestamp — impossible for expiry, whose durations were 30s
and 120s — and both were re-dropped **0.11s and 0.34s later**, i.e. on the next press. Early
destruction is also visible: one Stoneclaw ended 1.8s before its 15s duration (it taunts, so
it was killed), another expired at exactly 14.99s. **The open Phase 2 item "Shaman
totem-destruction detection" is now demonstrated, not just implemented.**

**A non-ClassicAPI bug fell out of the same capture.** `GetTotemInfo` reported `rest=30.0` for
Searing Totem where `TOTEM_REDROP` hardcoded `55`: totem durations are **rank dependent**, and
the table held max-rank values, so a levelling shaman's fire slot sat empty for 25 seconds —
precisely the "totem upkeep doesn't work" report that table's own comment records. Fixed by
reading the duration from the spell tooltip (`Aegis_SBR:SpellDuration`, same approach
`SpellCost` and `SpellRadius` already use, and rank/server-proof by construction), applied as
a **ceiling** so a tooltip read can only ever make the re-drop earlier, never later.

Note who that fix helps: **players without ClassicAPI**, for whom the table is the only
knowledge. It was only *found* because ClassicAPI reported the real duration and contradicted
the table — the clearest case so far of the integration paying off for people who do not run
the DLL.

### 4. Exact spell range — `C_Spell.IsSpellInRange` — CONFIRMED for ranged
`InMeleeRange()` is `CheckInteractDistance("target", 3)`, an **~9.9yd proxy**
(`Aegis_SBR.lua:790`), and Aegis says so in its own comments. It drives Hunter Auto mode,
the sting's pull window, the Paladin run-in seal pre-cast, and the Shaman imbue's
"on approach" case. Druid and Paladin heals use the same trick at index 4 (~28yd).

`C_Spell.IsSpellInRange(spellIdentifier, unit)` uses the engine's own geometric range core
— the one behind action-button range colouring — folding in the target's bounding radius,
so the boundary matches the client exactly, melee and min-range spells included. Returns
`true` / `false`, or `nil` when the check does not apply.

Range-only, matching retail: **ignores line of sight** (keep UnitXP for that) and does not
reject wrong-faction targets.

**Verified 2026-08-18** with Serpent Sting, walking a hostile target down from max range:

| Distance band | `IsSpellInRange` | `CheckInteractDistance(…, 3)` |
|---|---|---|
| beyond max | `false` | `false` |
| mid band | `true` | `false` |
| **inside the hunter dead zone** | **`false`** | **`true`** |

The last row is the point. `CheckInteractDistance` is **monotonic** — the closer you get,
the sooner it reads `true`. A real spell range is a **band with a minimum as well as a
maximum**, and every hunter ranged attack has a min range. No choice of interact index can
express that; the proxy is the wrong shape, not merely the wrong number. `IsSpellInRange`
flips correctly at *both* ends.

The run establishes the shape, not exact yardages (the target simply walked in), which is
all that's needed here.

**Consequence for Hunter Auto mode.** `InMeleeRange()` switches to the melee rotation at the
proxy's ~9.9yd, but the ranged dead zone ends around 8yd — leaving a band where Aegis goes
melee while ranged still works and melee does not yet reach. This is the concrete mechanism
behind the audit's "Auto mode's ~10yd proxy" note.

**Melee side measured in the field, 2026-08-18** (Rogue, Blackrock Spire, ~40 min,
`Sinister Strike` probe, 128 recorded flips of the verdict):

| Direction | Flips | Meaning for `InMeleeRange()` |
|---|---:|---|
| proxy says melee, engine says **no** | 44 | Aegis switches to the melee rotation too early |
| engine says melee, proxy says **no** | 5 | Aegis withholds melee that would actually reach |
| both agree | 79 | |

**Second capture, 246 flips (same character, longer session):** 74 / 8 / 164 — **82 of 246
(33%) disagree**, and all eight of the second kind were again on **The Beast** (worldboss).
Two independent samples, same picture: the bounding-radius prediction holds, and against
ordinary elites only the first direction ever occurs.

That settles the **value** question. It does not settle the **safety** question: re-enabling
adds melee casts in the 5-flip direction, which is the side of the regression-log rule that
requires a play-test on the affected class first. Swapping `InMeleeRange()`'s basis changes
**which ability fires at what range** — a rotation change, sign-off gate, however clearly it
fixes a known defect.

**Distance sources — corrected twice, and the second correction matters.** SuperWoW's
`UnitPosition` resolved for **players only**; every NPC target returned nil. ClassicAPI's
`UnitDistanceSquared` does cover NPCs — so the first conclusion was "distance-to-a-mob is a
ClassicAPI capability". **That conclusion was wrong**, and a no-ClassicAPI test run exposed it:
the range window showed `?` against every mob.

`UnitXP_SP3` — a **Required** dependency all along — provides
`UnitXP("distanceBetween", "player", "target")`, verified returning 40.16 / 37.71 against a mob
on a client with ClassicAPI removed. It is now the primary source, ahead of both.

The lesson is about search order, not APIs: the capability was reachable from the Required
stack the whole time, and it was missed because the investigation started from ClassicAPI and
stopped at the first source that worked. **Check what the Required dependencies already
provide before concluding that something needs the optional one.**

### 5. `C_EncodingUtil` — makes roadmap **Phase 3** almost free — round-trip confirmed
Phase 3's profile import/export is specced as a hand-rolled, Lua-5.0-safe serializer with a
sandboxed `pcall` parser — the most error-prone item on the roadmap. `SerializeJSON` /
`DeserializeJSON` / `CompressString` / `EncodeBase64` cover it. Because sharing profiles is
inherently opt-in, gating this on ClassicAPI is **acceptable**: users without it get a
clear "needs ClassicAPI" message rather than a broken feature.

### 6. `C_LossOfControl` — NEW, nothing equivalent today
`GetActiveLossOfControlData(i)` reports `STUN` / `FEAR` / `ROOT` / `SILENCE` / `PACIFY` /
`SCHOOL_INTERRUPT` with `timeRemaining` and, for interrupts, the authoritative
`lockoutSchool` from the server's own `SMSG_SPELL_COOLDOWN`. Aegis has no notion of any of
this and will happily fire into a Counterspell lockout. CC timing is best-effort (same
`Aura::Source` caveat); the school-interrupt data is authoritative.

Any use of this is a **rotation change** (it changes which ability fires) → sign-off gate.

### 7. `C_Timer.After` / `NewTicker` — real deferred callbacks (verified, 2.01s)
The gain is *things currently impossible* — "re-check in 0.5s" without an OnUpdate frame.
Existing `GetTime()` throttles work and should not be rewritten for fashion.

*Caution:* the rotation is deliberately **synchronous and press-driven**. Deferred
callbacks that cast are a new failure mode. Limit to bookkeeping, never to issuing casts.

### 8. Smaller wins
- `C_Spell.GetSpellCooldown(spellID)` — no spellbook-slot resolution first
  (cf. `Aegis_SBR.lua:336`).
- `C_Spell.IsSpellUsable`, `GetSpellPowerCost`, `IsSpellKnown`, `IsPlayerSpell` — could
  replace parts of the spellbook scan and the mana hand-maths.
- `frame:HookScript` — would delete the hand-chained `prevEnter`/`prevLeave` pattern in
  `Aegis_SBR_UI.lua`. Low value; only if that area is being touched anyway.

---

## What it does NOT give us (avoid duplicate paths)

| ClassicAPI offers | Aegis already has it from | Verdict |
|---|---|---|
| `UnitGUID` | SuperWoW (`UnitExists` 2nd return) — **Required** | Keep SuperWoW's |
| `C_Spell.GetSpellInfo` | SuperWoW `SpellInfo(id)` — **Required** | Keep SuperWoW's |
| `UnitInLineOfSight` | UnitXP_SP3 — **Required** | Keep UnitXP's |
| `UnitPosition` | SuperWoW — **Required**, and it wins by load order | Keep SuperWoW's |

**Rule of thumb: never move an existing capability from a Required dependency onto a
Recommended one.** Use ClassicAPI only where 1.12 + the Required stack has *no* answer.

---

## Risks

- **Soft dependency.** Every call site needs a guard and a degraded path. Two code paths per
  feature is a real maintenance cost — worth it for aura timers and totems, not for
  cosmetics.
- **Platform limit.** 32-bit Windows via VanillaFixes. Players on other setups never get it.
- **Load-order coupling.** The `UnitPosition` collision makes `dlls.txt` order load-bearing.
  Document it wherever install instructions live.
- **Best-effort data.** Pre-login auras and max-stack refreshes are known blind spots. Code
  must treat "unknown" as a first-class answer, not as zero.
- **Divergence risk.** A backported function that subtly differs from the retail semantics
  it imitates will be wrong in ways that only show in combat.
- **Licensing.** ClassicAPI is GPLv3; Aegis is MIT. Calling a separately-distributed DLL's
  Lua API is not linking its source into ours — but if it were ever *bundled*, get a real
  opinion.

---

## Still to verify

The 2026-08-18 pass covered presence, coexistence, aura timing and encoding. Open:

1. **Spell range — measurement DONE** (§4: 49/128 flips disagree with the proxy, both
   directions, bounding-radius effect confirmed on a worldboss). The integration stays
   **reverted** pending a play-test on an affected class, per the regression-log rule.
   Data now collects itself: `/sbr probe on`, play, `/reload`, then
   `py scripts/read_probe.py`.
2. **Turtle duration mods**, per class:
   - Shaman — Molten Blast on a Flame Shock'd target: remaining jumps back to full
   - Warlock — Conflagrate: Immolate's remaining drops by 3s
   - Rogue — Rupture at 4 CP: `dur=14`, not 6
   - Druid — Carnage refresh on Rip/Rake
3. **Totems** (needs a Shaman): drop one, then kill it / Totemic Recall.
   `PLAYER_TOTEM_UPDATE` must fire on the early removal, not just on expiry.
4. **LossOfControl**: get stunned or kicked, then `/capi loc`.

`CAPICheck` (`OctoWoW\Interface\AddOns\CAPICheck`) is the throwaway harness for these —
delete it once answered.

---

## Recommended sequence (if the user wants to proceed)

1. **Amend the `C_*` rule** in `CLAUDE.md` to the presence-gated carve-out above.
   *(Decision, not code.)*
2. **Add the capability probe** — `Aegis_SBR:HasClassicAPI()` on `CLASSIC_API_VERSION`,
   plus per-feature probes. Ungated plumbing, inert on its own.
3. **Finish the open verifications** above — items 2-4 gate the batches below.
4. **Shared debuff-remaining helper**, preferring ClassicAPI, falling back to today's blind
   timers. Plumbing only; changing a refresh window is a separate, gated change.
5. **Totem tracking** — closes an open Phase 2 item and, as pure upkeep bookkeeping, is the
   least rotation-entangled real win.
6. **Spell range**, once verified.
7. **Phase 3 import/export** on `C_EncodingUtil`, gated with a clear message.
8. *Later, and clearly rotation-gated:* `C_LossOfControl`.

Items 4-8 are each their own verified batch, in that order of value.
