extends Node2D

# CLIENT SIDE. Replaces the current scene while connected to a host.
# Rebuilds the host's screen from snapshots, and sends local controller or
# keyboard input back to the host as a virtual gamepad.

const P = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/protocol.gd")

# Keyboard fallbacks for each virtual gamepad button.
const KEYMAP = {
	JOY_XBOX_A: [KEY_SPACE, KEY_ENTER, KEY_E],
	JOY_XBOX_B: [KEY_BACKSPACE, KEY_Q],
	JOY_XBOX_X: [KEY_R],
	JOY_XBOX_Y: [KEY_F],
	JOY_L: [KEY_1],
	JOY_R: [KEY_2],
	JOY_START: [KEY_ESCAPE],
	JOY_SELECT: [KEY_TAB],
	JOY_DPAD_UP: [KEY_UP],
	JOY_DPAD_DOWN: [KEY_DOWN],
	JOY_DPAD_LEFT: [KEY_LEFT],
	JOY_DPAD_RIGHT: [KEY_RIGHT],
}

var coop  # OnlineCoop node
var res_paths := {}   # id -> path
var _res_cache := {}  # path -> Resource or null
var _atlas_cache := {}
var _holders := {}    # key -> {holder: Node2D, kind: int, visual: CanvasItem}
var _screen: Node2D
var _overlay: Label
var _host_size := Vector2(1920, 1080)
var _input_timer := 0.0
var _input_seq := 0
var _last_snapshot_ms := 0
var _frames_received := 0
# Every press is counted and latched until the next send, so taps shorter
# than one send interval (or in a lost packet) still reach the host.
var _press_counts := []
var _latch := 0


func _init(owner_coop) -> void:
	coop = owner_coop
	name = "OnlineCoopMirror"
	pause_mode = PAUSE_MODE_PROCESS


func _ready() -> void:
	for i in P.BUTTONS.size():
		_press_counts.append(0)
	_screen = Node2D.new()
	add_child(_screen)

	var layer = CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_overlay = Label.new()
	_overlay.rect_position = Vector2(16, 8)
	_overlay.add_color_override("font_color", Color(1, 1, 1, 0.85))
	_overlay.add_color_override("font_color_shadow", Color(0, 0, 0, 1))
	layer.add_child(_overlay)
	_set_overlay("Connecting to host...")


func _set_overlay(text: String) -> void:
	_overlay.text = "Tater-Net  |  " + text + "\nF8: leave online game"


func add_resources(table: Dictionary) -> void:
	for id in table:
		res_paths[int(id)] = str(table[id])


func _res(id: int) -> Resource:
	if id == 0 or not res_paths.has(id):
		return null
	var path = res_paths[id]
	if not _res_cache.has(path):
		var r = null
		if path.begins_with("res://") and ResourceLoader.exists(path.split("::")[0]):
			r = load(path)
		_res_cache[path] = r
	return _res_cache[path]


func _atlas(tex_id: int, region: Rect2) -> Texture:
	var base = _res(tex_id)
	if base == null:
		return null
	var key = str(tex_id) + ":" + str(region)
	if not _atlas_cache.has(key):
		var a = AtlasTexture.new()
		a.atlas = base
		a.region = region
		_atlas_cache[key] = a
	return _atlas_cache[key]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.scancode == KEY_F8:
		coop.leave_session()


func _process(delta: float) -> void:
	# Stretch the host's screen to fit ours.
	var my_size = get_viewport_rect().size
	if _host_size.x > 0 and _host_size.y > 0:
		var s = min(my_size.x / _host_size.x, my_size.y / _host_size.y)
		_screen.scale = Vector2(s, s)
		_screen.position = (my_size - _host_size * s) / 2.0

	# Smooth positions between snapshots.
	var k = 1.0 - exp(-delta * 25.0)
	for key in _holders:
		var h = _holders[key]
		var holder: Node2D = h.holder
		var target: Transform2D = h.target
		var cur = holder.transform
		if cur.origin.distance_to(target.origin) > 160.0:
			holder.transform = target
		else:
			holder.transform = Transform2D(target.x, target.y, cur.origin.linear_interpolate(target.origin, k))

	_input_timer += delta
	if _input_timer >= 1.0 / 30.0:
		_input_timer = 0.0
		_send_input()

	if _frames_received > 0 and OS.get_ticks_msec() - _last_snapshot_ms > 3000:
		_set_overlay("Waiting for host... (no picture for %d s)" % ((OS.get_ticks_msec() - _last_snapshot_ms) / 1000))


# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	var pressed_button = -1
	if event is InputEventKey and event.pressed and not event.echo:
		for b in KEYMAP:
			if event.scancode in KEYMAP[b]:
				pressed_button = b
				break
	elif event is InputEventJoypadButton and event.pressed:
		var pads = Input.get_connected_joypads()
		if pads.size() > 0 and event.device == pads[0]:
			pressed_button = event.button_index
	if pressed_button < 0:
		return
	var i = P.BUTTONS.find(pressed_button)
	if i >= 0:
		_press_counts[i] = (_press_counts[i] + 1) & 0xFF
		_latch |= 1 << i


func _key(sc: int) -> bool:
	return Input.is_key_pressed(sc)


func _send_input() -> void:
	var pads = Input.get_connected_joypads()
	var pad = pads[0] if pads.size() > 0 else -1

	var lx = 0.0
	var ly = 0.0
	var rx = 0.0
	var ry = 0.0
	if pad >= 0:
		lx = Input.get_joy_axis(pad, JOY_AXIS_0)
		ly = Input.get_joy_axis(pad, JOY_AXIS_1)
		rx = Input.get_joy_axis(pad, JOY_AXIS_2)
		ry = Input.get_joy_axis(pad, JOY_AXIS_3)
	# Keyboard: WASD acts as the left stick.
	var kx = float(_key(KEY_D)) - float(_key(KEY_A))
	var ky = float(_key(KEY_S)) - float(_key(KEY_W))
	if kx != 0.0 or ky != 0.0:
		var v = Vector2(kx, ky).normalized()
		lx = v.x
		ly = v.y

	var buttons = 0
	for i in P.BUTTONS.size():
		var b = P.BUTTONS[i]
		var down = pad >= 0 and Input.is_joy_button_pressed(pad, b)
		if KEYMAP.has(b):
			for sc in KEYMAP[b]:
				down = down or _key(sc)
		if down:
			buttons |= 1 << i
	buttons |= _latch
	_latch = 0

	# Don't send input while this window isn't focused.
	if not OS.is_window_focused():
		lx = 0.0; ly = 0.0; rx = 0.0; ry = 0.0; buttons = 0
		_latch = 0

	_input_seq += 1
	var buf = StreamPeerBuffer.new()
	buf.put_u32(_input_seq)
	buf.put_float(lx)
	buf.put_float(ly)
	buf.put_float(rx)
	buf.put_float(ry)
	buf.put_u32(buttons)
	for c in _press_counts:
		buf.put_u8(c)
	coop.send_input(buf.data_array)


# ------------------------------------------------------------- snapshots

func apply_snapshot(compressed: PoolByteArray, host_name: String) -> void:
	var raw = compressed.decompress_dynamic(-1, File.COMPRESSION_DEFLATE)
	if raw.size() < 8:
		return
	_last_snapshot_ms = OS.get_ticks_msec()
	_frames_received += 1
	if _frames_received == 1 or _frames_received % 60 == 0:
		_set_overlay("Playing online with " + host_name)

	var b = StreamPeerBuffer.new()
	b.data_array = raw
	_host_size = Vector2(b.get_u16(), b.get_u16())
	var count = b.get_u32()
	var seen = {}
	for i in count:
		if b.get_position() >= raw.size():
			break
		var kind = b.get_u8()
		var key = b.get_u32()
		var t = Transform2D(Vector2(b.get_float(), b.get_float()), Vector2(b.get_float(), b.get_float()), Vector2(b.get_float(), b.get_float()))
		var h = _holder(key, kind)
		h.target = t
		if not h.has("shown"):
			h.holder.transform = t
			h.shown = true
		h.holder.z_index = clamp(i - 4000, -4096, 4096)
		_read_kind(kind, b, h.visual)
		h.holder.modulate = Color(b.get_u32())
		h.holder.visible = true
		seen[key] = true

	for key in _holders.keys():
		if not seen.has(key):
			_holders[key].holder.queue_free()
			_holders.erase(key)


