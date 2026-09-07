extends SceneTree

## ItemBridge round-trip test: serialise -> deserialise -> compare, over a
## fixture set of deliberately awkward items.
##
## The brief names a lossy round-trip as the primary correctness risk on the
## client, and asks for this test to be green from the first commit. It runs
## headlessly against a real Godot binary, so it needs no game launch:
##
##     tools/run-tests.sh
##
## Fixtures are chosen to break things rather than to pass: fractional
## condition, zero and boundary condition, heavy attachment loads, partial
## stacks, every weapon-state field set to a non-default, and the container
## case that must be refused rather than serialised.

const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")

var _passed := 0
var _failed := 0

## Stand-in item catalog. Keys mirror real ones from the extracted catalog so a
## typo here would look like a typo in the real thing.
var _items := {}


func _init() -> void:
	print("")
	print("ItemBridge round-trip")
	print("=====================")

	_build_items()
	_run_round_trips()
	_run_rejections()
	_run_regressions()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# --- Fixtures ---

func _make_item(key: String, has_condition: bool = true) -> ItemData:
	var item := ItemData.new()
	item.file = key
	item.name = key
	item.showCondition = has_condition
	return item


func _build_items() -> void:
	for key in [
		"AK_12", "AK_12_Magazine", "ACOG", "PBS", "ANPEQ", "Kobra", "Vudu",
		"Ammo_545x39", "Bandage", "Backpack_Military", "Casette_Player",
	]:
		_items[key] = _make_item(key)


func _resolve(key: String):
	return _items.get(key)


func _slot(key: String) -> SlotData:
	var s := SlotData.new()
	s.itemData = _items[key]
	return s


# --- Round trips ---

func _run_round_trips() -> void:
	# A bare item, everything default.
	var plain := _slot("Bandage")
	_round_trip("plain item, all defaults", plain)

	# Fractional condition. The casette player drains condition by
	# `delta * 0.1`, so non-integer values genuinely occur; rounding them would
	# alter the item on every trip through the market.
	var fractional := _slot("Casette_Player")
	fractional.condition = 62.3456
	_round_trip("fractional condition", fractional)

	# Condition boundaries, including a destroyed-but-present item.
	for value in [0.0, 0.5, 99.5, 100.0]:
		var edge := _slot("AK_12")
		edge.condition = value
		_round_trip("condition %s" % value, edge)

	# A heavily kitted rifle with every weapon-state field off its default.
	# This is the fixture that would have caught descriptor v1: under v1 it
	# comes back on semi, at 1x, with an empty chamber and no attachments.
	var kitted := _slot("AK_12")
	kitted.condition = 62.0
	kitted.amount = 27
	kitted.nested.append(_items["AK_12_Magazine"])
	kitted.nested.append(_items["ACOG"])
	kitted.nested.append(_items["PBS"])
	kitted.nested.append(_items["ANPEQ"])
	kitted.mode = 2
	kitted.zoom = 3
	kitted.position = 0.04
	kitted.chamber = true
	kitted.casing = false
	_round_trip("kitted rifle, full weapon state", kitted)

	# A jammed weapon. State has real value implications in both directions: a
	# jammed rifle that round-trips clean is a free repair.
	var jammed := _slot("AK_12")
	jammed.condition = 12.0
	jammed.state = "Jammed"
	jammed.chamber = true
	jammed.casing = true
	_round_trip("jammed weapon with spent casing", jammed)

	var frozen := _slot("Bandage")
	frozen.state = "Frozen"
	_round_trip("frozen item", frozen)

	# Partial stack. A full stack is the easy case; a partial one is where an
	# off-by-one shows up.
	var partial := _slot("Ammo_545x39")
	partial.amount = 37
	_round_trip("partial ammo stack", partial)

	var single := _slot("Ammo_545x39")
	single.amount = 1
	_round_trip("single round", single)

	var empty_stack := _slot("Ammo_545x39")
	empty_stack.amount = 0
	_round_trip("empty stack", empty_stack)

	# Attachment order must survive: nested is an ordered Array and the game
	# indexes into it (Context.gd builds its Remove buttons by index).
	var ordered := _slot("AK_12")
	ordered.nested.append(_items["Vudu"])
	ordered.nested.append(_items["Kobra"])
	ordered.nested.append(_items["AK_12_Magazine"])
	_round_trip("attachment order preserved", ordered)

	# An empty container is listable; only a full one is refused.
	var empty_container := _slot("Backpack_Military")
	_round_trip("empty container", empty_container)


