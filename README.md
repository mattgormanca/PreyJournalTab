# PreyJournalTab

**Version:** 1.1.0  
**Interface:** 12.0.0.1 (World of Warcraft: Midnight)  
**SavedVariables:** `PreyJournalDB`

A World of Warcraft addon that integrates Prey Hunt tracking directly into the Adventure Guide as a native tab, appearing after the existing Tutorials tab.

---

## Download

Grab the latest packaged addon here:

- [**PreyJournalTab.zip**](PreyJournalTab.zip) — ready-to-install archive

## Installation

1. Download [**PreyJournalTab.zip**](PreyJournalTab.zip) and extract it.
2. Copy the resulting `PreyJournalTab` folder into your addons directory:
   ```
   World of Warcraft/_retail_/Interface/AddOns/PreyJournalTab/
   ```
3. Log in or reload your UI (`/reload`).
4. Open the Adventure Guide (`J` or via the main menu) — the **Prey Hunts** tab will appear at the far right of the tab bar.

> **Note:** If you also have the **WeeklyTracker** addon installed, use `/preyhunts` to open to this tab directly. Do not use `/prey` — that command belongs to WeeklyTracker.

---

## What You See On Screen

### The Tab

A **Prey Hunts** tab appears as the last tab on the Adventure Guide window, positioned immediately to the right of the **Tutorials** tab. It uses the same `PanelTabButtonTemplate` as all native EJ tabs, so it looks and behaves identically to the built-in tabs — including the active/inactive tab art.

### The Content Panel

When the Prey Hunts tab is selected, the Adventure Guide's inner content area is replaced with a tracking panel. The outer window border, title bar, close button, and all other tabs remain fully visible and functional.

The panel contains three sections:

#### Active Hunt
A card at the top of the panel showing your currently active Prey Hunt contract, if one is in progress. It displays:
- **Target name** — the name of the prey you are currently hunting (e.g. *Knight-Errant Bloodshatter*)
- **Difficulty** — Normal, Hard, or Nightmare, colour-coded green / orange / red
- **Zone** — the zone the hunt is taking place in, if it can be resolved from the quest log

If no hunt is in progress, the card shows *"No hunt in progress"*.

#### Weekly Progress
Three cards, one per difficulty, showing how many hunts you have completed this week out of the maximum four:

| Difficulty | Colour   | Max per week |
|------------|----------|--------------|
| Normal     | Green    | 4            |
| Hard       | Orange   | 4            |
| Nightmare  | Red      | 4            |

Each card displays a `−` and `+` button for manual adjustment, in case the auto-tracking misses a completion.

