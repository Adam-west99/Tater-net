extends Node

# Lives at /root/OnlineCoop. Owns the Steam lobby, the P2P traffic, and the
# host or client half of an online session.
#
# HOST:   runs Brotato's normal local co-op. Each remote friend is a virtual
#         gamepad (device 100 + slot) driven by the input they send.
#         Streams screen snapshots, sounds, achievements and run results.
# CLIENT: shows the host's screen (client/mirror_view.gd) and sends input.
#         Applies achievements and run results to its OWN save and Steam
#         account.

signal state_changed

const MOD_ID = "TaterNet-OnlineCoop"
const P = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/protocol.gd")
const MirrorCapture = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/mirror_capture.gd")
const MirrorView = preload("res://mods-unpacked/TaterNet-OnlineCoop/client/mirror_view.gd")
const SaveSlots = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/save_slots.gd")
const CONFIG_PATH = "user://taternet_online_coop.cfg"

# Steamworks enum values (hard-coded so this file parses without GodotSteam)
const SEND_UNRELIABLE = 0
const SEND_RELIABLE = 2
const LOBBY_FRIENDS_ONLY = 1
const LOBBY_PUBLIC = 2
const CHAT_ENTERED = 1

enum Role { NONE, HOST, CLIENT }

var steam = null
var role = Role.NONE
var lobby_id := 0
var my_id := 0
var host_id := 0
var host_name := ""
var status_text := ""
var snapshot_rate := 20
var public_lobby := false
# The run save slot changed under the open main menu; it must be reloaded so
# "Continue" shows the right run.
var menu_needs_refresh := false

# HOST: steam_id -> {name, slot, device, axes:[lx,ly,rx,ry], buttons, seq, last_ms, joined}
var peers := {}
var _capture = null
var _snapshot_frame := 0
var _next_snapshot_ms := 0
var _sounds := []
var _known_challenges := {}
var _ach_baseline_taken := false
var _sent_achievements := {}
var _next_ach_poll_ms := 0
var _last_scene_id := 0
var _reported_scene_id := 0
var _config := ConfigFile.new()

# CLIENT
var _view = null
var _chunks := {}  # frame -> {count, parts: {}}
var _latest_frame := -1
var _pending_res := {}
var _client_seen_ach := {}


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	_config.load(CONFIG_PATH)
	snapshot_rate = int(_config.get_value("net", "snapshot_rate", 20))
	public_lobby = bool(_config.get_value("net", "public_lobby", false))

	if Engine.has_singleton("Steam"):
		steam = Engine.get_singleton("Steam")
	if steam == null:
		status_text = "Steam is not available: online co-op needs the Steam version of Brotato."
		ModLoaderLog.warning(status_text, MOD_ID)
		return
	my_id = steam.getSteamID()
	steam.connect("lobby_created", self, "_on_lobby_created")
	steam.connect("lobby_joined", self, "_on_lobby_joined")
	steam.connect("lobby_chat_update", self, "_on_lobby_chat_update")
	steam.connect("p2p_session_request", self, "_on_p2p_session_request")
	if steam.has_signal("join_requested"):
		steam.connect("join_requested", self, "_on_join_requested")

	# Launched by clicking "Join game" in the Steam friends list.
	var args = OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "+connect_lobby" and i + 1 < args.size():
			call_deferred("join_lobby", int(args[i + 1]))


func is_available() -> bool:
	return steam != null


func is_host() -> bool:
	return role == Role.HOST


func is_client() -> bool:
	return role == Role.CLIENT


func in_session() -> bool:
	return role != Role.NONE


func _set_status(text: String) -> void:
	status_text = text
	ModLoaderLog.info(text, MOD_ID)
	emit_signal("state_changed")


# =================================================================== lobby

