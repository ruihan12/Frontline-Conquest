# Step 4 of docs/LUAU_PORT.md: Luau's tile layer (luau/sim/Core/SimState.luau) stays equal to the GDScript one
# (owner_map, fallout) through a seeded match: GDScript writes go to Luau (sim/luau_link.gd flush), Luau
# writes come back through _set_owner (pull), a nuke's fallout and its recapture, a new map.
#   godot --headless --path . -s res://tests/test_luau_state.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _same(m) -> bool:
	var vm: LuauVM = m.luau_link.vm
	var ob: Variant = vm.call_fn("Core/SimState", "owner_bytes")
	var fb: Variant = vm.call_fn("Core/SimState", "fallout_bytes")
	return ob is PackedByteArray and fb is PackedByteArray and ob == m.owner_map.to_byte_array() and fb == m.fallout


func _run() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	m.peace = 0.0
	m._sim_tick_whole()
	_check(m.luau_link != null and m.luau_link.on, "link on after the first tick (%s)" % ("" if m.luau_link == null else m.luau_link.error))
	if m.luau_link == null or not m.luau_link.on:
		_done()
		return
	_check(_same(m), "Luau starts from copies of owner_map and fallout")
	var bad := 0
	var us := 0
	for i in 600:
		var t0 := Time.get_ticks_usec()
		m._sim_tick_whole()
		us += Time.get_ticks_usec() - t0
		if (i + 1) % 100 == 0 and not _same(m): bad += 1
	_check(bad == 0, "equal every 100 ticks through 600 ticks of GDScript writes (%d mismatches)" % bad)
	# a nuke between ticks: tiles relinquished + fallout, then the next tick end sends them
	var target := -1
	var best := 0
	for id in range(2, m.nations.size()):
		var n = m.nations[id]
		if n.alive and int(n.land) > best:
			best = int(n.land); target = id
	var tn = m.nations[target]
	var c := Vector2(float(tn.sx) / float(tn.land), float(tn.sy) / float(tn.land))
	var before: int = m.fallout_list.size()
	m.sim_ars.nuke_blast(m.PLAYER, c, 8.0, SimRules.N_ATOM)
	var made: int = m.fallout_list.size() - before
	m.luau_link.sync(m)
	_check(made > 0 and _same(m), "a nuke's owner changes and %d fallout tiles reach Luau" % made)
	for i in 300:
		m._sim_tick_whole()
	var left: int = m.fallout_list.size()
	_check(_same(m), "equal after 300 more ticks (fallout tiles left %d of %d; recaptured ones cleared on both)" % [left, before + made])
	# Luau writes: a helper module sets tiles through SimState, pull() applies them with _set_owner
	var vm: LuauVM = m.luau_link.vm
	var ok_load := vm.load_source("state_check", "local S = require('Core/SimState')\nlocal M = {}\nfunction M.write(t, o, f)\n\tlocal st = S.cur\n\tst:set_owner(t, o)\n\tif f >= 0 then st:set_fallout(t, f) end\n\treturn st:get_owner(t)\nend\nreturn M\n")
	_check(ok_load, "load a Luau writer (%s)" % vm.last_error)
	var pt := -1
	var victim := -1
	for t in m.owner_map.size():
		var o: int = m.owner_map[t]
		if o > 1 and o != target:
			pt = t; victim = o; break
	var land_v: int = m.nations[victim].land
	var land_p: int = m.nations[m.PLAYER].land
	m.luau_link.flush(m)
	var got: Variant = vm.call_fn("state_check", "write", [pt, m.PLAYER, -1])
	m.luau_link.pull(m)
	_check(int(got) == m.PLAYER and m.owner_map[pt] == m.PLAYER and m.luau_link.applied_owner == 1
		and int(m.nations[victim].land) == land_v - 1 and int(m.nations[m.PLAYER].land) == land_p + 1,
		"a Luau owner write reaches owner_map through _set_owner (land counts follow)")
	# fallout written by Luau on a neutral tile, then a Luau owner write that GDScript's _set_owner clears it for
	var nt := -1
	for t in m.owner_map.size():
		if m.owner_map[t] == m.NEUTRAL and m.fallout[t] == 0:
			nt = t; break
	vm.call_fn("state_check", "write", [nt, m.NEUTRAL, 1])
	m.luau_link.pull(m)
	_check(m.fallout[nt] == 1 and m.fallout_list.has(nt) and _same(m), "a Luau fallout write reaches fallout / fallout_list")
	vm.call_fn("state_check", "write", [nt, m.PLAYER, -1])
	m.luau_link.pull(m)
	_check(m.fallout[nt] == 0 and not m.fallout_list.has(nt), "owning the tile clears its fallout in GDScript (_set_owner)")
	m.luau_link.flush(m)
	_check(_same(m), "and that clear reaches Luau with the next flush")
	m._sim_tick_whole()
	_check(_same(m), "equal at the next tick boundary")
	# a new map: Luau starts again from copies
	m.rng.seed = 77; seed(77)
	hs.start(1, 0, Vector2(0.5, 0.5), 0, -1.0)
	m.peace = 0.0
	for i in 50:
		m._sim_tick_whole()
	_check(m.luau_link.epoch == m.sim_epoch and _same(m), "a new map (random map) restarts the copy (%dx%d)" % [m.W, m.H])
	print("  info 600 ticks with the link: %.2f ms/tick avg" % (us / 600.0 / 1000.0))
	_done()


func _done() -> void:
	print("LUAU_STATE_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
