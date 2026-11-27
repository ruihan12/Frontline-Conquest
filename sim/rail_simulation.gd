extends RefCounted
## Shared train tick and rail cache logic for inline and detached play.

const RailGeometry = preload("res://sim/rail_geometry.gd")

static func _rail_curve(world, tile_a: int, tile_b: int) -> Array:
	# Upstream SimStructures.rail_path: a 4-neighbour land path (A* on a uniform grid here).
	# No custom Manhattan L-shape / MST geometry.
	var lo_t := mini(tile_a, tile_b)
	var hi_t := maxi(tile_a, tile_b)
	var key := RailGeometry.cache_key(lo_t, hi_t)
	if world.rail_cache.has(key):
		return world.rail_cache[key]
	if world._rail_bfs_left <= 0:
		world._rail_pending = true
		return []
	world._rail_bfs_left -= 1
	var res: Array
	if world._prepared_rail_scale == world.sim_rules.k_lin and world._prepared_rail_curves.has(key):
		res = world._prepared_rail_curves[key]
		world._prepared_rail_curves.erase(key)
		world._rail_worker_curves_used += 1
	else:
		res = RailGeometry.curve(lo_t, hi_t, world.W, world.H, world.owner_map, world.sim_rules.k_lin, world.sim_rules.rail_max_path())
	world.rail_cache[key] = res
	return res

static func _rail_neighbors(world, st) -> Array:
	if not (st.k in world.RAIL_KINDS) or st.get("bt", 0.0) > 0.0: return []
	# per-owner cache: one nation building something no longer invalidates everyone's rail web
	var ver := "%d|%d|%d|%d" % [st.o, world._own_sv.get(st.o, 0), world.allies.size(), world.embargoes.size()]
	var ce = world._rail_nb_cache.get(st.tile)
	if ce != null and ce[0] == ver and world.elapsed - float(ce[1]) < 6.0: return ce[2]
	if world._rail_calc_left <= 0 and ce != null: return ce[2]  # over this frame's budget: reuse the stale list
	world._rail_calc_left -= 1
	world._rail_pending = false
	var r := _rail_neighbors_calc(world, st)
	if not world._rail_pending: world._rail_nb_cache[st.tile] = [ver, world.elapsed, r]
	return r


static func _rail_mst_version(world, owner: int) -> String:
	return "%d|%d|%d" % [owner, world._own_sv.get(owner, 0), int(world.elapsed / 6.0)]

static func _rail_neighbors_calc(world, st) -> Array:
	var ver := _rail_mst_version(world, st.o)
	# an unfinished web (route searches ran out of this frame's budget) is kept for the rest of the frame only,
	# so the next frame carries on, instead of every station rebuilding the whole web again and again
	var pver := ver + "|f%d" % world._rail_frame
	var ce = world._rail_mst.get(st.o)
	if ce == null or (ce[0] != ver and ce[0] != pver):
		var adj := _build_rail_mst(world, st.o)
		if adj.is_empty() and world._rail_pending and ce != null:
			adj = ce[1]
		ce = [pver if world._rail_pending else ver, adj]
		world._rail_mst[st.o] = ce
	return ce[1].get(st.tile, [])


static func _rail_hops(from, to, max_d: int, adj: Dictionary) -> int:
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
static func _build_rail_mst(world, o: int) -> Dictionary:
	var nodes := []; var facs := []
	var rmax: float = world.sim_rules.road_max_tiles()
	var rmin: float = world.sim_rules.road_min_tiles()
	for c in world.structs:
		if c.o != o or c.get("bt", 0.0) > 0.0: continue
		if c.k == 2: facs.append(Vector2(c.tile % world.W + 0.5, c.tile / world.W + 0.5))
		if c.k in world.RAIL_KINDS: nodes.append(c)
	var adj := {}
	if facs.is_empty() or nodes.size() < 2: return adj
	var edges: Array
	var prepared: Array = world._prepared_rail_edges.get(o, [])
	if world._prepared_rail_scale == world.sim_rules.k_lin and not prepared.is_empty() \
			and prepared[0] == RailGeometry.station_signature(nodes):
		edges = prepared[1]
		world._rail_worker_edge_lists_used += 1
	else:
		edges = RailGeometry.station_edges(nodes, facs, world.W, rmin, rmax)
	for e in edges:
		var a = nodes[e[1]]; var b = nodes[e[2]]
		if _rail_hops(a, b, SimRules.RAIL_LINK_HOPS, adj) != -1: continue
		if _rail_curve(world, a.tile, b.tile).is_empty(): continue
		if not adj.has(a.tile): adj[a.tile] = []
		if not adj.has(b.tile): adj[b.tile] = []
		adj[a.tile].append(b); adj[b.tile].append(a)
	return adj

static func _has_rail_link(world, st_a, st_b) -> bool:
	if st_a == null or st_b == null or st_a == st_b: return false
	if not is_same(world.struct_at.get(st_a.tile), st_a) or not is_same(world.struct_at.get(st_b.tile), st_b): return false
	if st_b in _rail_neighbors(world, st_a): return true
	if st_a in _rail_neighbors(world, st_b): return true
	return false


static func _rail_len(world, st_a, st_b) -> float:
	var rc := _rail_curve(world, st_a.tile, st_b.tile)
	if rc.is_empty(): return 20.0
	var cum: PackedFloat32Array = rc[1]
	return maxf(1.0, cum[cum.size() - 1])

