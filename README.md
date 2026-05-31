# HappyBooster

Track how many boost runs each customer has paid for — with a live counter on their unit frame, a movable window, and automatic run + trade detection. Built by a boost seller, for boost sellers and the people who buy from them.

Works on **Retail (Midnight)** and **WoW Classic Era**. Optional **Nova Instance Tracker (NIT)** integration (not required).

---

## Quick start

1. Install (see below) and `/reload`.
2. Type **`/hb`** (or click the minimap coin) to open the window.
3. In **Settings → Prices**, set what you charge per run for the dungeons you sell.
4. Trade a customer — HappyBooster reads the gold, suggests the run count, and tracks it from there.

You can also open the window from a macro: `/run HappyBooster_ToggleWindow()`.

---

## Where you see the counts

1. **The window** — a draggable panel listing every tracked player with their remaining runs and `+ / - / Set / X` buttons per row.
2. **On unit frames** — a number on each customer's party/raid frame (or your own frame in boosted mode).
3. **Minimap tooltip** — hover the coin for a quick summary.

---

## The two modes (saved per character)

Each character on your account remembers its own mode, so a booster main and a boosted alt don't flip each other back and forth on login.

- **Booster** (default) — you run customers. Trade a customer → the popup confirms how many runs they paid for → that number shows on their frame and ticks down as runs complete.
- **Boosted** — you're the customer. Trading your booster (you *pay*) adds to **your own** counter, which ticks down each run so you always know how many paid runs you have left.

Counts are stored per **Name-Realm**, so anyone who drops group and rejoins keeps their remaining runs. Your own alts can be hidden from the booster customer list with `/hb alt`.

---

## Smart trade detection

When a trade completes, HappyBooster reads the gold and, using your per-dungeon price:

- **Pre-fills the suggested run count** — you just confirm.
- **Flags underpayments** — if a customer pays less than one run's worth, the popup shows a red **UNDERPAID** warning and defaults the count to **0**, so a short-pay never silently becomes a stack of free runs. You can still override if it was intentional.
- **Tops up existing customers** — trading someone who's already tracked adds to their remaining runs instead of overwriting.

### Pick the dungeon at the trade window

A **"Selling which dungeon?"** panel docks to the trade window (booster mode) so you choose exactly which dungeon a trade is for. The dungeon you're currently in floats to the top, tagged **(here)**, and is pre-selected; unpriced dungeons appear tagged **(no price)**. Because you pick the dungeon explicitly, the price math and the underpayment warning work **even when you trade outside the instance** — in town, at the summoning stone, between runs. Your pick is sticky for the session, and the list updates live if you add a price while the window is open.

### Per-dungeon pricing

Set a price per run for each dungeon in **Settings → Prices**, or via command:

```
/hb price                        -- list all prices
/hb price default 10             -- fallback price (10g/run)
/hb price Scarlet Monastery 12   -- SM at 12g/run
/hb price Zul'Gurub 50           -- ZG at 50g/run
/hb selling <dungeon>            -- override which dungeon's price applies
```

Abbreviations work (SM, BRD, ZG, ZF, Mara, etc.).

### Dungeon name normalization

