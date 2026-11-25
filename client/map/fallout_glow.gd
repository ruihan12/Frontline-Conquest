# Port of src/client/Map/FalloutGlow.luau: the glow of fresh fallout on the 2D map.
#   * heat: a tile that turns to fallout is at heat 1, which drains over 25.5 s (the game keeps the
#     fallout's seconds left in fallout_t, 60 at the bomb: heat = (left - 34.5) / 25.5);
#   * the glow is worked out for one tile in every SCALE x SCALE block (its centre tile): a "broil" of
#     two value noises, contrast and intensity mixed from cold to hot by the heat, a slower meta
#     noise over it, all faded in by the heat; and, on some blocks (a hash over the threshold), a dot
#     of light flickering at a rate of its own (extract). Kept in 0..1.
#   * a 5-tap Gaussian blur across and down (BLUR), then laid over the map, linearly filtered, times
#     COVERAGE: one image of the blocks (straight alpha) stretched over the map, under the overlays.
# Worked out on the CPU, redrawn UPDATE_S apart, its noise (the costly part) for as many blocks as
# NOISE_BUDGET_S allows each time, round robin; only what the view can reach is drawn (_win).
# (Upstream's flags_changed hook is game/nukes: sim/arsenal.gd calls on_fallout() per new fallout tile.)
class_name FalloutGlow
extends Control

const SCALE := 8
const BROIL_SPEED_COLD := 0.0018
const BROIL_SPEED_HOT := 0.0
const NOISE_FREQ1 := 0.059
const NOISE_FREQ2 := 0.171
const CONTRAST_LO_COLD := 0.52
const CONTRAST_LO_HOT := 0.0
const CONTRAST_HI_COLD := 1.0
const CONTRAST_HI_HOT := 0.0
const META_FREQ := 0.02
const INTENSITY_COLD := 0.15
const INTENSITY_HOT := 1.8
const META_INFLUENCE_COLD := 1.0
const META_INFLUENCE_HOT := 0.0
const OPACITY_FADE_END := 1.0
const BLOOM := Color(0.054901960784313725, 0.8196078431372549, 0.0)
const COVERAGE := 1.1
const HEAT_SECONDS := 25.5
const HEAT_FLOOR := 34.5
const PARTICLE_DARK := Color(0.05, 0.4, 0.05)
const PARTICLE_BRIGHT := Color(0.2, 1.0, 0.2)
const PARTICLE_THRESHOLD_UNOWNED := 0.85
const PARTICLE_THRESHOLD_OWNED := 0.875
const PARTICLE_FLICKER_SPEED := 0.2
const PARTICLE_STRENGTH := 1.0
const PARTICLE_FRESH_SCALE := 0.2
## the blur's weights: the pixel, then 1 and 2 away
const BLUR := [0.375, 0.25, 0.0625]
const UPDATE_S := 1.0 / 20.0
const DUTY := 8.0
const NOISE_BUDGET_S := 0.0015
const CUSHION := 2
const WIN_MIN := 4

var g  # main.gd
## block -> true (blocks with heat)
var _hot := {}
## block -> [broil noise, meta noise]
var _noise := {}
var _h := {}
var _order: Array = []
var _rr := 0
var _next := 0.0
var _tex: ImageTexture
## the texture's block box (i0, j0, i1, j1), empty when nothing is shown
var _box := Rect2i()
var _bw := 0
var _bh := 0


func _init(main) -> void:
	g = main
	name = "FalloutGlow"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


# ---------------------------------------------------------------------------------------------
# Noise
# ---------------------------------------------------------------------------------------------

static func fract(x: float) -> float:
	return x - floorf(x)


static func smoothstep_(e0: float, e1: float, x: float) -> float:
	if e1 <= e0:
		return 1.0 if x > e0 else 0.0
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func hash3(x: float, y: float, z: float) -> float:
	return fract(sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453)


