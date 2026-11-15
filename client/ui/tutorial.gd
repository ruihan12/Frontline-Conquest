# Port of src/client/UI/Tutorial.luau (scripts/ui/tutorial.gd, UITutorial) with the constants and
# steps of src/shared/Data/Tutorial.luau.
# A new player's first match, guided: one short instruction at a time in a card under the top bar
# and a pulsing ring on what to press. Steps: start your nation, take land, let troops refill,
# attack a neighbour, set the Attack bar to 35%, build a City. Finishing pays Stars.
#
# Port: the Stars go into this port's save; the tutorial match is an ordinary solo match on the
# default map at the gentlest difficulty (upstream also thins the tribes and shortens the spawn
# countdown; this port's match setup has no such options).
class_name Tutorial
extends Control

signal finished(how: String)
signal step_done(step: int, step_name: String)
signal closed

const DONE_S := 0.9
const END_S := 9.0
const SPAWN_TRIES := 240
const SPAWN_ROOM := 35.0

# --- Data/Tutorial ---
const STARS := 1000
const DIFFICULTY := 0
const RATIO_CAP := 0.5
const TROOP_FLOOR := 0.25
const FLOOR_ARM := 0.35
const FLOOR_ARM_S := 10.0
const FLOOR_FROM := "attack"
const AUTO_SPAWN_S := 12.0
const GROW_TAPS := 1
const GROW_READY := 0.3
const EARLY_S := 2.0
const CONTACT_WAIT_S := 25.0
const RATIO_GOAL := 0.35
const RATIO_LOW := 0.3
const RATIO_HIGH := 0.4
const RATIO_HOLD_S := 0.2
const RATIO_MAX_S := 30.0
const RATIO_TOO_MUCH := "Too many! Tap 35%"
const STEP_MAX_S := 75.0
const NUDGE_S := 5.0
const STEPS := [
	{"id": "spawn", "touch": "Tap the map to start your nation", "desktop": "Click the map to start your nation"},
	{"id": "expand", "touch": "Tap the land next to you to take it", "desktop": "Click the land next to you to take it"},
	{"id": "grow", "touch": "Tap empty land to expand", "desktop": "Click empty land to expand", "wait": "Now let your troops refill", "early": "Done! Next time, let the bar fill", "bar": true},
	{"id": "attack", "touch": "Tap %s, then tap again to attack", "desktop": "Click %s's land to attack them"},
	{"id": "ratio", "touch": "Tap 35% below. Keep troops home!", "desktop": "Click 35% on the Attack bar. Keep troops home!", "max_s": RATIO_MAX_S},
	{"id": "city", "touch": "Open BUILD, pick City, tap your land", "desktop": "Pick City (1) and click your land", "note": "Here is gold for your first City"},
]
const FUNNEL := ["Started", "Spawned", "First Tap", "Grew", "Attacked", "Used Slider", "Built City", "Completed"]

var ctx: UICtx
var ui  # ClientHud
var active := false
var _i := 0
var _t := 0.0
var _step_t := 0.0
var _flash := 0.0
var _ending := 0.0
var _sent := 0
var _idle := 0.0
var _spot := -1
var _spot_state = null
var _picked := false
var _neighbour := 0
var _gold_given := false
var _started := false
var _shown := -1
var _taps := 0
var _ready = null
var _refill := -1.0
var _line := ""
var _ratio_ok := 0.0
var _ratio_high := false
var _fill_f := 0.0
var _mark: Control
var _mark_p := Vector2(-1, -1)
var _mark_word := ""
var _mark_around := -1.0
var _card: GlassPanel
var _count: Label
var _text: Label
var _bar: Control
var _fill: ColorRect
var _fill_col := UITheme.AMBER
var _skip: Button


static func funnel_step(id: String) -> int:
	for i in STEPS.size():
		if STEPS[i].id == id:
			return i + 2
	return 0


static func step_index(id: String) -> int:
	for i in STEPS.size():
		if STEPS[i].id == id:
			return i + 1
	return 0


## A player with no finished match, no tutorial run and no tip seen.
static func is_new(settings: Dictionary, matches: int) -> bool:
	var tut = settings.get("tutorial", "")
	if tut is String and tut != "":
		return false
	if matches > 0:
		return false
	var seen = settings.get("tips_seen", {})
	if seen is Dictionary and not seen.is_empty():
		return false
	return true


