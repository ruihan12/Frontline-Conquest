extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var sim = load("res://sim/headless_sim.gd").new(self)
	await sim.ready_async()
	var game = sim.m
	game.set_process(false)
	game.rng.seed = 12345
	seed(12345)
	sim.start()
	game._attack_worker = game.AttackWorker.new()
	game._ai(0.1)
	if game.attacks.is_empty():
		print("LIVE_ATTACK_WORKER FAIL: fixture has no attacks")
		game.queue_free()
		quit(1)
		return
	var before: int = game.sim_atk.tick
	var old_owner := hash(game.owner_map)
	game._advance_fixed_ticks(0.1)
	var submitted: bool = game._tick_stage == 3 and game._attack_worker.pending() \
		and game.sim_atk.tick == before and hash(game.owner_map) == old_owner
	var yielded := 0
	while game._tick_stage != 0 and yielded < 600:
		await process_frame
		yielded += 1
		game._advance_fixed_ticks(0.0)
	var finished: bool = game._tick_stage == 0 and game.sim_atk.tick == before + 1 \
		and not game._attack_worker.pending() and game._attack_worker_applied == 1
	var changed: int = game.owner_map.find(0)
	game._set_owner(changed, game.PLAYER)
	game._advance_fixed_ticks(0.1)
	while game._attack_worker.pending() and not game._attack_worker.ready():
		await process_frame
	var mirror_updated: bool = game._attack_worker.ready() and game._attack_worker._job.owner_map[changed] == game.PLAYER
	var second: bool = game._tick_stage == 3
	game.rng.randi()  # external mutation must invalidate the copied pass
	while game._tick_stage != 0 and yielded < 1200:
		await process_frame
		yielded += 1
		game._advance_fixed_ticks(0.0)
	var recovered: bool = game._tick_stage == 0 and game.sim_atk.tick == before + 2 \
		and game._attack_worker_applied == 1
	game._rebuild_def_posts()
	var map_job: bool = game._attack_worker.submit(game)
	var neutral: int = game.owner_map.find(0)
	game._set_owner(neutral, 0)
	while map_job and not game._attack_worker.ready() and yielded < 1800:
		await process_frame
		yielded += 1
	var map_invalidated: bool = map_job and game._attack_worker.ready() and not game._attack_worker.take(game)
	var structure_replayed := _check_structure_capture(game, 3)
	var player_structure_deferred := _check_structure_capture(game, game.PLAYER)
	var conquest_replayed := _check_player_conquest(game)
	var merge_replayed := _check_pending_merge(game)
	var merge_restarted := _check_ended_merge(game)
	var preparation_matches := _check_ai_preparation(game)
	var scans_match := _check_ai_border_scan(game)
	var tribe_scan_matches := _check_tribe_shore_scan(game)
	var battery_matches := _check_battery_preparation(game)
	var sam_matches := _check_sam_preparation(game)
	var rails_match := _check_rail_preparation(game)
	var shore_matches := _check_shore_preparation(game)
	var trader_matches := _check_trader_preparation(game)
	var steering_matches := _check_warship_steering(game)
	var posts_match := _check_post_transport_preparation(game)
	var strikes_match := _check_strike_preparation(game)
	var passed := submitted and yielded > 0 and finished and second and recovered \
		and map_invalidated and mirror_updated and structure_replayed and player_structure_deferred \
		and conquest_replayed and merge_replayed and merge_restarted and preparation_matches and scans_match \
		and tribe_scan_matches and battery_matches and sam_matches and rails_match and shore_matches and trader_matches \
		and steering_matches and posts_match and strikes_match
	print("LIVE_ATTACK_WORKER ", "PASS" if passed else "FAIL")
	game.queue_free()
	await process_frame
	quit(0 if passed else 1)

