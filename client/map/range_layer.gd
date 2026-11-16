# Port of src/client/Map/RangeLayer.luau: range rings on the map.
# SAM interception cover and defense-post (artillery, airfield) radius, the prospective ring while
# placing one, and the selected warship's patrol / targeting rings:
#   mode "auto" (default): own SAMs / posts faint, fading out as the view pulls back; while aiming
#   a nuke the hostile SAMs within NEAR_AIM x their range of the aim tile (red-tinted) and those
#   covering it (hot: thicker, pulsing; aim_sams() counts them); boat aim / "attack_aim": the
#   target owner's posts; hovered / focused sites; the build preview ring (+ own rings of that
#   kind at full strength). "nuke_aim", "all", "none" as upstream.
#
# Upstream keeps pooled GUI circles and is told of structure events; here the rings are drawn with
# draw_arc each frame and the site list is re-read from the game state when its structures change.
# The port's own launch-range rings (silo reach, blast radius at the pointer) stay in main.gd.
class_name RangeLayer
extends Control

const NEAR_AIM := 2.0
const MAX_RINGS := 300
const C_OWN_SAM := 0
const C_OWN_DEF := 1
const C_OWN_HI := 2
const C_HOSTILE := 3
const C_HOT := 4
const C_FOCUS := 5
const C_BUILD := 6
const C_ALL := 7
const C_PENDING := 8
const RING_A := [0.62, 0.55, 0.92, 0.62, 1.0, 0.95, 1.0, 0.6, 0.7]
const WIDTH := [1.5, 1.5, 2.0, 2.0, 3.0, 2.2, 2.6, 1.5, 1.6]
const FILL_A := [0.045, 0.04, 0.075, 0.03, 0.055, 0.085, 0.2, 0.03, 0.0]
const PULSE := [false, false, false, false, true, false, true, false, false]
## camera "distance" (MapCamera.scale_to_distance) over which own rings fade out
const OWN_SAM_FADE := [1.9, 2.5]
const OWN_DEF_FADE := [1.42, 1.72]
const RINGED := [Defs.S_SAM, Defs.S_DEFENSE, Defs.S_ARTILLERY, Defs.S_AIRFIELD]
const HOSTILE_TINT := Color(1.0, 0.2, 0.16)
const HOT_COLOR := Color(1.0, 0.2625, 0.2075)  # HOSTILE_TINT lerped 0.25 toward (1, 0.45, 0.35)

var g  # main.gd
var st: RWGameState
var mode := "auto"
var _sites := {}  # sid -> [kind, owner, tile]
var _lvl := {}  # sid -> [level, active_tick, upgrade_tick]
var _hot := {}
var _hot_n := 0
var _aim_kind := ""
var _aim_tile := -1
var _aim_detail := ""
var _aim_level := 1
var _range_owner := 0
var _hover_owner := 0
var _hover_focus := -1
var _ui_focus := -1
var _want: Array = []  # [tile, r, cls, col]
var _dirty := true
var _unit := {}
var _now := 0.0
var _seen_structs: Array = []
var _seen_tick := -1


func _init(main, state: RWGameState) -> void:
	g = main
	st = state
	name = "Ranges"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func unbind() -> void:
	_sites.clear()
	_lvl.clear()
	_hot.clear()
	_hot_n = 0
	_hover_focus = -1
	_ui_focus = -1
	_want.clear()
	_unit = {}
	_seen_tick = -1


## Re-reads the ringed structures (upstream: reload plus the on_structure_* handlers).
func reload() -> void:
	var cur := int(st.tick)
	var live := {}
	for s in st.structures():
		if not RINGED.has(int(s.kind)):
			continue
		var sid := int(s.sid)
		live[sid] = true
		_sites[sid] = [int(s.kind), int(s.owner), int(s.tile)]
		var was = _lvl.get(sid)
		if was == null:
			_lvl[sid] = [int(s.level), int(s.active_tick), -100000]
		elif int(was[0]) != int(s.level) or int(was[1]) != int(s.active_tick):
			# a level gained starts the range growing from now
			_lvl[sid] = [int(s.level), int(s.active_tick), cur if int(s.level) > int(was[0]) else int(was[2])]
	for sid2 in _sites.keys():
		if not live.has(sid2):
			_sites.erase(sid2)
			_lvl.erase(sid2)
	_dirty = true


