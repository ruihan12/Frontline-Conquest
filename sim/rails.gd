# Rail networks and gold trains: the sim half of the old game/rails.gd (split before Step 5b2 of docs/LUAU_PORT.md).
# Port of upstream SimStructures.rail_path / _link_nearby / factories_tick / _truck_tick (RoWorld): station links,
# rail paths (A* on a minimap), factory train spawns, train legs and train gold. The state stays on the game
# (rail_cache, _rail_nb_cache, _rail_mst, trains, the per-tick search budgets): the renderer, net/rep.gd and the
# tests read it there. game/rails.gd keeps the drawing-side readers (_rail_neighbors_view), the land-path helpers and
# the fx, and forwards the old names here.
extends RefCounted
class_name SimRails

var g


func _init(main) -> void:
	g = main


# Upstream SimStructures.rail_path, land only: A* on a minimap (RAIL_MINIMAP = 2 below k_lin 1.5), heuristic
# weight 2, turn penalty 3, nodes that cannot lie on a path shorter than RAIL_MAX_PATH are never searched,
# the newest of equal priorities comes out first. The path (from -> to, 4-connected) is scaled back up.
# (Replaces a 4-neighbour breadth-first search over up to 30000 tiles: ~9 ms a route, 4 routes a frame.)
func _rail_astar(from_t: int, to_t: int) -> PackedInt32Array:
	var W: int = g.W
	var H: int = g.H
	var owner_map: PackedInt32Array = g.owner_map
	var f := 2 if g.sim_rules.k_lin < 1.5 else 1
	var mw := (W + f - 1) / f
	var mh := (H + f - 1) / f
	var start := ((from_t / W) / f) * mw + (from_t % W) / f
	var goal := ((to_t / W) / f) * mw + (to_t % W) / f
	var sx := start % mw; var sy := start / mw
	var gx := goal % mw; var gy := goal / mw
	var limit := int(ceil(g.sim_rules.rail_max_path() / float(f))) + 2
	var out := PackedInt32Array()
	if absi(sx - gx) + absi(sy - gy) > limit: return out
	var hw := 2
	var tpen := 3
	var hp := PackedInt32Array(); var hq := PackedInt32Array(); var hn := PackedInt32Array()
	var seq := 0
	var gs := {start: 0}
	var parent := {start: -1}
	var closed := {}
	# push (binary heap on priority, then newest sequence first)
	hp.append(hw * (absi(sx - gx) + absi(sy - gy))); hq.append(0); hn.append(start)
	var expanded := 0
	var found := false
	var nbs := PackedInt32Array([0, 0, 0, 0])
	while hp.size() > 0:
		var node: int = hn[0]
		var last := hp.size() - 1
		var lp: int = hp[last]; var lq: int = hq[last]; var ln: int = hn[last]
		hp.resize(last); hq.resize(last); hn.resize(last)
		if last > 0:
			var i := 0
			while true:
				var c := i * 2 + 1
				if c >= last: break
				if c + 1 < last and (hp[c + 1] < hp[c] or (hp[c + 1] == hp[c] and hq[c + 1] > hq[c])): c += 1
				if lp < hp[c] or (lp == hp[c] and lq > hq[c]): break
				hp[i] = hp[c]; hq[i] = hq[c]; hn[i] = hn[c]
				i = c
			hp[i] = lp; hq[i] = lq; hn[i] = ln
		if closed.has(node): continue
		closed[node] = true
		if node == goal:
			found = true
			break
		expanded += 1
		if expanded > 60000: break
		var x := node % mw; var y := node / mw
		var prev: int = parent[node]
		var gn: int = gs[node]
		var nn := 0
		if y > 0: nbs[nn] = node - mw; nn += 1
		if y < mh - 1: nbs[nn] = node + mw; nn += 1
		if x > 0: nbs[nn] = node - 1; nn += 1
		if x < mw - 1: nbs[nn] = node + 1; nn += 1
		for k in nn:
			var m: int = nbs[k]
			if closed.has(m): continue
			var mx := m % mw; var my := m / mw
			if m != goal and owner_map[my * f * W + mx * f] < 0: continue  # water
			var hg := absi(mx - gx) + absi(my - gy)
			if absi(mx - sx) + absi(my - sy) + hg > limit: continue
			var c := 1
			if prev >= 0 and node - prev != m - node: c += tpen
			var ng := gn + c
			var og = gs.get(m)
			if og == null or ng < int(og):
				gs[m] = ng; parent[m] = node
				seq += 1
				# push
				var pri := ng + hw * hg
				hp.append(pri); hq.append(seq); hn.append(m)
				var j := hp.size() - 1
				while j > 0:
					var pp := (j - 1) / 2
					if hp[pp] < pri or (hp[pp] == pri and hq[pp] > seq): break
					hp[j] = hp[pp]; hq[j] = hq[pp]; hn[j] = hn[pp]
					j = pp
				hp[j] = pri; hq[j] = seq; hn[j] = m
	if not found: return out
	var mini_path := []
	var cur := goal
	while cur >= 0:
		mini_path.append(cur); cur = parent[cur]
	mini_path.reverse()
	# scale up to full tiles, 4-connected (from first, to last)
	var px := from_t % W; var py := from_t / W
	out.append(from_t)
	for mnode in mini_path:
		var tx: int = (mnode % mw) * f
		var ty: int = (mnode / mw) * f
		if mnode == goal: tx = to_t % W; ty = to_t / W
		while px != tx:
			px += signi(tx - px); out.append(py * W + px)
		while py != ty:
			py += signi(ty - py); out.append(py * W + px)
	return out