func _check_structure_capture(game, defender: int) -> bool:
	# Put a city on a target adjacent to a bot, then begin the
	# pass with the city tile already chewed so capture is guaranteed.
	const ATTACKER := 2
	var tile := -1
	for border_tile: int in game.border[ATTACKER]:
		var right := border_tile + 1
		if right % game.W != 0 and game.owner_map[right] == 0 and not game.struct_at.has(right):
			tile = right
			break
	if tile < 0:
		return false
	game.attacks.clear()
	game.sim_atk.merges.clear()
	game._set_owner(tile, defender)
	game._struct_add(0, tile, defender)
	var city: Dictionary = game.struct_at[tile]
	city.hits = 2
	var attack = game.sim_atk.start(ATTACKER, defender, 100000.0)
	if attack == null:
		return false
	attack.head = tile
	attack.chew = game.sim_rules.k_area
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game):
		return false
	var rng_before: int = game.rng.state
	game.rng.randi()
	game._attack_worker.wait()
	if game._attack_worker.take(game) or game.owner_map[tile] != defender or city.o != defender:
		return false
	game.rng.state = rng_before
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	var applied: bool = game._attack_worker.take(game)
	if defender == game.PLAYER:
		return not applied and game.owner_map[tile] == defender and city.o == defender and city.hits == 2
	return applied and game.owner_map[tile] == ATTACKER \
		and city.o == ATTACKER and city.hits == 0

func _check_player_conquest(game) -> bool:
	var tile := -1
	for border_tile: int in game.border[game.PLAYER]:
		var right := border_tile + 1
		if right % game.W != 0 and game.owner_map[right] == 0:
			tile = right
			break
	if tile < 0:
		return false
	game.attacks.clear()
	game.sim_atk.merges.clear()
	var victim: int = game._new_nation("Worker conquest fixture", Color.RED, true)
	game._set_owner(tile, victim)
	game.nations[victim].gold = 1234.0
	game.tile_snapshot = game.TileSnapshot.new()
	game._publish_tile_snapshot()
	var attack = game.sim_atk.start(game.PLAYER, victim, 100000.0)
	if attack == null:
		return false
	attack.head = tile
	attack.chew = game.sim_rules.k_area
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	game._begin_presentation_batch()
	var applied: bool = game._attack_worker.take(game)
	var event_replayed: bool = game._presentation_events.has(["map", "conquest", [victim, 0.0, 0.0, 1234.0]])
	game._flush_presentation_batch()
	var packet_ready: bool = game._tile_snapshot_worker_packets.size() == 1 \
		and game._tile_snapshot_dirty.is_empty() and game.tile_snapshot.owner(tile) == victim
	# A scene-side update recorded after replay must take precedence over the worker packet.
	game.fallout[tile] = 1
	game._record_tile_snapshot(tile)
	game._publish_tile_snapshot()
	var published: bool = game.tile_snapshot.owner(tile) == game.PLAYER and game.tile_snapshot.has_fallout(tile) \
		and game._tile_snapshot_worker_packets.is_empty() and game._tile_snapshot_dirty.is_empty()
	game.fallout[tile] = 0
	game._reset_tile_snapshot()
	game.tile_snapshot = null
	return applied and event_replayed and game.owner_map[tile] == game.PLAYER \
		and game.nations[victim].land == 0 and game.nations[victim].killer == game.PLAYER and packet_ready and published

func _check_pending_merge(game) -> bool:
	game.attacks.clear()
	game.sim_atk.merges.clear()
	# Hold the frontier in place so the only troop change is the pending order.
	game.sim_rules.max_tiles_per_tick = 0
	var attack = game.sim_atk.start(2, 0, 100000.0)
	if attack == null:
		return false
	attack.started = game.sim_atk.tick - 1
	game.sim_atk.start(2, 0, 321.0)
	if game.sim_atk.merges.size() != 1:
		return false
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game):
		return false
	var merged = game.sim_atk.attack_between(2, 0)
	return merged != null and merged.troops == 100321.0 and merged.pend == 0.0 \
		and game.sim_atk.merges.is_empty()

