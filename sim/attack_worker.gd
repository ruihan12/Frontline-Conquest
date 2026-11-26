extends RefCounted
## One in-flight conquest pass. The scene thread owns capture and replay.

const Job = preload("res://sim/attack_worker_job.gd")
var _task := -1
var _job: Job
var _signature: Array
var _mirror_owners := PackedInt32Array()
var _mirror_fallout := PackedByteArray()
var _dirty_tiles := PackedInt32Array()

func record_tile(tile: int) -> void:
	if not _mirror_owners.is_empty() or pending():
		_dirty_tiles.append(tile)


func pending() -> bool:
	return _task >= 0

func ready() -> bool:
	return pending() and WorkerThreadPool.is_task_completed(_task)

func submit(game) -> bool:
	if pending() or game.attacks.is_empty() or game.team_mode or not game.tile_pop.is_empty() \
			or not game.sim_atk.merges.is_empty():
		return false
	_signature = _state_signature(game)
	if _mirror_owners.size() == game.owner_map.size():
		for tile: int in _dirty_tiles:
			_mirror_owners[tile] = game.owner_map[tile]
			_mirror_fallout[tile] = game.fallout[tile]
	_dirty_tiles = PackedInt32Array()
	_job = Job.new(game, _mirror_owners, _mirror_fallout)
	_mirror_owners = PackedInt32Array()
	_mirror_fallout = PackedByteArray()
	_task = WorkerThreadPool.add_task(_job.run)
	if not pending():
		_job = null
		_signature = []
	return pending()

func take(game) -> bool:
	assert(ready())
	WorkerThreadPool.wait_for_task_completion(_task)
	var job := _job
	var signature := _signature
	_clear()
	if job.tick != game.sim_atk.tick + 1 or job.player_conquest or signature != _state_signature(game):
		return false
	for i in range(0, job.captures.size(), 2):
		if game.struct_at.has(job.captures[i]):
			return false
	for i in range(0, job.captures.size(), 2):
		game._set_owner(job.captures[i], job.captures[i + 1])
	for i in game.nations.size():
		var nation: Dictionary = game.nations[i]
		var result: Dictionary = job.nations[i]
		for field in result:
			if field not in ["lp", "ls"]:
				nation[field] = result[field]
	var visual := {}
	for attack: Dictionary in game.attacks:
		visual[attack.aid] = attack
	for attack: Dictionary in job.attacks:
		var old: Dictionary = visual.get(attack.aid, {})
		for field in ["disp", "vel", "shown"]:
			if old.has(field):
				attack[field] = old[field]
	game.attacks.assign(job.attacks)
	game.rng.state = job.rng.state
	game.sim_atk.tick = job.tick
	_mirror_owners = job.owner_map
	_mirror_fallout = job.fallout
	_dirty_tiles = PackedInt32Array()
	for key in job.counters:
		game._pf_add(key, job.counters[key])
	return true

func stop() -> void:
	if pending():
		WorkerThreadPool.wait_for_task_completion(_task)
	_clear()
	_mirror_owners = PackedInt32Array()
	_mirror_fallout = PackedByteArray()
	_dirty_tiles = PackedInt32Array()

func _clear() -> void:
	_task = -1
	_job = null
	_signature = []

static func _state_signature(game) -> Array:
	var nations := []
	for nation: Dictionary in game.nations:
		var record := nation.duplicate()
		record.erase("lp")
		record.erase("ls")
		nations.append(record)
	var attacks := []
	for attack: Dictionary in game.attacks:
		var record := attack.duplicate()
		for field in ["disp", "vel", "shown"]:
			record.erase(field)
		attacks.append(record)
	var rules: SimRules = game.sim_rules
	return [game.W, game.H, game.rng.state, game.sim_atk.tick, game.fallout_count, game.land_total,
		game._attack_map_revision, hash(nations), hash(attacks),
		hash(game.allies), hash(game.traitor), hash(game.def_posts), hash(game._kind_cache),
		not game.sim_atk.merges.is_empty(), game.team_mode, game.tile_pop.size(),
		rules.k_lin, rules.k_area, rules.ts, rules.max_tiles_per_tick, rules.defense_range,
		rules.log_mid, hash(rules.priority_f4)]
