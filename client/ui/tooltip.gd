# Port of src/client/UI/Tooltip.luau (scripts/ui/tooltip.gd, UITooltip).
# Small glass info card. Three placements: following the cursor (tile hover), anchored above a
# control (button hints) or pinned in a corner (tap-to-inspect on touch screens).
#
# Spec: {title, title_color, swatch (Color), badge, badge_color, sub, rows: [[k, v, color]], body,
# hint, hint_color, hint_icon, footer}
class_name Tooltip
extends Control

signal closed

const PLACE_FOLLOW := 0
const PLACE_ANCHOR := 1
const PLACE_PINNED := 2
## Tap-to-inspect cards close on their own after this many seconds.
const PIN_SECONDS := 6.0

var ctx: UICtx
var place := PLACE_FOLLOW
var _anchor: Control = null
var _key := ""
var _shown := false
var _tween: Tween = null
var _target := Vector2.ZERO
var _close: Button = null
var _pin_rect := Rect2()
var _pin_age := 0.0
var _panel: GlassPanel
var _box: VBoxContainer


func _init(c: UICtx) -> void:
	ctx = c
	name = "Tooltip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel = GlassPanel.new(12.0, 10.0, UITheme.R_MD, true, 14)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	_box = UITheme.vbox(6)
	_panel.add_child(_box)
	modulate.a = 0.0
	visible = false
	set_process(false)


func is_shown() -> bool:
	return _shown


func anchor_is(c: Control) -> bool:
	return _anchor == c


func show_follow(spec: Dictionary) -> void:
	_show(spec, PLACE_FOLLOW, null)


func show_anchor(spec: Dictionary, anchor: Control) -> void:
	move_to_front()  # above full-screen panels (the Victory screen moves itself to the front)
	_show(spec, PLACE_ANCHOR, anchor)


func show_pinned(spec: Dictionary, rect: Rect2) -> void:
	_pin_rect = rect
	_pin_age = 0.0
	_show(spec, PLACE_PINNED, null)


func hide_tip() -> void:
	if not _shown:
		return
	_shown = false
	_key = ""
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, 0.1)
	_tween.tween_callback(func() -> void:
		if not _shown:
			visible = false
			set_process(false))


## The card's current rect: UIInteract.show_inspect keeps it off the tapped spot.
func target_rect() -> Rect2:
	return Rect2(_target, _panel.get_combined_minimum_size())


func _show(spec: Dictionary, p: int, anchor: Control) -> void:
	if has_meta("stats"):
		remove_meta("stats")  # UIRoot tags its strip-details card after showing it
	var key := var_to_str(spec) + "#" + str(p)
	var was := _shown
	place = p
	_anchor = anchor
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP if p == PLACE_PINNED else Control.MOUSE_FILTER_IGNORE
	if key != _key:
		_key = key
		_build(spec)
	_shown = true
	visible = true
	set_process(true)
	_panel.reset_size()
	_target = _compute_target()
	if not was:
		_set_pos(_target)
		if _tween:
			_tween.kill()
		_tween = create_tween()
		_tween.tween_property(self, "modulate:a", 1.0, 0.12)
	elif modulate.a < 1.0 and (_tween == null or not _tween.is_running()):
		modulate.a = 1.0


func _set_pos(p: Vector2) -> void:
	position = p


