class_name LuauVM
extends RefCounted
## Thin bridge to the Luau GDExtension (fernforestgames/luau-gdextension, built from tools/luau_ext).
## One LuauVM = one Lua state. Load modules from res://luau/sim/**.luau, call their functions,
## pass bytes in and out as Luau buffers (PackedByteArray <-> buffer, copied at the boundary).
## The extension classes are looked up at run time so this script still parses where the
## extension is missing (available() is then false).

var L: Object = null          # LuaState
var _luau: Object = null      # Luau (static helpers)
var _modules: Dictionary = {} # module name -> registry ref of its table
var last_error: String = ""

static func available() -> bool:
	return ClassDB.class_exists("LuaState") and ClassDB.class_exists("Luau")

func _init() -> void:
	if not available():
		last_error = "Luau extension not loaded"
		return
	L = ClassDB.instantiate("LuaState")
	_luau = ClassDB.instantiate("Luau")
	L.open_libs()

func ok() -> bool:
	return L != null

## Compile and run `src`; its return value (a table) is stored as module `name`.
func load_source(name: String, src: String) -> bool:
	if L == null: return false
	var bc: PackedByteArray = _luau.compile(src)
	if not L.load_bytecode(bc, name):
		last_error = "%s: %s" % [name, str(L.to_variant(-1))]
		L.pop(1)
		return false
	if L.pcall(0, 1) != 0:
		last_error = "%s: %s" % [name, str(L.to_variant(-1))]
		L.pop(1)
		return false
	_modules[name] = L.ref(-1)
	L.pop(1)
	return true

func load_file(name: String, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		last_error = "cannot open " + path
		return false
	return load_source(name, f.get_as_text())

## Call module[fn](args...) and return its first result as a Variant (null on error, see last_error).
func call_fn(module: String, fn: String, args: Array = []) -> Variant:
	if L == null or not _modules.has(module): return null
	var top: int = L.get_top()
	L.get_ref(_modules[module])
	L.get_field(-1, StringName(fn))
	for a in args:
		L.push_variant(a)
	if L.pcall(args.size(), 1) != 0:
		last_error = "%s.%s: %s" % [module, fn, str(L.to_variant(-1))]
		L.set_top(top)
		return null
	var r: Variant = L.to_variant(-1)
	L.set_top(top)
	return r
