# Port of RoWorld SimNaval.luau: water bodies, transport limits/tokens/landing, and trade ships
# (ports_tick: every 10 ticks each finished port rolls `level` times against tradeShipSpawnRate with a
# pity timer, picks a partner port of a non-hostile owner on the same water body, sails, and pays
# tradeShipGold(tiles sailed) to both owners).
extends RefCounted
class_name SimNaval

var g
var R: SimRules
var body := PackedInt32Array()
var tokens := {}       # owner -> boat orders left this second
var path_budget := 0

func _init(main, rules: SimRules) -> void:
	g = main
	R = rules

var coast_list := PackedInt32Array()

func own_coast_tile(id: int) -> int:
	var n := coast_list.size()
	if n == 0: return -1
	for _k in 400:
		var c: int = coast_list[g.rng.randi() % n]
		if g.owner_map[c] == id: return c
	return -1

func compute_bodies() -> void:
	var W: int = g.W
	var om: PackedInt32Array = g.owner_map
	var N: int = om.size()
	var WT: int = g.WATER
	var bd := PackedInt32Array(); bd.resize(N); bd.fill(0)
	var q := PackedInt32Array(); q.resize(N)
	var next := 1
	for s in N:
		if om[s] != WT or bd[s] != 0: continue
		var qn := 1; q[0] = s
		bd[s] = next
		var qi := 0
		while qi < qn:
			var i: int = q[qi]; qi += 1
			var x := i % W
			var j := i - W
			if j >= 0 and bd[j] == 0 and om[j] == WT: bd[j] = next; q[qn] = j; qn += 1
			j = i + W
			if j < N and bd[j] == 0 and om[j] == WT: bd[j] = next; q[qn] = j; qn += 1
			if x > 0:
				j = i - 1
				if bd[j] == 0 and om[j] == WT: bd[j] = next; q[qn] = j; qn += 1
			if x < W - 1:
				j = i + 1
				if bd[j] == 0 and om[j] == WT: bd[j] = next; q[qn] = j; qn += 1
		next += 1
	body = bd
	var cl := PackedInt32Array(); cl.resize(N); var cn := 0
	for i in N:
		if om[i] == WT: continue
		if (i >= 1 and om[i - 1] == WT) or (i + 1 < N and om[i + 1] == WT) or (i >= W and om[i - W] == WT) or (i + W < N and om[i + W] == WT):
			cl[cn] = i; cn += 1
	cl.resize(cn)
	coast_list = cl

# water body a coastal land tile touches (first of west, east, north, south), 0 if none
func coast_body(t: int) -> int:
	var W: int = g.W
	var x := t % W
	for j in [t - 1 if x > 0 else -1, t + 1 if x < W - 1 else -1, t - W, t + W]:
		if j >= 0 and j < body.size() and body[j] > 0: return body[j]
	return 0

func water_next_to(t: int) -> int:
	var W: int = g.W
	var x := t % W
	for j in [t - 1 if x > 0 else -1, t + 1 if x < W - 1 else -1, t - W, t + W]:
		if j >= 0 and j < body.size() and body[j] > 0: return j
	return -1

func tick() -> void:
	var t: int = g.sim_atk.tick
	if g.sim_nav != null: g.sim_nav.begin_tick()  # SimNav per-tick search budget (budget_n searches)
	if t % 10 == 0:
		tokens.clear()
	# trade-route searches: 2 per tick (upstream Sim.step path_budget = 2); the old BFS fallback (no nav
	# graph) keeps 1 per 4 ticks. Counted per tick only (no frame-time deferral), so runs are repeatable.
	var nav_ok: bool = g.sim_nav != null and g.sim_nav.ready
	path_budget = 2 if nav_ok else (1 if t % 4 == 0 else 0)
	_ports_tick(t)

func take_token(id: int) -> bool:
	var left: int = tokens.get(id, SimRules.BOAT_SEARCHES_PER_S)
	if left <= 0: return false
	tokens[id] = left - 1
	return true

func boats_of(id: int) -> int:
	var c := 0
	for bt in g.boats:
		if bt.a == id: c += 1
	return c

func max_boats(id: int) -> int:
	return SimRules.MAX_BOATS_PLAYER if id == g.PLAYER else SimRules.MAX_BOATS_PER_OWNER

