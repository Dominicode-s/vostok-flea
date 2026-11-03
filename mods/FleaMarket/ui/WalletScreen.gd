extends Control

## §8.1 screen 6 -- wallet.
##
## Server-held credit, what is already queued as physical cash, and the control
## to turn the first into the second.
##
## The distinction between the two numbers matters and is worth stating plainly
## on screen: a balance is money the market is holding, and it only becomes
## spendable once it has been withdrawn and physically delivered to the crate.
## One number for both would let a player think they can spend money that is
## still in transit.
##
## Withdrawing is a mutating call with NO ordering hazard: nothing is destroyed
## client-side, the server moves its own credit into a delivery. So it carries
## an idempotency key like any mutating call but needs no PendingLedger entry --
## there is no window in which a crash could lose anything. The same reasoning
## as cancelling a listing.

const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")
const DeliveryService := preload("res://mods/FleaMarket/DeliveryService.gd")
const Stash := preload("res://mods/FleaMarket/Stash.gd")

var _ui: Node = null
var _client: Node = null
var _body: VBoxContainer = null
var _amount: SpinBox = null
var _balance := 0
var _busy := false


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
			_message("Cannot reach the market. Your balance is held server-side "
				+ "and is unaffected by this terminal being offline.")
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

	_balance = int(body.get("balance", 0))

	_body.add_child(MarketTheme.label(
		"TRADING AS  " + str(body.get("callsign", "-")),
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.label(
		"Other traders see this callsign and nothing else about you.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(MarketTheme.rule())

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MarketTheme.panel(MarketTheme.PANEL, 1))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	box.add_child(MarketTheme.label("HELD BY THE MARKET", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	box.add_child(MarketTheme.label(MarketTheme.money(_balance),
		MarketTheme.FONT_TITLE, MarketTheme.ACCENT))
	box.add_child(MarketTheme.label(
		"Refunds and uncollected proceeds. This is not cash in your pockets "
		+ "until it has been withdrawn and delivered.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	box.add_child(MarketTheme.rule())
	box.add_child(MarketTheme.label("ALREADY ON THE VAN", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	box.add_child(MarketTheme.label(MarketTheme.money(body.get("queued_for_delivery", 0)),
		MarketTheme.FONT_HEAD, MarketTheme.TEXT))
	box.add_child(MarketTheme.label(
		"Cash already queued for delivery to your courier crate.",
		MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))
	_body.add_child(panel)

	_body.add_child(_withdraw_panel())


func _withdraw_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.add_child(MarketTheme.label("WITHDRAW AS CASH", MarketTheme.FONT_SMALL, MarketTheme.TEXT_DIM))

	var crate := DeliveryService.find_crate(get_tree())
	var reason := ""
	if not _ui.is_online():
		reason = "The market is unreachable, so withdrawing is disabled."
	elif _balance <= 0:
		reason = "Nothing to withdraw."
	elif crate == null:
		reason = "Place a courier crate in your shelter first -- cash is delivered there."

	if reason != "":
		box.add_child(MarketTheme.button("Withdraw", false))
		box.add_child(_wrapped(reason, MarketTheme.TEXT_DIM))
		return box

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_amount = SpinBox.new()
	_amount.min_value = 1
	_amount.max_value = _balance
	_amount.step = 1
	_amount.value = _balance
	_amount.custom_minimum_size = Vector2(200, 0)
	row.add_child(_amount)

	var all := MarketTheme.button("All")
	all.pressed.connect(func(): _amount.value = _balance)
	row.add_child(all)

	var go := MarketTheme.button("Withdraw")
	go.pressed.connect(_withdraw)
	row.add_child(go)
	box.add_child(row)

	# Cash is physical, and a large withdrawal is a storage problem rather than
	# a number going up (§7.1). Warn before the delivery arrives and cannot fit,
	# because a delivery that does not fit simply waits -- correct, but baffling
	# if nobody said why.
	var per_stack := _cash_stack_size()
	var capacity: Dictionary = DeliveryService.capacity(crate)
	var stacks := int(ceil(float(_balance) / float(per_stack)))
	box.add_child(_wrapped(
		"%s arrives as %d stack%s of at most %s, each taking one crate slot. "
		% [MarketTheme.money(_balance), stacks, "" if stacks == 1 else "s",
			MarketTheme.money(per_stack)]
		+ "Your crate has %d of %d slots free." % [
			int(capacity.get("free", 0)), int(capacity.get("total", 0))],
		MarketTheme.WARN if stacks > int(capacity.get("free", 0)) else MarketTheme.TEXT_DIM))
	return box


func _cash_stack_size() -> int:
	var cash := Stash.cash_mod()
	if cash != null and "cash_item_data" in cash and cash.cash_item_data != null:
		var per := int(cash.cash_item_data.maxAmount)
		if per > 0:
			return per
	return 99999


func _withdraw() -> void:
	if _busy or _amount == null:
		return
	_busy = true
	var amount := int(_amount.value)

	for child in _body.get_children():
		child.queue_free()
	_body.add_child(MarketTheme.label("Requesting...", MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM))

	var res: Dictionary = await _client.post_json("/wallet/withdraw",
		{"amount": amount}, _client.new_idempotency_key())
	_busy = false

	for child in _body.get_children():
		child.queue_free()

	if not res["ok"]:
		_body.add_child(MarketTheme.label("REFUSED", MarketTheme.FONT_HEAD, MarketTheme.DANGER))
		# The server refuses rather than clamping, so "withdraw everything" and
		# "withdraw too much" stay distinguishable. Pass its wording through.
		_body.add_child(_wrapped(str(res.get("message", "The market refused that withdrawal.")),
			MarketTheme.WARN))
	else:
		_body.add_child(MarketTheme.label("ON ITS WAY", MarketTheme.FONT_HEAD, MarketTheme.ACCENT))
		_body.add_child(_wrapped(
			"%s is queued for delivery to your courier crate." % MarketTheme.money(amount),
			MarketTheme.TEXT))

	var back := MarketTheme.button("Back")
	back.pressed.connect(_load)
	_body.add_child(back)


func _wrapped(text: String, colour: Color) -> Label:
	var l := MarketTheme.label(text, MarketTheme.FONT_SMALL, colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(640, 0)
	return l


func _message(text: String) -> void:
	for child in _body.get_children():
		child.queue_free()
	var l := MarketTheme.label(text, MarketTheme.FONT_BODY, MarketTheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(620, 0)
	_body.add_child(l)
