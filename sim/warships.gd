# Port of RoWorld src/shared/Core/SimWarships.luau (AGPL-3.0, lukechatton/roworld @ae7a350), per sim tick.
# Targeting (transport > warship > trade ship, 130 full-size tiles), shells (3 full-size tiles/tick,
# damage 200..300 x veterancy), veterancy (warship kill = +1 level; 10 transports or 25 trade ships fill
# one), healing (+1 HP/tick near an own port, docked: port level x 5 shared), repair retreat below 75 %.
# Captured trade ships change hands and sail to the captor's nearest port on that water (_capture_trade);
# defense posts shell enemy transports / warships in reach (_posts_tick, SimWarships 1024-1080).
# Simplified vs source: straight-line steering over water unless sim/nav.gd provides a route.
extends RefCounted
class_name SimWarships

var g
var R: SimRules
var shells := []   # {shooter, o, target, kind ("boat"/"ws"), t1, dmg, from:Vector2}
var next_uid := 1
var tref := {}          # ship uid -> current target {kind, ref} (kept off the ship dict: no reference cycles)
var stats := {"shots": 0, "sunk_transports": 0, "sunk_warships": 0, "captures": 0, "post_shots": 0, "rerouted": 0}
# Upstream Rules.DEFENSE_POST_SHOOTS is false (a match option, "defense_posts_shoot"); on here because the
# coastal-defense behaviour was asked for. Set false for the upstream default.
var defense_posts_shoot := true
var _post_last := {}     # post tile -> tick of its last shell
const POST_TRANSPORT_STRIDE := 1 << 20
var _post_shelled := {}  # post tile * 2^20 + transport uid -> true
var _prepared_post_targets := {}
var worker_post_scans_used := 0

func _init(main, rules: SimRules) -> void:
	g = main
	R = rules

func reset() -> void:
	accept_steering_steps(-1, 0, -1, {})
	_prepared_post_targets = {}
	accept_transport_targets(-1, 0.0, {}, [], {})
	accept_shore_checks(-1, -1, 0.0, [])
	accept_trade_targets(0.0, 0.0, {}, {})
	shells.clear(); tref.clear(); next_uid = 1; _post_last.clear(); _post_shelled.clear()
	for k in stats: stats[k] = 0

func now() -> int:
	return g.sim_atk.tick if g.sim_atk else 0

func init_ship(ws: Dictionary) -> void:
	ws["uid"] = next_uid; next_uid += 1
	ws["vet"] = 0; ws["vet_p"] = 0
	ws["max_hp"] = SimRules.warship_max_hp(0)
	ws["hp"] = float(ws.max_hp)
	ws["last_shot"] = -1000
	ws["shelled"] = {}
	ws["state"] = 0
	ws["port"] = null
	ws["heal_rem"] = 0.0
	ws["manual"] = -1000
	ws["patrol"] = ws.pos
	ws["near_port"] = false
	ws["np_tick"] = 0
	tref.erase(int(ws.uid))

func _ports_of(o: int) -> Array:
	var out := []
	for st in g.structs:
		if st.o == o and st.k == 1 and float(st.get("bt", 0.0)) <= 0.0: out.append(st)
	return out

func _tile_of(p: Vector2) -> int:
	return clampi(int(p.y), 0, g.H - 1) * g.W + clampi(int(p.x), 0, g.W - 1)

func _body_at(p: Vector2) -> int:
	var t := _tile_of(p)
	var b: PackedInt32Array = g.sim_naval.body
	return b[t] if t < b.size() else 0

func tick() -> void:
	var t := now()
	for ws in g.warships.duplicate():
		if not ws.has("uid"): init_ship(ws)
		if not g.nations[ws.o].alive:
			erase_ref(g.warships, ws); continue
		_ship_tick(ws, t)
	if defense_posts_shoot and t % 10 == 0: _posts_tick(t)
	_shells_tick(t)

