extends Reference

# HOST SIDE. Walks the scene tree and records every visible sprite, texture,
# panel and text node as a draw "primitive" in screen space. Remote players
# own the same game, so only resource paths are sent, never pixels.

const P = preload("res://mods-unpacked/TaterNet-OnlineCoop/core/protocol.gd")

var res_ids := {}        # resource path -> id
var new_res := {}        # id -> path, not yet announced to clients
var _next_id := 1
var _prims := []         # [sort_key, index, PoolByteArray]
var _counter := 0
var _skip_root: Node = null


func capture(tree: SceneTree, skip_root: Node) -> PoolByteArray:
	_prims.clear()
	_counter = 0
	_skip_root = skip_root
	var root = tree.root
	for child in root.get_children():
		_walk(child, 0, 0, Color(1, 1, 1, 1))

	_prims.sort_custom(self, "_sort")

	var buf = StreamPeerBuffer.new()
	var vp_size = root.get_visible_rect().size
	buf.put_u16(int(vp_size.x))
	buf.put_u16(int(vp_size.y))
	buf.put_u32(_prims.size())
	for p in _prims:
		buf.put_data(p[2])
	return buf.data_array.compress(File.COMPRESSION_DEFLATE)


func take_new_resources() -> Dictionary:
	var out = new_res
	new_res = {}
	return out


func all_resources() -> Dictionary:
	var out = {}
	for path in res_ids:
		out[res_ids[path]] = path
	return out


func _sort(a, b) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	return a[1] < b[1]


func _walk(node, layer: int, z: int, mod: Color) -> void:
	if node == _skip_root:
		return
	if node is Viewport:
		return  # sub-viewports render elsewhere
	if node is CanvasLayer:
		if "visible" in node and not node.visible:
			return
		layer = node.layer
		mod = Color(1, 1, 1, 1)
		z = 0
	elif node is CanvasItem:
		if not node.visible:
			return
		if node is Node2D:
			z = node.z_index if not node.z_as_relative else z + node.z_index
		mod = mod * node.modulate
		if mod.a <= 0.01:
			return
		_emit(node, layer, z, mod * node.self_modulate)

	var children = node.get_children()
	if node is YSort and node.sort_enabled:
		children = children.duplicate()
		children.sort_custom(self, "_ysort")
	for c in children:
		_walk(c, layer, z, mod)


func _ysort(a, b) -> bool:
	var ay = a.global_position.y if a is Node2D else 0.0
	var by = b.global_position.y if b is Node2D else 0.0
	return ay < by


func _emit(n, layer: int, z: int, color: Color) -> void:
	var b: StreamPeerBuffer = null
	if n is Sprite:
		b = _sprite(n)
	elif n is AnimatedSprite:
		b = _animated_sprite(n)
	elif n is TextureRect:
		b = _texrect(n, n.texture, n.stretch_mode, n.expand, n.flip_h, n.flip_v)
	elif n is TextureButton:
		b = _texrect(n, _texbutton_texture(n), TextureRect.STRETCH_SCALE if n.expand else TextureRect.STRETCH_KEEP, n.expand, n.flip_h, n.flip_v)
	elif n is NinePatchRect:
		b = _ninepatch(n)
	elif n is ColorRect:
		b = _header(P.K_COLORRECT, n)
		b.put_float(n.rect_size.x)
		b.put_float(n.rect_size.y)
		b.put_u32(n.color.to_rgba32())
	elif n is TextureProgress:
		b = _texprogress(n)
	elif n is ProgressBar:
		b = _progressbar(n)
	elif n is RichTextLabel:
		b = _richtext(n)
	elif n is Label:
		b = _label(n, n.text, n.align, n.valign, n.autowrap, n.get_color("font_color"), n.get_color("font_color_shadow"))
	elif n is Button:
		_button(n, layer, z, color)
		return
	elif n is Panel or n is PanelContainer:
		b = _stylebox(n, n.get_stylebox("panel"))
	if b == null:
		return
	_push(b, layer, z, color)


func _push(b: StreamPeerBuffer, layer: int, z: int, color: Color) -> void:
	b.put_u32(color.to_rgba32())
	_counter += 1
	_prims.append([layer * 10000 + z, _counter, b.data_array])


func _header(kind: int, n, key_salt := 0) -> StreamPeerBuffer:
	var b = StreamPeerBuffer.new()
	b.put_u8(kind)
	b.put_u32((n.get_instance_id() * 4 + key_salt) & 0xFFFFFFFF)
	var t: Transform2D = n.get_global_transform_with_canvas()
	b.put_float(t.x.x)
	b.put_float(t.x.y)
	b.put_float(t.y.x)
	b.put_float(t.y.y)
	b.put_float(t.origin.x)
	b.put_float(t.origin.y)
	return b