func _rail_curve(tile_a: int, tile_b: int) -> Array:
	var W: int = g.W
	# Upstream SimStructures.rail_path: a 4-neighbour land path (A* on a uniform grid here).
	# No custom Manhattan L-shape / MST geometry.
	var lo_t := mini(tile_a, tile_b)
	var hi_t := maxi(tile_a, tile_b)
	var key := "r%d:%d" % [lo_t, hi_t]
	if g.rail_cache.has(key):
		return g.rail_cache[key]
	if g._rail_bfs_left <= 0:
		g._rail_pending = true
		return []
	g._rail_bfs_left -= 1
	var raw := _rail_astar(lo_t, hi_t)
	var max_path: float = g.sim_rules.rail_max_path()
	if raw.size() < 2 or float(raw.size()) >= max_path:
		g.rail_cache[key] = []
		return []
	var pts := PackedVector2Array()
	for t in raw:
		var v := Vector2(t % W + 0.5, t / W + 0.5)
		if pts.size() >= 1 and pts[pts.size() - 1] == v: continue
		if pts.size() >= 2:
			var u := pts[pts.size() - 2]; var w := pts[pts.size() - 1]
			if (u.x == w.x and w.x == v.x) or (u.y == w.y and w.y == v.y): pts[pts.size() - 1] = v; continue
		pts.append(v)
	if pts.size() < 2:
		g.rail_cache[key] = []
		return []
	var cum := PackedFloat32Array([0.0])
	for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
	var res := [pts, cum, []]
	g.rail_cache[key] = res
	return res

func _rail_neighbors(st) -> Array:
	if not (st.k in g.RAIL_KINDS) or st.get("bt", 0.0) > 0.0: return []
	# per-owner cache: one nation building something no longer invalidates everyone's rail web
	var ver := "%d|%d|%d|%d" % [st.o, g._own_sv.get(st.o, 0), g.allies.size(), g.embargoes.size()]
	var ce = g._rail_nb_cache.get(st.tile)
	if ce != null and ce[0] == ver and g.elapsed - float(ce[1]) < 6.0: return ce[2]
	if g._rail_calc_left <= 0 and ce != null: return ce[2]  # over this tick's budget: reuse the stale list
	g._rail_calc_left -= 1
	g._rail_pending = false
	var r := _rail_neighbors_calc(st)
	if not g._rail_pending: g._rail_nb_cache[st.tile] = [ver, g.elapsed, r]
	return r