# Defense posts: every 10 ticks each active post with its shell ready (DEFENSE_POST_SHELL_TICKS) fires
# at the nearest enemy ship within DEFENSE_POST_TARGET_FULL, transports first; a post shells a given
# transport once.
func _posts_tick(t: int) -> void:
	if g.boats.is_empty() and g.warships.size() == 0: return
	var r: float = SimRules.DEFENSE_POST_TARGET_FULL / R.k_lin
	var r2 := r * r
	var W: int = g.W
	var use_prepared: bool = not _prepared_post_targets.is_empty() and _transport_tick == t \
		and not g.team_mode and _transport_allies == g.allies and _transport_inputs_match()
	for s in g.structs:
		if s.k != 3 or float(s.get("bt", 0.0)) > 0.0: continue
		var pt: int = s.tile
		if t - int(_post_last.get(pt, -100000)) <= SimRules.DEFENSE_POST_SHELL_TICKS: continue
		var sp := Vector2(pt % W + 0.5, pt / W + 0.5)
		var best = null
		var bp := 9
		var bd := 0.0
		var prepared: Array = _prepared_post_targets.get(pt, []) if use_prepared else []
		if not prepared.is_empty() and prepared[0] == s.o and prepared[1] == r \
				and prepared[2] == int(_post_last.get(pt, -100000)):
			worker_post_scans_used += 1
			if prepared[3] >= 0:
				best = {"kind": "boat", "ref": g.boats[prepared[3]]}
				bp = 0
		else:
			for bt in g.boats:
				if bt.a == s.o or g.allied(bt.a, s.o) \
						or _post_shelled.has(pt * POST_TRANSPORT_STRIDE + int(bt.get("uid", -1))):
					continue
				var d: float = (g._boat_pos(bt)[0] / g.TS as Vector2).distance_squared_to(sp)
				if d <= r2 and (best == null or d < bd):
					best = {"kind": "boat", "ref": bt}; bp = 0; bd = d
		if bp != 0:
			for w in g.warships:
				if w.o == s.o or g.allied(w.o, s.o): continue
				var d2: float = (w.pos as Vector2).distance_squared_to(sp)
				if d2 <= r2 and (best == null or d2 < bd):
					best = {"kind": "ws", "ref": w}; bp = 1; bd = d2
		if best == null: continue
		_post_last[pt] = t
		var tp := unit_pos(best)
		shells.append({"shooter": s, "o": s.o, "target": best, "t1": t + R.shell_flight_ticks(sp.distance_to(tp)),
			"dmg": SimRules.shell_damage(g.rng.randi_range(1, 5), 0), "from": sp, "t0": t, "post": true})
		stats.post_shots += 1
		if s.o == g.PLAYER or (best.kind == "boat" and best.ref.a == g.PLAYER) or (best.kind == "ws" and best.ref.o == g.PLAYER):
			g.sfx("warship_shot", -4.0, 0.06, g.PLAYER)
		if best.kind == "boat": _post_shelled[pt * POST_TRANSPORT_STRIDE + int(best.ref.get("uid", -1))] = true

func _ship_tick(ws: Dictionary, t: int) -> void:
	var hp_before: float = ws.hp
	_heal(ws, t)
	if ws.state == 2:
		var p = ws.port
		if p == null or not is_same(g.struct_at.get(p.tile), p) or p.o != ws.o or ws.hp >= ws.max_hp:
			ws.state = 0; ws.port = null; ws.heal_rem = 0.0
		else:
			return
	if ws.state == 1:
		_retreat_step(ws)
		return
	if ws.state == 0 and t - int(ws.manual) >= SimRules.WARSHIP_MANUAL_NO_RETREAT_TICKS \
			and hp_before < float(ws.max_hp) * SimRules.WARSHIP_RETREAT_PCT / 100.0:
		var port = _nearest_port(ws)
		if port != null:
			ws.state = 1; ws.port = port; ws.heal_rem = 0.0; tref.erase(int(ws.uid))
			_retreat_step(ws)
			return
	var tgt = null
	if (t + int(ws.uid)) % SimRules.SCAN_TICKS == 0:
		tgt = _find_target(ws)
		if tgt == null: tref.erase(int(ws.uid))
		else: tref[int(ws.uid)] = tgt
	elif tref.has(int(ws.uid)):
		tgt = tref[int(ws.uid)]
		if not _target_valid(ws, tgt): tgt = null; tref.erase(int(ws.uid))
	if tgt != null and tgt.kind != "trade":
		_shoot(ws, tgt, t)
		_patrol(ws)
		return
	if tgt != null:
		_hunt(ws, tgt)
		return
	_patrol(ws)

