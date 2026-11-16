extends "res://entities/units/movement_behaviors/player_movement_behavior.gd"

# Remote players move with the stick they send over the network.


func get_movement() -> Vector2:
	if device >= 100 and device < 104:
		var coop = get_node_or_null("/root/OnlineCoop")
		if coop:
			return coop.get_remote_movement(device)
	return .get_movement()
