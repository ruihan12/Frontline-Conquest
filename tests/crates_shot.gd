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
	for _f in 60: await process_frame
	m._shot("a_title.png")
	m.save.stars = 20000
	m.client.crates.open()
	for _f in 40: await process_frame
	m._shot("e_locker.png")
	m.save.stars = 400000
	var cr = m.client.crates
	cr._start_open(1)
	for tt in [1.0, 1.7, 3.2]:
		cr._rt = tt
		for _f in 4: await process_frame
		cr._rt = tt
		m._shot("g_open_%d.png" % int(tt * 10))
	cr._end_show()
	cr._start_open(10)
	cr._rt = 3.6
	for _f in 6: await process_frame
	m._shot("h_open10.png")
	cr._end_show()
	for _f in 20: await process_frame
	m._shot("i_after.png")
	print("CRATES_SHOT done")
	quit(0)
