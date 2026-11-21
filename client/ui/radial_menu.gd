# Port of src/client/UI/RadialMenu.luau (scripts/ui/radial_menu.gd, UIRadialMenu).
# The action ring around a right-clicked (long-pressed) tile: up to eight segments with an icon and
# a label, a title pill above, a caption pill below that explains the hovered segment, a centre
# button (close, or back from a sub-ring) and nested sub-rings (Build, Nuke, bulk amounts).
#
# Upstream places pre-rendered segment masks (Roblox has no vector drawing); here the segments are
# drawn as annular sectors.
#
# Items: {id, label, icon, ok, reason, danger, cost, troops, capped, sub: [items]}
class_name RadialMenu
extends Control

signal picked(id: String, tile: int)
signal closed

## How far (logical px) the opening finger must slide before its release picks an item.
const SLIDE_PICK_PX := 30.0
## Gap between two segments, in px along the ring.
const SEG_GAP := 3.0

var ctx: UICtx
var tile := -1
var center := Vector2.ZERO
var items: Array = []
var title := ""
var title_color: Color = UITheme.TEXT
var is_open := false
## () -> float: the ring stays above this y (the command bar's top edge).
var bottom_limit: Callable = Callable()
var _root_items: Array = []
var _in_sub := false
## the rings above the current sub-ring (nested sub-rings)
var _stack: Array = []
var _sub_title := ""
var _hover := -1
var _center_hover := false
var _anim := 0.0
var _closing := false
## False until a press lands on the open menu: a release before that ends a long-press-and-slide.
var _saw_press := false
var _press_pos := Vector2.ZERO
## The opening finger has moved off its press point (press-slide-release may pick).
var _slid := false
var r_in := 44.0
var r_out := 116.0


