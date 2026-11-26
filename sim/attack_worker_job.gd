extends RefCounted
## A private copy of the inputs to one conquest pass. Tile writes become an
## ordered journal for the caller to replay through the live ownership path.

const TS := 2.0
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
var def_posts := {}
var rng := RandomNumberGenerator.new()
var captures := PackedInt32Array()
var player_capture_tiles := PackedInt32Array()
var counters := {}
var tick: int
var player_conquest := false
var _allies: Dictionary
var _traitors: Dictionary
var _kinds := PackedInt32Array()
var _rules: SimRules

func _init(game, mirror_owners := PackedInt32Array(), mirror_fallout := PackedByteArray()) -> void:
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
	if not game.sim_atk.merges.is_empty():
		var copies_by_id := {}
		for attack: Dictionary in attacks:
			copies_by_id[attack.aid] = attack
		for merge: Dictionary in game.sim_atk.merges:
			if copies_by_id.has(merge.aid):
				pending_merges.append(copies_by_id[merge.aid])
			else:
				pending_merges.append(merge.duplicate(true))
	for owner in game.def_posts:
		def_posts[owner] = game.def_posts[owner].duplicate()
	rng.state = game.rng.state
	tick = game.sim_atk.tick
	_allies = game.allies.duplicate()
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

func run() -> void:
	var conquest := SimAttacks.new(self, _rules)
	conquest.tick = tick
	conquest.tick_all()
	tick = conquest.tick
	conquest.g = null

func _set_owner(tile: int, owner: int) -> void:
	var old := owner_map[tile]
	var x := tile % W
	var y := tile / W
	if old > 0:
		var lost: Dictionary = nations[old]
		lost.land -= 1
		lost.sx -= x
		lost.sy -= y
		lost.last_by = owner
	owner_map[tile] = owner
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
	return a > 0 and b > 0 and _allies.has(mini(a, b) * 4096 + maxi(a, b))

func kind_of(id: int) -> int:
	return _kinds[id]

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

func _on_conquest(_victim: int, attacker: int, _gold: float) -> void:
	if attacker == 1:
		player_conquest = true
