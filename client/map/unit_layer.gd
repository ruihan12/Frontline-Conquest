# Port of src/client/Map/UnitLayer.luau: units on the map.
#   * sprites from the unit atlas (13 x 13 px cells, UNIT_SIZE = 13 full-size tiles wide so they scale
#     with the map, at least MIN_PX device px, never rotated, snapped to whole device pixels): light
#     pixels in the owner's territory colour, dark pixels in its border colour (HSV value - 0.16);
#   * every sprite (ships included) from the current atlas (assets/rw/map_sprites/units_one.png, both of
#     its colours in one tint);
#   * a transport leaves a wake: the way sailed so far along its route, one full-size tile wide
#     (at least TRAIL_MIN_PX) in the owner's territory colour at alpha 0.588, gone with the ship;
#   * a train is the engine, TRAIN_CARRIAGES carriages and a tail engine, TRAIN_SPACING full-size
#     tiles apart along the rails behind it, the cars only from CARS_MIN_ZOOM on;
#   * shells, air strikes and slugs (the Arsenal's munitions) and SAM missiles are small sprites
#     flying straight to their target;
#   * a selected warship wears a white ring two sprites wide.
# (nukes: draw_nukes, called from game/planes_fx.gd)
# (The sim here moves ships, trains and warships itself: main.gd's lists. This layer draws them; the
# bomb missiles keep the game's own contrail drawing in game/planes_fx.gd.)
class_name UnitLayer
extends RefCounted

const UNIT_SIZE := 13.0
const MIN_PX := 5.0
const TRAIL_ALPHA := 0.588
const TRAIL_MIN_PX := 1.5
const TRAIN_CARRIAGES := 5
const TRAIN_SPACING := 2.0
const CARS_MIN_ZOOM := 3.0
const DEVICE_RATIO := 2.0
const CELL := 13.0
const COL_TRANSPORT := 0
const COL_TRADE := 1
const COL_WARSHIP := 2
const COL_SAM := 6
const COL_ATOM := 3
const COL_HYDROGEN := 4
const COL_MIRV := 5
const COL_WARHEAD := 8
const TRAIL_STEP := 2.0
const TRAIL_WIDTH := 0.9
## Map/TrailBudget.luau: the most dots one trail has, dots for all trails per redraw, MIRV warheads keep
## their target rings only while at most RING_MAX munitions fly
const TRAIL_MAX := 160
const TRAIL_BUDGET := 800
const TRAIL_RING_MAX := 24
const MEGA_SCALE := 1.5
const COL_SHELL := 7
const COL_TRAIN := 9
const COL_CARRIAGE := 10
## munition scale: a railgun slug 1.2, a shell 0.75 (NUKE_SCALE)
const SHELL_SCALE := 0.75
const SLUG_SCALE := 1.2

var g  # main.gd
var _old: Texture2D
var _one: Texture2D


func _init(main) -> void:
	g = main
	_old = g._tex("units_old.png", 4)
	_one = g._tex("rw/map_sprites/units_one.png", 4)


static func border_of(c: Color) -> Color:
	return Color.from_hsv(c.h, c.s, maxf(0.0, c.v - 0.16), c.a)


## Sprite size in device px for the current zoom.
func sprite_px() -> float:
	return g._ship_px()


## One sprite centred at screen point `p` (snapped to whole device pixels), size `px` (screen px).
func sprite(ci: CanvasItem, col: int, owner_col: Color, p: Vector2, px: float, ship := false) -> void:
	var ds: float = g.hud._device_scale() if g.hud and g.hud.has_method("_device_scale") else 1.0
	var c := Vector2(roundf(p.x * ds), roundf(p.y * ds)) / ds
	var dst := Rect2(c - Vector2(px, px) * 0.5, Vector2(px, px))
	# upstream: ships use the current atlas like every other unit (Sprites.units_one, one tint)
	if _one != null:
		ci.draw_texture_rect_region(_one, dst, Rect2(col * CELL * 4.0, 0, CELL * 4.0, CELL * 4.0), owner_col)


func _owner_col(o: int) -> Color:
	return g.nations[o].color if o > 0 and o < g.nations.size() else g.GOLD_C


func _on_screen(p: Vector2, margin: float, vp: Vector2) -> bool:
	return p.x >= -margin and p.y >= -margin and p.x <= vp.x + margin and p.y <= vp.y + margin


