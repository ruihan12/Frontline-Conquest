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
	var passed := submitted and yielded > 0 and finished and second and recovered and map_invalidated and mirror_updated
	print("LIVE_ATTACK_WORKER ", "PASS" if passed else "FAIL")
	game.queue_free()
	await process_frame
	quit(0 if passed else 1)