func _rid(res: Resource) -> int:
	if res == null:
		return 0
	var path = res.resource_path
	if path == "":
		return 0
	if not res_ids.has(path):
		res_ids[path] = _next_id
		new_res[_next_id] = path
		_next_id += 1
	return res_ids[path]


# Resolve a texture to (resource id, region or null). Atlas textures that only
# exist inside another resource are sent as their atlas plus a region.
func _tex(tex: Texture) -> Array:
	if tex == null:
		return [0, null]
	if tex.resource_path == "" and tex is AtlasTexture and tex.atlas:
		return [_rid(tex.atlas), tex.region]
	return [_rid(tex), null]


func _put_rect(b: StreamPeerBuffer, r: Rect2) -> void:
	b.put_float(r.position.x)
	b.put_float(r.position.y)
	b.put_float(r.size.x)
	b.put_float(r.size.y)


func _sprite(n) -> StreamPeerBuffer:
	var t = _tex(n.texture)
	if t[0] == 0:
		return null
	var b = _header(P.K_SPRITE, n)
	var region_on = n.region_enabled or t[1] != null
	var region: Rect2 = n.region_rect if n.region_enabled else (t[1] if t[1] != null else Rect2())
	b.put_u16(t[0])
	b.put_u8(int(n.centered) | int(n.flip_h) << 1 | int(n.flip_v) << 2 | int(region_on) << 3)
	b.put_u16(n.hframes)
	b.put_u16(n.vframes)
	b.put_u16(n.frame)
	b.put_float(n.offset.x)
	b.put_float(n.offset.y)
	if region_on:
		_put_rect(b, region)
	return b


func _animated_sprite(n) -> StreamPeerBuffer:
	if n.frames == null or not n.frames.has_animation(n.animation):
		return null
	if n.frame >= n.frames.get_frame_count(n.animation):
		return null
	var t = _tex(n.frames.get_frame(n.animation, n.frame))
	if t[0] == 0:
		return null
	var b = _header(P.K_SPRITE, n)
	var region_on = t[1] != null
	b.put_u16(t[0])
	b.put_u8(int(n.centered) | int(n.flip_h) << 1 | int(n.flip_v) << 2 | int(region_on) << 3)
	b.put_u16(1)
	b.put_u16(1)
	b.put_u16(0)
	b.put_float(n.offset.x)
	b.put_float(n.offset.y)
	if region_on:
		_put_rect(b, t[1])
	return b


func _texbutton_texture(n) -> Texture:
	if n.disabled and n.texture_disabled:
		return n.texture_disabled
	if n.pressed and n.texture_pressed:
		return n.texture_pressed
	if n.is_hovered() and n.texture_hover:
		return n.texture_hover
	if n.has_focus() and n.texture_focused:
		return n.texture_focused
	return n.texture_normal


func _texrect(n, tex: Texture, stretch: int, expand: bool, fh: bool, fv: bool) -> StreamPeerBuffer:
	var t = _tex(tex)
	if t[0] == 0:
		return null
	var b = _header(P.K_TEXRECT, n)
	b.put_u16(t[0])
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	b.put_u8(stretch)
	b.put_u8(int(expand) | int(fh) << 1 | int(fv) << 2 | int(t[1] != null) << 3)
	if t[1] != null:
		_put_rect(b, t[1])
	return b


func _ninepatch(n) -> StreamPeerBuffer:
	var t = _tex(n.texture)
	if t[0] == 0:
		return null
	var b = _header(P.K_NINEPATCH, n)
	var region = n.region_rect
	if t[1] != null:
		region = t[1] if region.size == Vector2.ZERO else Rect2(t[1].position + region.position, region.size)
	b.put_u16(t[0])
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	_put_rect(b, region)
	b.put_u16(n.patch_margin_left)
	b.put_u16(n.patch_margin_top)
	b.put_u16(n.patch_margin_right)
	b.put_u16(n.patch_margin_bottom)
	b.put_u8(int(n.draw_center))
	b.put_u8(n.axis_stretch_horizontal)
	b.put_u8(n.axis_stretch_vertical)
	return b


func _stylebox(n, sb: StyleBox, salt := 0) -> StreamPeerBuffer:
	if sb == null or sb is StyleBoxEmpty:
		return null
	if _rid(sb) == 0 and not sb is StyleBoxFlat:
		return null
	var b = _header(P.K_STYLEBOX, n, salt)
	_put_stylebox(b, sb)
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	return b


