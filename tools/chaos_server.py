"""Chaos mock of the flea market API (spec §10.2).

Every crash-recovery path in PendingLedger should be reachable locally, without
waiting for a real failure and without putting a real item at risk. Testing
those against the live VPS with a real rifle is how you eat a rifle.

Random 500s are the least useful part of this. The failures that actually occur
in a two-phase design are specific, and the server side named them:

  1. phase 2 lands but the RESPONSE is lost -> client retries the same op_id
     and must get the original result, not a second action
  2. client dies between destroy and phase 2, returns after the window ->
     `status: returned` / `credited`, both HTTP 200
  3. 409 idempotency_retry -- a concurrent duplicate is still resolving
  4. 429 mid-flow
  5. ACK lost after the goods were spawned -> the delivery is still pending at
     the next terminal open, and the client must not spawn it twice

Each is triggerable deliberately rather than hoped for.

Usage:
    python tools/chaos_server.py [--port 8788]

    # arm a failure for the next matching call
    curl -X POST localhost:8788/__chaos -d '{"next": "lose_response"}'
    curl -X POST localhost:8788/__chaos -d '{"next": "drop_request"}'
    curl -X POST localhost:8788/__chaos -d '{"next": "lapse_window"}'
    curl -X POST localhost:8788/__chaos -d '{"next": "idempotency_retry"}'
    curl -X POST localhost:8788/__chaos -d '{"next": "rate_limited"}'
    curl -X POST localhost:8788/__chaos -d '{"next": "server_error"}'
    curl -X POST localhost:8788/__chaos -d '{"next": "hang"}'

    # or a background failure rate, for soak runs
    curl -X POST localhost:8788/__chaos -d '{"failure_rate": 0.3}'

    curl localhost:8788/__state     # what the world looks like
    curl -X POST localhost:8788/__reset

Point the mod at it via FleaMarket.cfg:
    [api]
    base_url="http://127.0.0.1:8788/v1"

Plain HTTP is fine HERE and only here: it is loopback, it holds no real key,
and it never sees a real item. The production client must never fall back to
HTTP -- a player key would travel in the clear.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --- The failures worth simulating -------------------------------------------

LOSE_RESPONSE = "lose_response"      # action applied, reply never arrives
DROP_REQUEST = "drop_request"        # request never lands; nothing applied
LAPSE_WINDOW = "lapse_window"        # phase-1 window expired before phase 2
IDEMPOTENCY_RETRY = "idempotency_retry"
RATE_LIMITED = "rate_limited"
SERVER_ERROR = "server_error"
HANG = "hang"                        # no response at all, client must time out

CHAOS_MODES = {
    LOSE_RESPONSE, DROP_REQUEST, LAPSE_WINDOW, IDEMPOTENCY_RETRY,
    RATE_LIMITED, SERVER_ERROR, HANG,
}

REPO = Path(__file__).resolve().parent.parent


class World:
    """Mock market state. Deliberately simple; the failure shapes are the point."""

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.catalog = self._load_catalog()
        self.reset()

    def _load_catalog(self) -> dict:
        path = REPO / "docs" / "catalog" / "catalog.json"
        items = []
        if path.exists():
            raw = json.loads(path.read_text(encoding="utf-8"))
            for entry in raw.get("items", []):
                if entry.get("class") == "Furniture":
                    continue
                items.append({
                    "item_key": entry["item_key"],
                    "display_name": entry.get("display_name", entry["item_key"]),
                    "class": entry.get("class"),
                    "subclass": entry.get("subclass"),
                    "base_value": entry.get("value") or 1,
                    "stackable": bool(entry.get("stackable")),
                    "has_condition": bool(entry.get("has_condition")),
                    "max_stack": entry.get("max_stack") or 1,
                    "bulk": entry.get("bulk") or 1,
                    "allowed_attachments": entry.get("compatible", []),
                    "broker_basket": True,
                    "ammo_item_key": entry.get("ammo"),
                    "tradeable": True,
                    "magazine_size": entry.get("magazine_size"),
                    "capacity": entry.get("capacity") or 0,
                })
        return {
            "catalog_version": 2,
            "requested_game_version": None,
            "descriptor_version": 2,
            "condition_scale": {"min": 0, "max": 100},
            "items": items,
        }

    def reset(self) -> None:
        with self.lock:
            self.listings: dict[int, dict] = {}
            self.deliveries: dict[int, dict] = {}
            self.idempotency: dict[str, dict] = {}
            self.acked: set[int] = set()
            self.next_id = 1
            self.wallet = {"balance": 0, "queued_for_delivery": 0,
                           "callsign": "CHAOS-0001"}
            self.armed: str | None = None
            self.failure_rate = 0.0
            self.seed_listings()

    def seed_listings(self) -> None:
        for key, name, price, cond in [
            ("AK_12", "KA-12", 2400, 62),
            ("Mosin", "Mosin", 900, 41),
            ("SSh_39", "SSh-39", 217, 81),
        ]:
            lid = self.take_id()
            self.listings[lid] = {
                "listing_id": lid, "item_key": key, "display_name": name,
                "category": "Weapon", "condition": cond, "amount": 0,
                "amount_means": "not_applicable", "capacity": 0,
                "attachments": [], "state": "", "ask_price": price,
                "intrinsic_value": int(price * 0.9),
                "seller_callsign": "BROKER", "broker": True,
                "status": "active",
                "expires_at": iso(time.time() + 3600),
                "average_7d": None, "average_ratio_7d": None,
                "market_indicator": "unknown",
            }

    def take_id(self) -> int:
        with self.lock:
            v = self.next_id
            self.next_id += 1
            return v

    def take_chaos(self) -> str | None:
        """Consume an armed failure, or roll the background rate."""
        with self.lock:
            if self.armed:
                mode, self.armed = self.armed, None
                return mode
            if self.failure_rate > 0 and random.random() < self.failure_rate:
                return random.choice([SERVER_ERROR, RATE_LIMITED,
                                      LOSE_RESPONSE, IDEMPOTENCY_RETRY])
            return None


def iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + ".000Z"


WORLD = World()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("  %s" % (fmt % args))

    # --- plumbing ---

    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        if code == 429:
            self.send_header("X-Ratelimit-Reset", "2")
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return {}

    def _authed(self) -> bool:
        return bool(self.headers.get("Authorization", "").startswith("Bearer "))

    def _apply_chaos(self, phase2: bool) -> str | None:
        """Returns a mode the caller should honour, having already replied."""
        mode = WORLD.take_chaos()
        if mode is None:
            return None

        if mode == HANG:
            print("  [chaos] hanging, client must time out")
            time.sleep(120)
            return mode
        if mode == SERVER_ERROR:
            print("  [chaos] 500")
            self._send(500, {"error": "internal", "message": "chaos"})
            return mode
        if mode == RATE_LIMITED:
            print("  [chaos] 429")
            self._send(429, {"error": "rate_limited"})
            return mode
        if mode == IDEMPOTENCY_RETRY:
            print("  [chaos] 409 idempotency_retry")
            self._send(409, {"error": "idempotency_retry",
                             "message": "a duplicate is still resolving"})
            return mode
        if mode == DROP_REQUEST:
            # Distinct from LOSE_RESPONSE, and the distinction is the whole
            # point for an ACK. Here NOTHING is applied: the delivery stays
            # pending, so at the next terminal open the client sees goods it
            # has already spawned still listed as owed. The server cannot tell
            # that from a genuine re-request -- this is the one hazard the
            # design leaves on the client, and it must be guarded client-side.
            print("  [chaos] request dropped, nothing applied")
            try:
                self.close_connection = True
                self.wfile.close()
            except Exception:
                pass
            return mode
        # LOSE_RESPONSE and LAPSE_WINDOW are handled by the route: the action
        # must still be applied for the replay to return the original result.
        return mode

    # --- routing ---

    def do_GET(self) -> None:
        p = self.path.split("?")[0]

        if p == "/v1/ping":
            return self._send(200, {"ok": True, "service": "vostok-market-chaos",
                                    "api_version": "v1",
                                    "server_time": iso(time.time())})
        if p == "/__state":
            with WORLD.lock:
                return self._send(200, {
                    "listings": len(WORLD.listings),
                    "deliveries": len(WORLD.deliveries),
                    "acked": sorted(WORLD.acked),
                    "idempotency_keys": len(WORLD.idempotency),
                    "armed": WORLD.armed,
                    "failure_rate": WORLD.failure_rate,
                })
        if p == "/v1/catalog":
            return self._send(200, WORLD.catalog)

        if self._apply_chaos(False):
            return
        if not self._authed():
            return self._send(401, {"error": "unauthorized",
                                    "message": "invalid player key"})

        if p == "/v1/listings":
            with WORLD.lock:
                rows = [l for l in WORLD.listings.values() if l["status"] == "active"]
            return self._send(200, {"listings": rows, "next_cursor": None,
                                    "as_of": iso(time.time())})
        if p == "/v1/wallet":
            return self._send(200, WORLD.wallet)
        if p == "/v1/deliveries":
            with WORLD.lock:
                rows = [d for d in WORLD.deliveries.values()
                        if d["id"] not in WORLD.acked]
            for d in rows:
                d["seconds_remaining"] = max(0, int(d["_ready_at"] - time.time()))
                d["ready"] = d["seconds_remaining"] == 0
            return self._send(200, {"deliveries": rows})

        m = re.match(r"^/v1/listings/(\d+)$", p)
        if m:
            with WORLD.lock:
                listing = WORLD.listings.get(int(m.group(1)))
            if not listing:
                return self._send(404, {"error": "not_found"})
            return self._send(200, {
                "listing": {**listing, "item": {
                    "instance_id": listing["listing_id"], "descriptor_version": 2,
                    "item_key": listing["item_key"], "amount": listing["amount"],
                    "condition": listing["condition"], "attachments": [],
                    "mode": None, "zoom": None, "mount_position": None,
                    "chamber": None, "casing": None, "state": listing["state"],
                    "storage": [], "custom": {}, "origin": "player",
                    "intrinsic_value": listing["intrinsic_value"]}},
                "quote": {"price": listing["ask_price"], "delivery_fee": 0,
                          "total": listing["ask_price"], "seller_commission": 0,
                          "eta_seconds": 900,
                          "intrinsic_value": listing["intrinsic_value"]},
                "stats": {"item_key": listing["item_key"],
                          "display_name": listing["display_name"],
                          "base_value": listing["intrinsic_value"],
                          "recent_sales": [], "volume_24h": {"trades": 0, "value": 0},
                          "average_7d": None, "broker": None},
                "market_indicator": "unknown",
            })

        return self._send(404, {"error": "not_found", "message": p})

    def do_POST(self) -> None:
        p = self.path.split("?")[0]
        body = self._read_json()

        if p == "/__chaos":
            mode = body.get("next")
            with WORLD.lock:
                if mode in CHAOS_MODES:
                    WORLD.armed = mode
                elif mode is not None:
                    return self._send(400, {"error": "unknown_mode",
                                            "known": sorted(CHAOS_MODES)})
                if "failure_rate" in body:
                    WORLD.failure_rate = float(body["failure_rate"])
                return self._send(200, {"armed": WORLD.armed,
                                        "failure_rate": WORLD.failure_rate})
        if p == "/__reset":
            WORLD.reset()
            return self._send(200, {"ok": True})

        if not self._authed():
            return self._send(401, {"error": "unauthorized"})

        key = str(body.get("idempotency_key") or "")
        phase2 = "/confirm" in p or "/settle" in p or "/ack" in p
        mode = self._apply_chaos(phase2)
        if mode in (HANG, SERVER_ERROR, RATE_LIMITED, IDEMPOTENCY_RETRY, DROP_REQUEST):
            return

        # Replay: an operation already applied returns its ORIGINAL result. This
        # is what makes a lost response survivable, and it is the single most
        # important behaviour in this file.
        if key:
            with WORLD.lock:
                if key in WORLD.idempotency:
                    prior = WORLD.idempotency[key]
                    print(f"  [replay] {key[:8]} -> original result")
                    return self._send(prior["code"], prior["body"])

        code, result = self._route_post(p, body, mode)

        if key and code < 400:
            with WORLD.lock:
                WORLD.idempotency[key] = {"code": code, "body": result}

        if mode == LOSE_RESPONSE:
            # The action HAS been applied and recorded. Drop the connection so
            # the client never learns that, and must replay to find out.
            print("  [chaos] action applied, response dropped")
            try:
                self.close_connection = True
                self.wfile.close()
            except Exception:
                pass
            return

        self._send(code, result)

    def _route_post(self, p: str, body: dict, mode: str | None):
        # phase 1: records a descriptor, moves nothing
        if p == "/v1/listings":
            lid = WORLD.take_id()
            desc = body.get("descriptor", {})
            fee = max(500, int(body.get("ask_price", 0) * 0.03))
            with WORLD.lock:
                WORLD.listings[lid] = {
                    "listing_id": lid, "item_key": desc.get("item_key", "?"),
                    "display_name": desc.get("item_key", "?"), "category": "?",
                    "condition": desc.get("condition"), "amount": desc.get("amount", 0),
                    "amount_means": "not_applicable", "capacity": 0,
                    "attachments": desc.get("attachments", []),
                    "state": desc.get("state", ""),
                    "ask_price": body.get("ask_price", 0),
                    "intrinsic_value": body.get("ask_price", 0),
                    "seller_callsign": "CHAOS-0001", "broker": False,
                    "status": "pending", "expires_at": iso(time.time() + 3600),
                    "average_7d": None, "average_ratio_7d": None,
                    "market_indicator": "unknown",
                    "_fee": fee,
                }
            return 200, {
                "listing_id": lid, "item_instance_id": lid,
                "ask_price": body.get("ask_price", 0), "listing_fee": fee,
                "estimated_commission": int(body.get("ask_price", 0) * 0.06),
                "estimated_net_proceeds": int(body.get("ask_price", 0) * 0.94) - fee,
                "status": "pending", "pending_expires_at": iso(time.time() + 900),
                "destroy": {"item": True, "cash": fee},
            }

        # phase 2: MUST NOT refuse. Either it publishes or it hands the goods
        # back -- both HTTP 200, distinguished only by `status`.
        m = re.match(r"^/v1/listings/(\d+)/confirm$", p)
        if m:
            lid = int(m.group(1))
            with WORLD.lock:
                listing = WORLD.listings.get(lid)
                if not listing:
                    return 404, {"error": "not_found"}
                if mode == LAPSE_WINDOW:
                    did = WORLD.take_id()
                    WORLD.deliveries[did] = {
                        "id": did, "order_id": None, "kind": "item",
                        "cash_amount": None,
                        "item": {"instance_id": lid, "descriptor_version": 2,
                                 "item_key": listing["item_key"], "amount": 0,
                                 "condition": listing["condition"],
                                 "attachments": [], "mode": None, "zoom": None,
                                 "mount_position": None, "chamber": None,
                                 "casing": None, "state": "", "storage": [],
                                 "custom": {}, "origin": "player",
                                 "intrinsic_value": listing["intrinsic_value"]},
                        "reason": "pending_listing_lapsed",
                        "ready_at": iso(time.time()), "_ready_at": time.time(),
                        "ready": True, "seconds_remaining": 0,
                    }
                    listing["status"] = "returned"
                    print(f"  [chaos] confirm -> returned, delivery {did}")
                    return 200, {
                        "listing_id": lid, "status": "returned",
                        "expires_at": None, "listing_fee_charged": 0,
                        "returned_delivery_id": did,
                        "note": "phase-1 window had lapsed; goods returned and fee refunded",
                    }
                listing["status"] = "active"
            return 200, {"listing_id": lid, "status": "active",
                         "expires_at": iso(time.time() + 259200),
                         "listing_fee_charged": listing["_fee"]}

        m = re.match(r"^/v1/deliveries/(\d+)/ack$", p)
        if m:
            did = int(m.group(1))
            with WORLD.lock:
                if did not in WORLD.deliveries:
                    return 404, {"error": "not_found"}
                WORLD.acked.add(did)
            return 200, {"delivery_id": did, "status": "delivered"}

        return 404, {"error": "not_found", "message": p}

    def do_DELETE(self) -> None:
        m = re.match(r"^/v1/listings/(\d+)$", self.path.split("?")[0])
        if not m:
            return self._send(404, {"error": "not_found"})
        with WORLD.lock:
            listing = WORLD.listings.get(int(m.group(1)))
            if listing:
                listing["status"] = "cancelled"
        return self._send(200, {"listing_id": int(m.group(1)), "status": "cancelled"})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8788)
    args = ap.parse_args()

    print(f"Chaos market on http://127.0.0.1:{args.port}/v1")
    print(f"  catalog: {len(WORLD.catalog['items'])} items")
    print(f"  arm a failure: curl -X POST localhost:{args.port}/__chaos "
          "-d '{\"next\":\"lapse_window\"}'")
    print(f"  modes: {', '.join(sorted(CHAOS_MODES))}")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
