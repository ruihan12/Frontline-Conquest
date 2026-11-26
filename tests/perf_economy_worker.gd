# Run with Godot 4.3: godot --headless --path . -s tests/perf_economy_worker.gd
# Measures the pure accrual calculation and the cost of submitting and joining it.
extends SceneTree

class EconomyJob extends RefCounted:
	var rules := SimRules.new()

	func run(rows: PackedFloat64Array) -> PackedFloat64Array:
		var out := PackedFloat64Array()
		out.resize(rows.size() / 6 * 4)
		var offset := 0
		for i in range(0, rows.size(), 6):
			var cap := rules.max_troops(int(rows[i]), int(rows[i + 1]), int(rows[i + 2]), int(rows[i + 3]))
			var troops := rows[i + 4]
			var growth := rules.troop_growth(int(rows[i]), troops, cap, int(rows[i + 3]))
			out[offset] = cap
			out[offset + 1] = growth * 10.0
			out[offset + 2] = troops + (floor(growth) if growth >= 0.0 else -floor(-growth))
			out[offset + 3] = rows[i + 5] + rules.gold_per_tick(int(rows[i]))
			offset += 4
		return out

class Request extends RefCounted:
	var output: PackedFloat64Array
	func work(job: EconomyJob, rows: PackedFloat64Array) -> void:
		output = job.run(rows)

func _initialize() -> void:
	var rows := PackedFloat64Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in 472:
		rows.append_array(PackedFloat64Array([i % 3, rng.randi_range(1, 8000), rng.randi_range(0, 6),
			i % 3, rng.randf_range(0, 5e6), rng.randf_range(0, 15e6)]))
	var main_job := EconomyJob.new()
	var worker_job := EconomyJob.new()
	var expected := main_job.run(rows)
	var inline := PackedInt64Array()
	var threaded := PackedInt64Array()
	for i in 1000:
		var start := Time.get_ticks_usec()
		var direct := main_job.run(rows)
		inline.append(Time.get_ticks_usec() - start)
		start = Time.get_ticks_usec()
		var request := Request.new()
		var task := WorkerThreadPool.add_task(request.work.bind(worker_job, rows.duplicate()))
		WorkerThreadPool.wait_for_task_completion(task)
		threaded.append(Time.get_ticks_usec() - start)
		if direct != expected or request.output != expected:
			push_error("Economy worker result mismatch")
			quit(1)
			return
	inline.sort()
	threaded.sort()
	print("ECONOMY_WORKER PASS owners=472 1000_iterations inline_p50_us=", inline[500],
		" inline_p95_us=", inline[950], " worker_p50_us=", threaded[500], " worker_p95_us=", threaded[950])
	quit()
