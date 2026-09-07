# Milestone 0 — network spike results

**Date:** 2026-09-07
**Build:** Road to Vostok, Godot **4.6.2-stable (official)**, exported release
build (`RTV.exe`), Windows
**Loader:** Metro Mod Loader 3.2.1, spike mounted at `priority=100`
**Method:** `spike/mods/FleaSpike/Main.gd`, a throwaway autoload that probes
each capability and writes `user://FleaSpike_Report.json`. Raw output in
[`spike-results/`](spike-results/).

## Verdict

**The spike passed. `HTTPRequest` over HTTPS works from inside a mod in an
exported build.** The single unproven assumption the whole project was gated on
is retired, the transport design in the spec stands, and the store-and-forward
companion fallback (§3.2) is not needed.

Confirmed two ways: the JSON report below, and the spike's own panel rendering
`HTTPS OK · ping 200` on screen in the running game — observed directly by the
developer.

One item is **not** proven and is now the blocker: the test player key is
rejected. See §3.

---

## 1. The §3.1 capability table, as observed

| Capability | Status going in | Observed | Evidence |
|---|---|---|---|
| Own GDScript executes in a mod | Assumed, unconfirmed | **PASS** | The spike is an autoload; its `_ready()` ran and logged. Independently, all eight existing mods are GDScript autoloads — see §2 |
| `HTTPRequest` works | **Unproven — the risk** | **PASS** | `GET /v1/ping` → `result=0` (`RESULT_SUCCESS`), `code=200`, **259 ms** |
| HTTPS/TLS works in the exported build | Unknown | **PASS** | Scheme was `https://`. TLS handshake succeeded; response carried `Via: 1.1 Caddy` |
| Add a new interactable scene to the safehouse | Confirmed possible | **PASS** | Closed in M2. The terminal is registered furniture: granted to the build catalog, placed by the player in decor mode, and interacted with in-game — confirmed on screen |
| Draw custom UI | Assumed | **PASS** | `PanelContainer` + `Label` parented to `/root` and confirmed in-tree. Also **visually confirmed in-game** — the panel renders on screen reading `HTTPS OK · ping 200` |
| Write custom keys into the game save | Confirmed possible | **PASS** | `ConfigFile` round-trip: nested dict, float `0.6234`, UTF-8 string, all read back identical |
| Survives game patches | Low breakage historically | Unchanged | Not testable in one session |

Extra rows the spike added, because the spec's table did not cover them and the
client depends on all four:

| Capability | Observed | Evidence |
|---|---|---|
| Running in an **exported** build, not the editor | **PASS** | `has_feature("editor")=false`, `has_feature("template")=true`, `debug_build=false`, exe `RTV.exe` |
| `POST` with a JSON body reaches the server | **PASS** | `POST /v1/listings` → structured JSON error, so request line, headers and body were all transmitted |
| Bearer auth accepted | **FAIL — see §3** | The documented test key is rejected on every authenticated endpoint |
| `RTVModLib` hook + registry API present | **PASS** | `hook`, `register`, `patch`, `skip_super`, `frameworks_ready` all present |
| Physical-money mod reachable read-only | **PASS** | `Engine.get_meta("CashMain")` present with `CountCash` / `AddCash` / `RemoveCash` and three signals |

### Why the transport was always likely to work

Worth recording, because it retires the risk independently of my one probe: the
**mod loader itself makes `HTTPRequest` calls over HTTPS from this same shipped
build.** Its Browse tab and update checks hit
`https://api.modworkshop.net` (`src/mws_api.gd`, `src/constants.gd`). Its
security scanner also has no network-related patterns and, by its own
documentation, *"Loading is never blocked."*

So in-mod HTTPS is load-bearing for a component thousands of players already
run. My ping is confirmation, not discovery.

---

## 2. Are the existing mods script-level or asset-level?

**Script-level, unambiguously.** Every one of the eight is a GDScript autoload
declared in `mod.txt`:

| Mod | Autoload | Pattern |
|---|---|---|
| Cash System | `CashMain` | Autoload + `RTVModLib` replace-hooks on `interface-drop` / `interface-contextplace` |
| XP & Skills | `XPMain` | Autoload; migrated from `take_over_path` script overrides to hooks in 3.0 |
| Quick Stack & Sort | `QuickStackMain` | Autoload, UI injection |
| Secure Container | `SecureContainer` + `SecureContainerConfig` | Autoload + registry |
| Run Summary | `RunSummaryMain` | Autoload |
| Vostok AI | `VostokAIMain` | Autoload |
| Echoes of Vostok | `EchoesMain` | Autoload, 5 scripts |
| DomFrags Overhaul | 4 autoloads | Bundle of the above |