Different spellings of the same dungeon fold into a **single price row** — "Stockade", "SW Stockade", and "The Stockade" are all the same dungeon, so your prices never fragment into duplicates. Folding covers abbreviations, a leading "The", and capital-city qualifiers. Existing prices are de-duplicated automatically on update (the higher price is kept on a collision), and names display cleanly (e.g. *Scarlet Monastery*, *Zul'Farrak*) however they were typed.

---

## Run detection

**A run counts when it's done, not when you walk in** — credited on an instance reset or when you leave the dungeon, so the number always reflects runs actually completed, and a quick re-entry for repairs won't false-count. A short cooldown stops one run being counted twice.

- **Instance reset** — counts the moment the leader resets, whether you get the system message or only the group-chat announcement.
- **Inside-instance reset** — the "party leader has attempted to reset" notice counts too.
- **No NIT? Still works** — reads the session-unique instance ID embedded in mob GUIDs to detect a reset on re-entry. Works standalone; integrates with Nova Instance Tracker if present.
- **Smart leave** — leaving doesn't count instantly. A 90-second grace window covers HS-for-repair and vendor breaks; if it elapses without return, a popup asks whether the run finished.

Boss kills aren't required by default (most boosting is trash farming). Tick **Require boss kill to count a run** for stricter counting. If a run is ever missed, **Count Run** adds one for the group (and **Undo** removes one).

---

## Announce to party / raid

Click **Announce** (or `/hb announce`) to post the group's current standings to party/raid chat on demand — customers see their remaining runs, which dungeon, and who's at zero. It uses RAID or PARTY automatically and splits long lists across messages.

In **boosted mode**, an opt-in **Auto-announce 'last run' and 'out of runs'** setting posts only at the two moments that matter (1 run left, and 0 left), so there's no chat spam.

> WoW strips text colors from player chat, so announces are plain text by design.

---

## Settings

Open with the **Settings** button on the window. Toggles (each prints what it does when clicked):

- On-frame numbers
- Prompt after trade
- Require boss kill to count a run
- Count down (off = count up)
- Only prompt when gold was traded
- Auto-open window after a trade
- Open window when entering a dungeon
- Auto-announce 'last run' and 'out of runs' (boosted mode)

Plus the **Prices (per run)** editor, an **Add a dungeon** field with a **Use current dungeon's name** shortcut, and a **Restore Defaults** button (resets only the settings checkboxes — your tracked customers, prices, and stats are left untouched).

---

## Frame support (party and raid)

- **Party**: default party frames, modern `PartyFrame`, raid-style party frames, ElvUI party.
- **Raid**: default compact raid frames (both layouts), ElvUI raid, plus a generic safety-net scan that catches most other frame addons (Grid2, VuhDo, Cell, etc.).
- Your own number is never touched in booster mode, even in a 40-player raid.

> Raid frames are small — if the number crowds them, `/hb font 12` (or smaller) and `/hb pos` to reposition.

---

## Installation

1. Copy the `HappyBooster` folder into:
   - **Retail**: `World of Warcraft\_retail_\Interface\AddOns\`
   - **Classic Era**: `World of Warcraft\_classic_era_\Interface\AddOns\`
2. `/reload` or restart WoW.
3. Click the minimap coin or type `/hb`.

> **Interface number**: ships as `120005` (Midnight) and `11508` (Classic Era). If a future patch flags it out of date, get the current value in-game with `/dump select(4, GetBuildInfo())` and put it on the `## Interface:` line — the addon works either way.

---

## Commands

The window covers everything; these are for power users and for setting counts on players who aren't in your group.

| Command | Effect |
| --- | --- |
| `/hb` | Open / close the window |
| `/hb mode booster\|boosted` | Switch mode |
| `/hb set <name\|self> <n>` | Set a player's runs |
| `/hb add <name\|self> <±n>` | Adjust a player's runs |
| `/hb reset <name\|self>` | Clear a player |
| `/hb resetall` | Clear the current mode's data |
| `/hb wipe` | Clear everything (both modes) |
| `/hb count` | Count 1 run for the group |
| `/hb pin` | Pin the selected target |
| `/hb session [reset]` | Show or reset today's totals |
| `/hb stats [clear]` | Lifetime top customers |
| `/hb price [<dungeon> <gold>]` | Show or set per-dungeon prices |
| `/hb selling <dungeon>` | Override which dungeon's price applies |
| `/hb announce` | Post current standings to party/raid now |
| `/hb alt <name>` / `/hb alts` | Flag / list your own alts (hidden from the booster list) |
| `/hb minimap` | Toggle the minimap button |
| `/hb font <6-48>` | On-frame number size |
| `/hb pos <ANCHOR> [x] [y]` | On-frame number position |
| `/hb history` | Last 20 events |

---

## Files

`Core.lua` (data + counts), `Trade.lua` (trade detection), `TradePicker.lua` (trade-window dungeon picker), `Runs.lua` (run detection), `Frames.lua` (on-frame numbers), `UI.lua` (the window + settings), `Minimap.lua` (minimap button), `Commands.lua` (slash commands). Saved data lives in `HappyBoosterDB`.
