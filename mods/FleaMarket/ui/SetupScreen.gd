extends Control

## Player key entry, plus a connection readout.
##
## Identity is one server-issued key pasted in once (§2). No account, no email,
## no personal data -- the market knows a key hash and a callsign and nothing
## else, and this screen should not imply otherwise.
##
## The key is verified by making a real authenticated call rather than by
## checking its shape. A key that looks right and is refused is exactly the
## failure this screen exists to diagnose, and it is what actually happened
## during development: the key in the handoff notes was well-formed and stale.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")

var _ui: Node = null
var _client: Node = null
var _field: LineEdit = null
var _result: Label = null
var _diagnostics: VBoxContainer = null


func setup(ui: Node, client: Node) -> void:
	_ui = ui
	_client = client


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var body := VBoxContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 10)
	add_child(body)

	body.add_child(MarketTheme.label("PLAYER KEY", MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
	body.add_child(MarketTheme.label(
		"Paste the key you were issued. It identifies you to the market and " +
		"nothing else -- there is no account and no personal data.",
		MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_field = LineEdit.new()
	_field.placeholder_text = "rtv_..."
	_field.custom_minimum_size = Vector2(460, 0)
	_field.add_theme_font_size_override("font_size", MarketTheme.FONT_BODY)
	# Masked by default: the key is a bearer credential and players stream.
	_field.secret = true
	if _client != null and _client.has_key():
		_field.text = _client.player_key
	row.add_child(_field)

	var reveal := MarketTheme.button("Show")
	reveal.toggle_mode = true
	reveal.toggled.connect(func(on: bool):
		_field.secret = not on
		reveal.text = "Hide" if on else "Show")
	row.add_child(reveal)

	var save := MarketTheme.button("Save and test")
	save.pressed.connect(_save)
	row.add_child(save)
	body.add_child(row)

	_result = MarketTheme.label("", MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.custom_minimum_size = Vector2(640, 0)
	body.add_child(_result)

	body.add_child(MarketTheme.rule())
	body.add_child(MarketTheme.label("CONNECTION", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_diagnostics = VBoxContainer.new()
	_diagnostics.add_theme_constant_override("separation", 4)
	body.add_child(_diagnostics)

	_refresh_diagnostics()
	if _client != null and not _client.has_key():
		_result.text = "No key saved yet. Browsing needs one."


func _save() -> void:
	var key := _field.text.strip_edges()
	if key == "":
		_result.add_theme_color_override("font_color", MarketTheme.DANGER)
		_result.text = "Enter a key first."
		return

	var main = _ui.main() if _ui.has_method("main") else null
	if main != null and main.has_method("save_player_key"):
		main.save_player_key(key)

	_result.add_theme_color_override("font_color", MarketTheme.TEXT_DIM)
	_result.text = "Checking with the market..."

	# A real authenticated call. /wallet is the cheapest endpoint that actually
	# requires the key -- /ping and /catalog do not, so a 200 from either would
	# prove nothing about whether this key works.
	var res: Dictionary = await _client.get_json("/wallet")

	if res["ok"]:
		var body = res["json"]
		var callsign := "?"
		if body is Dictionary:
			callsign = str(body.get("callsign", "?"))
		_result.add_theme_color_override("font_color", MarketTheme.ACCENT)
		_result.text = "Key accepted. You are trading as %s." % callsign
	elif str(res.get("error")) == "unauthorized":
		_result.add_theme_color_override("font_color", MarketTheme.DANGER)
		_result.text = ("The market rejected that key. It was saved anyway so you "
			+ "can correct a typo, but nothing will load until a valid key is entered.")
	elif str(res.get("error")) == "offline":
		_result.add_theme_color_override("font_color", MarketTheme.WARN)
		_result.text = ("Saved, but the market is unreachable so the key could not "
			+ "be checked. It will be tested on the next connection.")
	else:
		_result.add_theme_color_override("font_color", MarketTheme.WARN)
		_result.text = str(res.get("message", "Could not check the key."))

	_refresh_diagnostics()


func _refresh_diagnostics() -> void:
	for child in _diagnostics.get_children():
		child.queue_free()

	var main = _ui.main() if _ui.has_method("main") else null
	var catalog = main.catalog() if main != null and main.has_method("catalog") else null

	_diagnostics.add_child(_row("Market",
		"reachable" if _ui.is_online() else "unreachable",
		MarketTheme.ACCENT if _ui.is_online() else MarketTheme.DANGER))

	_diagnostics.add_child(_row("Key",
		"saved" if (_client != null and _client.has_key()) else "not set",
		MarketTheme.TEXT if (_client != null and _client.has_key()) else MarketTheme.WARN))

	if catalog != null and catalog.is_loaded():
		_diagnostics.add_child(_row("Item catalog",
			"v%d, %d items" % [catalog.catalog_version, catalog.count()], MarketTheme.TEXT))

		# The escrow guard, surfaced. It only bites when trading starts, but a
		# mismatch is worth showing before the player discovers it mid-sale.
		var block: String = catalog.escrow_block_reason()
		if block == "":
			_diagnostics.add_child(_row("Trading", "catalog matches this mod", MarketTheme.TEXT))
		else:
			_diagnostics.add_child(_row("Trading", block, MarketTheme.DANGER))
	else:
		_diagnostics.add_child(_row("Item catalog", "not loaded", MarketTheme.WARN))


func _row(label: String, value: String, colour: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := MarketTheme.label(label, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(140, 0)
	row.add_child(l)
	var v := MarketTheme.label(value, MarketTheme.FONT_BODY, colour)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.custom_minimum_size = Vector2(500, 0)
	row.add_child(v)
	return row
