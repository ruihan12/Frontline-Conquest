--!strict
-- SimArsenal: bombs, munitions, SAMs and blasts (docs/LUAU_PORT.md, Step 5c). Transliterated line for line from
-- this project's sim/arsenal.gd (SimArsenal) and game/nukes.gd (launch, flight, MIRV split, detonation), which
-- port upstream RoWorld src/shared/Core/SimNukes.luau + SimArsenal.luau (AGPL-3.0, lukechatton/roworld), with
-- the customs in CLAUDE.md (marked `-- CUSTOM:`).
--
-- Luau owns the missiles in flight (with their SAM state) and the munitions in flight. GDScript keeps mirror
-- Dictionaries of both (game.missiles, sim_ars.munitions: the renderer, net/rep.gd and the tests read them) and
-- builds them from what each call returns. The structures stay GDScript's (game.structs): every call that needs
-- them gets a snapshot in list order (SNAP f64 each: k, tile, o, level, bt, hp (NaN = no key), serial) plus the
-- reload / battery fields of the arsenal kinds (EXT, see read_ext). A structure is named by its snapshot index
-- inside a call and by (tile, serial) across calls (the serial changes when a different Dictionary stands on
-- the tile). Writes to structures come back as records (out.sw) and events, in the order GDScript made them.
--
-- Events (SimState.ev, kinds >= 10, applied by sim/arsenal.gd on_luau_event in stream order) carry what only
-- GDScript can do: remove a structure, sounds / notes / effects, boats, grudges.
local Rules = require("./Rules")
local SimState = require("./SimState")
local SimAttacks = require("./SimAttacks")
local GodotRng = require("./GodotRng")

local readf64, writef64 = buffer.readf64, buffer.writef64
local readi32, writei32 = buffer.readi32, buffer.writei32
local floor, ceil, sqrt, cos, sin, abs = math.floor, math.ceil, math.sqrt, math.cos, math.sin, math.abs
local vcreate = vector.create
local f32 = GodotRng.f32
local TAU = 2.0 * math.pi

local function trunc(x: number): number
	return if x >= 0 then floor(x) else ceil(x)
end
local function maxf(a: number, b: number): number
	return if a > b then a else b
end
local function minf(a: number, b: number): number
	return if a < b then a else b
end
local function clampi(x: number, lo: number, hi: number): number
	return if x < lo then lo elseif x > hi then hi else x
end
-- C++ integer division (truncates toward zero)
local function cdiv(a: number, b: number): number
	return trunc(a / b)
end

local M = {}

M.SNAP = 7
local SNAP = M.SNAP
M.MS_REC = 17 -- f64 per new missile record (out.nms)
M.MU_REC = 8 -- f64 per new munition record (out.nmu)

-- event kinds (sim/arsenal.gd on_luau_event)
M.EV_STRUCT_REMOVE = 10 -- (index, by, why 1 strike / 2 blast)
M.EV_STRUCT_DOWN = 11 -- (index, by, new level)
M.EV_BOATS_SCALE = 12 -- (owner, f)                 boats of owner: troops *= f
M.EV_BOATS_WARHEAD = 13 -- (owner, tiles lost, cap)  boats of owner: the warhead loss per tile
M.EV_GRUDGE_SET = 14 -- (victim, by, expiry, attacked tick or -1)
M.EV_LAST_BY = 15 -- (nation, by)
M.EV_STRIKE_FX = 16 -- (nk, tile, shooter)
M.EV_SAM_FIRED = 17 -- (mid, index, k, hit tick)
M.EV_SAM_HIT = 18 -- (mid, SAM owner)
M.EV_SAM_CLEAR = 19 -- (mid, 1: cand_tick = now)
M.EV_DETONATE = 20 -- (mid, victim, tile)
M.EV_FALLOUT_VIEW = 21 -- (start, count) into out.ft
M.EV_UNITS_BLAST = 22 -- (cx, cy, r2)
M.EV_BREAK = 23 -- (breaker, other)
local E = M

-- CUSTOM: game/nukes.gd NUKE_SPEED_X, ICBM_SPEED_X, ICBM_EVADE_P (game/state.gd): every bomb flies at 0.9x
-- upstream's speed, an ICBM launch 1.2x faster on top and with a 20% chance to evade SAMs (tests/test_luau_arsenal.gd
-- checks they equal the GDScript constants).
M.NUKE_SPEED_X = 0.9
M.ICBM_SPEED_X = 1.2
M.ICBM_EVADE_P = 0.20

local R = Rules.new(1.0)
local rng = GodotRng.new(0, true)

-- module state (reset with a new map)
local S = {
	missiles = {} :: { any },
	by_mid = {} :: { [number]: any },
	next_mid = 1,
	munitions = {} :: { any },
	by_uid = {} :: { [number]: any },
	next_uid = 1,
	land = nil :: { number }?,
	land_key = "",
}

-- per call
local C = {
	tick = 0,
	player = 1,
	rapid = false,
	r_wh = 0.0,
	new_ms = {} :: { any },
	gone_ms = {} :: { number },
	new_mu = {} :: { any },
	gone_mu = {} :: { number },
	sam_dirty = {} :: { any },
	ftiles = {} :: { number },
	stats = { 0, 0, 0, 0, 0, 0, 0 }, -- sam_fired, sam_hits, shells, strikes, struct_dmg, struct_down, killed
	tk = {} :: { [number]: number },
	td = {} :: { [number]: number },
}
local ST_SAM_FIRED, ST_SAM_HITS, ST_SHELLS, ST_STRIKES, ST_DMG, ST_DOWN, ST_KILLED = 1, 2, 3, 4, 5, 6, 7

-- the structure snapshot (1-based index i = GDScript index + 1)
local N = 0
local K: { number } = {}
local T: { number } = {}
local O: { number } = {}
local L: { number } = {}
local B: { number } = {}
local HP: { number } = {}
local SER: { number } = {}
local DEAD: { boolean } = {}
local NF: { number } = {} -- next_fire (NaN = no key)
local UP: { number } = {} -- up_tick (NaN = no key)
local CD: { number } = {}
local CM: { number } = {}
local SH: { any } = {} -- shots (false = no key)
local SHW: { boolean } = {} -- shots changed
local WM: { number } = {} -- write mask
local B0: { number } = {}
local CD0: { number } = {}
local CM0: { number } = {}
local NF0: { number } = {}
local HP0: { number } = {}
local L0: { number } = {}
local AT: { [number]: number } = {} -- tile -> live index
local W_BT, W_CD, W_CM, W_NF, W_HP, W_LV, W_SH = 1, 2, 4, 8, 16, 32, 64

local function st(): any
	return SimState.cur
end

local function now(): number
	return C.tick
end

local function nan(x: number): boolean
	return x ~= x
end

function M.reset(): boolean
	S.missiles = {}
	S.by_mid = {}
	S.next_mid = 1
	S.munitions = {}
	S.by_uid = {}
	S.next_uid = 1
	S.land = nil
	S.land_key = ""
	return true
end

