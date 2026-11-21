# Port of src/client/UI/FloatText.luau (scripts/ui/float_text.gd, UIFloatText).
# A small pill that rises from where an order was given and fades: "Attacking Brazil with 24.5K".
class_name FloatText
extends Control

## () -> Rect2: where floating confirmations may appear (set once by UIInteract).
static var bounds_provider: Callable = Callable()

var rise := 0.0
var _fixed_bounds := Rect2()
var _sz := Vector2.ZERO
var _base_y := 0.0
var _x := 0.0


static func spawn(parent: Control, pos: Vector2, text: String, icon_name: String = "", col: Color = UITheme.TEXT, bounds: Rect2 = Rect2()) -> FloatText:
	if parent == null or text == "":
		return null
	var ft := FloatText.new()
	ft.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ft._fixed_bounds = bounds
	parent.add_child(ft)
	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_theme_stylebox_override("panel", UITheme.box(Color(0.03, 0.045, 0.1, 0.92), 999, UITheme.c(col, 0.55), 1, 12.0, 5.0))
	var row := UITheme.hbox(7)
	if icon_name != "":
		var ic := UITheme.icon_rect(icon_name, 14.0, col)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(ic)
	row.add_child(UITheme.label(text, 13, 700, col.lerp(Color.WHITE, 0.35)))
	pill.add_child(row)
	ft.add_child(pill)
	ft._sz = pill.get_combined_minimum_size()
	pill.size = ft._sz
	var p := pos + Vector2(-ft._sz.x * 0.5, -ft._sz.y - 22.0)
	ft._base_y = p.y
	ft._x = p.x
	ft.size = ft._sz
	ft.pivot_offset = ft._sz * 0.5
	ft._clamp()
	ft.scale = Vector2(0.85, 0.85)
	ft.modulate.a = 0.0
	var t := ft.create_tween().set_parallel(true)
	t.tween_property(ft, "modulate:a", 1.0, 0.12)
	t.tween_property(ft, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(ft, "rise", 26.0, 1.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(ft, "modulate:a", 0.0, 0.45).set_delay(1.05)
	t.chain().tween_callback(ft.queue_free)
	return ft


func _clamp() -> void:
	var b := _fixed_bounds
	if bounds_provider.is_valid():
		var v: Rect2 = bounds_provider.call()
		if v.size.x > 0:
			b = v
	if b.size.x <= 0:
		b = Rect2(Vector2.ZERO, get_viewport_rect().size if is_inside_tree() else Vector2(1600, 900))
	var x := clampf(_x, b.position.x + 8.0, maxf(b.position.x + 8.0, b.end.x - _sz.x - 8.0))
	var y := _base_y - rise
	y = clampf(y, b.position.y + 8.0, maxf(b.position.y + 8.0, b.end.y - _sz.y - 8.0))
	position = Vector2(x, y)


func _process(_delta: float) -> void:
	_clamp()