func _target_valid(ws, tg) -> bool:
	match tg.kind:
		"boat": return has_ref(g.boats, tg.ref) and tg.ref.a != ws.o and not g.allied(tg.ref.a, ws.o)
		"ws": return has_ref(g.warships, tg.ref) and tg.ref.o != ws.o and not g.allied(tg.ref.o, ws.o)
		"trade": return has_ref(g.traders, tg.ref) and tg.ref.o != ws.o and not g.allied(tg.ref.o, ws.o)
	return false

func unit_pos(tg) -> Vector2:
	match tg.kind:
		"boat": return g._boat_pos(tg.ref)[0] / g.TS
		"ws": return tg.ref.pos
		"trade": return g._path_pos(tg.ref)[0] / g.TS
	return Vector2.ZERO

func _heal(ws: Dictionary, t: int) -> void:
	if t >= int(ws.np_tick):
		ws.np_tick = t + 10
		ws.near_port = false
		var r := SimRules.WARSHIP_PASSIVE_HEAL_FULL / R.k_lin
		for p in _ports_of(ws.o):
			if Vector2(p.tile % g.W + 0.5, p.tile / g.W + 0.5).distance_squared_to(ws.pos) <= r * r:
				ws.near_port = true; break
	if ws.near_port: ws.hp = minf(float(ws.max_hp), ws.hp + SimRules.WARSHIP_PASSIVE_HEAL)
	if ws.state == 2 and ws.port != null:
		var docked := 0
		for o2 in g.warships:
			if o2.get("state", 0) == 2 and o2.get("port") == ws.port: docked += 1
		if docked > 0:
			ws.heal_rem += float(int(ws.port.get("level", 1)) * SimRules.WARSHIP_PORT_HEAL_PER_LEVEL) / docked
			var add := floorf(ws.heal_rem)
			if add > 0:
				ws.heal_rem -= add
				ws.hp = minf(float(ws.max_hp), ws.hp + add)

func _nearest_port(ws):
	var best = null
	var bd := 0.0
	var body := _body_at(ws.pos)
	for p in _ports_of(ws.o):
		if body > 0 and g.sim_naval.coast_body(p.tile) != body: continue
		var d := absf(p.tile % g.W - ws.pos.x) + absf(p.tile / g.W - ws.pos.y)
		if best == null or d < bd: best = p; bd = d
	return best

func _retreat_step(ws: Dictionary) -> void:
	var p = ws.port
	if p == null or not is_same(g.struct_at.get(p.tile), p) or p.o != ws.o:
		ws.state = 0; ws.port = null; return
	var wt: int = g.sim_naval.water_next_to(p.tile)
	if wt < 0: ws.state = 0; ws.port = null; return
	var dest := Vector2(wt % g.W + 0.5, wt / g.W + 0.5)
	var dock := SimRules.WARSHIP_DOCK_FULL / R.k_lin
	if absf(dest.x - ws.pos.x) + absf(dest.y - ws.pos.y) <= dock:
		var docked := 0
		for o2 in g.warships:
			if o2.get("state", 0) == 2 and o2.get("port") == p: docked += 1
		if docked < int(p.get("level", 1)):
			ws.state = 2; ws.pos = dest
		return
	ws.tgt = dest
	_move(ws, R.warship_tiles_per_tick(false))

var _transport_tick := -1
var _transport_range := 0.0
var _transport_allies := {}
var _transport_inputs: Array = []
var _transport_targets := {}
var worker_transport_scans_used := 0

func accept_transport_targets(tick: int, scan_range: float, allies: Dictionary, inputs: Array, targets: Dictionary) -> void:
	_transport_tick = tick
	_transport_range = scan_range
	_transport_allies = allies
	_transport_inputs = inputs
	_transport_targets = targets

const STALE_TARGET_SCAN := -2

