# Port of src/client/Map/MapCamera.luau: the flat-map camera.
# A centre (cu, cv) in tiles and a scale in screen px per tile; smooth zoom toward a held map
# point, drag with inertia, a centre clamp that lets small maps float and large ones stop at their
# edges, eased focus glides with a zoom-out bump on long hops, the title's slow drift, and shake.
#
# This port draws the map with a Godot Camera2D: main.gd copies cu / cv / scale to it every frame
# (position = centre * TS, zoom = scale / TS). The globe helpers (latlon_to_map, xyz_to_map,
# distance_to_scale) are kept for completeness.
class_name MapCamera
extends RefCounted

## px per tile at a 900 px tall viewport
const MAX_SCALE_900 := 44.0
const FIT_MARGIN := 0.9
const ZOOM_TAU := 0.07
const INERTIA_DECAY := 0.004
const INERTIA_HOLD_MS := 90.0
## A map axis shorter than this share of the screen is centred; between this and 1 it eases out.
const CENTRE_FROM := 0.75
const DIST_K := 0.0044

var W := 2000
var H := 1000
var cu := 1000.0
var cv := 500.0
var scale := 2.0
var target_scale := 2.0
var screen_offset := Vector2.ZERO
var dragging := false
var attract := false
var version := 0
var lat := 0.0
var lon := 0.0
var _vel := Vector2.ZERO
var _last_drag_ms := 0.0
var _has_anchor := false
var _anchor_map := Vector2.ZERO
var _anchor_screen := Vector2.ZERO
var _focus_active := false
var _focus_t := 0.0
var _focus_dur := 1.0
var _focus_from := Vector3.ZERO
var _focus_to := Vector3.ZERO
var _shake := 0.0
var _shake_px := Vector2.ZERO
var _vp := Vector2(1600, 900)
var _drift := 1.0


static func now_ms() -> float:
	return FrameClock.now() * 1000.0


func _init(w: int = 2000, h: int = 1000, vp: Vector2 = Vector2(1600, 900)) -> void:
	_vp = vp
	W = w
	H = h
	cu = w * 0.5
	cv = h * 0.5
	scale = min_scale()
	target_scale = scale


func set_map(w: int, h: int) -> void:
	if w == W and h == H:
		return
	W = w
	H = h
	cu = w * 0.5
	cv = h * 0.5
	halt()
	scale = min_scale()
	target_scale = scale
	_clamp()
	_bump()


## (upstream reads the Roblox camera's viewport; here the host passes it in)
func set_viewport(v: Vector2) -> bool:
	if v.x > 1 and v.y > 1 and v != _vp:
		_vp = v
		return true
	return false


func viewport_size() -> Vector2:
	return _vp


func viewport_height() -> float:
	return _vp.y


func min_scale() -> float:
	return minf(_vp.x / W, _vp.y / H) * FIT_MARGIN


func max_scale() -> float:
	return maxf(MAX_SCALE_900 * maxf(_vp.y, 300.0) / 900.0, min_scale() * 2.0)


func clamp_scale(s: float) -> float:
	return clampf(s, min_scale(), max_scale())


## The screen point the centre (cu, cv) is drawn at.
func anchor_px() -> Vector2:
	return _vp * 0.5 + screen_offset + _shake_px


func map_to_screen(u: float, v: float) -> Vector2:
	var a := anchor_px()
	return Vector2(a.x + (u - cu) * scale, a.y + (v - cv) * scale)


func screen_to_map(x: float, y: float) -> Vector2:
	var a := anchor_px()
	return Vector2(cu + (x - a.x) / scale, cv + (y - a.y) / scale)


func tile_at_screen(pos: Vector2) -> int:
	var m := screen_to_map(pos.x, pos.y)
	if m.y < 0 or m.y >= H or m.x < 0 or m.x >= W:
		return -1
	return int(floor(m.y)) * W + int(floor(m.x))


func tile_to_screen(tile: int) -> Vector2:
	@warning_ignore("integer_division")
	return map_to_screen(tile % W + 0.5, tile / W + 0.5)


