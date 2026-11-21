# World control / domination: owned tiles / (contestable land minus fallout).
# Upstream:
#   Rules.luau:1057-1058  WIN_SHARE = 0.8  ("80 % of the land that is not fallout")
#   SimState.luau:610-611  land_share = tiles / contestable_count  (does not exclude fallout)
#   UICtx.luau:1324-1337  win_share = tiles / max(contestable_count - fallout_count, 1)
#   Sim.luau:1699  _check_victory: bt >= WIN_SHARE * (contestable_count - fallout_count)
extends RefCounted

func run(H) -> void:
	H.section("world control / win share", "Sim.luau:_check_victory / UICtx.win_share")
	H.expect_eq(SimRules.WIN_SHARE, 0.8, "WIN_SHARE 0.8")

	# No fallout: land_share == win_share, 80 of 100 is exactly the goal.
	H.expect_near(SimRules.land_share(80, 100), 0.8, 1e-12, "land_share 80/100 = 0.8")
	H.expect_near(SimRules.win_share(80, 100, 0), 0.8, 1e-12, "win_share 80/100 with 0 fallout = 0.8")
	H.expect(SimRules.dominates(80, 100, 0), "80 tiles dominate 100 contestable, 0 fallout")
	H.expect(not SimRules.dominates(79, 100, 0), "79 tiles do not dominate 100 contestable")

	# Fallout shrinks the denominator, so the bar rises and the same army can win.
	# 70 owned, 100 land, 20 fallout: win_share = 70/80 = 0.875; land_share stays 0.70.
	H.expect_near(SimRules.land_share(70, 100), 0.70, 1e-12, "land_share ignores fallout (70/100)")
	H.expect_near(SimRules.win_share(70, 100, 20), 0.875, 1e-12, "win_share 70/(100-20) = 0.875")
	H.expect(SimRules.dominates(70, 100, 20), "70 tiles dominate once 20 fallout tiles drop out of the denom")
	H.expect(not SimRules.dominates(70, 100, 0), "70 tiles do not dominate all 100 land")

	# Spreading fallout only (owned tiles unchanged) raises win_share.
	var before := SimRules.win_share(40, 200, 0)
	var after := SimRules.win_share(40, 200, 50)
	H.expect(after > before, "win_share rises as fallout spreads (40/200=%.3f -> 40/150=%.3f)" % [before, after])
	H.expect_near(after, 40.0 / 150.0, 1e-12, "40 / (200-50) exact")

	# Denominator floors at 1 (all land irradiated).
	H.expect_near(SimRules.win_share(0, 10, 10), 0.0, 1e-12, "0 tiles, all fallout -> 0")
	H.expect_near(SimRules.win_share(5, 10, 10), 5.0, 1e-12, "denom floors at 1 when contestable==fallout")

	# Exact Sim.luau:1699 comparison (float product, not pre-rounded).
	H.expect(SimRules.dominates(80, 100, 0), "bt >= 0.8 * (100-0)")
	# 79.9 would be tiles as int; 80 is the first integer that wins 100 land.
	H.expect(float(80) >= SimRules.WIN_SHARE * float(100 - 0), "integer tiles vs 0.8 * denom")
