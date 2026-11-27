# Port of RoWorld src/shared/Core/SimNukes.luau + SimArsenal.luau (AGPL-3.0, lukechatton/roworld).
# Runs on the sim clock (10 ticks/s): bomb flight (game/nukes.gd: launch tick + flight ticks), SAM / silo /
# airfield / railgun reloads, battery gaps, SAM missile flight, construction, reinforcements.
# Blast radii, SAM range / reload and the MIRV are upstream's.
extends RefCounted
class_name SimArsenal

var g
var R: SimRules
const DT_TICK := 0.02   # missile.t / missile.dur units per sim tick (the old missile-clock view)
var munitions := []     # shells / air strikes / slugs in flight: {nk,o,from:Vector2,to:Vector2,tile,t0,t1}
var sam_shots := []     # SAM missiles in flight (visual): {from:Vector2, to:Vector2, t0, t1, o}
var stats := {"sam_fired": 0, "sam_hits": 0, "shells": 0, "strikes": 0, "struct_dmg": 0, "struct_down": 0, "killed": 0}

func _init(main, rules: SimRules) -> void:
	g = main
	threaded_blasts = "--sim-worker-blasts" in OS.get_cmdline_user_args()
	R = rules

const BlastGeometry = preload("res://sim/blast_geometry.gd")
const MAX_BLAST_GEOMETRIES := 24
var threaded_blasts := false
var _blast_geometries := {}

func prepare_blast(radius: float) -> void:
	if not threaded_blasts or radius <= 0.0 or not is_finite(radius) or radius > 4096.0:
		return
	if _blast_geometries.has(radius) or _blast_geometries.size() >= MAX_BLAST_GEOMETRIES:
		return
	var geometry := BlastGeometry.new()
	var task := WorkerThreadPool.add_task(geometry.prepare.bind(radius))
	if task >= 0:
		_blast_geometries[radius] = {"task": task, "geometry": geometry}

func _join_blast_tasks() -> void:
	for entry: Dictionary in _blast_geometries.values():
		if entry.task >= 0:
			WorkerThreadPool.wait_for_task_completion(entry.task)
	_blast_geometries.clear()

func _blast_tiles(center: int, radius: float) -> PackedInt32Array:
	var entry: Dictionary = _blast_geometries.get(radius, {})
	if entry.is_empty():
		return disk_tiles(center, radius)
	if entry.task >= 0:
		if not WorkerThreadPool.is_task_completed(entry.task):
			return disk_tiles(center, radius)
		WorkerThreadPool.wait_for_task_completion(entry.task)
		entry.task = -1
	return entry.geometry.land_tiles(center, g.W, g.H, g.owner_map)

func reset() -> void:
	_join_blast_tasks()
	_battery_targets.clear()
	_battery_allies = {}
	_prepared_sam.clear()
	accept_strike_scans(-1, -1, -1, {})
	munitions.clear(); sam_shots.clear()
	for k in stats: stats[k] = 0

func now() -> int:
	return g.sim_atk.tick if g.sim_atk else 0

static func tpos(t: int, W: int) -> Vector2:
	return Vector2(t % W + 0.5, t / W + 0.5)

func _alive_struct(st) -> bool:
	return st != null and is_same(g.struct_at.get(st.tile), st)

func _strike_enemy(a: int, b: int) -> bool:
	return b > 0 and b != a and not g.allied(a, b)

# ---------------------------------------------------------------- missile slots (shots queues)
func s_kind(st) -> int:
	return int(SimRules.S_OF.get(st.k, -1))

func reload_ticks(st) -> int:
	var sk := s_kind(st)
	if sk < 0: return 0
	var base: int = SimRules.RELOAD_TICKS[sk]
	return maxi(1, ceili(base * SimRules.SAM_RELOAD_MULT)) if st.k == 4 else base

# SimArsenal.shot_stamp: Rapid Reload records the shot as fired earlier
func shot_stamp(st) -> int:
	var t := now()
	if st.o == g.PLAYER and g.reload_mult() < 1.0:
		var base := reload_ticks(st)
		return t - (base - maxi(1, ceili(base * SimRules.RAPID_RELOAD_MULT)))
	return t

# SimNukes.ready_missiles: `level` missiles minus those still reloading
func ready_missiles(st) -> int:
	if float(st.get("bt", 0.0)) > 0.0: return 0
	var cd := reload_ticks(st)
	var shots: Array = st.get("shots", [])
	var t := now()
	while not shots.is_empty() and int(shots[0]) + cd <= t: shots.pop_front()
	st["shots"] = shots
	var lvl := int(st.get("level", 1)) if st.k in [4, 5] else 1
	return lvl - shots.size()

func fire_shot(st) -> void:
	var shots: Array = st.get("shots", [])
	shots.append(shot_stamp(st))
	st["shots"] = shots

# reload ring / HUD fields (seconds until the next missile is loaded)
func _refresh_cd(st) -> void:
	var cd := reload_ticks(st)
	if cd <= 0: return
	var rdy := ready_missiles(st)
	var shots: Array = st.shots
	if rdy > 0 or shots.is_empty():
		st.cd = 0.0
	else:
		st.cd = maxf(0.0, float(int(shots[0]) + cd - now()) / 10.0)
	st.cmax = cd / 10.0