# A valid scan with no target returns -1.
func _prepared_transport_target(ws: Dictionary, scan_range: float) -> int:
	if not _transport_targets.has(ws.uid) or _transport_tick != now() or _transport_range != scan_range \
			or g.team_mode or _transport_allies != g.allies:
		return STALE_TARGET_SCAN
	var result: Array = _transport_targets[ws.uid]
	var ship: Dictionary = result[0]
	if ship.o != ws.o or ship.pos != ws.pos or ship.shelled != ws.shelled:
		return STALE_TARGET_SCAN
	if not _transport_inputs_match():
		return STALE_TARGET_SCAN
	worker_transport_scans_used += 1
	return result[1]

func _transport_inputs_match() -> bool:
	if _transport_inputs.size() != g.boats.size():
		return false
	for i in _transport_inputs.size():
		var saved: Dictionary = _transport_inputs[i]
		var boat: Dictionary = g.boats[i]
		if saved.a != boat.a or saved.uid != int(boat.get("uid", -1)) or saved.d != boat.d \
				or saved.pts != boat.pts or saved.cum != boat.cum:
			return false
	return true

func capture_post_transport_scans(tick: int) -> Array:
	var posts := []
	if not defense_posts_shoot or tick % 10 != 0 or g.boats.is_empty():
		return posts
	# With IDs inside this range, a shot at one post cannot modify another post's exclusions.
	for boat: Dictionary in g.boats:
		var uid := int(boat.get("uid", -1))
		if uid < 0 or uid >= POST_TRANSPORT_STRIDE:
			return posts
	for post: Dictionary in g.structs:
		if post.k != 3 or float(post.get("bt", 0.0)) > 0.1:
			continue
		var tile: int = post.tile
		var last := int(_post_last.get(tile, -100000))
		if tick - last <= SimRules.DEFENSE_POST_SHELL_TICKS:
			continue
		var shelled := {}
		for boat: Dictionary in g.boats:
			var uid := int(boat.get("uid", -1))
			if _post_shelled.has(tile * POST_TRANSPORT_STRIDE + uid):
				shelled[uid] = true
		posts.append({"tile": tile, "last": last, "shelled": shelled, "o": post.o,
			"pos": SimArsenal.tpos(tile, g.W)})
	return posts

func accept_post_transport_targets(targets: Dictionary) -> void:
	_prepared_post_targets = targets

static func nearest_transport(ship: Dictionary, boats: Array, allies: Dictionary, scan_range: float, tile_size: float) -> int:
	var best := -1
	var distance_limit := scan_range * scan_range
	for i in boats.size():
		var boat: Dictionary = boats[i]
		if boat.a == ship.o or ship.shelled.has(boat.uid) \
				or (boat.a > 0 and ship.o > 0 and allies.has(mini(boat.a, ship.o) * 4096 + maxi(boat.a, ship.o))):
			continue
		var point: Vector2 = boat.pos / tile_size
		var distance := point.distance_squared_to(ship.pos)
		if distance <= distance_limit and (best < 0 or distance < distance_limit):
			best = i
			distance_limit = distance
	return best

func _find_target(ws: Dictionary):
	var r := R.warship_range()
	var r2 := r * r
	var pr := R.warship_patrol()
	var best = null
	var bp := 9
	var bd := 0.0
	var shelled: Dictionary = ws.shelled
	var prepared := _prepared_transport_target(ws, r)
	if prepared >= 0:
		return {"kind": "boat", "ref": g.boats[prepared]}
	if prepared == STALE_TARGET_SCAN:
		for bt in g.boats:
			if bt.a == ws.o or g.allied(bt.a, ws.o) or shelled.has(int(bt.get("uid", -1))): continue
			var d := (g._boat_pos(bt)[0] / g.TS as Vector2).distance_squared_to(ws.pos)
			if d <= r2 and (best == null or 0 < bp or d < bd):
				best = {"kind": "boat", "ref": bt}; bp = 0; bd = d
	if bp == 0: return best
	for o2 in g.warships:
		if o2 == ws or o2.o == ws.o or g.allied(o2.o, ws.o) or int(o2.get("state", 0)) == 2: continue
		var d2: float = o2.pos.distance_squared_to(ws.pos)
		if d2 <= r2 and (best == null or d2 < bd):
			best = {"kind": "ws", "ref": o2}; bp = 1; bd = d2
	if bp == 1: return best
	# trade ships: only with an own port on this water body, not bound for an own/allied port, near patrol
	var body := _body_at(ws.pos)
	var reachable := false
	for p in _ports_of(ws.o):
		if g.sim_naval.coast_body(p.tile) == body: reachable = true; break
	if not reachable: return null
	var prepared_trader := _prepared_trade_target(ws, r, pr)
	if prepared_trader >= 0: return {"kind": "trade", "ref": g.traders[prepared_trader]}
	if prepared_trader == -1: return null
	for i in g.traders.size():
		var tr: Dictionary = g.traders[i]
		if tr.o == ws.o or g.allied(tr.o, ws.o): continue
		var dst_o := trader_destination_owner(tr)
		if dst_o == ws.o or (dst_o > 0 and g.allied(dst_o, ws.o)): continue
		var tp: Vector2 = g._path_pos(tr)[0] / g.TS
		var d3 := tp.distance_squared_to(ws.pos)
		if d3 > r2 or tp.distance_squared_to(ws.patrol) > pr * pr or _safe_from_pirates(tr, i): continue
		if best == null or d3 < bd:
			best = {"kind": "trade", "ref": tr}; bd = d3
	return best

