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

	bar = CommandBar.new(ctx)
	icbm = IcbmSlot.new(ctx)
	bar.port_slots = [icbm]
	root.add_child(bar)
	bar.visible = false
	bar.build_chosen.connect(_on_build_chosen)
	bar.arsenal_wanted.connect(func(_key, _from) -> void: g._open_shop())
	bar.slots_changed.connect(layout)
	ctx.ratio_changed.connect(_on_ratio_changed)
	root.resized.connect(layout)
	layout()


## UIRoot._layout: metrics, then each part.
func layout() -> void:
	if root == null:
		return
	var vs := root.size
	if vs.x < 10:
		vs = Vector2(1600, 900)
	ctx.vp = vs
	ctx.compact = false
	# UIRoot: the single-row bar needs 1420 px plus what the Arsenal adds
	ctx.wide = vs.x >= 1420.0 + bar.extra_width() + 62.0 * bar.port_slots.size()
	bar.apply_layout()
	ctx.layout_changed.emit()


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


func process(dt: float) -> void:
	if root == null:
		return
	var play: bool = g.state == "play" and g.nations.size() > g.PLAYER
	ctx.state_mode = ctx.mode()
	if play != _was_play:
		_was_play = play
		bar.visible = play
		if play:
			ctx.play_start_tick = float(ctx.state.tick)
			ctx.alive_from_tick = NAN
			ctx.rules.recount()
			bar.reset_rate()
			on_share_changed()
			bar.refresh(false)
			layout()
	if not play:
		return
	# (the server sends stats every 5 ticks: the bar's numbers refresh four times a second)
	_stats_t += dt
	if _stats_t >= 0.25:
		_stats_t = 0.0
		bar.refresh(true)
	_growth_t += dt
	if _growth_t >= 0.5:
		_growth_t = 0.0
		bar.sample_growth()
	var placing := _placing_kind()
	if placing != bar._placing:
		bar.set_placing(placing)
	icbm.refresh()
	bar.update(dt)
