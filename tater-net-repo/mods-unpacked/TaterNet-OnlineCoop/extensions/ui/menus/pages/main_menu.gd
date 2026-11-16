extends "res://ui/menus/pages/main_menu.gd"

# Adds a "Tater-Net" online co-op button above Start.

const OnlineMenu = preload("res://mods-unpacked/TaterNet-OnlineCoop/ui/online_menu.gd")

var online_button: Button


func _ready() -> void:
	if start_button == null or start_button.get_parent() == null:
		return
	var parent = start_button.get_parent()
	online_button = start_button.duplicate()
	online_button.name = "OnlineCoopButton"
	for c in online_button.get_signal_connection_list("pressed"):
		online_button.disconnect("pressed", c.target, c.method)
	var coop = get_node_or_null("/root/OnlineCoop")
	online_button.text = "Tater-Net (hosting)" if coop and coop.is_host() else "Tater-Net Online"
	online_button.connect("pressed", self, "_on_online_coop_pressed")
	parent.add_child(online_button)
	parent.move_child(online_button, start_button.get_index())
	online_button.focus_neighbour_bottom = start_button.get_path()
	start_button.focus_neighbour_top = online_button.get_path()


func _on_online_coop_pressed() -> void:
	var menu = OnlineMenu.new()
	add_child(menu)
