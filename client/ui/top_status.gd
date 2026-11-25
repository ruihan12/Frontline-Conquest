# Port of src/client/UI/TopStatus.luau (scripts/ui/top_status.gd, UITopStatus).
# Top-centre status pill: match clock (and time limit), phase, and world-control progress towards
# the 80 % victory share for you and the current leader. Phones get a one-line mini pill (clock ·
# rank · share, a tiny Protected chip) whose tap opens the leaderboard.
#
# Members: panel, rank_provider (Callable -> int, set by UIRoot).
# Methods: apply_layout(), bottom_edge(), on_phase(phase, ticks_left), on_bind(), refresh(),
# grace_left(); per frame update(dt).
class_name TopStatus
extends Control

signal tapped

var ctx: UICtx
var _phase_end_tick := -1.0
## () -> int: my leaderboard rank (phones show it here instead of a separate pill).
var rank_provider: Callable = Callable()
var _accum := 0.0
var _over_secs := NAN

var panel: GlassPanel
var _full: HBoxContainer
var _phase: Label
var _clock: Label
var _limit: Label
var _grace_row: HBoxContainer
var _grace: Label
var _head: HBoxContainer
var _goal: Label
var _bar: FillBar
var _you_sw: PanelContainer
var _you: Label
var _lead_box: HBoxContainer
var _lead_sw: PanelContainer
var _lead: Label
var _mini: HBoxContainer
var _m_grace: PanelContainer
var _m_grace_l: Label
var _m_clock: Label
var _m_sw: PanelContainer
var _m_you: Label
var _m_chev: TextureRect
var _hit: Control
var _clock_col: Color = UITheme.TEXT


static func _spacer() -> Control:
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sp


func _on_release(node: Control, fn: Callable) -> void:
	node.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			fn.call())


func _init(c: UICtx) -> void:
	var T := UITheme
	ctx = c
	name = "TopStatus"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = GlassPanel.new(18.0, 10.0, T.R_LG, true, 18)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_on_release(panel, func() -> void: tapped.emit())
	add_child(panel)
	var row := T.hbox(16)
	_full = row
	panel.add_child(row)

	var tb := T.vbox(0)
	tb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_phase = T.caption("Match time")
	tb.add_child(_phase)
	var tv := T.hbox(4)
	_clock = T.label("0:00", 20, 700)
	_clock.add_theme_font_override("font", T.font(700, 0, true))
	tv.add_child(_clock)
	_limit = T.label("", 12, 600, T.TEXT_3)
	_limit.size_flags_vertical = Control.SIZE_SHRINK_END
	tv.add_child(_limit)
	tb.add_child(tv)
	_grace_row = T.hbox(4)
	var gic := T.icon_rect("defense", 11.0, T.GREEN)
	gic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_grace_row.add_child(gic)
	_grace = T.label("", 11, 700, T.GREEN, 1)
	_grace_row.add_child(_grace)
	_grace_row.visible = false
	tb.add_child(_grace_row)
	tb.move_child(_grace_row, 0)
	tb.custom_minimum_size = Vector2(88, 0)
	row.add_child(tb)
	row.add_child(T.vdivider(38.0))

	var sb := T.vbox(5)
	sb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var head := T.hbox(6)
	_head = head
	head.add_child(T.icon_rect("globe", 12.0, T.TEXT_3))
	head.add_child(T.caption("World control"))
	head.add_child(_spacer())
	_goal = T.caption("Goal 80%", 11, T.GOLD)
	head.add_child(_goal)
	sb.add_child(head)
	_bar = FillBar.new(7.0, T.AMBER)
	_bar.goal = SimRules.WIN_SHARE
	_bar.custom_minimum_size = Vector2(280, 12)
	sb.add_child(_bar)
	var who := T.hbox(6)
	_you_sw = T.swatch(T.AMBER, 9.0, 2)
	_you_sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	who.add_child(_you_sw)
	_you = T.label("You 0.0%", 12, 600, T.TEXT)
	who.add_child(_you)
	who.add_child(_spacer())
	_lead_box = T.hbox(6)
	var crown := T.icon_rect("crown", 12.0, T.GOLD)
	crown.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_lead_box.add_child(crown)
	_lead_sw = T.swatch(T.TEXT, 9.0, 2)
	_lead_sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_lead_box.add_child(_lead_sw)
	_lead = T.label("", 12, 600, T.TEXT_2)
	_lead_box.add_child(_lead)
	who.add_child(_lead_box)
	sb.add_child(who)
	row.add_child(sb)
	_build_mini()


