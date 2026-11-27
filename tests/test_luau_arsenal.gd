# Step 5c of docs/LUAU_PORT.md: bombs, munitions, SAMs, blasts, construction, reloads and batteries run in Luau
# (luau/sim/Core/SimArsenal.luau); sim/arsenal.gd and game/nukes.gd are its face. Plays the same seeded match
# twice, once with Luau and once with the GDScript sim (NO_LUAU_SIM), with the same scripted silos, SAMs,
# batteries, airfields and launches of every bomb kind, and checks that game.missiles, sim_ars.munitions, the
# structures and the arsenal stats are byte-identical (var_to_bytes, key order included) after every tick.
# Also checks Luau's copy of Godot's sort_custom on tied keys and the customs it carries (0.9x nuke speed, ICBM
# speed and 20% SAM evasion for the player's ICBM launches, MIRV warheads sharing the bus's roll and speed).
#   godot --headless --path . -s res://tests/test_luau_arsenal.gd
extends SceneTree

var fails := 0
const SETUP_T := 1200
const END_T := 2600


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _sort_check(vm: LuauVM) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 4242
	var bad := 0
	for n in range(1, 201):
		var keys := PackedFloat64Array()
		var arr := []
		for i in n:
			var key := float(r.randi_range(0, maxi(1, n / 7)) * 1000)
			keys.append(key)
			arr.append([key, i])
		arr.sort_custom(func(a, b): return a[0] > b[0])
		var got: PackedInt32Array = (vm.call_fn("Core/SimArsenal", "sort_check", [keys.to_byte_array()]) as PackedByteArray).to_int32_array()
		for i in n:
			if got[i] != int(arr[i][1]):
				bad += 1
				break
	_check(bad == 0, "Luau's sort == Godot's sort_custom on tied keys, sizes 1..200 (%d differ)" % bad)


func _biggest(m, skip: int) -> int:
	var best := -1
	for id in range(1, m.nations.size()):
		if id == skip or not m.nations[id].alive: continue
		if best < 0 or int(m.nations[id].land) > int(m.nations[best].land): best = id
	return best


func _build(m, o: int, k: int, n: int) -> int:
	var made := 0
	for t in m.W * m.H:
		if made >= n: break
		if m.owner_map[t] != o or t % 7 != 0: continue
		var s: Dictionary = m.sim_struct.place_site(o, k, t)
		if s.reason != "" or s.upgrade != null: continue
		m._struct_add(k, int(s.tile), o)
		m.struct_at[int(s.tile)].bt = 0.0
		made += 1
	return made


func _tile_of(m, r: RandomNumberGenerator, o: int) -> int:
	for _i in 4000:
		var t := r.randi_range(0, m.W * m.H - 1)
		if m.owner_map[t] == o: return t
	return -1


# a foreign, non-allied tile in reach of one of `by`'s airfields (or any tile of `o`)
func _tile_near_field(m, r: RandomNumberGenerator, by: int, o: int) -> int:
	var reach: float = m.sim_rules.airfield_range()
	for st in m.structs:
		if st.o != by or st.k != 14: continue
		var c := Vector2i(int(st.tile) % m.W, int(st.tile) / m.W)
		for _i in 400:
			var x := c.x + r.randi_range(-int(reach), int(reach))
			var y := c.y + r.randi_range(-int(reach), int(reach))
			if x < 0 or y < 0 or x >= m.W or y >= m.H: continue
			if Vector2(x - c.x, y - c.y).length() > reach - 1.0: continue
			var ow: int = m.owner_map[y * m.W + x]
			if ow > 0 and ow != by and not m.allied(by, ow): return y * m.W + x
	return _tile_of(m, r, o)


# the scripted part of the match (the same in both runs)
func _script(m, r: RandomNumberGenerator, t: int, st: Dictionary) -> void:
	if t == SETUP_T:
		var a: int = m.PLAYER if m.nations[m.PLAYER].alive and int(m.nations[m.PLAYER].land) > 200 else _biggest(m, -1)
		var b := _biggest(m, a)
		st.a = a; st.b = b
		for id in [a, b]:
			_build(m, id, 5, 3)
			_build(m, id, 4, 4)
			_build(m, id, 10, 2)
			_build(m, id, 14, 1)
			m.nations[id].gold += 1.0e10
		m.icbm_mode = true
		return
	if t <= SETUP_T or t > END_T or t % 30 != 0 or not st.has("a"): return
	var a: int = st.a
	var b: int = st.b
	var ks := [7, 8, 9, 11, 12]
	var k: int = ks[(t / 30) % ks.size()]
	var ta := _tile_of(m, r, b)
	if ta >= 0 and m.launch_nuke(a, k, ta): st.launched += 1
	var tb := _tile_of(m, r, a)
	if tb >= 0 and m.launch_nuke(b, 7, tb): st.launched += 1
	var ts := _tile_near_field(m, r, a, b)
	if ts >= 0 and m.sim_ars.launch_strike(a, SimRules.N_AIRSTRIKE, ts): st.strikes += 1


