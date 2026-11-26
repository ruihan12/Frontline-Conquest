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

class GameProbe extends "res://main.gd":
	var events := []
	func _sim_frame_budget_us() -> int:
		return 1000000
	func _drain_sim_intents() -> void:
		events.append("intents")
	func _rebuild_def_posts() -> void:
		events.append("defenses")
	func _economy(_dt: float) -> void:
		events.append("economy")
	func _tick_missiles(_dt := 0.0) -> void:
		events.append("missiles")
	func _requests_tick() -> void:
		events.append("requests")
	func _trains_tick() -> void:
		events.append("trains")

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
	var passed := attack_paused and ai_paused and complete and game.events == expected
	print("FIXED_TICK_SCHEDULE ", "PASS" if passed else "FAIL")
	if not passed: print(game.events)
	game.free()
	quit(0 if passed else 1)
