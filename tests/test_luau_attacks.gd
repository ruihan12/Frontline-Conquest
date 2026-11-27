# Step 5a of docs/LUAU_PORT.md: the attack pass runs in Luau (luau/sim/Core/SimAttacks.luau) and
# sim/attacks.gd is its face. Checks that Luau's per-nation state (land, bounding box, last_by, border sets in
# order) stays equal to GDScript's through a seeded match, that g.attacks mirrors Luau's list, and that the
# order calls (start, retreat, end_attack) and the arsenal's troop cuts go through Luau.
#   godot --headless --path . -s res://tests/test_luau_attacks.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


# Luau's land / bb / last_by / border lists == GDScript's (border dict key order included). Returns mismatching ids.
func _diff_nations(m) -> int:
	var nb: PackedInt32Array = (m.luau_link.vm.call_fn("Core/SimState", "nations_bytes") as PackedByteArray).to_int32_array()
	var k := 0
	var bad := 0
	var nn: int = m.nations.size()
	for id in nn:
		if k >= nb.size():
			return bad + nn - id
		var n: Dictionary = m.nations[id]
		var r: Rect2i = n.get("bb", Rect2i())
		var ok: bool = nb[k] == int(n.get("land", 0)) and nb[k + 1] == r.position.x and nb[k + 2] == r.position.y \
			and nb[k + 3] == r.size.x and nb[k + 4] == r.size.y and nb[k + 5] == int(n.get("last_by", 0))
		var cnt: int = nb[k + 6]
		var keys: Array = m.border[id].keys() if id < m.border.size() else []
		ok = ok and cnt == keys.size()
		if ok:
			for j in cnt:
				if nb[k + 7 + j] != int(keys[j]):
					ok = false
					break
		k += 7 + cnt
		if not ok: bad += 1
	return bad


func _mirror_ok(m) -> bool:
	var mir: Dictionary = m.sim_atk._mir
	if mir.size() != m.attacks.size(): return false
	for a in m.attacks:
		if mir.get(int(a.aid)) != a or a.get("dead", false): return false
	return true


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
	_check(m.sim_atk._L(), "attacks run in Luau (%s)" % m.luau_link.error)
	if not m.sim_atk._L():
		_done()
		return
	var bad := 0
	var mbad := 0
	var seen := 0
	for i in 600:
		m._sim_tick_whole()
		seen = maxi(seen, m.attacks.size())
		if (i + 1) % 100 == 0:
			bad += _diff_nations(m)
			if not _mirror_ok(m): mbad += 1
	_check(seen > 0, "attacks ran (up to %d at once)" % seen)
	_check(bad == 0, "land, bounding boxes, last_by and border order equal every 100 ticks (%d mismatches)" % bad)
	_check(mbad == 0, "g.attacks mirrors Luau's list (same ids, same dicts)")
	_check(int(m.luau_link.vm.call_fn("Core/SimState", "anomaly_count")) == 0, "no border-set anomalies in Luau")
	# the player's orders: start, retreat, end_attack
	var P: int = m.PLAYER
	var tg := -1
	for t in m.border[P]:
		for nb in [t - 1, t + 1, t - m.W, t + m.W]:
			if nb >= 0 and nb < m.owner_map.size() and m.owner_map[nb] != P and m.owner_map[nb] >= 0:
				tg = m.owner_map[nb]
				break
		if tg >= 0: break
	var send: float = floorf(float(m.nations[P].troops) * 0.2)
	m.nations[P].troops -= send
	var a = m.sim_atk.start(P, tg, send)
	_check(a != null and int(a.a) == P and int(a.t) == tg and m.attacks.has(a) and m.sim_atk._mir.has(int(a.aid)),
		"start: a new attack comes back as a mirror dict in g.attacks (target %d)" % tg)
	if a != null:
		var aid := int(a.aid)
		m.sim_atk.retreat(a)
		_check(int(a.retreat_at) > 0, "retreat: retreat_at set through Luau (%d)" % int(a.retreat_at))
		var tr: float = m.nations[P].troops
		var held: float = a.troops + a.pend
		m.sim_atk.end_attack(a, true)
		_check(a.get("dead", false) and not m.attacks.has(a) and not m.sim_atk._mir.has(aid),
			"end_attack: the attack leaves g.attacks and is marked dead")
		_check(float(m.nations[P].troops) >= tr + floorf(maxf(held - a.pend, 0.0)) - 1.0, "end_attack gives the troops back (%.0f -> %.0f)" % [tr, m.nations[P].troops])
	# arsenal cuts: scale_owner / set_troops reach Luau's records
	var b = null
	for x in m.attacks:
		if float(x.troops) > 10.0:
			b = x
			break
	if b != null:
		var o: int = b.a
		var before: float = b.troops
		m.sim_atk.scale_owner(o, 0.5)
		_check(is_equal_approx(float(b.troops), before * 0.5), "scale_owner halves an owner's attacks (%.1f -> %.1f)" % [before, b.troops])
		m.sim_atk.set_troops(b, 3.0)
		_check(is_equal_approx(float(b.troops), 3.0), "set_troops sets one attack's troops")
		m._sim_tick_whole()
		_check(_diff_nations(m) == 0 and _mirror_ok(m), "still equal on the next tick")
	_done()


func _done() -> void:
	print("LUAU_ATTACKS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
