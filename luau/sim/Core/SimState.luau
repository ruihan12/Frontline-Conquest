--!strict
-- SimState: the match's world state as Luau owns it (docs/LUAU_PORT.md, Steps 4 and 5).
--
-- Tile layer (Step 4):
--   owner    buffer, i32 per tile (row-major, W * H): -2 ice, -1 water, 0 neutral, > 0 nation id
--   fallout  buffer, u8 per tile: 1 = fallout (left by a nuke, until the tile is owned again)
--   mtn      buffer, u8 per tile: terrain class 0 plains, 1 hills, 2 mountains (constant per map)
-- Per nation, kept by set_owner exactly as game/map.gd _set_owner keeps them (Step 5):
--   land, bb (Rect2i as x, y, w, h), last_by, and the border sets: border[o] = the tiles of o with a land
--   4-neighbour of another owner, in the insertion order of the GDScript Dictionary (erase then insert moves a
--   tile to the end, setting a present tile keeps its place). One doubly linked list per nation, threaded
--   through per-tile buffers (a tile is only ever in its owner's set).
-- Per nation, sent by GDScript before each Luau call (the AI and the economy still change them in GDScript):
--   troops, gold, alive, kind, team, left; and the diplomacy / defence inputs (allies, traitors, defence posts).
--
-- While the sim is half ported, both sides write tiles. GDScript keeps its own arrays (owner_map, fallout, the
-- border dicts; the renderer, the HUD, the AI and net/rep.gd read those) and records every change it makes;
-- push() replays them here through the same set_owner, in order. Luau modules write with set_owner /
-- set_fallout / ev(), which append to one ordered output stream; sim/luau_link.gd applies it after the call
-- (owners through the game's _set_owner, so GDScript's borders end in the same order as these lists).
local SimState = {}
SimState.__index = SimState

local readi32, writei32 = buffer.readi32, buffer.writei32
local readu8, writeu8 = buffer.readu8, buffer.writeu8
local readf64, writef64 = buffer.readf64, buffer.writef64

export type State = any

SimState.cur = (nil :: any) :: State?

-- events in the output stream (kind codes; sim/luau_link.gd applies them in stream order)
SimState.EV_VIEWER_ATTACK = 1 -- (actor, target)           g._viewer_event({type = "attack", ...}, [target])
SimState.EV_HOSTILE = 2 -- (victim, attacker, tick, expiry) attacked_tick = tick, grudge_<attacker> = max(., expiry)
SimState.EV_CONQUEST = 3 -- (victim, by, gold)             annex: gold moves, _on_conquest, last_by / killer = by

local function ensure_nat(st: State, n: number)
	local cur = st.nat_n
	if n <= cur then
		return
	end
	for id = cur, n - 1 do
		st.land[id] = 0
		st.bbx[id] = 0
		st.bby[id] = 0
		st.bbw[id] = 0
		st.bbh[id] = 0
		st.last_by[id] = 0
		st.bhead[id] = -1
		st.btail[id] = -1
		st.bcnt[id] = 0
		st.troops[id] = 0.0
		st.gold[id] = 0.0
		st.alive[id] = false
		st.kind[id] = 2
		st.team[id] = 0
		st.left[id] = false
	end
	st.nat_n = n
end

function SimState.new(W: number, H: number, owner: buffer, fallout: buffer, mtn: buffer?): State
	local n = W * H
	assert(buffer.len(owner) == n * 4, "owner buffer size")
	assert(buffer.len(fallout) == n, "fallout buffer size")
	local bown = buffer.create(n * 4)
	buffer.fill(bown, 0, 0xFF) -- -1: in no border set
	local self = setmetatable({
		W = W,
		H = H,
		n = n,
		owner = owner,
		fallout = fallout,
		mtn = if mtn and buffer.len(mtn) == n then mtn else buffer.create(n),
		bown = bown,
		bnext = buffer.create(n * 4),
		bprev = buffer.create(n * 4),
		nat_n = 0,
		land = {},
		bbx = {},
		bby = {},
		bbw = {},
		bbh = {},
		last_by = {},
		bhead = {},
		btail = {},
		bcnt = {},
		troops = {},
		gold = {},
		alive = {},
		kind = {},
		team = {},
		left = {},
		t_dirty = {},
		t_list = {},
		team_mode = false,
		allies = {},
		traitor = {},
		def_posts = {},
		fallout_count = 0,
		land_total = 0,
		anomalies = 0,
		out = {},
		evs = {},
	}, SimState)
	return self
end

-- ---- border sets (Godot Dictionary order)
local function bset(st: State, o: number, t: number)
	local bown = st.bown
	local bo = readi32(bown, t * 4)
	if bo == o then
		return
	end
	if bo >= 0 then
		-- a tile in another nation's set: never happens through set_owner (counted; tests check it stays 0)
		st.anomalies += 1
		return
	end
	writei32(bown, t * 4, o)
	local tail = st.btail[o]
	writei32(st.bprev, t * 4, tail)
	writei32(st.bnext, t * 4, -1)
	if tail >= 0 then
		writei32(st.bnext, tail * 4, t)
	else
		st.bhead[o] = t
	end
	st.btail[o] = t
	st.bcnt[o] += 1
end

local function berase(st: State, o: number, t: number)
	local bown = st.bown
	if readi32(bown, t * 4) ~= o then
		return
	end
	local p = readi32(st.bprev, t * 4)
	local nx = readi32(st.bnext, t * 4)
	if p >= 0 then
		writei32(st.bnext, p * 4, nx)
	else
		st.bhead[o] = nx
	end
	if nx >= 0 then
		writei32(st.bprev, nx * 4, p)
	else
		st.btail[o] = p
	end
	writei32(bown, t * 4, -1)
	st.bcnt[o] -= 1
end

-- map.gd _upd_border_fast
local function upd_border(st: State, t: number, om: buffer, W: number, last_row: number)
	local o = readi32(om, t * 4)
	if o <= 0 then
		return
	end
	local x = t % W
	local b = false
	local u
	if x > 0 then
		u = readi32(om, (t - 1) * 4)
		if u ~= o and u >= 0 then
			b = true
		end
	end
	if not b and x < W - 1 then
		u = readi32(om, (t + 1) * 4)
		if u ~= o and u >= 0 then
			b = true
		end
	end
	if not b and t >= W then
		u = readi32(om, (t - W) * 4)
		if u ~= o and u >= 0 then
			b = true
		end
	end
	if not b and t < last_row then
		u = readi32(om, (t + W) * 4)
		if u ~= o and u >= 0 then
			b = true
		end
	end
	if b then
		bset(st, o, t)
	else
		berase(st, o, t)
	end
end

-- map.gd _set_owner without the parts only GDScript needs (pop, structures, net, repaint): owner, land, last_by,
-- fallout clear, bounding box, borders, in the same order.
local function core_set_owner(st: State, i: number, o: number)
	local om = st.owner
	local W = st.W
	local old = readi32(om, i * 4)
	local x = i % W
	local y = i // W
	if old > 0 then
		berase(st, old, i)
		st.land[old] -= 1
	end
	writei32(om, i * 4, o)
	if old > 0 and o > 0 then
		st.last_by[old] = o
	end
	if o > 0 and readu8(st.fallout, i) == 1 then
		writeu8(st.fallout, i, 0)
	end
	if o > 0 then
		st.land[o] += 1
		local bw, bh = st.bbw[o], st.bbh[o]
		if bw == 0 and bh == 0 then
			st.bbx[o] = x
			st.bby[o] = y
			st.bbw[o] = 1
			st.bbh[o] = 1
		else
			local bx, by = st.bbx[o], st.bby[o]
			if x < bx or y < by or x >= bx + bw or y >= by + bh then
				-- Rect2i.merge(Rect2i(x, y, 1, 1))
				local nx = if x < bx then x else bx
				local ny = if y < by then y else by
				local ex = if x + 1 > bx + bw then x + 1 else bx + bw
				local ey = if y + 1 > by + bh then y + 1 else by + bh
				st.bbx[o] = nx
				st.bby[o] = ny
				st.bbw[o] = ex - nx
				st.bbh[o] = ey - ny
			end
		end
	end
	local lr = W * (st.H - 1)
	upd_border(st, i, om, W, lr)
	if o >= 0 then
		local t, p
		if x > 0 then
			t = i - 1
			p = readi32(om, t * 4)
			if p > 0 then
				if p ~= o then
					bset(st, p, t)
				else
					upd_border(st, t, om, W, lr)
				end
			end
		end
		if x < W - 1 then
			t = i + 1
			p = readi32(om, t * 4)
			if p > 0 then
				if p ~= o then
					bset(st, p, t)
				else
					upd_border(st, t, om, W, lr)
				end
			end
		end
		if i >= W then
			t = i - W
			p = readi32(om, t * 4)
			if p > 0 then
				if p ~= o then
					bset(st, p, t)
				else
					upd_border(st, t, om, W, lr)
				end
			end
		end
		if i < lr then
			t = i + W
			p = readi32(om, t * 4)
			if p > 0 then
				if p ~= o then
					bset(st, p, t)
				else
					upd_border(st, t, om, W, lr)
				end
			end
		end
	else
		if x > 0 then
			upd_border(st, i - 1, om, W, lr)
		end
		if x < W - 1 then
			upd_border(st, i + 1, om, W, lr)
		end
		if i >= W then
			upd_border(st, i - W, om, W, lr)
		end
		if i < lr then
			upd_border(st, i + W, om, W, lr)
		end
	end
end

-- ---- reads / writes for Luau modules (tile ids are 0-based like GDScript)
function SimState.get_owner(self: State, i: number): number
	return readi32(self.owner, i * 4)
end

function SimState.set_owner(self: State, i: number, o: number)
	core_set_owner(self, i, o)
	local q = self.out
	q[#q + 1] = i
	q[#q + 1] = o
end

function SimState.get_fallout(self: State, i: number): number
	return readu8(self.fallout, i)
end

function SimState.set_fallout(self: State, i: number, v: number)
	writeu8(self.fallout, i, v)
	local q = self.out
	q[#q + 1] = -2 - i
	q[#q + 1] = v
end

-- an event for GDScript, in stream order (kind, then up to four numbers)
function SimState.ev(self: State, kind: number, a: number, b: number, c: number, d: number)
	local e = self.evs
	local k = #e
	e[k + 1] = kind
	e[k + 2] = a
	e[k + 3] = b
	e[k + 4] = c
	e[k + 5] = d
	local q = self.out
	q[#q + 1] = -1
	q[#q + 1] = k // 5
end

function SimState.set_troops(self: State, id: number, v: number)
	self.troops[id] = v
	if not self.t_dirty[id] then
		self.t_dirty[id] = true
		self.t_list[#self.t_list + 1] = id
	end
end

-- border set of o in Godot order (tests; modules walk bhead / bnext directly)
function SimState.border_list(self: State, o: number): { number }
	local out = {}
	if o < 0 or o >= self.nat_n then
		return out
	end
	local t = self.bhead[o]
	local nx = self.bnext
	while t >= 0 do
		out[#out + 1] = t
		t = readi32(nx, t * 4)
	end
	return out
end

-- diplomacy.gd allied / same_team
function SimState.allied(self: State, a: number, b: number): boolean
	if a <= 0 or b <= 0 then
		return false
	end
	if self.team_mode and a ~= b and a < self.nat_n and b < self.nat_n then
		local t = self.team[a]
		if t ~= 0 and t == self.team[b] and not self.left[a] and not self.left[b] then
			return true
		end
	end
	local lo, hi = a, b
	if b < a then
		lo, hi = b, a
	end
	return self.allies[lo * 4096 + hi] == true
end

function SimState.is_traitor(self: State, id: number, tick: number): boolean
	local u = self.traitor[id]
	return (if u == nil then -1 else u) > tick
end

-- economy.gd defended
function SimState.defended(self: State, i: number, o: number, range: number): boolean
	if o <= 0 then
		return false
	end
	local arr = self.def_posts[o]
	if arr == nil then
		return false
	end
	local W = self.W
	local x = i % W
	local y = i // W
	local r2 = range * range
	for k = 1, #arr do
		local t = arr[k]
		local dx = t % W - x
		local dy = t // W - y
		if dx * dx + dy * dy <= r2 then
			return true
		end
	end
	return false
end

-- ---- the GDScript side (sim/luau_link.gd)

local function i32s(b: buffer): { number }
	local out = table.create(buffer.len(b) // 4)
	for k = 0, buffer.len(b) - 4, 4 do
		out[#out + 1] = readi32(b, k)
	end
	return out
end

-- A new map (or the link's first sync): copies of the tile layer, the terrain, and per nation the land count,
-- bounding box (x, y, w, h), last_by and the border set in Dictionary order (flat: count, tiles..., per id).
function SimState.begin(W: number, H: number, owner: buffer, fallout: buffer, mtn: buffer, nat_n: number,
	land: buffer, bb: buffer, last_by: buffer, borders: buffer): boolean
	local st = SimState.new(W, H, owner, fallout, mtn)
	ensure_nat(st, nat_n)
	for id = 0, nat_n - 1 do
		st.land[id] = readi32(land, id * 4)
		st.bbx[id] = readi32(bb, id * 16)
		st.bby[id] = readi32(bb, id * 16 + 4)
		st.bbw[id] = readi32(bb, id * 16 + 8)
		st.bbh[id] = readi32(bb, id * 16 + 12)
		st.last_by[id] = readi32(last_by, id * 4)
	end
	local k = 0
	local nb = buffer.len(borders)
	for id = 0, nat_n - 1 do
		if k >= nb then
			break
		end
		local c = readi32(borders, k)
		k += 4
		for _ = 1, c do
			bset(st, id, readi32(borders, k))
			k += 4
		end
	end
	SimState.cur = st
	return true
end

-- in_owner / in_fall: (tile i32, value i32) pairs GDScript wrote since the last push, in order; nat_n: nations.size().
function SimState.push(in_owner: buffer, in_fall: buffer, nat_n: number?): boolean
	local st = SimState.cur
	assert(st, "SimState.push before begin")
	if nat_n then
		ensure_nat(st, nat_n)
	end
	for k = 0, buffer.len(in_owner) - 8, 8 do
		local i = readi32(in_owner, k)
		local o = readi32(in_owner, k + 4)
		if o >= st.nat_n then
			ensure_nat(st, o + 1)
		end
		core_set_owner(st, i, o)
	end
	local fb = st.fallout
	for k = 0, buffer.len(in_fall) - 8, 8 do
		writeu8(fb, readi32(in_fall, k), readi32(in_fall, k + 4))
	end
	return true
end

-- Per-call nation values: nat = f64 triples (id, troops, alive 0/1) for the nations the call may touch.
function SimState.nat_some(st: State, nat: buffer)
	for k = 0, buffer.len(nat) - 24, 24 do
		local id = readf64(nat, k)
		if id >= st.nat_n then
			ensure_nat(st, id + 1)
		end
		st.troops[id] = readf64(nat, k + 8)
		st.alive[id] = readf64(nat, k + 16) ~= 0
	end
end

-- Everything a whole pass reads (sent at each attacks slice): per nation troops / gold (f64), alive (u8), kind
-- (i32), team (i32) and left (u8) in a team game; the alliance keys (i32, min * 4096 + max), traitors (i32 pairs
-- id, until), finished defence posts (i32 flat: owner, count, tiles...), fallout and land counts.
function SimState.nat_all(st: State, n: number, troops: buffer, gold: buffer, alive: buffer, kind: buffer,
	team_mode: boolean, team: buffer, left: buffer, allies: buffer, traitor: buffer, defs: buffer,
	fallout_count: number, land_total: number)
	ensure_nat(st, n)
	local T, G, A, K = st.troops, st.gold, st.alive, st.kind
	for id = 0, n - 1 do
		T[id] = readf64(troops, id * 8)
		G[id] = readf64(gold, id * 8)
		A[id] = readu8(alive, id) ~= 0
		K[id] = readi32(kind, id * 4)
	end
	st.team_mode = team_mode
	if team_mode then
		for id = 0, n - 1 do
			st.team[id] = readi32(team, id * 4)
			st.left[id] = readu8(left, id) ~= 0
		end
	end
	local al = {}
	for k = 0, buffer.len(allies) - 4, 4 do
		al[readi32(allies, k)] = true
	end
	st.allies = al
	local tr = {}
	for k = 0, buffer.len(traitor) - 8, 8 do
		tr[readi32(traitor, k)] = readi32(traitor, k + 4)
	end
	st.traitor = tr
	local dp = {}
	local k = 0
	local nd = buffer.len(defs)
	while k < nd do
		local o = readi32(defs, k)
		local c = readi32(defs, k + 4)
		k += 8
		local arr = table.create(c)
		for j = 1, c do
			arr[j] = readi32(defs, k)
			k += 4
		end
		dp[o] = arr
	end
	st.def_posts = dp
	st.fallout_count = fallout_count
	st.land_total = land_total
end

local function pairs_buf(q: { number }): buffer
	local b = buffer.create(#q * 4)
	for k = 1, #q do
		writei32(b, (k - 1) * 4, q[k])
	end
	return b
end

local function f64_buf(q: { number }): buffer
	local b = buffer.create(#q * 8)
	for k = 1, #q do
		writef64(b, (k - 1) * 8, q[k])
	end
	return b
end

-- What Luau modules did since the last take: { ops = i32 pairs in order (tile >= 0: owner; -1: event index;
-- <= -2: fallout of tile -2 - code), evs = f64 records of 5 (kind, a, b, c, d), troops = f64 pairs (id, troops)
-- of nations whose troops changed }. Modules add their own fields to `into`.
function SimState.take(into: { [string]: any }?): any
	local st = SimState.cur
	assert(st, "SimState.take before begin")
	local out = into or {}
	out.ops = pairs_buf(st.out)
	out.evs = f64_buf(st.evs)
	local tq = {}
	for _, id in st.t_list do
		tq[#tq + 1] = id
		tq[#tq + 1] = st.troops[id]
	end
	out.troops = f64_buf(tq)
	table.clear(st.out)
	table.clear(st.evs)
	table.clear(st.t_list)
	table.clear(st.t_dirty)
	return out
end

-- copies of the whole layer (tests)
function SimState.owner_bytes(): buffer
	local st = SimState.cur
	assert(st, "no state")
	local b = buffer.create(buffer.len(st.owner))
	buffer.copy(b, 0, st.owner)
	return b
end

function SimState.fallout_bytes(): buffer
	local st = SimState.cur
	assert(st, "no state")
	local b = buffer.create(buffer.len(st.fallout))
	buffer.copy(b, 0, st.fallout)
	return b
end

-- per nation land, bb and border sets as flat i32: (land, bbx, bby, bbw, bbh, last_by, count, tiles...) per id
-- (tests compare it with GDScript's dicts)
function SimState.nations_bytes(): buffer
	local st = SimState.cur
	assert(st, "no state")
	local q = {}
	for id = 0, st.nat_n - 1 do
		q[#q + 1] = st.land[id]
		q[#q + 1] = st.bbx[id]
		q[#q + 1] = st.bby[id]
		q[#q + 1] = st.bbw[id]
		q[#q + 1] = st.bbh[id]
		q[#q + 1] = st.last_by[id]
		local l = SimState.border_list(st, id)
		q[#q + 1] = #l
		for _, t in l do
			q[#q + 1] = t
		end
	end
	return pairs_buf(q)
end

function SimState.anomaly_count(): number
	local st = SimState.cur
	return if st then st.anomalies else -1
end

SimState._i32s = i32s

return SimState
