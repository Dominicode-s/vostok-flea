extends Node

## Vostok Flea Market -- client entry point.
##
## Design rule this file exists to protect: the terminal is a RENDERER. No
## market logic, no price calculation, no deciding what a trade is worth, ever.

const VERSION := "0.3.2"
const LOG_PREFIX := "[FleaMarket] "

const TerminalAssets := preload("res://mods/FleaMarket/TerminalAssets.gd")
const MarketClientScript := preload("res://mods/FleaMarket/MarketClient.gd")
const CatalogScript := preload("res://mods/FleaMarket/Catalog.gd")
const TerminalUIScript := preload("res://mods/FleaMarket/ui/TerminalUI.gd")

## Player key lives in user:// and is global rather than per-save-profile: it
## identifies the player to the market, not a particular world. (PendingLedger
## is the opposite -- see the M0 report, it MUST be per-profile.)
const CONFIG_PATH := "user://FleaMarket.cfg"

## How often to check whether the player has entered a shelter. Deliberately not
## per-frame: Quick Stack shipped a fix for exactly that mistake (it scanned the
## tree every frame looking for the inventory screen and cost real framerate).
const SHELTER_POLL_SECONDS := 1.0

var _client: Node = null
var _catalog: RefCounted = null
var _poll_timer: Timer = null

var _furniture_registered := false
var _last_scene_note := ""
var _ui: Node = null
var _absent_ticks := 0
## Instance id of the shelter whose terminal state is already resolved.
var _settled_map := 0

## Presence of the terminal in the player's world.
const PRESENCE_NO := 0
const PRESENCE_YES := 1
## Could not tell -- the UI is not up yet. Never treated as absent: a false
## negative grants a second terminal.
const PRESENCE_UNKNOWN := -1

## Consecutive one-second polls reporting "absent" before a terminal is
## granted. The catalog grid fills a beat after the shelter finishes loading.
const ABSENT_TICKS_BEFORE_GRANT := 4


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

	await _register_furniture()
	_refresh_catalog()


# --- Furniture registration ---
#
# The terminal is placeable furniture rather than an object the mod drops at
# fixed coordinates. The first cut hardcoded the Bunker's canteen table, which
# put the terminal outside the building in the other three shelters -- Cabin,
# Tent and Attic all declare mapType "Shelter" too. Letting the player place it
# is both what the game already does for every other fixture and the only
# approach that cannot be wrong about geometry.
#
# It also sets up the courier crate, which needs the same machinery:
# FurnitureSave persists `container` and `storage`, so a crate placed by the
# player keeps its contents across sessions for free.

func _register_furniture() -> void:
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		_log("RTVModLib unavailable - terminal cannot be registered as furniture")
		return

	# The generated ItemData must be on disk before the world scene is loaded:
	# FleaTerminal_F.tscn references it by its user:// path.
	if not TerminalAssets.build():
		_log("terminal assets failed to build; skipping furniture registration")
		return

	# Registration has to happen in _ready(), before the shelter systems copy
	# from the shared stores. Hooks and registry may not be up yet, so wait.
	if lib.has_signal("frameworks_ready"):
		await lib.frameworks_ready

	var result: Dictionary = lib.register_furniture({
		TerminalAssets.ITEM_KEY: {
			"item_path": TerminalAssets.ITEM_PATH,
			"scene_path": TerminalAssets.SCENE_PATH,
			# No trader_pools and no recipe on purpose: the terminal is the
			# thing that lets you trade at all, so putting it behind a trader
			# would be circular. It is granted once instead, below.
			"trader_pools": [],
		},
	})

	_furniture_registered = bool(result.get("ok", false))
	if _furniture_registered:
		_log("terminal registered as furniture (item '%s')" % TerminalAssets.ITEM_KEY)
	else:
		_log("furniture registration failed: %s" % str(result))


# --- Granting the terminal ---

func _check_shelter() -> void:
	var tree := get_tree()
	if tree == null:
		return

	_log_scene_state(tree)

	if not _furniture_registered:
		return

	var map := tree.root.get_node_or_null("Map")
	if map == null or not "mapType" in map or str(map.mapType) != "Shelter":
		_absent_ticks = 0
		# Leaving the shelter invalidates the settled state, so re-entering
		# re-checks. A new game rebuilds the map, which gives a new instance id.
		_settled_map = 0
		return

	# Settled for this shelter: stop looking. Without this the presence check
	# walks the whole shelter tree once a second forever, which is the mistake
	# Quick Stack shipped a fix for.
	if _settled_map == map.get_instance_id():
		return

	match _terminal_presence(map):
		PRESENCE_YES:
			_absent_ticks = 0
			_settled_map = map.get_instance_id()
			_mark_terminal_granted()
		PRESENCE_UNKNOWN:
			# Could not read the catalog grid. Say nothing rather than guess:
			# a false "absent" grants a duplicate.
			_absent_ticks = 0
		PRESENCE_NO:
			# The catalog grid populates a beat after the shelter loads, so a
			# single empty read is not evidence of anything. Require several
			# consecutive absent reads before acting.
			_absent_ticks += 1
			if _absent_ticks >= ABSENT_TICKS_BEFORE_GRANT:
				_absent_ticks = 0
				_settled_map = map.get_instance_id()
				_grant_terminal(map)