## Trilinear value noise, smoothstep-faded.
static func vnoise3(px: float, py: float, pz: float) -> float:
	var ix := floorf(px)
	var iy := floorf(py)
	var iz := floorf(pz)
	var fx := px - ix
	var fy := py - iy
	var fz := pz - iz
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	fz = fz * fz * (3.0 - 2.0 * fz)
	var n000 := hash3(ix, iy, iz)
	var n100 := hash3(ix + 1.0, iy, iz)
	var n010 := hash3(ix, iy + 1.0, iz)
	var n110 := hash3(ix + 1.0, iy + 1.0, iz)
	var n001 := hash3(ix, iy, iz + 1.0)
	var n101 := hash3(ix + 1.0, iy, iz + 1.0)
	var n011 := hash3(ix, iy + 1.0, iz + 1.0)
	var n111 := hash3(ix + 1.0, iy + 1.0, iz + 1.0)
	return lerpf(lerpf(lerpf(n000, n100, fx), lerpf(n010, n110, fx), fy), lerpf(lerpf(n001, n101, fx), lerpf(n011, n111, fx), fy), fz)


## A block's dot hashes from its centre tile: [h1 its colour and rate, h2 whether it has one].
static func hashes(cx: float, cy: float) -> Array:
	var tx := cx - 0.5
	var ty := cy - 0.5
	return [fract(sin(tx * 12.9898 + ty * 78.233) * 43758.5453), fract(sin(tx * 63.7 + ty * 157.3) * 23421.631)]


## The glow of a block at heat `heat`, tick `rt`: premultiplied rgba, each in 0..1.
## nz = [broil noise, meta noise], h1 / h2 its hashes.
static func extract(heat: float, rt: float, nz: Array, owned: bool, h1: float, h2: float) -> Color:
	var lo := lerpf(CONTRAST_LO_COLD, CONTRAST_LO_HOT, heat)
	var hi := lerpf(CONTRAST_HI_COLD, CONTRAST_HI_HOT, heat)
	var broil := smoothstep_(lo, hi, nz[0])
	var intensity := lerpf(INTENSITY_COLD, INTENSITY_HOT, heat) * lerpf(1.0, nz[1], lerpf(META_INFLUENCE_COLD, META_INFLUENCE_HOT, heat))
	var opacity := smoothstep_(0.0, OPACITY_FADE_END, heat)
	var s := broil * intensity * opacity
	var r := BLOOM.r * s
	var gg := BLOOM.g * s
	var bb := BLOOM.b * s
	var a := s
	if h2 > (PARTICLE_THRESHOLD_OWNED if owned else PARTICLE_THRESHOLD_UNOWNED):
		var rate := PARTICLE_FLICKER_SPEED * (0.4 + h1 * 1.2)
		var flick := maxf(0.0, sin(rt * rate + h1 * 12.0) * 0.8 + 0.2)
		flick *= flick
		flick *= lerpf(PARTICLE_FRESH_SCALE, 1.0, 1.0 - heat)
		flick *= opacity
		var k := flick * PARTICLE_STRENGTH
		var pr := lerpf(PARTICLE_DARK.r, PARTICLE_BRIGHT.r, h1) * k
		var pg := lerpf(PARTICLE_DARK.g, PARTICLE_BRIGHT.g, h1) * k
		var pb := lerpf(PARTICLE_DARK.b, PARTICLE_BRIGHT.b, h1) * k
		r += pr
		gg += pg
		bb += pb
		a += maxf(pr, maxf(pg, pb))
	return Color(minf(r, 1.0), minf(gg, 1.0), minf(bb, 1.0), minf(a, 1.0))


static func noise_of(cx: float, cy: float, heat: float, rt: float) -> Array:
	var t := rt * lerpf(BROIL_SPEED_COLD, BROIL_SPEED_HOT, heat)
	var n1 := vnoise3(cx * NOISE_FREQ1, cy * NOISE_FREQ1, t)
	var n2 := vnoise3(cx * NOISE_FREQ2, cy * NOISE_FREQ2, t * 1.3)
	var meta := vnoise3(cx * META_FREQ, cy * META_FREQ, t * 0.5)
	return [n1 * 0.6 + n2 * 0.4, meta]


## Blurs one row/column of `n` cells of 4 floats (premultiplied rgba) with the 5-tap weights,
## clamped at the ends.
static func blur_line(src: PackedFloat32Array, dst: PackedFloat32Array, start: int, stride: int, n: int) -> void:
	var w0: float = BLUR[0]
	var w1: float = BLUR[1]
	var w2: float = BLUR[2]
	for i in n:
		var i_m2 := maxi(0, i - 2)
		var i_m1 := maxi(0, i - 1)
		var i_p1 := mini(n - 1, i + 1)
		var i_p2 := mini(n - 1, i + 2)
		var o := (start + i * stride) * 4
		var a := (start + i_m2 * stride) * 4
		var b := (start + i_m1 * stride) * 4
		var c := (start + i_p1 * stride) * 4
		var d := (start + i_p2 * stride) * 4
		for ch in 4:
			dst[o + ch] = src[o + ch] * w0 + (src[c + ch] + src[b + ch]) * w1 + (src[d + ch] + src[a + ch]) * w2


