extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## The two-phase buy, and its crash recovery.
##
## The mirror of SellFlow, and the ordering discipline is identical because the
## reasoning is (§4, §13):
##
##     verify the cash is physically in inventory   BEFORE reserving anything
##     POST /orders                     phase 1: reserves the listing, takes
##                                      no cash
##     ledger.advance(LOCAL_COMMITTED)  FLUSHED TO DISK before anything is
##                                      destroyed
##     destroy the cash
##     POST /orders/{id}/settle         phase 2
##
## ## Phase 2 does not fail
##
## By the time settle is called the cash is gone, so the server cannot refuse
## on business grounds. It answers HTTP 200 either way and `status` says which:
##
##     settled   bought it, goods scheduled for the crate
##     credited  the reservation LAPSED. The player did NOT get the item, and
##               their money is coming back as physical cash.
##
## Rendering "Purchased!" on a `credited` tells the player they own something
## they do not. The status is checked, never assumed.
##
## ## Why the cash check comes first
##
## §13 step 2 is explicit: verify the physical cash is in inventory before
## reserving. Reserving first would hold a listing out of the market on behalf
## of someone who cannot pay for it, and would put the player one click from
## destroying cash they turn out not to have enough of.

const PendingLedger := preload("res://mods/FleaMarket/PendingLedger.gd")
const Stash := preload("res://mods/FleaMarket/Stash.gd")

const LOG_PREFIX := "[FleaMarket/buy] "

## Outcomes, for the caller to render. Never inferred from an HTTP code.
const OUTCOME_BOUGHT := "bought"
const OUTCOME_CREDITED := "credited"
const OUTCOME_REFUSED := "refused"          # nothing was destroyed
const OUTCOME_INTERRUPTED := "interrupted"  # cash gone, phase 2 unresolved


## Reserve a listing and quote the all-in total.
##
## Takes no cash. The reservation lapses on its own if the player walks away,
## and the listing returns to the market.
static func reserve(client: Node, ledger: RefCounted, listing_id: int,
		expected_total: int) -> Dictionary:
	# §13 step 2. Checked before the call, so a player who cannot pay never
	# holds a listing out of the market.
	var on_hand := Stash.cash_on_hand()
	if expected_total > 0 and on_hand < expected_total:
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": ("You are carrying %d. This costs %d. "
				+ "Bring the cash to the terminal.") % [on_hand, expected_total]}

	var op_id: String = client.new_idempotency_key()
	ledger.begin(op_id, PendingLedger.KIND_ORDER, {"listing_id": listing_id})

	var res: Dictionary = await client.post_json("/orders", {
		"listing_id": listing_id,
	}, op_id)

	if not res["ok"]:
		# Nothing destroyed. Drop the entry; the server's reservation, if it
		# made one, lapses by itself and the listing goes back on the market.
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": str(res.get("message", "The market refused this purchase.")),
			"error": str(res.get("error", ""))}

	var body = res["json"]
	if not body is Dictionary:
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "The market sent a reply this terminal could not read."}

	var total := int(body.get("total", 0))

	# Re-check against the price the server actually quoted, not the one the
	# browse feed showed. They can differ -- a delivery fee is added at
	# reservation -- and discovering that after destroying the cash is the
	# failure this check exists to prevent.
	if Stash.cash_on_hand() < total:
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": ("The all-in price is %d, and you are carrying %d. "
				+ "Nothing was taken.") % [total, Stash.cash_on_hand()]}

	# The settle key is minted NOW and stored, not at settle time. Recovery has
	# to replay settle with the same value, and a key generated per attempt
	# would pay twice.
	var settle_key: String = client.new_idempotency_key()
	ledger.advance(op_id, PendingLedger.RESERVED, {
		"order_id": int(body.get("order_id", 0)),
		"listing_id": listing_id,
		"total": total,
		"settle_key": settle_key,
		"destroyed": false,
	})

	return {
		"ok": true,
		"op_id": op_id,
		"order_id": int(body.get("order_id", 0)),
		"price": int(body.get("price", 0)),
		"fee": int(body.get("fee", 0)),
		"total": total,
		"eta_seconds": int(body.get("eta_seconds", 0)),
		"reserved_until": str(body.get("reserved_until", "")),
		"seller_callsign": str(body.get("seller_callsign", "")),
	}


## Commit a reserved order: destroy the cash, then settle.
static func commit(client: Node, ledger: RefCounted, op_id: String) -> Dictionary:
	var entry: Dictionary = ledger.get_entry(op_id)
	if entry.is_empty():
		# No record means no safety net. Destroying cash for an operation the
		# ledger has never heard of is unrecoverable.
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "This purchase is no longer on record. Nothing was taken."}

	var payload: Dictionary = entry["payload"]
	var total := int(payload.get("total", 0))

	if Stash.cash_on_hand() < total:
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "You are no longer carrying enough cash. Nothing was taken."}

	# THE ORDERING RULE. This write reaches disk before anything is destroyed;
	# if it fails, nothing is destroyed at all.
	if not ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED):
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "Could not record this purchase, so nothing was taken."}

	if total > 0 and not Stash.take_cash(total):
		# The cash is still there and the entry is unresolved. Recovery will
		# find it and pick up where this stopped.
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "Could not take the cash from your inventory."}

	ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})
	return await _settle(client, ledger, op_id)


