# Step 5d3 of docs/LUAU_PORT.md: warships, their shells and the defense posts' shells run in Luau
# (luau/sim/Core/SimWarships.luau). Plays the seeded match twice, once with Luau and once with the GDScript sim
# (NO_LUAU_SIM), and checks after every tick that the warships (every key, in order), the shells, the target
# table, the posts' memory, the stats, the transports, the trade ships, every nation's gold, the notes and the rng
# are identical.
#   godot --headless --path . -s res://tests/test_luau_warships.gd
extends SceneTree

const END_T := 5000

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _ref_row(tg) -> Array:
	if tg == null: return []
	var r: Dictionary = tg.ref
	return [tg.kind, r.get("uid", -1), r.get("o", r.get("a", -1)), r.get("d", 0.0), r.get("tile", -1)]


func _state_bytes(m) -> PackedByteArray:
	var W = m.sim_ws
	var ships := []
	for ws in m.warships:
		var row := []
		for k in ws:
			var v = ws[k]
			if k == "port": v = -1 if v == null else int(v.tile)
			row.append([k, v])
		ships.append(row)
	var shs := []
	for s in W.shells:
		shs.append([s.keys(), s.shooter.get("uid", -1), s.shooter.get("tile", -1), s.o, _ref_row(s.target), s.t1, s.dmg, s.from, s.t0])
	var tr := []
	for uid in W.tref: tr.append([uid, _ref_row(W.tref[uid])])
	var boats := []
	for bt in m.boats: boats.append([bt.keys(), bt.a, bt.get("uid", -1), bt.d])
	var trs := []
	for t in m.traders:
		trs.append([t.keys(), t.o, t.d, t.pts, t.cum, t.gold, t.get("orig", 0), t.get("sailed", 0.0),
			int(t.dst.tile) if t.dst is Dictionary else -1])
	var gold := PackedFloat64Array()
	for n in m.nations: gold.append(float(n.get("gold", 0.0)))
	var notes := []
	for n in m.notes: notes.append(n.text)
	return var_to_bytes([ships, shs, tr, W._post_last, W._post_shelled, W.stats, W.next_uid, W._capture_msg,
		boats, trs, gold, notes, m.shells.size(), m.rng.state])


func _play(luau: bool) -> Dictionary:
	if luau: OS.unset_environment("NO_LUAU_SIM")
	else: OS.set_environment("NO_LUAU_SIM", "1")
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	m.rng.seed = 5516; seed(5516)
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	var hashes := PackedInt64Array()
	var max_ws := 0
	var vets := 0
	var routes := 0
	for i in END_T:
		m._sim_tick_whole()
		max_ws = maxi(max_ws, m.warships.size())
		for ws in m.warships:
			if int(ws.get("vet", 0)) > 0: vets += 1
			if ws.has("nav_r"): routes += 1
		hashes.append(hash(_state_bytes(m)))
	var res := {"hashes": hashes, "max_ws": max_ws, "vets": vets, "routes": routes, "stats": m.sim_ws.stats.duplicate(),
		"calls": m.sim_ws.luau_calls, "resumes": m.sim_ws.luau_resumes, "err": m.luau_link.error if m.get("luau_link") != null else ""}
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
	_check(vm.boot() and vm.require_module("Core/SimState") and vm.require_module("Core/SimNav") and vm.require_module("Core/SimWarships"),
		"SimWarships loads (%s)" % vm.last_error)
	var lua: Dictionary = await _play(true)
	_check(lua.err == "" and int(lua.calls) > 1000, "the warships ran in Luau (%d calls, %s)" % [lua.calls, lua.err])
	var gd: Dictionary = await _play(false)
	OS.unset_environment("NO_LUAU_SIM")
	_check(int(gd.calls) == 0, "the second run used the GDScript warships")
	var s: Dictionary = gd.stats
	_check(int(lua.max_ws) > 3 and int(s.shots) > 50 and int(s.sunk_transports) + int(s.sunk_warships) > 3 and int(lua.routes) > 100,
		"a match with warships (up to %d, stats %s, %d ship-ticks on a route, %d with veterancy)" % [lua.max_ws, str(s), lua.routes, lua.vets])
	var ha: PackedInt64Array = lua.hashes
	var hb: PackedInt64Array = gd.hashes
	var first := -1
	for i in mini(ha.size(), hb.size()):
		if ha[i] != hb[i]:
			first = i
			break
	_check(first < 0 and ha.size() == hb.size(), "warships, shells, targets, posts, stats, boats, trade ships, gold, notes and rng identical to GDScript after each of %d ticks%s" % [ha.size(), "" if first < 0 else " (first difference after tick %d)" % first])
	_check(lua.stats == gd.stats, "same stats (%s)" % str(lua.stats))
	_check(int(lua.resumes) > 0, "ticks stopped for the AI's answer to a lost ship and went on (%d)" % lua.resumes)
	# custom (CLAUDE.md, 2026-11-25): a warship capturing a trade ship plays no sound
	var src := FileAccess.get_file_as_string("res://luau/sim/Core/SimWarships.luau")
	var a := src.find("local function capture_trade(")
	var b := src.find("\nlocal function ", a + 10)
	var body := src.substr(a, b - a) if a >= 0 and b > a else ""
	_check(body != "" and not body.contains("E_SFX") and src.contains("-- CUSTOM: a capture plays no sound"), "custom: a capture plays no sound (no sound event in capture_trade)")
	_done()


func _done() -> void:
	print("LUAU_WARSHIPS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
