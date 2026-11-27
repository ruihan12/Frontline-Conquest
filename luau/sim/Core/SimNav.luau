--!strict
-- SimNav: water pathfinding (docs/LUAU_PORT.md, Step 5d1). Line-for-line transliteration of this project's
-- sim/nav.gd, which ports upstream RoWorld src/shared/Core/SimNav.luau (AGPL-3.0, lukechatton/roworld @ae7a350).
--
-- 8 x 8 tile cells, 4-connected water regions per cell, a region graph (CSR) with weighted A* (w 1.4) and a
-- coarse cluster level, in-region BFS stitching through portal tiles, string pulling with line-of-sight checks.
--
-- Float rules, so results match the GDScript bit for bit: every value GDScript keeps in a PackedFloat32Array
-- (region centres, edge costs, A* g scores, heap keys, cluster centres) or computes as a Vector2 (float32 in
-- Godot) is rounded through f32() here; GDScript locals (`float`) are f64, as Luau numbers are.
-- The sort keys of the edge list ((pair << 23) | sample) need 63 bits; here the samples are sorted by (pair,
-- sample), which is the same order.
--
-- One nav per map, named by a handle (the gen cache keeps the previous map's SimNav object alive).
local SimState = require("./SimState")

local readi32, writei32 = buffer.readi32, buffer.writei32
local writef32, readf32 = buffer.writef32, buffer.readf32
local sqrt, abs, floor, min, max = math.sqrt, math.abs, math.floor, math.min, math.max

local M = {}

local CELL = 8
local HEURISTIC_W = 1.4
local PAIR_K = 1048576 -- 1 << 20, region ids stay below 2^20
local C_LAND = -2
local C_MIXED = -1
local SUPER = 8
local CORRIDOR_WIDEN = 0
local REG_CACHE_MAX = 4096
local ROUTE_CACHE_MAX = 2048

local fb = buffer.create(4)
local function f32(x: number): number
	writef32(fb, 0, x)
	return readf32(fb, 0)
end
M.f32 = f32

-- Godot Vector2(x, y).length(): components stored as float32, length in float32
local function len32(x: number, y: number): number
	local fx, fy = f32(x), f32(y)
	return f32(sqrt(f32(f32(fx * fx) + f32(fy * fy))))
end
M.len32 = len32

-- truncating integer division (GDScript int /), operands may be negative
local function idiv(a: number, b: number): number
	local q = a / b
	if q >= 0 then
		return floor(q)
	end
	return -floor(-q)
end

type Nav = {
	ready: boolean,
	W: number,
	H: number,
	N: number,
	CW: number,
	CH: number,
	body: buffer,
	cell_reg: { number },
	region: buffer,
	reg_count: number,
	reg_body: { number },
	reg_tile: { number },
	reg_x: { number },
	reg_y: { number },
	reg_full: { number },
	reg_n: { number },
	adj_off: { number },
	adj_to: { number },
	adj_cost: { number },
	adj_pa: { number },
	adj_pb: { number },
	reg_clu: { number },
	clu_count: number,
	clu_x: { number },
	clu_y: { number },
	cadj_off: { number },
	cadj_to: { number },
	cadj_cost: { number },
	_cg: { number },
	_ccame: { number },
	_cseen: { number },
	_cclosed: { number },
	_cmark: { number },
	_cstamp: number,
	coast_off: { number },
	coast_tiles: { number },
	_g: { number },
	_came: { number },
	_seen: { number },
	_closed: { number },
	_stamp: number,
	_hn: { number },
	_hf: { number },
	_hs: number,
	_lpar: { number },
	_lseen: { number },
	_lstamp: number,
	_reg_cache: { [number]: { number } },
	_reg_n: number,
	_route_cache: { [number]: { number } },
	_route_n: number,
	budget_n: number,
	_spent: number,
	searches: number,
	expanded: number,
	fails: number,
	cache_hits: number,
	deferred: number,
	last_deferred: boolean,
}

local navs: { [number]: Nav } = {}
local next_id = 1

-- 0-based table helpers (GDScript arrays are 0-based; tables here are indexed the same way)
local function zeros(n: number, v: number): { number }
	local t = table.create(n + 1, v)
	t[0] = v
	return t
end

local function body_at(nv: Nav, t: number): number
	return readi32(nv.body, t * 4)
end

local function region_at(nv: Nav, t: number): number
	return readi32(nv.region, t * 4)
end

local function region_of(nv: Nav, t: number): number
	if t < 0 or t >= nv.N then
		return -1
	end
	local W = nv.W
	local cr = nv.cell_reg[(idiv(idiv(t, W), CELL)) * nv.CW + idiv(t % W, CELL)]
	if cr >= 0 then
		return cr
	end
	if cr == C_LAND then
		return -1
	end
	return region_at(nv, t)
end

-- ------------------------------------------------------------------------------------------------ build

local function _build_clusters(nv: Nav)
	local rc = nv.reg_count
	local W, CW = nv.W, nv.CW
	local SW = idiv(CW + SUPER - 1, SUPER)
	local sup = zeros(max(rc, 1), 0)
	local reg_tile, adj_off, adj_to = nv.reg_tile, nv.adj_off, nv.adj_to
	for r = 0, rc - 1 do
		local t = reg_tile[r]
		sup[r] = idiv(idiv(idiv(t, W), CELL), SUPER) * SW + idiv(idiv(t % W, CELL), SUPER)
	end
	local par = zeros(max(rc, 1), 0)
	for r = 0, rc - 1 do
		par[r] = r
	end
	for r = 0, rc - 1 do
		for k = adj_off[r], adj_off[r + 1] - 1 do
			local n = adj_to[k]
			if n <= r or sup[n] ~= sup[r] then
				continue
			end
			local a = r
			while par[a] ~= a do
				par[a] = par[par[a]]
				a = par[a]
			end
			local b = n
			while par[b] ~= b do
				par[b] = par[par[b]]
				b = par[b]
			end
			if a ~= b then
				par[max(a, b)] = min(a, b)
			end
		end
	end
	local reg_clu = zeros(max(rc, 1), 0)
	local cid = zeros(max(rc, 1), -1)
	local cc = 0
	local sx: { number } = {}
	local sy: { number } = {}
	local sn: { number } = {}
	local reg_x, reg_y = nv.reg_x, nv.reg_y
	for r = 0, rc - 1 do
		local a = r
		while par[a] ~= a do
			a = par[a]
		end
		if cid[a] < 0 then
			cid[a] = cc
			sx[cc] = 0.0
			sy[cc] = 0.0
			sn[cc] = 0
			cc += 1
		end
		local c = cid[a]
		reg_clu[r] = c
		-- PackedFloat32Array: sx[c] += reg_x[r] is stored as float32
		sx[c] = f32(sx[c] + reg_x[r])
		sy[c] = f32(sy[c] + reg_y[r])
		sn[c] += 1
	end
	nv.reg_clu = reg_clu
	nv.clu_count = cc
	for c = 0, cc - 1 do
		sx[c] = f32(sx[c] / sn[c])
		sy[c] = f32(sy[c] / sn[c])
	end
	nv.clu_x = sx
	nv.clu_y = sy
	local keys: { number } = {}
	for r = 0, rc - 1 do
		local a = reg_clu[r]
		for k = adj_off[r], adj_off[r + 1] - 1 do
			local b = reg_clu[adj_to[k]]
			if b > a then
				table.insert(keys, a * PAIR_K + b)
			end
		end
	end
	table.sort(keys)
	local ga: { number } = {}
	local gb: { number } = {}
	local deg = zeros(cc + 1, 0)
	local prev = -1
	for _, k in keys do
		if k == prev then
			continue
		end
		prev = k
		local a = idiv(k, PAIR_K)
		local b = k % PAIR_K
		table.insert(ga, a)
		table.insert(gb, b)
		deg[a] += 1
		deg[b] += 1
	end
	local cadj_off = zeros(cc + 1, 0)
	local acc = 0
	for c = 0, cc - 1 do
		cadj_off[c] = acc
		acc += deg[c]
	end
	cadj_off[cc] = acc
	local cadj_to = zeros(max(acc, 1), 0)
	local cadj_cost = zeros(max(acc, 1), 0.0)
	local fill = zeros(cc + 1, 0)
	for q = 1, #ga do
		local a, b = ga[q], gb[q]
		local cost = len32(sx[a] - sx[b], sy[a] - sy[b])
		local ia = cadj_off[a] + fill[a]
		fill[a] += 1
		cadj_to[ia] = b
		cadj_cost[ia] = cost
		local ib = cadj_off[b] + fill[b]
		fill[b] += 1
		cadj_to[ib] = a
		cadj_cost[ib] = cost
	end
	nv.cadj_off, nv.cadj_to, nv.cadj_cost = cadj_off, cadj_to, cadj_cost
	local n1 = max(cc, 1)
	nv._cg = zeros(n1, 0.0)
	nv._ccame = zeros(n1, 0)
	nv._cseen = zeros(n1, 0)
	nv._cclosed = zeros(n1, 0)
	nv._cmark = zeros(n1, 0)
	nv._cstamp = 0
end

-- water_body: i32 per tile (sim/naval.gd body), w x h. Returns the nav handle.
function M.build(water_body: buffer, w: number, h: number): number
	local W, H = w, h
	local N = w * h
	local CW = idiv(W + CELL - 1, CELL)
	local CH = idiv(H + CELL - 1, CELL)
	local nv: Nav = {
		ready = false,
		W = W,
		H = H,
		N = N,
		CW = CW,
		CH = CH,
		body = water_body,
		cell_reg = zeros(CW * CH, 0),
		region = buffer.create(N * 4),
		reg_count = 0,
		reg_body = {},
		reg_tile = {},
		reg_x = {},
		reg_y = {},
		reg_full = {},
		reg_n = {},
		adj_off = {},
		adj_to = {},
		adj_cost = {},
		adj_pa = {},
		adj_pb = {},
		reg_clu = {},
		clu_count = 0,
		clu_x = {},
		clu_y = {},
		cadj_off = {},
		cadj_to = {},
		cadj_cost = {},
		_cg = {},
		_ccame = {},
		_cseen = {},
		_cclosed = {},
		_cmark = {},
		_cstamp = 0,
		coast_off = {},
		coast_tiles = {},
		_g = {},
		_came = {},
		_seen = {},
		_closed = {},
		_stamp = 0,
		_hn = {},
		_hf = {},
		_hs = 0,
		_lpar = {},
		_lseen = {},
		_lstamp = 0,
		_reg_cache = {},
		_reg_n = 0,
		_route_cache = {},
		_route_n = 0,
		budget_n = 12,
		_spent = 0,
		searches = 0,
		expanded = 0,
		fails = 0,
		cache_hits = 0,
		deferred = 0,
		last_deferred = false,
	}
	local body = water_body
	local region = nv.region
	buffer.fill(region, 0, 255) -- -1 everywhere
	local cell_reg = nv.cell_reg
	local rn, rb, rt, rx, ry, rf = nv.reg_n, nv.reg_body, nv.reg_tile, nv.reg_x, nv.reg_y, nv.reg_full
	local co: { number } = { [0] = 0 }
	local ct: { number } = {}
	local ctn = 0
	local rc = 0
	local stack: { number } = {}
	local members: { number } = {}
	local function B(t: number): number
		return readi32(body, t * 4)
	end
	local function zeros_in_row(s: number, cw: number): number
		local c = 0
		for i = s, s + cw - 1 do
			if readi32(body, i * 4) == 0 then
				c += 1
			end
		end
		return c
	end
	-- 1. regions
	for cy = 0, CH - 1 do
		local y0 = cy * CELL
		local y1 = min(y0 + CELL, H) - 1
		for cx = 0, CW - 1 do
			local x0 = cx * CELL
			local x1 = min(x0 + CELL, W) - 1
			local cw = x1 - x0 + 1
			local land = 0
			for yy = y0, y1 do
				land += zeros_in_row(yy * W + x0, cw)
			end
			local c = cy * CW + cx
			local area = cw * (y1 - y0 + 1)
			if land == area then
				cell_reg[c] = C_LAND
				continue
			end
			if land == 0 then
				local mx = min(x0 + idiv(CELL, 2), x1)
				local my = min(y0 + idiv(CELL, 2), y1)
				rb[rc] = B(my * W + mx)
				rt[rc] = my * W + mx
				rx[rc] = f32((x0 + x1) * 0.5)
				ry[rc] = f32((y0 + y1) * 0.5)
				rf[rc] = if area == CELL * CELL then 1 else 0
				rn[rc] = area
				cell_reg[c] = rc
				-- land just outside the cell = this region's coast
				if y0 > 0 then
					local s0 = (y0 - 1) * W + x0
					if zeros_in_row(s0, cw) > 0 then
						for xx = x0, x1 do
							if B(s0 + xx - x0) == 0 then
								ct[ctn] = s0 + xx - x0
								ctn += 1
							end
						end
					end
				end
				if y1 < H - 1 then
					local s1 = (y1 + 1) * W + x0
					if zeros_in_row(s1, cw) > 0 then
						for xx = x0, x1 do
							if B(s1 + xx - x0) == 0 then
								ct[ctn] = s1 + xx - x0
								ctn += 1
							end
						end
					end
				end
				if x0 > 0 then
					for yy = y0, y1 do
						if B(yy * W + x0 - 1) == 0 then
							ct[ctn] = yy * W + x0 - 1
							ctn += 1
						end
					end
				end
				if x1 < W - 1 then
					for yy = y0, y1 do
						if B(yy * W + x1 + 1) == 0 then
							ct[ctn] = yy * W + x1 + 1
							ctn += 1
						end
					end
				end
				co[rc + 1] = ctn
				rc += 1
				continue
			end
			cell_reg[c] = C_MIXED
			for yy = y0, y1 do
				for xx = x0, x1 do
					local ts = yy * W + xx
					local b = B(ts)
					if b == 0 or readi32(region, ts * 4) ~= -1 then
						continue
					end
					local r = rc
					writei32(region, ts * 4, r)
					local sn = 1
					stack[0] = ts
					local mn = 0
					local fx, fy = 0.0, 0.0
					-- Dictionary cmark: insertion order kept in cml
					local cmark: { [number]: boolean } = {}
					local cml: { number } = {}
					while sn > 0 do
						sn -= 1
						local t = stack[sn]
						members[mn] = t
						mn += 1
						local tx = t % W
						local ty = idiv(t, W)
						fx += tx
						fy += ty
						if tx > 0 then
							local j = t - 1
							if B(j) == 0 then
								if not cmark[j] then
									cmark[j] = true
									table.insert(cml, j)
								end
							elseif tx > x0 and readi32(region, j * 4) == -1 then
								writei32(region, j * 4, r)
								stack[sn] = j
								sn += 1
							end
						end
						if tx < W - 1 then
							local j = t + 1
							if B(j) == 0 then
								if not cmark[j] then
									cmark[j] = true
									table.insert(cml, j)
								end
							elseif tx < x1 and readi32(region, j * 4) == -1 then
								writei32(region, j * 4, r)
								stack[sn] = j
								sn += 1
							end
						end
						if ty > 0 then
							local j = t - W
							if B(j) == 0 then
								if not cmark[j] then
									cmark[j] = true
									table.insert(cml, j)
								end
							elseif ty > y0 and readi32(region, j * 4) == -1 then
								writei32(region, j * 4, r)
								stack[sn] = j
								sn += 1
							end
						end
						if ty < H - 1 then
							local j = t + W
							if B(j) == 0 then
								if not cmark[j] then
									cmark[j] = true
									table.insert(cml, j)
								end
							elseif ty < y1 and readi32(region, j * 4) == -1 then
								writei32(region, j * 4, r)
								stack[sn] = j
								sn += 1
							end
						end
					end
					fx /= mn
					fy /= mn
					local best = members[0]
					local bd = 1e20
					for m = 0, mn - 1 do
						local t = members[m]
						local ddx = (t % W) - fx
						local ddy = idiv(t, W) - fy
						local dd = ddx * ddx + ddy * ddy
						if dd < bd then
							bd = dd
							best = t
						end
					end
					rb[rc] = b
					rt[rc] = best
					rx[rc] = f32(fx)
					ry[rc] = f32(fy)
					rf[rc] = 0
					rn[rc] = mn
					for _, k in cml do
						ct[ctn] = k
						ctn += 1
					end
					co[rc + 1] = ctn
					rc += 1
				end
			end
		end
	end
	nv.reg_count = rc
	nv.coast_off = co
	nv.coast_tiles = ct
	assert(rc < PAIR_K, "SimNav: too many regions")
	-- 2. edges: every region pair that touches (4-adjacent, or diagonal through a one-tile strait)
	-- samples: pair key, sample index (ne), tile a, tile b
	local ekey: { number } = {}
	local eta: { number } = {}
	local etb: { number } = {}
	local ne = 0
	local function add(a: number, b: number, ta: number, tb: number)
		if a > b then
			a, b = b, a
			ta, tb = tb, ta
		end
		ekey[ne] = a * PAIR_K + b
		eta[ne] = ta
		etb[ne] = tb
		ne += 1
	end
	local function rof(t: number): number
		return region_of(nv, t)
	end
	for cy = 0, CH - 1 do
		local y0 = cy * CELL
		local y1 = min(y0 + CELL, H) - 1
		for cx = 0, CW - 1 do
			local c = cy * CW + cx
			local cr = cell_reg[c]
			if cr == C_LAND then
				continue
			end
			local x0 = cx * CELL
			local x1 = min(x0 + CELL, W) - 1
			-- right neighbour
			if cx + 1 < CW then
				local rr = cell_reg[c + 1]
				if rr ~= C_LAND then
					if cr >= 0 and rr >= 0 then
						local tm = idiv(y0 + y1, 2) * W + x1
						add(cr, rr, tm, tm + 1)
					else
						for y = y0, y1 do
							local t = y * W + x1
							local a = rof(t)
							local e = t + 1
							if a >= 0 then
								local b2 = rof(e)
								if b2 >= 0 and b2 ~= a then
									add(a, b2, t, e)
								end
							end
							if y < y1 then
								-- t -> south-east (crosses the vertical edge)
								local se = e + W
								if a >= 0 then
									local b3 = rof(se)
									if b3 >= 0 and b3 ~= a and rof(e) < 0 and rof(t + W) < 0 then
										add(a, b3, t, se)
									end
								end
								-- e -> south-west
								local a2 = rof(e)
								if a2 >= 0 then
									local sw = t + W
									local b4 = rof(sw)
									if b4 >= 0 and b4 ~= a2 and a < 0 and rof(e + W) < 0 then
										add(a2, b4, e, sw)
									end
								end
							end
						end
					end
				end
			end
			-- lower neighbour (incl. both corners)
			if cy + 1 < CH then
				local dr = cell_reg[c + CW]
				if not (cr >= 0 and dr >= 0) then
					for x = x0, x1 do
						local t = y1 * W + x
						local a = rof(t)
						if a < 0 then
							continue
						end
						local s = t + W
						local bs = rof(s)
						if bs >= 0 and bs ~= a then
							add(a, bs, t, s)
						end
						if x < W - 1 and bs < 0 and rof(t + 1) < 0 then
							local b3 = rof(s + 1)
							if b3 >= 0 and b3 ~= a then
								add(a, b3, t, s + 1)
							end
						end
						if x > 0 and bs < 0 and rof(t - 1) < 0 then
							local b4 = rof(s - 1)
							if b4 >= 0 and b4 ~= a then
								add(a, b4, t, s - 1)
							end
						end
					end
				elseif dr ~= cr then
					local tm2 = y1 * W + idiv(x0 + x1, 2)
					add(cr, dr, tm2, tm2 + W)
				end
			end
			-- interior diagonals of a mixed cell
			if cr == C_MIXED then
				for y = y0, y1 - 1 do
					for x = x0, x1 do
						local t = y * W + x
						local a = region_at(nv, t)
						if a < 0 then
							continue
						end
						local s = t + W
						if region_at(nv, s) >= 0 then
							continue
						end
						if x < x1 and region_at(nv, t + 1) < 0 then
							local b3 = region_at(nv, s + 1)
							if b3 >= 0 and b3 ~= a then
								add(a, b3, t, s + 1)
							end
						end
						if x > x0 and region_at(nv, t - 1) < 0 then
							local b4 = region_at(nv, s - 1)
							if b4 >= 0 and b4 ~= a then
								add(a, b4, t, s - 1)
							end
						end
					end
				end
			end
		end
	end
	-- keys.sort(): by pair, then sample index
	local order: { number } = table.create(ne)
	for i = 0, ne - 1 do
		order[i + 1] = i
	end
	table.sort(order, function(p: number, q: number): boolean
		local kp, kq = ekey[p], ekey[q]
		if kp ~= kq then
			return kp < kq
		end
		return p < q
	end)
	-- 3. CSR adjacency, portal = middle sample of each pair
	local ga: { number } = {}
	local gb: { number } = {}
	local gpa: { number } = {}
	local gpb: { number } = {}
	local deg = zeros(rc + 1, 0)
	local i = 0
	while i < ne do
		local k = ekey[order[i + 1]]
		local j = i
		while j < ne and ekey[order[j + 1]] == k do
			j += 1
		end
		local mid = order[i + idiv(j - i, 2) + 1]
		local a = idiv(k, PAIR_K)
		local b = k % PAIR_K
		table.insert(ga, a)
		table.insert(gb, b)
		table.insert(gpa, eta[mid])
		table.insert(gpb, etb[mid])
		deg[a] += 1
		deg[b] += 1
		i = j
	end
	local adj_off = zeros(rc + 1, 0)
	local acc = 0
	for r = 0, rc - 1 do
		adj_off[r] = acc
		acc += deg[r]
	end
	adj_off[rc] = acc
	local adj_to = zeros(max(acc, 1), 0)
	local adj_cost = zeros(max(acc, 1), 0.0)
	local adj_pa = zeros(max(acc, 1), 0)
	local adj_pb = zeros(max(acc, 1), 0)
	local fill = zeros(rc + 1, 0)
	for q = 1, #ga do
		local a, b = ga[q], gb[q]
		local cost = len32(rx[a] - rx[b], ry[a] - ry[b])
		local ia = adj_off[a] + fill[a]
		fill[a] += 1
		adj_to[ia] = b
		adj_cost[ia] = cost
		adj_pa[ia] = gpa[q]
		adj_pb[ia] = gpb[q]
		local ib = adj_off[b] + fill[b]
		fill[b] += 1
		adj_to[ib] = a
		adj_cost[ib] = cost
		adj_pa[ib] = gpb[q]
		adj_pb[ib] = gpa[q]
	end
	nv.adj_off, nv.adj_to, nv.adj_cost, nv.adj_pa, nv.adj_pb = adj_off, adj_to, adj_cost, adj_pa, adj_pb
	_build_clusters(nv)
	local n1 = max(rc, 1)
	nv._g = zeros(n1, 0.0)
	nv._came = zeros(n1, 0)
	nv._seen = zeros(n1, 0)
	nv._closed = zeros(n1, 0)
	nv._stamp = 0
	nv._lpar = zeros(CELL * CELL, 0)
	nv._lseen = zeros(CELL * CELL, 0)
	nv._lstamp = 0
	nv.ready = true
	local id = next_id
	next_id += 1
	navs[id] = nv
	-- the gen cache keeps one previous map's nav: drop older ones
	for k in navs do
		if k < id - 2 then
			navs[k] = nil
		end
	end
	return id
end

function M.free(id: number): boolean
	navs[id] = nil
	return true
end

-- ------------------------------------------------------------------------------------------------ heap

local function _push(nv: Nav, n: number, f: number)
	local hn, hf = nv._hn, nv._hf
	local i = nv._hs
	nv._hs += 1
	while i > 0 do
		local p = (i - 1) // 2
		if hf[p] <= f then
			break
		end
		hn[i] = hn[p]
		hf[i] = hf[p]
		i = p
	end
	hn[i] = n
	hf[i] = f32(f)
end

local function _pop(nv: Nav): number
	local hn, hf = nv._hn, nv._hf
	local top = hn[0]
	nv._hs -= 1
	local size = nv._hs
	if size == 0 then
		return top
	end
	local ln, lf = hn[size], hf[size]
	local i = 0
	while true do
		local c = i * 2 + 1
		if c >= size then
			break
		end
		if c + 1 < size and hf[c + 1] < hf[c] then
			c += 1
		end
		if hf[c] >= lf then
			break
		end
		hn[i] = hn[c]
		hf[i] = hf[c]
		i = c
	end
	hn[i] = ln
	hf[i] = lf
	return top
end

-- ------------------------------------------------------------------------------------------------ queries

local function water_next_to(nv: Nav, t: number, wb: number): number
	local W, N = nv.W, nv.N
	local x = t % W
	local hw = x > 0
	local he = x < W - 1
	local cands: { number } = {}
	if hw then
		table.insert(cands, t - 1)
	end
	if he then
		table.insert(cands, t + 1)
	end
	if t >= W then
		table.insert(cands, t - W)
		if hw then
			table.insert(cands, t - W - 1)
		end
		if he then
			table.insert(cands, t - W + 1)
		end
	end
	if t < N - W then
		table.insert(cands, t + W)
		if hw then
			table.insert(cands, t + W - 1)
		end
		if he then
			table.insert(cands, t + W + 1)
		end
	end
	for _, c in cands do
		local b = body_at(nv, c)
		if b > 0 and (wb <= 0 or b == wb) then
			return c
		end
	end
	return -1
end

local function body_of(nv: Nav, t: number): number
	if t >= 0 and t < nv.N then
		return body_at(nv, t)
	end
	return 0
end

local function _cluster_path(nv: Nav, ca: number, cb: number): { number }
	nv._stamp += 1
	local st = nv._stamp
	nv._hs = 0
	local cg, ccame, cseen, cclosed = nv._cg, nv._ccame, nv._cseen, nv._cclosed
	cg[ca] = 0.0
	ccame[ca] = -1
	cseen[ca] = st
	local gx, gy = nv.clu_x[cb], nv.clu_y[cb]
	_push(nv, ca, 0.0)
	local found = false
	local cadj_off, cadj_to, cadj_cost, clu_x, clu_y = nv.cadj_off, nv.cadj_to, nv.cadj_cost, nv.clu_x, nv.clu_y
	while nv._hs > 0 do
		local c = _pop(nv)
		if cclosed[c] == st then
			continue
		end
		cclosed[c] = st
		if c == cb then
			found = true
			break
		end
		local gc = cg[c]
		for k = cadj_off[c], cadj_off[c + 1] - 1 do
			local n = cadj_to[k]
			if cclosed[n] == st then
				continue
			end
			local ng = gc + cadj_cost[k]
			if cseen[n] ~= st or ng < cg[n] then
				cseen[n] = st
				cg[n] = f32(ng)
				ccame[n] = c
				_push(nv, n, ng + len32(clu_x[n] - gx, clu_y[n] - gy) * HEURISTIC_W)
			end
		end
	end
	local out: { number } = {}
	if found then
		local c = cb
		while c ~= -1 do
			table.insert(out, c)
			c = ccame[c]
		end
	end
	return out
end

local function _astar_regions(nv: Nav, ra: number, rb: number, corridor: boolean): { number }
	local cs = nv._cstamp
	nv._stamp += 1
	local st = nv._stamp
	nv._hs = 0
	local g, came, seen, closed = nv._g, nv._came, nv._seen, nv._closed
	g[ra] = 0.0
	came[ra] = -1
	seen[ra] = st
	local reg_x, reg_y = nv.reg_x, nv.reg_y
	local gx, gy = reg_x[rb], reg_y[rb]
	_push(nv, ra, len32(reg_x[ra] - gx, reg_y[ra] - gy) * HEURISTIC_W)
	local found = false
	local ex = 0
	local adj_off, adj_to, adj_cost, cmark, reg_clu = nv.adj_off, nv.adj_to, nv.adj_cost, nv._cmark, nv.reg_clu
	while nv._hs > 0 do
		local r = _pop(nv)
		if closed[r] == st then
			continue
		end
		closed[r] = st
		ex += 1
		if r == rb then
			found = true
			break
		end
		local gr = g[r]
		for k = adj_off[r], adj_off[r + 1] - 1 do
			local n = adj_to[k]
			if closed[n] == st then
				continue
			end
			if corridor and cmark[reg_clu[n]] ~= cs then
				continue
			end
			local ng = gr + adj_cost[k]
			if seen[n] ~= st or ng < g[n] then
				seen[n] = st
				g[n] = f32(ng)
				came[n] = r
				_push(nv, n, ng + len32(reg_x[n] - gx, reg_y[n] - gy) * HEURISTIC_W)
			end
		end
	end
	nv.expanded += ex
	local out: { number } = {}
	if found then
		local c = rb
		while c ~= -1 do
			table.insert(out, c)
			c = came[c]
		end
		-- reverse
		local n = #out
		for k = 1, n // 2 do
			out[k], out[n + 1 - k] = out[n + 1 - k], out[k]
		end
	end
	return out
end

local function _region_path(nv: Nav, ra: number, rb: number): { number }
	local key = ra * PAIR_K + rb
	local hit = nv._reg_cache[key]
	if hit then
		return hit
	end
	local rhit = nv._reg_cache[rb * PAIR_K + ra]
	if rhit then
		local n = #rhit
		local rv = table.create(n)
		for k = 1, n do
			rv[k] = rhit[n + 1 - k]
		end
		return rv
	end
	nv.searches += 1
	local corridor = false
	if nv.clu_count > 0 and nv.reg_clu[ra] ~= nv.reg_clu[rb] then
		local cp = _cluster_path(nv, nv.reg_clu[ra], nv.reg_clu[rb])
		if #cp == 0 then
			if nv._reg_cache[key] == nil then
				nv._reg_n += 1
			end
			nv._reg_cache[key] = {}
			return {}
		end
		nv._cstamp += 1
		for _, c in cp do
			nv._cmark[c] = nv._cstamp
		end
		for _w = 1, CORRIDOR_WIDEN do
			local ring: { number } = {}
			for _, c in cp do
				for k = nv.cadj_off[c], nv.cadj_off[c + 1] - 1 do
					local n = nv.cadj_to[k]
					if nv._cmark[n] ~= nv._cstamp then
						table.insert(ring, n)
					end
				end
			end
			for _, n in ring do
				nv._cmark[n] = nv._cstamp
			end
			for _, n in ring do
				table.insert(cp, n)
			end
		end
		corridor = true
	end
	local res = _astar_regions(nv, ra, rb, corridor)
	if #res == 0 and corridor then
		res = _astar_regions(nv, ra, rb, false)
	end
	if nv._reg_n >= REG_CACHE_MAX then
		table.clear(nv._reg_cache)
		nv._reg_n = 0
	end
	if nv._reg_cache[key] == nil then
		nv._reg_n += 1
	end
	nv._reg_cache[key] = res
	return res
end

local function los_strict(nv: Nav, a: number, bt: number, b: number): boolean
	local W = nv.W
	local body = nv.body
	local x = a % W
	local y = idiv(a, W)
	local dx = bt % W - x
	local dy = idiv(bt, W) - y
	local nx, ny = abs(dx), abs(dy)
	local sx = if dx > 0 then 1 else -1
	local sy = if dy > 0 then 1 else -1
	local ix, iy = 0, 0
	while ix < nx or iy < ny do
		local dec = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
		if dec == 0 then
			if readi32(body, (y * W + x + sx) * 4) ~= b or readi32(body, ((y + sy) * W + x) * 4) ~= b then
				return false
			end
			x += sx
			y += sy
			ix += 1
			iy += 1
		elseif dec < 0 then
			x += sx
			ix += 1
		else
			y += sy
			iy += 1
		end
		if readi32(body, (y * W + x) * 4) ~= b then
			return false
		end
	end
	return true
end

-- the source's los() (kept for completeness; the port string-pulls with los_strict)
local function los(nv: Nav, a: number, bt: number, b: number): boolean
	local W = nv.W
	local x0, y0 = a % W, idiv(a, W)
	local x1, y1 = bt % W, idiv(bt, W)
	local dx, dy = x1 - x0, y1 - y0
	local sx = if dx > 0 then 1 else -1
	local sy = if dy > 0 then 1 else -1
	local ax, ay = abs(dx), abs(dy)
	local err = ax - ay
	local x, y = x0, y0
	local steps = ax + ay
	local k = 0
	while k < steps do
		local e2 = err * 2
		local nx, ny = x, y
		if e2 > -ay then
			err -= ay
			nx = x + sx
		end
		if e2 < ax then
			err += ax
			ny = y + sy
		end
		if nx ~= x and ny ~= y then
			if body_at(nv, y * W + nx) ~= b and body_at(nv, ny * W + x) ~= b then
				return false
			end
			k += 1
		end
		x, y = nx, ny
		if body_at(nv, y * W + x) ~= b then
			return false
		end
		k += 1
	end
	return true
end

local function raster(nv: Nav, a: number, bt: number, out: { number })
	local W = nv.W
	local x0, y0 = a % W, idiv(a, W)
	local x1, y1 = bt % W, idiv(bt, W)
	local dx, dy = x1 - x0, y1 - y0
	local sx = if dx > 0 then 1 else -1
	local sy = if dy > 0 then 1 else -1
	local ax, ay = abs(dx), abs(dy)
	local err = ax - ay
	local x, y = x0, y0
	while x ~= x1 or y ~= y1 do
		local e2 = err * 2
		if e2 > -ay then
			err -= ay
			x += sx
		end
		if e2 < ax then
			err += ax
			y += sy
		end
		table.insert(out, y * W + x)
	end
end

local function _portal(nv: Nav, r: number, r2: number): (number, number)
	for k = nv.adj_off[r], nv.adj_off[r + 1] - 1 do
		if nv.adj_to[k] == r2 then
			return nv.adj_pa[k], nv.adj_pb[k]
		end
	end
	return -1, -1
end

-- BFS inside region r from a to b; appends the tiles after a up to and including b.
local function _bfs_append(nv: Nav, a: number, b: number, r: number, out: { number }): boolean
	if a == b then
		return true
	end
	local W, H, CW = nv.W, nv.H, nv.CW
	if nv.reg_full[r] == 1 or nv.cell_reg[idiv(idiv(a, W), CELL) * CW + idiv(a % W, CELL)] >= 0 then
		raster(nv, a, b, out)
		return true
	end
	local x0 = idiv(a % W, CELL) * CELL
	local y0 = idiv(idiv(a, W), CELL) * CELL
	if idiv(b % W, CELL) * CELL ~= x0 or idiv(idiv(b, W), CELL) * CELL ~= y0 then
		table.insert(out, b) -- diagonal strait jump across a cell edge
		return region_of(nv, b) == r or region_of(nv, a) == r
	end
	nv._lstamp += 1
	local ls = nv._lstamp
	local lseen, lpar = nv._lseen, nv._lpar
	local q: { number } = { a }
	local la = (idiv(a, W) - y0) * CELL + (a % W) - x0
	lseen[la] = ls
	lpar[la] = -1
	local head = 1
	local found = false
	while head <= #q do
		local t = q[head]
		head += 1
		if t == b then
			found = true
			break
		end
		local x = t % W
		local y = idiv(t, W)
		for k = 0, 3 do
			local n = -1
			if k == 0 then
				if x == x0 or x == 0 then
					continue
				end
				n = t - 1
			elseif k == 1 then
				if x == x0 + CELL - 1 or x == W - 1 then
					continue
				end
				n = t + 1
			elseif k == 2 then
				if y == y0 or y == 0 then
					continue
				end
				n = t - W
			else
				if y == y0 + CELL - 1 or y == H - 1 then
					continue
				end
				n = t + W
			end
			if region_at(nv, n) ~= r then
				continue
			end
			local ln = (idiv(n, W) - y0) * CELL + (n % W) - x0
			if lseen[ln] == ls then
				continue
			end
			lseen[ln] = ls
			lpar[ln] = t
			table.insert(q, n)
		end
	end
	if not found then
		table.insert(out, b)
		return region_of(nv, b) == r or region_of(nv, a) == r
	end
	local seg: { number } = {}
	local c = b
	while c ~= a do
		table.insert(seg, c)
		c = lpar[(idiv(c, W) - y0) * CELL + (c % W) - x0]
	end
	for k = #seg, 1, -1 do
		table.insert(out, seg[k])
	end
	return true
end

local function _stitch(nv: Nav, src: number, dst: number, regs: { number }): { number }
	local raw: { number } = { src }
	local cur = src
	local nr = #regs
	for i = 1, nr - 1 do
		local px, py = _portal(nv, regs[i], regs[i + 1])
		if px < 0 then
			return {}
		end
		if px ~= cur and los_strict(nv, cur, px, body_at(nv, cur)) then
			table.insert(raw, px) -- sparse: smoothing only needs visible hops
		elseif not _bfs_append(nv, cur, px, regs[i], raw) then
			return {}
		end
		table.insert(raw, py)
		cur = py
	end
	if dst ~= cur and los_strict(nv, cur, dst, body_at(nv, cur)) then
		table.insert(raw, dst)
	elseif not _bfs_append(nv, cur, dst, regs[nr], raw) then
		return {}
	end
	return raw
end

-- String pulling: exponential probe + binary search for the farthest visible raw tile. Corner tiles only.
local function _smooth(nv: Nav, raw: { number }, b: number): { number }
	local n = #raw
	if n <= 2 then
		return raw
	end
	-- raw is 1-based here: raw[i + 1] is GDScript raw[i]
	local out: { number } = { raw[1] }
	local i = 0
	while i < n - 1 do
		local good = i + 1
		local stride = 2
		local bad = -1
		while true do
			local j = min(i + stride, n - 1)
			if los_strict(nv, raw[i + 1], raw[j + 1], b) then
				good = j
				if j == n - 1 or stride >= 256 then
					break
				end
				stride *= 2
			else
				bad = j
				break
			end
		end
		if bad > 0 then
			local lo, hi = good, bad
			while hi - lo > 1 do
				local mid = idiv(lo + hi, 2)
				if los_strict(nv, raw[i + 1], raw[mid + 1], b) then
					lo = mid
				else
					hi = mid
				end
			end
			good = lo
		end
		table.insert(out, raw[good + 1])
		i = good
	end
	return out
end

local function _cache_route(nv: Nav, key: number, r: { number })
	if nv._route_n >= ROUTE_CACHE_MAX then
		table.clear(nv._route_cache)
		nv._route_n = 0
	end
	if nv._route_cache[key] == nil then
		nv._route_n += 1
	end
	nv._route_cache[key] = r
end

local function find_route(nv: Nav, src: number, dst: number, urgent: boolean): { number }
	nv.last_deferred = false
	local N = nv.N
	if not nv.ready or src < 0 or dst < 0 or src >= N or dst >= N then
		return {}
	end
	local b = body_at(nv, src)
	if b == 0 or body_at(nv, dst) ~= b then
		return {}
	end
	local key = src * N + dst
	local hit = nv._route_cache[key]
	if hit then
		nv.cache_hits += 1
		return hit
	end
	if src == dst then
		return { src }
	end
	if los_strict(nv, src, dst, b) then
		local straight = { src, dst }
		_cache_route(nv, key, straight)
		return straight
	end
	if not urgent and nv._spent >= nv.budget_n then
		nv.deferred += 1
		nv.last_deferred = true
		return {}
	end
	local out: { number } = {}
	local ra, rb = region_of(nv, src), region_of(nv, dst)
	if ra >= 0 and rb >= 0 then
		local regs = _region_path(nv, ra, rb)
		if #regs > 0 then
			local raw = _stitch(nv, src, dst, regs)
			if #raw > 0 then
				out = _smooth(nv, raw, b)
			end
		end
	end
	nv._spent += 1
	if #out == 0 then
		nv.fails += 1
	end
	_cache_route(nv, key, out)
	return out
end

-- Nearest coastal land tile of owner `a` by sea from water tile `wd` (region BFS over wd's body).
local function nearest_own_coast(nv: Nav, owner: buffer, a: number, wd: number, max_tiles: number): (number, { number }?)
	local r0 = region_of(nv, wd)
	if r0 < 0 then
		return -1, nil
	end
	nv._stamp += 1
	local st = nv._stamp
	local seen, came = nv._seen, nv._came
	local q: { number } = { r0 }
	seen[r0] = st
	came[r0] = -1
	local head = 1
	local seen_tiles = 0
	local coast_off, coast_tiles, adj_off, adj_to, reg_n = nv.coast_off, nv.coast_tiles, nv.adj_off, nv.adj_to, nv.reg_n
	while head <= #q and seen_tiles < max_tiles do
		local r = q[head]
		head += 1
		seen_tiles += reg_n[r]
		for k = coast_off[r], coast_off[r + 1] - 1 do
			local c = coast_tiles[k]
			if readi32(owner, c * 4) == a then
				local regs: { number } = {}
				local x = r
				while x ~= -1 do
					table.insert(regs, x)
					x = came[x]
				end
				return c, regs
			end
		end
		for k = adj_off[r], adj_off[r + 1] - 1 do
			local n = adj_to[k]
			if seen[n] == st then
				continue
			end
			seen[n] = st
			came[n] = r
			table.insert(q, n)
		end
	end
	return -1, nil
end

local function _boat_route_body(nv: Nav, owner: buffer, a: number, wd: number, max_tiles: number): { number }
	local c, regs = nearest_own_coast(nv, owner, a, wd, max_tiles)
	if regs == nil then
		return {}
	end
	local W, N = nv.W, nv.N
	local b = body_at(nv, wd)
	local ws = -1
	local r0 = regs[1]
	local x = c % W
	for _, j in { if x > 0 then c - 1 else -1, if x < W - 1 then c + 1 else -1, c - W, c + W } do
		if j >= 0 and j < N and region_of(nv, j) == r0 then
			ws = j
			break
		end
	end
	if ws < 0 then
		ws = water_next_to(nv, c, b)
	end
	if ws < 0 then
		return {}
	end
	local key = ws * N + wd
	local hit = nv._route_cache[key]
	if hit then
		nv.cache_hits += 1
		return hit
	end
	local out: { number } = {}
	if los_strict(nv, ws, wd, b) then
		out = { ws, wd }
	else
		local raw = _stitch(nv, ws, wd, regs)
		if #raw > 0 then
			out = _smooth(nv, raw, b)
		end
	end
	_cache_route(nv, key, out)
	return out
end

local function boat_route(nv: Nav, owner: buffer, a: number, dest: number, max_tiles: number): { number }
	local W, N = nv.W, nv.N
	if not nv.ready or dest < 0 or dest >= N then
		return {}
	end
	local out: { number } = {}
	local tried: { [number]: boolean } = {}
	local x = dest % W
	for _, wd in { if x > 0 then dest - 1 else -1, if x < W - 1 then dest + 1 else -1, dest - W, dest + W } do
		if wd < 0 or wd >= N or body_at(nv, wd) == 0 or tried[body_at(nv, wd)] then
			continue
		end
		tried[body_at(nv, wd)] = true
		out = _boat_route_body(nv, owner, a, wd, max_tiles)
		if #out > 0 then
			break
		end
	end
	nv._spent += 1
	if #out == 0 then
		nv.fails += 1
	end
	return out
end

-- ------------------------------------------------------------------------------------------------ pixels
-- Points are float32 pairs (Godot PackedVector2Array); every Vector2 operation rounds through f32.

local function lerp32(ax: number, ay: number, bx: number, by: number, w: number): (number, number)
	-- Vector2::lerp: res = this + (to - this) * weight, all float32 (weight cast to float)
	local w32 = f32(w)
	return f32(ax + f32(f32(bx - ax) * w32)), f32(ay + f32(f32(by - ay) * w32))
end

local function dist32(ax: number, ay: number, bx: number, by: number): number
	-- Vector2::distance_to: Math::sqrt((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)) in float32
	local dx, dy = f32(ax - bx), f32(ay - by)
	return f32(sqrt(f32(f32(dx * dx) + f32(dy * dy))))
end

local function roundf(x: number): number
	-- Godot Math::round(float): ::round (half away from zero)
	if x >= 0 then
		return floor(x + 0.5)
	end
	return -floor(-x + 0.5)
end

local function seg_water(nv: Nav, p0x: number, p0y: number, p1x: number, p1y: number): boolean
	local W, H = nv.W, nv.H
	local n = floor(dist32(p0x, p0y, p1x, p1y) * 4.0) + 1
	for s = 0, n do
		local px, py = lerp32(p0x, p0y, p1x, p1y, s / n)
		local x = if px >= 0 then floor(px) else -floor(-px)
		local y = if py >= 0 then floor(py) else -floor(-py)
		if x < 0 or y < 0 or x >= W or y >= H then
			return false
		end
		if body_at(nv, y * W + x) ~= 0 then
			continue
		end
		-- absf(p.x - roundf(p.x)): p.x is float32, roundf of a float returns a float, the difference is
		-- GDScript float (f64)
		local ex = abs(px - roundf(px)) < 1e-4
		local ey = abs(py - roundf(py)) < 1e-4
		if not ex and not ey then
			return false
		end
		local ok = false
		local xs = if ex then { x - 1, x } else { x }
		local ys = if ey then { y - 1, y } else { y }
		for _, yy in ys do
			for _, xx in xs do
				if xx >= 0 and yy >= 0 and xx < W and yy < H and body_at(nv, yy * W + xx) ~= 0 then
					ok = true
				end
			end
		end
		if not ok then
			return false
		end
	end
	return true
end

-- corners -> pixel polyline (x, y pairs), Chaikin-rounded where the cut stays on water
local function to_points(nv: Nav, corners: { number }, end_tile: number, ts: number, rounds: number): { number }
	local W = nv.W
	local px: { number } = {}
	local py: { number } = {}
	for _, t in corners do
		table.insert(px, f32(t % W + 0.5))
		table.insert(py, f32(idiv(t, W) + 0.5))
	end
	if end_tile >= 0 then
		table.insert(px, f32(end_tile % W + 0.5))
		table.insert(py, f32(idiv(end_tile, W) + 0.5))
	end
	local last = #px - (if end_tile >= 0 then 1 else 0) -- the landing leg is not rounded
	for _it = 1, rounds do
		if last < 3 then
			break
		end
		-- 1-based: pts[m] (GDScript, 0-based) is px[m + 1]
		local nx: { number } = { px[1] }
		local ny: { number } = { py[1] }
		for m = 1, last - 2 do
			local ax, ay = px[m], py[m]
			local qx, qy = px[m + 1], py[m + 1]
			local cx, cy = px[m + 2], py[m + 2]
			local q1x, q1y = lerp32(qx, qy, ax, ay, 0.25)
			local q2x, q2y = lerp32(qx, qy, cx, cy, 0.25)
			if seg_water(nv, q1x, q1y, q2x, q2y) then
				table.insert(nx, q1x)
				table.insert(ny, q1y)
				table.insert(nx, q2x)
				table.insert(ny, q2y)
			else
				table.insert(nx, qx)
				table.insert(ny, qy)
			end
		end
		for m = last - 1, #px - 1 do
			table.insert(nx, px[m + 1])
			table.insert(ny, py[m + 1])
		end
		local nlast = #nx - (if end_tile >= 0 then 1 else 0)
		local ok = true
		for m = 1, nlast - 1 do
			if not seg_water(nv, nx[m], ny[m], nx[m + 1], ny[m + 1]) then
				ok = false
				break
			end
		end
		if not ok then
			break -- keep the previous (valid) polyline
		end
		last = nlast
		px, py = nx, ny
	end
	local out: { number } = table.create(#px * 2)
	local ts32 = f32(ts)
	for m = 1, #px do
		out[2 * m - 1] = f32(px[m] * ts32)
		out[2 * m] = f32(py[m] * ts32)
	end
	return out
end

local function water_path_px(nv: Nav, from_tile: number, to_tile: number, ts: number, urgent: boolean): { number }
	local wa = if body_of(nv, from_tile) == 0 then water_next_to(nv, from_tile, 0) else from_tile
	if wa < 0 then
		return {}
	end
	local wb = if body_of(nv, to_tile) == 0 then water_next_to(nv, to_tile, body_at(nv, wa)) else to_tile
	if wb < 0 then
		return {}
	end
	local r = find_route(nv, wa, wb, urgent)
	if #r == 0 then
		return {}
	end
	return to_points(nv, r, if body_of(nv, to_tile) == 0 then to_tile else -1, ts, 2)
end

-- ------------------------------------------------------------------------------------------------ calls

local function ibuf(t: { number }): buffer
	local b = buffer.create(#t * 4)
	for i, v in t do
		writei32(b, (i - 1) * 4, v)
	end
	return b
end

local function fbuf(t: { number }): buffer
	local b = buffer.create(#t * 4)
	for i, v in t do
		writef32(b, (i - 1) * 4, v)
	end
	return b
end

local function nav(id: number): Nav
	local nv = navs[id]
	assert(nv ~= nil, "SimNav: no nav " .. tostring(id))
	return nv
end
M.nav = nav

-- a new sim tick: the search budget starts over (budget = SimNav.budget_n, which tests change)
function M.begin_tick(id: number, budget: number?): boolean
	local nv = nav(id)
	nv._spent = 0
	if budget ~= nil then
		nv.budget_n = budget
	end
	return true
end

-- counters, for the GDScript facade's stats
function M.stats(id: number): any
	local nv = nav(id)
	return { searches = nv.searches, expanded = nv.expanded, fails = nv.fails, cache_hits = nv.cache_hits,
		deferred = nv.deferred, spent = nv._spent }
end

function M.set_budget(id: number, n: number): boolean
	nav(id).budget_n = n
	return true
end

-- -> { r = i32 corners, d = last_deferred }
function M.find_route(id: number, src: number, dst: number, urgent: boolean): any
	local nv = nav(id)
	local r = find_route(nv, src, dst, urgent)
	return { r = ibuf(r), d = nv.last_deferred }
end

-- owner: i32 owner map, or nil for SimState's
function M.boat_route(id: number, owner: buffer?, a: number, dest: number, max_tiles: number): buffer
	local om = owner or (SimState.cur :: any).owner
	return ibuf(boat_route(nav(id), om, a, dest, max_tiles))
end

function M.to_points(id: number, corners: buffer, end_tile: number, ts: number, rounds: number): buffer
	local c: { number } = {}
	for k = 0, buffer.len(corners) - 4, 4 do
		table.insert(c, readi32(corners, k))
	end
	return fbuf(to_points(nav(id), c, end_tile, ts, rounds))
end

-- -> { p = f32 x, y pairs, d = last_deferred }
function M.water_path_px(id: number, from_tile: number, to_tile: number, ts: number, urgent: boolean): any
	local nv = nav(id)
	-- last_deferred is only set by find_route (an early return keeps the previous call's flag, as in GDScript)
	local p = water_path_px(nv, from_tile, to_tile, ts, urgent)
	return { p = fbuf(p), d = nv.last_deferred }
end

-- for Core/SimNaval (trade routes): the polyline as a 1-based x, y table, and the deferral flag
function M.water_path_px_t(id: number, from_tile: number, to_tile: number, ts: number, urgent: boolean): ({ number }, boolean)
	local nv = nav(id)
	local p = water_path_px(nv, from_tile, to_tile, ts, urgent)
	return p, nv.last_deferred
end

-- for Core/SimWarships (sim/nav.gd steer): the corners as a 1-based table, nothing copied
function M.find_route_t(id: number, src: number, dst: number, urgent: boolean): { number }
	return find_route(nav(id), src, dst, urgent)
end

function M.water_next_to(id: number, t: number, wb: number): number
	return water_next_to(nav(id), t, wb)
end

function M.region_of(id: number, t: number): number
	return region_of(nav(id), t)
end

-- graph arrays, for the tests: { reg_count, clu_count, reg (i32 body, tile, n, full), regxy (f32), adj (i32
-- off..., then to, pa, pb), cost (f32), coast (i32 off..., tiles) }
function M.dump(id: number): any
	local nv = nav(id)
	local rc = nv.reg_count
	local reg: { number } = {}
	local regxy: { number } = {}
	for r = 0, rc - 1 do
		table.insert(reg, nv.reg_body[r])
		table.insert(reg, nv.reg_tile[r])
		table.insert(reg, nv.reg_n[r])
		table.insert(reg, nv.reg_full[r])
		table.insert(regxy, nv.reg_x[r])
		table.insert(regxy, nv.reg_y[r])
	end
	local adj: { number } = {}
	for r = 0, rc do
		table.insert(adj, nv.adj_off[r])
	end
	local acc = nv.adj_off[rc]
	local cost: { number } = {}
	for k = 0, acc - 1 do
		table.insert(adj, nv.adj_to[k])
		table.insert(adj, nv.adj_pa[k])
		table.insert(adj, nv.adj_pb[k])
		table.insert(cost, nv.adj_cost[k])
	end
	local coast: { number } = {}
	for r = 0, rc do
		table.insert(coast, nv.coast_off[r])
	end
	for k = 0, nv.coast_off[rc] - 1 do
		table.insert(coast, nv.coast_tiles[k])
	end
	local clu: { number } = {}
	for r = 0, rc - 1 do
		table.insert(clu, nv.reg_clu[r])
	end
	for c = 0, nv.clu_count do
		table.insert(clu, nv.cadj_off[c] or 0)
	end
	return {
		reg_count = rc,
		clu_count = nv.clu_count,
		reg = ibuf(reg),
		regxy = fbuf(regxy),
		adj = ibuf(adj),
		cost = fbuf(cost),
		coast = ibuf(coast),
		clu = ibuf(clu),
		spent = nv._spent,
		searches = nv.searches,
		fails = nv.fails,
	}
end

M._los = los
return M
