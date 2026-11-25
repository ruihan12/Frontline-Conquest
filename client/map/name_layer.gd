# Port of src/client/Map/NameLayer.luau: owner names and troop counts on the map.
#   * placement (_place): a coarse grid over the bounding box of the owner's main cluster (scaling
#     factor 1..32 by the box's size) where a cell is usable if it is the owner's tile, a shoreline
#     tile, ocean with magnitude < 10 or fallout; the largest inscribed rectangle of that grid; the name sits at its centre, raised
#     by fontSize / 3, with fontSize = min(rect.width / name length * 2, rect.height / 3).
#     Recomputed every 30 ticks and at once for new owners; spawn-phase names use an 8-tile box on
#     the spawn;
#   * sizing: baseSize = max(1, floor(size)), nameSize = max(4, floor(baseSize * 0.4)), nameScale =
#     min(baseSize * 0.25, 3); the name line is nameSize * nameScale full-size tiles tall, the troop
#     line 0.6 of it; names shorter on screen than the cull threshold hide (hovered ones never do).
#     Positions and sizes glide to new targets (LERP_SPEED 10);
#   * style: fill black for humans, 0.3 grey nations, 0.4 grey tribes; outline in the owner's
#     colour; a crown over the owner with the most land.
#
# Port differences: flags, faces and the HUMAN badge come from Roblox cosmetics and accounts and are
# left out.
class_name NameLayer
extends Control

const NAME_SCALE_FACTOR := 0.4
const NAME_SCALE_CAP := 3.0
const TROOP_SIZE_MULT := 0.6
const LERP_SPEED := 18.0  # custom (owner): upstream 10, plates follow their territory faster
const CULL_VW := 0.004
const CULL_MIN_PX := 6.0
const CULL_HYSTERESIS_PX := 0.5
## smallest name size drawn (px); names are no longer culled below the old CULL_MIN_PX
const MIN_LABEL_PX := 7.0
const SHADE_NATION := 0.3
const SHADE_BOT := 0.4
## outline px per text px
const OUTLINE_K := 0.085
const REPLACE_PLAY_S := 0.1     # custom (owner 2026-11-25): in a match a new placement pass starts every 0.1 s (real time); was 1 s, upstream every 30 ticks
const REPLACE_SPAWN_S := 0.001  # custom (owner): before the match (spawn phase) a new pass starts every millisecond, i.e. as soon as the last one is through
## full-size tiles
const SPAWN_DIAMETER := 8
const BUDGET_S := 0.003  # custom (owner): upstream-ish 1.5 ms; placement finishes sooner
## tiles a flood fill takes between two looks at the clock
const FILL_CHECK := 2048
const LINE_K := 1.0
const OWN_MAX_VH := 0.04
const OWN_MAX_MIN_PX := 18.0
const CROWN_MIN_PX := 16.0
## (Assets/MapSprites.status: 256 px cells, 16 px padding; cell 0 is the crown)
const STATUS_CELL := 256
const STATUS_PAD := 16

var g  # main.gd
var st: RWGameState
var hover_owner := 0
var crown_owner := 0
var _crown_t := 0.0
var _plates := {}  # id -> {sx, sy, ss, tx, ty, ts, t0, rect, shown}
var _targets := {}  # id -> [u, v, font size]
var _queue: Array[int] = []
var _last_place_tick := -1000
var _last_phase := -1
var _last_place_s := 0.0
var _label_tiles := {}  # id -> last label tile
var _visit := PackedInt32Array()
var _visit_gen := 0
var _stack := PackedInt32Array()
var _job = null  # the placement under way: {id, gen, n (stack size), x0, y0, x1, y1}
var _font: Font
var _status: Texture2D


## Troop counts on the plates refresh this often (s); the sim only changes them once per tick anyway.
const TROOP_TEXT_S := 0.0
## Longest gap between redraws while the camera is still (s).
const REDRAW_S := 0.05
var _redraw_t := 0.0
## True while a plate is still easing to a new spot: redraw every frame so the move stays smooth.
var _easing := false
var _last_cam := Vector3.ZERO
var _last_hover := -2


func _init(main, state: RWGameState) -> void:
	g = main
	st = state
	name = "Names"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = UITheme.font(700.0)
	_status = load("res://assets/rw/map_sprites/status.png")


