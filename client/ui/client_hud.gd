# The remade client's HUD host: owns the UICtx, the GameState / Session facades and the HUD parts
# ported from upstream so far, and places them over the game. It grows into the port of
# src/client/UI/UIRoot.luau as the remaining parts arrive; until then the parts not yet ported are
# still drawn by ui_upstream/rw_hud.gd.
class_name ClientHud
extends Node

var g  # main.gd
var ctx: UICtx
var root: Control
var bar: CommandBar
var icbm: IcbmSlot
var tooltip: Tooltip
var top: TopStatus
var board: Leaderboard
var attacks: AttacksPanel
var feed: EventFeed
var alert: AlertBanner
var spawn: SpawnOverlay
var topbar: ClientTopbar
var pause: PauseMenu
var over: GameOver
var help: HelpOverlay
var interact: UIInteract
var _hover_seen := -2
var _state_seen := ""
var _seen_nukes := {}
var _pending_toasts: Array = []
var _phase := -1
var _in_layout := false
var _stats_t := 0.0
var _growth_t := 0.0
var _was_play := false
var _syncing := false


func setup(main, layer: Node, at_index: int = -1) -> void:
	g = main
	ctx = UICtx.new()
	ctx.state = RWGameState.new(main)
	ctx.session = RWSession.new(main)
	ctx.audio = RWAudio.new(main)
	ctx.world = RWWorld.new(main)
	ctx.borders = RWBorders.new(ctx.state)
	ctx.reload_settings()
	root = Control.new()
	root.name = "ClientHud"
	root.theme = UITheme.theme()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)
	if at_index >= 0:
		layer.move_child(root, at_index)
	ctx.root = root

	top = TopStatus.new(ctx)
	root.add_child(top)
	top.visible = false
	board = Leaderboard.new(ctx)
	root.add_child(board)
	board.visible = false
	attacks = AttacksPanel.new(ctx)
	root.add_child(attacks)
	attacks.visible = false
	spawn = SpawnOverlay.new(ctx)
	root.add_child(spawn)
	spawn.visible = false
	feed = EventFeed.new(ctx)
	root.add_child(feed)
	alert = AlertBanner.new(ctx)
	root.add_child(alert)
	topbar = ClientTopbar.new(self)
	root.add_child(topbar)
	over = GameOver.new(ctx)
	root.add_child(over)
	over.play_again.connect(func() -> void:
		over.close()
		g._start_game_ui())
	over.to_title.connect(func() -> void:
		over.close()
		g._to_menu())
	over.open_arsenal.connect(func(_key, _from) -> void: g._open_shop())
	help = HelpOverlay.new(ctx)
	root.add_child(help)
	help.closed.connect(_update_pause)
	pause = PauseMenu.new(ctx)
	root.add_child(pause)
	# (this port keeps its own Settings window)
	pause.port_settings = func() -> void: g._open_settings()
	pause.closed.connect(_update_pause)
	pause.help_requested.connect(toggle_help)
	pause.leave_requested.connect(func() -> void:
		_update_pause()
		g._to_menu())
	pause.restart_requested.connect(func() -> void:
		_update_pause()
		g._start_game_ui())
	pause.music_toggled.connect(func(on: bool) -> void:
		ctx.set_music(on)
		topbar.refresh())
	pause.music_volume_changed.connect(func(v: float, final: bool) -> void: ctx.set_music_volume(v, final))
	pause.pops_toggled.connect(func(on: bool) -> void: ctx.set_pops(on))
	top.rank_provider = board.my_rank
	top.tapped.connect(func() -> void:
		if ctx.compact:
			board.toggle())
	board.toggled.connect(func(_on: bool) -> void: layout())
	attacks.toggled.connect(func(_c: bool) -> void: layout())
	attacks.retreat_requested.connect(_on_retreat)
	for c in [top.panel, board.panel, board._pill, attacks.panel, spawn.panel]:
		c.resized.connect(_queue_layout)
		c.visibility_changed.connect(_queue_layout)

	bar = CommandBar.new(ctx)
	icbm = IcbmSlot.new(ctx)
	bar.port_slots = [icbm]
	root.add_child(bar)
	bar.visible = false
	bar.build_chosen.connect(_on_build_chosen)
	bar.arsenal_wanted.connect(func(_key, _from) -> void: g._open_shop())
	bar.slots_changed.connect(layout)
	ctx.ratio_changed.connect(_on_ratio_changed)
	tooltip = Tooltip.new(ctx)
	root.add_child(tooltip)
	ctx.tooltip = tooltip
	interact = UIInteract.new(ctx)
	interact.tooltip = tooltip
	root.resized.connect(layout)
	layout()


var _layout_queued := false


func _queue_layout() -> void:
	if _in_layout or _layout_queued:
		return
	_layout_queued = true
	_do_queued.call_deferred()


