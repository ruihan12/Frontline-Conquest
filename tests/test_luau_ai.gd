# Step 5f of docs/LUAU_PORT.md: the AI in Luau (luau/sim/Core/SimAI.luau). 5f1: the border scan.
# Plays the seeded match twice, once with Luau and once with the GDScript sim (NO_LUAU_SIM), and checks after every
# tick that the owner map, every nation's troops and gold, the attacks, the AI's per-nation state and stats and the
# rng are identical. Every 100 ticks of the Luau run, scans every live nation both ways from the same rng state and
# checks the neighbour owners (in order), their counts and first tiles, the neutral count and pick, the fallout
# tile and the rng after.
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
	for i in END_T:
		m._sim_tick_whole()
		hashes.append(hash(_state_bytes(m)))
		if luau and i % 100 == 99:
			var keep := _scan_row(W)
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
				if m.kind_of(id) == SimRules.KIND_TRIBE: tribes += 1
			# leave the match as it was (the GDScript run makes no extra scans)
			m.rng.state = r_keep
			W.sc_list = keep[0]; W.sc_count = keep[1]; W.sc_tile = keep[2]
			W.sc_neutral = keep[3]; W.sc_neutral_tile = keep[4]; W.sc_fallout_tile = keep[5]
	var res := {"hashes": hashes, "scans": W.luau_scans, "direct": direct, "bad": direct_bad, "picks": neutral_picks,
		"tribes": tribes, "stats": W.stats.duplicate(), "err": m.luau_link.error if m.get("luau_link") != null else ""}
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
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.scans) == 0, "the second run used the GDScript scan")
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
