# Port of src/client/UI/RatioSlider.luau.
# The Attack bar: the share of the army an order sends, bound to UICtx.ratio. Five stops in one row
# (UICtx.RATIO_STOPS: 10% 25% 35% 50% 75%), each one a labelled target: tap a stop, or drag across
# them, and the amber thumb moves to it. The mouse wheel steps one stop.
#
# A stop above UICtx.ratio_max (the tutorial stops at 50%) is drawn faint, and a tap on it sets the
# highest stop allowed.
class_name RatioSlider
extends Control

var ctx: UICtx
## The row's height (it sits in the middle of the control, whose whole rect takes input).
var track_height := 26.0
## The stops' text.
var font_size := 12
var _drag := false
var _hover := -1
## Where the thumb is drawn: a stop's index (0-based), or between two while it moves.
var _shown := 0.0


func _init(c: UICtx) -> void:
	ctx = c
	name = "RatioSlider"
	_shown = float(UICtx.ratio_stop_index(c.ratio, c.ratio_max))
	custom_minimum_size = Vector2(170, 26)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)
	c.ratio_changed.connect(func(_r: float) -> void:
		set_process(true)
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = -1
		queue_redraw())
	resized.connect(queue_redraw)


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag = true
				_set_from_x(mb.position.x)
				ctx.sfx("click", -10.0)
			else:
				_drag = false
			queue_redraw()
			accept_event()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			ctx.step_ratio(1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
			accept_event()
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if _drag:
			var before := ctx.ratio
			_set_from_x(mm.position.x)
			if ctx.ratio != before:
				ctx.sfx("click", -14.0)  # (a tick for every stop the finger crosses)
		# (the stop under the cursor reads brighter)
		var i := _stop_at(mm.position.x)
		if i != _hover:
			_hover = i
			queue_redraw()


func _process(delta: float) -> void:
	var target := float(UICtx.ratio_stop_index(ctx.ratio, ctx.ratio_max))
	_shown = _shown + (target - _shown) * (1.0 - exp(-delta * 24.0))
	if absf(_shown - target) < 0.004:
		_shown = target
		set_process(false)
	queue_redraw()


## Second-finger drags (UITouchRouter): position in screen coordinates.
func drag_to_global(p: Vector2) -> void:
	_set_from_x(p.x - global_position.x)


## The stop (0-based index in RATIO_STOPS) under local x.
func _stop_at(x: float) -> int:
	var n := UICtx.RATIO_STOPS.size()
	return clampi(int(floor(x / maxf(size.x, 1.0) * n)), 0, n - 1)


func _set_from_x(x: float) -> void:
	ctx.set_ratio(UICtx.RATIO_STOPS[_stop_at(x)])


## The rect of the stop for `ratio` in screen coordinates (the tutorial points at it), or an empty
## rect when the bar has no stop there.
func stop_rect(ratio: float) -> Rect2:
	var stops := UICtx.RATIO_STOPS
	for i in stops.size():
		if absf(stops[i] - ratio) < 1e-6:
			var r := get_global_rect()
			var cw := r.size.x / stops.size()
			var h := minf(track_height, r.size.y)
			return Rect2(r.position.x + i * cw, r.position.y + (r.size.y - h) * 0.5, cw, h)
	return Rect2()


func _rbox(c: Color, r: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(int(round(r)))
	return UITheme.smooth(s)


func _draw() -> void:
	var stops := UICtx.RATIO_STOPS
	var n := stops.size()
	var w := size.x
	var th := minf(track_height, size.y)
	var ty := (size.y - th) * 0.5
	var cw := w / n
	var at := UICtx.ratio_stop_index(ctx.ratio, ctx.ratio_max)
	var radius := minf(th * 0.5, 10.0)
	# the row
	var track := _rbox(Color(1, 1, 1, 0.07), radius)
	track.set_border_width_all(1)
	track.border_color = Color(1, 1, 1, 0.12)
	draw_style_box(track, Rect2(0, ty, w, th))
	# the thumb, on the stop in use (and a soft edge around it while it is held)
	var inset := 2.0
	var x := _shown * cw + inset
	var hot := _drag
	if hot:
		draw_style_box(
			_rbox(Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.3), radius - inset + 2.0),
			Rect2(x - 2.0, ty + inset - 2.0, cw - inset * 2.0 + 4.0, th - inset * 2.0 + 4.0)
		)
	draw_style_box(_rbox(UITheme.AMBER_HI if hot else UITheme.AMBER, radius - inset), Rect2(x, ty + inset, cw - inset * 2.0, th - inset * 2.0))
	# the stops
	var top := ctx.ratio_max + 1e-6
	for i in n:
		var on := i == at
		var locked: bool = stops[i] > top
		var f := UITheme.font(800 if on else 700)
		var col: Color
		if on:
			col = UITheme.INK
		elif locked:
			col = Color(UITheme.TEXT_3.r, UITheme.TEXT_3.g, UITheme.TEXT_3.b, 0.4)
		else:
			col = UITheme.TEXT if i == _hover else UITheme.TEXT_2
		var s := "%d%%" % int(floor(stops[i] * 100.0 + 0.5))
		var asc := f.get_ascent(font_size)
		var hgt := f.get_height(font_size)
		draw_string(f, Vector2(i * cw, ty + (th - hgt) * 0.5 + asc), s, HORIZONTAL_ALIGNMENT_CENTER, cw, font_size, col)
