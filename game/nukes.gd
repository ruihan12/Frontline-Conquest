extends "res://game/economy.gd"
# Nukes, MIRVs, Scattershot, fallout and SAM interception: a port of upstream RoWorld
# src/shared/Core/SimNukes.luau (launch, flight, MIRV split, detonation), SimArsenal.luau
# (_scatter_warheads) and Rules.luau (nuke arc, flight ticks, radii). AGPL-3.0, lukechatton/roworld.
#
# Flight is on the sim clock only: a missile carries its launch tick `lt` and flight time `ft` (ticks,
# Rules.nuke_arc_ticks), and it detonates on the sim tick lt + ft. Its position is the arc point at
# (tick - lt) / ft in map (tile) space; the renderer adds the fraction of the tick in progress and then
# applies the camera. Nothing here depends on zoom, viewport, frame rate or the render dt; the game
# speed slider only changes how many sim ticks run per second.
#
# Kept custom (user): the ICBM toggle (key I). While it is on, every bomb the player launches costs 10% more
# and has a 35% chance (ICBM_EVADE_P) to evade SAMs entirely, rolled once at launch with the sim RNG
# (main.rng). An evading missile ("evade": true) is never a SAM candidate, never planned, never intercepted.
# A MIRV rolls once for its bus and every warhead it splits into inherits that roll; a Scattershot's
# warheads likewise share the core's roll. (Upstream silos already reach the whole map, so ICBM lifts no range.)
#
# Missile dictionaries (main.missiles): {o, k (build id), nk (Defs.N_*), from, to (tile centres),
# lt, ft, t, dur (t / dur: the old missile-clock view, DT_TICK per tick), r (outer radius, tiles),
# arc, tgt_o, mirv, mirv_bus, branched, plus the SAM fields sim/arsenal.gd adds}.

# Vanilla: no nuke range. These stay for old callers (UI labels, tests).
func land_width() -> float:
	if _land_w < 0.0:
		var x0 := W; var x1 := -1
		for x in range(0, W, 2):
			for y in range(0, H, 4):
				if owner_map[y * W + x] != WATER:
					x0 = mini(x0, x); x1 = maxi(x1, x); break
		_land_w = float(maxi(x1 - x0 + 2, 64)) if x1 >= 0 else float(W)
	return _land_w
func nuke_range(_k: int) -> float:
	return INF
func nuke_range_label(_k: int) -> String:
	return "Whole map"

# ---------------------------------------------------------------- radii (Rules.NUKE_INNER/OUTER_FULL / K_LIN)
var _nuke_r_k := -1.0

# NUKE_R (build id -> outer radius in our tiles) follows upstream's radii for the map's k_lin; the Tab
# console may still edit it during a match. MIRV (9): a warhead's radius.
func _refresh_nuke_r() -> void:
	if sim_rules == null: return
	var kl: float = sim_rules.k_lin
	if is_equal_approx(kl, _nuke_r_k): return
	_nuke_r_k = kl
	NUKE_R = {7: SimRules.NUKE_OUTER_FULL[SimRules.N_ATOM] / kl, 8: SimRules.NUKE_OUTER_FULL[SimRules.N_HYDROGEN] / kl,
		9: SimRules.NUKE_OUTER_FULL[SimRules.N_WARHEAD] / kl, 11: SimRules.NUKE_OUTER_FULL[SimRules.N_MEGA] / kl,
		12: SimRules.NUKE_OUTER_FULL[SimRules.N_SCATTER] / kl}

func nuke_outer(k: int, nk: int) -> float:
	_refresh_nuke_r()
	if nk == SimRules.N_WARHEAD: return float(NUKE_R.get(9, sim_rules.nuke_radii(nk).y))
	return float(NUKE_R.get(k, sim_rules.nuke_radii(nk).y))

# ---------------------------------------------------------------- cost (Rules.nuke_cost) + ICBM fee
# o: the buyer. The ICBM fee is the local player's toggle, so it is charged to the player only
# (o < 0: the HUD asking for the player's price).
func nuke_cost(k: int, o := -1) -> float:
	var nk: int = SimRules.NUKE_KIND_OF.get(k, SimRules.N_ATOM)
	var base: float = SimRules.NUKE_COST[nk] + (SimRules.MIRV_COST_STEP * mirvs_launched if nk == SimRules.N_MIRV else 0.0)
	var fee := icbm_mode and (o < 0 or o == PLAYER)
	return base * ((1.0 + ICBM_FEE_PCT) if fee else 1.0)

func set_icbm(on: bool) -> void:
	icbm_mode = on
	if not save.has("settings"): save["settings"] = {}
	save.settings["icbm"] = on
	if build_btns.size() > 16: build_btns[16].queue_redraw()
	_update_hud()

