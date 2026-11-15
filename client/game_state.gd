# The client's GameState: upstream's read API (src/shared/Core/GameState.luau as the UI uses it)
# over this port's simulation (main.gd and sim/). The UI ports under client/ui read this and
# nothing else of the game, so they stay line for line with upstream.
#
# Owners, structures, units and attacks are plain Dictionaries with upstream's field names, rebuilt
# at most once per sim tick (structures: when the game's structure version changes).
class_name RWGameState
extends RefCounted

## Build ids of the game (main.gd build_data) by upstream kind name.
const BUILD_ID := {
	"city": 0, "port": 1, "factory": 2, "defense": 3, "sam": 4, "silo": 5, "warship": 6,
	"atom": 7, "hydrogen": 8, "mirv": 9, "artillery": 10, "mega": 11, "scatter": 12,
	"reinforce": 13, "airfield": 14, "railgun": 15, "airstrike": 14, "slug": 15,
}
## Defs.S_* by the game's structure id.
const S_OF := {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 10: 6, 14: 7, 15: 8}

var g  # main.gd
var map: RWMapInfo
var local_owner := 1
var _own_tick := -1
var _owners: Array = []
var _by_id := {}
var _st_ver := -1
var _st_tick := -1
var _structs: Array = []
var _un_tick := -1
var _units: Array = []
var _atk_tick := -1
var _attacks: Array = []


class RWMapInfo:
	extends RefCounted
	var g
	var W: int
	var H: int
	var contestable_count: int:
		get:
			return g.land_total

	func _init(main) -> void:
		g = main
		W = main.W
		H = main.H

	## Defs.T_* of a tile.
	func terrain_at(tile: int) -> int:
		if tile < 0 or tile >= W * H:
			return Defs.T_OCEAN
		var o: int = g.owner_map[tile]
		if o == g.WATER:
			return Defs.T_OCEAN
		if o == g.ICE:
			return Defs.T_ICECAP
		if g.snow_src.size() > tile and g.snow_src[tile] == 4:
			return Defs.T_TUNDRA
		if g.mtn.size() > tile:
			var m: int = g.mtn[tile]
			if m >= 2:
				return Defs.T_MOUNTAIN
			if m == 1:
				return Defs.T_HIGHLAND
		return Defs.T_PLAINS


func _init(main) -> void:
	g = main
	local_owner = main.PLAYER
	map = RWMapInfo.new(main)


# ---------------------------------------------------------------------------------------------
# Clock and phase
# ---------------------------------------------------------------------------------------------
var tick: int:
	get:
		return int(g.sim_atk.tick) if g.sim_atk != null else 0

var render_tick: float:
	get:
		return float(tick)

var phase: int:
	get:
		match g.state:
			"pick":
				return Defs.PHASE_SPAWN
			"play":
				return Defs.PHASE_PLAYING
			"over":
				return Defs.PHASE_OVER
		return Defs.PHASE_SPAWN

var fallout_count: int:
	get:
		return int(g.fallout_count)

var mirvs_launched: int:
	get:
		return int(g.mirvs_launched)

var winner: int:
	get:
		return int(g.get("win_id")) if g.get("win_id") != null else 0

var over_reason: int:
	get:
		return Defs.OVER_DOMINATION


# ---------------------------------------------------------------------------------------------
# Owners
# ---------------------------------------------------------------------------------------------
static func _kind(sim_kind: int) -> int:
	if sim_kind == SimRules.KIND_HUMAN:
		return Defs.KIND_HUMAN
	if sim_kind == SimRules.KIND_NATION:
		return Defs.KIND_NATION
	return Defs.KIND_TRIBE


func _refresh_owners() -> void:
	var t := tick
	if t == _own_tick and _owners.size() == maxi(g.nations.size() - 1, 0):
		# (troops and gold move within a tick's frames only for display; refresh the local owner)
		var mine = _by_id.get(local_owner)
		if mine != null:
			_fill(mine, local_owner)
		return
	_own_tick = t
	_owners.clear()
	_by_id.clear()
	for id in range(1, g.nations.size()):
		var o := {"id": id}
		_fill(o, id)
		_owners.append(o)
		_by_id[id] = o


func _fill(o: Dictionary, id: int) -> void:
	var n: Dictionary = g.nations[id]
	o["name"] = n.get("name", "")
	o["color"] = n.get("color", Color.GRAY)
	o["tiles"] = int(n.get("land", 0))
	o["troops"] = float(n.get("troops", 0.0))
	o["gold"] = float(n.get("gold", 0.0))
	o["alive"] = bool(n.get("alive", false))
	o["max_troops"] = float(g.troop_cap(id)) if o["alive"] else 0.0
	o["kind"] = _kind(g.kind_of(id))
	o["team"] = 0
	o["spawned"] = (g.state != "pick" or g.start_tile >= 0) if id == local_owner else true
	o["flag"] = n.get("flag", "")


## Every owner (index order = id order, ids from 1).
func owners() -> Array:
	_refresh_owners()
	return _owners


func get_owner(id: int):
	_refresh_owners()
	return _by_id.get(id)


func owner_name(id: int) -> String:
	if id <= 0 or id >= g.nations.size():
		return ""
	return g.nations[id].get("name", "")


func tile_owner(tile: int) -> int:
	if tile < 0 or tile >= g.owner_map.size():
		return 0
	return maxi(int(g.owner_map[tile]), 0)


