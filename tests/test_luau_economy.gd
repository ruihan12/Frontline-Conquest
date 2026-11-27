# Step 5e of docs/LUAU_PORT.md: troop growth, gold income and the reinforcement cooldown run in Luau
# (luau/sim/Core/SimEconomy.luau). Plays the seeded match twice, once with Luau and once with the GDScript sim
# (NO_LUAU_SIM), and checks after every tick that every nation's troops, gold, regen, cooldown, alive flag and land,
# the stats, the notes and the rng are identical. Then turns on the console's god mode (a custom) in both and checks
# the player's numbers again.
#   godot --headless --path . -s res://tests/test_luau_economy.gd
extends SceneTree

const END_T := 3000
const GOD_T := 50

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _state_bytes(m) -> PackedByteArray:
	var nat := []
	for n in m.nations:
		nat.append([n.keys(), n.get("troops", 0.0), n.get("gold", 0.0), n.get("regen", 0.0), n.get("reinf_cd", 0.0),
			n.get("alive", false), n.get("land", 0)])
	var notes := []
	for n in m.notes: notes.append(n.text)
	return var_to_bytes([nat, m.stats, notes, m.rng.state])


func _play(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var hashes := PackedInt64Array()
	var deaths := 0
	var alive0 := 0
	for n in m.nations:
		if n.get("alive", false): alive0 += 1
	for i in END_T:
		m._sim_tick_whole()
		hashes.append(hash(_state_bytes(m)))
	var alive1 := 0
	for n in m.nations:
		if n.get("alive", false): alive1 += 1
	deaths = alive0 - alive1
	var calls: int = m.econ_luau_calls
	var err: String = m.luau_link.error if m.get("luau_link") != null else ""
	m.queue_free()
	await process_frame
	await process_frame
	# the console's god mode on a new match, where the player is alive
	hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	for i in 20: m._sim_tick_whole()
	m.god_mode = true
	var god := []
	var alive := true
	for i in GOD_T:
		m._sim_tick_whole()
		var p = m.nations[m.PLAYER]
		alive = alive and bool(p.alive)
		god.append([p.troops, p.gold, p.reinf_cd, m.rail_cd, hash(_state_bytes(m))])
	var p = m.nations[m.PLAYER]
	var res := {"hashes": hashes, "deaths": deaths, "calls": calls, "god": god, "god_gold": float(p.gold),
		"god_cd": float(p.reinf_cd), "god_alive": alive, "err": err}
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
	_check(vm.boot() and vm.require_module("Core/SimEconomy"), "SimEconomy loads (%s)" % vm.last_error)
	var lua: Dictionary = await _play(true)
	_check(lua.err == "" and int(lua.calls) >= END_T - 5, "the economy ran in Luau (%d calls, %s)" % [lua.calls, lua.err])
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.calls) == 0, "the second run used the GDScript economy")
	_check(int(lua.deaths) > 20, "a match where nations die (%d)" % lua.deaths)
	var ha: PackedInt64Array = lua.hashes
	var hb: PackedInt64Array = gd.hashes
	var first := -1
	for i in mini(ha.size(), hb.size()):
		if ha[i] != hb[i]:
			first = i
			break
	_check(first < 0 and ha.size() == hb.size(), "troops, gold, regen, cooldowns, deaths, land, stats, notes and rng identical to GDScript after each of %d ticks%s" % [ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_check(var_to_bytes(lua.god) == var_to_bytes(gd.god), "custom: god mode gives the player the same numbers in both (%d ticks)" % GOD_T)
	_check(bool(lua.god_alive) and float(lua.god_gold) >= 999e6 and float(lua.god_cd) == 0.0, "custom: god mode keeps the player's gold at 999M or more and the cooldown at 0")
	_done()


func _done() -> void:
	print("LUAU_ECONOMY_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
