# Real input on World (native 2000x1000): mouse / key InputEvents pushed through the root viewport
# into the main scene (main._unhandled_input -> MapInput -> UIInteract -> Session -> sim).
#   godot --headless --path . --script tests/test_input_world.gd
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 --script tests/test_input_world.gd
# (the second also covers Space at the pointer: the HUD hover reads the OS pointer, absent headless)
# Checks: spawn pick, a click on adjacent unclaimed land and on unclaimed land that is contiguous but
# not adjacent are LAND expansions (no boat, no "boat orders" toast), the hover hint over contiguous
# land says expand, a click on a nation across the ocean is a boat, Space at the pointer, a right
# click opens the action ring, key 1 + click builds a City, and a silo + atom aim launches.
extends SceneTree

var fails := 0
var m
var toasts: Array = []


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _push(ev: InputEvent) -> void:
	root.push_input(ev, true)


func _mouse_to(pos: Vector2) -> void:
	# (a real window: the OS pointer, which the HUD's hover reads; a no-op headless)
	root.warp_mouse(pos)
	var mv := InputEventMouseMotion.new()
	mv.position = pos
	mv.global_position = pos
	_push(mv)


func _button(pos: Vector2, idx: int) -> void:
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = idx
		b.pressed = down
		b.position = pos
		b.global_position = pos
		_push(b)


func _key(code: int) -> void:
	for down in [true, false]:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = down
		_push(k)


## Centres the camera on `tile`, moves the pointer over it and returns its screen position.
func _aim(tile: int) -> Vector2:
	# The deployment tween drives Camera2D independently of MapCamera.halt().
	# Wait through the hover frames before checking the point we will click.
	for _try in 40:
		m.mcam.halt()
		m.mcam.set_scale_immediate(maxf(m.mcam.scale, 6.0))
		m.mcam.look_at(tile % m.W + 0.5, tile / m.W + 0.5)
		await _frames(1)
		var pos: Vector2 = m.client.ctx.tile_screen_pos(tile)
		if pos.x < 0.0 or m.client.ctx.tile_at(pos) != tile:
			continue
		_mouse_to(pos)
		await _frames(2)
		if m.client.ctx.tile_at(pos) == tile:
			return pos
	_check(false, "pointer stayed on tile %d through the hover frames" % tile)
	return Vector2(-1, -1)


func _click(tile: int, idx := MOUSE_BUTTON_LEFT) -> Vector2:
	var pos: Vector2 = await _aim(tile)
	if pos.x < 0.0:
		return pos
	m.client.interact._last_click_tile = -1
	m.client.ctx.rules.invalidate()
	_button(pos, idx)
	await _frames(2)
	return pos


func _boat_toasts() -> int:
	var n := 0
	for nt in m.notes:
		var t := str(nt.get("text", ""))
		if "boat" in t.to_lower() or "transport" in t.to_lower():
			n += 1
	return n


func _player_attacks() -> int:
	var n := 0
	for a in m.attacks:
		if int(a.a) == m.PLAYER:
			n += 1
	return n


## Troops the player has committed to orders: running attacks (+ pending merges) and boats at sea.
func _committed() -> float:
	var n := 0.0
	for a in m.attacks:
		if int(a.a) == m.PLAYER:
			n += float(a.troops) + float(a.get("pend", 0.0))
	for b in m.boats:
		if int(b.get("a", -1)) == m.PLAYER:
			n += float(b.troops)
	return n


func _player_boats() -> int:
	var n := 0
	for b in m.boats:
		if int(b.get("a", b.get("o", -1))) == m.PLAYER:
			n += 1
	return n


