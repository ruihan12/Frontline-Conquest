# Locker screenshots: xvfb-run -a -s "-screen 0 1456x760x24" godot --path . --resolution 1456x760 --script tests/crates_shot.gd -- --out=DIR
extends SceneTree
func _initialize() -> void:
	var out := "/tmp/claude-0/shot"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.substr(6)
	var m = load("res://main.tscn").instantiate()
	root.add_child(m)
	for _f in 10: await process_frame
	m.shots_dir = out
	if m.client.title != null: m.client.title.finish_show()
	m.save.stars = 20000
	m.client.crates.open()
	for _f in 40: await process_frame
	m._shot("e_locker.png")
	for i in 3: m.client.ctx.session.open_crate()
	m.client.crates._refresh()
	for _f in 40: await process_frame
	m._shot("f_locker_after.png")
	print("CRATES_SHOT done")
	quit(0)
