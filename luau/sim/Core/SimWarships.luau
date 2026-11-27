--!strict
-- SimWarships: warships, their shells and the defense posts' shells (docs/LUAU_PORT.md, Step 5d3). Transliterated
-- line for line from this project's sim/warships.gd, which ports upstream RoWorld SimWarships.luau (AGPL-3.0,
-- lukechatton/roworld): targeting (transport > warship > trade ship), shells, veterancy, healing, the repair
-- retreat, trade ship captures and the posts' shells. Steering goes through Core/SimNav (sim/nav.gd steer).
--
-- Nothing is kept between ticks: the GDScript side keeps the ships, the shells, the target table, the posts' state
-- and the stats, sends them each tick and applies what comes back (sim/warships.gd, Luau part). Inside a tick the
-- work runs in a coroutine: where the GDScript calls game.ai_ship_loss (after a sunk transport, after a capture),
-- the tick stops, hands back everything done so far, and goes on after the GDScript has run the AI's answer
-- (M.resume with the ships and the rng as they are then).
--
-- Vector2 is float32 in Godot: positions, routes and every Vector2 operation are rounded like Godot's.
local Rules = require("./Rules")
local SimState = require("./SimState")
local SimAttacks = require("./SimAttacks")
local SimNav = require("./SimNav")
local GodotRng = require("./GodotRng")

local readf64, writef64, readi32 = buffer.readf64, buffer.writef64, buffer.readi32
local abs, min, max, floor, sqrt = math.abs, math.min, math.max, math.floor, math.sqrt

local M = {}

local R = Rules.new(1.0)
local rng = GodotRng.new(0, true)
local f32 = GodotRng.f32

local WATER = -1

-- ---------------------------------------------------------------------------------------------------------------
-- float32 Vector2 helpers (Godot 4.5 Vector2, real_t = float)
-- ---------------------------------------------------------------------------------------------------------------
local function dist2(ax: number, ay: number, bx: number, by: number): number
	local dx, dy = f32(ax - bx), f32(ay - by)
	return f32(f32(dx * dx) + f32(dy * dy))
end

local function dist(ax: number, ay: number, bx: number, by: number): number
	return f32(sqrt(dist2(ax, ay, bx, by)))
end

local function lerp2(ax: number, ay: number, bx: number, by: number, w: number): (number, number)
	local w32 = f32(w)
	return f32(ax + f32(f32(bx - ax) * w32)), f32(ay + f32(f32(by - ay) * w32))
end

local function clampf(x: number, a: number, b: number): number
	if x < a then
		return a
	elseif x > b then
		return b
	end
	return x
end

local function clampi(x: number, a: number, b: number): number
	if x < a then
		return a
	elseif x > b then
		return b
	end
	return x
end

-- GDScript int(float): toward zero
local function trunc(x: number): number
	if x >= 0 then
		return floor(x)
	end
	return -floor(-x)
end

-- GDScript signf
local function signf(x: number): number
	if x > 0 then
		return 1.0
	elseif x < 0 then
		return -1.0
	end
	return 0.0
end

-- ---------------------------------------------------------------------------------------------------------------
-- the tick's data
-- ---------------------------------------------------------------------------------------------------------------
type Port = { k: number, tile: number, o: number, level: number, cur: boolean, fin: boolean }
type Ship = {
	uid: number,
	o: number,
	px: number,
	py: number,
	tx: number,
	ty: number,
	pax: number,
	pay: number,
	hp: number,
	max_hp: number,
	vet: number,
	vet_p: number,
	last_shot: number,
	state: number,
	port: Port?,
	heal_rem: number,
	manual: number,
	near_port: boolean,
	np_tick: number,
	has_r: boolean,
	has_t: boolean,
	has_i: boolean,
	route: { number }, -- x, y pairs (float32), 1-based
	route_new: boolean,
	ntx: number,
	nty: number,
	nav_i: number,
	shelled: { [number]: boolean },
	shelled_l: { number },
	inlist: boolean,
}
type Boat = { id: number, a: number, uid: number, bx: number, by: number, x: number, y: number, inlist: boolean }
type Trader = {
	id: number,
	o: number,
	dst_o: number,
	d: number,
	orig: number,
	sailed: number,
	pts: { number }, -- px x, y pairs, 1-based
	cum: { number },
	pos_ok: boolean,
	x: number,
	y: number,
	inlist: boolean,
}
type Target = { kind: number, id: number } -- kind 0 boat (id), 1 warship (uid), 2 trade ship (id)
type Shell = {
	src: number, -- place in the GDScript list, -1 new
	shooter: number, -- warship uid, -1 a post
	post_k: number, -- the post (place in the posts list) for a new post shell
	o: number,
	tkind: number,
	tid: number,
	t1: number,
	dmg: number,
	fx: number,
	fy: number,
	t0: number,
	post: boolean,
}

local KB, KW, KT = 0, 1, 2

local C = {
	t = 0,
	nav = -1,
	TS = 1.0,
	W = 0,
	H = 0,
	PLAYER = 1,
	boat_speed = 1.0,
	warship_speed = 1.0,
	posts_shoot = true,
	next_tid = 1,
	cap_msg = -1000,
}
local ships: { Ship } = {}
local ship_by_uid: { [number]: Ship } = {}
local boats: { Boat } = {}
local boat_by_id: { [number]: Boat } = {}
local traders: { Trader } = {}
local trader_by_id: { [number]: Trader } = {}
-- the trade ships come over only when a ship needs them this tick (a trade target, a scan that reaches them):
-- most ticks no ship does, and there are hundreds of them
local tr_loaded = false
local need_tr = false
local ports: { Port } = {} -- the call's port table (finished ports in game.structs order, then the others ships hold)
local posts: { { tile: number, o: number, k: number } } = {}
local shells: { Shell } = {}
local tref: { [number]: Target } = {}
local tref_order: { number } = {}
local post_last: { [number]: number } = {}
local pl_ch: { number } = {} -- (tile, tick) of each post that shelled this call, in order
local post_shelled: { [number]: boolean } = {}
local post_shelled_new: { number } = {}
local stats = { shots = 0, sunk_transports = 0, sunk_warships = 0, captures = 0, post_shots = 0, rerouted = 0 }
local ev: { number } = {}
local new_tr: { number } = {}
local pts_cache: { [number]: { pts: { number }, cum: { number } } } = {}
local co: thread? = nil
local yield_req: { number }? = nil