func host_game() -> void:
	if steam == null or in_session():
		return
	role = Role.HOST
	host_id = my_id
	host_name = steam.getPersonaName()
	_capture = MirrorCapture.new()
	peers.clear()
	SaveSlots.switch_to_online()
	menu_needs_refresh = true
	_set_status("Creating lobby...")
	steam.createLobby(LOBBY_PUBLIC if public_lobby else LOBBY_FRIENDS_ONLY, P.MAX_PLAYERS)


func join_lobby(id: int) -> void:
	if steam == null or id <= 0:
		return
	if in_session():
		leave_session()
	_set_status("Joining lobby...")
	steam.joinLobby(id)


func invite_friends() -> void:
	if steam and lobby_id > 0:
		steam.activateGameOverlayInviteDialog(lobby_id)


func leave_session() -> void:
	if not in_session():
		return
	var was_host = is_host()
	_broadcast({"t": "bye"})
	if lobby_id > 0:
		steam.leaveLobby(lobby_id)
	for id in peers:
		_release_all(peers[id])
		steam.closeP2PSessionWithUser(id)
	if host_id != my_id and host_id != 0:
		steam.closeP2PSessionWithUser(host_id)
	steam.clearRichPresence()
	role = Role.NONE
	lobby_id = 0
	peers.clear()
	_capture = null
	_chunks.clear()
	_latest_frame = -1

	if _view:
		_view = null
	if was_host:
		# Drop the remote friends' virtual controllers from local co-op.
		var cs = get_node_or_null("/root/CoopService")
		if cs and cs.has_method("clear_coop_players"):
			cs.clear_coop_players()
		SaveSlots.switch_to_singleplayer()
	_set_status("Left the online game.")
	_go_to_title()


func _go_to_title() -> void:
	menu_needs_refresh = false
	get_tree().paused = false
	var scene = "res://ui/menus/title_screen/title_screen.tscn"
	var md = get_node_or_null("/root/MenuData")
	if md and "title_screen_scene" in md:
		scene = md.title_screen_scene
	get_tree().change_scene(scene)


func _on_lobby_created(result: int, id: int) -> void:
	if result != 1:
		_set_status("Could not create a Steam lobby (error %d)." % result)
		role = Role.NONE
		SaveSlots.switch_to_singleplayer()
		return
	lobby_id = id
	steam.setLobbyJoinable(lobby_id, true)
	steam.setLobbyData(lobby_id, "taternet_coop", str(P.PROTOCOL_VERSION))
	steam.setLobbyData(lobby_id, "host_name", host_name)
	steam.setRichPresence("connect", "+connect_lobby " + str(lobby_id))
	steam.setRichPresence("status", "Hosting online co-op")
	_set_status("Hosting. Invite friends, then start a run with Co-op turned on.")


func _on_join_requested(id: int, _friend_id: int) -> void:
	join_lobby(id)


