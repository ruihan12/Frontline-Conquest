--!strict
-- Attack-pass kernel (condensed from sim/attacks.gd): heap queue, neighbour pushes, loss/time maths, set_owner + border upkeep.
local W, H = 2000, 1000
local N = W * H
local CAP = 2
local om: {number} = table.create(N, 0)
local border: {{[number]: boolean}} = {}
local land: {number} = {}
local troops: {number} = {}
local pf4: {number} = {}
for i = 0, 39 do pf4[i + 1] = 1 + (i % 5) end
local rs = 12345
local function rnd(): number
	rs = (rs * 48271) % 2147483647
	return rs
end
local attacks: {any} = {}
local tick = 0

local function hpush(hk: {number}, ht: {number}, key: number, t: number)
	local i = #hk + 1
	hk[i] = key; ht[i] = t
	while i > 1 do
		local p = i // 2
		local kp = hk[p]
		if kp <= key then break end
		hk[i] = kp; ht[i] = ht[p]
		i = p
	end
	hk[i] = key; ht[i] = t
end

local function hpop(hk: {number}, ht: {number}): number
	local n = #hk
	if n == 0 then return -1 end
	local top = ht[1]
	local lk, lt = hk[n], ht[n]
	hk[n] = nil :: any; ht[n] = nil :: any
	n -= 1
	if n == 0 then return top end
	local i = 1
	while true do
		local l = i * 2
		if l > n then break end
		local m = l
		if l + 1 <= n and hk[l + 1] < hk[l] then m = l + 1 end
		if lk <= hk[m] then break end
		hk[i] = hk[m]; ht[i] = ht[m]
		i = m
	end
	hk[i] = lk; ht[i] = lt
	return top
end

local function is_border(i: number): boolean
	local o = om[i + 1]
	local x = i % W
	if x > 0 and om[i] ~= o then return true end
	if x < W - 1 and om[i + 2] ~= o then return true end
	if i >= W and om[i - W + 1] ~= o then return true end
	if i < N - W and om[i + W + 1] ~= o then return true end
	return false
end

local function upd_border(i: number)
	local o = om[i + 1]
	if is_border(i) then border[o][i] = true else border[o][i] = nil end
end

local function set_owner(i: number, o: number)
	local old = om[i + 1]
	border[old][i] = nil
	land[old] -= 1
	om[i + 1] = o
	land[o] += 1
	upd_border(i)
	local x = i % W
	if x > 0 then upd_border(i - 1) end
	if x < W - 1 then upd_border(i + 1) end
	if i >= W then upd_border(i - W) end
	if i < N - W then upd_border(i + W) end
end

local function init()
	for y = 0, H - 1 do
		local cy = y // 50
		for x = 0, W - 1 do
			om[y * W + x + 1] = cy * 20 + x // 100 + 1
		end
	end
	for o = 1, 400 do border[o] = {}; land[o] = 5000; troops[o] = 1e9 end
	for i = 0, N - 1 do
		if is_border(i) then border[om[i + 1]][i] = true end
	end
	for cy = 0, 19 do
		for cx = 0, 19 do
			local at = cy * 20 + cx + 1
			if cx < 19 then
				local a = {a = at, t = at + 1, hk = {}, ht = {}, front = {}, nf = 0, troops = 1e9}
				for y = cy * 50, cy * 50 + 49 do
					local t = y * W + (cx + 1) * 100
					hpush(a.hk, a.ht, 4 * tick + (10 + rnd() % 7) * 2, t)
					a.front[t] = true; a.nf += 1
				end
				attacks[#attacks + 1] = a
			end
			if cy < 19 then
				local a = {a = at, t = at + 20, hk = {}, ht = {}, front = {}, nf = 0, troops = 1e9}
				for x = cx * 100, cx * 100 + 99 do
					local t = (cy + 1) * 50 * W + x
					hpush(a.hk, a.ht, 4 * tick + (10 + rnd() % 7) * 2, t)
					a.front[t] = true; a.nf += 1
				end
				attacks[#attacks + 1] = a
			end
		end
	end
end

local function add_neighbors(a: any, t: number, tg: number, at: number)
	local x = t % W
	local t4 = 4 * tick
	for k = 0, 3 do
		local u
		if k == 0 then
			if t < W then continue end
			u = t - W
		elseif k == 1 then
			if t >= N - W then continue end
			u = t + W
		elseif k == 2 then
			if x == 0 then continue end
			u = t - 1
		else
			if x == W - 1 then continue end
			u = t + 1
		end
		if om[u + 1] ~= tg then continue end
		local ux = u % W
		local n = 0
		if ux > 0 and om[u] == at then n += 1 end
		if ux < W - 1 and om[u + 2] == at then n += 1 end
		if u >= W and om[u - W + 1] == at then n += 1 end
		if u < N - W and om[u + W + 1] == at then n += 1 end
		local key = t4 + (10 + rnd() % 7) * pf4[(u % 8) * 5 + n + 1]
		hpush(a.hk, a.ht, key, u)
		if not a.front[u] then a.nf += 1 end
		a.front[u] = true
	end
end

local function process(a: any)
	local at, tg = a.a, a.t
	local hk, ht, front = a.hk, a.ht, a.front
	local budget = 1.0
	local taken = 0
	local tr = a.troops
	local border_of = a.nf * 1.0 + rnd() % 8
	while budget > 0.0 do
		if taken >= CAP then break end
		local t = hpop(hk, ht)
		if t < 0 then break end
		if front[t] then front[t] = nil; a.nf -= 1 end
		local tx = t % W
		if om[t + 1] ~= tg or not ((tx > 0 and om[t] == at) or (tx < W - 1 and om[t + 2] == at) or (t >= W and om[t - W + 1] == at) or (t < N - W and om[t + W + 1] == at)) then continue end
		add_neighbors(a, t, tg, at)
		local dtr = troops[tg]
		local ratio = dtr / tr
		local loss = 0.5 * math.clamp(ratio, 0.6, 2.0) * (1.0 + 0.001 * (dtr / math.max(land[tg], 1)))
		local tf = math.max(math.clamp(ratio, 0.82, 7.5) * math.clamp(ratio / 20.0, 1.0, 50.0) * 1.0 * 0.02 / math.max(border_of, 1.0), 1e-6)
		budget -= tf
		tr -= loss
		troops[tg] -= math.min(loss, math.max(troops[tg], 0))
		set_owner(t, at)
		taken += 1
	end
	a.troops = tr
	return taken
end

local M = {}
function M.init() init() end
function M.tick()
	tick += 1
	local total = 0
	for _, a in attacks do total += process(a) end
	return total
end
function M.checksum()
	local s = 0
	for i = 0, N - 1, 7 do s = (s + om[i + 1] * (i % 97 + 1)) % 1000000007 end
	local b = 0
	for o = 1, 400 do for _ in border[o] do b += 1 end end
	return s * 1000 + b % 1000, b
end
return M
