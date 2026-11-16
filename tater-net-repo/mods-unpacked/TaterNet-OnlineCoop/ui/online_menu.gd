extends Control

# Online Co-op panel opened from the main menu. Built in code so it picks up
# the game's own theme.

var coop
var _status: Label
var _players: Label
var _code: LineEdit
var _host_btn: Button
var _invite_btn: Button
var _copy_btn: Button
var _join_btn: Button
var _leave_btn: Button
var _public_toggle: CheckBox


func _ready() -> void:
	coop = get_node_or_null("/root/OnlineCoop")
	anchor_right = 1
	anchor_bottom = 1
	mouse_filter = MOUSE_FILTER_STOP

	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	dim.anchor_right = 1
	dim.anchor_bottom = 1
	add_child(dim)

	var center = CenterContainer.new()
	center.anchor_right = 1
	center.anchor_bottom = 1
	add_child(center)

	var panel = PanelContainer.new()
	panel.rect_min_size = Vector2(900, 0)
	center.add_child(panel)

	var margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_constant_override("margin_" + side, 32)
	panel.add_child(margin)

	var v = VBoxContainer.new()
	v.add_constant_override("separation", 16)
	margin.add_child(v)

	var title = Label.new()
	title.text = "Tater-Net: Online Co-op"
	title.align = Label.ALIGN_CENTER
	v.add_child(title)

	_status = Label.new()
	_status.autowrap = true
	_status.align = Label.ALIGN_CENTER
	v.add_child(_status)

	_players = Label.new()
	_players.autowrap = true
	v.add_child(_players)

	var host_row = HBoxContainer.new()
	host_row.add_constant_override("separation", 12)
	v.add_child(host_row)
	_host_btn = _button(host_row, "Host game", "_on_host")
	_invite_btn = _button(host_row, "Invite friends", "_on_invite")
	_copy_btn = _button(host_row, "Copy lobby code", "_on_copy")

	_public_toggle = CheckBox.new()
	_public_toggle.text = "Anyone with the lobby code can join (otherwise friends only)"
	_public_toggle.pressed = coop != null and coop.public_lobby
	_public_toggle.connect("toggled", self, "_on_public_toggled")
	v.add_child(_public_toggle)

	var join_row = HBoxContainer.new()
	join_row.add_constant_override("separation", 12)
	v.add_child(join_row)
	_code = LineEdit.new()
	_code.placeholder_text = "Lobby code"
	_code.size_flags_horizontal = SIZE_EXPAND_FILL
	_code.connect("text_entered", self, "_on_code_entered")
	join_row.add_child(_code)
	_join_btn = _button(join_row, "Join", "_on_join")

	var help = Label.new()
	help.autowrap = true
	help.text = "Host: click Host game, invite friends, then press Start and tick Co-op on the character screen. " \
		+ "Friends press A / Space there to join. While hosting, your single-player run is set aside and you get a separate online run slot.\n" \
		+ "Friends: accept the Steam invite, or paste the host's lobby code. Gamepad works as normal. " \
		+ "Keyboard: WASD move, arrows navigate menus, Space/Enter confirm, Backspace back, Esc pause, R/F extra buttons."
	v.add_child(help)

	var bottom = HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGN_END
	bottom.add_constant_override("separation", 12)
	v.add_child(bottom)
	_leave_btn = _button(bottom, "Stop hosting", "_on_leave")
	var back = _button(bottom, "Back", "_on_back")

	if coop:
		coop.connect("state_changed", self, "_refresh")
	_refresh()
	back.grab_focus()


func _button(parent: Node, text: String, method: String) -> Button:
	var b = Button.new()
	b.text = text
	b.connect("pressed", self, method)
	parent.add_child(b)
	return b


func _process(_delta: float) -> void:
	# Player list changes without a signal; keep it fresh while open.
	if coop and coop.is_host():
		var names = coop.get_peer_names()
		_players.text = "Players: you (slot 0)" + ("" if names.empty() else ", " + PoolStringArray(names).join(", "))


func _refresh() -> void:
	if coop == null or not coop.is_available():
		_status.text = coop.status_text if coop else "Tater-Net failed to load."
		for b in [_host_btn, _invite_btn, _copy_btn, _join_btn, _leave_btn]:
			b.disabled = true
		return
	var hosting = coop.is_host()
	_status.text = coop.status_text if coop.status_text != "" else "Not connected."
	if hosting and coop.lobby_id > 0:
		_status.text += "\nLobby code: " + str(coop.lobby_id)
	_host_btn.disabled = coop.in_session()
	_invite_btn.disabled = not (hosting and coop.lobby_id > 0)
	_copy_btn.disabled = _invite_btn.disabled
	_join_btn.disabled = coop.in_session()
	_leave_btn.disabled = not hosting
	_public_toggle.disabled = coop.in_session()
	_players.visible = hosting


func _on_host() -> void:
	coop.host_game()
	_refresh()


func _on_invite() -> void:
	coop.invite_friends()


func _on_copy() -> void:
	OS.set_clipboard(str(coop.lobby_id))
	_status.text = "Lobby code copied: " + str(coop.lobby_id)


func _on_public_toggled(on: bool) -> void:
	coop.public_lobby = on
	coop._config.set_value("net", "public_lobby", on)
	coop._config.save(coop.CONFIG_PATH)


func _on_code_entered(_t: String) -> void:
	_on_join()


func _on_join() -> void:
	var text = _code.text.strip_edges()
	if not text.is_valid_integer():
		_status.text = "A lobby code is a long number, like 109775241212345678."
		return
	coop.join_lobby(int(text))


func _on_leave() -> void:
	coop.leave_session()


func _on_back() -> void:
	queue_free()
	if coop and coop.menu_needs_refresh:
		coop.menu_needs_refresh = false
		get_tree().reload_current_scene()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().set_input_as_handled()
		_on_back()