static func trader_destination_owner(trader: Dictionary) -> int:
	var destination = trader.get("dst")
	return int(destination.get("o", 0)) if destination is Dictionary else 0

static func nearest_trader(ship: Dictionary, checks: Array, allies: Dictionary, scan_range: float, patrol_range: float) -> int:
	var best := -1
	var distance_limit := scan_range * scan_range
	for i in checks.size():
		var check: Array = checks[i]
		if check[1]: continue
		var trader: Dictionary = check[0]
		var owner: int = trader.o
		var destination: int = trader.dst_o
		if owner == ship.o or destination == ship.o \
				or (owner > 0 and allies.has(mini(owner, ship.o) * 4096 + maxi(owner, ship.o))) \
				or (destination > 0 and allies.has(mini(destination, ship.o) * 4096 + maxi(destination, ship.o))):
			continue
		var position: Vector2 = trader.pos
		var distance := position.distance_squared_to(ship.pos)
		if distance <= distance_limit and (best < 0 or distance < distance_limit) \
				and position.distance_squared_to(ship.patrol) <= patrol_range * patrol_range:
			best = i
			distance_limit = distance
	return best

var _trade_scan_range := 0.0
var _trade_patrol_range := 0.0
var _trade_alliances := {}
var _trade_targets := {}
var worker_trade_scans_used := 0

func accept_trade_targets(scan_range: float, patrol_range: float, alliances: Dictionary, targets: Dictionary) -> void:
	_trade_scan_range = scan_range
	_trade_patrol_range = patrol_range
	_trade_alliances = alliances
	_trade_targets = targets

func _prepared_trade_target(ship: Dictionary, scan_range: float, patrol_range: float) -> int:
	if not _trade_targets.has(ship.uid) or _trade_scan_range != scan_range or _trade_patrol_range != patrol_range \
			or not _shore_checks_current() or g.team_mode or _trade_alliances != g.allies \
			or _prepared_shore_checks.size() != g.traders.size():
		return STALE_TARGET_SCAN
	var result: Array = _trade_targets[ship.uid]
	var saved: Dictionary = result[0]
	if saved.o != ship.o or saved.pos != ship.pos or saved.patrol != ship.patrol:
		return STALE_TARGET_SCAN
	for i in _prepared_shore_checks.size():
		var check: Dictionary = _prepared_shore_checks[i][0]
		var trader: Dictionary = g.traders[i]
		if check.o != trader.o or check.dst_o != trader_destination_owner(trader) or check.d != trader.d \
				or check.pts != trader.pts or check.cum != trader.cum:
			return STALE_TARGET_SCAN
	worker_trade_scans_used += 1
	return result[1]

# SimWarships._safe_from_pirates: a trade ship that sailed a shoreline tile (water 4-adjacent to land)
# in the last SAFE_FROM_PIRATES_TICKS ticks is safe. The port's ships keep the distance sailed (tr.d,
# px along tr.pts), so the last ticks' stretch of the route is sampled about every half tile.
var _prepared_shore_tick := -1
var _prepared_shore_revision := -1
var _prepared_shore_distance := 0.0
var _prepared_shore_checks: Array = []
var worker_shore_checks_used := 0

