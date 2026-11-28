# Defense posts don't shell ships (SimRules.DEFENSE_POST_SHOOTS false, upstream's default; owner request
# 2026-11-26, multiplayer 130a1be). Plays the seeded match on the Luau path and on the GDScript fallback
# (NO_LUAU_SIM). When the first transport is at sea, a finished defense post of a non-allied nation is put on the
# land tile nearest to it, and a warship of the transport's owner next to the post; then 400 ticks run and no post
# shell may be fired, at the transport or the warship. The same scene with the flag forced on must fire post shells, so the scene really puts
# ships in a post's reach.
#   godot --headless --path . -s res://tests/test_defense_posts.gd
extends SceneTree

const MAX_WAIT := 6000
const AFTER := 400

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


# a land tile of a nation that is not the boat's owner and not allied to it, nearest to p, within r tiles
func _post_tile(m, p: Vector2, a: int, r: float) -> Array:
	var W: int = m.W
	var H: int = m.H
	var best := -1
	var bo := -1
	var bd := r * r
	var cx := int(p.x)
	var cy := int(p.y)
	var ri := int(ceil(r))
	for y in range(maxi(0, cy - ri), mini(H, cy + ri + 1)):
		for x in range(maxi(0, cx - ri), mini(W, cx + ri + 1)):
			var i: int = y * W + x
			var o: int = m.owner_map[i]
			if o <= 0 or o == a or m.allied(o, a) or m.struct_at.has(i): continue
			var d := Vector2(x + 0.5, y + 0.5).distance_squared_to(p)
			if d <= bd:
				bd = d; best = i; bo = o
	return [best, bo]


func _water_near(m, tile: int, a_pos: Vector2) -> Vector2:
	var W: int = m.W
	for rr in range(1, 8):
		for dy in range(-rr, rr + 1):
			for dx in range(-rr, rr + 1):
				var j: int = tile + dy * W + dx
				if j >= 0 and j < W * m.H and m.owner_map[j] == m.WATER and m.sim_naval.body[j] > 0:
					return Vector2(j % W + 0.5, j / W + 0.5)
	return a_pos


func _play(luau: bool, shoot: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var W = m.sim_ws
	W.defense_posts_shoot = shoot
	var r: float = SimRules.DEFENSE_POST_TARGET_FULL / W.R.k_lin
	var placed := false
	var post_tile := -1
	var seen_shells := 0
	var at_boats := 0
	var seen := {}
	var ws_in := 0
	var t := 0
	var left := AFTER
	while t < MAX_WAIT + AFTER and left > 0:
		m._sim_tick_whole()
		t += 1
		if not placed:
			for bt in m.boats:
				var cum: PackedFloat32Array = bt.cum
				if (cum[cum.size() - 1] - float(bt.d)) / m.TS < 25.0: continue  # still well out at sea
				var bp: Vector2 = m._boat_pos(bt)[0] / m.TS
				var pt: Array = _post_tile(m, bp, int(bt.a), r * 0.5)
				if pt[0] < 0: continue
				m._struct_add(3, pt[0], pt[1])
				var st = m.struct_at[pt[0]]
				st.bt = 0.0
				post_tile = pt[0]
				var ws := {"o": int(bt.a), "pos": _water_near(m, pt[0], bp), "home": pt[0], "hp": 1000.0, "vet": 0,
					"kills": 0, "tgt": bp, "cd": 0.0}
				W.init_ship(ws)
				ws["patrol"] = ws.pos
				m.warships.append(ws)
				placed = true
				break
			continue
		left -= 1
		for s in W.shells:
			if not s.get("post", false): continue
			var key := [int(s.t0), s.from]  # one post shell, counted once while it flies
			if seen.has(key): continue
			seen[key] = true
			seen_shells += 1
			if s.target.kind == "boat": at_boats += 1
		for w in m.warships:
			if (w.pos as Vector2).distance_to(Vector2(post_tile % m.W + 0.5, post_tile / m.W + 0.5)) <= r: ws_in += 1
	var res := {"placed": placed, "t": t, "post_shots": int(W.stats.post_shots), "post_shells_seen": seen_shells, "at_boats": at_boats,
		"ws_ticks_in_reach": ws_in, "calls": W.luau_calls, "err": m.luau_link.error if m.get("luau_link") != null else ""}
	m.queue_free()
	await process_frame
	await process_frame
	return res


func _run() -> void:
	_check(SimRules.DEFENSE_POST_SHOOTS == false, "SimRules.DEFENSE_POST_SHOOTS is false")
	var src := FileAccess.get_file_as_string("res://sim/warships.gd")
	_check(src.contains("var defense_posts_shoot := SimRules.DEFENSE_POST_SHOOTS"), "sim/warships.gd takes the flag from SimRules")
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	for luau in [true, false]:
		var name := "Luau" if luau else "GDScript"
		var off: Dictionary = await _play(luau, false)
		_check(off.placed, "%s: a post and a warship were put next to a transport (tick %d)" % [name, off.t - AFTER])
		if luau: _check(off.err == "" and int(off.calls) > 0, "%s: the warships ran in Luau (%d calls %s)" % [name, off.calls, off.err])
		else: _check(int(off.calls) == 0, "%s: the warships ran in GDScript" % name)
		_check(int(off.post_shots) == 0 and int(off.post_shells_seen) == 0,
			"%s: no post shell fired in %d ticks (post_shots %d, post shells seen %d, warship-ticks in reach %d)"
			% [name, AFTER, off.post_shots, off.post_shells_seen, off.ws_ticks_in_reach])
		var on: Dictionary = await _play(luau, true)
		_check(on.placed and int(on.post_shots) > 0 and int(on.at_boats) > 0,
			"%s control: with the flag forced on the same post fires, at the transport too (post_shots %d, at transports %d)"
			% [name, on.post_shots, on.at_boats])
	OS.unset_environment("NO_LUAU_SIM")
	_done()


func _done() -> void:
	print("DEFENSE_POSTS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
