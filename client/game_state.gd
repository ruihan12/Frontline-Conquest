# The client's GameState: upstream's read API (src/shared/Core/GameState.luau as the UI uses it)
# over this port's simulation (main.gd and sim/). The UI ports under client/ui read this and
# nothing else of the game, so they stay line for line with upstream.
#
# Owners, structures, units and attacks are plain Dictionaries with upstream's field names, rebuilt
# at most once per sim tick (structures: when the game's structure version changes).
class_name RWGameState
extends RefCounted

const TeamsC := preload("res://net/teams.gd")

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

	var k_lin: float:
		get:
			return float(g.sim_rules.k_lin) if g.sim_rules != null else 1.0

	func is_water(tile: int) -> bool:
		return tile >= 0 and tile < W * H and g.owner_map[tile] == g.WATER

	## Land of any kind (the ice cap included).
	func is_land(tile: int) -> bool:
		return tile >= 0 and tile < W * H and g.owner_map[tile] != g.WATER

	## Land that can be owned.
	func is_contestable(tile: int) -> bool:
		return tile >= 0 and tile < W * H and g.owner_map[tile] >= 0

	func is_coastal(tile: int) -> bool:
		return is_contestable(tile) and g._coastal(tile)

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


## Ticks until the current phase ends (0: open-ended).
var phase_ticks_left: int:
	get:
		return int(ceil(maxf(float(g.deploy_t), 0.0) * Defs.TICK_RATE)) if g.state == "pick" else 0

## Absolute tick at which the match ends (0: no limit; solo matches have none).
var time_limit_ticks: int:
	get:
		return 0


## Spawn phase: seconds until the match starts (-1: not counting).
func spawn_seconds_left() -> float:
	if g.state != "pick" or g.start_tile < 0:
		return -1.0
	return maxf(float(g.deploy_t), 0.0)


## Seconds of the opening protection left (the game's peace clock).
func grace_seconds_left() -> float:
	if g.state != "play":
		return 0.0
	return maxf(float(g.peace) - float(g.elapsed), 0.0)


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
	o["team"] = int(n.get("team", 0)) if g.team_mode else 0
	o["spawned"] = (g.state != "pick" or g.start_tile >= 0) if id == local_owner else true
	o["flag"] = n.get("flag", "")
	o["traitor_until"] = int(g.traitor.get(id, 0))
	# (the owner's capital, or the middle of its land: the spawn hint counts neighbours by it)
	var land := maxf(1.0, float(n.get("land", 0)))
	o["label_tile"] = int(n.get("sy", 0.0) / land) * int(g.W) + int(n.get("sx", 0.0) / land) if int(n.get("land", 0)) > 0 else -1


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


func owner_color(id: int) -> Color:
	if id <= 0 or id >= g.nations.size():
		return Color.GRAY
	return g.nations[id].get("color", Color.GRAY)


func tile_owner(tile: int) -> int:
	if tile < 0 or tile >= g.owner_map.size():
		return 0
	return maxi(int(g.owner_map[tile]), 0)


## Render-only tile lookup. Gameplay and intent validation retain their live reads.
func render_tile_owner(tile: int) -> int:
	if g.tile_snapshot == null:
		return tile_owner(tile)
	g._publish_tile_snapshot()
	return maxi(g.tile_snapshot.owner(tile), 0)

func are_allies(a: int, b: int) -> bool:
	return g.allied(a, b)


func is_traitor(id: int) -> bool:
	return g.sim_atk != null and g.is_traitor(id)


func is_team_game() -> bool:
	return g.team_mode


func team_of(id: int) -> int:
	if not is_team_game() or id <= 0 or id >= g.nations.size():
		return 0
	return int(g.nations[id].get("team", 0))


func same_team(a: int, b: int) -> bool:
	var team := team_of(a)
	return team != 0 and team == team_of(b)


func team_name(team: int) -> String:
	return str(g.team_names[team - 1]) if is_team_game() and team > 0 and team <= g.team_names.size() else ""


func team_color(team: int) -> Color:
	return TeamsC.color(team_name(team), team, 0) if team > 0 else Color.GRAY


func team_ranking() -> Array:
	if not is_team_game():
		return []
	var rows := []
	for i in g.team_names.size():
		rows.append({"team": i + 1, "tiles": 0, "members": 0})
	for id in range(1, g.nations.size()):
		var team := team_of(id)
		var nation: Dictionary = g.nations[id]
		if team > 0 and team <= rows.size() and nation.alive:
			rows[team - 1].tiles += int(nation.land)
			rows[team - 1].members += 1
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.tiles > b.tiles if a.tiles != b.tiles else a.team < b.team)
	return rows


func has_fallout(tile: int) -> bool:
	return tile >= 0 and tile < g.fallout.size() and g.fallout[tile] != 0


## A tile next to `tile` (or the tile itself) belongs to `id`.
func borders_tile(id: int, tile: int) -> bool:
	return tile >= 0 and tile < g.owner_map.size() and bool(g._adj_any(tile, id))


