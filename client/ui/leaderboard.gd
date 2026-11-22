# Port of src/client/UI/Leaderboard.luau (scripts/ui/leaderboard.gd, UILeaderboard).
# Right-side leaderboard: top 10 by land share with colour, name, land % and troops. Your own row is
# pinned when you are outside the top 10; allies and traitors are marked. Clicking a row focuses the
# camera on that nation. On phones it collapses into a rank pill. Game admins see a person icon on
# real players' rows, and every real player outside the top is pinned below it.
#
# Every match starts with the board closed (close_for_match): the pill opens it, and it stays as the
# player leaves it until the match ends.
#
# Left out: the Roblox head shot and the cosmetic flag of a row (Data/Cosmetics; no accounts here).
#
# Members: panel, _pill, expanded, user_hidden, pill_enabled.
# Methods: set_open(on), toggle(), close_for_match(), apply_layout(top), place_pill_left_of(rect),
# bottom_edge(), my_rank(), mark_dirty(), refresh(); per frame update(dt).
class_name Leaderboard
extends Control

signal toggled(open: bool)

const ROWS := 10
## Game admins: real players outside the top rows pinned below them (desktop / phones).
const ADMIN_PINS := 8
const ADMIN_PINS_COMPACT := 3
## Phones: the board is a peek (opened from the status pill) that folds itself away again.
const PEEK_SECONDS := 8.0
const TEAM_ROWS := 7


