extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## The two-phase sell, and its crash recovery.
##
## This is the file that destroys real property, so the ordering rules from §4
## and §13 are the structure rather than a comment on it:
##
##     POST /listings                      phase 1: the server records the
##                                         descriptor and escrows NOTHING. The
##                                         item is still in the player's hands.
##     ledger.advance(LOCAL_COMMITTED)     FLUSHED TO DISK before anything is
##                                         destroyed. This is the only window
##                                         in the design where property can
##                                         actually be lost, and it is entirely
##                                         client-side.
##     destroy the item, then the fee cash
##     POST /listings/{id}/confirm         phase 2
##
## ## Phase 2 does not fail
##
## By the time confirm is called the goods are gone, so the server is forbidden
## from refusing on business grounds. It answers HTTP 200 either way and the
## `status` field says which happened:
##
##     active    published, fee charged
##     returned  the phase-1 window lapsed. NO listing exists. The item is
##               coming back to the crate and the fee was refunded.
##
## Rendering "Listed!" on a `returned` tells the player they own something they
## do not, and they will report it as the market eating their rifle. The status
## is checked, never assumed.
##
## ## The duplication window, and how recovery closes it
##
## Writing the ledger before destroying is what stops an item being lost. It
## creates the opposite risk: crash after the write but before the destroy, and
## a naive recovery would confirm a listing for an item the player still holds.
## So recovery does not assume — it looks in the inventory, and finishes the
## destroy if it finds the item still there.

const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")
const PendingLedger := preload("res://mods/FleaMarket/PendingLedger.gd")
const Stash := preload("res://mods/FleaMarket/Stash.gd")

const LOG_PREFIX := "[FleaMarket/sell] "

## Outcomes, for the caller to render. Never inferred from an HTTP code.
const OUTCOME_LISTED := "listed"
const OUTCOME_SOLD := "sold"            # sold outright to the broker
const OUTCOME_RETURNED := "returned"
const OUTCOME_REFUSED := "refused"      # nothing was destroyed
const OUTCOME_INTERRUPTED := "interrupted"  # destroyed, phase 2 unresolved


## Quote a sale without committing to it (§8.1 screen 3).
##
## Phase 1 escrows nothing, so this is safe to call to show the player their
## fee, commission and net proceeds BEFORE they commit. Nobody should discover
## a fee after the fact.
##
## The quote is left un-confirmed if the player backs out; the server's phase-1
## window lapses on its own and nothing was ever taken.
static func quote(client: Node, ledger: RefCounted, slot: SlotData,
		ask_price: int, catalog_version: int) -> Dictionary:
	var refusal: String = ItemBridge.rejection_reason(slot)
	if refusal != "":
		return {"ok": false, "outcome": OUTCOME_REFUSED, "message": refusal}

	var op_id: String = client.new_idempotency_key()
	var descriptor: Dictionary = ItemBridge.to_descriptor(slot)

	# Recorded BEFORE the call, not after. If the response is lost the entry is
	# already on disk, and recovery can ask the server what became of it.
	ledger.begin(op_id, PendingLedger.KIND_LISTING, {
		"descriptor": descriptor,
		"ask_price": ask_price,
	})

	var res: Dictionary = await client.post_json("/listings", {
		"descriptor": descriptor,
		"ask_price": ask_price,
		"catalog_version": catalog_version,
	}, op_id)

	if not res["ok"]:
		# Nothing was destroyed, so this is a clean refusal. Drop the entry:
		# the server's phase-1 record, if it made one, lapses by itself.
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": str(res.get("message", "The market refused this listing.")),
			"error": str(res.get("error", ""))}

	var body = res["json"]
	if not body is Dictionary:
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "The market sent a reply this terminal could not read."}

	# The confirm key is minted NOW and stored, not at confirm time. Recovery
	# has to replay confirm with the same value, and a key generated per attempt
	# would settle twice.
	var confirm_key: String = client.new_idempotency_key()
	ledger.advance(op_id, PendingLedger.RESERVED, {
		"listing_id": int(body.get("listing_id", 0)),
		"listing_fee": int(body.get("listing_fee", 0)),
		"confirm_key": confirm_key,
		"destroyed": false,
	})

	return {
		"ok": true,
		"op_id": op_id,
		"listing_id": int(body.get("listing_id", 0)),
		"ask_price": int(body.get("ask_price", ask_price)),
		"listing_fee": int(body.get("listing_fee", 0)),
		"estimated_commission": int(body.get("estimated_commission", 0)),
		"estimated_net_proceeds": int(body.get("estimated_net_proceeds", 0)),
		"pending_expires_at": str(body.get("pending_expires_at", "")),
		"destroy": body.get("destroy", {}),
	}