# Port of SimStructures.factories_tick / _spawn_truck / _truck_tick (RoWorld): each finished factory
# rolls `level` times per tick against trainSpawnRate(owner's factory levels, train units world-wide),
# at most one train per 10 ticks and 6 in flight per factory; the train runs the station route (over
# the station network) to a random reachable city or port, paying trainGold at every city/port stop.
static func _rail_route(world, a, b) -> Array:
	var par := {a.tile: null}
	var q := [a]
	var qi := 0
	while qi < q.size():
		var cur = q[qi]; qi += 1
		if is_same(cur, b): break
		for nb in _rail_neighbors(world, cur):
			if not par.has(nb.tile): par[nb.tile] = cur; q.append(nb)
	if not par.has(b.tile): return []
	var route := [b]
	var c = par[b.tile]
	while c != null:
		route.push_front(c); c = par[c.tile]
	return route

static func _rail_dests(world, f) -> Array:
	var seen := {f.tile: true}
	var q := [f]
	var qi := 0
	var out := []
	while qi < q.size():
		var cur = q[qi]; qi += 1
		if not is_same(cur, f) and cur.k in [0, 1] and (cur.o == f.o or not world.sim_naval.hostile(cur.o, f.o)): out.append(cur)
		for nb in _rail_neighbors(world, cur):
			if not seen.has(nb.tile): seen[nb.tile] = true; q.append(nb)
	return out

static func _train_leg_ticks(world, a, b) -> float:
	return maxf(1.0, _rail_len(world, a, b) * world.sim_rules.k_lin / SimRules.TRAIN_SPEED_FULL)

static func spawn_train_from(world, f) -> bool:
	var dests := _rail_dests(world, f)
	if dests.is_empty(): return false
	var pick = dests[world.rng.randi() % dests.size()]
	var route := _rail_route(world, f, pick)
	if route.size() <= 1: return false
	var a := Vector2(route[0].tile % world.W + 0.5, route[0].tile / world.W + 0.5)
	var b := Vector2(route[1].tile % world.W + 0.5, route[1].tile / world.W + 0.5)
	world.trains.append({"o": f.o, "fac": f, "route": route, "leg": 0, "src": route[0], "dst": route[1],
		"from": a, "to": b, "t": 0.0, "dur": _train_leg_ticks(world, route[0], route[1]), "stops": 0, "lvl": int(f.get("level", 1))})
	f["trucks"] = int(f.get("trucks", 0)) + 1
	return true

static func _train_done(world, tr) -> void:
	world.trains.erase(tr)
	var f = tr.get("fac")
	if f != null: f["trucks"] = maxi(0, int(f.get("trucks", 0)) - 1)

static func _trains_tick(world) -> void:
	var tick: int = world.sim_atk.tick
	var units_w: int = world.trains.size() * SimRules.TRAIN_UNITS
	var fac_lv := {}
	for st in world.structs:
		if st.k == 2: fac_lv[st.o] = int(fac_lv.get(st.o, 0)) + int(st.get("level", 1))
	for f in world.structs:
		if f.k != 2 or float(f.get("bt", 0.0)) > 0.0 or not world.nations[f.o].alive: continue
		if int(f.get("trucks", 0)) >= SimRules.TRUCKS_PER_FACTORY: continue
		if tick < int(f.get("last_spawn", -1000)) + SimRules.TRAIN_COOLDOWN_TICKS: continue
		var rate := SimRules.train_spawn_rate(int(fac_lv.get(f.o, 0)), units_w)
		var go := false
		for _l in mini(int(f.get("level", 1)), 1000):
			if world.rng.randi() % rate == 0: go = true; break
		if go and spawn_train_from(world, f): f["last_spawn"] = tick
	var steps: Array = world._prepared_train_steps if world._prepared_train_tick == tick else []
	world._prepared_train_steps = []
	world._prepared_train_tick = -1
	var active: Array = world.trains.duplicate()
	for i in active.size():
		var tr: Dictionary = active[i]
		if not _has_rail_link(world, tr.src, tr.dst) or not world.nations[tr.o].alive:
			_train_done(world, tr); continue
		var step: RailGeometry.TrainStep
		if i < steps.size() and steps[i].matches(tr):
			step = steps[i]
			world._rail_worker_train_steps_used += 1
			tr.t = step.next_time
			if not step.arrives: continue
		else:
			tr.t += 1.0
			if tr.t < tr.dur: continue
		var s = tr.dst
		if not is_same(world.struct_at.get(s.tile), s) or (s.o != tr.o and world.sim_naval.hostile(s.o, tr.o)) or world.is_embargoed(tr.o, s.o):
			_train_done(world, tr); continue
		if s.k in [0, 1]:
			var rel := "self" if s.o == tr.o else ("ally" if world.allied(tr.o, s.o) else "other")
			var pay: float = step.payout(rel) if step != null else SimRules.train_gold(rel, int(tr.stops))
			world.nations[tr.o].gold += pay
			if s.o != tr.o and world.nations[s.o].alive: world.nations[s.o].gold += pay
			if tr.o == world.PLAYER or s.o == world.PLAYER: world._emit_train_payout(Vector2(s.tile % world.W + 0.5, s.tile / world.W + 0.5) * world.TS, pay)
			tr.stops = int(tr.stops) + 1
		var route: Array = tr.route
		tr.leg = step.next_leg if step != null else int(tr.leg) + 1
		if tr.leg >= route.size() - 1:
			_train_done(world, tr); continue
		tr.src = route[tr.leg]; tr.dst = route[tr.leg + 1]
		tr.from = Vector2(tr.src.tile % world.W + 0.5, tr.src.tile / world.W + 0.5); tr.to = Vector2(tr.dst.tile % world.W + 0.5, tr.dst.tile / world.W + 0.5)
		tr.t = 0.0; tr.dur = _train_leg_ticks(world, tr.src, tr.dst)