-- ---------------------------------------------------------------- snapshot
local function read_snap(snap: buffer, ext: buffer)
	local n = buffer.len(snap) // (SNAP * 8)
	table.clear(AT)
	for i = 1, n do
		local b = (i - 1) * SNAP * 8
		K[i] = readf64(snap, b)
		T[i] = readf64(snap, b + 8)
		O[i] = readf64(snap, b + 16)
		L[i] = readf64(snap, b + 24)
		B[i] = readf64(snap, b + 32)
		HP[i] = readf64(snap, b + 40)
		SER[i] = readf64(snap, b + 48)
		DEAD[i] = false
		NF[i] = 0 / 0
		UP[i] = 0 / 0
		CD[i] = 0 / 0
		CM[i] = 0 / 0
		SH[i] = false
		SHW[i] = false
		WM[i] = 0
		B0[i] = B[i]
		HP0[i] = HP[i]
		L0[i] = L[i]
		AT[T[i]] = i
	end
	for i = n + 1, N do
		K[i], T[i], O[i], L[i], B[i], HP[i], SER[i] = nil :: any, nil :: any, nil :: any, nil :: any, nil :: any, nil :: any, nil :: any
		DEAD[i], NF[i], UP[i], CD[i], CM[i], SH[i], SHW[i], WM[i] = nil :: any, nil :: any, nil :: any, nil :: any, nil :: any, nil :: any, nil :: any, nil :: any
		B0[i], HP0[i], L0[i], CD0[i], CM0[i], NF0[i] = nil :: any, nil :: any, nil :: any, nil :: any, nil :: any, nil :: any
	end
	N = n
	-- EXT: per structure of kind 4, 5, 10, 14, 15: index (0-based), next_fire, up_tick, cd, cmax (NaN = no key),
	-- shots count (-1 = no key), shots...
	local k = 0
	local ne = buffer.len(ext)
	while k < ne do
		local i = readf64(ext, k) + 1
		NF[i] = readf64(ext, k + 8)
		UP[i] = readf64(ext, k + 16)
		CD[i] = readf64(ext, k + 24)
		CM[i] = readf64(ext, k + 32)
		local ns = readf64(ext, k + 40)
		k += 48
		if ns >= 0 then
			local sh = table.create(ns)
			for j = 1, ns do
				sh[j] = readf64(ext, k)
				k += 8
			end
			SH[i] = sh
		end
	end
	for i = 1, n do
		CD0[i] = CD[i]
		CM0[i] = CM[i]
		NF0[i] = NF[i]
	end
end

-- (tile, serial) of a structure seen in an earlier call -> its index now (nil: gone)
local function resolve(ref: any): number?
	if not ref then
		return nil
	end
	local i = AT[ref[1]]
	if i == nil or SER[i] ~= ref[2] or DEAD[i] then
		return nil
	end
	return i
end

local function kill_struct(i: number)
	DEAD[i] = true
	if AT[T[i]] == i then
		AT[T[i]] = nil
	end
end

