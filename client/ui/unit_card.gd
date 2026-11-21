# Port of src/client/UI/UnitCard.luau (scripts/ui/unit_card.gd, UIUnitCard).
# The selected warship's card: owner, hull points, veterancy and what it is doing, with the hint
# that a click on the sea moves it; plus the pulsing marker where a move order was given.
class_name UnitCard
extends Control

signal closed

const STATE_TEXT := ["Patrolling", "Returning to port for repairs", "Repairing"]
const DEST_SECONDS := 2.5

var ctx: UICtx
var uid := 0
var is_open := false
var own := false
## the command bar (the card sits above it)
var bar: CommandBar = null
var _accum := 0.0
var _dest_tile := -1
var _dest_t := 0.0
var _marker: Control
var _panel: GlassPanel
var _icon: TextureRect
var _title: Label
var _sw: PanelContainer
var _owner_l: Label
var _close: Button
var _hp_bar: FillBar
var _hp_l: Label
var _vet: HBoxContainer
var _vet_l: Label
var _next_l: Label
var _state_l: Label
var _hint: Label


static func field(u: Dictionary, fname: String, fallback: float) -> float:
	var v = u.get(fname)
	return float(v) if (v is float or v is int) else fallback


func _init(c: UICtx) -> void:
	ctx = c
	name = "UnitCard"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker = Control.new()
	_marker.name = "DestMarker"
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.draw.connect(_draw_marker)
	_marker.visible = false
	add_child(_marker)

	var panel := GlassPanel.new(10.0, 4.0, UITheme.R_LG, true, 18)
	panel.set_accent(UITheme.CYAN)
	_panel = panel
	add_child(panel)
	var v := UITheme.vbox(5)
	panel.add_child(v)
	var head := UITheme.hbox(7)
	_icon = UITheme.icon_rect("warship", 16.0, UITheme.CYAN)
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_icon)
	_title = UITheme.label("Warship", 14, 700)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_title)
	_sw = UITheme.swatch(UITheme.TEXT, 9.0, 2)
	_sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_sw)
	_owner_l = UITheme.label("", 12, 600, UITheme.TEXT_2)
	_owner_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_owner_l.clip_text = true
	_owner_l.custom_minimum_size = Vector2(60, 0)
	_owner_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_owner_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_owner_l)
	var x := UITheme.button("", "GhostButton", "close", 44.0)
	x.name = "UnitClose"
	x.expand_icon = true
	x.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	x.add_theme_constant_override("icon_max_width", 12)
	x.custom_minimum_size = Vector2(44, 44)
	x.pressed.connect(func() -> void: hide_card(true))
	_close = x
	head.add_child(x)
	v.add_child(head)

	var hp_row := UITheme.hbox(8)
	_hp_bar = FillBar.new(5.0, UITheme.GREEN)
	_hp_bar.glow = false
	_hp_bar.custom_minimum_size = Vector2(120, 8)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hp_row.add_child(_hp_bar)
	_hp_l = UITheme.label("", 12, 700, UITheme.TEXT)
	UITheme.fix_width(_hp_l, UITheme.text_width("8888 / 8888", 12, 700) + 2.0, HORIZONTAL_ALIGNMENT_RIGHT)
	hp_row.add_child(_hp_l)
	v.add_child(hp_row)

	var vet_row := UITheme.hbox(6)
	_vet = UITheme.hbox(2)
	for _i in 3:
		var ch := UITheme.icon_rect("chevron", 14.0, UITheme.GOLD)
		ch.flip_v = true  # rank chevrons point up
		_vet.add_child(ch)
	vet_row.add_child(_vet)
	_vet_l = UITheme.label("", 12, 600, UITheme.TEXT_2)
	vet_row.add_child(_vet_l)
	v.add_child(vet_row)
	_next_l = UITheme.label("", 12, 500, UITheme.TEXT_3)
	v.add_child(_next_l)
	_state_l = UITheme.label("", 12, 600, UITheme.TEXT_2)
	v.add_child(_state_l)
	_hint = UITheme.label("Tap the sea to move it", 12, 600, UITheme.CYAN)
	v.add_child(_hint)
	panel.custom_minimum_size = Vector2(240, 0)
	panel.visible = false
	set_process(true)


func _unit():
	var s = ctx.state
	return s.unit(uid) if s != null else null


func show_unit(u: int) -> void:
	var s = ctx.state
	var info = s.unit(u) if s != null else null
	if info == null:
		return
	uid = u
	own = info.owner == ctx.me() and ctx.me() != 0
	var was := is_open
	is_open = true
	_panel.visible = true
	refresh()
	place()
	if not was:
		UIFx.pop_in(_panel, 0.0, 0.94, 0.22)
	ctx.sfx("click", -8.0)


func hide_card(user: bool = false) -> void:
	if not is_open:
		return
	is_open = false
	uid = 0
	_panel.visible = false
	if user:
		ctx.sfx("close", -8.0)
	closed.emit()