## The wake: the route sailed so far, `w` px thick.
func _wake(ci: CanvasItem, bt: Dictionary, cur: Vector2, w: float, col: Color, vp: Vector2) -> void:
	var pts: PackedVector2Array = bt.pts
	var cum: PackedFloat32Array = bt.cum
	var d: float = bt.d
	var line := PackedVector2Array()
	line.append(g._screen_of(pts[0]))
	var m := 1
	while m < pts.size() and cum[m] < d:
		line.append(g._screen_of(pts[m]))
		m += 1
	line.append(cur)
	if line.size() < 2:
		return
	# (off screen altogether: nothing to draw)
	var lo := line[0]
	var hi := line[0]
	for p in line:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	if hi.x < -w or hi.y < -w or lo.x > vp.x + w or lo.y > vp.y + w:
		return
	ci.draw_polyline(line, Color(col.r, col.g, col.b, TRAIL_ALPHA), w, false)


const ViewerMotion := preload("res://client/map/viewer_motion.gd")


func _draw_boat_pos(boat: Dictionary) -> Array:
	if not g.net_remote or not boat.has("_draw_previous"):
		return g._boat_pos(boat)
	var visual := boat.duplicate(false)
	visual.d = ViewerMotion.sample(boat, "d")
	return g._boat_pos(visual)


func draw(ci: CanvasItem) -> void:
	var vp: Vector2 = g.get_viewport_rect().size
	var px: float = sprite_px()
	var k: float = maxf(0.01, float(g.sim_rules.k_lin))
	var ppt: float = g.cam.zoom.x * g.TS / k
	var wake_w := maxf(TRAIL_MIN_PX, ppt)
	# transports: wake under the sprite
	for bt in g.boats:
		var bp: Array = _draw_boat_pos(bt)
		var col: Color = _owner_col(int(bt.a))
		var p0: Vector2 = g._screen_of(bp[0])
		if bt.get("air", false):
			g._plane_glyph(p0, g._sdir(bt, bp[1]), col, 1.0, false)
			continue
		_wake(ci, bt, p0, wake_w, col, vp)
		if _on_screen(p0, px, vp):
			sprite(ci, COL_TRANSPORT, col, p0, px, true)
	# trains: cars back to front, the engine on top
	var cars_shown := ppt * DEVICE_RATIO >= CARS_MIN_ZOOM
	for tr in g.trains:
		if not g._has_rail_link(tr.src, tr.dst):
			continue
		var f: float = clampf((tr.t + g.sub_tick()) / maxf(0.01, tr.dur), 0.0, 1.0)
		var rp: Array = g._rail_pos(tr.src, tr.dst, f)
		var col: Color = _owner_col(int(tr.o))
		if cars_shown:
			var tot: float = maxf(4.0, float(rp[2]))
			var step := TRAIN_SPACING / k
			for j in range(TRAIN_CARRIAGES + 1, 0, -1):
				var fj := clampf(f - float(j) * step / tot, 0.0, 1.0)
				var rj: Array = g._rail_pos(tr.src, tr.dst, fj)
				var cp: Vector2 = g._screen_of(rj[0] * g.TS)
				if _on_screen(cp, px, vp):
					sprite(ci, COL_TRAIN if j > TRAIN_CARRIAGES else COL_CARRIAGE, col, cp, px)
		var ep: Vector2 = g._screen_of(rp[0] * g.TS)
		if _on_screen(ep, px, vp):
			sprite(ci, COL_TRAIN, col, ep, px)
	# trade ships
	for tr in g.traders:
		var bp: Array = _draw_boat_pos(tr)
		var p0: Vector2 = g._screen_of(bp[0])
		if not _on_screen(p0, maxf(px, 40.0), vp):
			continue
		var ocol: Color = _owner_col(int(tr.o)) if tr.o > 0 and tr.o < g.nations.size() else g.GOLD_C
		if tr.get("air", false):
			var rd: Vector2 = bp[1] if bp[1] != Vector2.ZERO else Vector2.RIGHT
			g._plane_glyph(p0, g._sdir(tr, rd), ocol, 0.85, true)
			continue
		sprite(ci, COL_TRADE, ocol, p0, px, true)
	# warships (smoothed toward their sim position), the selected one ringed
	for ws in g.warships:
		var dp: Vector2 = ws.get("dp", ws.pos)
		var mv: Vector2 = ws.pos - dp
		if g.net_remote:
			dp = ViewerMotion.sample(ws, "pos")
		else:
			dp = ws.pos if g._q() == 0 or mv.length() > 6.0 else dp + mv * clampf(1.0 - exp(-8.0 * g.get_process_delta_time()), 0.0, 1.0)
			ws["dp"] = dp
		var p: Vector2 = g._screen_of(dp * g.TS)
		var col: Color = _owner_col(int(ws.o))
		if g.sel_ws != null and is_same(g.sel_ws, ws):
			ci.draw_arc(p, px, 0, TAU, 32, Color(1, 1, 1, 0.9), 2.0, true)
			if ws.tgt.distance_to(ws.pos) > 1.5:
				var tp: Vector2 = g._screen_of(ws.tgt * g.TS)
				ci.draw_arc(tp, 6.0, 0, TAU, 20, Color(1, 1, 1, 0.8), 1.6, true)
				ci.draw_circle(tp, 2.0, Color(1, 1, 1, 0.8))
		if not _on_screen(p, px, vp):
			continue
		sprite(ci, COL_WARSHIP, col, p, px, true)
		if int(ws.vet) > 0:
			for v in int(ws.vet):
				ci.draw_circle(p + Vector2(-8 + v * 4, -px * 0.5 - 3), 1.6, g.GOLD_C)
	_draw_munitions(ci, px, vp)



