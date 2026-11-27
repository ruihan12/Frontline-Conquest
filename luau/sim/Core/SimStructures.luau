--!strict
-- SimStructures: structure placement and construction (docs/LUAU_PORT.md, Step 5b). Transliterated from this
-- project's sim/structures.gd (place_site, which ports upstream RoWorld Rules.place_site, AGPL-3.0,
-- lukechatton/roworld) and the construction countdown of sim/arsenal.gd tick (upstream
-- SimStructures.construction_tick).
--
-- The structure list itself is still GDScript's (game.structs: Dictionaries the renderer, net/rep.gd, the
-- arsenal, the AI and the tests read and write). sync() hands Luau a snapshot of the fields this module reads,
-- in list order (f64 per structure: k, tile, o, level, bt), so a structure is named by its index in the list.
-- The list moves to Luau with the modules that read it per tick (arsenal, AI).
local Rules = require("./Rules")
local SimState = require("./SimState")
local SimAttacks = require("./SimAttacks")

local readf64, writef64, writei32 = buffer.readf64, buffer.writef64, buffer.writei32
local readi32 = buffer.readi32

local M = {}

M.SNAP = 5 -- f64 per structure in the snapshot
local SNAP = M.SNAP
local WATER = -1
local K_PORT = 1
-- SimRules.UPGRADABLE_K (sim/rules.gd)
local UPGRADABLE: { [number]: boolean } = {}

local R = Rules.new(1.0)

local S = {
	n = 0,
	k = {} :: { number },
	tile = {} :: { number },
	o = {} :: { number },
	level = {} :: { number },
	bt = {} :: { number },
}

function M.reset(): boolean
	S.n = 0
	S.k, S.tile, S.o, S.level, S.bt = {}, {}, {}, {}, {}
	return true
end

-- upgradable kinds (i32 list) and the rules fields (SimAttacks.RULE_FIELDS order), once per match
function M.setup(upgradable: buffer, fields: buffer): boolean
	table.clear(UPGRADABLE)
	for k = 0, buffer.len(upgradable) - 4, 4 do
		UPGRADABLE[readi32(upgradable, k)] = true
	end
	for i, name in SimAttacks.RULE_FIELDS do
		(R :: any)[name] = readf64(fields, (i - 1) * 8)
	end
	return true
end

-- game.structs -> Luau, in list order
function M.sync(snap: buffer): number
	local n = buffer.len(snap) // (SNAP * 8)
	local K, T, O, L, B = S.k, S.tile, S.o, S.level, S.bt
	for i = 1, n do
		local b = (i - 1) * SNAP * 8
		K[i] = readf64(snap, b)
		T[i] = readf64(snap, b + 8)
		O[i] = readf64(snap, b + 16)
		L[i] = readf64(snap, b + 24)
		B[i] = readf64(snap, b + 32)
	end
	for i = n + 1, S.n do
		K[i], T[i], O[i], L[i], B[i] = nil :: any, nil :: any, nil :: any, nil :: any, nil :: any
	end
	S.n = n
	return n
end

