extends Control

## §8.1 screen 1 -- the browse feed.
##
## Renders exactly what `GET /v1/listings` returns. No sorting, filtering or
## price reasoning happens here: `category`, `q` and `sort` are query
## parameters the server acts on, so the list the player sees is the list the
## market produced.
##
## The market indicator is the point of this screen. A column of numbers is a
## price list; the same column with "is this dear or cheap" against it is a
## market. `unknown` renders as an absence, never as `at` -- "no idea" and "at
## the average" are different statements.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")

var _ui: Node = null
var _client: Node = null

var _search: LineEdit = null
var _category: OptionButton = null
var _sort: OptionButton = null
var _rows: VBoxContainer = null
var _summary: Label = null

var _categories := ["All"]
var _as_of := ""
var _loading := false

const SORTS := [
	{"id": "newest", "label": "Newest"},
	{"id": "price_asc", "label": "Price, low to high"},
	{"id": "price_desc", "label": "Price, high to low"},
	{"id": "condition_desc", "label": "Condition, best first"},
	{"id": "condition_asc", "label": "Condition, worst first"},
]


func setup(ui: Node, client: Node) -> void:
	_ui = ui
	_client = client


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	_load_categories()
	_refresh()


func _build() -> void:
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 8)
	add_child(column)

	# --- Controls ---
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)

	_search = LineEdit.new()
	_search.placeholder_text = "Search by name..."
	_search.custom_minimum_size = Vector2(240, 0)
	_search.add_theme_font_size_override("font_size", MarketTheme.FONT_BODY)
	_search.text_submitted.connect(func(_t): _refresh())
	controls.add_child(_search)

	_category = OptionButton.new()
	_category.focus_mode = Control.FOCUS_NONE
	_category.item_selected.connect(func(_i): _refresh())
	controls.add_child(_category)

	_sort = OptionButton.new()
	_sort.focus_mode = Control.FOCUS_NONE
	for entry in SORTS:
		_sort.add_item(entry["label"])
	_sort.item_selected.connect(func(_i): _refresh())
	controls.add_child(_sort)

	var refresh := MarketTheme.button("Refresh")
	refresh.pressed.connect(_refresh)
	controls.add_child(refresh)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(spacer)

	_summary = MarketTheme.label("", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM)
	controls.add_child(_summary)
	column.add_child(controls)

	column.add_child(_header_row())
	column.add_child(MarketTheme.rule())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 2)
	scroll.add_child(_rows)


func _header_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	for spec in [
		{"text": "ITEM", "width": 300},
		{"text": "COND.", "width": 90},
		{"text": "ASK", "width": 130},
		{"text": "", "width": 34},
		{"text": "SELLER", "width": 140},
		{"text": "EXPIRES", "width": 110},
	]:
		var l := MarketTheme.label(spec["text"], MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM)
		l.custom_minimum_size = Vector2(spec["width"], 0)
		row.add_child(l)
	return row


# --- Data ---

func _load_categories() -> void:
	# Categories come from the cached catalog rather than a dedicated call: the
	# browse filter's vocabulary is the catalog's `class` column.
	var main = _ui.main() if _ui != null and _ui.has_method("main") else null
	if main == null or not main.has_method("catalog"):
		return
	var catalog = main.catalog()
	if catalog == null or not catalog.is_loaded():
		return

	_categories = ["All"]
	for c in catalog.classes():
		_categories.append(str(c))
	_category.clear()
	for c in _categories:
		_category.add_item(c)


func _refresh() -> void:
	if _loading:
		return
	_loading = true
	_set_message("Loading...")
	_ui.set_status("fetching listings")

	var query := {}
	var text := _search.text.strip_edges()
	if text != "":
		query["q"] = text
	if _category.selected > 0 and _category.selected < _categories.size():
		query["category"] = _categories[_category.selected]
	var sort_index: int = _sort.selected if _sort.selected >= 0 else 0
	query["sort"] = SORTS[sort_index]["id"]

	var res: Dictionary = await _client.get_json("/listings", query)
	_loading = false

	if not res["ok"]:
		_render_failure(res)
		return

	var body = res["json"]
	if not body is Dictionary:
		_set_message("The market sent something this terminal could not read.")
		return

	_as_of = str(body.get("as_of", ""))
	_ui.set_offline(false)
	_ui.set_status("as of " + MarketTheme.staleness(_as_of))

	var listings = body.get("listings", [])
	_render(listings if listings is Array else [])


