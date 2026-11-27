extends SceneTree

const TrainWorker = preload("res://sim/train_worker.gd")

func _initialize() -> void:
	call_deferred("_run")

func _fixture():
	var game = load("res://main.tscn").instantiate()
	game.W = 96
	game.H = 32
	game.state = "play"
	game.owner_map.resize(game.W * game.H)
	game.owner_map.fill(1)
	game.owner_map[0] = 0
	game.nations = [{}, {"alive": true, "gold": 100.0}]
	game.sim_atk = SimAttacks.new(game, game.sim_rules)
	game.sim_naval = SimNaval.new(game, game.sim_rules)
	game.sim_atk.tick = 50
	var factory := {"k": 2, "o": 1, "tile": 96 * 12 + 25, "level": 1, "bt": 0.0, "trucks": 1}
	var city := {"k": 0, "o": 1, "tile": 96 * 12 + 60, "level": 1, "bt": 0.0}
	game.structs = [factory, city]
	game.struct_at = {factory.tile: factory, city.tile: city}
	game.trains = [{"o": 1, "fac": factory, "src": factory, "dst": city, "route": [factory, city],
		"leg": 0, "stops": 0, "t": 4.0, "dur": 5.0}]
	var rate := SimRules.train_spawn_rate(1, SimRules.TRAIN_UNITS)
	var random := RandomNumberGenerator.new()
	var trial_seed := 1
	random.seed = trial_seed
	while random.randi() % rate != 0:
		trial_seed += 1
		random.seed = trial_seed
	game.rng.seed = trial_seed
	return game

func _run() -> void:
	var game = _fixture()
	var reference = _fixture()
	var worker := TrainWorker.new()
	game._train_worker = worker
	var factory: Dictionary = game.structs[0]
	var original: Dictionary = game.trains[0]
	var before: int = game.rng.state
	var eligible := worker.submit(game)
	worker.wait()
	var isolated: bool = game.trains.size() == 1 and original.t == 4.0 and game.rng.state == before \
		and game.rail_cache.is_empty() and factory.trucks == 1 and game.nations[1].gold == 100.0
	reference._begin_presentation_batch()
	reference._trains_tick()
	game._begin_presentation_batch()
	var applied := eligible and worker.take(game)
	var expected_payout: float = SimRules.train_gold("self", 0)
	var correct: bool = applied and game.trains.size() == 1 and game.trains == reference.trains \
		and game.structs == reference.structs and game.rng.state == reference.rng.state \
		and game._presentation_events == reference._presentation_events and game._presentation_events.size() == 1 \
		and game.nations[1].gold == 100.0 + expected_payout and game.nations == reference.nations \
		and game.rail_cache == reference.rail_cache and game._rail_bfs_left == reference._rail_bfs_left \
		and game._rail_calc_left == reference._rail_calc_left and is_same(game.trains[0].fac, factory) \
		and is_same(game.trains[0].dst, game.structs[1]) and original.t == 5.0 \
		and is_same(game._rail_nb_cache[factory.tile][2][0], game.structs[1])
	game._flush_presentation_batch()
	reference._flush_presentation_batch()

	var pending := worker.submit(game)
	game._tick_stage = game.TRAIN_PHASE_PENDING
	var live_bfs: int = game._rail_bfs_left
	var cached: Array = game._rail_curve(factory.tile, game.structs[1].tile)
	var available: bool = not cached.is_empty() and game._rail_bfs_left == live_bfs
	game.nations[1].gold += 135.0
	worker.wait()
	var stale: bool = pending and not worker.take(game) and worker.inline_retries == 1 \
		and game.nations[1].gold == 235.0 + expected_payout
	game._tick_stage = 0
	pending = worker.submit(game)
	game._set_owner(0, game.WATER)
	worker.wait()
	var topology_changed: bool = pending and not worker.take(game) and game.owner_map[0] == game.WATER
	pending = worker.submit(game)
	game._stop_sim_workers()
	var stopped := pending and not worker.ready() and worker.applied_ticks == 1
	game.free()
	reference.free()
	var passed := isolated and correct and available and stale and topology_changed and stopped
	if not passed:
		print("train phase isolated=", isolated, " correct=", correct, " cached=", available,
			" stale=", stale, " topology=", topology_changed, " stopped=", stopped)
	print("TRAIN_WORKER ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
