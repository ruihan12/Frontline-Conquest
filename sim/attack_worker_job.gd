extends RefCounted
## A private copy of the inputs to one conquest pass. Tile writes become an
## ordered journal for the caller to replay through the live ownership path.

const TS := 2.0
const WATER := -1
const ConquestBorders = preload("res://sim/conquest_borders.gd")
const RailGeometry = preload("res://sim/rail_geometry.gd")
const RoutePosition = preload("res://sim/route_position.gd")
var W: int
var H: int
var owner_map: PackedInt32Array
var mtn: PackedByteArray
var fallout: PackedByteArray
var fallout_count: int
var land_total: int
var nations: Array
var attacks: Array
var pending_merges: Array = []
var border: Array = []
var border_scans := {}
var _scan_ids := PackedInt32Array()
var transport_orders: PackedInt32Array
var standings: Array = []
var pressure: Variant = null
var _prepare_standings: bool
var economy: EconomyWorker.Job
var structs: Array = []
var battery_targets := {}
var sam_plans: Array = []
var structure_revision := -1
var battery_radius: float
var _due_batteries: Array = []
var transport_inputs: Array = []
var transport_targets := {}
var transport_range: float
var _transport_hunters := {}
var shore_checks: Array = []
var shore_distance: float
var _trade_water: int
var _trade_routes: Array = []
var train_steps: Array[RailGeometry.TrainStep] = []
var rail_curves := {}
var rail_station_edges := {}
var rail_scale: float
var _rail_stations := {}
var _known_rail_curves := {}
var def_posts := {}
var rng := RandomNumberGenerator.new()
var captures := PackedInt32Array()
var player_capture_tiles := PackedInt32Array()
var counters := {}
var tick: int
var next_aid: int
var player_conquests: Array[Array] = []
var alliances: Dictionary
var _traitors: Dictionary
var _kinds := PackedInt32Array()
var _rules: SimRules

func _init(game, mirror_owners := PackedInt32Array(), mirror_fallout := PackedByteArray(), prepare_ai_scans := false) -> void:
	W = game.W
	H = game.H
	owner_map = game.owner_map.duplicate() if mirror_owners.is_empty() else mirror_owners
	# Terrain is read-only during play. Map generation joins the live
	# worker before it changes the terrain buffer.
	mtn = game.mtn
	fallout = game.fallout.duplicate() if mirror_fallout.is_empty() else mirror_fallout
	fallout_count = game.fallout_count
	land_total = game.land_total
	nations = game.nations.duplicate(true)
	attacks = game.attacks.duplicate(true)
	for attack: Dictionary in attacks:
		attack.hk = attack.hk.duplicate()
		attack.ht = attack.ht.duplicate()
	if prepare_ai_scans:
		_scan_ids = game.sim_ai.scheduled_border_scans(game.sim_atk.tick + 1)
	if not game.sim_atk.merges.is_empty() or not _scan_ids.is_empty():
		border.resize(nations.size())
		for id in border.size():
			border[id] = {}
		for id in _scan_ids:
			border[id] = game.border[id].duplicate()
	if not game.sim_atk.merges.is_empty():
		var copies_by_id := {}
		for attack: Dictionary in attacks:
			copies_by_id[attack.aid] = attack
		for merge: Dictionary in game.sim_atk.merges:
			if border[merge.a].is_empty():
				border[merge.a] = game.border[merge.a].duplicate()
			if copies_by_id.has(merge.aid):
				pending_merges.append(copies_by_id[merge.aid])
			else:
				pending_merges.append(merge.duplicate(true))
	for owner in game.def_posts:
		def_posts[owner] = game.def_posts[owner].duplicate()
	rng.state = game.rng.state
	tick = game.sim_atk.tick
	next_aid = game.sim_atk.next_aid
	_prepare_standings = (tick + 1) % 50 == 0 or game.sim_ai.rank.is_empty()
	transport_orders = SimAI.transport_orders(game.boats)
	alliances = game.allies.duplicate()
	_traitors = game.traitor.duplicate()
	for id in nations.size():
		_kinds.append(game.kind_of(id))
	var source: SimRules = game.sim_rules
	_rules = SimRules.new(source.k_lin)
	_rules.k_area = source.k_area
	_rules.ts = source.ts
	_rules.max_tiles_per_tick = source.max_tiles_per_tick
	_rules.defense_range = source.defense_range
	_rules.log_mid = source.log_mid
	_rules.priority_f4 = source.priority_f4.duplicate()