func _check_ended_merge(game) -> bool:
	var ended = game.sim_atk.attack_between(2, 0)
	if ended == null:
		return false
	game.sim_atk.end_attack(ended, false)
	ended.pend = 321.0
	game.sim_atk.merges.append(ended)
	# Keep one unrelated attack active so the production worker is eligible.
	if game.sim_atk.start(3, 0, 100000.0) == null:
		return false
	var new_id: int = game.sim_atk.next_aid
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game):
		return false
	var restarted = game.sim_atk.attack_between(2, 0)
	return restarted != null and restarted.aid == new_id and restarted.troops == 321.0 \
		and game.sim_atk.next_aid == new_id + 1 and game.sim_atk.merges.is_empty()

func _check_ai_preparation(game) -> bool:
	game.sim_ai.rank.clear()
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game):
		return false
	var standings := SimAI.collect_standings(game)
	var pressure := SimAI.collect_pressure(game, SimAI.transport_orders(game.boats))
	var prepared: bool = game.sim_ai._prepared_tick == game.sim_atk.tick \
		and game.sim_ai._prepared_leader == standings and game.sim_ai._prepared_pressure == pressure
	game.sim_ai.begin_tick()
	if not prepared or game.sim_ai.rank != standings[3] or game.sim_ai.attackers_on != pressure \
			or game.sim_ai._prepared_tick != -1:
		return false
	if not game._attack_worker.submit(game):
		return false
	var human_tile: int = game.owner_map.find(game.PLAYER)
	game.boats.append({"a": 2, "dest": human_tile})
	game._attack_worker.wait()
	if not game._attack_worker.take(game) or game.sim_ai._prepared_pressure != null:
		return false
	pressure = SimAI.collect_pressure(game, SimAI.transport_orders(game.boats))
	game.sim_ai.begin_tick()
	return game.sim_ai.attackers_on == pressure

func _check_ai_border_scan(game) -> bool:
	var id := 2
	var next_tick: int = game.sim_atk.tick + 1
	var ai_state: Dictionary = game.sim_ai.st[id]
	if game.kind_of(id) == SimRules.KIND_TRIBE:
		ai_state.attack_tick = next_tick % int(ai_state.attack_rate)
	else:
		ai_state.next_think = next_tick
	game._attack_worker.prepare_ai_scans = true
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game) or not game.sim_ai._prepared_border_scans.has(id):
		return false
	var reference_rng := RandomNumberGenerator.new()
	reference_rng.state = game.rng.state
	var expected := SimAI.collect_border(game, id, game.sim_rules.legacy_lin, reference_rng)
	game.sim_ai.scan_border(id)
	var actual := [game.sim_ai.sc_list, game.sim_ai.sc_count, game.sim_ai.sc_tile, \
		game.sim_ai.sc_neutral, game.sim_ai.sc_neutral_tile, game.sim_ai.sc_fallout_tile]
	if actual != expected.slice(0, 6) or game.rng.state != reference_rng.state \
			or game.sim_ai._prepared_border_scans.has(id):
		return false
	game.sim_ai.accept_border_scans(game.sim_atk.tick, game._attack_map_revision, {id: expected})
	var neutral_tile: int = game.owner_map.find(0)
	game._set_owner(neutral_tile, 0)
	game.sim_ai.scan_border(id)
	return game.sim_ai._prepared_border_scans.has(id)

class ShoreFixture:
	const WATER := -1
	const W := 12
	const H := 12
	var owner_map := PackedInt32Array()
	var fallout := PackedByteArray()
	var border := [{}, {}, {78: true}]

	func _init() -> void:
		owner_map.resize(W * H)
		owner_map.fill(2)
		fallout.resize(W * H)
		for tile in [66, 90, 77, 79]:
			owner_map[tile] = WATER
		owner_map[18] = 5
		owner_map[138] = 0
		owner_map[73] = 6
		owner_map[83] = 5

	func kind_of(_id: int) -> int:
		return SimRules.KIND_TRIBE

