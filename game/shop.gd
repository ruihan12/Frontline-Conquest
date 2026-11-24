extends "res://game/end_screen.gd"
# Shop and arsenal (stars menu)

# The Arsenal window is client/ui/arsenal.gd (the port of UI/Arsenal.luau); `arsenal_dlg` is that
# window, so the game's own checks of it (Esc, modal) keep working.
func _open_shop() -> void:
	if client != null: client.open_arsenal()

func _close_shop() -> void:
	if client != null: client.arsenal.close()

func unlock_arsenal_item(id: String) -> bool:
	for it in ARSENAL:
		if it.id == id and not unlocked(id) and save.stars >= it.cost:
			save.stars -= it.cost
			save.unlocked.append(id)
			write_save()
			notify("%s unlocked in Shop!" % it.name, "good")
			_refresh_arsenal()
			return true
	return false

func _build_arsenal() -> void:
	pass

func _refresh_arsenal() -> void:
	if client != null and client.arsenal != null: client.arsenal.refresh()

func _end_icon(cc: Control, kk: int, col: Color) -> void:
	var o := Vector2(15, 15)
	match kk:
		0:
			cc.draw_arc(o, 11, 0, TAU, 24, col, 2, true); cc.draw_line(o - Vector2(11, 0), o + Vector2(11, 0), col, 1.5)
			cc.draw_arc(o, 5, -PI / 2, PI / 2, 10, col, 1.5); cc.draw_arc(o, 5, PI / 2, PI * 1.5, 10, col, 1.5)
		1:
			cc.draw_arc(o + Vector2(0, 4), 11, PI, TAU, 16, col, 6); cc.draw_line(o + Vector2(-14, 5), o + Vector2(14, 5), col, 2.5)
		2:
			cc.draw_line(o + Vector2(-10, -10), o + Vector2(10, 10), col, 3); cc.draw_line(o + Vector2(10, -10), o + Vector2(-10, 10), col, 3)
			cc.draw_circle(o, 4, col)
		3:
			cc.draw_arc(o, 11, 0, TAU, 24, col, 2, true); cc.draw_line(o, o + Vector2(0, -7), col, 2); cc.draw_line(o, o + Vector2(5, 3), col, 2)

# ================= v9: Settings & Graphics Modal + Password-Protected Tab Console =================
func _draw_gear(c: Control, o: Vector2, r: float, col: Color) -> void:
	for m in 8:
		var a := float(m) * TAU / 8.0
		c.draw_line(o + Vector2.from_angle(a) * (r * 0.65), o + Vector2.from_angle(a) * (r * 1.08), col, 2.6)
	c.draw_circle(o, r * 0.78, col)
	c.draw_circle(o, r * 0.36, Color(0.07, 0.09, 0.16))

func _open_settings() -> void:
	# The settings are upstream's own page of the game menu (client/ui/pause_menu.gd); this port has no window of its own.
	if client != null:
		client.open_settings_page()

func _build_settings() -> void:
	pass


func _input(e: InputEvent) -> void:
	_try_unlock_web_audio(e)
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_TAB:
			toggle_console()
			get_viewport().set_input_as_handled()
		elif console_panel != null and console_panel.visible:
			if e.keycode == KEY_ESCAPE:
				toggle_console()
				get_viewport().set_input_as_handled()
			elif console_unlocked and e.keycode == KEY_UP and not console_hist.is_empty():
				console_hist_i = maxi(0, console_hist_i - 1)
				console_in.text = console_hist[console_hist_i]
				console_in.caret_column = console_in.text.length()
				get_viewport().set_input_as_handled()
			elif console_unlocked and e.keycode == KEY_DOWN and not console_hist.is_empty():
				console_hist_i = mini(console_hist.size(), console_hist_i + 1)
				console_in.text = console_hist[console_hist_i] if console_hist_i < console_hist.size() else ""
				console_in.caret_column = console_in.text.length()
				get_viewport().set_input_as_handled()