# ---------------------------------------------------------------- structure health (SimArsenal.damage_struct)
func struct_hp_full(st) -> int:
	var sk := s_kind(st)
	return SimRules.STRUCT_HP[sk] if sk >= 0 else 1000

func damage_struct(st, dmg: int, by: int) -> void:
	if not _alive_struct(st) or dmg <= 0: return
	var full := struct_hp_full(st)
	st.hp = int(st.get("hp", full)) - dmg
	stats.struct_dmg += 1
	if st.hp > 0: return
	var title: String = g.build_data[st.k][1]
	if int(st.get("level", 1)) <= 1:
		g._struct_remove(st)
		stats.struct_down += 1
		if st.o == g.PLAYER: g.notify("%s destroyed your %s" % [g._nname(by), title], "bad")
		return
	st.level = int(st.level) - 1
	st.hp = full
	g._sv += 1
	if st.k in [4, 5]:
		var shots: Array = st.get("shots", [])
		while shots.size() > int(st.level): shots.pop_back()
	if st.o == g.PLAYER: g.notify("%s knocked your %s down to level %d" % [g._nname(by), title, st.level], "bad")

# ---------------------------------------------------------------- per-tick driver
func tick() -> void:
	var t := now()
	for st in g.structs:
		if float(st.get("bt", 0.0)) > 0.0:
			st.bt = maxf(0.0, float(st.bt) - 0.1)
			if st.bt <= 0.0: _activate(st)
			continue
		if st.k in [4, 5, 14, 15]: _refresh_cd(st)
	_battery_tick(t)
	_munitions_tick(t)
	_sam_tick(t)
	for s in sam_shots.duplicate():
		if t > int(s.t1) + 2: sam_shots.erase(s)

func _activate(st) -> void:
	if st.k == 10: st["next_fire"] = now() + _battery_gap(st)

# ---------------------------------------------------------------- artillery (SimArsenal battery)
func _battery_gap(st) -> int:
	var gap: int = g.rng.randi_range(SimRules.ARTILLERY_GAP_MIN, SimRules.ARTILLERY_GAP_MAX)
	if st.o == g.PLAYER and g.reload_mult() < 1.0: gap = maxi(1, ceili(gap * SimRules.RAPID_RELOAD_MULT))
	return gap

static func battery_structure_target(world, st: Dictionary, radius_squared: float) -> int:
	var width: int = world.W
	var best := -1
	var bd := 0.0
	for target: Dictionary in world.structs:
		if target.o <= 0 or target.o == st.o or world.allied(st.o, target.o):
			continue
		var d := _d2(st.tile, target.tile, width)
		if d <= radius_squared and (best < 0 or d < bd or (d == bd and target.tile < best)):
			best = target.tile; bd = d
	return best

var _battery_tick_prepared := -1
var _battery_structure_revision := -1
var _battery_allies := {}
var _battery_radius: float
var _battery_targets := {}
var worker_battery_count := 0

func accept_battery_targets(tick: int, revision: int, alliances: Dictionary, radius: float, targets: Dictionary) -> void:
	_battery_tick_prepared = tick
	_battery_structure_revision = revision
	_battery_allies = alliances
	_battery_radius = radius
	_battery_targets = targets

func battery_target(st) -> int:
	var W: int = g.W
	var rng_ := R.artillery_range()
	var best: int
	if _battery_targets.has(st.tile) and _battery_tick_prepared == now() \
			and _battery_structure_revision == g._sv and _battery_radius == rng_ \
			and _battery_allies == g.allies and not g.team_mode:
		best = _battery_targets[st.tile]
		worker_battery_count += 1
	else:
		best = battery_structure_target(g, st, rng_ * rng_)
	if best >= 0: return best
	var cx: int = st.tile % W; var cy: int = st.tile / W
	for _k in SimRules.ARTILLERY_SAMPLES:
		var ang: float = g.rng.randf() * TAU
		var rad: float = rng_ * sqrt(g.rng.randf())
		var x := int(floor(cx + cos(ang) * rad + 0.5)); var y := int(floor(cy + sin(ang) * rad + 0.5))
		if x < 0 or y < 0 or x >= W or y >= g.H: continue
		var tt := y * W + x
		if g.owner_map[tt] >= 0 and _strike_enemy(st.o, g.owner_map[tt]): return tt
	return -1

func _battery_tick(t: int) -> void:
	for st in g.structs:
		if st.k != 10 or float(st.get("bt", 0.0)) > 0.0: continue
		if not st.has("next_fire"): st["next_fire"] = t + _battery_gap(st)
		if t < int(st.next_fire): continue
		var tt := battery_target(st)
		if tt < 0:
			st.next_fire = t + SimRules.ARTILLERY_IDLE_TICKS
			continue
		st.next_fire = t + _battery_gap(st)
		_spawn_munition(SimRules.N_SHELL, st.o, st.tile, tt)
		stats.shells += 1