local function alive(id: number): boolean
	return (SimState.cur :: any).alive[id] == true
end

local function allied(a: number, b: number): boolean
	return SimState.allied(SimState.cur :: any, a, b)
end

local function owner_at(t: number): number
	return readi32((SimState.cur :: any).owner, t * 4)
end

local function body_buf(): buffer
	return (SimNav.nav(C.nav) :: any).body
end

-- sim_naval.body[t] (0 past the end)
local function body_of_tile(t: number): number
	local b = body_buf()
	if t < 0 or t >= buffer.len(b) // 4 then
		return 0
	end
	return readi32(b, t * 4)
end

local function tile_of(x: number, y: number): number
	return clampi(trunc(y), 0, C.H - 1) * C.W + clampi(trunc(x), 0, C.W - 1)
end

local function body_at(x: number, y: number): number
	return body_of_tile(tile_of(x, y))
end

-- main._is_water
local function is_water(x: number, y: number): boolean
	local xi, yi = trunc(x), trunc(y)
	return xi >= 0 and yi >= 0 and xi < C.W and yi < C.H and owner_at(yi * C.W + xi) == WATER
end

-- sim_naval.coast_body: the water body a coastal land tile touches (W, E, N, S), 0 if none
local function coast_body(t: number): number
	local W = C.W
	local b = body_buf()
	local n = buffer.len(b) // 4
	local x = t % W
	for _, j in { if x > 0 then t - 1 else -1, if x < W - 1 then t + 1 else -1, t - W, t + W } do
		if j >= 0 and j < n then
			local v = readi32(b, j * 4)
			if v > 0 then
				return v
			end
		end
	end
	return 0
end

-- sim_naval.water_next_to (W, E, N, S)
local function water_next_to(t: number): number
	local W = C.W
	local b = body_buf()
	local n = buffer.len(b) // 4
	local x = t % W
	for _, j in { if x > 0 then t - 1 else -1, if x < W - 1 then t + 1 else -1, t - W, t + W } do
		if j >= 0 and j < n and readi32(b, j * 4) > 0 then
			return j
		end
	end
	return -1
end

local function ports_of(o: number): { Port }
	local out: { Port } = {}
	for _, p in ports do
		if p.fin and p.o == o then
			table.insert(out, p)
		end
	end
	return out
end

local function push(...: number)
	for i = 1, select("#", ...) do
		table.insert(ev, (select(i, ...)))
	end
end

-- events (f64 stream): see sim/warships.gd _lapply
local E_SFX_SHOT, E_SFX_LOST, E_NOTE, E_FX, E_BOAT_GONE, E_WS_GONE, E_TR_GONE, E_TR_NEW = 1, 2, 3, 4, 5, 6, 7, 8
-- notes: 1 sank your transport (s.o), 2 sank a transport from (bt.a), 3 sank your warship (s.o), 4 sank a warship
-- from (o2.o), 5 veterancy (vet), 6 capturing your trade ships (ws.o), 7 captured a trade ship from (victim)

local function erase_ship(ws: Ship)
	ws.inlist = false
	local i = table.find(ships, ws)
	if i then
		table.remove(ships, i)
	end
	push(E_WS_GONE, ws.uid)
end

local function erase_boat(bt: Boat)
	bt.inlist = false
	local i = table.find(boats, bt)
	if i then
		table.remove(boats, i)
	end
	push(E_BOAT_GONE, bt.id)
end

local function erase_trader(tr: Trader)
	tr.inlist = false
	local i = table.find(traders, tr)
	if i then
		table.remove(traders, i)
	end
	push(E_TR_GONE, tr.id)
end

local function tref_set(uid: number, tg: Target)
	if tref[uid] == nil then
		table.insert(tref_order, uid)
	end
	tref[uid] = tg
end

local function tref_erase(uid: number)
	if tref[uid] ~= nil then
		tref[uid] = nil
		local i = table.find(tref_order, uid)
		if i then
			table.remove(tref_order, i)
		end
	end
end

-- main._boat_pos(bt)[0] (px) for a trade ship
local function path_pos(tr: Trader): (number, number)
	if tr.pos_ok then
		return tr.x, tr.y
	end
	local cum, pts, d = tr.cum, tr.pts, tr.d
	local n = #cum
	local m = 1 -- 0-based index as in GDScript
	while m < n - 1 and cum[m + 1] < d do
		m += 1
	end
	local seg = max(0.001, cum[m + 1] - cum[m])
	local ax, ay = pts[2 * m - 1], pts[2 * m]
	local bx, by = pts[2 * m + 1], pts[2 * m + 2]
	local x, y = lerp2(ax, ay, bx, by, clampf((d - cum[m]) / seg, 0, 1))
	local ts = f32(C.TS)
	tr.x, tr.y = f32(x / ts), f32(y / ts)
	tr.pos_ok = true
	return tr.x, tr.y
end

-- traders (f64 each): id, o, dst o, d, orig, sailed. tpts: points of trade ships Luau has not seen (f64: id, n,
--   x, y ..., cum ...)
local function load_traders(tb: buffer, tpts: buffer)
	local k = 0
	while k < buffer.len(tpts) do
		local id = readf64(tpts, k)
		local n = readf64(tpts, k + 8)
		k += 16
		local pts: { number } = table.create(n * 2)
		for j = 0, n * 2 - 1 do
			pts[j + 1] = readf64(tpts, k + j * 8)
		end
		k += n * 16
		local cum: { number } = table.create(n)
		for j = 0, n - 1 do
			cum[j + 1] = readf64(tpts, k + j * 8)
		end
		k += n * 8
		pts_cache[id] = { pts = pts, cum = cum }
	end
	table.clear(traders)
	table.clear(trader_by_id)
	local keep: { [number]: { pts: { number }, cum: { number } } } = {}
	k = 0
	while k < buffer.len(tb) do
		local id = readf64(tb, k)
		local pc = pts_cache[id]
		assert(pc ~= nil, "SimWarships: no points for trade ship " .. tostring(id))
		keep[id] = pc
		local tr: Trader = {
			id = id, o = readf64(tb, k + 8), dst_o = readf64(tb, k + 16), d = readf64(tb, k + 24),
			orig = readf64(tb, k + 32), sailed = readf64(tb, k + 40), pts = pc.pts, cum = pc.cum, pos_ok = false,
			x = 0, y = 0, inlist = true,
		}
		table.insert(traders, tr)
		trader_by_id[id] = tr
		k += 48
	end
	pts_cache = keep
	tr_loaded = true
