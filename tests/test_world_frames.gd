# Load the World map at native size and run a match for 300 frames.
#   godot --headless --path . -s res://tests/test_world_frames.gd
extends SceneTree

var fails := 0

func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)

func _initialize() -> void:
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	m.map_tab = 0
	m.map_i = 0
	m.gen_map()
	_check(m.W == 2000 and m.H == 1000, "World is the native 2000x1000 grid (%dx%d)" % [m.W, m.H])
	var top := 0
	var bot := 0
	var land := 0
	for x in m.W:
		if m.owner_map[x] != m.WATER: top += 1
		if m.owner_map[(m.H - 1) * m.W + x] != m.WATER: bot += 1
	for i in m.owner_map.size():
		if m.owner_map[i] != m.WATER: land += 1
	_check(top == 0, "row 0 is water, as in upstream (land=%d)" % top)
	_check(bot == m.W, "the bottom row is land, as in upstream (land=%d)" % bot)
	_check(land == 689018, "World land_tiles = 689018 (%d)" % land)
	_check(m.tribe_count() == 400, "World tribes = 400 (%d)" % m.tribe_count())
	m.rng.seed = 20261121
	m._start_game()
	var st: int = m._find_spawn_tile(int(m.W * 0.52), int(m.H * 0.30))
	_check(st >= 0, "found a land spawn (%d)" % st)
	m._place_start(st)
	m.deploy_t = 0.0
	m.state = "play"
	var err := 0
	for _f in 300:
		await process_frame
		if m.owner_map.size() != m.W * m.H:
			err += 1
	_check(err == 0, "300 frames: owner_map stays W*H")
	_check(m.nations.size() > 2 and m.nations[m.PLAYER].alive, "player still alive after 300 frames (nations=%d)" % m.nations.size())
	_check(m.W == 2000 and m.H == 1000, "size unchanged after the match (%dx%d)" % [m.W, m.H])
	print("WORLD_FRAMES_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
