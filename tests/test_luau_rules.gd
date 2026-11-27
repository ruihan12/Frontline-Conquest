# Step 3 of docs/LUAU_PORT.md: luau/sim/Core/Rules.luau against sim/rules.gd (SimRules), bit for bit:
# every constant, every instance field after set_k / set_troop_scale / the per-match settings, and every
# function over a grid of inputs (edge values plus seeded random ones) for several map scales and modes.
#   godot --headless --path . -s res://tests/test_luau_rules.gd
extends SceneTree

var fails := 0
const STATIC_OR_DATA_ONLY := ["NUKE_KINDS"]  # Luau-only: the size of the N_* tables (GDScript calls size())


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


static func _flat(v: Variant, out: PackedFloat64Array) -> void:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			out.append(float(v))
		TYPE_BOOL:
			out.append(1.0 if v else 0.0)
		TYPE_VECTOR2:
			out.append(float(v.x))
			out.append(float(v.y))
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_VECTOR2_ARRAY:
			for e in v:
				_flat(e, out)
		TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys.sort()
			for k in keys:
				out.append(float(k))
				_flat(v[k], out)
		_:
			push_error("flat: type %d" % typeof(v))


static func _first_diff(a: PackedFloat64Array, b: PackedByteArray) -> String:
	var bb := PackedFloat64Array()
	var n := b.size() / 8
	for i in n:
		bb.append(b.decode_double(i * 8))
	if a.size() != bb.size():
		return "sizes %d vs %d" % [a.size(), bb.size()]
	for i in a.size():
		if a[i] != bb[i] and not (is_nan(a[i]) and is_nan(bb[i])):
			return "item %d: gd %s luau %s" % [i, var_to_str(a[i]), var_to_str(bb[i])]
	return ""


func _same(a: PackedFloat64Array, b: Variant) -> String:
	if not (b is PackedByteArray):
		return "luau returned %s" % str(b)
	var pa := a.to_byte_array()
	if pa == b:
		return ""
	var d := _first_diff(a, b)
	return d if d != "" else "byte mismatch (signed zero?)"


func _initialize() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	var vm := LuauVM.new()
	_check(vm.boot(), "boot (%s)" % vm.last_error)
	var ok_load: bool = vm.load_file("rules_check", "res://tests/luau/rules_check.luau")
	_check(ok_load, "load tests/luau/rules_check.luau (%s)" % vm.last_error)
	if not ok_load:
		_done()
		return
	_constants(vm)
	_fields(vm)
	_functions(vm)
	_done()


func _constants(vm: LuauVM) -> void:
	var cmap: Dictionary = (load("res://sim/rules.gd") as GDScript).get_script_constant_map()
	var luau_names: Array = vm.call_fn("rules_check", "const_names")
	var missing: Array = []
	for k in cmap.keys():
		if not luau_names.has(k):
			missing.append(k)
	var extra: Array = []
	for k in luau_names:
		if not cmap.has(k) and not STATIC_OR_DATA_ONLY.has(k):
			extra.append(k)
	_check(missing.is_empty(), "every SimRules constant is in Rules.luau (%d constants; missing %s)" % [cmap.size(), str(missing)])
	_check(extra.is_empty(), "Rules.luau has no constant SimRules lacks (extra %s)" % str(extra))
	var bad: Array = []
	for k in cmap.keys():
		if missing.has(k):
			continue
		var v: Variant = cmap[k]
		if v is Array and not (v as Array).is_empty() and v[0] is String:
			var lv: Variant = vm.call_fn("rules_check", "const_str", [k])
			if str(lv) != ",".join(PackedStringArray(v)):
				bad.append("%s: %s vs %s" % [k, str(v), str(lv)])
			continue
		var g := PackedFloat64Array()
		_flat(v, g)
		var d := _same(g, vm.call_fn("rules_check", "const", [k, v is Dictionary]))
		if d != "":
			bad.append("%s: %s" % [k, d])
	_check(bad.is_empty(), "every constant has the same value (%s)" % str(bad))
	var nk: int = vm.call_fn("rules_check", "const", ["NUKE_KINDS", false]).decode_double(0)
	_check(nk == SimRules.NUKE_OUTER_FULL.size() and nk == SimRules.NUKE_SPEED_FULL.size() and nk == SimRules.NUKE_NAMES.size(),
		"NUKE_KINDS = size of the N_* tables (%d)" % nk)


