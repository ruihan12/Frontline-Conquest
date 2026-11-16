# Port of src/client/Map/MapInput.luau: pointer input on the map.
# One press at a time (the mouse, or one finger): a press that stays within the tap slop is a
# click, one that moves drags the map (with inertia on release), one that is held opens the
# context menu; a press on a still-gliding map only stops it. Two fingers pinch-zoom around their
# midpoint. The wheel zooms toward the pointer, the keys pan.
#
# Upstream listens to Roblox's UserInputService; here main.gd passes the Godot events its
# _unhandled_input receives (so presses the HUD took never arrive: upstream's "game processed"),
# and calls tick() every frame. Port differences: a finger that started on the HUD is not seen at
# all (no mixed pinch), and the = / - keys are the port's game-speed keys, not zoom.
class_name MapInput
extends RefCounted

signal tile_clicked(tile: int)
signal tile_context(tile: int, pos: Vector2)
signal tile_hovered(tile: int)

## px a press may move and still count as a click
const TAP_SLOP_MOUSE := 6.0
## fingers wobble more (a hold for the menu must survive it)
const TAP_SLOP_TOUCH := 16.0
const LONG_PRESS_MS := 500.0
const WHEEL_STEP := 1.16
## view heights per second
const KEY_PAN_SPEED := 0.55
## doublings per second
const KEY_ZOOM_SPEED := 1.6
## map moving faster than this under the pointer: a press only stops it
const STOP_PX_PER_S := 30.0
const STALE_TOUCH_S := 3.0
## press index of the mouse (touches use their finger index, 0 and up)
const MOUSE := -1

var rig: MapCamera
## Callable() -> bool: the map takes input now (no window over it, not the title's drift).
var active: Callable
## Callable(Vector2) -> int: the tile under a screen point, -1 for none.
var tile_at: Callable
## Callable(Vector2) -> bool: a HUD control is under this point (hover stops there).
var over_gui: Callable
## (port) = and - zoom, as upstream; off because they set the game speed here.
var key_zoom := false
var stats := {"touch_presses": 0, "mouse_presses": 0, "stop_presses": 0, "pinches": 0, "stale_touches": 0, "ticks": 0}
var _press_active := false
var _press_index := MOUSE
var _press_pos := Vector2.ZERO
var _press_ms := 0.0
var _press_dragging := false
var _press_consumed := false
var _press_stop := false
var _press_slop := TAP_SLOP_MOUSE
var _touches := {}  # finger index -> {pos, pair_pos, order, t}
var _touch_order := 0
var _pinching := false
var _pinch_a := -2
var _pinch_b := -2
var _pinch_dist := 0.0
var _pinch_anchor := Vector2.ZERO
var _mouse_pos := Vector2(-1, -1)
var _mouse_inside := true
var _hover_tile := -1


static func now_ms() -> float:
	return Time.get_ticks_msec()


func _init(camera: MapCamera) -> void:
	rig = camera


func reset() -> void:
	_cancel_press()
	_forget_touches()
	set_hover_tile(-1)


func _forget_touches() -> void:
	_touches.clear()
	_pinching = false
	_pinch_a = -2
	_pinch_b = -2


## The window lost focus: an open press or pinch ends there.
func on_focus_lost() -> void:
	if _press_active or _pinching:
		_cancel_press()
		rig.halt()
	_press_active = false
	_forget_touches()
	mouse_left_window()


## Fingers the OS stopped reporting (a touch that left the window) are forgotten after a while.
func _prune_touches(stale_s: float) -> int:
	if _touches.is_empty():
		return 0
	var now := Time.get_ticks_msec() / 1000.0
	var drop := []
	for idx in _touches:
		if now - float(_touches[idx].t) > stale_s:
			drop.append(idx)
	for idx in drop:
		stats.stale_touches += 1
		_drop_touch(idx)
	return drop.size()


func _drop_touch(idx: int) -> void:
	if not _touches.has(idx):
		return
	_touches.erase(idx)
	if _pinching and (idx == _pinch_a or idx == _pinch_b):
		_pinching = false
	if _press_active and _press_index == idx:
		_cancel_press()
	if _touches.is_empty():
		_press_active = false


func _active() -> bool:
	return not active.is_valid() or bool(active.call())


func disable() -> void:
	if _press_active or _pinching:
		_cancel_press()
		rig.halt()
		_press_consumed = true
	_forget_touches()
	set_hover_tile(-1)


func enable() -> void:
	_cancel_press()
	_forget_touches()


