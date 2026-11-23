# Supply drops: off in headless sims (parity untouched); when on, one lands on neutral land and the nation
# whose territory covers it gets a prize, once.
#   godot --headless --path . -s res://tests/test_supply.gd
extends SceneTree

var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	hs.start(0, 0, Vector2(0.5, 0.38), 0, -1.0)
	_ok(not m.supply_on, "sims started by tests have no supply drops")
	hs.step(1200)
	_ok(m.drops.is_empty(), "no drops while supply_on is false")
	m.supply_on = true
	m._supply_rng.seed = 99
	m.peace = 1e9
	hs.step(2400)
	_ok(m.drops.size() >= 1, "a drop landed (%d)" % m.drops.size())
	if m.drops.size() >= 1:
		var d: Dictionary = m.drops[0]
		_ok(m.owner_map[d.tile] == m.NEUTRAL, "it lies on neutral land")
		var gold0: float = m.nations[m.PLAYER].gold
		var troops0: float = m.nations[m.PLAYER].troops
		m.nations[m.PLAYER].troops = 1.0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var t: int = d.tile + dy * m.W + dx
				if m.owner_map[t] == m.NEUTRAL: m._set_owner(t, m.PLAYER)
		var n0: int = m.drops.size()
		m._economy(0.1)
		_ok(m.drops.size() == n0 - 1, "taking the land claims the drop once")
		var gained: bool = m.nations[m.PLAYER].gold > gold0 or m.nations[m.PLAYER].troops > 1.0 or m.save.cosmetics.last != ""
		_ok(gained, "the claimer got a prize")
	print("SUPPLY_TEST ", "PASS" if fails == 0 else "FAIL", " fails=", fails)
	quit(1 if fails > 0 else 0)
