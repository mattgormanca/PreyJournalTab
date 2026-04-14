# CLAUDE.md

Guidance for AI assistants (Claude Code, etc.) working in this repository.

## Project Overview

**PreyJournalTab** is a World of Warcraft: Midnight addon (Interface `120001`)
written in pure Lua against the retail WoW API. It injects a **"Prey Hunts"**
tab into the native Adventure Guide (`EncounterJournal`) frame — positioned
immediately to the right of the existing Tutorials tab — and renders a custom
content panel that tracks weekly Prey Hunt contract completions (Normal / Hard
/ Nightmare, max 4 each).

There is no build system, no package manager, no tests, no dependencies. Users
install it by dropping the folder into
`World of Warcraft/_retail_/Interface/AddOns/PreyJournalTab/`.

## Repository Layout

```
PreyJournalTab/
├── PreyJournalTab.toc   # WoW addon manifest (interface version, saved vars, load order)
├── PreyJournalTab.lua   # Entire addon implementation (single file)
├── README.md            # User-facing documentation
└── CLAUDE.md            # This file
```

That is the entire source tree. Do **not** introduce a build step, bundler,
linter config, or split the Lua into multiple files unless the user explicitly
asks — the addon is intentionally distributed as a single `.lua` + `.toc`.

## The .toc Manifest

`PreyJournalTab.toc` is the WoW addon manifest. Every non-comment line that
isn't a directive (`## Key: Value`) is a file path the client loads in order.
When adding a new Lua file, you must also add its filename to the `.toc`.

Keep these fields in sync when editing:
- `## Interface: 120001` — must match the WoW Midnight client version
- `## Version: X.Y.Z` — bump when releasing; no code elsewhere depends on it
- `## SavedVariables: PreyJournalDB` — the global table persisted between sessions

## Architecture of `PreyJournalTab.lua`

The file is organised into labelled sections (separated by 80-char rule
comments `---...`). Preserve this structure when editing:

1. **Constants** — `MAX_HUNTS`, `FULL_REWARD_CAP`, `DIFFICULTIES`, `COLORS`,
   `GOLD`, panel dimensions.
2. **SavedVariables helpers** — `GetWeeklyResetTimestamp`, `InitDB`,
   `GetCount`, `SetCount`, `GetTotalCompleted`.
3. **Persistent logger (`PJTLog`)** — timestamped, capped at 500 entries,
   writes to `PreyJournalDB.log`. Must remain defined before any function that
   calls it.
4. **Active hunt detection** — `ParsePreyTitle`, `GetZoneFromTaskQuest`,
   `ScanQuestLogForActiveHunt`.
5. **UI state (upvalues)** — `preyPanel`, `rows`, `preyFooterLabel`,
   `activeSection`, `preyTabButton`, `preyTabIndex`.
6. **Display update** — `UpdateActiveHunt`, `UpdateDisplay`.
7. **Content panel builder** — `BuildPreyContent` (uses `UI-Journeys-*` atlases).
8. **Show / hide logic** — `TryHookEJ`, `ShowPreyTab`, `HidePreyTab`,
   `HidePreyTabFromClick`.
9. **EJ tab helpers** — `GetAllEJTabs`, `FindTabByText`.
10. **Setup** — `SetupEncounterJournalTab` (the big one — tab creation, reload
    rewiring, stale-index recovery).
11. **Events** — `eventFrame` registering `ADDON_LOADED`, `PLAYER_ENTERING_WORLD`,
    `QUEST_TURNED_IN`, `QUEST_ACCEPTED`, `QUEST_REMOVED`.
12. **Debug helpers** — `LogFrameRegions` (recursive region tree dumper).
13. **Slash commands** — `/preyhunts` and `/pjt`.

### Key Design Decisions (don't regress these)

- **Single-file addon.** Everything lives in `PreyJournalTab.lua`.
- **Triple registration for EJ hook.** `ADDON_LOADED` (own name + legacy
  `Blizzard_EncounterJournal`) plus `PLAYER_ENTERING_WORLD` as a final
  fallback. Midnight bakes EJ into FrameXML so the own-name path is the one
  that usually fires first.
- **Setup is deferred to EJ's `OnShow` + one `C_Timer.After(0, ...)` tick.**
  This is critical — without the tick, transiently-visible tabs (e.g.
  `EncounterJournalLootJournalTab`) inflate the tab count and the Prey Hunts
  tab gets created at the wrong index. Do not remove this deferral.
- **Tab detection scans by position, not by global name.** The EJ's native
  tabs are named things like `EncounterJournalJourneysTab`, not
  `EncounterJournalTab{N}`. Only the tabs we create use the `Tab{N}` naming.
  Scan logic lives in `GetAllEJTabs` and filters to shown buttons within 60px
  of the EJ bottom edge, then sorts left-to-right by X center.
- **Reload path with stale-index recovery.** On `/reload`, previous frames
  persist as globals (`PreyJournalTabPanel`, `EncounterJournalTab{N}`). The
  reload path recomputes the expected index and, if it doesn't match (e.g. the
  tab was originally created during the transient-tab bug), discards the old
  button and re-runs first-time setup at the correct index. This logic is in
  the top of `SetupEncounterJournalTab`.