#### Footer
A status line at the bottom of the panel showing how many of the **4 full-reward hunts** remain for the week (the account-wide cap that awards 1,000 Preyseeker's Journey progress per hunt). Once all four are claimed it shows *"Full weekly rewards claimed!"*.

---

## Commands

| Command | Description |
|---------|-------------|
| `/preyhunts` | Opens the Adventure Guide directly to the Prey Hunts tab |
| `/pjt` | Shorthand for `/preyhunts` |
| `/preyhunts reset` | Resets all weekly hunt counts to zero |
| `/preyhunts inspect` | Dumps all immediate children of the EncounterJournal frame to chat (for debugging) |
| `/preyhunts panelscan` | Deep-dumps all textures and font strings from currently-visible EJ content frames to the persistent log (for atlas research — navigate to the tab you want to scan first) |
| `/preyhunts suggestinspect` | Deep-dumps the EncounterJournalSuggestFrame region tree to the persistent log (run while on the Suggested Content tab) |
| `/preyhunts log` | Prints the last 20 entries from the persistent log to chat |
| `/preyhunts clearlog` | Clears the persistent log |

---

## Auto-Tracking

Hunt completions are detected automatically. When you turn in a Prey Hunt quest, the addon fires on the `QUEST_TURNED_IN` event, reads the quest title via `C_QuestLog.GetTitleForQuestID()`, and checks whether it matches the pattern:

```
Prey: <Target Name> (Normal|Hard|Nightmare)
```

If the title matches, the corresponding difficulty counter is incremented and a confirmation message is printed to chat:

```
[PreyJournalTab] Auto-tracked Hard hunt! (2 / 4 this week)
```

This approach is future-proof — it matches any target name across all four Midnight zones without requiring a hardcoded quest ID list.

The addon also registers `QUEST_ACCEPTED` and `QUEST_REMOVED` events to refresh the **Active Hunt** card whenever a quest is accepted or abandoned, so the card stays current without needing the panel to be reopened.

---

## Weekly Reset

Counts reset automatically at the weekly reset time: **Tuesday 15:00 UTC** (the standard US reset). The addon computes the most recent past Tuesday at 15:00 UTC on every login and compares it against the stored reset timestamp. If the stored value is older than the computed reset, all counts are wiped.

---

## Persistent Log

All significant events are timestamped and written to `PreyJournalDB.log` (capped at 500 entries). This log persists across sessions and is readable offline:

```
WTF/Account/<YourAccount>/SavedVariables/PreyJournalTab.lua
```

Logged events include:
- Tab open and close
- Hunt auto-tracking (difficulty, count, cap)
- Manual count resets
- Setup lifecycle events (hook registration, setup execution)
- Navigation via slash command

---

## Technical Details

### Hook Strategy

The Adventure Guide (`EncounterJournal`) is loaded on demand in Midnight — it is part of FrameXML rather than a separately loaded addon. The addon uses three registration points to ensure the hook is always registered:

1. `ADDON_LOADED` with arg `PreyJournalTab` — fires immediately on load; checks if `EncounterJournal` is already available
2. `ADDON_LOADED` with arg `Blizzard_EncounterJournal` — legacy path for clients where EJ ships as a separate addon
3. `PLAYER_ENTERING_WORLD` — final fallback that fires after all addons and FrameXML have initialised

In all cases, setup is **deferred to the first `OnShow` event** on `EncounterJournal`. Within that handler, execution is further deferred by one tick via `C_Timer.After(0, ...)` so that Blizzard finishes showing and hiding its own tabs before the addon scans for them. Without this deferral, transiently-visible tabs (such as `EncounterJournalLootJournalTab`) can inflate the tab count and cause the Prey Hunts tab to be created at the wrong index. Setup only runs when the EJ is actually visible on screen.

### Tab Injection

The tab button is created as `EncounterJournalTab{N}` using `PanelTabButtonTemplate`, where `N` is one more than the count of currently-visible EJ tabs. It is anchored with `SetPoint("LEFT", anchorTab, "RIGHT", 4, 0)`. `PanelTemplates_SetNumTabs` and `PanelTemplates_TabResize` are called to register it with the panel system.

Tab detection scans child buttons of `EncounterJournal` by position (buttons sitting within 60px of the frame bottom) and sorts them left-to-right. Only **shown** tabs are counted — hidden tabs such as `EncounterJournalLootJournalTab` are excluded. The anchor is the tab whose text contains "tutorial"; if none is found, the rightmost visible tab is used instead; if there are no existing tabs, the button is placed at the EJ bottom-left.

On UI reload, the addon detects previously-created frames via the `PreyJournalTabPanel` global. It verifies the stored tab index against the current visible tab count; if the index is stale (e.g. was created during a transient-tab bug), the old button is discarded and the tab is recreated at the correct position.

### Content Isolation

`preyPanel` is anchored to fill the EJ content area (`TOPLEFT` + `4, -60` to `BOTTOMRIGHT` + `-4, 6` relative to `EncounterJournal`) and runs at frame level `EJ + 50`. Because it sits above Blizzard's content at a higher frame level, no native EJ children need to be hidden — the panel simply overlays them.

When the Prey Hunts tab is selected (`ShowPreyTab`):

1. Every visible tab button child of `EncounterJournal` is visually deselected via `PanelTemplates_DeselectTab`.
2. `preyPanel` is shown and our tab button is selected via `PanelTemplates_SelectTab`.
3. `wasOnPreyTab` is set to `true` — if the EJ is closed and later reopened, the prey panel is automatically restored on the next `OnShow`.

When another tab is selected, `HidePreyTab` fires (hooked via `HookScript` on each existing tab and `hooksecurefunc` on `EncounterJournal_ShowTab`). It hides `preyPanel` and deselects our tab button. When triggered by an explicit click on another tab, `wasOnPreyTab` is also cleared.

### SavedVariables Schema

```lua
PreyJournalDB = {
    lastReset = <unix timestamp of most recent weekly reset>,
    counts = {
        Normal    = <0–4>,
        Hard      = <0–4>,
        Nightmare = <0–4>,
    },
    log = {  -- all events including panelscan and suggestinspect output
        "[YYYY-MM-DD HH:MM:SS][CATEGORY] message",
        ...
    },
}
```

---

## Known Limitations

- **Zone detection for active hunts is not always available.** Prey hunt contracts are normal quests, not world quests, so `C_TaskQuest.GetQuestZoneID()` returns nil for them. Zone is only shown if a companion task quest with "Prey" in the title is found in the quest log.
- **The `−`/`+` buttons are the fallback.** If the game client does not fire `QUEST_TURNED_IN` for a given hunt completion (e.g. if the quest was completed before the addon loaded), the counter can be manually corrected.
- **Weekly reset time is hardcoded to US/EU Tuesday 15:00 UTC.** Players on Oceanic or other regions with different reset times may see early resets.

---

## Compatibility

- Requires WoW: Midnight (Interface 12.0.0.1 or later)
- Compatible with WeeklyTracker (separate addon, different slash command — `/prey` vs `/preyhunts`)
- Does not conflict with other Adventure Guide addons as long as they do not also attempt to name a button `EncounterJournalTab{N}` with the same index
