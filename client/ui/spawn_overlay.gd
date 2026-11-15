# Port of src/client/UI/SpawnOverlay.luau (scripts/ui/spawn_overlay.gd, UISpawnOverlay).
# Spawn-phase banner: "Choose your starting location", a countdown ring, the solo "Deploying in 5…"
# count and, in multiplayer, how many commanders have placed their capitals.
#
# One slim row: two lines of text, the count and the ring. (The commanders' head shots are left out:
# no accounts here.)
class_name SpawnOverlay
extends Control

## The title's size on a wide screen (phones: 13).
const TITLE_PX := 14
## The ring's side on a wide screen (phones: 36).
const RING_PX := 40


## Countdown ring: track circle, amber / red arc, seconds.
class Ring:
	extends Control
	var frac := 1.0
	var secs := 0
	var urgent := false

	func _init() -> void:
		custom_minimum_size = Vector2(54, 54)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 3.0
		draw_arc(c, r, 0, TAU, 48, Color(1, 1, 1, 0.1), 4.0, true)
		if frac > 0:
			draw_arc(c, r, -PI / 2, -PI / 2 + TAU * frac, 48, UITheme.RED if urgent else UITheme.AMBER, 4.0, true)
		# draw_string(font 800, size 20) with its baseline at c.y + 20 * 0.36
		draw_string(UITheme.font(800), Vector2(0, c.y + 20 * 0.36), str(secs), HORIZONTAL_ALIGNMENT_CENTER, size.x, 20, UITheme.TEXT)


var ctx: UICtx
var _end_tick := -1.0
var _total := 1.0
var _last_sec := -1
var _accum := 0.0
var panel: GlassPanel
var _row: HBoxContainer
var _title: Label
var _sub: Label
var _placed: Label
var _side: HBoxContainer
var _count: Label
var _ring: Ring


func _init(c: UICtx) -> void:
	ctx = c
	name = "SpawnOverlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = GlassPanel.new(22.0, 14.0, UITheme.R_LG, true, 24)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	var row := UITheme.hbox(14)
	_row = row
	panel.add_child(row)
	var v := UITheme.vbox(1)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title = UITheme.label("CHOOSE YOUR STARTING LOCATION", TITLE_PX, 800, UITheme.TEXT, 1)
	v.add_child(_title)
	_sub = UITheme.label("Click any unclaimed land to place your capital.", 12, 500, UITheme.TEXT_2)
	v.add_child(_sub)
	# phones: the count is a third line under the text
	_placed = UITheme.label("", 12, 600, UITheme.TEXT_3)
	_placed.visible = false
	v.add_child(_placed)
	row.add_child(v)
	# a wide screen: the count beside the text
	_side = UITheme.hbox(8)
	_side.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_side.add_child(UITheme.vdivider(26.0))
	_count = UITheme.label("", 12, 700, UITheme.TEXT_2)
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_side.add_child(_count)
	_side.visible = false
	row.add_child(_side)
	_ring = Ring.new()
	_ring.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_ring)
	# (fixed text box: the two lines change without moving the banner)
	UITheme.fix_width(_sub, UITheme.text_width("Click elsewhere to relocate until the countdown ends.", 12, 500) + 4.0, HORIZONTAL_ALIGNMENT_LEFT, false)


func apply_layout() -> void:
	panel.mouse_filter = Control.MOUSE_FILTER_STOP if ctx.touch else Control.MOUSE_FILTER_IGNORE
	var top := 12.0 + ctx.insets.y
	if ctx.compact:
		# Phones: slimmer still, leaving the globe to the player.
		top = 8.0 + ctx.insets.y
		_title.add_theme_font_size_override("font_size", 13)
		panel.set_padding(12.0, 4.0, 8.0, 4.0)
		_ring.custom_minimum_size = Vector2(36, 36)
		_row.add_theme_constant_override("separation", 10)
	else:
		_title.add_theme_font_size_override("font_size", TITLE_PX)
		panel.set_padding(16.0, 8.0, 12.0, 8.0)
		_ring.custom_minimum_size = Vector2(RING_PX, RING_PX)
		_row.add_theme_constant_override("separation", 14)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_END
	var pt := ctx.place_top(panel.get_combined_minimum_size().x, top)
	panel.offset_left = pt[0]
	panel.offset_right = pt[0]
	panel.offset_top = pt[1]
	panel.offset_bottom = pt[1]
	panel.reset_size()


