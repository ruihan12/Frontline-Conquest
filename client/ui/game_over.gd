# Port of src/client/UI/GameOver.luau (scripts/ui/game_over.gd, UIGameOver).
# The result screen: a kicker, the gradient headline (VICTORY / DEFEAT / ELIMINATED / TIME'S UP), a
# line of copy, the winner (or current leader) pill, four stat cards, the Stars earned and the
# buttons; under them what the Stars go towards (the next unlock, 2x Stars).
#
# Left out: the paid "take over a nation" card (set_takeover and its glow; a Robux product).
#
# open(kind, winner, killer, stats, reason): kind = "victory" / "defeat" / "eliminated" / "result";
# stats = {peak_share, max_troops, kills, duration_s, match_s}.
class_name GameOver
extends Control

signal play_again
signal spectate
signal to_title
signal open_arsenal(key, from)
signal opened

## Labels of an award's lines (Data/Stars LABELS).
const STAR_LABELS := {"played": "Match played", "survived": "Time survived", "territory": "Land held", "conquests": "Nations conquered", "placed": "Final place", "victory": "Victory", "double": "2x Stars"}

var ctx: UICtx
var _award = null
var _balance := 0
var _stars_shown := 0.0
var _stars_done := true
var is_open := false
var _sweep_t := -1.0
var _kind := ""
var _next_accum := 0.0
## The pill names the current leader (it follows the ranking) instead of a winner.
var _pill_live := false
var _pill_domination := false
var _dominated := false
var _pill_id := 0
var _pill_text := ""
var _pill_wanted := false
var _pill_room := true
var _goal_key = null
var _goal_wanted := false
var _x2_wanted := false
var _close_tween: Tween = null
var _enter_tween: Tween = null

var _dim: ColorRect
var _center: VBoxContainer
var _kicker: Label
var _title: GradientText
var _sub: Label
var _winner: PanelContainer
var _crown: TextureRect
var _winner_sw: PanelContainer
var _winner_name: Label
var _gap2: Control
var _stats: HBoxContainer
var _gap3: Control
var _gap4: Control
var _buttons: HBoxContainer
var _stars_btn: Button
var _again: Button
var _spec: Button
var _home: Button
var _gap_offers: Control
var _offers: HBoxContainer
var _goal_btn: Button
var _x2_btn: Button
var _next: Label
var _gap_next: Control


static func _spacer(h: float) -> Control:
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.custom_minimum_size = Vector2(0, h)
	return g


func _gold_button(b: Button, a0: float, a1: float, a2: float, a_line: float, mh: float, mv: float) -> void:
	var T := UITheme
	for cn in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		b.add_theme_color_override(cn, T.GOLD)
	for st in ["normal", "disabled"]:
		b.add_theme_stylebox_override(st, T.flat(T.c(T.GOLD, a0), T.R_MD, T.c(T.GOLD, a_line), 1, mh, mv))
	b.add_theme_stylebox_override("hover", T.flat(T.c(T.GOLD, a1), T.R_MD, T.GOLD, 1, mh, mv))
	b.add_theme_stylebox_override("pressed", T.flat(T.c(T.GOLD, a2), T.R_MD, T.GOLD, 1, mh, mv))