static func floor_armed(troops: float, cap: float, played_s: float) -> bool:
	return played_s >= FLOOR_ARM_S or (cap > 0 and troops >= FLOOR_ARM * cap)


static func refill(troops: float, cap: float, shown: float) -> float:
	var need := GROW_READY * cap
	var f := clampf(troops / need, 0.0, 1.0) if need > 0 else 1.0
	return maxf(f, maxf(shown, 0.0))


func _init(c: UICtx, host) -> void:
	ctx = c
	ui = host
	name = "Tutorial"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mark = Control.new()
	_mark.name = "TutorialMark"
	_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mark.draw.connect(_paint_mark)
	_mark.visible = false
	add_child(_mark)

	var card := GlassPanel.new(12.0, 8.0, UITheme.R_MD, true, 18)
	card.set_accent(UITheme.AMBER)
	card.set_border(UITheme.c(UITheme.AMBER, 0.5))
	_card = card
	var h := UITheme.hbox(10)
	card.add_child(h)
	_count = UITheme.label("1 / 6", 12, 800, UITheme.AMBER)
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(_count)
	var v := UITheme.vbox(5)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_text = UITheme.label("", 14, 700, UITheme.TEXT)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(220, 0)
	v.add_child(_text)
	_bar = Control.new()
	_bar.custom_minimum_size = Vector2(0, 5)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(func() -> void:
		var r := Rect2(Vector2.ZERO, _bar.size)
		_bar.draw_style_box(UITheme.flat(Color(1, 1, 1, 0.15), 3), r)
		if _fill_f > 0.0:
			_bar.draw_style_box(UITheme.flat(_fill_col, 3), Rect2(0, 0, maxf(5.0, r.size.x * _fill_f), r.size.y)))
	v.add_child(_bar)
	h.add_child(v)
	_skip = UITheme.button("Skip", "GhostButton", "", 36.0)
	_skip.add_theme_font_size_override("font_size", 12)
	_skip.custom_minimum_size = Vector2(52, 36)
	_skip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_skip.pressed.connect(func() -> void:
		if _ending > 0.0:
			_close()
		else:
			stop("skipped"))
	h.add_child(_skip)
	add_child(card)
	card.visible = false
	set_process(true)


func begin() -> void:
	active = true
	_i = 1
	_step_t = 0.0
	_flash = 0.0
	_ending = 0.0
	_idle = 0.0
	_spot = -1
	_spot_state = null
	_picked = false
	_neighbour = 0
	_gold_given = false
	_shown = -1
	_sent = ctx.sent_log.size()
	_card.visible = false
	_started = false
	ctx.ratio_max = 1.0
	ctx.set_ratio(UICtx.DEFAULT_RATIO)
	ctx.set_ratio_max(RATIO_CAP)
	ctx.troop_floor = NAN


func stop(how: String) -> void:
	if not active:
		return
	active = false
	_mark.visible = false
	ctx.set_ratio_max(1.0)
	ctx.troop_floor = NAN
	if how == "done":
		_ending = END_S
		_count.text = "★"
		_text.text = "Tutorial complete! +%s Stars\nSpend them in the ARSENAL" % UICtx.commas(STARS)
		_bar.visible = false
		_skip.text = "OK"
		_tint(UITheme.GREEN)
		_card.visible = true
		_place()
		ctx.sfx("unlock", -4.0)
	else:
		_card.visible = false
	finished.emit(how)
	if how != "done":
		closed.emit()


func _close() -> void:
	_ending = 0.0
	_card.visible = false
	closed.emit()


func _tint(col: Color) -> void:
	_card.set_accent(col)
	_card.set_border(UITheme.c(col, 0.5))
	UITheme.set_font_color(_count, col)


func apply_layout() -> void:
	if _card.visible:
		_place()


func _place() -> void:
	var vp := ctx.vp
	var ins := ctx.insets
	var c := ctx.compact
	_text.add_theme_font_size_override("font_size", 13 if c else 15)
	_text.custom_minimum_size = Vector2(256 if _ending > 0.0 else (200 if c else 260), 0)
	_card.reset_size()
	var sz := _card.get_combined_minimum_size()
	var x := clampf((vp.x - sz.x) * 0.5, ins.x + 8.0, maxf(ins.x + 8.0, vp.x - ins.z - sz.x - 8.0))
	var y := ins.y + (62.0 if c else 74.0)
	# (port) this port's status pill is taller than upstream's: sit under it
	if ui.top != null and ui.top.visible:
		y = maxf(y, ui.top.bottom_edge() + 8.0)
	_card.position = Vector2(floorf(x), floorf(y))
	_card.size = sz


