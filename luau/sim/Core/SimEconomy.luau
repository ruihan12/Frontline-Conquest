--!strict
-- SimEconomy: troop growth, gold income and the reinforcement cooldown of every live nation (docs/LUAU_PORT.md,
-- Step 5e). Transliterated from this project's game/economy.gd _economy, which follows upstream RoWorld
-- (AGPL-3.0, lukechatton/roworld) Sim troop growth (Rules.luau troopIncreaseRate, maxTroops) and the per-tick
-- gold of Rules.luau.
--
-- The nations stay GDScript Dictionaries. game/economy.gd keeps the parts with side effects (the overflow guards,
-- deaths with their sound, stats, notes and rng draw, the console's god mode, supply drops, the nuke queue) and
-- sends one row per nation that is still alive after them; this returns the new values in the same order.
local Rules = require("./Rules")
local SimAttacks = require("./SimAttacks")

local readf64, writef64 = buffer.readf64, buffer.writef64

local M = {}

local R = Rules.new(1.0)

local IN_ROW = 10 -- id, troops, gold, land, pop, city levels, troop kind, troop difficulty, kind, reinf_cd
local OUT_ROW = 5 -- troops, gold, regen, reinf_cd, cap

-- rf: rule fields (SimAttacks.RULE_FIELDS). hdr (f64): dt, 1 when the cap comes from population (tile_pop),
-- tile_pop_avg. nb: IN_ROW f64 per nation. -> { rows = OUT_ROW f64 per nation }
function M.tick(rf: buffer, hdr: buffer, nb: buffer): any
	for i, name in SimAttacks.RULE_FIELDS do
		(R :: any)[name] = readf64(rf, (i - 1) * 8)
	end
	local dt = readf64(hdr, 0)
	local by_pop = readf64(hdr, 8) ~= 0
	local pop_avg = readf64(hdr, 16)
	local n = buffer.len(nb) // (IN_ROW * 8)
	local out = buffer.create(n * OUT_ROW * 8)
	for j = 0, n - 1 do
		local k = j * IN_ROW * 8
		local troops = readf64(nb, k + 8)
		local gold = readf64(nb, k + 16)
		local land = readf64(nb, k + 24)
		local pop = readf64(nb, k + 32)
		local city = readf64(nb, k + 40)
		local tk = readf64(nb, k + 48)
		local tdf = readf64(nb, k + 56)
		local kd = readf64(nb, k + 64)
		local cd = readf64(nb, k + 72)
		local cap = if by_pop then R:max_troops_pop(tk, land, pop, pop_avg, city, tdf) else R:max_troops(tk, land, city, tdf)
		local regen = R:troop_growth(tk, troops, cap, tdf) * 10.0
		troops += R:troop_growth_applied(tk, troops, cap, tdf)
		gold += R:gold_per_tick(kd)
		cd = math.max(0.0, cd - dt)
		local o = j * OUT_ROW * 8
		writef64(out, o, troops)
		writef64(out, o + 8, gold)
		writef64(out, o + 16, regen)
		writef64(out, o + 24, cd)
		writef64(out, o + 32, cap)
	end
	return { rows = out }
end

return M
