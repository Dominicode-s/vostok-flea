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
## ## Fields are conditional, not unconditional
##
## The server rejects fields that do not apply to the item, so this cannot just
## emit everything and let the server sort it out (API.md, Rejections):
##
##   * `condition` supplied for an item that has none          -> 422
##   * `mode`/`zoom`/`mount_position`/`chamber`/`casing` on a
##     non-weapon                                              -> 422
##   * `amount` non-zero on something neither stackable nor a
##     weapon, or `amount < 1` on a stackable                   -> 422
##   * `storage` omitted on an item with capacity > 0           -> 422
##
## ## Classification comes from the game, not the catalog
##
## `GET /v1/catalog` does not publish `capacity` or `magazine_size`, although
## the contract's rejection rules reference both. The game's own ItemData does
## carry them, and the server's catalog was derived from exactly these fields,
## so classifying locally is both possible and authoritative.

const DESCRIPTOR_VERSION := 2

## Condition is 0-100 in the game and 0-100 on the wire. Stated as a constant
## because reading it as a 0-1 fraction is a silent 100x mispricing rather than
## a validation failure -- `0.62` means 0.62%.
const CONDITION_MIN := 0.0
const CONDITION_MAX := 100.0

const VALID_STATES := ["", "Jammed", "Frozen"]


# --- Classification ---

## Weapons carry fire mode, optic settings and a chamber. Nothing else may.
static func is_weapon(item: ItemData) -> bool:
	return item != null and str(item.type) == "Weapon"


## Magazines hold rounds in `amount` exactly as weapons do, but are not weapons
## and so carry none of the weapon-only fields.
static func is_magazine(item: ItemData) -> bool:
	return item != null and str(item.subtype) == "Magazine"


## Whether `amount` means anything for this item at all.
static func carries_amount(item: ItemData) -> bool:
	if item == null:
		return false
	return bool(item.stackable) or is_weapon(item) or is_magazine(item)


## `showCondition` is the game's own flag and is what the server's
## `has_condition` was derived from.
static func has_condition(item: ItemData) -> bool:
	return item != null and bool(item.showCondition)


## Containers are identified by capacity, not by `slots` -- `slots` turned out
## to be equip slots (Primary, Head, Torso). This catches the 12 items of
## clothing with pockets, not just backpacks.
static func is_container(item: ItemData) -> bool:
	return item != null and float(item.capacity) > 0.0


# --- Validation ---

## Why this item cannot be listed, or "" when it can.
##
## Checked BEFORE anything is destroyed. Every reason here is a refusal to
## start, never a failure part-way through.
static func rejection_reason(slot: SlotData) -> String:
	if slot == null:
		return "There is no item here."
	if slot.itemData == null:
		return "This item has no data attached to it."

	var item: ItemData = slot.itemData
	if str(item.file) == "":
		return "This item has no identity key and cannot be traded safely."

	# The property-loss case.
	#
	# `storage` holds a container's contents as a nested Array[SlotData] and it
	# travels with the item everywhere the game moves one. Listing a full
	# backpack -- or a jacket with something in the pocket -- would destroy the
	# contents too, while the server's record described only the container. A
	# refund could not put back what the server never held, and the loss happens
	# on the happy path where nobody is looking for it.
	#
	# Checked against actual contents rather than the catalog's capacity flag,
	# because contents are the thing that can actually be lost.
	if slot.storage != null and slot.storage.size() > 0:
		return "Empty this container before listing it. Its contents would be destroyed."

	if bool(item.stackable) and int(slot.amount) < 1:
		return "This stack is empty."

	if not carries_amount(item) and int(slot.amount) != 0:
		return "This item carries an amount the market cannot describe."

	if bool(item.stackable) and slot.nested != null and slot.nested.size() > 0:
		return "A stackable item cannot carry attachments."

	if str(slot.state) not in VALID_STATES:
		return "This item is in a state the market does not recognise ('%s')." % slot.state

	var seen := {}
	if slot.nested != null:
		for nested in slot.nested:
			if nested == null or str(nested.file) == "":
				return "One of this item's attachments is missing its identity key."
			if seen.has(str(nested.file)):
				return "This item has the same attachment fitted twice."
			seen[str(nested.file)] = true

	return ""