func _init(c: UICtx) -> void:
	var T := UITheme
	ctx = c
	name = "GameOver"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# (upstream: a radial dim image, darker towards the edges)
	_dim = ColorRect.new()
	_dim.color = Color(0.01, 0.015, 0.05, 0.72)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	_center = T.vbox(0)
	_center.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_center)
	_kicker = T.label("MATCH COMPLETE", 14, 700, T.TEXT_2, 6)
	_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.add_child(_kicker)
	var title := GradientText.new("GAME OVER", 110, 900)
	title.spacing = 10
	title.shadow = {"color": Color(0, 0, 0), "alpha": 0.5, "offset_y": 6, "outline": 12}
	title.shine = 0.35
	title.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title = title
	_center.add_child(title)
	_sub = T.label("", 18, 500, T.TEXT)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.add_child(_sub)
	_center.add_child(_spacer(14))
	_winner = PanelContainer.new()
	_winner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_winner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_winner.add_theme_stylebox_override("panel", T.box(T.c(T.GOLD, 0.1), 999, T.c(T.GOLD, 0.45), 1, 16.0, 6.0))
	var wr := T.hbox(8)
	_crown = T.icon_rect("crown", 16.0, T.GOLD)
	_crown.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wr.add_child(_crown)
	_winner_sw = T.swatch(T.TEXT, 12.0, 3)
	_winner_sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wr.add_child(_winner_sw)
	_winner_name = T.label("", 15, 700)
	wr.add_child(_winner_name)
	_winner.add_child(wr)
	_center.add_child(_winner)
	_gap2 = _spacer(26)
	_center.add_child(_gap2)
	_stats = T.hbox(12)
	_stats.alignment = BoxContainer.ALIGNMENT_CENTER
	_center.add_child(_stats)
	_gap3 = _spacer(28)
	_center.add_child(_gap3)
	_gap4 = _spacer(16)
	_gap4.visible = false
	_center.add_child(_gap4)
	_buttons = T.hbox(12)
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_center.add_child(_buttons)
	# Stars earned this match: counts up, opens the Arsenal.
	var sb := T.button("+0", "GlassButton", "star", 52.0)
	sb.custom_minimum_size = Vector2(150, 52)
	sb.add_theme_constant_override("icon_max_width", 18)
	_gold_button(sb, 0.1, 0.18, 0.26, 0.5, 14.0, 8.0)
	sb.visible = false
	sb.pressed.connect(func() -> void:
		ctx.hide_hint(sb)
		open_arsenal.emit(null, "stars"))
	sb.mouse_entered.connect(func() -> void:
		if _award != null:
			ctx.show_hint(sb, _stars_spec()))
	sb.mouse_exited.connect(func() -> void: ctx.hide_hint(sb))
	_stars_btn = sb
	_buttons.add_child(sb)
	_again = T.button("PLAY AGAIN", "PrimaryButton", "play", 52.0)
	_again.custom_minimum_size = Vector2(200, 52)
	_again.pressed.connect(func() -> void: play_again.emit())
	_buttons.add_child(_again)
	_spec = T.button("Spectate", "GlassButton", "eye", 52.0)
	_spec.custom_minimum_size = Vector2(170, 52)
	_spec.pressed.connect(func() -> void:
		close()
		spectate.emit())
	_buttons.add_child(_spec)
	_home = T.button("Return to title", "GlassButton", "exit", 52.0)
	_home.custom_minimum_size = Vector2(200, 52)
	_home.pressed.connect(func() -> void: to_title.emit())
	_buttons.add_child(_home)
	# what the Stars go towards: the next unlock, and 2x Stars
	_gap_offers = _spacer(10)
	_gap_offers.visible = false
	_center.add_child(_gap_offers)
	_offers = T.hbox(10)
	_offers.alignment = BoxContainer.ALIGNMENT_CENTER
	_offers.visible = false
	_center.add_child(_offers)
	_goal_btn = _offer_button("lock")
	_goal_btn.pressed.connect(func() -> void:
		if _goal_key != null:
			open_arsenal.emit(_goal_key, "offer"))
	_x2_btn = _offer_button("star")
	_x2_btn.pressed.connect(func() -> void: open_arsenal.emit("stars2x", "offer"))
	_next = T.label("", 13, 600, T.TEXT_2)
	_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gap_next = _spacer(14)
	_center.add_child(_gap_next)
	_center.add_child(_next)


func _offer_button(icon: String) -> Button:
	var b := UITheme.button("", "GlassButton", icon, 40.0)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_constant_override("icon_max_width", 16)
	_gold_button(b, 0.06, 0.16, 0.24, 0.35, 14.0, 6.0)
	b.visible = false
	_offers.add_child(b)
	return b


func _stars_spec() -> Dictionary:
	var a: Dictionary = _award
	var rows := []
	for l in a.get("lines", []):
		rows.append([STAR_LABELS.get(l[0], l[0]), "+" + UICtx.commas(l[1]), UITheme.GOLD])
	return {
		"title": "Stars earned",
		"body": "Stars unlock new weapons in the Arsenal.",
		"rows": rows,
		"hint": "You have %s Stars" % UICtx.commas(a.get("balance", 0)),
		"hint_color": UITheme.GOLD,
		"hint_icon": "star",
	}


## award: {total, balance, lines: [[key, stars]]} or null.
func set_award(award) -> void:
	if award == null or float(award.get("total", 0)) <= 0:
		_award = null
		_stars_btn.visible = false
		_refresh_offers()
		return
	if _award == award:
		return
	_award = award
	_balance = int(award.get("balance", 0))
	_stars_shown = 0.0
	_stars_done = false
	_stars_btn.text = "+0"
	_stars_btn.visible = true
	_refresh_offers()
	if is_open:
		UIFx.pop_in(_stars_btn, 0.0, 0.8, 0.35)
		UIFx.pop_in(_offers, 0.5, 0.9, 0.35)
		apply_layout()


