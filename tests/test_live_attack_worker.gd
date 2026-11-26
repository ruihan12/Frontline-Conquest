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
	var merge_replayed := _check_pending_merge(game)
	var merge_restarted := _check_ended_merge(game)
	var preparation_matches := _check_ai_preparation(game)
	var scans_match := _check_ai_border_scan(game)
	var passed := submitted and yielded > 0 and finished and second and recovered \
		and map_invalidated and mirror_updated and structure_replayed and player_structure_deferred \
		and merge_replayed and merge_restarted and preparation_matches and scans_match
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
