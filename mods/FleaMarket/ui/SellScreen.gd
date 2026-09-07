extends Control

## §8.1 screen 3 -- sell.
##
## Pick from the stash, set an ask, and see the listing fee, the estimated
## commission and the **net proceeds before committing**. Nobody should discover
## a fee after the fact.
##
## Every one of those figures is quoted by the server on phase 1, which escrows
## nothing. So the player can look at a real quote for a real item and still
## walk away, having risked nothing: the phase-1 window simply lapses.
##
## The confirm step is the only place in this mod that destroys player property,
## so it is deliberately two clicks and states plainly what is about to happen.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")
const SellFlow := preload("res://mods/FleaMarket/SellFlow.gd")
const Stash := preload("res://mods/FleaMarket/Stash.gd")
const ItemBridge := preload("res://mods/FleaMarket/ItemBridge.gd")
const DeliveryService := preload("res://mods/FleaMarket/DeliveryService.gd")

var _ui: Node = null
var _client: Node = null
var _rows: VBoxContainer = null
var _panel: VBoxContainer = null

var _selected: Dictionary = {}
var _quote: Dictionary = {}
var _ask: SpinBox = null
var _busy := false


func setup(ui: Node, client: Node) -> void:
	_ui = ui
	_client = client


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	left.add_child(MarketTheme.label("YOUR STASH", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	left.add_child(MarketTheme.rule())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 2)
	scroll.add_child(_rows)
	left.add_child(scroll)
	row.add_child(left)

	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(420, 0)
	right.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL, 1))
	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", 8)
	right.add_child(_panel)
	row.add_child(right)

	_refresh_stash()
	_show_prompt()


# --- Stash ---

func _refresh_stash() -> void:
	for child in _rows.get_children():
		child.queue_free()

	var main = _ui.main() if _ui.has_method("main") else null
	var catalog = main.catalog() if main != null and main.has_method("catalog") else null
	var items: Array = Stash.sellable(get_tree(), catalog)

	if items.is_empty():
		_rows.add_child(MarketTheme.label(
			"Nothing in your inventory.\n\nCarry what you want to sell to the terminal.",
			MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
		return

	var index := 0
	for entry in items:
		_rows.add_child(_stash_row(entry, index))
		index += 1


func _stash_row(entry: Dictionary, index: int) -> Control:
	var slot: SlotData = entry["slot"]
	var can_sell := bool(entry["sellable"])

	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 32)
	button.disabled = not can_sell
	button.add_theme_stylebox_override("normal",
		MarketTheme.panel(MarketTheme.PANEL if index % 2 == 0 else MarketTheme.PANEL_ALT))
	button.add_theme_stylebox_override("hover",
		MarketTheme.panel(MarketTheme.PANEL_ALT.lightened(0.10), 1))
	button.add_theme_stylebox_override("disabled",
		MarketTheme.panel(MarketTheme.PANEL.darkened(0.15)))
	if can_sell:
		button.pressed.connect(func(): _select(entry))

	var line := HBoxContainer.new()
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	line.add_theme_constant_override("separation", 10)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(line)

	var name_text := str(slot.itemData.name)
	if slot.nested != null and not slot.nested.is_empty():
		name_text += "  +%d" % slot.nested.size()
	line.add_child(_cell(name_text, 260, MarketTheme.TEXT if can_sell else MarketTheme.TEXT_DIM))

	var condition_text := "-"
	if ItemBridge.has_condition(slot.itemData):
		condition_text = "%d%%" % int(round(float(slot.condition)))
	line.add_child(_cell(condition_text, 70, MarketTheme.TEXT_DIM))

	# The reason is shown rather than the item being hidden: "why can't I sell
	# this?" is a question the screen has to answer.
	if not can_sell:
		line.add_child(_cell(str(entry["reason"]), 380, MarketTheme.WARN))
	return button


func _cell(text: String, width: int, colour: Color) -> Label:
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, colour)
	l.custom_minimum_size = Vector2(width, 0)
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# --- Right-hand panel ---

func _clear_panel() -> void:
	for child in _panel.get_children():
		child.queue_free()


