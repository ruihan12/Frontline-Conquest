# Luau runtime + bridge (sim/luau_vm.gd): the extension loads, modules run, numbers / strings / buffers cross both ways,
# state stays in the VM between calls, errors come back as last_error.
#   godot --headless --path . -s res://tests/test_luau_bridge.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_check(LuauVM.available(), "extension loaded (LuaState and Luau classes exist)")
	if not LuauVM.available():
		_done()
		return
	var vm := LuauVM.new()
	_check(vm.ok(), "VM created")
	var loaded: bool = vm.load_file("hello", "res://luau/sim/hello.luau")
	_check(loaded, "load res://luau/sim/hello.luau (%s)" % vm.last_error)
	_check(vm.call_fn("hello", "add", [2, 3.5]) == 5.5, "number in and out")
	_check(vm.call_fn("hello", "greet", ["RoFront"]) == "hi RoFront", "string in and out")
	var b := PackedByteArray()
	b.resize(16)
	for i in 4:
		b.encode_s32(i * 4, (i + 1) * 1000 - 3)
	_check(int(vm.call_fn("hello", "sum_i32", [b])) == 9988, "PackedByteArray in as a Luau buffer")
	var d: Variant = vm.call_fn("hello", "double_i32", [b])
	var ok_d := d is PackedByteArray and (d as PackedByteArray).size() == 16
	if ok_d:
		for i in 4:
			ok_d = ok_d and (d as PackedByteArray).decode_s32(i * 4) == ((i + 1) * 1000 - 3) * 2
	_check(ok_d, "Luau buffer out as a PackedByteArray")
	vm.call_fn("hello", "bump")
	_check(int(vm.call_fn("hello", "bump")) == 2, "module state kept between calls")
	var bad: Variant = vm.call_fn("hello", "add", ["x", {}])
	_check(bad == null and vm.last_error != "", "a Luau error returns null and sets last_error")
	_check(not vm.load_source("broken", "return {"), "a syntax error fails to load")
	_done()


func _done() -> void:
	print("LUAU_BRIDGE_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails > 0 else 0)