func unbind() -> void:
	_plates.clear()
	_targets.clear()
	_queue.clear()
	_label_tiles.clear()
	_job = null
	_last_place_tick = -1000
	crown_owner = 0


func k_lin() -> float:
	return maxf(0.01, float(st.map.k_lin))


## Largest rectangle under a histogram: [x, width, height].
static func largest_in_histogram(h: PackedInt32Array, n: int) -> Array:
	var stack := PackedInt32Array()
	var best := 0
	var bx := 0
	var bw := 0
	var bh := 0
	for i in n + 1:
		var cur := 0 if i == n else h[i]
		while not stack.is_empty() and cur < h[stack[stack.size() - 1]]:
			var height := h[stack[stack.size() - 1]]
			stack.remove_at(stack.size() - 1)
			var width := i if stack.is_empty() else i - stack[stack.size() - 1] - 1
			if height * width > best:
				best = height * width
				bx = 0 if stack.is_empty() else stack[stack.size() - 1] + 1
				bw = width
				bh = height
		stack.append(i)
	return [bx, bw, bh]


static func font_size(width: float, height: float, text: String) -> float:
	return minf(width / maxf(text.length(), 1) * 2.0, height / 3.0)


func _label_name(id: int) -> String:
	return st.owner_name(id)


## Upstream GameState.label_tile: the owner's tile nearest its centre of mass (the centre itself, the last
## one found, a bounded spiral out to 47 tiles, else its spawn tile), or -1.
func label_tile(id: int) -> int:
	var n: Dictionary = g.nations[id]
	var land := int(n.get("land", 0))
	if land <= 0:
		return -1
	var W: int = g.W
	var H: int = g.H
	var own: PackedInt32Array = g.owner_map
	var gx := clampi(int(floor(float(n.sx) / land + 0.5)), 0, W - 1)
	var gy := clampi(int(floor(float(n.sy) / land + 0.5)), 0, H - 1)
	var guess := gy * W + gx
	if own[guess] == id:
		_label_tiles[id] = guess
		return guess
	var last := int(_label_tiles.get(id, -1))
	if last >= 0 and last < own.size() and own[last] == id:
		return last
	for r in range(1, 48):
		for dx in range(-r, r + 1):
			for k in 2:
				var yy := gy + (-r if k == 0 else r)
				var xx := gx + dx
				if yy < 0 or yy >= H or xx < 0 or xx >= W:
					continue
				if own[yy * W + xx] == id:
					_label_tiles[id] = yy * W + xx
					return yy * W + xx
		for dy in range(-r + 1, r):
			for k in 2:
				var yy2 := gy + dy
				var xx2 := gx + (-r if k == 0 else r)
				if yy2 < 0 or yy2 >= H or xx2 < 0 or xx2 >= W:
					continue
				if own[yy2 * W + xx2] == id:
					_label_tiles[id] = yy2 * W + xx2
					return yy2 * W + xx2
	var sp := int(n.get("spawn_tile", -1))
	var lt := sp if sp >= 0 and sp < own.size() and own[sp] == id else -1
	_label_tiles[id] = lt
	return lt


## A placement job for `id`: the 4-connected flood fill of the cluster holding its label tile
## (upstream NameLayer._cluster_box), resumable across frames; null when it has no land.
func _job_for(id: int):
	var seed := label_tile(id)
	if seed < 0:
		return null
	var W: int = g.W
	var N: int = g.owner_map.size()
	if _visit.size() != N:
		_visit = PackedInt32Array()
		_visit.resize(N)
		_visit_gen = 0
	_visit_gen += 1
	_visit[seed] = _visit_gen
	if _stack.size() != N:
		_stack = PackedInt32Array()
		_stack.resize(N)
	_stack[0] = seed
	return {"id": id, "gen": _visit_gen, "n": 1, "x0": seed % W, "y0": seed / W, "x1": seed % W, "y1": seed / W}