## Orders sent since the last look: [any, one on an owner, one on unclaimed land].
func _orders() -> Array:
	var log: Array = ctx.sent_log
	var s = ctx.state
	var any := false
	var on_owner := false
	var on_land := false
	if _sent > log.size():
		_sent = 0
	for k in range(_sent, log.size()):
		var it = log[k].intent
		if it is Dictionary and (it.get("type") == "attack" or it.get("type") == "boat"):
			any = true
			var target := -1
			if it.has("target"):
				target = int(it.target)
			elif it.has("tile") and s != null:
				target = s.tile_owner(int(it.tile))
			if target > 0:
				on_owner = true
			else:
				on_land = true
	_sent = log.size()
	return [any, on_owner, on_land]


## A roomy inland place to start: unclaimed, away from the coast and from every other start.
func _find_spot() -> int:
	var s = ctx.state
	if s == null:
		return -1
	var map = s.map
	var w: int = map.W
	var h: int = map.H
	var starts: Array[int] = []
	for o in s.owners():
		if o.alive and int(o.get("label_tile", -1)) >= 0 and int(o.tiles) > 0:
			starts.append(int(o.label_tile))
	var best := -1
	var best_d := -1.0
	for _k in SPAWN_TRIES:
		var t := randi_range(0, w * h - 1)
		if not map.is_land(t) or not map.is_contestable(t) or s.tile_owner(t) != 0 or map.is_coastal(t):
			continue
		var d := INF
		for o2 in starts:
			d = minf(d, Vector2(t % w - o2 % w, t / w - o2 / w).length())
		d = minf(d, SPAWN_ROOM)
		@warning_ignore("integer_division")
		var off := absf(float(t / w) / float(h) - 0.45)
		d -= maxf(0.0, off - 0.27) * 300.0
		if d > best_d:
			best = t
			best_d = d
	return best


func _say(i: int, arg: String = "") -> void:
	var step: Dictionary = STEPS[i - 1]
	var txt: String = step.touch if ctx.touch else step.desktop
	if txt.contains("%s"):
		txt = txt % (arg if arg != "" else "them")
	_count.text = "%d / %d" % [i, STEPS.size()]
	_text.text = txt
	_bar.visible = step.get("bar", false) == true
	_fill_f = 0.0
	_fill_col = UITheme.AMBER
	_bar.queue_redraw()
	_skip.text = "Skip"
	_tint(UITheme.AMBER)
	_card.visible = i > 1
	if i > 1:
		_place()
		UIFx.pop_in(_card, 0.0, 0.94, 0.3)


func _advance(passed: bool = false) -> void:
	var step: Dictionary = STEPS[_i - 1]
	if not passed:
		var fs := funnel_step(step.id)
		step_done.emit(fs, FUNNEL[fs - 1])
		ctx.sfx("confirm", -4.0)
		if _card.visible:
			_tint(UITheme.GREEN)
			_text.text = "Nice!"
			_bar.visible = false
			_flash = DONE_S
	_i += 1
	_step_t = 0.0
	_idle = 0.0
	_shown = -1
	if _i > STEPS.size():
		step_done.emit(FUNNEL.size(), FUNNEL[FUNNEL.size() - 1])
		stop("done")


