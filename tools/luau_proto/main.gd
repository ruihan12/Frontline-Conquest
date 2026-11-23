extends Node
const W := 2000
const H := 1000
const NT := W * H
const CAP := 2
var om := PackedInt32Array()
var border: Array = []
var land := PackedInt32Array()
var troops := PackedFloat64Array()
var pf4 := PackedInt32Array()
var rs := 12345
var attacks: Array = []
var tick := 0

func rnd() -> int:
	rs = (rs * 48271) % 2147483647
	return rs

func hpush(hk: PackedInt64Array, ht: PackedInt32Array, key: int, t: int) -> void:
	hk.append(key); ht.append(t)
	var i := hk.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		var kp := hk[p]
		if kp <= key: break
		hk[i] = kp; ht[i] = ht[p]
		i = p
	hk[i] = key; ht[i] = t

func hpop(hk: PackedInt64Array, ht: PackedInt32Array) -> int:
	var n := hk.size()
	if n == 0: return -1
	var top := ht[0]
	var lk := hk[n - 1]; var lt := ht[n - 1]
	n -= 1
	hk.resize(n); ht.resize(n)
	if n == 0: return top
	var i := 0
	while true:
		var l := i * 2 + 1
		if l >= n: break
		var m := l
		if l + 1 < n and hk[l + 1] < hk[l]: m = l + 1
		if lk <= hk[m]: break
		hk[i] = hk[m]; ht[i] = ht[m]
		i = m
	hk[i] = lk; ht[i] = lt
	return top

func is_border(i: int) -> bool:
	var o := om[i]
	var x := i % W
	if x > 0 and om[i - 1] != o: return true
	if x < W - 1 and om[i + 1] != o: return true
	if i >= W and om[i - W] != o: return true
	if i < NT - W and om[i + W] != o: return true
	return false

func upd_border(i: int) -> void:
	var o := om[i]
	if is_border(i): border[o][i] = true
	else: border[o].erase(i)

func set_own(i: int, o: int) -> void:
	var old := om[i]
	border[old].erase(i)
	land[old] -= 1
	om[i] = o
	land[o] += 1
	upd_border(i)
	var x := i % W
	if x > 0: upd_border(i - 1)
	if x < W - 1: upd_border(i + 1)
	if i >= W: upd_border(i - W)
	if i < NT - W: upd_border(i + W)

func init_state() -> void:
	om.resize(NT)
	for y in H:
		var cy := y / 50
		for x in W:
			om[y * W + x] = cy * 20 + x / 100 + 1
	land.resize(401); troops.resize(401)
	border.resize(401)
	for o in range(1, 401):
		border[o] = {}; land[o] = 5000; troops[o] = 1e9
	pf4.resize(40)
	for i in 40: pf4[i] = 1 + (i % 5)
	for i in NT:
		if is_border(i): border[om[i]][i] = true
	for cy in 20:
		for cx in 20:
			var at := cy * 20 + cx + 1
			if cx < 19:
				var a := {"a": at, "t": at + 1, "hk": PackedInt64Array(), "ht": PackedInt32Array(), "front": {}, "troops": 1e9}
				for y in range(cy * 50, cy * 50 + 50):
					var t := y * W + (cx + 1) * 100
					hpush(a.hk, a.ht, 4 * tick + (10 + rnd() % 7) * 2, t)
					a.front[t] = true
				attacks.append(a)
			if cy < 19:
				var a := {"a": at, "t": at + 20, "hk": PackedInt64Array(), "ht": PackedInt32Array(), "front": {}, "troops": 1e9}
				for x in range(cx * 100, cx * 100 + 100):
					var t := (cy + 1) * 50 * W + x
					hpush(a.hk, a.ht, 4 * tick + (10 + rnd() % 7) * 2, t)
					a.front[t] = true
				attacks.append(a)

func add_neighbors(a: Dictionary, t: int, tg: int, at: int) -> void:
	var x := t % W
	var t4 := 4 * tick
	var hk: PackedInt64Array = a.hk
	var ht: PackedInt32Array = a.ht
	var front: Dictionary = a.front
	for k in 4:
		var u: int
		if k == 0:
			if t < W: continue
			u = t - W
		elif k == 1:
			if t >= NT - W: continue
			u = t + W
		elif k == 2:
			if x == 0: continue
			u = t - 1
		else:
			if x == W - 1: continue
			u = t + 1
		if om[u] != tg: continue
		var ux := u % W
		var n := 0
		if ux > 0 and om[u - 1] == at: n += 1
		if ux < W - 1 and om[u + 1] == at: n += 1
		if u >= W and om[u - W] == at: n += 1
		if u < NT - W and om[u + W] == at: n += 1
		var key := t4 + (10 + rnd() % 7) * pf4[(u % 8) * 5 + n]
		hpush(hk, ht, key, u)
		front[u] = true

