--!strict
-- Runs first in every sim Lua state (sim/luau_vm.gd boot()), before the state is sandboxed.
--
-- 1. Modules: every .luau file under res://luau/sim is registered as a chunk named by its path without the
--    extension ("Core/GodotRng"); `require(name)` runs a chunk once and caches its result. The loader rewrites
--    upstream's relative string requires (`require("./Defs")`, `require("../Net/Coop")`) to these names when
--    it loads a file, on the same line, so upstream sources load unchanged.
-- 2. The few Roblox globals upstream modules touch, as plain Luau (no Roblox engine behind them):
--    Vector3 / Vector2 -> Luau's native float32 `vector` (as Roblox's), Color3 -> a frozen {R, G, B} table,
--    Random.new -> NOT Roblox's generator: Godot's PCG32 (Core/GodotRng), which the sim needs anyway,
--    task.spawn / task.defer run the function at once (the sim never waits), task.wait raises an error.
--    `typeof` stays Luau's own ("vector" for a Vector3, Roblox says "Vector3"; upstream only tests "buffer").
local chunks: { [string]: () -> any } = {}
local cache: { [string]: any } = {}
local loading: { [string]: boolean } = {}

function __register(name: string, fn: () -> any)
	chunks[name] = fn
end

function __has(name: string): boolean
	return chunks[name] ~= nil
end

function require(name: string): any
	local m = cache[name]
	if m ~= nil then
		return m
	end
	local fn = chunks[name]
	if fn == nil then
		error("module not found: " .. tostring(name), 2)
	end
	if loading[name] then
		error("require cycle through " .. name, 2)
	end
	loading[name] = true
	local r = fn()
	loading[name] = nil
	if r == nil then
		r = true
	end
	cache[name] = r
	return r
end

local vcreate = vector.create

Vector3 = table.freeze({
	new = function(x: number?, y: number?, z: number?): vector
		return vcreate(x or 0, y or 0, z or 0)
	end,
	zero = vcreate(0, 0, 0),
	one = vcreate(1, 1, 1),
})

Vector2 = table.freeze({
	new = function(x: number?, y: number?): vector
		return vcreate(x or 0, y or 0, 0)
	end,
	zero = vcreate(0, 0, 0),
	one = vcreate(1, 1, 0),
})

local function color3(r: number?, g: number?, b: number?): any
	return table.freeze({ R = r or 0, G = g or 0, B = b or 0 })
end

Color3 = table.freeze({
	new = color3,
	fromRGB = function(r: number?, g: number?, b: number?): any
		return color3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
})

local RandomMT = {}
RandomMT.__index = RandomMT
function RandomMT.NextInteger(self: any, a: number, b: number): number
	return self._g:randi_range(a, b)
end
function RandomMT.NextNumber(self: any, a: number?, b: number?): number
	if a == nil then
		return self._g:randf()
	end
	return self._g:randf_range(a, b or 1)
end

Random = table.freeze({
	new = function(seed: number?): any
		local G = require("Core/GodotRng")
		return setmetatable({ _g = G.new(seed or 0, true) }, RandomMT)
	end,
})

task = table.freeze({
	spawn = function(f: (...any) -> ...any, ...: any)
		f(...)
	end,
	defer = function(f: (...any) -> ...any, ...: any)
		f(...)
	end,
	wait = function(_: number?): number
		error("task.wait is not available in the sim", 2)
	end,
})
