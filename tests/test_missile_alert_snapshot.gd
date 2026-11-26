extends SceneTree

func _initialize() -> void:
	var game = load("res://main.tscn").instantiate()
	game.tile_snapshot = game.TileSnapshot.new()
	game.missiles = [{"sim_uid": 7, "o": 2, "nk": SimRules.N_ATOM, "to": Vector2(10, 4)}]
	var view := RWGameState.new(game)
	game._publish_render_records()
	var old := view.nukes()
	game.missiles[0].to = Vector2(3, 3)
	var detached: bool = old[7].raw.is_read_only() and old[7].raw.to == Vector2(10, 4) \
		and not game.missiles[0].has("cuid")
	game._record_missile_intercept(game.missiles[0])
	game.missiles.clear()
	game._publish_render_records()
	var resolved: bool = view.nukes().is_empty() and view.take_missile_intercepts() == {7: true} \
		and view.take_missile_intercepts().is_empty()
	var passed := detached and resolved
	print("MISSILE_ALERT_SNAPSHOT ", "PASS" if passed else "FAIL")
	game.free()
	quit(0 if passed else 1)