func _process(delta: float) -> void:
	_t += delta
	if _ending > 0.0:
		_ending -= delta
		if _ending <= 0.0:
			_close()
		return
	if not active:
		return
	var s = ctx.state
	if s == null or ctx.mode() != UICtx.MODE_SOLO:
		return
	if s.phase == Defs.PHASE_OVER:
		stop("left")
		return
	if _flash > 0.0:
		_flash -= delta
		_mark.visible = false
		if _flash > 0.0:
			return
	var i := _i
	var step: Dictionary = STEPS[i - 1]
	var o = ctx.my()
	var ord := _orders()
	var any: bool = ord[0]
	var on_owner: bool = ord[1]
	_step_t += delta
	if is_nan(ctx.troop_floor) and i >= maxi(1, step_index(FLOOR_FROM)) and o != null and floor_armed(float(o.troops), float(o.get("max_troops", 0)), ctx.alive_seconds()):
		ctx.troop_floor = TROOP_FLOOR
	if not _started and _step_t > 1.0:
		_started = true
		step_done.emit(1, FUNNEL[0])
	_idle = 0.0 if any else _idle + delta
	var point := Vector2(-1, -1)
	var around := -1.0
	var word := ""
	var id: String = step.id
	if id == "spawn":
		if o != null and o.spawned:
			_advance()
			return
		if _spot < 0 or _spot_state != s:
			_spot = _find_spot()
			_spot_state = s
			_step_t = 0.0
			if _spot >= 0:
				ctx.world_call("focus_tile", [_spot, -1.0, 0.9])
		if _spot >= 0:
			point = ctx.tile_screen_pos(_spot)
			if _step_t > AUTO_SPAWN_S and not _picked and s.tile_owner(_spot) == 0:
				_picked = true
				ctx.send({"type": "spawn", "tile": _spot})
	elif o != null and o.spawned and o.alive == false:
		stop("left")  # (conquered: the result screen takes over)
		return
	elif o == null or not ctx.alive_player() or s.phase != Defs.PHASE_PLAYING:
		_mark.visible = false
		return
	else:
		if _shown != i:
			_shown = i
			if id == "grow":
				_taps = 0
				_ready = null
				_refill = -1.0
				_line = ""
				any = false
			elif id == "attack":
				_neighbour = 0
			elif id == "ratio":
				_ratio_ok = 0.0
				_ratio_high = false
			elif id == "city" and not _gold_given:
				_gold_given = true
				# the gold for the first City
				var g = ctx.session.g
				var cost: float = ctx.rules.cost("city")
				if cost > 0 and float(g.nations[g.PLAYER].gold) < cost:
					g.nations[g.PLAYER].gold = cost
			_say(i, s.owner_name(_neighbour) if _neighbour != 0 else "")
		if id == "expand":
			if any:
				_advance()
				return
			point = ui.advisor.frontier_point()
		elif id == "grow":
			if any:
				var early: bool = _ready != true
				_taps += 1
				if early:
					_refill = -1.0
				if _taps >= GROW_TAPS:
					_advance()
					if early and _card.visible:
						_text.text = step.early
						_flash = EARLY_S
					return
			var cap := float(o.get("max_troops", 0))
			var f := refill(float(o.troops), cap, _refill) if cap > 0 else 1.0
			_refill = f
			var ready := f >= 1.0
			if _ready == null or ready != _ready:
				if ready and _ready == false:
					ctx.sfx("tick", -6.0)
					UIFx.pop_in(_card, 0.0, 0.97, 0.25)
				_ready = ready
				_fill_col = UITheme.GREEN if ready else UITheme.AMBER
				_bar.queue_redraw()
			var line: String = (step.touch if ctx.touch else step.desktop) if ready else step.wait
			if line != _line:
				_line = line
				_text.text = line
			if absf(f - _fill_f) >= 0.005 or (ready and _fill_f != 1.0):
				_fill_f = f
				_bar.queue_redraw()
			if not ready:
				var tc = _troops_control()
				if tc != null:
					var r: Rect2 = tc.get_global_rect()
					point = r.get_center()
					around = maxf(r.size.x, r.size.y) * 0.5
					word = "Refilling"
			elif _taps == 0 or _idle > NUDGE_S:
				point = ui.advisor.frontier_point()
		elif id == "ratio":
			var rr := ctx.ratio
			if rr >= RATIO_LOW and rr <= RATIO_HIGH:
				_ratio_ok += delta
				if _ratio_ok >= RATIO_HOLD_S:
					_advance()
					return
			else:
				_ratio_ok = 0.0
			var high := rr > RATIO_HIGH
			if high != _ratio_high:
				_ratio_high = high
				_text.text = RATIO_TOO_MUCH if high else (step.touch if ctx.touch else step.desktop)
				_tint(UITheme.RED if high else UITheme.AMBER)
			var sl = ui.bar._slider
			if sl != null and sl.is_visible_in_tree():
				var r2: Rect2 = sl.stop_rect(RATIO_GOAL)
				if r2.size.x <= 0.0:
					r2 = sl.get_global_rect()
				point = r2.get_center()
				around = minf(r2.size.x, r2.size.y) * 0.5
		elif id == "attack":
			if on_owner:
				_advance()
				return
			if _neighbour == 0 or s.get_owner(_neighbour) == null or not s.get_owner(_neighbour).alive:
				_neighbour = 0
				var ns: Array[int] = ctx.borders.neighbour_ids()
				if not ns.is_empty():
					_neighbour = ns[0]
					_say(i, s.owner_name(ns[0]))
				elif _step_t > CONTACT_WAIT_S:
					_advance(true)  # nobody to attack yet
					return
				else:
					_text.text = "Keep growing until you meet a neighbour"
					if _idle > NUDGE_S:
						point = ui.advisor.frontier_point()
			if _neighbour != 0:
				point = ctx.tile_screen_pos(int(s.get_owner(_neighbour).label_tile))
		elif id == "city":
			for st in s.structures():
				if st.owner == ctx.me() and st.kind == Defs.S_CITY:
					_advance()
					return
			var cb = ui.bar.button("city")
			var b = cb if (cb != null and cb.is_visible_in_tree()) else ui.bar._tray_btn
			var pc: PlaceConfirm = ui.place_confirm
			var placing: bool = ui.interact.aim_kind == "city"
			if _card.visible == placing:
				_card.visible = not placing
			if pc != null and pc.is_open and pc._ok.is_visible_in_tree():
				var r3 := pc._ok.get_global_rect()
				point = r3.get_center()
				around = maxf(r3.size.x, r3.size.y) * 0.5
			elif placing:
				point = ctx.tile_screen_pos(int(s.get_owner(ctx.me()).label_tile))
			elif b != null and b.is_visible_in_tree():
				var r4: Rect2 = b.get_global_rect()
				point = r4.get_center()
				around = maxf(r4.size.x, r4.size.y) * 0.5
		if _step_t > float(step.get("max_s", STEP_MAX_S)):
			_advance(true)
			return
	_draw_mark(point, word if word != "" else str(step.get("mark", "")), around)


