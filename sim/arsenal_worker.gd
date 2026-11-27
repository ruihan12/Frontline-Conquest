extends RefCounted
## Runs the regular construction, artillery, and SAM tick on detached records.

const BlastTerritory = preload("res://sim/blast_territory.gd")
const MirvLanding = preload("res://sim/mirv_landing.gd")
const RecordCopies = preload("res://sim/detached_records.gd")
const WarshipWorker = preload("res://sim/warship_worker.gd")

class Job extends RefCounted:
	const PLAYER := 1
	const TS := 2.0
	const team_mode := false
	var W: int
	var H: int
	var tick: int
	var owner_map: PackedInt32Array
	var rules: SimRules
	var rng := RandomNumberGenerator.new()
	var structs: Array
	var struct_at := {}
	var missiles: Array
	var allies: Dictionary
	var nations: Array
	var attacks: Array
	var boats: Array
	var build_data: Array
	var _sv: int
	var _own_sv: Dictionary
	var reload: float
	var result: SimArsenal
	var events: Array = []
	var visibility_checks := {}
	var first_arrival := {}
	var blast_fallout := PackedByteArray()
	var blast_has_borders := false
	var troop_rules: Array
	var mirv_land := PackedInt32Array()
	var mirv_speed := 0.0
	var mirv_icbm_speed := 0.0
	var canvas: Transform2D
	var viewport: Vector2
	var has_viewport: bool

	var sim_atk: Job:
		get: return self

	func _init(inputs: Dictionary, owners: PackedInt32Array, view: Array) -> void:
		W = inputs.width
		H = inputs.height
		tick = inputs.tick
		rules = SimRules.new(inputs.scale)
		rules.k_area = inputs.area
		rules.ts = inputs.troop_scale
		owner_map = owners
		rng.state = inputs.rng
		structs = inputs.structures
		for entry: Array in inputs.structures_by_tile:
			struct_at[entry[0]] = entry[1]
		missiles = inputs.missiles
		allies = inputs.allies
		nations = inputs.owners.map(func(row): return {"name": row[0], "troops": row[1], "attacked_tick": row[2]})
		troop_rules = inputs.troop_rules
		attacks = inputs.attack_rows.map(func(row): return {"a": row[0], "troops": row[1]})
		boats = inputs.boat_rows.map(func(row): return {"a": row[0], "troops": row[1]})
		build_data = inputs.build_titles
		_sv = inputs.structure_revision
		_own_sv = inputs.owner_revisions
		reload = inputs.reload
		has_viewport = view[0]
		canvas = view[1]
		viewport = view[2]
		result = SimArsenal.new(self, rules)
		result.munitions = inputs.munitions
		result.sam_shots = inputs.sam_shots
		result.stats = inputs.stats

	func run() -> void:
		result.tick()
		result.g = null
		_prepare_first_arrival()

	func _prepare_first_arrival() -> void:
		for missile: Dictionary in missiles:
			if not missile.has("lt") or tick < int(missile.lt) + int(missile.ft):
				continue
			# Earlier arrivals can change the terrain and draw from the gameplay RNG.
			if owner_map.is_empty():
				return
			if missile.nk == SimRules.N_MIRV:
				_prepare_mirv(missile)
				return
			var radius: float = missile.r
			var point: Vector2 = missile.to
			var tile := int(point.y) * W + int(point.x)
			if radius <= 0.0 or radius > 4096.0 or not is_finite(radius) or tile < 0 or tile >= W * H:
				return
			var before := rng.state
			var tiles := SimArsenal.select_blast_fallout(point, radius, missile.nk, owner_map, W, H, rng)
			first_arrival = {"missile": missile, "tick": tick, "center": point, "radius": radius,
				"kind": missile.nk, "rng_before": before, "rng_after": rng.state, "tiles": tiles}
			if not blast_fallout.is_empty():
				first_arrival.territory = BlastTerritory.prepare(tiles, owner_map, blast_fallout, W, H, blast_has_borders)
				first_arrival.fallout_before = blast_fallout
				first_arrival.has_borders = blast_has_borders
				if missile.nk == SimRules.N_WARHEAD and not troop_rules.is_empty():
					first_arrival.casualties = _prepare_warhead_casualties(first_arrival.territory)
					first_arrival.casualty_scale = [rules.k_area, rules.ts]
			rng.state = before
			return

	func _prepare_warhead_casualties(territory: Dictionary) -> Dictionary:
		var lost: Dictionary = territory.lost
		var removed: PackedInt32Array = territory.removed
		var city_levels := {}
		for city: Dictionary in structs:
			if city.k == 0 and lost.has(city.o):
				city_levels[city.o] = city_levels.get(city.o, 0) + int(city.get("level", 1))
		for i in range(0, removed.size(), 2):
			var city = struct_at.get(removed[i])
			if city != null and city.k == 0 and lost.has(city.o):
				city_levels[city.o] = city_levels.get(city.o, 0) - int(city.get("level", 1))
		var attack_groups := SimArsenal.group_troops(attacks, lost)
		var boat_groups := SimArsenal.group_troops(boats, lost)
		var casualties := {}
		for owner in lost:
			var properties: Array = troop_rules[owner]
			var count: int = lost[owner]
			var cap := maxf(rules.max_troops(properties[1], int(properties[0]) - count,
				city_levels.get(owner, 0), properties[2]), 1.0)
			var troops: float = nations[owner].troops
			casualties[owner] = {
				"troops_before": troops,
				"cap": cap,
				"survivors": SimArsenal.warhead_survivors(troops, cap, count, rules.k_area, rules.ts),
				"attacks": _surviving_units(attack_groups.get(owner, []), cap, count),
				"boats": _surviving_units(boat_groups.get(owner, []), cap, count),
			}
		return casualties

	func _surviving_units(units: Array, cap: float, count: int) -> Array:
		var updates := []
		for unit: Dictionary in units:
			var troops: float = unit.troops
			updates.append([troops, SimArsenal.warhead_survivors(troops, cap, count, rules.k_area, rules.ts)])
		return updates

	func _prepare_mirv(missile: Dictionary) -> void:
		var target: int = missile.get("tgt_o", 0)
		if allied(missile.o, target):
			return  # an alliance break can play a sound that uses gameplay RNG
		var before := rng.state
		var icbm: bool = missile.get("icbm", false)
		var speed := mirv_icbm_speed if icbm else mirv_speed
		if speed <= 0.0:
			return
		var flights := MirvLanding.prepare(missile, W, H, owner_map, mirv_land, rules, rng, speed)
		first_arrival = {"missile": missile, "tick": tick, "center": missile.to,
			"kind": missile.nk, "rng_before": before, "rng_after": rng.state, "target": target,
			"icbm": icbm, "flights": flights}
		rng.state = before

	func reload_mult() -> float:
		return reload

	func allied(a: int, b: int) -> bool:
		return a > 0 and b > 0 and allies.has(mini(a, b) * 4096 + maxi(a, b))

	func _nname(id: int) -> String:
		if id == PLAYER: return "You"
		return "the wilds" if id <= 0 else nations[id].name

	func _struct_remove(structure: Dictionary) -> void:
		_map_effect("structure_removed", [SimRules.S_OF.get(int(structure.k), -1), int(structure.tile)])
		structs.erase(structure)
		struct_at.erase(structure.tile)
		_sv += 1
		_own_sv[structure.o] = _own_sv.get(structure.o, 0) + 1

	func _missile_arc(missile: Dictionary) -> Dictionary:
		if missile.get("arc") == null:
			missile.arc = rules.munition_arc(H, missile.from, missile.to, int(missile.get("nk", SimRules.N_ATOM)))
		return missile.arc

	func _missile_world_pos(missile: Dictionary, fraction: float) -> Vector2:
		return SimRules.nuke_arc_at(_missile_arc(missile), fraction) * TS

	func _record_missile_intercept(missile: Dictionary) -> void:
		if missile.has("sim_uid"): events.append(["intercept", missile.sim_uid])

	func _viewer_event(_event: Dictionary, _recipients: Array) -> void:
		pass

	func _world_on_screen(point: Vector2) -> bool:
		var screen := canvas * point
		var visible := not has_viewport or (screen.x >= 0.0 and screen.y >= 0.0 and screen.x <= viewport.x and screen.y <= viewport.y)
		visibility_checks[point] = visible
		return visible

	func _map_effect(kind: String, values: Array) -> void:
		events.append(["effect", kind, values])

	func notify(message: String, kind: String) -> void:
		events.append(["notice", message, kind])

	func sfx(key: String, volume := 0.0, jitter := 0.04, owner := PLAYER, point := Vector2(NAN, NAN)) -> void:
		events.append(["sound", key, volume, jitter, owner, point])

