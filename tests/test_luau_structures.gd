# Step 5b of docs/LUAU_PORT.md: placement (place_site) and the construction countdown run in Luau
# (luau/sim/Core/SimStructures.luau). Checks Luau's place_site against the GDScript one on many clicks of a seeded
# match (every kind, own and foreign land, upgrades, ports), that construction counts down and activates through
# Luau, and that a direct write to a structure between ticks (the shop's instant build, the tests' bt = 0) wins.
#   godot --headless --path . -s res://tests/test_luau_structures.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _same_site(a: Dictionary, b: Dictionary) -> bool:
	return int(a.tile) == int(b.tile) and str(a.reason) == str(b.reason) and is_same(a.upgrade, b.upgrade)


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
	for i in 1500:
		m._sim_tick_whole()
	_check(m.sim_struct._lu() != null, "structures run in Luau (%s)" % m.luau_link.error)
	if m.sim_struct._lu() == null:
		_done()
		return
	_check(m.structs.size() > 20, "a match with structures (%d)" % m.structs.size())
	# place_site: Luau == GDScript on clicks near every structure and on random tiles, every kind
	var r := RandomNumberGenerator.new()
	r.seed = 99
	var n := 0
	var bad := 0
	var ups := 0
	var reasons := {}
	var kinds := [0, 1, 2, 3, 4, 5, 10, 14, 15]
	for st in m.structs.duplicate():
		for k in kinds:
			var t: int = int(st.tile) + r.randi_range(-6, 6) + r.randi_range(-6, 6) * m.W
			t = clampi(t, 0, m.W * m.H - 1)
			for o in [int(st.o), m.PLAYER]:
				var a: Dictionary = m.sim_struct.place_site(o, k, t)
				var b: Dictionary = m.sim_struct.place_site_gd(o, k, t)
				n += 1
				if not _same_site(a, b): bad += 1
				if a.upgrade != null: ups += 1
				reasons[str(a.reason)] = true
	for _i in 600:
		var t := r.randi_range(0, m.W * m.H - 1)
		var o: int = m.owner_map[t] if m.owner_map[t] > 0 else m.PLAYER
		var k: int = kinds[r.randi_range(0, kinds.size() - 1)]
		var a: Dictionary = m.sim_struct.place_site(o, k, t)
		var b: Dictionary = m.sim_struct.place_site_gd(o, k, t)
		n += 1
		if not _same_site(a, b): bad += 1
		reasons[str(a.reason)] = true
	_check(bad == 0, "place_site in Luau == GDScript on %d clicks (%d upgrades, outcomes %s; %d differ)" % [n, ups, str(reasons.keys()), bad])
	# construction: a new building counts down through Luau and activates
	var tile := -1
	var P: int = m.PLAYER
	for t in m.border[P]:
		var s: Dictionary = m.sim_struct.place_site(P, 3, int(t))
		if s.reason == "" and s.upgrade == null:
			tile = int(s.tile)
			break
	_check(tile >= 0, "a free site for a defense post")
	if tile >= 0:
		m._struct_add(3, tile, P)
		var st: Dictionary = m.struct_at[tile]
		var b0: float = st.bt
		m._sim_tick_whole()
		_check(is_equal_approx(float(st.bt), maxf(0.0, b0 - 0.1)), "construction counts down 0.1 s per tick (%.2f -> %.2f)" % [b0, st.bt])
		st.bt = 0.0  # the shop's instant build / the tests' direct write, between ticks
		m._sim_tick_whole()
		_check(float(st.bt) == 0.0 and m.def_posts.has(P) and (m.def_posts[P] as PackedInt32Array).has(tile),
			"a direct bt = 0 between ticks wins; the post counts as finished")
		# an artillery battery activates through Luau (its first shot gap is drawn on activation)
		var at := -1
		var big := P
		for id in range(1, m.nations.size()):
			if m.nations[id].alive and int(m.nations[id].land) > int(m.nations[big].land): big = id
		for _j in 20000:
			var t2 := r.randi_range(0, m.W * m.H - 1)
			if m.owner_map[t2] != big: continue
			var s2: Dictionary = m.sim_struct.place_site(big, 10, t2)
			if s2.reason == "" and s2.upgrade == null:
				at = int(s2.tile)
				break
		_check(at >= 0, "a free site for an artillery battery")
		if at >= 0:
			m._struct_add(10, at, big)
			var art: Dictionary = m.struct_at[at]
			art.bt = 0.15
			m._sim_tick_whole()
			_check(not art.has("next_fire"), "still building after one tick (%.2f left)" % art.bt)
			m._sim_tick_whole()
			_check(float(art.bt) == 0.0 and art.has("next_fire"), "activates when the countdown ends")
	_done()


func _done() -> void:
	print("LUAU_STRUCTURES_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