- **`wasOnPreyTab` restores the panel across EJ hide/show cycles.** It is
  cleared only on an explicit click on another tab (`HidePreyTabFromClick`),
  never on EJ close.
- **No EJ children are hidden.** `preyPanel` sits at
  `EncounterJournal:GetFrameLevel() + 50` and overlays the native content.
  Don't "clean up" by hiding EJ's content frames — it breaks their tabs.
- **Auto-tracking is pattern-based, not quest-ID based.** `ParsePreyTitle`
  matches titles of the form `Prey: <Target> (Normal|Hard|Nightmare)`. This is
  intentional — it works across all four Midnight zones without a hardcoded
  quest-ID table. Do not regress this by adding a quest-ID whitelist.
- **Weekly reset is Tuesday 15:00 UTC (US/EU standard reset).** Hardcoded in
  `GetWeeklyResetTimestamp`. A known limitation for Oceanic players.
- **Log cap: 500 entries.** Enforced in `PJTLog`. Don't raise casually —
  `panelscan` and `suggestinspect` dump hundreds of lines per invocation and
  the log lives in `SavedVariables` which is serialised on every logout.

### SavedVariables Schema

```lua
PreyJournalDB = {
    lastReset = <unix timestamp>,            -- last applied weekly reset
    counts    = { Normal, Hard, Nightmare }, -- 0..MAX_HUNTS[diff]
    log       = { "[YYYY-MM-DD HH:MM:SS][CATEGORY] msg", ... },
}
```

Log categories currently in use: `SETUP`, `TAB`, `QUEST`, `CMD`, `NAV`,
`PANEL`, `SUGGEST`. Prefer reusing an existing category over inventing a new
one unless you're adding a new feature area.

## Slash Commands

The `/preyhunts` (alias `/pjt`) handler is the one-stop debugging entry point.
When adding a new debug command, follow the existing pattern: `elseif cmd == "..."
then` inside `SlashCmdList["PREYJOURNALTAB"]`, print a confirmation to chat,
and log to `PJTLog`.

Existing subcommands: `reset`, `inspect`, `panelscan`, `suggestinspect`, `log`,
`clearlog`. Default (no arg) opens the EJ on the Prey Hunts tab.

## Coding Conventions

- **Lua style:** 4-space indentation, aligned assignments in constant blocks
  (see `COLORS`, `MAX_HUNTS`), `---`-padded section banners at 80 cols.
- **Naming:** `PascalCase` for functions, `camelCase` or short lowercase for
  locals, `UPPER_SNAKE` for file-scope constants, `PreyJournalDB` /
  `PreyJournalTabPanel` for exported globals (prefix all globals with `Prey`
  or `PJT` to avoid collisions — this is a WoW convention and matters because
  the global table is shared across all addons).
- **Colour escapes:** `|cffRRGGBB...|r` with the addon's brand red `ff6060`
  for chat prefix and `ffd700` for highlights.
- **Never call Blizzard internals you haven't verified exist.** When adding UI
  code, use `panelscan` / `suggestinspect` to discover the actual atlas names
  and templates used by that panel, then mirror them. The codebase has done
  this successfully with `UI-Journeys-*` atlases.
- **Defer layout-sensitive work one tick.** If you read `GetCenter`,
  `GetSize`, `IsShown`, etc. during setup, wrap the read in
  `C_Timer.After(0, function() ... end)` if there's any chance Blizzard is
  still mid-layout.

## Testing & Validation

There is no automated test suite — WoW addons are validated in-game. When you
make changes:

1. Verify the `.lua` parses by eye (there is no CI lint). Common mistakes:
   unbalanced `end`, missing commas in table literals, forgetting to update
   the `.toc` when renaming files.
2. Recommend the user `/reload` in-game and test:
   - Open the Adventure Guide — Prey Hunts tab appears as the rightmost tab.
   - Click the tab — content panel renders without clipping or overlap.
   - Click back to Tutorials/Dungeons — prey panel hides cleanly.
   - Close and reopen EJ while on the prey tab — panel is restored.
   - `/reload` while on the prey tab — tab is re-wired at the correct index.
3. For auto-tracking changes, ask the user to run `/preyhunts log` after a
   hunt completion to confirm the `QUEST` log entry fired.

## Git Workflow

- Default branch: `main`.
- Feature work for this task lives on branch
  `claude/add-claude-documentation-M1SzD`.
- Commit messages in this repo are short and declarative — match the existing
  style (e.g. "README file update", "Add files via upload").
- Do **not** open pull requests unless the user explicitly asks.

## What NOT to do

- Don't split `PreyJournalTab.lua` into multiple files.
- Don't introduce a package manager, Luarocks, or a build step.
- Don't add a `.luacheckrc` or formatter config without the user asking.
- Don't hardcode quest IDs for prey targets — title-pattern matching is the
  design.
- Don't hide native `EncounterJournal` child frames to "clear space" for the
  prey panel — the overlay design is intentional.
- Don't create a pull request proactively.