## Runs the job's fill for at most `max_tiles` tiles (-1: to the end); true when the fill is done.
## (One job at a time: the stack and the visit marks are shared.)
func _fill_step(job: Dictionary, max_tiles: int) -> bool:
	var W: int = g.W
	var own: PackedInt32Array = g.owner_map
	var visit := _visit
	var stack := _stack
	var id: int = job.id
	var gen: int = job.gen
	var n: int = job.n
	var x0: int = job.x0
	var y0: int = job.y0
	var x1: int = job.x1
	var y1: int = job.y1
	var left := max_tiles
	var lim := own.size() - W
	while n > 0 and left != 0:
		left -= 1
		n -= 1
		var i := stack[n]
		@warning_ignore("integer_division")
		var y := i / W
		var x := i - y * W
		if x < x0:
			x0 = x
		elif x > x1:
			x1 = x
		if y < y0:
			y0 = y
		elif y > y1:
			y1 = y
		if x > 0 and visit[i - 1] != gen and own[i - 1] == id:
			visit[i - 1] = gen
			stack[n] = i - 1
			n += 1
		if x < W - 1 and visit[i + 1] != gen and own[i + 1] == id:
			visit[i + 1] = gen
			stack[n] = i + 1
			n += 1
		if i >= W and visit[i - W] != gen and own[i - W] == id:
			visit[i - W] = gen
			stack[n] = i - W
			n += 1
		if i < lim and visit[i + W] != gen and own[i + W] == id:
			visit[i + W] = gen
			stack[n] = i + W
			n += 1
	job.n = n
	job.x0 = x0
	job.y0 = y0
	job.x1 = x1
	job.y1 = y1
	return n == 0


## Where an owner's name goes: [u, v, font size] in tiles, or null (upstream NameLayer._place). The grid
## is over the owner's cluster box; a cell is usable if it is the owner's tile, a shoreline tile, ocean
## with magnitude < 10, or fallout (so a coastal name may spill over its shore and shallow sea).
func _place_from_box(id: int, x0: int, y0: int, x1: int, y1: int):
	var W: int = g.W
	var k := k_lin()
	var size_of := minf(x1 - x0, y1 - y0) * k
	var sf_of := 1 if size_of < 25 else (2 if size_of < 50 else (4 if size_of < 100 else (8 if size_of < 250 else (16 if size_of < 500 else 32))))
	var sf := maxi(1, int(floor(sf_of / k + 0.5)))
	@warning_ignore("integer_division")
	var gx0 := x0 / sf
	@warning_ignore("integer_division")
	var gy0 := y0 / sf
	@warning_ignore("integer_division")
	var gw := x1 / sf - gx0 + 1
	@warning_ignore("integer_division")
	var gh := y1 / sf - gy0 + 1
	var heights := PackedInt32Array()
	heights.resize(gw)
	var own: PackedInt32Array = g.owner_map
	var tb: PackedByteArray = g.tile_bytes
	var has_tb := tb.size() == own.size()
	var fall: PackedByteArray = g.fallout
	var has_fall := fall.size() == own.size()
	var best := 0
	var bx := 0
	var by := 0
	var bw := 0
	var bh := 0
	for gy in gh:
		var ty := (gy0 + gy) * sf
		for gx in gw:
			var t := ty * W + (gx0 + gx) * sf
			var usable := own[t] == id
			if not usable:
				if has_tb:
					var b: int = tb[t]
					usable = (b & 64) != 0 or (b < 128 and (b & 32) != 0 and (b & 31) < 10)
				usable = usable or (has_fall and fall[t] == 1)
			heights[gx] = heights[gx] + 1 if usable else 0
		var r := largest_in_histogram(heights, gw)
		if int(r[1]) * int(r[2]) > best:
			best = int(r[1]) * int(r[2])
			bx = r[0]
			by = gy - int(r[2]) + 1
			bw = r[1]
			bh = r[2]
	var rw := bw * sf
	var rh := bh * sf
	var cx := floorf(bx * sf + rw / 2.0 + gx0 * sf)
	var cy := floorf(by * sf + rh / 2.0 + gy0 * sf)
	var fs := font_size(rw * k, rh * k, _label_name(id))
	return [cx + 0.5, cy + 0.5 - fs / 3.0 / k, fs]


