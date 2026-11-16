extends Node

# Entry point loaded by Godot Mod Loader.

const MOD_ID = "TaterNet-OnlineCoop"
const SaveSlots = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/save_slots.gd")
const OnlineCoop = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/online_coop.gd")

var dir := ""


func _init() -> void:
	dir = ModLoaderMod.get_unpacked_dir() + MOD_ID + "/"

	# If the game closed while an online run was loaded, put the single-player
	# run back before the game reads its save files.
	SaveSlots.recover_after_crash()

	var ext = dir + "extensions/"
	ModLoaderMod.install_script_extension(ext + "singletons/coop_service.gd")
	ModLoaderMod.install_script_extension(ext + "singletons/sound_manager.gd")
	ModLoaderMod.install_script_extension(ext + "singletons/sound_manager_2d.gd")
	ModLoaderMod.install_script_extension(ext + "entities/units/movement_behaviors/player_movement_behavior.gd")
	ModLoaderMod.install_script_extension(ext + "ui/menus/pages/main_menu.gd")
	ModLoaderLog.info("Extensions installed", MOD_ID)


func _ready() -> void:
	var coop = OnlineCoop.new()
	coop.name = "OnlineCoop"
	get_tree().root.call_deferred("add_child", coop)
	ModLoaderLog.info("Ready", MOD_ID)
