# Port of GradientText in src/client/UI/TitleScreen.luau (the wordmark / game-over headline): heavy
# Rubik with letter spacing, a vertical gradient, a soft dark outline behind it and a shine that can
# sweep across.
#
# Upstream builds it per glyph from TextLabels with UIGradients; here it is two Labels: the shadow
# (an outlined copy) and the word itself under a small shader (gradient by y, shine by x).
class_name GradientText
extends Control

const SHINE_HALF := 70.0  # smoothstep(0, 70, |x - sweep - (y - y0) * 0.35|)
const SHADER := """
shader_type canvas_item;
uniform vec4 top_col : source_color = vec4(1.0);
uniform vec4 bot_col : source_color = vec4(1.0);
uniform float y0 = 0.0;
uniform float span = 100.0;
uniform float sweep = -10000.0;
uniform float shine = 0.4;
uniform float shine_half = 70.0;
varying vec2 vpos;
void vertex() { vpos = VERTEX; }
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float k = clamp((vpos.y - y0) / max(1.0, span), 0.0, 1.0);
	vec3 g = mix(top_col.rgb, bot_col.rgb, k);
	float d = abs(vpos.x - sweep - (vpos.y - y0) * 0.35);
	float s = (1.0 - smoothstep(0.0, shine_half, d)) * shine;
	COLOR = vec4(mix(g, vec3(1.0), s), t.a * COLOR.a);
}
"""

var text := ""
var px := 100.0
var weight := 900
var spacing := 0:
	set(v):
		spacing = v
		_restyle()
var top_color := Color(1, 1, 1)
var bottom_color := Color(1.0, 0.8, 0.52)
var y0 := 0.0  # gradient start (px from the top of the line)
var span := 100.0
var sweep := -10000.0  # shine centre x, off by default
var shine := 0.4
var shadow := {"color": Color(0.0, 0.02, 0.08), "alpha": 0.55, "offset_y": 6, "outline": 14}
var _shadow_l: Label
var _word: Label
var _mat: ShaderMaterial
static var _shader: Shader = null


func _init(t: String, size_px: float, w: int = 900) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	text = t
	px = size_px
	weight = w
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	_shadow_l = Label.new()
	_shadow_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_shadow_l)
	_word = Label.new()
	_word.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_word.material = _mat
	add_child(_word)
	_restyle()


func _restyle() -> void:
	if _word == null:
		return
	var f := UITheme.font(weight, spacing)
	for l in [_shadow_l, _word]:
		l.text = text
		l.add_theme_font_override("font", f)
		l.add_theme_font_size_override("font_size", int(px))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sc: Color = shadow.color
	_shadow_l.add_theme_color_override("font_color", Color(sc.r, sc.g, sc.b, shadow.alpha))
	_shadow_l.add_theme_color_override("font_outline_color", Color(sc.r, sc.g, sc.b, shadow.alpha))
	_shadow_l.add_theme_constant_override("outline_size", int(shadow.outline))
	update_minimum_size()
	redraw()


func set_text(t: String) -> void:
	if t == text:
		return
	text = t
	_restyle()


func set_px(size_px: float) -> void:
	if size_px == px:
		return
	px = size_px
	_restyle()


func set_colors(top: Color, bottom: Color) -> void:
	top_color = top
	bottom_color = bottom
	redraw()


func _get_minimum_size() -> Vector2:
	if _word == null:
		return Vector2.ZERO
	return _word.get_combined_minimum_size()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		redraw()


## Upstream's _redraw: places the parts and writes the gradient and the shine.
func redraw() -> void:
	if _word == null:
		return
	var ms := _word.get_combined_minimum_size()
	_word.position = Vector2(floorf((size.x - ms.x) * 0.5 + 0.5), 0)
	_word.size = ms
	_shadow_l.position = _word.position + Vector2(0, float(shadow.offset_y))
	_shadow_l.size = ms
	_mat.set_shader_parameter("top_col", top_color)
	_mat.set_shader_parameter("bot_col", bottom_color)
	_mat.set_shader_parameter("y0", y0)
	_mat.set_shader_parameter("span", span)
	_mat.set_shader_parameter("sweep", sweep - _word.position.x)
	_mat.set_shader_parameter("shine", shine)
	_mat.set_shader_parameter("shine_half", SHINE_HALF)
