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
| M0 | Network + capability spike | in progress |
| M2 | Read-only client (browse + price data) | not started |
| M3 | Selling: escrow, deliveries, courier crate | not started |
| M4 | Buying | not started |

M0 is blocking. Nothing else gets built until the capability table in
`docs/M0-SPIKE.md` is filled in from an actual exported-build run.

## Layout

```
spike/          Milestone 0 throwaway capability prober (not production code)
  mod.txt
  mods/FleaSpike/Main.gd
tools/          Build + deploy scripts
docs/           Findings, decisions, and questions back to the server side
```

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
