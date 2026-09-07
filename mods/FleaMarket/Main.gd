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
const MarketClientScript := preload("res://mods/FleaMarket/MarketClient.gd")
const CatalogScript := preload("res://mods/FleaMarket/Catalog.gd")

## Player key lives in user:// and is global rather than per-save-profile: it
## identifies the player to the market, not a particular world. (PendingLedger
## is the opposite -- see the M0 report, it MUST be per-profile.)
const CONFIG_PATH := "user://FleaMarket.cfg"

## How often to check whether the player has entered a shelter. Deliberately not
## per-frame: Quick Stack shipped a fix for exactly that mistake (it scanned the
## tree every frame looking for the inventory screen and cost real framerate).
const SHELTER_POLL_SECONDS := 1.0

var _terminal: Node3D = null
var _poll_timer: Timer = null
var _client: Node = null
var _catalog: RefCounted = null

## Diagnostics. Placement failing silently cost a play session once already:
## the mod logged that it loaded and then nothing, which is indistinguishable
## from the timer never firing. These log on CHANGE only, so they narrate what
## the mod can see without spamming a line every second.
var _last_scene_note := ""
var _warned_no_player := false


func _ready() -> void:
	Engine.set_meta("FleaMarketMain", self)
	_log("v%s loading" % VERSION)

	_catalog = CatalogScript.new()
	_client = MarketClientScript.new()
	_client.name = "MarketClient"
	add_child(_client)
	_client.configure("", _load_player_key())

	_poll_timer = Timer.new()
	_poll_timer.wait_time = SHELTER_POLL_SECONDS
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_check_shelter)
	add_child(_poll_timer)

	_refresh_catalog()


# --- Catalog ---

func _refresh_catalog() -> void:
	# Render from cache immediately if we have one, so an offline launch still
	# shows item names rather than an empty terminal.
	if _catalog.load_cache():
		_log("catalog cache loaded: v%d, %d items" % [
			_catalog.catalog_version, _catalog.count()])

	var res: Dictionary = await _client.get_json("/catalog")
	if not res["ok"]:
		_log("catalog fetch failed (%s): %s" % [res["error"], res["message"]])
		return

	if not _catalog.ingest(res["json"]):
		_log("catalog response was not shaped like a catalog; keeping cache")
		return

	_catalog.save_cache()
	_log("catalog v%d loaded: %d items, %d classes, condition %s-%s" % [
		_catalog.catalog_version, _catalog.count(), _catalog.classes().size(),
		_catalog.condition_min, _catalog.condition_max])

	# Explicit type: _catalog is declared RefCounted, so this is a dynamic
	# call returning Variant and := would have nothing to infer from.
	var block: String = _catalog.escrow_block_reason()
	if block == "":
		_log("escrow guard: OK (catalog v%d, descriptor v%d)" % [
			_catalog.catalog_version, _catalog.descriptor_version])
	else:
		_log("escrow guard: BLOCKED - " + block)


func catalog() -> RefCounted:
	return _catalog


func client() -> Node:
	return _client


# --- Player key ---

func _load_player_key() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return ""
	return str(cfg.get_value("auth", "player_key", ""))


func save_player_key(key: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("auth", "player_key", key.strip_edges())
	cfg.save(CONFIG_PATH)
	_client.configure("", key.strip_edges())
	_log("player key saved")


# --- Fixture placement ---

func _check_shelter() -> void:
	var tree := get_tree()
	if tree == null:
		return

	_log_scene_state(tree)

	var map := ShelterFixtures.find_shelter(tree)
	if map == null:
		# Not in a shelter. The old node died with the previous scene; drop the
		# stale reference so re-entering re-places rather than silently doing
		# nothing because a freed node looked "already placed".
		_terminal = null
		return

	if is_instance_valid(_terminal) and _terminal.is_inside_tree():
		return

	# The player body appears a beat after the map does. No player means no
	# anchor, so wait for the next tick rather than placing at the origin.
	var player: Node3D = ShelterFixtures.find_player(map)
	if player == null:
		if not _warned_no_player:
			_warned_no_player = true
			_log("shelter found but no Core/Controller yet; waiting")
		return
	_warned_no_player = false

	_place_terminal(map, player)


func _place_terminal(map: Node3D, player: Node3D) -> void:
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

	# Position after parenting so global_position is meaningful.
	var target: Vector3 = ShelterFixtures.placement_for(player)
	terminal.global_position = target

	terminal.set_open_handler(_on_terminal_opened)
	_terminal = terminal

	_log("terminal placed in shelter '%s' at %s (player at %s)" % [
		str(map.mapName) if "mapName" in map else "?",
		target, player.global_position])


func _log_scene_state(tree: SceneTree) -> void:
	var map := tree.root.get_node_or_null("Map")
	var note := ""
	if map == null:
		note = "no /root/Map (menu or loading)"
	elif not "mapType" in map:
		note = "/root/Map has no mapType property"
	else:
		note = "map '%s' type '%s'" % [
			str(map.mapName) if "mapName" in map else "?", str(map.mapType)]

	if note != _last_scene_note:
		_last_scene_note = note
		_log("scene: " + note)


# --- Terminal ---

func _on_terminal_opened() -> void:
	# Placeholder for the browse screen. Proving the interaction path end to end
	# is this commit's whole purpose; the UI is the next one.
	_log("terminal opened")
	_flash("FLEA MARKET\nterminal online", Color(0.4, 1.0, 0.5))


# --- Utilities ---

func _flash(text: String, colour: Color, seconds: float = 2.5) -> void:
	# Explicitly typed: a ternary yielding Window-or-null gives := nothing to
	# infer from, which is a parse error, not a runtime one.
	var tree := get_tree()
	if tree == null:
		return
	var root: Node = tree.root

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(24, 24)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", colour)
	panel.add_child(label)
	root.add_child(panel)

	var timer := tree.create_timer(seconds)
	timer.timeout.connect(func():
		if is_instance_valid(panel):
			panel.queue_free()
	)


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
