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
