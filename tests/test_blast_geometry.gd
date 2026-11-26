extends SceneTree

func _initialize() -> void:
	var game = load("res://main.tscn").instantiate()
	game.W = 151
	game.H = 109
	var owners := PackedInt32Array()
	owners.resize(game.W * game.H)
	for tile in owners.size():
		owners[tile] = -1 if tile % 7 == 0 else tile % 5
	game.owner_map = owners
	var arsenal := SimArsenal.new(game, SimRules.new())
	arsenal.threaded_blasts = true
	var passed := true
	for radius in [1.0, 5.001, 14.999, 30.0, 86.0, 100.0, 150.0]:
		arsenal.prepare_blast(radius)
		for center in [0, 150, 2010, 8313, owners.size() - 1]:
			if arsenal._blast_tiles(center, radius) != arsenal.disk_tiles(center, radius):
				passed = false
		if arsenal._blast_geometries[radius].task < 0:
			continue
		# Require the worker result as well as allowing the live fallback to run above.
		var entry: Dictionary = arsenal._blast_geometries[radius]
		WorkerThreadPool.wait_for_task_completion(entry.task)
		entry.task = -1
		for center in [0, 8313, owners.size() - 1]:
			passed = passed and arsenal._blast_tiles(center, radius) == arsenal.disk_tiles(center, radius)
	arsenal.reset()
	game.free()
	print("BLAST_GEOMETRY ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