## Commit a quoted sale: destroy the goods, then publish.
##
## `element` is the inventory node holding the item. It is passed in rather than
## looked up so the player commits the exact item they were shown.
static func commit(tree: SceneTree, client: Node, ledger: RefCounted,
		op_id: String, element: Node) -> Dictionary:
	var entry: Dictionary = ledger.get_entry(op_id)
	if entry.is_empty():
		# No record means no safety net. Refusing here is the whole point of
		# the class: destroying goods for an operation the ledger has never
		# heard of is unrecoverable.
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "This sale is no longer on record. Nothing was destroyed."}

	var payload: Dictionary = entry["payload"]
	var fee := int(payload.get("listing_fee", 0))

	# Check the fee is payable BEFORE destroying the item. Destroying the rifle
	# and then discovering the player cannot pay the fee would be the worst
	# possible ordering.
	if fee > 0 and Stash.cash_on_hand() < fee:
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "You need %d in cash on you to pay the listing fee." % fee}

	# THE ORDERING RULE. This write reaches disk before anything is destroyed;
	# if it fails, nothing is destroyed at all.
	if not ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED):
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "Could not record this sale, so nothing was destroyed."}

	if not Stash.destroy(tree, element):
		# The item is still there and the ledger entry is unresolved. Leave it:
		# recovery will find the item still present and pick up where this
		# stopped.
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "Could not take the item from your inventory."}

	if fee > 0 and not Stash.take_cash(fee):
		# The item is gone and the fee is not paid. Do NOT stop: the server
		# charges the fee itself at confirm, and abandoning here would strand
		# the item. Recorded so the discrepancy is visible.
		ledger.note_error(op_id, "fee cash could not be taken locally")

	ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})

	return await _confirm(client, ledger, op_id)


## Replay every unfinished operation. Called on load and on terminal open.
##
## This is the whole of §5.1's recovery: for each entry that is not done,
## re-send the call for its phase using the ORIGINAL op_id.
static func recover(tree: SceneTree, client: Node, ledger: RefCounted) -> Array:
	var results := []
	for entry in ledger.outstanding():
		var kind := str(entry.get("kind", ""))
		if kind != PendingLedger.KIND_LISTING and kind != PendingLedger.KIND_BROKER_SELL:
			continue
		if ledger.is_stalled(entry):
			# Retried too often. Kept, never dropped -- an operation that cannot
			# be resolved is exactly the one worth keeping a record of.
			continue

		var op_id := str(entry["op_id"])
		var phase := str(entry.get("phase", ""))

		match phase:
			PendingLedger.RESERVED:
				# Phase 1 returned but nothing was destroyed: the item is still
				# in the player's inventory. Abandoning is free, because the
				# server's phase-1 window lapses on its own and it escrowed
				# nothing.
				_log("abandoning un-committed listing %s (nothing was destroyed)" % op_id)
				ledger.complete(op_id)

			PendingLedger.LOCAL_COMMITTED:
				results.append(await _recover_committed(tree, client, ledger, entry, kind))

			PendingLedger.CONFIRMED:
				# The server has already told us what happened; only local
				# bookkeeping was outstanding.
				ledger.complete(op_id)
	return results


# --- Internals ---

