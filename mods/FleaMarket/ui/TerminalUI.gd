extends CanvasLayer

## The terminal shell: header, navigation, offline banner, screen switching.
##
## **This is a renderer.** It holds no market logic, computes no prices, and
## decides nothing about what a trade is worth. Every number it shows arrives
## from the server already computed -- fees, totals, ETAs, the market indicator.
## If a calculation ever appears in this directory, the design has been broken.
##
## Opening and closing goes through the game's own UIManager so the terminal
## behaves like a native screen: the player freezes, the mouse is released, and
## the HUD hides, exactly as a container or trader does.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")
const BrowseScreen := preload("res://mods/FleaMarket/ui/BrowseScreen.gd")
const DetailScreen := preload("res://mods/FleaMarket/ui/DetailScreen.gd")
const OrdersScreen := preload("res://mods/FleaMarket/ui/OrdersScreen.gd")
const WalletScreen := preload("res://mods/FleaMarket/ui/WalletScreen.gd")
const SetupScreen := preload("res://mods/FleaMarket/ui/SetupScreen.gd")

signal closed

var _main: Node = null
var _client: Node = null

var _ui_manager: Node = null
var _root: Control = null
var _content: Control = null
var _banner: PanelContainer = null
var _banner_label: Label = null
var _status_label: Label = null
var _nav_buttons := {}
var _current := ""
var _screen: Control = null


func setup(main: Node, client: Node) -> void:
	_main = main
	_client = client


func _ready() -> void:
	layer = 100
	_build()
	_open_game_ui()

	if _client != null and _client.has_signal("online_changed"):
		_client.online_changed.connect(_on_online_changed)

	# A player with no key cannot browse at all, so send them straight to the
	# screen that fixes that rather than to an empty feed with a 401 behind it.
	if _client != null and not _client.has_key():
		_show("setup")
	else:
		_show("browse")


# --- Shell ---

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.color = MarketTheme.BG
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(backdrop)

	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		frame.add_theme_constant_override("margin_" + side, 48)
	_root.add_child(frame)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	frame.add_child(column)

	column.add_child(_build_header())
	column.add_child(_build_banner())
	column.add_child(_build_nav())
	column.add_child(MarketTheme.rule())

	_content = MarginContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_content)

	column.add_child(MarketTheme.rule())
	column.add_child(_build_footer())


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var title := MarketTheme.label("VOSTOK FLEA MARKET", MarketTheme.FONT_TITLE, MarketTheme.ACCENT)
	row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_status_label = MarketTheme.label("", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM)
	row.add_child(_status_label)
	return row


## §8.3: offline is a designed state, not an error path.
func _build_banner() -> Control:
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL_ALT, 1))
	_banner_label = MarketTheme.label("", MarketTheme.FONT_BODY, MarketTheme.WARN)
	_banner.add_child(_banner_label)
	_banner.hide()
	return _banner


func _build_nav() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	# Wanted ads (§8.1 screen 4) are absent on purpose: there are no endpoints
	# for them, so a tab would be a promise the server cannot keep.
	for entry in [
		{"id": "browse", "label": "Browse"},
		{"id": "orders", "label": "My Orders"},
		{"id": "wallet", "label": "Wallet"},
		{"id": "setup", "label": "Setup"},
	]:
		var b := MarketTheme.button(entry["label"])
		var id: String = entry["id"]
		b.pressed.connect(func(): _show(id))
		row.add_child(b)
		_nav_buttons[id] = b

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var close := MarketTheme.button("Close  [Esc]")
	close.pressed.connect(close_terminal)
	row.add_child(close)
	return row


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.add_child(MarketTheme.label(
		"Prices, fees and delivery times are set by the market, not by this terminal.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	return row


# --- Screens ---

func _show(id: String) -> void:
	_current = id
	for key in _nav_buttons:
		var b: Button = _nav_buttons[key]
		b.add_theme_color_override(
			"font_color", MarketTheme.ACCENT if key == id else MarketTheme.TEXT)

	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null

	var screen: Control = null
	match id:
		"browse":
			screen = BrowseScreen.new()
		"orders":
			screen = OrdersScreen.new()
		"wallet":
			screen = WalletScreen.new()
		"setup":
			screen = SetupScreen.new()
		"detail":
			screen = DetailScreen.new()
		_:
			screen = BrowseScreen.new()

	screen.setup(self, _client)
	_screen = screen
	_content.add_child(screen)


## Open the detail screen for a listing (§8.1 screen 2).
func open_detail(listing_id: int) -> void:
	_current = "detail"
	for key in _nav_buttons:
		_nav_buttons[key].add_theme_color_override("font_color", MarketTheme.TEXT)

	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()

	var screen := DetailScreen.new()
	screen.setup(self, _client)
	screen.listing_id = listing_id
	_screen = screen
	_content.add_child(screen)


func back_to_browse() -> void:
	_show("browse")


# --- Status and connectivity ---

func set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


## Show or hide the offline banner.
##
## `as_of` comes from the server so the banner reports when the MARKET last
## spoke rather than when this client last asked -- the two differ, and the
## player cares about the first.
func set_offline(offline: bool, as_of: String = "") -> void:
	if _banner == null:
		return
	if offline:
		_banner_label.text = "OFFLINE  -  showing cached prices, %s.  Buying is disabled." % \
			MarketTheme.staleness(as_of)
		_banner.show()
	else:
		_banner.hide()


func _on_online_changed(is_online: bool) -> void:
	if is_online:
		set_offline(false)
	else:
		set_offline(true)


func is_online() -> bool:
	return _client != null and _client.is_online()


func main() -> Node:
	return _main


# --- Open / close ---

func _open_game_ui() -> void:
	_ui_manager = _find_ui_manager()
	if _ui_manager != null and _ui_manager.has_method("UIOpen"):
		_ui_manager.UIOpen()
		if _ui_manager.has_method("PlayClick"):
			_ui_manager.PlayClick()


func close_terminal() -> void:
	if _ui_manager != null and is_instance_valid(_ui_manager) \
			and _ui_manager.has_method("UIClose"):
		_ui_manager.UIClose()
	closed.emit()
	queue_free()


func _find_ui_manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	# The same path LootContainer.Interact() uses to reach the UI manager.
	return tree.root.get_node_or_null("Map/Core/UI")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			close_terminal()
