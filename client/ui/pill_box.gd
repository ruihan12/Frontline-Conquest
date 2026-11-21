# A pill / round-ended box: a StyleBoxFlat whose radius is cut to just under half of the drawn box's
# short side at draw time. (A StyleBoxFlat with a radius of 999 is cut to exactly half by Godot, and its
# two halves then meet with overlapping anti-aliasing feathers: a bright dot or seam at each end, worst
# in the translucent colours of the HUD.) Made by UITheme.box() for radius >= 999.
class_name PillBox
extends StyleBox

var inner: StyleBoxFlat


func _init(flat_box: StyleBoxFlat = null) -> void:
	inner = flat_box if flat_box != null else StyleBoxFlat.new()
	content_margin_left = inner.content_margin_left
	content_margin_right = inner.content_margin_right
	content_margin_top = inner.content_margin_top
	content_margin_bottom = inner.content_margin_bottom


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var r := UITheme.pill_radius(minf(rect.size.x, rect.size.y))
	if inner.corner_radius_top_left != r:
		inner.set_corner_radius_all(r)
		UITheme._apply_smooth(inner)
	inner.draw(to_canvas_item, rect)


func _get_draw_rect(rect: Rect2) -> Rect2:
	return inner.get_draw_rect(rect)
