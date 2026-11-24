extends "res://game/ui_build.gd"
# Air strike and railgun

# ---------- air strike ----------
func _tick_air(_dt: float) -> void:
	pass

func launch_sortie_legacy(st) -> bool:
	if st.get("bt", 0.0) > 0.0: return false
	var o: int = st.o
	var c := Vector2(st.tile % W + 0.5, st.tile / W + 0.5)
	var lvl := int(st.get("level", 1))
	var wh := 5 + (lvl - 1)
	# 1. Prefer enemies currently at war with 'o', or nearest enemy nation within 750 tiles
	var best_p := Vector2(-1, -1)
	var best_ow := -1
	var best_sc := 1e18
	for at in attacks:
		var cand_o := -1
		if at.a == o and at.t > 0: cand_o = at.t
		elif at.t == o and at.a > 0: cand_o = at.a
		if cand_o > 0 and nations[cand_o].alive and not allied(o, cand_o):
			var nn = nations[cand_o]
			var cp := Vector2(nn.sx / maxf(1, nn.land), nn.sy / maxf(1, nn.land))
			var d := c.distance_to(cp)
			if d <= 750.0 and d * 0.5 < best_sc:
				best_sc = d * 0.5; best_p = cp; best_ow = cand_o
	if best_ow < 0:
		for id in range(1, nations.size()):
			if id == o or not nations[id].alive or nations[id].land <= 0 or allied(o, id): continue
			if o != PLAYER and id == PLAYER and elapsed < peace: continue
			var nn = nations[id]
			var cp := Vector2(nn.sx / maxf(1, nn.land), nn.sy / maxf(1, nn.land))
			var d := c.distance_to(cp)
			if d <= 750.0 and d < best_sc:
				best_sc = d; best_p = cp; best_ow = id
	if best_ow < 0:
		return false
	# Pick a land tile inside or near the target nation
	var target_pt := best_p
	var bbt: Rect2i = nations[best_ow].bb
	for _t in 30:
		var tx := bbt.position.x + rng.randi() % maxi(1, bbt.size.x)
		var ty := bbt.position.y + rng.randi() % maxi(1, bbt.size.y)
		if tx >= 0 and ty >= 0 and tx < W and ty < H and owner_map[ty * W + tx] == best_ow:
			target_pt = Vector2(tx + 0.5, ty + 0.5); break
	planes.append({
		"o": o, "from": c, "to": target_pt, "t": 0.0,
		"dur": maxf(2.5, c.distance_to(target_pt) / 34.0),
		"warheads": wh, "dropped": 0
	})
	if o == PLAYER: notify("Airfield (Lv%d) launched %d-warhead Air Strike at %s" % [lvl, wh, _nname(best_ow)], "info")
	elif best_ow == PLAYER: notify("Enemy bombers from %s are inbound!" % _nname(o), "bad")
	return true

# ---------- railgun (requires a ready Missile Silo) ----------
# railgun slug (SimArsenal): from the nearest loaded Railgun structure, any range
func fire_railgun(o: int, tile: int) -> bool:
	return sim_ars.launch_strike(o, SimRules.N_SLUG, tile)

