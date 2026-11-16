# Port of src/client/Map/MapView.luau: the world view the UI calls through UICtx.world_call, and what
# its frame does around the layers:
#   * the API: focus_tile, focus_owner (frames the nation: its diameter about a sixth of the view
#     height, never closer than FOCUS_MAX_ZOOM of the zoom range), tile_at_screen, screen_pos_of_tile,
#     set_hover_owner / set_selected_owner (the surface's highlight waits HOVER_DELAY_S for the pointer
#     to rest), set_selected_unit, set_aim, aim_sams, set_range_*;
#   * update(): the delayed surface hover and the surface's sweeps;
#   * markers: the spawn-phase ring breathing around the local player's placed spawn.
# (Upstream's three ScreenGuis, the layer list and the Roblox camera setup are main.gd's scene here; the
# layers are created in game/map.gd. The aim disk is the game's own drawing: main.gd's build preview.)
class_name MapView
extends RefCounted

const HOVER_DELAY_S := 0.08
const FOCUS_MAX_ZOOM := 0.3
const SPAWN_MIN_RAD := 10.0
const SPAWN_MAX_RAD := 30.0

var g  # main.gd
var input_enabled := true
var _tween: Tween = null
var _hover_owner := 0
var _selected_owner := 0
var _selected_unit := -1
var _want := -1
var _want_at := 0.0
var _aim := {}


func _init(main) -> void:
	g = main


func _tile_world(tile: int) -> Vector2:
	var w: int = g.W
	@warning_ignore("integer_division")
	return Vector2(tile % w + 0.5, tile / w + 0.5) * g.TS


func _glide(target: Vector2, dur: float) -> void:
	if g._mcam_on():
		# the ported camera glides (and pulls back on a long hop)
		g.mcam.focus(target.x / g.TS, target.y / g.TS, 0.0, dur)
		return
	if _tween:
		_tween.kill()
	if g.autoshot or g.bench or dur <= 0.0:
		g.cam.position = target
		g._clamp_cam()
		return
	_tween = g.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(g.cam, "position", target, dur)
	_tween.tween_callback(g._clamp_cam)


## Glide the camera to a tile. `zoom` < 0 keeps the current zoom.
func focus_tile(tile: int, zoom: float = -1.0, dur: float = 0.8) -> void:
	if tile < 0:
		return
	if g._mcam_on():
		g.mcam.focus_tile(tile, zoom * g.TS if zoom > 0 else 0.0, dur)
		return
	if zoom > 0:
		g.cam.zoom = Vector2(zoom, zoom)
	_glide(_tile_world(tile), dur * 0.5)


## Fly to an owner's land, framing it (upstream MapView.focus_owner).
func focus_owner(id: int) -> void:
	if id <= 0 or id >= g.nations.size():
		return
	var n: Dictionary = g.nations[id]
	if int(n.get("land", 0)) <= 0:
		return
	var land := maxf(1.0, float(n.land))
	var centre := Vector2(n.sx / land, n.sy / land)
	if g._mcam_on():
		var rig: MapCamera = g.mcam
		var diam := 2.0 * sqrt(maxf(land, 1.0) / PI)
		var s := rig.viewport_height() / maxf(diam * 6.0, 8.0)
		var lo := rig.min_scale()
		var hi := rig.max_scale()
		s = minf(s, lo + (hi - lo) * FOCUS_MAX_ZOOM)
		rig.focus(centre.x, centre.y, rig.clamp_scale(s), 1.0)
		return
	_glide(centre * g.TS, 0.42)


## Tile under a screen point (-1 if none).
func tile_at_screen(pos: Vector2) -> int:
	var wp: Vector2 = g.get_canvas_transform().affine_inverse() * pos
	var x := int(floor(wp.x / g.TS))
	var y := int(floor(wp.y / g.TS))
	if x < 0 or y < 0 or x >= g.W or y >= g.H:
		return -1
	return y * g.W + x


## Screen position of a tile.
func screen_pos_of_tile(tile: int) -> Vector2:
	if tile < 0:
		return Vector2(-1, -1)
	return g._screen_of(_tile_world(tile))


func set_input_enabled(on: bool) -> void:
	input_enabled = on


## Hostile SAMs whose cover holds `tile` (the aim card's "SAM cover" row).
func aim_sams(tile: int) -> int:
	if tile < 0:
		return 0
	var n := 0
	var w: int = g.W
	@warning_ignore("integer_division")
	var p := Vector2(tile % w, tile / w)
	for st in g.structs:
		if int(st.k) == 4 and int(st.o) != g.PLAYER and not g.allied(g.PLAYER, int(st.o)) and float(st.get("bt", 0.0)) <= 0.0:
			@warning_ignore("integer_division")
			var sp := Vector2(int(st.tile) % w, int(st.tile) / w)
			if sp.distance_to(p) <= float(g.sim_rules.sam_range(int(st.get("level", 1)))):
				n += 1
	return n