func _on_lobby_joined(id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:
		_set_status("Could not join that lobby (Steam response %d)." % response)
		if not is_host():
			role = Role.NONE
		return
	lobby_id = id
	var owner = steam.getLobbyOwner(id)
	if owner == my_id:
		return  # our own lobby (host)
	if steam.getLobbyData(id, "taternet_coop") != str(P.PROTOCOL_VERSION):
		_set_status("That lobby is not running a compatible version of Online Co-op.")
		steam.leaveLobby(id)
		lobby_id = 0
		return
	role = Role.CLIENT
	host_id = owner
	host_name = steam.getFriendPersonaName(owner)
	_send(host_id, {"t": "hello", "name": steam.getPersonaName(), "proto": P.PROTOCOL_VERSION, "mod": P.MOD_VERSION, "game": ProjectSettings.get_setting("application/config/version") if ProjectSettings.has_setting("application/config/version") else ""}, P.CH_CONTROL, SEND_RELIABLE)
	steam.setRichPresence("status", "Playing online co-op")
	_set_status("Joined " + host_name + "'s game. Waiting for the host...")
	_show_mirror()


func _on_lobby_chat_update(id: int, changed_id: int, _making_change: int, chat_state: int) -> void:
	if id != lobby_id:
		return
	if chat_state == CHAT_ENTERED:
		return  # host waits for the "hello" packet
	# Someone left, disconnected, was kicked or banned.
	if is_host() and peers.has(changed_id):
		_release_all(peers[changed_id])
		_set_status(peers[changed_id].name + " left the game.")
		peers.erase(changed_id)
	elif is_client() and changed_id == host_id:
		_set_status("The host left the game.")
		leave_session()


func _on_p2p_session_request(remote_id: int) -> void:
	# Only accept people who are in our lobby.
	if lobby_id > 0:
		for i in steam.getNumLobbyMembers(lobby_id):
			if steam.getLobbyMemberByIndex(lobby_id, i) == remote_id:
				steam.acceptP2PSessionWithUser(remote_id)
				return


# ================================================================ transport

func _send(target: int, data: Dictionary, channel: int, mode: int) -> void:
	steam.sendP2PPacket(target, P.encode_control(data), mode, channel)


func _send_raw(target: int, bytes: PoolByteArray, channel: int, mode: int) -> void:
	steam.sendP2PPacket(target, bytes, mode, channel)


func _broadcast(data: Dictionary) -> void:
	if steam == null:
		return
	if is_host():
		for id in peers:
			_send(id, data, P.CH_CONTROL, SEND_RELIABLE)
	elif is_client():
		_send(host_id, data, P.CH_CONTROL, SEND_RELIABLE)


func _read_channel(channel: int) -> void:
	var size = steam.getAvailableP2PPacketSize(channel)
	var guard = 0
	while size > 0 and guard < 512:
		guard += 1
		var packet = steam.readP2PPacket(size, channel)
		size = steam.getAvailableP2PPacketSize(channel)
		if packet == null or packet.empty():
			continue
		var sender = 0
		for k in ["remote_steam_id", "steam_id_remote", "steam_id"]:
			if packet.has(k):
				sender = int(packet[k])
				break
		var data: PoolByteArray = packet.get("data", PoolByteArray())
		if channel == P.CH_CONTROL:
			var msg = P.decode_control(data)
			if msg != null:
				_on_control(sender, msg)
		elif channel == P.CH_SNAPSHOT:
			if is_client() and sender == host_id:
				_on_snapshot_chunk(data)
		elif channel == P.CH_INPUT:
			if is_host() and peers.has(sender):
				_on_remote_input(peers[sender], data)


func _process(_delta: float) -> void:
	if steam == null:
		return
	steam.run_callbacks()
	if not in_session():
		return
	_read_channel(P.CH_CONTROL)
	_read_channel(P.CH_SNAPSHOT)
	_read_channel(P.CH_INPUT)
	if is_host():
		_host_tick()


func _on_control(sender: int, msg: Dictionary) -> void:
	var t = msg.get("t", "")
	if is_host():
		match t:
			"hello": _on_hello(sender, msg)
			"bye":
				if peers.has(sender):
					_release_all(peers[sender])
					_set_status(peers[sender].name + " left the game.")
					peers.erase(sender)
		return
	if not is_client() or sender != host_id:
		return
	match t:
		"welcome":
			_pending_res = msg.get("res", {})
			if _view:
				_view.add_resources(_pending_res)
			_set_status("Connected to " + host_name + " as player slot " + str(msg.get("slot", "?")) + ".")
		"res":
			if _view:
				_view.add_resources(msg.get("add", {}))
		"snd": _play_sounds(msg.get("list", []))
		"ach": _apply_achievement(str(msg.get("id", "")))
		"run": _apply_run_report(msg)
		"full": _set_status("The host's game is full.")
		"bye":
			_set_status("The host ended the game.")
			leave_session()


# ===================================================================== HOST

func _on_hello(sender: int, msg: Dictionary) -> void:
	if int(msg.get("proto", 0)) != P.PROTOCOL_VERSION:
		_send(sender, {"t": "bye"}, P.CH_CONTROL, SEND_RELIABLE)
		return
	if peers.has(sender):
		_send_welcome(sender)
		return
	var slot = _pick_slot(sender)
	if slot < 0:
		_send(sender, {"t": "full"}, P.CH_CONTROL, SEND_RELIABLE)
		return
	peers[sender] = {
		"name": str(msg.get("name", "Player")), "slot": slot, "device": P.DEVICE_BASE + slot,
		"axes": [0.0, 0.0, 0.0, 0.0], "buttons": 0, "seq": 0, "last_ms": OS.get_ticks_msec(), "join_tries": 0,
		"counts": null, "logical": 0, "queues": [], "last_emit": [],
	}
	for i in P.BUTTONS.size():
		peers[sender].queues.append([])
		peers[sender].last_emit.append(-1)
	_config.set_value("slots", str(sender), slot)
	_config.save(CONFIG_PATH)
	_send_welcome(sender)
	if msg.get("game", "") != "" and ProjectSettings.has_setting("application/config/version") \
			and msg.get("game") != ProjectSettings.get_setting("application/config/version"):
		_set_status(peers[sender].name + " joined, but has a different game version. Things may look wrong.")
	else:
		_set_status(peers[sender].name + " joined. They press A (or Space) on the character screen to join in.")
	_snapshot_known_achievements()


# Reuse the slot a friend had last time so a saved online run can be resumed
# with the same people controlling the same characters.
func _pick_slot(steam_id: int) -> int:
	var used = {}
	for id in peers:
		used[peers[id].slot] = true
	var prev = int(_config.get_value("slots", str(steam_id), -1))
	if prev >= 1 and prev < P.MAX_PLAYERS and not used.has(prev):
		return prev
	for s in range(1, P.MAX_PLAYERS):
		if not used.has(s):
			return s
	return -1


func _send_welcome(target: int) -> void:
	_send(target, {"t": "welcome", "slot": peers[target].slot, "res": _capture.all_resources()}, P.CH_CONTROL, SEND_RELIABLE)


func get_peer_names() -> Array:
	var out = []
	for id in peers:
		out.append("%s (slot %d)" % [peers[id].name, peers[id].slot])
	return out


func _host_tick() -> void:
	var now = OS.get_ticks_msec()
	if peers.empty():
		_sounds.clear()
		return

	# Remote players who stopped sending input let go of everything.
	for id in peers:
		var p = peers[id]
		_flush_button_queues(p)
		if now - p.last_ms > 1000 and (p.logical != 0 or p.axes != [0.0, 0.0, 0.0, 0.0]):
			_release_all(p)

	if now >= _next_snapshot_ms:
		_next_snapshot_ms = now + int(1000.0 / max(5, snapshot_rate))
		_send_snapshot()

	if not _sounds.empty():
		_broadcast({"t": "snd", "list": _sounds})
		_sounds = []

	if now >= _next_ach_poll_ms:
		_next_ach_poll_ms = now + 1000
		_poll_achievements()
		_check_run_end()


func _send_snapshot() -> void:
	var data = _capture.capture(get_tree(), self)
	var new_res = _capture.take_new_resources()
	if not new_res.empty():
		_broadcast({"t": "res", "add": new_res})
	_snapshot_frame += 1
	var count = int(ceil(float(data.size()) / P.CHUNK_PAYLOAD))
	if count > 255:
		ModLoaderLog.warning("Snapshot too large (%d bytes), skipped" % data.size(), MOD_ID, true)
		return
	var parts = []
	for i in count:
		parts.append(data.subarray(i * P.CHUNK_PAYLOAD, min(data.size(), (i + 1) * P.CHUNK_PAYLOAD) - 1))
	for i in count:
		_send_chunk(_snapshot_frame, i, count, 0, data.size(), parts[i])
	# One XOR recovery chunk per group, so a single lost chunk per group can
	# be rebuilt instead of losing the whole frame (see tests/netsim.py).
	var groups = int(ceil(float(count) / P.PARITY_GROUP))
	for g in groups:
		_send_chunk(_snapshot_frame, g, count, 1, data.size(), _xor_parts(parts, g * P.PARITY_GROUP, min(count, (g + 1) * P.PARITY_GROUP)))


func _send_chunk(frame: int, idx: int, count: int, kind: int, total: int, payload: PoolByteArray) -> void:
	var b = StreamPeerBuffer.new()
	b.put_u32(frame)
	b.put_u8(idx)
	b.put_u8(count)
	b.put_u8(kind)
	b.put_u32(total)
	b.put_data(payload)
	for id in peers:
		_send_raw(id, b.data_array, P.CH_SNAPSHOT, SEND_UNRELIABLE)


static func _xor_parts(parts, first: int, last: int) -> PoolByteArray:
	var x = PoolByteArray()
	x.resize(P.CHUNK_PAYLOAD)
	for j in P.CHUNK_PAYLOAD:
		x[j] = 0
	for i in range(first, last):
		var part: PoolByteArray = parts[i]
		for j in part.size():
			x[j] = x[j] ^ part[j]
	return x


# ------------------------------------------------------- remote input (host)

func _on_remote_input(p: Dictionary, data: PoolByteArray) -> void:
	if data.size() < 24:
		return
	var b = StreamPeerBuffer.new()
	b.data_array = data
	var seq = b.get_u32()
	if seq <= p.seq and p.seq - seq < 100000:
		return  # old or duplicate packet
	p.seq = seq
	p.last_ms = OS.get_ticks_msec()
	var axes = [b.get_float(), b.get_float(), b.get_float(), b.get_float()]
	var buttons = b.get_u32()
	var counts = null
	if data.size() >= 24 + P.BUTTONS.size():
		counts = []
		for i in P.BUTTONS.size():
			counts.append(b.get_u8())

	for a in 4:
		var v = clamp(axes[a], -1.0, 1.0)
		if abs(v - p.axes[a]) > 0.01:
			p.axes[a] = v
			var ev = InputEventJoypadMotion.new()
			ev.device = p.device
			ev.axis = a
			ev.axis_value = v
			Input.parse_input_event(ev)

	# Buttons: replay presses that happened between samples or were in lost
	# packets (press counters), then follow the sampled state. Tested in
	# tests/netsim.py against Mac/Windows frame rates and packet loss.
	for i in P.BUTTONS.size():
		var down = buttons & (1 << i) != 0
		if counts != null and p.counts != null:
			var missed = (counts[i] - p.counts[i]) & 0xFF
			if missed > 0 and missed < 128:
				var n = min(missed, 4)
				for k in n:
					if _logical(p, i):
						_push_button(p, i, false)
					_push_button(p, i, true)
					if k < n - 1 or not down:
						_push_button(p, i, false)
		if down != _logical(p, i):
			_push_button(p, i, down)
	if counts != null:
		p.counts = counts
	p.buttons = buttons


func _logical(p: Dictionary, i: int) -> bool:
	return p.logical & (1 << i) != 0


# Queue a button change; at most one change per button per frame reaches the
# game, so a replayed press and its release never land in the same frame.
func _push_button(p: Dictionary, i: int, pressed: bool) -> void:
	if pressed:
		p.logical |= 1 << i
	else:
		p.logical &= ~(1 << i)
	if p.queues[i].empty() and p.last_emit[i] != Engine.get_idle_frames():
		_emit_button(p, i, pressed)
	else:
		p.queues[i].append(pressed)


func _emit_button(p: Dictionary, i: int, pressed: bool) -> void:
	p.last_emit[i] = Engine.get_idle_frames()
	var ev = InputEventJoypadButton.new()
	ev.device = p.device
	ev.button_index = P.BUTTONS[i]
	ev.pressed = pressed
	ev.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)
	if pressed and P.BUTTONS[i] == JOY_XBOX_A:
		call_deferred("_ensure_joined", p)


