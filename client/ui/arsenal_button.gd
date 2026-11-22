# Port of src/client/UI/ArsenalButton.luau: the title screen's gold Arsenal shield (rays, glow, a
# bobbing shield, a sparkle, the "ARSENAL" pill and the Stars badge). Opens the Arsenal window.
class_name ArsenalButton
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
var _stars := -1
var _s := SIZE
var _cy := SIZE * 0.46
var _body: Control
var _rays: TextureRect
var _glow: TextureRect
var _shade: TextureRect
var _shield: TextureRect
var _spark: TextureRect
var _pill: PanelContainer
var _pill_l: Label
var _badge: PanelContainer
var _badge_icon: TextureRect
var _badge_text: Label
var _hit: Button
var _hover := false
var _accum := 0.0


static func _commas(n: float) -> String:
	return UICtx.commas(n)


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
	name = "ArsenalButton"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_body)
	var shield_tex := UITheme.icon_texture("arsenal")
	_rays = _img("Rays", load(ART + "rays.svg"), Color(GOLD, 0.16))
	_glow = _img("Glow", load(ART + "glow.svg"), Color(GOLD, 0.5))
	_shade = _img("Shade", shield_tex, Color(Color8(60, 34, 0), 0.75))
	_shield = _img("Shield", shield_tex, Color.WHITE)
	# vertical gold gradient over the shield mask
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nuniform vec4 top : source_color;\nuniform vec4 bottom : source_color;\nvoid fragment() { COLOR = vec4(mix(top.rgb, bottom.rgb, UV.y), texture(TEXTURE, UV).a * COLOR.a); }"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("top", GOLD_LIGHT)
	mat.set_shader_parameter("bottom", Color8(240, 150, 30))
	_shield.material = mat
	_spark = _img("Spark", load(ART + "sparkle.svg"), Color(GOLD_LIGHT, 0.0))

	_pill = PanelContainer.new()
	_pill.name = "Pill"
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_pill)
	_pill_l = UITheme.label("ARSENAL", 16, 800, Color8(46, 26, 4))
	_pill_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pill_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pill.add_child(_pill_l)

	_badge = PanelContainer.new()
	_badge.name = "Stars"
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.visible = false
	_body.add_child(_badge)
	var brow := UITheme.hbox(3)
	brow.alignment = BoxContainer.ALIGNMENT_CENTER
	brow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.add_child(brow)
	_badge_icon = UITheme.icon_rect("star", 14.0, GOLD)
	_badge_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	brow.add_child(_badge_icon)
	_badge_text = UITheme.label("0", 14, 800, GOLD_LIGHT)
	brow.add_child(_badge_text)

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
	refresh()


func _scale_body(to: float, dur: float) -> void:
	_body.pivot_offset = _body.size * 0.5
	var t := _body.create_tween()
	t.tween_property(_body, "scale", Vector2(to, to), dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func set_scale_k(k: float) -> void:
	if k == _k:
		return
	_k = k
	_size_parts()


## (port) how far the Stars badge reaches past the button's right edge (upstream has the crate
## button there; here the Arsenal is the last thing before the screen edge).
func overhang() -> float:
	return maxf(0.0, _badge.position.x + _badge.size.x - _s) if _badge.visible else 0.0


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
	_place(_shield, Vector2(s * 0.5, cy), Vector2(s * 0.7, s * 0.7))
	_place(_shade, Vector2(s * 0.5, cy + s * 0.03), Vector2(s * 0.7, s * 0.7))
	_place(_spark, Vector2(s * 0.66, cy - s * 0.2), Vector2(s * 0.14, s * 0.14))
	var pw := s * 0.86
	var ph := maxf(22.0, s * 0.22)
	var pst := StyleBoxFlat.new()
	pst.bg_color = Color8(249, 187, 75)  # (255,214,110) -> (242,160,40) top to bottom, flattened
	pst.set_corner_radius_all(UITheme.pill_radius(ph))
	pst.set_border_width_all(2)
	pst.border_color = Color(Color8(70, 40, 6), 0.8)
	UITheme.smooth(pst)
	_pill.add_theme_stylebox_override("panel", pst)
	_pill.custom_minimum_size = Vector2(pw, ph)
	_pill.size = Vector2(pw, ph)
	_pill.position = Vector2(s * 0.5 - pw * 0.5, s * 1.08 - ph)
	_pill_l.add_theme_font_size_override("font_size", int(ph * 0.56))
	var bh := maxf(20.0, s * 0.2)
	var bst := StyleBoxFlat.new()
	bst.bg_color = Color8(20, 28, 52)
	bst.set_corner_radius_all(UITheme.pill_radius(bh))
	bst.set_border_width_all(2)
	bst.border_color = GOLD
	UITheme.smooth(bst)
	bst.content_margin_left = bh * 0.35
	bst.content_margin_right = bh * 0.35
	_badge.add_theme_stylebox_override("panel", bst)
	_badge_icon.custom_minimum_size = Vector2(bh * 0.6, bh * 0.6)
	_badge_text.add_theme_font_size_override("font_size", int(bh * 0.62))
	_size_badge()
	custom_minimum_size = size_px()


func _size_badge() -> void:
	var bh := maxf(20.0, _s * 0.2)
	_badge.custom_minimum_size = Vector2(bh * 1.8, bh)
	_badge.reset_size()
	_badge.position = Vector2(_s * 0.78, _s * 0.12) - _badge.size * 0.5
	_badge.pivot_offset = _badge.size * 0.5


## The Stars badge (the port's save holds the Stars; the badge grows when the count does).
func refresh() -> void:
	var g = ctx.session.g if ctx.session != null else null
	var stars := int(g.save.get("stars", 0)) if g != null else 0
	_badge.visible = g != null
	if stars == _stars:
		return
	var grew := _stars >= 0 and stars > _stars
	_stars = stars
	_badge_text.text = _commas(stars)
	_size_badge()
	if grew:
		_badge.scale = Vector2(1.5, 1.5)
		var t := _badge.create_tween()
		t.tween_property(_badge, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	_accum += dt
	if _accum >= 0.25:
		_accum = 0.0
		refresh()
	_t += dt
	var t := _t
	var s := _s
	var bob := sin(t * 2.0) * s * 0.018
	_shield.position = Vector2(s * 0.5, _cy + bob) - _shield.size * 0.5
	_shade.position = Vector2(s * 0.5, _cy + bob + s * 0.03) - _shade.size * 0.5
	_shield.rotation_degrees = sin(t * 1.3) * 3.0
	_shade.rotation_degrees = _shield.rotation_degrees
	_glow.modulate.a = 1.0 - (0.56 - 0.12 * (0.5 + 0.5 * sin(t * 3.2)))
	_rays.rotation_degrees = fposmod(_rays.rotation_degrees - dt * 12.0, 360.0)
	var k := fmod(t, 2.6) / 0.9
	if k < 1.0:
		var v := sin(k * PI)
		_spark.modulate.a = v * 0.9
		_spark.rotation_degrees = k * 90.0
		_spark.position = Vector2(s * 0.66, _cy - s * 0.2 + bob) - _spark.size * 0.5
	else:
		_spark.modulate.a = 0.0
