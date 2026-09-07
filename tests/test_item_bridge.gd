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
## Fixtures mirror the real catalog's classification of each item -- weapon,
## magazine, stackable, container, condition-bearing -- because the descriptor's
## legal field set depends on it. A bandage that claims to be a weapon would
## test nothing real.
##
## For the live counterpart that validates these same descriptors against the
## server's own validator, see tools/validate-descriptors.sh.

const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")

var _passed := 0
var _failed := 0
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
#
# Field values taken from the real catalog so classification matches production.

func _make_item(key: String, type: String, subtype: String, stackable: bool,
		has_condition: bool, capacity: float = 0.0) -> ItemData:
	var item := ItemData.new()
	item.file = key
	item.name = key
	item.type = type
	item.subtype = subtype
	item.stackable = stackable
	item.showCondition = has_condition
	item.capacity = capacity
	return item


func _build_items() -> void:
	_items["AK_12"] = _make_item("AK_12", "Weapon", "Rifle", false, true)
	_items["Makarov"] = _make_item("Makarov", "Weapon", "Pistol", false, true)
	_items["AK_12_Magazine"] = _make_item("AK_12_Magazine", "Attachment", "Magazine", false, false)
	_items["Ammo_545x39"] = _make_item("Ammo_545x39", "Ammo", "", true, false)
	_items["Bandage"] = _make_item("Bandage", "Medical", "", false, false)
	_items["SSh_39"] = _make_item("SSh_39", "Helmet", "", false, true)
	_items["Casette_Player"] = _make_item("Casette_Player", "Electronics", "", false, true)
	# A backpack and a jacket: both containers, because the container signal is
	# capacity, not class. Selling a jacket with a full pocket is the same bug
	# as selling a loaded backpack.
	_items["Backpack_Military"] = _make_item("Backpack_Military", "Backpack", "", false, true, 20.0)
	_items["Jacket_Civilian"] = _make_item("Jacket_Civilian", "Clothing", "", false, true, 4.0)
	for optic in ["ACOG", "PBS", "ANPEQ", "Kobra", "Vudu"]:
		_items[optic] = _make_item(optic, "Attachment", "Optic", false, false)


func _resolve(key: String):
	return _items.get(key)


func _slot(key: String) -> SlotData:
	var s := SlotData.new()
	s.itemData = _items[key]
	return s


# --- Round trips ---

func _run_round_trips() -> void:
	_round_trip("plain item, all defaults", _slot("Bandage"))

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
	# jammed rifle that round-tripped clean would be a free repair.
	var jammed := _slot("AK_12")
	jammed.condition = 12.0
	jammed.state = "Jammed"
	jammed.chamber = true
	jammed.casing = true
	_round_trip("jammed weapon with spent casing", jammed)

	var frozen := _slot("Bandage")
	frozen.state = "Frozen"
	_round_trip("frozen item", frozen)

	# Magazines hold rounds in `amount` exactly as weapons do, but carry none of
	# the weapon-only fields.
	var loaded_mag := _slot("AK_12_Magazine")
	loaded_mag.amount = 18
	_round_trip("partially loaded magazine", loaded_mag)

	# Partial stack. A full stack is the easy case; a partial one is where an
	# off-by-one shows up.
	var partial := _slot("Ammo_545x39")
	partial.amount = 37
	_round_trip("partial ammo stack", partial)

	var single := _slot("Ammo_545x39")
	single.amount = 1
	_round_trip("single round", single)

	# Attachment order must survive: nested is an ordered Array and the game
	# indexes into it (Context.gd builds its Remove buttons by index).
	var ordered := _slot("AK_12")
	ordered.nested.append(_items["Vudu"])
	ordered.nested.append(_items["Kobra"])
	ordered.nested.append(_items["AK_12_Magazine"])
	_round_trip("attachment order preserved", ordered)

	# Empty containers are listable; only full ones are refused.
	_round_trip("empty backpack", _slot("Backpack_Military"))
	_round_trip("empty jacket", _slot("Jacket_Civilian"))

	var damaged_helmet := _slot("SSh_39")
	damaged_helmet.condition = 81.0
	_round_trip("damaged helmet", damaged_helmet)


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