-- ---------------------------------------------------------------- helpers
local function tpos(t: number, W: number): vector
	return vcreate(t % W + 0.5, t // W + 0.5, 0)
end

-- Vector2.distance_squared_to (float32)
local function dsq(a: vector, b: vector): number
	local dx = f32(a.x - b.x)
	local dy = f32(a.y - b.y)
	return f32(f32(dx * dx) + f32(dy * dy))
end

local function d2(a: number, b: number, W: number): number
	local dx = a % W - b % W
	local dy = a // W - b // W
	return dx * dx + dy * dy
end

local function man(a: number, b: number, W: number): number
	return abs(a % W - b % W) + abs(a // W - b // W)
end

local function man_v(a: vector, b: vector): number
	return abs(floor(a.x) - floor(b.x)) + abs(floor(a.y) - floor(b.y))
end

local function strike_enemy(a: number, b: number): boolean
	return b > 0 and b ~= a and not st():allied(a, b)
end

local function s_kind(i: number): number
	local sk = Rules.S_OF[K[i]]
	return if sk == nil then -1 else sk
end

local function stat(k: number, v: number)
	C.stats[k] += v
end

-- ---------------------------------------------------------------- missile slots (shots queues)
local function reload_ticks(i: number): number
	local sk = s_kind(i)
	if sk < 0 then
		return 0
	end
	local base = Rules.RELOAD_TICKS[sk]
	if K[i] == 4 then
		return math.max(1, ceil(base * Rules.SAM_RELOAD_MULT))
	end
	return base
end

-- SimArsenal.shot_stamp: Rapid Reload records the shot as fired earlier
local function shot_stamp(i: number): number
	local t = now()
	if O[i] == C.player and C.rapid then
		local base = reload_ticks(i)
		return t - (base - math.max(1, ceil(base * Rules.RAPID_RELOAD_MULT)))
	end
	return t
end

local function shots_of(i: number): { number }
	local sh = SH[i]
	if not sh then
		sh = {}
		SH[i] = sh
		SHW[i] = true -- st["shots"] = [] creates the key
		WM[i] = bit32.bor(WM[i], W_SH)
	end
	return sh
end

-- SimNukes.ready_missiles: `level` missiles minus those still reloading
local function ready_missiles(i: number): number
	if B[i] > 0.0 then
		return 0
	end
	local cd = reload_ticks(i)
	local shots = shots_of(i)
	local t = now()
	while #shots > 0 and shots[1] + cd <= t do
		table.remove(shots, 1)
		SHW[i] = true
		WM[i] = bit32.bor(WM[i], W_SH)
	end
	local lvl = if K[i] == 4 or K[i] == 5 then L[i] else 1
	return lvl - #shots
end

local function fire_shot(i: number)
	local shots = shots_of(i)
	shots[#shots + 1] = shot_stamp(i)
	SHW[i] = true
	WM[i] = bit32.bor(WM[i], W_SH)
end

-- reload ring / HUD fields (seconds until the next missile is loaded)
local function refresh_cd(i: number)
	local cd = reload_ticks(i)
	if cd <= 0 then
		return
	end
	local rdy = ready_missiles(i)
	local shots = SH[i] :: { number }
	if rdy > 0 or #shots == 0 then
		CD[i] = 0.0
	else
		CD[i] = maxf(0.0, (shots[1] + cd - now()) / 10.0)
	end
	CM[i] = cd / 10.0
	WM[i] = bit32.bor(WM[i], W_CD + W_CM)
end

-- ---------------------------------------------------------------- structure health (SimArsenal.damage_struct)
local function struct_hp_full(i: number): number
	local sk = s_kind(i)
	return if sk >= 0 then Rules.STRUCT_HP[sk] else 1000
end

local function damage_struct(i: number, dmg: number, by: number)
	if DEAD[i] or dmg <= 0 then
		return
	end
	local full = struct_hp_full(i)
	HP[i] = (if nan(HP[i]) then full else HP[i]) - dmg
	WM[i] = bit32.bor(WM[i], W_HP)
	stat(ST_DMG, 1)
	if HP[i] > 0 then
		return
	end
	if L[i] <= 1 then
		kill_struct(i)
		stat(ST_DOWN, 1)
		st():ev(E.EV_STRUCT_REMOVE, i - 1, by, 1, 0)
		return
	end
	L[i] -= 1
	HP[i] = full
	WM[i] = bit32.bor(WM[i], W_LV)
	if K[i] == 4 or K[i] == 5 then
		local shots = SH[i]
		if shots then
			while #shots > L[i] do
				shots[#shots] = nil
				SHW[i] = true
				WM[i] = bit32.bor(WM[i], W_SH)
			end
		end
	end
	st():ev(E.EV_STRUCT_DOWN, i - 1, by, L[i], 0)
end

-- ---------------------------------------------------------------- artillery (SimArsenal battery)
local function battery_gap(i: number): number
	local gap = rng:randi_range(Rules.ARTILLERY_GAP_MIN, Rules.ARTILLERY_GAP_MAX)
	if O[i] == C.player and C.rapid then
		gap = math.max(1, ceil(gap * Rules.RAPID_RELOAD_MULT))
	end
	return gap
end

local function activate(i: number)
	if K[i] == 10 then
		NF[i] = now() + battery_gap(i)
		WM[i] = bit32.bor(WM[i], W_NF)
	end
end

local function battery_target(i: number): number
	local s = st()
	local W = s.W
	local rng_ = R:artillery_range()
	local r2 = rng_ * rng_
	local best = -1
	local bd = 0.0
	local oi, ti = O[i], T[i]
	for j = 1, N do
		if DEAD[j] or not strike_enemy(oi, O[j]) then
			continue
		end
		local d = d2(ti, T[j], W)
		if d <= r2 and (best < 0 or d < bd or (d == bd and T[j] < best)) then
			best = T[j]
			bd = d
		end
	end
	if best >= 0 then
		return best
	end
	local cx = ti % W
	local cy = ti // W
	local own = s.owner
	for _ = 1, Rules.ARTILLERY_SAMPLES do
		local ang = rng:randf() * TAU
		local rad = rng_ * sqrt(rng:randf())
		local x = trunc(floor(cx + cos(ang) * rad + 0.5))
		local y = trunc(floor(cy + sin(ang) * rad + 0.5))
		if x < 0 or y < 0 or x >= W or y >= s.H then
			continue
		end
		local tt = y * W + x
		local ow = readi32(own, tt * 4)
		if ow >= 0 and strike_enemy(oi, ow) then
			return tt
		end
	end
	return -1
end

local function spawn_munition(nk: number, o: number, from_tile: number, to_tile: number): any
	local s = st()
	local W = s.W
	local a = tpos(from_tile, W)
	local b = tpos(to_tile, W)
	local t0 = now()
	local m = {
		uid = S.next_uid,
		nk = nk,
		o = o,
		from = from_tile,
		tile = to_tile,
		t0 = t0,
		t1 = t0 + R:munition_flight_ticks(vector.magnitude(a - b), nk),
		victim = readi32(s.owner, to_tile * 4),
	}
	S.next_uid += 1
	S.munitions[#S.munitions + 1] = m
	S.by_uid[m.uid] = m
	C.new_mu[#C.new_mu + 1] = m
	return m
end

local function battery_tick(t: number)
	for i = 1, N do
		if K[i] ~= 10 or B[i] > 0.0 or DEAD[i] then
			continue
		end
		if nan(NF[i]) then
			NF[i] = t + battery_gap(i)
			WM[i] = bit32.bor(WM[i], W_NF)
		end
		if t < NF[i] then
			continue
		end
		local tt = battery_target(i)
		WM[i] = bit32.bor(WM[i], W_NF)
		if tt < 0 then
			NF[i] = t + Rules.ARTILLERY_IDLE_TICKS
			continue
		end
		NF[i] = t + battery_gap(i)
		spawn_munition(Rules.N_SHELL, O[i], T[i], tt)
		stat(ST_SHELLS, 1)
	end
end

-- land tiles of a disc around tile `c` (tile-centre distances, like SimState.disk_tiles(.., land_only))
local function disk_tiles(c: number, r: number): { number }
	local s = st()
	local out = {}
	local W, H = s.W, s.H
	local own = s.owner
	local cx = c % W
	local cy = c // W
	local ri = trunc(ceil(r))
	local r2 = r * r
	for y = math.max(0, cy - ri), math.min(H, cy + ri + 1) - 1 do
		local dy = y - cy
		for x = math.max(0, cx - ri), math.min(W, cx + ri + 1) - 1 do
			local dx = x - cx
			if dx * dx + dy * dy > r2 then
				continue
			end
			local i = y * W + x
			if readi32(own, i * 4) >= 0 then
				out[#out + 1] = i
			end
		end
	end
	return out
end

-- SimArsenal._strike: kills a share of each enemy army with land under it, damages structures there
local function strike(m: any)
	local s = st()
	local nk = m.nk
	local to = m.tile
	local shooter = m.o
	local W = s.W
	local radius = R:strike_radius(nk)
	local r2 = radius * radius
	local hit: { [number]: number } = {}
	local order: { number } = {}
	if nk == Rules.N_SHELL then
		local o0 = readi32(s.owner, to * 4)
		if strike_enemy(shooter, o0) then
			hit[o0] = 1
			order[1] = o0
		end
	else
		for _, tt in disk_tiles(to, radius) do
			local o1 = readi32(s.owner, tt * 4)
			if strike_enemy(shooter, o1) then
				if hit[o1] == nil then
					hit[o1] = 0
					order[#order + 1] = o1
				end
				hit[o1] += 1
			end
		end
	end
	for _, o in order do
		local troops = s.troops[o]
		local kill = Rules.strike_kill(nk, troops, hit[o] * R.k_area, R.ts)
		if kill <= 0.0 then
			continue
		end
		local keep = 1.0 - kill / maxf(troops, 1.0)
		s:set_troops(o, troops - kill)
		stat(ST_KILLED, trunc(kill))
		if nk ~= Rules.N_SHELL then
			SimAttacks.ext_scale(o, keep)
			s:ev(E.EV_BOATS_SCALE, o, keep, 0, 0)
			s:ev(E.EV_GRUDGE_SET, o, shooter, now() + Rules.HOSTILE_TICKS, now())
		end
	end
	local dmg = Rules.STRIKE_DAMAGE[nk]
	if dmg > 0 then
		for j = 1, N do
			if DEAD[j] then
				continue
			end
			if strike_enemy(shooter, O[j]) and d2(to, T[j], W) <= r2 then
				damage_struct(j, dmg, shooter)
			end
		end
	end
	s:ev(E.EV_STRIKE_FX, nk, to, shooter, 0)
end

local function list_erase(list: { any }, x: any): boolean
	for k, v in list do
		if v == x then
			table.remove(list, k)
			return true
		end
	end
	return false
end

local function munitions_tick(t: number)
	for _, m in table.clone(S.munitions) do
		if t < m.t1 then
			continue
		end
		list_erase(S.munitions, m)
		S.by_uid[m.uid] = nil
		C.gone_mu[#C.gone_mu + 1] = m.uid
		strike(m)
	end
end

-- ---------------------------------------------------------------- diplomacy
local function break_alliance(a: number, b: number)
	local s = st()
	local lo, hi = a, b
	if b < a then
		lo, hi = b, a
	end
	local key = lo * 4096 + hi
	if not s.allies[key] then
		return -- (diplomacy.gd end_alliance: no alliance key, nothing to end)
	end
	s.allies[key] = nil
	s.traitor[a] = now() + Rules.TRAITOR_TICKS
	s:ev(E.EV_BREAK, a, b, 0, 0)
end

-- ---------------------------------------------------------------- nukes: troops, blasts
local function cities(o: number): number
	local c = 0
	for j = 1, N do
		if not DEAD[j] and K[j] == 0 and O[j] == o then
			c += L[j]
		end
	end
	return c
end

local function troop_cap(o: number): number
	local s = st()
	return R:max_troops(C.tk[o] or 0, s.land[o], cities(o), C.td[o] or 0)
end

-- SimNukes._nuke_troops: bombs shrink troops by ((T - n) / T)^5; warheads 500 x (1 - e^(-2 excess/max))
-- per full-size tile, never below 3 % of the cap.
local function nuke_troops(o: number, nk: number, n_lost: number, tiles_before: number)
	local s = st()
	if nk ~= Rules.N_WARHEAD then
		local f = (maxf(0.0, tiles_before - n_lost) / maxf(tiles_before, 1)) ^ 5.0
		s:set_troops(o, s.troops[o] * f)
		SimAttacks.ext_scale(o, f)
		s:ev(E.EV_BOATS_SCALE, o, f, 0, 0)
		return
	end
	local cap = maxf(troop_cap(o), 1.0)
	local k = R.k_area
	local tr = s.troops[o]
	for _ = 1, n_lost do
		local d = minf(k * Rules.warhead_death(tr, cap, R.ts), maxf(0.0, tr - 0.03 * cap))
		if d <= 0.0 then
			break
		end
		tr -= d
	end
	s:set_troops(o, tr)
	for _, a in SimAttacks.ext_owner(o) do
		local at = a.troops
		for _ = 1, n_lost do
			local d2_ = minf(k * Rules.warhead_death(at, cap, R.ts), maxf(0.0, at - 0.03 * cap))
			if d2_ <= 0.0 then
				break
			end
			at -= d2_
		end
		SimAttacks.ext_set(a, at)
	end
	s:ev(E.EV_BOATS_WARHEAD, o, n_lost, cap, 0)
end

-- SimNukes._detonate: every land tile of the inner radius and a random half of the outer ring is relinquished
-- and left as fallout; each hit owner loses troops (nuke_troops); every structure and unit inside the outer
-- radius is destroyed. Returns lost (owner -> tiles, in hit order) and the fallout count.
local function nuke_blast(o: number, cxf: number, cyf: number, r: number, nk: number): ({ number }, { [number]: number }, number)
	local s = st()
	local W, H = s.W, s.H
	local cx = trunc(cxf)
	local cy = trunc(cyf)
	local ct = clampi(cy, 0, H - 1) * W + clampi(cx, 0, W - 1)
	local inner = r * Rules.inner_frac(nk)
	local inner2 = inner * inner
	local r2 = r * r
	local lost: { [number]: number } = {}
	local before: { [number]: number } = {}
	local order: { number } = {}
	local fstart = #C.ftiles
	local fallout_n = 0
	local own = s.owner
	for _, tt in disk_tiles(ct, r) do
		local dx = tt % W - cx
		local dy = tt // W - cy
		if dx * dx + dy * dy > inner2 and rng:randi() % 2 == 0 then
			continue
		end
		local ow = readi32(own, tt * 4)
		if ow > 0 then
			if before[ow] == nil then
				before[ow] = s.land[ow]
				lost[ow] = 0
				order[#order + 1] = ow
			end
			lost[ow] += 1
			s:set_owner(tt, 0)
			local i = AT[tt]
			if i ~= nil then
				kill_struct(i) -- (map.gd _set_owner removes it when the owner change is applied)
			end
		end
		s:set_fallout(tt, 1)
		C.ftiles[#C.ftiles + 1] = tt
		fallout_n += 1
	end
	if fallout_n > 0 then
		s:ev(E.EV_FALLOUT_VIEW, fstart, fallout_n, 0, 0)
	end
	for _, ow in order do
		nuke_troops(ow, nk, lost[ow], before[ow])
		if s.land[ow] <= 0 then
			s.last_by[ow] = o
			s:ev(E.EV_LAST_BY, ow, o, 0, 0)
		end
		if ow ~= o then
			s:ev(E.EV_GRUDGE_SET, ow, o, now() + Rules.NUKE_GRUDGE_TICKS, -1)
		end
	end
	-- structures and units inside the outer radius
	for j = 1, N do
		if DEAD[j] then
			continue
		end
		local sdx = T[j] % W - cx
		local sdy = T[j] // W - cy
		if sdx * sdx + sdy * sdy <= r2 then
			kill_struct(j)
			s:ev(E.EV_STRUCT_REMOVE, j - 1, o, 2, 0)
		end
	end
	s:ev(E.EV_UNITS_BLAST, cx, cy, r2, 0)
	return order, lost, fallout_n
end

-- SimNukes._break_nuked_alliances: allies with >= 100 weighted full-size tiles (inner 1, outer 0.5)
-- inside the blast lose their alliance with the launcher.
local function break_nuked_alliances(o: number, cxf: number, cyf: number, r: number, nk: number): { number }
	local s = st()
	local W = s.W
	local cx = trunc(cxf)
	local cy = trunc(cyf)
	local ct = clampi(cy, 0, s.H - 1) * W + clampi(cx, 0, W - 1)
	local inner = r * Rules.inner_frac(nk)
	local inner2 = inner * inner
	local w: { [number]: number } = {}
	local order: { number } = {}
	for _, tt in disk_tiles(ct, r) do
		local ow = readi32(s.owner, tt * 4)
		if ow <= 0 or ow == o or not s:allied(o, ow) then
			continue
		end
		local dx = tt % W - cx
		local dy = tt // W - cy
		if w[ow] == nil then
			w[ow] = 0.0
			order[#order + 1] = ow
		end
		w[ow] += if dx * dx + dy * dy <= inner2 then 1.0 else 0.5
	end
	local broke = {}
	for _, ow in order do
		if w[ow] * R.k_area >= Rules.NUKE_ALLIANCE_BREAK_FULL then
			break_alliance(o, ow)
			broke[#broke + 1] = ow
		end
	end
	return broke
end

-- ---------------------------------------------------------------- missiles
local function tc(tile: number, W: number): vector
	return vcreate(tile % W + 0.5, tile // W + 0.5, 0)
end

-- CUSTOM: game/nukes.gd flight_ticks: 0.9x upstream speed, ICBM 1.2x faster on top
local function flight_ticks_x(ft: number, icbm: boolean): number
	return math.max(1, trunc(ceil(ft / (M.NUKE_SPEED_X * (if icbm then M.ICBM_SPEED_X else 1.0)))))
end

-- SimNukes._spawn_nuke (game/nukes.gd _spawn_missile)
local function spawn_missile(o: number, k: number, nk: number, from: vector, to: vector, ft: number, arc: any, r: number): any
	local s = st()
	local W = s.W
	local tile = trunc(to.y) * W + trunc(to.x)
	local ms = {
		mid = S.next_mid,
		o = o,
		k = k,
		nk = nk,
		from = from,
		to = to,
		lt = now(),
		ft = math.max(1, ft),
		r = r,
		arc = arc,
		tgt_o = if tile >= 0 and tile < W * s.H then readi32(s.owner, tile * 4) else -1,
		mirv = nk == Rules.N_MIRV,
		mirv_bus = nk == Rules.N_MIRV,
		branched = nk == Rules.N_WARHEAD,
		evade = false,
		icbm = false,
		-- SAM state (sim/arsenal.gd _sam_*): sam = has the candidate keys
		sam = false,
		cand_tick = -100000,
		cands = {} :: { any },
		pf = {} :: { [number]: number },
		pf_keys = {} :: { number },
		pk = {} :: { [number]: number },
		pk_keys = {} :: { number },
		traj = nil :: { vector }?,
		traj_new = false,
		refreshed = false,
		sam_st = nil :: any, -- (tile, serial); false = the key holds null
		sam_hit = 0,
		sam_k = 0,
	}
	S.next_mid += 1
	S.missiles[#S.missiles + 1] = ms
	S.by_mid[ms.mid] = ms
	C.new_ms[#C.new_ms + 1] = ms
	return ms
end

local function erase_missile(ms: any)
	list_erase(S.missiles, ms)
	S.by_mid[ms.mid] = nil
	C.gone_ms[#C.gone_ms + 1] = ms.mid
end

-- SimArsenal._scatter_warheads targets: 4..6 warheads evenly around the aim (random turn, +-0.3 rad jitter),
-- 28..46 full-size tiles out, never onto the launcher's or an ally's land.
local function scatter_targets(o: number, aim: vector): { vector }
	local s = st()
	local W, H = s.W, s.H
	local count = rng:randi_range(Rules.SCATTER_MIN, Rules.SCATTER_MAX)
	local base = rng:randf() * TAU
	local near = R:scatter_near()
	local far = R:scatter_far()
	local out = {}
	for i = 0, count - 1 do
		for _try = 1, 6 do
			local ang = base + i * TAU / count + rng:randf_range(-0.3, 0.3)
			local rad = rng:randf_range(near, far)
			local x = trunc(floor(aim.x + cos(ang) * rad + 0.5))
			local y = trunc(floor(aim.y + sin(ang) * rad + 0.5))
			if x < 0 or y < 0 or x >= W or y >= H then
				continue
			end
			local ow = readi32(s.owner, (y * W + x) * 4)
			if ow == o or (ow > 0 and s:allied(o, ow)) then
				continue
			end
			out[#out + 1] = vcreate(x + 0.5, y + 0.5, 0)
			break
		end
	end
	return out
end

-- game/nukes.gd _scatter_warheads: each flies its own arc from the silo and lands 2 ticks after the last
local function scatter_warheads(o: number, k: number, from: vector, aim: number, flight: number, evade: boolean, icbm: boolean)
	local s = st()
	local fired = 0
	for _, wp in scatter_targets(o, tc(aim, s.W)) do
		fired += 1
		local arc = R:nuke_arc(s.H, from, wp)
		local ft = math.max(flight, flight_ticks_x(R:nuke_arc_ticks(arc, Rules.N_SCATTER), icbm)) + fired * 2
		local w = spawn_missile(o, k, Rules.N_WARHEAD, from, wp, ft, arc, C.r_wh)
		w.evade = evade
		w.icbm = icbm
	end
end

-- game/nukes.gd launch_nuke after its checks, the silo pick and the silo's shot (GDScript): the missile, its
-- target owner, the ICBM roll, a Scattershot's warheads. Returns the missile.
local function launch(o: number, k: number, nk: number, silo_tile: number, tile: number, r: number, icbm: boolean, victim: number): any
	local s = st()
	local W = s.W
	local from = tc(silo_tile, W)
	local tp = tc(tile, W)
	local arc = R:munition_arc(s.H, from, tp, nk)
	local ms = spawn_missile(o, k, nk, from, tp, flight_ticks_x(R:nuke_arc_ticks(arc, nk), icbm), arc, r)
	ms.icbm = icbm
	ms.tgt_o = victim
	-- CUSTOM: ICBM: one roll per launch (sim RNG), player only, never with the toggle off
	ms.evade = icbm and rng:randf() < M.ICBM_EVADE_P
	if nk == Rules.N_SCATTER then
		scatter_warheads(o, k, from, tile, ms.ft, ms.evade, icbm)
	end
	return ms
end

-- ---------------------------------------------------------------- SAMs (SimNukes._sam_tick / _sam_plan)
local function interceptable(ms: any): boolean
	if ms.mirv_bus then
		return false
	end
	if ms.evade then
		return false -- CUSTOM: ICBM evasion roll: SAMs ignore it entirely
	end
	return Rules.NUKE_INTERCEPT_P[ms.nk] > 0.0
end

local function flight_ticks(ms: any): number
	return math.max(1, ms.ft)
end

local function cur_k(ms: any): number
	return now() - ms.lt
end

local function sam_mark(ms: any)
	if not C.sam_dirty[ms] then
		C.sam_dirty[ms] = true
		C.sam_dirty[#C.sam_dirty + 1] = ms
	end
end

-- the tile under the missile at tick k of its flight, along its arc, as that tile's centre
local function traj(ms: any, k: number): vector
	local tr = ms.traj
	if tr == nil then
		local s = st()
		local ft = flight_ticks(ms)
		local arc = ms.arc
		tr = table.create(ft + 1)
		for i = 0, ft do
			local p = Rules.nuke_arc_at(arc, i / ft)
			tr[i + 1] = vcreate(clampi(floor(p.x), 0.0, s.W - 1) + 0.5, clampi(floor(p.y), 0.0, s.H - 1) + 0.5, 0)
		end
		ms.traj = tr
		ms.traj_new = true
		sam_mark(ms)
	end
	local tt = tr :: { vector }
	return tt[clampi(k, 0, #tt - 1) + 1]
end

local function sam_candidates(ms: any, sams: { number })
	ms.sam = true
	ms.refreshed = true
	ms.cand_tick = now() + Rules.SAM_CAND_REFRESH_TICKS
	ms.pf, ms.pf_keys, ms.pk, ms.pk_keys = {}, {}, {}, {}
	sam_mark(ms)
	if ms.evade then
		ms.cands = {}
		return
	end
	local reach = (Rules.SAM_MAX_RANGE_FULL + Rules.NUKE_TARGETABLE_FULL) / R.k_lin
	local r2 = reach * reach
	local c = {}
	local W = st().W
	for _, i in sams do
		if O[i] == ms.o then
			continue
		end
		local p = tpos(T[i], W)
		if dsq(p, ms.to) <= r2 or dsq(p, ms.from) <= r2 then
			c[#c + 1] = { T[i], SER[i], i }
		end
	end
	ms.cands = c
end

local function pf_set(ms: any, key: number, v: number)
	if ms.pf[key] == nil then
		ms.pf_keys[#ms.pf_keys + 1] = key
	end
	ms.pf[key] = v
	sam_mark(ms)
end

local function pk_set(ms: any, key: number, v: number)
	if ms.pk[key] == nil then
		ms.pk_keys[#ms.pk_keys + 1] = key
	end
	ms.pk[key] = v
	sam_mark(ms)
end

local function sam_plan(ms: any, j: number)
	local key = T[j]
	if ms.evade then
		pf_set(ms, key, -1)
		return
	end
	local W = st().W
	local t = now()
	local cur = math.max(0, cur_k(ms))
	local last = flight_ticks(ms)
	local zone = Rules.NUKE_TARGETABLE_FULL / R.k_lin
	local z2 = zone * zone
	local rmax = Rules.SAM_MAX_RANGE_FULL / R.k_lin
	local rmax2 = rmax * rmax
	local sp = tpos(T[j], W)
	local lvl = L[j]
	local up = if nan(UP[j]) then -100000 else UP[j]
	local inc = 0
	local lastd = -1.0
	for k = cur, last - 1 do
		local p = traj(ms, k)
		local d = dsq(sp, p)
		inc = if lastd >= 0.0 and d > lastd then inc + 1 else 0
		lastd = d
		local nt = k - cur
		local rr = R:sam_range_at(lvl, t + nt - up)
		if d <= rr * rr and (dsq(p, ms.to) < z2 or dsq(p, ms.from) < z2) then
			local stk = R:sam_ticks_to(man_v(sp, p))
			if nt >= stk then
				pf_set(ms, key, t + nt - stk)
				pk_set(ms, key, k)
				return
			end
		end
		if inc > 3 and d > rmax2 then
			break
		end
	end
	local kf = last - 1
	if kf >= cur then
		local rf = R:sam_range_at(lvl, t + (last - cur) - up)
		if dsq(sp, ms.to) <= rf * rf then
			local st2 = R:sam_ticks_to(man_v(sp, traj(ms, kf)))
			if kf - cur >= st2 then
				pf_set(ms, key, t + kf - cur - st2)
				pk_set(ms, key, kf)
				return
			end
		end
	end
	pf_set(ms, key, -1)
end

-- Godot's Array.sort_custom (core/templates/sort_array.h SortArray::sort: introsort, then the final insertion
-- sort), so equal keys end in the order Godot leaves them. arr is 0-based [0 .. n - 1].
local function godot_sort(arr: { [number]: any }, n: number, less: (any, any) -> boolean)
	local THRESH = 16
	local function median_of_3(a: any, b: any, c: any): any
		if less(a, b) then
			if less(b, c) then
				return b
			elseif less(a, c) then
				return c
			else
				return a
			end
		elseif less(a, c) then
			return a
		elseif less(b, c) then
			return c
		else
			return b
		end
	end
	local function bitlog(x: number): number
		local k = 0
		while x ~= 1 do
			x = x // 2
			k += 1
		end
		return k
	end
	local function push_heap(first: number, hole: number, top: number, value: any)
		local parent = cdiv(hole - 1, 2)
		while hole > top and less(arr[first + parent], value) do
			arr[first + hole] = arr[first + parent]
			hole = parent
			parent = cdiv(hole - 1, 2)
		end
		arr[first + hole] = value
	end
	local function adjust_heap(first: number, hole: number, len: number, value: any)
		local top = hole
		local second = 2 * hole + 2
		while second < len do
			if less(arr[first + second], arr[first + (second - 1)]) then
				second -= 1
			end
			arr[first + hole] = arr[first + second]
			hole = second
			second = 2 * (second + 1)
		end
		if second == len then
			arr[first + hole] = arr[first + (second - 1)]
			hole = second - 1
		end
		push_heap(first, hole, top, value)
	end
	local function pop_heap3(first: number, last: number, result: number, value: any)
		arr[result] = arr[first]
		adjust_heap(first, 0, last - first, value)
	end
	local function pop_heap(first: number, last: number)
		pop_heap3(first, last - 1, last - 1, arr[last - 1])
	end
	local function sort_heap(first: number, last: number)
		while last - first > 1 do
			pop_heap(first, last)
			last -= 1
		end
	end
	local function make_heap(first: number, last: number)
		if last - first < 2 then
			return
		end
		local len = last - first
		local parent = (len - 2) // 2
		while true do
			adjust_heap(first, parent, len, arr[first + parent])
			if parent == 0 then
				return
			end
			parent -= 1
		end
	end
	local function partial_sort(first: number, last: number, middle: number)
		make_heap(first, middle)
		for i = middle, last - 1 do
			if less(arr[i], arr[first]) then
				pop_heap3(first, middle, i, arr[i])
			end
		end
		sort_heap(first, middle)
	end
	local function partitioner(first: number, last: number, pivot: any): number
		while true do
			while less(arr[first], pivot) do
				first += 1
			end
			last -= 1
			while less(pivot, arr[last]) do
				last -= 1
			end
			if not (first < last) then
				return first
			end
			arr[first], arr[last] = arr[last], arr[first]
			first += 1
		end
	end
	local function introsort(first: number, last: number, depth: number)
		while last - first > THRESH do
			if depth == 0 then
				partial_sort(first, last, last)
				return
			end
			depth -= 1
			local cut = partitioner(first, last, median_of_3(arr[first], arr[first + (last - first) // 2], arr[last - 1]))
			introsort(cut, last, depth)
			last = cut
		end
	end
	local function unguarded_linear_insert(last: number, value: any)
		local nxt = last - 1
		while less(value, arr[nxt]) do
			arr[last] = arr[nxt]
			last = nxt
			nxt -= 1
		end
		arr[last] = value
	end
	local function linear_insert(first: number, last: number)
		local val = arr[last]
		if less(val, arr[first]) then
			for i = last, first + 1, -1 do
				arr[i] = arr[i - 1]
			end
			arr[first] = val
		else
			unguarded_linear_insert(last, val)
		end
	end
	local function insertion_sort(first: number, last: number)
		if first == last then
			return
		end
		for i = first + 1, last - 1 do
			linear_insert(first, i)
		end
	end
	local function unguarded_insertion_sort(first: number, last: number)
		for i = first, last - 1 do
			unguarded_linear_insert(i, arr[i])
		end
	end
	if n > 0 then
		introsort(0, n, bitlog(n) * 2)
		if n > THRESH then
			insertion_sort(0, THRESH)
			unguarded_insertion_sort(THRESH, n)
		else
			insertion_sort(0, n)
		end
	end
end
M.godot_sort = godot_sort

-- SimNukes._sam_intercept: the bomb is destroyed unless the SAM was lost meanwhile
local function sam_resolve(ms: any): boolean
	if not ms.sam_st then
		return false
	end
	local s = st()
	if ms.evade then
		ms.sam_st = false
		s:ev(E.EV_SAM_CLEAR, ms.mid, 0, 0, 0)
		return false
	end
	local j = resolve(ms.sam_st)
	if j == nil or O[j] == ms.o then
		ms.sam_st = false
		ms.cand_tick = now()
		s:ev(E.EV_SAM_CLEAR, ms.mid, 1, 0, 0)
		return false
	end
	erase_missile(ms)
	stat(ST_SAM_HITS, 1)
	s:ev(E.EV_SAM_HIT, ms.mid, O[j], 0, 0)
	return true
end

local function sam_tick(t: number)
	if #S.missiles == 0 then
		return
	end
	local s = st()
	local W = s.W
	local sams: { number }? = nil
	local fires = {}
	local nf = 0
	for _, ms in S.missiles do
		if ms.sam_st or not interceptable(ms) then
			continue
		end
		if t >= ms.cand_tick then
			if sams == nil then
				local l = {}
				for i = 1, N do
					if K[i] == 4 and B[i] <= 0.0 and not DEAD[i] then
						l[#l + 1] = i
					end
				end
				sams = l
			end
			sam_candidates(ms, sams :: { number })
		end
		for _, c in ms.cands do
			local j = resolve(c)
			if j == nil or B[j] > 0.0 or O[j] == ms.o or s:allied(O[j], ms.o) then
				continue
			end
			local key = T[j]
			local plan = ms.pf[key]
			if plan == nil then
				plan = -3
			end
			if plan == -3 or (plan >= 0 and plan < t) then
				sam_plan(ms, j)
				plan = ms.pf[key]
			end
			if plan >= 0 and plan <= t + 1 then
				local rem = flight_ticks(ms) - cur_k(ms)
				local score = (if ms.nk == Rules.N_HYDROGEN then 70001 else 0)
					+ math.max(0, 200000 - trunc(man_v(tpos(T[j], W), ms.to) * R.k_lin) * 1000)
					+ math.max(0, 10000 - rem * 100)
				fires[nf] = { score, ms, j }
				nf += 1
			end
		end
	end
	if nf > 0 then
		godot_sort(fires, nf, function(a: any, b: any): boolean
			return a[1] > b[1]
		end)
		for q = 0, nf - 1 do
			local f = fires[q]
			local ms, j = f[2], f[3]
			if ms.sam_st or ready_missiles(j) <= 0 then
				continue
			end
			fire_shot(j)
			local k = ms.pk[T[j]]
			local p = traj(ms, k)
			local sp = tpos(T[j], W)
			ms.sam_st = { T[j], SER[j] }
			ms.sam_hit = t + R:sam_ticks_to(man_v(sp, p))
			ms.sam_k = k
			stat(ST_SAM_FIRED, 1)
			s:ev(E.EV_SAM_FIRED, ms.mid, j - 1, k, ms.sam_hit)
		end
	end
	for _, ms in table.clone(S.missiles) do
		if ms.sam_st and t >= ms.sam_hit then
			sam_resolve(ms)
		end
	end
end

-- ---------------------------------------------------------------- MIRV (SimNukes._split_mirv)
local function land_list(): { number }
	local s = st()
	local key = tostring(s) .. ":" .. s.land_total
	if S.land == nil or S.land_key ~= key then
		local l = {}
		local own = s.owner
		for i = 0, s.n - 1 do
			if readi32(own, i * 4) >= 0 then
				l[#l + 1] = i
			end
		end
		S.land = l
		S.land_key = key
	end
	return S.land :: { number }
end

local function mirv_cell(t: number, w: number, gap: number): number
	return ((t // w) // gap) * 65536 + ((t % w) // gap)
end

local function mirv_overlaps(grid: { [number]: { number } }, t: number, gap: number, W: number): boolean
	local gx = (t % W) // gap
	local gy = (t // W) // gap
	for dy = -1, 1 do
		for dx = -1, 1 do
			if gx + dx < 0 or gy + dy < 0 then
				continue
			end
			local cell = grid[(gy + dy) * 65536 + (gx + dx)]
			if cell == nil then
				continue
			end
			for _, c in cell do
				if abs(c % W - t % W) + abs(c // W - t // W) < gap then
					return true
				end
			end
		end
	end
	return false
end

-- Up to MIRV_WARHEADS warheads, aimed at the target's land within MIRV_SPREAD of the aim point and at least
-- 55 full-size tiles (manhattan) apart; each flies the arc from the aim point at warhead speed plus 0..15 ticks.
local function split_mirv(ms: any)
	local s = st()
	local W = s.W
	local own = s.owner
	local o = ms.o
	local to = ms.to
	local to_tile = trunc(to.y) * W + trunc(to.x)
	local tg = ms.tgt_o
	if tg > 0 and s:allied(o, tg) then
		break_alliance(o, tg)
	end
	local spread = R:mirv_spread()
	local spread2 = spread * spread
	local gap = trunc(ceil(55.0 / R.k_lin))
	local grid: { [number]: { number } } = {}
	local targets = { to_tile }
	grid[mirv_cell(to_tile, W, gap)] = { to_tile }
	local land = land_list()
	local nlt = #land
	local tx = to_tile % W
	local ty = to_tile // W
	for _ = 1, 8000 do
		if #targets >= Rules.MIRV_WARHEADS or nlt == 0 then
			break
		end
		local c = land[rng:randi() % nlt + 1]
		if readi32(own, c * 4) ~= tg or tg <= 0 then
			continue
		end
		local dx = c % W - tx
		local dy = c // W - ty
		if dx * dx + dy * dy > spread2 then
			continue
		end
		if mirv_overlaps(grid, c, gap, W) then
			continue
		end
		targets[#targets + 1] = c
		local key = mirv_cell(c, W, gap)
		local cell = grid[key]
		if cell then
			cell[#cell + 1] = c
		else
			grid[key] = { c }
		end
	end
	local from = tc(to_tile, W)
	for _, t in targets do
		local dp = tc(t, W)
		local arc = R:nuke_arc(s.H, from, dp)
		local ft = flight_ticks_x(R:nuke_arc_ticks(arc, Rules.N_WARHEAD), ms.icbm) + rng:randi_range(0, 15)
		local w = spawn_missile(o, 9, Rules.N_WARHEAD, from, dp, ft, arc, C.r_wh)
		w.mirv = true
		w.tgt_o = tg
		w.evade = ms.evade
		w.icbm = ms.icbm
	end
end

local function detonate_missile(ms: any)
	local s = st()
	local W = s.W
	local to = ms.to
	local tile = trunc(to.y) * W + trunc(to.x)
	if tile < 0 or tile >= W * s.H then
		return
	end
	nuke_blast(ms.o, to.x, to.y, ms.r, ms.nk)
	s:ev(E.EV_DETONATE, ms.mid, ms.tgt_o, tile, 0)
end

-- SimNukes.nukes_tick (game/nukes.gd _tick_missiles): SAM hits due, then arrivals (a MIRV bus splits)
local function missiles_tick(t: number)
	for _, ms in table.clone(S.missiles) do
		if ms.sam_st and t >= ms.sam_hit and sam_resolve(ms) then
			continue
		end
		if t < ms.lt + ms.ft then
			continue
		end
		erase_missile(ms)
		if ms.nk == Rules.N_MIRV then
			split_mirv(ms)
		else
			detonate_missile(ms)
		end
	end
end

-- sim/arsenal.gd tick: construction, reload fields, batteries, munitions, SAMs
local function ars_tick(t: number)
	for i = 1, N do
		if B[i] > 0.0 then
			local v = B[i] - 0.1
			B[i] = if v < 0.0 then 0.0 else v
			WM[i] = bit32.bor(WM[i], W_BT)
			if B[i] <= 0.0 then
				activate(i)
			end
			continue
		end
		local k = K[i]
		if k == 4 or k == 5 or k == 14 or k == 15 then
			refresh_cd(i)
		end
	end
	battery_tick(t)
	munitions_tick(t)
	sam_tick(t)
end

-- ---------------------------------------------------------------- call frame
-- the missiles / munitions still in GDScript's lists, in their order (others were removed there)
local function reconcile(list_key: string, map_key: string, ids: buffer, id_field: string)
	local map = (S :: any)[map_key]
	local keep = {}
	local new_map = {}
	for k = 0, buffer.len(ids) - 4, 4 do
		local x = map[readi32(ids, k)]
		if x ~= nil and new_map[x[id_field]] == nil then
			keep[#keep + 1] = x
			new_map[x[id_field]] = x
		end
	end
	;(S :: any)[list_key] = keep
	;(S :: any)[map_key] = new_map
end

local function begin_call(rhi: number, rlo: number, hdr: buffer, rf: buffer, snap: buffer, ext: buffer, rms: buffer,
	rmu: buffer, tkd: buffer)
	rng.shi = rhi
	rng.slo = rlo
	C.tick = readf64(hdr, 0)
	C.player = readf64(hdr, 8)
	C.rapid = readf64(hdr, 16) ~= 0
	C.r_wh = readf64(hdr, 24)
	for i, name in SimAttacks.RULE_FIELDS do
		(R :: any)[name] = readf64(rf, (i - 1) * 8)
	end
	table.clear(C.new_ms)
	table.clear(C.gone_ms)
	table.clear(C.new_mu)
	table.clear(C.gone_mu)
	table.clear(C.sam_dirty)
	table.clear(C.ftiles)
	for k = 1, 7 do
		C.stats[k] = 0
	end
	table.clear(C.tk)
	table.clear(C.td)
	for k = 0, buffer.len(tkd) - 12, 12 do
		local id = readi32(tkd, k)
		C.tk[id] = readi32(tkd, k + 4)
		C.td[id] = readi32(tkd, k + 8)
	end
	read_snap(snap, ext)
	reconcile("missiles", "by_mid", rms, "mid")
	reconcile("munitions", "by_uid", rmu, "uid")
end

local function i32_buf(q: { number }): buffer
	local b = buffer.create(#q * 4)
	for k = 1, #q do
		writei32(b, (k - 1) * 4, q[k])
	end
	return b
end

local function finish(ret: any): any
	local out: { [string]: any } = { rhi = rng.shi, rlo = rng.slo, ret = ret }
	SimAttacks.collect(out)
	-- new missiles: mid, o, k, nk, from x/y, to x/y, lt, ft, r, tgt_o, mirv, mirv_bus, branched, evade, icbm
	local nms = buffer.create(#C.new_ms * M.MS_REC * 8)
	for q, ms in C.new_ms do
		local b = (q - 1) * M.MS_REC * 8
		writef64(nms, b, ms.mid)
		writef64(nms, b + 8, ms.o)
		writef64(nms, b + 16, ms.k)
		writef64(nms, b + 24, ms.nk)
		writef64(nms, b + 32, ms.from.x)
		writef64(nms, b + 40, ms.from.y)
		writef64(nms, b + 48, ms.to.x)
		writef64(nms, b + 56, ms.to.y)
		writef64(nms, b + 64, ms.lt)
		writef64(nms, b + 72, ms.ft)
		writef64(nms, b + 80, ms.r)
		writef64(nms, b + 88, ms.tgt_o)
		writef64(nms, b + 96, if ms.mirv then 1 else 0)
		writef64(nms, b + 104, if ms.mirv_bus then 1 else 0)
		writef64(nms, b + 112, if ms.branched then 1 else 0)
		writef64(nms, b + 120, if ms.evade then 1 else 0)
		writef64(nms, b + 128, if ms.icbm then 1 else 0)
	end
	out.nms = nms
	out.gms = i32_buf(C.gone_ms)
	-- new munitions: uid, nk, o, from tile, to tile, t0, t1, victim
	local nmu = buffer.create(#C.new_mu * M.MU_REC * 8)
	for q, m in C.new_mu do
		local b = (q - 1) * M.MU_REC * 8
		writef64(nmu, b, m.uid)
		writef64(nmu, b + 8, m.nk)
		writef64(nmu, b + 16, m.o)
		writef64(nmu, b + 24, m.from)
		writef64(nmu, b + 32, m.tile)
		writef64(nmu, b + 40, m.t0)
		writef64(nmu, b + 48, m.t1)
		writef64(nmu, b + 56, m.victim)
	end
	out.nmu = nmu
	out.gmu = i32_buf(C.gone_mu)
	-- SAM state of missiles it changed: mid, flags (1 candidates refreshed, 2 trajectory made), cand_tick,
	-- candidate count + snapshot indices (when refreshed), plan_fire count + (key, value)..., plan_k the same
	local sq: { number } = {}
	for _, ms in ipairs(C.sam_dirty) do
		sq[#sq + 1] = ms.mid
		sq[#sq + 1] = (if ms.refreshed then 1 else 0) + (if ms.traj_new then 2 else 0)
		sq[#sq + 1] = ms.cand_tick
		if ms.refreshed then
			sq[#sq + 1] = #ms.cands
			for _, c in ms.cands do
				sq[#sq + 1] = c[3] - 1
			end
		else
			sq[#sq + 1] = 0
		end
		sq[#sq + 1] = #ms.pf_keys
		for _, key in ms.pf_keys do
			sq[#sq + 1] = key
			sq[#sq + 1] = ms.pf[key]
		end
		sq[#sq + 1] = #ms.pk_keys
		for _, key in ms.pk_keys do
			sq[#sq + 1] = key
			sq[#sq + 1] = ms.pk[key]
		end
		ms.refreshed = false
		ms.traj_new = false
	end
	local sb = buffer.create(#sq * 8)
	for k = 1, #sq do
		writef64(sb, (k - 1) * 8, sq[k])
	end
	out.sam = sb
	-- structure writes: index, mask, then per set bit in order: bt, cd, cmax, next_fire, hp, level, shots (n, ...)
	local wq: { number } = {}
	for i = 1, N do
		local m = WM[i]
		if m == 0 then
			continue
		end
		local mm = 0
		if bit32.band(m, W_BT) ~= 0 and B[i] ~= B0[i] then
			mm += W_BT
		end
		if bit32.band(m, W_CD) ~= 0 and CD[i] ~= CD0[i] then
			mm += W_CD
		end
		if bit32.band(m, W_CM) ~= 0 and CM[i] ~= CM0[i] then
			mm += W_CM
		end
		if bit32.band(m, W_NF) ~= 0 and NF[i] ~= NF0[i] then
			mm += W_NF
		end
		if bit32.band(m, W_HP) ~= 0 and HP[i] ~= HP0[i] then
			mm += W_HP
		end
		if bit32.band(m, W_LV) ~= 0 and L[i] ~= L0[i] then
			mm += W_LV
		end
		if SHW[i] then
			mm += W_SH
		end
		if mm == 0 then
			continue
		end
		wq[#wq + 1] = i - 1
		wq[#wq + 1] = mm
		if bit32.band(mm, W_BT) ~= 0 then
			wq[#wq + 1] = B[i]
		end
		if bit32.band(mm, W_CD) ~= 0 then
			wq[#wq + 1] = CD[i]
		end
		if bit32.band(mm, W_CM) ~= 0 then
			wq[#wq + 1] = CM[i]
		end
		if bit32.band(mm, W_NF) ~= 0 then
			wq[#wq + 1] = NF[i]
		end
		if bit32.band(mm, W_HP) ~= 0 then
			wq[#wq + 1] = HP[i]
		end
		if bit32.band(mm, W_LV) ~= 0 then
			wq[#wq + 1] = L[i]
		end
		if bit32.band(mm, W_SH) ~= 0 then
			local sh = SH[i] :: { number }
			wq[#wq + 1] = #sh
			for _, v in sh do
				wq[#wq + 1] = v
			end
		end
	end
	local wb = buffer.create(#wq * 8)
	for k = 1, #wq do
		writef64(wb, (k - 1) * 8, wq[k])
	end
	out.sw = wb
	local stb = buffer.create(7 * 8)
	for k = 1, 7 do
		writef64(stb, (k - 1) * 8, C.stats[k])
	end
	out.stats = stb
	out.ft = i32_buf(C.ftiles)
	return SimState.take(out)
end

-- The nations (troops, alliances, ...) for the next call: SimState.nat_all's arguments. sim/arsenal.gd sends them
-- before a call that can read them (missiles or munitions in flight, a battery about to aim, launches, blasts).
function M.world(n: number, troops: buffer, gold: buffer, alive: buffer, kind: buffer, team_mode: boolean, team: buffer,
	left: buffer, allies: buffer, traitor: buffer, defs: buffer, fallout_count: number, land_total: number): boolean
	SimState.nat_all(st(), n, troops, gold, alive, kind, team_mode, team, left, allies, traitor, defs, fallout_count,
		land_total)
	return true
end

-- One entry for every call from sim/arsenal.gd: op, the sim rng (two uint32 halves), hdr (f64: tick, PLAYER,
-- rapid reload on, warhead radius), the rules fields (SimAttacks.RULE_FIELDS order), the structure snapshot and
-- its EXT block, the missile / munition ids still in GDScript's lists, troop rules per nation (i32 triples id,
-- kind, diff; empty when no warhead lands), then the op's arguments.
function M.call(op: string, rhi: number, rlo: number, hdr: buffer, rf: buffer, snap: buffer, ext: buffer, rms: buffer,
	rmu: buffer, tkd: buffer, a1: any, a2: any, a3: any, a4: any, a5: any, a6: any, a7: any, a8: any): any
	begin_call(rhi, rlo, hdr, rf, snap, ext, rms, rmu, tkd)
	local t = now()
	if op == "tick" then
		ars_tick(t)
		return finish(true)
	elseif op == "missiles" then
		missiles_tick(t)
		return finish(true)
	elseif op == "launch" then
		-- o, k, nk, silo tile, target tile, outer radius, icbm, victim
		local ms = launch(a1, a2, a3, a4, a5, a6, a7, a8)
		return finish(ms.mid)
	elseif op == "break" then
		-- o, centre x, centre y, radius, nk
		return finish(i32_buf(break_nuked_alliances(a1, a2, a3, a4, a5)))
	elseif op == "munition" then
		-- nk, o, from tile, to tile
		local m = spawn_munition(a1, a2, a3, a4)
		return finish(m.uid)
	elseif op == "blast" then
		-- o, centre x, centre y, radius, nk
		local order, lost, fn = nuke_blast(a1, a2, a3, a4, a5)
		local q = {}
		for _, ow in order do
			q[#q + 1] = ow
			q[#q + 1] = lost[ow]
		end
		q[#q + 1] = fn
		return finish(i32_buf(q))
	end
	error("SimArsenal.call: unknown op " .. tostring(op))
end

-- tests: the Godot sort on (key, id) pairs: keys f64 -> ids (i32) in sorted order, descending keys
function M.sort_check(keys: buffer): buffer
	local n = buffer.len(keys) // 8
	local arr = {}
	for i = 0, n - 1 do
		arr[i] = { readf64(keys, i * 8), i }
	end
	godot_sort(arr, n, function(a: any, b: any): boolean
		return a[1] > b[1]
	end)
	local out = buffer.create(n * 4)
	for i = 0, n - 1 do
		writei32(out, i * 4, arr[i][2])
	end
	return out
end

-- tests: the customs' constants (tests/test_luau_arsenal.gd checks they equal game/nukes.gd and game/state.gd)
function M.customs(): any
	return { nuke_speed_x = M.NUKE_SPEED_X, icbm_speed_x = M.ICBM_SPEED_X, icbm_evade_p = M.ICBM_EVADE_P }
end

-- tests: the missiles Luau holds (mid list in order) and one missile's SAM fields
function M.debug(): any
	local ids = {}
	for _, ms in S.missiles do
		ids[#ids + 1] = ms.mid
	end
	local mu = {}
	for _, m in S.munitions do
		mu[#mu + 1] = m.uid
	end
	return { missiles = i32_buf(ids), munitions = i32_buf(mu) }
end

return M