func _round_trip(label: String, original: SlotData) -> void:
	var reason: String = ItemBridge.rejection_reason(original)
	if reason != "":
		_fail(label, "unexpectedly rejected: " + reason)
		return

	var descriptor: Dictionary = ItemBridge.to_descriptor(original)

	# Through JSON, not just through the dictionary. The descriptor crosses the
	# wire as text, and JSON has no integer type -- a bug where an int comes
	# back as a float only shows up if the test serialises for real.
	var wire := JSON.stringify(descriptor)
	var parsed = JSON.parse_string(wire)
	if not parsed is Dictionary:
		_fail(label, "descriptor did not survive JSON encoding")
		return

	var rebuilt: SlotData = ItemBridge.from_descriptor(parsed, _resolve)
	if rebuilt == null:
		_fail(label, "from_descriptor returned null")
		return

	var diffs: Array = ItemBridge.differences(original, rebuilt)
	if diffs.is_empty():
		_pass(label)
	else:
		_fail(label, "; ".join(PackedStringArray(diffs)))


# --- Rejections ---

func _run_rejections() -> void:
	# The property-loss case. A container's contents travel with the item, so
	# listing a full backpack would destroy the contents too while the server's
	# record described only the backpack.
	var full := _slot("Backpack_Military")
	var contents := _slot("Bandage")
	full.storage.append(contents)
	_expect_rejected("non-empty container", full)

	var no_data := SlotData.new()
	_expect_rejected("item with no ItemData", no_data)

	var no_key := SlotData.new()
	no_key.itemData = _make_item("")
	_expect_rejected("item with an empty identity key", no_key)

	_expect_rejected("null slot", null)


func _expect_rejected(label: String, slot: SlotData) -> void:
	var reason: String = ItemBridge.rejection_reason(slot)
	if reason == "":
		_fail("reject " + label, "was accepted but should have been refused")
	else:
		_pass("reject %s (%s)" % [label, reason])


# --- Regressions ---

func _run_regressions() -> void:
	print("  -- the next few checks assert that bad input is REFUSED, so the")
	print("     ERROR lines they print are the expected behaviour, not failures")

	# An unknown item_key must produce nothing rather than a partial item.
	var unknown := {"descriptor_version": 2, "item_key": "NotAThing", "amount": 1}
	if ItemBridge.from_descriptor(unknown, _resolve) == null:
		_pass("unknown item_key returns null")
	else:
		_fail("unknown item_key returns null", "built an item anyway")

	# An unresolvable ATTACHMENT must also fail the whole build. Spawning a
	# rifle whose scope silently vanished is worse than spawning nothing.
	var bad_attachment := {
		"descriptor_version": 2,
		"item_key": "AK_12",
		"amount": 0,
		"attachments": ["NotAScope"],
	}
	if ItemBridge.from_descriptor(bad_attachment, _resolve) == null:
		_pass("unknown attachment fails the whole item")
	else:
		_fail("unknown attachment fails the whole item",
			"built a rifle with the attachment silently dropped")

	# Condition is 0-100, never a 0-1 fraction. Reading a 0-1 value as 0-100 is
	# a silent 100x pricing error, so the scale is asserted explicitly.
	var rifle := _slot("AK_12")
	rifle.condition = 62.0
	var desc: Dictionary = ItemBridge.to_descriptor(rifle)
	if is_equal_approx(float(desc["condition"]), 62.0):
		_pass("condition serialises on the 0-100 scale")
	else:
		_fail("condition serialises on the 0-100 scale",
			"got %s" % str(desc["condition"]))

	# v1's invented field must not reappear.
	if not desc.has("durability"):
		_pass("no invented durability field")
	else:
		_fail("no invented durability field", "descriptor still carries it")

	# Attachments are plain keys: the game has no per-attachment condition to
	# report, so anything richer would be fabricated.
	var kitted := _slot("AK_12")
	kitted.nested.append(_items["ACOG"])
	var kitted_desc: Dictionary = ItemBridge.to_descriptor(kitted)
	if kitted_desc["attachments"] == ["ACOG"]:
		_pass("attachments serialise as plain keys")
	else:
		_fail("attachments serialise as plain keys",
			"got %s" % str(kitted_desc["attachments"]))

	if int(desc.get("descriptor_version", 0)) == 2:
		_pass("descriptor_version is 2")
	else:
		_fail("descriptor_version is 2", "got %s" % str(desc.get("descriptor_version")))


# --- Reporting ---

func _pass(label: String) -> void:
	_passed += 1
	print("  ok    %s" % label)


func _fail(label: String, detail: String) -> void:
	_failed += 1
	print("  FAIL  %s" % label)
	print("        %s" % detail)
