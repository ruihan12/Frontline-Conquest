# Nuke flight is a function of sim time only (upstream SimNukes / Rules.nuke_arc).
#   godot --headless --path . --script tests/test_nuke_flight.gd
# 1. The same atom bomb is launched three times, at min / mid / max camera zoom, each driven through the
#    real frame loop (main._process_inner) at a different frame rate and game speed. Its map position on
#    every sim tick of the flight must be identical in the three runs, and it must land on the tick
#    launch + the upstream arc duration scaled by the port's missile speed.
# 2. What is drawn is that map position through the camera: the screen head maps back to the arc point at
#    the drawn flight fraction, and that fraction stays inside the current sim tick.
# 3. Flight ticks of each kind use the same missile speed; the MIRV bus splits on its arrival tick into
#    warheads that follow SimNukes._split_mirv; Scattershot warheads follow SimArsenal._scatter_warheads.
extends SceneTree

var fails := 0
var m

func _check(ok: bool, what: String) -> void:
	if not ok: fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)

func _initialize() -> void:
	call_deferred("_run")

func _clear_sams() -> void:
	for st in m.structs.duplicate():
		if st.k == 4 and st.o != m.PLAYER: m._struct_remove(st)

func _arc_len(a: Vector2, b: Vector2) -> float:
	return float(m.sim_rules.nuke_arc(m.H, a, b).length)

func _match_flight_ticks(upstream_ticks: int) -> int:
	return maxi(1, ceili(float(upstream_ticks) / float(m.NUKE_SPEED_X)))