## Does the player actually have a terminal -- placed in the shelter, or
## waiting in the build catalog?
##
## This replaced a persisted "already granted" flag, which had a hole. The flag
## lived in FleaMarket.cfg, and a .cfg survives the game's save reset while the
## generated ItemData -- a .tres -- does not (Loader.FormatSave deletes every
## top-level *.tres). So after starting a new game the mod believed it had
## granted a terminal that no longer existed anywhere, and would never grant
## another.
##
## Asking the world is strictly better than remembering: it is correct after a
## save wipe, after a profile switch, and if the player scraps the terminal.
func _terminal_presence(map: Node) -> int:
	# Catalog grid first: it is a handful of children, where the placed-terminal
	# search walks the entire shelter.
	var interface := map.get_node_or_null("Core/UI/Interface")
	if interface == null or not "catalogGrid" in interface:
		return PRESENCE_UNKNOWN
	var grid = interface.catalogGrid
	if grid == null or not is_instance_valid(grid):
		return PRESENCE_UNKNOWN

	if not map.find_children("FleaTerminal_F*", "", true, false).is_empty():
		return PRESENCE_YES

	for child in grid.get_children():
		if not "slotData" in child or child.slotData == null:
			continue
		if child.slotData.itemData == null:
			continue
		if str(child.slotData.itemData.file) == TerminalAssets.ITEM_KEY:
			return PRESENCE_YES
	return PRESENCE_NO


## Put one terminal into the player's build catalog, once ever.
##
## AddToCatalog is how vanilla hands furniture to the player -- it is the same
## call the game makes when you pick a placed piece back up. The catalog grid is
## where unplaced furniture lives; from there the player positions it in decor
## mode and the game's own ShelterSave keeps it there.
func _grant_terminal(map: Node) -> void:
	var interface := map.get_node_or_null("Core/UI/Interface")
	if interface == null or not interface.has_method("AddToCatalog"):
		return

	var item := TerminalAssets.load_item()
	if item == null:
		_log("cannot grant terminal: ItemData did not load")
		return

	interface.AddToCatalog(item, null)
	_mark_terminal_granted()
	_log("terminal added to the build catalog - place it from the decor menu")
	_flash("FLEA MARKET\nTerminal added to your build catalog", Color(0.4, 1.0, 0.5), 6.0)


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

func open_terminal(_terminal: Node) -> void:
	if is_instance_valid(_ui):
		# Already open. Interacting again must not stack a second copy on the
		# first: closing one would leave the player frozen behind the other.
		return

	var tree := get_tree()
	if tree == null:
		return

	_log("terminal opened")
	var ui = TerminalUIScript.new()
	ui.setup(self, _client)
	ui.closed.connect(_on_terminal_closed)
	tree.root.add_child(ui)
	_ui = ui


func _on_terminal_closed() -> void:
	_ui = null
	_log("terminal closed")


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

	# Explicit type: _catalog is declared RefCounted, so this is a dynamic call
	# returning Variant and := would have nothing to infer from.
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


# --- Config ---

func _config() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	return cfg


func _load_player_key() -> String:
	return str(_config().get_value("auth", "player_key", ""))


func save_player_key(key: String) -> void:
	var cfg := _config()
	cfg.set_value("auth", "player_key", key.strip_edges())
	cfg.save(CONFIG_PATH)
	_client.configure("", key.strip_edges())
	_log("player key saved")


## Record that this profile has a terminal.
##
## Kept only as a breadcrumb for support ("has this save ever had one?").
## Nothing branches on it: _terminal_presence asks the world instead, because a
## remembered flag outlived the thing it described. See that function.
func _mark_terminal_granted() -> void:
	var cfg := _config()
	if bool(cfg.get_value("granted", _profile_id(), false)):
		return
	cfg.set_value("granted", _profile_id(), true)
	cfg.save(CONFIG_PATH)


func _profile_id() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://profiles/active_profile.cfg") != OK:
		return "default"
	return str(cfg.get_value("profiles", "active", "default"))


# --- Utilities ---

func _flash(text: String, colour: Color, seconds: float = 2.5) -> void:
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