func _flush_button_queues(p: Dictionary) -> void:
	var frame = Engine.get_idle_frames()
	for i in P.BUTTONS.size():
		if not p.queues[i].empty() and p.last_emit[i] != frame:
			_emit_button(p, i, p.queues[i].pop_front())


func _release_all(p: Dictionary) -> void:
	for i in P.BUTTONS.size():
		p.queues[i].clear()
		if _logical(p, i):
			p.logical &= ~(1 << i)
			_emit_button(p, i, false)
	p.buttons = 0
	for a in 4:
		if p.axes[a] != 0.0:
			p.axes[a] = 0.0
			var ev = InputEventJoypadMotion.new()
			ev.device = p.device
			ev.axis = a
			ev.axis_value = 0.0
			Input.parse_input_event(ev)


# Movement vector for player_movement_behavior (deadzone applied).
func get_remote_movement(device: int) -> Vector2:
	for id in peers:
		if peers[id].device == device:
			var v = Vector2(peers[id].axes[0], peers[id].axes[1])
			if v.length() < 0.2:
				return Vector2.ZERO
			return v.clamped(1.0)
	return Vector2.ZERO


static func is_remote_device(device: int) -> bool:
	return device >= P.DEVICE_BASE and device < P.DEVICE_BASE + P.MAX_PLAYERS