func _run() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	m = hs.m
	var home: int = hs.start(0, 0, Vector2(0.30, 0.38), 40, 5e12)
	var P: int = m.PLAYER
	m.peace = 1e12
	m.no_cd = true
	m.icbm_mode = false
	hs.step(20)
	var silo_t: int = m._pt_free_land_near(P, home, 30)
	m._struct_add(5, silo_t, P)
	m.struct_at[silo_t].bt = 0.0
	# a target far east on someone else's land
	var tgt := -1
	var best := 0.0
	for id in range(2, m.nations.size()):
		if not m.nations[id].alive or m.nations[id].land < 50: continue
		var c: int = m._pt_center(id)
		if c < 0: continue
		var d := Vector2(c % m.W, c / m.W).distance_to(Vector2(silo_t % m.W, silo_t / m.W))
		if d > best and d < m.W * 0.45: best = d; tgt = c
	_check(tgt >= 0, "found a far target (%.0f tiles from the silo)" % best)
	if tgt < 0:
		quit(1); return
	var from := Vector2(silo_t % m.W + 0.5, silo_t / m.W + 0.5)
	var to := Vector2(tgt % m.W + 0.5, tgt / m.W + 0.5)
	var k_lin: float = m.sim_rules.k_lin
	var want_ft := _match_flight_ticks(ceili(_arc_len(from, to) * k_lin / 10.0))
	print("  k_lin=%.4f silo=%s target=%s arc=%.1f tiles want_ft=%d" % [k_lin, str(from), str(to), _arc_len(from, to), want_ft])

	# ---- 1. three runs: zoom, frame dt and game speed differ
	var runs := [[0.12, 1.0 / 30.0, 1.0], [2.0, 1.0 / 144.0, 3.0], [24.0, 1.0 / 60.0, 10.0]]
	var logs := []
	var render_ok := true
	var render_worst := 0.0
	for ri in runs.size():
		var zoom: float = runs[ri][0]
		var fdt: float = runs[ri][1]
		m.sim_speed = runs[ri][2]
		m.cam.zoom = Vector2(zoom, zoom)
		m.cam.position = (from + to) * 0.5 * m.TS
		_clear_sams()
		m._pt_rearm()
		var n0: int = m.missiles.size()
		var ok: bool = m.launch_nuke(P, 7, tgt)
		_check(ok and m.missiles.size() == n0 + 1, "run %d: launch (zoom %.2f, %.0f fps, %.1fx)" % [ri, zoom, 1.0 / fdt, runs[ri][2]])
		if not ok: continue
		var ms = m.missiles[m.missiles.size() - 1]
		var lt: int = ms.lt
		var ft: int = ms.ft
		_check(ft == want_ft, "run %d: flight %d ticks matches the scaled arc duration (%d)" % [ri, ft, want_ft])
		var lg := {}
		var last_tick := -1
		var landed := -1
		var frames := 0
		while frames < 200000:
			m._process_inner(fdt)
			frames += 1
			_clear_sams()
			var t: int = m.sim_atk.tick
			if not m.missiles.has(ms):
				# the sim tick it detonated on (ms.t is stamped by _tick_missiles on that tick; a new tick may
				# already have begun in the same frame)
				landed = lt + int(round(float(ms.t) / SimArsenal.DT_TICK))
				break
			if t != last_tick:
				last_tick = t
				lg[t - lt] = m._missile_world_pos(ms, float(t - lt) / float(ft))
			# render: the drawn fraction is inside the current tick, and the screen head maps back to the arc
			var f: float = m.missile_frac(ms)
			var k0 := float(t - lt) / float(ft)
			var k1 := float(t - lt + 1) / float(ft)
			if f < k0 - 1e-6 or f > minf(1.0, k1) + 1e-6: render_ok = false
			var wp: Vector2 = m._missile_world_pos(ms, f)
			var back: Vector2 = m.get_canvas_transform().affine_inverse() * m._missile_screen_pos(ms, f)
			render_worst = maxf(render_worst, back.distance_to(wp))
		_check(landed == lt + ft, "run %d: detonated on tick %d = launch %d + flight %d (%d frames)" % [ri, landed, lt, ft, frames])
		logs.append(lg)
	_check(render_ok, "drawn flight fraction always lies inside the current sim tick")
	_check(render_worst < 1e-3, "screen head = camera transform of the map position (worst %.6f px)" % render_worst)
	if logs.size() == 3:
		var same := true
		var n := 0
		for kk in logs[0]:
			for j in [1, 2]:
				if logs[j].has(kk):
					n += 1
					if logs[j][kk] != logs[0][kk]: same = false
		var per_tick: int = logs[0].size()
		_check(same and n > per_tick, "map positions identical per tick at min / mid / max zoom (%d ticks compared)" % n)
		print("  sample  k=%d %s / %s / %s" % [want_ft / 2, str(logs[0].get(want_ft / 2)), str(logs[1].get(want_ft / 2)), str(logs[2].get(want_ft / 2))])
	m.sim_speed = 1.0

	# ---- 3. per-kind flight ticks, MIRV split, scattershot
	var kinds := {9: [SimRules.N_MIRV, 15.0], 7: [SimRules.N_ATOM, 10.0], 8: [SimRules.N_HYDROGEN, 10.0], 11: [SimRules.N_MEGA, 10.0], 12: [SimRules.N_SCATTER, 10.0]}
	# the biggest other nation (the MIRV goes first, onto live land)
	var foe := -1
	for id in range(2, m.nations.size()):
		if m.nations[id].alive and (foe < 0 or m.nations[id].land > m.nations[foe].land): foe = id
	var aim: int = m._pt_center(foe)
	m._claim_blob(foe, aim, 150)  # a big country, so the MIRV has room for many warheads 55 full-size tiles apart
	var aim_v := Vector2(aim % m.W + 0.5, aim / m.W + 0.5)
	for bk in kinds:
		_clear_sams(); m._pt_rearm()
		var n0: int = m.missiles.size()
		if not m.launch_nuke(P, bk, aim):
			_check(false, "launch %s" % m.build_data[bk][1]); continue
		var ms = m.missiles[n0]
		var spd: float = kinds[bk][1]
		var wft := _match_flight_ticks(ceili(_arc_len(from, aim_v) * k_lin / spd))
		_check(int(ms.nk) == kinds[bk][0] and int(ms.ft) == wft, "%s: flight %d ticks matches the scaled arc duration (%d)" % [m.build_data[bk][1], int(ms.ft), wft])
		var r_want: float = m.sim_rules.nuke_radii(SimRules.N_WARHEAD if bk == 9 else int(ms.nk)).y
		_check(bk == 9 or absf(float(ms.r) - r_want) < 1e-4, "%s: outer radius %.2f = upstream %.2f" % [m.build_data[bk][1], float(ms.r), r_want])
		if bk == 12:
			var whs := []
			for i in range(n0 + 1, m.missiles.size()): whs.append(m.missiles[i])
			var ok_sc := whs.size() >= 1 and whs.size() <= SimRules.SCATTER_MAX
			for i in whs.size():
				var w = whs[i]
				var d: float = (w.to as Vector2).distance_to(aim_v)
				var arc_ticks: int = m.sim_rules.nuke_arc_ticks(m.sim_rules.nuke_arc(m.H, from, w.to), SimRules.N_SCATTER)
				var wl := maxi(int(ms.ft), _match_flight_ticks(arc_ticks)) + (i + 1) * 2
				if int(w.nk) != SimRules.N_WARHEAD or int(w.ft) != wl or d < m.sim_rules.scatter_near() - 1.5 or d > m.sim_rules.scatter_far() + 1.5: ok_sc = false
			_check(ok_sc, "scattershot: %d warheads, 28-46 full-size tiles out, each 2 ticks after the last" % whs.size())
		if bk == 9:
			var lt: int = ms.lt
			var split_at := -1
			var n_before: int = m.missiles.size()
			for _i in int(ms.ft) + 2:
				hs.step(1)
				if not m.missiles.has(ms): split_at = m.sim_atk.tick; break
			_check(split_at == lt + int(ms.ft), "MIRV bus splits on its arrival tick (%d = %d + %d)" % [split_at, lt, int(ms.ft)])
			var whs := []
			for w in m.missiles:
				if int(w.nk) == SimRules.N_WARHEAD and int(w.lt) == split_at and w.mirv: whs.append(w)
			var gap := int(ceil(55.0 / k_lin))
			var spread: float = float(m.sim_rules.mirv_spread())
			var ok_w := whs.size() >= 1 and whs.size() <= SimRules.MIRV_WARHEADS
			var tgo: int = int(ms.tgt_o)
			for i in whs.size():
				var w = whs[i]
				var wt: int = int(w.to.y) * m.W + int(w.to.x)
				var arc_ticks: int = m.sim_rules.nuke_arc_ticks(m.sim_rules.nuke_arc(m.H, aim_v, w.to), SimRules.N_WARHEAD)
				var base := _match_flight_ticks(arc_ticks)
				if int(w.ft) < base or int(w.ft) > base + 15: ok_w = false
				if (w.from as Vector2) != aim_v or (w.to as Vector2).distance_to(aim_v) > spread + 1e-3: ok_w = false
				if i > 0 and m.owner_map[wt] != tgo: ok_w = false
				for j in i:
					var o2 = whs[j]
					if absi(int(o2.to.x) - int(w.to.x)) + absi(int(o2.to.y) - int(w.to.y)) < gap: ok_w = false
			_check(ok_w, "MIRV: %d warheads from the aim, on the target's land, >= %d tiles apart, flight = warhead arc + 0..15" % [whs.size(), gap])
		# let them all land
		var guard := 0
		while not m.missiles.is_empty() and guard < 4000:
			hs.step(1); guard += 1
	_check(m.missiles.is_empty(), "every munition landed")
	print("NUKE_FLIGHT %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