# A stylebox by path, plus a flat-colour description in case the client can't
# load it (theme sub-resources often have no loadable path).
func _put_stylebox(b: StreamPeerBuffer, sb) -> void:
	b.put_u16(_rid(sb))
	if sb is StyleBoxFlat:
		b.put_u8(1)
		b.put_u32(sb.bg_color.to_rgba32())
		b.put_u32(sb.border_color.to_rgba32())
		for m in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
			b.put_u8(clamp(sb.get_border_width(m), 0, 255))
		for c in [CORNER_TOP_LEFT, CORNER_TOP_RIGHT, CORNER_BOTTOM_RIGHT, CORNER_BOTTOM_LEFT]:
			b.put_u8(clamp(sb.get_corner_radius(c), 0, 255))
		b.put_u8(int(sb.draw_center))
	else:
		b.put_u8(0)


# A font by path, plus its font file and size so the client can rebuild it.
func _put_font(b: StreamPeerBuffer, font) -> void:
	b.put_u16(_rid(font))
	if font is DynamicFont and font.font_data:
		b.put_u16(_rid(font.font_data))
		b.put_u16(font.size)
		b.put_u8(font.outline_size)
		b.put_u32(font.outline_color.to_rgba32())
	else:
		b.put_u16(0)
		b.put_u16(0)
		b.put_u8(0)
		b.put_u32(0)


func _label(n, text: String, align: int, valign: int, autowrap: bool, col: Color, shadow: Color, salt := 0) -> StreamPeerBuffer:
	if text.strip_edges() == "":
		return null
	var b = _header(P.K_LABEL, n, salt)
	_put_font(b, n.get_font("font"))
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	b.put_u8(align)
	b.put_u8(valign)
	b.put_u8(int(autowrap))
	b.put_u32(col.to_rgba32())
	b.put_u32(shadow.to_rgba32())
	b.put_utf8_string(text)
	return b


func _richtext(n) -> StreamPeerBuffer:
	var text = n.bbcode_text if n.bbcode_enabled else n.text
	if text.strip_edges() == "":
		return null
	var b = _header(P.K_RICHTEXT, n)
	_put_font(b, n.get_font("normal_font"))
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	b.put_u32(n.get_color("default_color").to_rgba32())
	b.put_u8(int(n.bbcode_enabled))
	b.put_utf8_string(text)
	return b


func _texprogress(n) -> StreamPeerBuffer:
	var b = _header(P.K_TEXPROGRESS, n)
	b.put_u16(_tex(n.texture_under)[0])
	b.put_u16(_tex(n.texture_progress)[0])
	b.put_u16(_tex(n.texture_over)[0])
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	b.put_u8(n.fill_mode)
	b.put_float(n.ratio)
	b.put_u8(int(n.nine_patch_stretch))
	b.put_u16(n.stretch_margin_left)
	b.put_u16(n.stretch_margin_top)
	b.put_u16(n.stretch_margin_right)
	b.put_u16(n.stretch_margin_bottom)
	b.put_u32(n.tint_under.to_rgba32())
	b.put_u32(n.tint_progress.to_rgba32())
	b.put_u32(n.tint_over.to_rgba32())
	return b


func _progressbar(n) -> StreamPeerBuffer:
	var b = _header(P.K_PROGRESSBAR, n)
	_put_stylebox(b, n.get_stylebox("bg"))
	_put_stylebox(b, n.get_stylebox("fg"))
	b.put_float(n.rect_size.x)
	b.put_float(n.rect_size.y)
	b.put_float(n.ratio)
	return b


# Buttons draw a state stylebox, then a focus box, then their text.
func _button(n, layer: int, z: int, color: Color) -> void:
	var state = "normal"
	if n.disabled:
		state = "disabled"
	elif n.pressed:
		state = "pressed"
	elif n.is_hovered():
		state = "hover"
	if not n.flat:
		var b = _stylebox(n, n.get_stylebox(state))
		if b:
			_push(b, layer, z, color)
	if n.has_focus():
		var f = _stylebox(n, n.get_stylebox("focus"), 1)
		if f:
			_push(f, layer, z, color)
	var col_name = "font_color" if state == "normal" else "font_color_" + state
	var col = n.get_color(col_name) if n.has_color(col_name) else n.get_color("font_color")
	var t = _label(n, n.text, n.align, Label.VALIGN_CENTER, false, col, Color(0, 0, 0, 0), 2)
	if t:
		_push(t, layer, z, color)