func _check_tribe_shore_scan(game) -> bool:
	var fixture := ShoreFixture.new()
	var scan := SimAI.collect_border(fixture, 2, 1.0, null, 1.0)
	if scan[7] != [[5, 0, 6], true]: return false
	fixture.fallout[138] = 1
	scan = SimAI.collect_border(fixture, 2, 1.0, null, 1.0)
	if scan[7] != [[5, 6], false]: return false
	var id := -1
	for candidate in range(2, game.nations.size()):
		if game.kind_of(candidate) == SimRules.KIND_TRIBE and game.nations[candidate].alive \
				and not game.border[candidate].is_empty():
			id = candidate
			break
	if id < 0: return false
	var state: Dictionary = game.sim_ai.st[id]
	state.attack_tick = (game.sim_atk.tick + 1) % int(state.attack_rate)
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	var ai: SimAI = game.sim_ai
	var prepared: Array = ai._prepared_border_scans.get(id, [])
	if prepared.size() < 8: return false
	var coasts: Dictionary = ai._prepared_coasts.duplicate()
	if not coasts.has(id): return false
	var worker_coast := ai.own_coast_tiles(id, 3)
	var worker_filtered := ai.own_coast_tiles(id, 9, true)
	var reads := ai.worker_coast_reads
	var revision: int = game._attack_map_revision
	var original_rng: int = game.rng.state
	ai.accept_border_scans(-1, -1, {})
	var coast_matches := ai.own_coast_tiles(id, 3) == worker_coast and ai.own_coast_tiles(id, 9, true) == worker_filtered
	ai.accept_border_scans(game.sim_atk.tick, revision - 1, {}, {id: [-100]})
	coast_matches = coast_matches and ai.own_coast_tiles(id, 3) == worker_coast and ai.worker_coast_reads == reads
	ai.accept_border_scans(-1, -1, {})
	var inline_neutral := ai._tribe_nearby(id)
	var inline_near := ai._near.duplicate()
	var inline_rng: int = game.rng.state
	game.rng.state = original_rng
	ai.accept_border_scans(game.sim_atk.tick, revision, {id: prepared})
	var worker_neutral := ai._tribe_nearby(id)
	var matched: bool = inline_neutral == worker_neutral and inline_near == ai._near \
		and inline_rng == game.rng.state and ai.worker_tribe_shore_count == 1
	game.rng.state = original_rng
	ai.accept_border_scans(game.sim_atk.tick, revision - 1, {id: prepared})
	var fallback_neutral := ai._tribe_nearby(id)
	return coast_matches and matched and fallback_neutral == inline_neutral and ai._near == inline_near \
		and ai.worker_tribe_shore_count == 1

func _check_battery_preparation(game) -> bool:
	var tile: int = game.owner_map.find(2)
	if tile < 0:
		return false
	var target := tile + 1
	var alternate: int = tile + game.W
	game._struct_add(10, tile, 2)
	game._struct_add(0, target, 3)
	game._struct_add(0, alternate, 4)
	var battery: Dictionary = game.struct_at[tile]
	battery.bt = 0.0
	battery.next_fire = game.sim_atk.tick + 1
	game._attack_worker.prepare_batteries = true
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game):
		return false
	game.sim_ars._battery_tick(game.sim_atk.tick)
	var used: bool = not game.sim_ars.munitions.is_empty() and game.sim_ars.munitions.back().tile == target \
		and game.sim_ars.worker_battery_count == 1
	game._struct_remove(game.struct_at[target])
	var recalculated: bool = game.sim_ars.battery_target(battery) == alternate and game.sim_ars.worker_battery_count == 1
	return used and recalculated

