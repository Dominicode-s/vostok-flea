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