## The alliance between `a` and `b`: {expires_at, ticks_left, in_window, can_extend, me_asked,
## other_asked}, or null.
func alliance_info(a: int, b: int):
	if not g.allied(a, b):
		return null
	var exp_t := int(g.allies.get(g._akey(a, b), -1))
	var me_asked := bool(g.asked_to_extend(a, b))
	var in_window := bool(g.in_extension_window(a, b))
	return {"expires_at": exp_t, "ticks_left": maxi(0, exp_t - tick), "in_window": in_window, "can_extend": in_window and not me_asked, "me_asked": me_asked, "other_asked": bool(g.asked_to_extend(b, a))}


## An alliance (not a team) joins `a` and `b`.
func has_alliance(a: int, b: int) -> bool:
	return bool(g.allied(a, b))


## `a` has asked `b` for an alliance and the request still stands.
func has_request(a: int, b: int) -> bool:
	return bool(g.has_request(a, b))


## Ticks until `a` may ask `b` again.
func request_cooldown_left(a: int, b: int) -> int:
	return int(g.request_cooldown_left(a, b))


## `a` and `b` share a land border (BorderTracker.borders_owner). Kept for a second per pair.
var _bord_tick := -100
var _bord := {}


func borders_owner(a: int, b: int) -> bool:
	if a <= 0 or b <= 0 or a == b:
		return false
	var t := tick
	if t - _bord_tick >= 10 or t < _bord_tick:
		_bord_tick = t
		_bord.clear()
	var k := a * 4096 + b
	if not _bord.has(k):
		_bord[k] = bool(g._shares_land_border(a, b))
	return _bord[k]


## Share of the contestable land `id` holds (all land, including fallout). SimState.luau:610-611.
func land_share(id: int) -> float:
	return g.land_share(id)

## Progress toward victory: tiles / (contestable land minus fallout). UICtx.luau:1324-1337.
func win_share(id: int) -> float:
	return g.win_share(id)


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
		_units.append(_warship_info(w))
	return _units


func _warship_info(w: Dictionary) -> Dictionary:
	var per: float = maxf(1.0, float(SimRules.WARSHIP_VET_TRANSPORTS * SimRules.WARSHIP_VET_TRADES))
	var pos: Vector2 = w.pos
	return {
		"kind": Defs.U_WARSHIP, "owner": int(w.o), "troops": 0.0, "raw": w,
		"uid": int(w.get("uid", 0)),
		"hp": float(w.get("hp", 0.0)), "max_hp": float(w.get("max_hp", SimRules.WARSHIP_HP)),
		"veterancy": int(w.get("vet", 0)),
		"vet_progress": clampf(float(w.get("vet_p", 0)) / per, 0.0, 1.0),
		"state": int(w.get("state", 0)),
		"path": [int(pos.y) * map.W + int(pos.x)],
	}


## The warship with this uid (upstream: state.units[uid]), read live; null when it is gone.
func unit(uid: int):
	for w in g.warships:
		if int(w.get("uid", 0)) == uid:
			return _warship_info(w)
	return null


## [{aid, attacker, target, troops, anchor_tile, retreating, raw}]
func attacks() -> Array:
	var t := tick
	if t == _atk_tick and _attacks.size() == g.attacks.size():
		return _attacks
	_atk_tick = t
	_attacks.clear()
	for a in g.attacks:
		_attacks.append({
			"aid": int(a.get("aid", 0)),
			"attacker": int(a.a),
			"target": int(a.t),
			"troops": float(a.get("troops", 0.0)),
			"anchor_tile": int(a.get("last", -1)),
			"retreating": int(a.get("retreat_at", 0)) > 0,
			"raw": a,
		})
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


# ---------------------------------------------------------------------------------------------
# Nukes in flight
# ---------------------------------------------------------------------------------------------
var _nuke_uid := 0
var _nuke_tick := -1
var _nukes := {}


## uid -> {uid, owner, kind (Defs.N_*), to_tile, launch_tick, flight_ticks, raw}. A uid is given to
## each missile of the game the first time it is seen. (A MIRV bus that has split is not listed: its
## warheads are.)
func nukes() -> Dictionary:
	var t := tick
	if t == _nuke_tick and _nukes.size() <= g.missiles.size():
		return _nukes
	_nuke_tick = t
	_nukes = {}
	var w: int = g.W
	for ms in g.missiles:
		if bool(ms.get("mirv_bus", false)) and bool(ms.get("split_done", false)):
			continue
		if not ms.has("cuid"):
			_nuke_uid += 1
			ms["cuid"] = _nuke_uid
		var to: Vector2 = ms.to
		var tx := int(to.x)
		var ty := int(to.y)
		_nukes[int(ms.cuid)] = {
			"uid": int(ms.cuid),
			"owner": int(ms.o),
			"kind": int(ms.get("nk", SimRules.NUKE_KIND_OF.get(int(ms.k), 0))),
			"to_tile": ty * w + tx if (tx >= 0 and ty >= 0 and tx < w and ty < g.H) else -1,
			"target_owner": int(ms.get("tgt_o", -1)),
			"launch_tick": int(ms.get("lt", t)),
			"flight_ticks": int(ms.get("ft", 1)),
			"raw": ms,
		}
	return _nukes
