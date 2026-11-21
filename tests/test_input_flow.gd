# The whole solo flow on World with real InputEvents (no direct calls into the click handlers):
# title PLAY SOLO -> loading -> spawn pick by mouse click -> deploy timer -> a click on adjacent
# unclaimed land and on same-continent wilderness 15+ tiles out (both land attacks, no boat) ->
# key 1 + click builds a City.
#   godot --headless --path . --script tests/test_input_flow.gd
# Events go in with push_input(ev, true): the headless window is tiny, so window->viewport
# conversion would otherwise scale every click off the map.
extends SceneTree

var fails := 0
var m


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _secs(s: float) -> void:
	await create_timer(s).timeout


func _move(pos: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = pos; mv.global_position = pos
	root.push_input(mv, true)


func _click(pos: Vector2, idx := MOUSE_BUTTON_LEFT) -> void:
	_move(pos)
	await _frames(2)
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = idx; b.pressed = down; b.position = pos; b.global_position = pos
		root.push_input(b, true)
		await _frames(1)
	await _frames(2)


func _key(code: int) -> void:
	for down in [true, false]:
		var k := InputEventKey.new()
		k.keycode = code; k.physical_keycode = code; k.pressed = down
		root.push_input(k, true)
		await _frames(1)


func _look(tile: int) -> Vector2:
	m.mcam.halt()
	m.mcam.set_scale_immediate(maxf(m.mcam.scale, 6.0))
	m.mcam.look_at(tile % m.W + 0.5, tile / m.W + 0.5)
	await _frames(3)
	return m.client.ctx.tile_screen_pos(tile)


func _player(kind: String) -> int:
	var n := 0
	for a in (m.attacks if kind == "attacks" else m.boats):
		if int(a.get("a", -1)) == m.PLAYER: n += 1
	return n


func _initialize() -> void:
	m = load("res://main.tscn").instantiate()
	root.add_child(m)
	await _frames(5)
	m.rng.seed = 20261121; seed(20261121)
	m.map_tab = 0; m.map_i = 0
	m.client.title.play_solo.emit(1)
	for _i in 2000:
		await process_frame
		if m.state == "pick" and not m._loading: break
	await _frames(5)
	_check(m.state == "pick" and m.W == 2000 and m.H == 1000, "PLAY SOLO reaches the spawn pick on World 2000x1000 (state %s)" % m.state)
	var W: int = m.W
	# spawn: an unclaimed tile in the middle of Africa / Eurasia, clicked with the mouse
	var spawn := -1
	for y in range(int(m.H * 0.25), int(m.H * 0.6), 7):
		for x in range(int(W * 0.48), int(W * 0.62), 7):
			var t: int = y * W + x
			if m.owner_map[t] == m.NEUTRAL and spawn < 0: spawn = t
	var sp: Vector2 = await _look(spawn)
	await _click(sp)
	var hov = root.gui_get_hovered_control()
	_check(m.start_tile >= 0 and m.nations[m.PLAYER].land > 0, "mouse click picks the spawn (land %d, hovered %s)" % [m.nations[m.PLAYER].land, hov.get_path() if hov else "none"])

	# the deploy timer runs out on its own (5 s of real time)
	for _i in 100:
		await _secs(0.1)
		if m.state == "play": break
	_check(m.state == "play", "match starts when the deploy timer runs out")
	var t0: int = m.ticks_done
	await _secs(1.0)
	_check(m.ticks_done > t0, "sim ticks after deploy (%d -> %d)" % [t0, m.ticks_done])
	m.set_speed(0)
	m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 30000.0)
	m.nations[m.PLAYER].gold = 1.0e9

	var tg := _targets()
	_check(tg[0] >= 0 and tg[1] >= 0, "found adjacent (%d) and same-continent wilderness 15 tiles out (%d)" % [tg[0], tg[1]])
	for which in [[0, "adjacent unclaimed land"], [1, "same-continent wilderness 15 tiles out"]]:
		var tile: int = _targets()[which[0]]
		if tile < 0: continue
		var a0 := _player("attacks"); var b0 := _player("boats")
		var tr0: float = m.nations[m.PLAYER].troops
		var land0: int = m.nations[m.PLAYER].land
		var pos: Vector2 = await _look(tile)
		m.client.interact._last_click_tile = -1
		m.client.ctx.rules.invalidate()
		print('    primary: ', m.client.ctx.rules.primary(tile), ' tile_at ', m.client.ctx.tile_at(pos), '=', tile, ' owner ', m.owner_map[tile])
		var sp0: int = m.minput.stats.stop_presses if m.minput else -1
		await _click(pos)
		print('    stop_presses %d -> %d, moving=%s' % [sp0, m.minput.stats.stop_presses, m.mcam.is_moving(30.0)])
		_check(_player("attacks") > a0 or m.nations[m.PLAYER].troops < tr0 - 0.5, "click on %s starts a land attack (attacks %d -> %d, troops %.0f -> %.0f)" % [which[1], a0, _player("attacks"), tr0, m.nations[m.PLAYER].troops])
		_check(_player("boats") == b0, "  ... and sends no boat (boats %d -> %d)" % [b0, _player("boats")])
		await _secs(2.0)
		_check(m.nations[m.PLAYER].land > land0, "  ... and territory grows (%d -> %d)" % [land0, m.nations[m.PLAYER].land])
		m.nations[m.PLAYER].troops = maxf(m.nations[m.PLAYER].troops, 30000.0)

	# key 1 then a click on our land builds a City
	var own := -1
	for t in m.border[m.PLAYER].keys():
		if m.build_req(0, int(t)) == "": own = int(t); break
	_check(own >= 0, "found a buildable tile of ours")
	if own >= 0:
		var pos2: Vector2 = await _look(own)
		await _key(KEY_1)
		await _frames(2)
		_check(m.build_sel == 0, "key 1 selects City (build_sel %d, aim '%s')" % [m.build_sel, m.client.interact.aim_kind])
		var s0: int = m.structs.size()
		await _click(pos2)
		_check(m.structs.size() == s0 + 1, "click builds the City (%d -> %d)" % [s0, m.structs.size()])

	print("INPUT_FLOW_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)


## BFS over unclaimed land from our border: [adjacent tile, tile 15+ steps out on the same land].
func _targets() -> Array:
	var W: int = m.W
	var depth := {}
	var q: Array[int] = []
	for t in m.border[m.PLAYER].keys():
		for d in [1, -1, W, -W]:
			var j: int = int(t) + d
			if j >= 0 and j < W * m.H and m.owner_map[j] == m.NEUTRAL and not depth.has(j):
				depth[j] = 1; q.append(j)
	var qi := 0
	var adj := -1
	var far := -1
	while qi < q.size():
		var t2: int = q[qi]; qi += 1
		var dd: int = depth[t2]
		if dd == 1 and adj < 0: adj = t2
		if dd >= 15: far = t2; break
		var x2 := t2 % W
		for d in [1, -1, W, -W]:
			if (d == 1 and x2 == W - 1) or (d == -1 and x2 == 0): continue
			var j: int = t2 + d
			if j >= 0 and j < W * m.H and m.owner_map[j] == m.NEUTRAL and not depth.has(j):
				depth[j] = dd + 1; q.append(j)
	return [adj, far]