# ---------------------------------------------------------------------------------------------
# Row
# ---------------------------------------------------------------------------------------------
class Row:
	extends Button

	var ctx: UICtx
	var owner_id := 0
	var is_me := false
	var _hover := false
	var rank: Label
	var sw: PanelContainer
	var name_l: Label
	var mark: TextureRect
	var human: TextureRect
	var land: Label
	var troops: Label

	func _init(c: UICtx) -> void:
		var T := UITheme
		ctx = c
		flat = true
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(0, 28)
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			add_theme_stylebox_override(st, T.empty_box())
		var h := T.hbox(8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 10.0
		h.offset_right = -10.0
		add_child(h)
		rank = T.label("1", 12, 600, T.TEXT_3)
		T.fix_width(rank, 26.0, HORIZONTAL_ALIGNMENT_RIGHT)
		rank.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(rank)
		sw = T.swatch(T.TEXT, 10.0, 3)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(sw)
		name_l = T.label("", 13, 600)
		name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.custom_minimum_size = Vector2(40, 0)
		name_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(name_l)
		mark = T.icon_rect("alliance", 13.0, T.GREEN)
		mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(mark)
		# game admins only: a person icon on real players' rows
		human = T.icon_rect("users", 13.0, T.CYAN)
		human.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		human.visible = false
		h.add_child(human)
		land = T.label("", 13, 700)
		T.fix_width(land, T.text_width("88.88%", 13, 700) + 2.0, HORIZONTAL_ALIGNMENT_RIGHT)
		land.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(land)
		troops = T.label("", 12, 500, T.TEXT_2)
		T.fix_width(troops, T.text_width("888.8K", 12, 500) + 2.0, HORIZONTAL_ALIGNMENT_RIGHT)
		troops.clip_text = false  # (port: a longer value shrinks to fit instead of being cut off)
		troops.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		troops.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(troops)
		mouse_entered.connect(func() -> void:
			if ctx.touch:
				return
			_hover = true
			ctx.world_call("set_hover_owner", [owner_id])
			queue_redraw())
		mouse_exited.connect(func() -> void:
			_hover = false
			ctx.world_call("set_hover_owner", [0])
			queue_redraw())
		pressed.connect(func() -> void:
			if owner_id != 0:
				# spectating (a watcher, or knocked out): the switch sound
				var mine = ctx.my()
				if ctx.me() == 0 or (mine != null and mine.alive == false):
					ctx.sfx("spectate_switch")
				ctx.world_call("focus_owner", [owner_id]))

	func set_row(o: Dictionary, r: int) -> void:
		var T := UITheme
		var s = ctx.state
		owner_id = o.id
		is_me = o.id == ctx.me()
		rank.text = str(r)
		T.set_swatch_color(sw, o.color)
		name_l.text = o.name
		land.text = T.fmt_pct(s.land_share(o.id))
		T.fit_label(troops, T.fmt_troops(o.troops), troops.custom_minimum_size.x, 12, 8)
		# Threat context: a neighbour with over 3x our army reads red.
		var mine = ctx.my()
		var threat: bool = mine != null and not is_me and mine.troops > 0 and o.troops > 3 * mine.troops and not s.are_allies(ctx.me(), o.id) and s.borders_owner(ctx.me(), o.id)
		T.set_font_color(troops, T.RED if threat else T.TEXT_2)
		var ally: bool = s.are_allies(ctx.me(), o.id)
		var traitor: bool = s.is_traitor(o.id)
		mark.visible = ally or traitor
		if traitor:
			mark.texture = T.icon_texture("betray")
			mark.modulate = T.RED
		elif ally:
			mark.texture = T.icon_texture("alliance")
			mark.modulate = T.GREEN
		var nc: Color = T.TEXT
		if is_me:
			nc = T.AMBER_HI
		elif traitor:
			nc = Color(1.0, 0.7, 0.72)
		T.set_font_color(name_l, nc)
		T.set_font_color(rank, T.GOLD if r == 1 else T.TEXT_3)
		human.visible = Leaderboard.is_real_player(ctx, o)
		queue_redraw()

	func _draw() -> void:
		if ctx == null:
			return
		var T := UITheme
		var r := Rect2(2, 1, size.x - 4, size.y - 2)
		if is_me:
			draw_style_box(T.flat(T.c(T.AMBER, 0.12), 7, T.c(T.AMBER, 0.35), 1), r)
		elif _hover and not ctx.touch:
			draw_style_box(T.flat(Color(1, 1, 1, 0.07), 7), r)


# ---------------------------------------------------------------------------------------------
# Leaderboard
# ---------------------------------------------------------------------------------------------
var ctx: UICtx
var expanded := false
var user_hidden := false
var _rows: Array[Row] = []
var _accum := 0.0
var _dirty := true
var _opened_msec := 0.0
var _layout_key := ""
## Phones: no separate rank pill (the status panel shows the rank and opens the board).
var pill_enabled := true
var humans_only := false

var panel: GlassPanel
var _header: HBoxContainer
var _humans_btn: Button
var _count: Label
var _close: Button
var _cols: HBoxContainer
var _cols_margin: MarginContainer
var _list: VBoxContainer
var _pin_sep: Label
var _pins: Array[Row] = []
var _pin_more: Label
var _pill: Button
var _team_box: VBoxContainer = null


## Game admins only (Session.admin_bots): a real player, not a bot filling the lobby.
static func is_real_player(c: UICtx, o: Dictionary) -> bool:
	var bots = c.session.get("admin_bots") if c.session != null else null
	return bots != null and o.kind == Defs.KIND_HUMAN and not bots.get(o.id, false)


func _init(c: UICtx) -> void:
	var T := UITheme
	ctx = c
	name = "Leaderboard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = GlassPanel.new(8.0, 10.0, T.R_LG, true, 18)
	add_child(panel)
	var v := T.vbox(4)
	panel.add_child(v)
	_header = T.hbox(8)
	var hm := MarginContainer.new()
	hm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hm.add_theme_constant_override("margin_left", 10)
	hm.add_theme_constant_override("margin_right", 4)
	hm.add_child(_header)
	var hi := T.icon_rect("leaderboard", 14.0, T.AMBER)
	hi.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_header.add_child(hi)
	var ht := T.label("LEADERBOARD", 12, 800, T.TEXT, 2)
	ht.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_header.add_child(ht)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(sp)
	# game admins only: show just the real players
	var hf := T.button("HUMANS", "ChipButton", "", 22.0)
	hf.toggle_mode = true
	hf.add_theme_font_size_override("font_size", 10)
	hf.pressed.connect(func() -> void:
		humans_only = hf.button_pressed
		mark_dirty())
	hf.visible = false
	_humans_btn = hf
	_header.add_child(hf)
	_count = T.label("", 11, 600, T.TEXT_3)
	T.fix_width(_count, 64.0, HORIZONTAL_ALIGNMENT_RIGHT)
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_header.add_child(_count)
	var close := Button.new()
	close.theme_type_variation = "GhostButton"
	close.focus_mode = Control.FOCUS_NONE
	close.icon = T.icon_texture("close")
	close.expand_icon = true
	close.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close.custom_minimum_size = Vector2(26, 26)
	close.add_theme_constant_override("icon_max_width", 11)
	close.add_theme_stylebox_override("normal", T.empty_box(6, 6))
	close.add_theme_stylebox_override("hover", T.flat(T.FILL, 6, T.CLEAR, 0, 6, 6))
	close.pressed.connect(func() -> void: set_open(false))
	_close = close
	_header.add_child(close)
	v.add_child(hm)
	_cols = T.hbox(8)
	var cm := MarginContainer.new()
	cm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cm.add_theme_constant_override("margin_left", 10)
	cm.add_theme_constant_override("margin_right", 10)
	cm.add_child(_cols)
	var c1 := T.caption("#", 10)
	c1.custom_minimum_size = Vector2(22, 0)
	c1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cols.add_child(c1)
	var c2 := T.caption("Nation", 10)
	c2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c2.custom_minimum_size = Vector2(18, 0)
	_cols.add_child(c2)
	var c3 := T.caption("Land", 10)
	c3.custom_minimum_size = Vector2(50, 0)
	c3.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cols.add_child(c3)
	var c4 := T.caption("Troops", 10)
	c4.custom_minimum_size = Vector2(46, 0)
	c4.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cols.add_child(c4)
	v.add_child(cm)
	_cols_margin = cm
	v.add_child(T.hdivider())
	_list = T.vbox(0)
	v.add_child(_list)
	for _i in ROWS:
		var r := Row.new(c)
		r.pressed.connect(func() -> void: _opened_msec = UICtx.msec())
		_rows.append(r)
		_list.add_child(r)
	_pin_sep = T.label("···", 12, 700, T.TEXT_3)
	_pin_sep.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_list.add_child(_pin_sep)
	## rows pinned below the top: yours, and (admins) real players; grown on demand
	_pin_more = T.label("", 11, 600, T.TEXT_3)
	_pin_more.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pin_more.visible = false
	_list.add_child(_pin_more)
	var pill := Button.new()
	pill.theme_type_variation = "GlassButton"
	pill.focus_mode = Control.FOCUS_NONE
	pill.icon = T.icon_texture("leaderboard")
	pill.add_theme_constant_override("icon_max_width", 16)
	pill.custom_minimum_size = Vector2(0, 40)
	pill.add_theme_stylebox_override("normal", T.box(T.GLASS, 999, T.LINE, 1, 14, 6))
	for st in ["hover", "pressed", "hover_pressed"]:
		pill.add_theme_stylebox_override(st, T.box(T.GLASS_RAISED, 999, T.LINE_2, 1, 14, 6))
	pill.add_theme_font_size_override("font_size", 13)
	pill.pressed.connect(func() -> void: set_open(true))
	_pill = pill
	add_child(pill)
	pill.visible = false


func set_open(on: bool) -> void:
	var was := expanded
	expanded = on
	user_hidden = not on
	_opened_msec = UICtx.msec()
	_apply_visibility()
	if on and not was:
		UIFx.pop_in(panel, 0.0, 0.97, 0.3)
		ctx.sfx("open", -8.0)
	elif not on and was:
		ctx.sfx("close", -8.0)
	refresh()
	if on != was:
		toggled.emit(on)


func toggle() -> void:
	set_open(not expanded)


## A new match: the board is closed, without the sound or the signal of a player closing it.
func close_for_match() -> void:
	expanded = false
	user_hidden = false
	_apply_visibility()


func _apply_visibility() -> void:
	panel.visible = expanded
	_pill.visible = not expanded and pill_enabled


func apply_layout(top: float) -> void:
	pill_enabled = not ctx.compact
	# Phones never keep the board open (it is a peek): a screen that turns into one closes it.
	var key := "compact" if ctx.compact else ("touch" if ctx.touch else "desktop")
	if key != _layout_key:
		_layout_key = key
		if ctx.compact:
			expanded = false
	var right := 12.0 + ctx.insets.z
	var w := 250.0 if ctx.compact else 300.0
	for c in [panel, _pill]:
		c.anchor_left = 1.0
		c.anchor_right = 1.0
		c.anchor_top = 0.0
		c.anchor_bottom = 0.0
		c.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		c.grow_vertical = Control.GROW_DIRECTION_END
		c.offset_left = -right
		c.offset_right = -right
		c.offset_top = top
		c.offset_bottom = top
	panel.custom_minimum_size = Vector2(w, 0)
	for r in _rows:
		r.custom_minimum_size = Vector2(0, 44 if ctx.touch else 28)
	for r in _pins:
		r.custom_minimum_size = Vector2(0, 44 if ctx.touch else 28)
	_close.custom_minimum_size = Vector2(44, 44) if ctx.touch else Vector2(26, 26)
	_pill.custom_minimum_size = Vector2(170, 44 if ctx.touch else 40)
	_pill.clip_text = true
	_cols_margin.visible = not ctx.compact
	_apply_visibility()
	panel.reset_size()
	_pill.reset_size()
	_dirty = true


## Phones: put the collapsed rank pill to the left of `status` (same row) to save height.
func place_pill_left_of(status: Rect2) -> void:
	var p := _pill
	var right_edge := ctx.vp.x - status.position.x + 8.0
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.offset_left = -right_edge
	p.offset_right = -right_edge
	p.offset_top = status.position.y + (status.size.y - p.get_combined_minimum_size().y) * 0.5
	p.offset_bottom = p.offset_top
	p.reset_size()


func bottom_edge() -> float:
	if panel.visible:
		return panel.get_rect().end.y
	if _pill.visible:
		return _pill.get_rect().end.y
	return -1.0


## My rank (1-based) for other panels; 0 when unranked.
func my_rank() -> int:
	if ctx.state == null or ctx.me() == 0:
		return 0
	return ctx.rank_of(ctx.me())


func mark_dirty() -> void:
	_dirty = true


func refresh() -> void:
	_dirty = false
	var s = ctx.state
	if s == null:
		return
	var admin: bool = ctx.session != null and ctx.session.get("admin_bots") != null
	_humans_btn.visible = admin
	var only_humans := admin and humans_only
	# Closed (every match starts so): only the pill can show; the rows and the panel are filled when
	# it opens (set_open).
	var mine := ctx.me()
	if not expanded and not only_humans:
		_set_pill(ctx.rank_of(mine) if mine != 0 else 0, ctx.leader())
		return
	var ranking: Array = s.ranking()
	if only_humans:
		ranking = ranking.filter(func(o) -> bool: return is_real_player(ctx, o))
	var shown := mini(ROWS if not ctx.compact else 5, ranking.size())
	var my_rank_i := -1
	for i in ranking.size():
		if ranking[i].id == mine:
			my_rank_i = i + 1
			break
	for i in _rows.size():
		var r := _rows[i]
		r.visible = i < shown
		if i < shown:
			r.set_row(ranking[i], i + 1)
	# pinned below the top: your own row, and for admins the real players (up to a cap)
	var cap := ADMIN_PINS_COMPACT if ctx.compact else ADMIN_PINS
	var pins: Array[int] = []
	var humans := 0
	var more := 0
	for i in range(shown, ranking.size()):
		var o: Dictionary = ranking[i]
		if o.id == mine and mine != 0:
			pins.append(i)
		elif is_real_player(ctx, o):
			if humans < cap:
				humans += 1
				pins.append(i)
			else:
				more += 1
	for j in pins.size():
		var r: Row
		if j < _pins.size():
			r = _pins[j]
		else:
			r = Row.new(ctx)
			r.custom_minimum_size = Vector2(0, 44 if ctx.touch else 28)
			r.pressed.connect(func() -> void: _opened_msec = UICtx.msec())
			_pins.append(r)
			_list.add_child(r)
			_list.move_child(_pin_more, -1)
		r.visible = true
		r.set_row(ranking[pins[j]], pins[j] + 1)
	for j in range(pins.size(), _pins.size()):
		_pins[j].visible = false
		_pins[j].owner_id = 0
	_pin_sep.visible = pins.size() > 0
	_pin_more.visible = more > 0
	if more > 0:
		_pin_more.text = "+%d more %s" % [more, "human" if more == 1 else "humans"]
	_refresh_teams()
	_count.text = ("%d humans" if only_humans else "%d alive") % ranking.size()
	_set_pill(my_rank_i, ranking[0] if ranking.size() > 0 else null)
	panel.reset_size()


## The pill: my rank (`rank` > 0) and land, else the leader's name (cut to 10 characters) and land.
func _set_pill(rank: int, leader) -> void:
	var T := UITheme
	var s = ctx.state
	var text := "Leaderboard"
	if rank > 0:
		text = "#%d  ·  %s" % [rank, T.fmt_pct(s.land_share(ctx.me()))]
	elif leader != null:
		var nm: String = leader.name
		if nm.length() > 10:
			nm = nm.substr(0, 9) + "…"
		text = "%s  %s" % [nm, T.fmt_pct(s.land_share(leader.id))]
	if text != _pill.text:
		_pill.text = text


## A team game (Core/Teams): the teams above the players, by land.
func _refresh_teams() -> void:
	var T := UITheme
	var s = ctx.state
	var on: bool = s != null and s.has_method("is_team_game") and s.is_team_game()
	if not on:
		if _team_box != null:
			_team_box.visible = false
		return
	if _team_box == null:
		_team_box = T.vbox(2)
		_list.add_child(_team_box)
		_list.move_child(_team_box, 0)
	var box := _team_box
	box.visible = true
	for ch in box.get_children():
		box.remove_child(ch)
		ch.queue_free()
	var mine: int = s.team_of(ctx.me()) if ctx.me() != 0 else 0
	var teams: Array = s.team_ranking()
	var limit := 3 if ctx.compact else TEAM_ROWS
	for i in teams.size():
		var r = teams[i]
		if i + 1 > limit and r.team != mine:
			continue
		var row := T.hbox(6)
		row.custom_minimum_size = Vector2(0, 22)
		var col: Color = s.team_color(r.team)
		var sw := T.swatch(col, 10.0, 3)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sw)
		var nm := T.label(ctx.team_label(r.team), 12, 800 if r.team == mine else 600, T.owner_ui_color(col) if r.team == mine else T.TEXT)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.clip_text = true
		row.add_child(nm)
		var n := T.label(str(r.members), 11, 600, T.TEXT_3)
		n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(n)
		var sh := T.label(T.fmt_pct(ctx.team_share(r.team)), 12, 700, T.TEXT)
		sh.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sh)
		box.add_child(row)
	box.add_child(T.hdivider())


## Per frame.
func update(delta: float) -> void:
	if ctx.compact and expanded and UICtx.msec() - _opened_msec > PEEK_SECONDS * 1000.0:
		set_open(false)
	_accum += delta
	if _accum >= 1.0 and is_visible_in_tree() and _dirty:
		_accum = 0.0
		refresh()
