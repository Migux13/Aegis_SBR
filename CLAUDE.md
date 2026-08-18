# Aegis_SBR — CLAUDE.md

> Project brief for Claude Code. Read this first, every session, before touching code.

## Project Overview (WHY)
**Aegis: Single Button Rotation** (repo/folder: `Aegis_SBR`, formerly "AutoRota") is a
one-button rotation-engine addon for **Turtle WoW** — a private Vanilla+ server running a
custom **1.12 client, patch 1.18.1**. It executes exactly **one primary ability per key
press** using strict single-cast priority lists, to avoid global-cooldown clipping. It
reads combat state (mana/rage/energy, procs, debuff windows) and fires the highest-priority
ability for the player's class/spec/context. Users tune priorities in an in-game config UI
(flat-dark theme, spec tab rails, per-class ability toggles) with per-profile management.

Author tag: "Mercaius & Subtilizer (Torchlite)".

## ⛔ CRITICAL RULES (read first, never violate)
1. **NEVER change rotation or ability-priority logic without explicit user approval first.**
   The existing per-class priority lists are hand-tuned. When the research in
   `docs/rotations.md` disagrees with what a module actually does, your job is to **REPORT
   the discrepancy and ask** — produce a written diff (what the code does vs. what the
   research says, with the source/confidence tag) and WAIT for the user to decide, per
   class. Do not "fix" rotations proactively, even if you're confident. Non-rotation work
   (rebrand, UI, tooling, bug fixes that don't alter priority) does not need this gate, but
   anything that changes WHICH ability fires or in WHAT ORDER does.
2. **The Phase 0 rebrand to Aegis_SBR is DONE (v0.14.0)** — folder/.toc/files renamed,
   `/sbr` primary (+ `/aegis`, legacy `/ar`), `AutoRotaDB` → `AegisDB` migration shim in
   place. Do not reintroduce the old names; keep the shim + toc backup line until the
   deprecation window closes (see `docs/roadmap.md` Phase 0).
3. Run `python3 scripts/verify.py --all` after every edit; never hand off a failing file.

## Current State / Next Task
**Current release: v1.1.8** — the Rogue combo-point/energy economy cut, driven by replaying
~2000 logged presses rather than theory (it reverted two of our own earlier changes with the
measurements that killed them). Since v1.1.4: **v1.1.5** `/sbr spell <name>` toggles instead
of silently switching off; **v1.1.6** Hunter's Mark leads the rotation (approved priority
change) + `verify.py` lookbehind fix; **v1.1.7** Shaman totem + imbue overhaul, per-context
buff lists, Paladin melee heal margin; **v1.1.8** as above.

**⚠️ The working tree holds TWO INDEPENDENT UNCOMMITTED STRANDS.** They are unrelated and
must not land in one commit — branch them separately from `origin/main`:
1. **Rogue** — `ExposeDue` / `MarkReady` / `PreparationReady` (Expose Armor, Mark for Death,
   Preparation) in `Class_Rogue.lua` + `Class_Rogue_UI.lua` + `docs/rotations.md`.
2. **ClassicAPI integration** — everything below.

### ClassicAPI integration (uncommitted, unreleased)
ClassicAPI is now **installed and active on the dev client** (`CLASSIC_API_VERSION = 10911`,
alongside SuperWoW + Nampower + UnitXP_SP3; nothing in the Required stack broke). The `C_*`
ban is amended — see Hard Constraints; all access goes through **`Aegis_SBR_Capabilities.lua`**,
which owns every probe and wrapper and returns `nil` for "unknown".

New files: `Aegis_SBR_Capabilities.lua` (capability layer + passive probe log),
`Aegis_SBR_Range.lua` (distance window with a self-calibrating melee/dead-zone/ranged scale),
`scripts/read_probe.py` (reads the probe SavedVariable off disk). New SavedVariable
`AegisProbe`; new commands `/sbr capi`, `/sbr probe`, `/sbr range`.

**Wired into rotations (all suppress-only unless noted):** Warlock `DotRemaining` prefers the
real expiry; Shaman Flame Shock holds on a known remaining time (covers Turtle's Molten Blast
refresh, audit item **S1**); Shaman totems read the element slot directly and react to
`PLAYER_TOTEM_UPDATE` — **this closes the open Phase 2 item "totem-destruction detection"**;
Hunter sting and `DebuffUpAny` for Hunter's Mark. The `markOK` fix is the one change on the
"adds casts" side and is **flagged for play-test**.