func _rail_warm() -> void:
	for st in g.structs:
		if st.k in g.RAIL_KINDS and st.get("bt", 0.0) <= 0.0: _rail_neighbors(st)

func _rail_neighbors_calc(st) -> Array:
	var ver := "%d|%d|%d" % [st.o, g._own_sv.get(st.o, 0), int(g.elapsed / 6.0)]
	# an unfinished web (route searches ran out of this frame's budget) is kept for the rest of the frame only,
	# so the next frame carries on, instead of every station rebuilding the whole web again and again
	var pver := ver + "|f%d" % g._rail_frame
	var ce = g._rail_mst.get(st.o)
	if ce == null or (ce[0] != ver and ce[0] != pver):
		var adj := _build_rail_mst(st.o)
		if adj.is_empty() and g._rail_pending and ce != null:
			adj = ce[1]
		ce = [pver if g._rail_pending else ver, adj]
		g._rail_mst[st.o] = ce
	return ce[1].get(st.tile, [])

func _rail_hops(from, to, max_d: int, adj: Dictionary) -> int:
	if from == to or from.tile == to.tile: return 0
	var seen := {from.tile: true}
	var frontier: Array = [from.tile]
	for d in range(1, max_d + 1):
		var nxt: Array = []
		for t in frontier:
			for nb in adj.get(t, []):
				if nb.tile == to.tile: return d
				if not seen.has(nb.tile):
					seen[nb.tile] = true
					nxt.append(nb.tile)
		if nxt.is_empty(): break
		frontier = nxt
	return -1

# Port of SimStructures._link_nearby (Rules.luau trainStationMin/MaxRange, RAIL_LINK_HOPS):
# link stations 15..110 full-size tiles apart, nearest first, when they are not already within
# 4 hops and a 4-neighbour land path shorter than railroadMaxSize exists. No Kruskal MST.
func _build_rail_mst(o: int) -> Dictionary:
	var W: int = g.W
	var nodes := []; var facs := []
	var rmax: float = g.sim_rules.road_max_tiles()
	var rmin: float = g.sim_rules.road_min_tiles()
	for c in g.structs:
		if c.o != o or c.get("bt", 0.0) > 0.0: continue
		if c.k == 2: facs.append(Vector2(c.tile % W + 0.5, c.tile / W + 0.5))
		if c.k in g.RAIL_KINDS: nodes.append(c)
	var adj := {}
	if facs.is_empty() or nodes.size() < 2: return adj
	var R2 := rmax * rmax
	var cov := []
	for nd in nodes:
		var p := Vector2(nd.tile % W + 0.5, nd.tile / W + 0.5); var l := []
		for fi in facs.size():
			if facs[fi].distance_squared_to(p) <= R2: l.append(fi)
		if nd.k == 2: l.append(-1)
		cov.append(l)
	var edges := []
	for i in nodes.size():
		if cov[i].is_empty(): continue
		var pi := Vector2(nodes[i].tile % W + 0.5, nodes[i].tile / W + 0.5)
		for j in range(i + 1, nodes.size()):
			if cov[j].is_empty(): continue
			var pj := Vector2(nodes[j].tile % W + 0.5, nodes[j].tile / W + 0.5)
			var d: float = pi.distance_to(pj)
			if d <= rmin or d > rmax: continue
			edges.append([d, i, j])
	edges.sort_custom(func(x, y): return x[0] < y[0])
	for e in edges:
		var a = nodes[e[1]]; var b = nodes[e[2]]
		if _rail_hops(a, b, SimRules.RAIL_LINK_HOPS, adj) != -1: continue
		if _rail_curve(a.tile, b.tile).is_empty(): continue
		if not adj.has(a.tile): adj[a.tile] = []
		if not adj.has(b.tile): adj[b.tile] = []
		adj[a.tile].append(b); adj[b.tile].append(a)
	return adj

func _has_rail_link(st_a, st_b) -> bool:
	if st_a == null or st_b == null or st_a == st_b: return false
	if not is_same(g.struct_at.get(st_a.tile), st_a) or not is_same(g.struct_at.get(st_b.tile), st_b): return false
	if st_b in _rail_neighbors(st_a): return true
	if st_a in _rail_neighbors(st_b): return true
	return false

