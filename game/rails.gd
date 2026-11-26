extends "res://game/navy.gd"
# Rail networks and gold trains

const RailGeometry = preload("res://sim/rail_geometry.gd")
const MAX_PREPARED_RAIL_CURVES := 80

func _publish_rail_geometry(curves: Dictionary, station_edges: Dictionary, scale: float) -> void:
	_prepared_rail_edges = station_edges
	if scale <= 0.0:
		return
	if _prepared_rail_scale != scale:
		_prepared_rail_curves.clear()
		_prepared_rail_scale = scale
	for key in curves:
		if rail_cache.has(key):
			continue
		if _prepared_rail_curves.size() >= MAX_PREPARED_RAIL_CURVES:
			_prepared_rail_curves.erase(_prepared_rail_curves.keys()[0])
		_prepared_rail_curves[key] = curves[key]

# ---------- rail networks & moving gold trains (OpenFront v24+) ----------
func _is_land_tile(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < W and y < H and owner_map[y * W + x] >= 0

func _land_los(a: Vector2, b: Vector2) -> bool:
	var n := maxi(2, int(a.distance_to(b) * 2.0))
	for k in range(n + 1):
		var p := a.lerp(b, float(k) / float(n))
		if not _is_land_tile(int(p.x), int(p.y)): return false
	return true

func _bezier_on_land(p0: Vector2, pc: Vector2, p1: Vector2, steps := 24) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for m in range(steps + 1):
		var u: float = float(m) / float(steps)
		var om := 1.0 - u
		var p: Vector2 = om * om * p0 + 2.0 * om * u * pc + u * u * p1
		if not _is_land_tile(int(p.x), int(p.y)):
			return PackedVector2Array()
		pts.append(p)
	for m in range(1, pts.size()):
		if not _land_los(pts[m - 1], pts[m]):
			return PackedVector2Array()
	return pts

func _smooth_land_chain(raw: PackedVector2Array) -> PackedVector2Array:
	if raw.size() <= 2: return raw
	var pulled := PackedVector2Array([raw[0]])
	var idx := 0
	while idx < raw.size() - 1:
		var j := mini(raw.size() - 1, idx + 10)
		while j > idx + 1 and not _land_los(raw[idx], raw[j]): j -= 1
		pulled.append(raw[j]); idx = j
	var pts := pulled
	for _it in 3:
		if pts.size() < 3: break
		var np := PackedVector2Array([pts[0]])
		for m in pts.size() - 1:
			var p0: Vector2 = pts[m]; var p1: Vector2 = pts[m + 1]
			var q0 := p0.lerp(p1, 0.25); var q1 := p0.lerp(p1, 0.75)
			if _land_los(p0, q0) and _land_los(q0, q1) and _land_los(q1, p1):
				np.append(q0); np.append(q1)
			else:
				np.append(p0); np.append(p1)
		np.append(pts[pts.size() - 1])
		pts = np
	return pts

func _land_bfs_points(from_t: int, to_t: int, max_visit := 26000) -> PackedVector2Array:
	if from_t == to_t:
		return PackedVector2Array([Vector2(from_t % W + 0.5, from_t / W + 0.5)])
	if bfs_par.size() != W * H:
		bfs_par.resize(W * H); bfs_stamp.resize(W * H); bfs_stamp.fill(0)
	bfs_gen += 1
	var gen := bfs_gen
	var q := PackedInt32Array([to_t])
	bfs_par[to_t] = -1; bfs_stamp[to_t] = gen
	var qi := 0
	var found := -1
	var dirs8 := [1, -1, W, -W, W + 1, W - 1, -W + 1, -W - 1]
	while qi < q.size() and qi < max_visit:
		var i: int = q[qi]; qi += 1
		if i == from_t: found = i; break
		var ix := i % W
		for d in dirs8:
			var j: int = i + d
			if j < 0 or j >= W * H or absi((j % W) - ix) > 1: continue
			if owner_map[j] >= 0 and bfs_stamp[j] != gen:
				if absi(d) != 1 and absi(d) != W:
					if owner_map[i + (j % W - ix)] < 0 or owner_map[j - (j % W - ix)] < 0: continue
				bfs_par[j] = i; bfs_stamp[j] = gen; q.append(j)
	if found < 0:
		return PackedVector2Array()
	var raw := PackedVector2Array()
	var k := found
	while k != -1:
		raw.append(Vector2(k % W + 0.5, k / W + 0.5)); k = bfs_par[k]
	return raw

func _water_crossing_spans(a: Vector2, b: Vector2) -> Array:
	# Returns [[w_start, w_end], ...] along straight line a -> b where tiles are WATER
	var spans := []
	var dist := a.distance_to(b)
	if dist < 0.5: return spans
	var steps := maxi(8, int(dist * 3.0))
	var in_water := false
	var w0 := Vector2.ZERO
	for k in range(steps + 1):
		var u: float = float(k) / float(steps)
		var p := a.lerp(b, u)
		var is_w := not _is_land_tile(int(p.x), int(p.y))
		if is_w and not in_water:
			in_water = true
			w0 = a.lerp(b, maxf(0.0, float(k - 1) / float(steps)))
		elif not is_w and in_water:
			in_water = false
			spans.append([w0, p])
	if in_water:
		spans.append([w0, b])
	return spans

func _axis_land(a: Vector2i, b: Vector2i) -> bool:
	# a->b must be horizontal or vertical; every tile on it must be land
	var d := Vector2i(signi(b.x - a.x), signi(b.y - a.y))
	var p := a
	while true:
		if not _is_land_tile(p.x, p.y): return false
		if p == b: return true
		p += d
	return true

func _land_bfs4(from_t: int, to_t: int, max_visit := 30000) -> PackedInt32Array:
	if bfs_par.size() != W * H:
		bfs_par.resize(W * H); bfs_stamp.resize(W * H); bfs_stamp.fill(0)
	bfs_gen += 1
	var gen := bfs_gen
	var q := PackedInt32Array([to_t]); bfs_par[to_t] = -1; bfs_stamp[to_t] = gen
	var qi := 0; var found := -1
	while qi < q.size() and qi < max_visit:
		var i: int = q[qi]; qi += 1
		if i == from_t: found = i; break
		var ix := i % W
		for d in [1, -1, W, -W]:
			if (d == 1 and ix == W - 1) or (d == -1 and ix == 0): continue
			var j: int = i + d
			if j < 0 or j >= W * H or owner_map[j] < 0 or bfs_stamp[j] == gen: continue
			bfs_par[j] = i; bfs_stamp[j] = gen; q.append(j)
	var out := PackedInt32Array()
	if found < 0: return out
	var k := found
	while k != -1: out.append(k); k = bfs_par[k]
	return out

func _rail_curve(tile_a: int, tile_b: int) -> Array:
	# Upstream SimStructures.rail_path: a 4-neighbour land path (A* on a uniform grid here).
	# No custom Manhattan L-shape / MST geometry.
	var lo_t := mini(tile_a, tile_b)
	var hi_t := maxi(tile_a, tile_b)
	var key := RailGeometry.cache_key(lo_t, hi_t)
	if rail_cache.has(key):
		return rail_cache[key]
	if _rail_bfs_left <= 0:
		_rail_pending = true
		return []
	_rail_bfs_left -= 1
	var res: Array
	if _prepared_rail_scale == sim_rules.k_lin and _prepared_rail_curves.has(key):
		res = _prepared_rail_curves[key]
		_prepared_rail_curves.erase(key)
		_rail_worker_curves_used += 1
	else:
		res = RailGeometry.curve(lo_t, hi_t, W, H, owner_map, sim_rules.k_lin, sim_rules.rail_max_path())
	rail_cache[key] = res
	return res

func _rail_neighbors(st) -> Array:
	if not (st.k in RAIL_KINDS) or st.get("bt", 0.0) > 0.0: return []
	# per-owner cache: one nation building something no longer invalidates everyone's rail web
	var ver := "%d|%d|%d|%d" % [st.o, _own_sv.get(st.o, 0), allies.size(), embargoes.size()]
	var ce = _rail_nb_cache.get(st.tile)
	if ce != null and ce[0] == ver and elapsed - float(ce[1]) < 6.0: return ce[2]
	if _rail_calc_left <= 0 and ce != null: return ce[2]  # over this frame's budget: reuse the stale list
	_rail_calc_left -= 1
	_rail_pending = false
	var r := _rail_neighbors_calc(st)
	if not _rail_pending: _rail_nb_cache[st.tile] = [ver, elapsed, r]
	return r

func _factories_covering(o: int, p: Vector2) -> Array:
	var out := []
	for f in structs:
		if f.k == 2 and f.o == o and f.get("bt", 0.0) <= 0.0:
			if Vector2(f.tile % W + 0.5, f.tile / W + 0.5).distance_to(p) <= FACTORY_RANGE: out.append(f)
	return out

func _rail_mst_version(owner: int) -> String:
	return "%d|%d|%d" % [owner, _own_sv.get(owner, 0), int(elapsed / 6.0)]

func _rail_neighbors_calc(st) -> Array:
	var ver := _rail_mst_version(st.o)
	# an unfinished web (route searches ran out of this frame's budget) is kept for the rest of the frame only,
	# so the next frame carries on, instead of every station rebuilding the whole web again and again
	var pver := ver + "|f%d" % _rail_frame
	var ce = _rail_mst.get(st.o)
	if ce == null or (ce[0] != ver and ce[0] != pver):
		var adj := _build_rail_mst(st.o)
		if adj.is_empty() and _rail_pending and ce != null:
			adj = ce[1]
		ce = [pver if _rail_pending else ver, adj]
		_rail_mst[st.o] = ce
	return ce[1].get(st.tile, [])

func _uf_find(par: Array, x: int) -> int:
	while par[x] != x:
		par[x] = par[par[x]]; x = par[x]
	return x

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
	var nodes := []; var facs := []
	var rmax: float = sim_rules.road_max_tiles()
	var rmin: float = sim_rules.road_min_tiles()
	for c in structs:
		if c.o != o or c.get("bt", 0.0) > 0.0: continue
		if c.k == 2: facs.append(Vector2(c.tile % W + 0.5, c.tile / W + 0.5))
		if c.k in RAIL_KINDS: nodes.append(c)
	var adj := {}
	if facs.is_empty() or nodes.size() < 2: return adj
	var edges: Array
	var prepared: Array = _prepared_rail_edges.get(o, [])
	if _prepared_rail_scale == sim_rules.k_lin and not prepared.is_empty() \
			and prepared[0] == RailGeometry.station_signature(nodes):
		edges = prepared[1]
		_rail_worker_edge_lists_used += 1
	else:
		edges = RailGeometry.station_edges(nodes, facs, W, rmin, rmax)
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
	if not is_same(struct_at.get(st_a.tile), st_a) or not is_same(struct_at.get(st_b.tile), st_b): return false
	if st_b in _rail_neighbors(st_a): return true
	if st_a in _rail_neighbors(st_b): return true
	return false

func _connected_rail_stations(st) -> Array:
	return _rail_neighbors(st)

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
		if not is_same(cur, f) and cur.k in [0, 1] and (cur.o == f.o or not sim_naval.hostile(cur.o, f.o)): out.append(cur)
		for nb in _rail_neighbors(cur):
			if not seen.has(nb.tile): seen[nb.tile] = true; q.append(nb)
	return out

func _train_leg_ticks(a, b) -> float:
	return maxf(1.0, _rail_len(a, b) * sim_rules.k_lin / SimRules.TRAIN_SPEED_FULL)

func spawn_train_from(f) -> bool:
	var dests := _rail_dests(f)
	if dests.is_empty(): return false
	var pick = dests[rng.randi() % dests.size()]
	var route := _rail_route(f, pick)
	if route.size() <= 1: return false
	var a := Vector2(route[0].tile % W + 0.5, route[0].tile / W + 0.5)
	var b := Vector2(route[1].tile % W + 0.5, route[1].tile / W + 0.5)
	trains.append({"o": f.o, "fac": f, "route": route, "leg": 0, "src": route[0], "dst": route[1],
		"from": a, "to": b, "t": 0.0, "dur": _train_leg_ticks(route[0], route[1]), "stops": 0, "lvl": int(f.get("level", 1))})
	f["trucks"] = int(f.get("trucks", 0)) + 1
	return true

func _train_done(tr) -> void:
	trains.erase(tr)
	var f = tr.get("fac")
	if f != null: f["trucks"] = maxi(0, int(f.get("trucks", 0)) - 1)

func _trains_tick() -> void:
	var tick := sim_atk.tick
	var units_w := trains.size() * SimRules.TRAIN_UNITS
	var fac_lv := {}
	for st in structs:
		if st.k == 2: fac_lv[st.o] = int(fac_lv.get(st.o, 0)) + int(st.get("level", 1))
	for f in structs:
		if f.k != 2 or float(f.get("bt", 0.0)) > 0.0 or not nations[f.o].alive: continue
		if int(f.get("trucks", 0)) >= SimRules.TRUCKS_PER_FACTORY: continue
		if tick < int(f.get("last_spawn", -1000)) + SimRules.TRAIN_COOLDOWN_TICKS: continue
		var rate := SimRules.train_spawn_rate(int(fac_lv.get(f.o, 0)), units_w)
		var go := false
		for _l in mini(int(f.get("level", 1)), 1000):
			if rng.randi() % rate == 0: go = true; break
		if go and spawn_train_from(f): f["last_spawn"] = tick
	for tr in trains.duplicate():
		if not _has_rail_link(tr.src, tr.dst) or not nations[tr.o].alive:
			_train_done(tr); continue
		tr.t += 1.0
		if tr.t < tr.dur: continue
		var s = tr.dst
		if not is_same(struct_at.get(s.tile), s) or (s.o != tr.o and sim_naval.hostile(s.o, tr.o)) or is_embargoed(tr.o, s.o):
			_train_done(tr); continue
		if s.k in [0, 1]:
			var rel := "self" if s.o == tr.o else ("ally" if allied(tr.o, s.o) else "other")
			var pay: float = SimRules.train_gold(rel, int(tr.stops))
			nations[tr.o].gold += pay
			if s.o != tr.o and nations[s.o].alive: nations[s.o].gold += pay
			if tr.o == PLAYER or s.o == PLAYER: add_float(Vector2(s.tile % W + 0.5, s.tile / W + 0.5) * TS, "+%s" % _fmt(pay), GOLD_C)
			tr.stops = int(tr.stops) + 1
		var route: Array = tr.route
		tr.leg = int(tr.leg) + 1
		if tr.leg >= route.size() - 1:
			_train_done(tr); continue
		tr.src = route[tr.leg]; tr.dst = route[tr.leg + 1]
		tr.from = Vector2(tr.src.tile % W + 0.5, tr.src.tile / W + 0.5); tr.to = Vector2(tr.dst.tile % W + 0.5, tr.dst.tile / W + 0.5)
		tr.t = 0.0; tr.dur = _train_leg_ticks(tr.src, tr.dst)

# construction, reloads and batteries run per sim tick in SimArsenal.tick (sim/arsenal.gd)
func _tick_artillery(_dt: float) -> void:
	pass

## `dt` is game time (sim_speed scaled: fallout wear, nuke blasts); `adt` is the animation clock, real time
## times the speed setting, so shell bursts, SAM blasts and floating text play at the pace of the 10 ticks/s sim.
func _tick_fx(dt: float, adt := -1.0) -> void:
	if adt < 0.0: adt = dt
	for b in ([] if fx_freeze else blasts.duplicate()):
		b.t += dt if b.get("kind", "") == "nuke" else adt
		var bdur: float = float(b.get("dur", 1.35))
		if b.t >= bdur: blasts.erase(b)
	for s2 in shells.duplicate():
		s2.t += adt
		if s2.t > 0.5: shells.erase(s2)
	for fl in floats.duplicate():
		fl.t += adt
		if fl.t > 1.4: floats.erase(fl)
	fallout_tick_t += dt
	if fallout_tick_t >= 2.0:
		var step := fallout_tick_t
		fallout_tick_t = 0.0
		# only the tiles that actually carry fallout (was a 2.87M-tile scan every 2 s -> hitch)
		var q2 := _qual() >= 2
		# (fallout_list loses a tile when it is conquered again: map.gd _set_owner)
		# fallout_t: counted down from 60 at the bomb for the glow's heat only (FalloutGlow). Upstream
		# fallout stays until the land is conquered again (SimState: no decay), so nothing is cleared here.
		for i in fallout_hot.keys():
			if i >= fallout.size() or fallout[i] != 1 or fallout_t[i] <= 0.0: fallout_hot.erase(i); continue
			fallout_t[i] = maxf(0.0, fallout_t[i] - step)
			if fallout_t[i] > 30.0 and q2: _pend_paint[i] = true; dirty = true

func _tick_notes(rdt: float) -> void:
	var ch := false
	for nt in notes.duplicate():
		nt.t += rdt
		if nt.t > 7.0: notes.erase(nt); ch = true
	if ch or not notes.is_empty(): note_box.queue_redraw()

# ---------- protagonist AI ----------
