extends RefCounted
## Runs a complete train tick with detached station and train records.

const RailSimulation = preload("res://sim/rail_simulation.gd")
const RecordCopies = preload("res://sim/detached_records.gd")

class Job extends RefCounted:
	const PLAYER := 1
	const TS := 2.0
	const RAIL_KINDS := [0, 1, 2]

	var W: int
	var H: int
	var tick: int
	var elapsed: float
	var owner_map: PackedInt32Array
	var sim_rules: SimRules
	var sim_naval: SimNaval
	var rng := RandomNumberGenerator.new()
	var structs: Array
	var struct_at := {}
	var trains: Array
	var starting_trains: Array
	var nations := []
	var attacks: Array
	var allies: Dictionary
	var embargoes: Dictionary
	var _own_sv: Dictionary
	var rail_cache: Dictionary
	var _rail_nb_cache: Dictionary
	var _rail_mst: Dictionary
	var _prepared_rail_curves: Dictionary
	var _prepared_rail_edges: Dictionary
	var _prepared_rail_scale: float
	var _rail_bfs_left: int
	var _rail_calc_left: int
	var _rail_frame: int
	var _rail_pending: bool
	var _rail_worker_curves_used := 0
	var _rail_worker_edge_lists_used := 0
	var _prepared_train_steps: Array = []
	var _prepared_train_tick := -1
	var _rail_worker_train_steps_used := 0
	var payouts: Array = []

	var sim_atk: Job:
		get: return self

	func _init(inputs: Dictionary, map: PackedInt32Array, clock: float, frame: int, bfs_left: int, calc_left: int) -> void:
		tick = inputs.tick
		W = inputs.width
		H = inputs.height
		elapsed = clock
		owner_map = map
		sim_rules = SimRules.new(inputs.scale)
		rng.state = inputs.rng_state
		structs = inputs.stations
		for station: Dictionary in structs:
			struct_at[station.tile] = station
		for row: Array in inputs.owners:
			nations.append({"alive": row[0], "gold": row[1]})
		trains = inputs.trains
		starting_trains = trains.duplicate()
		attacks = inputs.attacks
		allies = inputs.allies
		embargoes = inputs.embargoes
		_own_sv = inputs.owner_revisions
		rail_cache = inputs.curves
		_rail_nb_cache = inputs.neighbors
		_rail_mst = inputs.networks
		_prepared_rail_curves = inputs.prepared_curves
		_prepared_rail_edges = inputs.prepared_edges
		_prepared_rail_scale = inputs.prepared_scale
		_rail_frame = frame
		_rail_bfs_left = bfs_left
		_rail_calc_left = calc_left
		_rail_pending = inputs.rail_pending
		sim_naval = SimNaval.new(self, sim_rules)
		sim_naval._hp_tick = inputs.hostility_tick
		sim_naval._hp = inputs.hostility

	func allied(a: int, b: int) -> bool:
		return a > 0 and b > 0 and allies.has(mini(a, b) * 4096 + maxi(a, b))

	func is_embargoed(_a: int, _b: int) -> bool:
		return false

	func _emit_train_payout(position: Vector2, amount: float) -> void:
		payouts.append([position, amount])

	func run() -> void:
		RailSimulation._trains_tick(self)
		sim_naval.g = null

var _task := -1
var _joined := false
var _job: Job
var _expected := {}
var _records: RecordCopies
var _land_map := PackedInt32Array()
var _terrain_revision := 0
var _submitted_revision := -1
var _submitted_budgets := Vector2i.ZERO
var applied_ticks := 0
var inline_retries := 0

func invalidate_land_map() -> void:
	_terrain_revision += 1
	_land_map = PackedInt32Array()

static func _inputs(game) -> Dictionary:
	var stations := []
	for station: Dictionary in game.structs:
		if station.k in game.RAIL_KINDS:
			stations.append(station)
	var owners := []
	for owner: Dictionary in game.nations:
		owners.append([owner.get("alive", false), owner.get("gold", 0)])
	var attacks := []
	for attack: Dictionary in game.attacks:
		attacks.append([attack.a, attack.t, attack.get("dead", false)])
	return {
		"tick": game.sim_atk.tick, "width": game.W, "height": game.H, "scale": game.sim_rules.k_lin,
		"rng_state": game.rng.state, "stations": stations, "owners": owners, "trains": game.trains,
		"attack_rows": attacks, "allies": game.allies, "embargoes": game.embargoes, "owner_revisions": game._own_sv,
		"neighbors": game._rail_nb_cache, "networks": game._rail_mst, "rail_pending": game._rail_pending,
		"prepared_edges": game._prepared_rail_edges, "prepared_scale": game._prepared_rail_scale,
		"hostility_tick": game.sim_naval._hp_tick, "hostility": game.sim_naval._hp,
	}