func _rail_len(st_a, st_b) -> float:
	var rc := _rail_curve(st_a.tile, st_b.tile)
	if rc.is_empty(): return 20.0
	var cum: PackedFloat32Array = rc[1]
	return maxf(1.0, cum[cum.size() - 1])

# Port of SimStructures.factories_tick / _spawn_truck / _truck_tick (RoWorld): each finished factory
# rolls `level` times per tick against trainSpawnRate(owner's factory levels, train units world-wide),
# at most one train per 10 ticks and 6 in flight per factory; the train runs the station route (over
# the station network) to a random reachable city or port, paying trainGold at every city/port stop.
func _rail_route(a, b) -> Array:
	var par := {a.tile: null}
	var q := [a]
	var qi := 0
	while qi < q.size():
		var cur = q[qi]; qi += 1
		if is_same(cur, b): break
		for nb in _rail_neighbors(cur):
			if not par.has(nb.tile): par[nb.tile] = cur; q.append(nb)
	if not par.has(b.tile): return []
	var route := [b]
	var c = par[b.tile]
	while c != null:
		route.push_front(c); c = par[c.tile]
	return route

func _rail_dests(f) -> Array:
	var seen := {f.tile: true}
	var q := [f]
	var qi := 0
	var out := []
	while qi < q.size():
		var cur = q[qi]; qi += 1
		if not is_same(cur, f) and cur.k in [0, 1] and (cur.o == f.o or not g.sim_naval.hostile(cur.o, f.o)): out.append(cur)
		for nb in _rail_neighbors(cur):
			if not seen.has(nb.tile): seen[nb.tile] = true; q.append(nb)
	return out

func _train_leg_ticks(a, b) -> float:
	return maxf(1.0, _rail_len(a, b) * g.sim_rules.k_lin / SimRules.TRAIN_SPEED_FULL)

func spawn_train_from(f) -> bool:
	var W: int = g.W
	var dests := _rail_dests(f)
	if dests.is_empty(): return false
	var pick = dests[g.rng.randi() % dests.size()]
	var route := _rail_route(f, pick)
	if route.size() <= 1: return false
	var a := Vector2(route[0].tile % W + 0.5, route[0].tile / W + 0.5)
	var b := Vector2(route[1].tile % W + 0.5, route[1].tile / W + 0.5)
	g.trains.append({"o": f.o, "fac": f, "route": route, "leg": 0, "src": route[0], "dst": route[1],
		"from": a, "to": b, "t": 0.0, "dur": _train_leg_ticks(route[0], route[1]), "stops": 0, "lvl": int(f.get("level", 1))})
	f["trucks"] = int(f.get("trucks", 0)) + 1
	return true

func _train_done(tr) -> void:
	g.trains.erase(tr)
	var f = tr.get("fac")
	if f != null: f["trucks"] = maxi(0, int(f.get("trucks", 0)) - 1)