const CFGS := [
	{"kl": 1.0, "ts_on": false, "pop_cap_mode": 2, "tile_norm": 1.0, "growth_mult": 1.0, "gold_mult": 1.0},
	{"kl": 1.953125, "ts_on": true, "pop_cap_mode": 2, "tile_norm": 1.0, "growth_mult": 1.0, "gold_mult": 1.0},
	{"kl": 0.5, "ts_on": false, "pop_cap_mode": 0, "tile_norm": 1.0, "growth_mult": 1.25, "gold_mult": 0.8},
	{"kl": 0.75, "ts_on": true, "pop_cap_mode": 1, "tile_norm": 0.37, "growth_mult": 1.0, "gold_mult": 1.0},
	{"kl": 1.3, "ts_on": false, "pop_cap_mode": 1, "tile_norm": 2.5, "growth_mult": 0.9, "gold_mult": 1.0},
	{"kl": 3.0, "ts_on": true, "pop_cap_mode": 0, "tile_norm": 1.0, "growth_mult": 1.0, "gold_mult": 1.5},
	{"kl": 0.31, "ts_on": false, "pop_cap_mode": 2, "tile_norm": 1.0, "growth_mult": 1.0, "gold_mult": 1.0},
	{"kl": 2.2737, "ts_on": true, "pop_cap_mode": 2, "tile_norm": 1.0, "growth_mult": 1.1, "gold_mult": 1.0},
]


static func _make(cfg: Dictionary) -> SimRules:
	var r := SimRules.new(float(cfg.kl))
	r.set_troop_scale(bool(cfg.ts_on))
	r.pop_cap_mode = int(cfg.pop_cap_mode)
	r.tile_norm = float(cfg.tile_norm)
	r.growth_mult = float(cfg.growth_mult)
	r.gold_mult = float(cfg.gold_mult)
	return r


func _fields(vm: LuauVM) -> void:
	var names: Array = []
	for p in SimRules.new().get_property_list():
		if int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			names.append(str(p.name))
	var bad: Array = []
	for cfg in CFGS:
		var r := _make(cfg)
		var g := PackedFloat64Array()
		for n in names:
			_flat(r.get(n), g)
		var d := _same(g, vm.call_fn("rules_check", "fields", [cfg, names]))
		if d != "":
			bad.append("kl=%s: %s" % [cfg.kl, d])
	_check(names.size() >= 19 and bad.is_empty(), "every instance field (%d: %s) equal after set_k etc. for %d scales (%s)"
		% [names.size(), ", ".join(PackedStringArray(names)), CFGS.size(), str(bad)])


# A deterministic grid: edge values and seeded random draws for each argument kind.
var _r := RandomNumberGenerator.new()

func _i(lo: int, hi: int) -> int:
	return _r.randi_range(lo, hi)

func _f(lo: float, hi: float) -> float:
	return _r.randf_range(lo, hi)

func _big() -> float:
	# troops / gold / tiles across magnitudes, some whole, some not
	var e := _r.randf_range(0.0, 9.0)
	var v := pow(10.0, e)
	return floor(v) if _r.randf() < 0.4 else v