static func _d2(a: int, b: int, W: int) -> float:
	var dx := a % W - b % W
	var dy := a / W - b / W
	return float(dx * dx + dy * dy)

static func _man(a: int, b: int, W: int) -> float:
	return float(absi(a % W - b % W) + absi(a / W - b / W))

func _spawn_munition(nk: int, o: int, from_tile: int, to_tile: int) -> Dictionary:
	var W: int = g.W
	var a := tpos(from_tile, W); var b := tpos(to_tile, W)
	var m := {"nk": nk, "o": o, "from": a, "to": b, "tile": to_tile, "t0": now(),
		"t1": now() + R.munition_flight_ticks(a.distance_to(b), nk), "victim": g.owner_map[to_tile]}
	munitions.append(m)
	return m

# ---------------------------------------------------------------- strikes: air strike / slug launch
# SimNukes.launch_nuke for NUKE_FLAT kinds: nearest (manhattan) loaded airfield within reach / railgun
func launch_strike(o: int, nk: int, tile: int) -> bool:
	if tile < 0 or tile >= g.owner_map.size(): return false
	var tg: int = g.owner_map[tile]
	if tg == o:
		if o == g.PLAYER: g.notify("You can't strike your own land", "info")
		return false
	if tg > 0 and g.allied(o, tg):
		if o == g.PLAYER: g.notify("You can't strike an ally", "info")
		return false
	var lk := 14 if nk == SimRules.N_AIRSTRIKE else 15
	var reach := R.airfield_range() if nk == SimRules.N_AIRSTRIKE else 0.0
	var W: int = g.W
	var best = null
	var bd := 0.0
	var out_of_reach := false
	var free: bool = o == g.PLAYER and (g.god_mode or g.no_cd)
	for st in g.structs:
		if st.o != o or st.k != lk or float(st.get("bt", 0.0)) > 0.0: continue
		if not free and ready_missiles(st) <= 0: continue
		if reach > 0.0 and _d2(st.tile, tile, W) > reach * reach:
			out_of_reach = true; continue
		var d := _man(st.tile, tile, W)
		if best == null or d < bd: best = st; bd = d
	var what := "airfield" if lk == 14 else "railgun"
	if best == null:
		if o == g.PLAYER: g.notify(("That is out of your %s's reach" if out_of_reach else "No %s is ready") % what, "bad")
		return false
	if not free: fire_shot(best)
	_spawn_munition(nk, o, best.tile, tile)
	stats.strikes += 1
	if o == g.PLAYER:
		g.notify("%s on its way to %s" % ["Air Strike" if lk == 14 else "Railgun slug", g._nname(tg)], "info")
		g.sfx("atom_launch", -6.0, 0.04, o)
	elif tg == g.PLAYER:
		g.notify("%s from %s is inbound!" % ["An air strike" if lk == 14 else "A railgun slug", g._nname(o)], "bad")
	if lk == 15: g._map_effect("railgun_beam", [tpos(best.tile, W), tpos(tile, W)])
	return true

func _munitions_tick(t: int) -> void:
	for m in munitions.duplicate():
		if t < int(m.t1): continue
		munitions.erase(m)
		strike(m)

var _strike_tick := -1
var _strike_map_revision := -1
var _strike_structure_revision := -1
var _strike_scans := {}
var worker_strike_territory_scans_used := 0
var worker_strike_structure_scans_used := 0

func accept_strike_scans(tick: int, map_revision: int, structure_revision: int, scans: Dictionary) -> void:
	_strike_tick = tick
	_strike_map_revision = map_revision
	_strike_structure_revision = structure_revision
	_strike_scans = scans

static func strike_territory(center: int, radius: float, kind: int, owners: PackedInt32Array,
		width: int, height: int) -> Dictionary:
	var hit := {}
	if kind == SimRules.N_SHELL:
		var owner := owners[center]
		if owner > 0: hit[owner] = 1
		return hit
	for tile: int in land_in_disk(center, radius, owners, width, height):
		var owner := owners[tile]
		if owner > 0: hit[owner] = hit.get(owner, 0) + 1
	return hit

static func strike_structures(center: int, radius: float, structures: Array, width: int) -> PackedInt32Array:
	var tiles := PackedInt32Array()
	var squared := radius * radius
	for structure: Dictionary in structures:
		if _d2(center, structure.tile, width) <= squared:
			tiles.append(structure.tile)
	return tiles

