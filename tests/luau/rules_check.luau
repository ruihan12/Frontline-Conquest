--!strict
-- Helper for tests/test_luau_rules.gd: Core/Rules values and results flattened to f64 buffers, so the test can
-- compare them byte for byte with SimRules (sim/rules.gd).
local Rules = require("Core/Rules")

local M = {}

-- functions with no self (GDScript static func)
local STATIC = {}
for _, n in { "sigmoid", "land_share", "win_share", "dominates", "fallout_modifier", "neutral_loss_per_mag", "build_cost",
	"train_gold", "inner_frac", "strike_kill", "reinforce_troops", "warhead_death", "warship_max_hp", "shell_damage",
	"train_saturation", "train_spawn_rate", "nuke_kind_from_name", "nuke_cost_named" } do
	STATIC[n] = true
end

local function flatten(v: any, as_dict: boolean, out: { number })
	local t = typeof(v)
	if t == "number" then
		table.insert(out, v)
	elseif t == "boolean" then
		table.insert(out, if v then 1 else 0)
	elseif t == "vector" then
		table.insert(out, v.x)
		table.insert(out, v.y)
	elseif t == "table" then
		if as_dict then
			local keys = {}
			for k in v do
				table.insert(keys, k)
			end
			table.sort(keys)
			for _, k in keys do
				table.insert(out, k)
				flatten(v[k], false, out)
			end
		else
			local i = 0
			while v[i] ~= nil do
				flatten(v[i], false, out)
				i += 1
			end
		end
	else
		error("flatten: " .. t)
	end
end

local function to_buf(out: { number }): buffer
	local b = buffer.create(#out * 8)
	for i, x in out do
		buffer.writef64(b, (i - 1) * 8, x)
	end
	return b
end

-- every upper-case key of Rules (the GDScript constants), sorted
function M.const_names(): { string }
	local names = {}
	for k, v in Rules do
		if typeof(k) == "string" and string.upper(k) == k and typeof(v) ~= "function" then
			table.insert(names, k)
		end
	end
	table.sort(names)
	return names
end

function M.const(name: string, as_dict: boolean): buffer
	local out = {}
	flatten(Rules[name], as_dict, out)
	return to_buf(out)
end

function M.const_str(name: string): string
	local t = Rules[name]
	local parts = {}
	local i = 0
	while t[i] ~= nil do
		table.insert(parts, t[i])
		i += 1
	end
	return table.concat(parts, ",")
end

local function make(cfg: any): any
	local r = Rules.new(cfg.kl)
	r:set_troop_scale(cfg.ts_on)
	r.pop_cap_mode = cfg.pop_cap_mode
	r.tile_norm = cfg.tile_norm
	r.growth_mult = cfg.growth_mult
	r.gold_mult = cfg.gold_mult
	return r
end

function M.fields(cfg: any, names: { string }): buffer
	local r = make(cfg)
	local out = {}
	for _, n in names do
		flatten(r[n], false, out)
	end
	return to_buf(out)
end

-- calls: { { fname, args... }, ... }; results flattened in order. Arc functions take the two points as
-- four numbers (sx, sy, dx, dy) and build the vectors here.
function M.eval(cfg: any, calls: { { any } }): buffer
	local r = make(cfg)
	local out = {}
	for _, c in calls do
		local f = c[1]
		local v: any
		if f == "nuke_arc" then
			v = r:nuke_arc(c[2], vector.create(c[3], c[4], 0), vector.create(c[5], c[6], 0))
			out[#out + 1] = v.n
			for i = 0, v.n - 1 do
				flatten(v.pts[i], false, out)
			end
			for i = 0, v.n - 1 do
				out[#out + 1] = v.lens[i]
			end
			out[#out + 1] = v.length
			continue
		elseif f == "arc_at" then
			local arc = r:munition_arc(c[2], vector.create(c[3], c[4], 0), vector.create(c[5], c[6], 0), c[7])
			v = Rules.nuke_arc_at(arc, c[8])
		elseif f == "arc_ticks" then
			local arc = r:munition_arc(c[2], vector.create(c[3], c[4], 0), vector.create(c[5], c[6], 0), c[7])
			v = r:nuke_arc_ticks(arc, c[8])
		elseif f == "arc_len" then
			v = r:munition_arc(c[2], vector.create(c[3], c[4], 0), vector.create(c[5], c[6], 0), c[7]).length
		else
			local fn = Rules[f]
			if fn == nil then
				error("no Rules." .. tostring(f))
			end
			if STATIC[f] then
				v = fn(table.unpack(c, 2))
			else
				v = fn(r, table.unpack(c, 2))
			end
		end
		flatten(v, false, out)
	end
	return to_buf(out)
end

return M