func landable(id: int, t: int) -> bool:
	var o: int = g.owner_map[t]
	if o < 0: return false
	return o != id and not (o > 0 and g.allied(id, o))

func alt_landing(id: int, t: int, wb: int) -> int:
	var W: int = g.W; var H: int = g.H
	var cx := t % W; var cy := t / W
	for r in range(1, R.alt_landing_r() + 1):
		for dy in range(-r, r + 1):
			var y := cy + dy
			if y < 0 or y >= H: continue
			for dx in range(-r, r + 1):
				var x := cx + dx
				if x < 0 or x >= W: continue
				var c := y * W + x
				if g._coastal(c) and coast_body(c) == wb and landable(id, c): return c
	return -1

# at war = embargo or a live attack either way; attack pairs cached once per tick (was two list scans per call)
var _hp_tick := -1
var _hp := {}
func hostile(a: int, b: int) -> bool:
	if g.is_embargoed(a, b): return true
	var t: int = g.sim_atk.tick
	if t != _hp_tick:
		_hp_tick = t
		_hp.clear()
		var W: int = 1 << 16
		for at in g.attacks:
			if at.get("dead", false): continue
			_hp[int(at.a) * W + int(at.t)] = true
			_hp[int(at.t) * W + int(at.a)] = true
	return _hp.has(a * 65536 + b)

# ---------------- trade ----------------
func _ports_tick(t: int) -> void:
	if _luau_ports(t): return  # Step 5d2: luau/sim/Core/SimNaval.luau
	_ports_tick_gd(t)

func _ports_tick_gd(t: int) -> void:
	var slot := t % 10
	var rng: RandomNumberGenerator = g.rng
	var n_trade: int = g.traders.size()
	for p in g.structs:
		if p.k != 1 or float(p.get("bt", 0.0)) > 0.0: continue
		if not p.has("slot"):
			p.slot = rng.randi() % 10; p.rej = 0; p.partners = []; p.ptick = -100000
			p.water = water_next_to(p.tile); p.body = body[p.water] if p.water >= 0 else 0
		if p.slot != slot or p.water < 0 or not g.nations[p.o].alive: continue
		var hit := false
		for _l in mini(int(p.get("level", 1)), 1000):
			if rng.randi() % R.trade_spawn_rate(p.rej, n_trade) == 0:
				hit = true; break
			p.rej += 1
		if not hit: continue
		p.rej = 0
		var dst = _pick_partner(p, t)
		if dst == null: continue
		var pts := _trade_path(p, dst)
		if pts.size() < 2:
			if path_budget <= 0: p.rej += 1
			continue
		var cum := PackedFloat32Array([0.0])
		for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
		g.traders.append({"o": p.o, "pts": pts, "cum": cum, "d": 0.0, "dst": dst, "src": p,
			"gold": floor(R.trade_gold(cum[cum.size() - 1] / g.TS))})
		n_trade += 1

func _pick_partner(p: Dictionary, t: int):
	if p.partners.is_empty() or t - int(p.ptick) > 1200:
		_refresh_partners(p, t)
	var n: int = p.partners.size()
	for _k in 3:
		if n == 0: return null
		var q = g.struct_at.get(int(p.partners[g.rng.randi() % n]))  # partners hold tiles (no struct<->struct cycles)
		if q == null or q.k != 1 or q.o == p.o or not g.nations[q.o].alive or hostile(p.o, q.o): continue
		return q
	p.ptick = -100000
	return null