-- sim/arsenal.gd tick, the construction part: every structure still being built counts 0.1 s down; one that
-- reaches 0 activates. Returns busy = i32 indices (0-based) of the structures that were being built, in list
-- order, bt = their new build time (f64 each, same order), act = u8 per busy entry, 1 when it activated.
function M.construction(): any
	local B = S.bt
	local idx = {}
	for i = 1, S.n do
		if B[i] > 0.0 then
			idx[#idx + 1] = i
		end
	end
	local m = #idx
	local busy = buffer.create(m * 4)
	local bt = buffer.create(m * 8)
	local act = buffer.create(m)
	for j = 1, m do
		local i = idx[j]
		local v = B[i] - 0.1
		if v < 0.0 then
			v = 0.0
		end
		B[i] = v
		writei32(busy, (j - 1) * 4, i - 1)
		writef64(bt, (j - 1) * 8, v)
		if v <= 0.0 then
			buffer.writeu8(act, j - 1, 1)
		end
	end
	return { busy = busy, bt = bt, act = act }
end

local function d2(a: number, b: number, W: number): number
	local dx = a % W - b % W
	local dy = a // W - b // W
	return dx * dx + dy * dy
end

local function coastal(st: any, i: number): boolean
	local W = st.W
	local n = st.n
	local own = st.owner
	-- economy.gd _coastal: right, left, down, up
	if i % W ~= W - 1 and i + 1 < n and readi32(own, (i + 1) * 4) == WATER then
		return true
	end
	if i % W ~= 0 and i - 1 >= 0 and readi32(own, (i - 1) * 4) == WATER then
		return true
	end
	if i + W < n and readi32(own, (i + W) * 4) == WATER then
		return true
	end
	if i - W >= 0 and readi32(own, (i - W) * 4) == WATER then
		return true
	end
	return false
end

-- sim/structures.gd place_site: returns { tile, up (index 0-based of the structure to upgrade, -1 none), reason }
function M.place_site(id: number, k: number, tile: number): any
	local st = SimState.cur :: any
	local out = { tile = -1, up = -1, reason = "" }
	local W = st.W
	local n = st.n
	local own = st.owner
	if tile < 0 or tile >= n then
		out.reason = "invalid"
		return out
	end
	if readi32(own, tile * 4) ~= id then
		out.reason = "not_own"
		return out
	end
	local md = R.struct_min_dist
	local md2 = md * md
	local psr = Rules.place_search_r(R)
	local reach = psr + md + 1.0
	local near = {}
	local tx = tile % W
	local ty = tile // W
	local T = S.tile
	for i = 1, S.n do
		local t = T[i]
		local dx = t % W - tx
		local dy = t // W - ty
		if dx * dx + dy * dy <= reach * reach then
			near[#near + 1] = i
		end
	end
	if UPGRADABLE[k] then
		local best = -1
		local bd = 0.0
		for _, i in near do
			if S.k[i] ~= k then
				continue
			end
			local d = d2(T[i], tile, W)
			if d > md2 then
				continue
			end
			if best < 0 or d < bd then
				best = i
				bd = d
			end
		end
		if best >= 0 and S.o[best] == id and S.bt[best] <= 0.0 then
			out.tile = T[best]
			out.up = best - 1
			return out
		end
	end
	local r2 = psr * psr
	local seen: { [number]: boolean } = { [tile] = true }
	local stack = { tile }
	local flood = { tile }
	while #stack > 0 do
		local t = table.remove(stack) :: number
		local x = t % W
		-- up, down, left, right (sim/structures.gd order)
		local nb1 = if t >= W then t - W else -1
		local nb2 = if t < n - W then t + W else -1
		local nb3 = if x > 0 then t - 1 else -1
		local nb4 = if x < W - 1 then t + 1 else -1
		for _, nb in { nb1, nb2, nb3, nb4 } do
			if nb < 0 or seen[nb] or readi32(own, nb * 4) ~= id or d2(tile, nb, W) >= r2 then
				continue
			end
			seen[nb] = true
			flood[#flood + 1] = nb
			stack[#stack + 1] = nb
		end
	end
	local port = k == K_PORT
	local pick = -1
	local pd = 0.0
	local pm = Rules.port_spawn_manhattan(R)
	for _, t in flood do
		local man = math.abs(t % W - tx) + math.abs(t // W - ty)
		if port and (not coastal(st, t) or man > pm) then
			continue
		end
		local blocked = false
		for _, i in near do
			if d2(T[i], t, W) < md2 then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end
		local d = if port then man else d2(tile, t, W)
		if pick < 0 or d < pd then
			pick = t
			pd = d
		end
	end
	if pick < 0 then
		out.reason = if port then "no_coast" else "no_room"
		return out
	end
	out.tile = pick
	return out
end

return M
