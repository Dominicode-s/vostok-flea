extends Node

## Vostok Flea Market -- client entry point.
##
## Design rule this file exists to protect: the terminal is a RENDERER. No
## market logic, no price calculation, no deciding what a trade is worth, ever.

const VERSION := "0.2.0"
const LOG_PREFIX := "[FleaMarket] "

const TerminalAssets := preload("res://mods/FleaMarket/TerminalAssets.gd")
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

var _client: Node = null
var _catalog: RefCounted = null
var _poll_timer: Timer = null

var _furniture_registered := false
var _last_scene_note := ""


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

	if not _furniture_registered or _terminal_granted():
		return

	var map := tree.root.get_node_or_null("Map")
	if map == null or not "mapType" in map or str(map.mapType) != "Shelter":
		return

	_grant_terminal(map)


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
	# Placeholder for the browse screen. The interaction path is what this
	# commit proves; the UI is the next one.
	_log("terminal opened")
	var status := "offline"
	if _client != null and _client.is_online():
		status = "online"
	_flash("FLEA MARKET\n%s  -  catalog v%d, %d items" % [
		status.to_upper(), _catalog.catalog_version, _catalog.count()],
		Color(0.4, 1.0, 0.5))


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


## Whether this player has already been given a terminal.
##
## Keyed per save profile: profiles are separate worlds, and a terminal granted
## in one is not present in another. Secure Container shipped a fix for exactly
## this class of bug -- one shared file meant a container opened showing another
## save's items.
func _terminal_granted() -> bool:
	return bool(_config().get_value("granted", _profile_id(), false))


func _mark_terminal_granted() -> void:
	var cfg := _config()
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
