# Step 5d of docs/LUAU_PORT.md (draft): the trade ships' ports tick runs in Luau (luau/sim/Core/SimNaval.luau, its
# route searches through Core/SimNav.luau); sim/naval.gd is its face. Plays the same seeded match twice, once with
# Luau and once with the GDScript sim (NO_LUAU_SIM), and checks after every tick that the ports' trade fields, the
# trade ships, the nations' gold, the owner map and the sim rng are byte-identical (var_to_bytes, key order included).
#   godot --headless --path . -s res://tests/test_luau_naval.gd
extends SceneTree

const TICKS := 4000
var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _state_bytes(m) -> PackedByteArray:
	var ports := []
	for s in m.structs:
		if s.k == 1: ports.append(s)
	var trs := []
	for tr in m.traders:
		var d: Dictionary = tr.duplicate()
		if d.get("src") is Dictionary: d.src = int(tr.src.tile)
		if d.get("dst") is Dictionary: d.dst = int(tr.dst.tile)
		trs.append(d)
	var gold := PackedFloat64Array()
	for n in m.nations: gold.append(float(n.get("gold", 0.0)))
	return var_to_bytes([ports, trs, gold, m.owner_map, m.rng.state])


func _play(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var hashes := PackedInt64Array()
	var made := 0
	var n_prev := 0
	for i in TICKS:
		m._sim_tick_whole()
		var n: int = m.traders.size()
		if n > n_prev: made += n - n_prev
		n_prev = n
		hashes.append(hash(_state_bytes(m)))
	var ports := 0
	for s in m.structs:
		if s.k == 1: ports += 1
	var res := {"hashes": hashes, "calls": m.sim_naval.luau_calls, "nav": m.sim_nav.on_luau(), "made": made,
		"ports": ports, "err": m.luau_link.error if m.get("luau_link") != null else ""}
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
	_check(vm.boot() and vm.require_module("Core/SimNaval"), "SimNaval.luau loads (%s)" % vm.last_error)
	var lua: Dictionary = await _play(true)
	_check(lua.err == "" and bool(lua.nav) and int(lua.calls) > 50,
		"the ports tick ran in Luau (%d calls, nav in Luau %s, %s)" % [lua.calls, lua.nav, lua.err])
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.calls) == 0 and not bool(gd.nav), "the second run used the GDScript ports tick")
	_check(int(lua.made) > 20, "trade ships sailed (%d made, %d ports at the end)" % [lua.made, lua.ports])
	var ha: PackedInt64Array = lua.hashes
	var hb: PackedInt64Array = gd.hashes
	var first := -1
	for i in mini(ha.size(), hb.size()):
		if ha[i] != hb[i]:
			first = i
			break
	_check(first < 0 and ha.size() == hb.size(), "ports, trade ships, gold, owner map and rng identical to GDScript after each of %d ticks%s" % [ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_check(lua.made == gd.made, "same trade ships made (%d vs %d)" % [lua.made, gd.made])
	_done()


func _done() -> void:
	print("LUAU_NAVAL_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