func _draw_meta_fx(z: float) -> void:
	_draw_port_munitions(z)
	for pl in planes:
		var f: float = clampf(pl.t / maxf(0.01, pl.dur), 0.0, 1.0)
		var p := _screen_of(pl.from.lerp(pl.to, f) * TS)
		var d: Vector2 = (pl.to - pl.from).normalized()
		if d == Vector2.ZERO: d = Vector2.RIGHT
		var nrm := Vector2(-d.y, d.x)
		var col: Color = nations[pl.o].color
		# Flight path & twin jet contrails
		overlay.draw_line(_screen_of(pl.from * TS), p, Color(col.r, col.g, col.b, 0.65), 2.4)
		overlay.draw_line(p - d * 22 + nrm * 3.5, p - d * 5 + nrm * 3.5, Color(1, 1, 1, 0.65), 1.8)
		overlay.draw_line(p - d * 22 - nrm * 3.5, p - d * 5 - nrm * 3.5, Color(1, 1, 1, 0.65), 1.8)
		# Strategic swept-wing bomber silhouette (scaled up for high visibility)
		var sc := 1.45
		var body := PackedVector2Array([
			p + d * 11 * sc,
			p + nrm * 2.5 * sc - d * 1 * sc,
			p + nrm * 11 * sc - d * 5 * sc,
			p + nrm * 2.5 * sc - d * 4.5 * sc,
			p + nrm * 4.5 * sc - d * 10 * sc,
			p - d * 8 * sc,
			p - nrm * 4.5 * sc - d * 10 * sc,
			p - nrm * 2.5 * sc - d * 4.5 * sc,
			p - nrm * 11 * sc - d * 5 * sc,
			p - nrm * 2.5 * sc - d * 1 * sc
		])
		overlay.draw_colored_polygon(body, col.lightened(0.25))
		overlay.draw_polyline(body + PackedVector2Array([body[0]]), Color(0.06, 0.08, 0.14, 0.95), 1.8)
		overlay.draw_arc(_screen_of(pl.to * TS), 8 * TS * z, 0, TAU, 32, Color(1, 0.55, 0.2, 0.65), 1.8)
	for bm in beams:
		var a: float = clampf(1.0 - bm.t / 0.6, 0.0, 1.0)
		overlay.draw_line(_screen_of(bm.a * TS), _screen_of(bm.b * TS), Color(0.6, 0.9, 1.0, a), 4.0 * a + 1.0)
		overlay.draw_line(_screen_of(bm.a * TS), _screen_of(bm.b * TS), Color(1, 1, 1, a), 1.5)

# shells / air strikes / slugs (SimArsenal munitions) and SAM missiles, interpolated between sim ticks
func _draw_port_munitions(z: float) -> void:
	if sim_ars == null or client != null: return
	var tf: float = float(sim_atk.tick) + sub_tick_counted()
	for m in sim_ars.munitions:
		var f: float = clampf((tf - float(m.t0)) / maxf(1.0, float(m.t1 - m.t0)), 0.0, 1.0)
		var a: Vector2 = m.from; var b: Vector2 = m.to
		var p := _screen_of(a.lerp(b, f) * TS)
		var col: Color = nations[m.o].color if m.o > 0 and m.o < nations.size() else Color(1, 0.6, 0.3)
		var d: Vector2 = (b - a).normalized()
		if d == Vector2.ZERO: d = Vector2.RIGHT
		match int(m.nk):
			SimRules.N_SHELL:
				# low lob: a small parabola over the straight path
				var hgt: float = sin(f * PI) * minf(18.0, a.distance_to(b) * TS * z * 0.25)
				var ps := p + Vector2(0, -hgt)
				overlay.draw_circle(ps, 2.6, Color(0.08, 0.08, 0.1, 0.9))
				overlay.draw_circle(ps, 1.6, Color(1.0, 0.85, 0.45))
			SimRules.N_AIRSTRIKE:
				var nrm := Vector2(-d.y, d.x)
				overlay.draw_line(_screen_of(a * TS), p, Color(col, 0.35), 1.6)
				var sc := 1.3
				var body := PackedVector2Array([p + d * 11 * sc, p + nrm * 2.5 * sc - d * 1 * sc, p + nrm * 11 * sc - d * 5 * sc, p + nrm * 2.5 * sc - d * 4.5 * sc,
					p + nrm * 4.5 * sc - d * 10 * sc, p - d * 8 * sc, p - nrm * 4.5 * sc - d * 10 * sc, p - nrm * 2.5 * sc - d * 4.5 * sc, p - nrm * 11 * sc - d * 5 * sc, p - nrm * 2.5 * sc - d * 1 * sc])
				overlay.draw_colored_polygon(body, col.lightened(0.25))
				overlay.draw_polyline(body + PackedVector2Array([body[0]]), Color(0.06, 0.08, 0.14, 0.95), 1.6)
				overlay.draw_arc(_screen_of(b * TS), sim_rules.strike_radius(SimRules.N_AIRSTRIKE) * TS * z, 0, TAU, 40, Color(1, 0.55, 0.2, 0.6), 1.6, true)
			SimRules.N_SLUG:
				overlay.draw_line(p - d * 14, p, Color(0.6, 0.9, 1.0, 0.8), 3.0)
				overlay.draw_circle(p, 2.4, Color(1, 1, 1))
	for sm in sim_ars.sam_shots:
		var ms = sm.ms
		var f2: float = clampf((tf - float(sm.t0)) / maxf(1.0, float(sm.t1 - sm.t0)), 0.0, 1.0)
		var to_w: Vector2 = _missile_world_pos(ms, clampf(int(sm.k) * SimArsenal.DT_TICK / maxf(0.001, float(ms.dur)), 0.0, 1.0)) if ms != null else sm.from * TS
		var fw: Vector2 = sm.from * TS
		var q0 := _screen_of(fw)
		var q1 := _screen_of(fw.lerp(to_w, f2))
		overlay.draw_line(q0, q1, Color(1, 1, 1, 0.35), 1.4, true)
		overlay.draw_circle(q1, 2.6, Color(0.75, 0.95, 1.0))

