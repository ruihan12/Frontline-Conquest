extends RefCounted
class_name NavalWorker
## Runs the ordinary port tick on detached values. A cache miss that would
## spend navigation budget rejects the speculative result.

class TradePass extends SimNaval:
	var needs_search := false

	func _trade_path(source: Dictionary, target: Dictionary) -> PackedVector2Array:
		var key := "%d:%d" % [source.tile, target.tile]
		var reverse_key := "%d:%d" % [target.tile, source.tile]
		if trade_cache.has(key) or trade_cache.has(reverse_key):
			return super._trade_path(source, target)
		if path_budget > 0:
			needs_search = true
		return PackedVector2Array()

class Job extends RefCounted:
	const TS := 2.0
	var W: int
	var rng := RandomNumberGenerator.new()
	var nations: Array
	var attacks: Array
	var structs: Array
	var struct_at := {}
	var traders: Array = []
	var allies: Dictionary
	var result: TradePass
	var tick: int
	var trader_count: int

	func _init(game, defer_paths: bool, inputs: Array) -> void:
		W = game.W
		tick = game.sim_atk.tick
		rng.state = inputs[0]
		nations = inputs[1]
		attacks = inputs[2]
		structs = inputs[3]
		allies = inputs[4]
		trader_count = inputs[5]
		# Only the count of existing ships is needed. New ships reference
		# job-local ports, which are resolved to live records on commit.
		traders.resize(trader_count)
		for port: Dictionary in structs:
			struct_at[int(port.tile)] = port
		var rules := SimRules.new(game.sim_rules.k_lin)
		result = TradePass.new(self, rules)
		result.body = game.sim_naval.body
		result.trade_cache = game.sim_naval.trade_cache.duplicate()
		result._hp_tick = inputs[6]
		result._hp = inputs[7]
		# Hostility only needs the tick, which is supplied by the mirror below.
		var graph_ready: bool = game.sim_nav != null and game.sim_nav.ready
		result.path_budget = 0 if defer_paths else (2 if graph_ready else (1 if tick % 4 == 0 else 0))

	var sim_atk: Job:
		get: return self

	func allied(a: int, b: int) -> bool:
		return a > 0 and b > 0 and allies.has(mini(a, b) * 4096 + maxi(a, b))

	func is_embargoed(_a: int, _b: int) -> bool:
		return false

	func run() -> void:
		result._ports_tick(tick)
		result.g = null

static func _inputs(game) -> Array:
	var owners := []
	for nation: Dictionary in game.nations:
		owners.append({"alive": nation.get("alive", false)})
	var attacks := []
	for attack: Dictionary in game.attacks:
		attacks.append({"a": attack.a, "t": attack.t, "dead": attack.get("dead", false)})
	var ports := []
	for building: Dictionary in game.structs:
		if building.k == 1:
			ports.append(building.duplicate(true))
	return [game.rng.state, owners, attacks, ports, game.allies.duplicate(), game.traders.size(),
		game.sim_naval._hp_tick, game.sim_naval._hp.duplicate()]

var _task := -1
var _job: Job
var _initial: Array
var _joined := false
var defer_paths := false

func submit(game, defer: bool) -> bool:
	assert(_task == -1)
	var slot: int = game.sim_atk.tick % 10
	if not game.structs.any(func(building):
		return building.k == 1 and float(building.get("bt", 0.0)) <= 0.0 and int(building.get("slot", slot)) == slot):
		return false
	defer_paths = defer
	_initial = _inputs(game)
	_job = Job.new(game, defer_paths, _initial.duplicate(true))
	_task = WorkerThreadPool.add_task(_job.run)
	if _task < 0:
		_job.result.g = null
		_job = null
		_initial = []
	return _task >= 0

func ready() -> bool:
	return _task >= 0 and (_joined or WorkerThreadPool.is_task_completed(_task))

# The headless tick profiler joins immediately. Live play polls ready().
func wait() -> void:
	if _task >= 0 and not _joined:
		WorkerThreadPool.wait_for_task_completion(_task)
		_joined = true

func take(game) -> bool:
	assert(ready())
	_join()
	var job := _job
	_job = null
	var unchanged: bool = not job.result.needs_search and game.state == "play" and game.net_host == null \
		and not game.net_remote and not game.team_mode and game.sim_atk.tick == job.tick and _initial == _inputs(game)
	_initial = []
	if not unchanged:
		return false
	for port: Dictionary in job.structs:
		var live: Dictionary = game.struct_at[port.tile]
		for key in ["slot", "rej", "partners", "ptick", "water", "body"]:
			if port.has(key):
				live[key] = port[key]
	for i in range(job.trader_count, job.traders.size()):
		var trader: Dictionary = job.traders[i]
		trader.src = game.struct_at[trader.src.tile]
		trader.dst = game.struct_at[trader.dst.tile]
		game.traders.append(trader)
	game.sim_naval.trade_cache = job.result.trade_cache
	game.sim_naval._hp_tick = job.result._hp_tick
	game.sim_naval._hp = job.result._hp
	game.sim_naval.path_budget = job.result.path_budget
	if job.tick % 10 == 0:
		game.sim_naval.tokens.clear()
	if game.sim_nav != null:
		game.sim_nav.begin_tick()
	game.rng.state = job.rng.state
	return true

func stop() -> void:
	if _task >= 0:
		_join()
	_job = null
	_initial = []

func _join() -> void:
	wait()
	_joined = false
	_task = -1
