extends RefCounted
class_name EconomyWorker
## Computes economy values from private inputs. The scene thread validates the
## results and keeps control of elimination, notifications and the gameplay RNG.

enum Row { GOLD_KIND, TROOP_KIND, DIFFICULTY, LAND, POPULATION, CITY_LEVELS, TROOPS, GOLD, REINF_CD }
enum Result { TROOPS, GOLD, REGEN, REINF_CD, CAP }

class Job extends RefCounted:
	var rules := SimRules.new()
	var settings: Dictionary
	var rows := {}
	var values := {}
	var dt: float

	func update_after_attacks(nations: Array) -> void:
		for id in rows:
			var nation: Dictionary = nations[id]
			var row: Array = rows[id]
			row[Row.LAND] = nation.land
			row[Row.TROOPS] = float(nation.troops)
			row[Row.GOLD] = float(nation.gold)

	func run() -> void:
		EconomyWorker.configure(rules, settings)
		for id in rows:
			var row: Array = rows[id]
			var nation := {"troops": row[Row.TROOPS], "gold": row[Row.GOLD], "reinf_cd": row[Row.REINF_CD]}
			var cap := EconomyWorker.cap_for(rules, row[Row.TROOP_KIND], row[Row.DIFFICULTY], row[Row.LAND],
				row[Row.POPULATION], row[Row.CITY_LEVELS], settings.population_mode, settings.average_pop)
			EconomyWorker.accrue(nation, rules, row[Row.GOLD_KIND], row[Row.TROOP_KIND], row[Row.DIFFICULTY], cap, dt)
			values[id] = [nation.troops, nation.gold, nation.regen, nation.reinf_cd, cap]

var _job: Job
var _task := -1

static func settings_for(game) -> Dictionary:
	var rules: SimRules = game.sim_rules
	return {"k_area": rules.k_area, "ts": rules.ts, "growth_mult": rules.growth_mult,
		"gold_mult": rules.gold_mult, "pop_cap_mode": rules.pop_cap_mode, "pop_k": rules.pop_k,
		"tile_norm": rules.tile_norm, "population_mode": not game.tile_pop.is_empty(), "average_pop": game.tile_pop_avg}

static func configure(rules: SimRules, settings: Dictionary) -> void:
	rules.k_area = settings.k_area
	rules.ts = settings.ts
	rules.growth_mult = settings.growth_mult
	rules.gold_mult = settings.gold_mult
	rules.pop_cap_mode = settings.pop_cap_mode
	rules.pop_k = settings.pop_k
	rules.tile_norm = settings.tile_norm

static func row_for(game, id: int, city_levels: int) -> Array:
	var nation: Dictionary = game.nations[id]
	return [game.kind_of(id), game.troop_kind(id), game.troop_diff(id), nation.land,
		float(nation.get("pop", 0.0)), city_levels, float(nation.troops),
		float(nation.gold), float(nation.reinf_cd)]

static func cap_for(rules: SimRules, kind: int, diff: int, land: int, pop: float,
		cities: int, population_mode: bool, average_pop: float) -> float:
	if population_mode:
		return rules.max_troops_pop(kind, land, pop, average_pop, cities, diff)
	return rules.max_troops(kind, land, cities, diff)

static func accrue(nation: Dictionary, rules: SimRules, kind: int, troop_kind: int,
		diff: int, cap: float, dt: float) -> void:
	var growth := rules.troop_growth(troop_kind, nation.troops, cap, diff)
	nation.regen = growth * 10.0
	nation.troops += floor(growth) if growth >= 0.0 else -floor(-growth)
	nation.gold += rules.gold_per_tick(kind)
	nation.reinf_cd = maxf(0.0, nation.reinf_cd - dt)

static func capture(game, dt: float) -> Job:
	var job := Job.new()
	job.dt = dt
	job.settings = settings_for(game)
	var cities: Dictionary = game._economy_city_levels()
	for id in range(1, game.nations.size()):
		var nation: Dictionary = game.nations[id]
		if nation.alive and nation.land > 0:
			job.rows[id] = row_for(game, id, cities.get(id, 0))
	return job

func submit(game, dt: float) -> bool:
	assert(_task == -1)
	var job := capture(game, dt)
	if job.rows.is_empty():
		return false
	_task = WorkerThreadPool.add_task(job.run)
	if _task < 0:
		return false
	_job = job
	return true

func ready() -> bool:
	return _task >= 0 and WorkerThreadPool.is_task_completed(_task)

func take() -> Job:
	assert(ready())
	return _join()

func wait() -> Job:
	assert(_task >= 0)
	return _join()

func stop() -> void:
	if _task >= 0:
		_join()

func _join() -> Job:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var job := _job
	_job = null
	return job
