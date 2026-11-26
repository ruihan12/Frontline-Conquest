extends SceneTree

class SoundRecorder extends Node:
	var clock_ms := 99
	var played := []

	func has_sfx(_key: String) -> bool:
		return true

	func set_clock_ms(value: int) -> void:
		clock_ms = value

	func play_sfx(key: String, _vol: float, _jitter: float, _pitch: float, owner: int, _mine: bool, _button: bool) -> void:
		played.append([key, owner, clock_ms])

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	# Exercise the real event producers and consumer without starting a match.
	game.state = "play"
	game.tile_snapshot = game.TileSnapshot.new()
	var audio := SoundRecorder.new()
	game.audio_dir = audio
	var rng_before: int = game.rng.state
	game.fx_layer = FxLayer.new(game, RWGameState.new(game))
	var point := Vector2(12, 23)
	game.notify("immediate", "info")
	game._begin_presentation_batch()
	game.add_float(point, "first", Color.WHITE)
	game.notify("second", "bad")
	game.notify("third", "good")
	game._map_effect("sam", [Vector2(3, 4), 8003])
	game.sfx("sam_hit")
	audio.clock_ms = 120
	var queued: bool = game.floats.is_empty() and game.notes.size() == 1 and game.fx_layer._fx.is_empty() and audio.played.is_empty()
	game._flush_presentation_batch()
	var applied: bool = game.floats.size() == 1 and game.floats[0].pos == point \
		and game.floats[0].text == "first" and game.notes.size() == 3 \
		and game.notes[0].text == "third" and game.notes[1].text == "second" \
		and game.notes[2].text == "immediate" \
		and game.fx_layer._fx.size() == 1 and game.fx_layer._bursts.size() == 1
	game._begin_presentation_batch()
	game._flush_presentation_batch()
	var drained: bool = game.floats.size() == 1 and game.notes.size() == 3
	var sound: bool = audio.played == [["sam_hit", game.PLAYER, 99]] and audio.clock_ms == 120 \
		and game.rng.state == rng_before
	game.audio_dir = null
	audio.free()
	var voice := AudioStreamPlayer.new()
	var stream := AudioStreamWAV.new()
	game.sfx_pool.append(voice)
	game.sfx_streams["legacy"] = [stream]
	var expected_rng := RandomNumberGenerator.new()
	expected_rng.state = game.rng.state
	expected_rng.randi()
	var pitch := 1.0 + expected_rng.randf_range(-0.04, 0.04)
	game._begin_presentation_batch()
	game.sfx("legacy")
	var legacy_queued: bool = voice.stream == null and game.rng.state == expected_rng.state
	game._flush_presentation_batch()
	var legacy_played: bool = voice.stream == stream and is_equal_approx(voice.pitch_scale, pitch) \
		and game.rng.state == expected_rng.state
	voice.free()
	game.sfx_pool.clear()
	var combat_effects := _check_combat_effects(game)
	game.fx_layer.free()
	game.free()
	var passed := queued and applied and drained and sound and legacy_queued and legacy_played and combat_effects
	print("SIM_PRESENTATION ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)

func _check_combat_effects(game) -> bool:
	var rules := SimRules.new()
	var arsenal := SimArsenal.new(game, rules)
	var navy := SimWarships.new(game, rules)
	game.W = 3
	game.H = 1
	game.owner_map = PackedInt32Array([game.PLAYER, 0, game.WATER])
	game.structs = [{"o": game.PLAYER, "k": 15, "tile": 0, "bt": 0.0}]
	game.no_cd = true
	var ship := {"o": 2, "hp": 1000.0, "pos": Vector2(2.5, 0.5)}
	game.warships = [ship]
	navy.shells.append({"t1": 0, "o": 3, "dmg": 200, "target": {"kind": "ws", "ref": ship}})

	game._begin_presentation_batch()
	var launched := arsenal.launch_strike(game.PLAYER, SimRules.N_SLUG, 1)
	arsenal._munitions_tick(1)
	navy._shells_tick(1)
	var queued: bool = launched and arsenal.munitions.is_empty() and ship.hp == 800.0 \
		and game.beams.is_empty() and game.blasts.is_empty() and game.shells.is_empty() and game.shake_amp == 0.0
	var effects := []
	for event: Array in game._presentation_events:
		if event[0] == "map": effects.append(event[1])
	game._flush_presentation_batch()

	var beam := {"a": Vector2(0.5, 0.5), "b": Vector2(1.5, 0.5), "t": 0.0}
	var blast_position := Vector2(1.5, 0.5) * float(game.TS)
	var shell := {"pos": ship.pos * game.TS, "t": 0.0}
	return queued and effects == ["railgun_beam", "strike_blast", "strike_shake", "shell_impact"] \
		and game.beams == [beam] and game.blasts.size() == 1 \
		and game.blasts[0].pos == blast_position and game.blasts[0].t == 0.0 \
		and game.shells == [shell] and game.shake_amp > 0.0