func _trains_tick() -> void:
	var W: int = g.W
	var tick: int = g.sim_atk.tick
	if tick % 10 == 0: _rail_warm()
	var units_w: int = g.trains.size() * SimRules.TRAIN_UNITS
	var fac_lv := {}
	for st in g.structs:
		if st.k == 2: fac_lv[st.o] = int(fac_lv.get(st.o, 0)) + int(st.get("level", 1))
	for f in g.structs:
		if f.k != 2 or float(f.get("bt", 0.0)) > 0.0 or not g.nations[f.o].alive: continue
		if int(f.get("trucks", 0)) >= SimRules.TRUCKS_PER_FACTORY: continue
		if tick < int(f.get("last_spawn", -1000)) + SimRules.TRAIN_COOLDOWN_TICKS: continue
		var rate := SimRules.train_spawn_rate(int(fac_lv.get(f.o, 0)), units_w)
		var go := false
		for _l in mini(int(f.get("level", 1)), 1000):
			if g.rng.randi() % rate == 0: go = true; break
		if go and spawn_train_from(f): f["last_spawn"] = tick
	for tr in g.trains.duplicate():
		if not _has_rail_link(tr.src, tr.dst) or not g.nations[tr.o].alive:
			_train_done(tr); continue
		tr.t += 1.0
		if tr.t < tr.dur: continue
		var s = tr.dst
		if not is_same(g.struct_at.get(s.tile), s) or (s.o != tr.o and g.sim_naval.hostile(s.o, tr.o)) or g.is_embargoed(tr.o, s.o):
			_train_done(tr); continue
		if s.k in [0, 1]:
			var rel := "self" if s.o == tr.o else ("ally" if g.allied(tr.o, s.o) else "other")
			var pay: float = SimRules.train_gold(rel, int(tr.stops))
			g.nations[tr.o].gold += pay
			if s.o != tr.o and g.nations[s.o].alive: g.nations[s.o].gold += pay
			if tr.o == g.PLAYER or s.o == g.PLAYER: g.add_float(Vector2(s.tile % W + 0.5, s.tile / W + 0.5) * g.TS, "+%s" % g._fmt(pay), g.GOLD_C)
			tr.stops = int(tr.stops) + 1
		var route: Array = tr.route
		tr.leg = int(tr.leg) + 1
		if tr.leg >= route.size() - 1:
			_train_done(tr); continue
		tr.src = route[tr.leg]; tr.dst = route[tr.leg + 1]
		tr.from = Vector2(tr.src.tile % W + 0.5, tr.src.tile / W + 0.5); tr.to = Vector2(tr.dst.tile % W + 0.5, tr.dst.tile / W + 0.5)
		tr.t = 0.0; tr.dur = _train_leg_ticks(tr.src, tr.dst)


# ---------------------------------------------------------------- Step 5b2: the rails in Luau
# docs/LUAU_PORT.md, Step 5b2: with the Luau extension loaded, the rail caches, station links, train spawns, legs
# and gold run in luau/sim/Core/SimRails.luau. Luau owns the caches and the trains; game.rail_cache,
# game._rail_nb_cache and game.trains hold mirrors (same keys, same order) that the renderer and the tests read.
# The structures stay GDScript's: each call sends a snapshot (list order) and gets back the trucks / last_spawn
# writes, the new cache entries and trains, the trains as they are now and the gold paid, in order. A structure
# Dictionary is named by id = tile + serial * 2^24 (the serial moves on when another Dictionary stands on the tile).
# The public entry points (curve, neighbors, has_link, spawn, tick) pick Luau or the GDScript code above, which
# stays as the fallback (remote viewers, NO_LUAU_SIM, no extension). The renderer reads the mirrors only
# (game/rails.gd _rail_curve_view, _has_rail_link_view).
const LMOD := "Core/SimRails"
const LSNAP := 8   # f64 per structure (SimRails.luau M.SNAP)
const TR_IN := 5   # f64 per kept train (M.TR_IN)
const ID_MUL := 16777216

var _no_luau := OS.has_environment("NO_LUAU_SIM")
var _ser := {}      # tile -> the last serial handed out there
var _seen := {}     # tile -> the Dictionary the last snapshot had there
var _cur_id := {}   # tile -> its id
var _ids_at := {}   # tile -> PackedFloat64Array of every id handed out there (this map)
var _by_id := {}    # id -> Dictionary (live and dropped)
var _live := {}     # ids in the last snapshot
var _tlist: Array = []  # train mirrors Luau knows, in game.trains order
var _tids := PackedInt32Array()
var _by_tid := {}
var _rc_n := 0
var _nb_n := 0
var luau_calls := 0  # tests

## the link when Luau runs the rails (not on a remote viewer, not with NO_LUAU_SIM)
func lu_on() -> LuauLink:
	if g.net_remote or _no_luau: return null
	var lu = g.get("luau_link")
	if lu == null or not lu.on: return null
	return lu

