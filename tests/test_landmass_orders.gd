# Same-continent wilderness must be a land expansion, not a boat order that then fails.
# Reproduces the vanilla web bug: hover said "Click: boat invasion" on distant unclaimed
# land on the player's landmass; the click called launch_boat, which returned false.
#   godot --headless --path . --script tests/test_landmass_orders.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _initialize() -> void:
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	await _frames(2)
	m.map_tab = 0
	m.map_i = 0
	m.rng.seed = 20261121
	seed(20261121)
	m._start_game()
	await _frames(2)
	_check(m.W == 2000 and m.H == 1000, "World is native 2000x1000 (got %dx%d)" % [m.W, m.H])
	_check(m.land_comp.size() == m.W * m.H, "land_comp is filled for the map")

	var st: int = m._find_spawn_tile(int(m.W * 0.52), int(m.H * 0.30))
	_check(st >= 0, "found a spawn tile")
	m._place_start(st)
	m.deploy_t = 0.0
	m.state = "play"
	m.peace = 0.0
	m._claim_blob(m.PLAYER, st, 40)
	m.nations[m.PLAYER].troops = 50000.0
	m.nations[m.PLAYER].gold = 1.0e9
	m.set_speed(0)
	m.sim_paused = true
	await _frames(3)
	m.client.interact.enabled = true
	m.client.ctx.rules.invalidate()

	var cid: int = m.land_comp[st]
	_check(cid > 0, "spawn tile is on a landmass (id %d)" % cid)
	_check(m._shares_land_border(m.PLAYER, m.NEUTRAL), "player borders unclaimed land")

	# BFS over this landmass's unclaimed tiles: need a tile farther than the old 18000-step cap (~75).
	var W: int = m.W
	var n: int = W * m.H
	var depth := {}
	var q: Array[int] = []
	for t in m.border[m.PLAYER].keys():
		for d in [1, -1, W, -W]:
			var j: int = int(t) + d
			if j < 0 or j >= n:
				continue
			if m.owner_map[j] == m.NEUTRAL and m.land_comp[j] == cid and not depth.has(j):
				depth[j] = 1
				q.append(j)
	var qi := 0
	var adj := -1
	var far := -1
	var mid := -1
	while qi < q.size():
		var t2: int = q[qi]
		qi += 1
		var dd: int = depth[t2]
		if dd == 1 and adj < 0:
			adj = t2
		if dd >= 40 and mid < 0:
			mid = t2
		if dd >= 120 and far < 0:
			far = t2
			break
		var x2 := t2 % W
		for d in [1, -1, W, -W]:
			if (d == 1 and x2 == W - 1) or (d == -1 and x2 == 0):
				continue
			var j2: int = t2 + d
			if j2 < 0 or j2 >= n:
				continue
			if m.owner_map[j2] == m.NEUTRAL and m.land_comp[j2] == cid and not depth.has(j2):
				depth[j2] = dd + 1
				q.append(j2)
	if far < 0:
		far = mid
	_check(adj >= 0, "found adjacent unclaimed land")
	_check(far >= 0, "found distant same-landmass wilderness (depth scan %d tiles)" % depth.size())

	for pair in [[adj, "adjacent"], [far, "distant same-landmass"]]:
		var tile: int = pair[0]
		if tile < 0:
			continue
		_check(m._shares_land_border(m.PLAYER, m.NEUTRAL, tile), "%s tile shares a landmass with the player" % pair[1])
		m.client.ctx.rules.invalidate()
		var act: Dictionary = m.client.ctx.rules.primary(tile)
		_check(str(act.type) == "expand" and act.ok, "%s primary is expand (got %s ok=%s reason=%s)" % [pair[1], act.type, act.ok, act.get("reason", "")])
		var spec: Dictionary = m.client.interact.hover_spec(tile)
		_check("expand" in str(spec.get("hint", "")).to_lower() or "expand" in str(spec.get("title", "")).to_lower() or "Click: expand" in str(spec) or "Expand" in str(spec.get("hint", "")), "%s hover is an expansion (hint='%s')" % [pair[1], str(spec.get("hint", ""))])

	# A real click (InputEvent through the viewport) on distant wilderness starts a land attack, not a boat.
	if far >= 0:
		if m.minput == null:
			m._make_minput()
		m.mcam.halt()
		m.mcam.set_scale_immediate(maxf(m.mcam.scale, 6.0))
		m.mcam.look_at(far % W + 0.5, far / W + 0.5)
		await _frames(2)
		var pos: Vector2 = m.client.ctx.tile_screen_pos(far)
		var back: int = m.client.ctx.tile_at(pos)
		_check(back == far, "screen -> tile for the distant target (got %d, pos %s)" % [back, str(pos)])
		var a0 := 0
		for a in m.attacks:
			if int(a.a) == m.PLAYER:
				a0 += 1
		var b0 := 0
		for b in m.boats:
			if int(b.get("a", b.get("o", -1))) == m.PLAYER:
				b0 += 1
		var tr0: float = m.nations[m.PLAYER].troops
		m.client.interact._last_click_tile = -1
		m.client.ctx.rules.invalidate()
		# Headless has a 0x0 window, so Viewport.push_input does not reliably deliver the
		# button-up (the press is recorded, then dropped). Drive the same InputEventMouseButton
		# through main._unhandled_input, which is the live path once the OS event arrives.
		for down in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = down
			ev.position = pos
			ev.global_position = pos
			ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
			m._unhandled_input(ev)
		await _frames(3)
		var a1 := 0
		for a in m.attacks:
			if int(a.a) == m.PLAYER:
				a1 += 1
		_check(a1 > a0 or m.nations[m.PLAYER].troops < tr0 - 0.5, "click on distant same-landmass wilderness starts a land attack (attacks %d->%d troops %.0f->%.0f)" % [a0, a1, tr0, m.nations[m.PLAYER].troops])
		var b1 := 0
		for b in m.boats:
			if int(b.get("a", b.get("o", -1))) == m.PLAYER:
				b1 += 1
		_check(b1 == b0, "  ... and does not launch a boat (player boats %d -> %d)" % [b0, b1])

	# A coastal tile on a different landmass (if any) is still a boat.
	var overseas := -1
	for t in range(0, n, 91):
		if m.owner_map[t] != m.NEUTRAL and m.owner_map[t] <= 0:
			continue
		if m.land_comp[t] == cid or m.land_comp[t] == 0:
			continue
		if m.owner_map[t] == m.PLAYER:
			continue
		m.client.ctx.rules.invalidate()
		var a3: Dictionary = m.client.ctx.rules.primary(t)
		if str(a3.type) == "boat" and a3.ok:
			overseas = t
			break
	if overseas >= 0:
		_check(not m._shares_land_border(m.PLAYER, m.NEUTRAL, overseas) or m.owner_map[overseas] > 0, "overseas target is not the player's landmass (or is a foreign nation)")
		print("  (overseas boat candidate tile %d owner %d comp %d)" % [overseas, m.owner_map[overseas], m.land_comp[overseas]])
	else:
		print("  (no overseas boat candidate on this seed; land-vs-boat on this continent still checked)")

	print("LANDMASS_ORDERS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