# ---------------------------------------------------------------- launch site
# SimNukes.launch_nuke: the nearest (manhattan) finished silo with a loaded missile; bombs have no reach limit.
func nearest_silo(o: int, target: Vector2) -> Dictionary:
	var best := {}
	var bd := INF
	var tx := int(floor(target.x)); var ty := int(floor(target.y))
	for st in structs:
		if st.o == o and st.k == 5 and st.get("bt", 0.0) <= 0.0 and _ready_slots(st) > 0:
			var d := float(absi(st.tile % W - tx) + absi(st.tile / W - ty))
			if d < bd: bd = d; best = st
	return best

func silo_for(o: int, _k: int, tp: Vector2) -> Dictionary:
	return nearest_silo(o, tp)

func _any_silo_dist(o: int, tp: Vector2) -> float:
	var bd := INF
	for st in structs:
		if st.o == o and st.k == 5 and st.get("bt", 0.0) <= 0.0:
			bd = minf(bd, Vector2(st.tile % W + 0.5, st.tile / W + 0.5).distance_to(tp))
	return bd

# ---------------------------------------------------------------- flight (Rules.nuke_arc)
func _missile_arc(ms) -> Dictionary:
	var arc = ms.get("arc")
	if arc == null:
		arc = sim_rules.munition_arc(H, ms.from, ms.to, int(ms.get("nk", SimRules.N_ATOM)))
		ms["arc"] = arc
	return arc

# map position (world px) at arc fraction s
func _missile_world_pos(ms, s: float) -> Vector2:
	return SimRules.nuke_arc_at(_missile_arc(ms), s) * TS

func _missile_screen_pos(ms, s: float, _z := 1.0) -> Vector2:
	return _screen_of(_missile_world_pos(ms, s))

# Flight fraction for drawing: sim ticks flown plus the part of the tick in progress (tick_acc), never
# the render dt or the zoom.
func missile_frac(ms) -> float:
	if not ms.has("lt"): return clampf(float(ms.get("t", 0.0)) / maxf(0.001, float(ms.get("dur", 1.0))), 0.0, 1.0)
	var sub := 0.0 if sim_paused else clampf(tick_acc * 10.0, 0.0, 1.0)
	return clampf((float(sim_atk.tick - int(ms.lt)) + sub) / maxf(1.0, float(ms.ft)), 0.0, 1.0)

# SimNukes._spawn_nuke
func _spawn_missile(o: int, k: int, nk: int, from: Vector2, to: Vector2, ft: int, arc: Dictionary, extra := {}) -> Dictionary:
	var t0: int = sim_atk.tick
	var tile := int(to.y) * W + int(to.x)
	var ms := {"o": o, "k": k, "nk": nk, "from": from, "to": to, "lt": t0, "ft": maxi(1, ft),
		"t": 0.0, "dur": float(maxi(1, ft)) * SimArsenal.DT_TICK, "r": nuke_outer(k, nk), "arc": arc,
		"tgt_o": owner_map[tile] if tile >= 0 and tile < W * H else -1,
		"mirv": nk == SimRules.N_MIRV, "mirv_bus": nk == SimRules.N_MIRV, "branched": nk == SimRules.N_WARHEAD, "evade": false}
	ms.merge(extra, true)
	missiles.append(ms)
	return ms

static func _tc(tile: int, w: int) -> Vector2:
	return Vector2(tile % w + 0.5, tile / w + 0.5)