func process(a: Dictionary) -> int:
	var at: int = a.a
	var tg: int = a.t
	var hk: PackedInt64Array = a.hk
	var ht: PackedInt32Array = a.ht
	var front: Dictionary = a.front
	var budget := 1.0
	var taken := 0
	var tr: float = a.troops
	var border_of := front.size() * 1.0 + rnd() % 8
	while budget > 0.0:
		if taken >= CAP: break
		var t := hpop(hk, ht)
		if t < 0: break
		front.erase(t)
		var tx := t % W
		if om[t] != tg or not ((tx > 0 and om[t - 1] == at) or (tx < W - 1 and om[t + 1] == at) or (t >= W and om[t - W] == at) or (t < NT - W and om[t + W] == at)): continue
		add_neighbors(a, t, tg, at)
		var dtr := troops[tg]
		var ratio := dtr / tr
		var loss := 0.5 * clampf(ratio, 0.6, 2.0) * (1.0 + 0.001 * (dtr / maxf(land[tg], 1)))
		var tf := maxf(clampf(ratio, 0.82, 7.5) * clampf(ratio / 20.0, 1.0, 50.0) * 1.0 * 0.02 / maxf(border_of, 1.0), 1e-6)
		budget -= tf
		tr -= loss
		troops[tg] -= minf(loss, maxf(troops[tg], 0.0))
		set_own(t, at)
		taken += 1
	a.troops = tr
	return taken

func gd_tick() -> int:
	tick += 1
	var total := 0
	for a in attacks: total += process(a)
	return total

func gd_checksum() -> Array:
	var s := 0
	var i := 0
	while i < NT:
		s = (s + om[i] * (i % 97 + 1)) % 1000000007
		i += 7
	var b := 0
	for o in range(1, 401): b += border[o].size()
	return [s * 1000 + b % 1000, b]

func _ready() -> void:
	var TICKS := 200
	print("LUAUTEST kernel start")
	# GDScript
	init_state()
	var t0 := Time.get_ticks_usec()
	var tot := 0
	var worst := 0
	for i in TICKS:
		var a0 := Time.get_ticks_usec()
		tot += gd_tick()
		worst = maxi(worst, Time.get_ticks_usec() - a0)
	var gd_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("LUAUTEST gdscript tiles=", tot, " total_ms=", gd_ms, " per_tick_ms=", gd_ms / TICKS, " worst_ms=", worst / 1000.0, " chk=", gd_checksum())
	# Luau
	if not ClassDB.class_exists("LuaState"):
		print("LUAUTEST FAIL no LuaState"); return
	var f := FileAccess.open("res://kernel.luau", FileAccess.READ)
	var src := f.get_as_text()
	var st = ClassDB.instantiate("LuaState")
	st.open_libs()
	var bc = ClassDB.instantiate("Luau").compile(src)
	var ok = st.load_bytecode(bc, "kernel")
	if not ok:
		print("LUAUTEST FAIL load: ", st.to_string_at(-1) if st.has_method("to_string_at") else "?"); return
	st.pcall(0, 1)  # module table on stack
	st.set_global("K")
	var i0 := Time.get_ticks_usec()
	st.do_string("K.init()", "init")
	print("LUAUTEST luau init_ms=", (Time.get_ticks_usec() - i0) / 1000.0)
	var l0 := Time.get_ticks_usec()
	var ltot := 0.0
	var lworst := 0
	for i in TICKS:
		var a0 := Time.get_ticks_usec()
		st.do_string("TOT = K.tick()", "tick")
		lworst = maxi(lworst, Time.get_ticks_usec() - a0)
	var l_ms := (Time.get_ticks_usec() - l0) / 1000.0
	st.do_string("CHK, BB = K.checksum()", "chk")
	st.get_global("CHK"); var chk = st.to_number(-1); st.pop(1)
	st.get_global("BB"); var bb = st.to_number(-1); st.pop(1)
	st.get_global("TOT"); var lt = st.to_number(-1); st.pop(1)
	print("LUAUTEST luau total_ms=", l_ms, " per_tick_ms=", l_ms / TICKS, " worst_ms=", lworst / 1000.0, " chk=[", chk, ", ", bb, "] last_tick_tiles=", lt)
	print("LUAUTEST done")
