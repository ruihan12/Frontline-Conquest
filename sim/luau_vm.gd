class_name LuauVM
extends RefCounted
## Thin bridge to the Luau GDExtension (fernforestgames/luau-gdextension, built from tools/luau_ext).
## One LuauVM = one Lua state. boot() registers every res://luau/sim/**.luau file as a module (see
## luau/sim/rt/prelude.luau) and sandboxes the state; require_module(name) runs one and keeps its table;
## call_fn(module, fn, args) calls it. Bytes cross as Luau buffers (PackedByteArray <-> buffer, copied).
## load_source / load_file run a single chunk directly (no require), for tests and one-off scripts.
## The extension classes are looked up at run time so this script still parses where the
## extension is missing (available() is then false).

var L: Object = null          # LuaState
var _luau: Object = null      # Luau (static helpers)
var _modules: Dictionary = {} # module name -> registry ref of its table
var last_error: String = ""
var booted := false

## Every Luau library except the Godot bridge (LIB_GODOT = 1 << 11): the sim is plain Luau.
const LIBS := 2047
const ROOT := "res://luau/sim"
static var _req_re: RegEx = null

static func available() -> bool:
	return ClassDB.class_exists("LuaState") and ClassDB.class_exists("Luau")

func _init() -> void:
	if not available():
		last_error = "Luau extension not loaded"
		return
	L = ClassDB.instantiate("LuaState")
	_luau = ClassDB.instantiate("Luau")
	L.open_libs(LIBS)

func ok() -> bool:
	return L != null


## Registers every module under `root`, runs the prelude, then sandboxes the state (globals read-only, which also
## lets Luau use its fast paths for library calls). Call once, before require_module.
func boot(root: String = ROOT) -> bool:
	if L == null or booted: return booted
	var pre := _read(root + "/rt/prelude.luau")
	if pre == "":
		last_error = "no prelude in " + root
		return false
	if not _exec(pre, "rt/prelude"):
		return false
	var files: PackedStringArray = []
	_scan(root, "", files)
	for rel in files:
		var name := rel.trim_suffix(".luau")
		if name == "rt/prelude": continue
		if not _register(name, rewrite_requires(_read(root + "/" + rel), name)):
			return false
	L.sandbox()
	booted = true
	return true


## require(name) inside the state; keeps the module table for call_fn(name, ...).
func require_module(name: String) -> bool:
	if L == null: return false
	if _modules.has(name): return true
	var top: int = L.get_top()
	L.get_global(&"require")
	L.push_string(name)
	if L.pcall(1, 1) != 0:
		last_error = "require %s: %s" % [name, str(L.to_variant(-1))]
		L.set_top(top)
		return false
	_modules[name] = L.ref(-1)
	L.set_top(top)
	return true


## Upstream-style relative string requires -> module names: in module "Core/Sim", require("./Defs") becomes
## require("Core/Defs") and require("../Net/Coop") require("Net/Coop"). Same line, so line numbers stay.
static func rewrite_requires(src: String, name: String) -> String:
	if _req_re == null:
		_req_re = RegEx.new()
		_req_re.compile("require\\(\\s*\"(\\.\\.?/[^\"]*)\"\\s*\\)")
	var out := ""
	var at := 0
	for m in _req_re.search_all(src):
		out += src.substr(at, m.get_start() - at) + "require(\"" + resolve(name, m.get_string(1)) + "\")"
		at = m.get_end()
	return out + src.substr(at)


static func resolve(from_module: String, rel: String) -> String:
	var parts: Array = from_module.split("/")
	parts.pop_back()
	for seg in rel.split("/"):
		if seg == "..":
			if not parts.is_empty(): parts.pop_back()
		elif seg != "." and seg != "":
			parts.append(seg)
	return "/".join(parts)


func _register(name: String, src: String) -> bool:
	var bc: PackedByteArray = _luau.compile(src)
	var top: int = L.get_top()
	L.get_global(&"__register")
	L.push_string(name)
	if not L.load_bytecode(bc, "@luau/sim/" + name + ".luau"):
		last_error = "%s: %s" % [name, str(L.to_variant(-1))]
		L.set_top(top)
		return false
	if L.pcall(2, 0) != 0:
		last_error = "register %s: %s" % [name, str(L.to_variant(-1))]
		L.set_top(top)
		return false
	return true


func _exec(src: String, name: String) -> bool:
	var bc: PackedByteArray = _luau.compile(src)
	if not L.load_bytecode(bc, "@luau/sim/" + name + ".luau"):
		last_error = "%s: %s" % [name, str(L.to_variant(-1))]
		L.pop(1)
		return false
	if L.pcall(0, 0) != 0:
		last_error = "%s: %s" % [name, str(L.to_variant(-1))]
		L.pop(1)
		return false
	return true


static func _scan(root: String, sub: String, out: PackedStringArray) -> void:
	var dir := root if sub == "" else root + "/" + sub
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".luau"):
			out.append(f if sub == "" else sub + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_scan(root, d if sub == "" else sub + "/" + d, out)


static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""

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
	var src := _read(path)
	if src == "":
		last_error = "cannot open " + path
		return false
	return load_source(name, src)

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
