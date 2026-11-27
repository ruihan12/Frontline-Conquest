# Step 2 of docs/LUAU_PORT.md: the Luau runtime prelude (module loader, Roblox-globals shim) and Godot's RNG in Luau
# (luau/sim/Core/GodotRng.luau, luau/sim/rt/gd.luau) bit for bit against this Godot's RandomNumberGenerator,
# global seed() + Array.shuffle(), hash(int), and the tribe setup's shuffle + dummy draws (game/nations.gd).
#   godot --headless --path . -s res://tests/test_luau_rng.gd
extends SceneTree

var fails := 0
const SEEDS: Array[int] = [0, 1, 5516, 12345, 20261120, 2147483647, 4294967303, -1, -5516, 9007199254740991]


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	if not LuauVM.available():
		_check(false, "extension loaded")
		_done()
		return
	var vm := LuauVM.new()
	_check(vm.boot(), "boot: prelude, every luau/sim module registered, sandboxed (%s)" % vm.last_error)
	_check(LuauVM.resolve("Core/Sim", "./Defs") == "Core/Defs" and LuauVM.resolve("Core/Sim", "../Net/Coop") == "Net/Coop",
		"relative requires resolve to module names")
	_check(LuauVM.rewrite_requires('local A = require("./X")\nlocal B = require( "../Net/Coop" ) -- x\npcall(require, "@lune/serde")', "Core/Sim")
		== 'local A = require("Core/X")\nlocal B = require("Net/Coop") -- x\npcall(require, "@lune/serde")',
		"require rewrite keeps lines and leaves non-relative requires alone")
	var ok_load: bool = vm.load_file("rng_check", "res://tests/luau/rng_check.luau")
	_check(ok_load, "load tests/luau/rng_check.luau (%s)" % vm.last_error)
	if not ok_load:
		_done()
		return
	# --- shim
	var sh: Dictionary = vm.call_fn("rng_check", "shim")
	_check(is_equal_approx(float(sh.vx), 1.1) and float(sh.vx) == float(Vector3(1.1, 2, 3).x) and sh.vy == 2.0 and sh.vz == 3.0
		and sh.sum == 6.0 and str(sh.vt) == "vector", "Vector3 is Luau's float32 vector (same rounding as Godot's Vector3)")
	_check(sh.w == 4.5, "Vector2.new")
	_check(is_equal_approx(float(sh.r), 209.0 / 255.0) and is_equal_approx(float(sh.b), 199.0 / 255.0), "Color3.fromRGB (tribe grey #d1cdc7)")
	var gr := RandomNumberGenerator.new()
	gr.seed = 5516
	var gi := gr.randi_range(1, 100)
	var gf := gr.randf()
	_check(int(sh.ri) == gi and float(sh.rf) == gf, "Random.new(seed) draws Godot's PCG32 (%d %s / %d %s)" % [int(sh.ri), sh.rf, gi, gf])
	_check(int(sh.spawned) == 7 and bool(sh.wait_errors), "task.spawn runs at once, task.wait raises")
	_check(not bool(sh.global_write), "globals are read-only after boot (sandbox)")
	# --- calibration of randf_range rounding
	var samples: Array = []
	for i in 40:
		var s := 1000 + i * 7919
		var r := RandomNumberGenerator.new()
		r.seed = s
		var a := -3.7 + i * 0.913
		var b := a + 1234.567 * (i + 1)
		samples.append([s, a, b, r.randf_range(a, b)])
	var fused: Variant = vm.call_fn("rng_check", "calibrate", [samples])
	_check(fused != null, "randf_range rounding mode found (fused=%s)" % str(fused))
	# --- streams
	var pick := RandomNumberGenerator.new()
	pick.seed = 77
	var ri_ranges := [[-100, 100], [0, 2147483647], [5, 5], [10, -10], [-1000000000, 1000000000], [0, 1], [1, 6]]
	var rf_ranges := [[-1.5, 2.25], [0.0, 1000000.0], [3.3, -7.1], [0.1, 0.1], [0.0, 1.0], [-6.25, 6.25]]
	for s in SEEDS:
		var ops := PackedByteArray()
		var expect := PackedFloat64Array()
		var g := RandomNumberGenerator.new()
		g.seed = s
		var n := 3000
		ops.resize(n * 24)
		for i in n:
			var op := pick.randi_range(0, 3)
			if i == 1500: op = 4
			var a := 0.0
			var b := 0.0
			var v := 0.0
			match op:
				0: v = float(g.randi())
				1: v = g.randf()
				2:
					var rr: Array = ri_ranges[pick.randi() % ri_ranges.size()]
					a = rr[0]; b = rr[1]
					v = float(g.randi_range(int(a), int(b)))
				3:
					var fr: Array = rf_ranges[pick.randi() % rf_ranges.size()]
					a = fr[0]; b = fr[1]
					v = g.randf_range(a, b)
				4:
					a = float(s + 99)
					g.seed = s + 99
			ops.encode_s32(i * 24, op)
			ops.encode_double(i * 24 + 8, a)
			ops.encode_double(i * 24 + 16, b)
			expect.append(v)
		var res: Dictionary = vm.call_fn("rng_check", "run", [s, ops])
		var got: PackedByteArray = res.res
		var bad := -1
		for i in n:
			if got.decode_double(i * 8) != expect[i]:
				bad = i
				break
		_check(bad < 0 and str(res.state) == str(g.state),
			"seed %d: 3000 mixed randi / randf / randi_range / randf_range / reseed identical, state %s (first diff %d)" % [s, str(g.state), bad])
	# --- hash(int)
	var hs: Array[int] = [0, 1, -1, 5516, 1099511627779, -1125899906842624, 2147483648, 9007199254740991]
	var hok := true
	for x in hs:
		if int(vm.call_fn("rng_check", "hash_int", [x])) != hash(x):
			hok = false
	_check(hok, "hash(int) for %d values" % hs.size())
	# --- global seed() + Array.shuffle()
	for s in [5516, 12345, -7]:
		seed(s)
		var arr: Array = range(60)
		arr.shuffle()
		var after: Array = [randi(), randi(), randi()]
		var lr: Dictionary = vm.call_fn("rng_check", "shuffle", [s, 60, 3])
		var la: Array = []
		for v in lr.arr: la.append(int(v))
		var lafter: Array = []
		for v in lr.after: lafter.append(int(v))
		_check(la == arr and lafter == after, "seed(%d) + Array.shuffle() of 60 + 3 global randi()" % s)
	# --- tribe setup (game/nations.gd): shuffle with rng.randi() % (i + 1), two dummy randf() per tribe
	for s in [5516, 12345]:
		var g := RandomNumberGenerator.new()
		g.seed = s
		var nn := 480
		var order := PackedInt32Array()
		order.resize(nn)
		for i in nn: order[i] = i
		for i in range(nn - 1, 0, -1):
			var j := g.randi() % (i + 1)
			var tmp := order[i]; order[i] = order[j]; order[j] = tmp
		for k in 400:
			g.randf(); g.randf()
		var st := str(g.state)
		var nxt := g.randi()
		var lt: Dictionary = vm.call_fn("rng_check", "tribe_draws", [s, nn, 400])
		var lo := PackedInt32Array()
		for v in lt.order: lo.append(int(v))
		_check(lo == order and str(lt.state) == st and int(lt.next) == nxt, "seed %d: tribe order + 800 dummy draws, same state after" % s)
	var nb := 200000
	var lt_s: float = vm.call_fn("rng_check", "bench", [nb])
	var gb := RandomNumberGenerator.new()
	gb.seed = 5516
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for i in nb:
		acc += float(gb.randi()) + gb.randf()
	var gt_s := float(Time.get_ticks_usec() - t0) / 1e6
	print("  info %d randi + randf: Luau %.1f ms, GDScript %.1f ms" % [nb, lt_s * 1000.0, gt_s * 1000.0])
	_done()


func _done() -> void:
	print("LUAU_RNG_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails > 0 else 0)
