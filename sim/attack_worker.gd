extends RefCounted
## One in-flight conquest pass. The scene thread owns capture and replay.

const Job = preload("res://sim/attack_worker_job.gd")
var prepare_ai_scans := false
var prepare_batteries := false
var prepare_rails := false
var prepare_warships := false
var _task := -1
var _joined := false
var _job: Job
var _signature: Array
var _mirror_owners := PackedInt32Array()
var _mirror_fallout := PackedByteArray()
var _dirty_tiles := PackedInt32Array()

func record_tile(tile: int) -> void:
	if not _mirror_owners.is_empty() or pending():
		_dirty_tiles.append(tile)

func record_tiles(tiles: PackedInt32Array) -> void:
	if not _mirror_owners.is_empty() or pending():
		_dirty_tiles.append_array(tiles)

func pending() -> bool:
	return _task >= 0

func ready() -> bool:
	return pending() and (_joined or WorkerThreadPool.is_task_completed(_task))

func submit(game) -> bool:
	if pending() or game.attacks.is_empty() or game.team_mode or game.net_host != null or game.net_remote \
			or not game.tile_pop.is_empty() or game.border.size() != game.nations.size():
		return false
	_signature = _state_signature(game)
	if _mirror_owners.size() == game.owner_map.size():
		for tile: int in _dirty_tiles:
			_mirror_owners[tile] = game.owner_map[tile]
			_mirror_fallout[tile] = game.fallout[tile]
	_dirty_tiles = PackedInt32Array()
	_job = Job.new(game, _mirror_owners, _mirror_fallout, prepare_ai_scans)
	_job.prepare_render_tiles = game._tile_snapshot_valid
	if game._economy_worker != null:
		_job.economy = EconomyWorker.capture(game, 0.1)
	if prepare_batteries:
		_job.capture_arsenal(game)
		_job.sam_plans = game.sim_ars.capture_sam_plans(_job.tick + 1)
	if prepare_rails:
		_job.capture_rail_inputs(game)
	if prepare_warships:
		_job.capture_warship_inputs(game)
		_job.capture_warship_steering(game)
	_mirror_owners = PackedInt32Array()
	_mirror_fallout = PackedByteArray()
	_task = WorkerThreadPool.add_task(_job.run)
	if not pending():
		_job = null
		_signature = []
	return pending()

## Used by benchmarks and teardown. The live scheduler polls ready() instead.
func wait() -> void:
	if pending() and not _joined:
		WorkerThreadPool.wait_for_task_completion(_task)
		_joined = true

func take(game) -> bool:
	assert(ready())
	if not _joined:
		wait()
	var job := _job
	var signature := _signature
	_clear()
	if game.net_host != null or game.net_remote or job.tick != game.sim_atk.tick + 1 \
			or signature != _state_signature(game):
		return _reject(job)
	# Player-facing structure capture audio can consume the gameplay RNG.
	# Other captures can replay their ownership changes in the original order.
	for tile in job.player_capture_tiles:
		if game.struct_at.has(tile):
			return _reject(job)
	var prepared_tiles: bool = game._tile_snapshot_valid and not job.render_tiles.is_empty()
	for i in range(0, job.captures.size(), 2):
		game._set_owner(job.captures[i], job.captures[i + 1], true, not prepared_tiles)
	if prepared_tiles:
		game._tile_snapshot_worker_packets.append(job.render_tiles)
	if not job.captures.is_empty():
		game._attack_map_revision += 1
	for i in game.nations.size():
		var nation: Dictionary = game.nations[i]
		nation.merge(job.nations[i], true)
	game.attacks.assign(job.attacks)
	game.rng.state = job.rng.state
	game.sim_atk.tick = job.tick
	game.sim_atk.next_aid = job.next_aid
	game.sim_atk.merges.clear()
	for values: Array in job.player_conquests:
		game._map_effect("conquest", values)
	var pressure: Variant = null
	if job.pressure != null and job.transport_orders == SimAI.transport_orders(game.boats):
		pressure = job.pressure
	game.sim_ai.accept_tick_preparation(job.tick, job.standings, pressure)
	game.sim_ai.accept_border_scans(job.tick, game._attack_map_revision, job.border_scans)
	game._prepared_economy = job.economy
	if not job.battery_targets.is_empty():
		game.sim_ars.accept_battery_targets(job.tick, job.structure_revision, job.alliances, job.battery_radius, job.battery_targets)
	if prepare_batteries:
		game.sim_ars.accept_sam_plans(job.tick, job.sam_plans)
		game.sim_ars.accept_strike_scans(job.tick, game._attack_map_revision, job.structure_revision, job.strike_scans)
	if prepare_rails:
		game._publish_rail_geometry(job.rail_curves, job.rail_station_edges, job.rail_scale)
		game._prepared_train_steps = job.train_steps
		game._prepared_train_tick = job.tick
	if prepare_warships:
		game.sim_ws.accept_steering_steps(job.tick, job.steering_graph_id, job.steering_graph_revision, job.steering_steps)
		game.sim_ws.accept_transport_targets(job.tick, job.transport_range, job.alliances, job.transport_inputs, job.transport_targets)
		game.sim_ws.accept_post_transport_targets(job.post_targets)
		game.sim_ws.accept_shore_checks(job.tick, game._attack_map_revision, job.shore_distance, job.shore_checks)
		game.sim_ws.accept_trade_targets(job.transport_range, job.patrol_range, job.alliances, job.trade_targets)
	_mirror_owners = job.owner_map
	_mirror_fallout = job.fallout
	_dirty_tiles = PackedInt32Array()
	for key in job.counters:
		game._pf_add(key, job.counters[key])
	return true

func _reject(job: Job) -> bool:
	# The worker wrote only its captured tiles. Resync those, together with
	# scene-side mutations already in the journal, from the authoritative map.
	_mirror_owners = job.owner_map
	_mirror_fallout = job.fallout
	for i in range(0, job.captures.size(), 2):
		_dirty_tiles.append(job.captures[i])
	return false

func stop() -> void:
	wait()
	_clear()
	_mirror_owners = PackedInt32Array()
	_mirror_fallout = PackedByteArray()
	_dirty_tiles = PackedInt32Array()

func _clear() -> void:
	_task = -1
	_joined = false
	_job = null
	_signature = []

static func _state_signature(game) -> Array:
	var rules: SimRules = game.sim_rules
	return [game.W, game.H, game.rng.state, game.sim_atk.tick, game.sim_atk.next_aid, game.fallout_count, game.land_total,
		game._attack_map_revision, hash(game.nations), hash(game.attacks),
		hash(game.allies), hash(game.traitor), hash(game.def_posts), hash(game._kind_cache),
		hash(game.sim_atk.merges), game.team_mode, game.tile_pop.size(),
		rules.k_lin, rules.k_area, rules.ts, rules.max_tiles_per_tick, rules.defense_range,
		rules.log_mid, hash(rules.priority_f4)]
