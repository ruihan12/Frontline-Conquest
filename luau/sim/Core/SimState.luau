--!strict
-- SimState: the tile layer of the match, owned by Luau (docs/LUAU_PORT.md, Step 4).
--
--   owner    buffer, i32 per tile (row-major, W * H): -2 ice, -1 water, 0 neutral, > 0 nation id
--   fallout  buffer, u8 per tile: 1 = fallout (left by a nuke, until the tile is owned again)
--
-- While the sim is half ported, both sides write tiles. GDScript keeps its own arrays (owner_map, fallout; the
-- renderer, the HUD and net/rep.gd read those) and sends every change it makes; Luau modules write here with
-- set_owner / set_fallout, which record the change for GDScript. sim/luau_link.gd pushes GDScript's changes before
-- a Luau module runs and takes Luau's after, and does both at the end of every tick, so at every tick boundary
-- the two copies are equal (tests/test_luau_state.gd checks it).
local SimState = {}
SimState.__index = SimState

export type State = {
	W: number,
	H: number,
	n: number,
	owner: buffer,
	fallout: buffer,
	out_owner: { number },
	out_fall: { number },
}

SimState.cur = (nil :: any) :: State?

function SimState.new(W: number, H: number, owner: buffer, fallout: buffer): State
	assert(buffer.len(owner) == W * H * 4, "owner buffer size")
	assert(buffer.len(fallout) == W * H, "fallout buffer size")
	local self = setmetatable({
		W = W,
		H = H,
		n = W * H,
		owner = owner,
		fallout = fallout,
		out_owner = {},
		out_fall = {},
	}, SimState)
	return (self :: any) :: State
end

-- ---- reads / writes for Luau modules (tile ids are 0-based like GDScript)
function SimState.get_owner(self: State, i: number): number
	return buffer.readi32(self.owner, i * 4)
end

function SimState.set_owner(self: State, i: number, o: number)
	buffer.writei32(self.owner, i * 4, o)
	local q = self.out_owner
	q[#q + 1] = i
	q[#q + 1] = o
end

function SimState.get_fallout(self: State, i: number): number
	return buffer.readu8(self.fallout, i)
end

function SimState.set_fallout(self: State, i: number, v: number)
	buffer.writeu8(self.fallout, i, v)
	local q = self.out_fall
	q[#q + 1] = i
	q[#q + 1] = v
end

-- ---- the GDScript side (sim/luau_link.gd)

-- A new map: Luau takes copies of owner_map and fallout.
function SimState.begin(W: number, H: number, owner: buffer, fallout: buffer): boolean
	SimState.cur = SimState.new(W, H, owner, fallout)
	return true
end

local function pairs_buf(q: { number }): buffer
	local b = buffer.create(#q * 4)
	for k = 1, #q do
		buffer.writei32(b, (k - 1) * 4, q[k])
	end
	return b
end

-- in_owner / in_fall: (tile i32, value i32) pairs GDScript wrote since the last push, in order.
function SimState.push(in_owner: buffer, in_fall: buffer): boolean
	local st = SimState.cur
	assert(st, "SimState.push before begin")
	local ob = st.owner
	for k = 0, buffer.len(in_owner) - 8, 8 do
		buffer.writei32(ob, buffer.readi32(in_owner, k) * 4, buffer.readi32(in_owner, k + 4))
	end
	local fb = st.fallout
	for k = 0, buffer.len(in_fall) - 8, 8 do
		buffer.writeu8(fb, buffer.readi32(in_fall, k), buffer.readi32(in_fall, k + 4))
	end
	return true
end

-- The (tile, value) pairs Luau modules wrote since the last take, in order: { owner = buffer, fallout = buffer }.
function SimState.take(): any
	local st = SimState.cur
	assert(st, "SimState.take before begin")
	local out = { owner = pairs_buf(st.out_owner), fallout = pairs_buf(st.out_fall) }
	table.clear(st.out_owner)
	table.clear(st.out_fall)
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

return SimState