func _do_queued() -> void:
	_layout_queued = false
	layout()


## UIRoot._layout: metrics, then each part.
func layout() -> void:
	if root == null or _in_layout:
		return
	_in_layout = true
	var vp := root.size
	if vp.x < 10:
		vp = Vector2(1600, 900)
	ctx.vp = vp
	ctx.compact = vp.y < 560.0 or vp.x < 900.0
	# (the single-row bar: ten slots, plus the Arsenal's SHOP slot and a slot per unlocked kind)
	ctx.wide = vp.x >= 1420.0 + bar.extra_width() + 62.0 * bar.port_slots.size()
	# the top-left corner belongs to the top-bar buttons (and the speed chip under them)
	topbar.layout()
	var tr := topbar.topbar_rect()
	ctx.airship_bar = Rect2(0, 0, tr.end.x + 8.0, tr.end.y + 2.0)
	ctx.reserved_top_left = Rect2(0, 0, tr.end.x + 8.0, tr.end.y + 8.0)
	top.apply_layout()
	spawn.apply_layout()
	bar.apply_layout()
	# Leaderboard: top-right, dropping below the status pill / spawn banner when they would touch.
	var board_top := 12.0 + ctx.insets.y
	var board_w := 250.0 if ctx.compact else 300.0
	var board_left := vp.x - 12.0 - ctx.insets.z - board_w
	var blockers: Array[Control] = []
	if top.visible:
		blockers.append(top.panel)
	if spawn.visible:
		blockers.append(spawn.panel)
	for b in blockers:
		var r := b.get_global_rect()
		if r.end.x + 12.0 > board_left:
			board_top = maxf(board_top, r.end.y + 10.0)
	board.apply_layout(board_top)
	# Phones: when the status pill had to drop below the top bar, the rank pill sits beside it.
	if ctx.compact and top.visible and not board.expanded:
		var tr2 := top.panel.get_global_rect()
		var pill_w := board._pill.get_combined_minimum_size().x
		var min_x := ctx.insets.x + 8.0 if tr2.position.y >= ctx.reserved_top_left.end.y else ctx.reserved_top_left.end.x + 8.0
		if tr2.position.x - 8.0 - pill_w >= min_x:
			board.place_pill_left_of(tr2)
	var attacks_top := maxf(board.bottom_edge() if board.visible else 0.0, top.bottom_edge() if top.visible else 0.0) + 10.0
	attacks.tray_open = bar.tray.visible
	attacks.apply_layout(attacks_top, (bar.top_edge() if bar.visible else vp.y - ctx.insets.w) - 8.0)
	if attacks.visible:
		attacks.refresh()
	var bar_top := bar.top_edge() if bar.visible else vp.y - ctx.insets.w
	# (UIRoot: the feed sits above the bar; beside it when the bar leaves the left edge free)
	if bar.visible and bar.panel.position.x > 16.0 + 340.0 + 12.0:
		bar_top = vp.y - ctx.insets.w - 4.0
	feed.apply_layout(bar_top - 12.0)
	_layout_alert()
	if pause.is_open:
		pause.apply_layout()
	if over.is_open:
		over.apply_layout()
	if help.is_open:
		help.apply_layout()
	ctx.layout_changed.emit()
	_in_layout = false


## The match ended for the player (main.show_end). `earned`: the Stars this match paid, already added
## to the balance.
func show_over(win: bool, eliminated: bool, leader: int, earned: int) -> void:
	var st: Dictionary = g.stats
	var me: int = g.PLAYER
	var x2: bool = g.unlocked("x2")
	var mult := 2 if x2 else 1
	var lines := [["land", int(float(st.get("peak", 0.0)) * 20.0) * mult], ["kills", int(st.get("elims", 0)) * 150 * mult], ["time", int(g.elapsed / 6.0) * mult]]
	if win:
		lines.insert(2, ["win", 1500 * mult])
	ctx.session.last_award = {"total": earned, "balance": int(g.save.stars), "lines": lines}
	var kind := "victory" if win else ("eliminated" if eliminated else "defeat")
	var killer := int(g.nations[me].get("last_by", 0)) if eliminated else 0
	var winner := me if win else leader
	var reason := Defs.OVER_DOMINATION if (winner > 0 and ctx.win_share(winner) >= SimRules.WIN_SHARE - 0.0005) else -1
	over.open(kind, winner, killer, {
		"peak_share": float(st.get("peak", 0.0)) / 100.0,
		"max_troops": float(st.get("maxtroops", 0.0)),
		"kills": int(st.get("elims", 0)),
		"duration_s": float(g.elapsed),
		"match_s": float(g.elapsed),
	}, reason)
	over.move_to_front()