func _build_mini() -> void:
	var T := UITheme
	_mini = T.hbox(7)
	_mini.visible = false
	_m_grace = PanelContainer.new()
	_m_grace.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_m_grace.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_m_grace.add_theme_stylebox_override("panel", T.flat(T.c(T.GREEN, 0.14), 999, T.c(T.GREEN, 0.45), 1, 6.0, 1.0))
	var gh := T.hbox(3)
	var gi := T.icon_rect("defense", 11.0, T.GREEN)
	gi.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gh.add_child(gi)
	_m_grace_l = T.label("", 12, 700, T.GREEN)
	gh.add_child(_m_grace_l)
	_m_grace.add_child(gh)
	_m_grace.visible = false
	_mini.add_child(_m_grace)
	_m_clock = T.label("0:00", 14, 700)
	_m_clock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mini.add_child(_m_clock)
	_m_sw = T.swatch(T.AMBER, 8.0, 2)
	_m_sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mini.add_child(_m_sw)
	_m_you = T.label("", 13, 600)
	_m_you.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mini.add_child(_m_you)
	_m_chev = T.icon_rect("leaderboard", 12.0, T.TEXT_3)
	_m_chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mini.add_child(_m_chev)
	panel.add_child(_mini)
	_hit = Control.new()
	_hit.name = "StatusHit"
	_hit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_on_release(_hit, func() -> void: tapped.emit())
	add_child(_hit)
	panel.item_rect_changed.connect(_fit_hit)
	panel.visibility_changed.connect(_fit_hit)


## The mini pill is ~30 px tall; its tap area is a full 44 px.
func _fit_hit() -> void:
	if _hit == null:
		return
	var on := ctx.compact and ctx.touch and panel.visible
	_hit.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	_hit.visible = on
	if on:
		var p := panel.position
		var s := panel.size
		var pad := maxf(0.0, (44.0 - s.y) * 0.5)
		_hit.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_hit.position = Vector2(p.x - 4.0, p.y - pad)
		_hit.size = Vector2(s.x + 8.0, s.y + pad * 2.0)


func apply_layout() -> void:
	var p := panel
	var top := 12.0 + ctx.insets.y
	# Phones drop the "WORLD CONTROL · GOAL 80%" header: the bar and its gold goal line say it.
	_head.visible = not ctx.compact
	_full.visible = not ctx.compact
	_mini.visible = ctx.compact
	# Very narrow phones drop the leaderboard hint icon (the pill still opens the board).
	_m_chev.visible = ctx.vp.x >= 800.0
	# On touch the pill swallows taps (and on phones opens the leaderboard).
	p.mouse_filter = Control.MOUSE_FILTER_STOP if ctx.touch else Control.MOUSE_FILTER_IGNORE
	if ctx.compact:
		# Phones: tuck into the top-right corner, clear of the top-left bar.
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		p.offset_left = -(8.0 + ctx.insets.z)
		p.offset_right = -(8.0 + ctx.insets.z)
		top = 8.0 + ctx.insets.y
		_bar.custom_minimum_size = Vector2(200, 10)
		_clock.add_theme_font_size_override("font_size", 16)
		p.set_padding(12.0, 5.0, 10.0, 5.0)
	else:
		p.anchor_left = 0.5
		p.anchor_right = 0.5
		p.grow_horizontal = Control.GROW_DIRECTION_BOTH
		p.offset_left = 0.0
		p.offset_right = 0.0
		_bar.custom_minimum_size = Vector2(340 if ctx.vp.x >= 1200.0 else 260, 12)
		_clock.add_theme_font_size_override("font_size", 20)
		p.set_padding(18.0, 10.0, 18.0, 10.0)
	_fix_widths()
	p.anchor_top = 0.0
	p.anchor_bottom = 0.0
	p.grow_vertical = Control.GROW_DIRECTION_END
	var w := p.get_combined_minimum_size().x
	if ctx.compact:
		# Right-aligned; drop below the top-left bar row when the phone is too narrow for both.
		if ctx.vp.x - ctx.insets.z - 8.0 - w < ctx.reserved_top_left.end.x + 8.0:
			top = ctx.reserved_top_left.end.y + 4.0
	else:
		var pt := ctx.place_top(w, top)
		p.offset_left = pt[0]
		p.offset_right = pt[0]
		top = pt[1]
	p.offset_top = top
	p.offset_bottom = top
	p.reset_size()
	_fit_hit()