func _render_failure(res: Dictionary) -> void:
	var code := str(res.get("error", ""))
	if code == "offline":
		# Never a dead end: say what happened and what still works.
		_ui.set_offline(true, _as_of)
		_ui.set_status("offline")
		_set_message("Cannot reach the market.\n\n" +
			"The terminal will keep trying. Prices shown elsewhere are cached " +
			"and may be out of date.")
	elif code == "unauthorized":
		_ui.set_status("key rejected")
		_set_message("The market rejected this player key.\n\n" +
			"Open Setup and paste the key you were issued.")
	else:
		_ui.set_status("error")
		_set_message(str(res.get("message", "The market could not be reached.")))


func _render(listings: Array) -> void:
	for child in _rows.get_children():
		child.queue_free()

	if listings.is_empty():
		_summary.text = "0 listings"
		_set_message("Nothing matches that search.")
		return

	_summary.text = "%d listing%s  -  as of %s" % [
		listings.size(), "" if listings.size() == 1 else "s",
		MarketTheme.staleness(_as_of)]

	var index := 0
	for entry in listings:
		if entry is Dictionary:
			_rows.add_child(_listing_row(entry, index))
			index += 1


func _listing_row(entry: Dictionary, index: int) -> Control:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 34)
	button.add_theme_stylebox_override("normal",
		MarketTheme.panel(MarketTheme.PANEL if index % 2 == 0 else MarketTheme.PANEL_ALT))
	button.add_theme_stylebox_override("hover",
		MarketTheme.panel(MarketTheme.PANEL_ALT.lightened(0.10), 1))
	button.add_theme_stylebox_override("pressed", MarketTheme.panel(MarketTheme.PANEL))

	var listing_id := int(entry.get("listing_id", 0))
	button.pressed.connect(func(): _ui.open_detail(listing_id))

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)

	# Item, with its attachments named -- a scoped rifle and a bare one share an
	# item_key, and the difference is most of the price.
	var name_text := str(entry.get("display_name", entry.get("item_key", "?")))
	var attachments = entry.get("attachments", [])
	if attachments is Array and not attachments.is_empty():
		name_text += "  +%d" % attachments.size()
	row.add_child(_cell(name_text, 300, MarketTheme.TEXT))

	# Condition is 0-100 and only meaningful on items that carry it.
	var condition_text := "-"
	if entry.get("condition") != null:
		condition_text = "%d%%" % int(round(float(entry["condition"])))
	row.add_child(_cell(condition_text, 90, MarketTheme.TEXT_DIM))

	row.add_child(_cell(MarketTheme.money(entry.get("ask_price", 0)), 130, MarketTheme.TEXT))

	# The glyph that turns a price list into a market.
	var glyph: Array = MarketTheme.indicator_glyph(str(entry.get("market_indicator", "unknown")))
	var glyph_label := _cell(str(glyph[0]), 34, glyph[1])
	glyph_label.tooltip_text = str(glyph[2])
	row.add_child(glyph_label)

	var seller := str(entry.get("seller_callsign", "?"))
	var seller_colour := MarketTheme.ACCENT if bool(entry.get("broker", false)) else MarketTheme.TEXT_DIM
	row.add_child(_cell(seller, 140, seller_colour))

	row.add_child(_cell(_expires_in(str(entry.get("expires_at", ""))), 110, MarketTheme.TEXT_DIM))
	return button


func _cell(text: String, width: int, colour: Color) -> Label:
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, colour)
	l.custom_minimum_size = Vector2(width, 0)
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	return l


func _expires_in(iso: String) -> String:
	if iso == "":
		return "-"
	var at := Time.get_unix_time_from_datetime_string(iso)
	if at <= 0:
		return "-"
	var remaining := int(at) - int(Time.get_unix_time_from_system())
	if remaining <= 0:
		return "expired"
	return MarketTheme.duration(remaining)


func _set_message(text: String) -> void:
	for child in _rows.get_children():
		child.queue_free()
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(600, 0)
	_rows.add_child(l)
