extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://main.tscn").instantiate()
	game.nations = [{}, {"name": "Test", "color": Color.RED, "land": 10, "sx": 30.0, "sy": 20.0}]
	game.structs = [{"k": 4, "o": 1, "tile": 2, "shots": [2, 5]}]
	game.boats = [{"uid": 2, "pts": PackedVector2Array([Vector2.ZERO, Vector2.RIGHT]), "cum": PackedFloat32Array([0, 1]), "d": 1.0}]
	game.warships = [{"uid": 3, "pos": Vector2.RIGHT, "_draw_previous": Vector2.ZERO,
		"_draw_received": 100, "_draw_duration": 100}]
	game.missiles = [{"o": 1, "nk": SimRules.N_ATOM, "from": Vector2.ZERO, "to": Vector2(10, 4),
		"dur": 3.0, "t": 1.0, "r": 3.0}]
	game.attacks = [{"aid": 4, "a": 1, "t": 2, "troops": 90.0, "last": 20, "front": {}}]
	game.sim_rules = SimRules.new()
	game.tile_snapshot = game.TileSnapshot.new()
	game._publish_render_records()
	game._animate_labels(0.1)
	var label_center: Vector2 = game._fallback_label_motion[1].center
	var detached_label: bool = label_center == Vector2(7, 5) \
		and not game.nations[1].has("lp") and not game.nations[1].has("ls")
	game.attacks[0].troops = 70.0
	var state := RWGameState.new(game)
	var attack: Dictionary = state.attacks()[0]
	var detached_attack: bool = attack.troops == 90.0 and attack.anchor_tile == 20 \
		and attack.raw.is_read_only() and not attack.raw.has("front")
	var owners: Array = game._render_nations()
	var buildings: Array = game._render_structures()
	game.nations[1].land = 11
	game.structs[0].shots.append(8)
	var boats: Array = game._render_boats()
	var ships: Array = game._render_warships()
	game.boats[0].pts[1] = Vector2.UP
	game.warships[0].pos = Vector2.DOWN
	var motion = preload("res://client/map/viewer_motion.gd")
	var unit_records: bool = boats[0].pts[1] == Vector2.RIGHT and boats[0].is_read_only() \
		and motion.sample(ships[0], "pos", 150.0) == Vector2(0.5, 0.0)
	var missile: Dictionary = game._render_records.missiles[0]
	var position: Vector2 = game._missile_world_pos(missile, 0.5)
	var expected: Vector2 = game._missile_world_pos(game.missiles[0], 0.5)
	game.missiles[0].t = 2.0
	var projectile: bool = missile.is_read_only() and not missile.has("arc") \
		and missile.t == 1.0 and position.is_equal_approx(expected)
	var detached: bool = owners[1].land == 10 and buildings[0].shots == [2, 5]
	var readonly: bool = owners.is_read_only() and owners[1].is_read_only() \
		and buildings.is_read_only() and buildings[0].is_read_only() and buildings[0].shots.is_read_only()
	game._publish_render_records()
	var published: bool = game._render_nations()[1].land == 11 \
		and game._render_structures()[0].shots == [2, 5, 8] and state.attacks()[0].troops == 70.0
	game._reset_tile_snapshot()
	var reset: bool = game._render_records == null and game._fallback_label_motion.is_empty()
	game.free()
	var passed := detached and readonly and published and reset and unit_records and projectile \
		and detached_attack and detached_label
	print("RENDER_RECORDS ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
