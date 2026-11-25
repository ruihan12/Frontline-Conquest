extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	# Exercise the real event producers and consumer without starting a match.
	game.state = "play"
	game.fx_layer = FxLayer.new(game, RWGameState.new(game))
	var point := Vector2(12, 23)
	game.notify("immediate", "info")
	game._begin_presentation_batch()
	game.add_float(point, "first", Color.WHITE)
	game.notify("second", "bad")
	game.notify("third", "good")
	game._map_effect("sam", [Vector2(3, 4), 8003])
	var queued: bool = game.floats.is_empty() and game.notes.size() == 1 and game.fx_layer._fx.is_empty()
	game._flush_presentation_batch()
	var applied: bool = game.floats.size() == 1 and game.floats[0].pos == point \
		and game.floats[0].text == "first" and game.notes.size() == 3 \
		and game.notes[0].text == "third" and game.notes[1].text == "second" \
		and game.notes[2].text == "immediate" \
		and game.fx_layer._fx.size() == 1 and game.fx_layer._bursts.size() == 1
	game._begin_presentation_batch()
	game._flush_presentation_batch()
	var drained: bool = game.floats.size() == 1 and game.notes.size() == 3
	game.fx_layer.free()
	game.free()
	var passed := queued and applied and drained
	print("SIM_PRESENTATION ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
