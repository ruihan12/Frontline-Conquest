# Port of src/client/Map/NameLayer.luau: owner names and troop counts on the map.
#   * placement (_place): a coarse grid over the owner's box (scaling factor 1..32 by the box's
#     size) where a cell is usable if it is the owner's tile (this game: upstream also allows a
#     shoreline tile, shallow sea or fallout, so names spilled over the water and nuked ground); the largest inscribed rectangle of that grid; the name sits at its centre, raised
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
# Port differences: upstream flood-fills the owner's main cluster for the box; this port's game
# already keeps a bounding box per nation (nations[id].bb), which is used instead (a far island
# widens the box, the largest rectangle is still found on the main land). Flags, faces and the
# HUMAN badge come from Roblox cosmetics and accounts and are left out.
class_name NameLayer
extends Control

const NAME_SCALE_FACTOR := 0.4
const NAME_SCALE_CAP := 3.0
const TROOP_SIZE_MULT := 0.6
const LERP_SPEED := 10.0
const CULL_VW := 0.004
const CULL_MIN_PX := 6.0
const SHADE_NATION := 0.3
const SHADE_BOT := 0.4
## outline px per text px
const OUTLINE_K := 0.085
const REPLACE_TICKS := 30
## full-size tiles
const SPAWN_DIAMETER := 8
const BUDGET_S := 0.0015
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
var _font: Font
var _status: Texture2D


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


## Where an owner's name goes: [u, v, font size] in tiles, or null.
func _place(id: int):
	var n: Dictionary = g.nations[id]
	if int(n.get("land", 0)) <= 0:
		return null
	var W: int = g.W
	var H: int = g.H
	var k := k_lin()
	var bb: Rect2i = n.get("bb", Rect2i())
	if bb.size.x <= 0 or bb.size.y <= 0:
		return null
	var x0 := clampi(bb.position.x, 0, W - 1)
	var y0 := clampi(bb.position.y, 0, H - 1)
	var x1 := clampi(bb.end.x - 1, 0, W - 1)
	var y1 := clampi(bb.end.y - 1, 0, H - 1)
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
	var cd: PackedInt32Array = g.coast_dist
	var fall: PackedByteArray = g.fallout
	var has_cd := cd.size() == own.size()
	var has_fall := fall.size() == own.size()
	var water: int = g.WATER
	var best := 0
	var bx := 0
	var by := 0
	var bw := 0
	var bh := 0
	for gy in gh:
		var ty := (gy0 + gy) * sf
		for gx in gw:
			var t := ty * W + (gx0 + gx) * sf
			var o := own[t]
			# (this game: only the owner's own land; upstream also lets a name spill over shoreline, shallow
			# sea and fallout)
			var usable := o == id
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


func _place_spawn(id: int):
	var n: Dictionary = g.nations[id]
	if int(n.get("land", 0)) <= 0:
		return null
	var k := k_lin()
	var d := float(SPAWN_DIAMETER)
	var fs := font_size(d, d, _label_name(id))
	var land := maxf(1.0, float(n.land))
	return [floorf(float(n.sx) / land) + 0.5, floorf(float(n.sy) / land) + 0.5 - fs / 3.0 / k, fs]


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
	if tick - _last_place_tick >= REPLACE_TICKS or tick < _last_place_tick or ph != _last_phase or now_s - _last_place_s > 3.0:
		_last_place_tick = tick
		_last_phase = ph
		_last_place_s = now_s
		_refresh_queue()
	var t0 := Time.get_ticks_usec()
	# new owners at once
	for id in range(1, g.nations.size()):
		if _live(id) and not _targets.has(id):
			var t = _place_spawn(id) if spawn else _place(id)
			if t != null:
				_targets[id] = t
	# the rest a little every frame (upstream: a cooperative job with a time budget)
	while not _queue.is_empty() and Time.get_ticks_usec() - t0 < int(BUDGET_S * 1e6):
		var id2: int = _queue.pop_back()
		if id2 >= g.nations.size() or not _live(id2):
			continue
		var t2 = _place_spawn(id2) if spawn else _place(id2)
		if t2 != null:
			_targets[id2] = t2


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
		var vis := (line_px >= cull_px or hovered) and sp.x >= -m and sp.y >= -m and sp.x <= vp.x + m and sp.y <= vp.y + m
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
		var nw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var asc := _font.get_ascent(fs)
		var nh := _font.get_height(fs)
		var np := Vector2(roundf(sp.x - nw * 0.5), top + asc)
		draw_string_outline(_font, np, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, stroke, col)
		draw_string(_font, np, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fill)
		var tt := UITheme.fmt_troops(float(n.get("troops", 0.0)))
		var tw := _font.get_string_size(tt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs).x
		var tp := Vector2(roundf(sp.x - tw * 0.5), top + nh + _font.get_ascent(tfs))
		draw_string_outline(_font, tp, tt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, tstroke, col)
		draw_string(_font, tp, tt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, fill)
		var w := maxf(nw, tw)
		p.rect = Rect2(sp.x - w * 0.5, top, w, nh + _font.get_height(tfs))
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