func latlon_to_map(la: float, lo: float) -> Vector2:
	return Vector2((lo + 180.0) / 360.0 * W, (90.0 - la) / 180.0 * H)


func on_screen(x: float, y: float, margin: float = 0.0) -> bool:
	return x >= -margin and y >= -margin and x <= _vp.x + margin and y <= _vp.y + margin


## The visible part of the map in tiles: Rect2(u0, v0, u1 - u0, v1 - v0).
func visible_rect() -> Rect2:
	var a := anchor_px()
	var p0 := Vector2(cu - a.x / scale, cv - a.y / scale)
	var p1 := Vector2(cu + (_vp.x - a.x) / scale, cv + (_vp.y - a.y) / scale)
	return Rect2(p0, p1 - p0)


func tiles_per_px() -> float:
	return 1.0 / scale


func deg_per_px() -> float:
	return 180.0 / H / scale


## One axis of the centre clamp: `before` / `after` are the tiles the screen shows on each side of
## the centre.
static func clamp_axis(c: float, size: float, before: float, after: float) -> float:
	var span := before + after
	if is_inf(span) or is_nan(span):
		return size * 0.5
	var centre := (size - after + before) * 0.5
	var t := clampf((span / size - CENTRE_FROM) / (1.0 - CENTRE_FROM), 0.0, 1.0)
	var lo := centre * t
	var hi := maxf(lo, size + (centre - size) * t)
	return clampf(c, lo, hi)


func _clamp() -> void:
	var a := anchor_px()
	cv = clamp_axis(cv, H, a.y / scale, (_vp.y - a.y) / scale)
	cu = clamp_axis(cu, W, a.x / scale, (_vp.x - a.x) / scale)


func _bump() -> void:
	version += 1
	lat = 90.0 - cv / H * 180.0
	lon = cu / W * 360.0 - 180.0


func distance_to_scale(d: float) -> float:
	var alt := maxf(d - 1.0, 0.02)
	return clamp_scale(DIST_K * _vp.y / alt)


func scale_to_distance(s: float) -> float:
	return 1.0 + DIST_K * _vp.y / maxf(s, 1e-3)


func begin_drag() -> void:
	dragging = true
	_focus_active = false
	_has_anchor = false
	_vel = Vector2.ZERO


func drag_by(rel: Vector2) -> void:
	var s := scale
	cu -= rel.x / s
	cv -= rel.y / s
	var now := now_ms()
	var dt := maxf((now - _last_drag_ms) / 1000.0, 1.0 / 240.0)
	if now - _last_drag_ms < 100.0:
		var v := Vector2(-rel.x / s, -rel.y / s) / dt
		_vel = _vel.lerp(v, 0.5)
	else:
		_vel = Vector2.ZERO
	_last_drag_ms = now
	_clamp()
	_bump()


func end_drag() -> void:
	dragging = false
	if now_ms() - _last_drag_ms > INERTIA_HOLD_MS:
		_vel = Vector2.ZERO
	var cap := 2.5 * _vp.x / scale
	if _vel.length() > cap:
		_vel = _vel.normalized() * cap


func is_moving(px_per_s: float) -> bool:
	if _focus_active:
		return true
	if dragging:
		return false
	return _vel.length() * scale > px_per_s


func halt() -> void:
	dragging = false
	_vel = Vector2.ZERO
	_focus_active = false
	target_scale = scale
	_has_anchor = false


func pan(dir: Vector2, amount: float) -> void:
	_focus_active = false
	var px := dir * amount * _vp.y
	cu += px.x / scale
	cv += px.y / scale
	_clamp()
	_bump()


## The map point under a screen point, held inside the map.
func globe_hit(screen_pos: Vector2) -> Vector2:
	var m := screen_to_map(screen_pos.x, screen_pos.y)
	return Vector2(clampf(m.x, 0, W), clampf(m.y, 0, H))


