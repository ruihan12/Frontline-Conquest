# Step 5d of docs/LUAU_PORT.md (draft): water pathfinding in Luau (luau/sim/Core/SimNav.luau) against the GDScript
# sim/nav.gd on a seeded match's map: the region graph (regions, centres, edges, portals, costs, coasts, clusters)
# and, in the same order on both sides (so the caches and the per-tick budget see the same history), many
# find_route, water_path_px and boat_route queries.
#   godot --headless --path . -s res://tests/test_luau_nav.gd
extends SceneTree

const MOD := "Core/SimNav"
var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _run() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	var vm := LuauVM.new()
	_check(vm.boot() and vm.require_module(MOD), "SimNav.luau loads (%s)" % vm.last_error)
	if not vm.ok() or not vm.booted:
		_done()
		return
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	for i in 600:
		m._sim_tick_whole()
	_check(m.sim_nav.on_luau(), "the match's searches run in Luau (%s)" % m.luau_link.error)
	var ls: Dictionary = m.sim_nav.luau_stats()
	print("  match nav in Luau: %s" % str(ls))
	var W: int = m.W
	var H: int = m.H
	var body: PackedInt32Array = m.sim_naval.body
	var gd := SimNav.new()
	gd.build(body, W, H)
	var t0 := Time.get_ticks_usec()
	var id = vm.call_fn(MOD, "build", [body.to_byte_array(), W, H])
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check(id != null, "Luau build (%s)" % vm.last_error)
	if id == null:
		_done()
		return
	print("  build: GDScript %.1f ms, Luau %.1f ms, %d regions" % [gd.build_ms, build_ms, gd.reg_count])
	# graph
	var d: Dictionary = vm.call_fn(MOD, "dump", [id])
	_check(int(d.reg_count) == gd.reg_count and int(d.clu_count) == gd.clu_count,
		"region / cluster counts (%d/%d vs %d/%d)" % [d.reg_count, d.clu_count, gd.reg_count, gd.clu_count])
	var reg := PackedInt32Array()
	var regxy := PackedFloat32Array()
	for r in gd.reg_count:
		reg.append(gd.reg_body[r]); reg.append(gd.reg_tile[r]); reg.append(gd.reg_n[r]); reg.append(gd.reg_full[r])
		regxy.append(gd.reg_x[r]); regxy.append(gd.reg_y[r])
	_check((d.reg as PackedByteArray) == reg.to_byte_array(), "regions: body, tile, size, full")
	_check((d.regxy as PackedByteArray) == regxy.to_byte_array(), "region centres (float32)")
	var adj := PackedInt32Array(gd.adj_off)
	var cost := PackedFloat32Array()
	for k in gd.adj_off[gd.reg_count]:
		adj.append(gd.adj_to[k]); adj.append(gd.adj_pa[k]); adj.append(gd.adj_pb[k]); cost.append(gd.adj_cost[k])
	_check((d.adj as PackedByteArray) == adj.to_byte_array(), "edges and portals (%d)" % gd.adj_off[gd.reg_count])
	_check((d.cost as PackedByteArray) == cost.to_byte_array(), "edge costs (float32)")
	var coast := PackedInt32Array(gd.coast_off)
	coast.append_array(gd.coast_tiles)
	_check((d.coast as PackedByteArray) == coast.to_byte_array(), "coasts (%d tiles)" % gd.coast_tiles.size())
	var clu := PackedInt32Array()
	for r in gd.reg_count: clu.append(gd.reg_clu[r])
	for c in gd.clu_count + 1: clu.append(gd.cadj_off[c] if c < gd.cadj_off.size() else 0)
	_check((d.clu as PackedByteArray) == clu.to_byte_array(), "clusters")
	# queries, in the same order on both sides
	var water := PackedInt32Array()
	var coastal := PackedInt32Array()
	for t in body.size():
		if body[t] > 0: water.append(t)
	coastal = m.sim_naval.coast_list
	var r := RandomNumberGenerator.new()
	r.seed = 77
	var n := 0
	var bad := 0
	var nonempty := 0
	var deferred_bad := 0
	for q in 3000:
		if q % 25 == 0:
			gd.begin_tick(); vm.call_fn(MOD, "begin_tick", [id])
		var a: int = water[r.randi() % water.size()]
		var b: int = water[r.randi() % water.size()]
		if q % 3 == 0:
			# same body: a tile near a
			for _k in 40:
				var c: int = water[r.randi() % water.size()]
				if body[c] == body[a]: b = c; break
		var urgent := q % 4 != 0
		var gr := gd.find_route(a, b, urgent)
		var lr: Dictionary = vm.call_fn(MOD, "find_route", [id, a, b, urgent])
		n += 1
		if (lr.r as PackedByteArray) != gr.to_byte_array(): bad += 1
		if bool(lr.d) != gd.last_deferred: deferred_bad += 1
		if gr.size() > 1: nonempty += 1
	_check(bad == 0 and deferred_bad == 0, "find_route: %d queries (%d routes), %d differ, %d deferral flags differ" % [n, nonempty, bad, deferred_bad])
	var pbad := 0
	var pn := 0
	var pne := 0
	for q in 800:
		if q % 25 == 0:
			gd.begin_tick(); vm.call_fn(MOD, "begin_tick", [id])
		var a: int = coastal[r.randi() % coastal.size()]
		var b: int = coastal[r.randi() % coastal.size()]
		var urgent := q % 2 == 0
		var gp := gd.water_path_px(a, b, m.TS, urgent)
		var lp: Dictionary = vm.call_fn(MOD, "water_path_px", [id, a, b, float(m.TS), urgent])
		pn += 1
		if gp.size() > 1: pne += 1
		var gb := PackedFloat32Array()
		for p in gp: gb.append(p.x); gb.append(p.y)
		if (lp.p as PackedByteArray) != gb.to_byte_array() or bool(lp.d) != gd.last_deferred:
			pbad += 1
			if pbad == 1:
				var lf: PackedFloat32Array = (lp.p as PackedByteArray).to_float32_array()
				var k := 0
				while k < mini(lf.size(), gb.size()) and lf[k] == gb[k]: k += 1
				print("    first difference: %d -> %d, %d vs %d floats, index %d: %s vs %s" % [a, b, lf.size(), gb.size(), k,
					str(lf.slice(maxi(0, k - 4), k + 4)), str(gb.slice(maxi(0, k - 4), k + 4))])
	_check(pbad == 0, "water_path_px: %d queries (%d paths), %d differ" % [pn, pne, pbad])
	var om: PackedInt32Array = m.owner_map
	var omb := om.to_byte_array()
	var bbad := 0
	var bn := 0
	var bne := 0
	for q in 600:
		var dest: int = coastal[r.randi() % coastal.size()]
		var o: int = 1 + r.randi() % (m.nations.size() - 1)
		var mx := 12000 if q % 2 == 0 else (1 << 30)
		var gr2 := gd.boat_route(om, o, dest, mx)
		var lr2 = vm.call_fn(MOD, "boat_route", [id, omb, o, dest, mx])
		bn += 1
		if gr2.size() > 1: bne += 1
		if lr2 == null or (lr2 as PackedByteArray) != gr2.to_byte_array(): bbad += 1
	_check(bbad == 0, "boat_route: %d queries (%d routes), %d differ (%s)" % [bn, bne, bbad, vm.last_error])
	var d2: Dictionary = vm.call_fn(MOD, "dump", [id])
	_check(int(d2.searches) == gd.searches and int(d2.fails) == gd.fails,
		"search / fail counters (%d/%d vs %d/%d)" % [d2.searches, d2.fails, gd.searches, gd.fails])
	_done()


func _done() -> void:
	print("LUAU_NAV_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
