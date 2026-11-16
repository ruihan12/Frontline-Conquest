# The world view surface the UI calls through UICtx.world_call (upstream: Map/MapView as the UI
# uses it), over main.gd's camera. Grows as the map layers are ported.
class_name RWWorld
extends RefCounted

var g  # main.gd
var input_enabled := true
var _tween: Tween = null


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


## Glide the camera to the middle of an owner's land.
func focus_owner(id: int) -> void:
	if id <= 0 or id >= g.nations.size():
		return
	var n: Dictionary = g.nations[id]
	if int(n.get("land", 0)) <= 0:
		return
	var land := maxf(1.0, float(n.land))
	_glide(Vector2(n.sx / land, n.sy / land) * g.TS, 0.42)


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


func set_hover_owner(id: int) -> void:
	if g.ranges != null:
		g.ranges.set_hover_owner(id)
	if g.names != null:
		g.names.hover_owner = id