## a new map (LuauLink._begin): forget the mirrors' bookkeeping
func luau_reset() -> void:
	_ser.clear(); _seen.clear(); _cur_id.clear(); _ids_at.clear(); _by_id.clear(); _live.clear()
	_tlist = []; _tids = PackedInt32Array(); _by_tid.clear()
	_rc_n = 0; _nb_n = 0

func curve(tile_a: int, tile_b: int) -> Array:
	var lu := lu_on()
	if lu != null:
		var r = _lrun(lu, "curve", [tile_a, tile_b], [])
		if r != null:
			return g.rail_cache.get("r%d:%d" % [mini(tile_a, tile_b), maxi(tile_a, tile_b)], []) if r else []
	return _rail_curve(tile_a, tile_b)

func neighbors(st) -> Array:
	var lu := lu_on()
	if lu != null and st != null:
		var ex: Array = []
		var id := _arg_id(st, ex)
		var r = _lrun(lu, "neighbors", [id, 0], ex)
		if r != null:
			var out: Array = []
			for x in (r as PackedByteArray).to_float64_array(): out.append(_by_id[x])
			return out
	return _rail_neighbors(st)

func has_link(st_a, st_b) -> bool:
	var lu := lu_on()
	if lu != null:
		if st_a == null or st_b == null: return false
		var ex: Array = []
		var ia := _arg_id(st_a, ex)
		var ib := _arg_id(st_b, ex)
		var r = _lrun(lu, "link", [ia, ib], ex)
		if r != null: return bool(r)
	return _has_rail_link(st_a, st_b)

func spawn(f) -> bool:
	var lu := lu_on()
	if lu != null and f != null:
		var ex: Array = []
		var id := _arg_id(f, ex)
		var r = _lrun(lu, "spawn", [id, 0], ex)
		if r != null: return bool(r)
	return spawn_train_from(f)

func tick() -> void:
	var lu := lu_on()
	if lu != null and _lrun(lu, "tick", [0, 0], []) != null: return
	_trains_tick()

# the id of the Dictionary st (a new one: its fields go to Luau in `ex`)
func _arg_id(st, ex: Array) -> float:
	var tile: int = st.tile
	if is_same(_seen.get(tile), st): return _cur_id[tile]
	var ids = _ids_at.get(tile)
	if ids != null:
		for x in ids:
			if is_same(_by_id[x], st): return x
	var id := _new_id(tile, st)
	ex.append(st)
	return id

func _new_id(tile: int, st) -> float:
	var s: int = int(_ser.get(tile, 0)) + 1
	_ser[tile] = s
	var id := float(tile + s * ID_MUL)
	_by_id[id] = st
	if not _ids_at.has(tile): _ids_at[tile] = PackedFloat64Array()
	var a: PackedFloat64Array = _ids_at[tile]
	a.append(id)
	_ids_at[tile] = a
	return id

func _put(f: PackedFloat64Array, j: int, id: float, st) -> void:
	f[j] = id; f[j + 1] = st.k; f[j + 2] = st.tile; f[j + 3] = st.o
	f[j + 4] = float(st.level) if st.has("level") else NAN
	f[j + 5] = float(st.bt) if st.has("bt") else NAN
	f[j + 6] = float(st.trucks) if st.has("trucks") else NAN
	f[j + 7] = float(st.last_spawn) if st.has("last_spawn") else NAN

# game.structs -> f (list order); the Dictionaries dropped since the last call (and `ex`) -> gone
func _snapshot(f: PackedFloat64Array, gone: PackedFloat64Array, ex: Array) -> void:
	var structs: Array = g.structs
	f.resize(structs.size() * LSNAP)
	var live := {}
	var j := 0
	for st in structs:
		var tile: int = st.tile
		var id: float
		if is_same(_seen.get(tile), st):
			id = _cur_id[tile]
		else:
			id = -1.0
			var ids = _ids_at.get(tile)
			if ids != null:
				for x in ids:
					if is_same(_by_id[x], st): id = x; break
			if id < 0.0: id = _new_id(tile, st)
			_seen[tile] = st
			_cur_id[tile] = id
		live[id] = true
		_put(f, j, id, st)
		j += LSNAP
	var drop: Array = []
	for id in _live:
		if not live.has(id): drop.append(id)
	for st in ex: drop.append(_arg_id(st, []))
	gone.resize(drop.size() * LSNAP)
	j = 0
	for id in drop:
		_put(gone, j, id, _by_id[id])
		j += LSNAP
	_live = live