# Pressing A on the character screen joins a local co-op player. If the game
# ignored our virtual gamepad, register it directly.
func _ensure_joined(p: Dictionary) -> void:
	var cs = get_node_or_null("/root/CoopService")
	if cs == null or not ("listening_for_inputs" in cs) or not cs.listening_for_inputs:
		return
	yield(get_tree().create_timer(0.25), "timeout")
	if not is_host() or _player_index_for_device(p.device) >= 0:
		return
	if not cs.has_method("_add_player"):
		return
	p.join_tries += 1
	if p.join_tries > 3:
		return
	cs._add_player(p.device, _gamepad_player_type(cs))
	ModLoaderLog.info("Registered %s as co-op device %d" % [p.name, p.device], MOD_ID)


func _gamepad_player_type(cs) -> int:
	var consts = cs.get_script().get_script_constant_map() if cs.get_script() else {}
	for cname in consts:
		var c = consts[cname]
		if c is Dictionary:
			for k in c:
				var key = str(k).to_upper()
				if "GAMEPAD" in key or "JOYPAD" in key or "CONTROLLER" in key:
					return int(c[k])
	return 1


func _player_index_for_device(device: int) -> int:
	var cs = get_node_or_null("/root/CoopService")
	var rd = get_node_or_null("/root/RunData")
	if cs == null or rd == null or not rd.has_method("get_player_count") or not cs.has_method("get_remapped_player_device"):
		return -1
	for i in rd.get_player_count():
		if cs.get_remapped_player_device(i) == device:
			return i
	return -1