func capture_batteries(game) -> void:
	for building: Dictionary in game.structs:
		if building.k == 10 and float(building.get("bt", 0.0)) <= 0.0 \
				and int(building.get("next_fire", tick + 2)) <= tick + 1:
			_due_batteries.append({"tile": building.tile, "o": building.o})
	if _due_batteries.is_empty():
		return
	for building: Dictionary in game.structs:
		structs.append({"tile": building.tile, "o": building.o})
	structure_revision = game._sv
	battery_radius = game.sim_rules.artillery_range()

func capture_warship_inputs(game) -> void:
	if game.boats.is_empty() and game.traders.is_empty():
		return
	for ship: Dictionary in game.warships:
		if not ship.has("uid") or (tick + 1 + int(ship.uid)) % SimRules.SCAN_TICKS != 0:
			continue
		_transport_hunters[ship.uid] = {"o": ship.o, "pos": ship.pos, "shelled": ship.get("shelled", {}).duplicate()}
	if _transport_hunters.is_empty():
		return
	transport_range = game.sim_rules.warship_range()
	for boat: Dictionary in game.boats:
		transport_inputs.append({"a": boat.a, "uid": int(boat.get("uid", -1)), "d": boat.d,
			"pts": boat.pts.duplicate(), "cum": boat.cum.duplicate()})
	shore_distance = SimWarships.shore_distance_per_tick(game.sim_rules, game.boat_speed, game.TS)
	_trade_water = game.WATER
	for trader: Dictionary in game.traders:
		var points: PackedVector2Array = trader.get("pts", PackedVector2Array())
		var distances: PackedFloat32Array = trader.get("cum", PackedFloat32Array())
		_trade_routes.append({"pts": points.duplicate(), "cum": distances.duplicate(), "d": trader.d})

func capture_rail_inputs(game) -> void:
	for train: Dictionary in game.trains:
		train_steps.append(RailGeometry.TrainStep.new(train))
	var factories := {}
	for building: Dictionary in game.structs:
		if building.k == 2 and float(building.get("bt", 0.0)) <= 0.1:
			var cached: Array = game._rail_mst.get(building.o, [])
			if cached.is_empty() or cached[0] != game._rail_mst_version(building.o):
				factories[building.o] = true
	if factories.is_empty():
		return
	for building: Dictionary in game.structs:
		if factories.has(building.o) and building.k in game.RAIL_KINDS and float(building.get("bt", 0.0)) <= 0.1:
			if not _rail_stations.has(building.o):
				_rail_stations[building.o] = []
			_rail_stations[building.o].append({"k": building.k, "tile": building.tile})
	for key in game.rail_cache:
		_known_rail_curves[key] = true
	rail_scale = _rules.k_lin
	if game._prepared_rail_scale == rail_scale:
		for key in game._prepared_rail_curves:
			_known_rail_curves[key] = true

func run() -> void:
	var conquest := SimAttacks.new(self, _rules)
	conquest.tick = tick
	conquest.next_aid = next_aid
	conquest.merges = pending_merges
	conquest.tick_all()
	tick = conquest.tick
	next_aid = conquest.next_aid
	conquest.g = null
	if _prepare_standings:
		standings = SimAI.collect_standings(self)
	pressure = SimAI.collect_pressure(self, transport_orders)
	for id in _scan_ids:
		var coast_scale := _rules.k_lin if kind_of(id) == SimRules.KIND_TRIBE else 0.0
		border_scans[id] = SimAI.collect_border(self, id, _rules.legacy_lin, null, coast_scale)
	if economy != null:
		economy.update_after_attacks(nations)
		economy.run()
	for battery: Dictionary in _due_batteries:
		battery_targets[battery.tile] = SimArsenal.battery_structure_target(self, battery, battery_radius * battery_radius)
	for job: Dictionary in sam_plans:
		var trajectory: PackedVector2Array = job.input_trajectory
		if trajectory.is_empty():
			trajectory = SimArsenal.sample_sam_trajectory(job.arc, job.flight[1], W, H)
		job.trajectory = trajectory
		var plans := {}
		for station: Vector3i in job.stations:
			plans[station] = SimArsenal.sam_plan(_rules, W, tick, job.flight, station, trajectory)
		job.results = plans
	for step: RailGeometry.TrainStep in train_steps:
		step.calculate()
	_prepare_rail_curves()
	for boat: Dictionary in transport_inputs:
		boat.pos = RoutePosition.sample(boat)[0]
	if not transport_inputs.is_empty():
		for uid in _transport_hunters:
			var ship: Dictionary = _transport_hunters[uid]
			transport_targets[uid] = [ship, SimWarships.nearest_transport(ship, transport_inputs, alliances, transport_range, TS)]
	for route: Dictionary in _trade_routes:
		shore_checks.append([route, SimWarships.route_near_shore(route, owner_map, W, H, _trade_water, TS, shore_distance)])

