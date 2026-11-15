# Port of the animation helpers at the end of src/client/UI/Widgets.luau (widgets.gd, UIWidgets).
# The rest of Widgets.luau emulates Godot's Control tree on Roblox and has no counterpart here.
class_name UIFx
extends RefCounted


## Fade + settle a control in (staggered entrances). Only touches modulate and scale.
static func pop_in(c: Control, delay: float = 0.0, from_scale: float = 0.96, dur: float = 0.4) -> Tween:
	c.modulate.a = 0.0
	var t := c.create_tween()
	if delay > 0:
		t.tween_interval(delay)
	t.tween_callback(func() -> void:
		c.pivot_offset = c.size * 0.5
		c.scale = Vector2(from_scale, from_scale))
	t.set_parallel(true)
	t.tween_property(c, "modulate:a", 1.0, dur * 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(c, "scale", Vector2.ONE, dur).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return t


static func fade(c: CanvasItem, to: float, dur: float = 0.2) -> Tween:
	var t := c.create_tween()
	t.tween_property(c, "modulate:a", to, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return t


## Hover grow for buttons (pivot centred).
static func hover_grow(b: Control, amount: float = 1.04) -> void:
	b.mouse_entered.connect(func() -> void:
		b.pivot_offset = b.size * 0.5
		var t := b.create_tween()
		t.tween_property(b, "scale", Vector2(amount, amount), 0.12).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT))
	b.mouse_exited.connect(func() -> void:
		var t := b.create_tween()
		t.tween_property(b, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT))


## Slide an anchored control in from an offset (a transient shift on top of its anchor offsets; a
## re-layout mid-slide takes the new offsets as the base, so layout and animation never fight).
static func slide_in(c: Control, from_offset: Vector2, delay: float = 0.0, dur: float = 0.45) -> Tween:
	_set_shift(c, Vector2.ZERO)
	c.modulate.a = 0.0
	_set_shift(c, from_offset)
	var t := c.create_tween().set_parallel(true)
	t.tween_method(func(v: Vector2) -> void: _set_shift(c, v), from_offset, Vector2.ZERO, dur).set_delay(delay).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	t.tween_property(c, "modulate:a", 1.0, dur * 0.7).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return t


static func _set_shift(c: Control, v: Vector2) -> void:
	if not is_instance_valid(c):
		return
	var cur := Vector2(c.offset_left, c.offset_top)
	var shift: Vector2 = c.get_meta("slide_shift", Vector2.ZERO)
	var base: Vector2 = c.get_meta("slide_base", cur - shift)
	if (cur - (base + shift)).length() > 1e-3:
		base = cur  # a layout pass wrote fresh (unshifted) offsets
	var d := base + v - cur
	c.offset_left += d.x
	c.offset_right += d.x
	c.offset_top += d.y
	c.offset_bottom += d.y
	c.set_meta("slide_shift", v)
	c.set_meta("slide_base", base)
