# HappyBooster v3

Track boost runs for each customer in your party **or raid**, with a live counter on their unit frame **and** a movable window you control with your mouse — no commands needed. Works on **Retail (Midnight)** and **Classic Era**. Optional **Nova Instance Tracker (NIT)** integration.

---

## Where you see the counts

Three places, pick whatever you like:

1. **The window** — your main view. A draggable panel listing every tracked player with their remaining runs and `+ / - / Set / X` buttons per row. Open it with:
   - the **minimap coin button** (left-click), or
   - the chat command **`/hb`**, or
   - a **key binding** (set one under Game Menu → Options → Keybindings → "HappyBooster").
2. **On the unit frames** — a number on each customer's party/raid frame (or your own frame in boosted mode).
3. **Minimap tooltip** — hover the coin button for a quick summary without opening anything.

---

## The window

```
┌─────────────────────────────────────┐
│            HappyBooster          [X] │
│ [ Mode: BOOSTER ]      [ Add Group ] │
│ Player            Left               │
│ ┌─────────────────────────────────┐ │
│ │ Al        0 / 5   [-][+][Set][X] │ │  <- 0 shown in red, sorted to top
│ │ Joe       3 / 5   [-][+][Set][X] │ │
│ │ Sue       4 / 5   [-][+][Set][X] │ │
│ │ ...                              │ │
│ └─────────────────────────────────┘ │
│ ☑ On-frame numbers                   │
│ ☑ Prompt after trade                 │
│ ☑ Require boss kill to count a run   │
│ ☑ Count down (off = count up)        │
│ [Count Run +1] [Reset All] [Undo]    │
└─────────────────────────────────────┘
```

- **Mode** button flips between BOOSTER (track customers) and BOOSTED (track yourself).
- **Add Group** adds everyone currently in your group at the default run count — handy when you form a fresh group. (Trades add people automatically too.)
- **Per row**: `-`/`+` adjust by one, `Set` types an exact number, `X` removes that player.
- **Count Run +1** manually counts a run for the whole group (use it if detection ever misses one).
- **Undo** adds one back to everyone from the last "Count Run".
- **Reset All** clears everyone (asks first).
- Drag the title bar to move it; position is saved. `Esc` closes it.

---

## How it works (the two modes)

### Booster mode (default) — you run customers
Trade a customer → popup asks **"How many runs paid for?"** → that number shows on their frame and in the window → each completed run ticks everyone down → at `0` it turns red, plays a sound, and prints "time to trade".

### Boosted mode — you are the customer
`/hb mode boosted` (or the Mode button). Now trading the booster (you *pay*) asks **"How many runs did you buy?"**, the count shows on **your own** frame, and each run ticks **your** count down so you always know how many paid runs you have left.

Counts are stored per **Name-Realm**, so anyone who drops group and rejoins keeps their remaining runs.

---

## Run detection

A run is counted automatically when any of these happen (whichever comes first; a short cooldown stops one run being counted twice):

