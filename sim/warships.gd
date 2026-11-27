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
var _post_shelled := {}  # post tile * 2^20 + transport uid -> true

func _init(main, rules: SimRules) -> void:
	g = main
	R = rules

func reset() -> void:
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
	if _luau_tick(): return  # Step 5d3: luau/sim/Core/SimWarships.luau
	_tick_gd()

func _tick_gd() -> void:
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
	for s in g.structs:
		if s.k != 3 or float(s.get("bt", 0.0)) > 0.0: continue
		var pt: int = s.tile
		if t - int(_post_last.get(pt, -100000)) <= SimRules.DEFENSE_POST_SHELL_TICKS: continue
		var sp := Vector2(pt % W + 0.5, pt / W + 0.5)
		var best = null
		var bp := 9
		var bd := 0.0
		for bt in g.boats:
			if bt.a == s.o or g.allied(bt.a, s.o) or _post_shelled.has(pt * 1048576 + int(bt.get("uid", -1))): continue
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
		if best.kind == "boat": _post_shelled[pt * 1048576 + int(best.ref.get("uid", -1))] = true

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

func _find_target(ws: Dictionary):
	var r := R.warship_range()
	var r2 := r * r
	var pr := R.warship_patrol()
	var best = null
	var bp := 9
	var bd := 0.0
	var shelled: Dictionary = ws.shelled
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
	for tr in g.traders:
		if tr.o == ws.o or g.allied(tr.o, ws.o): continue
		var dst_o: int = int(tr.dst.get("o", 0)) if tr.dst is Dictionary else 0
		if dst_o == ws.o or (dst_o > 0 and g.allied(dst_o, ws.o)): continue
		var tp: Vector2 = g._path_pos(tr)[0] / g.TS
		var d3 := tp.distance_squared_to(ws.pos)
		if d3 > r2 or tp.distance_squared_to(ws.patrol) > pr * pr or _safe_from_pirates(tr): continue
		if best == null or d3 < bd:
			best = {"kind": "trade", "ref": tr}; bd = d3
	return best

# SimWarships._safe_from_pirates: a trade ship that sailed a shoreline tile (water 4-adjacent to land)
# in the last SAFE_FROM_PIRATES_TICKS ticks is safe. The port's ships keep the distance sailed (tr.d,
# px along tr.pts), so the last ticks' stretch of the route is sampled about every half tile.
func _safe_from_pirates(tr: Dictionary) -> bool:
	var cum: PackedFloat32Array = tr.get("cum", PackedFloat32Array())
	var pts: PackedVector2Array = tr.get("pts", PackedVector2Array())
	if pts.size() < 2 or cum.size() != pts.size():
		return false
	var d1: float = float(tr.d)
	var per_tick: float = g.sim_rules.ship_tiles_per_s() / 10.0 * g.boat_speed * g.TS
	var d0 := maxf(0.0, d1 - SimRules.SAFE_FROM_PIRATES_TICKS * per_tick)
	var step: float = g.TS * 0.5
	var m := 1
	var d := d0
	while true:
		while m < cum.size() - 1 and cum[m] < d: m += 1
		var seg := maxf(0.001, cum[m] - cum[m - 1])
		var p: Vector2 = pts[m - 1].lerp(pts[m], clampf((d - cum[m - 1]) / seg, 0.0, 1.0)) / g.TS
		if _shore_water(_tile_of(p)):
			return true
		if d >= d1: break
		d = minf(d + step, d1)
	return false

# SimWarships.shore_water: 1 on water tiles 4-adjacent to land.
func _shore_water(t: int) -> bool:
	var om: PackedInt32Array = g.owner_map
	var W: int = g.W
	if t < 0 or t >= om.size() or om[t] != g.WATER: return false
	var x := t % W
	if x > 0 and om[t - 1] != g.WATER: return true
	if x < W - 1 and om[t + 1] != g.WATER: return true
	if t >= W and om[t - W] != g.WATER: return true
	if t + W < om.size() and om[t + W] != g.WATER: return true
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

func _move(ws: Dictionary, step: float) -> void:
	step *= float(g.get("warship_speed")) if g.get("warship_speed") != null else 1.0
	# SimNav: follow a water route around land; falls back to the straight step when no route this tick
	if g.sim_nav != null and g.sim_nav.ready and g.sim_nav.steer(ws, step): return
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


