--!strict
--!native
-- SimAI: the nation and tribe AI (docs/LUAU_PORT.md, Step 5f). Transliterated from this project's sim/ai.gd, which
-- ports upstream RoWorld SimAI.luau + SimAIEconomy.luau (AGPL-3.0, lukechatton/roworld).
--
-- Step 5f1: perception only. scan() is sim/ai.gd _scan_border (upstream Sim.scan_border): a walk over the
-- owner's border set in Dictionary order (nations: at most 400 legacy tiles, tribes: the whole set), counting the
-- owners of the land next to it, the neutral land (one tile picked by reservoir sampling on the sim rng) and the
-- first fallout tile. It reads Luau's tile layer (Core/SimState), which sim/luau_link.gd keeps equal to the
-- GDScript one at every flush. The thinking and the actions stay GDScript for now.
local SimState = require("./SimState")
local GodotRng = require("./GodotRng")

local readi32, readu8, writef64 = buffer.readi32, buffer.readu8, buffer.writef64

local M = {}

local rng = GodotRng.new(0, true)

-- id: the owner; cap: how many border tiles to walk (-1: all). -> { rhi, rlo, sc = f64 (owner, count, first tile)
-- per neighbour owner in the order first seen, nt = neutral tiles counted, ntile = the picked neutral tile (-1),
-- ftile = the first fallout tile (-1) }
function M.scan(rhi: number, rlo: number, id: number, cap: number): any
	rng.shi = rhi
	rng.slo = rlo
	local s = SimState.cur
	local list: { number } = {}
	local count: { [number]: number } = {}
	local first: { [number]: number } = {}
	local neutral, ntile, ftile = 0, -1, -1
	if id < s.nat_n then
		local om, fo, W, N, nx = s.owner, s.fallout, s.W, s.n, s.bnext
		local lim = if cap < 0 then s.bcnt[id] else cap
		local seen = 0
		local t = s.bhead[id]
		while t >= 0 do
			if seen >= lim then
				break
			end
			seen += 1
			local x = t % W
			-- the four neighbours in GDScript's order (left, right, up, down); water (< 0) and own land are skipped
			if x > 0 then
				local n = t - 1
				local o = readi32(om, n * 4)
				if o == 0 then
					if readu8(fo, n) == 1 then
						if ftile < 0 then
							ftile = n
						end
					else
						neutral += 1
						if ntile < 0 or rng:randi() % neutral == 0 then
							ntile = n
						end
					end
				elseif o > 0 and o ~= id then
					local c = count[o]
					if c == nil then
						list[#list + 1] = o
						count[o] = 1
						first[o] = n
					else
						count[o] = c + 1
					end
				end
			end
			if x < W - 1 then
				local n = t + 1
				local o = readi32(om, n * 4)
				if o == 0 then
					if readu8(fo, n) == 1 then
						if ftile < 0 then
							ftile = n
						end
					else
						neutral += 1
						if ntile < 0 or rng:randi() % neutral == 0 then
							ntile = n
						end
					end
				elseif o > 0 and o ~= id then
					local c = count[o]
					if c == nil then
						list[#list + 1] = o
						count[o] = 1
						first[o] = n
					else
						count[o] = c + 1
					end
				end
			end
			if t >= W then
				local n = t - W
				local o = readi32(om, n * 4)
				if o == 0 then
					if readu8(fo, n) == 1 then
						if ftile < 0 then
							ftile = n
						end
					else
						neutral += 1
						if ntile < 0 or rng:randi() % neutral == 0 then
							ntile = n
						end
					end
				elseif o > 0 and o ~= id then
					local c = count[o]
					if c == nil then
						list[#list + 1] = o
						count[o] = 1
						first[o] = n
					else
						count[o] = c + 1
					end
				end
			end
			if t + W < N then
				local n = t + W
				local o = readi32(om, n * 4)
				if o == 0 then
					if readu8(fo, n) == 1 then
						if ftile < 0 then
							ftile = n
						end
					else
						neutral += 1
						if ntile < 0 or rng:randi() % neutral == 0 then
							ntile = n
						end
					end
				elseif o > 0 and o ~= id then
					local c = count[o]
					if c == nil then
						list[#list + 1] = o
						count[o] = 1
						first[o] = n
					else
						count[o] = c + 1
					end
				end
			end
			t = readi32(nx, t * 4)
		end
	end
	local sc = buffer.create(#list * 24)
	for k, o in list do
		local b = (k - 1) * 24
		writef64(sc, b, o)
		writef64(sc, b + 8, count[o])
		writef64(sc, b + 16, first[o])
	end
	return { rhi = rng.shi, rlo = rng.slo, sc = sc, nt = neutral, ntile = ntile, ftile = ftile }
end

return M
