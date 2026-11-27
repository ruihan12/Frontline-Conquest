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
--
-- Step 5f2: near() is sim/ai.gd _tribe_nearby (upstream SimAI tribe nearby): the same scan, then the shore probes
-- (every k-th coastal border tile looks a fixed distance out over each neighbouring water tile) for owners the
-- border doesn't touch.
--
-- Step 5f3: coast() is sim/ai.gd own_coast / own_coast_tiles: the coastal tiles of an owner's border, in border
-- order, at most `cap`.
local SimState = require("./SimState")
local GodotRng = require("./GodotRng")

local readi32, readu8, writef64 = buffer.readi32, buffer.readu8, buffer.writef64

local M = {}

local rng = GodotRng.new(0, true)

-- The walk (rng must be loaded): -> list, count, first, neutral, ntile, ftile
local function do_scan(id: number, cap: number)
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
	return list, count, first, neutral, ntile, ftile
end

local function pack_sc(list: { number }, count: { [number]: number }, first: { [number]: number }): buffer
	local sc = buffer.create(#list * 24)
	for k, o in list do
		local b = (k - 1) * 24
		writef64(sc, b, o)
		writef64(sc, b + 8, count[o])
		writef64(sc, b + 16, first[o])
	end
	return sc
end

-- id: the owner; cap: how many border tiles to walk (-1: all). -> { rhi, rlo, sc = f64 (owner, count, first tile)
-- per neighbour owner in the order first seen, nt = neutral tiles counted, ntile = the picked neutral tile (-1),
-- ftile = the first fallout tile (-1) }
function M.scan(rhi: number, rlo: number, id: number, cap: number): any
	rng.shi = rhi
	rng.slo = rlo
	local list, count, first, neutral, ntile, ftile = do_scan(id, cap)
	return { rhi = rng.shi, rlo = rng.slo, sc = pack_sc(list, count, first), nt = neutral, ntile = ntile, ftile = ftile }
end

-- A tribe's whole-border scan, then the shore probes: every `every`-th coastal tile of its border (border order;
-- coastal: a 4-neighbour is water, -1) looks `dist` tiles out in each direction (up, down, left, right) whose first
-- step is water; an owner there that is not water / ice, not itself, not yet seen and not fallout land is added.
-- -> scan's fields plus ex = f64 owners the probes added (in order), tn = 1 when free land is nearby
function M.near(rhi: number, rlo: number, id: number, every: number, dist: number): any
	rng.shi = rhi
	rng.slo = rlo
	local list, count, first, neutral, ntile, ftile = do_scan(id, -1)
	local seen: { [number]: boolean } = {}
	for _, o in list do
		seen[o] = true
	end
	local tn = neutral > 0
	if tn then
		seen[0] = true
	end
	local ex: { number } = {}
	local s = SimState.cur
	if id < s.nat_n then
		local om, fo, W, N, nx = s.owner, s.fallout, s.W, s.n, s.bnext
		local H = N // W
		local k = 0
		local t = s.bhead[id]
		while t >= 0 do
			local x = t % W
			if (x < W - 1 and readi32(om, (t + 1) * 4) == -1) or (x > 0 and readi32(om, (t - 1) * 4) == -1)
				or (t + W < N and readi32(om, (t + W) * 4) == -1) or (t >= W and readi32(om, (t - W) * 4) == -1)
			then
				if k % every == 0 then
					local y = t // W
					for d = 0, 3 do
						local dx, dy = 0, 0
						if d == 0 then
							dy = -1
						elseif d == 1 then
							dy = 1
						elseif d == 2 then
							dx = -1
						else
							dx = 1
						end
						local x1, y1 = x + dx, y + dy
						if x1 >= 0 and x1 < W and y1 >= 0 and y1 < H and readi32(om, (y1 * W + x1) * 4) == -1 then
							local fx, fy = x + dx * dist, y + dy * dist
							if fx >= 0 and fx < W and fy >= 0 and fy < H then
								local n = fy * W + fx
								local o = readi32(om, n * 4)
								if not (o < 0 or o == id or seen[o] or (o == 0 and readu8(fo, n) == 1)) then
									seen[o] = true
									ex[#ex + 1] = o
									tn = tn or o == 0
								end
							end
						end
					end
				end
				k += 1
			end
			t = readi32(nx, t * 4)
		end
	end
	local eb = buffer.create(#ex * 8)
	for i, o in ex do
		writef64(eb, (i - 1) * 8, o)
	end
	return {
		rhi = rng.shi,
		rlo = rng.slo,
		sc = pack_sc(list, count, first),
		nt = neutral,
		ntile = ntile,
		ftile = ftile,
		ex = eb,
		tn = if tn then 1 else 0,
	}
end

-- id's coastal border tiles (a 4-neighbour is water, -1: game/economy.gd _coastal) in border order, at most cap.
-- -> { t = f64 tiles }
function M.coast(id: number, cap: number): any
	local out: { number } = {}
	local s = SimState.cur
	if id < s.nat_n and cap > 0 then
		local om, W, N, nx = s.owner, s.W, s.n, s.bnext
		local t = s.bhead[id]
		while t >= 0 do
			local x = t % W
			if (x < W - 1 and readi32(om, (t + 1) * 4) == -1) or (x > 0 and readi32(om, (t - 1) * 4) == -1)
				or (t + W < N and readi32(om, (t + W) * 4) == -1) or (t >= W and readi32(om, (t - W) * 4) == -1)
			then
				out[#out + 1] = t
				if #out >= cap then
					break
				end
			end
			t = readi32(nx, t * 4)
		end
	end
	local b = buffer.create(#out * 8)
	for i, t in out do
		writef64(b, (i - 1) * 8, t)
	end
	return { t = b }
end

return M