# ------------------------------------------------------------------------------------------------
# Step 5d3 (docs/LUAU_PORT.md): the tick in Luau
# ------------------------------------------------------------------------------------------------
# With the Luau link on (not a remote viewer, not NO_LUAU_SIM) and the water navigation in the same Luau state,
# the tick runs in luau/sim/Core/SimWarships.luau, transliterated from the GDScript above. The GDScript keeps the
# state (the ship dicts, shells, tref, the posts' memory, the stats) and sends it each tick; Luau sends back the
# ship fields, the shells and targets as they are after the tick and the events (sounds, notes, hit marks, sunk
# transports and warships, captured trade ships), applied here in the order the GDScript does them. Where the
# GDScript calls game.ai_ship_loss in the middle of the tick, Luau stops, the batch so far is applied, the AI runs
# here, and Luau goes on with the ships and the rng as they are then. Boats and trade ships have no id of their
# own, so they get one here, kept by identity across ticks (both lists only grow at the end and lose entries).
const LMOD := "Core/SimWarships"
const KINDS := ["boat", "ws", "trade"]
var luau_calls := 0
var luau_resumes := 0  # tests: ticks that stopped for game.ai_ship_loss and went on
var _bt_prev: Array = []
var _bt_ids := PackedInt64Array()
var _tr_prev: Array = []
var _tr_ids := PackedInt64Array()
var _next_id := 1
var _tr_sent := {}          # trade ship ids whose points the Luau state holds
var _lvm_sent: LuauVM = null

# ids for `list` given the last call's list and ids (identity merge: entries only leave or come in at the end)
func _ids_of(list: Array, prev: Array, prev_ids: PackedInt64Array) -> PackedInt64Array:
	var ids := PackedInt64Array()
	ids.resize(list.size())
	var j := 0
	var np := prev.size()
	for i in list.size():
		var x = list[i]
		while j < np and not is_same(prev[j], x): j += 1
		if j < np:
			ids[i] = prev_ids[j]
			j += 1
		else:
			ids[i] = _next_id
			_next_id += 1
	return ids

static func _index_of(list: Array, x) -> int:
	for i in list.size():
		if is_same(list[i], x): return i
	return -1

func _ship_row(q: PackedFloat64Array, ws: Dictionary, lports: Array) -> void:
	var pos: Vector2 = ws.pos
	var tgt: Vector2 = ws.tgt
	var pat: Vector2 = ws.patrol
	var pk := -1
	if ws.port != null:
		pk = _index_of(lports, ws.port)
	q.append(ws.uid); q.append(ws.o); q.append(pos.x); q.append(pos.y); q.append(tgt.x); q.append(tgt.y)
	q.append(pat.x); q.append(pat.y); q.append(ws.hp); q.append(ws.max_hp); q.append(ws.vet); q.append(ws.vet_p)
	q.append(ws.last_shot); q.append(ws.state); q.append(pk); q.append(ws.heal_rem); q.append(ws.manual)
	q.append(1.0 if ws.near_port else 0.0); q.append(ws.np_tick)
	var fl := 0
	if ws.has("nav_r"): fl += 1
	if ws.has("nav_t"): fl += 2
	if ws.has("nav_i"): fl += 4
	q.append(fl)
	var nt: Vector2 = ws.get("nav_t", Vector2(-1e9, -1e9))
	q.append(nt.x); q.append(nt.y); q.append(ws.get("nav_i", 0))
	var route: PackedVector2Array = ws.get("nav_r", PackedVector2Array())
	q.append(route.size())
	for p in route: q.append(p.x); q.append(p.y)
	var sh: Dictionary = ws.shelled
	q.append(sh.size())
	for u in sh: q.append(u)

func _ships_buf(lports: Array) -> PackedByteArray:
	var q := PackedFloat64Array()
	for ws in g.warships:
		# a port a ship still points at but no longer finished (or replaced) goes in as not finished
		if ws.port != null and _index_of(lports, ws.port) < 0:
			lports.append(ws.port)
		_ship_row(q, ws, lports)
	return q.to_byte_array()

func _ports_buf(lports: Array, nfin: int) -> PackedByteArray:
	var q := PackedFloat64Array()
	for i in lports.size():
		var p: Dictionary = lports[i]
		q.append(p.tile); q.append(p.o); q.append(int(p.get("level", 1)))
		q.append(1.0 if is_same(g.struct_at.get(p.tile), p) else 0.0)
		q.append(1.0 if i < nfin else 0.0)
	return q.to_byte_array()

