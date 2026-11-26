# ICBM toggle (kept custom): +10% cost and a 20% chance per launch to evade SAMs entirely.
#   godot --headless --path . --script tests/test_icbm_evade.gd
# Seeded sim RNG: about 20% of N launches evade (3 sigma band), the roll is deterministic for a seed, only
# the player rolls and only with ICBM on, a MIRV's warheads (and a Scattershot's) inherit the launch roll, and
# under a ring of enemy SAMs an evading bomb is never targeted or intercepted while the others are.
extends SceneTree

var fails := 0
var m

func _check(ok: bool, what: String) -> void:
	if not ok: fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)

func _initialize() -> void:
	call_deferred("_run")

func _rolls(n: int, tgt: int, seed_v: int) -> Array:
	m.rng.seed = seed_v
	var out := []
	for i in n:
		m._pt_rearm()
		if m.launch_nuke(m.PLAYER, 7, tgt): out.append(bool(m.missiles[m.missiles.size() - 1].evade))
	return out

func _place_sams(foe: int, tgt: int) -> int:
	# a ring of level-3 SAMs 45 tiles out: outside the atom blast (30 full-size), inside the targetable zone
	var n := 0
	for a in 16:
		var p: Vector2 = Vector2(tgt % m.W, tgt / m.W) + Vector2.from_angle(a * TAU / 16.0) * (45.0 / float(m.sim_rules.k_lin))
		var t: int = int(p.y) * m.W + int(p.x)
		if t < 0 or t >= m.W * m.H or m.owner_map[t] != foe: continue
		if not m.struct_at.has(t): m._struct_add(4, t, foe)
		if m.struct_at.has(t) and m.struct_at[t].k == 4:
			m.struct_at[t].bt = 0.0; m.struct_at[t].level = 3; m.struct_at[t].shots = []
			n += 1
	return n

