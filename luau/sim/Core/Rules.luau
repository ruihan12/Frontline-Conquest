-- Rules: the sim's numbers and formulas. Transliterated line for line from this project's sim/rules.gd
-- (SimRules), which ports upstream RoWorld src/shared/Core/Rules.luau (AGPL-3.0, lukechatton/roworld) with
-- the customs in CLAUDE.md. The GDScript file is the source of truth until its callers move to Luau
-- (docs/LUAU_PORT.md, Step 3); tests/test_luau_rules.gd checks every constant, every instance field and
-- every function here against it, bit for bit.
--
-- Conventions for the ported sim (all of luau/sim):
--   * data arrays are 0-based like GDScript (`{ [0] = a, b, c }`), so index code reads the same;
--     their sizes are written out where GDScript calls size();
--   * GDScript int division is `//` (only used on non-negative values here), int(x) is trunc(x);
--   * Vector2 is Luau's float32 vector (prelude Vector2.new), so it rounds like Godot's real_t Vector2;
--     PackedFloat32Array entries are rounded with gd.f32.
local gd = require("../rt/gd")

local exp, log, floor, ceil = math.exp, math.log, math.floor, math.ceil
local vmag = vector.magnitude
local vcreate = vector.create

local Rules = {}
Rules.__index = Rules

local function trunc(x: number): number
	return if x >= 0 then floor(x) else ceil(x)
end
local function clamp(x: number, lo: number, hi: number): number
	return if x < lo then lo elseif x > hi then hi else x
end
local function maxf(a: number, b: number): number
	return if a > b then a else b
end
local function minf(a: number, b: number): number
	return if a < b then a else b