func set_mode(m: String) -> void:
	if m != mode:
		mode = m
		_dirty = true


## kind: "", "build", "nuke" or "boat"; detail: the build / nuke kind's name. Returns aim_sams().
func set_aim(kind: String, tile: int, detail: String = "", level: int = 1) -> int:
	var lv := maxi(level, 1)
	if kind != _aim_kind or tile != _aim_tile or detail != _aim_detail or lv != _aim_level:
		_aim_kind = kind
		_aim_tile = tile
		_aim_detail = detail
		_aim_level = lv
		_dirty = true
		_update_hot()
	return _hot_n


## Hostile SAMs covering the nuke aim.
func aim_sams() -> int:
	return _hot_n


func set_range_owner(id: int) -> void:
	if id != _range_owner:
		_range_owner = id
		_dirty = true


func set_hover_owner(id: int) -> void:
	if id != _hover_owner:
		_hover_owner = id
		if mode == "attack_aim" and _range_owner == 0:
			_dirty = true


func set_hover_tile(tile: int, px_tiles: float) -> void:
	var f := _sites_near(tile, px_tiles)
	if f != _hover_focus:
		_hover_focus = f
		_dirty = true


func set_focus_tile(tile: int, px_tiles: float) -> void:
	var f := _sites_near(tile, px_tiles)
	if f != _ui_focus:
		_ui_focus = f
		_dirty = true


## The selected warship: its patrol ring (around `pu, pv`) and targeting ring (around the ship).
func set_unit_rings(pu: float, pv: float, patrol_r: float, au: float, av: float, target_r: float, col: Color) -> void:
	_unit = {"pu": pu, "pv": pv, "patrol_r": patrol_r, "au": au, "av": av, "target_r": target_r,
		"patrol_col": col.lerp(Color.WHITE, 0.4), "target_col": col.lerp(Color.WHITE, 0.3)}


func clear_unit_rings() -> void:
	_unit = {}


func _build_kind() -> int:
	var ak := _aim_kind
	if ak == "build" or ak.begins_with("build:"):
		var k := _aim_detail if _aim_detail != "" else ak.substr(6)
		match k:
			"sam":
				return Defs.S_SAM
			"defense":
				return Defs.S_DEFENSE
			"factory":
				return Defs.S_FACTORY
			"artillery":
				return Defs.S_ARTILLERY
			"airfield":
				return Defs.S_AIRFIELD
	elif ak == "sam":
		return Defs.S_SAM
	elif ak == "defense":
		return Defs.S_DEFENSE
	return -1


func _nuke_kind() -> int:
	return Defs.NUKE_NAMES.find(_aim_detail)


func _hostile(owner_id: int, local_id: int) -> bool:
	return owner_id != local_id and not st.are_allies(owner_id, local_id)


func _range_of(sid: int, kind: int, cur: int) -> float:
	if kind == Defs.S_ARTILLERY:
		return ViewRules.artillery_range()
	if kind == Defs.S_AIRFIELD:
		return ViewRules.airfield_range()
	if kind != Defs.S_SAM:
		return ViewRules.defense_range()
	var l: Array = _lvl.get(sid, [1, 0, -100000])
	return ViewRules.sam_range_at(int(l[0]), cur - int(l[2]))


func _update_hot() -> void:
	_hot.clear()
	_hot_n = 0
	if _aim_kind != "nuke" or _aim_tile < 0:
		return
	var nk := _nuke_kind()
	var mirv := nk == Defs.N_MIRV
	if nk >= 0 and ViewRules.intercept_p(Defs.N_WARHEAD if mirv else nk) <= 0.0:
		return
	var local_id: int = st.local_owner
	var cur := int(st.tick)
	var tg: int = st.tile_owner(_aim_tile) if mirv else 0
	var spread: float = ViewRules.nuke_radii(Defs.N_MIRV).y
	var w: int = st.map.W
	var h: int = st.map.H
	for sid: int in _sites:
		var s: Array = _sites[sid]
		var l = _lvl.get(sid)
		if s[0] != Defs.S_SAM or not _hostile(s[1], local_id) or (l != null and int(l[1]) > cur):
			continue
		var r := _range_of(sid, s[0], cur)
		var d2 := ViewRules.range_d2(s[2], _aim_tile, w, h)
		if d2 <= r * r or (mirv and tg != 0 and s[1] == tg and d2 <= (spread + r) * (spread + r)):
			_hot[sid] = true
			_hot_n += 1