# ------------------------------------------------------------ sounds (host)

func on_sound(sound: Resource, volume_mod: float, pitch_rand: float) -> void:
	if not is_host() or peers.empty() or sound == null or sound.resource_path == "":
		return
	if _sounds.size() < 48:
		_sounds.append([sound.resource_path, volume_mod, pitch_rand])


# ------------------------------------------------------ achievements (host)

# Challenges/achievements that unlock while hosting are passed on to everyone.
func _snapshot_known_achievements() -> void:
	_ach_baseline_taken = true
	for id in _list_completed():
		_known_challenges[id] = true


func _poll_achievements() -> void:
	if not _ach_baseline_taken:
		_snapshot_known_achievements()
		return
	for id in _list_completed():
		if not _known_challenges.has(id):
			_known_challenges[id] = true
			if not _sent_achievements.has(id):
				_sent_achievements[id] = true
				_broadcast({"t": "ach", "id": id})


func _list_completed() -> Array:
	var out = []
	var pd = get_node_or_null("/root/ProgressData")
	if pd:
		for prop in ["challenges_completed", "completed_challenges"]:
			if prop in pd and pd.get(prop) is Array:
				for c in pd.get(prop):
					out.append(str(c.my_id) if c is Object and "my_id" in c else str(c))
	if steam:
		for i in steam.getNumAchievements():
			var api = steam.getAchievementName(i)
			var r = steam.getAchievement(api)
			if r is Dictionary and r.get("achieved", false):
				out.append("steam:" + api)
	return out