static func _recover_committed(tree: SceneTree, client: Node, ledger: RefCounted,
		entry: Dictionary, kind: String = PendingLedger.KIND_LISTING) -> Dictionary:
	var op_id := str(entry["op_id"])
	var payload: Dictionary = entry["payload"]

	# Close the duplication window. The ledger was written before the destroy,
	# so a crash in between leaves the item still in the inventory. Confirming
	# without checking would publish a listing for an item the player still
	# holds -- the exact duplication the write-first rule risks. So look, and
	# finish the destroy if it never happened.
	if not bool(payload.get("destroyed", false)):
		var descriptor = payload.get("descriptor", {})
		if descriptor is Dictionary:
			var element := Stash.find_matching(tree, descriptor)
			if element != null:
				_log("recovery: item was never destroyed, completing that first")
				if not Stash.destroy(tree, element):
					ledger.note_error(op_id, "recovery could not destroy the item")
					return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
						"message": "Could not finish an interrupted sale."}
		ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})

	_log("replaying confirm for %s" % op_id)
	if kind == PendingLedger.KIND_BROKER_SELL:
		return await _broker_confirm(client, ledger, op_id)
	return await _confirm(client, ledger, op_id)


## Phase 2, and the status handling that goes with it.
static func _confirm(client: Node, ledger: RefCounted, op_id: String) -> Dictionary:
	var entry: Dictionary = ledger.get_entry(op_id)
	if entry.is_empty():
		return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
			"message": "This sale is no longer on record."}

	var payload: Dictionary = entry["payload"]
	var listing_id := int(payload.get("listing_id", 0))
	var confirm_key := str(payload.get("confirm_key", ""))
	if confirm_key == "":
		# Should be impossible: the key is minted in phase 1. Minting one now
		# would be safe only because the server has not seen any other, but it
		# is worth recording that we got here.
		confirm_key = client.new_idempotency_key()
		ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"confirm_key": confirm_key})
		ledger.note_error(op_id, "confirm key was missing and had to be minted")

	var res: Dictionary = await client.post_json(
		"/listings/%d/confirm" % listing_id, {}, confirm_key)

	if not res["ok"]:
		# The goods are gone and the market has not answered. The entry stays,
		# and the next terminal open replays it. This is not a loss: the server
		# either has the listing or will refund from its own record.
		ledger.note_error(op_id, str(res.get("message", res.get("error", "unknown"))))
		return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
			"message": ("The market did not answer. Your item is safe -- this "
				+ "will finish next time the terminal is opened."),
			"op_id": op_id}

	var body = res["json"]
	var status := ""
	if body is Dictionary:
		status = str(body.get("status", ""))

	ledger.advance(op_id, PendingLedger.CONFIRMED, {"status": status})
	ledger.complete(op_id)

	# HTTP 200 does NOT mean the listing exists. Check the field.
	if status == "returned":
		var note := "The listing window lapsed, so nothing was sold."
		if body is Dictionary and str(body.get("note", "")) != "":
			note = str(body["note"])
		return {"ok": true, "outcome": OUTCOME_RETURNED,
			"message": note,
			"delivery_id": int(body.get("returned_delivery_id", 0)) if body is Dictionary else 0}

	return {"ok": true, "outcome": OUTCOME_LISTED,
		"listing_id": listing_id,
		"message": "Listed.",
		"fee_charged": int(body.get("listing_fee_charged", 0)) if body is Dictionary else 0}


static func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)


# ---------------------------------------------------------------------------
# Selling to the broker
# ---------------------------------------------------------------------------
#
# §7.3: the broker always quotes a two-sided price, which is what makes "you can
# always sell" true on a market too small and too scattered to have a buyer for
# everything. Selling to it is instant rather than a listing that may sit for 72
# hours.
#
# The endpoint differs from a listing -- no ask price, no listing fee -- but the
# ordering discipline is identical, and deliberately shares this file's
# machinery rather than copying it: record, flush, destroy, confirm.