var _task := -1
var _joined := false
var _job: Job
var _expected := {}
var _records: RecordCopies
var _map_changed := false
var _arrival_plan := {}
var prepared_blasts_used := 0
var prepared_territory_used := 0
var prepared_mirvs_used := 0
var _start_structures: Array = []
var _start_missiles: Array = []
var applied_ticks := 0
var inline_retries := 0

func invalidate_owner_map() -> void:
	if _task >= 0:
		_map_changed = true
	elif not _arrival_plan.is_empty():
		_arrival_plan.clear()

static func _troops(pack: Array) -> Array:
	var rows := []
	for entry: Dictionary in pack:
		rows.append([entry.a, entry.get("troops", 0)])
	return rows

static func _active_structure(structure: Dictionary) -> bool:
	return float(structure.get("bt", 0.0)) > 0.0 or structure.k in [4, 5, 10, 14, 15]

static func _inputs(game, transfer_troops: bool, include_all_structures: bool, warhead_due: bool) -> Dictionary:
	var arsenal: SimArsenal = game.sim_ars
	var owners := []
	for n: Dictionary in game.nations:
		owners.append([n.get("name", ""), n.get("troops", 0), n.get("attacked_tick", -1)])
	var titles := []
	for row: Array in game.build_data:
		titles.append([null, row[1]])
	var troop_rules := []
	if warhead_due:
		for owner in game.nations.size():
			troop_rules.append([game.nations[owner].get("land", 0), game.troop_kind(owner), game.troop_diff(owner)])
	var structures: Array = game.structs if include_all_structures else game.structs.filter(_active_structure)
	var structures_by_tile := []
	for structure: Dictionary in structures:
		if game.struct_at.has(structure.tile):
			structures_by_tile.append([structure.tile, game.struct_at[structure.tile]])
	return {
		"width": game.W, "height": game.H, "tick": game.sim_atk.tick, "rng": game.rng.state,
		"scale": game.sim_rules.k_lin, "area": game.sim_rules.k_area, "troop_scale": game.sim_rules.ts,
		"structures": structures, "structures_by_tile": structures_by_tile, "missiles": game.missiles, "owners": owners, "allies": game.allies,
		"attack_rows": _troops(game.attacks) if transfer_troops else [],
		"troop_rules": troop_rules,
		"boat_rows": _troops(game.boats) if transfer_troops else [],
		"build_titles": titles, "structure_revision": game._sv, "owner_revisions": game._own_sv,
		"reload": game.reload_mult(), "munitions": arsenal.munitions, "sam_shots": arsenal.sam_shots,
		"stats": arsenal.stats,
	}