func _refresh_partners(p: Dictionary, t: int) -> void:
	p.ptick = t
	var keep := []
	for qt in p.partners:
		var q = g.struct_at.get(int(qt))
		if q != null and q.k == 1 and q.o != p.o and g.nations[q.o].alive: keep.append(int(qt))
	var dists := []
	var W: int = g.W
	for q in g.structs:
		if q.k != 1 or float(q.get("bt", 0.0)) > 0.0 or q.o == p.o or not g.nations[q.o].alive: continue
		if not q.has("slot"): continue
		if q.body != p.body or q.water < 0 or hostile(p.o, q.o): continue
		dists.append([(absi(p.tile % W - q.tile % W) + absi(p.tile / W - q.tile / W)) * R.k_lin, q])
	dists.sort_custom(func(a, b): return a[0] < b[0])
	var n := dists.size()
	var bonus_n := clampi(n / 3, mini(4, n), n)
	var cands := []
	var weights := []
	var total := 0.0
	for i in n:
		var q = dists[i][1]
		var far: bool = dists[i][0] >= SimRules.TRADE_SHORT_RANGE_FULL
		var lv := int(q.get("level", 1))
		var w := lv
		if far and i < bonus_n: w += lv
		if far and g.allied(p.o, q.o): w += lv
		cands.append(q); weights.append(w); total += w
	var partners := keep.duplicate()
	for _k in 8 - keep.size():
		if cands.is_empty(): break
		var r: float = g.rng.randf() * total
		var pick = cands[cands.size() - 1]
		for i in cands.size():
			r -= weights[i]
			if r <= 0.0: pick = cands[i]; break
		if not (int(pick.tile) in partners): partners.append(int(pick.tile))
	p.partners = partners

var trade_cache := {}
func _trade_path(a: Dictionary, b: Dictionary) -> PackedVector2Array:
	var key := "%d:%d" % [a.tile, b.tile]
	if trade_cache.has(key): return trade_cache[key]
	var rk := "%d:%d" % [b.tile, a.tile]
	if trade_cache.has(rk):
		var rv: PackedVector2Array = trade_cache[rk].duplicate()
		rv.reverse()
		trade_cache[key] = rv
		return rv
	if path_budget <= 0: return PackedVector2Array()
	path_budget -= 1
	var _b0 := Time.get_ticks_usec()
	var pts: PackedVector2Array
	if g.sim_nav != null and g.sim_nav.ready:
		pts = g.sim_nav.water_path_px(a.tile, b.tile, g.TS, false)
		if pts.is_empty() and g.sim_nav.last_deferred: return pts  # over this tick's budget: retry, don't cache
	else:
		pts = g._water_path(a.tile, b.tile, 60000)
	g._pf_add("nv_bfs", Time.get_ticks_usec() - _b0)
	trade_cache[key] = pts
	if trade_cache.size() > 2000: trade_cache.clear()
	return pts


# ---------------- Luau (Step 5d2 of docs/LUAU_PORT.md) ----------------
# The trade ships' ports tick runs in luau/sim/Core/SimNaval.luau when the water graph is in Luau (sim/nav.gd
# on_luau): the ports stay Dictionaries in game.structs; each call sends their trade fields and gets back the fields
# it changed and the new trade ships (made here, with the same cum and gold as _ports_tick_gd). Luau keeps the trade
# route cache; trade_gen (map.gd, with trade_cache.clear()) tells it a new map's water bodies came.
const LNAVAL := "Core/SimNaval"
var trade_gen := 0
var _lgen_sent := -1
var _lvm_sent: LuauVM = null
var luau_calls := 0  # ports ticks that ran in Luau (tests)