# ---------------------------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------------------------

## sim/arsenal.gd: a tile turned to fallout. A block's centre tile makes the block hot.
func on_fallout(tile: int) -> void:
	var w: int = g.W
	var x := tile % w
	@warning_ignore("integer_division")
	var y := tile / w
	var half := SCALE / 2
	if x % SCALE != half or y % SCALE != half:
		return
	@warning_ignore("integer_division")
	var bw := maxi(1, w / SCALE)
	var b := (y / SCALE) * bw + x / SCALE
	if not _hot.has(b):
		_order.append(b)
	_hot[b] = true
	_noise.erase(b)
	_next = 0.0


func reset() -> void:
	_hot.clear()
	_noise.clear()
	_h.clear()
	_order.clear()
	_box = Rect2i()
	visible = false


func _heat(tile: int) -> float:
	var fall: PackedByteArray = g._render_fallout()
	if fall.size() <= tile or fall[tile] != 1:
		return 0.0
	var left: float = float(g.fallout_t[tile]) - float(g.fallout_tick_t)
	return clampf((left - HEAT_FLOOR) / HEAT_SECONDS, 0.0, 1.0)


func _process(_dt: float) -> void:
	if g == null or _hot.is_empty():
		if _box.size != Vector2i.ZERO:
			_box = Rect2i()
			queue_redraw()
		return
	if g.state == "menu":
		return
	var now := FrameClock.now()
	if now >= _next:
		var t0 := Time.get_ticks_usec()
		_recompute()
		var took := float(Time.get_ticks_usec() - t0) / 1000000.0
		_next = now + maxf(UPDATE_S, took * DUTY)
	queue_redraw()


func _view_blocks() -> Rect2i:
	var vp: Vector2 = g.get_viewport_rect().size
	var a: Vector2 = g.cam.get_screen_center_position() - vp * 0.5 / g.cam.zoom.x
	var b: Vector2 = a + vp / g.cam.zoom.x
	var s: float = float(SCALE) * g.TS
	var c := CUSHION
	var i0 := int(floorf(a.x / s)) - c
	var j0 := int(floorf(a.y / s)) - c
	var i1 := int(floorf(b.x / s)) + c
	var j1 := int(floorf(b.y / s)) + c
	@warning_ignore("integer_division")
	var mi := maxi(WIN_MIN, (i1 - i0 + 1) / 4)
	@warning_ignore("integer_division")
	var mj := maxi(WIN_MIN, (j1 - j0 + 1) / 4)
	return Rect2i(i0 - mi, j0 - mj, (i1 - i0 + 1) + 2 * mi, (j1 - j0 + 1) + 2 * mj)