## Fixed boxes for every changing text (tabular digits) so the pill never resizes or jitters.
func _fix_widths() -> void:
	var T := UITheme
	var small := 11
	var cs := 16 if ctx.compact else 20
	var ws := 12
	var w_block := maxf(T.text_width("SPAWN PHASE", small, 700) + 12.0, T.text_width("PROTECTED 8:88", small, 700) + 20.0)
	T.fix_width(_phase, w_block, HORIZONTAL_ALIGNMENT_LEFT, false)
	T.fix_width(_grace, w_block - 16.0)
	var w_clock := T.text_width("8:88:88", cs, 700) + 2.0
	T.fix_width(_clock, w_clock)
	T.fix_width(_limit, maxf(w_block - w_clock - 4.0, T.text_width("/ 88:88", ws, 600) + 2.0))
	(_phase.get_parent() as Control).custom_minimum_size = Vector2(w_block, 0)
	_grace_row.custom_minimum_size = Vector2(w_block, _phase.get_combined_minimum_size().y)
	var bar_w := _bar.custom_minimum_size.x
	var w_you := T.text_width("You lead · 88.88%", ws, 600) + 2.0
	T.fix_width(_you, w_you, HORIZONTAL_ALIGNMENT_LEFT, false)
	var lead_w := maxf(40.0, bar_w - w_you - 12.0 - 9.0 - 12.0 - 18.0)
	T.fix_width(_lead, lead_w, HORIZONTAL_ALIGNMENT_LEFT, false)
	# The Protected chip and the clock take turns in one slot of fixed width (the pill never
	# resizes).
	var slot := maxf(T.text_width("88:88", 14, 700) + 2.0, 6.0 + 11.0 + 3.0 + T.text_width("8:88", 12, 700) + 2.0 + 6.0 + 2.0)
	T.fix_width(_m_clock, slot, HORIZONTAL_ALIGNMENT_LEFT)
	_m_grace.custom_minimum_size.x = slot
	T.fix_width(_m_you, T.text_width("#888 · 88.88%", 13, 600) + 2.0, HORIZONTAL_ALIGNMENT_LEFT)
	T.fix_width(_m_grace_l, T.text_width("8:88", 12, 700) + 2.0, HORIZONTAL_ALIGNMENT_LEFT)


func bottom_edge() -> float:
	return panel.get_rect().end.y


## Call on bind and on every phase change.
func on_phase(phase: int, ticks_left: float) -> void:
	var s = ctx.state
	if s == null:
		return
	_phase_end_tick = s.tick + ticks_left if (ticks_left > 0 and phase != Defs.PHASE_OVER) else -1.0
	# MATCH OVER: the clock stops at the final time.
	if phase == Defs.PHASE_OVER:
		if is_nan(_over_secs):
			_over_secs = ctx.match_seconds()
	else:
		_over_secs = NAN
	refresh()