func _check_sam_preparation(game) -> bool:
	var tile: int = game.owner_map.find(2)
	while tile >= 0 and game.struct_at.has(tile):
		tile = game.owner_map.find(2, tile + 1)
	if tile < 0: return false
	game._struct_add(4, tile, 2)
	var station: Dictionary = game.struct_at[tile]
	station.bt = 0.0
	var aim := SimArsenal.tpos(tile, game.W)
	var destination := aim + Vector2(20, 0)
	var arc := {"pts": PackedVector2Array([aim, destination]), "lens": PackedFloat32Array([0, 20]), "length": 20.0}
	var missile := {"o": 3, "k": 7, "nk": SimRules.N_ATOM, "from": aim, "to": destination, "arc": arc,
		"lt": game.sim_atk.tick, "ft": 60, "dur": 1.2, "plan_fire": {}, "plan_k": {}}
	game.missiles.append(missile)
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	var arsenal: SimArsenal = game.sim_ars
	var plans: Array = arsenal._prepared_sam
	var tick: int = game.sim_atk.tick
	var inline := missile.duplicate(true)
	arsenal.accept_sam_plans(-1, [])
	arsenal._sam_plan(inline, station)
	arsenal.accept_sam_plans(tick, plans)
	arsenal._sam_plan(missile, station)
	var used: bool = arsenal.worker_sam_plans_used == 1 and missile.plan_fire.get(tile, -1) >= tick \
		and inline.plan_fire == missile.plan_fire and inline.plan_k == missile.plan_k and inline.traj == missile.traj
	station.level += 1
	arsenal._sam_plan(missile, station)
	arsenal.accept_sam_plans(-1, [])
	arsenal._sam_plan(inline, station)
	var recomputed: bool = arsenal.worker_sam_plans_used == 1 and inline.plan_fire == missile.plan_fire \
		and inline.plan_k == missile.plan_k
	station.level -= 1
	arsenal.accept_sam_plans(tick, plans)
	var hits_before: int = arsenal.stats.sam_hits
	arsenal._sam_tick(tick)
	var intercepted: bool = arsenal.worker_sam_plans_used == 2 and missile.get("shot_down", false) \
		and arsenal.stats.sam_hits == hits_before + 1
	game.missiles.erase(missile)
	arsenal.sam_shots.clear()
	game._struct_remove(station)
	if not used or not recomputed or not intercepted:
		print("SAM preparation fixture used=", used, " recomputed=", recomputed, " intercepted=", intercepted)
	return used and recomputed and intercepted

func _check_rail_preparation(game) -> bool:
	var leg := ceili(game.sim_rules.road_min_tiles()) + 4
	var start := -1
	var finish := -1
	for y in range(10, game.H - 10, 10):
		for x in range(0, game.W - leg, leg):
			var a: int = y * game.W + x
			var b := a + leg
			if not game.struct_at.has(a) and not game.struct_at.has(b) \
					and game._land_los(Vector2(x + 0.5, y + 0.5), Vector2(x + leg + 0.5, y + 0.5)):
				start = a
				finish = b
				break
		if start >= 0:
			break
	if start < 0:
		return false
	game._struct_add(2, start, 2)
	game._struct_add(0, finish, 2)
	game.struct_at[start].bt = 0.0
	game.struct_at[finish].bt = 0.0
	game._rail_bfs_left = 1
	var expected: Array = game._rail_curve(start, finish)
	var key := "r%d:%d" % [start, finish]
	game.rail_cache.erase(key)
	var factory: Dictionary = game.struct_at[start]
	var city: Dictionary = game.struct_at[finish]
	factory.last_spawn = game.sim_atk.tick
	factory.trucks = 3
	var continuing := {"o": 2, "fac": factory, "route": [factory, city, factory], "leg": 0,
		"src": factory, "dst": city, "t": 0.0, "dur": 1.0, "stops": 12}
	game.trains = [{"o": 2, "fac": factory, "route": [factory, city], "leg": 0,
		"src": factory, "dst": city, "t": 0.0, "dur": 1.0, "stops": 0},
		{"o": 2, "fac": factory, "route": [factory, city], "leg": 0,
		"src": factory, "dst": city, "t": 0.0, "dur": 1.0, "stops": 12}, continuing]
	game._attack_worker.prepare_rails = true
	if expected.is_empty() or not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game) or not game._prepared_rail_curves.has(key):
		return false
	var deferred: bool = game._rail_curve(start, finish).is_empty() and game._prepared_rail_curves.has(key)
	game._rail_bfs_left = 1
	game._rail_calc_left = 40
	var delayed: Dictionary = game.trains[1]
	delayed.dur = 5.0
	var gold: float = game.nations[2].gold
	game._trains_tick()
	return deferred and game._rail_worker_curves_used == 1 and game._rail_bfs_left == 0 \
		and game._rail_worker_edge_lists_used == 1 \
		and game.rail_cache.get(key) == expected and game.trains.size() == 2 and factory.trucks == 2 \
		and is_same(game.trains[0], delayed) and delayed.t == 1.0 and delayed.stops == 12 \
		and is_same(game.trains[1], continuing) and continuing.leg == 1 and continuing.stops == 13 \
		and is_same(continuing.dst, factory) and continuing.t == 0.0 \
		and game._rail_worker_train_steps_used == 2 and game._prepared_train_steps.is_empty() \
		and game.nations[2].gold == gold + SimRules.train_gold("self", 0) + SimRules.train_gold("self", 12)

