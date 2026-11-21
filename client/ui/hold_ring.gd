# Port of src/client/UI/HoldRing.luau.
# Touch: a ring that closes in around a finger held on the map until the long-press menu opens. It
# shows that the hold is counting (keep still) and when it will open. Driven each frame from the
# map input's hold state; input-transparent.
class_name HoldRing
extends Control

## The ring appears once a hold is this far along (a tap never flashes it).
const SHOW_FROM := 0.2
## logical px, the closed ring's diameter
const SIZE := 58.0
const COL := Color8(255, 214, 120)

var ctx: UICtx
var _pos := Vector2.ZERO
var _e := 0.0


func _init(c: UICtx) -> void:
	ctx = c
	name = "HoldRing"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false


## pos: the finger (logical px) or null; k: the hold's progress 0..1.
func set_hold(pos, k: float) -> void:
	if pos == null or k < SHOW_FROM or k >= 1.0:
		if visible:
			visible = false
		return
	visible = true
	var q := (k - SHOW_FROM) / (1.0 - SHOW_FROM)
	_e = 1.0 - (1.0 - q) * (1.0 - q)
	_pos = pos
	queue_redraw()


func _draw() -> void:
	var e := _e
	var r := SIZE * (1.9 - 0.9 * e) * 0.5
	# a soft fill that brightens as it closes
	draw_circle(_pos, r, Color(COL, 0.05 + 0.25 * e), true, -1.0, true)
	draw_arc(_pos, r, 0.0, TAU, 48, Color(COL, 0.15 + 0.7 * e), 2.0 + 2.0 * e, true)