func accept_shore_checks(tick: int, revision: int, distance_per_tick: float, checks: Array) -> void:
	_prepared_shore_tick = tick
	_prepared_shore_revision = revision
	_prepared_shore_distance = distance_per_tick
	_prepared_shore_checks = checks

static func shore_distance_per_tick(rules: SimRules, boat_speed: float, tile_size: float) -> float:
	return rules.ship_tiles_per_s() / 10.0 * boat_speed * tile_size

func _shore_checks_current() -> bool:
	return _prepared_shore_tick == now() and _prepared_shore_revision == g._attack_map_revision \
		and _prepared_shore_distance == shore_distance_per_tick(R, g.boat_speed, g.TS)

func _safe_from_pirates(tr: Dictionary, index := -1) -> bool:
	if index >= 0 and index < _prepared_shore_checks.size() and _shore_checks_current():
		var check: Array = _prepared_shore_checks[index]
		if check[0].d == tr.d and check[0].pts == tr.get("pts") and check[0].cum == tr.get("cum"):
			worker_shore_checks_used += 1
			return check[1]
	return route_near_shore(tr, g.owner_map, g.W, g.H, g.WATER, g.TS, shore_distance_per_tick(R, g.boat_speed, g.TS))

static func route_near_shore(tr: Dictionary, owners: PackedInt32Array, width: int, height: int,
		water: int, tile_size: float, distance_per_tick: float) -> bool:
	var cum: PackedFloat32Array = tr.get("cum", PackedFloat32Array())
	var pts: PackedVector2Array = tr.get("pts", PackedVector2Array())
	if pts.size() < 2 or cum.size() != pts.size():
		return false
	var end: float = float(tr.d)
	var step := tile_size * 0.5
	var segment := 1
	var distance := maxf(0.0, end - SimRules.SAFE_FROM_PIRATES_TICKS * distance_per_tick)
	while true:
		while segment < cum.size() - 1 and cum[segment] < distance:
			segment += 1
		var length := maxf(0.001, cum[segment] - cum[segment - 1])
		var fraction := clampf((distance - cum[segment - 1]) / length, 0.0, 1.0)
		var point := pts[segment - 1].lerp(pts[segment], fraction) / tile_size
		var tile := clampi(int(point.y), 0, height - 1) * width + clampi(int(point.x), 0, width - 1)
		if _is_shore_water(tile, owners, width, water):
			return true
		if distance >= end:
			return false
		distance = minf(distance + step, end)
	return false

# SimWarships.shore_water: 1 on water tiles 4-adjacent to land.
func _shore_water(t: int) -> bool:
	return _is_shore_water(t, g.owner_map, g.W, g.WATER)

static func _is_shore_water(t: int, om: PackedInt32Array, W: int, water: int) -> bool:
	if t < 0 or t >= om.size() or om[t] != water: return false
	var x := t % W
	if x > 0 and om[t - 1] != water: return true
	if x < W - 1 and om[t + 1] != water: return true
	if t >= W and om[t - W] != water: return true
	if t + W < om.size() and om[t + W] != water: return true
	return false

func _shoot(ws: Dictionary, tg, t: int) -> void:
	if t - int(ws.last_shot) <= SimRules.WARSHIP_FIRE_TICKS: return
	if tg.kind != "boat": ws.last_shot = t
	var tp := unit_pos(tg)
	shells.append({"shooter": ws, "o": ws.o, "target": tg, "t1": t + R.shell_flight_ticks(ws.pos.distance_to(tp)),
		"dmg": SimRules.shell_damage(g.rng.randi_range(1, 5), int(ws.vet)), "from": ws.pos, "t0": t})
	stats.shots += 1
	if ws.o == g.PLAYER or (tg.kind == "boat" and tg.ref.a == g.PLAYER) or (tg.kind == "ws" and tg.ref.o == g.PLAYER):
		g.sfx("warship_shot", -4.0, 0.06, g.PLAYER)
	if tg.kind == "boat":
		ws.shelled[int(tg.ref.get("uid", -1))] = true
		tref.erase(int(ws.uid))

