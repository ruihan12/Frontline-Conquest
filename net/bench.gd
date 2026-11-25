class_name SimBench
extends SceneTree

const SCRIPT_PATH := "res://net/bench.gd"
const WORKER_FLAG := "--rofront-benchmark-worker"
const RESULT_PREFIX := "ROFRONT_BENCH_RESULT "


## Run the native benchmark in a separate headless Godot process. The usual
## simulation entry points touch engine globals at startup, so a second node in
## this process would briefly change settings for a running game.
static func run(ticks := 200) -> Dictionary:
	if ticks < 1:
		return _failure("A benchmark needs at least one tick.")
	if OS.has_feature("web"):
		return _failure("The benchmark requires a native Godot process.")
	var output := []
	var executable := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", SCRIPT_PATH, "--", WORKER_FLAG, str(ticks),
	])
	if OS.execute(executable, args, output, false) != 0 or output.is_empty():
		return _failure("The headless benchmark process could not finish.")
	for line in str(output[0]).split("\n"):
		if line.begins_with(RESULT_PREFIX):
			var result = JSON.parse_string(line.substr(RESULT_PREFIX.length()))
			if result is Dictionary and int(result.get("ticks", 0)) == ticks:
				result.ticks = ticks
				return result
	return _failure("The headless process did not return a benchmark result.")


## Average simulation tick time is the hosting criterion. A lower average
## means a higher score (100 divided by the mean tick time in milliseconds).
static func can_host(result: Dictionary, threshold_ms := 40.0) -> bool:
	var average := float(result.get("ms_per_tick", INF))
	return int(result.get("ticks", 0)) > 0 and is_finite(average) and average > 0.0 and average <= threshold_ms


static func _failure(message: String) -> Dictionary:
	return {"ms_per_tick": INF, "worst_ms": INF, "ticks": 0, "score": 0.0, "error": message}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != WORKER_FLAG or not args[1].is_valid_int() or int(args[1]) < 1:
		quit(1)
		return
	_measure.call_deferred(int(args[1]))


func _measure(ticks: int) -> void:
	var simulation := load("res://main.tscn").instantiate() as Node
	# Keep this run independent of the user's save and difficulty settings.
	var save_file := "user://simbench-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	simulation.save_path = save_file
	root.add_child(simulation)
	await process_frame
	await process_frame
	simulation.rng.seed = 12345
	seed(12345)
	var start: int = simulation.sim_start()
	if start < 0:
		simulation.free()
		quit(1)
		return
	var initial_ticks: int = simulation.ticks_done
	simulation.peace = 0.0
	var total := 0
	var worst := 0
	for _tick in ticks:
		var started := Time.get_ticks_usec()
		simulation.sim_step(1)
		var elapsed := maxi(1, Time.get_ticks_usec() - started)
		total += elapsed
		worst = maxi(worst, elapsed)
	var measured_ticks: int = simulation.ticks_done - initial_ticks
	simulation.free()
	if FileAccess.file_exists(save_file):
		DirAccess.remove_absolute(save_file)
	if measured_ticks != ticks:
		quit(1)
		return
	var mean := total / (1000.0 * ticks)
	print(RESULT_PREFIX + JSON.stringify({
		"ms_per_tick": mean,
		"worst_ms": worst / 1000.0,
		"ticks": ticks,
		"score": 100.0 / mean,
	}))
	quit(0)
