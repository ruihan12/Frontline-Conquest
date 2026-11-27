--!strict
-- Helper for tests/test_luau_rng.gd: replays GDScript RNG call sequences in Luau.
local gd = require("rt/gd")

local M = {}

-- ops: 24 bytes each (i32 op, i32 pad, f64 a, f64 b); op 0 randi, 1 randf, 2 randi_range(a, b),
-- 3 randf_range(a, b), 4 seed = a. Returns { res = buffer of f64 results, state = rng.state as a string }.
function M.run(seed: number, ops: buffer): any
	local r = gd.rng(seed)
	local n = buffer.len(ops) // 24
	local out = buffer.create(n * 8)
	for i = 0, n - 1 do
		local o = i * 24
		local op = buffer.readi32(ops, o)
		local a = buffer.readf64(ops, o + 8)
		local b = buffer.readf64(ops, o + 16)
		local v = 0
		if op == 0 then
			v = r:randi()
		elseif op == 1 then
			v = r:randf()
		elseif op == 2 then
			v = r:randi_range(a, b)
		elseif op == 3 then
			v = r:randf_range(a, b)
		else
			r:set_seed(a)
		end
		buffer.writef64(out, i * 8, v)
	end
	return { res = out, state = r:state_string() }
end

function M.hash_int(x: number): number
	return gd.hash_int(x)
end

-- seed(s); Array.shuffle() of 0..n-1; then `extra` global randi() draws.
function M.shuffle(s: number, n: number, extra: number): any
	gd.seed(s)
	local arr = {}
	for i = 0, n - 1 do
		arr[i + 1] = i
	end
	gd.shuffle(arr)
	local after = {}
	for i = 1, extra do
		after[i] = gd.global:randi()
	end
	return { arr = arr, after = after }
end

-- game/nations.gd tribe setup: shuffle name order with rng.randi() % (i + 1), then two dummy randf() per tribe
-- (the draws the old random tribe greys took). Returns the order and the state afterwards.
function M.tribe_draws(seed: number, nn: number, count: number): any
	local r = gd.rng(seed)
	local order = {}
	for i = 0, nn - 1 do
		order[i] = i
	end
	for i = nn - 1, 1, -1 do
		local j = r:randi() % (i + 1)
		order[i], order[j] = order[j], order[i]
	end
	for _ = 1, count do
		r:randf()
		r:randf()
	end
	local o = {}
	for i = 0, nn - 1 do
		o[i + 1] = order[i]
	end
	return { order = o, state = r:state_string(), next = r:randi() }
end

function M.calibrate(samples: { { number } }): any
	return gd.calibrate_fused(samples)
end

-- Seconds for n randi() + n randf() draws (printed by the test, not checked).
function M.bench(n: number): number
	local r = gd.rng(5516)
	local t0 = os.clock()
	local acc = 0
	for _ = 1, n do
		acc += r:randi() + r:randf()
	end
	return os.clock() - t0 + acc * 0
end

-- Roblox-globals shim smoke values.
function M.shim(): any
	local v = Vector3.new(1.1, 2, 3)
	local w = Vector2.new(0.5, 4)
	local c = Color3.fromRGB(209, 205, 199)
	local rnd = Random.new(5516)
	local spawned = 0
	task.spawn(function(k: number)
		spawned = k
	end, 7)
	local ok_wait = pcall(task.wait, 1)
	local Coop = require("Net/Coop")
	Coop.check()
	return {
		vx = v.X, vy = v.y, vz = v.Z, w = w.X + w.Y, sum = (v + v).Z, vt = typeof(v),
		r = c.R, g = c.G, b = c.B,
		ri = rnd:NextInteger(1, 100), rf = rnd:NextNumber(),
		spawned = spawned, wait_errors = not ok_wait,
		global_write = pcall(function() (_G :: any).x = 1 end),
	}
end

return M
