# MapCamera (client/map/map_camera.gd) and its hookup to main.gd's Camera2D.
#   godot --headless --path . --script tests/test_map_camera.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	var c := MapCamera.new(2000, 1000, Vector2(1600, 900))
	_check(is_equal_approx(c.scale, 0.72), "starts fitted with the margin (%.3f)" % c.scale)
	_check(is_equal_approx(c.max_scale(), 44.0), "max scale at 900 px")
	# zoom toward a point: it stays under the same screen point
	var sp := Vector2(1200, 300)
	var held := c.globe_hit(sp)
	c.zoom_by(4.0, held)
	for i in 120: c.tick(1.0 / 60.0)
	var back := c.map_to_screen(held.x, held.y)
	_check(is_equal_approx(c.scale, 2.88) and back.distance_to(sp) < 0.5, "zoom eases to the target and holds the anchor (%s)" % back)
	# clamp: zoomed in, the centre itself stays on the map
	c.look_at(-500, -500)
	_check(is_equal_approx(c.cu, 0.0) and is_equal_approx(c.cv, 0.0), "zoomed in, the centre stops at the map's edge")
	# fitted: the map is centred whatever is asked
	c.set_scale_immediate(c.min_scale())
	c.look_at(0, 0)
	_check(is_equal_approx(c.cu, 1000.0) and is_equal_approx(c.cv, 500.0), "a map smaller than the screen is centred")
	# drag and inertia
	c.set_scale_immediate(4.0)
	c.look_at(1000, 500)
	c.begin_drag()
	c._last_drag_ms = MapCamera.now_ms() - 16.0
	c.drag_by(Vector2(-40, 0))
	c._last_drag_ms = MapCamera.now_ms() - 16.0
	c.drag_by(Vector2(-40, 0))
	_check(is_equal_approx(c.cu, 1020.0), "drag moves the centre by px / scale")
	c.end_drag()
	var u0 := c.cu
	for i in 30: c.tick(1.0 / 60.0)
	_check(c.cu > u0 + 1.0, "release keeps gliding (%.1f tiles)" % (c.cu - u0))
	for i in 600: c.tick(1.0 / 60.0)
	_check(not c.is_moving(1.0), "inertia dies out")
	# focus glide
	c.focus(300, 300, 8.0, 1.0)
	c.tick(0.5)
	_check(c.scale < 4.0, "a long hop pulls back mid-way (%.2f)" % c.scale)
	c.tick(0.6)
	_check(is_equal_approx(c.cu, 300.0) and is_equal_approx(c.scale, 8.0), "focus lands on the target and scale")
	_check(c.tile_at_screen(Vector2(800, 450)) == 300 * 2000 + 300, "tile under the screen centre")

	# hooked to the game's Camera2D
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	for _f in 3: await process_frame
	m.map_tab = 0; m.map_i = 0
	m.gen_map()
	m._start_game()
	for _f in 3: await process_frame
	_check(m._mcam_on(), "the ported camera is on in normal play")
	var z0: float = m.cam.zoom.x
	m._zoom_at(1.5, Vector2(400, 300))
	for _f in 40: await process_frame
	_check(m.cam.zoom.x > z0 * 1.3, "wheel zoom reaches the Camera2D (%.2f -> %.2f)" % [z0, m.cam.zoom.x])
	m.cam.position = Vector2(m.W, m.H) * m.TS * 0.5
	m.cam.zoom = Vector2(3, 3)
	for _f in 2: await process_frame
	_check(is_equal_approx(m.mcam.scale, 3.0 * m.TS) and is_equal_approx(m.mcam.cu, m.W * 0.5), "a direct Camera2D write is taken over")
	var t: int = (m.H / 3) * m.W + m.W / 3
	m.client.ctx.world.focus_tile(t, -1.0, 0.3)
	for _f in 60: await process_frame
	_check(absf(m.cam.position.x / m.TS - (m.W / 3 + 0.5)) < 1.0, "focus_tile glides the Camera2D there")
	# MapInput: click, drag, stop press, long press, wheel, pinch
	for _f in 30: await process_frame
	m.mcam.halt()
	var mi = m.minput
	if mi == null:
		m._make_minput()
		mi = m.minput
	var clicks := []
	var ctxs := []
	mi.tile_clicked.connect(func(tl): clicks.append(tl))
	mi.tile_context.connect(func(tl, _p): ctxs.append(tl))
	mi._mouse_pos = Vector2(700, 400)
	mi.debug_pointer("down", Vector2(700, 400))
	mi.debug_pointer("move", Vector2(703, 401))
	mi.debug_pointer("up", Vector2(703, 401))
	_check(clicks.size() == 1 and clicks[0] == m.mcam.tile_at_screen(Vector2(703, 401)), "a press within the slop is a click on that tile")
	var cu0: float = m.mcam.cu
	mi.debug_pointer("down", Vector2(700, 400))
	mi.debug_pointer("move", Vector2(760, 400))
	_check(mi.is_dragging() and m.mcam.cu < cu0, "a press that moves drags the map")
	mi.debug_pointer("up", Vector2(760, 400))
	_check(clicks.size() == 1 and not mi.is_dragging(), "a drag is not a click")
	m.mcam._vel = Vector2(400, 0)
	mi.debug_pointer("down", Vector2(700, 400))
	mi.debug_pointer("up", Vector2(700, 400))
	_check(clicks.size() == 1 and not m.mcam.is_moving(1.0), "a press on a gliding map only stops it")
	mi.debug_pointer("down", Vector2(700, 400))
	mi._press_ms -= 600.0
	mi.tick(0.016)
	mi.debug_pointer("up", Vector2(700, 400))
	_check(ctxs.size() == 1 and clicks.size() == 1, "a held press opens the context menu instead of clicking")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	ev.position = Vector2(500, 500)
	var ts0: float = m.mcam.target_scale
	mi.input(ev)
	_check(is_equal_approx(m.mcam.target_scale, m.mcam.clamp_scale(ts0 * 1.16)), "one wheel notch zooms by 1.16")
	m.mcam.set_scale_immediate(4.0)
	mi._touch_down(0, Vector2(600, 400))
	mi._touch_down(1, Vector2(800, 400))
	mi._touch_drag(1, Vector2(1000, 400))
	_check(mi.stats.pinches == 1 and is_equal_approx(m.mcam.target_scale, 8.0), "two fingers spreading to twice the distance double the zoom")
	mi._touch_up(1, Vector2(1000, 400))
	mi._touch_up(0, Vector2(600, 400))
	_check(clicks.size() == 1, "a pinch never clicks")
	mi._touch_down(0, Vector2(650, 420))
	var hs: Array = mi.hold_state()
	_check(hs[0] == Vector2(650, 420), "a resting finger reports its hold (for the ring)")
	mi._touch_up(0, Vector2(650, 420))
	_check(clicks.size() == 2, "a finger tap is a click")
	# the real event path: a left press and release on the map reaches UIInteract
	m.client.interact.enabled = true
	m.client.interact.last_pick = -1
	m.client.interact._last_click_tile = -1
	m.mcam.halt()
	m.mcam.look_at(m.W * 0.5, m.H * 0.5)
	await process_frame
	var at := Vector2(805, 455)
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.pressed = down
		b.position = at
		b.global_position = at
		m._unhandled_input(b)
	_check(m.client.interact._last_click_tile >= 0, "a mouse click event reaches UIInteract.on_click (state %s)" % m.state)
	print("MAP_CAMERA_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
