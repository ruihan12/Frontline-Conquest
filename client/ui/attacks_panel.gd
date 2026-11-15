# Port of src/client/UI/AttacksPanel.luau (scripts/ui/attacks_panel.gd, UIAttacksPanel).
# Active attacks involving you (right side, under the leaderboard): incoming fronts in red with a
# Focus button, outgoing fronts and expansions with their committed troops and a Retreat button.
# Phones show only a small chip (icon + count, red when you are attacked); a tap opens the list as a
# peek that folds itself away again.
#
# Members: panel, collapsed, manual, tray_open.
# Methods: apply_layout(top, bottom_limit), peek(), bottom_edge(), mark_dirty(), involved(),
# committed(), refresh(); per frame update(dt).
class_name AttacksPanel
extends Control

signal retreat_requested(aid: int)
signal toggled(collapsed: bool)

const MAX_ROWS_DESKTOP := 6
const MAX_ROWS_PHONE := 2
## Lists this short never get summarised.
const ALWAYS_ROWS := 2
## Phones: seconds an opened list stays open after the last touch.
const PEEK_SECONDS := 8.0


# ---------------------------------------------------------------------------------------------
# Row
# ---------------------------------------------------------------------------------------------
class Row:
	extends PanelContainer

	signal retreat(aid: int)
	signal touched

	var ctx: UICtx
	var aid := 0
	var incoming := -1  # -1 unset, 0 outgoing, 1 incoming
	var focus_tile := -1
	var focus_id := 0
	var _bg_in: StyleBoxFlat
	var _bg_out: StyleBoxFlat
	var arrow: TextureRect
	var sw: PanelContainer
	var name_l: Label
	var troops_l: Label
	var action: Button

	func _init(c: UICtx) -> void:
		var T := UITheme
		ctx = c
		mouse_filter = Control.MOUSE_FILTER_STOP
		_bg_in = T.flat(T.c(T.RED, 0.14), 8, T.c(T.RED, 0.45), 1, 8.0, 3.0)
		_bg_out = T.flat(Color(1, 1, 1, 0.04), 8, Color(1, 1, 1, 0.06), 1, 8.0, 3.0)
		add_theme_stylebox_override("panel", _bg_out)
		var h := T.hbox(8)
		add_child(h)
		arrow = T.icon_rect("attack", 13.0, T.AMBER)
		arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(arrow)
		sw = T.swatch(T.TEXT, 9.0, 2)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(sw)
		name_l = T.label("", 13, 600)
		name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.custom_minimum_size = Vector2(40, 0)
		name_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(name_l)
		troops_l = T.label("", 13, 700)
		T.fix_width(troops_l, T.text_width("888.8K", 13, 700) + 2.0, HORIZONTAL_ALIGNMENT_RIGHT)
		troops_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(troops_l)
		action = Button.new()
		action.theme_type_variation = "GlassButton"
		action.focus_mode = Control.FOCUS_NONE
		action.expand_icon = true
		action.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		action.add_theme_constant_override("icon_max_width", 14)
		action.add_theme_font_size_override("font_size", 11)
		action.custom_minimum_size = Vector2(30, 28)
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			action.add_theme_stylebox_override(st, T.flat(T.FILL if st == "normal" else T.FILL_2, 7, T.LINE, 1, 6.0, 4.0))
		action.pressed.connect(_on_action)
		h.add_child(action)
		gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_focus())

	func set_attack(a: Dictionary, touch: bool) -> void:
		var T := UITheme
		var s = ctx.state
		aid = a.aid
		var inc: bool = a.target == ctx.me()
		var other: int = a.attacker if inc else a.target
		focus_id = other
		focus_tile = a.anchor_tile
		# Expansions into neutral land are routine: draw them quieter than real fronts.
		modulate.a = 0.72 if (not inc and other == 0) else 1.0
		if incoming != int(inc):
			incoming = int(inc)
			add_theme_stylebox_override("panel", _bg_in if inc else _bg_out)
		arrow.texture = T.icon_texture("target" if inc else ("attack" if other != 0 else "globe"))
		arrow.modulate = T.RED if inc else (T.AMBER if other != 0 else T.GREEN)
		sw.visible = other != 0
		if other != 0:
			T.set_swatch_color(sw, s.owner_color(other))
		# a retreating attack says so and can't be recalled again
		var nm: String = s.owner_name(other) if other != 0 else "Expansion"
		name_l.text = nm + " (retreating…)" if a.retreating else nm
		T.set_font_color(name_l, Color(1.0, 0.82, 0.84) if inc else T.TEXT)
		troops_l.text = T.fmt_troops(a.troops)
		T.set_font_color(troops_l, T.RED if inc else T.TEXT)
		action.custom_minimum_size = Vector2(48 if touch else 30, 44 if touch else 26)
		action.icon = T.icon_texture("eye" if inc else "retreat")
		action.text = ""
		action.disabled = a.retreating == true and not inc

	func _on_action() -> void:
		touched.emit()
		if incoming == 1:
			_focus()
		else:
			retreat.emit(aid)

	func _focus() -> void:
		touched.emit()
		if focus_tile >= 0:
			ctx.world_call("focus_tile", [focus_tile, -1.0, 0.8])
		elif focus_id != 0:
			ctx.world_call("focus_owner", [focus_id])