func _check_shore_preparation(game) -> bool:
	var shore := -1
	for tile in game.sim_naval.coast_list:
		var nearby: int = game.sim_naval.water_next_to(tile)
		if game.sim_ws._shore_water(nearby):
			shore = nearby
			break
	if shore < 0:
		return false
	@warning_ignore("integer_division")
	var point := Vector2(shore % int(game.W) + 0.5, shore / int(game.W) + 0.5) * float(game.TS)
	var trader := {"d": 0.0, "pts": PackedVector2Array([point, point + Vector2.RIGHT]),
		"cum": PackedFloat32Array([0.0, 1.0])}
	game.traders = [trader]
	game.warships = [{"uid": posmod(-game.sim_atk.tick - 1, SimRules.SCAN_TICKS),
		"o": 3, "pos": point / float(game.TS), "shelled": {}}]
	game.boats = [{"a": 2, "uid": 1, "d": 0.0, "dest": shore, "pts": trader.pts.duplicate(), "cum": trader.cum.duplicate()}]
	var second: Dictionary = game.boats[0].duplicate(true)
	second.uid = 2
	game.boats.append(second)
	game._attack_worker.prepare_warships = true
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game):
		return false
	var used: bool = game.sim_ws._safe_from_pirates(trader, 0) and game.sim_ws.worker_shore_checks_used == 1
	trader.pts = PackedVector2Array()
	var recalculated: bool = not game.sim_ws._safe_from_pirates(trader, 0) and game.sim_ws.worker_shore_checks_used == 1
	var target = game.sim_ws._find_target(game.warships[0])
	var used_transport: bool = target != null and is_same(target.ref, game.boats[0]) and game.sim_ws.worker_transport_scans_used == 1
	game.warships[0].shelled[1] = true
	target = game.sim_ws._find_target(game.warships[0])
	var fallback: bool = target != null and is_same(target.ref, second) and game.sim_ws.worker_transport_scans_used == 1
	game.warships[0].shelled.clear()
	var ship: Dictionary = game.warships[0]
	ship.uid = posmod(-game.sim_atk.tick - 1, SimRules.SCAN_TICKS)
	# A live alliance changes which transports can be selected.
	if not game._attack_worker.submit(game):
		return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game):
		return false
	game.allies[game._akey(2, 3)] = game.sim_atk.tick + 100
	var alliance_fallback: bool = game.sim_ws._find_target(ship) == null and game.sim_ws.worker_transport_scans_used == 1
	return used and recalculated and used_transport and fallback and alliance_fallback