func are_allies(a: int, b: int) -> bool:
	return g.allied(a, b)


func is_traitor(id: int) -> bool:
	return g.sim_atk != null and g.is_traitor(id)


func same_team(_a: int, _b: int) -> bool:
	return false


func team_name(_t: int) -> String:
	return ""


func has_fallout(tile: int) -> bool:
	return tile >= 0 and tile < g.fallout.size() and g.fallout[tile] != 0


## Share of the contestable land `id` holds.
func land_share(id: int) -> float:
	var o = get_owner(id)
	if o == null:
		return 0.0
	return float(o.tiles) / maxf(float(map.contestable_count), 1.0)


## Passive gold per second.
func income(id: int) -> float:
	if id <= 0 or id >= g.nations.size():
		return 0.0
	return float(g.gold_rate(id))


## Rules.troop_growth for `id` now: troops gained per tick.
func troop_growth(id: int) -> float:
	var o = get_owner(id)
	if o == null or not o.alive:
		return 0.0
	return float(g.sim_rules.troop_growth(g.troop_kind(id), o.troops, maxf(o.max_troops, 1.0), g.human_difficulty(id)))


## `id` owns land on a coast (a port can be built). Kept for a second: one pass over the border.
var _coast_tick := -100
var _coast := {}


func has_coast(id: int) -> bool:
	var t := tick
	if t - _coast_tick >= 10 or t < _coast_tick:
		_coast_tick = t
		_coast.clear()
	if _coast.has(id):
		return _coast[id]
	var ok := false
	if id > 0 and id < g.nations.size():
		var bb: Rect2i = g.nations[id].get("bb", Rect2i())
		var w: int = g.W
		var om: PackedInt32Array = g.owner_map
		for y in range(bb.position.y, bb.end.y + 1):
			if ok:
				break
			for x in range(bb.position.x, bb.end.x + 1):
				var i := y * w + x
				if i < 0 or i >= om.size() or om[i] != id:
					continue
				if (x + 1 < w and om[i + 1] == g.WATER) or (x > 0 and om[i - 1] == g.WATER) or (i + w < om.size() and om[i + w] == g.WATER) or (i - w >= 0 and om[i - w] == g.WATER):
					ok = true
					break
	_coast[id] = ok
	return ok


## Owners still in play, most land first (ties: the lower id).
func ranking() -> Array:
	var out: Array = []
	for o in owners():
		if o.alive and o.tiles > 0:
			out.append(o)
	out.sort_custom(func(a, b): return a.tiles > b.tiles or (a.tiles == b.tiles and a.id < b.id))
	return out


# ---------------------------------------------------------------------------------------------
# Structures, units, attacks
# ---------------------------------------------------------------------------------------------
## [{sid, kind (Defs.S_*), owner, tile, level, active_tick, shots, hp, raw}]
func structures() -> Array:
	var ver := int(g.get("_sv")) if g.get("_sv") != null else -1
	var t := tick
	if ver == _st_ver and t == _st_tick and _structs.size() == g.structs.size():
		return _structs
	_st_ver = ver
	_st_tick = t
	_structs.clear()
	var i := 0
	for st in g.structs:
		i += 1
		var k: int = S_OF.get(int(st.k), -1)
		var bt: float = float(st.get("bt", 0.0))
		_structs.append({
			"sid": int(st.get("sid", i)),
			"kind": k,
			"owner": int(st.o),
			"tile": int(st.tile),
			"level": int(st.get("level", 1)),
			# (bt: seconds of construction left, on the game's clock of 10 ticks a second)
			"active_tick": t + int(ceil(bt * Defs.TICK_RATE)) if bt > 0.0 else 0,
			"shots": st.get("shots", []),
			"hp": int(st.get("hp", 0)),
			"raw": st,
		})
	return _structs


## [{kind (Defs.U_*), owner, troops, raw}]: transports and warships.
func units() -> Array:
	var t := tick
	if t == _un_tick:
		return _units
	_un_tick = t
	_units.clear()
	for b in g.boats:
		_units.append({"kind": Defs.U_TRANSPORT, "owner": int(b.a), "troops": float(b.get("troops", 0.0)), "raw": b})
	for w in g.warships:
		_units.append({"kind": Defs.U_WARSHIP, "owner": int(w.o), "troops": 0.0, "raw": w})
	return _units


## [{attacker, target, troops, raw}]
func attacks() -> Array:
	var t := tick
	if t == _atk_tick and _attacks.size() == g.attacks.size():
		return _attacks
	_atk_tick = t
	_attacks.clear()
	for a in g.attacks:
		_attacks.append({"attacker": int(a.a), "target": int(a.t), "troops": float(a.get("troops", 0.0)), "raw": a})
	return _attacks


## Sum of the levels of `id`'s structures of `kind` (Defs.S_*).
func struct_level_sum(id: int, kind: int) -> int:
	var n := 0
	for st in structures():
		if st.owner == id and st.kind == kind:
			n += int(st.level)
	return n


## Tick at which `id` may call Reinforcements again.
func reinforce_ready(id: int) -> int:
	if id <= 0 or id >= g.nations.size():
		return 0
	var cd: float = float(g.nations[id].get("reinf_cd", 0.0))
	return tick + int(ceil(cd * Defs.TICK_RATE)) if cd > 0.0 else 0