# ---------------------------------------------------------------------------------------------
# Panel
# ---------------------------------------------------------------------------------------------
var ctx: UICtx
var _rows: Array[Row] = []
var _accum := 0.0
var _dirty := true
## Effective state (computed in refresh()).
var collapsed := false
## Player override: 0 = automatic, 1 = keep open, 2 = keep collapsed (reset when the list empties).
var manual := 0
## The phone build tray is open (the panel folds to its header so the tray never covers rows).
var tray_open := false
var _bottom_limit := -1.0
var _peek_msec := 0.0
var _chip_key := ""
var _fit_text := ""

var panel: GlassPanel
var _icon: TextureRect
var _title: Label
var _count: Label
var _chev: TextureRect
var _head_btn: Button
var _list: VBoxContainer
var _more: Label


func _init(c: UICtx) -> void:
	var T := UITheme
	ctx = c
	name = "AttacksPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = GlassPanel.new(10.0, 9.0, T.R_LG, true, 16)
	add_child(panel)
	var v := T.vbox(5)
	panel.add_child(v)
	var head := T.hbox(8)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon = T.icon_rect("attack", 13.0, T.AMBER)
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_icon)
	_title = T.label("ATTACKS", 12, 800, T.TEXT, 2)
	head.add_child(_title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(sp)
	_count = T.label("", 11, 600, T.TEXT_3)
	T.fix_width(_count, 90.0, HORIZONTAL_ALIGNMENT_RIGHT, false)
	head.add_child(_count)
	_chev = T.icon_rect("chevron", 12.0, T.TEXT_3)
	_chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_chev)
	# The whole header toggles the list (phones keep the globe clear with one tap).
	var hb := Button.new()
	hb.theme_type_variation = "GhostButton"
	hb.flat = true
	hb.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		hb.add_theme_stylebox_override(st, T.empty_box())
	hb.custom_minimum_size = Vector2(0, 24)
	var hm := MarginContainer.new()
	hm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hm.add_theme_constant_override("margin_left", 4)
	hm.add_theme_constant_override("margin_right", 4)
	hm.add_child(head)
	hb.add_child(hm)
	hb.pressed.connect(func() -> void:
		manual = 1 if collapsed else 2
		_peek_msec = UICtx.msec()
		refresh()
		toggled.emit(collapsed))
	_head_btn = hb
	v.add_child(hb)
	_list = T.vbox(4)
	v.add_child(_list)
	_more = T.label("", 11, 600, T.TEXT_3)
	_more.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_more)
	panel.visible = false


## `bottom_limit`: the panel must end above this y (the command bar); rows that do not fit are
## summarised as "+N more".
func apply_layout(top: float, bottom_limit: float = -1.0) -> void:
	_bottom_limit = bottom_limit
	var right := 12.0 + ctx.insets.z
	var p := panel
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.anchor_top = 0.0
	p.anchor_bottom = 0.0
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	p.grow_vertical = Control.GROW_DIRECTION_END
	p.offset_left = -right
	p.offset_right = -right
	p.offset_top = top
	p.offset_bottom = top
	_head_btn.custom_minimum_size.y = 44 if ctx.touch else 24
	_fit_chip()
	p.reset_size()


## Keep the phone list open (e.g. after the player used a row).
func peek() -> void:
	manual = 1
	_peek_msec = UICtx.msec()


## Phones: collapsed = a small chip exactly one touch target tall; open = the list panel.
func _fit_chip() -> void:
	var chip := ctx.compact and collapsed
	var key := "%s|%s" % [ctx.compact, chip]
	if key == _chip_key:
		return
	_chip_key = key
	_title.visible = not chip
	_list.visible = not chip
	panel.custom_minimum_size = Vector2(0.0 if chip else (250.0 if ctx.compact else 300.0), 0)
	if ctx.compact:
		if chip:
			panel.set_padding(6.0, 0.0, 4.0, 0.0)
		else:
			panel.set_padding(10.0, 2.0, 10.0, 8.0)
	else:
		panel.set_padding(10.0, 9.0, 10.0, 9.0)
	UITheme.fix_width(_count, 90.0, HORIZONTAL_ALIGNMENT_RIGHT, false)
	_count.add_theme_font_size_override("font_size", 12 if chip else 11)
	_fit_chip_width()