**REVERTED, do not re-apply without a play-test:** the `InMeleeRange()` melee-range
integration. Field data justifies it (49 of 128 boundary flips disagree with the 9.9yd proxy;
the bounding-radius effect confirmed on a worldboss) but it is on the "adds casts" side and
its sibling change caused the Auto Shot regression — see the Lessons list and
`docs/research-classicapi.md`.

**Open verification** (the probe log collects it passively — `/sbr probe on`, play, `/reload`,
then `py scripts/read_probe.py`): Rupture combo-point duration (expect `dur=16.0` at 5 CP vs a
`6.0` base — 5 CP is the decisive single test); Warlock DoT timers; Shaman Flame Shock + totem
destruction in play; `markOK` against another hunter's Mark; `C_LossOfControl` (unused so far).

### Carried forward
- **Warrior Overpower** (open since v1.1.4): reported as passed over for Slam/Heroic Strike,
  though it already sits ABOVE both. Likeliest cause is the Battle Stance gate or
  `overpowerExpiry` being zeroed before a cast that then fails (Revenge has the same shape).
  Awaiting a `/sbr log` capture; the Warrior trace already carries `op=Y/N`.
- **PR #32** (a `holyLightPct` health gate) was **closed unmerged**, superseded by #33 — not
  shipped; whether a slider is wanted, and which way it points, is still open.
- Phase 2 leftovers: off-hand imbue, poison auto-apply beyond the Quick Bar.
- **Logos:** raw image files still pending from the user. They need TGA conversion
  (power-of-two, 32-bit, uncompressed). The header stub already tries
  `Interface\AddOns\Aegis_SBR\logo` and falls back to the sigil + wordmark while absent
  (1.12 `SetTexture` returns nil for a missing file). Drop `logo.tga` in the addon root and do
  a **full relog**.
- `updatelog.md` was asked for but never created; `CHANGELOG.md` currently carries the
  history. Confirm with the user whether a second, differently-scoped file is actually wanted.

## Tech Stack / Hard Constraints (WHAT — read carefully, these bite)
- **Language: Lua 5.0** (Turtle 1.12 client). Non-negotiable:
  - Use `table.getn(t)` — **NOT** `#t`.
  - Use `math.mod(a, b)` — **NOT** `a % b`.
  - `string.find` and `string.gsub` EXIST. `string.match` / `string.gmatch` **DO NOT** —
    parse with `find` + captures via `gsub`, or hand-rolled loops.
  - Available: `ipairs`, `pairs`, `pcall`, `setmetatable`, `getglobal`, `next`,
    `string.format`, `tinsert`/`tremove`, `getn`.
  - **Event handlers use the globals `event`, `arg1`, `arg2`, …** — NOT a
    `function(self, event, ...)` signature. (`this` is the frame.)
- **Single-pass loader**: each file loads top-to-bottom exactly once, in `.toc` order.
  Every local function/table must be **DEFINED BEFORE USE** within its file. This is the
  #1 source of silent load crashes. The ordering audit (below) exists to catch it.
- **Required dependency stack** (do NOT assume retail/other APIs exist) — **read
  `docs/dependencies.md` for the actual APIs/events/behaviors before writing engine code**:
  - **SuperWoW** — `CastSpellByName(name[, unit])`, `UNIT_CASTEVENT` (cast detection with
    caster GUID + spell id), `SpellInfo(id)` (id → name), unit GUIDs, combat-log owner tags.
  - **Nampower** — spell queueing / cast timing. **One GCD spell queued at a time; one
    non-GCD spell per server tick.** Maintained fork moved to gitea.com/avitasia; expanded
    Lua API (`SCRIPTS.md`) + custom events (`EVENTS.md`). Confirm the installed fork/version.
  - **SuperCleveRoidMacros** — conditional macro engine. **Requires Nampower v3.0.0+ and
    UnitXP_SP3**; reactive abilities must be on action bars for detection; 261-char macro
    limit; enemy-debuff timers need pfUI libdebuff/Cursive. (Repo is archived/stable.)
  - Target client: **Turtle WoW 1.18.1**.
- **Custom textures**: TGA, power-of-two dimensions, 32-bit (referenced WITHOUT the `.tga`
  extension in Lua paths, using double backslashes). New/renamed textures need a full
  relog to appear (not just `/reload`). Pure-code changes need only `/reload`.
