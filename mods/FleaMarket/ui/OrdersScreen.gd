extends Control

## §8.1 screen 5 -- my orders.
##
## Two things the player needs to see about their own trading: what is still
## standing on the market, and what is on its way to the crate.
##
## Countdowns use the server's `seconds_remaining`, decremented locally between
## refreshes. The server clock is the authority precisely so a countdown
## survives a session: quitting and coming back does not reset the wait, and a
## purely client-side timer would drift or restart.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")
const DeliveryService := preload("res://mods/FleaMarket/DeliveryService.gd")

## Deliveries are the only thing here that moves, and they move slowly. Polling
## every 20s is plenty and stays far inside the read limit.
const REFRESH_SECONDS := 20.0

var _ui: Node = null
var _client: Node = null
var _body: VBoxContainer = null
var _countdowns := []
var _tick := 0.0
var _busy := false


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
	if _busy:
		return
	_busy = true

	var listings: Array = []
	var listings_error := ""
	# `mine=true` rather than filtering the browse feed by callsign: on a paged
	# feed the player's own listing may simply not be on the page fetched.
	var lres: Dictionary = await _client.get_json("/listings", {"mine": "true"})
	if lres["ok"] and lres["json"] is Dictionary:
		var rows = lres["json"].get("listings", [])
		if rows is Array:
			listings = rows
	else:
		listings_error = str(lres.get("message", lres.get("error", "")))

	var deliveries: Array = []
	var deliveries_error := ""
	var dres: Dictionary = await _client.get_json("/deliveries")
	if dres["ok"] and dres["json"] is Dictionary:
		var rows = dres["json"].get("deliveries", [])
		if rows is Array:
			deliveries = rows
	else:
		deliveries_error = str(dres.get("message", dres.get("error", "")))

	_busy = false

	if listings_error != "" and deliveries_error != "":
		if str(lres.get("error")) == "offline":
			_ui.set_offline(true)
			_message("Cannot reach the market.\n\n"
				+ "Nothing is lost: your listings and deliveries are held "
				+ "server-side and will still be here when the connection "
				+ "comes back.")
		else:
			_message(listings_error)
		return

	_render(listings, deliveries)


func _render(listings: Array, deliveries: Array) -> void:
	for child in _body.get_children():
		child.queue_free()
	_countdowns.clear()

	# --- Standing listings ---
	_body.add_child(MarketTheme.label(
		"ON THE MARKET  -  %d listing%s" % [listings.size(), "" if listings.size() == 1 else "s"],
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.rule())

	if listings.is_empty():
		_body.add_child(MarketTheme.label(
			"Nothing listed. Sell something from the Sell tab.",
			MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
	else:
		for entry in listings:
			if entry is Dictionary:
				_body.add_child(_listing_row(entry))

	# --- Inbound ---
	var ready_count := 0
	for entry in deliveries:
		if entry is Dictionary and bool(entry.get("ready", false)):
			ready_count += 1

	_body.add_child(MarketTheme.label(" ", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.label(
		"INBOUND  -  %d delivery(s), %d ready" % [deliveries.size(), ready_count],
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.rule())

	if deliveries.is_empty():
		_body.add_child(MarketTheme.label(
			"Nothing inbound. Purchases and sale proceeds arrive here, then "
			+ "appear in the courier crate in your shelter.",
			MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
	else:
		for entry in deliveries:
			if entry is Dictionary:
				_body.add_child(_delivery_row(entry))

	if DeliveryService.find_crate(get_tree()) == null and not deliveries.is_empty():
		_body.add_child(MarketTheme.label(
			"You have no courier crate placed. Deliveries wait on the van "
			+ "until you place one from the decor menu.",
			MarketTheme.FONT_SMALL, MarketTheme.WARN))


func _listing_row(entry: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL, 1))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var name_text := str(entry.get("display_name", entry.get("item_key", "?")))
	if entry.get("condition") != null:
		name_text += "  %d%%" % int(round(float(entry["condition"])))
	var name_label := MarketTheme.label(name_text, MarketTheme.FONT_BODY, MarketTheme.TEXT)
	name_label.custom_minimum_size = Vector2(280, 0)
	row.add_child(name_label)

	var ask := MarketTheme.label(MarketTheme.money(entry.get("ask_price", 0)),
		MarketTheme.FONT_BODY, MarketTheme.ACCENT)
	ask.custom_minimum_size = Vector2(120, 0)
	row.add_child(ask)

	var glyph: Array = MarketTheme.indicator_glyph(str(entry.get("market_indicator", "unknown")))
	var g := MarketTheme.label(str(glyph[0]), MarketTheme.FONT_BODY, glyph[1])
	g.tooltip_text = str(glyph[2])
	g.custom_minimum_size = Vector2(30, 0)
	row.add_child(g)

	var expires := MarketTheme.label(_expires_in(str(entry.get("expires_at", ""))),
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM)
	expires.custom_minimum_size = Vector2(120, 0)
	row.add_child(expires)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# Cancelling destroys nothing client-side: the server unwinds the escrow and
	# schedules the item back to the crate as an ordinary delivery. It is one of
	# the few mutating calls with no ordering hazard at all.
	var listing_id := int(entry.get("listing_id", 0))
	var cancel := MarketTheme.button("Cancel")
	cancel.pressed.connect(func(): _cancel(listing_id))
	row.add_child(cancel)
	return panel


func _cancel(listing_id: int) -> void:
	if _busy:
		return
	_busy = true
	var res: Dictionary = await _client.request_json(
		"DELETE", "/listings/%d" % listing_id, _client.new_idempotency_key())
	_busy = false

	if not res["ok"]:
		_ui.set_status(str(res.get("message", "could not cancel")))
		return
	# The fee is NOT refunded on a cancel (§7.2); the item comes back as a
	# delivery. Reloading shows both facts rather than asserting them.
	_load()


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
	name_label.custom_minimum_size = Vector2(280, 0)
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
		"pending_listing_lapsed":
			text = "listing window lapsed, item returned"
		"listing_cancelled":
			text = "you cancelled this listing"
		"credit_note":
			text = "refund"
	var l := MarketTheme.label(text, MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(240, 0)
	return l


func _delivery_when(remaining: float) -> String:
	if remaining <= 0.0:
		return "ready"
	return "in " + MarketTheme.duration(remaining)


func _expires_in(iso: String) -> String:
	if iso == "":
		return ""
	var at := Time.get_unix_time_from_datetime_string(iso)
	if at <= 0:
		return ""
	var remaining := int(at) - int(Time.get_unix_time_from_system())
	if remaining <= 0:
		return "expired"
	return "expires in " + MarketTheme.duration(remaining)


func _message(text: String) -> void:
	for child in _body.get_children():
		child.queue_free()
	_countdowns.clear()
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(620, 0)
	_body.add_child(l)
