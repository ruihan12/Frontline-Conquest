# Step 5b2 of docs/LUAU_PORT.md: rail paths, station links, factory train spawns, train legs and train gold run in
# Luau (luau/sim/Core/SimRails.luau). Plays the seeded match twice, once with Luau and once with the GDScript sim
# (NO_LUAU_SIM), and checks after every tick that the trains, the rail caches the renderer reads, the trucks /
# last_spawn of the factories, the search budgets and every nation's gold are identical. Then checks the direct
# calls (a route search with a big budget, a station's links, a spawn from a factory) against GDScript, and that
# the drawing-side readers never search.
#   godot --headless --path . -s res://tests/test_luau_rails.gd
extends SceneTree

const END_T := 3000

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _tr_row(tr: Dictionary) -> Array:
	var route := PackedInt32Array()
	for s in tr.route: route.append(int(s.tile))
	return [tr.keys(), tr.o, tr.fac.tile, route, tr.leg, tr.src.tile, tr.dst.tile, tr.from, tr.to, tr.t, tr.dur, tr.stops, tr.lvl]


func _state_bytes(m) -> PackedByteArray:
	var trs := []
	for tr in m.trains: trs.append(_tr_row(tr))
	var gold := PackedFloat64Array()
	for n in m.nations: gold.append(float(n.get("gold", 0.0)))
	var facs := []
	for st in m.structs:
		if st.k == 2: facs.append([st.tile, st.keys(), st.get("trucks", -1), st.get("last_spawn", -1)])
	var nb := []
	for t in m._rail_nb_cache:
		var ce: Array = m._rail_nb_cache[t]
		var ts := PackedInt32Array()
		for s in ce[2]: ts.append(int(s.tile))
		nb.append([t, ce[0], ce[1], ts])
	return var_to_bytes([trs, gold, facs, m.rail_cache.keys(), m.rail_cache.values(), nb,
		m._rail_bfs_left, m._rail_calc_left, m._rail_pending, m.rng.state])


func _play(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var hashes := PackedInt64Array()
	var max_tr := 0
	var legs := 0
	var lu_ticks := 0
	var paid := 0
	var view_same := true
	for i in END_T:
		var calls0: int = m.sim_rails.luau_calls
		m._sim_tick_whole()
		if m.sim_rails.luau_calls > calls0: lu_ticks += 1
		max_tr = maxi(max_tr, m.trains.size())
		for tr in m.trains:
			if int(tr.leg) > 0: legs += 1
			if int(tr.stops) > 0: paid += 1
		var h := hash(_state_bytes(m))
		hashes.append(h)
		# the drawing-side readers change nothing
		if i % 100 == 50:
			for tr in m.trains:
				m._has_rail_link_view(tr.src, tr.dst)
				m._rail_curve_view(tr.src.tile, tr.dst.tile)
			for st in m.structs: m._rail_neighbors_view(st)
			if hash(_state_bytes(m)) != h: view_same = false
	# direct calls (tests/upstream/test_live.gd, game/audio.gd port tests, main.gd showcase)
	var P: int = m.PLAYER
	var big := P
	for id in range(1, m.nations.size()):
		if m.nations[id].alive and int(m.nations[id].land) > int(m.nations[big].land): big = id
	m._rail_calc_left = 1000; m._rail_bfs_left = 1000
	var links := []
	var curves := []
	var spawned := []
	for st in m.structs:
		if st.o != big or not (st.k in m.RAIL_KINDS): continue
		var nb: Array = m._rail_neighbors(st)
		var ts := PackedInt32Array()
		for x in nb:
			ts.append(int(x.tile))
			var rc: Array = m._rail_curve(st.tile, x.tile)
			curves.append(rc.duplicate(true))
		links.append(ts)
	for st in m.structs:
		if st.o == big and st.k == 2 and st.get("bt", 0.0) <= 0.0:
			spawned.append(m.spawn_train_from(st))
	var res := {"hashes": hashes, "max_tr": max_tr, "legs": legs, "paid": paid, "lu_ticks": lu_ticks, "view_same": view_same,
		"links": links, "curves": var_to_bytes(curves), "spawned": spawned, "after": hash(_state_bytes(m)),
		"n_rail": m.rail_cache.size(), "err": m.luau_link.error if m.get("luau_link") != null else ""}
	m.queue_free()
	await process_frame
	await process_frame
	return res


func _run() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	var vm := LuauVM.new()
	_check(vm.boot() and vm.require_module("Core/SimState") and vm.require_module("Core/SimArsenal") and vm.require_module("Core/SimRails"),
		"SimRails loads (%s)" % vm.last_error)
	var lua: Dictionary = await _play(true)
	_check(lua.err == "" and int(lua.lu_ticks) >= END_T, "the rails ran in Luau every tick (%d, %s)" % [lua.lu_ticks, lua.err])
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.lu_ticks) == 0, "the second run used the GDScript rails")
	_check(int(lua.max_tr) > 5 and int(lua.legs) > 100 and int(lua.paid) > 50 and int(lua.n_rail) > 20,
		"a match with rails (%d rail pairs cached, up to %d trains, %d train-ticks past the first leg, %d after a paid stop)" % [lua.n_rail, lua.max_tr, lua.legs, lua.paid])
	var ha: PackedInt64Array = lua.hashes
	var hb: PackedInt64Array = gd.hashes
	var first := -1
	for i in mini(ha.size(), hb.size()):
		if ha[i] != hb[i]:
			first = i
			break
	_check(first < 0 and ha.size() == hb.size(), "trains, rail caches, factories, budgets and gold identical to GDScript after each of %d ticks%s" % [ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_check(lua.links == gd.links and lua.curves == gd.curves, "station links and rail paths of the biggest nation equal GDScript's (%d stations)" % (lua.links as Array).size())
	_check(lua.spawned == gd.spawned and (lua.spawned as Array).has(true) and lua.after == gd.after,
		"spawns from its factories equal GDScript's (%s), state after them too" % str(lua.spawned))
	_check(bool(lua.view_same) and bool(gd.view_same), "the drawing-side readers search nothing and spend no budget")
	_done()


func _done() -> void:
	print("LUAU_RAILS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