func _check_trader_preparation(game) -> bool:
	var port := -1
	var open_water := -1
	var width: int = game.W
	for tile: int in game.sim_naval.coast_list:
		if game.struct_at.has(tile): continue
		var coast: int = game.sim_naval.water_next_to(tile)
		if coast < 0: continue
		var body: int = game.sim_naval.body[coast]
		for step in [-width, width, -1, 1]:
			var water: int = coast + step
			if water < 0 or water >= game.owner_map.size() or game.sim_naval.body[water] != body \
					or game.sim_ws._shore_water(water):
				continue
			port = tile
			open_water = water
			break
		if port >= 0: break
	if port < 0: return false
	game._struct_add(1, port, 4)
	game.struct_at[port].bt = 0.0
	var position := SimArsenal.tpos(open_water, width)
	var point := position * float(game.TS)
	var trader := {"o": 2, "dst": {"o": 5}, "d": 0.0,
		"pts": PackedVector2Array([point, point + Vector2.RIGHT]), "cum": PackedFloat32Array([0.0, 1.0])}
	var alternate := trader.duplicate(true)
	game.traders = [trader, alternate]
	game.boats.clear()
	var ship := {"uid": posmod(-game.sim_atk.tick - 1, SimRules.SCAN_TICKS),
		"o": 4, "pos": position, "patrol": position, "shelled": {}}
	game.warships = [ship]
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	var target = game.sim_ws._find_target(ship)
	var matched: bool = target != null and is_same(target.ref, trader) and game.sim_ws.worker_trade_scans_used == 1
	trader.dst.o = 4
	target = game.sim_ws._find_target(ship)
	var fallback: bool = target != null and is_same(target.ref, alternate) and game.sim_ws.worker_trade_scans_used == 1
	if not matched or not fallback:
		print("Trade target fixture matched=", matched, " fallback=", fallback)
	return matched and fallback

func _check_warship_steering(game) -> bool:
	var nav: SimNav = game.sim_nav
	var width: int = game.W
	var tile := -1
	for candidate in range(0, nav.body.size() - 5):
		if candidate % width >= width - 5 or nav.body[candidate] == 0: continue
		if nav.body[candidate] == nav.body[candidate + 5]:
			tile = candidate
			break
	if tile < 0: return false
	game.traders.clear()
	var start := SimArsenal.tpos(tile, width)
	var target := start + Vector2(5, 0)
	var ship := {"o": 4, "pos": start, "tgt": target,
		"nav_r": PackedVector2Array([start, start + Vector2(0.5, 0), target]), "nav_t": target, "nav_i": 0}
	game.sim_ws.init_ship(ship)
	game.warships = [ship]
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	var step: float = game.sim_rules.warship_tiles_per_tick(false)
	var expected := ship.duplicate(true)
	var search_revision := nav.search_revision
	if not nav.steer(expected, step * game.warship_speed): return false
	game.sim_ws._move(ship, step)
	var used: bool = ship == expected and ship.nav_i == 2 and ship.pos == start + Vector2.RIGHT \
		and nav.search_revision == search_revision and game.sim_ws.worker_steering_steps_used == 1

	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	ship.tgt = target - Vector2.RIGHT
	expected = ship.duplicate(true)
	if not nav.steer(expected, step * game.warship_speed): return false
	game.sim_ws._move(ship, step)
	var stale: bool = ship == expected and game.sim_ws.worker_steering_steps_used == 1
	if not used or not stale:
		print("Warship steering fixture used=", used, " stale=", stale)
	return used and stale

