# Findings: the v1 descriptor cannot represent a Road to Vostok item

**For:** the server side
**From:** the client side, 2026-09-07
**Status:** blocking M3 (selling). Does not block M2 (read-only).

The spec's §5.1 descriptor was written on a machine without the game installed
(§14). Now that it has been checked against the real code, it is lossy in ways
that range from cosmetic to **outright property destruction**. This is the
"hardest client problem" the brief warns about, and it is a schema problem
rather than a serialisation problem — no amount of careful client code can
round-trip a field the wire format has nowhere to put.

Nothing here needs deciding today. It needs deciding before the first real
escrow.

---

## 1. What a game item actually is

Every item instance in the game is a `SlotData`
(`vostok-decompiled/Scripts/SlotData.gd`). The complete instance state:

| Field | Type | Meaning |
|---|---|---|
| `itemData` | `ItemData` | The item type. Its `.file` is the identity key |
| `nested` | `Array[ItemData]` | **Attachments.** Type references only — no per-attachment state |
| `storage` | `Array[SlotData]` | **Contents of a container item.** Recursive |
| `condition` | numeric **0–100** | Durability. Scales value directly |
| `amount` | int | Stack size, or rounds loaded in a weapon/magazine |
| `position` | float | Optic mount position — player-adjustable eye relief |
| `mode` | int | Fire selector: `1` = semi, `2` = auto |
| `zoom` | int | Optic magnification step, `1`–`3` |
| `chamber` | bool | A round is chambered |
| `casing` | bool | A spent casing is in the chamber |
| `state` | String | `""`, `"Jammed"`, or `"Frozen"` |

`SlotData.Update()` copies all eleven. That method is the game's own definition
of "the same item", and it is the bar a lossless round-trip has to clear.

## 2. What the v1 descriptor keeps

```json
{
  "descriptor_version": 1,
  "item_key": "ak74m",
  "quantity": 1,
  "condition": 0.62,
  "durability": 0.62,
  "attachments": [{ "item_key": "pso1_scope", "condition": 0.9 }],
  "custom": {}
}
```

It keeps `item_key`, `quantity` and `condition`. It silently drops `storage`,
`position`, `mode`, `zoom`, `chamber`, `casing` and `state`, and it invents two
fields the game does not have.

## 3. The defects, worst first

### 3.1 Selling a container destroys its contents — property loss

`storage` holds a container's contents as a nested `Array[SlotData]`, and it
travels with the item everywhere the game moves one
(`Interface.gd:541` — `newSlotData.storage = item.slotData.storage`).

A player lists a backpack with items inside. The descriptor records the
backpack alone. The client then destroys the backpack — **and everything in
it** — because destroying the item is destroying the `SlotData` that owns the
contents. The server's record cannot restore the contents on refund, because
the contents were never in the record.

This defeats the §4 guarantee directly. It is not a refund edge case; it
destroys property on the *happy* path, and the server would have no idea it
happened.

Two ways out, and this is the one decision I'd most like an answer on:

- **Represent `storage` in the descriptor**, recursively. Correct, and makes
  descriptors arbitrarily deep — the validator needs a depth and size cap.
- **Refuse to escrow a non-empty container**, client-side, with a clear
  message. Much simpler, costs players a little convenience, and closes the
  hole completely.

I lean to refusing non-empty containers for v1 and revisiting later. It is the
option that cannot silently lose anything.

### 3.2 `condition` is 0–100, not 0.0–1.0

Declared `@export var condition = 100`, and it scales value as
`value *= (slotData.condition * 0.01)` (`Scripts/Item.gd`). The spec's `0.62`
is a 0–1 fraction.

Left as-is, a 62%-condition rifle serialises as `62`, and a server reading it
as a fraction sees 6200% condition. That is a silent 100x pricing error, not a
validation failure — exactly the kind of thing that looks fine until money
moves.

Pick one scale and state it in the contract. I don't mind which; I do mind that
it is currently ambiguous.

### 3.3 `durability` does not exist

The spec carries both `condition` and `durability` with the same value. The
game has one field. Whatever the client puts in `durability` would be invented.
Drop the field.

### 3.4 Attachments have no condition

`nested` is `Array[ItemData]` — references to *shared* type resources, not
instances. An attachment has no per-instance state of any kind, so
`attachments[].condition` cannot be populated from anything real. The client
would have to fabricate `0.9`.

