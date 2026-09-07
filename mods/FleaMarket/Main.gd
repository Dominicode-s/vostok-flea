extends Node

## Vostok Flea Market -- client entry point.
##
## Milestone 2 (read-only) is being built in order. This commit covers the one
## capability the M0 spike could not close: placing a working interactable in
## the shelter. Everything else -- the terminal UI, MarketClient, the courier
## crate -- lands on top of this.
##
## Design rule this file exists to protect: the terminal is a RENDERER. No
## market logic, no price calculation, no deciding what a trade is worth, ever.

const VERSION := "0.1.0"
const LOG_PREFIX := "[FleaMarket] "

const ShelterFixtures := preload("res://mods/FleaMarket/ShelterFixtures.gd")
const FleaTerminalScript := preload("res://mods/FleaMarket/FleaTerminal.gd")

## How often to check whether the player has entered a shelter. Deliberately not
## per-frame: Quick Stack shipped a fix for exactly that mistake (it scanned the
## tree every frame looking for the inventory screen and cost real framerate).
const SHELTER_POLL_SECONDS := 1.0

var _terminal: Node3D = null
var _poll_timer: Timer = null


func _ready() -> void:
	Engine.set_meta("FleaMarketMain", self)
	_log("v%s loading" % VERSION)

	_poll_timer = Timer.new()
	_poll_timer.wait_time = SHELTER_POLL_SECONDS
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_check_shelter)
	add_child(_poll_timer)


# --- Fixture placement ---

func _check_shelter() -> void:
	var tree := get_tree()
	if tree == null:
		return

	var map := ShelterFixtures.find_shelter(tree)
	if map == null:
		# Not in a shelter. The old node died with the previous scene; drop the
		# stale reference so re-entering re-places rather than silently doing
		# nothing because a freed node looked "already placed".
		_terminal = null
		return

	if is_instance_valid(_terminal) and _terminal.is_inside_tree():
		return

	_place_terminal(map)


func _place_terminal(map: Node3D) -> void:
	var parent := ShelterFixtures.fixture_parent(map)

	# Re-entering the shelter rebuilds the scene from scratch, but a mid-session
	# reload could leave one behind. Never end up with two.
	var existing := parent.get_node_or_null(ShelterFixtures.TERMINAL_NODE_NAME)
	if existing != null:
		existing.queue_free()

	var terminal := ShelterFixtures.build_terminal(FleaTerminalScript)
	parent.add_child(terminal)
	# owner must be assigned only once the node is in the tree -- see the
	# contract notes in ShelterFixtures.gd.
	ShelterFixtures.finalise(terminal)

	terminal.set_open_handler(_on_terminal_opened)
	_terminal = terminal

	_log("terminal placed in %s at %s" % [map.get_path(), terminal.position])


# --- Terminal ---

func _on_terminal_opened() -> void:
	# Placeholder for the browse screen. Proving the interaction path end to end
	# is this commit's whole purpose; the UI is the next one.
	_log("terminal opened")
	_flash("FLEA MARKET\nterminal online", Color(0.4, 1.0, 0.5))


# --- Utilities ---

func _flash(text: String, colour: Color, seconds: float = 2.5) -> void:
	var root := get_tree().root if get_tree() != null else null
	if root == null:
		return

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(24, 24)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", colour)
	panel.add_child(label)
	root.add_child(panel)

	var timer := get_tree().create_timer(seconds)
	timer.timeout.connect(func():
		if is_instance_valid(panel):
			panel.queue_free()
	)


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
