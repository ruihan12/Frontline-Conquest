# Port of tests/arsenal.luau formula/cost cases. Live launch/build cases are pending.
extends RefCounted

func run(H) -> void:
	H.section("arsenal", "arsenal.luau")
	H.expect_eq(SimRules.build_cost("artillery", 0), 150000.0, "artillery price ladder first 150,000")
	H.expect_eq(SimRules.build_cost("artillery", 9), 750000.0, "artillery price ladder cap 750,000")
	H.expect_eq(SimRules.build_cost("airfield", 0), 500000.0, "airfield 500,000")
	H.expect_eq(SimRules.build_cost("railgun", 0), 2500000.0, "railgun first 2,500,000")
	H.expect_eq(SimRules.build_cost("railgun", 5), 7500000.0, "railgun cap 7,500,000")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_MEGA], 2500000.0, "mega 2,500,000 gold")
	H.expect_eq(SimRules.NUKE_COST[SimRules.N_SCATTER], 3750000.0, "scatter 3,750,000 gold")
	H.expect_eq(SimRules.REINFORCE_COST, 100000.0, "reinforcements 100,000 gold")
	H.expect_eq(SimRules.REINFORCE_FRACTION, 0.20, "reinforcements a fifth of the cap")
	H.expect_eq(SimRules.REINFORCE_COOLDOWN_TICKS, 300, "30 s between reinforcement calls")
	H.expect_eq(SimRules.RAPID_RELOAD_MULT, 0.5, "rapid reload halves silo / battery gaps")
	H.expect_eq(SimRules.SILO_COOLDOWN_TICKS, 90, "silo 9 s; half is 4.5 s (45 ticks)")
	H.expect_eq(SimRules.RELOAD_TICKS[7], 300, "airfield rearm 30 s (300 ticks)")
	H.expect_eq(SimRules.RELOAD_TICKS[8], 250, "railgun reload 25 s")
	H.expect_eq(SimRules.BUILD_TICKS[6], 80, "artillery construction 8 s (80 ticks)")
	H.expect_eq(SimRules.STRUCT_HP[0], 1000, "city HP 1000")
	H.expect_eq(SimRules.STRUCT_HP[3], 600, "defense post HP 600")
	# Owner custom (2026-11-28): artillery, air strike and railgun kills, structure damage, ranges and radii are
	# upstream's x2.5 (SimRules.STRIKE_BUFF); each value below is checked as upstream's number x2.5.
	var B: float = SimRules.STRIKE_BUFF
	H.intentional("artillery, air strike and railgun kills, damage, range and radius x%.1f (owner custom); reloads, cost, HP, build time, speed upstream's" % B, "checked below as upstream x2.5")
	H.expect_eq(SimRules.STRIKE_DAMAGE[SimRules.N_SHELL], int(150 * B), "shell 150 damage to a city, x2.5")
	H.expect_eq(SimRules.STRIKE_DAMAGE[SimRules.N_AIRSTRIKE], int(600 * B), "airstrike 600 damage, x2.5")
	H.expect_eq(SimRules.STRIKE_DAMAGE[SimRules.N_SLUG], int(1000 * B), "slug 1000 damage, x2.5")

	var r = SimRules.new(1.0)
	H.expect_near(r.artillery_range(), 45.0 * B, 1e-9, "artillery range 45, x2.5")
	H.expect_near(r.airfield_range(), 156.0 * B, 1e-9, "airfield / airstrike reach 156, x2.5")
	H.expect_near(r.strike_radius(SimRules.N_SHELL), 1.5 * B, 1e-9, "shell radius 1.5, x2.5")
	H.expect_near(r.strike_radius(SimRules.N_AIRSTRIKE), 15.0 * B, 1e-9, "air strike radius 15, x2.5")
	H.expect_near(r.strike_radius(SimRules.N_SLUG), 5.0 * B, 1e-9, "slug radius 5, x2.5")

	# strike_kill
	H.expect_eq(SimRules.strike_kill(SimRules.N_SHELL, 20000.0, 1.0), 1440.0 * B, "a small army loses at least 1,440 to a shell, x2.5")
	H.expect_eq(SimRules.strike_kill(SimRules.N_SHELL, 900.0, 1.0), 900.0, "shell never more than the army")
	H.expect_eq(SimRules.strike_kill(SimRules.N_SHELL, 5000000.0, 1.0), 19200.0 * B, "shell at most 19,200, x2.5")
	# 2.88% x2.5 = 7.2% of 100000 = 7200 (7199 after the floor of 0.072 x 100000 in doubles)
	H.expect_near(SimRules.strike_kill(SimRules.N_SHELL, 100000.0, 1.0), 2880.0 * B, 1.0, "shell kills 2.88% of a 100k army, x2.5")

	H.expect_eq(SimRules.strike_kill(SimRules.N_AIRSTRIKE, 10000.0, 1.0), 60.0 * B, "airstrike 60 per tile, x2.5 (under the cap)")
	H.expect_eq(SimRules.strike_kill(SimRules.N_AIRSTRIKE, 10000.0, 200.0), 600.0 * B, "airstrike at most 6% of the army, x2.5")
	H.expect_eq(SimRules.strike_kill(SimRules.N_SLUG, 10000.0, 1.0), 150.0 * B, "slug 150 per tile, x2.5")
	H.expect_eq(SimRules.strike_kill(SimRules.N_SLUG, 10000.0, 100.0), 400.0 * B, "slug at most 4% of the army, x2.5")

	H.expect_eq(SimRules.reinforce_troops(0.0, 200000.0), 40000.0, "reinforce: a fifth of 200k cap")
	H.expect_eq(SimRules.reinforce_troops(180000.0, 200000.0), 20000.0, "reinforce never past the cap")
	H.expect_eq(SimRules.reinforce_troops(200000.0, 200000.0), 0.0, "reinforce at cap is 0")
