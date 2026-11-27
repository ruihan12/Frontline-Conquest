# Step 5f of docs/LUAU_PORT.md: the AI in Luau (luau/sim/Core/SimAI.luau). 5f1: the border scan; 5f2: the tribes'
# nearby owners (the scan plus the shore probes); 5f3: the coastal border tiles (own_coast, own_coast_tiles).
# Plays the seeded match twice, once with Luau and once with the GDScript sim (NO_LUAU_SIM), and checks after every
# tick that the owner map, every nation's troops and gold, the attacks, the AI's per-nation state and stats and the
# rng are identical. Every 100 ticks of the Luau run, scans every live nation both ways from the same rng state and
# checks the neighbour owners (in order), their counts and first tiles, the neutral count and pick, the fallout
# tile and the rng after; every live nation's coastal border tiles both ways (caps 1, 64, all); and every live tribe's nearby list both ways (owners in order, free land, rng, scan fields).
#   godot --headless --path . -s res://tests/test_luau_ai.gd
extends SceneTree

const END_T := 3000

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _state_bytes(m) -> PackedByteArray:
	var nat := PackedFloat64Array()
	for n in m.nations:
		nat.append(float(n.get("troops", 0.0))); nat.append(float(n.get("gold", 0.0)))
	var atk := []
	for a in m.attacks: atk.append([a.a, a.t, a.get("troops", 0.0)])
	return var_to_bytes([hash(m.owner_map), nat, atk, m.sim_ai.st, m.sim_ai.stats, m.rng.state])


func _scan_row(W) -> Array:
	return [W.sc_list.duplicate(), W.sc_count.duplicate(), W.sc_tile.duplicate(), W.sc_neutral, W.sc_neutral_tile,
		W.sc_fallout_tile]


func _play(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var W = m.sim_ai
	var hashes := PackedInt64Array()
	var direct := 0
	var direct_bad := 0
	var neutral_picks := 0
	var tribes := 0
	var near_n := 0
	var near_bad := 0
	var near_tn := 0
	var near_probe := 0
	var coast_n := 0
	var coast_some := 0
	var coast_bad := 0
	for i in END_T:
		m._sim_tick_whole()
		hashes.append(hash(_state_bytes(m)))
		if luau and i % 100 == 99:
			var keep := _scan_row(W)
			var near_keep: Array = W._near.duplicate()
			var r_keep: int = m.rng.state
			for id in range(1, m.nations.size()):
				if not m.nations[id].get("alive", false): continue
				var r0: int = m.rng.state
				var n0: int = W.luau_scans
				W._scan_border(id)
				var a := _scan_row(W)
				var ra: int = m.rng.state
				var used: bool = W.luau_scans > n0
				m.rng.state = r0
				OS.set_environment("NO_LUAU_SIM", "1")
				W._scan_border(id)
				OS.unset_environment("NO_LUAU_SIM")
				var b := _scan_row(W)
				direct += 1
				if not used or var_to_bytes(a) != var_to_bytes(b) or ra != m.rng.state: direct_bad += 1
				if int(a[4]) >= 0: neutral_picks += 1
				for cap in [1, 64, 1 << 30]:
					n0 = W.luau_coasts
					var ca: Array = W.own_coast_tiles(id, cap)
					used = W.luau_coasts > n0
					OS.set_environment("NO_LUAU_SIM", "1")
					var cb: Array = W.own_coast_tiles(id, cap)
					OS.unset_environment("NO_LUAU_SIM")
					coast_n += 1
					if not ca.is_empty(): coast_some += 1
					if not used or ca != cb: coast_bad += 1
				if m.kind_of(id) != SimRules.KIND_TRIBE: continue
				tribes += 1
				r0 = m.rng.state
				n0 = W.luau_nears
				var tna: bool = W._tribe_nearby(id)
				var na: Array = [tna, W._near.duplicate(), _scan_row(W)]
				ra = m.rng.state
				used = W.luau_nears > n0
				m.rng.state = r0
				OS.set_environment("NO_LUAU_SIM", "1")
				var tnb: bool = W._tribe_nearby(id)
				OS.unset_environment("NO_LUAU_SIM")
				var nb: Array = [tnb, W._near.duplicate(), _scan_row(W)]
				near_n += 1
				if tna: near_tn += 1
				if W._near.size() > W.sc_list.size() + (1 if W.sc_neutral > 0 else 0): near_probe += 1
				if not used or var_to_bytes(na) != var_to_bytes(nb) or ra != m.rng.state: near_bad += 1
			# leave the match as it was (the GDScript run makes no extra scans)
			m.rng.state = r_keep
			W.sc_list = keep[0]; W.sc_count = keep[1]; W.sc_tile = keep[2]
			W.sc_neutral = keep[3]; W.sc_neutral_tile = keep[4]; W.sc_fallout_tile = keep[5]
			W._near = near_keep
	var res := {"hashes": hashes, "scans": W.luau_scans, "direct": direct, "bad": direct_bad, "picks": neutral_picks,
		"tribes": tribes, "nears": W.luau_nears, "near_n": near_n, "near_bad": near_bad, "near_tn": near_tn,
		"near_probe": near_probe, "coasts": W.luau_coasts, "coast_n": coast_n, "coast_some": coast_some,
		"coast_bad": coast_bad, "stats": W.stats.duplicate(), "err": m.luau_link.error if m.get("luau_link") != null else ""}
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
	_check(vm.boot() and vm.require_module("Core/SimState") and vm.require_module("Core/SimAI"), "SimAI loads (%s)" % vm.last_error)
	var lua: Dictionary = await _play(true)
	_check(lua.err == "" and int(lua.scans) > 5000, "the border scans ran in Luau (%d, %s)" % [lua.scans, lua.err])
	_check(int(lua.direct) > 1000 and int(lua.bad) == 0 and int(lua.picks) > 100 and int(lua.tribes) > 100,
		"direct scans equal GDScript's, rng included (%d scans, %d differ, %d with a neutral pick, %d of tribes)" % [lua.direct, lua.bad, lua.picks, lua.tribes])
	_check(int(lua.nears) > 1000, "the tribes' nearby lists were made in Luau (%d)" % lua.nears)
	_check(int(lua.near_n) > 100 and int(lua.near_bad) == 0 and int(lua.near_tn) > 10 and int(lua.near_probe) > 10,
		"direct nearby lists equal GDScript's, rng included (%d lists, %d differ, %d with free land, %d with probe finds)" % [lua.near_n, lua.near_bad, lua.near_tn, lua.near_probe])
	_check(int(lua.coasts) > 5000, "the AI's coast lookups ran in Luau (%d)" % lua.coasts)
	_check(int(lua.coast_n) > 1000 and int(lua.coast_bad) == 0 and int(lua.coast_some) > 300,
		"direct coastal tile lists equal GDScript's (%d lists, %d differ, %d not empty)" % [lua.coast_n, lua.coast_bad, lua.coast_some])
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.scans) == 0 and int(gd.nears) == 0 and int(gd.coasts) == 0, "the second run used the GDScript scan, nearby lists and coast lookups")
	var ha: PackedInt64Array = lua.hashes
	var hb: PackedInt64Array = gd.hashes
	var first := -1
	for i in mini(ha.size(), hb.size()):
		if ha[i] != hb[i]:
			first = i
			break
	_check(first < 0 and ha.size() == hb.size(), "owner map, troops, gold, attacks, AI state and rng identical to GDScript after each of %d ticks%s" % [ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_check(lua.stats == gd.stats, "same AI stats (%s)" % str(lua.stats))
	_done()


func _done() -> void:
	print("LUAU_AI_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