# ---------------------------------------------------------------- launch (SimNukes.launch_nuke)
func launch_nuke(o: int, k: int, tile: int) -> bool:
	if not k in NUKES or tile < 0 or tile >= W * H: return false
	if k == 9 and not mirv_enabled: return false
	_refresh_nuke_r()
	var nk: int = SimRules.NUKE_KIND_OF.get(k, SimRules.N_ATOM)
	var victim: int = owner_map[tile]
	if victim == o:
		if o == PLAYER: notify("You can't nuke your own land", "info")
		return false
	if victim > 0 and allied(o, victim):
		if o == PLAYER: notify("You can't nuke an ally", "info")
		return false
	var cost: float = nuke_cost(k, o)
	var nm: String = build_data[k][1]
	if nations[o].gold < cost:
		if o == PLAYER: notify("Not enough gold for %s" % nm, "info")
		return false
	var tp := _tc(tile, W)
	var silo := nearest_silo(o, tp)
	if silo.is_empty():
		if o == PLAYER: notify("No missile silo is ready", "info")
		return false
	nations[o].gold -= cost
	_use_slot(silo, 0.0 if (o == PLAYER and (god_mode or no_cd)) else 1.0)
	var from := _tc(int(silo.tile), W)
	var arc: Dictionary = sim_rules.munition_arc(H, from, tp, nk)
	var ms := _spawn_missile(o, k, nk, from, tp, sim_rules.nuke_arc_ticks(arc, nk), arc)
	ms.tgt_o = victim
	# ICBM: one roll per launch (sim RNG), player only, never with the toggle off
	ms["evade"] = icbm_mode and o == PLAYER and rng.randf() < ICBM_EVADE_P
	if nk == SimRules.N_MIRV:
		mirvs_launched += 1
	elif nk == SimRules.N_SCATTER:
		_scatter_warheads(o, k, from, tile, int(ms.ft), bool(ms.evade))
	if victim > 0:
		nations[victim]["grudge_" + str(o)] = sim_atk.tick + SimRules.NUKE_GRUDGE_TICKS
		nations[victim]["attacked_tick"] = sim_atk.tick
	if o == PLAYER: notify("%s launched at %s" % [nm, _nname(victim)], "info")
	elif victim == PLAYER: notify("%s launched a %s at you!" % [_nname(o), nm], "bad")
	elif nk != SimRules.N_ATOM: notify("%s launched a %s at %s" % [_nname(o), nm, _nname(victim)], "info")
	if nk != SimRules.N_MIRV:
		for ow in sim_ars.break_nuked_alliances(o, tp, float(ms.r), nk):
			if ow == PLAYER or o == PLAYER: notify("The %s launch ended the alliance between %s and %s" % [nm, _nname(o), _nname(ow)], "bad")
	var lk := "mirv_launch" if k == 9 else ("hydrogen_launch" if k in [8, 11] else "atom_launch")
	sfx(lk, 0.0 if o == PLAYER else -8.0, 0.04, o)
	if victim == PLAYER and o != PLAYER: sfx("nuke_warning")
	return true

# SimArsenal._scatter_warheads: SCATTER_MIN..MAX warheads evenly around the aim (a random turn, +-0.3 rad
# jitter), SCATTER_NEAR..FAR tiles out, never onto the launcher's or an ally's land; each flies its own
# arc from the silo and lands 2 ticks after the last (never before the core).
func _scatter_warheads(o: int, k: int, from: Vector2, aim: int, flight: int, evade := false) -> void:
	var fired := 0
	for wp in sim_ars.scatter_targets(o, _tc(aim, W)):
		fired += 1
		var arc: Dictionary = sim_rules.nuke_arc(H, from, wp)
		var ft := maxi(flight, sim_rules.nuke_arc_ticks(arc, SimRules.N_SCATTER)) + fired * 2
		_spawn_missile(o, k, SimRules.N_WARHEAD, from, wp, ft, arc, {"evade": evade})

# ---------------------------------------------------------------- per tick (SimNukes.nukes_tick)
# Called once per sim tick, after sim_ars.tick() (SimNukes._sam_tick). `_dt` is ignored: flight is
# counted in ticks.
func _tick_missiles(_dt := 0.0) -> void:
	if missiles.is_empty(): return
	var t: int = sim_atk.tick
	for ms in missiles.duplicate():
		if not ms.has("lt"): continue  # (a screenshot prop)
		ms.t = float(t - int(ms.lt)) * SimArsenal.DT_TICK
		if ms.get("sam_st") != null and t >= int(ms.get("sam_hit", 1 << 60)) and sim_ars.sam_resolve(ms): continue
		if t < int(ms.lt) + int(ms.ft): continue
		missiles.erase(ms)
		if int(ms.nk) == SimRules.N_MIRV:
			_split_mirv(ms)
		else:
			_detonate_missile(ms)

func _detonate_missile(ms) -> void:
	var nk: int = int(ms.nk)
	var to: Vector2 = ms.to
	var tile := int(to.y) * W + int(to.x)
	if tile < 0 or tile >= W * H: return
	var victim: int = int(ms.get("tgt_o", owner_map[tile]))
	detonate(ms.o, to, float(ms.r), 1.0, nk)
	var mine: bool = ms.o == PLAYER or owner_map[tile] == PLAYER or victim == PLAYER
	sfx("hydrogen_hit" if ms.k in [8, 11] and nk != SimRules.N_WARHEAD else "atom_hit", 0.0 if mine else -8.0, 0.04, PLAYER if mine else ms.o)
	if victim > 0 and nk != SimRules.N_WARHEAD and victim == PLAYER and ms.o != PLAYER:
		notify("A %s from %s hit your land" % [build_data[ms.k][1], _nname(ms.o)], "bad")
	if nk == SimRules.N_HYDROGEN and victim != PLAYER:
		notify("Hydrogen bomb detonated over %s" % _nname(victim), "info")