func bottom_edge() -> float:
	return panel.get_global_rect().end.y


func on_show() -> void:
	_last_sec = -1
	refresh()
	UIFx.pop_in(panel, 0.05, 0.94, 0.45)


func on_phase(ticks_left: float) -> void:
	var s = ctx.state
	if s == null:
		return
	_end_tick = s.tick + ticks_left if ticks_left > 0 else -1.0
	if ticks_left > 0:
		_total = maxf(ticks_left, SimRules.SOLO_COUNTDOWN_TICKS) / Defs.TICK_RATE
	refresh()


func refresh() -> void:
	var s = ctx.state
	if s == null:
		return
	var o = ctx.my()
	var placed: bool = o != null and o.spawned
	var solo := ctx.mode() == UICtx.MODE_SOLO
	var left := -1.0
	if _end_tick > 0.0:
		left = maxf(0.0, (_end_tick - ctx.render_tick()) / Defs.TICK_RATE)
	# (this port's spawn countdown runs on the game's clock while no sim tick passes, and only once
	# the capital is placed)
	var gs: float = s.spawn_seconds_left()
	if gs >= 0.0:
		left = gs
		_total = float(SimRules.SOLO_COUNTDOWN_TICKS) / Defs.TICK_RATE
	var ring := _ring
	ring.visible = left >= 0.0 and s.phase == Defs.PHASE_SPAWN
	if left >= 0.0:
		ring.frac = clampf(left / maxf(_total, 0.1), 0.0, 1.0)
		ring.secs = int(ceil(left))
		ring.urgent = left <= 5.0
		ring.queue_redraw()
		var sec := int(ceil(left))
		if sec != _last_sec and sec <= 5 and sec > 0 and _last_sec >= 0:
			ctx.sfx("tick", -4.0 if sec > 1 else 0.0, 0.0)
		_last_sec = sec
	var late: bool = s.phase == Defs.PHASE_PLAYING
	var verb := "Tap" if ctx.touch else "Click"
	if ctx.me() == 0:
		_title.text = "COMMANDERS ARE DEPLOYING"
		_sub.text = "You are spectating this match."
	elif late and not placed:
		_title.text = "DROP INTO THE WAR"
		_sub.text = verb + " any unclaimed land to deploy your capital."
	elif placed and solo and left >= 0.0:
		_title.text = "DEPLOYING IN %d" % int(ceil(left))
		_sub.text = verb + " elsewhere to relocate your capital."
	elif placed:
		_title.text = "CAPITAL PLACED"
		_sub.text = verb + " elsewhere to relocate until the countdown ends."
	else:
		_title.text = "CHOOSE YOUR STARTING LOCATION"
		_sub.text = "Click any unclaimed land to place your capital." if not ctx.touch else "Tap any unclaimed land to place your capital."
	_refresh_players()
	panel.reset_size()


func _refresh_players() -> void:
	var s = ctx.state
	var mp := ctx.mode() == UICtx.MODE_MULTI
	_side.visible = mp and not ctx.compact
	_placed.visible = mp and ctx.compact
	if not mp or s == null:
		return
	var humans := 0
	var placed := 0
	for o in s.owners():
		if o.kind == Defs.KIND_HUMAN and o.alive:
			humans += 1
			if o.spawned:
				placed += 1
	if ctx.compact:
		_placed.text = "%d / %d commanders placed" % [placed, humans]
		return
	_count.text = "%d / %d placed" % [placed, humans]


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= 0.1 and is_visible_in_tree():
		_accum = 0.0
		refresh()