func _troops_control():
	var bar = ui.bar
	if bar == null:
		return null
	for c in [bar._troops_box, bar._m_troops]:
		if c != null and c.is_visible_in_tree():
			return c
	return null


func _draw_mark(p: Vector2, word: String, around: float) -> void:
	if p.x < 0.0 or p.y < 0.0 or p.x > ctx.vp.x or p.y > ctx.vp.y:
		_mark.visible = false
		return
	_mark.visible = true
	_mark_p = p
	_mark_word = word
	_mark_around = around
	_mark.queue_redraw()


## Two rings closing in on the target, a dot (map targets) and a "Click here" tag.
func _paint_mark() -> void:
	var p := _mark_p
	var around := _mark_around
	var k1 := fmod(_t, 1.1) / 1.1
	var k2 := fmod(_t + 0.55, 1.1) / 1.1
	var inner := around + 4.0 if around >= 0.0 else 12.0
	var outer := inner + (16.0 if around >= 0.0 else 22.0)
	_mark.draw_arc(p, outer - (outer - inner) * k1, 0.0, TAU, 48, Color(UITheme.AMBER, k1 * 0.95), 3.0, true)
	_mark.draw_arc(p, outer - (outer - inner) * k2, 0.0, TAU, 48, Color(UITheme.AMBER, k2 * 0.95), 2.0, true)
	if around < 0.0:
		_mark.draw_circle(p, 6.0, UITheme.AMBER)
	var word := _mark_word if _mark_word != "" else ("Tap here" if ctx.touch else "Click here")
	var font := UITheme.font(700)
	var tw := font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	var sz := Vector2(tw + 18.0, 26.0)
	var gap := outer + 6.0
	var below := p.y + gap + 26.0 < ctx.vp.y - ctx.insets.w
	var top := p.y + gap if below else p.y - gap - sz.y
	var r := Rect2(p.x - sz.x * 0.5, top, sz.x, sz.y)
	_mark.draw_style_box(UITheme.flat(Color(Color8(14, 20, 38), 0.85), 13), r)
	_mark.draw_string(font, Vector2(r.position.x + 9.0, r.position.y + 18.0), word, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