# SimArsenal._strike: kills a share of each enemy army with land under it, damages structures there
func strike(m: Dictionary) -> void:
	var nk: int = m.nk
	var to: int = m.tile
	var shooter: int = m.o
	var W: int = g.W
	var radius := R.strike_radius(nk)
	var r2 := radius * radius
	var scan: Array = _strike_scans.get(Vector2i(to, nk), []) if _strike_tick == now() else []
	var use_scan: bool = not scan.is_empty() and scan[0] == radius
	var hit: Dictionary
	if use_scan and _strike_map_revision == g._attack_map_revision:
		hit = scan[1]
		worker_strike_territory_scans_used += 1
	else:
		hit = strike_territory(to, radius, nk, g.owner_map, W, g.H)
	for o in hit:
		if not _strike_enemy(shooter, o): continue
		var n = g.nations[o]
		var troops: float = n.troops
		var kill := SimRules.strike_kill(nk, troops, float(hit[o]) * R.k_area, R.ts)
		if kill <= 0.0: continue
		var keep := 1.0 - kill / maxf(troops, 1.0)
		n.troops = troops - kill
		stats.killed += int(kill)
		if nk != SimRules.N_SHELL:
			for a in g.attacks:
				if a.a == o: a.troops *= keep
			for bt in g.boats:
				if bt.a == o: bt.troops *= keep
			n["grudge_" + str(shooter)] = now() + SimRules.HOSTILE_TICKS
			n["attacked_tick"] = now()
	var dmg: int = SimRules.STRIKE_DAMAGE[nk]
	if dmg > 0:
		if use_scan and _strike_structure_revision == g._sv:
			worker_strike_structure_scans_used += 1
			for tile: int in scan[2]:
				var building = g.struct_at.get(tile)
				if building != null and _strike_enemy(shooter, building.o):
					damage_struct(building, dmg, shooter)
		else:
			for st in g.structs.duplicate():
				if _strike_enemy(shooter, st.o) and _d2(to, st.tile, W) <= r2:
					damage_struct(st, dmg, shooter)
	var c := tpos(to, W)
	var vis_r := maxf(1.5, radius)
	g._map_effect("strike_blast", [c * g.TS, vis_r * g.TS,
		0.55 if nk == SimRules.N_SHELL else 0.9, to * 2654435761 % 100000])
	var victim: int = g.owner_map[to]
	# UIAdvisor.on_nuke_detonated: shells play only when on screen; airstrike/slug when on screen or yours.
	var mine: bool = victim == g.PLAYER or shooter == g.PLAYER
	var near: bool = g._world_on_screen(c * g.TS)
	if nk == SimRules.N_SHELL:
		if near:
			g.sfx("atom_hit", -6.0 if mine else -11.0, 0.08, g.PLAYER if mine else shooter, c * g.TS)
	elif nk != SimRules.N_SHELL:
		if victim == g.PLAYER and shooter != g.PLAYER:
			g.notify("%s from %s hit your land" % ["An air strike" if nk == SimRules.N_AIRSTRIKE else "A railgun slug", g._nname(shooter)], "bad")
		if near or mine:
			g.sfx("atom_hit", -10.0, 0.06, g.PLAYER if mine else shooter, c * g.TS)
			if mine:
				g._map_effect("strike_shake", [1.2])

# land tiles of a disc around tile `c` (tile-centre distances, like SimState.disk_tiles(.., land_only))
func disk_tiles(c: int, r: float) -> PackedInt32Array:
	return land_in_disk(c, r, g.owner_map, g.W, g.H)