Several also ship assets (meshes, icons, audio), but the mechanism is your own
code executing, not asset replacement. Nothing in the client design depends on
a capability these mods don't already demonstrate.

---

## 3. Blocker: the test player key is rejected

`rtv_tFRu_…eytY` from the server handoff notes returns
`401 {"error":"unauthorized","message":"invalid player key"}` on **every**
authenticated endpoint:

| Call | Result |
|---|---|
| `GET /v1/ping` | 200 — **no auth required** |
| `GET /v1/catalog` | 200 with the key, **and 200 with no key at all** — no auth required |
| `GET /v1/wallet` | **401** invalid player key |
| `GET /v1/listings` | **401** |
| `POST /v1/listings` | **401** |

This is why the spike's own `bearer_auth_headers_work` row initially read PASS:
it inferred success from `GET /catalog` returning 200, but that endpoint is
unauthenticated, so the 200 said nothing about the key. Corrected to FAIL
above. The probe was wrong, not the server.

The header transport itself is fine — the request reached the application and
came back with a structured JSON error rather than a proxy rejection.

**What I need:** a working player key, or confirmation that keys must be
provisioned per player and the documented one has expired. Everything in M2
past the catalog needs it: `GET /listings` is the read-only client's entire
reason for existing, and it is 401 right now.

---

## 4. Placing the terminal and the crate

**Resolved in M2 (2026-09-07).** The terminal is registered furniture. It is
granted to the player's build catalog, positioned by the player in decor mode,
and persists through the game's own `ShelterSave`. Interacting with a placed
terminal reaches the mod and renders live server data — confirmed in-game.

The first attempt placed it at fixed Bunker coordinates, which put it outside
the building in the Cabin. Furniture placement removes the whole class of bug:
there is no coordinate to be wrong about, and it works in every shelter.

`FurnitureSave` persists `container` and `storage`, so the courier crate gets
its persistence from the same mechanism for free.

The original finding, that the registry exposes the needed buckets:

```
ITEMS  LOOT  SCENES  SCENE_PATHS  SCENE_NODES  SHELTERS  MAPS  INPUTS  RESOURCES
```

`SCENE_NODES` (property injection into vanilla scenes) and the
`register_furniture` aggregator are the likely route for both objects. The
safehouse is `Scenes/Bunker.tscn` — `mapType = "Shelter"`,
`shelterLocation = "Outpost"` — with content in `Assets/Bunker/Bunker.tscn`.
Shelter state persists through `ShelterSave` (`furnitures`, `items`,
`switches`).

I'd rather prove this with a placeholder object as the first task of M2 than
assume it now.

---

## 5. Does the safehouse have a power system? No — drop the §8.2 gate

There is no power system to gate the terminal on.

- `ItemData.Power` is an enum `{None, Low, Medium, High}` used only for
  flashlight and NVG brightness (`Flashlight.gd`, `NVG.gd`).
- The shelter has `Switch` nodes whose state persists via `SwitchSave`, but
  `Switch.Interact()` just flips `active` and calls `Activate()` /
  `Deactivate()` on target nodes. Lights on, lights off.
- There is no generator, fuel, battery, fuse or grid anywhere in the 176 game
  scripts. Nothing is scarce, so there is nothing meaningful to gate on.

**Recommendation: drop the requirement**, as the spec instructs when the
feature is absent. If you want the flavour, the terminal can be registered as
a `Switch` target so it visibly powers up with the shelter lights — but that is
decoration, not a constraint, and it would be dishonest to describe it as a
power gate.

---

## 6. Unknowns resolved

Running list, per the brief's request.