# When the run ends, tell each remote player how THEIR character did, so
# their own game records the win/difficulty and unlocks the achievements.
func _check_run_end() -> void:
	var scene = get_tree().current_scene
	if scene == null:
		return
	var sid = scene.get_instance_id()
	if sid == _last_scene_id:
		return
	_last_scene_id = sid
	var fname = scene.filename.to_lower()
	if not ("end_run" in fname or "endrun" in scene.name.to_lower()):
		return
	if _reported_scene_id == sid:
		return
	_reported_scene_id = sid
	var rd = get_node_or_null("/root/RunData")
	if rd == null:
		return
	for id in peers:
		var idx = _player_index_for_device(peers[id].device)
		if idx < 0:
			continue
		var report = _run_report(rd, idx)
		if not report.empty():
			_send(id, report, P.CH_CONTROL, SEND_RELIABLE)


func _run_report(rd, idx: int) -> Dictionary:
	var character = null
	if "players_data" in rd and idx < rd.players_data.size():
		var pdata = rd.players_data[idx]
		if pdata and "current_character" in pdata:
			character = pdata.current_character
	if character == null or not ("my_id" in character):
		return {}
	var acc = rd.current_run_accessibility_settings if "current_run_accessibility_settings" in rd else null
	return {
		"t": "run",
		"won": bool(rd.run_won) if "run_won" in rd else false,
		"character_id": str(character.my_id),
		"character_chal": "chal_" + str(character.name).to_lower().replace("character_", ""),
		"difficulty": rd.get_current_difficulty() if rd.has_method("get_current_difficulty") else 0,
		"zone": rd.current_zone if "current_zone" in rd else 0,
		"wave": rd.current_wave if "current_wave" in rd else 0,
		"endless": bool(rd.is_endless_run) if "is_endless_run" in rd else false,
		"acc": [acc.health, acc.damage, acc.speed] if acc and "health" in acc else [100, 100, 100],
	}


# =================================================================== CLIENT

func _show_mirror() -> void:
	var tree = get_tree()
	var old = tree.current_scene
	_view = MirrorView.new(self)
	if not _pending_res.empty():
		_view.add_resources(_pending_res)
	tree.root.add_child(_view)
	tree.current_scene = _view
	if old and old != _view:
		old.queue_free()
	tree.paused = false


func send_input(bytes: PoolByteArray) -> void:
	if is_client():
		_send_raw(host_id, bytes, P.CH_INPUT, SEND_UNRELIABLE)


func _on_snapshot_chunk(data: PoolByteArray) -> void:
	if data.size() < 12 or _view == null:
		return
	var b = StreamPeerBuffer.new()
	b.data_array = data
	var frame = b.get_u32()
	var idx = b.get_u8()
	var count = b.get_u8()
	var kind = b.get_u8()
	var total = b.get_u32()
	if count == 0 or frame <= _latest_frame and _latest_frame - frame < 100000:
		return
	if not _chunks.has(frame):
		_chunks[frame] = {"count": count, "total": total, "parts": {}, "parity": {}}
	var e = _chunks[frame]
	var payload = data.subarray(11, data.size() - 1)
	if kind == 0:
		e.parts[idx] = payload
	else:
		e.parity[idx] = payload
	_try_recover(e)
	if e.parts.size() == e.count:
		var full = PoolByteArray()
		for i in e.count:
			full.append_array(e.parts[i])
		_latest_frame = frame
		for f in _chunks.keys():
			if f <= frame:
				_chunks.erase(f)
		_view.apply_snapshot(full, host_name)
	# Drop frames that will never complete.
	if _chunks.size() > 8:
		var keys = _chunks.keys()
		keys.sort()
		_chunks.erase(keys[0])


