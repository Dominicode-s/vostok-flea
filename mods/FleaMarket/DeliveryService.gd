extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Collecting deliveries into the courier crate.
##
## §13 step 6: at the ETA the client polls for deliveries, spawns the goods into
## the crate, and ONLY THEN acknowledges. The server marks delivered on the ACK.
##
## ## The one hazard the design leaves client-side
##
## The server cannot tell a lost ACK from a genuine re-request. If the ACK never
## lands, the delivery is still pending at the next terminal open -- while the
## goods are already sitting in the crate. A client that spawns on every pending
## delivery duplicates them.
##
## So spawning is recorded locally, flushed, BEFORE the ACK is sent:
##
##     spawn into the crate
##     ledger.advance(LOCAL_COMMITTED)   <- flushed
##     POST /deliveries/{id}/ack
##
## and a delivery already marked spawned is never spawned again -- it is only
## re-acknowledged. This mirrors the sell flow's ordering, inverted: there the
## record precedes destruction, here it precedes the acknowledgement, and in
## both cases the record is what survives the crash.
##
## ## A full crate is not an error
##
## §8.2: deliveries that do not fit wait on the van. An unacked delivery is a
## delivery the server still owes you, so leaving it alone is both correct and
## free. It is never partially spawned and never dropped.

const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")
const PendingLedger := preload("res://mods/FleaMarket/PendingLedger.gd")
const Stash := preload("res://mods/FleaMarket/Stash.gd")

const LOG_PREFIX := "[FleaMarket/delivery] "

## The crate's scene root, as named in CourierCrate_F.tscn.
const CRATE_NODE := "CourierCrate_F"

## Grid.cellSize. Stored grid positions are in PIXELS, not cells: GridSave
## records `item.position`, which Place() has already set to
## cell * cellSize.
const CELL := 64

## Cash is one stackable item; a large payout arrives as several stacks.
const CASH_KEY := "Cash"


## Collect everything ready. Returns a list of human-readable outcomes.
static func collect(tree: SceneTree, client: Node, ledger: RefCounted) -> Array:
	var out := []

	var res: Dictionary = await client.get_json("/deliveries", {"ready": "true"})
	if not res["ok"]:
		return out
	var body = res["json"]
	if not body is Dictionary:
		return out
	var deliveries = body.get("deliveries", [])
	if not deliveries is Array:
		return out

	var crate := find_crate(tree)

	for entry in deliveries:
		if not entry is Dictionary:
			continue
		if not bool(entry.get("ready", false)):
			continue

		var delivery_id := int(entry.get("id", 0))
		if delivery_id <= 0:
			continue

		var already := _spawned_entry(ledger, delivery_id)
		if not already.is_empty():
			# Already in the crate; the ACK is what went missing. Re-acknowledge
			# WITHOUT spawning. Spawning here is the duplication bug.
			_log("delivery %d was already spawned; re-acknowledging only" % delivery_id)
			if await _ack(client, ledger, already):
				out.append("Collected earlier delivery #%d." % delivery_id)
			continue

		if crate == null:
			out.append("A delivery is waiting, but you have no courier crate placed.")
			continue

		var result := _spawn(crate, entry)
		if not result["ok"]:
			# Not an error. The server still owes it, and it stays pending.
			out.append(str(result["message"]))
			continue

		# Recorded and flushed BEFORE the ACK, so a lost ACK cannot cause a
		# second spawn.
		var ack_key: String = client.new_idempotency_key()
		ledger.begin(ack_key, PendingLedger.KIND_DELIVERY_ACK,
			{"delivery_id": delivery_id})
		ledger.advance(ack_key, PendingLedger.LOCAL_COMMITTED)

		if await _ack(client, ledger, ledger.get_entry(ack_key)):
			out.append(str(result["message"]))
		else:
			out.append(str(result["message"]) + " (the market has not confirmed yet)")

	return out