func _state_bytes(m) -> PackedByteArray:
	var t1 := []
	for s in m.sim_ars.sam_shots: t1.append([s.from, s.k, s.t0, s.t1, s.o])
	# "cuid" is the client's view id (client/game_state.gd nukes()), stamped lazily when the HUD reads the list
	# from inside a blast or SAM-hit callback; the GDScript sim erases bombs one by one between those callbacks,
	# the Luau facade updates the list once per call, so the counter can differ. It is not sim state.
	var ms := []
	for x in m.missiles:
		var d: Dictionary = x.duplicate()
		d.erase("cuid")
		ms.append(d)
	return var_to_bytes([ms, m.sim_ars.munitions, m.sim_ars.stats, m.structs, t1])


func _play(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.peace = 0.0
	var r := RandomNumberGenerator.new()
	r.seed = 77
	var st := {"launched": 0, "strikes": 0}
	var hashes := PackedInt64Array()
	var busy := 0
	var max_ms := 0
	var lu_ticks := 0
	for i in END_T + 200:
		var t: int = m.sim_atk.tick
		_script(m, r, t, st)
		m._sim_tick_whole()
		if m.sim_ars.lu_on() != null: lu_ticks += 1
		max_ms = maxi(max_ms, m.missiles.size())
		if not m.missiles.is_empty() or not m.sim_ars.munitions.is_empty(): busy += 1
		hashes.append(hash(_state_bytes(m)))
	var res := {"hashes": hashes, "stats": m.sim_ars.stats.duplicate(), "launched": st.launched, "strikes": st.strikes,
		"busy": busy, "max_ms": max_ms, "lu_ticks": lu_ticks,
		"owner": hash(m.owner_map), "err": m.luau_link.error if m.get("luau_link") != null else "", "a": st.get("a", -1)}
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
	_check(vm.boot() and vm.require_module("Core/SimState") and vm.require_module("Core/SimAttacks") and vm.require_module("Core/SimArsenal"),
		"SimArsenal loads (%s)" % vm.last_error)
	_sort_check(vm)
	var cu: Dictionary = vm.call_fn("Core/SimArsenal", "customs", [])
	var main_s: GDScript = load("res://game/nukes.gd")
	var consts: Dictionary = main_s.get_script_constant_map()
	_check(is_equal_approx(float(cu.nuke_speed_x), float(consts.NUKE_SPEED_X)) and is_equal_approx(float(cu.icbm_speed_x), float(consts.ICBM_SPEED_X)),
		"Luau's NUKE_SPEED_X %.2f and ICBM_SPEED_X %.2f == game/nukes.gd's" % [cu.nuke_speed_x, cu.icbm_speed_x])
	var state_s: GDScript = load("res://game/state.gd")
	_check(is_equal_approx(float(cu.icbm_evade_p), float(state_s.get_script_constant_map().ICBM_EVADE_P)),
		"Luau's ICBM_EVADE_P %.2f == game/state.gd's" % cu.icbm_evade_p)
	var lua: Dictionary = await _play(true)
	_check(lua.err == "" and int(lua.lu_ticks) > END_T, "the arsenal ran in Luau every tick (%d, %s)" % [lua.lu_ticks, lua.err])
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.lu_ticks) == 0, "the second run used the GDScript arsenal")
	_check(int(lua.launched) > 15 and int(lua.strikes) >= 3 and int(lua.max_ms) > 5,
		"scripted launches (%d bombs, %d strikes, up to %d missiles in flight)" % [lua.launched, lua.strikes, lua.max_ms])
	var s: Dictionary = lua.stats
	_check(int(s.sam_fired) > 0 and int(s.sam_hits) > 0 and int(s.shells) > 0 and int(s.struct_down) > 0,
		"SAMs fired %d / hit %d, shells %d, structures down %d" % [s.sam_fired, s.sam_hits, s.shells, s.struct_down])
	var ha: PackedInt64Array = lua.hashes
	var hb: PackedInt64Array = gd.hashes
	var first := -1
	for i in mini(ha.size(), hb.size()):
		if ha[i] != hb[i]:
			first = i
			break
	_check(first < 0 and ha.size() == hb.size(), "missiles, munitions, structures and stats identical to GDScript after each of %d ticks%s" % [ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_check(lua.stats == gd.stats and lua.launched == gd.launched and lua.owner == gd.owner, "same stats, launches and map at the end")
	var cl: Dictionary = await _icbm_customs(true)
	var cg: Dictionary = await _icbm_customs(false)
	OS.unset_environment("NO_LUAU_SIM")
	# CUSTOM: ICBM: the player's launches with the toggle on evade SAMs at 20% (seeded rng)
	var ev: Array = cl.evades
	var p := float(ev.count(true)) / maxf(1.0, float(ev.size()))
	_check(ev.size() >= 50 and ev == cg.evades and p > 0.05 and p < 0.40,
		"player ICBM launches evade %d of %d (%.0f%%, rolled at 20%%), the same rolls as GDScript" % [ev.count(true), ev.size(), p * 100.0])
	_check(cl.whs > 0 and cl.whs == cg.whs and cl.sig == cg.sig, "the ICBM MIRV splits into %d warheads, like GDScript's %d (same targets, rolls and speeds)" % [cl.whs, cg.whs])
	_done()


# CUSTOM: ICBM speed (x1.2 on top of the 0.9x nuke speed), the evade roll shared by MIRV warheads and Scattershot
# warheads, and the 0.9x speed of every other launch, through the Luau launch
func _icbm_customs(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.peace = 0.0
	for i in 900: m._sim_tick_whole()
	var P: int = m.PLAYER
	var foe := _biggest(m, P)
	_build(m, P, 5, 6)
	m.nations[P].gold += 1.0e10
	var r := RandomNumberGenerator.new()
	r.seed = 5
	var speed_ok := true
	var share_ok := true
	var n_icbm := 0
	var n_plain := 0
	for ic in [false, true]:
		m.icbm_mode = ic
		for k in [7, 8, 12, 9]:
			for _s in m.structs:
				if _s.o == P and _s.k == 5: _s.shots = []
			var tile := _tile_of(m, r, foe)
			var n0: int = m.missiles.size()
			if tile < 0 or not m.launch_nuke(P, k, tile): continue
			var ms: Dictionary = m.missiles[n0]
			var nk: int = ms.nk
			var want: int = m.flight_ticks(m.sim_rules.nuke_arc_ticks(ms.arc, nk), ic)
			if int(ms.ft) != want or bool(ms.icbm) != ic: speed_ok = false
			if ic: n_icbm += 1
			else: n_plain += 1
			for j in range(n0 + 1, m.missiles.size()):
				var w: Dictionary = m.missiles[j]
				if bool(w.evade) != bool(ms.evade) or bool(w.icbm) != ic: share_ok = false
	var tag := " (%s)" % ("Luau" if luau else "GDScript")
	_check(speed_ok and n_icbm >= 3 and n_plain >= 3, tag + " flight ticks = ceil(ft / (0.9 x 1.2 with ICBM)) on %d plain and %d ICBM launches" % [n_plain, n_icbm])
	_check(share_ok, tag + " Scattershot warheads share the core's evade roll and ICBM flag")
	# a MIRV bus splits; its warheads carry the bus's roll and speed
	var bus = null
	for ms in m.missiles:
		if int(ms.nk) == SimRules.N_MIRV and bool(ms.icbm): bus = ms
	var split_ok := bus != null
	var whs := 0
	var sig := []
	if bus != null:
		var land := int(bus.lt) + int(bus.ft)
		while m.sim_atk.tick <= land: m._sim_tick_whole()
		for w in m.missiles:
			if bool(w.get("mirv", false)) and int(w.nk) == SimRules.N_WARHEAD and int(w.lt) == land:
				whs += 1
				sig.append([w.to, w.ft, w.evade, w.icbm])
				if bool(w.evade) != bool(bus.evade) or not bool(w.icbm): split_ok = false
				var want_w: int = m.flight_ticks(m.sim_rules.nuke_arc_ticks(w.arc, SimRules.N_WARHEAD), true)
				if int(w.ft) < want_w or int(w.ft) > want_w + 15: split_ok = false
		split_ok = split_ok and whs > 0
		_check(split_ok, tag + " an ICBM MIRV splits into %d warheads with its roll and ICBM speed (+0..15 ticks)" % whs)
	else:
		_check(false, tag + " an ICBM MIRV was launched")
	# 60 more atom bombs with the toggle on: the evade rolls
	m.icbm_mode = true
	var evades := []
	for _i in 60:
		for _s in m.structs:
			if _s.o == P and _s.k == 5: _s.shots = []
		var tile := _tile_of(m, r, foe)
		var n0: int = m.missiles.size()
		if tile < 0 or not m.launch_nuke(P, 7, tile): continue
		evades.append(bool(m.missiles[n0].evade))
	m.queue_free()
	await process_frame
	return {"whs": whs, "sig": sig, "evades": evades}


func _done() -> void:
	print("LUAU_ARSENAL_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
