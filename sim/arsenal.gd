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
	R = rules

func reset() -> void:
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
	if _luau_tick():  # Step 5c: the whole arsenal tick runs in Luau
		for s in sam_shots.duplicate():
			if t > int(s.t1) + 2: sam_shots.erase(s)
		return
	var cons = g.sim_struct.construction() if g.sim_struct != null else null  # Step 5b: the countdown runs in Luau
	if cons == null:
		for st in g.structs:
			if float(st.get("bt", 0.0)) > 0.0:
				st.bt = maxf(0.0, float(st.bt) - 0.1)
				if st.bt <= 0.0: _activate(st)
				continue
			if st.k in [4, 5, 14, 15]: _refresh_cd(st)
	else:
		var busy: PackedInt32Array = cons.busy
		var bt: PackedFloat64Array = cons.bt
		var act: PackedByteArray = cons.act
		var structs: Array = g.structs
		var j := 0
		var nb := busy.size()
		for i in structs.size():
			var st = structs[i]
			if j < nb and busy[j] == i:
				st.bt = bt[j]
				if act[j] != 0: _activate(st)
				j += 1
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

func battery_target(st) -> int:
	var W: int = g.W
	var rng_ := R.artillery_range()
	var r2 := rng_ * rng_
	var best := -1
	var bd := 0.0
	for s2 in g.structs:
		if not _strike_enemy(st.o, s2.o): continue
		var d := _d2(st.tile, s2.tile, W)
		if d <= r2 and (best < 0 or d < bd or (d == bd and s2.tile < best)):
			best = s2.tile; bd = d
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
	var lu := lu_on()
	if lu != null:
		var uid = _lrun(lu, "munition", [nk, o, from_tile, to_tile], false, false)
		if uid != null: return _by_uid.get(int(uid), {})
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
	if lk == 15: g.beams.append({"a": tpos(best.tile, W), "b": tpos(tile, W), "t": 0.0})
	return true

func _munitions_tick(t: int) -> void:
	for m in munitions.duplicate():
		if t < int(m.t1): continue
		munitions.erase(m)
		strike(m)

# SimArsenal._strike: kills a share of each enemy army with land under it, damages structures there
func strike(m: Dictionary) -> void:
	var nk: int = m.nk
	var to: int = m.tile
	var shooter: int = m.o
	var W: int = g.W
	var radius := R.strike_radius(nk)
	var r2 := radius * radius
	var hit := {}
	if nk == SimRules.N_SHELL:
		var o0: int = g.owner_map[to]
		if _strike_enemy(shooter, o0): hit[o0] = 1
	else:
		for tt in disk_tiles(to, radius):
			var o1: int = g.owner_map[tt]
			if _strike_enemy(shooter, o1): hit[o1] = hit.get(o1, 0) + 1
	for o in hit:
		var n = g.nations[o]
		var troops: float = n.troops
		var kill := SimRules.strike_kill(nk, troops, float(hit[o]) * R.k_area, R.ts)
		if kill <= 0.0: continue
		var keep := 1.0 - kill / maxf(troops, 1.0)
		n.troops = troops - kill
		stats.killed += int(kill)
		if nk != SimRules.N_SHELL:
			g.sim_atk.scale_owner(o, keep)
			for bt in g.boats:
				if bt.a == o: bt.troops *= keep
			n["grudge_" + str(shooter)] = now() + SimRules.HOSTILE_TICKS
			n["attacked_tick"] = now()
	var dmg: int = SimRules.STRIKE_DAMAGE[nk]
	if dmg > 0:
		for st in g.structs.duplicate():
			if _strike_enemy(shooter, st.o) and _d2(to, st.tile, W) <= r2:
				damage_struct(st, dmg, shooter)
	var c := tpos(to, W)
	var vis_r := maxf(1.5, radius)
	g.blasts.append({"pos": c * g.TS, "r": vis_r * g.TS, "t": 0.0, "dur": 0.55 if nk == SimRules.N_SHELL else 0.9, "seed": to * 2654435761 % 100000, "kind": "sam"})
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
				g._add_shake(1.2)