## The whole placement at once (new owners).
func _place(id: int):
	var n: Dictionary = g.nations[id]
	if int(n.get("land", 0)) <= 0:
		return null
	if _job != null:
		# (the fill in progress shares the stack: it starts over later)
		_queue.append(int(_job.id))
		_job = null
	var job = _job_for(id)
	if job == null:
		return null
	_fill_step(job, -1)
	return _place_from_box(id, job.x0, job.y0, job.x1, job.y1)


## Upstream _place_spawn: an 8-tile box on the spawn tile.
func _place_spawn(id: int):
	var n: Dictionary = g.nations[id]
	if int(n.get("land", 0)) <= 0:
		return null
	var W: int = g.W
	var k := k_lin()
	var d := float(SPAWN_DIAMETER)
	var fs := font_size(d, d, _label_name(id))
	var t := int(n.get("spawn_tile", -1))
	if t < 0:
		var land := maxf(1.0, float(n.land))
		return [floorf(float(n.sx) / land) + 0.5, floorf(float(n.sy) / land) + 0.5 - fs / 3.0 / k, fs]
	return [t % W + 0.5, t / W + 0.5 - fs / 3.0 / k, fs]


func _live(id: int) -> bool:
	var n: Dictionary = g.nations[id]
	return bool(n.get("alive", false)) and int(n.get("land", 0)) > 0


func _refresh_queue() -> void:
	_queue.clear()
	for id in range(1, g.nations.size()):
		if _live(id):
			_queue.append(id)


func _placement_step() -> void:
	var tick := int(st.tick)
	var spawn: bool = st.phase == Defs.PHASE_SPAWN
	# (port) also when the phase changes (spawn names give way to placed ones at once) and every 3 s
	# of real time, for a game that is paused or stepped by hand
	var now_s := Time.get_ticks_msec() / 1000.0
	var ph := int(st.phase)
	if ph != _last_phase:
		# the spawn phase ended (or began): every name is placed again at once, so no 8-tile spawn
		# name is left waiting for its turn in the queue (cheap then: every owner holds its spawn disc)
		var was_spawn := _last_phase == Defs.PHASE_SPAWN
		_last_phase = ph
		if not spawn and not was_spawn:
			_queue.clear()
			_job = null
			_refresh_queue()
			return
		_last_place_tick = tick
		_last_place_s = now_s
		_job = null
		_queue.clear()
		for id0 in range(1, g.nations.size()):
			if _live(id0):
				var t0p = _place_spawn(id0) if spawn else _place(id0)
				if t0p != null:
					_targets[id0] = t0p
		return
	# (port) a new pass only once the last one is through (a pass of a few hundred flood fills goes
	# over many frames here; upstream starts one every REPLACE_PLAY_S), and every 3 s of real time for a
	# game that is paused or stepped by hand
	if (_queue.is_empty() and _job == null) and (tick < _last_place_tick or now_s - _last_place_s >= (REPLACE_SPAWN_S if spawn else REPLACE_PLAY_S)):
		_last_place_tick = tick
		_last_place_s = now_s
		_refresh_queue()
	var t0 := Time.get_ticks_usec()
	# new owners at once
	for id in range(1, g.nations.size()):
		if _live(id) and not _targets.has(id):
			var t = _place_spawn(id) if spawn else _place(id)
			if t != null:
				_targets[id] = t
	# the rest a little every frame, a flood fill going over several frames when it must (upstream: a
	# cooperative job with a time budget, Coop.check every FILL_CHECK tiles)
	var budget := int(BUDGET_S * 1e6)
	while Time.get_ticks_usec() - t0 < budget:
		if _job == null:
			if _queue.is_empty():
				break
			var id2: int = _queue.pop_back()
			if id2 >= g.nations.size() or not _live(id2):
				continue
			if spawn:
				var ts = _place_spawn(id2)
				if ts != null:
					_targets[id2] = ts
				continue
			_job = _job_for(id2)
			if _job == null:
				continue
		var jid: int = _job.id
		if jid >= g.nations.size() or not _live(jid):
			_job = null
			continue
		if _fill_step(_job, FILL_CHECK):
			var t2 = _place_from_box(jid, _job.x0, _job.y0, _job.x1, _job.y1)
			if t2 != null:
				_targets[jid] = t2
			_job = null