## UIRules.result_offers for this payout and the session's inventory.
func _refresh_offers() -> void:
	_goal_key = null
	_goal_wanted = false
	_x2_wanted = false
	var sess = ctx.session
	if _award == null or float(_award.get("total", 0)) <= 0 or sess == null or not sess.has_method("has_unlock"):
		return
	var owned := {}
	for it in ArsenalData.ITEMS:
		owned[it.key] = sess.has_unlock(it.key)
	# (this port's Arsenal has its own Star prices: Session.unlock_cost)
	var goal = null
	var goal_stars := 0
	for it in ArsenalData.ITEMS:
		var cost: int = int(sess.unlock_cost(it.key)) if sess.has_method("unlock_cost") else int(it.get("stars", 0))
		if cost > 0 and not owned[it.key] and it.key != "stars2x":
			goal = it
			goal_stars = cost
			break
	if goal != null:
		var ready: bool = _balance >= goal_stars
		_goal_key = goal.key
		_goal_btn.text = "UNLOCK " + String(goal.title).to_upper() if ready else "%s  %s / %s" % [String(goal.title).to_upper(), UICtx.commas(_balance), UICtx.commas(goal_stars)]
		_goal_btn.icon = UITheme.icon_texture("star" if ready else "lock")
		_goal_wanted = true
	if not owned.get("stars2x", false):
		# (a payout already doubled never gets here: its owner has the booster)
		_x2_btn.text = "WITH 2X STARS: +%s" % UICtx.commas(floor(float(_award.total)) * 2)
		_x2_wanted = true


## The inventory changed (something was unlocked from here).
func refresh_offers(balance: int = -1) -> void:
	if balance >= 0:
		_balance = balance
	_refresh_offers()
	if is_open:
		apply_layout()


func _stat_card(icon_name: String, value: String, caption: String, col: Color) -> GlassPanel:
	var T := UITheme
	if ctx.compact:
		var pc := GlassPanel.new(10.0, 7.0, 12, true, 12)
		pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := T.hbox(8)
		pc.add_child(h)
		var pic := T.icon_rect(icon_name, 18.0, col)
		pic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(pic)
		var pv := T.vbox(0)
		pv.add_child(T.label(value, 18, 800))
		pv.add_child(T.caption(caption, 10, T.TEXT_3))
		h.add_child(pv)
		return pc
	var card := GlassPanel.new(16.0, 14.0, 14, true, 16)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.custom_minimum_size = Vector2(150, 0)
	var v := T.vbox(4)
	card.add_child(v)
	var ic := T.icon_rect(icon_name, 20.0, col)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(ic)
	var vl := T.label(value, 26, 800)
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(vl)
	var cl := T.caption(caption, 10, T.TEXT_3)
	cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(cl)
	return card