func on_bind() -> void:
	_phase_end_tick = -1.0
	_over_secs = NAN
	var s = ctx.state
	if s == null:
		return
	on_phase(s.phase, s.phase_ticks_left)


func _set_clock_color(col: Color) -> void:
	_clock_col = col
	UITheme.set_font_color(_clock, col)


func refresh() -> void:
	var T := UITheme
	var s = ctx.state
	if s == null:
		return
	var now := ctx.render_tick()
	var tr := float(Defs.TICK_RATE)
	_set_clock_color(T.TEXT)
	if s.phase == Defs.PHASE_SPAWN:
		_phase.text = "SPAWN PHASE"
		# (this port's spawn countdown runs on the game's clock, not on sim ticks)
		var left_s: float = s.spawn_seconds_left()
		if left_s >= 0:
			_clock.text = T.fmt_time(ceil(left_s))
		elif _phase_end_tick > 0:
			_clock.text = T.fmt_time(ceil((_phase_end_tick - now) / tr))
		else:
			_clock.text = "--:--"
		_limit.text = ""
	elif s.phase == Defs.PHASE_PLAYING:
		var elapsed := ctx.match_seconds()
		if s.time_limit_ticks > 0:
			# time_limit_ticks is the absolute tick at which the match ends.
			var left: float = maxf(0.0, (s.time_limit_ticks - now) / tr)
			_phase.text = "TIME LEFT"
			_clock.text = T.fmt_time(ceil(left))
			_set_clock_color(T.RED if left < 120 else T.TEXT)
			var total: float = (s.time_limit_ticks - ctx.play_start_tick) / tr if ctx.play_start_tick >= 0 else ctx.match_limit_s()
			_limit.text = "/ " + T.fmt_time(floor(total + 0.5))
		else:
			_phase.text = "MATCH TIME"
			_clock.text = T.fmt_time(elapsed)
			_limit.text = ""
	else:
		_phase.text = "MATCH OVER"
		_limit.text = ""
		if is_nan(_over_secs):
			_over_secs = ctx.match_seconds()
		_clock.text = T.fmt_time(_over_secs)
	# While protected the one timer is the protection's countdown; the match clock comes back when
	# protection ends.
	var grace := grace_left()
	if grace > 0:
		_clock.text = T.fmt_time(ceil(grace))
		_set_clock_color(T.GREEN)
		_limit.text = ""
	_refresh_grace()
	# (the leader alone, from one pass: not the whole ranking sorted)
	var leader = ctx.leader()
	var mine := ctx.me()
	var my_share: float = s.land_share(mine) if mine != 0 else 0.0
	var mo = ctx.my()
	var mcol: Color = T.owner_ui_color(mo.color) if mo != null else T.AMBER
	_you_sw.visible = mine != 0
	T.set_swatch_color(_you_sw, mcol)
	_you.text = ("You " + T.fmt_pct(my_share)) if mine != 0 else "Spectating"
	if ctx.compact and mine != 0 and rank_provider.is_valid():
		var rk := int(rank_provider.call())
		if rk > 0:
			_you.text = "#%d · %s" % [rk, T.fmt_pct(my_share)]
	_bar.fill_color = mcol
	_bar.set_target(ctx.win_share(mine) if mine != 0 else 0.0)
	_bar.markers.clear()
	if leader != null:
		var ls: float = s.land_share(leader.id)
		_lead_box.visible = leader.id != mine
		T.set_swatch_color(_lead_sw, leader.color)
		_lead.text = T.fmt_pct(ls) if ctx.compact else "%s %s" % [leader.name, T.fmt_pct(ls)]
		if leader.id != mine:
			_bar.markers.append({"v": ctx.win_share(leader.id), "color": T.owner_ui_color(leader.color)})
		else:
			_you.text = ("#1 · " if ctx.compact else "You lead · ") + T.fmt_pct(my_share)
	else:
		_lead_box.visible = false
	# a team game: the team's land together, and the team ahead
	if s.has_method("is_team_game") and s.is_team_game():
		_refresh_teams(mine)
	_bar.queue_redraw()
	if ctx.compact:
		_m_clock.text = _clock.text
		if _m_clock.text.length() > 5 and _m_clock.custom_minimum_size.x < T.text_width("8:88:88", 14, 700):
			T.fix_width(_m_clock, T.text_width("8:88:88", 14, 700) + 2.0, HORIZONTAL_ALIGNMENT_LEFT)
			_m_grace.custom_minimum_size.x = _m_clock.custom_minimum_size.x
		T.set_font_color(_m_clock, _clock_col)
		T.set_swatch_color(_m_sw, mcol)
		_m_sw.visible = mine != 0
		var yt := _you.text.replace("You lead · ", "#1 · ")
		yt = yt.replace("You ", "")
		_m_you.text = yt
		# While protected, the shield countdown takes the clock's place (the match is young).
		var gl := grace_left()
		_m_grace.visible = gl > 0
		_m_clock.visible = gl <= 0
		if gl > 0:
			_m_grace_l.text = T.fmt_time(ceil(gl))