- **You reset the instance** — the "X has been reset." message. This is the main boost signal: you reset the dungeon to run it again. Fires for whoever resets (usually the booster).
- **You leave the instance** — after being inside at least a few seconds (so accidental zone-outs don't count). Also covers the customer side in boosted mode and the final run before you disband.
- **Nova Instance Tracker** records a new instance, if NIT is installed.

Boss kills are **not** required by default, because most boosting is trash farming. If you only do boss carries and want stricter counting, tick **"Require boss kill to count a run."** If a run is ever missed, **Count run +1** in the window adds one manually (**Undo** removes one).

---

## Per-dungeon pricing (booster mode)

Tell HappyBooster what you charge per run for each dungeon, and after every trade it will:

- Pre-fill the popup with the **suggested run count** based on the gold paid -- you just press Enter.
- **Hard-block underpayments** -- if a customer pays less than one run's worth (e.g., 60 silver instead of 60 gold), the popup pre-fills **0** with a clear UNDERPAID warning. No accidental free runs.
- Show the math in the popup: *"Aan paid 60g (12g/run -- Scarlet Monastery). Confirm runs:"*

Set prices via commands (or leave unset for manual mode like before):

```
/hb price                              -- list all set prices
/hb price default 10                   -- set fallback price (10g/run)
/hb price Scarlet Monastery 12         -- set SM at 12g/run
/hb price Zul'Gurub 50                 -- set ZG at 50g/run
/hb price Sunken Temple 17.5           -- decimals OK (17g 50s)
/hb price clear Scarlet Monastery      -- remove a specific dungeon's price
```

Prices apply only in **booster** mode. The dungeon used is whichever you're currently inside, or the last one you ran. With no prices set the popup behaves manually (you type the count).

## Announce to party / raid

Turn on **"Announce standings to party/raid after each run"** (or `/hb announce on`) and, in booster mode, HappyBooster posts the whole group's remaining runs to party/raid chat after every run — so your customers see their own counts, which dungeon it was, and who's at zero. Example:

```
HappyBooster >> Scarlet Monastery run complete! Runs remaining:
Kristiz: 8 left  |  Wsgmaster: 3 left  |  Decimage: DONE - pay for more!
```

Only the booster announces (boosted-mode users never broadcast), it uses RAID or PARTY automatically, and long lists are split across messages. Use `/hb announce` to post the standings on demand any time. Note: WoW strips text colors from player chat, so the message is plain text by design.

## Frame support (party AND raid)

- **Party**: default party frames, modern `PartyFrame`, raid-style party frames, ElvUI party.
- **Raid**: default compact raid frames in both layouts (Combined Groups + Separate Groups), ElvUI raid, plus a generic safety-net scan while in a raid that catches most other addons (Grid2, VuhDo, Cell, etc.).
- The counter never touches your own number in booster mode, even in a 40-player raid.

> Raid frames are small — if the number crowds them, `/hb font 12` (or smaller) and `/hb pos` to reposition.

---

## Installation

1. Copy the `HappyBooster` folder into:
   - **Retail**: `World of Warcraft\_retail_\Interface\AddOns\`
   - **Classic Era**: `World of Warcraft\_classic_era_\Interface\AddOns\`
2. `/reload` or restart WoW.
3. Click the minimap coin or type `/hb`.

> **Interface number**: ships as `120005` (Midnight 12.0.5) and `11508` (Classic Era). If a future patch flags it out-of-date, get the exact value in-game with `/dump select(4, GetBuildInfo())` and put it on the `## Interface:` line. The addon works either way.

---

## Commands (optional — the window covers everything)

| Command | Effect |
|---|---|
| `/hb` | Open / close the window |
| `/hb mode booster\|boosted` | Switch mode |
| `/hb set <name\|self> <n>` | Set a player's runs (works for players not in your group) |
| `/hb add <name\|self> <±n>` | Adjust a player's runs |
| `/hb reset <name\|self>` | Clear a player |
| `/hb resetall` | Clear everyone |
| `/hb count` | Count one run for the group |
| `/hb price` / `/hb price <dungeon> <gold>` | Show or set per-dungeon prices (see Pricing section) |
| `/hb announce` | Post current standings to party/raid now |
| `/hb announce on\|off` | Auto-post standings after every run |
| `/hb minimap` | Show/hide the minimap button |
| `/hb font <6-48>` | On-frame number size |
| `/hb pos <ANCHOR> [x] [y]` | On-frame number position |
| `/hb history` | Last 20 trades/runs |
| `/hb debug` | Toggle debug output |

---

## Files

`Core.lua` (data + counts), `Trade.lua` (trade detection), `Runs.lua` (run detection + NIT), `Frames.lua` (on-frame numbers), `UI.lua` (the window), `Minimap.lua` (minimap button), `Commands.lua` (slash commands), `Bindings.xml` (key binding). Saved data lives in `HappyBoosterDB`.