func _check_post_transport_preparation(game) -> bool:
	var tile: int = game.owner_map.find(2)
	while tile >= 0 and game.struct_at.has(tile):
		tile = game.owner_map.find(2, tile + 1)
	if tile < 0: return false
	game._struct_add(3, tile, 2)
	var post: Dictionary = game.struct_at[tile]
	post.bt = 0.0
	game.warships.clear()
	var point := (SimArsenal.tpos(tile, game.W) + Vector2(5.0, 0)) * float(game.TS)
	var boat := {"a": 4, "uid": 1, "dest": tile, "d": 0.0,
		"pts": PackedVector2Array([point, point + Vector2(2.0, 0)]), "cum": PackedFloat32Array([0.0, 2.0])}
	var earlier := boat.duplicate(true)
	earlier.uid = 2
	game.boats = [earlier, boat]
	var sim: SimWarships = game.sim_ws
	sim._post_shelled[tile * SimWarships.POST_TRANSPORT_STRIDE + int(earlier.uid)] = true
	game.sim_atk.tick = ceili(float(game.sim_atk.tick + 1) / 10.0) * 10 - 1
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	var before := sim.shells.size()
	sim._posts_tick(game.sim_atk.tick)
	var used: bool = sim.worker_post_scans_used >= 1 and sim.shells.size() > before \
		and sim.shells.any(func(shell): return is_same(shell.shooter, post) and is_same(shell.target.ref, boat))
	if not used:
		print("Defense post fixture count=", sim.worker_post_scans_used)
		return false

	var scans := sim.worker_post_scans_used
	var replacement := boat.duplicate(true)
	replacement.uid = 3
	var alternate := boat.duplicate(true)
	alternate.uid = 4
	game.boats = [replacement, alternate]
	game.sim_atk.tick += ceili(float(SimRules.DEFENSE_POST_SHELL_TICKS + 1) / 10.0) * 10 - 1
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	replacement.pts = PackedVector2Array([point + Vector2(2000, 0), point + Vector2(2002, 0)])
	before = sim.shells.size()
	sim._posts_tick(game.sim_atk.tick)
	return sim.worker_post_scans_used == scans and sim.shells.slice(before).any(
		func(shell): return is_same(shell.shooter, post) and is_same(shell.target.ref, alternate))

func _check_strike_preparation(game) -> bool:
	const SHOOTER := 5
	const TARGET := 3
	const KIND := SimRules.N_AIRSTRIKE
	var center: int = game.owner_map.find(TARGET)
	while center >= 0 and game.struct_at.has(center):
		center = game.owner_map.find(TARGET, center + 1)
	if center < 0: return false
	var arsenal: SimArsenal = game.sim_ars
	arsenal.munitions.clear()
	game._struct_add(0, center, TARGET)
	var building: Dictionary = game.struct_at[center]
	building.hp = 1000
	game.nations[TARGET].troops = 50000.0
	var impact := {"nk": KIND, "tile": center, "o": SHOOTER, "t1": game.sim_atk.tick + 1}
	arsenal.munitions.append(impact)
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	var radius: float = game.sim_rules.strike_radius(KIND)
	var hits := SimArsenal.strike_territory(center, radius, KIND, game.owner_map, game.W, game.H)
	var troops: float = game.nations[TARGET].troops
	var loss := SimRules.strike_kill(KIND, troops, hits[TARGET] * game.sim_rules.k_area, game.sim_rules.ts)
	arsenal._munitions_tick(game.sim_atk.tick)
	var prepared: bool = arsenal.worker_strike_territory_scans_used == 1 \
		and arsenal.worker_strike_structure_scans_used == 1 and building.hp == 400 \
		and loss > 0.0 and game.nations[TARGET].troops == troops - loss
	if not prepared:
		print("Strike fixture prepared=", prepared)
		return false

	impact.t1 = game.sim_atk.tick + 1
	arsenal.munitions.append(impact)
	game._rebuild_def_posts()
	if not game._attack_worker.submit(game): return false
	game._attack_worker.wait()
	if not game._attack_worker.take(game): return false
	game._struct_remove(building)
	game._set_owner(center, SHOOTER)
	game._struct_add(0, center, TARGET)
	var replacement: Dictionary = game.struct_at[center]
	replacement.hp = 1000
	arsenal._munitions_tick(game.sim_atk.tick)
	return arsenal.worker_strike_territory_scans_used == 1 and arsenal.worker_strike_structure_scans_used == 1 \
		and replacement.hp == 400
