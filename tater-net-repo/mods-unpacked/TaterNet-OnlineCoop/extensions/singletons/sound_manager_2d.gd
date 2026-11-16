extends "res://singletons/sound_manager_2d.gd"

# Host: forward positional sounds to remote players (played without position).


func play(sound: Resource, pos: Vector2, volume_mod: float = 0.0, pitch_rand: float = 0.0, always_play: bool = false) -> void:
	var coop = get_node_or_null("/root/OnlineCoop")
	if coop and coop.is_host():
		coop.on_sound(sound, volume_mod - 4.0, pitch_rand)
	.play(sound, pos, volume_mod, pitch_rand, always_play)
