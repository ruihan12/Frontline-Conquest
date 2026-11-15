# Port of RoWorld src/client/UI/GlassPanel.luau (itself a port of the original scripts/ui/glass_panel.gd).
# Frosted-glass panel: navy tint, 1 px light border, a top sheen line and a soft drop shadow.
# Lays out its children like a PanelContainer (inside the padding).
#
# Drawn the way upstream draws it (the original's no-frost path): a flat translucent tint,
# UITheme.GLASS_BOOST more opaque, plus the frost shader's top sheen gradient.
# Parts, back to front: shadow < tint with an inner border < sheen gradient < sheen line / accent stripe
# < content.
class_name GlassPanel
extends PanelContainer

var radius: float = UITheme.R_LG
var tint: Color = UITheme.GLASS
var border_color: Color = UITheme.LINE
# Optional accent stripe on the left edge (alliance cards, alerts...). Alpha 0 = none.
var accent: Color = UITheme.CLEAR
var accent_width := 3.0
var sheen := true
var _frost := true
var _shadow_size := 18
var _sheen_tex: GradientTexture2D
var _line_tex: GradientTexture2D

# UIGlass.new(pad_h = 16, pad_v = 12, r = R_LG, frost = true, shadow_size = 18)
func _init(pad_h: float = 16.0, pad_v: float = 12.0, r: float = UITheme.R_LG, frost: bool = true, shadow_size: int = 18) -> void:
	radius = r
	_frost = frost
	_shadow_size = shadow_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	# sheen * (1 - smoothstep(0, 0.6, UV.y))
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 1.0])
	var cols := PackedColorArray()
	for tr in [0.0, 0.074, 0.259, 0.5, 0.741, 0.926, 1.0, 1.0]:
		cols.append(Color(1, 1, 1, 1.0 - tr))
	g.colors = cols
	_sheen_tex = GradientTexture2D.new()
	_sheen_tex.gradient = g
	_sheen_tex.fill_from = Vector2(0, 0)
	_sheen_tex.fill_to = Vector2(0, 1)
	_sheen_tex.width = 4
	_sheen_tex.height = 64
	# sheen line: Color(1,1,1,0) -> Color(1,1,1,0.2) -> Color(1,1,1,0) along x
	var lg := Gradient.new()
	lg.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	lg.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	_line_tex = GradientTexture2D.new()
	_line_tex.gradient = lg
	_line_tex.width = 64
	_line_tex.height = 1
	set_padding(pad_h, pad_v, pad_h, pad_v)

func set_padding(left: float, top: float, right: float, bottom: float) -> void:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = left
	s.content_margin_top = top
	s.content_margin_right = right
	s.content_margin_bottom = bottom
	add_theme_stylebox_override("panel", s)

func set_tint(col: Color) -> void:
	tint = col
	restyle()

func set_border(col: Color) -> void:
	border_color = col
	queue_redraw()

func set_accent(col: Color, width: float = -1.0) -> void:
	accent = col
	if width >= 0.0:
		accent_width = width
	restyle()

func set_sheen(on: bool) -> void:
	sheen = on
	restyle()

# The panel's tint / accent changed: redraw every part.
func restyle() -> void:
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func _draw() -> void:
	var w := size.x; var h := size.y
	if w <= 0 or h <= 0:
		return
	var r := minf(radius, minf(w, h) / 2.0)
	var rect := Rect2(Vector2.ZERO, size)
	if _shadow_size > 0:
		UITheme.draw_shadow(self, rect, UITheme.shadow_box(r, _shadow_size, 0.5, 6.0))
	var a := tint.a
	if _frost and a < 0.97:
		a = clampf(a + UITheme.GLASS_BOOST, 0.0, 0.97)
	var bg := UITheme.flat(UITheme.c(tint, a), r, border_color, 1)
	draw_style_box(bg, rect)
	if sheen and _frost:
		# the gradient through the rounded shape: a rounded box in white, modulated by the gradient rows
		var steps := 24
		var top_h := h * 0.6
		for i in steps:
			var y0 := top_h * i / steps
			var y1 := top_h * (i + 1) / steps
			var t := (y0 + y1) * 0.5 / h
			var k := clampf(t / 0.6, 0.0, 1.0)
			var al := UITheme.GLASS_SHEEN * (1.0 - k * k * (3.0 - 2.0 * k))
			# inset by the corner so the sheen follows the rounded top
			var inset := 0.0
			if y0 < r:
				var dy := r - (y0 + y1) * 0.5
				inset = r - sqrt(maxf(0.0, r * r - dy * dy))
			draw_rect(Rect2(inset, y0, w - inset * 2.0, y1 - y0), Color(1, 1, 1, al))
	if sheen and w > r * 2.0:
		# sheen line from x = radius to w - radius at y = 1
		draw_texture_rect(_line_tex, Rect2(r, 0.5, w - 2.0 * r, 1.0), false, Color(1, 1, 1, 0.2))
	if accent.a > 0:
		var inset2 := minf(radius, h / 2.0) * 0.55
		var ah := maxf(h - inset2 * 2.0, 2.0)
		draw_rect(Rect2(1.0, inset2, accent_width, ah), accent)
