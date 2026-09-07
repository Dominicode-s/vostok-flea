extends RefCounted

# Deliberately no class_name: a global class registered from inside a mod
# archive collides across mods and survives reloads badly. Callers preload it.

## Places the market's physical fixtures in the player's shelter.
##
## The game's interaction contract, read off Scripts/Interactor.gd, is exact and
## easy to get subtly wrong:
##
##   1. A RayCast3D on the player camera scans collision_mask 16541. That mask
##      includes bit 16 and excludes bit 32, so the body the ray must hit is the
##      one on layer 16 -- vanilla containers put their *physical* collider on
##      layer 32 precisely so the ray ignores it.
##   2. The body must be in the group "Interactable".
##   3. The engine then calls `target.owner.UpdateTooltip()` and
##      `target.owner.Interact()` -- on the collider's OWNER, not the collider.
##
## Point 3 is the trap. `owner` is populated automatically for nodes loaded from
## a PackedScene, but a tree built at runtime has `owner == null` on every node,
## and a null owner means the raycast finds the body, sets the tooltip flag, and
## then hard-crashes on the interact call. So owner is assigned explicitly here,
## after the node is in the tree.

const INTERACT_COLLISION_LAYER := 16
const INTERACTABLE_GROUP := "Interactable"

# The bunker's living area, read from Assets/Bunker/Bunker.tscn: canteen table
# at (-3.5, 0, -10) with a stool beside it at (-3, 0, -10). The terminal sits on
# that table so it reads as part of the room rather than dropped in a corridor.
const TERMINAL_POSITION := Vector3(-3.5, 1.0, -10.0)
const TERMINAL_SIZE := Vector3(0.42, 0.5, 0.28)

const TERMINAL_NODE_NAME := "FleaMarketTerminal"


## Build the terminal fixture. The caller adds it to the shelter and then calls
## finalise() once it is in the tree.
static func build_terminal(interact_script: Script) -> Node3D:
	var root := Node3D.new()
	root.name = TERMINAL_NODE_NAME
	root.set_script(interact_script)
	root.position = TERMINAL_POSITION

	# --- Visible body ---
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box := BoxMesh.new()
	box.size = TERMINAL_SIZE
	mesh_instance.mesh = box

	# Placeholder look: a dark casing with a glowing screen-green emission, so
	# it is unmistakably the mod's object and not a vanilla prop. Replaced by a
	# real model before this ships to players.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.11, 0.10)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.95, 0.45)
	mat.emission_energy_multiplier = 0.6
	mat.roughness = 0.7
	mat.metallic = 0.2
	mesh_instance.material_override = mat
	root.add_child(mesh_instance)

	# --- Interaction body (layer 16, group "Interactable") ---
	var body := StaticBody3D.new()
	body.name = "InteractBody"
	body.collision_layer = INTERACT_COLLISION_LAYER
	# It is scanned, never scanning: leaving a mask on costs physics work and
	# buys nothing.
	body.collision_mask = 0
	body.add_to_group(INTERACTABLE_GROUP)

	var shape_node := CollisionShape3D.new()
	shape_node.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	# Slightly proud of the mesh so the ray catches the object rather than
	# slipping past an exactly-coincident face.
	shape.size = TERMINAL_SIZE * 1.05
	shape_node.shape = shape
	body.add_child(shape_node)
	root.add_child(body)

	return root


## Assign `owner` across the built subtree. MUST be called after the root is
## inside the scene tree -- Godot rejects an owner that is not an ancestor of
## the node, and an unowned collider makes Interactor.Interact() call a method
## on null.
static func finalise(root: Node) -> void:
	for child in root.get_children():
		child.owner = root
		for grandchild in child.get_children():
			grandchild.owner = root


## The shelter map node, or null when the player is not in a shelter.
##
## Map.gd exports mapType; the bunker sets it to "Shelter" (Scenes/Bunker.tscn).
## Testing that property rather than the node name means this keeps working if
## the developer adds a second shelter.
static func find_shelter(tree: SceneTree) -> Node3D:
	var map := tree.root.get_node_or_null("Map")
	if map == null:
		return null
	if not "mapType" in map:
		return null
	if str(map.mapType) != "Shelter":
		return null
	return map as Node3D


## Where fixtures get parented. Content is the NavigationRegion3D holding the
## shelter geometry; falling back to the map root keeps this from failing hard
## if that layer is ever renamed.
static func fixture_parent(map: Node3D) -> Node3D:
	var content := map.get_node_or_null("Content")
	if content != null and content is Node3D:
		return content as Node3D
	return map