# land tiles of a disc around tile `c` (tile-centre distances, like SimState.disk_tiles(.., land_only))
func disk_tiles(c: int, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var W: int = g.W; var H: int = g.H
	var cx := c % W; var cy := c / W
	var ri := int(ceil(r)); var r2 := r * r
	for y in range(maxi(0, cy - ri), mini(H, cy + ri + 1)):
		var dy := y - cy
		for x in range(maxi(0, cx - ri), mini(W, cx + ri + 1)):
			var dx := x - cx
			if dx * dx + dy * dy > r2: continue
			var i := y * W + x
			if g.owner_map[i] >= 0: out.append(i)
	return out

# ---------------------------------------------------------------- nuke blasts (SimNukes._detonate)
# Every land tile of the inner radius and a random half of the outer ring is relinquished and left as
# fallout; each hit owner loses troops by nukeDeathFactor (its attacks and transports too); every
# structure and unit inside the outer radius is destroyed. `r`: the outer radius (Rules.nuke_radii, or a
# console-edited NUKE_R); the inner disc is the source's inner/outer share for that kind.
func nuke_blast(o: int, c: Vector2, r: float, nk: int) -> Dictionary:
	var lu := lu_on()
	if lu != null:
		var ret = _lrun(lu, "blast", [o, c.x, c.y, r, nk], true, nk == SimRules.N_WARHEAD)
		if ret != null:
			var q: PackedInt32Array = (ret as PackedByteArray).to_int32_array()
			var lost_l := {}
			for k in range(0, q.size() - 1, 2): lost_l[q[k]] = q[k + 1]
			return {"lost": lost_l, "fallout": q[q.size() - 1]}
	var W: int = g.W; var H: int = g.H
	var cx := int(c.x); var cy := int(c.y)
	var ct := clampi(cy, 0, H - 1) * W + clampi(cx, 0, W - 1)
	var inner := r * SimRules.inner_frac(nk)
	var inner2 := inner * inner
	var r2 := r * r
	var lost := {}
	var before := {}
	var fallout_n := 0
	for tt in disk_tiles(ct, r):
		var dx := tt % W - cx; var dy := tt / W - cy
		if float(dx * dx + dy * dy) > inner2 and g.rng.randi() % 2 == 0: continue
		var ow: int = g.owner_map[tt]
		if ow > 0:
			if not before.has(ow):
				before[ow] = int(g.nations[ow].land); lost[ow] = 0
			lost[ow] += 1
			g._set_owner(tt, g.NEUTRAL)
		g.fallout[tt] = 1; g.fallout_list[tt] = true
		if g.luau_frec: g.luau_fdirty.append(tt); g.luau_fdirty.append(1)
		g.fallout_t[tt] = 60.0; g.fallout_hot[tt] = true
		if g.fallout_glow != null: g.fallout_glow.on_fallout(tt)
		fallout_n += 1
		g._repaint(tt)
	for ow in lost:
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
		g.sim_atk.scale_owner(o, f)
		for bt in g.boats:
			if bt.a == o: bt.troops *= f
		return
	var k := R.k_area
	var tr: float = n.troops
	for _i in n_lost:
		var d := minf(k * SimRules.warhead_death(tr, cap, R.ts), maxf(0.0, tr - 0.03 * cap))
		if d <= 0.0: break
		tr -= d
	n.troops = tr
	for a in g.attacks.duplicate():
		if a.a != o: continue
		var at: float = a.troops
		for _i in n_lost:
			var d2 := minf(k * SimRules.warhead_death(at, cap, R.ts), maxf(0.0, at - 0.03 * cap))
			if d2 <= 0.0: break
			at -= d2
		g.sim_atk.set_troops(a, at)
	for bt in g.boats:
		if bt.a != o: continue
		var bt_t: float = bt.troops
		for _i in n_lost:
			var d3 := minf(k * SimRules.warhead_death(bt_t, cap, R.ts), maxf(0.0, bt_t - 0.03 * cap))
			if d3 <= 0.0: break
			bt_t -= d3
		bt.troops = bt_t

# SimNukes._break_nuked_alliances: allies with >= 100 weighted full-size tiles (inner 1, outer 0.5)
# inside the blast lose their alliance with the launcher.
func break_nuked_alliances(o: int, c: Vector2, r: float, nk: int) -> Array:
	var lu := lu_on()
	if lu != null:
		var ret = _lrun(lu, "break", [o, c.x, c.y, r, nk], true, false)
		if ret != null:
			var broke_l := []
			for ow in (ret as PackedByteArray).to_int32_array(): broke_l.append(ow)
			return broke_l
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
		var ft := flight_ticks(ms)
		var arc: Dictionary = g._missile_arc(ms)
		traj = PackedVector2Array(); traj.resize(ft + 1)
		for i in ft + 1:
			var p: Vector2 = SimRules.nuke_arc_at(arc, float(i) / float(ft))
			traj[i] = Vector2(clampf(floorf(p.x), 0.0, g.W - 1) + 0.5, clampf(floorf(p.y), 0.0, g.H - 1) + 0.5)
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

func _man_v(a: Vector2, b: Vector2) -> float:
	return absf(floorf(a.x) - floorf(b.x)) + absf(floorf(a.y) - floorf(b.y))

func _sam_plan(ms, st) -> void:
	if ms.get("evade", false):
		ms.plan_fire[st.tile] = -1
		return
	var t := now()
	var cur := maxi(0, _cur_k(ms))
	var last := flight_ticks(ms)
	var zone := SimRules.NUKE_TARGETABLE_FULL / R.k_lin
	var z2 := zone * zone
	var rmax := SimRules.SAM_MAX_RANGE_FULL / R.k_lin
	var rmax2 := rmax * rmax
	var sp := tpos(st.tile, g.W)
	var lvl := int(st.get("level", 1))
	var up := int(st.get("up_tick", -100000))
	var inc := 0
	var lastd := -1.0
	var key: int = st.tile
	for k in range(cur, last):
		var p := _traj(ms, k)
		var d := sp.distance_squared_to(p)
		inc = inc + 1 if (lastd >= 0.0 and d > lastd) else 0
		lastd = d
		var nt := k - cur
		var rr := R.sam_range_at(lvl, t + nt - up)
		if d <= rr * rr and (p.distance_squared_to(ms.to) < z2 or p.distance_squared_to(ms.from) < z2):
			var stk := R.sam_ticks_to(_man_v(sp, p))
			if nt >= stk:
				ms.plan_fire[key] = t + nt - stk; ms.plan_k[key] = k
				return
		if inc > 3 and d > rmax2: break
	var kf := last - 1
	if kf >= cur:
		var rf := R.sam_range_at(lvl, t + (last - cur) - up)
		if sp.distance_squared_to(ms.to) <= rf * rf:
			var st2 := R.sam_ticks_to(_man_v(sp, _traj(ms, kf)))
			if kf - cur >= st2:
				ms.plan_fire[key] = t + kf - cur - st2; ms.plan_k[key] = kf
				return
	ms.plan_fire[key] = -1

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
			if plan == -3 or (plan >= 0 and plan < t):
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
	ms["shot_down"] = true  # (read by the client's alert banner: it turns green)
	SimWarships.erase_ref(g.missiles, ms)
	stats.sam_hits += 1
	# MapView._on_nuke_detonated (radius 0): an airburst where the nuke was, a pop ring and the SAM burst
	var f := clampf(float(int(ms.get("sam_k", 0))) / float(flight_ticks(ms)), 0.0, 1.0)
	var ip: Vector2 = g._missile_world_pos(ms, f) / g.TS
	g._viewer_event({"type": "sam", "actor": st.o, "target": ms.o, "point": ip}, [st.o, ms.o])
	if g.fx_layer != null:
		g.fx_layer.pop(int(floor(ip.y)) * g.W + int(floor(ip.x)), Color(1, 0.85, 0.5))
		g.fx_layer.burst("sam", ip.x, ip.y)
	if st.o == g.PLAYER or ms.o == g.PLAYER:
		g.sfx("sam_hit", 0.0, 0.04, g.PLAYER)
	if int(ms.get("nk", 0)) != SimRules.N_WARHEAD:
		var title: String = g.build_data[ms.k][1]
		if st.o == g.PLAYER: g.notify("Your SAM shot down %s from %s" % [title, g._nname(ms.o)], "good")
		elif ms.o == g.PLAYER: g.notify("Your %s was intercepted by %s" % [title, g._nname(st.o)], "bad")
	return true

# ---------------------------------------------------------------- Step 5c: the arsenal in Luau
# docs/LUAU_PORT.md, Step 5c: with the Luau extension loaded, bombs (flight, SAMs, MIRV split, detonation),
# munitions (shells, air strikes, slugs), construction, reloads and batteries run in
# luau/sim/Core/SimArsenal.luau. Luau owns the missiles and munitions in flight; game.missiles and munitions hold
# mirror Dictionaries with the same keys in the same order (the renderer, net/rep.gd and the tests read them).
# The structures stay GDScript's: each call sends a snapshot (index = place in game.structs) and gets back the
# writes and events in the order the GDScript sim made them. The GDScript code above stays as the fallback
# (remote viewers, NO_LUAU_SIM, no extension).
const LMOD := "Core/SimArsenal"
const LSNAP := 7      # f64 per structure (SimArsenal.luau M.SNAP)
const MS_REC := 17    # f64 per new missile (M.MS_REC)
const MU_REC := 8     # f64 per new munition (M.MU_REC)
const EXT_K := [4, 5, 10, 14, 15]
const EV_STRUCT_REMOVE := 10
const EV_STRUCT_DOWN := 11
const EV_BOATS_SCALE := 12
const EV_BOATS_WARHEAD := 13
const EV_GRUDGE_SET := 14
const EV_LAST_BY := 15
const EV_STRIKE_FX := 16
const EV_SAM_FIRED := 17
const EV_SAM_HIT := 18
const EV_SAM_CLEAR := 19
const EV_DETONATE := 20
const EV_FALLOUT_VIEW := 21
const EV_UNITS_BLAST := 22
const EV_BREAK := 23
const W_BT := 1
const W_CD := 2
const W_CM := 4
const W_NF := 8
const W_HP := 16
const W_LV := 32
const W_SH := 64
const STAT_KEYS := ["sam_fired", "sam_hits", "shells", "strikes", "struct_dmg", "struct_down", "killed"]

var _ser := {}        # tile -> serial of the structure Dictionary last seen there
var _seen := {}       # tile -> that Dictionary
var _mlist: Array = []  # missile mirrors Luau knows, in game.missiles order
var _mids := PackedInt32Array()
var _by_mid := {}
var _ulist: Array = []  # munition mirrors
var _uids := PackedInt32Array()
var _by_uid := {}
var _snap: Array = []  # game.structs at the current call (snapshot index -> Dictionary)
var _cur_ft := PackedInt32Array()
var _warned_foreign := false

## the link when Luau runs the arsenal (not on a remote viewer, not with NO_LUAU_SIM)
func lu_on() -> LuauLink:
	if g.net_remote or OS.has_environment("NO_LUAU_SIM"): return null
	var lu = g.get("luau_link")
	if lu == null or not lu.on: return null
	return lu

## a new map (LuauLink._begin): forget the mirrors
func luau_reset() -> void:
	_ser.clear(); _seen.clear()
	_mlist.clear(); _mids = PackedInt32Array(); _by_mid.clear()
	_ulist.clear(); _uids = PackedInt32Array(); _by_uid.clear()
	_snap = []

# the mirrors still in `list` (in its order), the ids Luau should keep
func _recon(list: Array, known: Array, ids: PackedInt32Array) -> PackedInt32Array:
	var keep := PackedInt32Array()
	var j := 0
	var n := known.size()
	for x in list:
		var k := j
		while k < n and not is_same(known[k], x): k += 1
		if k < n:
			keep.append(ids[k])
			j = k + 1
		elif not _warned_foreign and x is Dictionary and x.has("lt"):
			_warned_foreign = true
			push_warning("sim/arsenal.gd: a missile not made by the Luau arsenal is in game.missiles; it does not fly")
	return keep

func _snapshot(f: PackedFloat64Array, e: PackedFloat64Array, t: int) -> bool:
	var structs: Array = g.structs
	_snap = structs.duplicate()
	f.resize(structs.size() * LSNAP)
	var need := false
	var j := 0
	var i := 0
	for st in structs:
		var tile: int = st.tile
		if not is_same(_seen.get(tile), st):
			_seen[tile] = st
			_ser[tile] = int(_ser.get(tile, 0)) + 1
		var k: int = st.get("k", -1)
		var bt: float = st.get("bt", 0.0)
		f[j] = k; f[j + 1] = tile; f[j + 2] = st.get("o", 0); f[j + 3] = st.get("level", 1); f[j + 4] = bt
		f[j + 5] = float(st.hp) if st.has("hp") else NAN
		f[j + 6] = _ser[tile]
		j += LSNAP
		if k in EXT_K:
			e.append(i)
			e.append(float(st.next_fire) if st.has("next_fire") else NAN)
			e.append(float(st.up_tick) if st.has("up_tick") else NAN)
			e.append(float(st.cd) if st.has("cd") else NAN)
			e.append(float(st.cmax) if st.has("cmax") else NAN)
			if st.has("shots"):
				var sh: Array = st.shots
				e.append(sh.size())
				for v in sh: e.append(float(v))
			else:
				e.append(-1.0)
			if k == 10 and bt <= 0.0 and st.has("next_fire") and t >= int(st.next_fire): need = true
		i += 1
	return need

func _tkd() -> PackedInt32Array:
	var q := PackedInt32Array()
	for id in g.nations.size():
		q.append(id); q.append(g.troop_kind(id)); q.append(g.troop_diff(id))
	return q

## One Luau call. Returns its result (ret), or null when the link failed (the caller runs the GDScript path).
func _lrun(lu: LuauLink, op: String, extra: Array, world: bool, warheads: bool) -> Variant:
	if not lu.flush(g): return null
	var t := now()
	var f := PackedFloat64Array()
	var e := PackedFloat64Array()
	var bat := _snapshot(f, e, t)
	var rms := _recon(g.missiles, _mlist, _mids)
	var rmu := _recon(munitions, _ulist, _uids)
	if world or bat or not rms.is_empty() or not rmu.is_empty():
		var w: Array = g.sim_atk._world()
		if lu.vm.call_fn(LMOD, "world", w) == null:
			lu._fail(g, lu.vm.last_error)
			return null
	var hdr := PackedFloat64Array([t, g.PLAYER, 1.0 if g.reload_mult() < 1.0 else 0.0, g.nuke_outer(9, SimRules.N_WARHEAD)])
	var rf := PackedFloat64Array()
	for k in SimAttacks.RULE_FIELDS: rf.append(float(R.get(k)))
	var rg := LuauLink.rng_args(g)
	var args := [op, rg[0], rg[1], hdr.to_byte_array(), rf.to_byte_array(), f.to_byte_array(), e.to_byte_array(),
		rms.to_byte_array(), rmu.to_byte_array(), (_tkd() if warheads else PackedInt32Array()).to_byte_array()]
	args.append_array(extra)
	var out = lu.vm.call_fn(LMOD, "call", args)
	if out == null:
		lu._fail(g, lu.vm.last_error)
		return null
	_apply_out(lu, out, rms, rmu)
	return out.ret

func _apply_out(lu: LuauLink, out: Dictionary, rms: PackedInt32Array, rmu: PackedInt32Array) -> void:
	var W: int = g.W
	# the lists as Luau has them now: the kept mirrors (others were removed in GDScript), then the new ones
	var kept_m: Array = []
	var ids_m := PackedInt32Array()
	for mid in rms:
		kept_m.append(_by_mid[mid]); ids_m.append(mid)
	var nms: PackedFloat64Array = (out.nms as PackedByteArray).to_float64_array()
	var new_m: Array = []
	for k in range(0, nms.size(), MS_REC):
		var mid := int(nms[k])
		var nk := int(nms[k + 3])
		var from := Vector2(nms[k + 4], nms[k + 5])
		var to := Vector2(nms[k + 6], nms[k + 7])
		var ft := int(nms[k + 9])
		var arc: Dictionary = g.sim_rules.nuke_arc(g.H, from, to) if nk == SimRules.N_WARHEAD else g.sim_rules.munition_arc(g.H, from, to, nk)
		var ms := {"o": int(nms[k + 1]), "k": int(nms[k + 2]), "nk": nk, "from": from, "to": to, "lt": int(nms[k + 8]),
			"ft": ft, "t": 0.0, "dur": float(ft) * DT_TICK, "r": nms[k + 10], "arc": arc, "tgt_o": int(nms[k + 11]),
			"mirv": nms[k + 12] != 0.0, "mirv_bus": nms[k + 13] != 0.0, "branched": nms[k + 14] != 0.0,
			"evade": nms[k + 15] != 0.0, "icbm": nms[k + 16] != 0.0}
		_by_mid[mid] = ms
		new_m.append(ms); ids_m.append(mid)
	var kept_u: Array = []
	var ids_u := PackedInt32Array()
	for uid in rmu:
		kept_u.append(_by_uid[uid]); ids_u.append(uid)
	var nmu: PackedFloat64Array = (out.nmu as PackedByteArray).to_float64_array()
	var new_u: Array = []
	for k in range(0, nmu.size(), MU_REC):
		var uid := int(nmu[k])
		var from_t := int(nmu[k + 3])
		var to_t := int(nmu[k + 4])
		var m := {"nk": int(nmu[k + 1]), "o": int(nmu[k + 2]), "from": tpos(from_t, W), "to": tpos(to_t, W), "tile": to_t,
			"t0": int(nmu[k + 5]), "t1": int(nmu[k + 6]), "victim": int(nmu[k + 7])}
		_by_uid[uid] = m
		new_u.append(m); ids_u.append(uid)
	# SAM state of the missiles (before the events, so the keys come in the GDScript order)
	var sq: PackedFloat64Array = (out.sam as PackedByteArray).to_float64_array()
	var q := 0
	while q < sq.size():
		var ms = _by_mid.get(int(sq[q]))
		var flags := int(sq[q + 1])
		var cand := int(sq[q + 2])
		var nc := int(sq[q + 3])
		q += 4
		var cands := []
		for c in nc: cands.append(_snap[int(sq[q + c])])
		q += nc
		if ms != null and flags & 1:
			ms["cand_tick"] = cand; ms["plan_fire"] = {}; ms["plan_k"] = {}; ms["cands"] = cands
		if ms != null and flags & 2: _traj(ms, 0)
		var npf := int(sq[q]); q += 1
		for c in npf:
			if ms != null: ms.plan_fire[int(sq[q])] = int(sq[q + 1])
			q += 2
		var npk := int(sq[q]); q += 1
		for c in npk:
			if ms != null: ms.plan_k[int(sq[q])] = int(sq[q + 1])
			q += 2
	# the lists: entries GDScript removed or Luau finished leave, foreign ones (props) stay, new ones go last.
	# Done before the events, as GDScript erases a missile before its blast / SAM hit fx and the client
	# (game_state.nukes()) can read the list from inside them.
	var gone_m := {}
	for mid in (out.gms as PackedByteArray).to_int32_array(): gone_m[mid] = true
	var gone_u := {}
	for uid in (out.gmu as PackedByteArray).to_int32_array(): gone_u[uid] = true
	var all_m: Array = kept_m + new_m
	var alive_m := PackedByteArray(); alive_m.resize(all_m.size())
	for c in all_m.size(): alive_m[c] = 0 if gone_m.has(ids_m[c]) else 1
	var all_u: Array = kept_u + new_u
	var alive_u := PackedByteArray(); alive_u.resize(all_u.size())
	for c in all_u.size(): alive_u[c] = 0 if gone_u.has(ids_u[c]) else 1
	_relist(g.missiles, all_m, alive_m, kept_m.size())
	_relist(munitions, all_u, alive_u, kept_u.size())
	_cur_ft = (out.ft as PackedByteArray).to_int32_array()
	lu.apply(g, out)
	# structure writes
	var sw: PackedFloat64Array = (out.sw as PackedByteArray).to_float64_array()
	q = 0
	while q < sw.size():
		var st: Dictionary = _snap[int(sw[q])]
		var mask := int(sw[q + 1])
		q += 2
		if mask & W_BT: st.bt = sw[q]; q += 1
		if mask & W_CD: st.cd = sw[q]; q += 1
		if mask & W_CM: st.cmax = sw[q]; q += 1
		if mask & W_NF: st["next_fire"] = int(sw[q]); q += 1
		if mask & W_HP: st["hp"] = int(sw[q]); q += 1
		if mask & W_LV: st.level = int(sw[q]); q += 1
		if mask & W_SH:
			var n := int(sw[q]); q += 1
			var sh: Array = st.get("shots", [])
			sh.resize(n)
			for c in n: sh[c] = int(sw[q + c])
			q += n
			st["shots"] = sh
	g.sim_atk._mirror(out)
	_mlist = []; _mids = PackedInt32Array(); _by_mid = {}
	for c in all_m.size():
		if alive_m[c] == 0: continue
		_mlist.append(all_m[c]); _mids.append(ids_m[c]); _by_mid[ids_m[c]] = all_m[c]
	_ulist = []; _uids = PackedInt32Array(); _by_uid = {}
	for c in all_u.size():
		if alive_u[c] == 0: continue
		_ulist.append(all_u[c]); _uids.append(ids_u[c]); _by_uid[ids_u[c]] = all_u[c]
	var stv: PackedFloat64Array = (out.stats as PackedByteArray).to_float64_array()
	for c in STAT_KEYS.size():
		if stv[c] != 0.0: stats[STAT_KEYS[c]] += int(stv[c])

# list (in place: other code holds references to game.missiles / munitions): the known entries (all[0 .. nk-1],
# in list order) stay where they are while alive, foreign ones (props) stay, then the new alive ones (all[nk ..])
func _relist(list: Array, all: Array, alive: PackedByteArray, nk: int) -> void:
	var out: Array = []
	var ki := 0
	for x in list:
		if ki < nk and is_same(x, all[ki]):
			if alive[ki]: out.append(x)
			ki += 1
			continue
		out.append(x)
	for c in range(nk, all.size()):
		if alive[c]: out.append(all[c])
	list.clear()
	list.append_array(out)

## Luau events (kinds >= 10, LuauLink._event), in stream order
func on_luau_event(ev: PackedFloat64Array, k: int) -> void:
	var kind := int(ev[k])
	var a := int(ev[k + 1])
	var b := int(ev[k + 2])
	var W: int = g.W
	match kind:
		EV_STRUCT_REMOVE:
			var st: Dictionary = _snap[a]
			if not _alive_struct(st): return
			var title: String = g.build_data[st.k][1]
			var so: int = st.o
			g._struct_remove(st)
			if int(ev[k + 3]) == 1:
				if so == g.PLAYER: g.notify("%s destroyed your %s" % [g._nname(b), title], "bad")
			elif so == g.PLAYER and b != g.PLAYER:
				g.notify("%s destroyed your %s" % [g._nname(b), title], "bad")
		EV_STRUCT_DOWN:
			var st: Dictionary = _snap[a]
			g._sv += 1
			if st.o == g.PLAYER:
				g.notify("%s knocked your %s down to level %d" % [g._nname(b), g.build_data[st.k][1], int(ev[k + 3])], "bad")
		EV_BOATS_SCALE:
			var f: float = ev[k + 2]
			for bt in g.boats:
				if bt.a == a: bt.troops *= f
		EV_BOATS_WARHEAD:
			var cap: float = ev[k + 3]
			var kk := R.k_area
			for bt in g.boats:
				if bt.a != a: continue
				var bt_t: float = bt.troops
				for _i in b:
					var d3 := minf(kk * SimRules.warhead_death(bt_t, cap, R.ts), maxf(0.0, bt_t - 0.03 * cap))
					if d3 <= 0.0: break
					bt_t -= d3
				bt.troops = bt_t
		EV_GRUDGE_SET:
			var n: Dictionary = g.nations[a]
			n["grudge_" + str(b)] = int(ev[k + 3])
			if int(ev[k + 4]) >= 0: n["attacked_tick"] = int(ev[k + 4])
		EV_LAST_BY:
			g.nations[a]["last_by"] = b
		EV_STRIKE_FX:
			_strike_fx(a, b, int(ev[k + 3]))
		EV_SAM_FIRED:
			var ms: Dictionary = _by_mid[a]
			var st: Dictionary = _snap[b]
			var kk := int(ev[k + 3])
			ms["sam_st"] = st
			ms["sam_hit"] = int(ev[k + 4])
			ms["sam_k"] = kk
			sam_shots.append({"from": tpos(st.tile, W), "ms": ms, "k": kk, "t0": now(), "t1": ms.sam_hit, "o": st.o})
			if st.o == g.PLAYER or ms.o == g.PLAYER: g.sfx("sam_shoot", 0.0, 0.04, g.PLAYER)
		EV_SAM_HIT:
			_sam_hit_fx(_by_mid[a], b)
		EV_SAM_CLEAR:
			var ms: Dictionary = _by_mid[a]
			ms["sam_st"] = null
			if b != 0: ms["cand_tick"] = now()
		EV_DETONATE:
			_detonate_fx(_by_mid[a], b, int(ev[k + 3]))
		EV_FALLOUT_VIEW:
			for c in range(a, a + b):
				var tt: int = _cur_ft[c]
				g.fallout_t[tt] = 60.0; g.fallout_hot[tt] = true
				if g.fallout_glow != null: g.fallout_glow.on_fallout(tt)
				g._repaint(tt)
		EV_UNITS_BLAST:
			var cc := Vector2(a, b)
			var r2: float = ev[k + 3]
			for ws in g.warships.duplicate():
				if ws.pos.distance_squared_to(cc) <= r2: SimWarships.erase_ref(g.warships, ws)
			for bt in g.boats.duplicate():
				var bp: Vector2 = g._boat_pos(bt)[0] / g.TS
				if bp.distance_squared_to(cc) <= r2: SimWarships.erase_ref(g.boats, bt)
			for tr in g.traders.duplicate():
				var tp: Vector2 = g._path_pos(tr)[0] / g.TS
				if tp.distance_squared_to(cc) <= r2: SimWarships.erase_ref(g.traders, tr)
		EV_BREAK:
			g.break_alliance(a, b)

# strike()'s effects after the damage (blast ring, sounds, notes, shake)
func _strike_fx(nk: int, to: int, shooter: int) -> void:
	var W: int = g.W
	var radius := R.strike_radius(nk)
	var c := tpos(to, W)
	var vis_r := maxf(1.5, radius)
	g.blasts.append({"pos": c * g.TS, "r": vis_r * g.TS, "t": 0.0, "dur": 0.55 if nk == SimRules.N_SHELL else 0.9, "seed": to * 2654435761 % 100000, "kind": "sam"})
	var victim: int = g.owner_map[to]
	var mine: bool = victim == g.PLAYER or shooter == g.PLAYER
	var near: bool = g._world_on_screen(c * g.TS)
	if nk == SimRules.N_SHELL:
		if near:
			g.sfx("atom_hit", -6.0 if mine else -11.0, 0.08, g.PLAYER if mine else shooter, c * g.TS)
	else:
		if victim == g.PLAYER and shooter != g.PLAYER:
			g.notify("%s from %s hit your land" % ["An air strike" if nk == SimRules.N_AIRSTRIKE else "A railgun slug", g._nname(shooter)], "bad")
		if near or mine:
			g.sfx("atom_hit", -10.0, 0.06, g.PLAYER if mine else shooter, c * g.TS)
			if mine:
				g._add_shake(1.2)

# sam_resolve()'s effects of a hit (the missile is already gone from Luau's list)
func _sam_hit_fx(ms: Dictionary, sam_o: int) -> void:
	ms["shot_down"] = true  # (read by the client's alert banner: it turns green)
	var f := clampf(float(int(ms.get("sam_k", 0))) / float(flight_ticks(ms)), 0.0, 1.0)
	var ip: Vector2 = g._missile_world_pos(ms, f) / g.TS
	g._viewer_event({"type": "sam", "actor": sam_o, "target": ms.o, "point": ip}, [sam_o, ms.o])
	if g.fx_layer != null:
		g.fx_layer.pop(int(floor(ip.y)) * g.W + int(floor(ip.x)), Color(1, 0.85, 0.5))
		g.fx_layer.burst("sam", ip.x, ip.y)
	if sam_o == g.PLAYER or ms.o == g.PLAYER:
		g.sfx("sam_hit", 0.0, 0.04, g.PLAYER)
	if int(ms.get("nk", 0)) != SimRules.N_WARHEAD:
		var title: String = g.build_data[ms.k][1]
		if sam_o == g.PLAYER: g.notify("Your SAM shot down %s from %s" % [title, g._nname(ms.o)], "good")
		elif ms.o == g.PLAYER: g.notify("Your %s was intercepted by %s" % [title, g._nname(sam_o)], "bad")

# game/nukes.gd _detonate_missile + detonate after the blast (effect, shake, viewer event, sound, notes)
func _detonate_fx(ms: Dictionary, victim: int, tile: int) -> void:
	var nk: int = int(ms.nk)
	var to: Vector2 = ms.to
	var r := float(ms.r)
	if g.fx_layer != null: g.fx_layer.nuke(nk, tile, r)
	g._fx_shake_at(to, 0.9 if nk in [SimRules.N_HYDROGEN, SimRules.N_MEGA] else 0.5)
	g._viewer_event({"type": "nuke_hit", "actor": ms.o, "target": victim, "kind": ms.k, "nk": nk, "tile": tile, "radius": ms.r})
	var P: int = g.PLAYER
	var mine: bool = ms.o == P or g.owner_map[tile] == P or victim == P
	g.sfx("hydrogen_hit" if ms.k in [8, 11] and nk != SimRules.N_WARHEAD else "atom_hit", 0.0 if mine else -8.0, 0.04, P if mine else ms.o, to * g.TS)
	if victim > 0 and nk != SimRules.N_WARHEAD and victim == P and ms.o != P:
		g.notify("A %s from %s hit your land" % [g.build_data[ms.k][1], g._nname(ms.o)], "bad")
	if nk == SimRules.N_HYDROGEN and victim != P:
		g.notify("Hydrogen bomb detonated over %s" % g._nname(victim), "info")

## sim tick through Luau; false when Luau is off (the GDScript tick runs)
func _luau_tick() -> bool:
	var lu := lu_on()
	if lu == null: return false
	return _lrun(lu, "tick", [], not munitions.is_empty(), false) != null

## game/nukes.gd _tick_missiles through Luau; false when Luau is off. Missiles not due this tick need no call.
func luau_missiles() -> bool:
	var lu := lu_on()
	if lu == null: return false
	var t := now()
	var due := false
	var wh := false
	for ms in g.missiles:
		if not ms.has("lt"): continue
		ms.t = float(t - int(ms.lt)) * DT_TICK
		if (ms.get("sam_st") != null and t >= int(ms.get("sam_hit", 1 << 60))) or t >= int(ms.lt) + int(ms.ft):
			due = true
			if int(ms.nk) == SimRules.N_WARHEAD: wh = true
	if not due: return true
	return _lrun(lu, "missiles", [], true, wh) != null

## game/nukes.gd launch_nuke's missile (and a Scattershot's warheads, the ICBM roll) through Luau; {} when off
func luau_launch(o: int, k: int, nk: int, silo_tile: int, tile: int, r: float, icbm: bool, victim: int) -> Dictionary:
	var lu := lu_on()
	if lu == null: return {}
	var mid = _lrun(lu, "launch", [o, k, nk, silo_tile, tile, r, icbm, victim], true, false)
	if mid == null: return {}
	return _by_mid.get(int(mid), {})
