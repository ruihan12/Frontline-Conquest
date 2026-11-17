# Port of src/client/Map/FxLayer.luau: effects on the map.
#   * rings: a nuke's shockwave grows to 1.5 x its blast radius over 1.5 s behind a white flash; a
#     destroyed ship / shot-down nuke pops a small ring (0.8 s); a destroyed defensive structure a
#     short orange one;
#   * sprite bursts from the MapFx atlas (explosion, SAM hit, building collapse) and the looping
#     debris of a nuke (fire, smoke) fading out over 6 s;
#   * conquests by the local player: a victory flag planted at the conquered name's location, its
#     banner the conqueror's colour (10 frames of 24 x 24 at 90 ms, 12 full-size tiles wide, 2.5 s,
#     fade in over the first 10 % and out after 60 %), and a white "+ 12.3K" gold line below it;
#   * income: gold earned at a tile is a white "+ 25.0K" that rises and fades over 1.5 s.
# Flags and gold lines keep a minimum on-screen size, so a zoomed-out map still shows them.
#
# Live in this port: the conquest flag and the building collapse. The nuke, SAM and ship effects
# and the income notes are still drawn by the game's own code (game/planes_fx.gd, which already
# follows this file's atlas and timings); nuke(), pop() and bonus() are here for when they move.
class_name FxLayer
extends Control

const NUKE_SHOCK_S := 1.5
const NUKE_SHOCK_K := 1.5
const POP_S := 0.8
## full-size tiles (the ring of a ship or nuke shot down)
const POP_RADIUS := 40.0
const CONQUEST_S := 2.5
const CONQUEST_FADE_IN := 0.1
const CONQUEST_FADE_OUT := 0.6
## MapFx atlas rows: x, y, w, h, frames
const FLAG := {"x": 0, "y": 60, "w": 24, "h": 24, "frames": 10}
const BANNER := {"x": 0, "y": 84, "w": 24, "h": 24, "frames": 10}
const FLAG_FRAME_S := 0.09
const FLAG_WORLD := 12.0
const FLAG_MIN_PX := 24.0
const BANNER_MIN_LUMA := 0.32
const BANNER_LIFT := 0.3
## full-size tiles below the name
const GOLD_Y_OFFSET := 8.0
const GOLD_SIZE := 6.0
const GOLD_MIN_PX := 15.0
const BONUS_S := 1.5
const BONUS_RISE := 3.0
const BONUS_Y_OFFSET := -3.0
const BONUS_SIZE := 6.0
const BONUS_MIN_PX := 13.0
const BONUS_MAX_PX := 40.0
const BONUS_CULL_ZOOM := 0.3
const BONUS_MAX := 48
## name -> {y, w, h, frames, frame_s, world (full-size tiles wide), min_px, loop}
const BURSTS := {
	"building": {"y": 146, "w": 17, "h": 15, "frames": 10, "frame_s": 0.07, "world": 18.0, "min_px": 32.0, "loop": false},
	"sam": {"y": 108, "w": 48, "h": 38, "frames": 9, "frame_s": 0.08, "world": 40.0, "min_px": 60.0, "loop": false},
	"nuke": {"y": 0, "w": 60, "h": 60, "frames": 12, "frame_s": 0.07, "world": 60.0, "min_px": 36.0, "loop": false},
	"fire": {"y": 161, "w": 7, "h": 13, "frames": 6, "frame_s": 0.1, "world": 7.0, "min_px": 4.0, "loop": true},
	"smoke": {"y": 174, "w": 11, "h": 12, "frames": 4, "frame_s": 0.12, "world": 11.0, "min_px": 6.0, "loop": true},
	"big_smoke": {"y": 186, "w": 24, "h": 16, "frames": 5, "frame_s": 0.12, "world": 24.0, "min_px": 12.0, "loop": true},
	"smoke_fire": {"y": 202, "w": 24, "h": 16, "frames": 5, "frame_s": 0.12, "world": 24.0, "min_px": 12.0, "loop": true},
}
## the look of each nuke kind (Defs.N_*), in full-size tiles
const NUKE_FX_RADIUS := {0: 70.0, 1: 160.0, 3: 70.0, 4: 120.0, 5: 70.0}
const DEBRIS_PLAN := [
	{"kind": "fire", "factor": 1.0, "density": 1.0 / 25.0},
	{"kind": "smoke", "factor": 1.0, "density": 1.0 / 28.0},
	{"kind": "big_smoke", "factor": 0.9, "density": 1.0 / 70.0},
	{"kind": "smoke_fire", "factor": 0.9, "density": 1.0 / 70.0},
]
## s each debris sprite lasts
const DEBRIS_S := 6.0
const DEBRIS_FADE_IN := 0.1
const DEBRIS_FADE_OUT := 0.8
const BURST_MAX := 96
const DEBRIS_MAX := 240
const WARHEAD_DEBRIS := 28.0
const WARHEAD_WINDOW_S := 10.0
## nukes that land flat: a plain ring, no fireball (shell, air strike, slug)
const NUKE_FLAT := [6, 7, 8]

