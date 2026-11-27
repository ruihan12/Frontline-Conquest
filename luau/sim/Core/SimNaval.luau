--!strict
-- SimNaval: trade ships (docs/LUAU_PORT.md, Step 5d2). Transliterated from this project's sim/naval.gd
-- (_ports_tick, _pick_partner, _refresh_partners, _trade_path, hostile), which ports upstream RoWorld
-- SimNaval.luau ports_tick (AGPL-3.0, lukechatton/roworld): every 10 ticks each finished port rolls `level` times
-- against tradeShipSpawnRate with a pity timer, picks a partner port of a non-hostile owner on the same water body,
-- sails, and pays tradeShipGold(tiles sailed) to both owners (the sailing and the pay stay in GDScript for now).
--
-- The ports stay GDScript Dictionaries: each call sends the ports in game.structs order with their trade fields
-- (slot, rej, partners, ptick, water, body) and gets back the fields it changed and the new trade ships, in the
-- order the GDScript made them. Luau keeps the trade route cache (trade_cache) and searches through Core/SimNav.
-- Transports (tokens, landing), water bodies and the boats themselves are still GDScript.
local Rules = require("./Rules")
local SimState = require("./SimState")
local SimAttacks = require("./SimAttacks")
local SimArsenal = require("./SimArsenal")
local SimNav = require("./SimNav")
local GodotRng = require("./GodotRng")

local readf64, writef64, readi32 = buffer.readf64, buffer.writef64, buffer.readi32
local abs, min, floor = math.abs, math.min, math.floor

local M = {}

local KEYM = 67108864 -- 2^26: tile pair key a * KEYM + b
local R = Rules.new(1.0)
local rng = GodotRng.new(0, true)

type Port = {
	idx: number, -- place in game.structs
	tile: number,
	o: number,
	level: number,
	bt: number,
	has: boolean, -- p.has("slot")
	slot: number,
	rej: number,
	ptick: number,
	water: number,
	body: number,
	partners: { number },
	init: boolean, -- the fields were created by this call
	dirty: boolean,
}

local C = {
	nav = -1,
	body = buffer.create(0),
	W = 0,
	ts = 1.0,
	path_budget = 0,
	gen = -1,
	hostile_used = false,
}
local trade_cache: { [number]: { number } } = {}
local trade_n = 0
local hp: { [number]: boolean } = {}
local ports: { Port } = {}
local port_at: { [number]: Port } = {}
local new_tr: { number } = {}

local function alive(id: number): boolean
	return (SimState.cur :: any).alive[id] == true
end

local function allied(a: number, b: number): boolean
	return SimState.allied(SimState.cur :: any, a, b)
end

-- sim/naval.gd hostile: embargo (is_embargoed is always false in this game) or a live attack either way. The
-- attack pairs are GDScript's per-tick cache (or what it would build now); the facade commits the cache when
-- Luau used it, so later GDScript callers this tick see the pairs from the same moment.
local function hostile(a: number, b: number): boolean
	C.hostile_used = true
	return hp[a * 65536 + b] == true
end

-- sim/naval.gd water_next_to (W, E, N, S; body from compute_bodies)
local function water_next_to(t: number): number
	local W = C.W
	local body = C.body
	local n = buffer.len(body) // 4
	local x = t % W
	for _, j in { if x > 0 then t - 1 else -1, if x < W - 1 then t + 1 else -1, t - W, t + W } do
		if j >= 0 and j < n and readi32(body, j * 4) > 0 then
			return j
		end
	end
	return -1
end

local EMPTY: { number } = {}

local function _trade_path(a: Port, b: Port): { number }
	local key = a.tile * KEYM + b.tile
	local hit = trade_cache[key]
	if hit then
		return hit
	end
	local rk = b.tile * KEYM + a.tile
	local rhit = trade_cache[rk]
	if rhit then
		local n = #rhit // 2
		local rv: { number } = table.create(n * 2)
		for k = 1, n do
			rv[2 * k - 1] = rhit[2 * (n - k) + 1]
			rv[2 * k] = rhit[2 * (n - k) + 2]
		end
		trade_cache[key] = rv
		trade_n += 1
		return rv
	end
	if C.path_budget <= 0 then
		return EMPTY
	end
	C.path_budget -= 1
	local pts, deferred = SimNav.water_path_px_t(C.nav, a.tile, b.tile, C.ts, false)
	if #pts == 0 and deferred then
		return pts -- over this tick's budget: retry, don't cache
	end
	trade_cache[key] = pts
	trade_n += 1
	if trade_n > 2000 then
		table.clear(trade_cache)
		trade_n = 0
	end
	return pts
