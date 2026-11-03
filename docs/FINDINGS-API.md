# Findings: the API contract, from building against it

**For:** the server side
**From:** the client side, 2026-09-07
**Status:** **all five resolved and deployed, 2026-09-07.** Kept as the record
of what was wrong and why, since each fix has a reason worth not re-litigating.
Server commit `3a32c34`.

Thank you for the descriptor work — `condition_scale`, dropping `durability`,
plain-key attachments and the container refusal all landed exactly as proposed,
and the rejection messages name the real problem rather than a schema path.
`ItemBridge` now agrees with your validator: **89 descriptors accepted across
three dev keys, zero descriptor rejections.**

Five things surfaced while building against it.

---

## 1. Phase 1 consumes the daily sell caps — RESOLVED

> **Fixed.** The cap is now split: `assertSellCapAvailable` checks in phase 1
> (refuses while the player still has the item, so a refusal costs nothing),
> and `chargeSellCap` charges at confirm and cannot throw (by then the goods
> are gone and confirm may not refuse on business grounds). Verified live: 120
> consecutive phase-1 calls, previously fatal at 40, all accepted.

Your handoff note says phase 1 *"records a descriptor and moves nothing — no
escrow, no fee, no ledger posting"*, and:

> you can hammer `POST /v1/listings` with every awkward item in the game …
> Use it on day one.

You can't, quite. Phase 1 counts against the daily sell caps:

```
422  daily sell value cap reached: 50000 per day
422  daily sell cap reached: 40 items per day
```

The game has 249 tradeable items and my harness generates 434 descriptor
variants across them. At 40 items per key per day, validating the catalog once
takes three keys and most of a week — and a client that is *failing* validation
burns its budget fastest, exactly when it most needs to iterate.

It also seems inconsistent with the design: if phase 1 escrows nothing and
posts nothing to the ledger, there is nothing yet to abuse. The caps look like
they belong on **confirm**, where goods actually cross the world boundary.

**What would help, in order of preference:**

1. Exempt phase 1 from the caps, counting them at confirm instead.
2. A config flag lifting caps for dev keys.
3. Failing both: say so and I will shard the run across keys and days.

Not urgent for M2, which needs no descriptors at all. It is the gating item for
M3.

---

## 2. `capacity` and `magazine_size` missing from `/catalog` — RESOLVED

> **Fixed.** Both are published. `capacity` is cast to `float8`, because
> `numeric` arrives as a *string* over JSON and a client comparing `"0" > 0`
> would conclude nothing is a container. 28 items are containers: 12 clothing,
> 7 backpacks, 5 rigs, 4 belt pouches.

`API.md` is explicit that `capacity` is *the* container signal:

> The container signal is `catalog.capacity > 0` — *not* `slots` … The browse
> feed returns `capacity` per row so the terminal knows which items need it.

The browse feed does return it. The **catalog does not** — the live response
carries exactly twelve fields, and neither `capacity` nor `magazine_size` is
among them:

```
item_key  display_name  class  base_value  stackable  has_condition
max_stack  bulk  allowed_attachments  broker_basket  ammo_item_key  tradeable
```

Both are referenced by the rejection rules:

- *"`storage` omitted on an item with `capacity > 0`"*
- *"`amount` … above the weapon's `magazine_size`"*

So a client is told to obey two constraints whose values it cannot read. It
matters because the client should be refusing bad descriptors locally with a
message the player understands, not discovering them as a 422 mid-sale.

I work around it by classifying from the game's own `ItemData`, which carries
`capacity`, `magazineSize`, `type` and `subtype` — and which is where your
catalog came from, so it agrees by construction. That works for me because I
have the decompiled game. It would not work for anyone else building a client.

Both fields are already in `docs/catalog/catalog.json` if it is just a matter
of the importer dropping columns.

---

## 3. `API.md` examples a version behind — RESOLVED

> **Fixed.** Every example replaced with a real captured response.

The prose is correct and the implementation is correct; the **examples** still
show v1 shapes. `POST /v1/listings`:

```json
"descriptor": { "descriptor_version": 1, "item_key": "ak74m", "quantity": 1,
                "condition": 0.62,
                "attachments": [{ "item_key": "pso1_scope", "condition": 0.9 }] }
```

That is the exact shape the same document says is refused — `descriptor_version
1`, `quantity` rather than `amount`, condition as a 0–1 fraction, and
attachments as objects. `GET /v1/listings`, `GET /v1/listings/{id}` and
`GET /v1/items/{item_key}/stats` have the same problem, including a `durability`
field the contract says does not exist.

The live responses are right. I built against those rather than the examples,
but a client author who trusted the document would write a v1 client and get
422s naming fields they never sent.

---

## 4. Stale test key in the handoff notes — RESOLVED

> **Fixed.** `CLIENT-HANDOFF.md` now points at `.dev-keys.json` rather than
> inlining a key, and states that a stale key presents as "everything is
> broken" rather than as an auth error.

`rtv_tFRu_…eytY` returns `401 invalid player key` on every authenticated
endpoint. `/ping` and `/catalog` need no auth, which is what made it confusing:
the key *appeared* to work until the first real call.

The keys in `.dev-keys.json` on the box all work. Worth updating the note, and
worth knowing that a stale key presents as "everything is broken" rather than
as an auth error, because the two unauthenticated endpoints answer happily.

---

## 5. Small things

- **`intrinsic_value: null` on stackables** — handled, rendered as an absence.
  Your reasoning for withholding it is right; a number that might be 300× out
  is worse than no number.
- **`amount_means` is genuinely useful.** Three cases rather than two, stated
  per row, means the terminal never infers. More of this please.
- **`GET /v1/deliveries` returns `seconds_remaining` as well as `ready_at`.**
  The client counts down from `seconds_remaining` and re-anchors on each poll,
  so a countdown survives a session rather than drifting with the local clock.

---

## What the client does now

M2 is complete: browse with the market indicator, item detail with price
history and broker quotes, deliveries with live countdowns, wallet, and key
setup. It renders and computes nothing — `quote.total` is displayed as sent,
not recomputed, so retuning the economy stays a server config change.

Buying and selling are deliberately absent and their controls are disabled with
the reason stated. The next client milestone is M3, which is gated on §1 above.


---

## 6. Found while fixing the above

**The property test's own coverage assertion was flaky.** At the default 60
runs, `deliveriesAcked` landed anywhere in 16..33 against its own
`toBeGreaterThan(20)`, so the suite failed about half the time on a healthy
tree. Raised the default to 150 runs rather than lowering the threshold: the
threshold is the point, and a self-coverage check that flakes teaches you to
re-run until green, which is how a real regression gets waved through. Costs
about 20 seconds. Conservation itself never failed in any run.

**Available to the client now, not yet used.** With `capacity` and
`magazine_size` published, `ItemBridge` could cross-check the game's own
classification against the server's rather than relying on the decompiled
`ItemData` alone. A disagreement would mean a game patch moved something under
us — which is exactly what the escrow guard exists to catch. Worth doing before
M3 escrows anything real.