var _strike_due := false
var _samples_territory := false
var _warhead_due := false

func submit(game) -> bool:
	assert(_task == -1)
	_arrival_plan.clear()
	if game.state != "play" or game.net_host != null or game.net_remote or game.team_mode:
		return false
	var arsenal: SimArsenal = game.sim_ars
	if game.missiles.is_empty() and arsenal.munitions.is_empty() and arsenal.sam_shots.is_empty():
		if not game.structs.any(_active_structure):
			return false
	var tick: int = game.sim_atk.tick
	var impact_due := false
	_strike_due = false
	for munition: Dictionary in arsenal.munitions:
		if int(munition.t1) <= tick:
			impact_due = true
			_strike_due = _strike_due or munition.nk != SimRules.N_SHELL
	# A battery that completes construction or gains a shot timer this tick cannot fire yet.
	_samples_territory = impact_due or game.structs.any(func(st):
		return st.k == 10 and float(st.get("bt", 0.0)) <= 0.0 and int(st.get("next_fire", tick + 1)) <= tick)
	var pending_blast: bool = game.missiles.any(func(m):
		return m.has("lt") and m.nk != SimRules.N_MIRV and tick >= int(m.lt) + int(m.ft))
	var pending_mirv: bool = game.missiles.any(func(m):
		return m.has("lt") and m.nk == SimRules.N_MIRV and tick >= int(m.lt) + int(m.ft))
	_warhead_due = game.tile_snapshot != null and game.tile_pop.is_empty() and game.missiles.any(func(m):
		return m.has("lt") and m.nk == SimRules.N_WARHEAD and tick >= int(m.lt) + int(m.ft))
	var owners := PackedInt32Array()
	if _samples_territory or pending_blast or pending_mirv:
		owners = game.owner_map.duplicate()
	_records = RecordCopies.new()
	var inputs := _records.copy_fields(_inputs(game, _strike_due or _warhead_due, _samples_territory or _warhead_due, _warhead_due))
	_expected = inputs.duplicate(true)
	_start_structures = inputs.structures.duplicate()
	_start_missiles = inputs.missiles.duplicate()
	var viewport = game.get_viewport()
	var view := [viewport != null, game.get_canvas_transform() if viewport != null else Transform2D.IDENTITY,
		viewport.get_visible_rect().size if viewport != null else Vector2.ZERO]
	_job = Job.new(inputs, owners, view)
	if pending_mirv:
		# The prebuilt list is immutable. Map generation replaces it rather than editing it.
		_job.mirv_land = game._mirv_land_list()
		_job.mirv_speed = game.NUKE_SPEED_X
		_job.mirv_icbm_speed = game.NUKE_SPEED_X * game.ICBM_SPEED_X
	if pending_blast and game.tile_snapshot != null and game.tile_pop.is_empty() \
			and game.fallout.size() == owners.size() and game.fallout_t.size() == owners.size():
		_job.blast_fallout = game.fallout.duplicate()
		_job.blast_has_borders = game.border.size() == game.nations.size()
	_task = WorkerThreadPool.add_task(_job.run)
	if _task < 0:
		_job.result.g = null
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
	var structures := _start_structures
	var missiles := _start_missiles
	var map_changed := _map_changed
	_clear()
	if game.state != "play" or game.net_host != null or game.net_remote or game.team_mode or map_changed:
		inline_retries += 1
		return false
	var live := RecordCopies.new()
	if live.copy_fields(_inputs(game, _strike_due or _warhead_due, _samples_territory or _warhead_due, _warhead_due)) != expected or not records.same_records(live) \
			or WarshipWorker._legacy_sound_pending(job.events, game):
		inline_retries += 1
		return false
	for point: Vector2 in job.visibility_checks:
		if game._world_on_screen(point) != job.visibility_checks[point]:
			inline_retries += 1
			return false
	_commit(game, job, records, structures, missiles)
	if not job.first_arrival.is_empty():
		_arrival_plan = job.first_arrival
		_arrival_plan.missile = records.rebind(_arrival_plan.missile)
	applied_ticks += 1
	return true

