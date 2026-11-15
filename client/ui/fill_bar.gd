# Port of src/client/UI/FillBar.luau (scripts/ui/fill_bar.gd, UIBar).
# Rounded progress track with an animated fill, optional goal line and value markers.
class_name FillBar
extends Control

var value := 0.0  # 0..1 (animated towards target)
var target := 0.0
var fill_color: Color = UITheme.CYAN
var fill_color_2: Color = UITheme.CLEAR  # optional right-end colour (gradient)
var track_color := Color(1, 1, 1, 0.08)
var goal := -1.0  # 0..1 goal line (e.g. 0.8 to win)
var goal_color: Color = UITheme.GOLD
## [{v: float, color: Color}] thin vertical ticks (e.g. the leader's share).
var markers: Array = []
var glow := true
var bar_height := 4.0
var _drawn_px := -2


func _init(h: float = 4.0, c: Color = UITheme.CYAN) -> void:
	fill_color = c
	bar_height = h
	custom_minimum_size = Vector2(40, bar_height)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func set_target(v: float, instant: bool = false) -> void:
	target = clampf(v, 0.0, 1.0)
	if instant:
		value = target
	if absf(value - target) > 1e-6:
		set_process(true)
	queue_redraw()


## The fill's pixel edge at the current value (-1: none).
func _fill_px() -> int:
	var fw := size.x * value
	if not (fw > 0.5):
		return -1
	return int(floor(maxf(fw, bar_height) + 0.5))


## Straight to `v` (as set_target(v, true)), drawn again only when that moves the fill a pixel.
func set_instant(v: float) -> void:
	var t := clampf(v, 0.0, 1.0)
	target = t
	value = t
	if _drawn_px == _fill_px():
		return
	queue_redraw()


func _process(delta: float) -> void:
	if absf(value - target) > 1e-6:
		value = value + (target - value) * (1.0 - exp(-delta * 6.0))
		if absf(value - target) < 0.0005:
			value = target
		queue_redraw()
	else:
		set_process(false)


func _box(c: Color, r: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(int(round(r)))
	s.anti_aliasing = true
	return s


func _draw() -> void:
	var h := bar_height
	var y := (size.y - h) * 0.5
	var w := size.x
	var r := h * 0.5
	draw_style_box(_box(track_color, r), Rect2(0, y, w, h))
	var fw := w * value
	if fw > 0.5:
		var frw := maxf(fw, h)
		if glow:
			draw_style_box(_box(Color(fill_color.r, fill_color.g, fill_color.b, 0.22), r + 1.5), Rect2(-1.5, y - 1.5, frw + 3, h + 3))
		if fill_color_2.a > 0:
			# gradient fill (square-cornered polygon)
			draw_polygon(
				PackedVector2Array([Vector2(0, y), Vector2(frw, y), Vector2(frw, y + h), Vector2(0, y + h)]),
				PackedColorArray([fill_color, fill_color_2, fill_color_2, fill_color])
			)
		else:
			draw_style_box(_box(fill_color, r), Rect2(0, y, frw, h))
	if goal >= 0:
		var gx := floorf(w * goal + 0.5)
		draw_rect(Rect2(gx - 1, y - 4, 2, h + 8), goal_color)
	for m in markers:
		var mx := floorf(w * clampf(float(m.get("v", 0.0)), 0.0, 1.0) + 0.5)
		draw_rect(Rect2(mx - 2, y - 3, 4, h + 6), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(mx - 1, y - 3, 2, h + 6), m.get("color", UITheme.TEXT))
	_drawn_px = _fill_px()