## Zoom by `factor`, easing; with `anchor` (a map point, from globe_hit) that point stays under
## the same screen point while the zoom settles.
func zoom_by(factor: float, anchor = null) -> void:
	if factor <= 0.0:
		return
	_focus_active = false
	target_scale = clamp_scale(target_scale * factor)
	if anchor is Vector2:
		_anchor_map = anchor
		_anchor_screen = map_to_screen(anchor.x, anchor.y)
		_has_anchor = true
	else:
		_has_anchor = false


func set_scale_immediate(s: float) -> void:
	scale = clamp_scale(s)
	target_scale = scale
	_has_anchor = false
	_clamp()
	_bump()


func look_at(u: float, v: float) -> void:
	cu = u
	cv = v
	_clamp()
	_bump()


## Glide to (u, v); `to_scale` <= 0 keeps the zoom.
func focus(u: float, v: float, to_scale: float, duration: float) -> void:
	var s1 := clamp_scale(to_scale) if to_scale > 0 else scale
	_focus_from = Vector3(cu, cv, scale)
	_focus_to = Vector3(u, v, s1)
	_focus_dur = maxf(duration, 0.01)
	_focus_t = 0.0
	_focus_active = true
	_vel = Vector2.ZERO
	_has_anchor = false
	target_scale = s1


func focus_tile(tile: int, to_scale: float, duration: float) -> void:
	@warning_ignore("integer_division")
	focus(tile % W + 0.5, tile / W + 0.5, to_scale, duration)


func add_shake(strength: float) -> void:
	_shake = maxf(_shake, strength)


static func ease_in_out(t: float) -> float:
	return 4.0 * t * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5


func tick(dt: float) -> void:
	var changed := false
	scale = clamp_scale(scale)
	target_scale = clamp_scale(target_scale)
	if _focus_active:
		_focus_t += dt / _focus_dur
		var t := ease_in_out(minf(_focus_t, 1.0))
		var a := _focus_from
		var b := _focus_to
		cu = a.x + (b.x - a.x) * t
		cv = a.y + (b.y - a.y) * t
		var ls := log(a.z) + (log(b.z) - log(a.z)) * t
		# a long hop pulls back in the middle
		var dist_px := (absf(b.x - a.x) + absf(b.y - a.y)) * a.z
		var bump := clampf(dist_px / (_vp.x * 3.0), 0.0, 0.6)
		ls -= bump * sin(t * PI)
		scale = clamp_scale(exp(ls))
		target_scale = scale
		if _focus_t >= 1.0:
			_focus_active = false
			scale = clamp_scale(b.z)
			target_scale = scale
		changed = true
	elif absf(target_scale - scale) > 1e-4 * scale:
		var k := 1.0 - exp(-dt / ZOOM_TAU)
		scale = exp(log(scale) + (log(target_scale) - log(scale)) * k)
		if absf(target_scale - scale) <= 1e-4 * scale:
			scale = target_scale
		if _has_anchor:
			var ap := anchor_px()
			cu = _anchor_map.x - (_anchor_screen.x - ap.x) / scale
			cv = _anchor_map.y - (_anchor_screen.y - ap.y) / scale
		changed = true
	else:
		_has_anchor = false
	if not dragging and not _focus_active and _vel.length() > 1e-3:
		cu += _vel.x * dt
		cv += _vel.y * dt
		_vel *= pow(INERTIA_DECAY, dt)
		if _vel.length() * scale < 4.0:
			_vel = Vector2.ZERO
		changed = true
	if attract and not dragging and not _focus_active:
		var before := cu
		cu += _drift * dt * 6.0 * (min_scale() / scale)
		_clamp()
		if absf(cu - before) < 1e-6:
			_drift = -_drift
		changed = true
	if _shake > 0.01:
		var r := _shake * 10.0
		_shake_px = Vector2(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * r
		_shake *= pow(0.02, dt)
		changed = true
	elif _shake_px != Vector2.ZERO:
		_shake = 0.0
		_shake_px = Vector2.ZERO
		changed = true
	if changed:
		_clamp()
		_bump()