func _sites_near(tile: int, px_tiles: float) -> int:
	if tile < 0:
		return -1
	var w: int = st.map.W
	var rr := maxf(px_tiles, 1.5)
	var best := rr * rr
	var best_sid := -1
	var tx := tile % w
	@warning_ignore("integer_division")
	var ty := tile / w
	for sid: int in _sites:
		var t: int = _sites[sid][2]
		var dx := t % w - tx
		@warning_ignore("integer_division")
		var dy := t / w - ty
		var d := float(dx * dx + dy * dy)
		if d <= best:
			best = d
			best_sid = sid
	return best_sid


func _rebuild() -> void:
	_want.clear()
	var local_id: int = st.local_owner
	var cur := int(st.tick)
	var auto := mode != "none"
	var aiming_nuke := _aim_kind == "nuke" and _aim_tile >= 0
	var nuke_aim := (aiming_nuke and mode != "none") or mode == "nuke_aim"
	var atk := 0
	if _aim_kind == "boat" and _aim_tile >= 0:
		atk = st.tile_owner(_aim_tile)
	elif mode == "attack_aim":
		atk = _range_owner if _range_owner != 0 else _hover_owner
	if atk == local_id:
		atk = 0
	var bk := _build_kind()
	var upgrading := bk >= 0 and _aim_tile >= 0 and _aim_level > 1
	var near2 := NEAR_AIM * NEAR_AIM
	var w: int = st.map.W
	var h: int = st.map.H
	for sid: int in _sites:
		if _want.size() >= MAX_RINGS - 1:
			break
		var s: Array = _sites[sid]
		if upgrading and s[2] == _aim_tile and s[0] == bk:
			continue
		var l: Array = _lvl.get(sid, [1, 0, -100000])
		var pending := int(l[1]) > cur
		var r := _range_of(sid, s[0], cur)
		var own: bool = local_id != 0 and s[1] == local_id
		var hostile := not own and _hostile(s[1], local_id)
		var cls := -1
		if s[0] == Defs.S_SAM:
			if nuke_aim and hostile:
				if _hot.has(sid):
					cls = C_HOT
				elif not aiming_nuke or ViewRules.range_d2(s[2], _aim_tile, w, h) <= near2 * r * r:
					cls = C_HOSTILE
			elif own and bk == Defs.S_SAM:
				cls = C_OWN_HI
			elif own and auto:
				cls = C_OWN_SAM
		elif s[0] == Defs.S_ARTILLERY:
			if own and bk == Defs.S_ARTILLERY:
				cls = C_OWN_HI
			elif own and auto:
				cls = C_OWN_DEF
		elif s[0] == Defs.S_AIRFIELD:
			if own and (bk == Defs.S_AIRFIELD or (aiming_nuke and _aim_detail == "airstrike")):
				cls = C_OWN_HI
		else:
			if atk != 0 and s[1] == atk:
				cls = C_HOSTILE
			elif own and bk == Defs.S_DEFENSE:
				cls = C_OWN_HI
			elif own and auto:
				cls = C_OWN_DEF
		if (cls < C_HOSTILE or cls == C_ALL) and ((auto and _hover_focus == sid) or _ui_focus == sid):
			cls = C_FOCUS
		if cls < 0 and mode == "all":
			cls = C_ALL
		if cls < 0:
			continue
		if pending:
			cls = C_PENDING
		var col: Color = st.owner_color(s[1])
		if cls == C_OWN_SAM or cls == C_OWN_DEF or cls == C_OWN_HI:
			col = col.lerp(Color.WHITE, 0.4)
		elif cls == C_HOSTILE:
			col = col.lerp(HOSTILE_TINT, 0.62)
		elif cls == C_HOT:
			col = HOT_COLOR
		elif cls == C_FOCUS:
			col = col.lerp(HOSTILE_TINT, 0.55) if hostile else col.lerp(Color.WHITE, 0.3)
		else:
			col = col.lerp(HOSTILE_TINT, 0.35) if hostile else col.lerp(Color.WHITE, 0.3)
		_want.append([s[2], r, cls, col, sid])
	if bk >= 0 and _aim_tile >= 0:
		var br: float
		if bk == Defs.S_SAM:
			br = ViewRules.sam_range(_aim_level)
		elif bk == Defs.S_FACTORY:
			br = float(g.FACTORY_RANGE)
		elif bk == Defs.S_ARTILLERY:
			br = ViewRules.artillery_range()
		elif bk == Defs.S_AIRFIELD:
			br = ViewRules.airfield_range()
		else:
			br = ViewRules.defense_range()
		_want.append([_aim_tile, br, C_BUILD, Color.WHITE, -1])


