extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Converts a game item to the server's canonical descriptor and back.
##
## The spec calls this the hardest problem on the client, harder than the
## networking, and it is right: if the round-trip is lossy, players get their
## rifle back subtly different and they will notice.
##
## What a game item actually is (Scripts/SlotData.gd) -- eleven fields, all of
## which SlotData.Update() copies. That method is the game's own definition of
## "the same item", and it is the bar a lossless round-trip has to clear:
##
##   itemData   the type; its `.file` is the identity key
##   nested     attachments, as type references with NO per-instance state
##   storage    contents of a container item, recursive
##   condition  durability, 0-100 (NOT 0.0-1.0)
##   amount     stack size, or rounds loaded in a weapon/magazine
##   position   optic mount position, player-adjustable
##   mode       fire selector: 1 = semi, 2 = auto
##   zoom       optic magnification step, 1-3
##   chamber    a round is chambered
##   casing     a spent casing is in the chamber
##   state      "", "Jammed" or "Frozen"
##
## Descriptor version 2 carries all of them. Version 1 carried three, invented a
## `durability` field the game does not have, and expected a per-attachment
## condition that cannot exist -- see docs/FINDINGS-ITEMBRIDGE.md.
##
## CONTRACT CAVEAT: descriptor v2's exact field names are this client's
## proposal. The server has adopted descriptor_version 2 and condition_scale
## {0, 100} from that proposal, but the full shape has not been confirmed
## against API.md, and phase-1 POST /listings -- the free validator -- is
## currently unreachable behind a 401. Treat the key names as provisional and
## re-check them before the first real escrow.

const DESCRIPTOR_VERSION := 2

## Condition is 0-100 in the game and 0-100 on the wire. Stated as a constant
## because reading it as a 0-1 fraction is a silent 100x pricing error rather
## than a validation failure -- exactly the kind of bug that looks fine until
## money moves.
const CONDITION_MIN := 0.0
const CONDITION_MAX := 100.0


## Why this item cannot be listed, or "" when it can.
##
## Checked BEFORE anything is destroyed. Every reason here is a refusal to
## start, never a failure part-way through.
static func rejection_reason(slot: SlotData) -> String:
	if slot == null:
		return "There is no item here."
	if slot.itemData == null:
		return "This item has no data attached to it."
	if str(slot.itemData.file) == "":
		return "This item has no identity key and cannot be traded safely."

	# Containers are refused rather than serialised, for now.
	#
	# `storage` holds a container's contents as a nested Array[SlotData] and it
	# travels with the item everywhere the game moves one. Listing a full
	# backpack would destroy the backpack AND everything inside it, while the
	# server's record described only the backpack -- so a refund could not put
	# the contents back. That is property loss on the happy path.
	#
	# Representing storage recursively is the richer fix and the descriptor has
	# a slot for it. Refusing is the one option that cannot silently lose
	# anything, so it is what ships first.
	if slot.storage != null and slot.storage.size() > 0:
		return "Empty this container before listing it."

	return ""


## Serialise a game item to the canonical descriptor.
##
## Callers must check rejection_reason() first; this assumes a listable item.
static func to_descriptor(slot: SlotData) -> Dictionary:
	var attachments := []
	if slot.nested != null:
		for nested in slot.nested:
			if nested != null and str(nested.file) != "":
				attachments.append(str(nested.file))

	return {
		"descriptor_version": DESCRIPTOR_VERSION,
		"item_key": str(slot.itemData.file),
		"amount": int(slot.amount),
		# Kept as a float. The casette player drains condition fractionally
		# (condition -= delta * 0.1), so rounding here would quietly alter an
		# item on every round-trip.
		"condition": float(slot.condition),
		"attachments": attachments,
		"mode": int(slot.mode),
		"zoom": int(slot.zoom),
		"mount_position": float(slot.position),
		"chamber": bool(slot.chamber),
		"casing": bool(slot.casing),
		"state": str(slot.state),
		"storage": [],
	}