func refresh() -> void:
	var s = ctx.state
	var u = _unit()
	if u == null:
		hide_card()
		return
	var o = s.get_owner(u.owner)
	UITheme.set_swatch_color(_sw, o.color if o != null else UITheme.TEXT)
	_owner_l.text = "Yours" if own else s.owner_name(u.owner)
	_sw.visible = not own
	var max_hp := field(u, "max_hp", SimRules.WARSHIP_HP)
	if max_hp <= 0.0:
		max_hp = SimRules.WARSHIP_HP
	var hp := field(u, "hp", max_hp)
	var frac := clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)
	_hp_bar.fill_color = UITheme.GREEN if frac > 0.75 else (UITheme.GOLD if frac > 0.35 else UITheme.RED)
	_hp_bar.set_target(frac, true)
	_hp_l.text = "%d / %d" % [int(floor(hp + 0.5)), int(floor(max_hp + 0.5))]
	var vet := int(field(u, "veterancy", 0.0))
	var chevs := _vet.get_children()
	for i in chevs.size():
		chevs[i].modulate.a = 1.0 if i < vet else 0.22
	var max_vet: int = SimRules.WARSHIP_MAX_VET
	var prog := field(u, "vet_progress", -1.0)
	_vet_l.text = "Veterancy %d of %d" % [vet, max_vet]
	_next_l.visible = vet < max_vet
	if prog >= 0.0:
		_next_l.text = "%d%% to the next rank" % int(floor(prog * 100.0 + 0.5))
	else:
		_next_l.text = "Next: sink a warship or %d boats" % SimRules.WARSHIP_VET_TRANSPORTS
	var stt := int(field(u, "state", 0.0))
	_state_l.text = STATE_TEXT[clampi(stt, 0, 2)]
	UITheme.set_font_color(_state_l, UITheme.ORANGE if stt == 1 else (UITheme.GREEN if stt == 2 else UITheme.TEXT_2))
	_hint.visible = own
	_hint.text = "Tap the sea to move it" if ctx.touch else "Click the sea to move it"
	_panel.set_accent(UITheme.CYAN if own else UITheme.ORANGE)


func place() -> void:
	var area := ctx.clear_rect()
	var sz := _panel.get_combined_minimum_size()
	var bottom := area.end.y
	if bar != null and bar.is_visible_in_tree():
		bottom = minf(bottom, bar.top_edge())
	var y := maxf(bottom - sz.y - 10.0, area.position.y + 4.0)
	var cands: Array[Vector2] = []
	if not ctx.compact:
		cands.append(Vector2((ctx.vp.x - sz.x) * 0.5, y))
	cands.append(Vector2(area.position.x + 10.0, y))
	cands.append(Vector2(area.end.x - sz.x - 10.0, y))
	cands.append(Vector2(area.position.x + 10.0, area.position.y + 4.0))
	var sp := ship_screen_pos()
	var p := cands[0]
	for cnd in cands:
		if sp.x < 0.0 or not Rect2(cnd, sz).grow(24.0).has_point(sp):
			p = cnd
			break
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(p.y + 0.5))
	_panel.reset_size()


func ship_screen_pos() -> Vector2:
	var u = _unit()
	if u == null or u.get("path", []).is_empty():
		return Vector2(-1, -1)
	return ctx.tile_screen_pos(u.path[0])


func panel_rect() -> Rect2:
	return _panel.get_global_rect() if is_open else Rect2()


## Pulse a marker where the ship was told to go.
func mark_destination(tile: int) -> void:
	_dest_tile = tile
	_dest_t = DEST_SECONDS
	_marker.visible = true
	_marker.queue_redraw()


func _draw_marker() -> void:
	if _dest_tile < 0 or _dest_t <= 0.0:
		return
	var p := ctx.tile_screen_pos(_dest_tile)
	if p.x < 0.0:
		return
	var a := clampf(_dest_t / DEST_SECONDS, 0.0, 1.0)
	var k := 1.0 - fmod(_dest_t, 0.8) / 0.8
	_marker.draw_arc(p, 6.0 + 16.0 * k, 0, TAU, 40, Color(UITheme.CYAN, a * (1.0 - k)), 2.0, true)
	_marker.draw_arc(p, 9.0, 0, TAU, 32, Color(UITheme.CYAN, a), 2.0, true)
	_marker.draw_circle(p, 3.0, Color(UITheme.CYAN, a), true, -1.0, true)


func _process(delta: float) -> void:
	if _dest_t > 0.0:
		_dest_t -= delta
		if _dest_t <= 0.0:
			_dest_tile = -1
			_marker.visible = false
		_marker.queue_redraw()
	if not is_open:
		return
	_accum += delta
	if _accum >= 0.25:
		_accum = 0.0
		refresh()
