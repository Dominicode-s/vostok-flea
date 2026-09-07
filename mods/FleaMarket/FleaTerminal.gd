extends Node3D

## The market terminal as the game sees it: a placeable furniture fixture.
##
## `Interact()` and `UpdateTooltip()` are the two methods Scripts/Interactor.gd
## calls on a collider's owner. Their names and zero-argument signatures are the
## engine-side contract and are not ours to change.
##
## Instances are created by the game's furniture placement system, not by us, so
## this node finds the mod rather than waiting to be handed a reference.
##
## It holds NO market logic and never will. It is the physical handle the player
## grabs; everything behind it belongs to the terminal UI, which in turn only
## renders what the server sends. See the non-negotiables in README.

signal opened

var _game_data: Resource = null


func _ready() -> void:
	# GameData is a preloaded .tres singleton shared by the whole game. Loading
	# by path rather than preloading keeps this script parseable in isolation,
	# which matters because tools/check-gdscript.sh compiles it without the game.
	_game_data = load("res://Resources/GameData.tres")
	_fit_collision_to_mesh()


## Resize the interaction and physics boxes to the mesh actually in use.
##
## The scene ships sized for the placeholder. Dropping in a real model of a
## different size would otherwise leave the player interacting with a box that
## does not match what they see -- or worse, unable to reach the terminal at
## all because the collider sits inside it.
func _fit_collision_to_mesh() -> void:
	var mesh_node := get_node_or_null("Mesh") as MeshInstance3D
	if mesh_node == null or mesh_node.mesh == null:
		return

	var aabb: AABB = mesh_node.mesh.get_aabb()
	if aabb.size.x <= 0.01 or aabb.size.y <= 0.01:
		return
	var centre := aabb.position + aabb.size * 0.5

	for path in ["Collider_R/StaticBody3D/CollisionShape3D",
			"Collider_P/StaticBody3D/CollisionShape3D"]:
		var node := get_node_or_null(path) as CollisionShape3D
		if node == null:
			continue
		var box := BoxShape3D.new()
		# Fractionally proud of the mesh so the interaction ray catches the
		# object rather than slipping past a coincident face.
		box.size = aabb.size * 1.02
		node.shape = box
		node.position = centre


func UpdateTooltip() -> void:
	if _game_data == null:
		return
	_game_data.tooltip = "Flea Market Terminal [Open]"


func Interact() -> void:
	opened.emit()
	var main = Engine.get_meta("FleaMarketMain", null)
	if main == null:
		push_warning("FleaMarket: terminal interacted with but the mod is not loaded")
		return
	main.open_terminal(self)