## Console numbers: no NaN or infinity (they overflowed counters and labels), and a ceiling far above play.
func _cons_sane(v: float) -> float:
	if is_nan(v): return 0.0
	return clampf(v, -1.0e15, 1.0e15)

func _build_console() -> void:
	console_panel = _P(ui, Rect2(220, 70, 1160, 540), Color(0.04, 0.055, 0.11, 0.96), 8, ORANGE_Y, 2)
	console_panel.visible = false
	_head(console_panel, "TAB MENU  ·  PERFORMANCE & DEVELOPER CONSOLE", Vector2(20, 14), 16, ORANGE_Y)
	_T(console_panel, "Live FPS telemetry & password-protected developer command console.", Vector2(20, 38), 13, MUTED)
	# Prominent Live FPS Counter badge in the Tab Menu header
	var fps_pill := _P(console_panel, Rect2(620, 10, 470, 40), Color(0.08, 0.14, 0.12, 0.95), 8, GREEN, 1, false)
	console_fps_lbl = _T(fps_pill, "FPS: 180 / 180   ·   5.5 ms", Vector2(0, 9), 15, GREEN, f_bold, 470, HORIZONTAL_ALIGNMENT_CENTER)
	var x := _card_btn(console_panel, Rect2(1104, 12, 40, 36)); _close_x(x)
	x.pressed.connect(func(): toggle_console())
	# 1. Password Lock Gate ("5516")
	console_lock_box = Control.new()
	console_lock_box.position = Vector2(0, 60); console_lock_box.size = Vector2(1160, 480)
	console_lock_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	console_panel.add_child(console_lock_box)
	var lock_card := _P(console_lock_box, Rect2(310, 76, 540, 310), Color(0.07, 0.09, 0.17, 0.98), 8, Color(1, 0.72, 0.25, 0.45), 1, false)
	_draw_ctl(lock_card, Rect2(246, 24, 48, 52), func(cc: Control):
		cc.draw_rect(Rect2(8, 22, 32, 26), GOLD_C)
		cc.draw_arc(Vector2(24, 22), 11, PI, TAU, 16, GOLD_C, 4.0)
		cc.draw_circle(Vector2(24, 35), 4.0, Color(0.07, 0.09, 0.17)))
	_head(lock_card, "CONSOLE LOCKED", Vector2(0, 88), 22, TEXT, 540, HORIZONTAL_ALIGNMENT_CENTER)
	_T(lock_card, "Enter the 4-digit access password to unlock live game editing:", Vector2(0, 120), 14, MUTED, f_reg, 540, HORIZONTAL_ALIGNMENT_CENTER)
	console_pass_in = LineEdit.new()
	console_pass_in.position = Vector2(90, 162); console_pass_in.size = Vector2(230, 44)
	console_pass_in.placeholder_text = "Password..."
	console_pass_in.alignment = HORIZONTAL_ALIGNMENT_CENTER
	console_pass_in.add_theme_font_override("font", f_bold)
	console_pass_in.add_theme_font_size_override("font_size", 18)
	console_pass_in.add_theme_stylebox_override("normal", _flat(Color(0.04, 0.06, 0.12), 5, Color(1, 0.72, 0.25, 0.6), 1))
	console_pass_in.add_theme_stylebox_override("focus", _flat(Color(0.08, 0.11, 0.20), 5, ORANGE_Y, 2))
	console_pass_in.text_submitted.connect(func(txt: String): unlock_console(txt))
	lock_card.add_child(console_pass_in)
	var ul_btn := _big_btn(lock_card, Rect2(332, 162, 118, 44), "UNLOCK", ORANGE_Y, 15)
	ul_btn.pressed.connect(func(): unlock_console(console_pass_in.text))
	console_lock_msg = _T(lock_card, "Protected access · Enter password to continue", Vector2(0, 224), 13, MUTED, f_bold, 540, HORIZONTAL_ALIGNMENT_CENTER)
	# 2. Unlocked Console Body
	console_body = Control.new()
	console_body.position = Vector2(0, 0); console_body.size = Vector2(1160, 540)
	console_body.visible = false
	console_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	console_panel.add_child(console_body)
	x.move_to_front.call_deferred()
	var qbtns := [
		["+10M Gold", "gold +10000000"],
		["+100K Troops", "troops +100000"],
		["+10K Stars", "stars +10000"],
		["Unlock All", "unlock all"],
		["God Mode", "god"],
		["No Cooldowns", "no_cd"],
		["Peace = 0", "peace 0"],
		["Toggle MIRV", "mirv"],
		["Speed 20x", "speed 20"],
		["Inspect Vars", "vars"]
	]
	for k in qbtns.size():
		var qb := _card_btn(console_body, Rect2(20 + k * 112, 64, 108, 28))
		qb.text = qbtns[k][0]
		qb.add_theme_font_override("font", f_bold); qb.add_theme_font_size_override("font_size", 11)
		var cmd_str: String = qbtns[k][1]
		qb.pressed.connect(func(): run_console_cmd(cmd_str))
	var log_bg := _P(console_body, Rect2(20, 100, 1120, 372), Color(0.02, 0.03, 0.06, 0.95), 5, Color(1, 1, 1, 0.08), 1, false)
	console_log = RichTextLabel.new()
	console_log.position = Vector2(12, 8); console_log.size = Vector2(1096, 356)
	console_log.bbcode_enabled = true
	console_log.scroll_following = true
	console_log.add_theme_font_override("normal_font", f_reg)
	console_log.add_theme_font_override("bold_font", f_bold)
	console_log.add_theme_font_size_override("normal_font_size", 14)
	console_log.add_theme_font_size_override("bold_font_size", 14)
	log_bg.add_child(console_log)
	console_in = LineEdit.new()
	console_in.position = Vector2(20, 484); console_in.size = Vector2(990, 40)
	console_in.placeholder_text = "Enter command or assignment (e.g. gold 5000000, boat_speed = 6.0, NUKE_R[7] = 7, unlock all, spawn city 3, help)..."
	console_in.add_theme_font_override("font", f_bold)
	console_in.add_theme_font_size_override("font_size", 15)
	console_in.add_theme_stylebox_override("normal", _flat(Color(0.08, 0.10, 0.18), 5, Color(1, 0.72, 0.25, 0.6), 1))
	console_in.add_theme_stylebox_override("focus", _flat(Color(0.10, 0.13, 0.22), 5, ORANGE_Y, 2))
	console_in.text_submitted.connect(func(txt: String):
		if txt.strip_edges() != "":
			run_console_cmd(txt)
			console_in.clear()
		console_in.grab_focus())
	console_body.add_child(console_in)
	var run_b := _big_btn(console_body, Rect2(1020, 484, 120, 40), "EXECUTE", ORANGE_Y, 14)
	run_b.pressed.connect(func():
		if console_in.text.strip_edges() != "":
			run_console_cmd(console_in.text)
			console_in.clear()
		console_in.grab_focus())
	_clog("[color=#ffbe42][b]Frontline Conquest Developer Console Ready.[/b][/color] Type [b]help[/b] or [b]vars[/b], or edit any property (e.g. [b]gold 5000000[/b], [b]boat_speed = 6.0[/b], [b]NUKE_R[7] = 7[/b]).")