func _shells_tick(t: int) -> void:
	for s in shells.duplicate():
		if int(s.t1) > t: continue
		erase_ref(shells, s)
		var tg = s.target
		if tg.kind == "boat":
			var bt = tg.ref
			if not has_ref(g.boats, bt) or bt.a == s.o: continue
			var bp: Vector2 = g._boat_pos(bt)[0]
			erase_ref(g.boats, bt)
			g.shells.append({"pos": bp, "t": 0.0})
			stats.sunk_transports += 1
			if bt.a == g.PLAYER: g.notify("%s's warship sank your transport" % g._nname(s.o), "bad")
			elif s.o == g.PLAYER: g.notify("Your warship sank a transport from %s" % g._nname(bt.a), "good")
			_vet_progress(s.shooter, SimRules.WARSHIP_VET_TRADES)
			g.ai_ship_loss(bt.a, _tile_of(bp / g.TS), s.o)
		elif tg.kind == "ws":
			var o2 = tg.ref
			if not has_ref(g.warships, o2) or o2.o == s.o: continue
			o2.hp = maxf(0.0, o2.hp - s.dmg)
			g.shells.append({"pos": o2.pos * g.TS, "t": 0.0})
			if o2.hp <= 0.0:
				erase_ref(g.warships, o2)
				stats.sunk_warships += 1
				if o2.o == g.PLAYER: g.notify("%s's warship sank your warship" % g._nname(s.o), "bad"); g.sfx("warship_lost")
				elif s.o == g.PLAYER: g.notify("You sank a warship from %s" % g._nname(o2.o), "good")
				var w = s.shooter
				if has_ref(g.warships, w):
					w.vet_p = 0
					_vet_up(w)

func _vet_progress(w, points: int) -> void:
	if not has_ref(g.warships, w) or int(w.vet) >= SimRules.WARSHIP_MAX_VET: return
	var per := SimRules.WARSHIP_VET_TRANSPORTS * SimRules.WARSHIP_VET_TRADES
	w.vet_p = int(w.vet_p) + points
	while int(w.vet_p) >= per and int(w.vet) < SimRules.WARSHIP_MAX_VET:
		w.vet_p = int(w.vet_p) - per
		_vet_up(w)
	if int(w.vet) >= SimRules.WARSHIP_MAX_VET: w.vet_p = 0

func _vet_up(w) -> void:
	if int(w.vet) >= SimRules.WARSHIP_MAX_VET: return
	w.vet = int(w.vet) + 1
	w.max_hp = SimRules.warship_max_hp(w.vet)
	if w.o == g.PLAYER: g.notify("Your warship reached veterancy %d" % w.vet, "good")

func _hunt(ws: Dictionary, tg) -> void:
	var tp := unit_pos(tg)
	if absf(tp.x - ws.pos.x) + absf(tp.y - ws.pos.y) <= SimRules.WARSHIP_DOCK_FULL / R.k_lin:
		_capture_trade(ws, tg.ref, tp)
		tref.erase(int(ws.uid))
		return
	ws.tgt = tp
	_move(ws, R.warship_tiles_per_tick(true))

func _patrol(ws: Dictionary) -> void:
	if ws.pos.distance_to(ws.tgt) < 1.0 or not g._is_water(ws.tgt):
		var half := R.warship_patrol() / 2.0
		var c: Vector2 = ws.patrol
		var found := false
		for widen in 4:
			for _k in 12:
				var p := c + Vector2(g.rng.randf_range(-half, half), g.rng.randf_range(-half, half))
				if g._is_water(p) and _body_at(p) == _body_at(ws.pos):
					ws.tgt = p; found = true; break
			if found: break
			half *= 1.5
		if not found: return
	_move(ws, R.warship_tiles_per_tick(false))

var _steering_tick := -1
var _steering_graph_id := 0
var _steering_graph_revision := -1
var _steering_steps := {}
var worker_steering_steps_used := 0

func accept_steering_steps(tick: int, graph_id: int, revision: int, steps: Dictionary) -> void:
	_steering_tick = tick
	_steering_graph_id = graph_id
	_steering_graph_revision = revision
	_steering_steps = steps

