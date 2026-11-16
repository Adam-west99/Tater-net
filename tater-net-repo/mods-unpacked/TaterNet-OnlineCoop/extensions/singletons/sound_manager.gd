extends "res://singletons/sound_manager.gd"

# Host: forward sounds to remote players.


func play(sound: Resource, volume_mod: float = 0.0, pitch_rand: float = 0.0, always_play: bool = false) -> void:
	var coop = get_node_or_null("/root/OnlineCoop")
	if coop and coop.is_host():
		coop.on_sound(sound, volume_mod, pitch_rand)
	.play(sound, volume_mod, pitch_rand, always_play)