func tick(delta: float) -> void:
	stats.ticks += 1
	if not _active():
		if _press_active or _hover_tile != -1:
			disable()
		return
	if _press_active and not _press_dragging and not _press_consumed and now_ms() - _press_ms >= LONG_PRESS_MS:
		_press_consumed = true
		tile_context.emit(_tile(_press_pos), _press_pos)
	_keyboard(delta)
	if _touches.is_empty() and not _press_dragging:
		var mp := _mouse_pos
		var vp := rig.viewport_size()
		var inside := mp.x >= 0 and mp.y >= 0 and mp.x < vp.x and mp.y < vp.y
		if inside and _mouse_inside and not (over_gui.is_valid() and over_gui.call(mp)):
			set_hover_tile(_tile(mp))
		else:
			set_hover_tile(-1)


func _tile(pos: Vector2) -> int:
	return int(tile_at.call(pos)) if tile_at.is_valid() else rig.tile_at_screen(pos)


func set_hover_tile(tile: int) -> void:
	if tile != _hover_tile:
		_hover_tile = tile
		tile_hovered.emit(tile)


func hover_tile() -> int:
	return _hover_tile


func mouse_left_window() -> void:
	_mouse_inside = false
	set_hover_tile(-1)


func mouse_entered_window() -> void:
	_mouse_inside = true


static func _down(a: Key, b: Key) -> bool:
	return Input.is_key_pressed(a) or Input.is_key_pressed(b)


func _keyboard(delta: float) -> void:
	var loop := Engine.get_main_loop()
	var focus: Control = (loop as SceneTree).root.gui_get_focus_owner() if loop is SceneTree else null
	if focus is LineEdit or focus is TextEdit:
		return
	var d := Vector2.ZERO
	if _down(KEY_A, KEY_LEFT):
		d.x -= 1
	if _down(KEY_D, KEY_RIGHT):
		d.x += 1
	if _down(KEY_W, KEY_UP):
		d.y -= 1
	if _down(KEY_S, KEY_DOWN):
		d.y += 1
	if d != Vector2.ZERO:
		rig.pan(d.normalized(), KEY_PAN_SPEED * delta)
	if not key_zoom:
		return
	var z := 0
	if _down(KEY_EQUAL, KEY_KP_ADD):
		z += 1
	if _down(KEY_MINUS, KEY_KP_SUBTRACT):
		z -= 1
	if z != 0:
		rig.zoom_by(pow(2.0, z * KEY_ZOOM_SPEED * delta))


