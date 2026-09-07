extends SceneTree

## Emits an ItemBridge descriptor for every tradeable item in the real catalog,
## as JSON, for tools/validate-descriptors.sh to POST at the server's phase-1
## validator.
##
## Phase 1 records a descriptor and moves nothing -- no escrow, no fee, no
## ledger posting -- but fully validates it. So this exercises the real
## validator against every item in the game without ever putting one at risk.
##
## ItemBridge stays the single source of truth: descriptors are built by the
## same code the mod ships, never reimplemented in the harness. A harness that
## rebuilt the descriptor itself would validate the harness.
##
## Usage (via the wrapper script):
##   godot --headless --script res://tests/dump_descriptors.gd -- <catalog> <out>

const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: dump_descriptors.gd -- <catalog.json> <out.json>")
		quit(2)
		return

	var catalog_path := args[0]
	var out_path := args[1]

	var f := FileAccess.open(catalog_path, FileAccess.READ)
	if f == null:
		printerr("cannot read catalog: " + catalog_path)
		quit(2)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()

	if not parsed is Dictionary or not parsed.get("items") is Array:
		printerr("catalog is not shaped as expected")
		quit(2)
		return

	var cases := []
	var skipped := 0

	for entry in parsed["items"]:
		if not entry is Dictionary:
			continue
		# Furniture is flagged not tradeable server-side; sending it is a
		# guaranteed 422 and tells us nothing about serialisation. The locally
		# extracted catalog has no `tradeable` column, so class is the signal
		# here -- all 42 untradeable items are Furniture.
		if not bool(entry.get("tradeable", true)) or str(entry.get("class", "")) == "Furniture":
			skipped += 1
			continue

		var item := _item_from_catalog(entry)
		if item == null:
			skipped += 1
			continue

		for variant in _variants_for(item, entry):
			var slot: SlotData = variant["slot"]
			var reason: String = ItemBridge.rejection_reason(slot)
			if reason != "":
				# Refused locally on purpose. Recorded rather than dropped so
				# the report can show what the client declined to send and why.
				cases.append({
					"label": variant["label"],
					"item_key": str(item.file),
					"refused_locally": reason,
				})
				continue
			cases.append({
				"label": variant["label"],
				"item_key": str(item.file),
				"descriptor": ItemBridge.to_descriptor(slot),
			})

	var out := FileAccess.open(out_path, FileAccess.WRITE)
	if out == null:
		printerr("cannot write: " + out_path)
		quit(2)
		return
	out.store_string(JSON.stringify({"cases": cases}, "  "))
	out.close()

	print("built %d descriptor case(s), skipped %d untradeable item(s)" % [
		cases.size(), skipped])
	quit(0)


## Rebuild an ItemData from a catalog row. The extracted catalog carries the
## same fields the game's ItemData does, because it was generated from them.
func _item_from_catalog(entry: Dictionary) -> ItemData:
	var key := str(entry.get("item_key", ""))
	if key == "":
		return null
	var item := ItemData.new()
	item.file = key
	item.name = str(entry.get("display_name", key))
	item.type = str(entry.get("class", ""))
	item.subtype = str(entry.get("subclass", ""))
	item.stackable = bool(entry.get("stackable", false))
	item.showCondition = bool(entry.get("has_condition", false))
	item.capacity = float(entry.get("capacity", 0.0))
	item.maxAmount = int(entry.get("max_stack", 0))
	return item


## Per item, the awkward cases worth putting in front of the validator.
func _variants_for(item: ItemData, entry: Dictionary) -> Array:
	var variants := []

	var plain := SlotData.new()
	plain.itemData = item
	if bool(item.stackable):
		plain.amount = 1
	if ItemBridge.has_condition(item):
		plain.condition = 100.0
	variants.append({"label": "%s: plain" % item.file, "slot": plain})

	# Mid and boundary condition, where a 0-1 vs 0-100 scale error would show.
	if ItemBridge.has_condition(item):
		for value in [0.0, 62.5, 99.0]:
			var c := SlotData.new()
			c.itemData = item
			c.condition = value
			if bool(item.stackable):
				c.amount = 1
			variants.append({
				"label": "%s: condition %s" % [item.file, value], "slot": c})

	# A full stack and a partial one.
	if bool(item.stackable):
		var max_stack := int(entry.get("max_stack", 1))
		for amount in [max_stack, maxi(1, max_stack / 3)]:
			var s := SlotData.new()
			s.itemData = item
			s.amount = amount
			variants.append({
				"label": "%s: stack of %d" % [item.file, amount], "slot": s})

	# Weapons: every state field off its default, plus each legal attachment
	# fitted on its own so an illegal-attachment rejection names one culprit.
	if ItemBridge.is_weapon(item):
		var kitted := SlotData.new()
		kitted.itemData = item
		kitted.condition = 62.0
		kitted.mode = 2
		kitted.zoom = 3
		kitted.position = 0.02
		kitted.chamber = true
		variants.append({"label": "%s: full weapon state" % item.file, "slot": kitted})

		var jammed := SlotData.new()
		jammed.itemData = item
		jammed.condition = 20.0
		jammed.state = "Jammed"
		jammed.casing = true
		variants.append({"label": "%s: jammed" % item.file, "slot": jammed})

		var allowed = entry.get("allowed_attachments", [])
		if allowed is Array:
			for attachment_key in allowed:
				var a := SlotData.new()
				a.itemData = item
				a.condition = 90.0
				var attachment := ItemData.new()
				attachment.file = str(attachment_key)
				attachment.name = str(attachment_key)
				a.nested.append(attachment)
				variants.append({
					"label": "%s: + %s" % [item.file, attachment_key], "slot": a})

	return variants