end
-- Godot round(): half away from zero (Luau's math.round does the same)
local round = math.round
Rules.trunc = trunc
Rules.clamp = clamp

Rules.TICK_RATE = 10
Rules.KIND_HUMAN = 0
Rules.KIND_NATION = 1
Rules.KIND_TRIBE = 2

-- terrain magnitudes / tile cost per terrain class; difficulty-indexed tables are [0..2]
Rules.ATTACK_MAG = { [0] = 80.0, 100.0, 120.0 }
Rules.ATTACK_TILE_COST = { [0] = 16.5, 20.0, 25.0 }
Rules.PRIORITY_MAG = { [0] = 1.0, 1.5, 2.0 }

Rules.START_TROOPS_HUMAN = 25000.0
Rules.START_TROOPS_TRIBE = 10000.0
Rules.NATION_START_TROOPS = { [0] = 12500.0, 18750.0, 25000.0 }
Rules.NATION_TROOP_MULT = { [0] = 0.5, 0.75, 1.0 }
Rules.NATION_GROWTH_MULT = { [0] = 0.9, 0.95, 1.0 }
Rules.CITY_TROOPS = 250000.0
Rules.DEFAULT_TRIBES = 400
Rules.SOLO_COUNTDOWN_TICKS = 50

Rules.GOLD_PER_TICK = 100.0
Rules.TRIBE_GOLD_PER_TICK = 50.0

Rules.LARGE_ATTACKER_DEPTH = 0.7
Rules.LARGE_DEFENDER_DEPTH = 0.3
Rules.LARGE_ATTACKER_SPEED_DEPTH = 0.73
Rules.BOT_DEFENDER_LOSS_MULT = 0.7
Rules.TERRA_NULLIUS_COST_SCALE = 2000.0
Rules.TERRA_NULLIUS_MIN_COST = 5.0
Rules.TERRA_NULLIUS_MAX_COST = 100.0
Rules.ATTACKER_LOSS_BASE = 0.463
Rules.ATTACKER_LOSS_PER_DENSITY = 0.0039
Rules.SPEED_COST_DIVISOR = 8.55
Rules.BORDER_JITTER = 5
Rules.PRIORITY_BASE = 10
Rules.PRIORITY_RAND = 7
Rules.RETREAT_KEEP = 0.75
Rules.RETREAT_DELAY_TICKS = 20
Rules.ANNEX_BELOW_FULL_TILES = 100.0
Rules.ATTACK_UPDATE_TICKS = 10
Rules.DEFENSE_POST_MAG = 5.0
Rules.DEFENSE_POST_COST = 3.0
Rules.DEFENSE_POST_SHOOTS = false
Rules.DEFENSE_POST_SHELL_TICKS = 100
Rules.DEFENSE_POST_TARGET_FULL = 75.0
Rules.TRAITOR_DEFENSE_DEBUFF = 0.5
Rules.TRAITOR_SPEED_DEBUFF = 0.8
Rules.HOSTILE_TICKS = 600
Rules.WIN_SHARE = 0.8
Rules.MAX_BOATS_PER_OWNER = 3
Rules.MAX_BOATS_PLAYER = 10
Rules.BOAT_ATTACK_FRACTION = 0.2
Rules.HUMAN_GRACE_TICKS = { [0] = 3000, 1800, 1200 }
Rules.HUMAN_GRACE_JITTER = 900
Rules.MAX_AI_WARS_ON_HUMAN = { [0] = 1, 2, 3 }

Rules.SPAWN_SHIELD_TICKS = 300

Rules.SMART_VS_PLAYERS = 0
Rules.CAPITULATE_AGE = 12000
Rules.CAPITULATE_SHARE = 0.02
Rules.CAPITULATE_RATIO = 8.0
Rules.CAPITULATE_GAP = 300

-- real-pop 1:1 mode (docs/REAL_POP_1TO1.md); see sim/rules.gd for where each number comes from
Rules.TROOP_SCALE = 297.0
Rules.CITY_POP_BONUS = 309416.0
Rules.NEUTRAL_LOSS_FLOOR = 60.0
Rules.NEUTRAL_LOSS_POP_FRAC = 0.25
Rules.MIN_CAP_1TO1 = 300000.0

Rules.CAP_BASE = 5000.0
Rules.CAP_K = 6200.0
Rules.CAP_EXP = 0.41
Rules.CITY_TROOPS_NERF = 25000.0
Rules.OVERCAP_DECAY = 0.02 -- unused (upstream snaps over-cap armies to the cap)
Rules.POP_LAND_W = 0.25

Rules.SAM_RADIUS_MULT = 1.0
Rules.SAM_RELOAD_MULT = 1.0

-- naval + placement
Rules.UPGRADABLE_K = { [0] = 0, 1, 2, 4, 5 } -- city, port, factory, SAM, silo (our build ids)
Rules.TRADE_SHORT_RANGE_FULL = 300.0
Rules.BOAT_SEARCHES_PER_S = 2

-- nuke kinds (Defs.N_*)
Rules.N_ATOM = 0
Rules.N_HYDROGEN = 1
Rules.N_MIRV = 2
Rules.N_WARHEAD = 3
Rules.N_MEGA = 4
Rules.N_SCATTER = 5
Rules.N_SHELL = 6
Rules.N_AIRSTRIKE = 7
Rules.N_SLUG = 8
-- our build ids -> Defs.N_*
Rules.NUKE_KIND_OF = { [7] = 0, [8] = 1, [9] = 2, [11] = 4, [12] = 5 }
Rules.NUKE_COST = { [0] = 750000.0, 5000000.0, 25000000.0, 0.0, 2500000.0, 3750000.0, 0.0, 0.0, 0.0 }
Rules.MIRV_COST_STEP = 15000000.0
Rules.NUKE_INNER_FULL = { [0] = 12.0, 80.0, 0.0, 12.0, 24.0, 12.0, 0.0, 0.0, 0.0 }
Rules.NUKE_OUTER_FULL = { [0] = 30.0, 100.0, 0.0, 18.0, 60.0, 30.0, 1.5, 15.0, 5.0 }
Rules.NUKE_INTERCEPT_P = { [0] = 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0 }
Rules.NUKE_SPEED_FULL = { [0] = 10.0, 10.0, 15.0, 22.0, 10.0, 10.0, 6.0, 8.0, 80.0 }
Rules.NUKE_FLAT = { [0] = false, false, false, false, false, false, true, true, true }
Rules.NUKE_KINDS = 9 -- size of the N_* tables
Rules.MIRV_WARHEADS = 350
Rules.NUKE_ALLIANCE_BREAK_FULL = 100.0
Rules.NUKE_GRUDGE_TICKS = 3000
Rules.SAM_COOLDOWN_TICKS = 90
Rules.SILO_COOLDOWN_TICKS = 90
Rules.SAM_UPGRADE_TICKS = 45
Rules.SAM_MAX_RANGE_FULL = 150.0
Rules.SAM_MISSILE_SPEED_FULL = 12.0
Rules.NUKE_TARGETABLE_FULL = 150.0
Rules.SAM_CAND_REFRESH_TICKS = 30
-- Defs.S_* order: city, port, factory, defense, sam, silo, artillery, airfield, railgun
Rules.BUILD_TICKS = { [0] = 20, 50, 20, 50, 300, 100, 80, 100, 150 }
Rules.STRUCT_HP = { [0] = 1000, 1000, 1000, 600, 1000, 1000, 600, 800, 1000 }
Rules.RELOAD_TICKS = { [0] = 0, 0, 0, 0, 90, 90, 0, 300, 250 }
-- our build ids -> Defs.S_*
Rules.S_OF = { [0] = 0, [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [10] = 6, [14] = 7, [15] = 8 }
Rules.RAPID_RELOAD_MULT = 0.5
Rules.ARTILLERY_RANGE_FULL = 45.0
Rules.ARTILLERY_GAP_MIN = 40
Rules.ARTILLERY_GAP_MAX = 70
Rules.ARTILLERY_IDLE_TICKS = 20
Rules.ARTILLERY_SAMPLES = 24
Rules.SHELL_KILL_FRAC = 0.0288
Rules.SHELL_KILL_MIN = 1440.0
Rules.SHELL_KILL_MAX = 19200.0
Rules.AIRFIELD_RANGE_FULL = 156.0
Rules.AIRSTRIKE_KILL_PER_TILE = 60.0
Rules.AIRSTRIKE_KILL_FRAC = 0.06
Rules.SLUG_KILL_PER_TILE = 150.0
Rules.SLUG_KILL_FRAC = 0.04
Rules.STRIKE_DAMAGE = { [0] = 0, 0, 0, 0, 0, 0, 150, 600, 1000 }
Rules.SCATTER_MIN = 4
Rules.SCATTER_MAX = 6
Rules.SCATTER_NEAR_FULL = 28.0
Rules.SCATTER_FAR_FULL = 46.0
Rules.REINFORCE_COST = 100000.0
Rules.REINFORCE_FRACTION = 0.20
Rules.REINFORCE_COOLDOWN_TICKS = 300
-- warships
Rules.WARSHIP_HP = 1000
Rules.WARSHIP_MAX_VET = 3
Rules.WARSHIP_VET_TRANSPORTS = 10
Rules.WARSHIP_VET_TRADES = 25
Rules.WARSHIP_FIRE_TICKS = 20
Rules.WARSHIP_RANGE_FULL = 130.0
Rules.WARSHIP_PATROL_FULL = 100.0
Rules.WARSHIP_DOCK_FULL = 5.0
Rules.WARSHIP_PASSIVE_HEAL = 1
Rules.WARSHIP_PASSIVE_HEAL_FULL = 150.0
Rules.WARSHIP_PORT_HEAL_PER_LEVEL = 5
Rules.WARSHIP_RETREAT_PCT = 75
Rules.WARSHIP_MANUAL_NO_RETREAT_TICKS = 50
Rules.SHELL_SPEED_FULL = 3.0
Rules.SAFE_FROM_PIRATES_TICKS = 20
Rules.SCAN_TICKS = 5
-- trains
Rules.TRUCKS_PER_FACTORY = 6
Rules.TRAIN_UNITS = 6
Rules.TRAIN_COOLDOWN_TICKS = 10
Rules.TRAIN_SPEED_FULL = 2.0
-- diplomacy
Rules.ALLY_REQUEST_TICKS = 200
Rules.ALLY_REQUEST_COOLDOWN_TICKS = 300
Rules.ALLIANCE_TICKS = 3000
Rules.ALLIANCE_EXTEND_WINDOW_TICKS = 300
Rules.TRAITOR_TICKS = 300
Rules.AI_MAX_ALLIES = 3

Rules.RAIL_LINK_HOPS = 4
Rules.DEFAULT_ATTACK_RATIO = 0.2
Rules.NUKE_NAMES = { [0] = "atom", "hydrogen", "mirv", "warhead", "mega", "scatter", "shell", "airstrike", "slug" }
Rules.NUKE_ARC_MIN_HEIGHT_FULL = 50.0
Rules.NUKE_ARC_SAMPLES = 96

-- ---- instance (SimRules.new(kl)): the per-map scale and the per-match settings
function Rules.new(kl: number?): any
	local self = setmetatable({}, Rules)
	self.k_lin = 1.0
	self.k_area = 1.0
	self.legacy_lin = 1.0
	self.spawn_radius = 4.0
	self.tribe_spawn_min_dist = 30.0
	self.nation_spawn_delta = 25.0
	self.max_tiles_per_tick = 572
	self.defense_range = 30.0
	self.struct_min_dist = 15.0
	self.priority_f4 = {}
	self.log_mid = log(300000.0)
	self.ts = 1.0
	self.tile_norm = 1.0
	self.growth_mult = 1.0
	self.attack_speed_mult = 1.0
	self.gold_mult = 1.0
	self.ai_rate_mult = 1.0
	self.pop_cap_mode = 2
	self.pop_k = 1.0 / 300.0
	self:set_k(kl or 1.0)
	return self
end

function Rules.set_k(self: any, kl: number)
	self.k_lin = kl
	self.k_area = kl * kl
	self.legacy_lin = (2000.0 / 1024.0) / kl
	self.spawn_radius = 4.0 / kl
	self.tribe_spawn_min_dist = 30.0 / kl
	self.nation_spawn_delta = 25.0 / kl
	self.max_tiles_per_tick = math.max(1, trunc(floor(572.0 / self.k_area)))
	self.defense_range = 30.0 / kl
	self.struct_min_dist = 15.0 / kl
	local f4 = {}
	for tt = 0, 2 do
		for n = 0, 4 do
			f4[tt * 5 + n] = 4 - 2 * n + trunc(floor(2.0 * Rules.PRIORITY_MAG[tt] + 0.5))
		end
	end
	self.priority_f4 = f4
end

function Rules.sigmoid(v: number, decay: number, mid: number): number
	return 1.0 / (1.0 + exp(-decay * (v - mid)))
end
local sigmoid = Rules.sigmoid

function Rules.start_troops(self: any, kind: number, diff: number): number
	if kind == Rules.KIND_TRIBE then
		return Rules.START_TROOPS_TRIBE * self.ts
	end
	if kind == Rules.KIND_NATION then
		return Rules.NATION_START_TROOPS[clamp(diff, 0, 2)] * self.ts
	end
	return Rules.START_TROOPS_HUMAN * self.ts
end

function Rules.set_troop_scale(self: any, on: boolean)
	self.ts = if on then Rules.TROOP_SCALE else 1.0
end

function Rules.is_1to1(self: any): boolean
	return self.ts ~= 1.0
end

function Rules.city_troops_shown(self: any): number
	return if self:is_1to1() then Rules.CITY_POP_BONUS else Rules.CITY_TROOPS
end

-- Rules.luau:140  m = 2 * ((tiles * K_AREA)^0.6 * 1000 + 50000) + cities * 250000
function Rules.max_troops(self: any, kind: number, tiles: number, cities: number, diff: number): number
	local m = 2.0 * (maxf(tiles * self.k_area, 0.0) ^ 0.6 * 1000.0 + 50000.0) + cities * Rules.CITY_TROOPS
	if kind == Rules.KIND_TRIBE then
		return m / 3.0
	end
	if kind == Rules.KIND_NATION then
		return m * Rules.NATION_TROOP_MULT[clamp(diff, 0, 2)]
	end
	return m
end

function Rules.land_share(tiles: number, contestable: number): number
	return tiles / maxf(contestable, 1.0)
end

function Rules.win_share(tiles: number, contestable: number, fallout: number): number
	return tiles / maxf(contestable - fallout, 1.0)
end

function Rules.dominates(tiles: number, contestable: number, fallout: number): boolean
	return tiles >= Rules.WIN_SHARE * (contestable - fallout)
end

function Rules.max_troops_pop(
	self: any,
	kind: number,
	tiles: number,
	pop: number,
	avg_pop: number,
	cities: number,
	diff: number,
	with_floor: boolean?
): number
	local wf = if with_floor == nil then true else with_floor
	local m: number
	if self.pop_cap_mode == 2 then
		m = maxf(pop, 0.0) + cities * Rules.CITY_POP_BONUS
		if wf and kind ~= Rules.KIND_TRIBE then
			m = maxf(m, Rules.MIN_CAP_1TO1)
		end
	elseif self.pop_cap_mode == 0 then
		m = Rules.CAP_BASE + maxf(pop, 0.0) * self.pop_k + cities * Rules.CITY_TROOPS_NERF
	else
		local eff = Rules.POP_LAND_W * tiles + (1.0 - Rules.POP_LAND_W) * maxf(pop, 0.0) / maxf(avg_pop, 1.0)
		m = Rules.CAP_BASE + Rules.CAP_K * maxf(eff * self.tile_norm, 0.0) ^ Rules.CAP_EXP + cities * Rules.CITY_TROOPS_NERF
	end
	if kind == Rules.KIND_TRIBE then
		return m / 3.0
	end
	if kind == Rules.KIND_NATION then
		return m * Rules.NATION_TROOP_MULT[clamp(diff, 0, 2)]
	end
	return m
end

-- troopIncreaseRate per tick: (10 + troops^0.73 / 4) * (1 - troops/max); an over-cap army snaps to the cap
function Rules.troop_growth(self: any, kind: number, troops: number, cap: number, diff: number): number
	if troops > cap then
		return cap - troops
	end
	local ts = self.ts
	local add = ts * (10.0 + maxf(troops / ts, 0.0) ^ 0.73 / 4.0) * (1.0 - troops / maxf(cap, 1.0)) * self.growth_mult
	if kind == Rules.KIND_TRIBE then
		add *= 0.5
	elseif kind == Rules.KIND_NATION then
		add *= Rules.NATION_GROWTH_MULT[clamp(diff, 0, 2)]
	end
	return minf(troops + add, cap) - troops
end

function Rules.troop_growth_applied(self: any, kind: number, troops: number, cap: number, diff: number): number
	local g = self:troop_growth(kind, troops, cap, diff)
	return if g >= 0.0 then floor(g) else -floor(-g)
end

function Rules.gold_per_tick(self: any, kind: number): number
	return (if kind == Rules.KIND_TRIBE then Rules.TRIBE_GOLD_PER_TICK else Rules.GOLD_PER_TICK) * self.gold_mult
end

function Rules.conquer_gold(self: any, victim_kind: number, victim_gold: number): number
	return victim_gold * (if victim_kind == Rules.KIND_HUMAN then 0.5 else 1.0)
end

function Rules.large_territory_bonus(self: any, src_full_tiles: number, depth: number): number
	return 1.0 - depth * sigmoid(log(maxf(src_full_tiles, 1.0)), 2.5, self.log_mid)
end

function Rules.fallout_modifier(ratio: number): number
	return 5.0 - clamp(ratio, 0.0, 1.0) * 2.0
end

function Rules.neutral_loss_per_mag(kind: number): number
	return 1.0 / (if kind == Rules.KIND_TRIBE then 10.0 else 5.0)
end

-- structure prices (Rules.build_cost); nukes are priced elsewhere
function Rules.build_cost(kind_name: string, n: number): number
	n = math.max(n, 0)
	if kind_name == "city" or kind_name == "port" or kind_name == "factory" then
		return minf(1000000.0, 125000.0 * 2.0 ^ math.min(n, 4))
	elseif kind_name == "defense" then
		return minf(250000.0, 50000.0 * (n + 1))
	elseif kind_name == "sam" then
		return minf(3000000.0, 1500000.0 * (n + 1))
	elseif kind_name == "silo" then
		return 1000000.0
	elseif kind_name == "warship" then
		return minf(1000000.0, 250000.0 * (n + 1))
	elseif kind_name == "artillery" then
		return minf(750000.0, 150000.0 * (n + 1))
	elseif kind_name == "airfield" then
		return minf(1500000.0, 500000.0 * (n + 1))
	elseif kind_name == "railgun" then
		return minf(7500000.0, 2500000.0 * (n + 1))
	end
	return -1.0
end

function Rules.sam_range(self: any, level: number): number
	return (150.0 - 480.0 / (math.max(level, 1) + 5)) * Rules.SAM_RADIUS_MULT / self.k_lin
end

-- tradeShipGold(dist): dist = full-size tiles sailed
function Rules.trade_gold(self: any, path_tiles: number): number
	local d = path_tiles * self.k_lin
	return 75000.0 / (1.0 + exp(-0.03 * (d - 300.0))) + 50.0 * d
end

function Rules.train_gold(rel: string, stops: number): number
	local base = 25000.0
	if rel == "self" then
		base = 10000.0
	elseif rel == "ally" then
		base = 35000.0
	end
	return maxf(5000.0, base - 5000.0 * math.max(0, stops - 9))
end

function Rules.human_grace_ticks(self: any, diff: number): number
	return Rules.HUMAN_GRACE_TICKS[clamp(diff, 0, 2)]
end

function Rules.place_search_r(self: any): number
	return 15.0 / self.k_lin
end
function Rules.port_spawn_manhattan(self: any): number
	return 20.0 / self.k_lin
end
-- transports / trade ships: 1 full-size tile per tick -> our tiles per sim second
function Rules.ship_tiles_per_s(self: any): number
	return 10.0 / self.k_lin
end
function Rules.alt_landing_r(self: any): number
	return math.max(3, ceil(6.0 / self.k_lin))
end

function Rules.trade_saturation(self: any, ships: number): number
	local boost = 1.0 + 0.45 * exp(-ships / 120.0)
	local damping = 1.0 - sigmoid(ships, log(2.0) / 50.0, 330.0)
	local plateau = 0.25 * (1.0 - sigmoid(ships, log(2.0) / 100.0, 800.0))
	return boost * maxf(damping, plateau)
end

function Rules.trade_spawn_rate(self: any, rejections: number, ships: number): number
	return math.max(1, trunc(floor(100.0 / (rejections + 1) / self:trade_saturation(ships))))
end

function Rules.nuke_radii_full_scaled(self: any, kind: number): vector
	return vcreate(Rules.NUKE_INNER_FULL[kind], Rules.NUKE_OUTER_FULL[kind], 0) / self.k_lin
end

-- share of a blast radius that is the inner (always-fallout) disc
function Rules.inner_frac(kind: number): number
	local o = Rules.NUKE_OUTER_FULL[kind]
	return if o > 0.0 then Rules.NUKE_INNER_FULL[kind] / o else 0.0
end

function Rules.sam_range_at(self: any, level: number, ticks_since_upgrade: number): number
	local r = self:sam_range(level)
	if level <= 1 or ticks_since_upgrade >= Rules.SAM_UPGRADE_TICKS then
		return r
	end
	local r0 = self:sam_range(level - 1)
	return r0 + (r - r0) * maxf(ticks_since_upgrade, 0) / Rules.SAM_UPGRADE_TICKS
end

function Rules.sam_ticks_to(self: any, manhattan_tiles: number): number
	return trunc(ceil(manhattan_tiles * self.k_lin / Rules.SAM_MISSILE_SPEED_FULL))
end

function Rules.munition_flight_ticks(self: any, dist_tiles: number, kind: number): number
	return math.max(1, trunc(ceil(dist_tiles * self.k_lin / Rules.NUKE_SPEED_FULL[clamp(kind, 0, 8)])))
end

function Rules.artillery_range(self: any): number
	return Rules.ARTILLERY_RANGE_FULL / self.k_lin
end
function Rules.airfield_range(self: any): number
	return Rules.AIRFIELD_RANGE_FULL / self.k_lin
end
function Rules.strike_radius(self: any, kind: number): number
	return Rules.NUKE_OUTER_FULL[kind] / self.k_lin
end
function Rules.scatter_near(self: any): number
	return Rules.SCATTER_NEAR_FULL / self.k_lin
end
function Rules.scatter_far(self: any): number
	return Rules.SCATTER_FAR_FULL / self.k_lin
end

-- troops a shell / air strike / slug kills of an army with src_full_tiles under it (s: the 1:1 troop scale)
function Rules.strike_kill(kind: number, troops: number, src_full_tiles: number, s: number?): number
	local sc = s or 1.0
	local t = maxf(troops, 0.0)
	if kind == Rules.N_SHELL then
		return minf(t, clamp(floor(t * Rules.SHELL_KILL_FRAC), Rules.SHELL_KILL_MIN * sc, Rules.SHELL_KILL_MAX * sc))
	end
	if kind == Rules.N_AIRSTRIKE then
		return floor(minf(t, minf(src_full_tiles * Rules.AIRSTRIKE_KILL_PER_TILE * sc, t * Rules.AIRSTRIKE_KILL_FRAC)))
	end
	if kind == Rules.N_SLUG then
		return floor(minf(t, minf(src_full_tiles * Rules.SLUG_KILL_PER_TILE * sc, t * Rules.SLUG_KILL_FRAC)))
	end
	return 0.0
end

function Rules.reinforce_troops(troops: number, cap: number): number
	return maxf(0.0, minf(floor(cap * Rules.REINFORCE_FRACTION), floor(cap) - floor(troops)))
end

-- nukeDeathFactor for a warhead, per full-size tile: 500 * (1 - e^(-2 * excess / max))
function Rules.warhead_death(troops: number, max_troops: number, s: number?): number
	local sc = s or 1.0
	local m = maxf(max_troops, 1.0)
	local excess = maxf(0.0, troops - 0.03 * m)
	return 500.0 * sc * (1.0 - exp(-2.0 * excess / m))
end

function Rules.warship_max_hp(vet: number): number
	return Rules.WARSHIP_HP * (100 + clamp(vet, 0, 3) * 20) // 100
end

function Rules.shell_damage(roll: number, vet: number): number
	local mult = (clamp(roll, 1, 5) - 1) * 25 + 200
	if vet > 0 then
		mult = mult * (100 + vet * 20) // 100
	end
	return round(250.0 / 250.0 * mult)
end

function Rules.shell_flight_ticks(self: any, dist_tiles: number): number
	return math.max(1, trunc(ceil(dist_tiles * self.k_lin / Rules.SHELL_SPEED_FULL)))
end

function Rules.warship_range(self: any): number
	return Rules.WARSHIP_RANGE_FULL / self.k_lin
end
function Rules.warship_patrol(self: any): number
	return Rules.WARSHIP_PATROL_FULL / self.k_lin
end
function Rules.warship_tiles_per_tick(self: any, hunting: boolean): number
	return (if hunting then 2.0 else 1.0) / self.k_lin
end

function Rules.train_saturation(units: number): number
	local boost = 1.0 + 0.5 * exp(-units / 30.0)
	local damping = 1.0 - sigmoid(units, log(2.0) / 100.0, 560.0)
	local plateau = 0.25 * (1.0 - sigmoid(units, log(2.0) / 150.0, 900.0))
	return boost * maxf(damping, plateau)
end

function Rules.train_spawn_rate(owner_factories: number, train_units: number): number
	local rate = (owner_factories + 10) * 15.0
	return math.max(1, trunc(floor(rate / Rules.train_saturation(train_units))))
end

function Rules.train_tiles_per_tick(self: any): number
	return Rules.TRAIN_SPEED_FULL / self.k_lin
end

-- roads (Rules.luau trainStationMin/MaxRange 15..110 full-size tiles, RAIL_LINK_HOPS, railroadMaxSize)
function Rules.road_min_tiles(self: any): number
	return 15.0 / self.k_lin
end
function Rules.road_max_tiles(self: any): number
	return 110.0 / self.k_lin
end
function Rules.rail_max_path(self: any): number
	return 110.0 * 1.4142 / self.k_lin
end

function Rules.nuke_kind_from_name(kind_name: string): number
	for i = 0, Rules.NUKE_KINDS - 1 do
		if Rules.NUKE_NAMES[i] == kind_name then
			return i
		end
	end
	return -1
end

function Rules.nuke_cost_named(kind_name: string, mirvs_launched: number?): number
	local k = Rules.nuke_kind_from_name(kind_name)
	if k < 0 or k == Rules.N_WARHEAD or k == Rules.N_SHELL then
		return -1.0
	end
	if k == Rules.N_MIRV then
		return Rules.NUKE_COST[k] + Rules.MIRV_COST_STEP * math.max(mirvs_launched or 0, 0)
	end
	return Rules.NUKE_COST[k]
end

function Rules.launch_range(self: any, kind: number): number
	if kind == Rules.N_AIRSTRIKE then
		return 156.0 / self.k_lin
	end
	if kind == Rules.N_SHELL then
		return 45.0 / self.k_lin
	end
	return 0.0
end

-- ---- nuke flight (Rules.luau 817-819, 847-916): MIRV spread, arc, flight time. All in our tiles.
-- Rules.MIRV_SPREAD = trunc(1500 / K_LIN)
function Rules.mirv_spread(self: any): number
	return trunc(1500.0 / self.k_lin)
end

-- (inner, outer) in our tiles; MIRV: (0, spread)
function Rules.nuke_radii(self: any, kind: number): vector
	if kind == Rules.N_MIRV then
		return vcreate(0.0, self:mirv_spread(), 0)
	end
	if kind < 0 or kind >= Rules.NUKE_KINDS then
		return vcreate(0, 0, 0)
	end
	return vcreate(Rules.NUKE_INNER_FULL[kind], Rules.NUKE_OUTER_FULL[kind], 0) / self.k_lin
end

function Rules.nuke_flight_ticks(self: any, dist_tiles: number, kind: number?): number
	local k = kind or Rules.N_ATOM
	return math.max(1, trunc(ceil(dist_tiles * self.k_lin / Rules.NUKE_SPEED_FULL[clamp(k, 0, Rules.NUKE_KINDS - 1)])))
end

-- Cubic Bezier from sp to dp (tile centres, map space), control points a quarter and three quarters along
-- raised by max(dist / 3, 50 full-size tiles) toward the top (clamped to [0, H - 1]), sampled into an
-- arc-length table: { pts = 0-based vectors, lens = 0-based float32 lengths, length = total, n = count }.
function Rules.nuke_arc(self: any, H: number, sp: vector, dp: vector): any
	local dd = dp - sp
	local hmax = maxf(vmag(dd) / 3.0, Rules.NUKE_ARC_MIN_HEIGHT_FULL / self.k_lin)
	local p1 = vcreate(sp.x + dd.x / 4.0, clamp(sp.y + dd.y / 4.0 - hmax, 0.0, H - 1), 0)
	local p2 = vcreate(sp.x + dd.x * 3.0 / 4.0, clamp(sp.y + dd.y * 3.0 / 4.0 - hmax, 0.0, H - 1), 0)
	local n = Rules.NUKE_ARC_SAMPLES
	local pts = table.create(n + 1)
	local lens = table.create(n + 1)
	local f32 = gd.f32
	local total = 0.0
	local prev = sp
	for i = 0, n do
		local t = i / n
		local u = 1.0 - t
		local pt = sp * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + dp * (t * t * t)
		if i > 0 then
			total += vmag(pt - prev)
		end
		pts[i] = pt
		lens[i] = f32(total)
		prev = pt
	end
	return { pts = pts, lens = lens, length = total, n = n + 1 }
end

-- the nuke arc for bombs, a straight line for the flat munitions
function Rules.munition_arc(self: any, H: number, sp: vector, dp: vector, kind: number): any
	if kind < 0 or not Rules.NUKE_FLAT[kind] then
		return self:nuke_arc(H, sp, dp)
	end
	local len = vmag(sp - dp)
	return { pts = { [0] = sp, dp }, lens = { [0] = 0.0, gd.f32(len) }, length = len, n = 2 }
end

-- the point at arc-length fraction s in [0, 1] (tile units, map space)
function Rules.nuke_arc_at(arc: any, s: number): vector
	local pts = arc.pts
	local lens = arc.lens
	local total = arc.length
	if total <= 0.0 then
		return pts[0]
	end
	local want = clamp(s, 0.0, 1.0) * total
	local lo = 0
	local hi = arc.n - 1
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if lens[mid] < want then
			lo = mid
		else
			hi = mid
		end
	end
	local seg = lens[hi] - lens[lo]
	local f = if seg > 0.0 then (want - lens[lo]) / seg else 0.0
	local a = pts[lo]
	return a + (pts[hi] - a) * f
end

-- nukeSpeed full-size tiles along the curve per tick
function Rules.nuke_arc_ticks(self: any, arc: any, kind: number?): number
	local k = kind or Rules.N_ATOM
	return math.max(1, trunc(ceil(arc.length * self.k_lin / Rules.NUKE_SPEED_FULL[clamp(k, 0, Rules.NUKE_KINDS - 1)])))
end

return Rules