## Rebuild a game item from a descriptor.
##
## `resolve` maps an item_key to an ItemData: `func(key: String) -> ItemData`.
## Injected rather than reaching for the game's Database directly so this is
## testable headlessly, without the game running.
##
## Returns null when the item_key or any attachment key cannot be resolved.
## Refusing to build a partial item matters: spawning a rifle whose scope
## silently vanished is worse than spawning nothing and leaving the delivery
## unacked for a human to look at.
static func from_descriptor(desc: Dictionary, resolve: Callable) -> SlotData:
	if desc == null or desc.is_empty():
		return null

	var key := str(desc.get("item_key", ""))
	if key == "":
		return null

	var item_data = resolve.call(key)
	if item_data == null:
		push_error("FleaMarket: unknown item_key '%s' in descriptor" % key)
		return null

	var slot := SlotData.new()
	slot.itemData = item_data
	slot.amount = int(desc.get("amount", 0))
	slot.condition = _clamp_condition(desc.get("condition", CONDITION_MAX))
	slot.mode = int(desc.get("mode", 1))
	slot.zoom = int(desc.get("zoom", 1))
	slot.position = float(desc.get("mount_position", 0.0))
	slot.chamber = bool(desc.get("chamber", false))
	slot.casing = bool(desc.get("casing", false))
	slot.state = str(desc.get("state", ""))

	var attachments = desc.get("attachments", [])
	if attachments is Array:
		for entry in attachments:
			var attachment_key := str(entry)
			var attachment = resolve.call(attachment_key)
			if attachment == null:
				push_error("FleaMarket: unknown attachment '%s' on '%s'" % [
					attachment_key, key])
				return null
			slot.nested.append(attachment)

	return slot


## True when two SlotData describe the same item, field for field.
##
## Used by the round-trip test. Compares everything SlotData.Update() copies,
## because that is the game's own definition of sameness -- a comparison that
## checked fewer fields would let exactly the losses this class exists to
## prevent pass as equal.
static func equivalent(a: SlotData, b: SlotData) -> bool:
	return differences(a, b).is_empty()


## Field-by-field differences between two items, as human-readable strings.
static func differences(a: SlotData, b: SlotData) -> Array:
	var diffs := []
	if a == null or b == null:
		diffs.append("one side is null")
		return diffs

	var a_key := str(a.itemData.file) if a.itemData != null else "<none>"
	var b_key := str(b.itemData.file) if b.itemData != null else "<none>"
	if a_key != b_key:
		diffs.append("item_key: %s != %s" % [a_key, b_key])

	if int(a.amount) != int(b.amount):
		diffs.append("amount: %d != %d" % [a.amount, b.amount])
	if not is_equal_approx(float(a.condition), float(b.condition)):
		diffs.append("condition: %s != %s" % [a.condition, b.condition])
	if int(a.mode) != int(b.mode):
		diffs.append("mode: %d != %d" % [a.mode, b.mode])
	if int(a.zoom) != int(b.zoom):
		diffs.append("zoom: %d != %d" % [a.zoom, b.zoom])
	if not is_equal_approx(float(a.position), float(b.position)):
		diffs.append("mount_position: %s != %s" % [a.position, b.position])
	if bool(a.chamber) != bool(b.chamber):
		diffs.append("chamber: %s != %s" % [a.chamber, b.chamber])
	if bool(a.casing) != bool(b.casing):
		diffs.append("casing: %s != %s" % [a.casing, b.casing])
	if str(a.state) != str(b.state):
		diffs.append("state: '%s' != '%s'" % [a.state, b.state])

	var a_att := _attachment_keys(a)
	var b_att := _attachment_keys(b)
	if a_att != b_att:
		diffs.append("attachments: %s != %s" % [str(a_att), str(b_att)])

	var a_storage := a.storage.size() if a.storage != null else 0
	var b_storage := b.storage.size() if b.storage != null else 0
	if a_storage != b_storage:
		diffs.append("storage size: %d != %d" % [a_storage, b_storage])

	return diffs


# --- Internals ---

static func _attachment_keys(slot: SlotData) -> Array:
	var out := []
	if slot.nested != null:
		for nested in slot.nested:
			if nested != null:
				out.append(str(nested.file))
	return out


static func _clamp_condition(value) -> float:
	return clampf(float(value), CONDITION_MIN, CONDITION_MAX)