func _luau_tick() -> bool:
	if g.net_remote or OS.has_environment("NO_LUAU_SIM"): return false
	var nav = g.sim_nav
	if nav == null or not nav.ready or not nav.on_luau(): return false
	var lu = g.get("luau_link")
	if lu == null or not lu.on or not is_same(lu.vm, nav._lvm): return false
	var t := now()
	if g.warships.is_empty() and shells.is_empty() and not (defense_posts_shoot and t % 10 == 0 and not g.boats.is_empty()):
		return true  # the GDScript tick would do nothing
	var vm: LuauVM = lu.vm
	if not is_same(vm, _lvm_sent): _tr_sent.clear()
	# trade ships Luau has not seen: their points must be something Luau takes, or the GDScript tick runs
	var tr_ids := _ids_of(g.traders, _tr_prev, _tr_ids)
	for i in g.traders.size():
		if _tr_sent.has(tr_ids[i]): continue
		var tr: Dictionary = g.traders[i]
		var pts: PackedVector2Array = tr.pts
		var cum: PackedFloat32Array = tr.cum
		if pts.size() != cum.size(): return false
	if not vm.require_module(LMOD) or not lu.flush(g):
		if lu.on: lu._fail(g, vm.last_error)
		return false
	if vm.call_fn("Core/SimArsenal", "world", g.sim_atk._world()) == null:
		lu._fail(g, vm.last_error)
		return false
	# the GDScript inits ships in the tick's loop, before the alive check: same order here
	for ws in g.warships:
		if not ws.has("uid"): init_ship(ws)
	var bt_ids := _ids_of(g.boats, _bt_prev, _bt_ids)
	# id -> dict for everything a shell, a target or an event can name (kept when it leaves the lists this tick);
	# trade ships by their place in tr_ids, the ones gone this tick in tr_gone
	var boat_by := {}
	var ws_by := {}
	var lports: Array = []
	var lposts: Array = []
	var qb := PackedFloat64Array()
	for s in g.structs:
		var sk: int = s.k
		if (sk != 1 and sk != 3) or float(s.get("bt", 0.0)) > 0.0: continue
		if sk == 1:
			lports.append(s)
		else:
			qb.append(s.tile); qb.append(s.o); qb.append(lposts.size())
			lposts.append(s)
	var nfin := lports.size()
	var sb := _ships_buf(lports)
	for ws in g.warships: ws_by[int(ws.uid)] = ws
	var bb := PackedFloat64Array()
	for i in g.boats.size():
		var bt: Dictionary = g.boats[i]
		boat_by[bt_ids[i]] = bt
		var bp: Vector2 = g._boat_pos(bt)[0]
		bb.append(bt_ids[i]); bb.append(bt.a); bb.append(int(bt.get("uid", -1))); bb.append(bp.x); bb.append(bp.y)
	var shb := PackedFloat64Array()
	for s in shells:
		var post: bool = s.get("post", false)
		var tg: Dictionary = s.target
		var tid := -1
		if tg.kind == "boat":
			var bi := _index_of(g.boats, tg.ref)
			if bi >= 0: tid = bt_ids[bi]
		else:
			tid = int(tg.ref.get("uid", -1))
		var from: Vector2 = s.from
		shb.append(-1 if post else int(s.shooter.get("uid", -1))); shb.append(s.o); shb.append(0 if tg.kind == "boat" else 1)
		shb.append(tid); shb.append(s.t1); shb.append(s.dmg); shb.append(from.x); shb.append(from.y)
		shb.append(int(s.get("t0", 0))); shb.append(1.0 if post else 0.0)
	var trb := PackedFloat64Array()
	for uid in tref:
		var tg: Dictionary = tref[uid]
		var kind: int = KINDS.find(tg.kind)
		var id := -1
		if kind == 0:
			var bi := _index_of(g.boats, tg.ref)
			if bi >= 0: id = bt_ids[bi]
		elif kind == 1:
			id = int(tg.ref.get("uid", -1))
		else:
			var ti := _index_of(g.traders, tg.ref)
			if ti >= 0: id = tr_ids[ti]
		trb.append(uid); trb.append(kind); trb.append(id)
	var plb := PackedFloat64Array()
	for pt in _post_last: plb.append(pt); plb.append(_post_last[pt])
	var psb := PackedFloat64Array()
	for k in _post_shelled: psb.append(k)
	var stb := PackedFloat64Array([stats.shots, stats.sunk_transports, stats.sunk_warships, stats.captures,
		stats.post_shots, stats.rerouted])
	var wsp: float = float(g.get("warship_speed")) if g.get("warship_speed") != null else 1.0
	var hdr := PackedFloat64Array([t, nav._lid, g.TS, g.W, g.H, g.PLAYER, g.boat_speed, wsp,
		1.0 if defense_posts_shoot else 0.0, _next_id, int(_capture_msg.get(g.PLAYER, -1000))])
	var rf := PackedFloat64Array()
	for k in SimAttacks.RULE_FIELDS: rf.append(float(R.get(k)))
	var rg := LuauLink.rng_args(g)
	var out = vm.call_fn(LMOD, "tick", [rg[0], rg[1], hdr.to_byte_array(), rf.to_byte_array(), sb,
		bb.to_byte_array(), _ports_buf(lports, nfin), qb.to_byte_array(),
		shb.to_byte_array(), trb.to_byte_array(), plb.to_byte_array(), psb.to_byte_array(), stb.to_byte_array()])
	if out == null:
		lu._fail(g, vm.last_error)
		return false
	luau_calls += 1
	_lvm_sent = vm
	var st := {"bt_ids": bt_ids, "tr_ids": tr_ids, "boat_by": boat_by, "tr_gone": {}, "ws_by": ws_by,
		"lports": lports, "lposts": lposts}
	while true:
		if not _lapply(out, st):
			vm.call_fn(LMOD, "abort", [])
			lu._fail(g, "SimWarships: the Luau tick and the lists here no longer match (check %d, tick %d)" % [_why, t])
			break
		if bool(out.done): break
		if bool(out.need_tr):
			# a ship needs the trade ships: Luau holds their points from earlier calls, the rest comes now
			var tb := PackedFloat64Array()
			var tp := PackedFloat64Array()
			var ids: PackedInt64Array = st.tr_ids
			var sent := {}
			for i in g.traders.size():
				var tr: Dictionary = g.traders[i]
				var id: int = ids[i]
				var dst_o: int = int(tr.dst.get("o", 0)) if tr.dst is Dictionary else 0
				tb.append(id); tb.append(tr.o); tb.append(dst_o); tb.append(tr.d)
				tb.append(int(tr.get("orig", 0))); tb.append(float(tr.get("sailed", 0.0)))
				if not _tr_sent.has(id):
					var pts: PackedVector2Array = tr.pts
					var cum: PackedFloat32Array = tr.cum
					tp.append(id); tp.append(pts.size())
					for p in pts: tp.append(p.x); tp.append(p.y)
					for c in cum: tp.append(c)
				sent[id] = true
			_tr_sent = sent  # Luau keeps the points of the ships it was sent now and drops the rest
			rg = LuauLink.rng_args(g)
			out = vm.call_fn(LMOD, "resume", [rg[0], rg[1], PackedByteArray(), tb.to_byte_array(), tp.to_byte_array()])
		else:
			var ai: PackedFloat64Array = (out.ai as PackedByteArray).to_float64_array()
			g.ai_ship_loss(int(ai[0]), int(ai[1]), int(ai[2]))
			for ws in g.warships:
				if not ws_by.has(int(ws.uid)): ws_by[int(ws.uid)] = ws
			rg = LuauLink.rng_args(g)
			luau_resumes += 1
			out = vm.call_fn(LMOD, "resume", [rg[0], rg[1], _ships_buf(lports)])
		if out == null:
			# half a tick is applied: the GDScript can't take over from here
			lu._fail(g, vm.last_error)
			break
	_bt_prev = g.boats.duplicate()
	_bt_ids = st.bt_ids
	_tr_prev = g.traders.duplicate()
	_tr_ids = st.tr_ids
	return true

