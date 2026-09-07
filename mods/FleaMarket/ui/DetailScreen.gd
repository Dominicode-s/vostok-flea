extends Control

## §8.1 screen 2 -- item detail.
##
## Price history, last five sales, broker bid/ask, delivery fee and ETA, and
## the all-in total. Everything the player needs BEFORE committing.
##
## Every figure here is quoted by the server. `quote.total` is not
## `price + delivery_fee` computed locally even though it happens to equal it
## today: the moment this terminal starts deriving a price, retuning the economy
## stops being a server config change and starts needing a mod update.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")

var listing_id := 0

var _ui: Node = null
var _client: Node = null
var _body: VBoxContainer = null


func setup(ui: Node, client: Node) -> void:
	_ui = ui
	_client = client


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	scroll.add_child(_body)

	_load()


func _load() -> void:
	_message("Loading...")
	var res: Dictionary = await _client.get_json("/listings/%d" % listing_id)

	if not res["ok"]:
		if str(res.get("error")) == "offline":
			_ui.set_offline(true)
			_message("Cannot reach the market. This item's details are not cached.")
		else:
			_message(str(res.get("message", "Could not load this listing.")))
		return

	var body = res["json"]
	if not body is Dictionary:
		_message("The market sent something this terminal could not read.")
		return

	_render(body)


func _render(body: Dictionary) -> void:
	for child in _body.get_children():
		child.queue_free()

	var listing: Dictionary = body.get("listing", {}) if body.get("listing") is Dictionary else {}
	var quote: Dictionary = body.get("quote", {}) if body.get("quote") is Dictionary else {}
	var stats: Dictionary = body.get("stats", {}) if body.get("stats") is Dictionary else {}
	var item: Dictionary = listing.get("item", {}) if listing.get("item") is Dictionary else {}

	_body.add_child(_header(listing, body))
	_body.add_child(MarketTheme.rule())
	_body.add_child(_two_columns(_item_panel(listing, item), _price_panel(quote, listing)))
	_body.add_child(_stats_panel(stats))
	_body.add_child(_buy_panel(quote))