static func _commit(game, job: Job, records: RecordCopies, structures: Array, missiles: Array) -> void:
	for record: Dictionary in structures:
		var live: Dictionary = records.rebind(record)
		live.merge(records.rebind_fields(record), true)
		if game.struct_at.has(record.tile) and not job.struct_at.has(record.tile):
			game.struct_at.erase(record.tile)
			SimWarships.erase_ref(game.structs, live)
	for missile: Dictionary in missiles:
		var live: Dictionary = records.rebind(missile)
		live.merge(records.rebind_fields(missile), true)
		# The SAM planner also updates existing per-tile dictionaries in place.
		for key: String in ["plan_fire", "plan_k", "arc"]:
			if missile.has(key):
				live[key] = missile[key]
	game.missiles.assign(records.rebind(job.missiles))
	game._sv = job._sv
	game._own_sv = job._own_sv
	var arsenal: SimArsenal = game.sim_ars
	arsenal.munitions.assign(records.rebind(job.result.munitions))
	arsenal.sam_shots.assign(records.rebind(job.result.sam_shots))
	arsenal.stats = job.result.stats
	for id in job.nations.size():
		var update: Dictionary = job.nations[id]
		var live: Dictionary = game.nations[id]
		if update.troops != live.get("troops", 0):
			live.troops = update.troops
		for key: String in update:
			if key.begins_with("grudge_"):
				live[key] = update[key]
				live.attacked_tick = update.attacked_tick
	for i in job.attacks.size():
		if job.attacks[i].troops != game.attacks[i].get("troops", 0):
			game.attacks[i].troops = job.attacks[i].troops
	for i in job.boats.size():
		if job.boats[i].troops != game.boats[i].get("troops", 0):
			game.boats[i].troops = job.boats[i].troops
	game.rng.state = job.rng.state
	for event: Array in job.events:
		match event[0]:
			"effect": game._map_effect(event[1], event[2])
			"notice": game.notify(event[1], event[2])
			"sound": game.sfx(event[1], event[2], event[3], event[4], event[5])
			"intercept": game._record_missile_intercept({"sim_uid": event[1]})

func _take_arrival(game, missile: Dictionary) -> Dictionary:
	var plan := _arrival_plan
	_arrival_plan = {}
	if plan.is_empty() or not is_same(plan.missile, missile) or plan.tick != game.sim_atk.tick:
		return {}
	if plan.rng_before != game.rng.state or plan.center != missile.to or plan.kind != missile.nk:
		return {}
	return plan

func take_mirv(game, missile: Dictionary) -> Variant:
	var plan := _take_arrival(game, missile)
	if plan.is_empty() or plan.target != missile.get("tgt_o", 0) or plan.icbm != missile.get("icbm", false):
		return null
	game.rng.state = plan.rng_after
	prepared_mirvs_used += 1
	return plan.flights

func take_blast_fallout(game, missile: Dictionary) -> Variant:
	var plan := _take_arrival(game, missile)
	if plan.is_empty() or plan.radius != missile.r:
		return null
	game.rng.state = plan.rng_after
	prepared_blasts_used += 1
	if plan.has("territory") and game._collect_presentation and game.tile_snapshot != null \
			and not game.net_rec and not game.net_dedicated and game.tile_pop.is_empty() \
			and game.fallout == plan.fallout_before and game.fallout_t.size() == game.fallout.size() \
			and (game.border.size() == game.nations.size()) == plan.has_borders:
		prepared_territory_used += 1
		return plan
	return {"tiles": plan.tiles}

func stop() -> void:
	wait()
	_clear()
	_arrival_plan.clear()

func _clear() -> void:
	_task = -1
	_joined = false
	_map_changed = false
	_job = null
	_records = null
	_expected = {}
	_start_structures = []
	_start_missiles = []