end

local function _refresh_partners(p: Port, t: number)
	p.ptick = t
	p.dirty = true
	local keep: { number } = {}
	for _, qt in p.partners do
		local q = port_at[qt]
		if q ~= nil and q.o ~= p.o and alive(q.o) then
			table.insert(keep, qt)
		end
	end
	local W = C.W
	local dists: { [number]: any } = {}
	local nd = 0
	for _, q in ports do
		if q.bt > 0.0 or q.o == p.o or not alive(q.o) then
			continue
		end
		if not q.has then
			continue
		end
		if q.body ~= p.body or q.water < 0 or hostile(p.o, q.o) then
			continue
		end
		dists[nd] = { (abs(p.tile % W - q.tile % W) + abs(p.tile // W - q.tile // W)) * R.k_lin, q }
		nd += 1
	end
	SimArsenal.godot_sort(dists, nd, function(x: any, y: any): boolean
		return x[1] < y[1]
	end)
	local n = nd
	-- clampi(n / 3, mini(4, n), n)
	local lo, hi = min(4, n), n
	local v = n // 3
	local bonus_n = if v < lo then lo elseif v > hi then hi else v
	local cands: { Port } = {}
	local weights: { number } = {}
	local total = 0.0
	for i = 0, n - 1 do
		local q: Port = dists[i][2]
		local far = dists[i][1] >= Rules.TRADE_SHORT_RANGE_FULL
		local lv = q.level
		local w = lv
		if far and i < bonus_n then
			w += lv
		end
		if far and allied(p.o, q.o) then
			w += lv
		end
		table.insert(cands, q)
		table.insert(weights, w)
		total += w
	end
	local partners = table.clone(keep)
	for _k = 1, 8 - #keep do
		if #cands == 0 then
			break
		end
		local r = rng:randf() * total
		local pick = cands[#cands]
		for i = 1, #cands do
			r -= weights[i]
			if r <= 0.0 then
				pick = cands[i]
				break
			end
		end
		if table.find(partners, pick.tile) == nil then
			table.insert(partners, pick.tile)
		end
	end
	p.partners = partners
end

local function _pick_partner(p: Port, t: number): Port?
	if #p.partners == 0 or t - p.ptick > 1200 then
		_refresh_partners(p, t)
	end
	local n = #p.partners
	for _k = 1, 3 do
		if n == 0 then
			return nil
		end
		local q = port_at[p.partners[rng:randi() % n + 1]] -- partners hold tiles
		if q == nil or q.o == p.o or not alive(q.o) or hostile(p.o, q.o) then
			continue
		end
		return q
	end
	p.ptick = -100000
	p.dirty = true
	return nil
end

local function _ports_tick(t: number, n_trade: number)
	local slot = t % 10
	local body = C.body
	for _, p in ports do
		if p.bt > 0.0 then
			continue
		end
		if not p.has then
			p.slot = rng:randi() % 10
			p.rej = 0
			p.partners = {}
			p.ptick = -100000
			p.water = water_next_to(p.tile)
			p.body = if p.water >= 0 then readi32(body, p.water * 4) else 0
			p.has = true
			p.init = true
			p.dirty = true
		end
		if p.slot ~= slot or p.water < 0 or not alive(p.o) then
			continue
		end
		local hit = false
		for _l = 1, min(p.level, 1000) do
			if rng:randi() % R:trade_spawn_rate(p.rej, n_trade) == 0 then
				hit = true
				break
			end
			p.rej += 1
			p.dirty = true
		end
		if not hit then
			continue
		end
		p.rej = 0
		p.dirty = true
		local dst = _pick_partner(p, t)
		if dst == nil then
			continue
		end
		local pts = _trade_path(p, dst)
		if #pts < 4 then
			if C.path_budget <= 0 then
				p.rej += 1
			end
			continue
		end
		table.insert(new_tr, p.idx)
		table.insert(new_tr, dst.idx)
		table.insert(new_tr, #pts // 2)
		for _, v in pts do
			table.insert(new_tr, v)
		end
		n_trade += 1
	end
end

-- hdr (f64): tick, nav handle, path_budget, n_trade (game.traders.size()), TS, W, trade cache generation
-- rf: the rules fields (SimAttacks.RULE_FIELDS order). ports (f64 per port in game.structs order): idx, tile, o,
-- level, bt, has_slot, slot, rej, ptick, water, body, n_partners, partner tiles... body: i32 water body per tile
-- (sent when the map changes, else an empty buffer). hpairs: i32 attack pair keys a * 65536 + b.
-- -> { rhi, rlo, pw = changed port fields (f64: idx, init, slot, rej, ptick, water, body, n, partners...),
--      nt = new trade ships (f64: src idx, dst idx, n points, x, y ...), hu = the attack pairs were read,
--      pb = path_budget left }
function M.ports_tick(rhi: number, rlo: number, hdr: buffer, rf: buffer, snap: buffer, body: buffer, hpairs: buffer): any
	rng.shi = rhi
	rng.slo = rlo
	local t = readf64(hdr, 0)
	C.nav = readf64(hdr, 8)
	C.path_budget = readf64(hdr, 16)
	local n_trade = readf64(hdr, 24)
	C.ts = readf64(hdr, 32)
	C.W = readf64(hdr, 40)
	local gen = readf64(hdr, 48)
	if gen ~= C.gen then
		C.gen = gen
		table.clear(trade_cache)
		trade_n = 0
	end
	if buffer.len(body) > 0 then
		C.body = body
	end
	for i, name in SimAttacks.RULE_FIELDS do
		(R :: any)[name] = readf64(rf, (i - 1) * 8)
	end
	table.clear(hp)
	for k = 0, buffer.len(hpairs) - 4, 4 do
		hp[readi32(hpairs, k)] = true
	end
	C.hostile_used = false
	table.clear(ports)
	table.clear(port_at)
	table.clear(new_tr)
	local k = 0
	local len = buffer.len(snap)
	while k < len do
		local np = readf64(snap, k + 88)
		local partners: { number } = table.create(np)
		for j = 1, np do
			partners[j] = readf64(snap, k + 88 + j * 8)
		end
		local p: Port = {
			idx = readf64(snap, k),
			tile = readf64(snap, k + 8),
			o = readf64(snap, k + 16),
			level = readf64(snap, k + 24),
			bt = readf64(snap, k + 32),
			has = readf64(snap, k + 40) ~= 0,
			slot = readf64(snap, k + 48),
			rej = readf64(snap, k + 56),
			ptick = readf64(snap, k + 64),
			water = readf64(snap, k + 72),
			body = readf64(snap, k + 80),
			partners = partners,
			init = false,
			dirty = false,
		}
		table.insert(ports, p)
		port_at[p.tile] = p
		k += 96 + np * 8
	end
	_ports_tick(t, n_trade)
	local pw: { number } = {}
	for _, p in ports do
		if not p.dirty then
			continue
		end
		table.insert(pw, p.idx)
		table.insert(pw, if p.init then 1 else 0)
		table.insert(pw, p.slot)
		table.insert(pw, p.rej)
		table.insert(pw, p.ptick)
		table.insert(pw, p.water)
		table.insert(pw, p.body)
		table.insert(pw, #p.partners)
		for _, v in p.partners do
			table.insert(pw, v)
		end
	end
	local function f64s(q: { number }): buffer
		local b = buffer.create(#q * 8)
		for i, v in q do
			writef64(b, (i - 1) * 8, v)
		end
		return b
	end
	return { rhi = rng.shi, rlo = rng.slo, pw = f64s(pw), nt = f64s(new_tr), hu = C.hostile_used, pb = C.path_budget }
end

function M.cache_size(): number
	return trade_n
end

return M