var g  # main.gd
var st: RWGameState
var _fx: Array = []  # {u, v, r0, r1, t0, dur, col, flash}
var _pops: Array = []  # {u, v, t0, text, col}
var _bonus: Array = []  # {u, v, t0, text}
var _bursts: Array = []  # {u, v, t0, row}
var _debris: Array = []  # {u, v, t0, row, life, fade_in, fade_out}
var _warheads_landed: Array[float] = []
var _tex: Texture2D
var _font: Font


func _init(main, state: RWGameState) -> void:
	g = main
	st = state
	name = "Fx"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_tex = load("res://assets/rw/map_fx/map_fx.png")
	_font = UITheme.font(700.0)


func unbind() -> void:
	_fx.clear()
	_pops.clear()
	_bonus.clear()
	_bursts.clear()
	_debris.clear()
	_warheads_landed.clear()


func k_lin() -> float:
	return maxf(0.01, float(st.map.k_lin))


func _add(tile: int, r0: float, r1: float, dur: float, col: Color, flash: bool) -> void:
	if tile < 0:
		return
	var w: int = st.map.W
	@warning_ignore("integer_division")
	_fx.append({"u": tile % w + 0.5, "v": tile / w + 0.5, "r0": r0, "r1": r1, "t0": FrameClock.now(), "dur": dur, "col": col, "flash": flash})


static func _imul(a: int, b: int) -> int:
	return (a * b) & 0xffffffff


## A repeatable random number in [0, 1) for `seed` (the same on every client).
static func seeded_random(seed_v: int) -> float:
	var s := (seed_v + 0x6d2b79f5) & 0xffffffff
	var t := _imul(s ^ (s >> 15), 1 | s)
	t = (((t + _imul(t ^ (t >> 7), 61 | t)) & 0xffffffff) ^ t) & 0xffffffff
	return float((t ^ (t >> 14)) & 0xffffffff) / 4294967296.0


## Where a nuke's debris sprites go: [{kind, du, dv}] in tiles from the impact.
static func debris_plan(tile: int, radius: float, k: float) -> Array:
	var out := []
	var idx := 0
	for d: Dictionary in DEBRIS_PLAN:
		var count := maxi(0, int(floor(radius * float(d.density))))
		var r: float = radius * float(d.factor)
		for _i in count:
			var seed_v := tile * 997 + idx
			idx += 1
			var angle := seeded_random(seed_v) * TAU
			var dist := seeded_random(seed_v + 0x10000) * (r / 2.0)
			out.append({"kind": d.kind, "du": floorf(cos(angle) * dist) / k, "dv": floorf(sin(angle) * dist) / k})
	return out


## A MIRV's warheads share one budget of debris, so a full volley does not bury the map in smoke.
func _warhead_debris(tile: int) -> bool:
	var now := FrameClock.now()
	while not _warheads_landed.is_empty() and now - _warheads_landed[0] > WARHEAD_WINDOW_S:
		_warheads_landed.remove_at(0)
	_warheads_landed.append(now)
	var flying := 0
	for m in st.nukes().values():
		if int(m.kind) == Defs.N_WARHEAD:
			flying += 1
	var p := WARHEAD_DEBRIS / maxf(1.0, _warheads_landed.size() + flying)
	return seeded_random(tile * 31 + 7) < p


## A nuke of `kind` (Defs.N_*) landed on `tile` with blast radius `radius` (tiles).
func nuke(kind: int, tile: int, radius: float) -> void:
	if kind == Defs.N_MIRV:
		return
	var r := radius
	var outer: float = ViewRules.nuke_radii(kind).y
	if outer > 0.0:
		r = outer
	if NUKE_FLAT.has(kind):
		var col := Color(0.75, 0.6, 1.0) if kind == 8 else Color(1.0, 0.72, 0.35)
		_add(tile, 0.0, maxf(r, 2.5) * 1.15, 0.45 if kind == 6 else 0.8, col, false)
		return
	var k := k_lin()
	var look = NUKE_FX_RADIUS.get(kind)
	_add(tile, 0.0, (float(look) / k if look != null else r) * NUKE_SHOCK_K, NUKE_SHOCK_S, Color(1.0, 0.92, 0.75), kind != Defs.N_WARHEAD)
	if look != null and tile >= 0:
		var w: int = st.map.W
		var u := tile % w + 0.5
		@warning_ignore("integer_division")
		var v := tile / w + 0.5
		burst("nuke", u, v)
		if kind != Defs.N_WARHEAD or _warhead_debris(tile):
			var now := FrameClock.now()
			for d: Dictionary in debris_plan(tile, float(look), k):
				if _debris.size() >= DEBRIS_MAX:
					break
				_debris.append({"u": u + float(d.du), "v": v + float(d.dv), "t0": now, "row": BURSTS[d.kind], "life": DEBRIS_S, "fade_in": DEBRIS_FADE_IN, "fade_out": DEBRIS_FADE_OUT})


