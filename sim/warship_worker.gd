extends RefCounted
## Runs the whole warship phase on private records. The scene retains the
## authoritative object identities for port, unit and projectile references.

const RoutePosition = preload("res://sim/route_position.gd")

class RecordCopies:
	var originals: Array[Dictionary] = []
	var copies: Array[Dictionary] = []

	func copy(value: Variant) -> Variant:
		if value is Dictionary:
			for i in originals.size():
				if is_same(originals[i], value): return copies[i]
			var detached := {}
			originals.append(value)
			copies.append(detached)
			for key in value:
				detached[key] = copy(value[key])
			return detached
		if value is Array:
			return value.map(copy)
		if typeof(value) >= TYPE_PACKED_BYTE_ARRAY:
			return value.duplicate()
		return value

	func copy_fields(fields: Dictionary) -> Dictionary:
		var detached := {}
		for key in fields:
			detached[key] = copy(fields[key])
		return detached

	func rebind(value: Variant) -> Variant:
		if value is Dictionary:
			for i in copies.size():
				if is_same(copies[i], value): return originals[i]
			return rebind_fields(value)
		if value is Array:
			return value.map(rebind)
		return value

	func rebind_fields(fields: Dictionary) -> Dictionary:
		var rebound := {}
		for key in fields:
			rebound[key] = rebind(fields[key])
		return rebound

	func same_records(other: RecordCopies) -> bool:
		if originals.size() != other.originals.size(): return false
		for i in originals.size():
			if not is_same(originals[i], other.originals[i]): return false
		return true

class Job extends RefCounted:
	const PLAYER := 1
	const WATER := -1
	const TS := 2.0
	const team_mode := false

	var W: int
	var H: int
	var tick: int
	var owner_map: PackedInt32Array
	var rng := RandomNumberGenerator.new()
	var nations: Array
	var structs: Array
	var struct_at := {}
	var warships: Array
	var boats: Array
	var traders: Array
	var allies: Dictionary
	var boat_speed: float
	var warship_speed: float
	var sim_nav: SimNav
	var sim_naval: SimNaval
	var result: SimWarships
	var events: Array = []
	var retry_inline := false
	var tracking_owners := {}

	var sim_atk: Job:
		get: return self

	func _init(inputs: Dictionary, water_map: PackedInt32Array, bodies: PackedInt32Array, search: SimNav) -> void:
		tick = inputs.tick
		W = inputs.width
		H = inputs.height
		boat_speed = inputs.boat_speed
		warship_speed = inputs.warship_speed
		rng.state = inputs.rng_state
		nations = []
		for owner: Array in inputs.owners:
			nations.append({"alive": owner[0], "name": owner[1]})
		structs = inputs.buildings
		warships = inputs.warships
		boats = inputs.boats
		traders = inputs.traders
		allies = inputs.allies
		for row: Array in inputs.tracking:
			var owner: int = row[0]
			tracking_owners[owner] = row[1]
			nations[owner].gold = row[2]
		var rules := SimRules.new(inputs.linear_scale)
		owner_map = water_map
		sim_nav = search
		sim_naval = SimNaval.new(self, rules)
		sim_naval.body = bodies
		for building: Dictionary in structs:
			struct_at[building.tile] = building
		result = SimWarships.new(self, rules)
		result.shells = inputs.shells
		result.tref = inputs.targets
		result.stats = inputs.stats
		result._post_last = inputs.post_last
		result._post_shelled = inputs.post_shelled
		result._capture_msg = inputs.capture_messages
		result.next_uid = inputs.next_uid
		result.defense_posts_shoot = inputs.posts_shoot

	func run() -> void:
		result.tick()
		clear_world_refs()

	func clear_world_refs() -> void:
		result.g = null
		sim_naval.g = null

	func allied(a: int, b: int) -> bool:
		return a > 0 and b > 0 and allies.has(mini(a, b) * 4096 + maxi(a, b))

	func _nname(id: int) -> String:
		if id == PLAYER: return "You"
		return "the wilds" if id <= 0 else nations[id].name

	func _boat_pos(boat: Dictionary) -> Array:
		return RoutePosition.sample(boat)

	func _path_pos(trader: Dictionary) -> Array:
		return RoutePosition.sample(trader)

	func _is_water(point: Vector2) -> bool:
		var x := int(point.x)
		var y := int(point.y)
		return x >= 0 and x < W and y >= 0 and y < H and owner_map[y * W + x] == WATER

	func _water_path(source: int, destination: int, _max_nodes: int) -> PackedVector2Array:
		if sim_nav != null: return sim_nav.water_path_px(source, destination, TS)
		retry_inline = true
		return PackedVector2Array()

	func ai_ship_loss(victim: int, tile: int, enemy: int) -> void:
		if victim != enemy and tile >= 0 and tracking_owners.has(victim):
			result.react_to_ship_loss(victim, tile, tracking_owners[victim])

	func _map_effect(kind: String, values: Array) -> void:
		events.append(["effect", kind, values])

	func notify(message: String, kind: String) -> void:
		events.append(["notice", message, kind])

	func sfx(key: String, volume := 0.0, jitter := 0.04, owner := PLAYER) -> void:
		events.append(["sound", key, volume, jitter, owner])

var _task := -1
var _joined := false
var _job: Job
var _records: RecordCopies
var _expected: Dictionary
var _water_map := PackedInt32Array()
var _water_revision := 0
var _submitted_water_revision := 0
var _source_nav: SimNav
var _search: SimNav
var _graph_revision := -1
var _search_revision := -1
var _search_budget := 0
var applied_ticks := 0
var inline_retries := 0

func invalidate_water_map() -> void:
	_water_revision += 1
	_water_map = PackedInt32Array()

