--!strict
-- GDScript built-ins the GDScript sim relies on, so ported modules consume random numbers exactly as it does.
--
--   gd.rng(seed)          a RandomNumberGenerator after `rng.seed = seed` (bit-exact, Core/GodotRng)
--   gd.seed(s)            GDScript seed(s): reseeds the global generator (Math::seed)
--   gd.shuffle(arr)       Array.shuffle() on a 1-based Luau array; draws from the global generator
--   gd.shuffle_rng(arr, rng)  the same Fisher-Yates loop with a given generator
--   gd.hash_int(x)        GDScript hash(int)
--
-- Array.shuffle (core/variant/array.cpp): for i = n-1 down to 1: j = Math::rand() % (i + 1); swap(i, j),
-- where Math::rand() is the global RandomPCG's rand() (a uint32), i.e. randi() of the global generator.
local GodotRng = require("../Core/GodotRng")

local gd = {}

function gd.rng(seed: number): any
	return GodotRng.new(seed, true)
end

-- Godot seeds the global generator from the clock at start; a match that needs determinism calls seed().
gd.global = GodotRng.new(0, true)

function gd.seed(s: number)
	gd.global:set_seed(s)
end

function gd.shuffle_rng(arr: { any }, rng: any)
	local n = #arr
	for i = n - 1, 1, -1 do
		local j = rng:randi() % (i + 1)
		arr[i + 1], arr[j + 1] = arr[j + 1], arr[i + 1]
	end
end

function gd.shuffle(arr: { any })
	gd.shuffle_rng(arr, gd.global)
end

--- randf_range rounds a*b+c once on builds where the C++ compiler fuses it (clang contracts it on arm64) and twice
--- elsewhere. `samples` = { {seed, from, to, godot_result}, ... } computed by this machine's Godot; picks the
--- mode that reproduces all of them and returns it (nil if neither does).
function gd.calibrate_fused(samples: { { number } }): boolean?
	for _, fused in { false, true } do
		GodotRng.FUSED = fused
		local all = true
		for _, s in samples do
			local r = GodotRng.new(s[1], true)
			if r:randf_range(s[2], s[3]) ~= s[4] then
				all = false
				break
			end
		end
		if all then
			return fused
		end
	end
	GodotRng.FUSED = false
	return nil
end

gd.hash_int = GodotRng.hash_int
gd.f32 = GodotRng.f32

return gd
