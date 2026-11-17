# Port of src/client/Map/UnitLayer.luau: units on the map.
#   * sprites from the unit atlas (13 x 13 px cells, UNIT_SIZE = 13 full-size tiles wide so they scale
#     with the map, at least MIN_PX device px, never rotated, snapped to whole device pixels): light
#     pixels in the owner's territory colour, dark pixels in its border colour (HSV value - 0.16);
#   * every sprite, ships included, comes from the current atlas (assets/rw/map_sprites/units_one.png,
#     both of its colours in one tint; the old diamond "specks" were invisible on the sea);
#   * a transport leaves a wake: the way sailed so far along its route, one full-size tile wide
#     (at least TRAIL_MIN_PX) in the owner's territory colour at alpha 0.588, gone with the ship;
#   * a train is the engine, TRAIN_CARRIAGES carriages and a tail engine, TRAIN_SPACING full-size
#     tiles apart along the rails behind it, the cars only from CARS_MIN_ZOOM on;
#   * shells, air strikes and slugs (the Arsenal's munitions) and SAM missiles are small sprites
#     flying straight to their target;
#   * a selected warship wears a white ring two sprites wide.
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
const COL_SHELL := 7
const COL_TRAIN := 9
const COL_CARRIAGE := 10
## munition scale: a railgun slug 1.2, a shell 0.75 (NUKE_SCALE)
const SHELL_SCALE := 0.75
const SLUG_SCALE := 1.2

var g  # main.gd
var _one: Texture2D


func _init(main) -> void:
	g = main
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


func draw(ci: CanvasItem) -> void:
	var vp: Vector2 = g.get_viewport_rect().size
	var px: float = sprite_px()
	var k: float = maxf(0.01, float(g.sim_rules.k_lin))
	var ppt: float = g.cam.zoom.x * g.TS / k
	var wake_w := maxf(TRAIL_MIN_PX, ppt)
	# transports: wake under the sprite
	for bt in g.boats:
		var bp: Array = g._boat_pos(bt)
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
		var f: float = clampf((tr.t + g.tick_acc * 10.0) / maxf(0.01, tr.dur), 0.0, 1.0)
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
		var bp: Array = g._boat_pos(tr)
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


## Shells, air strikes, slugs and SAM missiles: sprites flying straight to their target.
func _draw_munitions(ci: CanvasItem, px: float, vp: Vector2) -> void:
	if g.sim_ars == null:
		return
	var tf: float = float(g.sim_atk.tick) + g.tick_acc * 10.0
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