## Chip: as narrow as its count ("3", "3 · 1 in"); the header button carries that width (margins 4 +
## icon + gap + count + gap + chevron + margins 4, and a full 44 px at least).
func _fit_chip_width() -> void:
	if not (ctx.compact and collapsed):
		_head_btn.custom_minimum_size.x = 0.0
		return
	var cw := UITheme.text_width(_count.text if _count.text != "" else "8", 12, 700) + 2.0
	_count.custom_minimum_size.x = cw
	_head_btn.custom_minimum_size.x = maxf(44.0, 4.0 + 13.0 + 8.0 + cw + 8.0 + 12.0 + 4.0)


func bottom_edge() -> float:
	if panel.visible:
		return panel.get_rect().end.y
	return -1.0


func mark_dirty() -> void:
	_dirty = true


## Attacks involving the local player, incoming first, then by committed troops.
func involved() -> Array:
	var out: Array = []
	var s = ctx.state
	var mine := ctx.me()
	if s == null or mine == 0:
		return out
	for a in s.attacks():
		if a.attacker == mine or a.target == mine:
			out.append(a)
	out.sort_custom(func(p, q) -> bool:
		var pi: bool = p.target == mine
		var qi: bool = q.target == mine
		if pi != qi:
			return pi
		var pe: bool = p.target == 0
		var qe: bool = q.target == 0
		if pe != qe:
			return qe
		if p.troops != q.troops:
			return p.troops > q.troops
		return p.aid < q.aid)
	return out


## Phones fold the panel to its header while the build tray is open, and while only expansions into
## neutral land are running (those are routine, not wars); the player can override by tapping.
func _want_collapsed(list: Array) -> bool:
	if list.size() == 0:
		manual = 0
		return false
	if tray_open and ctx.compact:
		return true
	if ctx.compact:
		# A peek: open only after a tap, and only until the player leaves it alone for a while.
		if manual == 1 and UICtx.msec() - _peek_msec < PEEK_SECONDS * 1000.0:
			return false
		manual = 0
		return true
	if manual != 0:
		return manual == 2
	return false


## Troops currently committed to our outgoing attacks.
func committed() -> float:
	var n := 0.0
	for a in involved():
		if a.attacker == ctx.me():
			n += a.troops
	return n


func refresh() -> void:
	var T := UITheme
	_dirty = false
	var list := involved()
	var was := panel.visible
	panel.visible = list.size() > 0 and ctx.alive_player()
	if not panel.visible:
		return
	var max_rows := MAX_ROWS_PHONE if ctx.compact else MAX_ROWS_DESKTOP
	if _bottom_limit > 0:
		var row_h := 48.0 if ctx.touch else 30.0
		var head_h := _head_btn.custom_minimum_size.y + 24.0
		var room := _bottom_limit - panel.offset_top - head_h
		max_rows = clampi(int(floor(room / row_h)), 0, max_rows)
	# Short lists are always shown in full; "+N more" only summarises a real overflow.
	max_rows = maxi(max_rows, mini(ALWAYS_ROWS, list.size()))
	if list.size() == max_rows + 1:
		max_rows += 1  # "+1 more" would take a row anyway
	var was_collapsed := collapsed
	collapsed = _want_collapsed(list)
	if collapsed != was_collapsed or not was:
		_fit_chip()
	var shown := 0 if collapsed else mini(max_rows, list.size())
	_chev.pivot_offset = _chev.size * 0.5
	_chev.rotation = -PI * 0.5 if collapsed else 0.0
	while _rows.size() < shown:
		var r := Row.new(ctx)
		r.retreat.connect(func(aid: int) -> void: retreat_requested.emit(aid))
		r.touched.connect(func() -> void: _peek_msec = UICtx.msec())
		_rows.append(r)
		_list.add_child(r)
	for i in _rows.size():
		var r := _rows[i]
		r.visible = i < shown
		if i < shown:
			r.set_attack(list[i], ctx.touch)
	var inc := 0
	for a in list:
		if a.target == ctx.me():
			inc += 1
	var outc := list.size() - inc
	var parts := PackedStringArray()
	if outc > 0:
		parts.append("%d out" % outc)
	if inc > 0:
		parts.append("%d in" % inc)
	var ctext := "  ·  ".join(parts)
	if ctx.compact and collapsed:
		ctext = str(list.size()) if inc == 0 else "%d · %d in" % [list.size(), inc]
	_count.text = ctext
	T.set_font_color(_count, T.RED if inc > 0 else (T.TEXT if (collapsed and ctx.compact) else T.TEXT_3))
	if ctx.compact and collapsed and _count.text != _fit_text:
		_fit_text = _count.text
		_fit_chip_width()
	_icon.texture = T.icon_texture("target" if inc > 0 else "attack")
	_icon.modulate = T.RED if inc > 0 else T.AMBER
	_more.visible = list.size() > shown and not collapsed
	_more.text = "+%d more" % (list.size() - shown)
	panel.reset_size()
	if not was:
		UIFx.pop_in(panel, 0.0, 0.96, 0.3)


## Per frame.
func update(delta: float) -> void:
	_accum += delta
	if (_dirty or _accum >= 0.5) and is_visible_in_tree():
		_accum = 0.0
		refresh()