func open(kind: String, winner: int, killer: int, stats: Dictionary, reason: int = -1) -> void:
	var T := UITheme
	var s = ctx.state
	var was_shown := visible
	if _close_tween != null:
		_close_tween.kill()
		_close_tween = null
	if _enter_tween != null:
		_enter_tween.kill()
		_enter_tween = null
	is_open = true
	visible = true
	modulate.a = 1.0
	_kind = kind
	var copy := _copy(kind, winner, killer, reason, float(stats.get("duration_s", 0.0)))
	_kicker.text = copy.kicker
	_title.set_text(copy.title)
	_sub.text = copy.sub
	_title.set_colors(copy.top, copy.bottom)
	# The pill: the winner when the match was decided (domination / time), else the current leader.
	var real_winner: bool = (kind == "victory" or kind == "defeat" or kind == "result") and winner != 0 and (reason == Defs.OVER_DOMINATION or reason == Defs.OVER_TIME)
	var pill_id := winner if real_winner else _leader_id()
	_pill_domination = real_winner and reason == Defs.OVER_DOMINATION and _dominated
	_pill_live = not real_winner
	_pill_id = -1
	_pill_text = ""
	_crown.visible = real_winner
	_winner.add_theme_stylebox_override("panel", T.box(T.c(T.GOLD, 0.1), 999, T.c(T.GOLD, 0.45), 1, 16.0, 6.0) if real_winner else T.box(Color(1, 1, 1, 0.06), 999, T.LINE_2, 1, 16.0, 6.0))
	_set_pill(pill_id)
	for ch in _stats.get_children():
		_stats.remove_child(ch)
		ch.queue_free()
	var cards: Array[GlassPanel] = [
		_stat_card("globe", T.fmt_pct(float(stats.get("peak_share", 0.0))), "Peak land", T.AMBER),
		_stat_card("troops", T.fmt_troops(float(stats.get("max_troops", 0))), "Max troops", T.CYAN),
		_stat_card("skull", str(int(stats.get("kills", 0))), "Nations eliminated", T.RED),
		_stat_card("clock", T.fmt_time(UIRules.result_seconds(kind, stats)), "Match duration", T.VIOLET),
	]
	for card in cards:
		_stats.add_child(card)
	var solo := ctx.mode() == UICtx.MODE_SOLO
	var running: bool = s != null and s.phase == Defs.PHASE_PLAYING
	var sess = ctx.session
	set_award(sess.get("last_award") if sess != null else null)
	_again.visible = solo
	_spec.visible = kind == "eliminated" and running
	_spec.text = "Keep watching"
	_home.text = "Return to title"
	_next.visible = ctx.mode() == UICtx.MODE_MULTI and kind != "eliminated"
	_refresh_next()
	apply_layout()
	if not was_shown:
		_dim.modulate.a = 0.0
		UIFx.fade(_dim, 1.0, 0.6)
	elif _dim.modulate.a < 1.0:
		UIFx.fade(_dim, 1.0, 0.3)
	# the entrance: kicker, the headline settling from 1.35x, copy, pill, cards one by one, buttons
	_kicker.modulate.a = 0.0
	var t := create_tween().set_parallel(true)
	_enter_tween = t
	t.tween_property(_kicker, "modulate:a", 1.0, 0.5).set_delay(0.15)
	_title.modulate.a = 0.0
	_title.pivot_offset = _title.size * 0.5
	_title.scale = Vector2(1.35, 1.35)
	t.tween_property(_title, "modulate:a", 1.0, 0.45).set_delay(0.2)
	t.tween_property(_title, "scale", Vector2.ONE, 0.9).set_delay(0.2).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_sub.modulate.a = 0.0
	t.tween_property(_sub, "modulate:a", 1.0, 0.5).set_delay(0.6)
	_winner.modulate.a = 0.0
	t.tween_property(_winner, "modulate:a", 1.0, 0.5).set_delay(0.75)
	for i in cards.size():
		UIFx.pop_in(cards[i], 0.9 + 0.09 * i, 0.9, 0.45)
	_buttons.modulate.a = 0.0
	t.tween_property(_buttons, "modulate:a", 1.0, 0.5).set_delay(1.35)
	_offers.modulate.a = 0.0
	t.tween_property(_offers, "modulate:a", 1.0, 0.5).set_delay(1.6)
	_next.modulate.a = 0.0
	t.tween_property(_next, "modulate:a", 1.0, 0.5).set_delay(1.6)
	_sweep_t = 0.0
	ctx.set_world_input(false)
	opened.emit()


func set_building(on: bool) -> void:
	_again.disabled = on
	_again.text = "DEPLOYING…" if on else "PLAY AGAIN"


func _set_pill(id: int) -> void:
	var s = ctx.state
	var wo = s.get_owner(id) if (s != null and id != 0) else null
	var show: bool = wo != null and _kind != "victory"
	_pill_wanted = show
	var vis := show and _pill_room
	if vis != _winner.visible:
		_winner.visible = vis
	if wo == null:
		_pill_id = id
		return
	var share: float = _win_share(id) if _pill_domination else s.land_share(id)
	var prefix := "Current leader  ·  " if _pill_live else ""
	var text := "%s%s  ·  %s" % [prefix, wo.name, UITheme.fmt_pct(share)]
	if id != _pill_id:
		UITheme.set_swatch_color(_winner_sw, wo.color)
	_pill_id = id
	if text != _pill_text:
		_pill_text = text
		_winner_name.text = text


func _win_share(id: int) -> float:
	return ctx.win_share(id)


func _win_phrase(id: int, all_land: String) -> String:
	var s = ctx.state
	return UIRules.win_phrase(_win_share(id), s.land_share(id) if s != null else 0.0, int(s.fallout_count) if s != null else 0, all_land)


func _leader_id() -> int:
	var s = ctx.state
	if s == null:
		return 0
	var r: Array = s.ranking()
	return r[0].id if r.size() > 0 else 0