end

-- stops the tick until the GDScript has sent the trade ships (M.resume)
local function need_traders()
	if tr_loaded then
		return
	end
	need_tr = true
	coroutine.yield()
	assert(tr_loaded, "SimWarships: the trade ships did not come")
end

local function unit_pos(tg: Target): (number, number)
	if tg.kind == KB then
		local bt = boat_by_id[tg.id]
		return bt.x, bt.y
	elseif tg.kind == KW then
		local w = ship_by_uid[tg.id]
		return w.px, w.py
	end
	need_traders()
	return path_pos(trader_by_id[tg.id])
end

local function target_valid(ws: Ship, tg: Target): boolean
	if tg.kind == KB then
		local bt = boat_by_id[tg.id]
		return bt ~= nil and bt.inlist and bt.a ~= ws.o and not allied(bt.a, ws.o)
	elseif tg.kind == KW then
		local w = ship_by_uid[tg.id]
		return w ~= nil and w.inlist and w.o ~= ws.o and not allied(w.o, ws.o)
	end
	need_traders()
	local tr = trader_by_id[tg.id]
	return tr ~= nil and tr.inlist and tr.o ~= ws.o and not allied(tr.o, ws.o)
end

-- ---------------------------------------------------------------------------------------------------------------
-- veterancy
-- ---------------------------------------------------------------------------------------------------------------
local function vet_up(w: Ship)
	if w.vet >= Rules.WARSHIP_MAX_VET then
		return
	end
	w.vet += 1
	w.max_hp = Rules.warship_max_hp(w.vet)
	if w.o == C.PLAYER then
		push(E_NOTE, 5, w.vet)
	end
end

local function vet_progress(w: Ship?, points: number)
	if w == nil or not w.inlist or w.vet >= Rules.WARSHIP_MAX_VET then
		return
	end
	local per = Rules.WARSHIP_VET_TRANSPORTS * Rules.WARSHIP_VET_TRADES
	w.vet_p += points
	while w.vet_p >= per and w.vet < Rules.WARSHIP_MAX_VET do
		w.vet_p -= per
		vet_up(w)
	end
	if w.vet >= Rules.WARSHIP_MAX_VET then
		w.vet_p = 0
	end
end

-- the GDScript runs game.ai_ship_loss(victim, tile, enemy) here (it may move or add warships and draws the rng)
local function ai_ship_loss(victim: number, tile: number, enemy: number)
	-- game/bot_ai.gd returns at once (and draws nothing) for these: no need to stop
	if victim <= 0 or victim == C.PLAYER or enemy == victim or tile < 0 then
		return
	end
	yield_req = { victim, tile, enemy }
	coroutine.yield()
end