# Rebuild a single missing chunk in a group from its XOR recovery chunk.
func _try_recover(e: Dictionary) -> void:
	for g in e.parity:
		var first = g * P.PARITY_GROUP
		var last = int(min(e.count, first + P.PARITY_GROUP))
		var missing = -1
		var n_missing = 0
		for i in range(first, last):
			if not e.parts.has(i):
				missing = i
				n_missing += 1
		if n_missing != 1:
			continue
		var x: PoolByteArray = e.parity[g]
		for i in range(first, last):
			if e.parts.has(i):
				var part: PoolByteArray = e.parts[i]
				for j in part.size():
					x[j] = x[j] ^ part[j]
		var length = P.CHUNK_PAYLOAD if missing < e.count - 1 else e.total - (e.count - 1) * P.CHUNK_PAYLOAD
		if length > 0 and length <= x.size():
			e.parts[missing] = x.subarray(0, length - 1)
		e.parity.erase(g)
		return  # dictionary changed; the next chunk will retry other groups


func _play_sounds(list: Array) -> void:
	var sm = get_node_or_null("/root/SoundManager")
	if sm == null:
		return
	for s in list:
		if s is Array and s.size() >= 3 and str(s[0]).begins_with("res://") and ResourceLoader.exists(str(s[0])):
			sm.play(load(str(s[0])), float(s[1]), float(s[2]), false)


# ------------------------------------------------- achievements (client side)

func _apply_achievement(id: String) -> void:
	if id == "" or _client_seen_ach.has(id):
		return
	_client_seen_ach[id] = true
	if id.begins_with("steam:"):
		var api = id.substr(6)
		var r = steam.getAchievement(api)
		if r is Dictionary and not r.get("achieved", false):
			steam.setAchievement(api)
			steam.storeStats()
			ModLoaderLog.info("Unlocked Steam achievement " + api, MOD_ID)
		return
	_complete_challenge(id)


func _complete_challenge(chal_id: String) -> void:
	var cs = get_node_or_null("/root/ChallengeService")
	if cs and cs.has_method("complete_challenge"):
		cs.complete_challenge(chal_id)
		ModLoaderLog.info("Completed challenge " + chal_id, MOD_ID)


func _apply_run_report(r: Dictionary) -> void:
	var pd = get_node_or_null("/root/ProgressData")
	_complete_challenge("chal_rookie")
	var acc = r.get("acc", [100, 100, 100])
	var difficulty = int(r.get("difficulty", 0))
	var zone = r.get("zone", 0)
	var info = null
	if pd and pd.has_method("get_character_difficulty_info"):
		info = pd.get_character_difficulty_info(r.get("character_id", ""), zone)

	if r.get("endless", false) and int(r.get("wave", 0)) >= 20 and info and "max_endless_wave_beaten" in info:
		info.max_endless_wave_beaten.set_info(difficulty, int(r.wave), acc[0], acc[1], acc[2], true)

	if r.get("won", false):
		_complete_challenge(str(r.get("character_chal", "")))
		_complete_challenge("chal_difficulty_" + str(difficulty))
		if pd and "difficulties_unlocked" in pd and "MAX_DIFFICULTY" in pd:
			for char_diff in pd.difficulties_unlocked:
				if "zones_difficulty_info" in char_diff:
					for zinfo in char_diff.zones_difficulty_info:
						zinfo.max_selectable_difficulty = clamp(difficulty + 1, zinfo.max_selectable_difficulty, pd.MAX_DIFFICULTY)
		if info and "max_difficulty_beaten" in info:
			info.max_difficulty_beaten.set_info(difficulty, int(r.get("wave", 20)), acc[0], acc[1], acc[2], false)

	if pd and pd.has_method("save"):
		pd.save()
	_set_status("Run finished. Your progress and achievements were saved on this PC.")
