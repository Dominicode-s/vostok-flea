extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Generates the terminal's ItemData, icon and inventory sprite at runtime.
##
## Why generate rather than ship these files: a .png inside a mounted VMZ has no
## .import sidecar, so Godot cannot load it as a Texture2D. The physical-money
## mod hit the same wall and solved it the same way -- build the image in code
## and hand it to ResourceSaver, which writes a .tres the rest of the engine can
## load normally.
##
## The placed world scene (FleaTerminal_F.tscn) IS shipped statically, because
## .tscn and .tres are text formats that need no import step. It references the
## ItemData below by its user:// path, so these files must exist before that
## scene is ever loaded.

const TerminalModel := preload("res://mods/FleaMarket/TerminalModel.gd")

const ITEM_KEY := "FleaTerminal"
const DISPLAY_NAME := "Flea Market Terminal"

## See the note in TerminalModel.gd: a save reset deletes every top-level
## *.tres in user://, so generated resources live one level down.
const ASSET_DIR := TerminalModel.ASSET_DIR
const ICON_PATH := ASSET_DIR + "/TerminalIcon.tres"
const TETRIS_PATH := ASSET_DIR + "/TerminalTetris.tscn"
const ITEM_PATH := ASSET_DIR + "/TerminalItem.tres"
const SCENE_PATH := "res://mods/FleaMarket/FleaTerminal_F.tscn"

## Catalog grid footprint, in inventory cells.
const GRID_SIZE := Vector2(2, 2)
const ICON_PX := 128


## Build every generated asset. Returns true when the ItemData is on disk and
## loadable, which is the precondition for the world scene resolving.
static func build() -> bool:
	DirAccess.make_dir_recursive_absolute(ASSET_DIR)

	# The world scene references the mesh by its user:// path, so it has to
	# exist before that scene is ever loaded.
	var used_model := TerminalModel.build()
	print("[FleaMarket] terminal mesh: %s" % (
		"model/terminal.obj" if used_model else "placeholder box (no model supplied)"))

	var icon := _build_icon()
	if ResourceSaver.save(icon, ICON_PATH) != OK:
		push_error("FleaMarket: could not save terminal icon")
		return false
	# CACHE_MODE_REPLACE so a rebuilt icon is picked up rather than serving the
	# copy cached from a previous launch.
	ResourceLoader.load(ICON_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)

	var f := FileAccess.open(TETRIS_PATH, FileAccess.WRITE)
	if f == null:
		push_error("FleaMarket: could not write terminal inventory sprite")
		return false
	f.store_string(_build_tetris_text())
	f.close()
	var tetris = ResourceLoader.load(TETRIS_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)

	var item := ItemData.new()
	item.file = ITEM_KEY
	item.name = DISPLAY_NAME
	item.inventory = DISPLAY_NAME
	item.rotated = DISPLAY_NAME
	item.equipment = DISPLAY_NAME
	item.display = DISPLAY_NAME
	# Vanilla branches on this exact string when the player takes the item, and
	# routes "Furniture" to the catalog grid rather than the inventory grid.
	# Getting it wrong makes the terminal unplaceable.
	item.type = "Furniture"
	item.value = 0
	# Rarity.Null -- keeps it out of every loot bucket. The terminal is granted,
	# not found.
	item.rarity = ItemData.Rarity.Null
	item.weight = 8.0
	item.size = GRID_SIZE
	item.icon = ResourceLoader.load(ICON_PATH)
	item.tetris = tetris
	item.stackable = false
	item.showCondition = false
	item.showAmount = false

	if ResourceSaver.save(item, ITEM_PATH) != OK:
		push_error("FleaMarket: could not save terminal ItemData")
		return false
	ResourceLoader.load(ITEM_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	return true


static func load_item() -> ItemData:
	var res = ResourceLoader.load(ITEM_PATH)
	return res as ItemData


# --- Generated art ---

static func _build_icon() -> ImageTexture:
	var img := Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var casing := Color(0.13, 0.15, 0.14, 1.0)
	var bezel := Color(0.07, 0.08, 0.08, 1.0)
	var screen := Color(0.10, 0.34, 0.20, 1.0)
	var glow := Color(0.35, 0.95, 0.52, 1.0)

	# Casing with a 6px margin, then an inset screen. Drawn by hand rather than
	# with a texture so nothing needs importing.
	_rect(img, 8, 6, ICON_PX - 16, ICON_PX - 12, casing)
	_rect(img, 14, 12, ICON_PX - 28, 68, bezel)
	_rect(img, 18, 16, ICON_PX - 36, 60, screen)

	# Scanlines, so it reads as a screen at inventory size.
	for y in range(20, 72, 6):
		_rect(img, 22, y, ICON_PX - 44, 2, glow)

	# Keypad blocks under the screen.
	for row in range(2):
		for col in range(3):
			_rect(img, 26 + col * 28, 90 + row * 16, 20, 10, bezel)

	return ImageTexture.create_from_image(img)


static func _rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for py in range(y, mini(y + h, img.get_height())):
		for px in range(x, mini(x + w, img.get_width())):
			if px >= 0 and py >= 0:
				img.set_pixel(px, py, c)


## The inventory-grid sprite. Vanilla items centre the sprite at 32px per grid
## cell and halve its scale; a 2x2 item sits at (64, 64).
static func _build_tetris_text() -> String:
	var centre := GRID_SIZE * 32.0
	return """[gd_scene format=3]

[ext_resource type="Material" path="res://UI/Effects/MT_Item.tres" id="1"]
[ext_resource type="Texture2D" path="%s" id="2"]

[node name="%s" type="Sprite2D"]
material = ExtResource("1")
position = Vector2(%d, %d)
scale = Vector2(0.5, 0.5)
texture = ExtResource("2")
""" % [ICON_PATH, ITEM_KEY, int(centre.x), int(centre.y)]