static func shade_of(kind: int) -> float:
	if kind == Defs.KIND_NATION:
		return SHADE_NATION
	if kind == Defs.KIND_TRIBE:
		return SHADE_BOT
	return 0.0


## The owner with the most land (the lowest id on a tie).
func crown_of() -> int:
	var best := 0
	var bt := 0
	for id in range(1, g.nations.size()):
		var n: Dictionary = g.nations[id]
		var t := int(n.get("land", 0))
		if bool(n.get("alive", false)) and t > 0 and t > bt:
			best = id
			bt = t
	return best


func _process(dt: float) -> void:
	if not is_visible_in_tree() or g.nations.size() < 2:
		return
	_crown_t -= dt
	if _crown_t <= 0.0:
		_crown_t = 0.25
		crown_owner = crown_of()
	var _pt0 := Time.get_ticks_usec()
	_placement_step()
	g._pf_add("names_place", Time.get_ticks_usec() - _pt0)
	# The plates only change with the camera, a hover, or the 10 Hz troop/ease refresh: re-recording every
	# label each frame was the layer's whole cost (about 7 ms a frame with a few hundred nations).
	_redraw_t -= dt
	var cs := Vector3(g.cam.position.x, g.cam.position.y, g.cam.zoom.x)
	if cs != _last_cam or hover_owner != _last_hover or _redraw_t <= 0.0 or _easing:
		_last_cam = cs
		_last_hover = hover_owner
		_redraw_t = REDRAW_S
		queue_redraw()


func _draw() -> void:
	var _pt0 := Time.get_ticks_usec()
	_draw_body()
	g._pf_add("names", Time.get_ticks_usec() - _pt0)


