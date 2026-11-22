# Port of src/client/UI/ShopSlot.luau.
# The gold SHOP slot that closes the build row and opens the Arsenal. It shows, in turn, what the
# player has yet to get (a render every CYCLE_S), with a sheen that crosses it, a red count badge and
# a wiggle until it has been pressed once.
class_name ShopSlot
extends Control

signal wanted(key, from)

const CYCLE_S := 2.4
const FADE_S := 0.3
const SHINE_S := 3.2
const WIGGLE_S := 6.4
const CAPTION_H := 17.0
const GOLD_LIGHT := Color8(255, 226, 122)
const GOLD_DEEP := Color8(238, 148, 28)
const INK := Color8(52, 28, 2)
const RED := Color8(232, 52, 52)

var ctx: UICtx
var _items: Array = []
var _n_locked := 0
var _sig := "?"
var _seen := false
var _t := 0.0
var _hover := false
var _scale := 1.0
var _scale_tw: Tween = null
var _grad: GradientTexture2D


func _init(c: UICtx) -> void:
	ctx = c
	name = "Shop"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var g := Gradient.new()
	g.set_color(0, GOLD_LIGHT)
	g.set_color(1, GOLD_DEEP)
	_grad = GradientTexture2D.new()
	_grad.gradient = g
	_grad.fill_from = Vector2(0, 0)
	_grad.fill_to = Vector2(0, 1)
	_grad.width = 8
	_grad.height = 64
	set_block(58.0, 60.0)
	mouse_entered.connect(func() -> void:
		_hover = true
		_tween_scale(1.06, 0.12)
		if not ctx.touch:
			ctx.sfx("hover", -12.0))
	mouse_exited.connect(func() -> void:
		_hover = false
		_tween_scale(1.0, 0.12))


func _tween_scale(to: float, t: float) -> void:
	if _scale_tw:
		_scale_tw.kill()
	_scale_tw = create_tween()
	_scale_tw.tween_property(self, "_scale", to, t).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_tween_scale(0.93, 0.08)
		else:
			_tween_scale(1.06 if _hover else 1.0, 0.12)
			if Rect2(Vector2.ZERO, size).has_point(ev.position):
				_seen = true
				wanted.emit(_current_key(), "match")
		accept_event()


func set_block(w: float, h: float) -> void:
	custom_minimum_size = Vector2(w, h)
	queue_redraw()


## The catalogue items the player has yet to get.
func locked() -> Array:
	var out: Array = []
	var s = ctx.session
	var has: bool = s != null and s.has_method("has_unlock")
	for it in ArsenalData.ITEMS:
		if not (has and s.has_unlock(it.key)):
			out.append(it)
	return out


func _current_key():
	var n := _items.size()
	if n == 0:
		return null
	var i := int(floor(_t / CYCLE_S)) % n
	return _items[i].key


## Takes the locked items again; true when they changed.
func refresh() -> bool:
	var items := locked()
	var keys := PackedStringArray()
	for it in items:
		keys.append(it.key)
	var sig := ",".join(keys)
	var changed := sig != _sig
	if changed:
		_sig = sig
		var shown: Array = []
		for it in items:
			if ArsenalData.render(it.key) != null:
				shown.append(it)
		_items = shown
		_n_locked = items.size()
		queue_redraw()
	return changed


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	_t += dt
	queue_redraw()