- **1.12 UI quirks that have bitten us** (don't relearn the hard way):
  - CheckButton `SetCheckedTexture`/disabled-variant setters IGNORE file paths — you must
    grab the template texture OBJECT via `GetCheckedTexture`/`GetDisabledTexture` and call
    `SetTexture` on it. (`SetNormalTexture` DOES take a path.)
  - Slider thumb is a FIXED-size texture positioned by its CENTRE travelling the full
    track — a tall thumb overhangs the ends. Keep the thumb small and inset the slider
    inside a full-span groove.
- **Do NOT use**: `#`, `%`, `string.match`/`gmatch`, retail widget APIs,
  `SecureActionButton`/protected functions, or anything introduced after client 1.12.
- **`C_*` namespaces — banned by default, ONE carve-out** (amended 2026-08-18). They come
  from **ClassicAPI**, a DLL that is *Recommended*, never *Required*, so the addon may
  never assume they exist. The only permitted use is **through
  `Aegis_SBR_Capabilities.lua`**, which owns every probe and wrapper:
  - Never call a `C_*` function directly from the core, a class module, or the UI. Add a
    wrapper to the capability file instead, so there is exactly one guarded call site per
    function and one place to fix when a DLL version changes a signature.
  - Gate on `self:Capability("<key>")`, not on `HasClassicAPI()` — an older DLL can be
    present and still lack one function.
  - **Every wrapper returns `nil` for "unknown"**, and callers must treat unknown as "not a
    reason to act differently", falling through to the existing 1.12 path. `nil` is never
    `0` and never `false`. This is the same stance `SpellCost` and `DotRemaining` already
    take for unreadable data.
  - The fallback path is the contract, not a courtesy: a player without ClassicAPI must get
    **exactly** today's behaviour. Any change that a non-ClassicAPI player would also feel
    is a normal rotation change and needs the Rule #1 gate on its own merits.
  - Note that wiring a capability into a rotation gate changes WHEN an ability fires — that
    is a rotation change under Rule #1 even though the plumbing itself is not.

## Architecture (WHAT)
- **Shared core/UI shell** + **one rotation module per class** (9 vanilla classes), each
  with a paired `*_UI.lua` config panel. See `docs/architecture.md` for the file list and
  the shared UI primitives (the `Row` layout, `BindCheck`, `SkinButton`, section cards,
  spec tab rails, the scroll system).
- **Rotation model**: on each press, the active spec's ordered priority list is evaluated;
  the first ability whose gate passes is cast, then the function returns (strict one-cast).
- **SavedVariables**: `AegisDB` after the rebrand (migrated from `AutoRotaDB` — see the
  Phase 0 migration shim in `docs/roadmap.md`).
- **Reference docs** (read the relevant one before working in that area):
  - `docs/dependencies.md` — SuperWoW / Nampower / SuperCleveRoidMacros APIs, events,
    behaviors, and gotchas. **Read before writing any casting/detection code.**
  - `docs/rotations.md` — per-class / per-spec Turtle 1.18.1 rotation priorities (the
    reference for the rotation-correctness AUDIT — see Critical Rule #1, report don't change).
  - `docs/turtle-mechanics.md` — confirmed Turtle-specific class-change facts.
  - `docs/architecture.md` — module layout, conventions, key APIs, UI primitives.
  - `docs/roadmap.md` — phased plan; the rebrand steps; what's next.
  - `docs/sources.md` — where the game/dependency knowledge comes from, which links are
    fetchable vs. paste-only, and the two update commands. **For talents, read the in-repo
    `docs/TALENTS_1_18_1.md` — do NOT try to scrape the talent calculators (they block bots).**

## Workflow (HOW — the loop, follow it every time)
1. **Run the verifier after EVERY edit**, before presenting anything:
   ```
   python3 scripts/verify.py --all
   ```
   It runs the **balance check** (bracket/string/comment balance) AND the
   **define-before-use ordering audit**. Never commit or hand off a file that fails it.
   Target a single file with `python3 scripts/verify.py Aegis_SBR.lua` while iterating.
2. **Read the actual file content before editing** — do not edit from memory of a prior
   version; the code has moved.
3. **Incremental verified batches**: make a small, coherent change; verify; then proceed.
   Roll multi-file conversions (e.g. all class panels) in small batches, not all at once.
4. **Version cut**: `1.1.0` and up is the current scheme (pre-rebrand used letter suffixes,
   e.g. `0.13.12b`; post-rebrand ran `0.14.0`–`0.16.2` before the `v1.1.0` release cut).
   Bump the version in ALL THREE canonical spots (`.toc`, the core `.lua` `ver = "..."`,
   **and the README H1** — `# Aegis: Single Button Rotation (vX.Y.Z)`) and prepend a
   `CHANGELOG.md` entry. Keep them in sync — grep to confirm no stale version strings
   remain.
5. **Preserve `.toc` load order** — reordering files can break the single-pass loader.
6. Prefer **minimal, surgical diffs**; match existing code style and naming exactly.
7. Confirm the plan with the user before large changes; the user tests in-game and reports
   back with screenshots.

## Keeping current (dependency / mechanics updates)
Source knowledge is kept in the docs, not fetched live every session — Claude Code re-checks
sources only when the user runs an update command. `docs/sources.md` lists which links are
fetchable vs. paste-only and holds the two commands:
- **Command 1 (dependency refresh)** — check the SuperWoW/Nampower/SuperCleveRoid changelogs
  against their last-verified dates and update `docs/dependencies.md`. Run when a mod ships a
  new version.
- **Command 2 (mechanics refresh)** — re-check the Turtle Wiki against `docs/turtle-mechanics.md`
  / `docs/rotations.md` and report a discrepancy list. Run after a Turtle patch. Rotation
  priority changes still go through the audit-and-report gate (Critical Rule #1).
When you update a doc from a source, bump that source's "last verified" date in
`docs/sources.md`. For talents, consult `docs/TALENTS_1_18_1.md`; the online
calculators block automated access.

## Definition of Done (per change)
- Passes `python3 scripts/verify.py --all` (balance + ordering).
- No forbidden Lua 5.1+/retail constructs (see Hard Constraints).
- If a texture was added/renamed: noted that a **full relog** is required.
- Version bumped + CHANGELOG entry added when cutting a version; all version spots in sync.
- Files ready for the user to pull and test in-game.

## House style
- Comments explain WHY, not what. Keep the flat-dark UI conventions and palette already in
  the code. Don't introduce new dependencies. Don't refactor unrelated code in a feature
  change. When you fix a class of bug, add a one-line note to this file so it isn't
  relearned.
- **README badge header is USER-OWNED — preserve it verbatim.** The top of `README.md`
  carries the version in the **H1** (`# Aegis: Single Button Rotation (vX.Y.Z)` — bump this
  with every version cut, per Workflow step 4) plus two shields.io badge rows the user
  curates by hand: row 1 = Discord (blurple `5865F2`) · Octo WoW 1.18.1 (**purple**
  `8A2BE2`) · Capy WoW 1.18.1 (**brown** `8B5A2B`); row 2 = SuperWoW / Nampower / UnitXP_SP3
  (**Required**, **red** `C41E3A`) then ClassicAPI / SCRM (**Recommended**, **orange**
  `ff8c00`), all `style=flat-square&labelColor=555`. Do NOT add classes/license badges back,
  and do not reorder or re-colour the rows without being asked. Keep the Requirements
  table's Required/Recommended split in step with row 2.
- **Lessons already learned (don't relearn):**
  - `verify.py`'s ordering audit only flags a local defined past the calling body's END —
    a function's own inner locals (incl. closure captures) are legal, don't "fix" them
    (fixed 0.14.0; three historical false positives were exactly this).
  - When scripting bulk renames, run mechanical sweeps BEFORE inserting text that
    intentionally mentions the old name (migration shims, "formerly X" notes, legacy-alias
    comments) — or the sweep eats your own insert.
  - `verify.py`'s forward-reference check used `\b<name>\s*\(`, and `\b` matches between a
    dot and a letter — so `string.sub(` read as a call to a local named `sub`. Fixed in
    v1.1.6 with a `(?<![.:\w])` lookbehind. If a local ever shares a name with a stdlib
    function and the audit complains, check this before "fixing" the Lua.
  - An on/off command argument must be parsed with `Aegis_SBR:ToggleArg` (core), NOT
    `(arg or "") == "on"` — that idiom sends every unrecognised argument, the empty one
    included, to `false`, so a bare command silently disables what it was meant to toggle
    (fixed v1.1.5 in three places). Test its result with `== nil`; `false` is a valid return.
  - A second detection source (ClassicAPI) wired into a gate may only ever **suppress** a
    cast, never shorten a throttle or unblock one. Letting it shorten the sting retry while
    the OLD detection still decided whether to cast re-queued a ranged shot every 1.5s and
    starved Auto Shot — the Hunter looked like it had stopped attacking (2026-08-18).
    Suppression is safe however badly the two sources disagree: worst case is a missed cast,
    never a loop. Anything on the "adds casts" side needs a play-test on that class first.
