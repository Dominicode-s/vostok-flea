# vostok-flea

Client (game mod) half of the Road to Vostok server-backed flea market.

The market is an authoritative ledger running on a VPS; this mod is a **dumb
terminal** that renders it. No market logic, no price calculation, no deciding
what a trade is worth ever lives on this side of the wire.

- Server API: `https://api.domfragsvostokmods.bid/v1`
- Server contract: see the server repo's `API.md`

## Status

| Milestone | Content | State |
|---|---|---|
| M0 | Network + capability spike | **passed** - see [docs/M0-SPIKE.md](docs/M0-SPIKE.md) |
| M2 | Read-only client (browse + price data) | **complete** — terminal, browse, detail, orders, wallet, setup |
| M3 | Selling: escrow, deliveries, courier crate | not started — `ItemBridge` done and server-validated |
| M4 | Buying | not started |

M0 passed: `HTTPRequest` over HTTPS works from a mod in an exported build, so
the transport design stands and the store-and-forward fallback is not needed.

M2 is complete and shippable on its own as a market-prices mod. The only
outstanding art dependency is a 3D model for the terminal — it currently
renders as a placeholder box.

## Layout

```
mod.txt                     Mod loader manifest
mods/FleaMarket/
  Main.gd                   Autoload: registration, catalog, terminal lifecycle
  MarketClient.gd           The ONLY component that touches the network
  Catalog.gd                Cached item catalog + the escrow version guard
  ItemBridge.gd             SlotData <-> canonical descriptor
  TerminalAssets.gd         Runtime-generated ItemData, icon, inventory sprite
  FleaTerminal.gd           The placed fixture's Interact()/UpdateTooltip()
  FleaTerminal_F.tscn       Placed world scene  <-- needs a real 3D model
  ui/                       The six terminal screens
spike/                      Milestone 0 throwaway capability prober
tests/                      Headless test suite
tools/                      Build, deploy, parse-check, test, validate
docs/                       Findings, the catalog, questions to the server side
```

## Development

```bash
tools/check-gdscript.sh        # parse-check every script (~10s, no game launch)
tools/run-tests.sh             # headless test suite
tools/validate-descriptors.sh  # ItemBridge vs the server's own validator
pwsh -File tools/build.ps1     # build + deploy the VMZ
```

`tools/check-gdscript.sh` and `tools/run-tests.sh` need a Godot 4.6.2-stable
binary (matching the game's build hash) at `D:/Projects/tools/godot/`, or
`GODOT_BIN` pointing at one. `validate-descriptors.sh` needs dev keys in
`.dev-keys.json`, which is gitignored.

## Building the spike

```powershell
pwsh -File tools\build-spike.ps1
```

Builds `Flea-Market-Spike.vmz`, deploys it to the game's `mods\` folder, clears
the loader's mount cache and deletes any previous report. Then launch the game,
reach the main menu, and quit; the probe writes its findings to:

```
%APPDATA%\Road to Vostok\FleaSpike_Report.json
```

## Non-negotiables

Carried from the design brief, restated here because they are easy to erode:

1. **The terminal is a renderer.** If a price is being computed client-side,
   the design has been broken.
2. **Ordering is exact.** The server records the item descriptor *before* the
   client destroys anything; the client ACKs a delivery *after* the goods are
   spawned. Reversing either creates a way to lose or duplicate player
   property.
3. **Every mutating call carries a client-generated idempotency key**,
   persisted in `PendingLedger` before anything is destroyed, and replayed with
   the *same* key on recovery.
4. **Offline is a designed state, not an error path.** Cached listings behind
   an explicit banner, Buy disabled. Never render a live-looking button that
   will fail.