func _calls() -> Array:
	var c: Array = []
	var names := ["city", "port", "factory", "defense", "sam", "silo", "warship", "artillery", "airfield", "railgun", "nope", ""]
	var rels := ["self", "ally", "other", "", "neutral"]
	for kind in [-1, 0, 1, 2, 3]:
		for diff in [-1, 0, 1, 2, 3]:
			c.append(["start_troops", kind, diff])
			c.append(["human_grace_ticks", diff])
	for i in 400:
		var kind := _i(0, 2)
		var diff := _i(-1, 3)
		var tiles := _i(0, 400000) if i % 3 else _i(0, 50)
		var cities := _i(0, 40)
		var troops := _big() * (1.0 if i % 7 else -1.0)
		var cap := _big()
		var pop := _big() * (1.0 if i % 11 else 0.0)
		var avg := _f(0.0, 5000.0)
		var cont := _i(0, 600000)
		var fall := _i(0, 20000)
		c.append(["sigmoid", _f(-50, 50), _f(0.0, 5.0), _f(-30, 30)])
		c.append(["max_troops", kind, tiles, cities, diff])
		c.append(["land_share", tiles, cont])
		c.append(["win_share", tiles, cont, fall])
		c.append(["dominates", tiles, cont, fall])
		c.append(["max_troops_pop", kind, tiles, pop, avg, cities, diff])
		c.append(["max_troops_pop", kind, tiles, pop, avg, cities, diff, false])
		c.append(["max_troops_pop", kind, tiles, pop, avg, cities, diff, true])
		c.append(["troop_growth", kind, troops, cap, diff])
		c.append(["troop_growth", kind, minf(troops, cap), cap, diff])
		c.append(["troop_growth_applied", kind, troops, cap, diff])
		c.append(["troop_growth_applied", kind, cap * _f(0.0, 1.0), cap, diff])
		c.append(["gold_per_tick", kind])
		c.append(["conquer_gold", _i(0, 2), _big()])
		c.append(["large_territory_bonus", _big(), _f(0.0, 1.0)])
		c.append(["fallout_modifier", _f(-0.5, 1.5)])
		c.append(["neutral_loss_per_mag", kind])
		c.append(["build_cost", names[_i(0, names.size() - 1)], _i(-2, 12)])
		c.append(["sam_range", _i(-1, 12)])
		c.append(["trade_gold", _f(0.0, 3000.0)])
		c.append(["train_gold", rels[_i(0, rels.size() - 1)], _i(0, 30)])
		c.append(["trade_saturation", _i(0, 3000)])
		c.append(["trade_spawn_rate", _i(0, 40), _i(0, 3000)])
		var nk := _i(0, 8)
		c.append(["nuke_radii_full_scaled", nk])
		c.append(["inner_frac", nk])
		c.append(["sam_range_at", _i(0, 8), _i(-5, 60)])
		c.append(["sam_ticks_to", _f(0.0, 900.0)])
		c.append(["munition_flight_ticks", _f(0.0, 2000.0), _i(-2, 11)])
		c.append(["strike_radius", nk])
		c.append(["strike_kill", _i(5, 9), troops, _f(0.0, 400.0)])
		c.append(["strike_kill", _i(5, 9), _big(), _f(0.0, 400.0), 297.0])
		c.append(["reinforce_troops", _big(), _big()])
		c.append(["warhead_death", troops, cap])
		c.append(["warhead_death", _big(), _big(), 297.0])
		c.append(["warship_max_hp", _i(-1, 5)])
		c.append(["shell_damage", _i(-1, 7), _i(-1, 5)])
		c.append(["shell_flight_ticks", _f(0.0, 500.0)])
		c.append(["warship_tiles_per_tick", i % 2 == 0])
		c.append(["train_saturation", _f(0.0, 2000.0)])
		c.append(["train_saturation", float(_i(0, 2000))])
		c.append(["train_spawn_rate", _i(0, 60), _i(0, 2000)])
		c.append(["nuke_kind_from_name", SimRules.NUKE_NAMES[nk] if i % 5 else "nope"])
		c.append(["nuke_cost_named", SimRules.NUKE_NAMES[nk], _i(-2, 9)])
		c.append(["nuke_cost_named", SimRules.NUKE_NAMES[nk]])
		c.append(["launch_range", _i(-1, 9)])
		c.append(["nuke_radii", _i(-2, 10)])
		c.append(["nuke_flight_ticks", _f(0.0, 2000.0), _i(-2, 11)])
		c.append(["nuke_flight_ticks", _f(0.0, 2000.0)])
	for f in ["place_search_r", "port_spawn_manhattan", "ship_tiles_per_s", "alt_landing_r", "artillery_range",
			"airfield_range", "scatter_near", "scatter_far", "warship_range", "warship_patrol", "train_tiles_per_tick",
			"road_min_tiles", "road_max_tiles", "rail_max_path", "mirv_spread", "is_1to1", "city_troops_shown"]:
		c.append([f])
	# arcs: H, sp, dp (tile centres), kind; the same point twice; points off the map top
	for i in 120:
		var H := _i(100, 3000)
		var W := H * 2
		var sx := _i(0, W - 1) + 0.5
		var sy := _i(0, H - 1) + 0.5
		var dx := _i(0, W - 1) + 0.5 if i % 9 else sx
		var dy := _i(0, H - 1) + 0.5 if i % 9 else sy
		if i % 13 == 0:
			sy = 1.5
		var kind := _i(-1, 8)
		c.append(["nuke_arc", H, sx, sy, dx, dy])
		c.append(["arc_len", H, sx, sy, dx, dy, kind])
		for s in [0.0, 1.0, -0.2, 1.3, _f(0.0, 1.0), _f(0.0, 1.0), _f(0.0, 1.0)]:
			c.append(["arc_at", H, sx, sy, dx, dy, kind, s])
		c.append(["arc_ticks", H, sx, sy, dx, dy, kind, _i(-2, 11)])
	return c


