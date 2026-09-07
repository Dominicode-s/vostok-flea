extends Control

## §8.1 screen 6 -- wallet.
##
## Server-held credit, and what is already queued as physical cash.
##
## The distinction matters and is worth stating plainly on screen: a balance is
## money the market is holding, and it only becomes spendable once it has been
## withdrawn and physically delivered to the crate. Showing one number for both
## would let a player think they can spend money that is still in transit.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")

var _ui: Node = null
var _client: Node = null
var _body: VBoxContainer = null


func setup(ui: Node, client: Node) -> void:
	_ui = ui
	_client = client


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body = VBoxContainer.new()
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.add_theme_constant_override("separation", 10)
	add_child(_body)
	_load()


func _load() -> void:
	var res: Dictionary = await _client.get_json("/wallet")
	if not res["ok"]:
		if str(res.get("error")) == "offline":
			_ui.set_offline(true)
			_message("Cannot reach the market. Your balance is held server-side " +
				"and is unaffected by this terminal being offline.")
		elif str(res.get("error")) == "unauthorized":
			_message("The market rejected this player key. Open Setup to paste a new one.")
		else:
			_message(str(res.get("message", "Could not load your wallet.")))
		return

	var body = res["json"]
	if not body is Dictionary:
		_message("The market sent something this terminal could not read.")
		return
	_render(body)


func _render(body: Dictionary) -> void:
	for child in _body.get_children():
		child.queue_free()

	var callsign := str(body.get("callsign", "-"))
	_body.add_child(MarketTheme.label(
		"TRADING AS  " + callsign, MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.label(
		"Other traders see this callsign and nothing else about you.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.rule())

	var balance := PanelContainer.new()
	balance.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL, 1))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	balance.add_child(box)

	box.add_child(MarketTheme.label("HELD BY THE MARKET", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	box.add_child(MarketTheme.label(
		MarketTheme.money(body.get("balance", 0)), MarketTheme.FONT_TITLE, MarketTheme.ACCENT))
	box.add_child(MarketTheme.label(
		"Refunds and uncollected proceeds. This is not cash in your pockets " +
		"until it has been withdrawn and delivered.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	box.add_child(MarketTheme.rule())
	box.add_child(MarketTheme.label("ALREADY ON THE VAN", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	box.add_child(MarketTheme.label(
		MarketTheme.money(body.get("queued_for_delivery", 0)),
		MarketTheme.FONT_HEAD, MarketTheme.TEXT))
	box.add_child(MarketTheme.label(
		"Cash already queued for delivery to your courier crate.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(balance)

	# Withdrawal is a mutating call and arrives with selling. Disabled with the
	# reason stated rather than hidden -- §8.3.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var withdraw := MarketTheme.button("Withdraw as cash", false)
	withdraw.custom_minimum_size = Vector2(200, 38)
	row.add_child(withdraw)
	row.add_child(MarketTheme.label(
		"Withdrawing arrives with the courier crate in a later update.",
		MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))
	_body.add_child(row)

	_body.add_child(MarketTheme.label(
		"Cash is a physical item. A large withdrawal arrives as bricks and needs " +
		"crate space -- 99 999 to a stack.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))


func _message(text: String) -> void:
	for child in _body.get_children():
		child.queue_free()
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(620, 0)
	_body.add_child(l)
