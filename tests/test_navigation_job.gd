extends SceneTree

const NavigationJob = preload("res://sim/navigation_job.gd")

func _initialize() -> void:
	var owners := PackedInt32Array()
	var width := 64
	var height := 32
	owners.resize(width * height)
	owners.fill(-1)
	for y in range(1, height - 1):
		owners[y * width + width / 2] = 0
	var job := NavigationJob.new(owners.duplicate(), width, height, -1)
	var expected := job.build()
	var worker := Thread.new()
	if worker.start(job.build) != OK:
		push_error("Navigation worker failed to start")
		quit(1)
		return
	owners.fill(0)
	var actual: Array = worker.wait_to_finish()
	var got = actual[2]
	var want = expected[2]
	var passed: bool = actual[0] == expected[0] and actual[1] == expected[1] \
		and got.ready and got.region == want.region and got.cell_reg == want.cell_reg \
		and got.find_route(65, 190) == want.find_route(65, 190)
	print("NAVIGATION_JOB ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