func _tr_ref(st: Dictionary, id: int):
	var i: int = (st.tr_ids as PackedInt64Array).find(id)
	if i >= 0: return g.traders[i]
	return st.tr_gone.get(id)

var _why := 0
func _no(k: int) -> bool:
	_why = k
	return false

const NOTES := ["%s's warship sank your transport", "Your warship sank a transport from %s",
	"%s's warship sank your warship", "You sank a warship from %s", "Your warship reached veterancy %d",
	"%s's warships are capturing your trade ships", "Your warship captured a trade ship from %s"]
const NOTE_KIND := ["bad", "good", "bad", "good", "good", "bad", "good"]

# one batch: the rng, the events in order, the ships, shells, targets, posts and stats
func _lapply(out: Dictionary, st: Dictionary) -> bool:
	var hi: int = int(out.rhi)
	if hi >= 0x80000000: hi -= 0x100000000
	g.rng.state = hi * 0x100000000 + int(out.rlo)
	var bt_ids: PackedInt64Array = st.bt_ids
	var tr_ids: PackedInt64Array = st.tr_ids
	var lports: Array = st.lports
	var ev: PackedFloat64Array = (out.ev as PackedByteArray).to_float64_array()
	var ntp: PackedFloat64Array = (out.ntp as PackedByteArray).to_float64_array()
	var npk := 0
	var k := 0
	while k < ev.size():
		var code := int(ev[k])
		match code:
			1:
				g.sfx("warship_shot", -4.0, 0.06, g.PLAYER); k += 1
			2:
				g.sfx("warship_lost"); k += 1
			3:
				var n := int(ev[k + 1]) - 1
				var arg := int(ev[k + 2])
				g.notify(NOTES[n] % (arg if n == 4 else g._nname(arg)), NOTE_KIND[n]); k += 3
			4:
				g.shells.append({"pos": Vector2(ev[k + 1], ev[k + 2]), "t": 0.0}); k += 3
			5:
				var i := bt_ids.find(int(ev[k + 1]))
				if i < 0: return _no(1)
				g.boats.remove_at(i); bt_ids.remove_at(i); k += 2
			6:
				var uid := int(ev[k + 1])
				var i := -1
				for j in g.warships.size():
					if int(g.warships[j].uid) == uid: i = j; break
				if i < 0: return _no(2)
				g.warships.remove_at(i); k += 2
			7:
				var i := tr_ids.find(int(ev[k + 1]))
				if i < 0: return _no(3)
				st.tr_gone[tr_ids[i]] = g.traders[i]
				g.traders.remove_at(i); tr_ids.remove_at(i); k += 2
			8:
				var id := int(ev[k + 1])
				var n := int(ev[k + 6])
				var pts := PackedVector2Array()
				pts.resize(n)
				for m in n: pts[m] = Vector2(ntp[npk + 2 * m], ntp[npk + 2 * m + 1])
				npk += 2 * n
				var cum := PackedFloat32Array([0.0])
				for m in range(1, pts.size()): cum.append(cum[m - 1] + pts[m].distance_to(pts[m - 1]))
				var sailed: float = ev[k + 5]
				var gold := floorf(R.trade_gold(sailed + cum[cum.size() - 1] / g.TS))
				var tr := {"o": int(ev[k + 3]), "pts": pts, "cum": cum, "d": 0.0, "dst": lports[int(ev[k + 2])],
					"gold": gold, "orig": int(ev[k + 4]), "sailed": sailed}
				g.traders.append(tr); tr_ids.append(id); _tr_sent[id] = true  # Luau made its points
				k += 7
			_:
				return _no(4)
	# the ships, in the list's order
	var so: PackedFloat64Array = (out.ships as PackedByteArray).to_float64_array()
	var ws_by: Dictionary = st.ws_by
	k = 0
	var wi := 0
	while k < so.size():
		if wi >= g.warships.size(): return _no(5)
		var ws: Dictionary = g.warships[wi]
		wi += 1
		if int(ws.uid) != int(so[k]): return _no(6)
		var pos := Vector2(so[k + 1], so[k + 2])
		if ws.pos != pos: ws.pos = pos
		var tgt := Vector2(so[k + 3], so[k + 4])
		if ws.tgt != tgt: ws.tgt = tgt
		if float(ws.hp) != so[k + 5]: ws.hp = so[k + 5]
		if int(ws.max_hp) != int(so[k + 6]): ws.max_hp = int(so[k + 6])
		if int(ws.vet) != int(so[k + 7]): ws.vet = int(so[k + 7])
		if int(ws.vet_p) != int(so[k + 8]): ws.vet_p = int(so[k + 8])
		if int(ws.last_shot) != int(so[k + 9]): ws.last_shot = int(so[k + 9])
		if int(ws.state) != int(so[k + 10]): ws.state = int(so[k + 10])
		var pk := int(so[k + 11])
		var port = lports[pk] if pk >= 0 else null
		if not is_same(ws.port, port): ws.port = port
		if float(ws.heal_rem) != so[k + 12]: ws.heal_rem = so[k + 12]
		var near: bool = so[k + 13] != 0.0
		if bool(ws.near_port) != near: ws.near_port = near
		if int(ws.np_tick) != int(so[k + 14]): ws.np_tick = int(so[k + 14])
		var fl := int(so[k + 15])
		var nt := Vector2(so[k + 16], so[k + 17])
		var ni := int(so[k + 18])
		var nr := int(so[k + 19])
		k += 20
		var route = null
		if nr >= 0:
			var r := PackedVector2Array()
			r.resize(nr)
			for m in nr: r[m] = Vector2(so[k + 2 * m], so[k + 2 * m + 1])
			route = r
			k += 2 * nr
		# the keys in the order sim/nav.gd steer() leaves them: nav_r, nav_t, nav_i set together, nav_r erased alone
		if fl & 1:
			if route != null: ws["nav_r"] = route
			elif not ws.has("nav_r"): return _no(7)
		if fl & 2 and (not ws.has("nav_t") or ws.nav_t != nt): ws["nav_t"] = nt
		if fl & 4 and (not ws.has("nav_i") or int(ws.nav_i) != ni): ws["nav_i"] = ni
		if not (fl & 1) and ws.has("nav_r"): ws.erase("nav_r")
		var ns := int(so[k])
		k += 1
		var sh: Dictionary = ws.shelled
		for m in range(sh.size(), ns): sh[int(so[k + m])] = true
		k += ns
	if wi != g.warships.size(): return _no(8)
	# shells: an index into the list before this batch, or a new one
	var old := shells.duplicate()
	shells.clear()
	var sho: PackedFloat64Array = (out.shells as PackedByteArray).to_float64_array()
	k = 0
	while k < sho.size():
		var src := int(sho[k])
		if src >= 0:
			if src >= old.size(): return _no(9)
			shells.append(old[src])
			k += 1
			continue
		var post: bool = sho[k + 11] != 0.0
		var shooter = st.lposts[int(sho[k + 2])] if post else ws_by.get(int(sho[k + 1]))
		var tid := int(sho[k + 5])
		var tg: Dictionary
		if int(sho[k + 4]) == 0: tg = {"kind": "boat", "ref": st.boat_by.get(tid)}
		else: tg = {"kind": "ws", "ref": ws_by.get(tid)}
		if shooter == null or tg.ref == null: return _no(10)
		var s := {"shooter": shooter, "o": int(sho[k + 3]), "target": tg, "t1": int(sho[k + 6]), "dmg": int(sho[k + 7]),
			"from": Vector2(sho[k + 8], sho[k + 9]), "t0": int(sho[k + 10])}
		if post: s["post"] = true
		shells.append(s)
		k += 12
	# targets
	var oldt := tref.duplicate()
	tref.clear()
	var tro: PackedFloat64Array = (out.tref as PackedByteArray).to_float64_array()
	k = 0
	while k < tro.size():
		var uid := int(tro[k])
		var kind := int(tro[k + 1])
		var id := int(tro[k + 2])
		var o = oldt.get(uid)
		var ref = null
		if id >= 0: ref = st.boat_by.get(id) if kind == 0 else (ws_by.get(id) if kind == 1 else _tr_ref(st, id))
		if ref == null:
			# a target that left its list before this tick: the GDScript keeps it until the ship looks again
			if o == null or o.kind != KINDS[kind]: return _no(11)
			ref = o.ref
		if o != null and o.kind == KINDS[kind] and is_same(o.ref, ref): tref[uid] = o
		else: tref[uid] = {"kind": KINDS[kind], "ref": ref}
		k += 3
	var pl: PackedFloat64Array = (out.pl as PackedByteArray).to_float64_array()
	k = 0
	while k < pl.size():
		_post_last[int(pl[k])] = int(pl[k + 1]); k += 2
	for key in (out.ps as PackedByteArray).to_float64_array(): _post_shelled[int(key)] = true
	var sv: PackedFloat64Array = (out.st as PackedByteArray).to_float64_array()
	stats.shots = int(sv[0]); stats.sunk_transports = int(sv[1]); stats.sunk_warships = int(sv[2])
	stats.captures = int(sv[3]); stats.post_shots = int(sv[4]); stats.rerouted = int(sv[5])
	_next_id = int(out.next_tid)
	var cm := int(out.cap_msg)
	if cm != int(_capture_msg.get(g.PLAYER, -1000)): _capture_msg[g.PLAYER] = cm
	return true