# the train mirrors still in game.trains (in its order) -> their ids and the fields GDScript may have written
func _recon_trains() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var keep: Array = []
	var ids := PackedInt32Array()
	var j := 0
	var n := _tlist.size()
	for tr in g.trains:
		var k := j
		while k < n and not is_same(_tlist[k], tr): k += 1
		if k < n:
			out.append(_tids[k]); out.append(tr.leg); out.append(tr.t); out.append(tr.dur); out.append(tr.stops)
			keep.append(tr); ids.append(_tids[k])
			j = k + 1
	_tlist = keep; _tids = ids
	return out

func _hostile_pairs() -> PackedInt32Array:
	var nv = g.sim_naval
	var q := PackedInt32Array()
	if nv._hp_tick == g.sim_atk.tick:
		for k in nv._hp: q.append(int(k))
		return q
	var W: int = 1 << 16
	for at in g.attacks:
		if at.get("dead", false): continue
		q.append(int(at.a) * W + int(at.t)); q.append(int(at.t) * W + int(at.a))
	return q

## One Luau call. Returns its result (ret), or null when the link failed (the caller runs the GDScript path).
func _lrun(lu: LuauLink, op: String, a: Array, ex: Array) -> Variant:
	if not lu.flush(g): return null
	var wc: Array = g.sim_atk.world_call()  # Step 5g2
	if lu.vm.call_fn(LMOD, wc[0], wc[1]) == null:
		lu._fail(g, lu.vm.last_error)
		return null
	var f := PackedFloat64Array()
	var gone := PackedFloat64Array()
	_snapshot(f, gone, ex)
	var trn := _recon_trains()
	var hdr := PackedFloat64Array([g.sim_atk.tick, g.elapsed, g.allies.size(), g.embargoes.size(), g._rail_bfs_left,
		g._rail_calc_left, g._rail_frame, 1.0 if g._rail_pending else 0.0, g.PLAYER,
		1.0 if g.rail_cache.size() < _rc_n else 0.0, 1.0 if g._rail_nb_cache.size() < _nb_n else 0.0])
	var rf := PackedFloat64Array()
	for k in SimAttacks.RULE_FIELDS: rf.append(float(g.sim_rules.get(k)))
	var osv := PackedInt32Array()
	for o in g._own_sv:
		osv.append(int(o)); osv.append(int(g._own_sv[o]))
	var rg := LuauLink.rng_args(g)
	var out = lu.vm.call_fn(LMOD, "call", [op, rg[0], rg[1], hdr.to_byte_array(), rf.to_byte_array(),
		f.to_byte_array(), gone.to_byte_array(), trn.to_byte_array(), osv.to_byte_array(),
		_hostile_pairs().to_byte_array(), a[0], a[1]])
	if out == null:
		lu._fail(g, lu.vm.last_error)
		return null
	luau_calls += 1
	_apply_out(out)
	return out.ret

