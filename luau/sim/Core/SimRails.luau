--!strict
-- SimRails: station links, rail paths, factory train spawns, train legs and train gold (docs/LUAU_PORT.md,
-- Step 5b2). Transliterated line for line from this project's sim/rails.gd (SimRails), which ports upstream
-- RoWorld SimStructures.rail_path / _link_nearby / factories_tick / _spawn_truck / _truck_tick (AGPL-3.0,
-- lukechatton/roworld).
--
-- Luau owns the rail caches (geometry per station pair, links per station, the link web per owner) and the trains.
-- GDScript keeps mirrors the renderer reads (game.rail_cache, game._rail_nb_cache, game.trains with the same keys in
-- the same order) and builds them from what each call returns. The structures stay GDScript's (game.structs): every
-- call gets a snapshot in list order (SNAP f64 each: id, k, tile, o, level, bt, trucks, last_spawn; NaN = no key),
-- where id = tile + serial * 2^24 names a structure Dictionary across calls (the serial changes when a different
-- Dictionary stands on the tile). A structure GDScript dropped keeps its last fields here, like the Dictionary the
-- GDScript caches and trains still hold. Writes to structures (trucks, last_spawn) come back as records.
--
-- Differences from the GDScript (all in cases the seeded matches never reach; LUAU_PORT.md, Step 5b2):
--   `st_b in list` / Array.erase compare Dictionaries by content in GDScript; here a structure (or a train) is the
--   same only when it is the same Dictionary (same id).
local Rules = require("./Rules")
local SimState = require("./SimState")
local SimAttacks = require("./SimAttacks")
local SimArsenal = require("./SimArsenal")
local GodotRng = require("./GodotRng")

local readf64, writef64 = buffer.readf64, buffer.writef64
local readi32, writei32 = buffer.readi32, buffer.writei32
local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs
local f32 = GodotRng.f32
local godot_sort = SimArsenal.godot_sort

local function maxf(a: number, b: number): number
	return if a > b then a else b
end
local function mini(a: number, b: number): number
	return if a < b then a else b
end
local function maxi(a: number, b: number): number
	return if a > b then a else b
end
local function signi(x: number): number
	return if x > 0 then 1 elseif x < 0 then -1 else 0
end
local function idiv(a: number, b: number): number
	-- GDScript int division (all operands here are >= 0)
	return a // b
end
local function nan(x: number): boolean
	return x ~= x
end

local M = {}

M.SNAP = 8
local SNAP = M.SNAP
M.TR_IN = 5 -- f64 per kept train sent in (tid, leg, t, dur, stops)
M.TR_OUT = 5 -- f64 per train sent back (same)
local ID_MUL = 16777216

-- game/state.gd RAIL_KINDS: city, port, factory
local function is_rail_kind(k: number): boolean
	return k == 0 or k == 1 or k == 2
end

local R = Rules.new(1.0)
local rng = GodotRng.new(0, true)

-- module state (reset with a new map)
local S = {
	recs = {} :: { [number]: any }, -- id -> structure record
	rail = {} :: { [number]: any }, -- lo * 2^24 + hi -> { tiles, cum } or false (no path)
	rail_n = 0,
	nb = {} :: { [number]: any }, -- tile -> { ver, elapsed, list }
	nb_n = 0,
	mst = {} :: { [number]: any }, -- owner -> { ver, adj (tile -> list) }
	trains = {} :: { any },
	by_tid = {} :: { [number]: any },
	next_tid = 1,
}

-- per call
local C = {
	W = 0,
	H = 0,
	owner = (nil :: any) :: buffer,
	tick = 0,
	elapsed = 0.0,
	allies_n = 0,
	emb_n = 0,
	bfs_left = 0,
	calc_left = 0,
	frame = 0,
	pending = false,
	player = 1,
	hq = false, -- hostile() was asked (sim/naval.gd builds its per-tick cache on the first ask)
	own_sv = {} :: { [number]: number },
	hp = {} :: { [number]: boolean },
	structs = {} :: { any }, -- game.structs order
	at = {} :: { [number]: any }, -- tile -> live record (game.struct_at)
	new_rc = {} :: { number }, -- rail keys set this call, in order
	new_nb = {} :: { any }, -- { tile, o } set this call, in order
	new_tr = {} :: { any },
	pays = {} :: { number },
	wrote = {} :: { any },
}