func _header(listing: Dictionary, body: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var back := MarketTheme.button("< Back")
	back.pressed.connect(func(): _ui.back_to_browse())
	row.add_child(back)

	var title := MarketTheme.label(
		str(listing.get("display_name", "?")), MarketTheme.FONT_HEAD, MarketTheme.ACCENT)
	row.add_child(title)

	var glyph: Array = MarketTheme.indicator_glyph(str(body.get("market_indicator", "unknown")))
	var g := MarketTheme.label(str(glyph[0]) + " " + str(glyph[2]), MarketTheme.FONT_SMALL, glyph[1])
	row.add_child(g)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	return row


func _two_columns(left: Control, right: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	row.add_child(right)
	return row


func _item_panel(listing: Dictionary, item: Dictionary) -> Control:
	var panel := _section("THE ITEM")
	var box: VBoxContainer = panel.get_meta("body")

	box.add_child(_field("Category", str(listing.get("category", "-"))))

	if item.get("condition") != null:
		box.add_child(_field("Condition", "%d%%" % int(round(float(item["condition"])))))

	# `amount` is overloaded exactly as it is in the game, so the row is only
	# meaningful when the item actually carries one.
	var amount := int(item.get("amount", 0))
	if amount > 0:
		box.add_child(_field("Rounds / stack", str(amount)))

	var attachments = item.get("attachments", [])
	if attachments is Array and not attachments.is_empty():
		box.add_child(_field("Attachments", ", ".join(PackedStringArray(attachments))))

	if item.get("mode") != null:
		box.add_child(_field("Fire mode", "Auto" if int(item["mode"]) == 2 else "Semi"))
	if item.get("zoom") != null:
		box.add_child(_field("Optic zoom", "%dx" % int(item["zoom"])))
	if bool(item.get("chamber", false)):
		box.add_child(_field("Chamber", "Loaded"))

	var state := str(item.get("state", ""))
	if state != "":
		# Damage the player is buying, called out rather than buried: a jammed
		# weapon arrives jammed.
		var l := MarketTheme.label("Condition flag: " + state, MarketTheme.FONT_BODY, MarketTheme.DANGER)
		box.add_child(l)

	box.add_child(_field("Seller", str(listing.get("seller_callsign", "-"))))
	if bool(listing.get("broker", false)):
		box.add_child(MarketTheme.label(
			"Sold by the market broker.", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	return panel


func _price_panel(quote: Dictionary, listing: Dictionary) -> Control:
	var panel := _section("PRICE")
	var box: VBoxContainer = panel.get_meta("body")

	box.add_child(_field("Ask", MarketTheme.money(quote.get("price", listing.get("ask_price", 0)))))
	box.add_child(_field("Delivery fee", MarketTheme.money(quote.get("delivery_fee", 0))))
	box.add_child(MarketTheme.rule())

	var total := _big_field("You pay", MarketTheme.money(quote.get("total", 0)))
	box.add_child(total)
	box.add_child(MarketTheme.label(
		"Cash you must be carrying at the terminal.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	if quote.get("eta_seconds") != null:
		box.add_child(_field("Arrives in", MarketTheme.duration(quote["eta_seconds"])))
		box.add_child(MarketTheme.label(
			"Real time, counted by the market. It keeps running while you play.",
			MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	if quote.get("intrinsic_value") != null:
		box.add_child(_field("Intrinsic value", MarketTheme.money(quote["intrinsic_value"])))
	return panel


func _stats_panel(stats: Dictionary) -> Control:
	var panel := _section("PRICE HISTORY")
	var box: VBoxContainer = panel.get_meta("body")

	if stats.is_empty():
		box.add_child(MarketTheme.label("No market data for this item.",
			MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
		return panel

	var average = stats.get("average_7d")
	box.add_child(_field("7-day average",
		MarketTheme.money(average) if average != null else "no trades yet"))

	var volume = stats.get("volume_24h")
	if volume is Dictionary:
		box.add_child(_field("24-hour volume", "%d trade%s, %s" % [
			int(volume.get("trades", 0)),
			"" if int(volume.get("trades", 0)) == 1 else "s",
			MarketTheme.money(volume.get("value", 0))]))

	var broker = stats.get("broker")
	if broker is Dictionary:
		box.add_child(_field("Broker buys at", MarketTheme.money(broker.get("bid", 0))))
		box.add_child(_field("Broker sells at", MarketTheme.money(broker.get("ask", 0))))
	else:
		box.add_child(MarketTheme.label(
			"The broker does not deal in this item.",
			MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	box.add_child(MarketTheme.rule())
	var sales = stats.get("recent_sales", [])
	if sales is Array and not sales.is_empty():
		box.add_child(MarketTheme.label("Recent sales", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
		for sale in sales:
			if not sale is Dictionary:
				continue
			var condition_text := ""
			if sale.get("condition") != null:
				condition_text = "  at %d%%" % int(round(float(sale["condition"])))
			box.add_child(MarketTheme.label(
				"%s%s   %s" % [
					MarketTheme.money(sale.get("price", 0)), condition_text,
					_ago(str(sale.get("traded_at", "")))],
				MarketTheme.FONT_BODY, MarketTheme.TEXT))
	else:
		box.add_child(MarketTheme.label("Nothing has sold yet.",
			MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
	return panel


## Buying is M4. The control is shown disabled with the reason stated, rather
## than hidden: §8.3's point is that a greyed control which explains itself is
## worth a great deal of goodwill, and hiding it would leave the player
## wondering whether the terminal works at all.
func _buy_panel(_quote: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var buy := MarketTheme.button("Buy", false)
	buy.custom_minimum_size = Vector2(160, 38)
	row.add_child(buy)

	var reason := "Buying arrives in a later update. This terminal is read-only for now."
	if not _ui.is_online():
		reason = "Buying is disabled while the market is unreachable."
	row.add_child(MarketTheme.label(reason, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
	return row


# --- Building blocks ---

func _section(title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL, 1))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.add_child(MarketTheme.label(title, MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	box.add_child(MarketTheme.rule())
	panel.add_child(box)
	panel.set_meta("body", box)
	return panel


func _field(label: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := MarketTheme.label(label, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	row.add_child(MarketTheme.label(value, MarketTheme.FONT_BODY, MarketTheme.TEXT))
	return row


func _big_field(label: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := MarketTheme.label(label, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	row.add_child(MarketTheme.label(value, MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
	return row


func _ago(iso: String) -> String:
	if iso == "":
		return ""
	var at := Time.get_unix_time_from_datetime_string(iso)
	if at <= 0:
		return ""
	var age := int(Time.get_unix_time_from_system()) - int(at)
	if age < 60:
		return "just now"
	if age < 3600:
		return "%dm ago" % (age / 60)
	if age < 86400:
		return "%dh ago" % (age / 3600)
	return "%dd ago" % (age / 86400)


func _message(text: String) -> void:
	for child in _body.get_children():
		child.queue_free()
	var back := MarketTheme.button("< Back")
	back.pressed.connect(func(): _ui.back_to_browse())
	_body.add_child(back)
	_body.add_child(MarketTheme.label(text, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
