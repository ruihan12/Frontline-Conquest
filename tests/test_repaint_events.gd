extends SceneTree

func _initialize() -> void:
	var game = load("res://main.tscn").instantiate()
	game.W = 3
	game.H = 2
	game.owner_map = PackedInt32Array([0, 0, 4, 0, 3, 0])
	game.fallout = PackedByteArray([1, 0, 0, 0, 0, 0])
	game._repaint(1)
	game.owner_map[2] = 0
	game._repaint(4)
	var expected: PackedInt32Array = game._rp_list.duplicate()
	game._rp_clear()
	game.owner_map[2] = 4
	game.tile_snapshot = game.TileSnapshot.new()
	game._begin_presentation_batch()
	game._repaint(1)
	game.owner_map[2] = 0
	game._repaint(4)
	var queued: bool = not game._paint_pending()
	game._flush_presentation_batch()
	var passed: bool = queued and game._rp_list == expected and expected == PackedInt32Array([1, 2, 0, 4])
	print("REPAINT_EVENTS ", "PASS" if passed else "FAIL")
	game.free()
	quit(0 if passed else 1)