# ---------------------------------------------------------------- MIRV (SimNukes._split_mirv)
# Up to MIRV_WARHEADS warheads, aimed at the target's land within MIRV_SPREAD of the aim point and at least
# 55 full-size tiles (manhattan) apart, leave the bus when it arrives; each flies the arc from the aim point
# at warhead speed plus 0..15 random ticks.
var _land_list := PackedInt32Array()
var _land_list_key := ""

func _mirv_land_list() -> PackedInt32Array:
	var key := "%d:%d:%d:%d" % [W, H, land_total, map_i]
	if key != _land_list_key or _land_list.is_empty():
		_land_list_key = key
		_land_list = PackedInt32Array()
		for i in W * H:
			if owner_map[i] >= 0: _land_list.append(i)
	return _land_list

static func _mirv_cell(t: int, w: int, gap: int) -> int:
	return ((t / w) / gap) * 65536 + ((t % w) / gap)

func _mirv_overlaps(grid: Dictionary, t: int, gap: int) -> bool:
	var gx := (t % W) / gap
	var gy := (t / W) / gap
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if gx + dx < 0 or gy + dy < 0: continue
			var cell = grid.get((gy + dy) * 65536 + (gx + dx))
			if cell == null: continue
			for c in cell:
				if absi(c % W - t % W) + absi(c / W - t / W) < gap: return true
	return false

func _split_mirv(ms) -> void:
	var o: int = ms.o
	var to: Vector2 = ms.to
	var to_tile := int(to.y) * W + int(to.x)
	var tg: int = int(ms.get("tgt_o", 0))
	if tg > 0 and allied(o, tg): break_alliance(o, tg)
	var spread: float = float(sim_rules.mirv_spread())
	var spread2 := spread * spread
	var gap := int(ceil(55.0 / sim_rules.k_lin))
	var grid := {}
	var targets := [to_tile]
	grid[_mirv_cell(to_tile, W, gap)] = [to_tile]
	var land := _mirv_land_list()
	var nlt := land.size()
	var tx := to_tile % W; var ty := to_tile / W
	for _i in 8000:
		if targets.size() >= SimRules.MIRV_WARHEADS or nlt == 0: break
		var c: int = land[g_randi() % nlt]
		if owner_map[c] != tg or tg <= 0: continue
		var dx := c % W - tx; var dy := c / W - ty
		if float(dx * dx + dy * dy) > spread2: continue
		if _mirv_overlaps(grid, c, gap): continue
		targets.append(c)
		var key := _mirv_cell(c, W, gap)
		if grid.has(key): grid[key].append(c)
		else: grid[key] = [c]
	var from := _tc(to_tile, W)
	for t in targets:
		var dp := _tc(t, W)
		var arc: Dictionary = sim_rules.nuke_arc(H, from, dp)
		var ft: int = sim_rules.nuke_arc_ticks(arc, SimRules.N_WARHEAD) + rng.randi_range(0, 15)
		_spawn_missile(o, 9, SimRules.N_WARHEAD, from, dp, ft, arc, {"mirv": true, "tgt_o": tg, "evade": bool(ms.get("evade", false))})

func g_randi() -> int:
	return rng.randi()

# ---------------------------------------------------------------- detonation (SimNukes._detonate)
# Inner disc + a random half of the outer ring -> fallout, nukeDeathFactor troop loss, everything inside
# the outer radius destroyed (sim/arsenal.gd nuke_blast). Then upstream's effect (FxLayer.nuke): shockwave
# ring, explosion burst, debris, and a small camera shake when the blast is on screen.
func detonate(o: int, c: Vector2, r: float, _eff_mult := 1.0, nk := SimRules.N_ATOM) -> void:
	sim_ars.nuke_blast(o, c, r, nk)
	var tile := clampi(int(c.y), 0, H - 1) * W + clampi(int(c.x), 0, W - 1)
	if fx_layer != null: fx_layer.nuke(nk, tile, r)
	_fx_shake_at(c, 0.9 if nk in [SimRules.N_HYDROGEN, SimRules.N_MEGA] else 0.5)

# MapCamera.add_shake(strength) when the tile is within 200 px of the screen: +-strength x 10 px.
func _fx_shake_at(c: Vector2, strength: float) -> void:
	if cam == null or not is_inside_tree(): return
	var sp := _screen_of(c * TS)
	var vp := get_viewport_rect().size
	if sp.x < -200 or sp.y < -200 or sp.x > vp.x + 200 or sp.y > vp.y + 200: return
	var sh_i := clampi(int(save.get("settings", {}).get("shake_i", 1)), 0, 2)
	shake_amp = maxf(shake_amp, strength * 10.0 * SHAKE_MULT[sh_i])