func _holder(key: int, kind: int) -> Dictionary:
	if _holders.has(key) and _holders[key].kind == kind:
		return _holders[key]
	if _holders.has(key):
		_holders[key].holder.queue_free()
	var holder = Node2D.new()
	holder.z_as_relative = false
	var visual
	if kind == P.K_SPRITE: visual = Sprite.new()
	elif kind == P.K_TEXRECT: visual = TextureRect.new()
	elif kind == P.K_NINEPATCH: visual = NinePatchRect.new()
	elif kind == P.K_STYLEBOX: visual = Panel.new()
	elif kind == P.K_COLORRECT: visual = ColorRect.new()
	elif kind == P.K_LABEL: visual = Label.new()
	elif kind == P.K_RICHTEXT:
		visual = RichTextLabel.new()
		visual.scroll_active = false
	elif kind == P.K_TEXPROGRESS: visual = TextureProgress.new()
	elif kind == P.K_PROGRESSBAR:
		visual = ProgressBar.new()
		visual.percent_visible = false
	else: visual = Node2D.new()
	if visual is Control:
		visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual.focus_mode = Control.FOCUS_NONE
	holder.add_child(visual)
	_screen.add_child(holder)
	var h = {"holder": holder, "kind": kind, "visual": visual, "target": Transform2D()}
	_holders[key] = h
	return h


var _built_fonts := {}
var _built_styles := {}


func _read_font(b: StreamPeerBuffer):
	var id = b.get_u16()
	var data_id = b.get_u16()
	var size = b.get_u16()
	var outline = b.get_u8()
	var outline_col = b.get_u32()
	var f = _res(id)
	if f is Font:
		return f
	if data_id == 0:
		return null
	var key = "%d:%d:%d:%d" % [data_id, size, outline, outline_col]
	if not _built_fonts.has(key):
		var data = _res(data_id)
		var df = null
		if data is DynamicFontData:
			df = DynamicFont.new()
			df.font_data = data
			df.size = size
			df.outline_size = outline
			df.outline_color = Color(outline_col)
		_built_fonts[key] = df
	return _built_fonts[key]


func _read_stylebox(b: StreamPeerBuffer):
	var id = b.get_u16()
	var sb = _res(id)
	if b.get_u8() == 0:
		return sb if sb is StyleBox else null
	var bg = b.get_u32()
	var border = b.get_u32()
	var widths = [b.get_u8(), b.get_u8(), b.get_u8(), b.get_u8()]
	var radii = [b.get_u8(), b.get_u8(), b.get_u8(), b.get_u8()]
	var center = b.get_u8() != 0
	if sb is StyleBox:
		return sb
	var key = str([bg, border, widths, radii, center])
	if not _built_styles.has(key):
		var f = StyleBoxFlat.new()
		f.bg_color = Color(bg)
		f.border_color = Color(border)
		f.border_width_left = widths[0]
		f.border_width_top = widths[1]
		f.border_width_right = widths[2]
		f.border_width_bottom = widths[3]
		f.corner_radius_top_left = radii[0]
		f.corner_radius_top_right = radii[1]
		f.corner_radius_bottom_right = radii[2]
		f.corner_radius_bottom_left = radii[3]
		f.draw_center = center
		_built_styles[key] = f
	return _built_styles[key]


func _rect(b: StreamPeerBuffer) -> Rect2:
	return Rect2(b.get_float(), b.get_float(), b.get_float(), b.get_float())