## A Godot input event the HUD did not take. True when it was map input.
func input(e: InputEvent) -> bool:
	if e is InputEventScreenTouch:
		if e.pressed:
			if _active():
				_touch_down(e.index, e.position)
		else:
			_touch_up(e.index, e.position)
		return true
	if e is InputEventScreenDrag:
		if _active():
			_touch_drag(e.index, e.position)
		return true
	if not _active():
		return false
	if e is InputEventMouseButton:
		var pos: Vector2 = e.position
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				if not _touches.is_empty():
					return true  # (the mouse event a finger also sends)
				_mouse_pos = pos
				stats.mouse_presses += 1
				_pointer_down(MOUSE, pos, TAP_SLOP_MOUSE)
			elif _press_active and _press_index == MOUSE:
				_pointer_up(pos)
			return true
		if e.button_index == MOUSE_BUTTON_RIGHT:
			if e.pressed and _touches.is_empty():
				_cancel_press()
				tile_context.emit(_tile(pos), pos)
			return true
		if e.pressed and (e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			if Input.is_key_pressed(KEY_SHIFT):
				return false
			var k := pow(WHEEL_STEP, maxf(absf(e.factor), 1.0) if e.factor != 0.0 else 1.0)
			rig.zoom_by(k if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / k, rig.globe_hit(pos))
			return true
		return false
	if e is InputEventMouseMotion:
		var rel: Vector2 = e.position - _mouse_pos
		_mouse_pos = e.position
		_mouse_inside = true
		if _press_active and _press_index == MOUSE:
			_pointer_move(e.position, rel)
		return true
	# trackpad gestures (upstream's PointerAction)
	if e is InputEventMagnifyGesture:
		rig.zoom_by(e.factor, rig.globe_hit(e.position))
		return true
	if e is InputEventPanGesture:
		if e.delta.y != 0.0:
			rig.zoom_by(pow(1.035, -e.delta.y), rig.globe_hit(e.position))
		return true
	return false


func _touch_down(idx: int, pos: Vector2) -> void:
	if _touches.has(idx):
		return  # repeated press
	if _touches.size() >= 2:
		_prune_touches(STALE_TOUCH_S)
	if _touches.size() >= 2:
		return  # a third finger: ignore
	_touch_order += 1
	_touches[idx] = {"pos": pos, "pair_pos": pos, "order": _touch_order, "t": Time.get_ticks_msec() / 1000.0}
	stats.touch_presses += 1
	if _touches.size() == 2:
		_cancel_press()
		_press_consumed = true
		rig.halt()
		for k in _touches:
			_touches[k].pair_pos = _touches[k].pos
	_touch_on_globe(idx)


func _other(idx: int) -> int:
	for k in _touches:
		if k != idx:
			return k
	return -2


func _touch_on_globe(idx: int) -> void:
	if _touches.size() == 1:
		_pointer_down(idx, _touches[idx].pos, TAP_SLOP_TOUCH)
		return
	if _other(idx) != -2:
		_start_pinch()  # both fingers on the map: pinch at once


func _touch_up(idx: int, pos: Vector2) -> void:
	if not _touches.has(idx):
		return
	_touches.erase(idx)
	if _pinching and (idx == _pinch_a or idx == _pinch_b):
		_pinching = false
	if not _active():
		_cancel_press()
		return
	if _touches.is_empty():
		if _press_active and _press_index == idx:
			_pointer_up(pos)
		_press_active = false
		return
	var rest: int = _touches.keys()[0]
	_cancel_press()
	_pointer_down(rest, _touches[rest].pos, TAP_SLOP_TOUCH)
	_press_consumed = true


func _touch_drag(idx: int, pos: Vector2) -> void:
	if not _touches.has(idx):
		return
	var t: Dictionary = _touches[idx]
	var rel: Vector2 = pos - t.pos
	t.pos = pos
	t.t = Time.get_ticks_msec() / 1000.0
	if _pinching:
		_pinch_update()
		return
	if _touches.size() == 2:
		return  # a finger during a two-finger touch never drags the map
	if _press_active and _press_index == idx:
		_pointer_move(pos, rel)


func _start_pinch() -> void:
	var a := -2
	var b := -2
	for k in _touches:
		if a == -2 or int(_touches[k].order) < int(_touches[a].order):
			b = a
			a = k
		else:
			b = k
	if a == -2 or b == -2:
		return
	_pinching = true
	_pinch_a = a
	_pinch_b = b
	var pa: Vector2 = _touches[a].pos
	var pb: Vector2 = _touches[b].pos
	_pinch_dist = pa.distance_to(pb)
	_pinch_anchor = rig.globe_hit((pa + pb) * 0.5)
	_cancel_press()
	_press_consumed = true
	rig.halt()
	stats.pinches += 1


func _pinch_update() -> void:
	if not _touches.has(_pinch_a) or not _touches.has(_pinch_b):
		return
	var pa: Vector2 = _touches[_pinch_a].pos
	var pb: Vector2 = _touches[_pinch_b].pos
	var d := pa.distance_to(pb)
	if _pinch_dist > 1.0 and d > 1.0:
		rig.zoom_by(d / _pinch_dist, _pinch_anchor)
	_pinch_dist = d


func _pointer_down(index: int, pos: Vector2, slop: float) -> void:
	var moving := rig.is_moving(STOP_PX_PER_S)
	rig.halt()
	_press_active = true
	_press_index = index
	_press_pos = pos
	_press_ms = now_ms()
	_press_dragging = false
	_press_consumed = false
	_press_stop = moving  # a "stop" press: halts the map, never taps (it may still be held)
	_press_slop = slop
	if moving:
		stats.stop_presses += 1


func _pointer_move(pos: Vector2, rel: Vector2) -> void:
	if not _press_dragging:
		if pos.distance_to(_press_pos) <= _press_slop:
			return
		_press_dragging = true
		rig.begin_drag()
		set_hover_tile(-1)
		rel = pos - _press_pos
	rig.drag_by(rel)


func _pointer_up(pos: Vector2) -> void:
	if not _press_active:
		return
	_press_active = false
	if _press_dragging:
		_press_dragging = false
		rig.end_drag()
		return
	if _press_consumed or _press_stop:
		return
	var tile := _tile(pos)
	if tile >= 0:
		tile_clicked.emit(tile)


## Touch: where a finger is being held and how far along the long press is (0..1); null when
## nothing is being held. Drives the HoldRing.
func hold_state() -> Array:
	if not _press_active or _press_dragging or _press_consumed or _press_index == MOUSE or not _active():
		return [null, 0.0]
	return [_press_pos, clampf((now_ms() - _press_ms) / LONG_PRESS_MS, 0.0, 1.0)]


func is_dragging() -> bool:
	return _press_dragging or _pinching


func _cancel_press() -> void:
	if _press_dragging:
		rig.end_drag()
		rig.halt()
	_press_active = false
	_press_dragging = false


## Tests: drive the mouse press without events.
func debug_pointer(what: String, pos: Vector2) -> void:
	if what == "down":
		_pointer_down(MOUSE, pos, TAP_SLOP_MOUSE)
	elif what == "move":
		var rel := pos - _mouse_pos
		_mouse_pos = pos
		if _press_active:
			_pointer_move(pos, rel)
	elif what == "up":
		_pointer_up(pos)