# --- Serialisation ---

## Serialise a game item to the canonical descriptor.
##
## Callers must check rejection_reason() first; this assumes a listable item.
## Only fields that legally apply to this item are emitted -- see the note at
## the top about conditional fields.
static func to_descriptor(slot: SlotData) -> Dictionary:
	var item: ItemData = slot.itemData

	var attachments := []
	if slot.nested != null:
		for nested in slot.nested:
			if nested != null and str(nested.file) != "":
				attachments.append(str(nested.file))

	var desc := {
		"descriptor_version": DESCRIPTOR_VERSION,
		"item_key": str(item.file),
		"attachments": attachments,
		"state": str(slot.state),
		# Sent explicitly and always. The server refuses a container that omits
		# it, and absent-means-empty would let a client hide a full backpack by
		# leaving the field out.
		"storage": [],
		"custom": {},
	}

	# `amount` is overloaded exactly as it is in the game: stack size for a
	# stackable, rounds loaded for a weapon or magazine, and meaningless
	# otherwise -- where it must be 0 rather than absent.
	desc["amount"] = int(slot.amount) if carries_amount(item) else 0

	if has_condition(item):
		# Kept as a float. The casette player drains condition fractionally
		# (condition -= delta * 0.1), so rounding would quietly alter an item on
		# every round-trip.
		desc["condition"] = _clamp_condition(slot.condition)

	if is_weapon(item):
		desc["mode"] = int(slot.mode)
		desc["zoom"] = int(slot.zoom)
		desc["mount_position"] = float(slot.position)
		desc["chamber"] = bool(slot.chamber)
		desc["casing"] = bool(slot.casing)

	return desc


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
	slot.state = str(desc.get("state", ""))

	# Defaults mirror SlotData's own, so a descriptor that legally omits a field
	# rebuilds the item the game would have created.
	slot.condition = _clamp_condition(desc.get("condition", CONDITION_MAX))
	slot.mode = int(desc.get("mode", 1))
	slot.zoom = int(desc.get("zoom", 1))
	slot.position = float(desc.get("mount_position", 0.0))
	slot.chamber = bool(desc.get("chamber", false))
	slot.casing = bool(desc.get("casing", false))

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


# --- Comparison ---

## True when two SlotData describe the same item, field for field.
static func equivalent(a: SlotData, b: SlotData) -> bool:
	return differences(a, b).is_empty()


## Field-by-field differences between two items, as human-readable strings.
##
## Compares everything SlotData.Update() copies, because that is the game's own
## definition of sameness -- a comparison that checked fewer fields would let
## exactly the losses this class exists to prevent pass as equal.
##
## Weapon-only fields are compared only on weapons: a bandage's `mode` is
## meaningless, is never sent, and rebuilds to the default, so comparing it
## would report a difference that does not exist.
static func differences(a: SlotData, b: SlotData) -> Array:
	var diffs := []
	if a == null or b == null:
		diffs.append("one side is null")
		return diffs

	var a_key := str(a.itemData.file) if a.itemData != null else "<none>"
	var b_key := str(b.itemData.file) if b.itemData != null else "<none>"
	if a_key != b_key:
		diffs.append("item_key: %s != %s" % [a_key, b_key])
		return diffs

	var item: ItemData = a.itemData

	if carries_amount(item) and int(a.amount) != int(b.amount):
		diffs.append("amount: %d != %d" % [a.amount, b.amount])

	if has_condition(item) and not is_equal_approx(float(a.condition), float(b.condition)):
		diffs.append("condition: %s != %s" % [a.condition, b.condition])

	if str(a.state) != str(b.state):
		diffs.append("state: '%s' != '%s'" % [a.state, b.state])

	if is_weapon(item):
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