func _read_kind(kind: int, b: StreamPeerBuffer, v) -> void:
	if kind == P.K_SPRITE:
		var tex = b.get_u16()
		var flags = b.get_u8()
		var hf = b.get_u16()
		var vf = b.get_u16()
		var fr = b.get_u16()
		v.offset = Vector2(b.get_float(), b.get_float())
		v.texture = _res(tex)
		v.centered = flags & 1 != 0
		v.flip_h = flags & 2 != 0
		v.flip_v = flags & 4 != 0
		v.region_enabled = flags & 8 != 0
		if v.region_enabled:
			v.region_rect = _rect(b)
		v.hframes = max(1, hf)
		v.vframes = max(1, vf)
		v.frame = min(fr, v.hframes * v.vframes - 1)
	elif kind == P.K_TEXRECT:
		var tex = b.get_u16()
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.stretch_mode = b.get_u8()
		var flags = b.get_u8()
		v.expand = flags & 1 != 0
		v.flip_h = flags & 2 != 0
		v.flip_v = flags & 4 != 0
		v.texture = _atlas(tex, _rect(b)) if flags & 8 != 0 else _res(tex)
	elif kind == P.K_NINEPATCH:
		v.texture = _res(b.get_u16())
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.region_rect = _rect(b)
		v.patch_margin_left = b.get_u16()
		v.patch_margin_top = b.get_u16()
		v.patch_margin_right = b.get_u16()
		v.patch_margin_bottom = b.get_u16()
		v.draw_center = b.get_u8() != 0
		v.axis_stretch_horizontal = b.get_u8()
		v.axis_stretch_vertical = b.get_u8()
	elif kind == P.K_STYLEBOX:
		var sb = _read_stylebox(b)
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.add_stylebox_override("panel", sb if sb else StyleBoxEmpty.new())
	elif kind == P.K_COLORRECT:
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.color = Color(b.get_u32())
	elif kind == P.K_LABEL:
		var font = _read_font(b)
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.align = b.get_u8()
		v.valign = b.get_u8()
		v.autowrap = b.get_u8() != 0
		v.clip_text = false
		v.add_color_override("font_color", Color(b.get_u32()))
		v.add_color_override("font_color_shadow", Color(b.get_u32()))
		if font is Font:
			v.add_font_override("font", font)
		v.text = b.get_utf8_string()
	elif kind == P.K_RICHTEXT:
		var font = _read_font(b)
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.add_color_override("default_color", Color(b.get_u32()))
		v.bbcode_enabled = b.get_u8() != 0
		if font is Font:
			v.add_font_override("normal_font", font)
		var text = b.get_utf8_string()
		if v.bbcode_enabled:
			if v.bbcode_text != text:
				v.bbcode_text = text
		elif v.text != text:
			v.text = text
	elif kind == P.K_TEXPROGRESS:
		v.texture_under = _res(b.get_u16())
		v.texture_progress = _res(b.get_u16())
		v.texture_over = _res(b.get_u16())
		v.rect_size = Vector2(b.get_float(), b.get_float())
		v.fill_mode = b.get_u8()
		v.min_value = 0
		v.max_value = 1
		v.step = 0
		v.value = b.get_float()
		v.nine_patch_stretch = b.get_u8() != 0
		v.stretch_margin_left = b.get_u16()
		v.stretch_margin_top = b.get_u16()
		v.stretch_margin_right = b.get_u16()
		v.stretch_margin_bottom = b.get_u16()
		v.tint_under = Color(b.get_u32())
		v.tint_progress = Color(b.get_u32())
		v.tint_over = Color(b.get_u32())
	elif kind == P.K_PROGRESSBAR:
		var bg = _read_stylebox(b)
		var fg = _read_stylebox(b)
		v.rect_size = Vector2(b.get_float(), b.get_float())
		if bg is StyleBox:
			v.add_stylebox_override("bg", bg)
		if fg is StyleBox:
			v.add_stylebox_override("fg", fg)
		v.min_value = 0
		v.max_value = 1
		v.step = 0
		v.value = b.get_float()