## Upstream's nukes (UnitLayer.luau 566-660): the curve flown so far as a solid trail (a line through points
## every TRAIL_STEP full-size tiles, TRAIL_WIDTH tiles thick, at least 2 px, in the owner's colour; the newest
## TrailBudget dots only), the bomb's sprite at its head and, for every kind but the MIRV bus, the blast ring
## on the target, pulsing (red when it falls on the local player); warheads lose their rings while many fly.
## Positions come from the flight fraction (sim ticks + the tick in progress) on the map, then the camera.
func draw_nukes(ci: CanvasItem) -> Dictionary:
	var heads := {}
	var vp: Vector2 = g.get_viewport_rect().size
	var px: float = sprite_px()
	var k: float = maxf(0.01, float(g.sim_rules.k_lin))
	var ppt: float = g.cam.zoom.x * g.TS
	var thick := maxf(2.0, roundf(ppt / k * TRAIL_WIDTH))
	var now := FrameClock.now()
	var flying: int = g.missiles.size()
	var trail_dots: int = mini(TRAIL_MAX, TRAIL_BUDGET / maxi(flying, 1))
	var rings_for_warheads: bool = flying <= TRAIL_RING_MAX
	for ms in g.missiles:
		var f: float = clampf(float(ViewerMotion.sample(ms, "t")) / maxf(0.001, float(ms.dur)), 0.0, 1.0) if g.net_remote else g.missile_frac(ms)
		var nk := int(ms.get("nk", SimRules.N_ATOM))
		var col_i := COL_ATOM
		match nk:
			SimRules.N_HYDROGEN, SimRules.N_MEGA: col_i = COL_HYDROGEN
			SimRules.N_MIRV, SimRules.N_SCATTER: col_i = COL_MIRV
			SimRules.N_WARHEAD: col_i = COL_WARHEAD
		var c: Color = _owner_col(int(ms.o)) if ms.o > 0 and ms.o < g.nations.size() else Color(1, 0.4, 0.3)
		var dist: float = (ms.from as Vector2).distance_to(ms.to)
		var steps := clampi(int(floor((dist * 1.4 + 1.0) * k / TRAIL_STEP)), 2, TRAIL_MAX)
		var newest := int(floor(float(steps) * f))
		var pts := PackedVector2Array()
		for i in range(maxi(0, newest - trail_dots + 1), newest + 1):
			pts.append(g._missile_screen_pos(ms, float(i) / float(steps)))
		var head: Vector2 = g._missile_screen_pos(ms, f)
		pts.append(head)
		if pts.size() >= 2:
			ci.draw_polyline(pts, Color(c.r, c.g, c.b, TRAIL_ALPHA), thick, false)
		var spx: float = px * (MEGA_SCALE if nk == SimRules.N_MEGA else 1.0)
		if _on_screen(head, spx, vp):
			sprite(ci, col_i, c, head, spx)
		heads[ms] = head
		if nk == SimRules.N_WARHEAD and not rings_for_warheads:
			continue
		if nk == SimRules.N_MIRV:
			continue
		var tgt: Vector2 = g._screen_of((ms.to as Vector2) * g.TS)
		var rad := maxf(4.0, float(ms.r) * ppt)
		if tgt.x < -rad or tgt.y < -rad or tgt.x > vp.x + rad or tgt.y > vp.y + rad:
			continue
		var tile: int = int(ms.to.y) * int(g.W) + int(ms.to.x)
		var own: PackedInt32Array = g._render_owners()
		var mine: bool = g.PLAYER > 0 and tile >= 0 and tile < own.size() and own[tile] == g.PLAYER
		var rc := Color(1, 0.16, 0.12) if mine else c
		var pulse := 0.2 + 0.3 * (0.5 + 0.5 * sin(now * 6.0))
		ci.draw_circle(tgt, rad, Color(rc.r, rc.g, rc.b, 0.15))
		ci.draw_arc(tgt, rad, 0.0, TAU, 64, Color(rc.r, rc.g, rc.b, 1.0 - pulse), 2.0, true)
	return heads


