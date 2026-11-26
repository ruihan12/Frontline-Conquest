# Stale-pixel check: after real attacks (time-sliced paint), every painted map pixel must equal what
# the painter would produce for the tile now.  godot --headless --path . --script tests/test_paint_stale.gd
extends SceneTree
var m
func _initialize() -> void:
	m = load("res://main.tscn").instantiate()
	root.add_child(m)
	for _i in 2: await process_frame
	m.map_tab = 0; m.map_i = 0
	m.rng.seed = 777; seed(777)
	m._start_game()
	for _i in 3: await process_frame
	var W: int = m.W
	var P := 2
	for id in range(2, m.nations.size()):
		if m.nations[id].land > 20: P = id; break
	print("attacker ", P, " land ", m.nations[P].land)
	m.nations[P].troops = 5.0e6
	for k in 600:
		m._begin_presentation_batch()
		m.sim_atk.begin_tick(); m.sim_atk.run_slice(-1)
		if k % 15 == 0 and m.nations[P].troops > 100.0:
			m.sim_atk.start(P, 0, minf(m.nations[P].troops * 0.2, 200000.0))
		m._flush_presentation_batch()
		m._flush_paint_budget(300)
	# let all pending paint drain
	m._flush_paint()
	var bad := 0; var checked := 0; var cols: int = m._chunk_cols()
	var surf = m.surface
	for i in range(W * m.H):
		var o: int = m.owner_map[i]
		if o <= 0: continue
		var c0: Color = surf.tile_color(i)
		var x := i % W; var y := i / W
		var k: int = (y / m.CH) * cols + x / m.CW
		var px: Color = m.chunk_img[k].get_pixel(x % m.CW, y % m.CH)
		checked += 1
		if absf(px.r - c0.r) > 0.01 or absf(px.g - c0.g) > 0.01 or absf(px.b - c0.b) > 0.01:
			bad += 1
			if bad <= 8: print("  stale tile ", x, ",", y, " owner ", o, " painted ", px, " expected ", c0)
	print("PAINT_STALE checked=", checked, " stale=", bad, " land=", m.nations[P].land)
	# pockets: non-P tiles (land, unowned) with >= 3 neighbours owned by P
	var pk := {}; var total := 0; var bymtn := {}
	for i in range(W, W * (m.H - 1) - 1):
		if m.owner_map[i] != 0: continue
		var n := 0
		for d in [1, -1, W, -W]:
			if m.owner_map[i + d] == P: n += 1
		if n >= 3:
			total += 1; var mt: int = m.mtn[i]; bymtn[mt] = bymtn.get(mt, 0) + 1
	print("POCKETS neutral tiles with >=3 owned neighbours: ", total, " by terrain ", bymtn, " of land ", m.nations[P].land)
	var hist := {}; var sumc := {}
	for i in range(W * m.H):
		if m.owner_map[i] != P: continue
		var mt: int = m.mtn[i]
		hist[mt] = hist.get(mt, 0) + 1
		var c1: Color = surf.tile_color(i)
		sumc[mt] = sumc.get(mt, Color(0, 0, 0, 0)) + Color(c1.r, c1.g, c1.b, 1.0)
	for mt in hist:
		var cc: Color = sumc[mt] / float(hist[mt])
		print("TERRAIN mtn=", mt, " tiles=", hist[mt], " mean painted rgb=(%d,%d,%d)" % [cc.r * 255, cc.g * 255, cc.b * 255], " base=", m.base_col[0] if false else "")
	quit(0 if bad == 0 else 1)