## Quote an outright sale to the broker. Escrows nothing and charges no fee.
static func broker_quote(client: Node, ledger: RefCounted, slot: SlotData) -> Dictionary:
	var refusal: String = ItemBridge.rejection_reason(slot)
	if refusal != "":
		return {"ok": false, "outcome": OUTCOME_REFUSED, "message": refusal}

	var op_id: String = client.new_idempotency_key()
	var descriptor: Dictionary = ItemBridge.to_descriptor(slot)

	ledger.begin(op_id, PendingLedger.KIND_BROKER_SELL, {"descriptor": descriptor})

	var res: Dictionary = await client.post_json("/broker/sell", {
		"descriptor": descriptor,
	}, op_id)

	if not res["ok"]:
		ledger.complete(op_id)
		# broker_not_bidding and not_in_basket are ordinary answers, not faults:
		# the broker declines items outside its basket, below its condition
		# floor, at its inventory cap, or when its float is dry.
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": str(res.get("message", "The broker will not buy this.")),
			"error": str(res.get("error", ""))}

	var body = res["json"]
	if not body is Dictionary:
		ledger.complete(op_id)
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "The market sent a reply this terminal could not read."}

	var confirm_key: String = client.new_idempotency_key()
	ledger.advance(op_id, PendingLedger.RESERVED, {
		"broker_sale_id": int(body.get("broker_sale_id", 0)),
		"quote_price": int(body.get("quote_price", 0)),
		"confirm_key": confirm_key,
		"destroyed": false,
	})

	return {
		"ok": true,
		"op_id": op_id,
		"broker_sale_id": int(body.get("broker_sale_id", 0)),
		"quote_price": int(body.get("quote_price", 0)),
		"reserved_until": str(body.get("reserved_until", "")),
	}


## Commit a broker sale: destroy the item, then confirm.
static func broker_commit(tree: SceneTree, client: Node, ledger: RefCounted,
		op_id: String, element: Node) -> Dictionary:
	var entry: Dictionary = ledger.get_entry(op_id)
	if entry.is_empty():
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "This sale is no longer on record. Nothing was destroyed."}

	# THE ORDERING RULE, exactly as for a listing.
	if not ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED):
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "Could not record this sale, so nothing was destroyed."}

	if not Stash.destroy(tree, element):
		return {"ok": false, "outcome": OUTCOME_REFUSED,
			"message": "Could not take the item from your inventory."}

	ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})
	return await _broker_confirm(client, ledger, op_id)


## Phase 2 for a broker sale. Cannot refuse: the goods are already gone.
static func _broker_confirm(client: Node, ledger: RefCounted, op_id: String) -> Dictionary:
	var entry: Dictionary = ledger.get_entry(op_id)
	if entry.is_empty():
		return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
			"message": "This sale is no longer on record."}

	var payload: Dictionary = entry["payload"]
	var sale_id := int(payload.get("broker_sale_id", 0))
	var confirm_key := str(payload.get("confirm_key", ""))
	if confirm_key == "":
		confirm_key = client.new_idempotency_key()
		ledger.advance(op_id, PendingLedger.LOCAL_COMMITTED, {"confirm_key": confirm_key})
		ledger.note_error(op_id, "confirm key was missing and had to be minted")

	var res: Dictionary = await client.post_json(
		"/broker/sell/%d/confirm" % sale_id, {}, confirm_key)

	if not res["ok"]:
		ledger.note_error(op_id, str(res.get("message", res.get("error", "unknown"))))
		return {"ok": false, "outcome": OUTCOME_INTERRUPTED,
			"message": ("The market did not answer. Your item is safe -- this "
				+ "will finish next time the terminal is opened."),
			"op_id": op_id}

	var body = res["json"]
	var status := ""
	if body is Dictionary:
		status = str(body.get("status", ""))

	ledger.advance(op_id, PendingLedger.CONFIRMED, {"status": status})
	ledger.complete(op_id)

	# HTTP 200 does NOT mean it was bought. The float can drain between phases.
	if status == "returned":
		var note := "The broker could not pay, so nothing was sold."
		if body is Dictionary and str(body.get("note", "")) != "":
			note = str(body["note"])
		return {"ok": true, "outcome": OUTCOME_RETURNED,
			"message": note,
			"delivery_id": int(body.get("delivery_id", 0)) if body is Dictionary else 0}

	return {"ok": true, "outcome": OUTCOME_SOLD,
		"paid": int(body.get("paid", 0)) if body is Dictionary else 0,
		"message": "Sold to the broker.",
		"delivery_id": int(body.get("delivery_id", 0)) if body is Dictionary else 0}