## Screen position of a world position given in tiles (a ship between tile centres).
func screen_pos_of_world(pos: Vector2) -> Vector2:
	return g._screen_of(pos * g.TS)


## Highlights warship `uid` on the map (-1 clears); only the player's own ships are steered.
func set_selected_unit(uid: int) -> void:
	g.sel_ws = null
	if uid <= 0:
		uid = -1
	_selected_unit = uid
	if uid < 0:
		if g.ranges != null:
			g.ranges.clear_unit_rings()
		return
	for ws in g.warships:
		if int(ws.get("uid", 0)) == uid and int(ws.o) == int(g.PLAYER):
			g.sel_ws = ws
			return


# ---- range rings (client/map/range_layer.gd) ----
func set_range_mode(m: String) -> void:
	if g.ranges != null:
		g.ranges.set_mode(m)


func set_range_owner(id: int) -> void:
	if g.ranges != null:
		g.ranges.set_range_owner(id)


func set_range_focus(tile: int) -> void:
	if g.ranges != null:
		g.ranges.set_focus_tile(tile, 12.0 / maxf(0.01, g.cam.zoom.x * g.TS))


# ---- highlights, selection, previews ----

func set_hover_owner(id: int) -> void:
	_hover_owner = id
	# (the surface's highlight waits HOVER_DELAY_S for the pointer to rest: update())
	_want_surface_hover(id if id > 0 else _selected_owner, HOVER_DELAY_S)
	if g.names != null:
		g.names.hover_owner = id
	if g.ranges != null:
		g.ranges.set_hover_owner(id)


func set_selected_owner(id: int) -> void:
	_selected_owner = id
	if _hover_owner <= 0:
		_want_surface_hover(id, 0.0)


## The owner the surface is to highlight, once `delay_s` have passed without another being asked for:
## a pointer crossing nations on its way somewhere highlights none of them.
func _want_surface_hover(id: int, delay_s: float) -> void:
	if _want == id:
		return
	_want = id
	_want_at = FrameClock.now() + delay_s


## Aim preview: kind "nuke" / "boat" / "build" / "" (clear); see WorldView.set_aim.
func set_aim(kind: String, tile: int, radius_tiles: float, valid: bool = true, detail: String = "", level: int = 1) -> void:
	if kind == "" or tile < 0 or tile >= g.W * g.H:
		_aim = {}
		if g.ranges != null:
			g.ranges.set_aim("", -1)
		return
	_aim = {"kind": kind, "tile": tile, "outer": maxf(radius_tiles, 0.5), "valid": valid}
	if g.ranges != null:
		g.ranges.set_aim(kind, tile, detail, level)


# ---------------------------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------------------------

## Once a frame (the HUD's process): the surface's delayed hover and its sweeps.
func update(_dt: float) -> void:
	if g.surface == null:
		return
	if _want >= 0 and FrameClock.now() >= _want_at:
		var want := _want
		_want = -1
		g.surface.set_hover(want if g.state != "menu" else 0)
	g.surface.step()


## The spawn-phase ring: breathing between SPAWN_MIN_RAD and SPAWN_MAX_RAD (full-size tiles) around the
## local spawn, at a phase speed of 0.008 per ms (the ring's fill 0.9 transparent, a 2 px stroke).
func draw_markers(ci: CanvasItem) -> void:
	if g.state != "pick" or g.start_tile < 0 or g.nations[g.PLAYER].land <= 0:
		return
	var w: int = g.W
	@warning_ignore("integer_division")
	var c: Vector2 = g._screen_of(Vector2(g.start_tile % w + 0.5, g.start_tile / w + 0.5) * g.TS)
	var col: Color = g.nations[g.PLAYER].color.lerp(Color.WHITE, 0.35)
	var k: float = maxf(0.01, float(g.sim_rules.k_lin))
	var b := 0.5 + 0.5 * sin(FrameClock.now() * 8.0)
	var r := (SPAWN_MIN_RAD + (SPAWN_MAX_RAD - SPAWN_MIN_RAD) * b) / k
	var px := maxf(r * g.cam.zoom.x * g.TS, 3.0)
	ci.draw_circle(c, px, Color(col, 0.1))
	ci.draw_arc(c, px, 0.0, TAU, 48, Color(col, 0.9), 2.0, true)