| Spec item | Resolution |
|---|---|
| §3.1 `HTTPRequest` works | **Yes.** 200 in 259 ms from the exported build |
| §3.1 HTTPS in exported build | **Yes.** TLS via Caddy |
| §3.1 mods script-level or asset-level | **Script-level** — eight GDScript autoloads |
| §3.1 custom save keys | **Yes**, via `ConfigFile` in `user://`, which is `%APPDATA%\Road to Vostok\` |
| §3.2 fallback companion needed | **No.** In-mod HTTP works |
| §8.2 power gate *(if supported)* | **Not supported.** Drop it |
| Server 4a: cash denominations | **None.** One stackable item, `value = 1` — see §7 |
| Server 4b: the real item table | **Delivered.** 291 items, `docs/catalog/` |
| Descriptor fidelity | **Broken as specced** — see [`FINDINGS-ITEMBRIDGE.md`](FINDINGS-ITEMBRIDGE.md) |
| Test player key | **Invalid** — see §3. Open |

---

## 7. Physical cash, as the game actually implements it

Answering the server's blocking question 4a with observed values rather than
inference. Read live off `CashMain.cash_item_data`:

| Field | Value |
|---|---|
| `file` (**item_key**) | `Cash` |
| `name` | `Vostok Dollars` |
| `value` | **1** |
| `stackable` | `true` |
| `maxAmount` | **99999** |
| `defaultAmount` | 1000 |
| `weight` | **0.0** |
| `size` | 1 × 1 |

**There are no denominations.** Cash is a single stackable item worth exactly 1,
so it is divisible to the rouble and `POST /orders` returning an exact integer
`total` works precisely as specified. No rounding-up, no denomination config
table, no `destroy` object needed.

Two corrections to the spec's economic assumptions, both worth knowing before
tuning fees:

- **Cash is weightless** (`weight = 0.0`). §7.1's "bulk is a real constraint on
  large purchases" is only true in *grid slots*, not weight. A 2,000,000
  payment is 21 stacks occupying 21 inventory cells and zero kilograms.
- The 99,999 stack cap is the only real limit, and it lands on the **courier
  crate's** slot count when large proceeds are delivered. That is a client
  problem, not a server one, but it constrains how large a single sale can
  usefully be.

The mod also exposes `CountCash()`, `AddCash(amount)` and `RemoveCash(amount)`
plus `cash_sold` / `cash_bought` / `cash_dropped` / `cash_picked_up` signals via
`Engine.get_meta("CashMain")`. The market can therefore verify and destroy cash
through that public API **without modifying the physical-money mod at all**,
which is what the brief asked for.

---

## 8. Save-profile scoping — a client hazard the spec doesn't mention

`PendingLedger` must be **scoped per save profile**, not stored once globally.

The user runs Patty's Profiles, and `user://` shows per-profile files from
other mods that already learned this:

```
XPData_profile_02.cfg   RunSummaryHistory_profile_01.cfg
XPData_profile_03.cfg   SecureContainer_session_profile_03.json
profiles/active_profile.cfg   ->   active="profile_03"
```

Secure Container shipped a 2.0.2 fix for exactly this class of bug: one shared
file meant a container could open showing another save's items.

A globally-scoped `PendingLedger` would be worse than that. A pending escrow
written on profile 3 would replay on profile 1's load and re-send a phase-2
call for an item that save never had — destroying items or spawning goods in
the wrong world. The ledger will be keyed
`FleaPending_<active_profile>.cfg`, read from `profiles/active_profile.cfg`.

---

## 9. Corrections to my own probe

Recorded so the raw JSON isn't trusted further than it deserves:

1. **`bearer_auth_headers_work` reported PASS and is actually FAIL.** It
   inferred auth from an unauthenticated endpoint. §3 has the real picture.
2. **`post_with_json_body_works` PASS is narrower than it sounds.** It proves a
   POST with a JSON body reaches the application and returns a parseable
   response. It does not prove the descriptor validator was reached — the call
   died at auth, before validation. The server's "phase 1 is a free
   `ItemBridge` validator" trick is therefore still untested, and it is the
   thing I most want to start using.

---

## 10. What happens next

1. **Blocked on you / the server side:** a working player key (§3), and a
   decision on the descriptor schema
   ([`FINDINGS-ITEMBRIDGE.md`](FINDINGS-ITEMBRIDGE.md)).
2. **M2, read-only client.** Not blocked on the descriptor — browse and price
   data need no descriptors at all — but blocked on the key past `/catalog`.
   First task will be placing a placeholder interactable in the shelter to
   close out the one untested §3.1 row.
3. The spike stays in the repo under `spike/` as evidence. It is not production
   code and nothing will be built on top of it.