## {kicker, title, sub, top, bottom}
func _copy(kind: String, winner: int, killer: int, reason: int, secs: float) -> Dictionary:
	var T := UITheme
	var s = ctx.state
	var wname: String = s.owner_name(winner) if (s != null and winner != 0) else "Nobody"
	var wshare: String = T.fmt_pct(s.land_share(winner)) if (s != null and winner != 0) else "0%"
	var dominated: bool = s != null and winner != 0 and _win_share(winner) >= SimRules.WIN_SHARE - 0.0005
	_dominated = dominated
	var wdom: String = _win_phrase(winner, "") if (s != null and winner != 0) else "0%"
	var lead := _leader_id()
	var lname: String = s.owner_name(lead) if (s != null and lead != 0) else "Nobody"
	var lshare: String = T.fmt_pct(s.land_share(lead)) if (s != null and lead != 0) else "0%"
	var gold_top := Color(1.0, 0.97, 0.86)
	var red_top := Color(1.0, 0.85, 0.85)
	var cyan_top := Color(0.92, 0.97, 1.0)
	var c := {"kicker": "MATCH COMPLETE", "title": "GAME OVER", "sub": "", "top": cyan_top, "bottom": T.CYAN}
	if kind == "eliminated":
		c.kicker = "YOUR NATION HAS FALLEN"
		c.title = "ELIMINATED"
		c.top = red_top
		c.bottom = T.RED
		c.sub = "Conquered by %s at %s." % [s.owner_name(killer), T.fmt_time(secs)] if (s != null and killer != 0) else "Your last territory fell at %s." % T.fmt_time(secs)
	elif kind == "victory":
		c.title = "VICTORY"
		c.top = gold_top
		c.bottom = T.GOLD
		if reason == Defs.OVER_TIME:
			c.kicker = "TIME LIMIT REACHED"
			c.sub = "Time! You hold the most land with %s." % wshare
		else:
			c.sub = "You conquered the world with %s." % (_win_phrase(winner, " of all land") if (s != null and winner != 0) else wshare)
	elif kind == "defeat":
		c.top = red_top
		c.bottom = T.RED
		if reason == Defs.OVER_TIME:
			c.kicker = "TIME LIMIT REACHED"
			c.title = "TIME'S UP"
			c.sub = "Time! %s holds the most land with %s." % [wname, wshare]
		elif dominated:
			c.title = "DEFEAT"
			c.sub = "%s conquered the world (%s)." % [wname, wdom]
		else:
			c.title = "DEFEAT"
			c.sub = "%s won the war with %s of the land." % [wname, wshare]
	else:
		if reason == Defs.OVER_TIME:
			c.kicker = "TIME LIMIT REACHED"
			c.title = "TIME'S UP"
			c.sub = "Time! %s holds the most land with %s." % [wname, wshare]
		elif reason == Defs.OVER_DOMINATION:
			c.sub = "%s conquered the world (%s)." % [wname, wdom] if dominated else "%s won the war with %s of the land." % [wname, wshare]
		elif reason == Defs.OVER_DEFEATED:
			c.title = "MATCH OVER"
			c.sub = "Every commander has fallen. %s leads with %s." % [lname, lshare]
		elif reason == Defs.OVER_ABANDONED:
			c.title = "MATCH OVER"
			c.sub = "Every commander left the match. %s leads with %s." % [lname, lshare]
		else:
			c.title = "MATCH OVER"
			c.sub = "%s leads with %s." % [lname, lshare]
	return c


func _refresh_next() -> void:
	if not _next.visible:
		return
	var lb := ctx.lobby()
	var stage := str(lb.get("stage", ""))
	var cd := float(lb.get("countdown_s", 0.0))
	if stage == "over":
		_next.text = "Next match in %s  ·  results close in %s" % [UITheme.fmt_time(ceil(cd + 12.0)), UITheme.fmt_time(ceil(cd))]
	elif stage == "lobby":
		_next.text = "Next match in " + UITheme.fmt_time(ceil(cd))
	else:
		_next.text = "Stay here for the next match, or return to the title."


func close() -> void:
	if not is_open:
		return
	is_open = false
	if _enter_tween != null:
		_enter_tween.kill()
		_enter_tween = null
	var t := create_tween()
	_close_tween = t
	t.tween_property(self, "modulate:a", 0.0, 0.25)
	t.tween_callback(func() -> void:
		if _close_tween == t:
			_close_tween = null
		if not is_open:
			visible = false
			modulate.a = 1.0)
	ctx.set_world_input(true)


