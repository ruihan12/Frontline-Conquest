# Custom geography fixes (tools/mapfix.py) are not applied on the vanilla maps. This checks that the
# decoded World grid is the native upstream 2000x1000 with Antarctica on the bottom row and no
# letterbox ocean, and that no map's meta lists a mapfix edit.
#   godot --headless --path . -s res://tests/test_mapfix.gd
extends SceneTree

const UM := preload("res://sim/upstream_maps.gd")
var fails := 0

func _initialize() -> void:
	for id in UM.ids():
		var fx = UM.meta(id).get("mapfix", [])
		var ok: bool = fx is Array and fx.is_empty()
		print("%-18s %s mapfix=%s" % [id, "OK  " if ok else "FAIL", str(fx)])
		if not ok: fails += 1
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	m.map_tab = 0; m.map_i = 0
	m.gen_map()
	var ok_sz: bool = m.W == 2000 and m.H == 1000
	print("world size %s %dx%d" % ["OK  " if ok_sz else "FAIL", m.W, m.H])
	if not ok_sz: fails += 1
	var bot := 0
	var top := 0
	for x in m.W:
		if m.owner_map[x] != m.WATER: top += 1
		if m.owner_map[(m.H - 1) * m.W + x] != m.WATER: bot += 1
	var ok_edge: bool = top == 0 and bot == m.W
	print("world edges %s top_land=%d bottom_land=%d" % ["OK  " if ok_edge else "FAIL", top, bot])
	if not ok_edge: fails += 1
	print("MAPFIX_TEST %s fails=%d (vanilla: mapfix not applied)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
