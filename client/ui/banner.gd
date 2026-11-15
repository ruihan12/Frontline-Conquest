# Port of src/client/UI/Banner.luau (scripts/ui/banner.gd, UIBanner).
# Centre-screen moment ("THE WAR BEGINS"): a wide letter-spaced title over a soft band that fades
# in, holds and fades out, then frees itself.
class_name Banner
extends Control

const BAND := Color(0.01, 0.015, 0.05)
const MARGIN := 10.0

var title_label: Label
## The text block (title + subtitle) as its own invisible node, so map labels can step aside.
var text_area: Control
## Optional: Callable() -> Rect2 (or null) the banner's text must not cover (the local player's own
## label while the camera pushes in); `min_top` / `max_bottom` bound where the band may move. Set
## by the caller after make() (explicitly placed banners only).
var avoid: Callable
var min_top := -INF
var max_bottom := INF
var _slide_parts: Array[Control] = []
var _bases := {}
var _base_top := NAN
var _height := 0.0
var _shift := 0.0


## `top_y` / `height`: the band's placement in logical px (height <= 0 = centred default).
## Add the returned node to a full-rect layer; it animates and frees itself.
static func make(ctx: UICtx, title: String, sub: String, col: Color, hold: float = 1.6, top_y: float = -1.0, height: float = 0.0, small: bool = false) -> Banner:
	var b := Banner.new()
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	b.theme = UITheme.theme()
	var placed := top_y >= 0.0 and height > 0.0
	# vertical gradient: alpha 0 -> 0.62 -> 0
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	gr.colors = PackedColorArray([Color(BAND, 0.0), Color(BAND, 0.62), Color(BAND, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = gr
	tex.width = 4
	tex.height = 64
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var band := TextureRect.new()
	band.texture = tex
	band.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	band.stretch_mode = TextureRect.STRETCH_SCALE
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := UITheme.vbox(6)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Control in [band, v]:
		c.anchor_left = 0.0
		c.anchor_right = 1.0
		if placed:
			c.anchor_top = 0.0
			c.anchor_bottom = 0.0
			c.offset_top = top_y
			c.offset_bottom = top_y + height
		else:
			c.anchor_top = 0.36
			c.anchor_bottom = 0.56
	b.add_child(band)
	b.add_child(v)
	var t := UITheme.label(title, 22 if small else (40 if not ctx.compact else 26), 900, col.lerp(Color.WHITE, 0.25), 4 if small else (8 if not ctx.compact else 5))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	t.add_theme_constant_override("shadow_offset_y", 3)
	t.add_theme_constant_override("shadow_outline_size", 6)
	v.add_child(t)
	if sub != "" and not small:
		var s := UITheme.label(sub, 15 if not ctx.compact else 12, 600, UITheme.TEXT_2, 1)
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(s)
	b.title_label = t
	var area := Control.new()
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := t.get_combined_minimum_size().x
	for ch: Control in v.get_children():
		tw = maxf(tw, ch.get_combined_minimum_size().x)
	var th := v.get_combined_minimum_size().y
	area.anchor_left = 0.5
	area.anchor_right = 0.5
	area.offset_left = -ceilf(tw * 0.5) - 8
	area.offset_right = ceilf(tw * 0.5) + 8
	if placed:
		area.anchor_top = 0.0
		area.anchor_bottom = 0.0
		var cy := top_y + height * 0.5
		area.offset_top = floorf(cy - th * 0.5) - 4
		area.offset_bottom = ceilf(cy + th * 0.5) + 4
	else:
		area.anchor_top = 0.46
		area.anchor_bottom = 0.46
		area.offset_top = -ceilf(th * 0.5) - 4
		area.offset_bottom = ceilf(th * 0.5) + 4
	b.add_child(area)
	b.text_area = area
	b._slide_parts = [band, v, area]
	if placed:
		b._base_top = top_y
		b._height = height
	b.set_process(placed)
	b.modulate.a = 0.0
	b._start.call_deferred(hold)
	return b


func _start(hold: float) -> void:
	if not is_inside_tree():
		return
	var t := title_label
	t.pivot_offset = t.size * 0.5
	t.scale = Vector2(1.12, 1.12)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "modulate:a", 1.0, 0.35)
	tw.tween_property(t, "scale", Vector2.ONE, 0.9).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(hold)
	tw.chain().tween_property(self, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(queue_free)


## Keeps the text block clear of the `avoid` rect: slides the band up above it (or below it when
## there is no room above) within [min_top, max_bottom], eased. Overlap is judged against the
## band's own placement, so a clear banner never drifts back and forth.
func _process(delta: float) -> void:
	if not avoid.is_valid() or is_nan(_base_top):
		return
	var r = avoid.call()
	var want := 0.0
	if r is Rect2 and text_area != null:
		var ar := text_area.get_global_rect()
		var a0 := ar.position.y - _shift
		var a1 := ar.end.y - _shift
		if r.end.x > ar.position.x and r.position.x < ar.end.x and r.end.y > a0 - MARGIN and r.position.y < a1 + MARGIN:
			var up: float = (r.position.y - MARGIN) - a1
			var down: float = (r.end.y + MARGIN) - a0
			var up_ok := _base_top + up >= min_top
			var down_ok := _base_top + _height + down <= max_bottom
			if up_ok and (not down_ok or -up <= down):
				want = up
			elif down_ok:
				want = down
			else:
				want = maxf(up, min_top - _base_top)
	var sh := _shift
	if absf(want - sh) < 0.25:
		sh = want
	else:
		sh += (want - sh) * minf(1.0, delta * 12.0)
	if sh == _shift:
		return
	_shift = sh
	var d := floorf(sh + 0.5)
	for c in _slide_parts:
		if not _bases.has(c):
			_bases[c] = Vector2(c.offset_top, c.offset_bottom)
		c.offset_top = _bases[c].x + d
		c.offset_bottom = _bases[c].y + d