func _apply_out(out: Dictionary) -> void:
	var W: int = g.W
	var hi: int = int(out.rhi)
	if hi >= 0x80000000: hi -= 0x100000000
	g.rng.state = hi * 0x100000000 + int(out.rlo)
	g._rail_bfs_left = int(out.bfs_left)
	g._rail_calc_left = int(out.calc_left)
	g._rail_pending = bool(out.pending)
	if bool(out.hq): g.sim_naval.hostile(0, 0)  # the GDScript sim asked: its per-tick cache is built now
	# rail geometry, as _rail_curve stores it
	var rc: PackedFloat64Array = (out.rc as PackedByteArray).to_float64_array()
	var q := 0
	while q < rc.size():
		var key := "r%d:%d" % [int(rc[q]), int(rc[q + 1])]
		var n := int(rc[q + 2])
		q += 3
		if n == 0:
			g.rail_cache[key] = []
			continue
		var pts := PackedVector2Array()
		for m in n:
			var t := int(rc[q + m])
			pts.append(Vector2(t % W + 0.5, t / W + 0.5))
		q += n
		var cum := PackedFloat32Array([0.0])
		for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
		g.rail_cache[key] = [pts, cum, []]
	_rc_n = g.rail_cache.size()
	# station links, as _rail_neighbors stores them
	var nb: PackedFloat64Array = (out.nb as PackedByteArray).to_float64_array()
	q = 0
	while q < nb.size():
		var tile := int(nb[q])
		var o := int(nb[q + 1])
		var n := int(nb[q + 2])
		q += 3
		var l: Array = []
		for m in n: l.append(_by_id[nb[q + m]])
		q += n
		g._rail_nb_cache[tile] = ["%d|%d|%d|%d" % [o, g._own_sv.get(o, 0), g.allies.size(), g.embargoes.size()], g.elapsed, l]
	_nb_n = g._rail_nb_cache.size()
	# trucks / last_spawn
	var sw: PackedFloat64Array = (out.sw as PackedByteArray).to_float64_array()
	for k in range(0, sw.size(), 3):
		var st: Dictionary = _by_id[sw[k]]
		if not is_nan(sw[k + 1]): st["trucks"] = int(sw[k + 1])
		if not is_nan(sw[k + 2]): st["last_spawn"] = int(sw[k + 2])
	# new trains
	var ntr: PackedFloat64Array = (out.ntr as PackedByteArray).to_float64_array()
	q = 0
	while q < ntr.size():
		var tid := int(ntr[q])
		var n := int(ntr[q + 4])
		var route: Array = []
		for m in n: route.append(_by_id[ntr[q + 5 + m]])
		var a := Vector2(route[0].tile % W + 0.5, route[0].tile / W + 0.5)
		var b := Vector2(route[1].tile % W + 0.5, route[1].tile / W + 0.5)
		_by_tid[tid] = {"o": int(ntr[q + 1]), "fac": _by_id[ntr[q + 2]], "route": route, "leg": 0, "src": route[0],
			"dst": route[1], "from": a, "to": b, "t": 0.0, "dur": 0.0, "stops": 0, "lvl": int(ntr[q + 3])}
		q += 5 + n
	# the trains now, in order
	var trs: PackedFloat64Array = (out.trs as PackedByteArray).to_float64_array()
	var trains: Array = g.trains
	trains.clear()
	_tlist = []
	_tids = PackedInt32Array()
	var alive := {}
	for k in range(0, trs.size(), TR_IN):
		var tid := int(trs[k])
		var tr: Dictionary = _by_tid[tid]
		var leg := int(trs[k + 1])
		if leg != int(tr.leg):
			var route: Array = tr.route
			tr.leg = leg
			tr.src = route[leg]; tr.dst = route[leg + 1]
			tr.from = Vector2(tr.src.tile % W + 0.5, tr.src.tile / W + 0.5); tr.to = Vector2(tr.dst.tile % W + 0.5, tr.dst.tile / W + 0.5)
		tr.t = trs[k + 2]; tr.dur = trs[k + 3]; tr.stops = int(trs[k + 4])
		trains.append(tr)
		_tlist.append(tr); _tids.append(tid)
		alive[tid] = true
	for tid in _by_tid.keys():
		if not alive.has(tid): _by_tid.erase(tid)
	# gold, in the order the trains paid it
	var pay: PackedFloat64Array = (out.pay as PackedByteArray).to_float64_array()
	for k in range(0, pay.size(), 5):
		var o := int(pay[k])
		var so := int(pay[k + 1])
		var p: float = pay[k + 3]
		g.nations[o].gold += p
		if so >= 0: g.nations[so].gold += p
		if pay[k + 4] != 0.0:
			var t := int(pay[k + 2])
			g.add_float(Vector2(t % W + 0.5, t / W + 0.5) * g.TS, "+%s" % g._fmt(p), g.GOLD_C)
