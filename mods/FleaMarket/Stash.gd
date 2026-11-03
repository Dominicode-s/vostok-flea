extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## The player's physical inventory: what is in it, and how to take things out.
##
## Everything here touches real property, so it is deliberately small and does
## exactly one thing per function. No market logic, no decisions about what
## ought to happen -- callers decide, this carries it out.
##
## Removal follows the pattern the physical-money mod established and has
## shipped with for months: `grid.Pick(element)` to detach the item from the
## grid's own bookkeeping, then `queue_free()`. Skipping Pick leaves the grid
## believing a freed node still occupies its cells, which corrupts placement
## for everything afterwards.
##
## Cash is never handled directly. It belongs to the physical-money mod, which
## exposes CountCash / RemoveCash / AddCash through Engine meta, and the brief
## forbids modifying that mod. Going through its public API also means its
## stacking, badge and persistence behaviour stay correct for free.

const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")


static func interface(tree: SceneTree) -> Node:
	if tree == null:
		return null
	return tree.root.get_node_or_null("Map/Core/UI/Interface")


static func cash_mod() -> Object:
	return Engine.get_meta("CashMain", null)


# --- Reading ---

## Every item in the player's inventory grid, as {element, slot} pairs.
##
## `element` is the UI node that owns the slot; it is what removal needs.
static func inventory(tree: SceneTree) -> Array:
	var out := []
	var iface := interface(tree)
	if iface == null or not "inventoryGrid" in iface or iface.inventoryGrid == null:
		return out

	for element in iface.inventoryGrid.get_children():
		if not "slotData" in element or element.slotData == null:
			continue
		if element.slotData.itemData == null:
			continue
		out.append({"element": element, "slot": element.slotData})
	return out


## Items the market will accept, each with the reason it would be refused.
##
## Returns every item rather than filtering, because "why can't I sell this?"
## is a question the sell screen has to answer. A list that silently omits the
## player's backpack teaches them nothing.
static func sellable(tree: SceneTree, catalog: RefCounted) -> Array:
	var out := []
	for entry in inventory(tree):
		var slot: SlotData = entry["slot"]
		var reason: String = ItemBridge.rejection_reason(slot)

		# Cash is not merchandise. Excluded outright rather than refused with a
		# message, because offering to sell money for money is nonsense.
		if reason == "" and str(slot.itemData.file) == "Cash":
			continue

		if reason == "" and catalog != null and catalog.is_loaded():
			var key := str(slot.itemData.file)
			if not catalog.has_item(key):
				reason = "The market does not deal in this item."
			elif not bool(catalog.get_item(key).get("tradeable", true)):
				reason = "This item cannot be traded."

		out.append({
			"element": entry["element"],
			"slot": slot,
			"reason": reason,
			"sellable": reason == "",
		})
	return out


## The first inventory item whose descriptor matches `descriptor`.
##
## Used by crash recovery to answer "did the destroy actually happen?". Matching
## is on the full descriptor rather than the item key, so a damaged rifle is not
## mistaken for a pristine one. Two genuinely identical items are
## interchangeable, so picking either is correct.
static func find_matching(tree: SceneTree, descriptor: Dictionary) -> Node:
	for entry in inventory(tree):
		var slot: SlotData = entry["slot"]
		if ItemBridge.rejection_reason(slot) != "":
			continue
		if _same_descriptor(ItemBridge.to_descriptor(slot), descriptor):
			return entry["element"]
	return null


# --- Removing ---

## Take an item out of the world. Returns false if it could not be removed, and
## the caller MUST treat that as a reason to stop: a sale that proceeds after a
## failed destroy is a duplication.
static func destroy(tree: SceneTree, element: Node) -> bool:
	if element == null or not is_instance_valid(element):
		return false
	var iface := interface(tree)
	if iface == null or not "inventoryGrid" in iface or iface.inventoryGrid == null:
		return false

	# Pick first: the grid tracks occupancy separately from the node tree, and
	# freeing a node it still believes is placed corrupts the layout.
	iface.inventoryGrid.Pick(element)
	element.queue_free()
	return true


# --- Cash ---

## Whether the physical-money mod is installed at all.
##
## Distinct from "you have no cash". Telling a player they need 500 roubles
## when the mod that implements roubles is missing sends them looking for money
## instead of for the dependency.
static func cash_available() -> bool:
	return cash_mod() != null


const CASH_MISSING := ("The Cash System mod is not installed. Trading needs it, "
	+ "because fees and payments are physical cash. Browsing works without it.")


static func cash_on_hand() -> int:
	var cash := cash_mod()
	if cash == null or not cash.has_method("CountCash"):
		return 0
	return int(cash.CountCash())


## Destroy exactly `amount` of physical cash. Returns false if the player does
## not have it, having changed nothing.
static func take_cash(amount: int) -> bool:
	if amount <= 0:
		return true
	var cash := cash_mod()
	if cash == null or not cash.has_method("RemoveCash"):
		return false
	return bool(cash.RemoveCash(amount))


## Put physical cash into the world. Used only when acknowledging a delivery.
static func give_cash(amount: int) -> bool:
	if amount <= 0:
		return true
	var cash := cash_mod()
	if cash == null or not cash.has_method("AddCash"):
		return false
	return bool(cash.AddCash(amount))


# --- Internals ---

## Descriptor equality, ignoring fields that do not identify an item.
static func _same_descriptor(a: Dictionary, b: Dictionary) -> bool:
	for field in ["item_key", "amount", "state"]:
		if str(a.get(field, "")) != str(b.get(field, "")):
			return false

	# Condition is a float and arrives back through JSON, so compare with a
	# tolerance rather than exactly.
	var ca := float(a.get("condition", -1.0))
	var cb := float(b.get("condition", -1.0))
	if absf(ca - cb) > 0.01:
		return false

	var aa = a.get("attachments", [])
	var ba = b.get("attachments", [])
	if not aa is Array or not ba is Array or aa.size() != ba.size():
		return false
	for i in range(aa.size()):
		if str(aa[i]) != str(ba[i]):
			return false

	for field in ["mode", "zoom", "chamber", "casing"]:
		if a.has(field) != b.has(field):
			return false
		if a.has(field) and str(a[field]) != str(b[field]):
			return false
	return true
