# Checks the pieces ported in the "port all of upstream left" pass:
#   tribes named from Data/Tribes and counted by map scale (Sim._create_tribes / default_tribes),
#   start troops (Rules.start_troops, bounded by the cap), SimWarships._safe_from_pirates, NEXT MATCH.
#   godot --headless --path . -s res://tests/test_port_left.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	m.map_tab = 0; m.map_i = 0
	m.gen_map()
	m.rng.seed = 20261120; seed(20261120)
	m._start_game()
	for _f in 3: await process_frame
	var names: Array = preload("res://sim/upstream_maps.gd").tribe_names()
	_check(names.size() == 480, "Data/Tribes: 480 names (%d)" % names.size())
	_check(m.tribe_count() == 321, "World tribes = round(400 * 0.896^2) = 321 (%d)" % m.tribe_count())
	var tribes := 0
	var named := 0
	var at_start := true
	var known := {}
	for nm in names: known[str(nm)] = true
	for id in range(2, m.nations.size()):
		var n = m.nations[id]
		if m.kind_of(id) != SimRules.KIND_TRIBE: continue
		tribes += 1
		if known.has(str(n.name)): named += 1
		if n.alive and n.land > 0 and float(n.troops) > SimRules.START_TROOPS_TRIBE + 0.5: at_start = false
	_check(tribes == 321, "321 tribes created (%d)" % tribes)
	_check(named == tribes, "every tribe has a Data/Tribes name (%d/%d)" % [named, tribes])
	_check(at_start, "tribes start at START_TROOPS_TRIBE (or their cap)")
	var nat_ok := true
	for id in range(2, m.nations.size()):
		if m.kind_of(id) == SimRules.KIND_NATION and m.nations[id].alive and m.nations[id].land > 0:
			if float(m.nations[id].troops) > m.sim_rules.start_troops(SimRules.KIND_NATION, m.diff_i) + 0.5: nat_ok = false
	_check(nat_ok, "nations start at Rules.start_troops (or their cap)")
	var st: int = m._find_spawn_tile(int(m.W * 0.47), int(m.H * 0.40))
	m._place_start(st)
	_check(float(m.nations[m.PLAYER].troops) <= SimRules.START_TROOPS_HUMAN + 0.5, "the player starts at START_TROOPS_HUMAN (or the cap): %.0f" % m.nations[m.PLAYER].troops)

	# safe from pirates: a trade ship that just passed shore water is skipped; open sea is not safe
	var sw = m.sim_ws
	var shore := -1
	var deep := -1
	var W: int = m.W
	for t in range(W * 200, m.owner_map.size() - W * 200):
		if m.owner_map[t] != m.WATER: continue
		var s: bool = sw._shore_water(t)
		if s and shore < 0: shore = t
		if not s and deep < 0:
			var far := true
			for dy in range(-30, 31, 3):
				for dx in range(-30, 31, 3):
					var q: int = t + dy * W + dx
					if q < 0 or q >= m.owner_map.size() or m.owner_map[q] != m.WATER: far = false
			if far: deep = t
		if shore >= 0 and deep >= 0: break
	var TS: float = m.TS
	var p_deep := Vector2(deep % W, deep / W) * TS + Vector2(TS, TS) * 0.5
	var sea := {"pts": PackedVector2Array([p_deep, p_deep + Vector2(20.0 * TS, 0)]), "cum": PackedFloat32Array([0.0, 20.0 * TS]), "d": 10.0 * TS}
	_check(not sw._safe_from_pirates(sea), "open sea: not safe from pirates")
	var p_sh := Vector2(shore % W, shore / W) * TS + Vector2(TS, TS) * 0.5
	var coast := {"pts": PackedVector2Array([p_sh, p_sh + Vector2(0.2 * TS, 0)]), "cum": PackedFloat32Array([0.0, 0.2 * TS]), "d": 0.1 * TS}
	_check(sw._safe_from_pirates(coast), "just sailed shore water: safe from pirates")

	# NEXT MATCH: opens, solo only (no ONLINE card), closes
	var nm2 = m.client.next_match
	_check(nm2 != null, "NEXT MATCH screen built")
	if nm2 != null:
		m.client.open_next_match("preview")
		_check(nm2.is_open and nm2.visible, "open_next_match opens it")
		_check(not nm2._cards[1].panel.visible, "ONLINE card hidden (no public matches)")
		_check(nm2._solo_text.text.begins_with("Another war against the computer, on "), "solo copy names the map: " + nm2._solo_text.text)
		nm2.close()
		_check(not nm2.is_open, "closes")
	# real-pop 1:1 scaling (docs/REAL_POP_1TO1.md): S * f(x / S) for growth, x S for absolute amounts
	var R1 := SimRules.new(1.1161)
	var R2 := SimRules.new(1.1161)
	R2.set_troop_scale(true)
	var S := SimRules.TROOP_SCALE
	_check(R1.ts == 1.0 and R2.ts == S, "ts is 1 normally and TROOP_SCALE in 1:1")
	_check(absf(R2.troop_growth(SimRules.KIND_HUMAN, 20000.0 * S, 100000.0 * S, 1) - S * R1.troop_growth(SimRules.KIND_HUMAN, 20000.0, 100000.0, 1)) < 1e-3 * S, "growth is S * f(troops / S)")
	_check(R2.start_troops(SimRules.KIND_HUMAN, 1) == SimRules.START_TROOPS_HUMAN * S, "human start x S (%.0f)" % R2.start_troops(SimRules.KIND_HUMAN, 1))
	_check(SimRules.strike_kill(SimRules.N_SHELL, 10000.0 * S, 1.0, S) == 1440.0 * S, "shell kill floor x S")
	_check(absf(SimRules.warhead_death(1e5 * S, 1e5 * S, S) - S * SimRules.warhead_death(1e5, 1e5)) < 1e-6 * S, "warhead death x S")
	R2.pop_cap_mode = 2
	_check(R2.max_troops_pop(SimRules.KIND_HUMAN, 100, 348e6, 1.0, 2, 1) == 348e6 + 2.0 * SimRules.CITY_POP_BONUS, "1:1 cap = people + city levels x CITY_POP_BONUS")
	_check(R1.max_troops(SimRules.KIND_HUMAN, 100, 0, 1) == R2.max_troops(SimRules.KIND_HUMAN, 100, 0, 1), "tile cap untouched by the scale")
	print("PORT_LEFT fails=%d" % fails)
	quit(1 if fails > 0 else 0)
