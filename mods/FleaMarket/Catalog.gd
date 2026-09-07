extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## The item catalog as the server defines it, cached locally.
##
## Two jobs:
##
## 1. Let the terminal render item names, classes and attachment rules without a
##    round-trip per row.
## 2. **Refuse to escrow against a catalog we have not validated against.** The
##    server side asked for this explicitly and it is the guard against a game
##    patch moving item keys under us. A wrong item_key means a rifle
##    round-trips as the wrong thing, and unlike most bugs here that one is not
##    recoverable from the ledger.
##
## The cache is written to user:// so an offline launch can still render browse
## rows behind the offline banner (§8.3).

const CACHE_PATH := "user://FleaMarket_Catalog.json"

## The catalog version this client's ItemBridge has actually been validated
## against. Bumping this is a deliberate act that should follow re-running the
## descriptor fixtures against the new catalog -- never a reflex to silence the
## guard.
const VALIDATED_CATALOG_VERSION := 2

## Descriptor version this client speaks.
const SUPPORTED_DESCRIPTOR_VERSION := 2

var catalog_version: int = -1
var descriptor_version: int = -1
var condition_min: float = 0.0
var condition_max: float = 100.0
var fetched_at_unix: int = 0

var _items: Dictionary = {}   # item_key -> item dict
var _classes: PackedStringArray = PackedStringArray()


func is_loaded() -> bool:
	return not _items.is_empty()


func count() -> int:
	return _items.size()


func get_item(item_key: String) -> Dictionary:
	var v = _items.get(item_key)
	return v if v is Dictionary else {}


func has_item(item_key: String) -> bool:
	return _items.has(item_key)


func classes() -> PackedStringArray:
	return _classes


func tradeable_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _items.keys():
		if bool(_items[k].get("tradeable", true)):
			out.append(str(k))
	return out


## True when it is safe to put a real item at risk against this catalog.
##
## Read the name literally: this gates escrow, not browsing. Browsing a catalog
## we don't fully trust is harmless; escrowing against one is how you lose a
## rifle.
func is_safe_to_escrow() -> bool:
	if not is_loaded():
		return false
	if catalog_version != VALIDATED_CATALOG_VERSION:
		return false
	if descriptor_version != SUPPORTED_DESCRIPTOR_VERSION:
		return false
	return true


## Human-readable reason escrow is blocked, or "" when it is allowed.
func escrow_block_reason() -> String:
	if not is_loaded():
		return "The item catalog has not loaded yet."
	if catalog_version != VALIDATED_CATALOG_VERSION:
		return ("The market's item catalog is version %d, but this mod was "
			+ "built against version %d. Trading is disabled until the mod is "
			+ "updated.") % [catalog_version, VALIDATED_CATALOG_VERSION]
	if descriptor_version != SUPPORTED_DESCRIPTOR_VERSION:
		return ("The market expects item descriptor version %d, but this mod "
			+ "speaks version %d. Trading is disabled until the mod is "
			+ "updated.") % [descriptor_version, SUPPORTED_DESCRIPTOR_VERSION]
	return ""


## Populate from a parsed /v1/catalog body. Returns false if the payload is not
## shaped like a catalog, leaving any previously-loaded data untouched.
func ingest(payload) -> bool:
	if not payload is Dictionary:
		return false
	var items = payload.get("items")
	if not items is Array:
		return false

	var by_key := {}
	var seen_classes := {}
	for entry in items:
		if not entry is Dictionary:
			continue
		var key = entry.get("item_key")
		if not key is String or key == "":
			continue
		by_key[key] = entry
		var cls = entry.get("class")
		if cls is String and cls != "":
			seen_classes[cls] = true

	if by_key.is_empty():
		return false

	_items = by_key
	var class_list := seen_classes.keys()
	class_list.sort()
	_classes = PackedStringArray(class_list)

	catalog_version = int(payload.get("catalog_version", -1))
	descriptor_version = int(payload.get("descriptor_version", -1))

	var scale = payload.get("condition_scale")
	if scale is Dictionary:
		condition_min = float(scale.get("min", 0.0))
		condition_max = float(scale.get("max", 100.0))

	fetched_at_unix = int(Time.get_unix_time_from_system())
	return true


# --- Persistence ---

func save_cache() -> void:
	if not is_loaded():
		return
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("FleaMarket: could not write catalog cache")
		return
	f.store_string(JSON.stringify({
		"catalog_version": catalog_version,
		"descriptor_version": descriptor_version,
		"condition_scale": {"min": condition_min, "max": condition_max},
		"fetched_at_unix": fetched_at_unix,
		"items": _items.values(),
	}))
	f.close()


func load_cache() -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(text)
	if not ingest(parsed):
		return false
	# ingest() stamps fetched_at as now; restore the real age so the offline
	# banner tells the truth about how stale this data is.
	if parsed is Dictionary:
		fetched_at_unix = int(parsed.get("fetched_at_unix", fetched_at_unix))
	return true
