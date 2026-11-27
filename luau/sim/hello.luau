--!strict
-- Bridge smoke module (tests/test_luau_bridge.gd): numbers, strings, buffers in and out.
local M = {}

function M.add(a: number, b: number): number
	return a + b
end

function M.greet(name: string): string
	return "hi " .. name
end

-- Sum of the buffer's little-endian int32s, and a buffer with each one doubled.
function M.sum_i32(b: buffer): number
	local s = 0
	for i = 0, buffer.len(b) - 4, 4 do
		s += buffer.readi32(b, i)
	end
	return s
end

function M.double_i32(b: buffer): buffer
	local n = buffer.len(b)
	local out = buffer.create(n)
	for i = 0, n - 4, 4 do
		buffer.writei32(out, i, buffer.readi32(b, i) * 2)
	end
	return out
end

-- State kept inside the VM between calls.
local count = 0
function M.bump(): number
	count += 1
	return count
end

return M