static func land_in_disk(c: int, r: float, owners: PackedInt32Array, W: int, H: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var cx := c % W; var cy := c / W
	var ri := int(ceil(r)); var r2 := r * r
	for y in range(maxi(0, cy - ri), mini(H, cy + ri + 1)):
		var dy := y - cy
		for x in range(maxi(0, cx - ri), mini(W, cx + ri + 1)):
			var dx := x - cx
			if dx * dx + dy * dy > r2: continue
			var i := y * W + x
			if owners[i] >= 0: out.append(i)
	return out

# ---------------------------------------------------------------- nuke blasts (SimNukes._detonate)
# Pick fallout tiles in blast order using the detached gameplay RNG.
static func select_blast_fallout(center: Vector2, radius: float, kind: int, owners: PackedInt32Array,
		width: int, height: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	var cx := int(center.x)
	var cy := int(center.y)
	var tile := clampi(cy, 0, height - 1) * width + clampi(cx, 0, width - 1)
	var inner := radius * SimRules.inner_frac(kind)
	var inner_squared := inner * inner
	var geometry := BlastGeometry.new()
	geometry.prepare(radius)
	var selected := PackedInt32Array()
	for candidate in geometry.land_tiles(tile, width, height, owners):
		var dx := candidate % width - cx
		var dy := candidate / width - cy
		if float(dx * dx + dy * dy) <= inner_squared or rng.randi() % 2 != 0:
			selected.append(candidate)
	return selected

# Every land tile of the inner radius and a random half of the outer ring is relinquished and left as
# fallout; each hit owner loses troops by nukeDeathFactor (its attacks and transports too); every
# structure and unit inside the outer radius is destroyed. `r`: the outer radius (Rules.nuke_radii, or a
# console-edited NUKE_R); the inner disc is the source's inner/outer share for that kind.
func nuke_blast(o: int, c: Vector2, r: float, nk: int, plan: Variant = null) -> Dictionary:
	var W: int = g.W; var H: int = g.H
	var cx := int(c.x); var cy := int(c.y)
	var ct := clampi(cy, 0, H - 1) * W + clampi(cx, 0, W - 1)
	var inner := r * SimRules.inner_frac(nk)
	var inner2 := inner * inner
	var r2 := r * r
	var lost := {}
	var before := {}
	var fallout_n := 0
	var blast_tiles: PackedInt32Array = _blast_tiles(ct, r) if plan == null else plan.tiles
	if plan != null and plan.has("territory"):
		lost = plan.territory.lost
		for owner in lost:
			before[owner] = int(g.nations[owner].land)
		g._apply_blast_territory(blast_tiles, plan.territory)
		fallout_n = blast_tiles.size()
	else:
		for tt in blast_tiles:
			if plan == null:
				var dx := tt % W - cx; var dy := tt / W - cy
				if float(dx * dx + dy * dy) > inner2 and g.rng.randi() % 2 == 0: continue
			var ow: int = g.owner_map[tt]
			if ow > 0:
				if not before.has(ow):
					before[ow] = int(g.nations[ow].land); lost[ow] = 0
				lost[ow] += 1
				g._set_owner(tt, g.NEUTRAL)
			g.fallout[tt] = 1; g.fallout_list[tt] = true
			if g._attack_worker != null: g._record_attack_tile(tt)
			g._record_tile_snapshot(tt)
			g.fallout_t[tt] = 60.0; g.fallout_hot[tt] = true
			g._map_effect("fallout", [tt])
			fallout_n += 1
			g._repaint(tt)
	var casualties := {}
	if plan != null and plan.get("casualty_scale", []) == [R.k_area, R.ts]:
		casualties = plan.casualties
	var attacks_by_owner := {}
	var boats_by_owner := {}
	if not casualties.is_empty():
		attacks_by_owner = group_troops(g.attacks, casualties)
		boats_by_owner = group_troops(g.boats, casualties)
	for ow in lost:
		var prepared: Dictionary = casualties.get(ow, {})
		if prepared.is_empty() or not _apply_warhead_casualties(ow, prepared, attacks_by_owner, boats_by_owner):
			nuke_troops(ow, nk, int(lost[ow]), int(before[ow]))
		var n = g.nations[ow]
		if int(n.land) <= 0: n["last_by"] = o
		if ow != o: n["grudge_" + str(o)] = now() + SimRules.NUKE_GRUDGE_TICKS
	# structures and units inside the outer radius
	for st in g.structs.duplicate():
		var sdx: int = st.tile % W - cx; var sdy: int = st.tile / W - cy
		if float(sdx * sdx + sdy * sdy) <= r2:
			var so: int = st.o
			g._struct_remove(st)
			if so == g.PLAYER and o != g.PLAYER: g.notify("%s destroyed your %s" % [g._nname(o), g.build_data[st.k][1]], "bad")
	var cc := Vector2(cx, cy)
	for ws in g.warships.duplicate():
		if ws.pos.distance_squared_to(cc) <= r2: SimWarships.erase_ref(g.warships, ws)
	for bt in g.boats.duplicate():
		var bp: Vector2 = g._boat_pos(bt)[0] / g.TS
		if bp.distance_squared_to(cc) <= r2: SimWarships.erase_ref(g.boats, bt)
	for tr in g.traders.duplicate():
		var tp: Vector2 = g._path_pos(tr)[0] / g.TS
		if tp.distance_squared_to(cc) <= r2: SimWarships.erase_ref(g.traders, tr)
	return {"lost": lost, "fallout": fallout_n}

# SimNukes._nuke_troops: bombs shrink troops by ((T - n) / T)^5; warheads 500 x (1 - e^(-2 excess/max))
# per full-size tile, never below 3 % of the cap.
func nuke_troops(o: int, nk: int, n_lost: int, tiles_before: int) -> void:
	var n = g.nations[o]
	var cap := maxf(g.troop_cap(o), 1.0)
	if nk != SimRules.N_WARHEAD:
		var f := pow(maxf(0.0, tiles_before - n_lost) / maxf(tiles_before, 1), 5.0)
		n.troops = float(n.troops) * f
		for a in g.attacks:
			if a.a == o: a.troops *= f
		for bt in g.boats:
			if bt.a == o: bt.troops *= f
		return
	n.troops = warhead_survivors(n.troops, cap, n_lost, R.k_area, R.ts)
	for a in g.attacks:
		if a.a == o: a.troops = warhead_survivors(a.troops, cap, n_lost, R.k_area, R.ts)
	for bt in g.boats:
		if bt.a == o: bt.troops = warhead_survivors(bt.troops, cap, n_lost, R.k_area, R.ts)

static func warhead_survivors(troops: float, cap: float, tiles: int, area: float, scale: float) -> float:
	for _i in tiles:
		var loss := minf(area * SimRules.warhead_death(troops, cap, scale), maxf(0.0, troops - 0.03 * cap))
		if loss <= 0.0:
			break
		troops -= loss
	return troops

static func group_troops(units: Array, owners: Dictionary) -> Dictionary:
	var grouped := {}
	for unit: Dictionary in units:
		if owners.has(unit.a):
			if not grouped.has(unit.a):
				grouped[unit.a] = []
			grouped[unit.a].append(unit)
	return grouped

var prepared_warhead_owners := 0

func _apply_warhead_casualties(owner: int, plan: Dictionary, attacks_by_owner: Dictionary, boats_by_owner: Dictionary) -> bool:
	var nation: Dictionary = g.nations[owner]
	var attacks: Array = attacks_by_owner.get(owner, [])
	var boats: Array = boats_by_owner.get(owner, [])
	if nation.troops != plan.troops_before or maxf(g.troop_cap(owner), 1.0) != plan.cap \
			or not _same_troops(attacks, plan.attacks) or not _same_troops(boats, plan.boats):
		return false
	nation.troops = plan.survivors
	for i in attacks.size():
		attacks[i].troops = plan.attacks[i][1]
	for i in boats.size():
		boats[i].troops = plan.boats[i][1]
	prepared_warhead_owners += 1
	return true

static func _same_troops(units: Array, plan: Array) -> bool:
	if units.size() != plan.size():
		return false
	for i in units.size():
		if units[i].troops != plan[i][0]:
			return false
	return true

# SimNukes._break_nuked_alliances: allies with >= 100 weighted full-size tiles (inner 1, outer 0.5)
# inside the blast lose their alliance with the launcher.
func break_nuked_alliances(o: int, c: Vector2, r: float, nk: int) -> Array:
	var W: int = g.W
	var cx := int(c.x); var cy := int(c.y)
	var ct := clampi(cy, 0, g.H - 1) * W + clampi(cx, 0, W - 1)
	var inner := r * SimRules.inner_frac(nk)
	var inner2 := inner * inner
	var w := {}
	for tt in disk_tiles(ct, r):
		var ow: int = g.owner_map[tt]
		if ow <= 0 or ow == o or not g.allied(o, ow): continue
		var dx := tt % W - cx; var dy := tt / W - cy
		w[ow] = float(w.get(ow, 0.0)) + (1.0 if float(dx * dx + dy * dy) <= inner2 else 0.5)
	var broke := []
	for ow in w:
		if float(w[ow]) * R.k_area >= SimRules.NUKE_ALLIANCE_BREAK_FULL:
			g.break_alliance(o, ow); broke.append(ow)
	return broke

# SimArsenal._scatter_warheads: 4..6 warheads evenly around the aim (random turn, +-0.3 rad jitter),
# 28..46 full-size tiles out, never onto the launcher's or an ally's land; each lands 2 ticks after the last.
func scatter_targets(o: int, aim: Vector2) -> Array:
	var W: int = g.W; var H: int = g.H
	var count: int = g.rng.randi_range(SimRules.SCATTER_MIN, SimRules.SCATTER_MAX)
	var base: float = g.rng.randf() * TAU
	var near := R.scatter_near(); var far := R.scatter_far()
	var out := []
	for i in count:
		for _try in 6:
			var ang: float = base + i * TAU / count + g.rng.randf_range(-0.3, 0.3)
			var rad: float = g.rng.randf_range(near, far)
			var x := int(floor(aim.x + cos(ang) * rad + 0.5)); var y := int(floor(aim.y + sin(ang) * rad + 0.5))
			if x < 0 or y < 0 or x >= W or y >= H: continue
			var ow: int = g.owner_map[y * W + x]
			if ow == o or (ow > 0 and g.allied(o, ow)): continue
			out.append(Vector2(x + 0.5, y + 0.5))
			break
	return out

# ---------------------------------------------------------------- SAMs (SimNukes._sam_tick / _sam_plan)
func interceptable(ms) -> bool:
	if ms.get("mirv_bus", false): return false
	if ms.get("evade", false): return false  # ICBM evasion roll (game/nukes.gd): SAMs ignore it entirely
	return SimRules.NUKE_INTERCEPT_P[int(ms.get("nk", 0))] > 0.0

func flight_ticks(ms) -> int:
	return maxi(1, int(ms.get("ft", ceili(float(ms.dur) / DT_TICK))))

func _cur_k(ms) -> int:
	return now() - int(ms.lt) if ms.has("lt") else int(floor(float(ms.t) / DT_TICK))

# SimNukes._sam_candidates traj: the tile under the missile at tick k of its flight, along its arc
# (Rules.nuke_arc_at(arc, k / flight), floored to the tile), as that tile's centre
func _traj(ms, k: int) -> Vector2:
	var traj = ms.get("traj")
	if traj == null:
		traj = sample_sam_trajectory(g._missile_arc(ms), flight_ticks(ms), g.W, g.H)
		ms["traj"] = traj
	return traj[clampi(k, 0, traj.size() - 1)]

func _sam_candidates(ms, sams: Array) -> void:
	ms["cand_tick"] = now() + SimRules.SAM_CAND_REFRESH_TICKS
	ms["plan_fire"] = {}; ms["plan_k"] = {}
	if ms.get("evade", false):
		ms["cands"] = []
		return
	var reach := (SimRules.SAM_MAX_RANGE_FULL + SimRules.NUKE_TARGETABLE_FULL) / R.k_lin
	var r2 := reach * reach
	var c := []
	for st in sams:
		if st.o == ms.o: continue
		var p := tpos(st.tile, g.W)
		if p.distance_squared_to(ms.to) <= r2 or p.distance_squared_to(ms.from) <= r2: c.append(st)
	ms["cands"] = c

static func _man_v(a: Vector2, b: Vector2) -> float:
	return absf(floorf(a.x) - floorf(b.x)) + absf(floorf(a.y) - floorf(b.y))

static func sample_sam_trajectory(arc: Dictionary, ft: int, width: int, height: int) -> PackedVector2Array:
	var trajectory := PackedVector2Array()
	trajectory.resize(ft + 1)
	for i in ft + 1:
		var p := SimRules.nuke_arc_at(arc, float(i) / float(ft))
		trajectory[i] = Vector2(clampf(floorf(p.x), 0.0, width - 1) + 0.5,
			clampf(floorf(p.y), 0.0, height - 1) + 0.5)
	return trajectory

static func sam_plan(rules: SimRules, width: int, t: int, flight: Array, station: Vector3i,
		trajectory: PackedVector2Array) -> Vector2i:
	var cur: int = flight[0]
	var last: int = flight[1]
	var from: Vector2 = flight[2]
	var to: Vector2 = flight[3]
	var zone := SimRules.NUKE_TARGETABLE_FULL / rules.k_lin
	var z2 := zone * zone
	var rmax := SimRules.SAM_MAX_RANGE_FULL / rules.k_lin
	var rmax2 := rmax * rmax
	var sp := tpos(station.x, width)
	var inc := 0
	var lastd := -1.0
	for k in range(cur, last):
		var p := trajectory[clampi(k, 0, trajectory.size() - 1)]
		var d := sp.distance_squared_to(p)
		inc = inc + 1 if (lastd >= 0.0 and d > lastd) else 0
		lastd = d
		var nt := k - cur
		var rr := rules.sam_range_at(station.y, t + nt - station.z)
		if d <= rr * rr and (p.distance_squared_to(to) < z2 or p.distance_squared_to(from) < z2):
			var stk := rules.sam_ticks_to(_man_v(sp, p))
			if nt >= stk:
				return Vector2i(t + nt - stk, k)
		if inc > 3 and d > rmax2: break
	var kf := last - 1
	if kf >= cur:
		var rf := rules.sam_range_at(station.y, t + (last - cur) - station.z)
		if sp.distance_squared_to(to) <= rf * rf:
			var st2 := rules.sam_ticks_to(_man_v(sp, trajectory[clampi(kf, 0, trajectory.size() - 1)]))
			if kf - cur >= st2:
				return Vector2i(t + kf - cur - st2, kf)
	return Vector2i(-1, -1)

var _prepared_sam: Array = []
var _prepared_sam_tick := -1
var worker_sam_plans_used := 0

func _sam_flight(ms: Dictionary, tick: int) -> Array:
	var k := tick - int(ms.lt) if ms.has("lt") else _cur_k(ms)
	return [maxi(0, k), flight_ticks(ms), ms.from, ms.to]

func _sam_arc(ms: Dictionary) -> Dictionary:
	var arc = ms.get("arc")
	return R.munition_arc(g.H, ms.from, ms.to, int(ms.get("nk", SimRules.N_ATOM))) if arc == null else arc

static func _sam_station(st: Dictionary) -> Vector3i:
	return Vector3i(st.tile, int(st.get("level", 1)), int(st.get("up_tick", -100000)))

static func _sam_needs_plan(plan: int, tick: int) -> bool:
	return plan == -3 or (plan >= 0 and plan < tick)

func capture_sam_plans(tick: int) -> Array:
	var jobs := []
	var stations: Variant = null
	var reach := (SimRules.SAM_MAX_RANGE_FULL + SimRules.NUKE_TARGETABLE_FULL) / R.k_lin
	for ms: Dictionary in g.missiles:
		if ms.get("sam_st") != null or not interceptable(ms): continue
		var refresh := tick >= int(ms.get("cand_tick", -100000))
		if refresh and stations == null:
			stations = []
			for st: Dictionary in g.structs:
				if st.k == 4 and float(st.get("bt", 0.0)) <= 0.1:
					stations.append(st)
		var due := []
		var candidates: Array = stations if refresh else ms.get("cands", [])
		for st: Dictionary in candidates:
			if not _alive_struct(st) or st.o == ms.o or g.allied(st.o, ms.o) \
					or float(st.get("bt", 0.0)) > 0.1:
				continue
			if refresh:
				var position := tpos(st.tile, g.W)
				if position.distance_squared_to(ms.from) > reach * reach \
						and position.distance_squared_to(ms.to) > reach * reach:
					continue
			elif not _sam_needs_plan(int(ms.plan_fire.get(st.tile, -3)), tick):
				continue
			due.append(_sam_station(st))
		if not due.is_empty():
			var flight := _sam_flight(ms, tick)
			if flight[0] >= flight[1]: continue
			var trajectory: PackedVector2Array = ms.get("traj", PackedVector2Array())
			jobs.append({"flight": flight, "arc": _sam_arc(ms).duplicate(true),
				"input_trajectory": trajectory.duplicate(), "stations": due})
	return jobs

func accept_sam_plans(tick: int, plans: Array) -> void:
	_prepared_sam_tick = tick
	_prepared_sam = plans

func _sam_plan(ms: Dictionary, st: Dictionary) -> void:
	var t := now()
	var key: int = st.tile
	ms.plan_fire[key] = -1
	if ms.get("evade", false): return
	var flight := _sam_flight(ms, t)
	if flight[0] >= flight[1]: return
	var station := _sam_station(st)
	var result := Vector2i(-1, -1)
	var prepared := false
	if t == _prepared_sam_tick and not _prepared_sam.is_empty():
		var arc := _sam_arc(ms)
		for job: Dictionary in _prepared_sam:
			if job.flight != flight or job.arc != arc or not job.results.has(station):
				continue
			if ms.get("traj", PackedVector2Array()) != job.input_trajectory and ms.get("traj") != job.trajectory:
				continue
			if not ms.has("arc"): ms.arc = arc
			ms.traj = job.trajectory
			result = job.results[station]
			prepared = true
			worker_sam_plans_used += 1
			break
	if not prepared:
		_traj(ms, flight[0])
		result = sam_plan(R, g.W, t, flight, station, ms.traj)
	ms.plan_fire[key] = result.x
	if result.x >= 0:
		ms.plan_k[key] = result.y

func _sam_tick(t: int) -> void:
	if g.missiles.is_empty(): return
	var sams = null
	var fires := []
	for ms in g.missiles:
		if ms.get("sam_st") != null or not interceptable(ms): continue
		if t >= int(ms.get("cand_tick", -100000)):
			if sams == null:
				sams = []
				for st in g.structs:
					if st.k == 4 and float(st.get("bt", 0.0)) <= 0.0: sams.append(st)
			_sam_candidates(ms, sams)
		var cands: Array = ms.get("cands", [])
		for st in cands:
			if not _alive_struct(st) or float(st.get("bt", 0.0)) > 0.0 or st.o == ms.o or g.allied(st.o, ms.o): continue
			var key: int = st.tile
			var plan := int(ms.plan_fire.get(key, -3))
			if _sam_needs_plan(plan, t):
				_sam_plan(ms, st)
				plan = int(ms.plan_fire[key])
			if plan >= 0 and plan <= t + 1:
				var rem := flight_ticks(ms) - _cur_k(ms)
				var score := (70001 if int(ms.get("nk", 0)) == SimRules.N_HYDROGEN else 0) \
					+ maxi(0, 200000 - int(_man_v(tpos(st.tile, g.W), ms.to) * R.k_lin) * 1000) \
					+ maxi(0, 10000 - rem * 100)
				fires.append([score, ms, st])
	if not fires.is_empty():
		fires.sort_custom(func(a, b): return a[0] > b[0])
		for f in fires:
			var ms = f[1]; var st = f[2]
			if ms.get("sam_st") != null or ready_missiles(st) <= 0: continue
			fire_shot(st)
			var k := int(ms.plan_k[st.tile])
			var p := _traj(ms, k)
			var sp := tpos(st.tile, g.W)
			ms["sam_st"] = st
			ms["sam_hit"] = t + R.sam_ticks_to(_man_v(sp, p))
			ms["sam_k"] = k
			stats.sam_fired += 1
			sam_shots.append({"from": sp, "ms": ms, "k": k, "t0": t, "t1": ms.sam_hit, "o": st.o})
			if st.o == g.PLAYER or ms.o == g.PLAYER: g.sfx("sam_shoot", 0.0, 0.04, g.PLAYER)
	for ms in g.missiles.duplicate():
		if ms.get("sam_st") != null and t >= int(ms.sam_hit): sam_resolve(ms)

# SimNukes._sam_intercept: the bomb is destroyed unless the SAM was lost meanwhile
func sam_resolve(ms) -> bool:
	var st = ms.get("sam_st")
	if st == null: return false
	if ms.get("evade", false):
		ms["sam_st"] = null
		return false
	if not _alive_struct(st) or st.o == ms.o:
		ms["sam_st"] = null
		ms["cand_tick"] = now()
		return false
	g._record_missile_intercept(ms)
	ms["shot_down"] = true  # (read by the client's alert banner: it turns green)
	SimWarships.erase_ref(g.missiles, ms)
	stats.sam_hits += 1
	# MapView._on_nuke_detonated (radius 0): an airburst where the nuke was, a pop ring and the SAM burst
	var f := clampf(float(int(ms.get("sam_k", 0))) / float(flight_ticks(ms)), 0.0, 1.0)
	var ip: Vector2 = g._missile_world_pos(ms, f) / g.TS
	g._viewer_event({"type": "sam", "actor": st.o, "target": ms.o, "point": ip}, [st.o, ms.o])
	g._map_effect("sam", [ip, int(floor(ip.y)) * g.W + int(floor(ip.x))])
	if st.o == g.PLAYER or ms.o == g.PLAYER:
		g.sfx("sam_hit", 0.0, 0.04, g.PLAYER)
	if int(ms.get("nk", 0)) != SimRules.N_WARHEAD:
		var title: String = g.build_data[ms.k][1]
		if st.o == g.PLAYER: g.notify("Your SAM shot down %s from %s" % [title, g._nname(ms.o)], "good")
		elif ms.o == g.PLAYER: g.notify("Your %s was intercepted by %s" % [title, g._nname(st.o)], "bad")
	return true
