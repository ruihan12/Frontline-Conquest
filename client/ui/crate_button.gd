# Title screen crate button, styled like upstream's: a bobbing wooden chest over gold rays and glow
# with a "CRATES" pill. Takes the top-right corner; the Arsenal sits to its left. Opens Crates.
class_name CrateButton
extends Control

signal pressed

const SIZE := 132.0
const PHONE_K := 0.6
const GOLD := Color8(255, 200, 61)
const GOLD_LIGHT := Color8(255, 232, 160)
const ART := "res://assets/rw/crate/"

var ctx: UICtx
var _t := 0.0
var _k := 1.0
var _s := SIZE
var _cy := SIZE * 0.46
var _body: Control
var _rays: TextureRect
var _glow: TextureRect
var _shade: TextureRect
var _chest: TextureRect
var _spark: TextureRect
var _pill: PanelContainer
var _pill_l: Label
var _hit: Button
var _hover := false


func _img(n: String, tex: Texture2D, col: Color) -> TextureRect:
	var r := TextureRect.new()
	r.name = n
	r.texture = tex
	r.modulate = col
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	_body.add_child(r)
	return r


func _init(c: UICtx) -> void:
	ctx = c
	name = "CrateButton"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_body)
	var tex: Texture2D = load(ART + "crate_icon.svg")
	_rays = _img("Rays", load(ART + "rays.svg"), Color(GOLD, 0.16))
	_glow = _img("Glow", load(ART + "glow.svg"), Color(GOLD, 0.5))
	_shade = _img("Shade", tex, Color(Color8(40, 22, 4), 0.75))
	_chest = _img("Chest", tex, Color.WHITE)
	# wooden gradient over the chest mask
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nuniform vec4 top : source_color;\nuniform vec4 bottom : source_color;\nvoid fragment() { COLOR = vec4(mix(top.rgb, bottom.rgb, UV.y), texture(TEXTURE, UV).a * COLOR.a); }"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("top", Color8(176, 124, 78))
	mat.set_shader_parameter("bottom", Color8(112, 72, 40))
	_chest.material = mat
	_spark = _img("Spark", load(ART + "sparkle.svg"), Color(GOLD_LIGHT, 0.0))

	_pill = PanelContainer.new()
	_pill.name = "Pill"
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_pill)
	_pill_l = UITheme.label("CRATES", 16, 800, Color8(46, 26, 4))
	_pill_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pill_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pill.add_child(_pill_l)

	_hit = Button.new()
	_hit.name = "Hit"
	_hit.flat = true
	_hit.focus_mode = Control.FOCUS_NONE
	_hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for st in ["normal", "hover", "pressed", "focus"]:
		_hit.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	add_child(_hit)
	_hit.mouse_entered.connect(func() -> void:
		_hover = true
		_scale_body(1.06, 0.12)
		if not ctx.touch:
			ctx.sfx("hover", -12.0))
	_hit.mouse_exited.connect(func() -> void:
		_hover = false
		_scale_body(1.0, 0.12))
	_hit.button_down.connect(func() -> void: _scale_body(0.94, 0.08))
	_hit.button_up.connect(func() -> void: _scale_body(1.06 if _hover else 1.0, 0.12))
	_hit.pressed.connect(func() -> void: pressed.emit())
	_size_parts()


func _scale_body(to: float, dur: float) -> void:
	_body.pivot_offset = _body.size * 0.5
	var t := _body.create_tween()
	t.tween_property(_body, "scale", Vector2(to, to), dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func set_scale_k(k: float) -> void:
	if k == _k:
		return
	_k = k
	_size_parts()


func size_px() -> Vector2:
	var s := SIZE * _k
	return Vector2(s, s * 1.08)


static func _place(r: Control, centre: Vector2, sz: Vector2) -> void:
	r.size = sz
	r.position = centre - sz * 0.5
	r.pivot_offset = sz * 0.5


func _size_parts() -> void:
	var s := SIZE * _k
	var cy := s * 0.46
	_s = s
	_cy = cy
	_place(_rays, Vector2(s * 0.5, cy), Vector2(s * 1.4, s * 1.4))
	_place(_glow, Vector2(s * 0.5, cy), Vector2(s * 1.2, s * 1.1))
	_place(_chest, Vector2(s * 0.5, cy), Vector2(s * 0.74, s * 0.74))
	_place(_shade, Vector2(s * 0.5, cy + s * 0.03), Vector2(s * 0.74, s * 0.74))
	_place(_spark, Vector2(s * 0.68, cy - s * 0.2), Vector2(s * 0.14, s * 0.14))
	var pw := s * 0.86
	var ph := maxf(22.0, s * 0.22)
	var pst := StyleBoxFlat.new()
	pst.bg_color = Color8(249, 187, 75)
	pst.set_corner_radius_all(UITheme.pill_radius(ph))
	pst.set_border_width_all(2)
	pst.border_color = Color(Color8(70, 40, 6), 0.8)
	UITheme.smooth(pst)
	_pill.add_theme_stylebox_override("panel", pst)
	_pill.custom_minimum_size = Vector2(pw, ph)
	_pill.size = Vector2(pw, ph)
	_pill.position = Vector2(s * 0.5 - pw * 0.5, s * 1.08 - ph)
	_pill_l.add_theme_font_size_override("font_size", int(ph * 0.56))
	custom_minimum_size = size_px()


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	_t += dt
	var t := _t
	var s := _s
	var bob := sin(t * 2.0 + 1.0) * s * 0.018
	_chest.position = Vector2(s * 0.5, _cy + bob) - _chest.size * 0.5
	_shade.position = Vector2(s * 0.5, _cy + bob + s * 0.03) - _shade.size * 0.5
	_chest.rotation_degrees = sin(t * 1.3 + 1.0) * 3.0
	_shade.rotation_degrees = _chest.rotation_degrees
	_glow.modulate.a = 1.0 - (0.56 - 0.12 * (0.5 + 0.5 * sin(t * 3.2)))
	_rays.rotation_degrees = fposmod(_rays.rotation_degrees - dt * 12.0, 360.0)
	var k := fmod(t + 1.3, 2.6) / 0.9
	if k < 1.0:
		var v := sin(k * PI)
		_spark.modulate.a = v * 0.9
		_spark.rotation_degrees = k * 90.0
		_spark.position = Vector2(s * 0.68, _cy - s * 0.2 + bob) - _spark.size * 0.5
	else:
		_spark.modulate.a = 0.0