## Shells, air strikes, slugs and SAM missiles: sprites flying straight to their target.
func _draw_munitions(ci: CanvasItem, px: float, vp: Vector2) -> void:
	if g.sim_ars == null:
		return
	var tf: float = float(g.sim_atk.tick) + g.sub_tick_counted()
	for m in g.sim_ars.munitions:
		var f: float = clampf((tf - float(m.t0)) / maxf(1.0, float(m.t1 - m.t0)), 0.0, 1.0)
		var a: Vector2 = m.from
		var b: Vector2 = m.to
		var p: Vector2 = g._screen_of(a.lerp(b, f) * g.TS)
		var col: Color = _owner_col(int(m.o)) if m.o > 0 and m.o < g.nations.size() else Color(1, 0.6, 0.3)
		match int(m.nk):
			SimRules.N_SHELL:
				if _on_screen(p, px, vp):
					sprite(ci, COL_SHELL, col, p, px * SHELL_SCALE)
			SimRules.N_AIRSTRIKE:
				ci.draw_arc(g._screen_of(b * g.TS), g.sim_rules.strike_radius(SimRules.N_AIRSTRIKE) * g.TS * g.cam.zoom.x, 0, TAU, 40, Color(col.r, col.g, col.b, 0.6), 1.6, true)
				if _on_screen(p, px, vp):
					sprite(ci, COL_SAM, col, p, px)
			SimRules.N_SLUG:
				if _on_screen(p, px, vp):
					sprite(ci, COL_SHELL, col, p, px * SLUG_SCALE)
	for sm in g.sim_ars.sam_shots:
		var ms = sm.ms
		var f2: float = clampf((tf - float(sm.t0)) / maxf(1.0, float(sm.t1 - sm.t0)), 0.0, 1.0)
		var to_w: Vector2 = g._missile_world_pos(ms, clampf(int(sm.k) * SimArsenal.DT_TICK / maxf(0.001, float(ms.dur)), 0.0, 1.0)) if ms != null else sm.from * g.TS
		var fw: Vector2 = sm.from * g.TS
		var q1: Vector2 = g._screen_of(fw.lerp(to_w, f2))
		if _on_screen(q1, px, vp):
			sprite(ci, COL_SAM, _owner_col(int(sm.o)), q1, px)
	# warship (and defense post) shells in flight: from the shooter to where the target is now
	if g.sim_ws != null:
		for sh in g.sim_ws.shells:
			if not (sh.has("from") and sh.has("target")):
				continue
			var t1: float = float(sh.t1)
			var f3: float = clampf((tf - float(sh.get("t0", t1 - 3.0))) / maxf(1.0, t1 - float(sh.get("t0", t1 - 3.0))), 0.0, 1.0)
			var tgp: Vector2 = g.sim_ws.unit_pos(sh.target)
			var q2: Vector2 = g._screen_of((sh.from as Vector2).lerp(tgp, f3) * g.TS)
			if _on_screen(q2, px, vp):
				var c3: Color = _owner_col(int(sh.o)) if int(sh.o) > 0 and int(sh.o) < g.nations.size() else Color(1, 0.6, 0.3)
				sprite(ci, COL_SHELL, c3, q2, px * SHELL_SCALE)
