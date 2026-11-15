# Port of src/client/UI/PlaceConfirm.luau (scripts/ui/place_confirm.gd, UIPlaceConfirm).
# Touch placement / launch confirmation: a small caption and two big buttons (cancel, build or
# launch) floating next to the ghost on the map, never over it. The buttons follow the ghost's
# screen position every frame; UIInteract moves the ghost (tap elsewhere, map drag).
class_name PlaceConfirm
extends Control

signal confirmed
signal cancelled

const BTN := 52.0
## Keep this far (px) from the ghost's centre so the target stays visible and tappable.
const CLEAR := 34.0

var ctx: UICtx
var tile := -1
var is_open := false
## Callable() -> Array[Rect2]: HUD panels the buttons must stay clear of.
var blockers: Callable
## the command bar (the buttons stay above it)
var bar: CommandBar = null
var _side := -1
var _panel: GlassPanel
var _caption: Label
var _no: Button
var _ok: Button


func _init(c: UICtx) -> void:
	ctx = c
	name = "PlaceConfirmLayer"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = GlassPanel.new(8.0, 6.0, UITheme.R_LG, true, 16)
	add_child(_panel)
	var v := UITheme.vbox(6)
	_panel.add_child(v)
	_caption = UITheme.label("", 12, 700, UITheme.TEXT)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_caption.clip_text = true
	v.add_child(_caption)
	var h := UITheme.hbox(8)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	_no = _round_button("close", false)
	_no.name = "PlaceCancel"
	_no.pressed.connect(func() -> void: cancelled.emit())
	h.add_child(_no)
	_ok = _round_button("check", true)
	_ok.name = "PlaceConfirm"
	_ok.pressed.connect(func() -> void: confirmed.emit())
	h.add_child(_ok)
	v.add_child(h)
	visible = false
	set_process(true)


func _round_button(icon_name: String, primary: bool) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.icon = UITheme.icon_texture(icon_name)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_constant_override("icon_max_width", 22)
	b.custom_minimum_size = Vector2(BTN, BTN)
	var r := int(BTN * 0.5)
	var bg := UITheme.flat(UITheme.AMBER if primary else UITheme.rgba(0.08, 0.1, 0.16, 0.92), r, UITheme.AMBER_LO if primary else UITheme.LINE_2, 0 if primary else 1, 4.0, 4.0)
	if primary:
		bg.border_width_bottom = 3
		bg.border_color = UITheme.AMBER_LO
	var hot: StyleBoxFlat = bg.duplicate()
	hot.bg_color = UITheme.AMBER_HI if primary else UITheme.rgba(0.14, 0.17, 0.25, 0.95)
	for st in ["normal", "disabled"]:
		b.add_theme_stylebox_override(st, bg)
	for st2 in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st2, hot)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var ic: Color = UITheme.INK if primary else UITheme.TEXT
	for cn in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_disabled_color"]:
		b.add_theme_color_override(cn, ic)
	return b


## Show the buttons for the ghost at `t`. `danger` paints the confirm button red (nuke launch).
func show_for(t: int, caption: String, danger: bool, ok: bool = true) -> void:
	tile = t
	_caption.text = caption
	_caption.custom_minimum_size = Vector2(minf(UITheme.text_width(caption, 12, 700) + 4.0, 230.0), 0)
	_ok.disabled = not ok
	var col: Color = UITheme.RED if danger else UITheme.AMBER
	var sb: StyleBoxFlat = _ok.get_theme_stylebox("normal").duplicate()
	sb.bg_color = col if ok else Color(1, 1, 1, 0.1)
	sb.border_color = col.darkened(0.3)
	_ok.add_theme_stylebox_override("normal", sb)
	_ok.add_theme_stylebox_override("disabled", sb)
	var was := is_open
	is_open = true
	visible = true
	_panel.reset_size()
	_side = -1
	_follow(true)
	if not was:
		UIFx.pop_in(_panel, 0.0, 0.9, 0.2)


func hide_confirm() -> void:
	if not is_open:
		return
	is_open = false
	tile = -1
	visible = false


func panel_rect() -> Rect2:
	return _panel.get_global_rect() if is_open else Rect2()


func button_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if is_open:
		out.append(_ok.get_global_rect())
		out.append(_no.get_global_rect())
	return out


func _process(_delta: float) -> void:
	if is_open:
		_follow(false)


## Beside the ghost: right, left, above or below: the first spot inside the free screen area that
## keeps CLEAR px from the ghost and off the HUD; the chosen side sticks while it still fits.
func _follow(force: bool) -> void:
	var p := ctx.tile_screen_pos(tile)
	if p.x < 0.0:
		_panel.visible = false  # off the map view: nothing to confirm against right now
		return
	_panel.visible = true
	var sz := _panel.get_combined_minimum_size()
	var area := ctx.clear_rect()
	if bar != null and bar.is_visible_in_tree():
		area.end.y = minf(area.end.y, bar.top_edge() - 6.0)
	var cands: Array[Vector2] = [
		Vector2(p.x + CLEAR, p.y - sz.y * 0.5),  # right
		Vector2(p.x - CLEAR - sz.x, p.y - sz.y * 0.5),  # left
		Vector2(p.x - sz.x * 0.5, p.y - CLEAR - sz.y),  # above
		Vector2(p.x - sz.x * 0.5, p.y + CLEAR),  # below
	]
	var blocked: Array = blockers.call() if blockers.is_valid() else []
	var order := [0, 1, 2, 3]
	if not force and _side >= 0:
		order.erase(_side)
		order.push_front(_side)
	var best := -1
	var best_pos := Vector2.ZERO
	for i: int in order:
		var q := cands[i]
		var r := Rect2(q, sz)
		if not area.encloses(r):
			continue
		var hit := false
		for b: Rect2 in blocked:
			if r.intersects(b):
				hit = true
				break
		if hit:
			continue
		best = i
		best_pos = q
		break
	if best < 0:
		# Nothing fits cleanly: clamp the right-hand spot into the area, then push it off the ghost.
		var q2 := cands[0]
		var x := clampf(q2.x, area.position.x, maxf(area.position.x, area.end.x - sz.x))
		var y := clampf(q2.y, area.position.y, maxf(area.position.y, area.end.y - sz.y))
		if Rect2(Vector2(x, y), sz).grow(CLEAR * 0.5).has_point(p):
			y = p.y - CLEAR - sz.y if p.y - CLEAR - sz.y >= area.position.y else p.y + CLEAR
		best_pos = Vector2(x, y)
	_side = best
	_panel.position = Vector2(floorf(best_pos.x + 0.5), floorf(best_pos.y + 0.5))