## Re-send any ACK that never landed. Called alongside SellFlow.recover().
static func recover(client: Node, ledger: RefCounted) -> void:
	for entry in ledger.outstanding():
		if str(entry.get("kind", "")) != PendingLedger.KIND_DELIVERY_ACK:
			continue
		if ledger.is_stalled(entry):
			continue
		await _ack(client, ledger, entry)


# --- The crate ---

static func find_crate(tree: SceneTree) -> Node:
	if tree == null:
		return null
	var map := tree.root.get_node_or_null("Map")
	if map == null:
		return null
	var found := map.find_children(CRATE_NODE + "*", "", true, false)
	return found[0] if not found.is_empty() else null


## Free capacity, as {free, total} cells. Used to warn before a sale that the
## proceeds may not fit.
static func capacity(crate: Node) -> Dictionary:
	if crate == null or not "containerSize" in crate:
		return {"free": 0, "total": 0}
	var size: Vector2 = crate.containerSize
	var total := int(size.x) * int(size.y)
	var occupied := _occupancy(crate)
	var used := 0
	for row in occupied:
		for cell in row:
			if cell:
				used += 1
	return {"free": total - used, "total": total}


# --- Spawning ---

static func _spawn(crate: Node, entry: Dictionary) -> Dictionary:
	var kind := str(entry.get("kind", ""))
	if kind == "cash":
		return _spawn_cash(crate, int(entry.get("cash_amount", 0)))
	return _spawn_item(crate, entry.get("item"))


static func _spawn_item(crate: Node, item) -> Dictionary:
	if not item is Dictionary:
		return {"ok": false, "message": "A delivery arrived in a form this terminal could not read."}

	var slot: SlotData = ItemBridge.from_descriptor(item, _resolve_item)
	if slot == null:
		# Refusing to build a partial item matters: a rifle whose scope silently
		# vanished is worse than nothing spawned and the delivery left pending
		# for a human to look at.
		return {"ok": false,
			"message": "A delivery could not be unpacked and is still waiting."}

	if not _place(crate, slot):
		return {"ok": false,
			"message": "The courier crate is full. A delivery is waiting on the van."}

	return {"ok": true,
		"message": "Collected %s into the courier crate." % str(item.get("item_key", "an item"))}


static func _spawn_cash(crate: Node, amount: int) -> Dictionary:
	if amount <= 0:
		return {"ok": true, "message": "Collected nothing."}

	var cash := Stash.cash_mod()
	if cash == null or not "cash_item_data" in cash or cash.cash_item_data == null:
		return {"ok": false,
			"message": "Cash arrived but the money system is not loaded."}

	var cash_item: ItemData = cash.cash_item_data
	var per_stack := int(cash_item.maxAmount)
	if per_stack <= 0:
		per_stack = 99999

	# A large payout is several stacks, and each needs a cell. This is the
	# physicality §7.1 asks for: two million is a storage problem.
	var remaining := amount
	var placed := 0
	while remaining > 0:
		var slot := SlotData.new()
		slot.itemData = cash_item
		slot.amount = mini(remaining, per_stack)
		if not _place(crate, slot):
			break
		remaining -= slot.amount
		placed += 1

	if placed == 0:
		return {"ok": false,
			"message": "The courier crate is full. %d in cash is waiting on the van." % amount}
	if remaining > 0:
		# Partial is refused rather than kept: the delivery is acknowledged as a
		# whole or not at all, and a half-collected payout would leave the
		# server believing it had paid in full.
		return {"ok": false,
			"message": ("The courier crate has room for only part of %d in cash. "
				+ "Clear space and it will arrive whole.") % amount}

	return {"ok": true,
		"message": "Collected %d in cash into the courier crate." % amount}


static func _resolve_item(key: String):
	# Database.master.items is the game's own item table; `file` is the identity
	# field, matching what the catalog was built from.
	var database = Engine.get_singleton("Database") if Engine.has_singleton("Database") else null
	if database == null:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			database = tree.root.get_node_or_null("Database")
	if database == null or not "master" in database or database.master == null:
		return null
	for item in database.master.items:
		if item != null and str(item.file) == key:
			return item
	return null