func _eval_gd(r: SimRules, calls: Array) -> PackedFloat64Array:
	var g := PackedFloat64Array()
	for c in calls:
		var f: String = c[0]
		if f == "nuke_arc":
			var arc: Dictionary = r.nuke_arc(int(c[1]), Vector2(c[2], c[3]), Vector2(c[4], c[5]))
			var pts: PackedVector2Array = arc.pts
			g.append(float(pts.size()))
			_flat(pts, g)
			_flat(arc.lens, g)
			g.append(float(arc.length))
			continue
		var v: Variant
		if f == "arc_at":
			v = SimRules.nuke_arc_at(r.munition_arc(int(c[1]), Vector2(c[2], c[3]), Vector2(c[4], c[5]), int(c[6])), float(c[7]))
		elif f == "arc_ticks":
			v = r.nuke_arc_ticks(r.munition_arc(int(c[1]), Vector2(c[2], c[3]), Vector2(c[4], c[5]), int(c[6])), int(c[7]))
		elif f == "arc_len":
			v = r.munition_arc(int(c[1]), Vector2(c[2], c[3]), Vector2(c[4], c[5]), int(c[6])).length
		else:
			v = r.callv(f, c.slice(1))
		_flat(v, g)
	return g


func _functions(vm: LuauVM) -> void:
	_r.seed = 3303
	var calls := _calls()
	var bad: Array = []
	var t_gd := 0
	var t_lu := 0
	for cfg in CFGS:
		var r := _make(cfg)
		var t0 := Time.get_ticks_usec()
		var g := _eval_gd(r, calls)
		var t1 := Time.get_ticks_usec()
		var l: Variant = vm.call_fn("rules_check", "eval", [cfg, calls])
		var t2 := Time.get_ticks_usec()
		t_gd += t1 - t0
		t_lu += t2 - t1
		var d := _same(g, l)
		if d != "":
			bad.append("kl=%s ts=%s mode=%s: %s (%s)" % [cfg.kl, cfg.ts_on, cfg.pop_cap_mode, d, vm.last_error])
	_check(bad.is_empty(), "every function equal over %d calls x %d configs (%s)" % [calls.size(), CFGS.size(), str(bad)])
	print("  info %d calls x %d configs: GDScript %.1f ms, Luau %.1f ms (incl. bridge)" % [calls.size(), CFGS.size(), t_gd / 1000.0, t_lu / 1000.0])


func _done() -> void:
	print("LUAU_RULES_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
