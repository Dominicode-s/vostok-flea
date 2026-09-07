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
| M2 | Read-only client (browse + price data) | **complete** |
| M3 | Selling: escrow, deliveries, courier crate | **complete** |
| M4 | Buying | **complete** |

All of v1's client scope is built and exercised in-game: browse, price data,
selling with escrow and deliveries, and buying. Buy orders / wanted ads are
v1.1 and deliberately absent — there are no endpoints, so a tab would be a
promise the server cannot keep.

What is left before this ships to players:

- **3D models** for the terminal and the crate. Drop `model/terminal.obj` and
  `model/crate.obj` into `mods/FleaMarket/model/` and they are picked up
  automatically; see the README there. Until then both render as placeholder
  boxes, fully functional.
- **Restore the production delivery ETA.** It is currently set to ~20s for
  testing; production is a 15-minute base. The wait is the intended feel, not
  friction — see §7.5.
- **A player key per player.** The mod ships with none; each player pastes one
  into the terminal's Setup screen once.

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

## Where the safety actually lives

Four files carry the "no failure can lose a player's property" guarantee, and
they are the ones to read first if you are picking this up:

| File | What it protects |
|---|---|
| `PendingLedger.gd` | The crash-recovery record. Written and flushed to disk **before** anything is destroyed — the only window in the design where property can genuinely be lost, and it is entirely client-side. |
| `SellFlow.gd` | Two-phase sell. Recovery re-checks the inventory rather than assuming, because writing the ledger first creates the opposite risk: a crash between the write and the destroy would otherwise publish a listing for an item the player still holds. |
| `BuyFlow.gd` | Two-phase buy. Cash is fungible, so there is no descriptor to match on recovery — the trade-offs that follow from that are documented in the file. |
| `DeliveryService.gd` | Spawns goods, records that it did, **then** acknowledges. The server cannot tell a lost ACK from a re-request, so a delivery already marked spawned is only ever re-acknowledged. |

Phase 2 of every flow returns **HTTP 200 whether or not it did what you asked**
— `returned` and `credited` are not errors. Every one of those paths is
reachable on demand via `tools/chaos_server.py`.

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
