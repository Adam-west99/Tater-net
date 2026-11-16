extends Reference

# Keeps the single-player run and the online run in separate files.
#
# Brotato stores the in-progress run in files named "run_*.json" (for example
# run_v3.json) inside its save folder, next to the progress file
# (save_v3.json). Unlocks and achievements live in the progress file, which is
# never touched here. Only the run files are swapped.
#
#   <save folder>/run_v3.json                       <- the run the game sees
#   <save folder>/taternet_slots/singleplayer/...   <- parked single-player run
#   <save folder>/taternet_slots/online/...         <- parked online run
#   <save folder>/taternet_slots/ACTIVE_ONLINE      <- marker: online run is live
#
# The single-player copy is only deleted after it has been copied back, so a
# crash at any point leaves at least one copy on disk.

const MOD_ID = "TaterNet-OnlineCoop"
const SLOT_DIR = "taternet_slots"
const MARKER = "ACTIVE_ONLINE"
const SINGLE = "singleplayer"
const ONLINE = "online"


static func is_online_slot_active() -> bool:
	for save_dir in _find_save_dirs():
		if File.new().file_exists(save_dir.plus_file(SLOT_DIR).plus_file(MARKER)):
			return true
	return false


# Park the single-player run and load the online run (if one was saved).
static func switch_to_online() -> void:
	if is_online_slot_active():
		return
	for save_dir in _find_save_dirs():
		var slots = save_dir.plus_file(SLOT_DIR)
		_ensure_dir(slots.plus_file(SINGLE))
		_ensure_dir(slots.plus_file(ONLINE))
		_clear_dir(slots.plus_file(SINGLE))
		_copy_run_files(save_dir, slots.plus_file(SINGLE))
		_write_marker(slots)
		_delete_run_files(save_dir)
		_copy_run_files(slots.plus_file(ONLINE), save_dir)
	_reload_game_data()
	_log("Switched to the online run slot")


# Park the online run and put the single-player run back.
static func switch_to_singleplayer() -> void:
	if not is_online_slot_active():
		return
	for save_dir in _find_save_dirs():
		_restore_dir(save_dir)
	_reload_game_data()
	_log("Switched back to the single-player run slot")


# Called from mod_main._init(), before the game loads its save, so it only
# moves files and never calls into game code.
static func recover_after_crash() -> void:
	for save_dir in _find_save_dirs():
		if File.new().file_exists(save_dir.plus_file(SLOT_DIR).plus_file(MARKER)):
			_restore_dir(save_dir)
			_log("Restored the single-player run after the game closed during an online session (" + save_dir + ")")


static func _restore_dir(save_dir: String) -> void:
	var slots = save_dir.plus_file(SLOT_DIR)
	if not File.new().file_exists(slots.plus_file(MARKER)):
		return
	_ensure_dir(slots.plus_file(ONLINE))
	_clear_dir(slots.plus_file(ONLINE))
	_copy_run_files(save_dir, slots.plus_file(ONLINE))
	_delete_run_files(save_dir)
	_copy_run_files(slots.plus_file(SINGLE), save_dir)
	var d = Directory.new()
	d.remove(slots.plus_file(MARKER))


static func _reload_game_data() -> void:
	var tree = Engine.get_main_loop()
	if not tree or not tree.root.has_node("ProgressData"):
		return
	var pd = tree.root.get_node("ProgressData")
	if pd.has_method("load_game_file"):
		pd.load_game_file()
	else:
		_log("ProgressData.load_game_file() not found: restart the game to see the swapped run")


# Brotato keeps saves in user://<steam id>/ (or user://user/ outside Steam).
# Any folder holding save_*.json or run_*.json counts.
static func _find_save_dirs() -> Array:
	var result = []
	for candidate in ["user://"] + _subdirs("user://"):
		for f in _files(candidate):
			if f.ends_with(".json") and (f.begins_with("save_") or f.begins_with("run_")):
				result.append(candidate)
				break
	return result


static func _is_run_file(name: String) -> bool:
	return name.begins_with("run_")


static func _copy_run_files(from_dir: String, to_dir: String) -> void:
	var d = Directory.new()
	for f in _files(from_dir):
		if _is_run_file(f):
			var err = d.copy(from_dir.plus_file(f), to_dir.plus_file(f))
			if err != OK:
				_log("Could not copy " + from_dir.plus_file(f) + " (error " + str(err) + ")")


static func _delete_run_files(dir_path: String) -> void:
	var d = Directory.new()
	for f in _files(dir_path):
		if _is_run_file(f):
			d.remove(dir_path.plus_file(f))


static func _clear_dir(dir_path: String) -> void:
	var d = Directory.new()
	for f in _files(dir_path):
		d.remove(dir_path.plus_file(f))


static func _write_marker(slots: String) -> void:
	var f = File.new()
	if f.open(slots.plus_file(MARKER), File.WRITE) == OK:
		f.store_string(str(OS.get_unix_time()))
		f.close()


static func _ensure_dir(path: String) -> void:
	var d = Directory.new()
	if not d.dir_exists(path):
		d.make_dir_recursive(path)


static func _files(path: String) -> Array:
	return _list(path, false)


static func _subdirs(path: String) -> Array:
	var out = []
	for n in _list(path, true):
		out.append(path.plus_file(n))
	return out


static func _list(path: String, want_dirs: bool) -> Array:
	var out = []
	var d = Directory.new()
	if d.open(path) != OK:
		return out
	d.list_dir_begin(true, true)
	var n = d.get_next()
	while n != "":
		if d.current_is_dir() == want_dirs and n != SLOT_DIR:
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	return out


static func _log(msg: String) -> void:
	ModLoaderLog.info(msg, MOD_ID)