func _tick_meta(dt: float, adt := -1.0) -> void:
	if adt < 0.0: adt = dt
	_tick_air(adt)
	rail_cd = maxf(0.0, rail_cd - dt)
	for bm in beams.duplicate():
		bm.t += adt
		if bm.t > 0.6: beams.erase(bm)

	var pl = nations[PLAYER]
	stats.peak = maxf(stats.peak, 100.0 * pl.land / maxf(1, land_total))
	stats["peak_tiles"] = maxi(int(stats.get("peak_tiles", 0)), int(pl.land))
	stats.maxtroops = maxf(stats.maxtroops, pl.troops)

# RoWorld Data/Stars.luau payout (solo): played 100, survived 15/min, land held 30 x peak land in fair
# shares, nations conquered 54 each (tribes excluded), final place 14/min x place score, victory 18/min;
# every line rounded to 5 and scaled by the difficulty (0.4 / 0.7 / 1.0); 2x Stars doubles the total.
const STARS_MODE_MULT := [0.4, 0.7, 1.0]
var star_lines: Array = []

func _stars_quantum(x: float) -> int:
	if x <= 0.0: return 0
	return maxi(5, int(floor(x / 5.0 + 0.5)) * 5)

func match_stars(win: bool) -> int:
	var pl = nations[PLAYER]
	var field := 1
	var alive_others := 0
	var more := 0
	for id in range(2, nations.size()):
		if id == PLAYER or kind_of(id) == SimRules.KIND_TRIBE: continue
		field += 1
		var n = nations[id]
		if n.alive and n.land > 0:
			alive_others += 1
			if n.land > pl.land: more += 1
	var mine_alive: bool = pl.alive and pl.land > 0
	var place := 1 if win else ((1 + more) if mine_alive else (alive_others + 1))
	var minutes := clampf(elapsed / 60.0, 0.0, 240.0)
	var share := maxf(float(land_total), 1.0) / float(maxi(field, 1))
	var shares := float(stats.get("peak_tiles", 0)) / share
	var pscore := 1.0
	if field > 1:
		var sc := clampf(1.0 - float(place - 1) / float(field - 1), 0.0, 1.0)
		pscore = sc * sc
	var mult: float = STARS_MODE_MULT[clampi(diff_i, 0, 2)]
	star_lines = []
	var total := 0
	var rows := [["played", 100.0], ["survived", 15.0 * minutes], ["territory", 30.0 * maxf(shares, 0.0)],
		["conquests", 54.0 * float(stats.get("conq", 0))], ["placed", 14.0 * pscore * minutes]]
	if win: rows.append(["victory", 18.0 * minutes])
	for r in rows:
		var a := _stars_quantum(float(r[1]) * mult)
		if a > 0:
			star_lines.append([r[0], a]); total += a
	if unlocked("x2") and total > 0:
		star_lines.append(["double", total]); total *= 2
	return total

func next_locked() -> Dictionary:
	var best := {}
	for it in ARSENAL:
		if not unlocked(it.id) and (best.is_empty() or it.cost < best.cost): best = it
	return best
