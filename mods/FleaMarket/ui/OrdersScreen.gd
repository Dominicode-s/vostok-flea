extends Control

## §8.1 screen 5 -- my orders.
##
## Inbound deliveries with live countdowns, and what is waiting on the van.
##
## Countdowns use the server's `seconds_remaining`, decremented locally between
## refreshes. The server clock is the authority precisely so a countdown
## survives a session: quitting and coming back does not reset the wait, and a
## client-side timer would drift or restart.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")

## Deliveries are the only thing on this screen that moves, and they move
## slowly. Polling every 20s is plenty and stays far inside the read limit.
const REFRESH_SECONDS := 20.0

var _ui: Node = null
var _client: Node = null
var _body: VBoxContainer = null
var _countdowns := []
var _tick := 0.0


func setup(ui: Node, client: Node) -> void:
	_ui = ui
	_client = client


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	set_process(true)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	scroll.add_child(_body)

	_load()


func _process(delta: float) -> void:
	# Local decrement between refreshes so the numbers move, re-anchored to the
	# server clock on every poll.
	for entry in _countdowns:
		var label: Label = entry["label"]
		if not is_instance_valid(label):
			continue
		entry["remaining"] = max(0.0, float(entry["remaining"]) - delta)
		label.text = _delivery_when(float(entry["remaining"]))

	_tick += delta
	if _tick >= REFRESH_SECONDS:
		_tick = 0.0
		_load()


func _load() -> void:
	var res: Dictionary = await _client.get_json("/deliveries")
	if not res["ok"]:
		if str(res.get("error")) == "offline":
			_ui.set_offline(true)
			_message("Cannot reach the market, so inbound deliveries cannot be checked.\n\n" +
				"Nothing is lost: deliveries wait on the server and will still be " +
				"here when the connection comes back.")
		elif str(res.get("error")) == "unauthorized":
			_message("The market rejected this player key. Open Setup to paste a new one.")
		else:
			_message(str(res.get("message", "Could not load deliveries.")))
		return

	var body = res["json"]
	if not body is Dictionary:
		_message("The market sent something this terminal could not read.")
		return
	_render(body.get("deliveries", []))


func _render(deliveries) -> void:
	for child in _body.get_children():
		child.queue_free()
	_countdowns.clear()

	if not deliveries is Array or deliveries.is_empty():
		_message("Nothing inbound.\n\n" +
			"Purchases and sale proceeds arrive here, then appear in the courier " +
			"crate in your shelter.")
		return

	var ready_count := 0
	for entry in deliveries:
		if entry is Dictionary and bool(entry.get("ready", false)):
			ready_count += 1

	_body.add_child(MarketTheme.label(
		"INBOUND  -  %d delivery(s), %d ready" % [deliveries.size(), ready_count],
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.rule())

	for entry in deliveries:
		if entry is Dictionary:
			_body.add_child(_delivery_row(entry))

	_body.add_child(MarketTheme.rule())
	_body.add_child(MarketTheme.label(
		"Deliveries are collected into the courier crate, which arrives with " +
		"selling in a later update. Nothing expires while you wait.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))


func _delivery_row(entry: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL, 1))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var kind := str(entry.get("kind", ""))
	var description := ""
	if kind == "cash":
		description = "%s in cash" % MarketTheme.money(entry.get("cash_amount", 0))
	else:
		var item = entry.get("item")
		if item is Dictionary:
			description = str(item.get("item_key", "item"))
			if item.get("condition") != null:
				description += "  %d%%" % int(round(float(item["condition"])))
			var state := str(item.get("state", ""))
			if state != "":
				description += "  (%s)" % state
		else:
			description = "item"

	var name_label := MarketTheme.label(description, MarketTheme.FONT_BODY, MarketTheme.TEXT)
	name_label.custom_minimum_size = Vector2(300, 0)
	row.add_child(name_label)

	row.add_child(_reason_label(str(entry.get("reason", ""))))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var remaining := float(entry.get("seconds_remaining", 0))
	var when := MarketTheme.label(_delivery_when(remaining), MarketTheme.FONT_BODY,
		MarketTheme.ACCENT if bool(entry.get("ready", false)) else MarketTheme.WARN)
	when.custom_minimum_size = Vector2(130, 0)
	row.add_child(when)

	if not bool(entry.get("ready", false)):
		_countdowns.append({"label": when, "remaining": remaining})
	return panel


func _reason_label(reason: String) -> Label:
	var text := reason.replace("_", " ")
	match reason:
		"purchase":
			text = "purchase"
		"broker_sale_proceeds":
			text = "broker sale"
		"listing_expired":
			text = "listing expired, item returned"
		"credit_note":
			text = "refund"
	var l := MarketTheme.label(text, MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(220, 0)
	return l


func _delivery_when(remaining: float) -> String:
	if remaining <= 0.0:
		return "ready"
	return "in " + MarketTheme.duration(remaining)


func _message(text: String) -> void:
	for child in _body.get_children():
		child.queue_free()
	_countdowns.clear()
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(620, 0)
	_body.add_child(l)