func unlock_console(code: String) -> bool:
	if code.strip_edges() == CONSOLE_PASS:
		console_unlocked = true
		console_lock_box.visible = false
		console_body.visible = true
		_clog("[color=#66e08c][b]Access granted (code 5516). Developer Console unlocked.[/b][/color]")
		if console_panel and console_panel.visible:
			console_in.grab_focus()
		return true
	console_lock_msg.text = "Access denied — invalid password"
	console_lock_msg.add_theme_color_override("font_color", RED)
	console_pass_in.clear()
	return false

func _update_console_fps(dt: float) -> void:
	if dt > 0.0001 and dt < 1.0:
		_fps_ema_ms = lerpf(_fps_ema_ms, dt * 1000.0, 0.12)
		if dt * 1000.0 >= _fps_hitch_ms:
			_fps_hitch_ms = dt * 1000.0
		_fps_hitch_t += dt
		if _fps_hitch_t >= 1.0:
			_fps_hitch_ms = lerpf(_fps_hitch_ms, _fps_ema_ms, 0.35)
			_fps_hitch_t = 0.0
	if console_panel == null or not console_panel.visible or console_fps_lbl == null:
		return
	var fps_now := int(Engine.get_frames_per_second())
	if fps_now <= 0: fps_now = int(round(1000.0 / maxf(0.5, _fps_ema_ms)))
	var cap_now := Engine.max_fps
	var cap_s := "rAF" if (OS.has_feature("web") and cap_now <= 0) else str(cap_now if cap_now > 0 else "inf")
	var avg_ms := 1000.0 / maxf(1.0, float(fps_now))
	var res_i := clampi(int(save.get("settings", {}).get("res_i", 3)), 0, RES_LIST.size() - 1)
	var r_v: Vector2i = RES_LIST[res_i]
	console_fps_lbl.text = "FPS %d / %s   ·   %.1f ms   ·   hitch %.0f ms   ·   %dp" % [fps_now, cap_s, avg_ms, _fps_hitch_ms, r_v.y]