# --- Field legality ---
#
# The server rejects fields that do not apply to the item, so the descriptor
# must omit them rather than send defaults.

func _run_field_legality() -> void:
	var bandage: Dictionary = ItemBridge.to_descriptor(_slot("Bandage"))
	for field in ["mode", "zoom", "mount_position", "chamber", "casing"]:
		if bandage.has(field):
			_fail("non-weapon omits %s" % field, "descriptor carried it")
		else:
			_pass("non-weapon omits %s" % field)

	if bandage.has("condition"):
		_fail("item without condition omits it", "descriptor carried it")
	else:
		_pass("item without condition omits it")

	var rifle: Dictionary = ItemBridge.to_descriptor(_slot("AK_12"))
	for field in ["mode", "zoom", "mount_position", "chamber", "casing", "condition"]:
		if rifle.has(field):
			_pass("weapon carries %s" % field)
		else:
			_fail("weapon carries %s" % field, "descriptor omitted it")

	# `amount` must be 0 -- not absent -- on something that carries no amount.
	if bandage.get("amount", -1) == 0:
		_pass("amount is 0 on an item that carries none")
	else:
		_fail("amount is 0 on an item that carries none",
			"got %s" % str(bandage.get("amount")))

	# storage and custom are always sent. Absent-means-empty would let a client
	# hide a full backpack by omitting the field.
	for field in ["storage", "custom"]:
		if bandage.has(field):
			_pass("%s always sent" % field)
		else:
			_fail("%s always sent" % field, "descriptor omitted it")

	# A magazine holds rounds but is not a weapon.
	var mag := _slot("AK_12_Magazine")
	mag.amount = 18
	var mag_desc: Dictionary = ItemBridge.to_descriptor(mag)
	if mag_desc.get("amount") == 18 and not mag_desc.has("mode"):
		_pass("magazine carries rounds but no weapon fields")
	else:
		_fail("magazine carries rounds but no weapon fields", str(mag_desc))


# --- Rejections ---

func _run_rejections() -> void:
	_run_field_legality()

	# The property-loss case, for both kinds of container.
	var full_pack := _slot("Backpack_Military")
	full_pack.storage.append(_slot("Bandage"))
	_expect_rejected("non-empty backpack", full_pack)

	var full_jacket := _slot("Jacket_Civilian")
	full_jacket.storage.append(_slot("Bandage"))
	_expect_rejected("jacket with a full pocket", full_jacket)

	# A stackable with nothing in it: the server refuses amount < 1.
	var empty_stack := _slot("Ammo_545x39")
	empty_stack.amount = 0
	_expect_rejected("empty stack", empty_stack)

	# An amount on something that cannot carry one.
	var odd_bandage := _slot("Bandage")
	odd_bandage.amount = 5
	_expect_rejected("amount on an item that carries none", odd_bandage)

	var stackable_with_scope := _slot("Ammo_545x39")
	stackable_with_scope.amount = 30
	stackable_with_scope.nested.append(_items["ACOG"])
	_expect_rejected("attachment on a stackable", stackable_with_scope)

	var duplicated := _slot("AK_12")
	duplicated.nested.append(_items["ACOG"])
	duplicated.nested.append(_items["ACOG"])
	_expect_rejected("the same attachment fitted twice", duplicated)

	var bad_state := _slot("AK_12")
	bad_state.state = "Melted"
	_expect_rejected("unrecognised state", bad_state)

	_expect_rejected("item with no ItemData", SlotData.new())

	var no_key := SlotData.new()
	no_key.itemData = _make_item("", "Medical", "", false, false)
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

	# Condition is 0-100, never a 0-1 fraction. `0.62` on a 0-100 scale means
	# 0.62%, which is a silent 100x mispricing rather than a validation failure.
	var rifle := _slot("AK_12")
	rifle.condition = 62.0
	var desc: Dictionary = ItemBridge.to_descriptor(rifle)
	if is_equal_approx(float(desc["condition"]), 62.0):
		_pass("condition serialises on the 0-100 scale")
	else:
		_fail("condition serialises on the 0-100 scale", "got %s" % str(desc["condition"]))

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
		_fail("attachments serialise as plain keys", "got %s" % str(kitted_desc["attachments"]))

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
