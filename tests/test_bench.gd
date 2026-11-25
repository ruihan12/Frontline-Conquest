extends SceneTree

const Bench := preload("res://net/bench.gd")
var fails := 0


func _initialize() -> void:
	_test.call_deferred()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL ", what)


func _test() -> void:
	var children := root.get_child_count()
	var old_limit := Engine.max_fps
	Engine.max_fps = 67
	var old_color := RenderingServer.get_default_clear_color()
	var result := Bench.run(4)
	_check(not result.has("error"), str(result.get("error", "")))
	_check(result.ticks == 4, "reported tick count")
	_check(is_finite(result.ms_per_tick) and result.ms_per_tick > 0, "positive mean tick time")
	_check(result.worst_ms >= result.ms_per_tick and is_finite(result.worst_ms), "finite worst tick time")
	_check(is_equal_approx(result.score, 100.0 / result.ms_per_tick), "score is inverse mean tick cost")
	_check(Bench.can_host(result, result.ms_per_tick), "threshold is inclusive")
	_check(not Bench.can_host(result, result.ms_per_tick * 0.5), "slower clients cannot host")
	_check(not Bench.can_host(Bench.run(0)), "invalid run does not qualify")
	_check(root.get_child_count() == children, "no simulation nodes remain in caller")
	_check(Engine.max_fps == 67 and RenderingServer.get_default_clear_color() == old_color, "caller engine settings preserved")
	Engine.max_fps = old_limit
	print("BENCH_TEST %s fails=%d mean=%.3f ms worst=%.3f ms" % [
		"PASS" if fails == 0 else "FAIL", fails, result.ms_per_tick, result.worst_ms,
	])
	quit(1 if fails else 0)
