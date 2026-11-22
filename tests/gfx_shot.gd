# Renders a World match for visual checks (not headless):
#   xvfb-run -s "-screen 0 1920x1080x24" godot --path . --resolution 1920x1080 --script tests/gfx_shot.gd -- --out=/workspace/shots/gfx
extends SceneTree

var out := "/workspace/shots/gfx"

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	for _f in 10: await process_frame
	m.shots_dir = out
	if m.client != null and m.client.title != null: m.client.title.finish_show()
	for _f in 20: await process_frame
	m._shot("00_menu.png")
	m.map_tab = 0; m.map_i = 0
	m._start_game()
	var guard := 0
	while m._loading and guard < 4000:
		await process_frame
		guard += 1
	for _f in 20: await process_frame
	m._rw_full_view()
	for _f in 10: await process_frame
	m._shot("01_world_spawn.png")
	var st: int = m._find_spawn_tile(m.W / 2, m.H / 3)
	m._place_start(st); m.deploy_t = 0.0
	m.launch_attack(m.PLAYER, m.NEUTRAL, 0.5)
	m.set_speed(m.SPEEDS.size() - 1)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 25000: await process_frame
	m.set_speed(1)
	m._rw_full_view()
	for _f in 10: await process_frame
	m._shot("02_world_play.png")
	m.cam.zoom = Vector2(0.48, 0.48); m.cam.position = Vector2(m.W, m.H) * m.TS / 2; m._clamp_cam()
	for _f in 10: await process_frame
	m._shot("05_world_full.png")
	m.cam.zoom = Vector2(0.9, 0.9); m.cam.position = Vector2(m.W * 0.3, m.H * 0.35) * m.TS; m._clamp_cam()
	for _f in 10: await process_frame
	m._shot("06_world_mid.png")
	m.cam.zoom = Vector2(3, 3); m.cam.position = Vector2(m.W * 0.52, m.H * 0.28) * m.TS; m._clamp_cam()
	for _f in 10: await process_frame
	m._shot("03_europe_zoom.png")
	m._focus_player(4.0)
	for _f in 10: await process_frame
	m._shot("04_player_zoom.png")
	print("GFX_SHOT done")
	quit(0)