func _show_prompt() -> void:
	_clear_panel()
	_panel.add_child(MarketTheme.label("SELL", MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
	_panel.add_child(MarketTheme.label(
		"Pick something from your stash to see what the market will pay.",
		MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))

	var crate := DeliveryService.find_crate(get_tree())
	if crate == null:
		_panel.add_child(MarketTheme.rule())
		_panel.add_child(_wrapped(
			"You have no courier crate placed. Proceeds and returned goods "
			+ "arrive there, so place one from the decor menu before selling.",
			MarketTheme.WARN))


func _select(entry: Dictionary) -> void:
	_selected = entry
	_quote = {}
	_clear_panel()

	var slot: SlotData = entry["slot"]
	_panel.add_child(MarketTheme.label(str(slot.itemData.name),
		MarketTheme.FONT_HEAD, MarketTheme.ACCENT))

	var main = _ui.main() if _ui.has_method("main") else null
	var catalog = main.catalog() if main != null and main.has_method("catalog") else null
	var suggested := 100
	if catalog != null and catalog.is_loaded():
		var row: Dictionary = catalog.get_item(str(slot.itemData.file))
		suggested = maxi(1, int(row.get("base_value", 100)))
		_panel.add_child(_field("Catalog value", MarketTheme.money(suggested)))

	_panel.add_child(MarketTheme.rule())
	_panel.add_child(MarketTheme.label("YOUR ASK", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	_ask = SpinBox.new()
	_ask.min_value = 1
	_ask.max_value = 100000000
	_ask.step = 1
	_ask.value = suggested
	_ask.custom_minimum_size = Vector2(200, 0)
	_panel.add_child(_ask)

	var quote_button := MarketTheme.button("Get a quote")
	quote_button.pressed.connect(_get_quote)
	_panel.add_child(quote_button)

	_panel.add_child(_wrapped(
		"A quote costs nothing and takes nothing. The item stays in your "
		+ "inventory until you confirm.", MarketTheme.TEXT_DIM))


func _get_quote() -> void:
	if _busy or _selected.is_empty():
		return
	_busy = true

	var main = _ui.main() if _ui.has_method("main") else null
	var catalog = main.catalog() if main != null and main.has_method("catalog") else null
	var ledger = main.ledger() if main != null and main.has_method("ledger") else null
	if ledger == null:
		_busy = false
		return

	# The escrow guard. A catalog this client has not validated against means a
	# game patch may have moved item keys, and a wrong key round-trips a rifle
	# as the wrong thing.
	var block: String = catalog.escrow_block_reason() if catalog != null else "No catalog."
	if block != "":
		_clear_panel()
		_panel.add_child(MarketTheme.label("CANNOT SELL", MarketTheme.FONT_HEAD, MarketTheme.DANGER))
		_panel.add_child(_wrapped(block, MarketTheme.WARN))
		_busy = false
		return

	var ask := int(_ask.value)
	_clear_panel()
	_panel.add_child(MarketTheme.label("Asking the market...",
		MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))

	var q: Dictionary = await SellFlow.quote(
		_client, ledger, _selected["slot"], ask, catalog.catalog_version)
	_busy = false

	if not q["ok"]:
		_clear_panel()
		_panel.add_child(MarketTheme.label("REFUSED", MarketTheme.FONT_HEAD, MarketTheme.DANGER))
		_panel.add_child(_wrapped(str(q["message"]), MarketTheme.WARN))
		var back := MarketTheme.button("Back")
		back.pressed.connect(func(): _select(_selected))
		_panel.add_child(back)
		return

	_quote = q
	_show_quote(q)


func _show_quote(q: Dictionary) -> void:
	_clear_panel()
	var slot: SlotData = _selected["slot"]

	_panel.add_child(MarketTheme.label(str(slot.itemData.name),
		MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
	_panel.add_child(MarketTheme.rule())

	_panel.add_child(_field("Your ask", MarketTheme.money(q["ask_price"])))
	_panel.add_child(_field("Listing fee", "-" + MarketTheme.money(q["listing_fee"])))
	_panel.add_child(_field("Commission if it sells",
		"-" + MarketTheme.money(q["estimated_commission"])))
	_panel.add_child(MarketTheme.rule())

	var net := HBoxContainer.new()
	net.add_theme_constant_override("separation", 10)
	var nl := MarketTheme.label("You receive", MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	nl.custom_minimum_size = Vector2(160, 0)
	net.add_child(nl)
	net.add_child(MarketTheme.label(MarketTheme.money(q["estimated_net_proceeds"]),
		MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
	_panel.add_child(net)

	_panel.add_child(_wrapped(
		"The listing fee is charged now and is NOT refunded if the item does "
		+ "not sell. Proceeds arrive as cash in your courier crate.",
		MarketTheme.TEXT_DIM))

	var fee := int(q["listing_fee"])
	var cash := Stash.cash_on_hand()
	if cash < fee:
		_panel.add_child(_wrapped(
			"You are carrying %s. The fee needs %s." % [
				MarketTheme.money(cash), MarketTheme.money(fee)], MarketTheme.DANGER))
		return

	_panel.add_child(MarketTheme.rule())
	_panel.add_child(_wrapped(
		"Confirming destroys the item and %s in cash from your inventory."
		% MarketTheme.money(fee), MarketTheme.WARN))

	var confirm := MarketTheme.button("Confirm and list")
	confirm.custom_minimum_size = Vector2(0, 38)
	confirm.pressed.connect(_commit)
	_panel.add_child(confirm)

	var cancel := MarketTheme.button("Cancel")
	cancel.pressed.connect(func(): _select(_selected))
	_panel.add_child(cancel)


func _commit() -> void:
	if _busy or _quote.is_empty():
		return
	_busy = true

	var main = _ui.main() if _ui.has_method("main") else null
	var ledger = main.ledger() if main != null and main.has_method("ledger") else null
	if ledger == null:
		_busy = false
		return

	_clear_panel()
	_panel.add_child(MarketTheme.label("Listing...", MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))

	var r: Dictionary = await SellFlow.commit(
		get_tree(), _client, ledger, str(_quote["op_id"]), _selected["element"])
	_busy = false

	_clear_panel()
	# The outcome is read from the flow, never inferred from success. A lapsed
	# window returns HTTP 200 and is NOT a sale.
	match str(r.get("outcome", "")):
		SellFlow.OUTCOME_LISTED:
			_panel.add_child(MarketTheme.label("LISTED", MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
			_panel.add_child(_wrapped(
				"Your item is on the market. Proceeds arrive in the courier "
				+ "crate when it sells.", MarketTheme.TEXT))
		SellFlow.OUTCOME_RETURNED:
			_panel.add_child(MarketTheme.label("NOT LISTED", MarketTheme.FONT_HEAD, MarketTheme.WARN))
			_panel.add_child(_wrapped(str(r.get("message", "")), MarketTheme.WARN))
			_panel.add_child(_wrapped(
				"Nothing was sold and the fee was refunded. The item is coming "
				+ "back to your courier crate.", MarketTheme.TEXT_DIM))
		SellFlow.OUTCOME_INTERRUPTED:
			_panel.add_child(MarketTheme.label("UNFINISHED", MarketTheme.FONT_HEAD, MarketTheme.WARN))
			_panel.add_child(_wrapped(str(r.get("message", "")), MarketTheme.WARN))
		_:
			_panel.add_child(MarketTheme.label("REFUSED", MarketTheme.FONT_HEAD, MarketTheme.DANGER))
			_panel.add_child(_wrapped(str(r.get("message", "")), MarketTheme.WARN))

	var done := MarketTheme.button("Done")
	done.pressed.connect(func():
		_selected = {}
		_quote = {}
		_refresh_stash()
		_show_prompt())
	_panel.add_child(done)

	_refresh_stash()


# --- Helpers ---

func _field(label: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := MarketTheme.label(label, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	row.add_child(MarketTheme.label(value, MarketTheme.FONT_BODY, MarketTheme.TEXT))
	return row


func _wrapped(text: String, colour: Color) -> Label:
	var l := MarketTheme.label(text, MarketTheme.FONT_SMALL, colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(380, 0)
	return l