## The top bar's ? and the H key.
func toggle_help() -> void:
	if help.is_open:
		help.close()
	else:
		help.open()
		help.move_to_front()
		tooltip.move_to_front()
	_update_pause()


func open_pause_menu() -> void:
	if g.state != "play" and g.state != "pick":
		return
	pause.open(true)
	pause.move_to_front()
	_update_pause()


## Solo freezes the simulation while the game menu is open (UIRoot._update_pause).
func _update_pause() -> void:
	var want: bool = (pause.is_open or help.is_open) and ctx.mode() == UICtx.MODE_SOLO and ctx.in_match() and ctx.state.phase != Defs.PHASE_OVER
	ctx.set_paused(want)


func _layout_alert() -> void:
	if ctx.compact:
		# Phones: the alert temporarily takes over the status pill's slot (top-right).
		alert.apply_layout(top.panel.offset_top, 8.0 + ctx.insets.z)
		return
	var y := 12.0 + ctx.insets.y
	if top.visible:
		y = top.bottom_edge() + 10.0
	elif spawn.visible:
		y = spawn.bottom_edge() + 10.0
	alert.apply_layout(y)


## The game has no nuke events: the missiles in flight are compared with the last frame's.
func _track_nukes() -> void:
	var now: Dictionary = ctx.state.nukes()
	for uid in now:
		if not _seen_nukes.has(uid):
			var r := alert.track(uid)
			if r[1]:
				ctx.sfx("alarm")
				_layout_alert()
	for uid in _seen_nukes.keys():
		if not now.has(uid):
			var raw = _seen_nukes[uid]
			alert.resolve(uid, bool(raw.get("shot_down", false)))
			_seen_nukes.erase(uid)
	for uid in now:
		_seen_nukes[uid] = now[uid].raw


func _on_retreat(aid: int) -> void:
	for a in ctx.state.attacks():
		if a.aid == aid:
			ctx.send({"type": "retreat", "attack": a})
			ctx.sfx("click", -6.0)
			attacks.mark_dirty()
			return


func _on_build_chosen(kind: String) -> void:
	var k: int = RWGameState.BUILD_ID.get(kind, -1)
	if k < 0:
		return
	var av := ctx.rules.availability(kind)
	if av.get("arsenal") != null:
		g._open_shop()
		return
	g.select_build(k)


## The Attack bar and the game's share index stay the same stop.
func _on_ratio_changed(_r: float) -> void:
	if _syncing:
		return
	_syncing = true
	var i := UICtx.ratio_stop_index(ctx.ratio, ctx.ratio_max)
	if g.share_i != i:
		g._set_share(i)
	_syncing = false


## main._set_share (Q / E keys, the wheel): the bar follows.
func on_share_changed() -> void:
	if _syncing or ctx == null:
		return
	_syncing = true
	ctx.set_ratio(UICtx.RATIO_STOPS[clampi(g.share_i, 0, UICtx.RATIO_STOPS.size() - 1)])
	_syncing = false


## The kind name of the game's selected build id ("" for none).
func _placing_kind() -> String:
	var k: int = g.build_sel
	if k < 0:
		return ""
	if k == 14 and g.has_method("_is_strike_click"):
		return "airfield"
	for name in RWGameState.BUILD_ID:
		if RWGameState.BUILD_ID[name] == k and name != "airstrike" and name != "slug":
			return name
	return ""


# ---------------------------------------------------------------------------------------------
# Event feed: the game's notify() and alliance prompts
# ---------------------------------------------------------------------------------------------
const _KIND_CAT := {"good": Defs.MSG_GOOD, "bad": Defs.MSG_BAD, "info": Defs.MSG_INFO, "alert": Defs.MSG_ALERT, "ally": Defs.MSG_ALLIANCE}
## The event's own glyph by what the line is about (boat for naval news, crown for captures, ...).
const _TOAST_ICONS := [["warship", "boat"], ["transport", "boat"], ["boat", "boat"], ["captured", "crown"], ["alliance", "alliance"], ["allied", "alliance"],
	["betray", "betray"], ["traitor", "betray"], ["nuke", "atom"], ["bomb", "atom"], ["mirv", "atom"], ["gold", "gold"], ["troops", "troops"],
	["eliminated", "skull"], ["destroyed", "skull"], ["attack", "attack"], ["unlocked", "check"]]


## main.notify(text, kind): kind is "good" / "bad" / "info". It can fire inside a time-budgeted sim
## pass, so the toast is built on the next frame; only the newest few are kept while no frames run.
func toast(text: String, kind: String = "info") -> void:
	_pending_toasts.append([text, kind])
	if _pending_toasts.size() > 6:
		_pending_toasts.pop_front()


