extends SceneTree

class TrainFixture extends "res://main.gd":
	var route := [
		PackedVector2Array([Vector2(1, 1), Vector2(6, 1), Vector2(6, 4)]),
		PackedFloat32Array([0, 5, 8]),
	]
	var linked := true

	func _has_rail_link(_from, _to) -> bool:
		return linked

	func _rail_curve(_a: int, _b: int) -> Array:
		return route

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := TrainFixture.new()
	var source := {"tile": 1}
	var destination := {"tile": 15}
	game.trains = [{"o": 1, "src": destination, "dst": source, "t": 2, "dur": 8}]
	var records := game._capture_train_draws()
	var draw: Dictionary = records[0]
	var expected := game._rail_pos(destination, source, 0.25)
	game.route[0][1] = Vector2(9, 9)
	destination.tile = 100
	var sampled := game._rail_pos_on_curve(draw.from_tile, draw.to_tile, 0.25, draw.curve)
	game.linked = false
	var passed: bool = records.is_read_only() and draw.is_read_only() and draw.curve.is_read_only() \
		and sampled == expected and game._capture_train_draws().is_empty()
	game.free()
	print("TRAIN_DRAW_SNAPSHOT ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