func toggle_console() -> void:
	if console_panel == null: return
	if not console_panel.visible and state != "play" and state != "pick": return  # no console on the title / end screens
	console_panel.visible = not console_panel.visible
	if console_panel.visible:
		_update_console_fps(0.0055)
		console_lock_box.visible = not console_unlocked
		console_body.visible = console_unlocked
		if console_unlocked:
			console_in.grab_focus()
		else:
			console_pass_in.grab_focus()
	else:
		console_in.release_focus()
		console_pass_in.release_focus()

func _clog(msg: String) -> void:
	if console_log:
		console_log.append_text(msg + "\n")

func _eval_expr(expr_str: String):
	var ex := Expression.new()
	if ex.parse(expr_str) != OK:
		return null
	return ex.execute([], self, false)

var _fps_ema_ms := 5.5
var _fps_hitch_ms := 0.0
var _fps_hitch_t := 0.0

func _console_spawn(parts: PackedStringArray) -> void:
	var q := parts[1].to_lower()
	var lvl := int(parts[2]) if parts.size() >= 3 and parts[2].is_valid_int() else 1
	lvl = clampi(lvl, 1, 1000)  # (a huge level froze the per-level spawn loops)
	var ship_kind := ""
	if q in ["warship", "wars", "ws"] or q == "6":
		ship_kind = "warship"
	elif q in ["boat", "transport", "ship"]:
		ship_kind = "boat"
	elif q in ["trade", "trader", "cargo"]:
		ship_kind = "trade"
	var k := int(q) if q.is_valid_int() else -1
	if k < 0 and ship_kind == "":
		for m in build_data.size():
			if str(build_data[m][1]).to_lower().begins_with(q):
				k = m
				break
	if k == 6:
		ship_kind = "warship"
	if ship_kind == "" and k < 0:
		_clog("Unknown spawn kind [b]%s[/b]. Try city, port, sam, silo, warship, boat." % q)
		return
	var t := _mouse_tile()
	if t < 0 and nations.size() > PLAYER and nations[PLAYER].land > 0:
		t = int(nations[PLAYER].sy / nations[PLAYER].land) * W + int(nations[PLAYER].sx / nations[PLAYER].land)
	if ship_kind != "":
		var wt := SpawnSnap.water_near(owner_map, W, H, t, 64)
		if wt < 0:
			_clog("No water near the cursor to spawn a %s." % ship_kind)
			return
		var o := PLAYER
		var pos := Vector2(wt % W + 0.5, wt / W + 0.5)
		if ship_kind == "warship":
			var ws := {"o": o, "pos": pos, "home": wt, "hp": 1000.0, "vet": 0, "kills": 0, "tgt": pos, "cd": 0.0}
			if sim_ws: sim_ws.init_ship(ws)
			ws["patrol"] = pos
			warships.append(ws)
			_clog("Spawned Warship on water at tile %d." % wt)
		elif ship_kind == "boat":
			boats.append({"a": o, "troops": 0.0, "pts": PackedVector2Array([pos, pos]), "cum": PackedFloat32Array([0.0, 0.0]), "d": 0.0, "dest": wt, "sid": rng.randi() % 10, "uid": boat_uid})
			boat_uid += 1
			_clog("Spawned transport boat on water at tile %d." % wt)
		else:
			traders.append({"o": o, "pts": PackedVector2Array([pos, pos]), "cum": PackedFloat32Array([0.0, 0.0]), "d": 0.0, "dst": null, "gold": 0.0})
			_clog("Spawned trade ship on water at tile %d." % wt)
		overlay.queue_redraw()
		return
	var prefer := PLAYER
	if t >= 0 and t < W * H and owner_map[t] > 0:
		prefer = owner_map[t]
	var occ := {}
	for tile in struct_at:
		occ[tile] = true
	var land := SpawnSnap.owned_land_near(owner_map, occ, W, H, t, prefer, 64)
	if land < 0:
		_clog("No owned land near the cursor to spawn a %s." % str(build_data[k][1]))
		return
	var o: int = owner_map[land]
	_struct_add(k, land, o)
	struct_at[land].level = lvl
	struct_at[land].bt = 0.0
	_sv += 1
	var lvtxt := _fmt_hud(float(lvl)) if lvl >= 1000 else str(lvl)
	_clog("Spawned %s Lv%s at tile %d for %s." % [build_data[k][1], lvtxt, land, _nname(o)])
	overlay.queue_redraw()