func _draw() -> void:
	var t := _t
	var w := size.x
	var h := size.y
	var rot := 0.0
	if not _seen:
		var wk := fmod(t, WIGGLE_S) / 0.55
		if wk < 1:
			rot = deg_to_rad(sin(wk * PI * 4) * 7 * (1 - wk))
	var c := size * 0.5
	draw_set_transform(c, rot, Vector2(_scale, _scale))
	var o := -c  # the body's top-left in the transformed space
	# the ground: a gold gradient with an ink edge
	var r := minf(float(UITheme.R_MD), minf(w, h) * 0.5)
	# (rounded gradient: one polygon along the rounded outline, each point coloured by its height, so
	# the corners are true arcs and not the steps of horizontal strips)
	var outline := PackedVector2Array()
	var cols := PackedColorArray()
	var seg := 12
	var centres := [Vector2(o.x + w - r, o.y + r), Vector2(o.x + w - r, o.y + h - r), Vector2(o.x + r, o.y + h - r), Vector2(o.x + r, o.y + r)]
	for ci in 4:
		var a0 := -PI * 0.5 + ci * PI * 0.5
		for k in seg + 1:
			var p: Vector2 = centres[ci] + Vector2.from_angle(a0 + PI * 0.5 * k / seg) * r
			outline.append(p)
			cols.append(GOLD_LIGHT.lerp(GOLD_DEEP, clampf((p.y - o.y) / h, 0.0, 1.0)))
	draw_polygon(outline, cols)
	var edge := UITheme.flat_draw(Color(0, 0, 0, 0), UITheme.R_MD, Color(INK.r, INK.g, INK.b, 0.75), 1)
	edge.draw_center = false
	draw_style_box(edge, Rect2(o, size))

	var cap_h := CAPTION_H
	var art_h := maxf(8.0, h - cap_h - 5.0)
	var art_w := w - 10.0
	var art_cy := 3.0 + art_h / 2
	var n := _items.size()
	if n > 0:
		var i := int(floor(t / CYCLE_S))
		var k := clampf(fmod(t, CYCLE_S) / FADE_S, 0.0, 1.0)
		var bob := sin(t * 2.2) * art_h * 0.03
		var pop := 0.82 + 0.18 * (1 - pow(1 - k, 3))
		var tilt := deg_to_rad(sin(t * 1.4) * 3)
		var center := Vector2(o.x + w / 2, o.y + art_cy + bob)
		if n > 1 and k < 1.0:
			_art(ArsenalData.render(_items[posmod(i - 1, n)].key), center, Vector2(art_w, art_h), tilt, rot, 1.0 - k)
		_art(ArsenalData.render(_items[i % n].key), center, Vector2(art_w, art_h) * pop, tilt, rot, k)
		draw_set_transform(c, rot, Vector2(_scale, _scale))
	else:
		var st := UITheme.icon_texture("arsenal")
		if st != null:
			var sz := art_h * 0.8
			draw_texture_rect(st, Rect2(o.x + w / 2 - sz / 2, o.y + art_cy - sz / 2, sz, sz), false, INK)
	# the caption
	var f := UITheme.font(800)
	var fs := 12
	draw_string(f, Vector2(o.x, o.y + h - 3.0 - (cap_h - f.get_height(fs)) * 0.5 - f.get_descent(fs)), "SHOP", HORIZONTAL_ALIGNMENT_CENTER, w, fs, INK)
	# the sheen: a slanted band that crosses the slot
	var sk := fmod(t, SHINE_S) / 0.75
	if sk < 1:
		var x := o.x + (-0.3 + 1.6 * sk) * w
		var band := w * 0.2
		var slant := h * 0.45
		var pts := PackedVector2Array([Vector2(x, o.y), Vector2(x + band, o.y), Vector2(x + band - slant, o.y + h), Vector2(x - slant, o.y + h)])
		for j in pts.size():
			pts[j].x = clampf(pts[j].x, o.x + 2, o.x + w - 2)
		draw_colored_polygon(pts, Color(1, 1, 1, 0.4))
	# the count badge
	if _n_locked > 0 and not _seen:
		var bc := Vector2(o.x + w - 3.0, o.y + 3.0)
		draw_circle(bc, 9.5, Color8(90, 10, 10), true, -1.0, true)
		draw_circle(bc, 8.0, RED, true, -1.0, true)
		draw_string(f, Vector2(bc.x - 8, bc.y + 4), str(_n_locked), HORIZONTAL_ALIGNMENT_CENTER, 16, 11, Color.WHITE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _art(tex: Texture2D, center: Vector2, box: Vector2, tilt: float, rot: float, alpha: float) -> void:
	if tex == null or alpha <= 0.0:
		return
	var ts := tex.get_size()
	var s := minf(box.x / ts.x, box.y / ts.y)
	var sz := ts * s
	# (centre is in the body's space: rotate it into the control's)
	var c := size * 0.5
	var p := c + (center.rotated(rot)) * _scale
	draw_set_transform(p, rot + tilt, Vector2(_scale, _scale))
	draw_texture_rect(tex, Rect2(-sz * 0.5, sz), false, Color(1, 1, 1, alpha))
