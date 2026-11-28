# The client's map size follows the match's map (owner report 2026-11-28, web: the artillery range ring
# drawn far from the cursor while placing). RWGameState.map copied W and H at boot, so on a map of
# another size every tile position the client layers drew (range rings, the build ring, fx, the target
# card) was off. Starts maps of three sizes in a row and, on each: the client's map size is the game's,
# and the build-preview ring of an artillery aimed at a tile is drawn at that tile.
#   godot --headless --path . -s res://tests/test_map_size_live.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _run() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	var st = m.client.ctx.state
	var sizes := {}
	for idx in [1, 0, 3]:
		hs.start(0, idx, Vector2(0.5, 0.38), 0, -1.0)
		await process_frame
		sizes["%dx%d" % [m.W, m.H]] = true
		var name := "map %d (%dx%d)" % [idx, m.W, m.H]
		_check(st.map.W == m.W and st.map.H == m.H, "%s: the client's map size is %dx%d" % [name, st.map.W, st.map.H])
		# a tile away from the corner, so a wrong width moves it
		var tx: int = int(m.W * 0.73)
		var ty: int = int(m.H * 0.61)
		var t: int = ty * m.W + tx
		m.ranges.set_aim("build", t, "artillery", 1)
		m.ranges._rebuild()
		var found := false
		for wt: Array in m.ranges._want:
			if int(wt[2]) != RangeLayer.C_BUILD:
				continue
			found = true
			var w: int = st.map.W
			var u: float = int(wt[0]) % w + 0.5
			@warning_ignore("integer_division")
			var v: float = int(wt[0]) / w + 0.5
			_check(is_equal_approx(u, tx + 0.5) and is_equal_approx(v, ty + 0.5),
				"%s: the artillery build ring is drawn at its tile (%.1f, %.1f), the tile is (%d, %d)" % [name, u, v, tx, ty])
		_check(found, "%s: the artillery build ring is there" % name)
		m.ranges.set_aim("", -1)
	_check(sizes.size() == 3, "three map sizes were tried (%s)" % ", ".join(sizes.keys()))
	m.queue_free()
	await process_frame
	print("MAP_SIZE_LIVE_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