-- ---------------------------------------------------------------------------------------------------------------
-- movement (sim/nav.gd steer, sim/warships.gd _move)
-- ---------------------------------------------------------------------------------------------------------------
local function steer(ws: Ship, step: number): boolean
	local W, H = C.W, C.H
	local px, py = ws.px, ws.py
	local tx, ty = ws.tx, ws.ty
	local pt = clampi(trunc(py), 0, H - 1) * W + clampi(trunc(px), 0, W - 1)
	local b = body_of_tile(pt)
	if b == 0 then
		return false
	end
	local route = if ws.has_r then ws.route else {}
	local rtx, rty = if ws.has_t then ws.ntx else -1e9, if ws.has_t then ws.nty else -1e9
	local ri = if ws.has_i then ws.nav_i else 0
	local nr = #route // 2
	if nr == 0 or dist(rtx, rty, tx, ty) > 3.0 or (ri >= nr and dist(px, py, tx, ty) > 0.01) then
		local tt = clampi(trunc(ty), 0, H - 1) * W + clampi(trunc(tx), 0, W - 1)
		if body_of_tile(tt) ~= b then
			local alt = SimNav.water_next_to(C.nav, tt, b)
			if alt < 0 then
				return false
			end
			tt = alt
			tx, ty = f32(tt % W + 0.5), f32(tt // W + 0.5)
			ws.tx, ws.ty = tx, ty
		end
		local corners = SimNav.find_route_t(C.nav, pt, tt, false)
		if #corners == 0 then
			return false
		end
		route = table.create(#corners * 2 + 2)
		for _, c in corners do
			table.insert(route, f32(c % W + 0.5))
			table.insert(route, f32(c // W + 0.5))
		end
		table.insert(route, tx)
		table.insert(route, ty)
		ws.route = route
		ws.route_new = true
		ws.has_r = true
		ws.has_t = true
		ws.ntx, ws.nty = tx, ty
		ws.has_i = true
		ws.nav_i = 0
		nr = #route // 2
	end
	local i = if ws.has_i then ws.nav_i else 0
	local left = step
	while left > 0.0 and i < nr do
		local wx, wy
		if i == nr - 1 then
			wx, wy = tx, ty
		else
			wx, wy = route[2 * i + 1], route[2 * i + 2]
		end
		local d = dist(px, py, wx, wy)
		if d <= left then
			if body_of_tile(clampi(trunc(wy), 0, H - 1) * W + clampi(trunc(wx), 0, W - 1)) ~= b then
				break
			end
			px, py = wx, wy
			left -= d
			i += 1
		else
			-- pos + (wp - pos) / d * left
			local d32, l32 = f32(d), f32(left)
			local nx = f32(px + f32(f32(f32(wx - px) / d32) * l32))
			local ny = f32(py + f32(f32(f32(wy - py) / d32) * l32))
			if body_of_tile(clampi(trunc(ny), 0, H - 1) * W + clampi(trunc(nx), 0, W - 1)) ~= b then
				ws.has_r = false
				ws.route = {}
				break
			end
			px, py = nx, ny
			left = 0.0
		end
	end
	ws.px, ws.py = px, py
	ws.has_i = true
	ws.nav_i = i
	return true
end

local function move(ws: Ship, step: number)
	step *= C.warship_speed
	if steer(ws, step) then
		return
	end
	local dx, dy = f32(ws.tx - ws.px), f32(ws.ty - ws.py)
	local len = f32(sqrt(f32(f32(dx * dx) + f32(dy * dy))))
	if len <= step then
		if is_water(ws.tx, ws.ty) then
			ws.px, ws.py = ws.tx, ws.ty
		end
		return
	end
	-- d.normalized() * step
	local l = f32(f32(dx * dx) + f32(dy * dy))
	local nx, ny = dx, dy
	if l ~= 0 then
		l = f32(sqrt(l))
		nx, ny = f32(dx / l), f32(dy / l)
	end
	local s32 = f32(step)
	local npx, npy = f32(ws.px + f32(nx * s32)), f32(ws.py + f32(ny * s32))
	if is_water(npx, npy) then
		ws.px, ws.py = npx, npy
	else
		-- slide along the coast, else give up this course
		local a1x = f32(ws.px + f32(signf(dx) * step))
		local a1y = ws.py -- + 0.0
		local a2x = ws.px
		local a2y = f32(ws.py + f32(signf(dy) * step))
		if abs(dx) > abs(dy) and is_water(a1x, a1y) then
			ws.px, ws.py = a1x, a1y
		elseif is_water(a2x, a2y) then
			ws.px, ws.py = a2x, a2y
		elseif is_water(a1x, a1y) then
			ws.px, ws.py = a1x, a1y
		else
			ws.tx, ws.ty = ws.px, ws.py
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------
-- the ship's tick
-- ---------------------------------------------------------------------------------------------------------------
local function heal(ws: Ship, t: number)
	if t >= ws.np_tick then
		ws.np_tick = t + 10
		ws.near_port = false
		local r = Rules.WARSHIP_PASSIVE_HEAL_FULL / R.k_lin
		for _, p in ports_of(ws.o) do
			if dist2(f32(p.tile % C.W + 0.5), f32(p.tile // C.W + 0.5), ws.px, ws.py) <= r * r then
				ws.near_port = true
				break
			end
		end
	end
	if ws.near_port then
		ws.hp = min(ws.max_hp, ws.hp + Rules.WARSHIP_PASSIVE_HEAL)
	end
	local p = ws.port
	if ws.state == 2 and p ~= nil then
		local docked = 0
		for _, o2 in ships do
			if o2.state == 2 and o2.port == p then
				docked += 1
			end
		end
		if docked > 0 then
			ws.heal_rem += (p.level * Rules.WARSHIP_PORT_HEAL_PER_LEVEL) / docked
			local add = floor(ws.heal_rem)
			if add > 0 then
				ws.heal_rem -= add
				ws.hp = min(ws.max_hp, ws.hp + add)
			end
		end
	end
end

local function nearest_port(ws: Ship): Port?
	local best: Port? = nil
	local bd = 0.0
	local body = body_at(ws.px, ws.py)
	for _, p in ports_of(ws.o) do
		if body > 0 and coast_body(p.tile) ~= body then
			continue
		end
		local d = abs(p.tile % C.W - ws.px) + abs(p.tile // C.W - ws.py)
		if best == nil or d < bd then
			best = p
			bd = d
		end
	end
	return best
end

local function retreat_step(ws: Ship)
	local p = ws.port
	if p == nil or not p.cur or p.o ~= ws.o then
		ws.state = 0
		ws.port = nil
		return
	end
	local wt = water_next_to(p.tile)
	if wt < 0 then
		ws.state = 0
		ws.port = nil
		return
	end
	local dx, dy = f32(wt % C.W + 0.5), f32(wt // C.W + 0.5)
	local dock = Rules.WARSHIP_DOCK_FULL / R.k_lin
	if abs(dx - ws.px) + abs(dy - ws.py) <= dock then
		local docked = 0
		for _, o2 in ships do
			if o2.state == 2 and o2.port == p then
				docked += 1
			end
		end
		if docked < p.level then
			ws.state = 2
			ws.px, ws.py = dx, dy
		end
		return
	end
	ws.tx, ws.ty = dx, dy
	move(ws, R:warship_tiles_per_tick(false))
end

-- SimWarships.shore_water: water 4-adjacent to land
local function shore_water(t: number): boolean
	local W = C.W
	local n = C.W * C.H
	if t < 0 or t >= n or owner_at(t) ~= WATER then
		return false
	end
	local x = t % W
	if x > 0 and owner_at(t - 1) ~= WATER then
		return true
	end
	if x < W - 1 and owner_at(t + 1) ~= WATER then
		return true
	end
	if t >= W and owner_at(t - W) ~= WATER then
		return true
	end
	if t + W < n and owner_at(t + W) ~= WATER then
		return true
	end
	return false
end

local function safe_from_pirates(tr: Trader): boolean
	local cum, pts = tr.cum, tr.pts
	local n = #cum
	if n < 2 or #pts // 2 ~= n then
		return false
	end
	local d1 = tr.d
	local per_tick = R:ship_tiles_per_s() / 10.0 * C.boat_speed * C.TS
	local d0 = max(0.0, d1 - Rules.SAFE_FROM_PIRATES_TICKS * per_tick)
	local step = C.TS * 0.5
	local m = 1
	local d = d0
	local ts = f32(C.TS)
	while true do
		while m < n - 1 and cum[m + 1] < d do
			m += 1
		end
		local seg = max(0.001, cum[m + 1] - cum[m])
		local x, y = lerp2(pts[2 * m - 1], pts[2 * m], pts[2 * m + 1], pts[2 * m + 2], clampf((d - cum[m]) / seg, 0.0, 1.0))
		x, y = f32(x / ts), f32(y / ts)
		if shore_water(tile_of(x, y)) then
			return true
		end
		if d >= d1 then
			break
		end
		d = min(d + step, d1)
	end
	return false
end

local function find_target(ws: Ship): Target?
	local r = R:warship_range()
	local r2 = r * r
	local pr = R:warship_patrol()
	local best: Target? = nil
	local bp = 9
	local bd = 0.0
	for _, bt in boats do
		if bt.a == ws.o or allied(bt.a, ws.o) or ws.shelled[bt.uid] then
			continue
		end
		local d = dist2(bt.x, bt.y, ws.px, ws.py)
		if d <= r2 and (best == nil or 0 < bp or d < bd) then
			best = { kind = KB, id = bt.id }
			bp = 0
			bd = d
		end
	end
	if bp == 0 then
		return best
	end
	for _, o2 in ships do
		if o2 == ws or o2.o == ws.o or allied(o2.o, ws.o) or o2.state == 2 then
			continue
		end
		local d2 = dist2(o2.px, o2.py, ws.px, ws.py)
		if d2 <= r2 and (best == nil or d2 < bd) then
			best = { kind = KW, id = o2.uid }
			bp = 1
			bd = d2
		end
	end
	if bp == 1 then
		return best
	end
	-- trade ships: only with an own port on this water body, not bound for an own/allied port, near patrol
	local body = body_at(ws.px, ws.py)
	local reachable = false
	for _, p in ports_of(ws.o) do
		if coast_body(p.tile) == body then
			reachable = true
			break
		end
	end
	if not reachable then
		return nil
	end
	need_traders()
	for _, tr in traders do
		if tr.o == ws.o or allied(tr.o, ws.o) then
			continue
		end
		local dst_o = tr.dst_o
		if dst_o == ws.o or (dst_o > 0 and allied(dst_o, ws.o)) then
			continue
		end
		local tx, ty = path_pos(tr)
		local d3 = dist2(tx, ty, ws.px, ws.py)
		if d3 > r2 or dist2(tx, ty, ws.pax, ws.pay) > pr * pr or safe_from_pirates(tr) then
			continue
		end
		if best == nil or d3 < bd then
			best = { kind = KT, id = tr.id }
			bd = d3
		end
	end
	return best
end

local function shoot(ws: Ship, tg: Target, t: number)
	if t - ws.last_shot <= Rules.WARSHIP_FIRE_TICKS then
		return
	end
	if tg.kind ~= KB then
		ws.last_shot = t
	end
	local tx, ty = unit_pos(tg)
	local t1 = t + R:shell_flight_ticks(dist(ws.px, ws.py, tx, ty))
	local dmg = Rules.shell_damage(rng:randi_range(1, 5), ws.vet)
	table.insert(shells, {
		src = -1, shooter = ws.uid, post_k = -1, o = ws.o, tkind = tg.kind, tid = tg.id, t1 = t1, dmg = dmg,
		fx = ws.px, fy = ws.py, t0 = t, post = false,
	})
	stats.shots += 1
	local hit_player = false
	if tg.kind == KB then
		hit_player = boat_by_id[tg.id].a == C.PLAYER
	elseif tg.kind == KW then
		hit_player = ship_by_uid[tg.id].o == C.PLAYER
	end
	if ws.o == C.PLAYER or hit_player then
		push(E_SFX_SHOT)
	end
	if tg.kind == KB then
		local uid = boat_by_id[tg.id].uid
		if not ws.shelled[uid] then
			ws.shelled[uid] = true
			table.insert(ws.shelled_l, uid)
		end
		tref_erase(ws.uid)
	end
end

local function patrol(ws: Ship)
	if dist(ws.px, ws.py, ws.tx, ws.ty) < 1.0 or not is_water(ws.tx, ws.ty) then
		local half = R:warship_patrol() / 2.0
		local cx, cy = ws.pax, ws.pay
		local found = false
		for _widen = 1, 4 do
			for _k = 1, 12 do
				local ox = rng:randf_range(-half, half)
				local oy = rng:randf_range(-half, half)
				local qx, qy = f32(cx + f32(ox)), f32(cy + f32(oy))
				if is_water(qx, qy) and body_at(qx, qy) == body_at(ws.px, ws.py) then
					ws.tx, ws.ty = qx, qy
					found = true
					break
				end
			end
			if found then
				break
			end
			half *= 1.5
		end
		if not found then
			return
		end
	end
	move(ws, R:warship_tiles_per_tick(false))
end

-- SimWarships._capture_trade
-- CUSTOM: a capture plays no sound (owner request 2026-11-25, CLAUDE.md): notes only, no E_SFX event
local function capture_trade(ws: Ship, tr: Trader, tpx: number, tpy: number)
	local victim = tr.o
	local orig = tr.orig
	if orig == 0 then
		orig = victim
	end
	local sailed = tr.sailed + tr.d / C.TS
	erase_trader(tr)
	stats.captures += 1
	vet_progress(ws, Rules.WARSHIP_VET_TRANSPORTS)
	local t = C.t
	if victim == C.PLAYER and t - C.cap_msg > 150 then
		C.cap_msg = t
		push(E_NOTE, 6, ws.o)
	end
	if ws.o == C.PLAYER then
		push(E_NOTE, 7, victim)
	end
	ai_ship_loss(victim, tile_of(tpx, tpy), ws.o)
	local vt = tile_of(tpx, tpy)
	local water = body_at(tpx, tpy)
	local best: Port? = nil
	local bd = 0.0
	local W = C.W
	for _, p in ports_of(ws.o) do
		if coast_body(p.tile) ~= water then
			continue
		end
		local d = abs(p.tile % W - tpx) + abs(p.tile // W - tpy)
		if best == nil or d < bd then
			best = p
			bd = d
		end
	end
	if best == nil then
		return
	end
	local pts = SimNav.water_path_px_t(C.nav, vt, best.tile, C.TS, true)
	local n = #pts // 2
	if n < 2 then
		return
	end
	local cum: { number } = table.create(n)
	cum[1] = 0.0
	for m = 2, n do
		cum[m] = f32(cum[m - 1] + dist(pts[2 * m - 1], pts[2 * m], pts[2 * m - 3], pts[2 * m - 2]))
	end
	local id = C.next_tid
	C.next_tid += 1
	local ntr: Trader = {
		id = id, o = ws.o, dst_o = best.o, d = 0.0, orig = orig, sailed = sailed, pts = pts, cum = cum,
		pos_ok = false, x = 0, y = 0, inlist = true,
	}
	table.insert(traders, ntr)
	trader_by_id[id] = ntr
	pts_cache[id] = { pts = pts, cum = cum }
	push(E_TR_NEW, id, best.k, ws.o, orig, sailed, n)
	stats.rerouted += 1
end

local function hunt(ws: Ship, tg: Target)
	local tx, ty = unit_pos(tg)
	if abs(tx - ws.px) + abs(ty - ws.py) <= Rules.WARSHIP_DOCK_FULL / R.k_lin then
		need_traders()
		capture_trade(ws, trader_by_id[tg.id], tx, ty)
		tref_erase(ws.uid)
		return
	end
	ws.tx, ws.ty = tx, ty
	move(ws, R:warship_tiles_per_tick(true))
end

local function ship_tick(ws: Ship, t: number)
	local hp_before = ws.hp
	heal(ws, t)
	if ws.state == 2 then
		local p = ws.port
		if p == nil or not p.cur or p.o ~= ws.o or ws.hp >= ws.max_hp then
			ws.state = 0
			ws.port = nil
			ws.heal_rem = 0.0
		else
			return
		end
	end
	if ws.state == 1 then
		retreat_step(ws)
		return
	end
	if ws.state == 0 and t - ws.manual >= Rules.WARSHIP_MANUAL_NO_RETREAT_TICKS
		and hp_before < ws.max_hp * Rules.WARSHIP_RETREAT_PCT / 100.0 then
		local port = nearest_port(ws)
		if port ~= nil then
			ws.state = 1
			ws.port = port
			ws.heal_rem = 0.0
			tref_erase(ws.uid)
			retreat_step(ws)
			return
		end
	end
	local tgt: Target? = nil
	if (t + ws.uid) % Rules.SCAN_TICKS == 0 then
		tgt = find_target(ws)
		if tgt == nil then
			tref_erase(ws.uid)
		else
			tref_set(ws.uid, tgt)
		end
	elseif tref[ws.uid] ~= nil then
		tgt = tref[ws.uid]
		if not target_valid(ws, tgt :: Target) then
			tgt = nil
			tref_erase(ws.uid)
		end
	end
	if tgt ~= nil and tgt.kind ~= KT then
		shoot(ws, tgt, t)
		patrol(ws)
		return
	end
	if tgt ~= nil then
		hunt(ws, tgt)
		return
	end
	patrol(ws)
end

-- defense posts: every 10 ticks each finished post with its shell ready shells the nearest enemy ship in reach,
-- transports first; a post shells a given transport once
local function posts_tick(t: number)
	if #boats == 0 and #ships == 0 then
		return
	end
	local r = Rules.DEFENSE_POST_TARGET_FULL / R.k_lin
	local r2 = r * r
	local W = C.W
	for _, s in posts do
		local pt = s.tile
		local last = post_last[pt]
		if t - (if last ~= nil then last else -100000) <= Rules.DEFENSE_POST_SHELL_TICKS then
			continue
		end
		local spx, spy = f32(pt % W + 0.5), f32(pt // W + 0.5)
		local best: Target? = nil
		local bp = 9
		local bd = 0.0
		for _, bt in boats do
			if bt.a == s.o or allied(bt.a, s.o) or post_shelled[pt * 1048576 + bt.uid] then
				continue
			end
			local d = dist2(bt.x, bt.y, spx, spy)
			if d <= r2 and (best == nil or d < bd) then
				best = { kind = KB, id = bt.id }
				bp = 0
				bd = d
			end
		end
		if bp ~= 0 then
			for _, w in ships do
				if w.o == s.o or allied(w.o, s.o) then
					continue
				end
				local d2 = dist2(w.px, w.py, spx, spy)
				if d2 <= r2 and (best == nil or d2 < bd) then
					best = { kind = KW, id = w.uid }
					bp = 1
					bd = d2
				end
			end
		end
		if best == nil then
			continue
		end
		local tg = best :: Target
		post_last[pt] = t
		table.insert(pl_ch, pt)
		table.insert(pl_ch, t)
		local tx, ty = unit_pos(tg)
		local t1 = t + R:shell_flight_ticks(dist(spx, spy, tx, ty))
		local dmg = Rules.shell_damage(rng:randi_range(1, 5), 0)
		table.insert(shells, {
			src = -1, shooter = -1, post_k = s.k, o = s.o, tkind = tg.kind, tid = tg.id, t1 = t1, dmg = dmg,
			fx = spx, fy = spy, t0 = t, post = true,
		})
		stats.post_shots += 1
		local hit_player = false
		if tg.kind == KB then
			hit_player = boat_by_id[tg.id].a == C.PLAYER
		else
			hit_player = ship_by_uid[tg.id].o == C.PLAYER
		end
		if s.o == C.PLAYER or hit_player then
			push(E_SFX_SHOT)
		end
		if tg.kind == KB then
			local key = pt * 1048576 + boat_by_id[tg.id].uid
			if not post_shelled[key] then
				post_shelled[key] = true
				table.insert(post_shelled_new, key)
			end
		end
	end
end

local function shells_tick(t: number)
	local dup = table.clone(shells)
	for _, s in dup do
		if s.t1 > t then
			continue
		end
		local i = table.find(shells, s)
		if i then
			table.remove(shells, i)
		end
		if s.tkind == KB then
			local bt = boat_by_id[s.tid]
			if bt == nil or not bt.inlist or bt.a == s.o then
				continue
			end
			local bx, by = bt.bx, bt.by
			erase_boat(bt)
			push(E_FX, bx, by)
			stats.sunk_transports += 1
			if bt.a == C.PLAYER then
				push(E_NOTE, 1, s.o)
			elseif s.o == C.PLAYER then
				push(E_NOTE, 2, bt.a)
			end
			vet_progress(if s.shooter >= 0 then ship_by_uid[s.shooter] else nil, Rules.WARSHIP_VET_TRADES)
			local ts = f32(C.TS)
			ai_ship_loss(bt.a, tile_of(f32(bx / ts), f32(by / ts)), s.o)
		elseif s.tkind == KW then
			local o2 = ship_by_uid[s.tid]
			if o2 == nil or not o2.inlist or o2.o == s.o then
				continue
			end
			o2.hp = max(0.0, o2.hp - s.dmg)
			local ts = f32(C.TS)
			push(E_FX, f32(o2.px * ts), f32(o2.py * ts))
			if o2.hp <= 0.0 then
				erase_ship(o2)
				stats.sunk_warships += 1
				if o2.o == C.PLAYER then
					push(E_NOTE, 3, s.o)
					push(E_SFX_LOST)
				elseif s.o == C.PLAYER then
					push(E_NOTE, 4, o2.o)
				end
				local w = if s.shooter >= 0 then ship_by_uid[s.shooter] else nil
				if w ~= nil and w.inlist then
					w.vet_p = 0
					vet_up(w)
				end
			end
		end
	end
end

local function run_tick()
	local t = C.t
	local dup = table.clone(ships)
	for _, ws in dup do
		if not alive(ws.o) then
			erase_ship(ws)
			continue
		end
		ship_tick(ws, t)
	end
	if C.posts_shoot and t % 10 == 0 then
		posts_tick(t)
	end
	shells_tick(t)
end

-- ---------------------------------------------------------------------------------------------------------------
-- the calls
-- ---------------------------------------------------------------------------------------------------------------
-- a ship: uid, o, px, py, tx, ty, pax, pay, hp, max_hp, vet, vet_p, last_shot, state, port (-1 null), heal_rem,
-- manual, near_port, np_tick, nav flags (1 nav_r, 2 nav_t, 4 nav_i), ntx, nty, nav_i, n route points, x, y ...,
-- n shelled, shelled boat uids ...
local SHIP_HEAD = 25

local function read_ships(b: buffer)
	local len = buffer.len(b)
	local k = 0
	local seen: { Ship } = {}
	while k < len do
		local uid = readf64(b, k)
		local ws = ship_by_uid[uid]
		if ws == nil then
			ws = { shelled = {}, shelled_l = {}, route = {}, route_new = false } :: any
			ship_by_uid[uid] = ws
		end
		local s = ws :: Ship
		s.uid = uid
		s.o = readf64(b, k + 8)
		s.px = readf64(b, k + 16)
		s.py = readf64(b, k + 24)
		s.tx = readf64(b, k + 32)
		s.ty = readf64(b, k + 40)
		s.pax = readf64(b, k + 48)
		s.pay = readf64(b, k + 56)
		s.hp = readf64(b, k + 64)
		s.max_hp = readf64(b, k + 72)
		s.vet = readf64(b, k + 80)
		s.vet_p = readf64(b, k + 88)
		s.last_shot = readf64(b, k + 96)
		s.state = readf64(b, k + 104)
		local pk = readf64(b, k + 112)
		s.port = if pk >= 0 then ports[pk + 1] else nil
		s.heal_rem = readf64(b, k + 120)
		s.manual = readf64(b, k + 128)
		s.near_port = readf64(b, k + 136) ~= 0
		s.np_tick = readf64(b, k + 144)
		local fl = readf64(b, k + 152)
		s.has_r = fl % 2 >= 1
		s.has_t = fl % 4 >= 2
		s.has_i = fl >= 4
		s.ntx = readf64(b, k + 160)
		s.nty = readf64(b, k + 168)
		s.nav_i = readf64(b, k + 176)
		local nr = readf64(b, k + 184)
		k += 192
		local route: { number } = table.create(nr * 2)
		for j = 0, nr * 2 - 1 do
			route[j + 1] = readf64(b, k + j * 8)
		end
		k += nr * 16
		s.route = route
		s.route_new = false
		local ns = readf64(b, k)
		k += 8
		local sh: { [number]: boolean } = {}
		local shl: { number } = table.create(ns)
		for j = 0, ns - 1 do
			local u = readf64(b, k + j * 8)
			sh[u] = true
			shl[j + 1] = u
		end
		k += ns * 8
		s.shelled = sh
		s.shelled_l = shl
		s.inlist = true
		table.insert(seen, s)
	end
	ships = seen
	table.clear(ship_by_uid)
	for _, s in seen do
		ship_by_uid[s.uid] = s
	end
end

local function f64s(q: { number }): buffer
	local b = buffer.create(#q * 8)
	for i, v in q do
		writef64(b, (i - 1) * 8, v)
	end
	return b
end

local function pack(done: boolean): any
	local so: { number } = {}
	for _, s in ships do
		table.insert(so, s.uid)
		table.insert(so, s.px)
		table.insert(so, s.py)
		table.insert(so, s.tx)
		table.insert(so, s.ty)
		table.insert(so, s.hp)
		table.insert(so, s.max_hp)
		table.insert(so, s.vet)
		table.insert(so, s.vet_p)
		table.insert(so, s.last_shot)
		table.insert(so, s.state)
		table.insert(so, if s.port then (s.port :: Port).k else -1)
		table.insert(so, s.heal_rem)
		table.insert(so, if s.near_port then 1 else 0)
		table.insert(so, s.np_tick)
		table.insert(so, (if s.has_r then 1 else 0) + (if s.has_t then 2 else 0) + (if s.has_i then 4 else 0))
		table.insert(so, s.ntx)
		table.insert(so, s.nty)
		table.insert(so, s.nav_i)
		if s.route_new then
			table.insert(so, #s.route // 2)
			for _, v in s.route do
				table.insert(so, v)
			end
			s.route_new = false
		else
			table.insert(so, -1)
		end
		table.insert(so, #s.shelled_l)
		for _, u in s.shelled_l do
			table.insert(so, u)
		end
	end
	local sho: { number } = {}
	for i, s in shells do
		table.insert(sho, s.src)
		if s.src < 0 then
			table.insert(sho, s.shooter)
			table.insert(sho, s.post_k)
			table.insert(sho, s.o)
			table.insert(sho, s.tkind)
			table.insert(sho, s.tid)
			table.insert(sho, s.t1)
			table.insert(sho, s.dmg)
			table.insert(sho, s.fx)
			table.insert(sho, s.fy)
			table.insert(sho, s.t0)
			table.insert(sho, if s.post then 1 else 0)
		end
		s.src = i - 1 -- the GDScript list after this batch
	end
	local tro: { number } = {}
	for _, uid in tref_order do
		local tg = tref[uid]
		table.insert(tro, uid)
		table.insert(tro, tg.kind)
		table.insert(tro, tg.id)
	end
	local trn: { number } = {}
	for i = 1, #ev do
		trn[i] = ev[i]
	end
	-- new trade ships' points go in their own list, in the order of their E_TR_NEW events
	local ntp: { number } = {}
	local k = 1
	while k <= #ev do
		local code = ev[k]
		if code == E_TR_NEW then
			local tr = trader_by_id[ev[k + 1]]
			for _, v in tr.pts do
				table.insert(ntp, v)
			end
			k += 7
		elseif code == E_NOTE then
			k += 3
		elseif code == E_FX then
			k += 3
		elseif code == E_BOAT_GONE or code == E_WS_GONE or code == E_TR_GONE then
			k += 2
		else
			k += 1
		end
	end
	local pl = pl_ch
	local out = {
		rhi = rng.shi,
		rlo = rng.slo,
		ships = f64s(so),
		ev = f64s(trn),
		ntp = f64s(ntp),
		shells = f64s(sho),
		tref = f64s(tro),
		pl = f64s(pl),
		ps = f64s(post_shelled_new),
		st = f64s({ stats.shots, stats.sunk_transports, stats.sunk_warships, stats.captures, stats.post_shots, stats.rerouted }),
		next_tid = C.next_tid,
		cap_msg = C.cap_msg,
		done = done,
		ai = if done or yield_req == nil then nil else f64s(yield_req :: { number }),
		need_tr = need_tr,
	}
	table.clear(ev)
	table.clear(post_shelled_new)
	table.clear(pl_ch)
	return out
end

local function step(): any
	local c = co :: thread
	yield_req = nil
	need_tr = false
	local ok, err = coroutine.resume(c)
	if not ok then
		co = nil
		error(err, 0)
	end
	local done = coroutine.status(c) == "dead"
	if done then
		co = nil
	end
	return pack(done)
end

-- hdr (f64): tick, nav handle, TS, W, H, PLAYER, boat_speed, warship_speed, posts shoot, next trade ship id, the
--   tick of the last "capturing your trade ships" note
-- rf: rule fields (SimAttacks.RULE_FIELDS). ships: see read_ships. boats (f64 each): id, a, uid, px x, px y.
-- the trade ships come later, only if a ship needs them (out.need_tr, M.resume).
-- ports (f64 each): tile, o, level, current, finished. posts (f64 each): tile, o.
-- shells (f64 each): shooter uid (-1 post), o, target kind, target id (-1 gone), t1, dmg, from x, from y, t0, post.
-- tref (f64 each): uid, kind, id. pl: post tile, tick of its last shell (out: only the posts that shelled since the
--   last batch, in order). ps: post_shelled keys.
-- st: the six stats. -> pack()
function M.tick(rhi: number, rlo: number, hdr: buffer, rf: buffer, sb: buffer, bb: buffer, pb: buffer, qb: buffer, shb: buffer, trb: buffer, plb: buffer, psb: buffer, stb: buffer): any
	rng.shi = rhi
	rng.slo = rlo
	C.t = readf64(hdr, 0)
	C.nav = readf64(hdr, 8)
	C.TS = readf64(hdr, 16)
	C.W = readf64(hdr, 24)
	C.H = readf64(hdr, 32)
	C.PLAYER = readf64(hdr, 40)
	C.boat_speed = readf64(hdr, 48)
	C.warship_speed = readf64(hdr, 56)
	C.posts_shoot = readf64(hdr, 64) ~= 0
	C.next_tid = readf64(hdr, 72)
	C.cap_msg = readf64(hdr, 80)
	for i, name in SimAttacks.RULE_FIELDS do
		(R :: any)[name] = readf64(rf, (i - 1) * 8)
	end
	-- ports first (ships point into them)
	table.clear(ports)
	local k = 0
	while k < buffer.len(pb) do
		table.insert(ports, {
			k = #ports, tile = readf64(pb, k), o = readf64(pb, k + 8), level = readf64(pb, k + 16),
			cur = readf64(pb, k + 24) ~= 0, fin = readf64(pb, k + 32) ~= 0,
		})
		k += 40
	end
	table.clear(posts)
	k = 0
	while k < buffer.len(qb) do
		table.insert(posts, { tile = readf64(qb, k), o = readf64(qb, k + 8), k = readf64(qb, k + 16) })
		k += 24
	end
	table.clear(ship_by_uid)
	read_ships(sb)
	table.clear(boats)
	table.clear(boat_by_id)
	local ts = f32(C.TS)
	k = 0
	while k < buffer.len(bb) do
		local bx, by = readf64(bb, k + 24), readf64(bb, k + 32)
		local bt: Boat = {
			id = readf64(bb, k), a = readf64(bb, k + 8), uid = readf64(bb, k + 16), bx = bx, by = by,
			x = f32(bx / ts), y = f32(by / ts), inlist = true,
		}
		table.insert(boats, bt)
		boat_by_id[bt.id] = bt
		k += 40
	end
	table.clear(traders)
	table.clear(trader_by_id)
	tr_loaded = false
	need_tr = false
	table.clear(shells)
	k = 0
	while k < buffer.len(shb) do
		table.insert(shells, {
			src = #shells, shooter = readf64(shb, k), post_k = -1, o = readf64(shb, k + 8), tkind = readf64(shb, k + 16),
			tid = readf64(shb, k + 24), t1 = readf64(shb, k + 32), dmg = readf64(shb, k + 40), fx = readf64(shb, k + 48),
			fy = readf64(shb, k + 56), t0 = readf64(shb, k + 64), post = readf64(shb, k + 72) ~= 0,
		})
		k += 80
	end
	table.clear(tref)
	table.clear(tref_order)
	k = 0
	while k < buffer.len(trb) do
		local uid = readf64(trb, k)
		table.insert(tref_order, uid)
		tref[uid] = { kind = readf64(trb, k + 8), id = readf64(trb, k + 16) }
		k += 24
	end
	table.clear(post_last)
	table.clear(pl_ch)
	k = 0
	while k < buffer.len(plb) do
		post_last[readf64(plb, k)] = readf64(plb, k + 8)
		k += 16
	end
	table.clear(post_shelled)
	for j = 0, buffer.len(psb) - 8, 8 do
		post_shelled[readf64(psb, j)] = true
	end
	table.clear(post_shelled_new)
	stats.shots = readf64(stb, 0)
	stats.sunk_transports = readf64(stb, 8)
	stats.sunk_warships = readf64(stb, 16)
	stats.captures = readf64(stb, 24)
	stats.post_shots = readf64(stb, 32)
	stats.rerouted = readf64(stb, 40)
	table.clear(ev)
	co = coroutine.create(run_tick)
	return step()
end

-- after game.ai_ship_loss: the ships as they are now (same layout as M.tick; new ones at the end) and the rng.
-- After out.need_tr: tb, the trade ships (f64 each: id, o, dst o, d, orig, sailed), and tpts, the points of those
-- Luau has not seen (f64: id, n, x, y ..., cum ...); sb is then empty.
function M.resume(rhi: number, rlo: number, sb: buffer, tb: buffer?, tpts: buffer?): any
	assert(co ~= nil, "SimWarships: nothing to resume")
	rng.shi = rhi
	rng.slo = rlo
	if tb ~= nil then
		load_traders(tb, tpts :: buffer)
	else
		-- the ships keep their tables (the tick's loop holds them); a ship the GDScript added comes in new
		local old = ship_by_uid
		ship_by_uid = table.clone(old)
		read_ships(sb)
	end
	return step()
end

-- a failed call leaves nothing running
function M.abort(): boolean
	co = nil
	return true
end

return M