func _initialize() -> void:
	m = load("res://main.tscn").instantiate()
	if m.get_script() == null or not ("map_tab" in m):
		print("INPUT_WORLD_TEST FAIL main scene script did not load")
		quit(1)
		return
	root.add_child(m)
	await _frames(2)
	m.map_tab = 0; m.map_i = 0
	m.rng.seed = 20261121; seed(20261121)
	m._start_game()
	await _frames(3)
	_check(m.W == 2000 and m.H == 1000, "World is native 2000x1000 (got %dx%d)" % [m.W, m.H])
	var c = m.client
	var W: int = m.W
	var H: int = m.H

	# --- tile picking: the screen position of a tile maps back to that tile at several zooms
	var probe: int = int(H * 0.45) * W + int(W * 0.52)
	var pick_ok := true
	for sc in [1.0, 4.0, 20.0]:
		m.mcam.halt(); m.mcam.set_scale_immediate(sc); m.mcam.look_at(W * 0.52 + 0.5, H * 0.45 + 0.5)
		await _frames(2)
		var p: Vector2 = c.ctx.tile_screen_pos(probe)
		var back: int = c.ctx.tile_at(p)
		if back != probe:
			pick_ok = false
			print("    zoom %.1f: tile %d -> %s -> %d" % [sc, probe, p, back])
	_check(pick_ok, "screen -> tile round trip at zoom 1, 4, 20")

	# --- spawn: a coastal unclaimed tile in Europe / Africa, picked by a real click
	var spawn := -1
	for r in range(0, 300, 2):
		for k in 60:
			var x := clampi(int(W * 0.50) + m.rng.randi_range(-r, r), 1, W - 2)
			var y := clampi(int(H * 0.30) + m.rng.randi_range(-r, r), 1, H - 2)
			var t := y * W + x
			if m.owner_map[t] == m.NEUTRAL and m._coastal(t):
				# keep it a few tiles inland so the disc has both coast and land around it
				spawn = t; break
		if spawn >= 0: break
	_check(spawn >= 0, "found a coastal spawn tile")
	await _click(spawn)
	_check(m.nations[m.PLAYER].land > 0 and m.start_tile >= 0, "spawn click places the player (land %d)" % m.nations[m.PLAYER].land)
	m.deploy_t = 0.0
	for _i in 30:
		await process_frame
		if m.state == "play": break
	_check(m.state == "play" and c.ctx.state.phase == Defs.PHASE_PLAYING, "match starts after the spawn timer")
	m.set_speed(0)
	m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 20000.0)
	m.nations[m.PLAYER].gold = 1.0e9
	await _frames(3)

	# BFS over unclaimed land out from our border: depth 1 = adjacent, depth >= 12 = contiguous, far
	var depth := {}
	var q: Array[int] = []
	for t in m.border[m.PLAYER].keys():
		for d in [1, -1, W, -W]:
			var j: int = int(t) + d
			if j >= 0 and j < W * H and m.owner_map[j] == m.NEUTRAL and not depth.has(j) and m.fallout[j] == 0:
				depth[j] = 1; q.append(j)
	var qi := 0
	var adj := -1
	var far := -1
	var vfar := -1
	while qi < q.size() and qi < 200000:
		var t2: int = q[qi]; qi += 1
		var dd: int = depth[t2]
		if dd == 1 and adj < 0: adj = t2
		if dd >= 20 and far < 0:
			far = t2
		if dd >= 120 and vfar < 0:
			vfar = t2; break
		var x2 := t2 % W
		for d in [1, -1, W, -W]:
			if (d == 1 and x2 == W - 1) or (d == -1 and x2 == 0): continue
			var j: int = t2 + d
			if j >= 0 and j < W * H and m.owner_map[j] == m.NEUTRAL and not depth.has(j):
				depth[j] = dd + 1; q.append(j)
	_check(adj >= 0 and far >= 0 and vfar >= 0, "found adjacent (%d), 20-out (%d) and 120-out (%d) contiguous unclaimed land" % [adj, far, vfar])

	# --- hover over the distant contiguous land: the hint offers an expansion, not a boat
	for ft in [far, vfar]:
		if ft < 0: continue
		c.ctx.rules.invalidate()
		var actf: Dictionary = c.ctx.rules.primary(ft)
		_check(str(actf.type) == "expand" and actf.ok, "contiguous land %d tiles out is an expansion (primary=%s)" % [depth.get(ft, -1), str(actf.type)])
	if far >= 0:
		c.ctx.rules.invalidate()
		await _aim(far)
		var spec: Dictionary = c.interact.hover_spec(far)
		_check("expand" in str(spec.get("hint", "")), "hover hint: '%s'" % str(spec.get("hint", "")))

	# --- clicks on unclaimed land: land attacks, never a boat
	for pair in [[adj, "adjacent"], [far, "contiguous, 20 tiles out"], [vfar, "contiguous, 120 tiles out"]]:
		var tile: int = pair[0]
		if tile < 0: continue
		m.notes.clear()
		var a0 := _player_attacks(); var b0 := _player_boats(); var t0 := _boat_toasts()
		var c0 := _committed()
		m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 20000.0)
		c.ctx.rules.invalidate()
		var pa: Dictionary = c.ctx.rules.primary(tile)
		print("    (%s: primary %s ok=%s %s, troops %.0f)" % [pair[1], pa.type, pa.ok, pa.reason, m.nations[m.PLAYER].troops])
		var sent: int = c.ctx.sent_log.size()
		await _click(tile)
		var orders: Array = c.ctx.sent_log.slice(sent)
		_check(orders.size() == 1 and orders[0].intent.type == "attack" and orders[0].intent.tile == tile,
			"clicked tile %d sends exactly one land intent" % tile)
		_check(_player_attacks() > a0 or _committed() > c0 + 0.5, "click on %s unclaimed land sends a land attack (attacks %d -> %d, committed %.0f -> %.0f)" % [pair[1], a0, _player_attacks(), c0, _committed()])
		_check(_player_boats() == b0 and _boat_toasts() == t0, "  ... and sends no boat (boats %d -> %d, boat toasts %d -> %d)" % [b0, _player_boats(), t0, _boat_toasts()])
		m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 20000.0)

	# --- Space at the pointer over distant land: the same expansion. The HUD's hover reads the OS
	# pointer, which a headless display does not have: run under xvfb-run for this check.
	if far >= 0 and DisplayServer.get_name() == "headless":
		print("  skip Space at the pointer (headless: no OS pointer; run under xvfb-run)")
	elif far >= 0:
		await _aim(far)
		var c1 := _committed()
		var b1 := _player_boats()
		c.interact._last_click_tile = -1
		c.ctx.rules.invalidate()
		m.notes.clear()
		_key(KEY_SPACE)
		await _frames(2)
		_check(_committed() > c1 + 0.5 and _player_boats() == b1, "Space over contiguous land sends troops over land (committed %.0f -> %.0f)" % [c1, _committed()])
		m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 20000.0)

	# --- a nation across the ocean: the click is a boat
	var overseas := -1
	var pr: Dictionary = {}
	for t in range(0, W * H, 97):
		var o: int = m.owner_map[t]
		if o <= 0 or o == m.PLAYER: continue
		c.ctx.rules.invalidate()
		var a2: Dictionary = c.ctx.rules.primary(t)
		if str(a2.type) == "boat" and a2.ok:
			overseas = t; pr = a2; break
	_check(overseas >= 0, "found a nation across the water")
	if overseas >= 0:
		var a0 := _player_attacks(); var b0 := _player_boats()
		m.notes.clear()
		print("    overseas primary: ", pr)
		await _click(overseas)
		if _player_boats() == b0:
			print("    notes: ", m.notes.map(func(n): return n.text))
		_check(_player_boats() > b0, "click across the ocean launches a boat (boats %d -> %d)" % [b0, _player_boats()])
		_check(_player_attacks() == a0, "  ... and no land attack")
		m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 20000.0)

	# --- the sim never turns a land order into a boat
	if overseas >= 0:
		var b2 := _player_boats()
		var ok_land: bool = m.intent_attack(m.PLAYER, overseas, 0.1)
		_check(not ok_land and _player_boats() == b2, "intent_attack on a non-bordering nation does not launch a transport")

	# --- right click opens the action ring; Escape closes it
	if overseas >= 0:
		await _click(overseas, MOUSE_BUTTON_RIGHT)
		_check(c.radial.is_open, "right click opens the action ring")
		_key(KEY_ESCAPE)
		await _frames(2)
		_check(not c.radial.is_open, "Escape closes the ring")

	# --- key 1 then a click on our land builds a City
	var own := -1
	for t in range(0, W * H):
		if m.owner_map[t] == m.PLAYER and m.build_req(0, t) == "":
			own = t; break
	_check(own >= 0, "found a buildable tile of ours")
	if own >= 0:
		await _aim(own)
		_key(KEY_1)
		await _frames(2)
		_check(m.build_sel == 0 and c.interact.aim_kind == "city", "key 1 selects City (sel %d, aim '%s')" % [m.build_sel, c.interact.aim_kind])
		var s0: int = m.structs.size()
		await _click(own)
		_check(m.structs.size() == s0 + 1, "click builds the City (%d -> %d)" % [s0, m.structs.size()])

	# --- a silo, then an atom bomb aimed with the mouse: lock, then launch (a silo needs room: grow
	# the nation first)
	m._claim_blob(m.PLAYER, m.start_tile, 30)
	await _frames(2)
	var silo_t := -1
	for t in range(0, W * H):
		if m.owner_map[t] == m.PLAYER and m.build_req(5, t) == "":
			silo_t = t; break
	if silo_t < 0:
		print("  skip atom aim: no tile of ours accepts a silo (%s)" % (m.build_req(5, own) if own >= 0 else "-"))
	if silo_t >= 0 and overseas >= 0:
		m.try_build(5, silo_t)
		for st2 in m.structs:
			if int(st2.o) == m.PLAYER: st2["bt"] = 0.0
		await _frames(2)
		_key(KEY_8)
		await _frames(2)
		_check(c.interact.aim_kind == "atom", "key 8 aims the atom bomb (aim '%s')" % c.interact.aim_kind)
		var g0: float = m.nations[m.PLAYER].gold
		await _click(overseas)
		await _click(overseas)
		_check(m.nations[m.PLAYER].gold < g0 and c.interact.aim_kind == "", "two clicks lock and launch the atom bomb")

	print("INPUT_WORLD_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)