func _run() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	m = hs.m
	m.rng.seed = 12345
	seed(12345)
	var P: int = m.PLAYER
	var home: int = hs.start(0, 0, Vector2(0.30, 0.38), 40, 1e15)
	m.peace = 1e12
	m.no_cd = true
	hs.step(20)
	var silo_t: int = m._pt_free_land_near(P, home, 30)
	m._struct_add(5, silo_t, P)
	m.struct_at[silo_t].bt = 0.0
	var foe := -1
	for id in range(2, m.nations.size()):
		if not m.nations[id].alive or m.nations[id].land < 30: continue
		var c: int = m._pt_center(id)
		var d := Vector2(c % m.W, c / m.W).distance_to(Vector2(silo_t % m.W, silo_t / m.W))
		if d > 200.0 and d < 800.0 and (foe < 0 or m.nations[id].land > m.nations[foe].land): foe = id
	_check(foe > 0, "found a foe 200-800 tiles away")
	if foe < 0:
		quit(1); return
	var tgt: int = m._pt_center(foe)
	m._claim_blob(foe, tgt, 90)

	# ---- roll statistics (no flight: launches are cleared right away)
	m.set_icbm(true)
	var N := 400
	var r1 := _rolls(N, tgt, 9001)
	m.missiles.clear()
	var ev := r1.count(true)
	var share := float(ev) / float(maxi(1, r1.size()))
	const EXPECTED_EVASION := 0.20
	var sd := sqrt(EXPECTED_EVASION * (1.0 - EXPECTED_EVASION) / float(N))
	_check(r1.size() == N and absf(share - EXPECTED_EVASION) <= 3.0 * sd, "ICBM on: %d / %d launches evade (%.1f%%, expect 20%% +- %.1f%%)" % [ev, r1.size(), share * 100.0, 3.0 * sd * 100.0])
	var r2 := _rolls(N, tgt, 9001)
	m.missiles.clear()
	_check(r1 == r2, "same seed, same evasion rolls (sim RNG, deterministic)")
	var g0: float = m.nations[P].gold
	m._pt_rearm(); m.launch_nuke(P, 7, tgt)
	_check(absf(g0 - m.nations[P].gold - 825000.0) < 1.0, "ICBM still costs +10% (825K atom)")
	m.missiles.clear()
	m.set_icbm(false)
	var r3 := _rolls(100, tgt, 9001)
	m.missiles.clear()
	_check(r3.size() == 100 and r3.count(true) == 0, "ICBM off: no launch evades")
	# AI launches never roll, even while the player's toggle is on
	m.set_icbm(true)
	var ai_silo: int = m._pt_free_land_near(foe, tgt, 40)
	m._struct_add(5, ai_silo, foe); m.struct_at[ai_silo].bt = 0.0
	m.nations[foe].gold = 1e15
	var ai_ev := 0
	var ai_n := 0
	for i in 60:
		for st in m.structs: if st.o == foe: st.shots = []
		if m.launch_nuke(foe, 7, home):
			ai_n += 1
			if m.missiles[m.missiles.size() - 1].evade: ai_ev += 1
	m.missiles.clear()
	m._struct_remove(m.struct_at[ai_silo])
	_check(ai_n > 0 and ai_ev == 0, "AI launches never evade (%d launches)" % ai_n)

	# ---- MIRV: the bus rolls once, every warhead inherits it
	var seen := {}
	for i in 40:
		if seen.size() == 2: break
		m._pt_rearm()
		if not m.launch_nuke(P, 9, tgt): continue
		var bus = m.missiles[m.missiles.size() - 1]
		var bev: bool = bus.evade
		if seen.has(bev):
			m.missiles.erase(bus); continue
		seen[bev] = true
		var guard := 0
		while m.missiles.has(bus) and guard < 2000:
			hs.step(1); guard += 1
		var whs := []
		for w in m.missiles:
			if int(w.nk) == SimRules.N_WARHEAD and w.mirv: whs.append(w)
		var inherit := whs.size() > 0
		for w in whs: if bool(w.evade) != bev: inherit = false
		_check(inherit, "MIRV bus evade=%s: all %d warheads inherit it" % [str(bev), whs.size()])
		m.missiles.clear()
	_check(seen.size() == 2, "saw both an evading and a non-evading MIRV")
	m.mirvs_launched = 0

	# ---- under enemy SAMs: evaders are never targeted / intercepted, the others are
	m._claim_blob(foe, tgt, 90)
	var sams := _place_sams(foe, tgt)
	_check(sams >= 8, "%d enemy SAMs (level 3) ringed 45 tiles round the target" % sams)
	var flown := []
	m.rng.seed = 4242
	for wave in 6:
		for i in 8:
			m._pt_rearm()
			if m.launch_nuke(P, 7, tgt): flown.append(m.missiles[m.missiles.size() - 1])
		var guard2 := 0
		while guard2 < 3000:
			var live := false
			for ms in flown:
				if m.missiles.has(ms):
					live = true
					if ms.evade and (ms.get("sam_st") != null or not (ms.get("cands", []) as Array).is_empty()): ms["_was_targeted"] = true
			if not live: break
			hs.step(1); guard2 += 1
		m._claim_blob(foe, tgt, 90)
		_place_sams(foe, tgt)
	var ev_n := 0; var ev_hit := 0; var non_n := 0; var non_hit := 0
	for ms in flown:
		var hit := bool(ms.get("shot_down", false))
		if ms.evade:
			ev_n += 1
			if hit or ms.get("_was_targeted", false): ev_hit += 1
		else:
			non_n += 1
			if hit: non_hit += 1
	_check(ev_n > 0 and ev_hit == 0, "evading bombs: %d launched, %d targeted or intercepted" % [ev_n, ev_hit])
	_check(non_n > 0 and non_hit >= int(non_n * 0.8), "non-evading bombs: %d of %d intercepted (the SAMs do work)" % [non_hit, non_n])
	print("ICBM_EVADE %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
