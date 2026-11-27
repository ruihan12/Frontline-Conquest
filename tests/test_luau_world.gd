# Step 5g of docs/LUAU_PORT.md: sim/attacks.gd _world() (what every Luau module call gets: troops, gold, alive, kind,
# teams, alliances, traitors, defence posts) keeps a dead nation's troops and gold from its last build instead of
# reading them again. Plays two seeded matches with the cache, checks after each phase of every tick (begin, attack
# pass, AI pass, end) that the cached build equals a full build, then plays each again with full builds only and
# checks that owner map, troops, gold, attacks and rng are identical after each tick.
#   godot --headless --path . -s res://tests/test_luau_world.gd
extends SceneTree

const END_T := 3000
const SEEDS := [5516, 12345]

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
	return var_to_bytes([hash(m.owner_map), nat, atk, m.rng.state])


func _cmp(m, st: Dictionary) -> void:
	var a: Array = m.sim_atk._world()
	m.sim_atk.world_full = true
	var b: Array = m.sim_atk._world()
	m.sim_atk.world_full = false
	st.n += 1
	if var_to_bytes(a) != var_to_bytes(b): st.bad += 1


func _play(sd: int, full: bool) -> Dictionary:
	OS.unset_environment("NO_LUAU_SIM")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = sd; seed(sd)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.sim_atk.world_full = full
	var hashes := PackedInt64Array()
	var st := {"n": 0, "bad": 0}
	var dead_max := 0
	for i in END_T:
		m._sim_tick_begin()
		if not full: _cmp(m, st)
		m.sim_atk.run_slice(-1)
		if not full: _cmp(m, st)
		m._ai_place_budget = 24
		m.sim_ai.begin_tick()
		m.sim_ai.run_slice(0)
		if not full: _cmp(m, st)
		m._sim_tick_end()
		if not full: _cmp(m, st)
		hashes.append(hash(_state_bytes(m)))
		var dead := 0
		for d in m.sim_atk._wc_dead:
			if d != null: dead += 1
		dead_max = maxi(dead_max, dead)
	var res := {"hashes": hashes, "n": st.n, "bad": st.bad, "dead": dead_max, "nn": m.nations.size(),
		"err": m.luau_link.error if m.get("luau_link") != null else "", "on": m.luau_link != null and m.luau_link.on}
	m.queue_free()
	await process_frame
	await process_frame
	return res


func _run() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	for sd in SEEDS:
		var a: Dictionary = await _play(sd, false)
		_check(bool(a.on) and a.err == "", "seed %d: the Luau sim ran (%s)" % [sd, a.err])
		_check(int(a.n) == END_T * 4 and int(a.bad) == 0 and int(a.dead) > int(a.nn) / 2,
			"seed %d: the cached world equals a full read after every phase (%d builds, %d differ, up to %d of %d nations kept dead)" % [sd, a.n, a.bad, a.dead, a.nn])
		var b: Dictionary = await _play(sd, true)
		var ha: PackedInt64Array = a.hashes
		var hb: PackedInt64Array = b.hashes
		var first := -1
		for i in mini(ha.size(), hb.size()):
			if ha[i] != hb[i]:
				first = i
				break
		_check(first < 0 and ha.size() == hb.size(), "seed %d: owner map, troops, gold, attacks and rng identical to full builds after each of %d ticks%s" % [sd, ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_done()


func _done() -> void:
	print("LUAU_WORLD_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