## A team game (Core/Teams): the bar is the player's team's land together (it wins at the same
## share), the lead box the team ahead.
func _refresh_teams(mine_id: int) -> void:
	var T := UITheme
	var s = ctx.state
	var mine: int = s.team_of(mine_id) if mine_id != 0 else 0
	var teams: Array = s.team_ranking()
	var share := ctx.team_share(mine) if mine != 0 else 0.0
	var mcol: Color = T.owner_ui_color(s.team_color(mine)) if mine != 0 else T.AMBER
	T.set_swatch_color(_you_sw, mcol)
	_bar.fill_color = mcol
	_bar.set_target(share)
	_bar.markers.clear()
	var rank := 0
	for i in teams.size():
		if teams[i].team == mine:
			rank = i + 1
	if mine != 0 and s.phase == Defs.PHASE_SPAWN:
		# before the land counts: which team you're on ("Your team:" in the spawn phase)
		_you.text = ctx.team_label(mine) if ctx.compact else "Your team: " + ctx.team_label(mine)
		_lead_box.visible = false
		return
	if mine != 0:
		if ctx.compact:
			_you.text = "#%d · %s" % [rank, T.fmt_pct(share)]
		elif rank == 1:
			_you.text = "Your team leads · " + T.fmt_pct(share)
		else:
			_you.text = "%s %s" % [ctx.team_label(mine), T.fmt_pct(share)]
	var top = teams[0] if teams.size() > 0 else null
	if top != null and top.team != mine:
		var ts := ctx.team_share(top.team)
		var tcol: Color = s.team_color(top.team)
		_lead_box.visible = true
		T.set_swatch_color(_lead_sw, tcol)
		_lead.text = T.fmt_pct(ts) if ctx.compact else "%s %s" % [ctx.team_label(top.team), T.fmt_pct(ts)]
		_bar.markers.append({"v": ts, "color": T.owner_ui_color(tcol)})
	else:
		_lead_box.visible = false


## Early peace: nations will not declare war on a commander during the grace window.
func _refresh_grace() -> void:
	var left := grace_left()
	var show := left > 0
	_grace_row.visible = show
	_phase.visible = not show
	if show:
		_grace.text = "PROTECTED"


## Seconds of protection left. (This port keeps its own countdown: the game's peace clock, which is
## Rules.human_grace_ticks(difficulty) counted from the start of play.)
func grace_left() -> float:
	var s = ctx.state
	if s == null or s.phase != Defs.PHASE_PLAYING or not ctx.alive_player() or ctx.play_start_tick < 0:
		return 0.0
	return float(s.grace_seconds_left())


## Per frame.
func update(delta: float) -> void:
	_accum += delta
	if _accum >= 0.25:
		_accum = 0.0
		if is_visible_in_tree():
			refresh()
