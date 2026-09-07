# Decisions taken while you were asleep

**2026-09-08.** You asked me to sort out the loose ends and leave a record of
anything I decided for myself. This is that record. Everything here is
reversible; the ones I'd most expect you to disagree with are marked.

---

## Things you had already flagged

### Restored the production delivery ETA

Testing values (20s base) are gone; §7.5 production values are back:
`delivery_eta_base_seconds` 900, `bulk_seconds` 30, `value_divisor` 1000,
`max_seconds` 7200.

The 15-minute wait is the intended feel — "order, play, come back to a full
crate" is the design, not friction. Config is a runtime row, so if you want it
fast again for testing it is one `update config` away and takes effect within
15 seconds without a deploy.

### Removed the M0 spike from the game

`Flea-Market-Spike.vmz` is deleted from the game's `mods/` folder, along with
its mount cache and stale report. It did its job days ago and was making a
pointless HTTP call with a dead key on every launch.

It stays in the repo under `spike/` as the evidence behind
`docs/M0-SPIKE.md`. Nothing is built on it.

---

## Features I added

I judged all three to be *in* v1 scope rather than additions, but they were not
things you asked for on the night, so they are listed here.

### Wallet withdrawal — §8.1 screen 6

Previously stubbed as "arrives with the courier crate". The crate exists now,
so the stub was just an unfinished screen. `POST /v1/wallet/withdraw` is wired,
with the amount capped at the balance and a warning about crate space, because
a large withdrawal arrives as multiple 99,999 stacks and each needs a slot.

No `PendingLedger` entry: nothing is destroyed client-side, the server moves
its own credit into a delivery. Same reasoning as cancelling a listing.

### Selling to the broker — §7.3, §12

`POST /v1/broker/sell` was in the v1 API surface and unimplemented. Without it,
an item nobody wants sits on the market for 72 hours; §7.3's whole argument is
that the broker guarantees you can always sell.

It shares `SellFlow`'s ordering discipline and recovery rather than copying
them. Verified end to end against the live server: quoted 190, paid 190,
delivery scheduled, and `not_in_basket` refuses cleanly for an item outside the
basket.

### Standing listings, and cancelling them

You found this one: My Orders only showed deliveries. It now shows your
listings too, with a Cancel button.

This needed a **server change** — a `mine=true` filter on `GET /v1/listings`.
Filtering the browse feed by callsign client-side would have worked today and
broken quietly once the market pages, because your own listing might not be on
the page fetched.

---

## Judgement calls

### Cash System stays an OPTIONAL dependency  ← most likely to be contentious

The loader supports `required=`, which blocks the mod with an explanation when
a dependency is missing. Trading genuinely needs the Cash mod, so `required`
is defensible.

I kept it optional. Browsing and price-checking work perfectly without cash,
and the brief was explicit that a read-only price-check mod is shippable on its
own. Blocking the whole mod would delete a feature that works.

The screens that need cash now say so plainly — "The Cash System mod is not
installed" rather than "you need 500 roubles", which would send someone looking
for money instead of for the dependency.

**Change it to `required=["cash-system"]` in `mod.txt` if you disagree.**

### The fixtures are granted, not sold

I registered both with `trader_pools: []`, intending "granted only". The
registry overrode that and defaulted them to the Generalist trader, warning
that furniture is otherwise unreachable. I left the override in place: it is a
sensible fallback if a player scraps theirs, and fighting the registry to
prevent it would be effort spent making the mod worse.

So both fixtures are **granted free on first shelter entry AND purchasable from
the Generalist**. Slightly redundant, harmless.

### Buying is refused with no crate placed

Not a server-side error — the server would happily take the money and hold the
delivery. But buying with nowhere for the goods to land is a trap, so the
button greys itself out and says why.

### The property test's flaky threshold was raised, not lowered

Server-side. At 60 runs, `deliveriesAcked` landed anywhere in 16..33 against
its own `> 20` assertion, so the suite failed about half the time on a healthy
tree. I raised the run count to 150 rather than lowering the threshold: the
threshold is the point, and a self-coverage check that flakes teaches you to
re-run until green. Costs about 20 seconds.

---

## Packaging

- **`CHANGELOG.md`** — written for players, not for us. It leads with what the
  mod does and states the three things it does not do yet.
- **`.github/workflows/build.yml`** — builds the VMZ on push, and a GitHub
  Release on a `v*` tag, matching the convention your other mods use. It also
  guards two mistakes that have actually happened here: backslash paths (the
  loader rejects those as `BAD ZIP`) and a missing fixture scene.
- CI deliberately does **not** run the test suites. They need a Godot binary
  and the decompiled game, neither of which belongs in a public runner.

---

## What I could not do

- **The 3D models.** Drop `model/terminal.obj` and `model/crate.obj` into
  `mods/FleaMarket/model/` and they are picked up automatically. Origin at the
  base is the one rigid requirement; the folder's README has the rest.
- **A player key for anyone but you.** Your `FleaMarket.cfg` currently holds
  `dev_buyer`, a shared key from the server box. Fine for you, wrong for
  anyone else — each player pastes their own into the Setup screen.

---

## Known limitations, stated plainly

- **Buy orders / wanted ads are absent.** v1.1 per §11, and there are no
  endpoints, so a tab would be a promise the server cannot keep.
- **Non-empty containers cannot be sold.** Selling one would destroy its
  contents, so it is refused. That covers 28 items including 12 pieces of
  clothing with pockets, not just backpacks.
- **Cash recovery is weaker than item recovery, deliberately.** Cash is
  fungible, so after a crash there is no descriptor to match against the
  inventory — the `destroyed` flag is the only record. `BuyFlow` documents the
  trade-off where it is made.
- **Daily sell caps are real**: 40 items or 50,000 value per player per day.
- **The save depends on the mod's generated files.** Placed furniture
  references `user://FleaMarket/*.tres` from the shelter save. They are rebuilt
  every launch, so this is invisible in normal use, but uninstalling the mod
  with fixtures placed will make the shelter save complain. The Cash mod has
  the same exposure; it is an accepted pattern here rather than something new.

---

## State

| | |
|---|---|
| Client | v0.7.0, 20 scripts, 98 tests across 4 suites |
| Server | commit `68910e4`, deployed, healthy, 52/52 |
| M0 spike | passed, retired |
| M2 / M3 / M4 | complete, all exercised in-game |

The one thing standing between this and a release is the art.
