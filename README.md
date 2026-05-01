# Station Trade Data Tab

> **Alpha warning:** this mod is early alpha software. No compatibility testing has been done with other mods, especially mods that change the map UI, trade data, station discovery, or sidebar behavior. Back up saves before relying on it in a long-running game.

Station Trade Data Tab adds a **Trade Data** panel to the X4: Foundations map sidebar. It collects stations where the player currently has usable trade information and presents either raw buy/sell offers or calculated best-trade opportunities.

## Requirements

- X4: Foundations
- kuertee UI Extensions and HUD
- SirNukes Mod Support APIs

The mod declares these dependencies in `content.xml` and `ui.xml`.

## Opening the Tab

1. Open the map.
2. Use either the left or right sidebar.
3. Select **Trade Data**.

The tab shows a refresh button, filters, a small summary line, and the matching station rows. Station and buyer rows can be right-clicked to open the normal interact menu for that object.

## What the Tab Shows

The tab has three modes:

- **Best Trades**: shows profitable one-trip sell-to-buyer opportunities.
- **Sell Offers**: shows known station sell offers.
- **Buy Offers**: shows known station buy offers.

In **Best Trades**, each station row is a seller. Buyer rows are nested beneath it, and ware rows show:

- **Trip**: units moved in one trip using the current Cargo Volume setting. If the full offer is larger than one trip, it shows `trip/full`.
- **Jumps**: gate distance from the seller sector to the buyer sector.
- **Buy Cr**: price paid at the seller.
- **Sell Cr**: price received from the buyer.
- **Trip Profit**: `(sell price - buy price) x trip amount`.
- **$/Jump**: trip profit divided by route jumps, using 1 as the divisor for same-sector trades.

Large numbers are compacted in the table, and the exact values are available in hover text.

## Filters

- **Mode** switches between Best Trades, Sell Offers, and Buy Offers.
- **Ware** filters to one or more wares. Selecting entries toggles them, and the small **X** button resets it to All Wares.
- **Sector** filters to one or more station sectors. Selecting entries toggles them, and the small **X** button resets it to All Sectors.
- **Faction** filters to one or more station-owner factions. In Best Trades, either the seller or buyer can match.
- **Illegal Wares** hides illegal wares by default, can show them, or can show only illegal wares. Legality is checked against the station sector police faction.
- **Search Origin** chooses the sector used by the Search Area filter.
- **Search Area** limits displayed stations by gate distance from Search Origin.
- **Max Trade Distance** limits seller-to-buyer route distance in Best Trades.
- **Cargo Volume** sets the one-trip cargo capacity used for Best Trades. By default it follows the selected player ship's largest free cargo storage. `0` means use the full matching offer amount. Manual edits stop auto-following; click **Auto** to use the selected ship again or **Apply** after typing to refresh immediately.

The **Refresh Trade Data** button rebuilds the cached dataset manually. The tab also marks the dataset dirty when the registry reports changed station data.

## How It Works

The mod is split between Lua UI code and a small Mission Director registry:

- `ui/trade_data_tab.lua` registers a new map sidebar entry through kuertee UI Extensions.
- `md/trade_data_registry.xml` watches discovery and trade-data events, builds a player blackboard station registry, and raises Lua events when data changes.
- Lua reads the registry, merges it with player-owned stations, rendered map stations, and the previous station cache, then calls `GetTradeList` only for operational station objects that are player-owned, currently in live view, or covered by a trade subscription.
- Lua builds ware, sector, and origin-sector filter lists from the current dataset.
- Best-trade rows are calculated from all matching sell offers and buy offers for the same ware.
- Gate-distance filtering and exact trade-distance lookups use Mission Director `find_sector_in_range` through UI-triggered events and player blackboard cache tables.

The data flow is intentionally cache-heavy because map UI refreshes are frequent. The Lua side keeps a station dataset, per-frame best-trade rows, sector graph data, and route-distance caches. The MD side owns the expensive sector-range queries that are easier and more reliable in Mission Director.
