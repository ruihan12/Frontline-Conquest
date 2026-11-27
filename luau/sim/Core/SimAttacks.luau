--!strict
-- SimAttacks: land attacks (docs/LUAU_PORT.md, Step 5). Transliterated line for line from this project's
-- sim/attacks.gd, which ports upstream RoWorld src/shared/Core/SimAttacks.luau (AGPL-3.0, lukechatton/roworld):
-- one attack per (attacker, target) pair; each tick it spends a budget of 1.0 "tick fractions" taking queued
-- front tiles in priority order; a defender under ANNEX_BELOW_FULL_TILES is annexed outright.
--
-- Luau owns the attacks. GDScript keeps a mirror of each attack as a Dictionary (game.attacks, the fields the
-- AI, the HUD, net/rep.gd and the tests read) which sim/attacks.gd updates from what every call returns:
--   atk   = f64 records (REC fields) of the attacks the call changed, ended ones included
--   order = i32 attack ids in list order, when the list changed (nil otherwise)
--   rng   = { hi, lo } the sim rng's state after the call (the attack pass shares g.rng with the AI)
--   ret   = the call's result
-- plus SimState.take() (owner changes, events, troops).
--
-- Kept: the time-sliced pass (begin_tick / run_slice), the merge of a second order into the next tick, the
-- heap order (same pushes, same pops), every rng draw in the same order.
local Rules = require("./Rules")
local SimState = require("./SimState")
local GodotRng = require("./GodotRng")

local readi32, readu8 = buffer.readi32, buffer.readu8
local writef64 = buffer.writef64
local floor, ceil = math.floor, math.ceil
local vcreate = vector.create

local function maxf(a: number, b: number): number
	return if a > b then a else b
end
local function minf(a: number, b: number): number
	return if a < b then a else b
end
local function clamp(x: number, lo: number, hi: number): number
	return if x < lo then lo elseif x > hi then hi else x
end
local function trunc(x: number): number
	return if x >= 0 then floor(x) else ceil(x)
end

local M = {}

-- f64 per attack in the mirror records
M.REC = 15
local REC = M.REC

-- the Rules instance fields (sim/rules.gd), in the order sim/attacks.gd sends them
M.RULE_FIELDS = {
	"k_lin", "k_area", "legacy_lin", "spawn_radius", "tribe_spawn_min_dist", "nation_spawn_delta",
	"max_tiles_per_tick", "defense_range", "struct_min_dist", "log_mid", "ts", "tile_norm", "growth_mult",
	"attack_speed_mult", "gold_mult", "ai_rate_mult", "pop_cap_mode", "pop_k",
}

local R = Rules.new(1.0)
local rng = GodotRng.new(0, true)

-- module state (reset with a new SimAttacks / a new map)
local S = {
	tick = 0,
	next_aid = 1,
	merges = {},
	list = {}, -- the attacks, in game.attacks order
	pass = {},
	pass_i = 0,
	pass_open = false,
	dirty = {}, -- attack -> true (mirror records to send)
	dlist = {},
	order_changed = false,
	ts_px = 2.0, -- game TS (pixels per tile)
	pf_tiles = 0,
	pf_atk = 0,
}

local function st(): any
	return SimState.cur
end