func _toast_now(text: String, kind: String) -> void:
	var t := text.to_lower()
	var k := kind
	if kind == "bad" and (t.contains("nuke") or t.contains("bomb") or t.contains("incoming") or t.contains("attack")):
		k = "alert"
	elif t.contains("alliance") or t.contains("allied") or t.contains("ally"):
		k = "ally"
	var icon := ""
	for pair in _TOAST_ICONS:
		if t.contains(pair[0]):
			icon = pair[1]
			break
	if UITheme.icon_texture(icon) == null:
		icon = ""
	feed.toast(_KIND_CAT.get(k, Defs.MSG_INFO), text, icon)


## The game's alliance prompt: "propose" (a request from `who`) or "expire" (the renewal window).
func show_ally_card(mode: String, who: int) -> void:
	if mode == "expire":
		var expires := float(int(g.allies.get(g._akey(g.PLAYER, who), ctx.state.tick)))
		feed.alliance_renewal(who, expires, bool(g.asked_to_extend(who, g.PLAYER)))
	else:
		feed.alliance_request(who)


func close_ally_request(who: int) -> void:
	feed.close_request(who)


func clear_feed() -> void:
	_pending_toasts.clear()
	feed.clear()


## The pointer over the map: the hover card (UIInteract.on_hover). main.gd still owns the clicks.
func _hover(dt: float, in_match: bool) -> void:
	var modal: bool = pause.is_open or over.is_open or help.is_open or (g.arsenal_dlg != null and g.arsenal_dlg.visible) or (g.settings_dlg != null and g.settings_dlg.visible)
	interact.enabled = in_match and not modal and (g.state == "pick" or g.state == "play")
	interact.aim_kind = _placing_kind() if g.state == "play" else ""
	var tile := -1
	if interact.enabled and root.get_viewport().gui_get_hovered_control() == null:
		tile = ctx.tile_at(root.get_viewport().get_mouse_position())
	if tile != _hover_seen or not interact.enabled:
		_hover_seen = tile
		interact.on_hover(tile)
	interact.process_frame(dt)


## Bottom edge of the status pill (the old HUD's alert banner sits under it).
func status_bottom() -> float:
	return top.bottom_edge() if top.visible else 0.0


func process(dt: float) -> void:
	if root == null:
		return
	var in_match: bool = (g.state == "play" or g.state == "pick" or g.state == "over") and g.nations.size() > g.PLAYER
	var play: bool = g.state == "play" and in_match
	ctx.state_mode = ctx.mode()
	if g.state != _state_seen:
		_state_seen = g.state
		if g.state != "over" and over.is_open:
			over.close()
		topbar.refresh()
		layout()
	var ph: int = ctx.state.phase if in_match else -1
	if ph != _phase:
		var before := _phase
		_phase = ph
		top.visible = ph == Defs.PHASE_PLAYING or ph == Defs.PHASE_OVER
		var was_spawn := spawn.visible
		spawn.visible = ph == Defs.PHASE_SPAWN
		if spawn.visible and not was_spawn:
			spawn.on_show()
		if ph != Defs.PHASE_PLAYING:
			alert.clear()
			_seen_nukes.clear()
		board.visible = ph == Defs.PHASE_PLAYING
		attacks.visible = ph == Defs.PHASE_PLAYING
		if ph == Defs.PHASE_SPAWN or (ph == Defs.PHASE_PLAYING and before != Defs.PHASE_SPAWN) or ph == -1:
			# a new match (or back at the title)
			clear_feed()
			board.close_for_match()
			ctx.play_start_tick = -1.0
			ctx.alive_from_tick = NAN
		if ph == Defs.PHASE_PLAYING:
			ctx.play_start_tick = float(ctx.state.tick)
			top.on_bind()
			board.refresh()
			attacks.mark_dirty()
		elif ph == Defs.PHASE_OVER:
			top.on_phase(ph, 0)
		layout()
	if play != _was_play:
		_was_play = play
		bar.visible = play
		if play:
			ctx.rules.recount()
			bar.reset_rate()
			on_share_changed()
			bar.refresh(false)
			layout()
	if top.visible:
		top.update(dt)
	feed.visible = in_match
	_hover(dt, in_match)
	if not _pending_toasts.is_empty():
		var q := _pending_toasts
		_pending_toasts = []
		for e in q:
			_toast_now(e[0], e[1])
	feed.update(dt)
	if not play:
		return
	# (the server sends stats every 5 ticks: the bar's numbers refresh four times a second)
	_stats_t += dt
	if _stats_t >= 0.25:
		_stats_t = 0.0
		bar.refresh(true)
		board.mark_dirty()
	_growth_t += dt
	if _growth_t >= 0.5:
		_growth_t = 0.0
		bar.sample_growth()
	var placing := _placing_kind()
	if placing != bar._placing:
		bar.set_placing(placing)
	icbm.refresh()
	_track_nukes()
	alert.update(dt)
	bar.update(dt)
	board.update(dt)
	attacks.update(dt)
