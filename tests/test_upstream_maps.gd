# Headless check of sim/upstream_maps.gd (native upstream grids, 1:1 with MapList):
#   godot --headless --path . -s res://tests/test_upstream_maps.gd
extends SceneTree

const UM := preload("res://sim/upstream_maps.gd")

func _init() -> void:
	var fails := 0
	var idx := UM.index()
	print("index maps=%d nation_table=%d tribes=%d" % [idx.get("maps", []).size(), UM.nation_colors().size(), UM.tribe_names().size()])
	if idx.get("maps", []).size() != 10: fails += 1
	if UM.count() < 10 or UM.id_at(0) != "world": fails += 1
	if UM.nation_colors().size() < 80 or UM.tribe_names().size() < 400: fails += 1
	DirAccess.make_dir_recursive_absolute("user://upstream_test")
	for k in UM.count():
		var id := UM.id_at(k)
		var t0 := Time.get_ticks_usec()
		var c := UM.codes(id)
		var tb := UM.tiles(id)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var m := UM.meta(id)
		var mw := int(m.get("width", 0))
		var mh := int(m.get("height", 0))
		var hist := [0, 0, 0, 0]
		var bad := 0
		var mismatch := 0
		for i in c.size():
			var v: int = c[i]
			if v > 3: bad += 1
			else: hist[v] += 1
			if (v > 0) != (tb[i] >= 128 and tb[i] != 0x9F): mismatch += 1
		var land: int = hist[1] + hist[2] + hist[3]
		var ok := c.size() == mw * mh and tb.size() == mw * mh and (id.begins_with("of_") or (mw == int(m.get("src_width", 0)) and mh == int(m.get("src_height", 0)))) and bad == 0 and mismatch == 0 and land == int(m.land_tiles)
		ok = ok and is_equal_approx(float(m.get("scale", 0)), 1.0) and is_equal_approx(float(m.k_lin), 1.0)
		ok = ok and (id.begins_with("of_") or int(m.get("default_tribes", 0)) == 400)
		var off := 0
		for n in UM.nations(id):
			var x: int = n[2]; var y: int = n[3]
			if x < 0 or y < 0 or x >= mw or y >= mh or c[y * mw + x] == 0: off += 1
		var ice := 0
		for i in tb.size():
			if tb[i] == 0x9F: ice += 1
		# No letterbox: first and last rows match the source grid (no ocean padding).
		var top_land := 0
		var bot_land := 0
		if mw > 0 and mh > 0 and tb.size() == mw * mh:
			for x in mw:
				if tb[x] >= 128: top_land += 1
				if tb[(mh - 1) * mw + x] >= 128: bot_land += 1
		ok = ok and off == 0 and ice == 0
		if id == "world":
			var aq := UM.nations(id).filter(func(e): return e[1] == "aq").size()
			print("world size=%dx%d first_land_row=%s last_land_row=%s top_land=%d bottom_land=%d aq=%d tribes=%d" % [
				mw, mh, str(m.get("first_land_row")), str(m.get("last_land_row")), top_land, bot_land, aq, UM.default_tribes(id)])
			# Upstream World is 2000x1000: Arctic water on row 0, Antarctica land on the bottom row.
			ok = ok and mw == 2000 and mh == 1000 and int(m.get("last_land_row", -1)) == 999 and bot_land == 2000 and top_land == 0 and aq == 3
		var rm := UM.as_real_map(id)
		var rb: PackedByteArray = Marshalls.base64_to_raw(rm.b64).decompress(mw * mh, FileAccess.COMPRESSION_DEFLATE)
		ok = ok and rb == c
		UM.preview_image(id, 448, 400).save_png("user://upstream_test/%s.png" % id)
		print("%-13s %s codes=%s land=%d nations=%d off_land=%d ice=%d %dx%d k_lin=%.3f scale=%.3f load_ms=%.0f" % [
			id, "OK  " if ok else "FAIL", str(hist), land, UM.nations(id).size(), off, ice, mw, mh, float(m.k_lin), float(m.scale), ms])
		if not ok: fails += 1
	print("menu_entries=", UM.menu_entries().map(func(e): return e[0]))
	print("UPSTREAM_MAPS_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
