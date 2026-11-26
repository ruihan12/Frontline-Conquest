extends RefCounted
## A private copy of the inputs to one conquest pass. Tile writes become an
## ordered journal for the caller to replay through the live ownership path.

const TS := 2.0
const ConquestBorders = preload("res://sim/conquest_borders.gd")
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
var structure_revision := -1
var battery_radius: float
var _due_batteries: Array = []
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
		border_scans[id] = SimAI.collect_border(self, id, _rules.legacy_lin)
	if economy != null:
		economy.update_after_attacks(nations)
		economy.run()
	for battery: Dictionary in _due_batteries:
		battery_targets[battery.tile] = SimArsenal.battery_structure_target(self, battery, battery_radius * battery_radius)

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