## The small ring of a destroyed ship or a nuke shot down.
func pop(tile: int, col: Color = Color(1.0, 0.6, 0.25)) -> void:
	_add(tile, 0.0, POP_RADIUS / k_lin() * 0.25, POP_S, col, false)


func burst(kind: String, u: float, v: float) -> void:
	if not BURSTS.has(kind) or _bursts.size() >= BURST_MAX:
		return
	_bursts.append({"u": u, "v": v, "t0": FrameClock.now(), "row": BURSTS[kind]})


## A structure of kind `kind` (Defs.S_*) on `tile` was destroyed: defensive ones collapse.
func on_structure_removed(kind: int, tile: int) -> void:
	if not (kind == Defs.S_DEFENSE or kind >= Defs.S_ARTILLERY):
		return
	var w: int = st.map.W
	@warning_ignore("integer_division")
	burst("building", tile % w + 0.5, tile / w + 0.5)
	_add(tile, 0.0, 14.0 / k_lin(), 0.5, Color(1.0, 0.7, 0.3), false)


static func format_gold(gold: float) -> String:
	if gold >= 1000000000.0:
		return UITheme.big(gold)
	if gold >= 1000000.0:
		return "%.1fM" % (floorf(gold / 1000000.0 * 10.0 + 0.5) / 10.0)
	if gold >= 1000.0:
		return "%.1fK" % (floorf(gold / 1000.0 * 10.0 + 0.5) / 10.0)
	return str(int(floor(gold)))


## A dark owner colour is lifted toward white so the banner reads on the map.
static func banner_color(c: Color) -> Color:
	var luma := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	return c.lerp(Color.WHITE, BANNER_LIFT) if luma < BANNER_MIN_LUMA else c


## The local player conquered an owner whose name was at (u, v) and took `gold`.
func conquest(u: float, v: float, gold: float) -> void:
	_pops.append({"u": u, "v": v, "t0": FrameClock.now(), "text": "+ " + format_gold(gold), "col": banner_color(st.owner_color(st.local_owner))})


## Gold the local player earned at `tile`.
func bonus(tile: int, gold: float) -> void:
	if tile < 0 or gold <= 0.0:
		return
	var w: int = st.map.W
	if _bonus.size() >= BONUS_MAX:
		_bonus.remove_at(0)
	@warning_ignore("integer_division")
	_bonus.append({"u": tile % w + 0.5, "v": tile / w + 0.5, "t0": FrameClock.now(), "text": "+ " + format_gold(gold)})


func _process(_dt: float) -> void:
	if _fx.is_empty() and _pops.is_empty() and _bonus.is_empty() and _bursts.is_empty() and _debris.is_empty():
		return
	queue_redraw()


func _screen(u: float, v: float) -> Vector2:
	return g._screen_of(Vector2(u, v) * g.TS)


func _on_screen(p: Vector2, m: float) -> bool:
	var vp := size
	return p.x >= -m and p.y >= -m and p.x <= vp.x + m and p.y <= vp.y + m


func _draw() -> void:
	var now := FrameClock.now()
	var scale_px: float = g.cam.zoom.x * g.TS
	var k := k_lin()
	# rings
	var keep := []
	for fx: Dictionary in _fx:
		var t: float = (now - float(fx.t0)) / float(fx.dur)
		if t >= 1.0:
			continue
		keep.append(fx)
		var p := _screen(fx.u, fx.v)
		var e := 1.0 - pow(1.0 - t, 3.0)
		var r: float = (float(fx.r0) + (float(fx.r1) - float(fx.r0)) * e) * scale_px
		if r < 0.5 or not _on_screen(p, r):
			continue
		var col: Color = fx.col
		# the flash fills the disc early on; the ring stays
		var fill_t := clampf(0.25 + t * 3.0, 0.0, 1.0) if fx.flash else 0.8 + 0.2 * t
		if fill_t < 0.999:
			draw_circle(p, r, Color(col, 1.0 - fill_t))
		draw_arc(p, r, 0.0, TAU, clampi(int(r * 0.6), 24, 128), Color(col, 1.0 - t), maxf(1.5, r * 0.04), true)
	_fx = keep
	_draw_pops(now, scale_px, k)
	_bursts = _draw_bursts(_bursts, now, scale_px, k)
	# (the debris over the fireball)
	_debris = _draw_bursts(_debris, now, scale_px, k)
	_draw_bonus(now, scale_px, k)


