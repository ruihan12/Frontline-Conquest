# Nothing of a finished world survives into the title screen or into a new attract sim (owner report 2026-11-28:
# structure icons, ships and nuke arcs of the last match drawn over the title's attract sim after a win, web).
# On the Luau path and on the GDScript fallback (NO_LUAU_SIM): a short seeded match gets structures for many
# nations, warships and nukes in flight; it is won and left for the title (_to_menu). Then every sim list, every
# list Luau keeps, the client's caches and every map layer must hold zero items, and the overlay must have
# redrawn (it keeps its last frame until it does). Then an attract sim runs, gets the same things, and a new
# attract sim starts (_attract_begin): right after it, before the attract has ticked, everything is zero again.
#   godot --headless --path . -s res://tests/test_title_reset.gd
extends SceneTree

var fails := 0
var draws := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _on_draw() -> void:
	draws += 1


# finished structures for every nation with land, a warship on the water near each, nukes at each other
func _dirty(m) -> Dictionary:
	var by := {}
	var i := 0
	var n: int = m.owner_map.size()
	while i < n:
		var o: int = m.owner_map[i]
		if o > 0 and not m.struct_at.has(i):
			if not by.has(o): by[o] = []
			if by[o].size() < 40: by[o].append(i)
		i += 5
	var ks: Array[int] = [0, 2, 3, 4, 5, 10, 14, 15, 5]
	for o in by.keys():
		var tl: Array = by[o]
		var j := 0
		for k in ks:
			if j >= tl.size(): break
			var t: int = tl[j]
			j += 4
			if m.struct_at.has(t): continue
			m._struct_add(k, t, o)
			if m.struct_at.has(t): m.struct_at[t].bt = 0.0
		var t0: int = tl[0]
		var W: int = m.W
		for rr in range(1, 40):
			var found := -1
			for dy in range(-rr, rr + 1):
				for dx in [-rr, rr]:
					var jj: int = t0 + dy * W + dx
					if jj >= 0 and jj < n and m.owner_map[jj] == m.WATER and m.sim_naval.body[jj] > 0:
						found = jj
						break
				if found >= 0: break
			if found >= 0:
				var ws := {"o": int(o), "pos": Vector2(found % W + 0.5, found / W + 0.5), "home": t0, "hp": 1000.0,
					"vet": 0, "kills": 0, "tgt": Vector2(found % W + 0.5, found / W + 0.5), "cd": 0.0}
				m.sim_ws.init_ship(ws)
				ws["patrol"] = ws.pos
				m.warships.append(ws)
				break
	var keys: Array = by.keys()
	for a in keys:
		for b in keys:
			if a == b or m.allied(a, b): continue
			m.nations[a].gold = 1e9
			m.launch_nuke(a, 7, by[b][by[b].size() / 2])
			break
	m._sv += 1
	for t in 3: m._sim_tick_whole()
	var cs = m.client.ctx.state if m.client != null and m.client.ctx != null else null
	if cs != null:
		cs.structures(); cs.units(); cs.attacks()
	return {"structs": m.structs.size(), "warships": m.warships.size(), "missiles": m.missiles.size()}


func _luau_counts(m) -> Dictionary:
	var lu = m.luau_link
	if lu == null or not lu.on or OS.has_environment("NO_LUAU_SIM"): return {}
	var ars: Dictionary = lu.vm.call_fn("Core/SimArsenal", "debug", [])
	var rl: Dictionary = lu.vm.call_fn("Core/SimRails", "debug", [])
	var at: Dictionary = lu.vm.call_fn("Core/SimAttacks", "debug", [0])
	return {"luau missiles": ars.missiles.size() / 4, "luau munitions": ars.munitions.size() / 4,
		"luau trains": int(rl.trains), "luau rails": int(rl.rail), "luau attacks": int(at.n),
		"mirror missiles": m.sim_ars._mlist.size(), "mirror munitions": m.sim_ars._ulist.size(),
		"mirror trains": m.sim_rails._tlist.size(), "mirror attacks": m.sim_atk._mir.size()}


func _counts(m) -> Dictionary:
	var c := {}
	for k in ["structs", "struct_at", "boats", "warships", "traders", "trains", "missiles", "shells", "blasts",
			"attacks", "planes", "beams", "floats", "cap_fx", "drops", "nuke_queue", "_rail_edges_cache"]:
		c[k] = (m.get(k) as Variant).size()
	c["warship shells"] = m.sim_ws.shells.size()
	c["munitions"] = m.sim_ars.munitions.size()
	var cs = m.client.ctx.state if m.client != null and m.client.ctx != null else null
	if cs != null:
		c["client structures cache"] = cs._structs.size()
		c["client units cache"] = cs._units.size()
		c["client attacks cache"] = cs._attacks.size()
		c["client structures()"] = cs.structures().size()
		c["client units()"] = cs.units().size()
	if m.names != null: c["name plates"] = m.names._plates.size()
	if m.ranges != null:
		c["range sites"] = m.ranges._sites.size()
		c["range seen structs"] = m.ranges._seen_structs.size()
	if m.fx_layer != null: c["fx"] = m.fx_layer._fx.size() + m.fx_layer._pops.size() + m.fx_layer._bursts.size() + m.fx_layer._debris.size()
	if m.fronts != null: c["front labels"] = m.fronts.entries.size()
	if m.road_layer != null: c["road pieces"] = m.road_layer._roads.size()
	c.merge(_luau_counts(m))
	return c


func _all_zero(c: Dictionary, what: String) -> void:
	var bad := []
	for k in c:
		if int(c[k]) != 0: bad.append("%s=%d" % [k, c[k]])
	_check(bad.is_empty(), "%s: every list and layer is empty (%d checked)%s" % [what, c.size(), "" if bad.is_empty() else " left: " + ", ".join(bad)])


func _one(luau: bool) -> void:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var name := "Luau" if luau else "GDScript"
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.peace = 0.0
	for t in 120: m._sim_tick_whole()
	var made: Dictionary = _dirty(m)
	_check(int(made.structs) > 100 and int(made.warships) > 10 and int(made.missiles) > 10,
		"%s: the match has structures %d, warships %d, missiles %d" % [name, made.structs, made.warships, made.missiles])
	if luau:
		var lc: Dictionary = _luau_counts(m)
		_check(int(lc.get("luau missiles", 0)) > 0, "%s: Luau holds the match's missiles (%d)" % [name, lc.get("luau missiles", 0)])
	# win, back to the title
	m._game_over(true)
	await process_frame
	m.overlay.draw.connect(_on_draw)
	draws = 0
	m._to_menu()
	_all_zero(_counts(m), "%s, title screen" % name)
	await process_frame
	await process_frame
	_check(draws > 0, "%s: the overlay redrew on the title (%d draws)" % [name, draws])
	# an attract sim that gets the same things, then the next attract start
	m._attract_begin()
	for t in 60: m._sim_tick_whole()
	var made2: Dictionary = _dirty(m)
	_check(int(made2.structs) > 50 and int(made2.missiles) > 5, "%s: the attract sim has structures %d, missiles %d"
		% [name, made2.structs, made2.missiles])
	draws = 0
	m._attract_begin()
	_all_zero(_counts(m), "%s, new attract sim before its first tick" % name)
	await process_frame
	await process_frame
	_check(draws > 0, "%s: the overlay redrew for the new attract sim (%d draws)" % [name, draws])
	m.overlay.draw.disconnect(_on_draw)
	m.queue_free()
	await process_frame
	await process_frame


func _run() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
	else:
		await _one(true)
	await _one(false)
	OS.unset_environment("NO_LUAU_SIM")
	print("TITLE_RESET_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
