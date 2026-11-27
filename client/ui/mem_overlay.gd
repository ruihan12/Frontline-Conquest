# Memory readout for phones and tablets (owner request 2026-11-26: iOS/iPadOS keeps killing the tab on memory).
# One small line at the bottom left, once a second: engine memory in use / peak, texture + video memory, object and
# node counts, sim tick. On the web it also stores the latest line in localStorage ("rf_memlog"), so after a crash and
# reload the title screen shows the last values the tab reached ("last run: ..."). Touch devices only; ?nomem=1 hides it.
extends Label
class_name MemOverlay

const KEY := "rf_memlog"
var g
var _acc := 0.0
var _prev := ""

func _init(main) -> void:
	g = main
	name = "MemOverlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_size_override("font_size", 12)
	add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	add_theme_constant_override("shadow_offset_x", 1)
	add_theme_constant_override("shadow_offset_y", 1)
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 8.0
	offset_top = -44.0
	offset_bottom = -6.0
	z_index = 100
	if OS.has_feature("web"):
		var p = JavaScriptBridge.eval("(function(){try{return localStorage.getItem('%s')||''}catch(e){return ''}})()" % KEY, true)
		_prev = str(p) if p != null else ""
		if bool(JavaScriptBridge.eval("String(window.location.search||'').indexOf('nomem=1')>=0", true)):
			visible = false
			set_process(false)
	_refresh()

func _process(dt: float) -> void:
	_acc += dt
	if _acc < 1.0:
		return
	_acc = 0.0
	_refresh()

func _mb(b: float) -> String:
	return "%d" % int(b / 1048576.0)

func line() -> String:
	var used := float(OS.get_static_memory_usage())
	var peak := float(OS.get_static_memory_peak_usage())
	var tex := float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var vid := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var objs := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var tick: int = int(g.sim_atk.tick) if g.sim_atk != null else 0
	return "mem %s/%s MB (peak) tex %s vid %s obj %d nodes %d t%d:%02d" % [_mb(used), _mb(peak), _mb(tex), _mb(vid), objs, nodes, tick / 600, (tick / 10) % 60]

func _refresh() -> void:
	var cur := line()
	text = cur if _prev == "" else "last run: %s\n%s" % [_prev, cur]
	if OS.has_feature("web"):
		JavaScriptBridge.eval("(function(){try{localStorage.setItem('%s','%s')}catch(e){}})()" % [KEY, cur.replace("'", "")], true)
