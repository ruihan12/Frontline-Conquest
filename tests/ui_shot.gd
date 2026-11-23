# Upstream-comparison shots at the user's window size (not headless):
#   xvfb-run -a -s "-screen 0 1456x760x24" godot --path . --resolution 1456x760 --script tests/ui_shot.gd -- --out=DIR
extends SceneTree
var out := "/tmp/claude-0/shot"
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
	m._shot("a_title.png")
	m.map_tab = 0; m.map_i = 0
	m._start_game()
	var guard := 0
	while m._loading and guard < 4000:
		await process_frame
		guard += 1
	for _f in 30: await process_frame
	m._shot("b_spawn.png")
	var st: int = m._find_spawn_tile(m.W / 2, m.H / 3)
	m._place_start(st); m.deploy_t = 0.0
	for _f in 30: await process_frame
	m._shot("c_placed.png")
	m.set_speed(m.SPEEDS.size() - 1)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 12000: await process_frame
	m.set_speed(1)
	m._focus_player(2.0)
	if m.client != null and m.client.hud != null: m.client.hud.board.set_open(true)
	for _f in 20: await process_frame
	m._shot("d_play.png")
	print("UI_SHOT done")
	quit(0)
