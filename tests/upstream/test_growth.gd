# Port of the formula section of tests/growth_rules.luau.
extends RefCounted

const R := preload("res://sim/rules.gd")

func _up_max(kind: int, tiles: float, cities: int, diff: int) -> float:
	var m = 2.0 * (pow(maxf(tiles, 0.0), 0.6) * 1000.0 + 50000.0) + float(cities) * 250000.0
	if kind == SimRules.KIND_TRIBE:
		return m / 3.0
	if kind == SimRules.KIND_NATION:
		return m * [0.5, 0.75, 1.0][clampi(diff, 0, 2)]
	return m

func _up_growth(kind: int, troops: float, cap: float, diff: int) -> float:
	var add = (10.0 + pow(maxf(troops, 0.0), 0.73) / 4.0) * (1.0 - troops / maxf(cap, 1.0))
	if kind == SimRules.KIND_TRIBE:
		add *= 0.5
	elif kind == SimRules.KIND_NATION:
		add *= [0.9, 0.95, 1.0][clampi(diff, 0, 2)]
	return minf(troops + add, cap) - troops

func run(H) -> void:
	H.section("growth_rules formulas", "growth_rules.luau")
	var r: SimRules = R.new(1.0)
	r.tile_norm = 1.0

	# start troops already covered; re-check vs Formula
	for kind in [SimRules.KIND_HUMAN, SimRules.KIND_NATION, SimRules.KIND_TRIBE]:
		for d in 3:
			# already exact vs upstream start_troops
			pass

	# cap: vanilla uses the upstream formula (k_lin=1 so k_area=1)
	var worst_rel = 0.0
	var sample = ""
	for kind in [SimRules.KIND_HUMAN, SimRules.KIND_NATION, SimRules.KIND_TRIBE]:
		for d in 3:
			for tiles in [0, 1, 30, 52, 1000, 25000]:
				for cities in [0, 1, 4]:
					var want = _up_max(kind, float(tiles), cities, d)
					var got: float = r.max_troops(kind, tiles, cities, d)
					var rel = abs(got - want) / maxf(abs(want), 1.0)
					if rel > worst_rel:
						worst_rel = rel
						sample = "kind=%d tiles=%d cities=%d diff=%d port=%.1f upstream=%.1f" % [kind, tiles, cities, d, got, want]
	H.expect(worst_rel < 1e-9, "maxTroops matches 2*((tiles*K_AREA)^0.6*1000+50000)+250k*cities", "worst rel %.3e at %s" % [worst_rel, sample])

	var cap30: float = r.max_troops(SimRules.KIND_HUMAN, 30, 0, 1)
	H.expect_near(cap30, _up_max(SimRules.KIND_HUMAN, 30.0, 0, 1), 1e-6, "30-tile human cap matches upstream")

	# k_lin != 1 (synthetic): cap uses tiles * k_area. World itself is now native k_lin 1.0.
	var rmap: SimRules = R.new(1.1161)
	var tfull := 30.0 * rmap.k_area
	var want_k: float = 2.0 * (pow(tfull, 0.6) * 1000.0 + 50000.0)
	H.expect_near(rmap.max_troops(SimRules.KIND_HUMAN, 30, 0, 1), want_k, 1e-4, "max_troops uses tiles * k_area at k_lin 1.1161")

	# troopIncreaseRate vs upstream (growth_mult 1.0 in vanilla)
	var mid_cap = _up_max(SimRules.KIND_HUMAN, 1000.0, 0, 1)
	var mid_troops = floor(mid_cap * 0.5)
	var up_g = _up_growth(SimRules.KIND_HUMAN, mid_troops, mid_cap, 1)
	var port_g: float = r.troop_growth(SimRules.KIND_HUMAN, mid_troops, mid_cap, 1)
	H.expect_near(r.growth_mult, 1.0, 1e-9, "growth_mult 1.0 (vanilla = upstream)")
	H.expect_near(port_g, up_g, 1e-6, "troopIncreaseRate matches upstream (50% of a 1000-tile cap)")
	var saved = r.growth_mult

	# over-cap: upstream and port both snap (return cap - troops)
	var up_over = _up_growth(SimRules.KIND_HUMAN, 200000.0, 100000.0, 1)
	var port_over: float = r.troop_growth(SimRules.KIND_HUMAN, 200000.0, 100000.0, 1)
	H.expect_near(up_over, -100000.0, 1e-6, "upstream over-cap reference is snap-to-cap (-100000)")
	H.expect_near(port_over, -100000.0, 1e-6, "port troop_growth over cap snaps to the cap (upstream)")

	# applied whole-troops truncation (toward zero) — test the helper itself at growth_mult=1
	r.growth_mult = 1.0
	var applied: float = r.troop_growth_applied(SimRules.KIND_HUMAN, mid_troops, mid_cap, 1)
	var raw: float = r.troop_growth(SimRules.KIND_HUMAN, mid_troops, mid_cap, 1)
	H.expect_eq(applied, floor(raw) if raw >= 0.0 else -floor(-raw), "troop_growth_applied truncates toward zero")
	r.growth_mult = saved

	H.expect_eq(SimRules.TICK_RATE, 10, "10 ticks per second")