## Replay every unfinished purchase. Called on load and on terminal open.
static func recover(client: Node, ledger: RefCounted) -> Array:
	var results := []
	for entry in ledger.outstanding():
		if str(entry.get("kind", "")) != PendingLedger.KIND_ORDER:
			continue
		if ledger.is_stalled(entry):
			continue

		var op_id := str(entry["op_id"])
		match str(entry.get("phase", "")):
			PendingLedger.RESERVED:
				# Reserved but no cash destroyed. Abandoning is free: the
				# reservation lapses and the listing returns to the market.
				_log("abandoning un-committed order %s (no cash was taken)" % op_id)
				ledger.complete(op_id)

			PendingLedger.LOCAL_COMMITTED:
				results.append(await _recover_committed(client, ledger, entry))

			PendingLedger.CONFIRMED:
				ledger.complete(op_id)
	return results


# --- Internals ---

static func _recover_committed(client: Node, ledger: RefCounted,
		entry: Dictionary) -> Dictionary:
	var op_id := str(entry["op_id"])
	var payload: Dictionary = entry["payload"]

	# The mirror of SellFlow's duplication window. The ledger is written before
	# the cash is destroyed, so a crash in between leaves the cash still in the
	# player's pocket. Settling without checking would buy an item the player
	# never paid for.
	#
	# Cash is fungible, so there is no descriptor to match -- the flag is the
	# only record of whether the take happened. If it says no, take it now
	# before settling.
	if not bool(payload.get("destroyed", false)):
		var total := int(payload.get("total", 0))
		if total > 0:
			if Stash.cash_on_hand() >= total:
				_log("recovery: cash was never taken, completing that first")
				if not Stash.take_cash(total):
					ledger.note_error(op_id, "recovery could not take the cash")
					return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
						"message": "Could not finish an interrupted purchase."}
			else:
				# Cannot tell whether it was taken or spent elsewhere. Settle
				# anyway: the server holds the reservation, and the worst case
				# is a credit note refunding money that was never taken --
				# which the ledger records for a human to look at.
				ledger.note_error(op_id,
					"not enough cash on hand at recovery; settling on the server's record")
		ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})

	_log("replaying settle for %s" % op_id)
	return await _settle(client, ledger, op_id)


## Phase 2, and the status handling that goes with it.
static func _settle(client: Node, ledger: RefCounted, op_id: String) -> Dictionary:
	var entry: Dictionary = ledger.get_entry(op_id)
	if entry.is_empty():
		return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
			"message": "This purchase is no longer on record."}

	var payload: Dictionary = entry["payload"]
	var order_id := int(payload.get("order_id", 0))
	var settle_key := str(payload.get("settle_key", ""))
	if settle_key == "":
		settle_key = client.new_idempotency_key()
		ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"settle_key": settle_key})
		ledger.note_error(op_id, "settle key was missing and had to be minted")

	var res: Dictionary = await client.post_json(
		"/orders/%d/settle" % order_id, {}, settle_key)

	if not res["ok"]:
		# The cash is gone and the market has not answered. The entry stays and
		# the next terminal open replays it. Not a loss: the server either has
		# the order or will refund from its own record.
		ledger.note_error(op_id, str(res.get("message", res.get("error", "unknown"))))
		return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
			"message": ("The market did not answer. Your money is safe -- this "
				+ "will finish next time the terminal is opened."),
			"op_id": op_id}

	var body = res["json"]
	var status := ""
	if body is Dictionary:
		status = str(body.get("status", ""))

	ledger.advance(op_id, PendingLedger.CONFIRMED, {"status": status})
	ledger.complete(op_id)

	# HTTP 200 does NOT mean the item was bought. Check the field.
	if status == "credited":
		var amount := 0
		if body is Dictionary and body.get("credit_note") is Dictionary:
			amount = int(body["credit_note"].get("amount", 0))
		return {"ok": true, "outcome": OUTCOME_CREDITED,
			"message": ("The reservation lapsed before payment went through, so "
				+ "you did NOT get the item. Your money is coming back as cash "
				+ "in the courier crate."),
			"amount": amount,
			"delivery_id": int(body.get("delivery_id", 0)) if body is Dictionary else 0}

	return {"ok": true, "outcome": OUTCOME_BOUGHT,
		"order_id": order_id,
		"message": "Bought. It is on its way to your courier crate.",
		"delivery_id": int(body.get("delivery_id", 0)) if body is Dictionary else 0}


static func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