## easeOutBack
static func _ease(t: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(t - 1.0, 3) + c1 * pow(t - 1.0, 2)


func _init(c: UICtx) -> void:
	ctx = c
	name = "Radial"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func open_at(t: int, pos: Vector2, its: Array, title_text: String, title_col: Color) -> void:
	tile = t
	_root_items = its
	items = its
	_in_sub = false
	_stack = []
	title = title_text
	title_color = title_col
	r_in = 50.0 if ctx.touch else 44.0
	r_out = 128.0 if ctx.touch else 116.0
	if ctx.compact:
		r_in = 44.0
		r_out = 112.0
	var area := ctx.clear_rect()
	if bottom_limit.is_valid():
		var b: float = bottom_limit.call()
		if b > area.position.y + 200.0 and b < area.end.y:
			area = Rect2(area.position, Vector2(area.size.x, b - 4.0 - area.position.y))
	var fit := (area.size.y - 34.0 - 40.0) * 0.5
	if r_out > fit:
		r_in = maxf(34.0, r_in * fit / r_out)
		r_out = maxf(80.0, fit)
	var m := r_out + 12.0
	var lo_y := area.position.y + r_out + 34.0
	center = Vector2(
		clampf(pos.x, area.position.x + m, maxf(area.position.x + m, area.end.x - m)),
		clampf(pos.y, lo_y, maxf(lo_y, area.end.y - r_out - 40.0))
	)
	is_open = true
	_closing = false
	_saw_press = false
	_press_pos = pos
	_slid = false
	_hover = -1
	_anim = 0.0
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	ctx.sfx("open", -6.0)
	queue_redraw()


func close(emit: bool = true) -> void:
	if not is_open:
		return
	is_open = false
	_closing = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if emit:
		closed.emit()


func _enter_sub(item: Dictionary) -> void:
	var sub: Array = item.get("sub", []).duplicate()
	if _in_sub:
		_stack.append({"items": items, "title": _sub_title})
	items = sub
	_in_sub = true
	_sub_title = str(item.get("label", ""))
	_hover = -1
	_anim = 0.35
	ctx.sfx("click", -4.0)
	queue_redraw()


func _back() -> void:
	if not _stack.is_empty():
		var prev: Dictionary = _stack.pop_back()
		items = prev.items
		_sub_title = prev.title
		_hover = -1
		_anim = 0.35
		ctx.sfx("click", -6.0)
		queue_redraw()
		return
	items = _root_items
	_in_sub = false
	_hover = -1
	_anim = 0.35
	ctx.sfx("click", -6.0)
	queue_redraw()


## Per frame (UIRoot's loop).
func update(delta: float) -> void:
	if _closing:
		_anim = maxf(0.0, _anim - delta * 7.0)
		if _anim <= 0.0:
			_closing = false
			visible = false
		queue_redraw()
	elif is_open and _anim < 1.0:
		_anim = minf(1.0, _anim + delta * 6.0)
		queue_redraw()


func _index_at(p: Vector2) -> int:
	var d := p - center
	var r := d.length()
	_center_hover = r < r_in - 4.0
	var n := items.size()
	if r < r_in - 4.0 or r > r_out + 18.0 or n == 0:
		return -1
	var span := TAU / n
	var a := fposmod(atan2(d.y, d.x) + PI * 0.5 + span * 0.5, TAU)
	return clampi(int(floor(a / span)), 0, n - 1)


func _set_hover(h: int) -> void:
	if h != _hover and h >= 0:
		ctx.sfx("hover", -12.0)
	_hover = h
	queue_redraw()


## Long-press, slide onto an item, release: pick it. A release on the centre / outside just leaves
## the menu open for a normal tap.
func _release_at(pos: Vector2) -> void:
	_saw_press = true
	if not _slid:
		return  # a plain long-press: the menu stays open for a tap
	var ri := _index_at(pos)
	if ri >= 0:
		var it: Dictionary = items[ri]
		if it.ok and not it.has("sub"):
			var rid := str(it.get("id", ""))
			var rt := tile
			close(false)
			picked.emit(rid, rt)
		elif it.has("sub") and it.ok:
			_enter_sub(it)


func _press(pos: Vector2, right: bool) -> void:
	if not is_open:
		return
	_saw_press = true
	if right:
		if _in_sub:
			_back()
		else:
			close()
		return
	var i := _index_at(pos)
	_hover = i
	if i < 0:
		if _center_hover and _in_sub:
			_back()
		else:
			close()
		return
	var it: Dictionary = items[i]
	if not it.ok:
		ctx.sfx("deny", -4.0)
		queue_redraw()
		return
	if it.get("sub") != null:
		_enter_sub(it)
		return
	var id := str(it.get("id", ""))
	var t := tile
	close(false)
	picked.emit(id, t)


func _gui_input(e: InputEvent) -> void:
	if not is_open:
		return
	if e is InputEventMouseButton:
		if e.pressed:
			if e.button_index == MOUSE_BUTTON_LEFT:
				_press(e.position, false)
			elif e.button_index == MOUSE_BUTTON_RIGHT:
				# (the right press that opened the ring is released over it: that release is not a press)
				if _saw_press or UICtx.msec() - _open_msec > 250.0:
					_press(e.position, true)
		elif not _saw_press and e.button_index == MOUSE_BUTTON_LEFT:
			_release_at(e.position)
		accept_event()
	elif e is InputEventMouseMotion:
		if not _saw_press and (e.position - _press_pos).length() > SLIDE_PICK_PX:
			_slid = true
		_set_hover(_index_at(e.position))
		accept_event()


var _open_msec := 0.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		_open_msec = UICtx.msec()


## An annular sector centred on angle `rad` (clockwise from 12 o'clock), `span` wide, with half of
## SEG_GAP taken off each side.
static func _sector(ri: float, ro: float, rad: float, span: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var a0 := rad - PI * 0.5 - span * 0.5
	var a1 := a0 + span
	var gi := (SEG_GAP * 0.5) / maxf(ri, 1.0)
	var go := (SEG_GAP * 0.5) / maxf(ro, 1.0)
	var steps := maxi(4, int(ceil(span / 0.08)))
	for k in steps + 1:
		var a := lerpf(a0 + go, a1 - go, float(k) / steps)
		pts.append(Vector2(cos(a), sin(a)) * ro)
	for k in steps + 1:
		var a := lerpf(a1 - gi, a0 + gi, float(k) / steps)
		pts.append(Vector2(cos(a), sin(a)) * ri)
	return pts


func _pill(c: Vector2, text: String, col: Color, alpha: float, fs: int, weight: int) -> void:
	if text == "" or alpha <= 0.0:
		return
	var f := UITheme.font(weight)
	var w := UITheme.text_width(text, fs, weight) + 22.0
	var h := fs + 12.0
	var r := Rect2(c.x - w * 0.5, c.y - h * 0.5, w, h)
	draw_style_box(UITheme.box(Color(0.04, 0.055, 0.11, alpha), 999, Color(1, 1, 1, 0.12 * alpha), 1), r)
	draw_string(f, Vector2(r.position.x, r.position.y + (h - f.get_height(fs)) * 0.5 + f.get_ascent(fs)), text, HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color(col.r, col.g, col.b, alpha))


func _draw() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var Th := UITheme
	var anim := _anim
	if anim <= 0.0:
		return
	var e := _ease(anim)
	var s := 0.72 + (1.0 - 0.72) * e
	var alpha := clampf(anim * 1.6, 0.0, 1.0)
	var c := center
	var ri := r_in
	var ro := r_out
	draw_set_transform(c, 0.0, Vector2(s, s))
	draw_circle(Vector2.ZERO, ro + 36.0, Color(0.0, 0.01, 0.04, 0.36 * alpha), true, -1.0, true)
	var n := items.size()
	var span := TAU / maxi(n, 1)
	var lf := Th.font(600)
	for i in n:
		var it: Dictionary = items[i]
		var ok: bool = it.ok == true
		var danger: bool = it.get("danger", false) == true
		var hov := i == _hover
		var fill := Color(0.06, 0.085, 0.17)
		var edge_a := 0.12
		var icol: Color = Th.TEXT
		var icol_a := 1.0
		if danger and ok:
			icol = Color(1.0, 0.8, 0.8)
		if not ok:
			fill = Color(0.05, 0.065, 0.12)
			icol = Th.TEXT
			icol_a = 0.28
		if hov and ok:
			fill = Th.RED if danger else Th.AMBER
			edge_a = 0.5
			icol = Color.WHITE if danger else Th.INK
		elif hov:
			fill = Color(0.12, 0.13, 0.2)
		var ro2 := ro + (6.0 if (hov and ok) else 0.0)
		var rad := i * span  # clockwise from 12 o'clock (segment centre)
		if n == 1:
			# the full annulus
			draw_arc(Vector2.ZERO, (ri + ro2) * 0.5, 0, TAU, 96, Color(fill.r, fill.g, fill.b, alpha), ro2 - ri, true)
			draw_arc(Vector2.ZERO, ro2, 0, TAU, 96, Color(1, 1, 1, edge_a * alpha), 1.0, true)
			draw_arc(Vector2.ZERO, ri, 0, TAU, 96, Color(1, 1, 1, edge_a * alpha), 1.0, true)
		else:
			var pts := _sector(ri, ro2, rad, span)
			draw_colored_polygon(pts, Color(fill.r, fill.g, fill.b, alpha))
			pts.append(pts[0])
			draw_polyline(pts, Color(1, 1, 1, edge_a * alpha), 1.0, true)
		var mid := rad - PI * 0.5
		var rm := (ri + ro2) * 0.5
		var ip := Vector2(cos(mid), sin(mid)) * (rm - 5.0)
		var tex := Th.icon_texture(str(it.get("icon", "info")))
		if tex != null:
			draw_texture_rect(tex, Rect2(ip.x - 12, ip.y - 5 - 12, 24, 24), false, Color(icol.r, icol.g, icol.b, icol_a * alpha))
		var la := icol_a * alpha * (0.95 if ok else 1.0)
		draw_string(lf, Vector2(ip.x - 45, ip.y + 21 - 0.935 * 11 + lf.get_ascent(11)), str(it.get("label", "")), HORIZONTAL_ALIGNMENT_CENTER, 90, 11, Color(icol.r, icol.g, icol.b, la))
	draw_circle(Vector2.ZERO, ri - 1.0, Color(0.02, 0.03, 0.07, 0.55 * alpha), true, -1.0, true)
	var cr := ri - 8.0
	var cc := Color(0.14, 0.18, 0.3) if _center_hover else Color(0.09, 0.12, 0.22)
	draw_circle(Vector2.ZERO, cr, Color(cc.r, cc.g, cc.b, alpha), true, -1.0, true)
	draw_arc(Vector2.ZERO, cr, 0, TAU, 64, Color(1, 1, 1, 0.16 * alpha), 1.0, true)
	var ct := Th.icon_texture("retreat" if _in_sub else "close")
	if ct != null:
		draw_texture_rect(ct, Rect2(-8, -8, 16, 16), false, Color(Th.TEXT_2.r, Th.TEXT_2.g, Th.TEXT_2.b, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var head := _sub_title.to_upper() if _in_sub else title
	var hcol: Color = Th.TEXT if _in_sub else title_color
	_pill(Vector2(c.x, c.y - ro * s - 16.0), head, hcol, alpha, 13, 800)
	var cap_text := ""
	var cap_col: Color = Th.TEXT
	if _hover >= 0 and _hover < n:
		var it2: Dictionary = items[_hover]
		var cap := str(it2.get("label", ""))
		var sub := ""
		var sub_col: Color = Th.TEXT_2
		if not it2.ok:
			sub = str(it2.get("reason", ""))
			sub_col = Color(1.0, 0.6, 0.62)
		elif it2.get("cost") != null:
			sub = Th.fmt_cost(it2.cost) + " gold"
			sub_col = Th.GOLD
		elif it2.get("note") != null:
			sub = str(it2.note)  # (port: a ready-made caption, e.g. the gold a donation sends)
		elif it2.id == "donate" and it2.get("troops") != null:
			sub = "%s troops (fills their cap)" % Th.fmt_troops(it2.troops) if it2.get("capped", false) else "%s troops (%d%%)" % [Th.fmt_troops(it2.troops), int(floor(ctx.ratio * 100 + 0.5))]
		elif it2.id == "attack" or it2.id == "boat" or it2.id == "donate":
			sub = "%s troops (%d%%)" % [Th.fmt_troops(ctx.troops_for_ratio()), int(floor(ctx.ratio * 100 + 0.5))]
		cap_text = cap if sub == "" else cap + "  ·  " + sub
		cap_col = sub_col if sub != "" else Th.TEXT
	_pill(Vector2(c.x, c.y + ro * s + 26.0), cap_text, cap_col, alpha, 12, 600)