local function mark(a: any)
	if not S.dirty[a] then
		S.dirty[a] = true
		S.dlist[#S.dlist + 1] = a
	end
end

local function add_troops(id: number, d: number)
	local s = st()
	s:set_troops(id, s.troops[id] + d)
end

function M.reset(): boolean
	S.tick = 0
	S.next_aid = 1
	S.merges = {}
	S.list = {}
	S.pass = {}
	S.pass_i = 0
	S.pass_open = false
	S.dirty = {}
	S.dlist = {}
	S.order_changed = true
	S.pf_tiles = 0
	S.pf_atk = 0
	return true
end

-- ---------------- queue (binary min-heap on key) ----------------
-- 1-based storage of GDScript's 0-based PackedInt64Array / PackedInt32Array; a.hn = size
local function hpush(a: any, key: number, t: number)
	local hk, ht = a.hk, a.ht
	local i = a.hn
	a.hn = i + 1
	while i > 0 do
		local p = (i - 1) // 2
		local kp = hk[p + 1]
		if kp <= key then
			break
		end
		hk[i + 1] = kp
		ht[i + 1] = ht[p + 1]
		i = p
	end
	hk[i + 1] = key
	ht[i + 1] = t
end

local function hpop(a: any): number
	local hk, ht = a.hk, a.ht
	local n = a.hn
	if n == 0 then
		return -1
	end
	local top = ht[1]
	local lk, lt = hk[n], ht[n]
	n -= 1
	a.hn = n
	if n == 0 then
		return top
	end
	local i = 0
	while true do
		local l = i * 2 + 1
		if l >= n then
			break
		end
		local m = l
		if l + 1 < n and hk[l + 2] < hk[l + 1] then
			m = l + 1
		end
		if lk <= hk[m + 1] then
			break
		end
		hk[i + 1] = hk[m + 1]
		ht[i + 1] = ht[m + 1]
		i = m
	end
	hk[i + 1] = lk
	ht[i + 1] = lt
	return top
end

local function front_add(a: any, t: number)
	local f = a.front
	if not f[t] then
		f[t] = true
		a.fcount += 1
	end
end

local function front_erase(a: any, t: number)
	local f = a.front
	if f[t] then
		f[t] = nil
		a.fcount -= 1
	end
end

local function push(a: any, t: number)
	local s = st()
	local om = s.owner
	local at = a.a
	local W = s.W
	local x = t % W
	local n = 0
	if x > 0 and readi32(om, (t - 1) * 4) == at then
		n += 1
	end
	if x < W - 1 and readi32(om, (t + 1) * 4) == at then
		n += 1
	end
	if t >= W and readi32(om, (t - W) * 4) == at then
		n += 1
	end
	if t < s.n - W and readi32(om, (t + W) * 4) == at then
		n += 1
	end
	local key = 4 * S.tick + (Rules.PRIORITY_BASE + rng:randi() % Rules.PRIORITY_RAND) * R.priority_f4[readu8(s.mtn, t) * 5 + n]
	hpush(a, key, t)
	front_add(a, t)
end

-- the neighbours of t that the target owns, in the order up, down, left, right, one rng draw per push
local function add_neighbors(a: any, t: number)
	local s = st()
	local om = s.owner
	local W = s.W
	local N = s.n
	local tg = a.t
	local at = a.a
	local mtn = s.mtn
	local f4 = R.priority_f4
	local x = t % W
	local t4 = 4 * S.tick
	for k = 0, 3 do
		local u
		if k == 0 then
			if t < W then
				continue
			end
			u = t - W
		elseif k == 1 then
			if t >= N - W then
				continue
			end
			u = t + W
		elseif k == 2 then
			if x == 0 then
				continue
			end
			u = t - 1
		else
			if x == W - 1 then
				continue
			end
			u = t + 1
		end
		if readi32(om, u * 4) ~= tg then
			continue
		end
		local ux = u % W
		local n = 0
		if ux > 0 and readi32(om, (u - 1) * 4) == at then
			n += 1
		end
		if ux < W - 1 and readi32(om, (u + 1) * 4) == at then
			n += 1
		end
		if u >= W and readi32(om, (u - W) * 4) == at then
			n += 1
		end
		if u < N - W and readi32(om, (u + W) * 4) == at then
			n += 1
		end
		local key = t4 + (10 + rng:randi() % 7) * f4[readu8(mtn, u) * 5 + n]
		hpush(a, key, u)
		front_add(a, u)
	end
end

-- Seeds the queue with every target tile next to the attacker, walking the attacker's border set in order.
local function seed_from_border(a: any): number
	local s = st()
	local at = a.a
	local tg = a.t
	local om = s.owner
	local W = s.W
	local N = s.n
	local front = a.front
	local c = 0
	if at >= s.nat_n then
		return 0
	end
	local nx = s.bnext
	local t = s.bhead[at]
	while t >= 0 do
		local x = t % W
		if x > 0 and readi32(om, (t - 1) * 4) == tg and not front[t - 1] then
			push(a, t - 1)
			c += 1
		end
		if x < W - 1 and readi32(om, (t + 1) * 4) == tg and not front[t + 1] then
			push(a, t + 1)
			c += 1
		end
		if t >= W and readi32(om, (t - W) * 4) == tg and not front[t - W] then
			push(a, t - W)
			c += 1
		end
		if t < N - W and readi32(om, (t + W) * 4) == tg and not front[t + W] then
			push(a, t + W)
			c += 1
		end
		t = readi32(nx, t * 4)
	end
	return c
end

local function attack_between(at: number, tg: number): any
	for _, a in S.list do
		if a.a == at and a.t == tg and not a.dead then
			return a
		end
	end
	return nil
end

local function list_erase(a: any)
	local l = S.list
	for k = 1, #l do
		if l[k] == a then
			table.remove(l, k)
			S.order_changed = true
			return
		end
	end
end

local function end_attack(a: any, give_back: boolean, keep: number?)
	if a.dead then
		return
	end
	local s = st()
	a.dead = true
	mark(a)
	if give_back and s.alive[a.a] then
		add_troops(a.a, floor(maxf(a.troops, 0.0) * (keep or 1.0)))
	end
	if a.pend > 0.0 and s.alive[a.a] then
		add_troops(a.a, a.pend)
	end
	a.pend = 0.0
	a.troops = 0.0
	list_erase(a)
end

local function hostile(tg: number, at: number)
	st():ev(SimState.EV_HOSTILE, tg, at, S.tick, S.tick + Rules.HOSTILE_TICKS)
end

-- start_attack: troops already removed from the attacker by the caller.
local function start(at: number, tg: number, troops: number, beachhead: number): any
	local s = st()
	if troops < 1.0 then
		add_troops(at, troops)
		return nil
	end
	local counter = false
	if tg ~= 0 then
		local opp = attack_between(tg, at)
		if opp ~= nil then
			counter = true
			local cancel = minf(troops, opp.troops)
			troops -= cancel
			opp.troops -= cancel
			mark(opp)
			if opp.troops < 1.0 then
				end_attack(opp, false)
			end
			if troops < 1.0 then
				return nil
			end
		end
	end
	local a = attack_between(at, tg)
	if a ~= nil then
		mark(a)
		if beachhead >= 0 then
			a.troops += troops
			a.retreat_at = 0
			a.frozen_from = 0
			add_neighbors(a, beachhead)
		elseif a.started == S.tick then
			a.troops += troops
			seed_from_border(a)
		else
			if a.pend == 0.0 then
				S.merges[#S.merges + 1] = a
			end
			a.pend += troops
		end
		return a
	end
	a = {
		a = at,
		t = tg,
		troops = troops,
		hk = {},
		ht = {},
		hn = 0,
		front = {},
		fcount = 0,
		head = -1,
		chew = 0.0,
		aid = S.next_aid,
		retreat_at = 0,
		frozen_from = 0,
		started = S.tick,
		counter = counter,
		last = -1,
		sent = trunc(troops),
		pend = 0.0,
		dead = false,
		tgx = 0.0,
		tgy = 0.0,
		new = true,
	}
	S.next_aid += 1
	if beachhead >= 0 then
		add_neighbors(a, beachhead)
		a.last = beachhead
	else
		seed_from_border(a)
	end
	if a.fcount == 0 then
		add_troops(at, troops)
		return nil
	end
	if a.last < 0 then
		a.last = a.ht[1]
	end
	local wp = vcreate(a.last % s.W + 0.5, a.last // s.W + 0.5, 0) * S.ts_px
	a.tgx = wp.x
	a.tgy = wp.y
	S.list[#S.list + 1] = a
	S.order_changed = true
	mark(a)
	if tg > 0 then
		s:ev(SimState.EV_VIEWER_ATTACK, at, tg, 0, 0)
		hostile(tg, at)
	end
	return a
end

local function retreat(a: any)
	if a.retreat_at > 0 then
		return
	end
	a.retreat_at = S.tick + Rules.RETREAT_DELAY_TICKS + 1
	a.frozen_from = S.tick + 2
	mark(a)
end

local function touches(t: number, at: number): boolean
	local s = st()
	local om = s.owner
	local W = s.W
	local x = t % W
	if x > 0 and readi32(om, (t - 1) * 4) == at then
		return true
	end
	if x < W - 1 and readi32(om, (t + 1) * 4) == at then
		return true
	end
	if t >= W and readi32(om, (t - W) * 4) == at then
		return true
	end
	return t < s.n - W and readi32(om, (t + W) * 4) == at
end

local function annex_neighbour(t: number, victim: number): number
	local s = st()
	local om = s.owner
	local W = s.W
	local N = s.n
	local x = t % W
	local cand = {
		if x > 0 then t - 1 else -1,
		if x < W - 1 then t + 1 else -1,
		if t >= W then t - W else -1,
		if t < N - W then t + W else -1,
	}
	for _, nb in cand do
		if nb < 0 then
			continue
		end
		local o = readi32(om, nb * 4)
		if o > 0 and o ~= victim and not s:allied(o, victim) then
			return o
		end
	end
	return 0
end

-- A defender under ANNEX_BELOW_FULL_TILES is conquered outright: tiles touching the attacker go to it, others to
-- a bordering non-allied player, in repeated passes (max 100); unreachable pockets stay.
local function annex(victim: number, by: number)
	local s = st()
	local taken = R:conquer_gold(s.kind[victim], s.gold[victim])
	s.gold[by] += taken
	s.gold[victim] = 0.0
	s:ev(SimState.EV_CONQUEST, victim, by, taken, 0)
	s.last_by[victim] = by
	local W = s.W
	local om = s.owner
	local tiles = {}
	-- nv.bb.intersection(Rect2i(0, 0, W, H))
	local bx, by0, bw, bh = s.bbx[victim], s.bby[victim], s.bbw[victim], s.bbh[victim]
	local x0 = maxf(bx, 0)
	local y0 = maxf(by0, 0)
	local x1 = minf(bx + bw, W)
	local y1 = minf(by0 + bh, s.H)
	if x1 > x0 and y1 > y0 then
		for y = y0, y1 - 1 do
			for x = x0, x1 - 1 do
				local i = y * W + x
				if readi32(om, i * 4) == victim then
					tiles[#tiles + 1] = i
				end
			end
		end
	end
	for _ = 1, 100 do
		local progressed = false
		local rest = {}
		for _, t in tiles do
			if readi32(om, t * 4) ~= victim then
				continue
			end
			if touches(t, by) then
				s:set_owner(t, by)
				progressed = true
				continue
			end
			local taker = annex_neighbour(t, victim)
			if taker > 0 then
				s:set_owner(t, taker)
				progressed = true
			else
				rest[#rest + 1] = t
			end
		end
		tiles = rest
		if not progressed or #tiles == 0 then
			break
		end
	end
	for _, a in table.clone(S.list) do
		if a.a == victim then
			end_attack(a, false)
		end
	end
end

local function done(a: any, taken: number, sx: number, sy: number, neutral: boolean, at: number, tg: number)
	S.pf_tiles += taken
	S.pf_atk += 1
	if taken > 0 then
		local v = vcreate(sx / taken + 0.5, sy / taken + 0.5, 0) * S.ts_px
		a.tgx = v.x
		a.tgy = v.y
	end
	if not a.dead and (S.tick + a.aid) % Rules.ATTACK_UPDATE_TICKS == 0 and trunc(a.troops) ~= a.sent then
		a.sent = trunc(a.troops)
		if not neutral then
			hostile(tg, at)
		end
	end
end

local function process(a: any)
	local s = st()
	mark(a)
	local at = a.a
	local tg = a.t
	if not s.alive[at] or (tg ~= 0 and not s.alive[tg]) then
		end_attack(a, true)
		return
	end
	local neutral = tg == 0
	if a.retreat_at > 0 then
		if S.tick >= a.retreat_at then
			end_attack(a, true, if neutral then 1.0 else Rules.RETREAT_KEEP)
			return
		end
		if S.tick >= a.frozen_from then
			return
		end
	end
	if not neutral and s:allied(at, tg) then
		end_attack(a, true)
		return
	end
	local K_AREA = R.k_area
	local border_of = a.fcount * R.k_lin + rng:randi() % Rules.BORDER_JITTER
	local fo_mod = Rules.fallout_modifier(s.fallout_count / maxf(s.land_total, 1.0))
	local at_kind = s.kind[at]
	local nl = Rules.neutral_loss_per_mag(at_kind)
	local bonus_l = 1.0
	local bonus_s = 1.0
	local trait_l = 1.0
	local trait_s = 1.0
	local mag_k = 1.0
	local land = s.land
	if not neutral then
		local att_of = land[at] * K_AREA
		local def_of = maxf(land[tg] * K_AREA, 1.0)
		local ldb = R:large_territory_bonus(def_of, Rules.LARGE_DEFENDER_DEPTH)
		bonus_l = Rules.ATTACKER_LOSS_BASE * R:large_territory_bonus(att_of, Rules.LARGE_ATTACKER_DEPTH) * ldb
		bonus_s = R:large_territory_bonus(att_of, Rules.LARGE_ATTACKER_SPEED_DEPTH) * ldb
			/ (Rules.SPEED_COST_DIVISOR * maxf(border_of, 1.0))
		if s:is_traitor(tg, S.tick) then
			trait_l = Rules.TRAITOR_DEFENSE_DEBUFF
			trait_s = Rules.TRAITOR_SPEED_DEBUFF
		end
		if s.kind[tg] == Rules.KIND_TRIBE and at_kind ~= Rules.KIND_TRIBE then
			mag_k = Rules.BOT_DEFENDER_LOSS_MULT
		end
	end
	local mtn = s.mtn
	local border1 = maxf(border_of, 1.0)
	local cap = R.max_tiles_per_tick
	local budget = 1.0
	local taken = 0
	local sx, sy = 0.0, 0.0
	local W = s.W
	local om = s.owner
	local N = s.n
	local fall = s.fallout
	local T = s.troops
	local chk_def = not neutral and s.def_posts[tg] ~= nil
	local def_range = R.defense_range
	local ATTACK_MAG = Rules.ATTACK_MAG
	local ATTACK_TILE_COST = Rules.ATTACK_TILE_COST
	local rts = R.ts
	local TN_SCALE = Rules.TERRA_NULLIUS_COST_SCALE
	local TN_MIN = Rules.TERRA_NULLIUS_MIN_COST
	local TN_MAX = Rules.TERRA_NULLIUS_MAX_COST
	local LPD = Rules.ATTACKER_LOSS_PER_DENSITY
	local troops = a.troops
	local head = a.head
	local chew = a.chew
	local function adj_at(t: number): boolean
		local tx = t % W
		return (tx > 0 and readi32(om, (t - 1) * 4) == at)
			or (tx < W - 1 and readi32(om, (t + 1) * 4) == at)
			or (t >= W and readi32(om, (t - W) * 4) == at)
			or (t < N - W and readi32(om, (t + W) * 4) == at)
	end
	while budget > 0.0 do
		if troops < 1.0 then
			a.troops = 0.0
			a.head = head
			a.chew = chew
			end_attack(a, false)
			done(a, taken, sx, sy, neutral, at, tg)
			return
		end
		local t = head
		if t >= 0 then
			if readi32(om, t * 4) ~= tg or not adj_at(t) then
				head = -1
				chew = 0.0
				t = -1
			end
		end
		if t < 0 then
			if taken >= cap then
				break
			end
			t = hpop(a)
			if t < 0 then
				a.troops = troops
				a.head = head
				a.chew = chew
				end_attack(a, true)
				done(a, taken, sx, sy, neutral, at, tg)
				return
			end
			front_erase(a, t)
			if readi32(om, t * 4) ~= tg or not adj_at(t) then
				continue
			end
			add_neighbors(a, t)
			head = t
			chew = 0.0
		end
		local tt = readu8(mtn, t)
		local mag = ATTACK_MAG[tt] * rts
		local tc = ATTACK_TILE_COST[tt]
		if chk_def and s:defended(t, tg, def_range) then
			mag *= Rules.DEFENSE_POST_MAG
			tc *= Rules.DEFENSE_POST_COST
		end
		if readu8(fall, t) == 1 then
			mag *= fo_mod
			tc *= fo_mod
		end
		local loss
		local tf
		local dloss = 0.0
		if neutral then
			loss = mag * nl
			local v = clamp(TN_SCALE * tc / troops, TN_MIN, TN_MAX)
			tf = v / (border1 * 2.0)
		else
			local dtroops = T[tg]
			dloss = dtroops / maxf(land[tg] * K_AREA, 1.0)
			local ratio = dtroops / troops
			loss = mag * mag_k * trait_l * clamp(ratio, 0.6, 2.0) * (bonus_l + LPD * dloss)
			tf = clamp(ratio, 0.82, 7.5) * clamp(ratio / 20.0, 1.0, 50.0) * tc * bonus_s * trait_s
		end
		tf = maxf(tf, 1e-6)
		local dfloor = floor(dloss)
		local need = K_AREA - chew
		local can = ceil(budget / tf)
		if loss > 0.0 then
			can = minf(can, ceil(troops / loss))
		end
		if can >= need then
			budget -= need * tf
			troops -= need * loss
			if not neutral then
				local dt = T[tg]
				s:set_troops(tg, dt - minf(need * dfloor, maxf(dt, 0.0)))
			end
			chew = 0.0
			head = -1
			a.troops = troops
			a.head = head
			a.chew = chew
			s:set_owner(t, at)
			a.last = t
			taken += 1
			sx += t % W
			sy += t // W
			if not neutral and land[tg] * K_AREA < Rules.ANNEX_BELOW_FULL_TILES
				and (s.kind[tg] ~= Rules.KIND_HUMAN or troops > T[tg]) then
				annex(tg, at)
				end_attack(a, true)
				done(a, taken, sx, sy, neutral, at, tg)
				return
			end
		else
			budget -= can * tf
			troops -= can * loss
			if not neutral then
				local dt = T[tg]
				s:set_troops(tg, dt - minf(can * dfloor, maxf(dt, 0.0)))
			end
			chew += can
		end
	end
	a.troops = troops
	a.head = head
	a.chew = chew
	done(a, taken, sx, sy, neutral, at, tg)
end

-- pending orders join their attack (retreat dropped, queue re-seeded from the whole border); an attack that
-- ended meanwhile restarts with them
local function apply_merges()
	local s = st()
	local list = S.merges
	S.merges = {}
	for _, a in list do
		local troops = a.pend
		a.pend = 0.0
		mark(a)
		local at, tg = a.a, a.t
		if troops <= 0.0 or not s.alive[at] then
			continue
		end
		if tg ~= 0 and (not s.alive[tg] or s:allied(at, tg)) then
			add_troops(at, troops)
			continue
		end
		if a.dead then
			start(at, tg, troops, -1)
			continue
		end
		a.troops += troops
		a.retreat_at = 0
		a.frozen_from = 0
		seed_from_border(a)
	end
end

-- ---------------- calls from sim/attacks.gd ----------------

local function set_rng(hi: number, lo: number)
	rng.shi = hi
	rng.slo = lo
end

local function result(ret: any): any
	local recs = buffer.create(#S.dlist * REC * 8)
	local k = 0
	for _, a in S.dlist do
		writef64(recs, k, a.aid)
		writef64(recs, k + 8, a.a)
		writef64(recs, k + 16, a.t)
		writef64(recs, k + 24, a.troops)
		writef64(recs, k + 32, a.pend)
		writef64(recs, k + 40, if a.dead then 1 else 0)
		writef64(recs, k + 48, a.retreat_at)
		writef64(recs, k + 56, a.frozen_from)
		writef64(recs, k + 64, a.started)
		writef64(recs, k + 72, if a.counter then 1 else 0)
		writef64(recs, k + 80, a.last)
		writef64(recs, k + 88, a.sent)
		writef64(recs, k + 96, a.tgx)
		writef64(recs, k + 104, a.tgy)
		writef64(recs, k + 112, if a.new then 1 else 0)
		a.new = false
		k += REC * 8
	end
	table.clear(S.dirty)
	table.clear(S.dlist)
	local out: { [string]: any } = { atk = recs, rhi = rng.shi, rlo = rng.slo, ret = ret }
	if S.order_changed then
		local ob = buffer.create(#S.list * 4)
		for i, a in S.list do
			buffer.writei32(ob, (i - 1) * 4, a.aid)
		end
		out.order = ob
		S.order_changed = false
	end
	out.pf_tiles = S.pf_tiles
	out.pf_atk = S.pf_atk
	S.pf_tiles = 0
	S.pf_atk = 0
	return SimState.take(out)
end

local function by_aid(aid: number): any
	for _, a in S.list do
		if a.aid == aid then
			return a
		end
	end
	return nil
end

-- the game's Rules instance fields (RULE_FIELDS order) + priority_f4 (i32), the tick, the map's TS
function M.begin_tick(tick: number, fields: buffer, f4: buffer, ts_px: number): any
	for i, name in M.RULE_FIELDS do
		R[name] = buffer.readf64(fields, (i - 1) * 8)
	end
	local pf = {}
	for k = 0, buffer.len(f4) // 4 - 1 do
		pf[k] = readi32(f4, k * 4)
	end
	R.priority_f4 = pf
	S.ts_px = ts_px
	S.tick = tick
	S.pass = table.clone(S.list)
	S.pass_i = 0
	S.pass_open = true
	return true
end

-- One slice of the attack pass. world = SimState.nat_all's arguments; budget_us < 0: the whole pass.
function M.run_slice(rhi: number, rlo: number, n: number, troops: buffer, gold: buffer, alive: buffer,
	kind: buffer, team_mode: boolean, team: buffer, left: buffer, allies: buffer, traitor: buffer, defs: buffer,
	fallout_count: number, land_total: number, budget_us: number): any
	set_rng(rhi, rlo)
	SimState.nat_all(st(), n, troops, gold, alive, kind, team_mode, team, left, allies, traitor, defs, fallout_count,
		land_total)
	if not S.pass_open then
		return result(true)
	end
	local t0 = os.clock()
	local pass = S.pass
	local np = #pass
	while S.pass_i < np do
		local a = pass[S.pass_i + 1]
		S.pass_i += 1
		if not a.dead then
			process(a)
		end
		if budget_us >= 0 and bit32.band(S.pass_i, 7) == 0 and (os.clock() - t0) * 1e6 > budget_us then
			return result(false)
		end
	end
	S.pass = {}
	S.pass_open = false
	if #S.merges > 0 then
		apply_merges()
	end
	return result(true)
end

-- nat: SimState.nat_some triples (attacker and target)
function M.start(rhi: number, rlo: number, nat: buffer, at: number, tg: number, troops: number, beachhead: number): any
	set_rng(rhi, rlo)
	SimState.nat_some(st(), nat)
	local a = start(at, tg, troops, beachhead)
	return result(if a then a.aid else -1)
end

function M.end_attack(rhi: number, rlo: number, nat: buffer, aid: number, give_back: boolean, keep: number): any
	set_rng(rhi, rlo)
	SimState.nat_some(st(), nat)
	local a = by_aid(aid)
	if a then
		end_attack(a, give_back, keep)
	end
	return result(a ~= nil)
end

function M.retreat(rhi: number, rlo: number, aid: number): any
	set_rng(rhi, rlo)
	local a = by_aid(aid)
	if a then
		retreat(a)
	end
	return result(a ~= nil)
end

-- arsenal: an owner's attacks lose a share of their troops (troops *= f)
function M.scale_owner(rhi: number, rlo: number, o: number, f: number): any
	set_rng(rhi, rlo)
	for _, a in S.list do
		if a.a == o then
			a.troops *= f
			mark(a)
		end
	end
	return result(true)
end

function M.set_troops(rhi: number, rlo: number, aid: number, v: number): any
	set_rng(rhi, rlo)
	local a = by_aid(aid)
	if a then
		a.troops = v
		mark(a)
	end
	return result(a ~= nil)
end

-- tests: the heap / front sizes of an attack (aid) and the merge queue
function M.debug(aid: number): any
	local a = by_aid(aid)
	if not a then
		return { found = false, merges = #S.merges, n = #S.list }
	end
	return { found = true, hn = a.hn, front = a.fcount, head = a.head, chew = a.chew, merges = #S.merges, n = #S.list }
end

return M