func apply_layout() -> void:
	var compact := ctx.compact
	var title_px := floorf(clampf(ctx.vp.y * 0.14, 44.0, 60.0)) if compact else floorf(clampf(minf(ctx.vp.x * 0.07, ctx.vp.y * 0.12), 72.0, 128.0))
	_title.set_px(title_px)
	_title.spacing = 6 if compact else 10
	_sub.add_theme_font_size_override("font_size", 14 if compact else 18)
	_kicker.add_theme_font_size_override("font_size", 11 if compact else 14)
	for b in [_again, _spec, _home]:
		b.custom_minimum_size = Vector2(150 if compact else 200, 44 if compact else 52)
	_stars_btn.custom_minimum_size = Vector2(110 if compact else 150, 44 if compact else 52)
	_gap4.custom_minimum_size = Vector2(0, 10 if compact else 16)
	# the offers under the buttons
	var offers := _goal_wanted or _x2_wanted
	_goal_btn.visible = _goal_wanted
	_x2_btn.visible = _x2_wanted
	for b in [_goal_btn, _x2_btn]:
		b.custom_minimum_size = Vector2(0, 34 if compact else 40)
		b.add_theme_font_size_override("font_size", 12 if compact else 13)
	_gap_offers.custom_minimum_size = Vector2(0, 6 if compact else 10)
	_offers.visible = offers
	_gap_offers.visible = offers
	_sub.visible = true
	_gap_next.visible = _next.visible
	_pill_room = true
	_winner.visible = _pill_wanted
	_stats.visible = true
	_gap3.visible = true
	_gap2.custom_minimum_size = Vector2(0, 14 if compact else 26)
	_gap3.custom_minimum_size = Vector2(0, 14 if compact else 28)
	var sz := _center.get_combined_minimum_size()
	var area := ctx.clear_rect()
	if sz.y > area.size.y - 8.0:
		# a short screen: the kicker goes, the gaps tighten, then the pill and the offers
		_kicker.visible = false
		_gap2.custom_minimum_size = Vector2(0, 8)
		_gap3.custom_minimum_size = Vector2(0, 8)
		sz = _center.get_combined_minimum_size()
		if offers and sz.y > area.size.y - 8.0 and _pill_live and _winner.visible:
			_pill_room = false
			_winner.visible = false
			sz = _center.get_combined_minimum_size()
		if offers and sz.y > area.size.y - 8.0 and _x2_btn.visible and _goal_btn.visible:
			_x2_btn.visible = false
			sz = _center.get_combined_minimum_size()
		if offers and sz.y > area.size.y - 8.0:
			_offers.visible = false
			_gap_offers.visible = false
			if not _pill_room:
				_pill_room = true
				_winner.visible = _pill_wanted
			sz = _center.get_combined_minimum_size()
	else:
		_kicker.visible = true
	var p := area.position + (area.size - sz) * 0.5
	var y := maxf(p.y, area.position.y + 2.0)
	_center.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_center.position = Vector2(floorf(p.x + 0.5), floorf(y + 0.5))
	_center.size = sz
	var ts := _title.get_combined_minimum_size()
	_title.y0 = ts.y * 0.2
	_title.span = ts.y * 0.62
	_title.redraw()


func _process(delta: float) -> void:
	if not is_open:
		return
	# the Stars count up once the buttons are in
	if _award != null and not _stars_done and _buttons.modulate.a > 0.5:
		var total := float(_award.total)
		_stars_shown = minf(total, _stars_shown + maxf(total / 1.1, 60.0) * delta)
		var k := _stars_shown / maxf(total, 1.0)
		_stars_btn.text = "+" + UICtx.commas(floor(_stars_shown))
		if _stars_shown >= total:
			_stars_done = true
			ctx.sfx("star_get")
			UIFx.pop_in(_stars_btn, 0.0, 1.12, 0.3)
		else:
			ctx.sfx("star_tick", -6.0, 0.0, 0.8 + 0.6 * k)
	_next_accum += delta
	if _next_accum >= 0.25:
		_next_accum = 0.0
		_refresh_next()
		var s = ctx.state
		if _pill_live and s != null and s.phase == Defs.PHASE_PLAYING:
			_set_pill(_leader_id())
	if _sweep_t < 0.0:
		return
	# the shine crosses the headline once
	_sweep_t += delta
	var w := _title.size.x
	_title.sweep = -200.0 + (w + 400.0) * clampf((_sweep_t - 0.9) / 1.1, 0.0, 1.0)
	_title.redraw()
	if _sweep_t > 2.2:
		_sweep_t = -1.0
		_title.sweep = -10000.0
		_title.redraw()
