extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	var view := RWGameState.new(game)
	game.owner_map = PackedInt32Array([-1, 1, 0])
	game.fallout = PackedByteArray([0, 0, 0])
	game.tile_snapshot = game.TileSnapshot.new()
	game._publish_tile_snapshot()
	var initialized: bool = view.render_tile_owner(1) == 1 and view.render_tile_owner(0) == 0
	game.owner_map[1] = 2
	game.fallout[2] = 1
	game._record_tile_snapshot(1)
	game._record_tile_snapshot(2)
	game.net_dirty.append(1)
	var detached: bool = view.render_tile_owner(1) == 1 and game._render_owners()[1] == 1 \
		and game._render_fallout()[2] == 0
	game._publish_render_records()
	var applied: bool = view.render_tile_owner(1) == 2 and game.tile_snapshot.has_fallout(2) \
		and game.net_dirty == PackedInt32Array([1])
	game._reset_tile_snapshot()
	game.owner_map = PackedInt32Array([7, 0])
	game.fallout = PackedByteArray([0, 0])
	game._publish_tile_snapshot()
	var reset: bool = view.render_tile_owner(0) == 7 and not game.tile_snapshot.has_fallout(2)
	game.free()
	var passed := initialized and detached and applied and reset
	print("TILE_SNAPSHOT ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
