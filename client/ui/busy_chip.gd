# Port of src/client/UI/BusyChip.luau (scripts/ui/busy_chip.gd, UIBusyChip).
# Small centred "Deploying a new world…" pill with a spinner, shown while a match is being built.
class_name BusyChip
extends Control


## 18 px: a faint ring and a rotating amber arc.
class Spinner:
	extends Control
	var t := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(18, 18)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		t += delta
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.5
		draw_arc(c, r, 0.0, TAU, 32, Color(1, 1, 1, 0.14), 2.0, true)
		var a := t * 5.5
		draw_arc(c, r, a, a + TAU * 0.28, 16, UITheme.AMBER, 2.0, true)


var ctx: UICtx
var _pill: GlassPanel
var _spin: Spinner
var _label: Label
var _hiding: Tween = null


func _init(c: UICtx) -> void:
	ctx = c
	name = "Busy"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pill = GlassPanel.new(16.0, 9.0, 999, true, 18)
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := UITheme.hbox(10)
	_spin = Spinner.new()
	_spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(_spin)
	_label = UITheme.label("", 14, 700, UITheme.TEXT, 1)
	h.add_child(_label)
	_pill.add_child(h)
	add_child(_pill)
	visible = false


func show_text(text: String) -> void:
	_label.text = text
	var p := _pill
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	p.offset_left = 0.0
	p.offset_right = 0.0
	p.offset_top = -ctx.vp.y * 0.18
	p.offset_bottom = p.offset_top
	p.reset_size()
	if _hiding != null:
		_hiding.kill()
		_hiding = null
		modulate.a = 1.0
	if not visible:
		visible = true
		_spin.set_process(true)
		UIFx.pop_in(p, 0.0, 0.94, 0.25)


func hide_chip() -> void:
	if not visible or _hiding != null:
		return
	_spin.set_process(false)
	_hiding = create_tween()
	_hiding.tween_property(self, "modulate:a", 0.0, 0.2)
	_hiding.tween_callback(func() -> void:
		visible = false
		modulate.a = 1.0
		_hiding = null)
