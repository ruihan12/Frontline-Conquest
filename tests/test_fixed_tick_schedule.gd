extends SceneTree

class AttackProbe extends SimAttacks:
	func begin_tick() -> void:
		g.events.append("attack_start")
	func run_slice(_deadline: int) -> bool:
		g.events.append("attack_slice")
		return g.events.count("attack_slice") > 1

class AIProbe extends SimAI:
	func begin_tick() -> void:
		g.events.append("ai_start")
	func run_slice(_deadline_us: int) -> bool:
		g.events.append("ai_slice")
		return g.events.count("ai_slice") > 1

class NavalProbe extends SimNaval:
	func tick() -> void:
		g.events.append("naval")

class ArsenalProbe extends SimArsenal:
	func tick() -> void:
		g.events.append("arsenal")

class WarshipProbe extends SimWarships:
	func tick() -> void:
		g.events.append("warships")

class HostProbe extends RefCounted:
	var events: Array
	func _init(log: Array) -> void:
		events = log
	func on_tick() -> void:
		events.append("replicate")

class EconomyProbe extends EconomyWorker:
	var allow_publish := false
	func ready() -> bool:
		return allow_publish and super.ready()

class GameProbe extends "res://main.gd":
	var events := []
	var frames := []
	var effects_frames := []
	func _sim_frame_budget_us() -> int:
		return 1000000
	func _drain_sim_intents() -> void:
		events.append("intents")
	func _rebuild_def_posts() -> void:
		events.append("defenses")
	func _economy(_dt: float) -> void:
		events.append("economy")
	func _economy_begin() -> void:
		events.append("economy_begin")
		super._economy_begin()
	func _tick_missiles(_dt := 0.0) -> void:
		events.append("missiles")
	func _requests_tick() -> void:
		events.append("requests")
	func _trains_tick() -> void:
		events.append("trains")
	func _advance_sim_frame(dt: float, tdt: float, advance_effects := true) -> void:
		frames.append([dt, tdt])
		if advance_effects:
			_advance_frame_effects(dt, tdt)
	func _advance_frame_effects(dt: float, tdt: float) -> void:
		effects_frames.append([dt, tdt])

func _check_held_frames(game: GameProbe) -> bool:
	game._tick_stage = 3
	var first := game._advance_or_hold_sim_frame(0.013, 0.026)
	var paused := game._advance_or_hold_sim_frame(0.0, 0.0)
	var held := not first and not paused and game.frames.is_empty() \
		and game.effects_frames == [[0.013, 0.026], [0.0, 0.0]]
	game._tick_stage = 0
	var resumed := game._advance_or_hold_sim_frame(0.016, 0.032)
	var ordered := game.frames == [[0.013, 0.026], [0.0, 0.0], [0.016, 0.032]] \
		and game.frames == game.effects_frames
	game.frames.clear()
	game._tick_stage = 3
	game._advance_or_hold_sim_frame(0.5, 1.0)
	game._stop_sim_workers()
	game._advance_or_hold_sim_frame(0.01, 0.02)
	return held and resumed and ordered and game.frames == [[0.01, 0.02]]

func _check_economy_worker() -> bool:
	var game := GameProbe.new()
	var rules := SimRules.new()
	game.sim_rules = rules
	game.sim_atk = AttackProbe.new(game, rules)
	game.sim_ai = AIProbe.new(game, rules)
	game.sim_naval = NavalProbe.new(game, rules)
	game.sim_ars = ArsenalProbe.new(game, rules)
	game.sim_ws = WarshipProbe.new(game, rules)
	game.state = "play"
	game.tile_pop = PackedFloat32Array([1200.0])
	game.nations = [{},
		{"alive": true, "land": 20, "troops": 10000.0, "gold": 120.0, "reinf_cd": 1.0, "pop": 1200.0},
		{"alive": true, "land": 12, "troops": 1000.0, "gold": 50.0, "reinf_cd": 0.02, "pop": 800.0}]
	var worker := EconomyProbe.new()
	game._economy_worker = worker
	game._advance_fixed_ticks(0.1)
	game._advance_fixed_ticks(0.0)
	game._advance_fixed_ticks(0.0)
	var suspended: bool = game._tick_stage == 4 and game.events.count("economy_begin") == 1 \
		and not game.events.has("arsenal") and game.nations[1].gold == 120.0
	var held := not game._advance_or_hold_sim_frame(0.01, 0.02) and game.frames.is_empty()
	game.nations[2].gold += 200.0
	var reference := GameProbe.new()
	reference.sim_rules = rules
	reference.state = game.state
	reference.tile_pop = game.tile_pop.duplicate()
	reference.nations = game.nations.duplicate(true)
	reference._economy_finish(0.1)
	worker.allow_publish = true
	var deadline := Time.get_ticks_msec() + 2000
	while not worker.ready() and Time.get_ticks_msec() < deadline:
		OS.delay_usec(100)
	game._advance_fixed_ticks(0.0)
	var finished := game._tick_stage == 0 and game.events.count("economy_begin") == 1 \
		and game.events.count("arsenal") == 1 and game.ticks_done == 1
	var matches := game._economy_worker_rows == 1 and game.nations == reference.nations
	reference.free()
	var gold: float = game.nations[1].gold
	var pending := worker.submit(game, 0.1)
	game._tick_stage = 4
	game._stop_sim_workers()
	var discarded: bool = pending and game._tick_stage == 0 and not worker.ready() \
		and game.nations[1].gold == gold and game._held_sim_frames.is_empty()
	game.free()
	return suspended and held and finished and matches and discarded

func _initialize() -> void:
	var game := GameProbe.new()
	var rules := SimRules.new()
	game.sim_atk = AttackProbe.new(game, rules)
	game.sim_ai = AIProbe.new(game, rules)
	game.sim_naval = NavalProbe.new(game, rules)
	game.sim_ars = ArsenalProbe.new(game, rules)
	game.sim_ws = WarshipProbe.new(game, rules)
	game.net_host = HostProbe.new(game.events)
	game._advance_fixed_ticks(0.1)
	var attack_paused := game._tick_stage == 1 and game.ticks_done == 0
	game._advance_fixed_ticks(0.0)
	var ai_paused := game._tick_stage == 2 and game.ticks_done == 0
	game._advance_fixed_ticks(0.0)
	var complete := game._tick_stage == 0 and game.ticks_done == 1
	var expected := ["intents", "defenses", "attack_start", "attack_slice", "attack_slice", "ai_start", "ai_slice", "ai_slice"]
	if not OS.has_environment("NO_TRADE"):
		expected.append("naval")
	expected.append_array(["economy", "arsenal", "missiles", "requests", "warships", "trains", "replicate"])
	var passed := attack_paused and ai_paused and complete and game.events == expected \
		and _check_held_frames(game) and _check_economy_worker()
	print("FIXED_TICK_SCHEDULE ", "PASS" if passed else "FAIL")
	if not passed: print(game.events)
	game.free()
	quit(0 if passed else 1)