func _draw_pops(now: float, scale_px: float, k: float) -> void:
	var keep := []
	for p: Dictionary in _pops:
		var el: float = now - float(p.t0)
		if el >= CONQUEST_S:
			continue
		keep.append(p)
		var c := _screen(p.u, p.v)
		var sw := maxf(FLAG_MIN_PX, FLAG_WORLD / k * scale_px)
		if not _on_screen(c, sw * 2.0):
			continue
		var t := el / CONQUEST_S
		var a := 1.0
		if t < CONQUEST_FADE_IN:
			a = t / CONQUEST_FADE_IN
		elif t > CONQUEST_FADE_OUT:
			a = (1.0 - t) / (1.0 - CONQUEST_FADE_OUT)
		var frame := mini(int(floor(el / FLAG_FRAME_S)), int(FLAG.frames) - 1)
		var sh := sw * float(FLAG.h) / float(FLAG.w)
		var dst := Rect2(c - Vector2(sw, sh) * 0.5, Vector2(sw, sh))
		draw_texture_rect_region(_tex, dst, Rect2(int(FLAG.x) + frame * int(FLAG.w), FLAG.y, FLAG.w, FLAG.h), Color(1, 1, 1, a))
		draw_texture_rect_region(_tex, dst, Rect2(int(BANNER.x) + frame * int(BANNER.w), BANNER.y, BANNER.w, BANNER.h), Color(p.col, a))
		var fs := maxf(GOLD_MIN_PX, GOLD_SIZE / k * scale_px)
		var gy := maxf(sw * GOLD_Y_OFFSET / FLAG_WORLD, sw * 0.42 + fs * 0.5)
		_text_centred(Vector2(c.x, c.y + gy), p.text, int(minf(fs, 100.0)), 1.0 - t)
	_pops = keep


func _text_centred(at: Vector2, text: String, fs: int, alpha: float) -> void:
	var sz := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pos := Vector2(at.x - sz.x * 0.5, at.y + (_font.get_ascent(fs) - _font.get_descent(fs)) * 0.5)
	var stroke := maxi(2, int(round(maxf(1.5, fs * 0.12) * 2.0)))
	draw_string_outline(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, stroke, Color(0, 0, 0, alpha))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, alpha))


func _draw_bursts(list: Array, now: float, scale_px: float, k: float) -> Array:
	var keep := []
	for b: Dictionary in list:
		var row: Dictionary = b.row
		var el: float = now - float(b.t0)
		var frame := int(floor(el / float(row.frame_s)))
		var a := 1.0
		if b.has("life"):
			if el >= float(b.life):
				continue
			if row.loop:
				frame %= int(row.frames)
			var t := el / float(b.life)
			if t < float(b.get("fade_in", 0.0)):
				a = t / float(b.fade_in)
			elif t > float(b.get("fade_out", 1.0)):
				a = (1.0 - t) / (1.0 - float(b.fade_out))
		elif frame >= int(row.frames):
			continue
		keep.append(b)
		frame = mini(frame, int(row.frames) - 1)
		var c := _screen(b.u, b.v)
		var w := maxf(float(row.min_px), float(row.world) / k * scale_px)
		if not _on_screen(c, w):
			continue
		var h := w * float(row.h) / float(row.w)
		draw_texture_rect_region(_tex, Rect2(c - Vector2(w, h) * 0.5, Vector2(w, h)), Rect2(frame * int(row.w), row.y, row.w, row.h), Color(1, 1, 1, a))
	return keep


func _draw_bonus(now: float, scale_px: float, k: float) -> void:
	var zoom := scale_px / k  # px per full-size tile
	var keep := []
	for b: Dictionary in _bonus:
		var el: float = now - float(b.t0)
		if el >= BONUS_S:
			continue
		keep.append(b)
		if zoom < BONUS_CULL_ZOOM:
			continue
		var fs := clampf(BONUS_SIZE * zoom, BONUS_MIN_PX, BONUS_MAX_PX)
		var unit := fs / BONUS_SIZE
		var c := _screen(b.u, b.v)
		c.y += (BONUS_Y_OFFSET - BONUS_RISE * el) * unit
		if not _on_screen(c, fs * 4.0):
			continue
		_text_centred(c, b.text, int(fs), 1.0 - el / BONUS_S)
	_bonus = keep