# --- Grid placement ---
#
# The crate is not open, so the game's own Grid cannot place anything. Its
# occupancy rules are reproduced here against `crate.storage`, which is what the
# grid is rebuilt from when the player next opens it.

static func _place(crate: Node, slot: SlotData) -> bool:
	if crate == null or not "containerSize" in crate:
		return false

	var size := _cell_size(slot)
	var cell := _free_cell(crate, size)
	if cell.x < 0:
		return false

	var stored := SlotData.new()
	stored.Update(slot)
	# Stored positions are pixels, because GridSave records item.position after
	# Place() has multiplied the cell by cellSize.
	stored.GridSave(Vector2(cell.x * CELL, cell.y * CELL), false)

	# `storaged` tells the game to load `storage` rather than regenerate loot.
	# Without it the crate would discard everything and roll fresh contents.
	crate.storaged = true
	crate.storage.append(stored)
	return true


static func _cell_size(slot: SlotData) -> Vector2i:
	var size := Vector2i(1, 1)
	if slot.itemData != null:
		size = Vector2i(maxi(1, int(slot.itemData.size.x)), maxi(1, int(slot.itemData.size.y)))
	if slot.gridRotated:
		size = Vector2i(size.y, size.x)
	return size


static func _occupancy(crate: Node) -> Array:
	var size: Vector2 = crate.containerSize
	var w := maxi(1, int(size.x))
	var h := maxi(1, int(size.y))

	var grid := []
	for x in range(w):
		var column := []
		for y in range(h):
			column.append(false)
		grid.append(column)

	if not "storage" in crate or crate.storage == null:
		return grid

	for stored in crate.storage:
		if stored == null or stored.itemData == null:
			continue
		var cell := Vector2i(int(stored.gridPosition.x) / CELL, int(stored.gridPosition.y) / CELL)
		var span := _cell_size(stored)
		for x in range(cell.x, mini(cell.x + span.x, w)):
			for y in range(cell.y, mini(cell.y + span.y, h)):
				if x >= 0 and y >= 0:
					grid[x][y] = true
	return grid


## First cell the item fits in, scanning the way Grid.Spawn does: rows top to
## bottom, columns left to right. Returns (-1, -1) when it does not fit.
static func _free_cell(crate: Node, span: Vector2i) -> Vector2i:
	var size: Vector2 = crate.containerSize
	var w := maxi(1, int(size.x))
	var h := maxi(1, int(size.y))
	var grid := _occupancy(crate)

	for y in range(h):
		for x in range(w):
			if x + span.x > w or y + span.y > h:
				continue
			var fits := true
			for i in range(x, x + span.x):
				for j in range(y, y + span.y):
					if grid[i][j]:
						fits = false
						break
				if not fits:
					break
			if fits:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


# --- ACK ---

static func _spawned_entry(ledger: RefCounted, delivery_id: int) -> Dictionary:
	for entry in ledger.outstanding():
		if str(entry.get("kind", "")) != PendingLedger.KIND_DELIVERY_ACK:
			continue
		if int(entry["payload"].get("delivery_id", 0)) == delivery_id:
			return entry
	return {}


static func _ack(client: Node, ledger: RefCounted, entry: Dictionary) -> bool:
	if entry.is_empty():
		return false
	var op_id := str(entry["op_id"])
	var delivery_id := int(entry["payload"].get("delivery_id", 0))

	var res: Dictionary = await client.post_json(
		"/deliveries/%d/ack" % delivery_id, {}, op_id)

	if not res["ok"]:
		# The goods are in the crate and the server has not been told. The entry
		# stays, and the next collection re-acknowledges without spawning.
		ledger.note_error(op_id, str(res.get("message", res.get("error", "unknown"))))
		return false

	ledger.complete(op_id)
	return true


static func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
