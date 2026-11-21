# /spawn snap: buildings never land on water; ships only on water.
#   godot --headless --path . -s res://tests/test_console_spawn.gd
extends SceneTree

var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	var W := 16
	var H := 16
	var owner_map := PackedInt32Array()
	owner_map.resize(W * H)
	# Top half water (-1), bottom half owned by nation 1; tile (2,10) nation 2.
	for y in H:
		for x in W:
			var t := y * W + x
			if y < 8:
				owner_map[t] = -1
			elif x == 2 and y == 10:
				owner_map[t] = 2
			else:
				owner_map[t] = 1

	# Cursor on open ocean (4, 2): must not return a water tile for a building.
	var water_cursor := 2 * W + 4
	_ok(owner_map[water_cursor] == -1, "fixture: cursor tile is water")
	var occ := {}
	var land := SpawnSnap.owned_land_near(owner_map, occ, W, H, water_cursor, 1, 64)
	_ok(land >= 0, "building snap from water finds owned land (got %d)" % land)
	if land >= 0:
		_ok(owner_map[land] > 0, "/spawn on water does not leave a building on a water tile (land=%d owner=%d)" % [land, owner_map[land]])
		_ok(land / W >= 8, "snapped tile is in the land half (y=%d)" % (land / W))

	# All-water map: refuse (no building).
	var all_water := PackedInt32Array()
	all_water.resize(W * H)
	all_water.fill(-1)
	var none := SpawnSnap.owned_land_near(all_water, {}, W, H, water_cursor, 1, 64)
	_ok(none < 0, "all-water map: spawn refuses (no owned land)")

	# Occupied land under cursor: snap to a free neighbour, never the occupied tile, never water.
	var land_tile := 10 * W + 4
	_ok(owner_map[land_tile] == 1, "fixture: land_tile owned")
	var occ2 := {land_tile: true}
	var alt := SpawnSnap.owned_land_near(owner_map, occ2, W, H, land_tile, 1, 64)
	_ok(alt >= 0 and alt != land_tile and owner_map[alt] > 0, "occupied land snaps to a free owned tile (%d)" % alt)

	# Prefer the nation under (or near) the cursor: nation 2 at (2,10).
	var t2 := 10 * W + 2
	var pref := SpawnSnap.owned_land_near(owner_map, {}, W, H, t2, 1, 64)
	_ok(pref == t2 and owner_map[pref] == 2, "prefers the target nation's land under the cursor")

	# Ships: water_near on land cursor finds water; on water returns the same tile.
	var wt := SpawnSnap.water_near(owner_map, W, H, land_tile, 64)
	_ok(wt >= 0 and owner_map[wt] == -1, "ship snap from land finds water (tile %d)" % wt)
	var wt2 := SpawnSnap.water_near(owner_map, W, H, water_cursor, 64)
	_ok(wt2 == water_cursor, "ship snap on water stays on the cursor water tile")

	# All land: ship spawn refuses.
	var all_land := PackedInt32Array()
	all_land.resize(W * H)
	all_land.fill(1)
	_ok(SpawnSnap.water_near(all_land, W, H, land_tile, 64) < 0, "all-land map: ship spawn refuses")

	# shop.gd wires /spawn through _console_spawn + SpawnSnap (not raw cursor tile).
	var shop := FileAccess.get_file_as_string("res://game/shop.gd")
	_ok(shop.find("func _console_spawn") >= 0 and shop.find("SpawnSnap.owned_land_near") >= 0, "shop._console_spawn snaps buildings via SpawnSnap")
	_ok(shop.find("SpawnSnap.water_near") >= 0, "shop._console_spawn snaps ships via water_near")
	_ok(shop.find("No owned land near the cursor") >= 0, "refuse message when no land")
	_ok(shop.find("No water near the cursor") >= 0, "refuse message when no water")
	_ok(shop.find("_fmt_hud") >= 0, "spawned structure level uses formatted HUD numbers")

	print("CONSOLE_SPAWN_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