static func _inputs(game) -> Dictionary:
	var owners := []
	for nation: Dictionary in game.nations:
		owners.append([nation.get("alive", false), nation.get("name", "")])
	var buildings := []
	for building: Dictionary in game.structs:
		if building.k == 1 or building.k == 3: buildings.append(building)
	var victims := {}
	for boat: Dictionary in game.boats: victims[boat.a] = true
	for trader: Dictionary in game.traders: victims[trader.o] = true
	var tracking := []
	for owner: int in victims:
		if game._tracks_ships(owner): tracking.append([owner, game.ai_difficulty(owner), game.nations[owner].gold])
	var navy: SimWarships = game.sim_ws
	return {
		"tick": game.sim_atk.tick, "width": game.W, "height": game.H, "boat_speed": game.boat_speed,
		"warship_speed": game.warship_speed, "rng_state": game.rng.state, "owners": owners,
		"buildings": buildings, "warships": game.warships, "boats": game.boats, "traders": game.traders,
		"allies": game.allies, "tracking": tracking, "linear_scale": game.sim_rules.k_lin,
		"shells": navy.shells, "targets": navy.tref, "stats": navy.stats, "post_last": navy._post_last,
		"post_shelled": navy._post_shelled, "capture_messages": navy._capture_msg, "next_uid": navy.next_uid,
		"posts_shoot": navy.defense_posts_shoot,
	}

func submit(game) -> bool:
	assert(_task == -1)
	if game.state != "play" or game.net_host != null or game.net_remote or game.team_mode:
		return false
	var navy: SimWarships = game.sim_ws
	if game.warships.is_empty() and navy.shells.is_empty():
		if not navy.defense_posts_shoot or game.sim_atk.tick % 10 != 0 or game.boats.is_empty():
			return false
	if _water_map.is_empty():
		# Only the water topology is read by the warship phase. Keep the private
		# copy until a map reset or a tile changes between water and land.
		_water_map = game.owner_map.duplicate()
	_submitted_water_revision = _water_revision
	var nav: SimNav = game.sim_nav
	var search: SimNav
	if nav != null and nav.ready:
		if nav != _source_nav or _graph_revision != nav.graph_revision:
			_source_nav = nav
			_graph_revision = nav.graph_revision
			_search = nav.fork_search()
		_search.prepare_search(nav, true)
		_search_revision = nav.search_revision
		_search_budget = nav.budget_us
		search = _search
	_records = RecordCopies.new()
	var inputs := _records.copy_fields(_inputs(game))
	_expected = inputs.duplicate(true)
	# Nation metadata is freshly packed on each capture. It has no identity
	# links to the entity graph.
	_job = Job.new(inputs, _water_map, game.sim_naval.body, search)
	_task = WorkerThreadPool.add_task(_job.run)
	if _task < 0:
		_job.clear_world_refs()
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
	var inputs := _expected
	var records := _records
	_clear()
	if job.retry_inline or game.state != "play" or game.net_host != null or game.net_remote or game.team_mode \
			or _water_revision != _submitted_water_revision:
		inline_retries += 1
		return false
	var nav: SimNav = game.sim_nav
	if job.sim_nav != null:
		if nav != _source_nav or not nav.ready or nav.graph_revision != _graph_revision \
				or nav.search_revision != _search_revision or nav.budget_us != _search_budget:
			inline_retries += 1
			return false
	elif nav != null and nav.ready:
		inline_retries += 1
		return false
	var current := RecordCopies.new()
	if inputs != current.copy_fields(_inputs(game)) or not records.same_records(current) or _legacy_sound_pending(job.events, game):
		inline_retries += 1
		return false
	_commit(job, records, game)
	applied_ticks += 1
	return true

static func _legacy_sound_pending(events: Array, game) -> bool:
	if game.sfx_pool.is_empty(): return false
	for event: Array in events:
		if event[0] != "sound" or not game.sfx_streams.has(event[1]): continue
		var key: String = event[1]
		if game.audio_dir == null:
			return true
		var director_handles: bool = game._audio_dir_known[key] if game._audio_dir_known.has(key) else game.audio_dir.has_sfx(key)
		if not director_handles: return true
	return false

static func _commit(job: Job, records: RecordCopies, game) -> void:
	for ship: Dictionary in game.warships:
		for i in records.originals.size():
			if not is_same(ship, records.originals[i]): continue
			var updated := records.copies[i]
			for key in ship.keys():
				if not updated.has(key): ship.erase(key)
			ship.merge(updated, true)
			if updated.has("port"): ship.port = records.rebind(updated.port)
			break
	game.warships.assign(records.rebind(job.warships))
	game.boats.assign(records.rebind(job.boats))
	game.traders.assign(records.rebind(job.traders))
	var navy: SimWarships = game.sim_ws
	navy.shells.assign(records.rebind(job.result.shells))
	navy.tref = records.rebind_fields(job.result.tref)
	navy.stats = job.result.stats
	navy._post_last = job.result._post_last
	navy._post_shelled = job.result._post_shelled
	navy._capture_msg = job.result._capture_msg
	navy.next_uid = job.result.next_uid
	for owner: int in job.tracking_owners:
		game.nations[owner].gold = job.nations[owner].gold
	game.rng.state = job.rng.state
	if job.sim_nav != null:
		game.sim_nav.commit_search(job.sim_nav)
	for event: Array in job.events:
		match event[0]:
			"effect": game._map_effect(event[1], event[2])
			"notice": game.notify(event[1], event[2])
			"sound": game.sfx(event[1], event[2], event[3], event[4])

func stop() -> void:
	wait()
	_clear()
	invalidate_water_map()
	_source_nav = null
	_search = null

func _clear() -> void:
	_task = -1
	_joined = false
	_job = null
	_records = null
	_expected = {}
