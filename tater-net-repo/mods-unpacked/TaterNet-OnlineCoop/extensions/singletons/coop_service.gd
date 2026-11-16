extends "res://singletons/coop_service.gd"

# Remote players use virtual gamepad device ids (100-103). They are gamepads,
# even though Godot has no physical joypad with that id.


func is_player_using_gamepad(player_index) -> bool:
	var device = get_remapped_player_device(player_index)
	if device >= 100 and device < 104:
		return true
	return .is_player_using_gamepad(player_index)