func _draw_body() -> void:
	if g.nations.size() < 2:
		return
	var k := k_lin()
	var now := FrameClock.now()
	var vp := get_viewport_rect().size
	var cull_px := maxf(CULL_MIN_PX, CULL_VW * vp.x)
	var scale_px: float = g.cam.zoom.x * g.TS  # screen px per tile
	var seen := {}
	_easing = false
	for id: int in _targets:
		if id >= g.nations.size() or not _live(id):
			continue
		seen[id] = true
		var t: Array = _targets[id]
		var p: Dictionary
		if not _plates.has(id):
			p = {"sx": t[0], "sy": t[1], "ss": t[2], "tx": t[0], "ty": t[1], "ts": t[2], "t0": now, "rect": Rect2(), "shown": false}
			_plates[id] = p
		else:
			p = _plates[id]
			if t[0] != p.tx or t[1] != p.ty or t[2] != p.ts:
				var a0 := minf(1.0 - exp(-LERP_SPEED * (now - float(p.t0))), 1.0)
				p.sx = p.sx + (p.tx - p.sx) * a0
				p.sy = p.sy + (p.ty - p.sy) * a0
				p.ss = p.ss + (p.ts - p.ss) * a0
				p.tx = t[0]
				p.ty = t[1]
				p.ts = t[2]
				p.t0 = now
		var a := minf(1.0 - exp(-LERP_SPEED * (now - float(p.t0))), 1.0)
		if a < 0.995 and (p.tx != p.sx or p.ty != p.sy or p.ts != p.ss):
			_easing = true
		var wx: float = p.sx + (p.tx - p.sx) * a
		var wy: float = p.sy + (p.ty - p.sy) * a
		var ws: float = p.ss + (p.ts - p.ss) * a
		var base := maxf(1.0, floorf(ws))
		var name_size := maxf(4.0, floorf(base * NAME_SCALE_FACTOR))
		var name_scale := minf(base * 0.25, NAME_SCALE_CAP)
		var line_px := name_size * name_scale / k * scale_px * LINE_K
		if id == int(g.PLAYER):
			line_px = minf(line_px, maxf(OWN_MAX_MIN_PX, vp.y * OWN_MAX_VH))
		var hovered := id == hover_owner
		var sp: Vector2 = g._screen_of(Vector2(wx, wy) * g.TS)
		var m := line_px * 4.0
		# A name shows when upstream would show it, or when it fits inside its own territory on screen
		# (so a territory big enough to hold its name always has it, without every tiny tribe cluttering the map).
		var hysteresis := CULL_HYSTERESIS_PX if p.shown else 0.0
		var cutoff := cull_px - hysteresis
		var fits := false
		if not (line_px >= cutoff or hovered):
			var bbn: Rect2i = g.nations[id].bb
			var eff := maxf(line_px, MIN_LABEL_PX)
			fits = bbn.size != Vector2i.ZERO and float(bbn.size.x) * scale_px * 0.8 >= float(_label_name(id).length()) * eff * 0.55 - hysteresis
			if fits: line_px = eff
		var vis := (line_px >= cutoff or hovered or fits) and sp.x >= -m and sp.y >= -m and sp.x <= vp.x + m and sp.y <= vp.y + m
		p.shown = vis
		if not vis:
			continue
		var n: Dictionary = g.nations[id]
		var text := _label_name(id)
		var o = st.get_owner(id)
		var shade := shade_of(int(o.kind) if o != null else Defs.KIND_NATION)
		var fill := Color(shade, shade, shade)
		var col: Color = st.owner_color(id)
		var px := floorf(line_px * 2.0 + 0.5) / 2.0
		var fs := maxi(1, int(round(px)))
		var tfs := maxi(1, int(round(px * TROOP_SIZE_MULT)))
		var stroke := maxi(1, int(round(maxf(1.0, px * OUTLINE_K) * 2.0)))
		var tstroke := maxi(1, int(round(maxf(1.0, px * OUTLINE_K * TROOP_SIZE_MULT) * 2.0)))
		var top := roundf(sp.y - px * 0.5)
		# Text metrics are cached on the plate: they only change with the text or the font size, and the
		# shaping calls were most of this layer's per-frame cost.
		var tt: String
		if p.get("c_tt_t", -1.0) >= 0.0 and now - float(p.c_tt_t) < TROOP_TEXT_S and p.get("c_tt") != null:
			tt = p.c_tt
		else:
			tt = UITheme.fmt_troops(float(n.get("troops", 0.0)))
			p.c_tt = tt
			p.c_tt_t = now
		if p.get("c_text") != text or p.get("c_fs") != fs or p.get("c_tfs") != tfs or p.get("c_tt_m") != tt:
			p.c_text = text
			p.c_fs = fs
			p.c_tfs = tfs
			p.c_tt_m = tt
			p.c_nw = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			p.c_asc = _font.get_ascent(fs)
			p.c_nh = _font.get_height(fs)
			p.c_tw = _font.get_string_size(tt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs).x
			p.c_tasc = _font.get_ascent(tfs)
			p.c_th = _font.get_height(tfs)
		var nw: float = p.c_nw
		var asc: float = p.c_asc
		var nh: float = p.c_nh
		var tw: float = p.c_tw
		var np := Vector2(roundf(sp.x - nw * 0.5), top + asc)
		draw_string_outline(_font, np, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, stroke, col)
		draw_string(_font, np, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fill)
		var tp := Vector2(roundf(sp.x - tw * 0.5), top + nh + float(p.c_tasc))
		draw_string_outline(_font, tp, tt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, tstroke, col)
		draw_string(_font, tp, tt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, fill)
		var w := maxf(nw, tw)
		p.rect = Rect2(sp.x - w * 0.5, top, w, nh + float(p.c_th))
		if id == crown_owner and _status != null:
			var icon := maxf(line_px * 1.1, CROWN_MIN_PX)
			var src := Rect2(STATUS_PAD, STATUS_PAD, STATUS_CELL - 2 * STATUS_PAD, STATUS_CELL - 2 * STATUS_PAD)
			draw_texture_rect_region(_status, Rect2(roundf(sp.x) - icon * 0.5, roundf(sp.y - line_px * 1.4), icon, icon), src)
	for id2 in _plates.keys():
		if not seen.has(id2):
			_plates.erase(id2)
			_targets.erase(id2)


## Where an owner's name sits, in tiles ([u, v]); null when it has none yet.
func name_location(id: int):
	if not _targets.has(id):
		return null
	return [_targets[id][0], _targets[id][1]]


## The local player's label on screen (tips and banners step around it); null when hidden.
func local_label_rect():
	var p = _plates.get(int(g.PLAYER))
	if p == null or not p.shown:
		return null
	return p.rect