func _prepare_rail_curves() -> void:
	if _rail_stations.is_empty():
		return
	var minimum := _rules.road_min_tiles()
	var maximum := _rules.road_max_tiles()
	var max_path := _rules.rail_max_path()
	for owner in _rail_stations:
		var nodes: Array = _rail_stations[owner]
		if nodes.size() < 2:
			continue
		var factories := []
		for node: Dictionary in nodes:
			if node.k == 2:
				var tile: int = node.tile
				factories.append(Vector2(tile % W + 0.5, tile / W + 0.5))
		var edges := RailGeometry.station_edges(nodes, factories, W, minimum, maximum)
		if not edges.is_empty():
			rail_station_edges[owner] = [RailGeometry.station_signature(nodes), edges]
		for edge: Array in edges:
			var source: int = nodes[edge[1]].tile
			var target: int = nodes[edge[2]].tile
			var key := RailGeometry.cache_key(source, target)
			if _known_rail_curves.has(key) or rail_curves.has(key):
				continue
			rail_curves[key] = RailGeometry.curve(mini(source, target), maxi(source, target), W, H, owner_map, rail_scale, max_path)
			if rail_curves.size() >= 40:
				return

func _set_owner(tile: int, owner: int) -> void:
	var old := owner_map[tile]
	var x := tile % W
	var y := tile / W
	if old > 0:
		if not border.is_empty():
			border[old].erase(tile)
		var lost: Dictionary = nations[old]
		lost.land -= 1
		lost.sx -= x
		lost.sy -= y
		lost.last_by = owner
	owner_map[tile] = owner
	if not border.is_empty():
		ConquestBorders.refresh_after_capture(border, tile, owner, x, owner_map, W, W * (H - 1))
	fallout[tile] = 0
	var gained: Dictionary = nations[owner]
	gained.land += 1
	gained.sx += x
	gained.sy += y
	var box: Rect2i = gained.bb
	var pixel := Rect2i(x, y, 1, 1)
	gained.bb = pixel if box.size == Vector2i.ZERO else box.merge(pixel)
	captures.append(tile)
	captures.append(owner)
	if old == 1 or owner == 1:
		player_capture_tiles.append(tile)

func allied(a: int, b: int) -> bool:
	return a > 0 and b > 0 and alliances.has(mini(a, b) * 4096 + maxi(a, b))

func kind_of(id: int) -> int:
	return _kinds[id]

func is_bot(id: int) -> bool:
	return id > 0 and id < nations.size() and bool(nations[id].get("bot", false))

# Jobs are only used in solo play, where this host event has no recipients.
func _viewer_event(_event: Dictionary, _recipients: Array) -> void:
	pass

func is_traitor(id: int) -> bool:
	return int(_traitors.get(id, -1)) > tick + 1

func defended(tile: int, owner: int) -> bool:
	var range_sq := _rules.defense_range * _rules.defense_range
	for post: int in def_posts[owner]:
		var dx := post % W - tile % W
		var dy := post / W - tile / W
		if dx * dx + dy * dy <= range_sq:
			return true
	return false

func _pf_add(key: String, value: float) -> void:
	counters[key] = counters.get(key, 0.0) + value

func _on_conquest(victim: int, attacker: int, gold: float) -> void:
	if attacker == 1:
		var nation: Dictionary = nations[victim]
		var land := maxf(1.0, float(nation.land))
		player_conquests.append([victim, float(nation.sx) / land, float(nation.sy) / land, gold])