func submit(game) -> bool:
	assert(_task == -1)
	if game.state != "play" or game.net_host != null or game.net_remote or game.team_mode:
		return false
	if game.trains.is_empty() and not game.structs.any(func(st):
		return st.k == 2 and float(st.get("bt", 0.0)) <= 0.0 and game.nations[st.o].alive \
			and int(st.get("trucks", 0)) < SimRules.TRUCKS_PER_FACTORY \
			and game.sim_atk.tick >= int(st.get("last_spawn", -1000)) + SimRules.TRAIN_COOLDOWN_TICKS):
		return false
	if _land_map.is_empty():
		_land_map = game.owner_map.duplicate()
	_submitted_revision = _terrain_revision
	_records = RecordCopies.new()
	var inputs := _records.copy_fields(_inputs(game))
	# Route geometry is immutable. The worker gets its own cache containers.
	_expected = inputs.duplicate(true)
	_expected["curves"] = game.rail_cache.duplicate()
	_expected["prepared_curves"] = game._prepared_rail_curves.duplicate()
	inputs["curves"] = _expected.curves.duplicate()
	inputs["prepared_curves"] = _expected.prepared_curves.duplicate()
	inputs["attacks"] = inputs.attack_rows.map(func(row): return {"a": row[0], "t": row[1], "dead": row[2]})
	_submitted_budgets = Vector2i(game._rail_bfs_left, game._rail_calc_left)
	_job = Job.new(inputs, _land_map, game.elapsed, game._rail_frame, _submitted_budgets.x, _submitted_budgets.y)
	_task = WorkerThreadPool.add_task(_job.run)
	if _task < 0:
		_job.sim_naval.g = null
		_clear()
	return _task >= 0

func ready() -> bool:
	return _task >= 0 and (_joined or WorkerThreadPool.is_task_completed(_task))

func wait() -> void:
	if _task >= 0 and not _joined:
		WorkerThreadPool.wait_for_task_completion(_task)
		_joined = true

func take(game) -> bool:
	assert(ready())
	wait()
	var job := _job
	var expected := _expected
	var records := _records
	_clear()
	if game.state != "play" or game.net_host != null or game.net_remote or game.team_mode or _terrain_revision != _submitted_revision:
		inline_retries += 1
		return false
	if game._rail_frame == job._rail_frame and Vector2i(game._rail_bfs_left, game._rail_calc_left) != _submitted_budgets:
		inline_retries += 1
		return false
	var current := RecordCopies.new()
	var inputs := current.copy_fields(_inputs(game))
	inputs["curves"] = game.rail_cache
	inputs["prepared_curves"] = game._prepared_rail_curves
	if inputs != expected or not records.same_records(current):
		inline_retries += 1
		return false
	_commit(game, job, records)
	applied_ticks += 1
	return true

static func _commit(game, job: Job, records: RecordCopies) -> void:
	for i in records.originals.size():
		var station: Dictionary = records.originals[i]
		if station.get("k", -1) != 2: continue
		var updated: Dictionary = records.copies[i]
		for field in ["trucks", "last_spawn"]:
			if updated.has(field): station[field] = updated[field]
	for train: Dictionary in job.starting_trains:
		var original: Dictionary = records.rebind(train)
		original.merge(records.rebind_fields(train), true)
	game.trains.assign(records.rebind(job.trains))
	for owner in job.nations.size():
		var gold: Variant = job.nations[owner].gold
		if game.nations[owner].get("gold", 0) != gold:
			game.nations[owner].gold = gold
	game.rail_cache = job.rail_cache
	game._rail_mst = records.rebind_fields(job._rail_mst)
	game._rail_nb_cache = records.rebind_fields(job._rail_nb_cache)
	game._prepared_rail_curves = job._prepared_rail_curves
	game._prepared_train_steps = []
	game._prepared_train_tick = -1
	game._rail_worker_curves_used += job._rail_worker_curves_used
	game._rail_worker_edge_lists_used += job._rail_worker_edge_lists_used
	game._rail_pending = job._rail_pending
	if game._rail_frame == job._rail_frame:
		game._rail_bfs_left = job._rail_bfs_left
		game._rail_calc_left = job._rail_calc_left
	game.sim_naval._hp = job.sim_naval._hp
	game.sim_naval._hp_tick = job.sim_naval._hp_tick
	game.rng.state = job.rng.state
	for payout: Array in job.payouts:
		game._emit_train_payout(payout[0], payout[1])

func stop() -> void:
	wait()
	_clear()
	invalidate_land_map()

func _clear() -> void:
	_task = -1
	_joined = false
	_job = null
	_records = null
	_expected = {}