function M.reset(): boolean
	S.recs = {}
	S.rail = {}
	S.rail_n = 0
	S.nb = {}
	S.nb_n = 0
	S.mst = {}
	S.trains = {}
	S.by_tid = {}
	S.next_tid = 1
	return true
end

local function alive(o: number): boolean
	return SimState.cur.alive[o] == true
end

-- sim/naval.gd hostile: a live attack either way (is_embargoed is always false: game/diplomacy.gd)
local function hostile(a: number, b: number): boolean
	C.hq = true
	return C.hp[a * 65536 + b] == true
end

local function allied(a: number, b: number): boolean
	return SimState.allied(SimState.cur, a, b)
end

local function own_sv(o: number): number
	return C.own_sv[o] or 0
end

local function trucks_of(r: any): number
	return r.trucks or 0
end

local function set_trucks(r: any, v: number)
	r.trucks = v
	if not r.w then
		r.w = true
		C.wrote[#C.wrote + 1] = r
	end
end

local function set_last_spawn(r: any, v: number)
	r.ls = v
	if not r.w then
		r.w = true
		C.wrote[#C.wrote + 1] = r
	end
end

-- ---------------------------------------------------------------- snapshot

local function read_recs(snap: buffer, live: boolean)
	local recs = S.recs
	local list = C.structs
	local at = C.at
	for b = 0, buffer.len(snap) - SNAP * 8, SNAP * 8 do
		local id = readf64(snap, b)
		local r = recs[id]
		if r == nil then
			r = { id = id }
			recs[id] = r
		end
		r.k = readf64(snap, b + 8)
		r.tile = readf64(snap, b + 16)
		r.o = readf64(snap, b + 24)
		local lv = readf64(snap, b + 32)
		r.level = if nan(lv) then 1 else lv
		local bt = readf64(snap, b + 40)
		r.bt = if nan(bt) then 0.0 else bt
		local tr = readf64(snap, b + 48)
		r.trucks = if nan(tr) then nil else tr
		local ls = readf64(snap, b + 56)
		r.ls = if nan(ls) then nil else ls
		r.w = false
		if live then
			list[#list + 1] = r
			at[r.tile] = r
		end
	end
end

-- ---------------------------------------------------------------- rail paths

-- Upstream SimStructures.rail_path, land only: A* on a minimap (RAIL_MINIMAP = 2 below k_lin 1.5), heuristic
-- weight 2, turn penalty 3, nodes that cannot lie on a path shorter than RAIL_MAX_PATH are never searched,
-- the newest of equal priorities comes out first. The path (from -> to, 4-connected) is scaled back up.
local function rail_astar(from_t: number, to_t: number): { number }
	local W, H = C.W, C.H
	local owner = C.owner
	local f = if R.k_lin < 1.5 then 2 else 1
	local mw = idiv(W + f - 1, f)
	local mh = idiv(H + f - 1, f)
	local start = idiv(idiv(from_t, W), f) * mw + idiv(from_t % W, f)
	local goal = idiv(idiv(to_t, W), f) * mw + idiv(to_t % W, f)
	local sx, sy = start % mw, idiv(start, mw)
	local gx, gy = goal % mw, idiv(goal, mw)
	local limit = ceil(Rules.rail_max_path(R) / f) + 2
	local out: { number } = {}
	if abs(sx - gx) + abs(sy - gy) > limit then
		return out
	end
	local hw = 2
	local tpen = 3
	-- binary heap, 0-based: priority, sequence, node
	local hp: { number } = {}
	local hq: { number } = {}
	local hn: { number } = {}
	local hsize = 0
	local seq = 0
	local gs: { [number]: number } = { [start] = 0 }
	local parent: { [number]: number } = { [start] = -1 }
	local closed: { [number]: boolean } = {}
	hp[0] = hw * (abs(sx - gx) + abs(sy - gy))
	hq[0] = 0
	hn[0] = start
	hsize = 1
	local expanded = 0
	local found = false
	local nbs = { 0, 0, 0, 0 }
	while hsize > 0 do
		local node = hn[0]
		local last = hsize - 1
		local lp, lq, ln = hp[last], hq[last], hn[last]
		hsize = last
		if last > 0 then
			local i = 0
			while true do
				local c = i * 2 + 1
				if c >= last then
					break
				end
				if c + 1 < last and (hp[c + 1] < hp[c] or (hp[c + 1] == hp[c] and hq[c + 1] > hq[c])) then
					c += 1
				end
				if lp < hp[c] or (lp == hp[c] and lq > hq[c]) then
					break
				end
				hp[i] = hp[c]
				hq[i] = hq[c]
				hn[i] = hn[c]
				i = c
			end
			hp[i] = lp
			hq[i] = lq
			hn[i] = ln
		end
		if closed[node] then
			continue
		end
		closed[node] = true
		if node == goal then
			found = true
			break
		end
		expanded += 1
		if expanded > 60000 then
			break
		end
		local x, y = node % mw, idiv(node, mw)
		local prev = parent[node]
		local gn = gs[node]
		local nn = 0
		if y > 0 then
			nn += 1
			nbs[nn] = node - mw
		end
		if y < mh - 1 then
			nn += 1
			nbs[nn] = node + mw
		end
		if x > 0 then
			nn += 1
			nbs[nn] = node - 1
		end
		if x < mw - 1 then
			nn += 1
			nbs[nn] = node + 1
		end
		for k = 1, nn do
			local m = nbs[k]
			if closed[m] then
				continue
			end
			local mx, my = m % mw, idiv(m, mw)
			if m ~= goal and readi32(owner, (my * f * W + mx * f) * 4) < 0 then
				continue -- water
			end
			local hg = abs(mx - gx) + abs(my - gy)
			if abs(mx - sx) + abs(my - sy) + hg > limit then
				continue
			end
			local c = 1
			if prev >= 0 and node - prev ~= m - node then
				c += tpen
			end
			local ng = gn + c
			local og = gs[m]
			if og == nil or ng < og then
				gs[m] = ng
				parent[m] = node
				seq += 1
				local pri = ng + hw * hg
				local j = hsize
				hsize += 1
				while j > 0 do
					local pp = idiv(j - 1, 2)
					if hp[pp] < pri or (hp[pp] == pri and hq[pp] > seq) then
						break
					end
					hp[j] = hp[pp]
					hq[j] = hq[pp]
					hn[j] = hn[pp]
					j = pp
				end
				hp[j] = pri
				hq[j] = seq
				hn[j] = m
			end
		end
	end
	if not found then
		return out
	end
	local mini_path: { number } = {}
	local cur = goal
	while cur >= 0 do
		mini_path[#mini_path + 1] = cur
		cur = parent[cur]
	end
	-- scale up to full tiles, 4-connected (from first, to last)
	local px, py = from_t % W, idiv(from_t, W)
	out[1] = from_t
	for q = #mini_path, 1, -1 do
		local mnode = mini_path[q]
		local tx = (mnode % mw) * f
		local ty = idiv(mnode, mw) * f
		if mnode == goal then
			tx = to_t % W
			ty = idiv(to_t, W)
		end
		while px ~= tx do
			px += signi(tx - px)
			out[#out + 1] = py * W + px
		end
		while py ~= ty do
			py += signi(ty - py)
			out[#out + 1] = py * W + px
		end
	end
	return out
end

-- Vector2.distance_to between two tile centres (real_t is float: the sum and the root in float)
local function tdist(a: number, b: number): number
	local W = C.W
	local dx = (a % W) - (b % W)
	local dy = idiv(a, W) - idiv(b, W)
	return f32(sqrt(f32(f32(dx * dx) + f32(dy * dy))))
end

-- returns the cache entry ({ tiles, cum }) or nil (no path / over this tick's budget)
local function rail_curve(tile_a: number, tile_b: number): any
	local W = C.W
	local lo_t = mini(tile_a, tile_b)
	local hi_t = maxi(tile_a, tile_b)
	local key = lo_t * ID_MUL + hi_t
	local ce = S.rail[key]
	if ce ~= nil then
		return if ce == false then nil else ce
	end
	if C.bfs_left <= 0 then
		C.pending = true
		return nil
	end
	C.bfs_left -= 1
	local raw = rail_astar(lo_t, hi_t)
	local max_path = Rules.rail_max_path(R)
	local function put(v: any)
		S.rail[key] = v
		S.rail_n += 1
		C.new_rc[#C.new_rc + 1] = key
	end
	if #raw < 2 or #raw >= max_path then
		put(false)
		return nil
	end
	-- pts as tiles: equal points are equal tiles, collinear on x / y is the same column / row
	local pts: { number } = {}
	for _, t in raw do
		local n = #pts
		if n >= 1 and pts[n] == t then
			continue
		end
		if n >= 2 then
			local u, w = pts[n - 1], pts[n]
			if ((u % W) == (w % W) and (w % W) == (t % W)) or (idiv(u, W) == idiv(w, W) and idiv(w, W) == idiv(t, W)) then
				pts[n] = t
				continue
			end
		end
		pts[n + 1] = t
	end
	if #pts < 2 then
		put(false)
		return nil
	end
	local cum: { number } = { 0.0 }
	for m = 2, #pts do
		cum[m] = f32(cum[m - 1] + tdist(pts[m], pts[m - 1]))
	end
	local res = { tiles = pts, cum = cum }
	put(res)
	return res
end

local rail_neighbors_calc: (st: any) -> { any }

local function rail_neighbors(st: any): { any }
	if not is_rail_kind(st.k) or st.bt > 0.0 then
		return {}
	end
	-- per-owner cache: one nation building something no longer invalidates everyone's rail web
	local ver = string.format("%d|%d|%d|%d", st.o, own_sv(st.o), C.allies_n, C.emb_n)
	local ce = S.nb[st.tile]
	if ce ~= nil and ce[1] == ver and C.elapsed - ce[2] < 6.0 then
		return ce[3]
	end
	if C.calc_left <= 0 and ce ~= nil then
		return ce[3] -- over this tick's budget: reuse the stale list
	end
	C.calc_left -= 1
	C.pending = false
	local r = rail_neighbors_calc(st)
	if not C.pending then
		if S.nb[st.tile] == nil then
			S.nb_n += 1
		end
		S.nb[st.tile] = { ver, C.elapsed, r }
		C.new_nb[#C.new_nb + 1] = { st.tile, st.o }
	end
	return r
end

local function rail_warm()
	for _, st in C.structs do
		if is_rail_kind(st.k) and st.bt <= 0.0 then
			rail_neighbors(st)
		end
	end
end

local function rail_hops(from: any, to: any, max_d: number, adj: { [number]: { any } }): number
	if from == to or from.tile == to.tile then
		return 0
	end
	local seen: { [number]: boolean } = { [from.tile] = true }
	local frontier: { number } = { from.tile }
	for d = 1, max_d do
		local nxt: { number } = {}
		for _, t in frontier do
			local l = adj[t]
			if l == nil then
				continue
			end
			for _, nb in l do
				if nb.tile == to.tile then
					return d
				end
				if not seen[nb.tile] then
					seen[nb.tile] = true
					nxt[#nxt + 1] = nb.tile
				end
			end
		end
		if #nxt == 0 then
			break
		end
		frontier = nxt
	end
	return -1
end

-- Port of SimStructures._link_nearby (Rules.luau trainStationMin/MaxRange, RAIL_LINK_HOPS):
-- link stations 15..110 full-size tiles apart, nearest first, when they are not already within
-- 4 hops and a 4-neighbour land path shorter than railroadMaxSize exists. No Kruskal MST.
local function build_rail_mst(o: number): { [number]: { any } }
	local W = C.W
	local nodes: { any } = {}
	local facs: { number } = {} -- factory tiles (their centres)
	local rmax = Rules.road_max_tiles(R)
	local rmin = Rules.road_min_tiles(R)
	for _, c in C.structs do
		if c.o ~= o or c.bt > 0.0 then
			continue
		end
		if c.k == 2 then
			facs[#facs + 1] = c.tile
		end
		if is_rail_kind(c.k) then
			nodes[#nodes + 1] = c
		end
	end
	local adj: { [number]: { any } } = {}
	if #facs == 0 or #nodes < 2 then
		return adj
	end
	local R2 = rmax * rmax
	local cov: { boolean } = {} -- the coverage list is only ever tested for emptiness
	for i, nd in nodes do
		local px, py = nd.tile % W, idiv(nd.tile, W)
		local any = false
		for _, ft in facs do
			-- Vector2.distance_squared_to in float
			local dx = (ft % W) - px
			local dy = idiv(ft, W) - py
			if f32(f32(dx * dx) + f32(dy * dy)) <= R2 then
				any = true
				break
			end
		end
		if nd.k == 2 then
			any = true
		end
		cov[i] = any
	end
	local edges: { [number]: any } = {}
	local ne = 0
	for i = 1, #nodes do
		if not cov[i] then
			continue
		end
		for j = i + 1, #nodes do
			if not cov[j] then
				continue
			end
			local d = tdist(nodes[i].tile, nodes[j].tile)
			if d <= rmin or d > rmax then
				continue
			end
			edges[ne] = { d, i, j }
			ne += 1
		end
	end
	godot_sort(edges, ne, function(x: any, y: any): boolean
		return x[1] < y[1]
	end)
	for q = 0, ne - 1 do
		local e = edges[q]
		local a, b = nodes[e[2]], nodes[e[3]]
		if rail_hops(a, b, Rules.RAIL_LINK_HOPS, adj) ~= -1 then
			continue
		end
		if rail_curve(a.tile, b.tile) == nil then
			continue
		end
		if adj[a.tile] == nil then
			adj[a.tile] = {}
		end
		if adj[b.tile] == nil then
			adj[b.tile] = {}
		end
		table.insert(adj[a.tile], b)
		table.insert(adj[b.tile], a)
	end
	return adj
end

local function adj_empty(adj: { [number]: any }): boolean
	return next(adj) == nil
end

rail_neighbors_calc = function(st: any): { any }
	local ver = string.format("%d|%d|%d", st.o, own_sv(st.o), floor(C.elapsed / 6.0))
	-- an unfinished web (route searches ran out of this frame's budget) is kept for the rest of the frame only,
	-- so the next frame carries on, instead of every station rebuilding the whole web again and again
	local pver = ver .. string.format("|f%d", C.frame)
	local ce = S.mst[st.o]
	if ce == nil or (ce[1] ~= ver and ce[1] ~= pver) then
		local adj = build_rail_mst(st.o)
		if adj_empty(adj) and C.pending and ce ~= nil then
			adj = ce[2]
		end
		ce = { if C.pending then pver else ver, adj }
		S.mst[st.o] = ce
	end
	local l = ce[2][st.tile]
	return if l == nil then {} else l
end

local function contains(list: { any }, x: any): boolean
	for _, v in list do
		if v == x then
			return true
		end
	end
	return false
end

local function has_rail_link(st_a: any, st_b: any): boolean
	if st_a == nil or st_b == nil or st_a == st_b then
		return false
	end
	if C.at[st_a.tile] ~= st_a or C.at[st_b.tile] ~= st_b then
		return false
	end
	if contains(rail_neighbors(st_a), st_b) then
		return true
	end
	if contains(rail_neighbors(st_b), st_a) then
		return true
	end
	return false
end

local function rail_len(st_a: any, st_b: any): number
	local rc = rail_curve(st_a.tile, st_b.tile)
	if rc == nil then
		return 20.0
	end
	local cum = rc.cum
	return maxf(1.0, cum[#cum])
end

-- Port of SimStructures.factories_tick / _spawn_truck / _truck_tick (RoWorld): each finished factory
-- rolls `level` times per tick against trainSpawnRate(owner's factory levels, train units world-wide),
-- at most one train per 10 ticks and 6 in flight per factory; the train runs the station route (over
-- the station network) to a random reachable city or port, paying trainGold at every city/port stop.
local function rail_route(a: any, b: any): { any }
	local par: { [number]: any } = { [a.tile] = false }
	local q: { any } = { a }
	local qi = 1
	while qi <= #q do
		local cur = q[qi]
		qi += 1
		if cur == b then
			break
		end
		for _, nb in rail_neighbors(cur) do
			if par[nb.tile] == nil then
				par[nb.tile] = cur
				q[#q + 1] = nb
			end
		end
	end
	if par[b.tile] == nil then
		return {}
	end
	local rev: { any } = { b }
	local c = par[b.tile]
	while c ~= false do
		rev[#rev + 1] = c
		c = par[c.tile]
	end
	local route: { any } = {}
	for k = #rev, 1, -1 do
		route[#route + 1] = rev[k]
	end
	return route
end

local function rail_dests(f: any): { any }
	local seen: { [number]: boolean } = { [f.tile] = true }
	local q: { any } = { f }
	local qi = 1
	local out: { any } = {}
	while qi <= #q do
		local cur = q[qi]
		qi += 1
		if cur ~= f and (cur.k == 0 or cur.k == 1) and (cur.o == f.o or not hostile(cur.o, f.o)) then
			out[#out + 1] = cur
		end
		for _, nb in rail_neighbors(cur) do
			if not seen[nb.tile] then
				seen[nb.tile] = true
				q[#q + 1] = nb
			end
		end
	end
	return out
end

local function train_leg_ticks(a: any, b: any): number
	return maxf(1.0, rail_len(a, b) * R.k_lin / Rules.TRAIN_SPEED_FULL)
end

local function spawn_train_from(f: any): boolean
	local dests = rail_dests(f)
	if #dests == 0 then
		return false
	end
	local pick = dests[(rng:randi() % #dests) + 1]
	local route = rail_route(f, pick)
	if #route <= 1 then
		return false
	end
	local tr = {
		tid = S.next_tid,
		o = f.o,
		fac = f,
		route = route,
		leg = 0,
		src = route[1],
		dst = route[2],
		t = 0.0,
		dur = train_leg_ticks(route[1], route[2]),
		stops = 0,
		lvl = f.level,
	}
	S.next_tid += 1
	S.trains[#S.trains + 1] = tr
	S.by_tid[tr.tid] = tr
	C.new_tr[#C.new_tr + 1] = tr
	set_trucks(f, trucks_of(f) + 1)
	return true
end

local function train_done(tr: any)
	local idx = table.find(S.trains, tr)
	if idx ~= nil then
		table.remove(S.trains, idx)
	end
	S.by_tid[tr.tid] = nil
	local f = tr.fac
	if f ~= nil then
		set_trucks(f, maxi(0, trucks_of(f) - 1))
	end
end

local function trains_tick()
	local tick = C.tick
	if tick % 10 == 0 then
		rail_warm()
	end
	local units_w = #S.trains * Rules.TRAIN_UNITS
	local fac_lv: { [number]: number } = {}
	for _, st in C.structs do
		if st.k == 2 then
			fac_lv[st.o] = (fac_lv[st.o] or 0) + st.level
		end
	end
	for _, f in C.structs do
		if f.k ~= 2 or f.bt > 0.0 or not alive(f.o) then
			continue
		end
		if trucks_of(f) >= Rules.TRUCKS_PER_FACTORY then
			continue
		end
		if tick < (f.ls or -1000) + Rules.TRAIN_COOLDOWN_TICKS then
			continue
		end
		local rate = Rules.train_spawn_rate(fac_lv[f.o] or 0, units_w)
		local go = false
		for _l = 1, mini(f.level, 1000) do
			if rng:randi() % rate == 0 then
				go = true
				break
			end
		end
		if go and spawn_train_from(f) then
			set_last_spawn(f, tick)
		end
	end
	local dup = table.clone(S.trains)
	for _, tr in dup do
		if not has_rail_link(tr.src, tr.dst) or not alive(tr.o) then
			train_done(tr)
			continue
		end
		tr.t += 1.0
		if tr.t < tr.dur then
			continue
		end
		local s = tr.dst
		if C.at[s.tile] ~= s or (s.o ~= tr.o and hostile(s.o, tr.o)) then
			train_done(tr)
			continue
		end
		if s.k == 0 or s.k == 1 then
			local rel = if s.o == tr.o then "self" elseif allied(tr.o, s.o) then "ally" else "other"
			local pay = Rules.train_gold(rel, tr.stops)
			-- o, other (-1: none), tile, pay, 1 = a float for the player
			local q = C.pays
			q[#q + 1] = tr.o
			q[#q + 1] = if s.o ~= tr.o and alive(s.o) then s.o else -1
			q[#q + 1] = s.tile
			q[#q + 1] = pay
			q[#q + 1] = if tr.o == C.player or s.o == C.player then 1 else 0
			tr.stops += 1
		end
		local route = tr.route
		tr.leg += 1
		if tr.leg >= #route - 1 then
			train_done(tr)
			continue
		end
		tr.src = route[tr.leg + 1]
		tr.dst = route[tr.leg + 2]
		tr.t = 0.0
		tr.dur = train_leg_ticks(tr.src, tr.dst)
	end
end

-- ---------------------------------------------------------------- calls

function M.world(n: number, troops: buffer, gold: buffer, alive_b: buffer, kind: buffer, team_mode: boolean,
	team: buffer, left: buffer, allies: buffer, traitor: buffer, defs: buffer, fallout_count: number,
	land_total: number): boolean
	SimState.nat_all(SimState.cur, n, troops, gold, alive_b, kind, team_mode, team, left, allies, traitor, defs,
		fallout_count, land_total)
	return true
end

-- Step 5g2: SimState.nat_lite's arguments (alive, kind, teams, alliances) for a call that reads only those.
function M.world_lite(n: number, alive: buffer, kind: buffer, team_mode: boolean, team: buffer, left: buffer,
	allies: buffer): boolean
	SimState.nat_lite(SimState.cur, n, alive, kind, team_mode, team, left, allies)
	return true
end

local function f64_buf(q: { number }): buffer
	local b = buffer.create(#q * 8)
	for k = 1, #q do
		writef64(b, (k - 1) * 8, q[k])
	end
	return b
end

local function begin_call(rhi: number, rlo: number, hdr: buffer, rf: buffer, snap: buffer, gone: buffer, trn: buffer,
	osv: buffer, hpb: buffer)
	rng.shi = rhi
	rng.slo = rlo
	local st = SimState.cur
	C.W = st.W
	C.H = st.H
	C.owner = st.owner
	C.tick = readf64(hdr, 0)
	C.elapsed = readf64(hdr, 8)
	C.allies_n = readf64(hdr, 16)
	C.emb_n = readf64(hdr, 24)
	C.bfs_left = readf64(hdr, 32)
	C.calc_left = readf64(hdr, 40)
	C.frame = readf64(hdr, 48)
	C.pending = readf64(hdr, 56) ~= 0
	C.player = readf64(hdr, 64)
	C.hq = false
	if readf64(hdr, 72) ~= 0 then -- GDScript emptied game.rail_cache
		S.rail = {}
		S.rail_n = 0
	end
	if readf64(hdr, 80) ~= 0 then -- GDScript emptied game._rail_nb_cache
		S.nb = {}
		S.nb_n = 0
	end
	for i, name in SimAttacks.RULE_FIELDS do
		(R :: any)[name] = readf64(rf, (i - 1) * 8)
	end
	table.clear(C.structs)
	table.clear(C.at)
	table.clear(C.new_rc)
	table.clear(C.new_nb)
	table.clear(C.new_tr)
	table.clear(C.pays)
	table.clear(C.wrote)
	table.clear(C.own_sv)
	for k = 0, buffer.len(osv) - 8, 8 do
		C.own_sv[readi32(osv, k)] = readi32(osv, k + 4)
	end
	table.clear(C.hp)
	for k = 0, buffer.len(hpb) - 4, 4 do
		C.hp[readi32(hpb, k)] = true
	end
	read_recs(gone, false)
	read_recs(snap, true)
	-- the trains still in game.trains, in its order, with the fields GDScript may have written
	local kept: { any } = {}
	local by: { [number]: any } = {}
	for b = 0, buffer.len(trn) - M.TR_IN * 8, M.TR_IN * 8 do
		local tr = S.by_tid[readf64(trn, b)]
		if tr ~= nil then
			tr.leg = readf64(trn, b + 8)
			tr.t = readf64(trn, b + 16)
			tr.dur = readf64(trn, b + 24)
			tr.stops = readf64(trn, b + 32)
			tr.src = tr.route[tr.leg + 1]
			tr.dst = tr.route[tr.leg + 2]
			kept[#kept + 1] = tr
			by[tr.tid] = tr
		end
	end
	S.trains = kept
	S.by_tid = by
end

local function finish(ret: any): any
	local out: { [string]: any } = { rhi = rng.shi, rlo = rng.slo, ret = ret }
	out.bfs_left = C.bfs_left
	out.calc_left = C.calc_left
	out.pending = C.pending
	out.hq = C.hq
	-- new rail entries: lo, hi, n, tiles... (n = 0: no path)
	local q: { number } = {}
	for _, key in C.new_rc do
		local e = S.rail[key]
		q[#q + 1] = key // ID_MUL
		q[#q + 1] = key % ID_MUL
		if e == false or e == nil then
			q[#q + 1] = 0
		else
			q[#q + 1] = #e.tiles
			for _, t in e.tiles do
				q[#q + 1] = t
			end
		end
	end
	out.rc = f64_buf(q)
	-- new station links: tile, o, n, ids...
	q = {}
	for _, e in C.new_nb do
		local ce = S.nb[e[1]]
		q[#q + 1] = e[1]
		q[#q + 1] = e[2]
		local l = ce[3]
		q[#q + 1] = #l
		for _, r in l do
			q[#q + 1] = r.id
		end
	end
	out.nb = f64_buf(q)
	-- structure writes: id, trucks (NaN = not written), last_spawn (NaN = not written)
	q = {}
	for _, r in C.wrote do
		q[#q + 1] = r.id
		q[#q + 1] = if r.trucks == nil then 0 / 0 else r.trucks
		q[#q + 1] = if r.ls == nil then 0 / 0 else r.ls
		r.w = false
	end
	out.sw = f64_buf(q)
	-- new trains: tid, o, fac id, lvl, n, route ids...
	q = {}
	for _, tr in C.new_tr do
		q[#q + 1] = tr.tid
		q[#q + 1] = tr.o
		q[#q + 1] = tr.fac.id
		q[#q + 1] = tr.lvl
		q[#q + 1] = #tr.route
		for _, r in tr.route do
			q[#q + 1] = r.id
		end
	end
	out.ntr = f64_buf(q)
	-- the trains now, in order: tid, leg, t, dur, stops
	q = {}
	for _, tr in S.trains do
		q[#q + 1] = tr.tid
		q[#q + 1] = tr.leg
		q[#q + 1] = tr.t
		q[#q + 1] = tr.dur
		q[#q + 1] = tr.stops
	end
	out.trs = f64_buf(q)
	out.pay = f64_buf(C.pays)
	return out
end

local function ids_buf(list: { any }): buffer
	local q: { number } = {}
	for _, r in list do
		q[#q + 1] = r.id
	end
	return f64_buf(q)
end

-- One entry for every call from sim/rails.gd: op, the sim rng (two uint32 halves), hdr (f64: tick, elapsed,
-- allies.size(), embargoes.size(), the route / link budgets left, the rail frame, rail pending, PLAYER, rail
-- cache emptied, link cache emptied), the rules fields (SimAttacks.RULE_FIELDS order), the structure snapshot,
-- the last fields of structures GDScript dropped since the last call, the trains still in game.trains,
-- _own_sv (i32 pairs), the hostile pairs (i32 a * 65536 + b), then the op's arguments (structure ids / tiles).
function M.call(op: string, rhi: number, rlo: number, hdr: buffer, rf: buffer, snap: buffer, gone: buffer,
	trn: buffer, osv: buffer, hpb: buffer, a1: any, a2: any): any
	begin_call(rhi, rlo, hdr, rf, snap, gone, trn, osv, hpb)
	if op == "tick" then
		trains_tick()
		return finish(true)
	elseif op == "curve" then
		-- tile a, tile b: true when the pair has a path (game.rail_cache holds it)
		return finish(rail_curve(a1, a2) ~= nil)
	elseif op == "neighbors" then
		local r = S.recs[a1]
		return finish(ids_buf(if r == nil then {} else rail_neighbors(r)))
	elseif op == "link" then
		local a, b = S.recs[a1], S.recs[a2]
		if a == nil or b == nil then
			return finish(false)
		end
		return finish(has_rail_link(a, b))
	elseif op == "spawn" then
		local f = S.recs[a1]
		return finish(f ~= nil and spawn_train_from(f))
	end
	error("SimRails.call: unknown op " .. tostring(op))
end

-- tests: what Luau holds (cache sizes, trains)
function M.debug(): any
	local mst_n = 0
	for _ in S.mst do
		mst_n += 1
	end
	return { rail = S.rail_n, nb = S.nb_n, mst = mst_n, trains = #S.trains }
end

return M