func run_console_cmd(raw: String) -> void:

	var cmd := raw.strip_edges()
	if cmd == CONSOLE_PASS:
		unlock_console(cmd)
		return
	if cmd.begins_with("/"): cmd = cmd.substr(1).strip_edges()
	if cmd == "": return
	console_hist.append(cmd)
	console_hist_i = console_hist.size()
	_clog("[color=#59ccff]> %s[/color]" % cmd)
	var low := cmd.to_lower()
	var parts := cmd.split(" ", false)
	var head := parts[0].to_lower() if parts.size() > 0 else ""
	if head in ["help", "?"]:
		_clog("[b]Commands (no leading slash needed):[/b]")
		_clog("  [b]gold <val|+val>[/b] · [b]troops <val|+val>[/b] · [b]stars <val|+val>[/b] · [b]speed <mult>[/b] · [b]peace <sec>[/b]")
		_clog("  [b]unlock all[/b] | [b]lock all[/b] | [b]unlock <id>[/b] · [b]god[/b] · [b]inf_gold[/b] · [b]no_cd[/b] · [b]mirv[/b]")
		_clog("  [b]claim <radius>[/b] · [b]spawn <building|warship|boat> [level][/b] (buildings snap to owned land near the cursor, ships to water) · [b]nuke <7|8|11|12> [tile][/b]")
		_clog("  [b]nation <id_or_name> <gold|troops|alive|prot> <val>[/b] · [b]win[/b] · [b]lose[/b] · [b]vars[/b] · [b]clear[/b]")
		_clog("  [b]Any assignment or GDScript expression:[/b] e.g. [b]boat_speed = 6.0[/b], [b]NUKE_R[7] = 27[/b], [b]nations[1].gold = 9e8[/b]")
		return
	if head == "clear":
		console_log.clear(); return
	if head == "vars":
		var pg: float = nations[PLAYER].gold if nations.size() > PLAYER else 0.0
		var pt: float = nations[PLAYER].troops if nations.size() > PLAYER else 0.0
		_clog("[b]Live Editable Variables:[/b]")
		_clog("  gold = %s  |  troops = %s / %s  |  save.stars = %d" % [_fmt(pg), _fmt(pt), _fmt(troop_cap(PLAYER) if nations.size() > PLAYER else 0.0), save.stars])
		_clog("  sim_speed = %.2fx (raw %.2f)  |  peace = %.1fs  |  boat_speed = %.2f" % [sim_speed / SPEED_BASE, sim_speed, maxf(0.0, peace - elapsed), boat_speed])
		_clog("  NUKE_R = %s  |  mirv_enabled = %s" % [str(NUKE_R), str(mirv_enabled)])
		_clog("  god_mode = %s  |  inf_gold = %s  |  no_cd = %s  |  traders = %d  |  trains = %d" % [str(god_mode), str(inf_gold), str(no_cd), traders.size(), trains.size()])
		return
	if head == "god":
		god_mode = not god_mode
		if god_mode and nations.size() > PLAYER:
			nations[PLAYER].gold = maxf(nations[PLAYER].gold, 999e6)
			nations[PLAYER].troops = troop_cap(PLAYER)
		_clog("god_mode = [b]%s[/b]" % str(god_mode)); _update_hud(); return
	if head == "inf_gold":
		inf_gold = not inf_gold
		if inf_gold and nations.size() > PLAYER: nations[PLAYER].gold = maxf(nations[PLAYER].gold, 999e6)
		_clog("inf_gold = [b]%s[/b]" % str(inf_gold)); _update_hud(); return
	if head == "no_cd":
		no_cd = not no_cd
		_clog("no_cd = [b]%s[/b]" % str(no_cd)); _update_hud(); return
	if head == "mirv":
		mirv_enabled = not mirv_enabled
		_clog("mirv_enabled = [b]%s[/b]" % str(mirv_enabled)); _refresh_arsenal(); _update_hud(); return
	if head == "leaderboard":
		if hud_nodes.size() > 2: hud_nodes[2].visible = not hud_nodes[2].visible
		_clog("Toggled leaderboard visibility."); return
	if head == "win":
		_game_over(true); _clog("Triggered VICTORY."); return
	if head == "lose":
		_game_over(false); _clog("Triggered DEFEAT."); return
	if head in ["gold", "troops", "stars", "speed", "peace"] and parts.size() >= 2 and parts[1] != "=":
		var arg := parts[1]
		var add_mode := arg.begins_with("+")
		var val := _cons_sane(float(arg))
		if head == "gold" and nations.size() > PLAYER:
			nations[PLAYER].gold = (nations[PLAYER].gold + val) if add_mode else val
			_clog("Player gold -> [b]%s[/b]" % _fmt(nations[PLAYER].gold))
		elif head == "troops" and nations.size() > PLAYER:
			nations[PLAYER].troops = (nations[PLAYER].troops + val) if add_mode else val
			_clog("Player troops -> [b]%s[/b]" % _fmt(nations[PLAYER].troops))
		elif head == "stars":
			save.stars = (save.stars + int(val)) if add_mode else int(val)
			write_save(); _refresh_arsenal()
			_clog("Stars -> [b]%s[/b]" % _fmt_int(save.stars))
		elif head == "speed":
			sim_speed = maxf(0.05, val * SPEED_BASE)
			_clog("Simulation speed -> [b]%.2fx[/b]" % val)
		elif head == "peace":
			peace = elapsed + val
			_clog("Peace timer -> [b]%.1fs remaining[/b]" % val)
		_update_hud(); return
	if head == "unlock" and parts.size() >= 2:
		var target_u := parts[1].to_lower()
		if target_u == "all":
			for it in ARSENAL:
				if not (it.id in save.unlocked): save.unlocked.append(it.id)
			write_save(); _refresh_arsenal(); _update_hud()
			_clog("Unlocked all 8 Arsenal items: [b]%s[/b]" % str(save.unlocked))
		else:
			if not (target_u in save.unlocked): save.unlocked.append(target_u)
			write_save(); _refresh_arsenal(); _update_hud()
			_clog("Unlocked [b]%s[/b]" % target_u)
		return
	if head == "lock" and parts.size() >= 2 and parts[1].to_lower() == "all":
		save.unlocked = []
		write_save(); _refresh_arsenal(); _update_hud()
		_clog("Locked all Arsenal items."); return
	if head == "claim":
		var rad := int(parts[1]) if parts.size() >= 2 else 15
		var t := _mouse_tile()
		if t < 0 and nations.size() > PLAYER and nations[PLAYER].land > 0:
			t = int(nations[PLAYER].sy / nations[PLAYER].land) * W + int(nations[PLAYER].sx / nations[PLAYER].land)
		if t >= 0:
			_claim_blob(PLAYER, t, clampi(rad, 1, 120))
			_clog("Claimed radius %d around tile %d for Player." % [rad, t])
		return
	if head == "spawn" and parts.size() >= 2:
		_console_spawn(parts)
		return
	if head == "nation" and parts.size() >= 4:
		var q := parts[1].to_lower()
		var prop := parts[2].to_lower()
		var val_s := parts[3]
		var nid := int(q) if q.is_valid_int() else -1
		if nid < 0:
			for id in range(1, nations.size()):
				if nations[id].name.to_lower().find(q) >= 0: nid = id; break
		if nid > 0 and nid < nations.size():
			var n = nations[nid]
			if prop in ["gold", "troops"]:
				n[prop] = _cons_sane(float(val_s))
			elif prop in ["alive", "prot"]:
				n[prop] = (val_s.to_lower() in ["true", "1", "yes"])
			else:
				n[prop] = _eval_expr(val_s)
			_clog("Updated nation #%d (%s) %s -> [b]%s[/b]" % [nid, n.name, prop, str(n[prop])])
			_update_hud()
		return
	# Universal assignment handler: e.g. boat_speed = 6.0, NUKE_R[7] = 27, nations[1].gold = 9e8, gold = 5000000
	if "=" in cmd and not ("==" in cmd):
		var eq := cmd.find("=")
		var lhs := cmd.substr(0, eq).strip_edges()
		var rhs := cmd.substr(eq + 1).strip_edges()
		var val = _eval_expr(rhs)
		if val == null and rhs.is_valid_float(): val = float(rhs)
		if lhs == "gold" and nations.size() > PLAYER:
			nations[PLAYER].gold = _cons_sane(float(val)); _clog("gold = [b]%s[/b]" % _fmt(nations[PLAYER].gold)); _update_hud(); return
		if lhs == "troops" and nations.size() > PLAYER:
			nations[PLAYER].troops = _cons_sane(float(val)); _clog("troops = [b]%s[/b]" % _fmt(nations[PLAYER].troops)); _update_hud(); return
		if lhs == "stars" or lhs == "save.stars":
			save.stars = int(val); write_save(); _refresh_arsenal(); _clog("save.stars = [b]%d[/b]" % save.stars); return
		if "[" in lhs and lhs.ends_with("]"):
			var b0 := lhs.find("[")
			var cname := lhs.substr(0, b0).strip_edges()
			var kexpr := lhs.substr(b0 + 1, lhs.length() - b0 - 2).strip_edges()
			var target_c = get(cname) if cname != "nuke_r" else NUKE_R
			var key_v = _eval_expr(kexpr)
			if target_c != null and key_v != null:
				target_c[key_v] = val
				_clog("%s[%s] = [b]%s[/b]" % [cname, str(key_v), str(val)]); _update_hud(); return
		if "." in lhs:
			var dot := lhs.rfind(".")
			var obj_e := lhs.substr(0, dot).strip_edges()
			var field := lhs.substr(dot + 1).strip_edges()
			var obj = _eval_expr(obj_e)
			if obj != null:
				obj[field] = val
				_clog("%s.%s = [b]%s[/b]" % [obj_e, field, str(val)]); _update_hud(); return
		set(lhs, val)
		_clog("%s = [b]%s[/b]" % [lhs, str(get(lhs))]); _update_hud(); return
	# Fallback: evaluate any GDScript expression or method call on self
	var res = _eval_expr(cmd)
	_clog("=> [b]%s[/b]" % str(res))
	_update_hud()