func _recompute() -> void:
	var W: int = g.W
	var H: int = g.H
	@warning_ignore("integer_division")
	_bw = maxi(1, W / SCALE)
	@warning_ignore("integer_division")
	_bh = maxi(1, H / SCALE)
	var half := SCALE / 2
	var rt: float = float(g.sim_atk.tick) + float(g.tick_acc) * 10.0
	# the hot blocks (the cold ones go) and their box
	var live: Array = []
	var heats := {}
	var i0 := 1 << 30
	var j0 := 1 << 30
	var i1 := -1
	var j1 := -1
	for b: int in _order:
		if not _hot.has(b):
			continue
		var i := b % _bw
		@warning_ignore("integer_division")
		var j := b / _bw
		var tile := (j * SCALE + half) * W + i * SCALE + half
		var heat := _heat(tile)
		if heat <= 0.0:
			_hot.erase(b)
			_noise.erase(b)
			continue
		live.append(b)
		heats[b] = heat
		i0 = mini(i0, i)
		i1 = maxi(i1, i)
		j0 = mini(j0, j)
		j1 = maxi(j1, j)
	_order = live
	if live.is_empty():
		_box = Rect2i()
		return
	# the noise: as many blocks as the budget allows, round robin; a block without any first
	var deadline := Time.get_ticks_usec() + int(NOISE_BUDGET_S * 1000000.0)
	var n := live.size()
	var spent := false
	var start := _rr % n
	for k in n:
		var b: int = live[(start + k) % n]
		var has := _noise.has(b)
		if has and spent:
			continue
		if has and Time.get_ticks_usec() > deadline:
			spent = true
			continue
		var cx := float((b % _bw) * SCALE + half) + 0.5
		@warning_ignore("integer_division")
		var cy := float((b / _bw) * SCALE + half) + 0.5
		_noise[b] = noise_of(cx, cy, float(heats[b]), rt)
		_rr = (start + k + 1) % n
	# what is drawn (R): the box, 2 blocks of blur either side, inside the image and the window
	var win := _view_blocks()
	var ri0 := maxi(0, maxi(i0 - 2, win.position.x))
	var rj0 := maxi(0, maxi(j0 - 2, win.position.y))
	var ri1 := mini(_bw - 1, mini(i1 + 2, win.end.x - 1))
	var rj1 := mini(_bh - 1, mini(j1 + 2, win.end.y - 1))
	if ri1 < ri0 or rj1 < rj0:
		_box = Rect2i()
		return
	var ki0 := maxi(0, ri0 - 2)
	var kj0 := maxi(0, rj0 - 2)
	var ki1 := mini(_bw - 1, ri1 + 2)
	var kj1 := mini(_bh - 1, rj1 + 2)
	var kw := ki1 - ki0 + 1
	var kh := kj1 - kj0 + 1
	var grid := PackedFloat32Array()
	grid.resize(kw * kh * 4)
	grid.fill(0.0)
	for b: int in live:
		var i := b % _bw
		@warning_ignore("integer_division")
		var j := b / _bw
		if i < ki0 or i > ki1 or j < kj0 or j > kj1:
			continue
		var tile := (j * SCALE + half) * W + i * SCALE + half
		var owned: bool = g._render_owners()[tile] > 0
		var hh: Array = _h.get(b, [])
		if hh.is_empty():
			hh = hashes(float(i * SCALE + half) + 0.5, float(j * SCALE + half) + 0.5)
			_h[b] = hh
		var c := extract(float(heats[b]), rt, _noise[b], owned, hh[0], hh[1])
		var o := ((j - kj0) * kw + (i - ki0)) * 4
		grid[o] = c.r
		grid[o + 1] = c.g
		grid[o + 2] = c.b
		grid[o + 3] = c.a
	# blur across, then down
	var tmp := PackedFloat32Array()
	tmp.resize(kw * kh * 4)
	for y in kh:
		blur_line(grid, tmp, y * kw, 1, kw)
	var blurred := PackedFloat32Array()
	blurred.resize(kw * kh * 4)
	for x in kw:
		blur_line(tmp, blurred, x, kw, kh)
	# R out of K, premultiplied to straight alpha
	var w := ri1 - ri0 + 1
	var h := rj1 - rj0 + 1
	var out := PackedByteArray()
	out.resize(w * h * 4)
	out.fill(0)
	for y in h:
		for x in w:
			var o := ((y + rj0 - kj0) * kw + (x + ri0 - ki0)) * 4
			var a := minf(1.0, blurred[o + 3] * COVERAGE)
			if a > 0.002:
				var p := (y * w + x) * 4
				out[p] = mini(255, int(minf(1.0, blurred[o] * COVERAGE) / a * 255.0 + 0.5))
				out[p + 1] = mini(255, int(minf(1.0, blurred[o + 1] * COVERAGE) / a * 255.0 + 0.5))
				out[p + 2] = mini(255, int(minf(1.0, blurred[o + 2] * COVERAGE) / a * 255.0 + 0.5))
				out[p + 3] = int(a * 255.0 + 0.5)
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out)
	if _tex == null or _tex.get_width() != w or _tex.get_height() != h:
		_tex = ImageTexture.create_from_image(img)
	else:
		_tex.update(img)
	_box = Rect2i(ri0, rj0, w, h)


func _draw() -> void:
	var _pt0 := Time.get_ticks_usec()
	_draw_body()
	g._pf_add("fallout", Time.get_ticks_usec() - _pt0)


func _draw_body() -> void:
	if _tex == null or _box.size == Vector2i.ZERO or g == null or g.state == "menu":
		return
	var s: float = float(SCALE) * g.TS
	var tl: Vector2 = g._screen_of(Vector2(_box.position) * s)
	var br: Vector2 = g._screen_of(Vector2(_box.end) * s)
	draw_texture_rect(_tex, Rect2(tl, br - tl), false)