static func smoothstep01(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _process(dt: float) -> void:
	if not is_visible_in_tree() or g.nations.size() < 2:
		return
	_now += dt
	var structs: Array = st.structures()
	var cur := int(st.tick)
	if cur != _seen_tick or structs.size() != _seen_structs.size():
		_seen_tick = cur
		_seen_structs = structs
		reload()
	if _dirty:
		_dirty = false
		_update_hot()
		_rebuild()
	queue_redraw()


func _ring(u: float, v: float, radius: float, cls: int, col: Color, k: float) -> void:
	var scale_px: float = g.cam.zoom.x * g.TS
	var sp: Vector2 = g._screen_of(Vector2(u, v) * g.TS)
	var d := radius * 2.0 * scale_px
	var vp := get_viewport_rect().size
	var m := d * 0.5
	if d < 4.0 or k <= 0.01 or sp.x < -m or sp.y < -m or sp.x > vp.x + m or sp.y > vp.y + m:
		return
	var pulse := 0.5 + 0.5 * sin(_now * 5.0) if PULSE[cls] else 0.0
	var fill_a: float = FILL_A[cls] * k * (1.0 + 0.3 * pulse)
	if fill_a > 0.001:
		draw_circle(sp, d * 0.5, Color(col, fill_a))
	var width: float = WIDTH[cls] * (1.0 + 0.25 * pulse)
	draw_arc(sp, d * 0.5, 0.0, TAU, clampi(int(d * 0.4), 32, 160), Color(col, RING_A[cls] * k), width, true)


func _draw() -> void:
	if g.nations.size() < 2:
		return
	var w: int = st.map.W
	var scale_px: float = g.cam.zoom.x * g.TS
	var cam_d := 1.0 + MapCamera.DIST_K * get_viewport_rect().size.y / maxf(scale_px, 1e-3)
	var k_sam := 1.0 - smoothstep01(OWN_SAM_FADE[0], OWN_SAM_FADE[1], cam_d)
	var k_def := 1.0 - smoothstep01(OWN_DEF_FADE[0], OWN_DEF_FADE[1], cam_d)
	var cur := int(st.tick)
	for wt: Array in _want:
		var k := 1.0
		if wt[2] == C_OWN_SAM:
			k = k_sam
		elif wt[2] == C_OWN_DEF:
			k = k_def
		var r: float = wt[1]
		# a SAM's range grows for a while after an upgrade
		if int(wt[4]) >= 0 and _sites.has(wt[4]) and _sites[wt[4]][0] == Defs.S_SAM:
			r = _range_of(wt[4], Defs.S_SAM, cur)
		var t: int = wt[0]
		@warning_ignore("integer_division")
		_ring(t % w + 0.5, t / w + 0.5, r, wt[2], wt[3], k)
	if not _unit.is_empty():
		if float(_unit.patrol_r) > 0.0:
			_ring(_unit.pu, _unit.pv, _unit.patrol_r, C_OWN_HI, _unit.patrol_col, 1.0)
		_ring(_unit.au, _unit.av, _unit.target_r, C_FOCUS, _unit.target_col, 1.0)