func _luau_ports(t: int) -> bool:
	if g.net_remote or OS.has_environment("NO_LUAU_SIM"): return false
	var nav = g.sim_nav
	if nav == null or not nav.ready or not nav.on_luau(): return false
	var lu = g.get("luau_link")
	if lu == null or not lu.on or not is_same(lu.vm, nav._lvm): return false
	var vm: LuauVM = lu.vm
	var slot := t % 10
	# a cheap pass first: most ticks no port rolls, and then nothing is sent (the GDScript draws nothing either)
	var need := false
	for p in g.structs:
		if p.k != 1 or float(p.get("bt", 0.0)) > 0.0: continue
		if not p.has("slot") or (int(p.slot) == slot and int(p.water) >= 0 and g.nations[p.o].alive):
			need = true
			break
	if not need: return true
	var ports: Array = []
	var snap := PackedFloat64Array()
	for p in g.structs:
		if p.k != 1: continue
		var has: bool = p.has("slot")
		var bt: float = float(p.get("bt", 0.0))
		snap.append(ports.size()); snap.append(p.tile); snap.append(p.o); snap.append(int(p.get("level", 1))); snap.append(bt)
		snap.append(1.0 if has else 0.0)
		if has:
			snap.append(p.slot); snap.append(p.rej); snap.append(p.ptick); snap.append(p.water); snap.append(p.body)
			snap.append(p.partners.size())
			for v in p.partners: snap.append(v)
		else:
			for _k in 6: snap.append(0.0)
		ports.append(p)
	if not vm.require_module(LNAVAL) or not lu.flush(g):
		if lu.on: lu._fail(g, vm.last_error)
		return false
	var wc: Array = g.sim_atk.world_call()  # Step 5g2
	if vm.call_fn("Core/SimArsenal", wc[0], wc[1]) == null:
		lu._fail(g, vm.last_error)
		return false
	# the attack pairs hostile() would see now: its cache when it was built this tick, else what it would build
	var fresh := {}
	var hp := PackedInt32Array()
	if _hp_tick == t:
		for k in _hp: hp.append(k)
	else:
		var Wk: int = 1 << 16
		for at in g.attacks:
			if at.get("dead", false): continue
			fresh[int(at.a) * Wk + int(at.t)] = true
			fresh[int(at.t) * Wk + int(at.a)] = true
		for k in fresh: hp.append(k)
	var bodyb := PackedByteArray()
	if trade_gen != _lgen_sent or not is_same(vm, _lvm_sent): bodyb = body.to_byte_array()
	var hdr := PackedFloat64Array([t, nav._lid, path_budget, g.traders.size(), g.TS, g.W,
		trade_gen])
	var rf := PackedFloat64Array()
	for k in SimAttacks.RULE_FIELDS: rf.append(float(R.get(k)))
	var rg := LuauLink.rng_args(g)
	var out = vm.call_fn(LNAVAL, "ports_tick", [rg[0], rg[1], hdr.to_byte_array(), rf.to_byte_array(),
		snap.to_byte_array(), bodyb, hp.to_byte_array()])
	if out == null:
		lu._fail(g, vm.last_error)
		return false
	_lgen_sent = trade_gen
	_lvm_sent = vm
	luau_calls += 1
	var hi: int = int(out.rhi)
	if hi >= 0x80000000: hi -= 0x100000000
	g.rng.state = hi * 0x100000000 + int(out.rlo)
	path_budget = int(out.pb)
	if bool(out.hu) and _hp_tick != t:
		_hp_tick = t
		_hp = fresh
	var pw: PackedFloat64Array = (out.pw as PackedByteArray).to_float64_array()
	var k := 0
	while k < pw.size():
		var p: Dictionary = ports[int(pw[k])]
		if pw[k + 1] != 0.0:  # made this call: the keys in _ports_tick_gd's order
			p.slot = int(pw[k + 2]); p.rej = int(pw[k + 3]); p.partners = []; p.ptick = int(pw[k + 4])
			p.water = int(pw[k + 5]); p.body = int(pw[k + 6])
		else:
			p.slot = int(pw[k + 2]); p.rej = int(pw[k + 3]); p.ptick = int(pw[k + 4])
			p.water = int(pw[k + 5]); p.body = int(pw[k + 6])
		var np := int(pw[k + 7])
		var parts: Array = p.partners
		var same: bool = parts.size() == np
		if same:
			for j in np:
				if int(parts[j]) != int(pw[k + 8 + j]): same = false; break
		if not same:
			var pa := []
			for j in np: pa.append(int(pw[k + 8 + j]))
			p.partners = pa
		k += 8 + np
	var nt: PackedFloat64Array = (out.nt as PackedByteArray).to_float64_array()
	k = 0
	while k < nt.size():
		var p: Dictionary = ports[int(nt[k])]
		var dst: Dictionary = ports[int(nt[k + 1])]
		var n := int(nt[k + 2])
		var pts := PackedVector2Array()
		pts.resize(n)
		for j in n: pts[j] = Vector2(nt[k + 3 + 2 * j], nt[k + 4 + 2 * j])
		k += 3 + 2 * n
		var cum := PackedFloat32Array([0.0])
		for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
		g.traders.append({"o": p.o, "pts": pts, "cum": cum, "d": 0.0, "dst": dst, "src": p,
			"gold": floor(R.trade_gold(cum[cum.size() - 1] / g.TS))})
	return true