func _apply_prepared_steering(ship: Dictionary, step: float, nav: SimNav) -> bool:
	if _steering_tick != now() or _steering_graph_id != nav.get_instance_id() \
			or _steering_graph_revision != nav.graph_revision:
		return false
	var prepared: Dictionary = _steering_steps.get(ship.get("uid", -1), {})
	if prepared.is_empty() or not prepared.moves.has(step) or prepared.pos != ship.pos or prepared.tgt != ship.tgt \
			or prepared.index != ship.get("nav_i", 0) or prepared.route_target != ship.get("nav_t", Vector2(-1e9, -1e9)) \
			or prepared.route != ship.get("nav_r"):
		return false
	_steering_steps.erase(ship.uid)
	SimNav.apply_route_step(ship, prepared.moves[step])
	worker_steering_steps_used += 1
	return true

func _move(ws: Dictionary, step: float) -> void:
	step *= float(g.get("warship_speed")) if g.get("warship_speed") != null else 1.0
	# SimNav: follow a water route around land; falls back to the straight step when no route this tick
	var nav: SimNav = g.sim_nav
	if nav != null and nav.ready:
		if _apply_prepared_steering(ws, step, nav) or nav.steer(ws, step): return
	var d: Vector2 = ws.tgt - ws.pos
	if d.length() <= step:
		if g._is_water(ws.tgt): ws.pos = ws.tgt
		return
	var np: Vector2 = ws.pos + d.normalized() * step
	if g._is_water(np): ws.pos = np
	else:
		# slide along the coast, else give up this course
		var alt1: Vector2 = ws.pos + Vector2(signf(d.x) * step, 0.0)
		var alt2: Vector2 = ws.pos + Vector2(0.0, signf(d.y) * step)
		if absf(d.x) > absf(d.y) and g._is_water(alt1): ws.pos = alt1
		elif g._is_water(alt2): ws.pos = alt2
		elif g._is_water(alt1): ws.pos = alt1
		else: ws.tgt = ws.pos


# identity (not deep ==) membership: unit dicts reference each other
static func has_ref(arr: Array, d) -> bool:
	for x in arr:
		if is_same(x, d): return true
	return false

static func erase_ref(arr: Array, d) -> void:
	for i in arr.size():
		if is_same(arr[i], d): arr.remove_at(i); return

# SimWarships._capture_trade: the trade ship changes hands and sails to the captor's nearest port on
# that water (manhattan); on arrival its gold (tradeShipGold of all tiles sailed) goes to the captor
# alone, if it still holds that port. No such port / no route: the ship is just taken off the sea.
var _capture_msg := {}
func _capture_trade(ws: Dictionary, tr, tp: Vector2) -> void:
	var victim: int = tr.o
	var orig: int = int(tr.get("orig", 0))
	if orig == 0: orig = victim
	var sailed: float = float(tr.get("sailed", 0.0)) + float(tr.d) / g.TS
	erase_ref(g.traders, tr)
	stats.captures += 1
	_vet_progress(ws, SimRules.WARSHIP_VET_TRANSPORTS)
	var t := now()
	if victim == g.PLAYER and t - int(_capture_msg.get(victim, -1000)) > 150:
		_capture_msg[victim] = t
		g.notify("%s's warships are capturing your trade ships" % g._nname(ws.o), "bad")
	if ws.o == g.PLAYER: g.notify("Your warship captured a trade ship from %s" % g._nname(victim), "good")
	g.ai_ship_loss(victim, _tile_of(tp), ws.o)
	var vt := _tile_of(tp)
	var water := _body_at(tp)
	var best = null
	var bd := 0.0
	var W: int = g.W
	for p in _ports_of(ws.o):
		if g.sim_naval.coast_body(p.tile) != water: continue
		var d := absf(p.tile % W - tp.x) + absf(p.tile / W - tp.y)
		if best == null or d < bd: best = p; bd = d
	if best == null: return
	var pts: PackedVector2Array = g._water_path(vt, best.tile, 40000)
	if pts.size() < 2: return
	var cum := PackedFloat32Array([0.0])
	for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
	var gold := floorf(R.trade_gold(sailed + cum[cum.size() - 1] / g.TS))
	g.traders.append({"o": ws.o, "pts": pts, "cum": cum, "d": 0.0, "dst": best, "gold": gold, "orig": orig, "sailed": sailed})
	stats.rerouted += 1