func _build(spec: Dictionary) -> void:
	for ch in _box.get_children():
		_box.remove_child(ch)
		ch.queue_free()
	var compact := ctx.compact
	var head := UITheme.hbox(8)
	if spec.get("swatch") != null:
		var sw := UITheme.swatch(spec.swatch, 11.0, 3)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(sw)
	var tc: Color = spec.get("title_color", UITheme.TEXT)
	var title := UITheme.label(str(spec.get("title", "")), 14 if compact else 15, 700, tc)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	if str(spec.get("badge", "")) != "":
		head.add_child(_badge(str(spec.badge), spec.get("badge_color", UITheme.TEXT_2)))
	_close = null
	if place == PLACE_PINNED:
		var b := UITheme.button("", "GhostButton", "close", 44.0)
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 16)
		b.custom_minimum_size = Vector2(44, 44)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_color_override("icon_normal_color", UITheme.TEXT)
		b.add_theme_stylebox_override("normal", UITheme.flat(UITheme.FILL, 10, UITheme.LINE, 1, 12.0, 12.0))
		b.pressed.connect(func() -> void:
			hide_tip()
			closed.emit())
		_close = b
		head.add_child(b)
	_box.add_child(head)
	if str(spec.get("sub", "")) != "":
		_box.add_child(UITheme.label(str(spec.sub), 12, 500, UITheme.TEXT_2))
	var rows: Array = spec.get("rows", [])
	if rows.size() > 0:
		# two columns: the key column shrinks, the value column expands and right-aligns (tabular
		# digits)
		var grid := UITheme.vbox(3)
		for r in rows:
			var line := UITheme.hbox(18)
			line.add_child(UITheme.label(str(r[0]), 12, 500, UITheme.TEXT_3))
			var vc: Color = r[2] if r.size() > 2 else UITheme.TEXT
			var v := UITheme.label(str(r[1]), 13, 600, vc)
			v.add_theme_font_override("font", UITheme.font(600, 0, true))
			v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line.add_child(v)
			grid.add_child(line)
		_box.add_child(grid)
	if str(spec.get("body", "")) != "":
		var body := UITheme.label(str(spec.body), 12, 500, UITheme.TEXT_2)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.custom_minimum_size = Vector2(220, 0)
		_box.add_child(body)
	if str(spec.get("hint", "")) != "":
		var hc: Color = spec.get("hint_color", UITheme.AMBER)
		var hint := UITheme.hbox(6)
		_box.add_child(UITheme.hdivider())
		if spec.get("hint_icon") != null:
			var ic := UITheme.icon_rect(str(spec.hint_icon), 14.0, hc)
			ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			hint.add_child(ic)
		var hl := UITheme.label(str(spec.hint), 12, 600, hc)
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hl.custom_minimum_size = Vector2(196, 0)
		hint.add_child(hl)
		_box.add_child(hint)
	if str(spec.get("footer", "")) != "":
		_box.add_child(UITheme.label(str(spec.footer), 11, 500, UITheme.TEXT_3))
	_panel.custom_minimum_size = Vector2(236 if place != PLACE_ANCHOR else 220, 0)


func _badge(text: String, c: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UITheme.box(UITheme.c(c, 0.16), 999, UITheme.c(c, 0.5), 1, 7.0, 1.0))
	p.add_child(UITheme.label(text.to_upper(), 10, 700, c, 1))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


func _compute_target() -> Vector2:
	var vp := ctx.vp
	var sz := _panel.get_combined_minimum_size()
	var ins := ctx.insets
	var margin := 8.0
	var p := Vector2.ZERO
	if place == PLACE_FOLLOW:
		var m := ctx.mouse_pos()
		p = m + Vector2(20, 22)
		if p.x + sz.x > vp.x - margin - ins.z:
			p.x = m.x - 16 - sz.x
		if p.y + sz.y > vp.y - margin - ins.w:
			p.y = m.y - 14 - sz.y
	elif place == PLACE_ANCHOR:
		var a := _anchor
		if a != null and is_instance_valid(a):
			var r := a.get_global_rect()
			var x := r.position.x + r.size.x * 0.5 - sz.x * 0.5
			var y := r.position.y - sz.y - 10.0
			if y < margin:
				y = r.end.y + 10.0
			p = Vector2(x, y)
	else:
		var pr := _pin_rect
		p = Vector2(pr.position.x + pr.size.x - sz.x, pr.position.y + pr.size.y - sz.y)
	return Vector2(
		clampf(p.x, margin + ins.x, maxf(margin, vp.x - sz.x - margin - ins.z)),
		clampf(p.y, margin + ins.y, maxf(margin, vp.y - sz.y - margin - ins.w))
	)


func _process(delta: float) -> void:
	if not _shown:
		return
	if place == PLACE_ANCHOR:
		var a := _anchor
		if a == null or not is_instance_valid(a) or not a.is_visible_in_tree():
			hide_tip()
			return
	if place == PLACE_PINNED:
		_pin_age += delta
		if _pin_age > PIN_SECONDS:
			hide_tip()
			return
	_target = _compute_target()
	var cur := position
	if (cur - _target).length() < 0.25:
		if cur != _target:
			_set_pos(_target)
		return
	if place == PLACE_FOLLOW:
		_set_pos(cur.lerp(_target, 1.0 - exp(-delta * 22.0)))
	else:
		_set_pos(_target)