`Value()` confirms the game treats them as type-only: it adds `nested.value` at
face value with no condition scaling.

Attachments should be a plain list of `item_key`s.

### 3.5 Weapon state is lost

`mode`, `zoom`, `position`, `chamber`, `casing` and `state` all round-trip to
their defaults. Concretely, a player sells a rifle set to full-auto, with a 3x
optic at adjusted eye relief and a round chambered, and buys back a semi-auto
rifle at 1x, default mount position, empty chamber.

Individually small. Collectively this is precisely the "players get their rifle
back subtly different, and they will notice" failure the brief names.

`state` also has real value implications in both directions — a `"Jammed"` or
`"Frozen"` weapon that round-trips clean is a free repair, which is an
exploitable value gain, not just a cosmetic loss.

### 3.6 Loaded ammo is priced but not described

`Item.Value()` adds the value of loaded rounds (`amount`, plus one more if
`chamber`) and of every attachment. So two items with the same `item_key` and
the same `condition` can be worth very different amounts.

If the descriptor omits attachments' real list and the loaded round count, the
server is pricing a bare item while the player is trading a kitted one. That
undermines the price data M2 is meant to prove out, quite apart from the
correctness question.

---

## 4. What I suggest the descriptor becomes

`descriptor_version: 2`. Client-side names kept identical to the game's so the
mapping stays auditable:

```json
{
  "descriptor_version": 2,
  "catalog_version": 2,
  "item_key": "AK_12",
  "amount": 30,
  "condition": 62,
  "attachments": ["ACOG", "AK_12_Magazine"],
  "mode": 2,
  "zoom": 3,
  "mount_position": 0.02,
  "chamber": true,
  "casing": false,
  "state": "",
  "storage": []
}
```

- `condition` is **0–100**, matching the game.
- `attachments` is a flat list of `item_key`s, no condition.
- `amount` is rounds-loaded for weapons and magazines, stack size otherwise.
- `storage` is empty in v1 if we take the refuse-non-empty-containers route,
  and stays in the schema so it can be filled later without another version
  bump.

If a schema change is unwelcome, the alternative is to carry §3.5's six fields
inside the existing `custom {}` object. That works **only if `custom` is
preserved byte-for-byte and returned verbatim on delivery.** If `custom` is
normalised, reordered, or dropped by the validator, it is not a safe home for
state that has to come back exactly as it went in — please confirm either way.

Either route, §3.1 (container contents) and §3.2 (condition scale) need
answering regardless, because both are live property/pricing bugs rather than
fidelity nits.

---

## 5. Also worth knowing

**The real catalog is extracted** — 291 items, in `docs/catalog/catalog.json`
and `.csv`, generated by `tools/extract_catalog.py` straight from the
decompiled `.tres` files. It carries `item_key`, display name, class/subclass,
stackable, max stack, has_condition, weight, grid footprint, a derived `bulk`
scalar, the game's own `value`, and per-weapon `allowed_attachments` resolved
from each weapon's `compatible` array.

Two data-quality notes from the game's own files, left unnormalised rather than
silently cleaned:

- `class` values include both `"Consumable"` and `"Consumables"`, and one item
  has a leading space: `" Misc"`. If `class` drives the browse filter, these
  want normalising server-side, deliberately.
- 42 of the 291 are `"Furniture"` (shelter decoration). Probably not tradeable
  — your call, flagged rather than filtered.

**`item_key` is `ItemData.file`, not the display name.** These differ, and
often deliberately: the AK-12 has `file = "AK_12"` and `display = "KA-12"`.
Keying on the display name would be wrong. The modding guide is explicit that
`resource_path` is empty at runtime and `file` is the identity field the game
itself uses.

**Cash denominations — your blocking question (4a) is answered: there are
none.** The physical-money mod creates a single stackable item with
`value = 1`, `stackable = true`, `maxAmount = 99999`. Cash is divisible to the
rouble, so `POST /orders` returning an exact integer `total` works as
specified. No rounding, no denomination table, no `destroy` object needed.

The only physicality constraint is the 99,999 stack cap: a 2,000,000 payout is
21 stacks, and the courier crate needs the slots for it. That is a client-side
concern, not a server one.
