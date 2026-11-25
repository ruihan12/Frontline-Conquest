extends SceneTree
# Party rules (net/party.gd) and the title-screen party panel (client/ui/party_panel.gd), phone and desktop.

var fails := 0
var _t := 0.0


func _check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		print("FAIL ", message)


func _initialize() -> void:
	create_timer(20).timeout.connect(func() -> void:
		print("PARTY_TEST FAIL timeout")
		quit(1))
	_run.call_deferred()


func _rules() -> void:
	var P := preload("res://net/party.gd")
	var p := P.new(func() -> float: return _t)
	for i in range(1, 12):
		p.names[i] = "P%d" % i
	_check(p.state(1).members.is_empty() and p.state(1).leader, "alone: no party, leader")
	_check(not p.invite(1, 1).ok, "cannot invite yourself")
	_check(p.invite(1, 2).ok, "invite")
	_check(not p.invite(1, 2).ok, "invite gap")
	_check(p.state(2).invites.size() == 1, "invite shows")
	_check(p.accept(2, 1).ok, "accept")
	_check(p.state(1).members.size() == 2 and p.is_leader(1) and not p.is_leader(2), "leader is the inviter")
	_check(not p.invite(1, 2).ok, "already in party")
	p.kick(2, 1)
	_check(p.state(1).members.size() == 2, "a member cannot kick")
	for i in range(3, 9):
		_t += 5.0
		p.invite(1, i)
		p.accept(i, 1)
	_check(p.state(1).members.size() == 8, "party of 8")
	_t += 5.0
	_check(not p.invite(1, 9).ok, "party full")
	p.kick(1, 8)
	_check(p.state(1).members.size() == 7 and p.state(8).members.is_empty(), "kick")
	p.leave(1)
	_check(p.is_leader(2) and p.state(2).members.size() == 6, "next member leads")
	_t += 5.0
	p.invite(9, 2)
	_t += 61.0
	_check(p.state(2).invites.is_empty(), "invite expires")
	_check(not p.accept(2, 9).ok, "expired accept refused")
	for i in range(3, 8):
		p.leave(i)
	_check(p.state(2).members.is_empty(), "one left alone is no party")


func _run() -> void:
	_rules()
	var ctx := UICtx.new()
	var panel := PartyPanel.new(ctx)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	host.add_child(panel)
	var model := PartyModel.new("You")
	panel.bind(model)
	panel.notice.connect(func(_t: String) -> void: pass)
	await process_frame
	# phone
	ctx.vp = Vector2(844, 390)
	ctx.compact = true
	ctx.insets = Vector4(47, 0, 47, 21)
	ctx.reserved_top_left = Rect2(0, 0, 300, 52)
	panel.apply_layout()
	await process_frame
	_check(panel.visible and panel._pill.visible, "phone: PARTY pill shows")
	_check(not panel._panel.visible, "phone: panel closed until opened")
	_check(panel._pill.position.x == 59.0 and panel._pill.position.y == 58.0, "phone: pill under the top bar, inside the inset (%s)" % panel._pill.position)
	panel._pill.pressed.emit()
	await process_frame
	_check(panel._panel.visible and panel._leave_btn.visible == false, "phone: opens, no LEAVE alone")
	_check(panel._hint.text.begins_with("Play public matches"), "phone: hint text")
	panel._invite_btn.pressed.emit()
	await process_frame
	_check(panel._list.visible and not panel._panel.visible, "phone: list takes the panel's place")
	_check(panel._list_rows.get_child_count() == 9, "list shows the 9 stand-ins")
	_check(panel._list_scroll.custom_minimum_size.y <= ctx.clear_rect().end.y, "list scrolls inside the screen")
	var first: Button = panel._list_rows.get_child(0).get_child(1)
	first.pressed.emit()
	await process_frame
	var sent: Button = panel._list_rows.get_child(0).get_child(1)
	_check(sent.text == "SENT" and sent.disabled, "button shows SENT")
	panel.close_list()
	# a stand-in invites you: phones open the panel
	model.preview_invite_from(4)
	await process_frame
	_check(panel._invites.get_child_count() == 1 and panel.is_open and panel._panel.visible, "invite opens the panel")
	panel._invites.get_child(0).get_child(1).get_child(0).pressed.emit()
	await process_frame
	_check(model.state().members.size() == 2 and not model.state().leader, "joined as a member")
	_check(panel._hint.text.begins_with("Your party leader"), "follower hint")
	_check(panel._pill.text == "PARTY  2", "pill shows the count")
	# desktop: leader of a full party shows two columns and kick buttons
	ctx.vp = Vector2(1600, 900)
	ctx.compact = false
	ctx.insets = Vector4.ZERO
	panel._leave_btn.pressed.emit()
	await process_frame
	_check(model.state().members.is_empty(), "leave dissolves the pair")
	for i in range(2, 8):
		_t += 5.0
		model.party.invite(1, i)
		model.party.accept(i, 1)
	model.changed.emit()
	await process_frame
	await process_frame
	_check(panel._wide and panel._members.get_child_count() == 2, "7 members: two columns")
	_check(panel._panel.size.x >= PartyPanel.WIDTH_WIDE - 1.0, "wide panel (%s)" % panel._panel.size)
	_check(panel._count.text == "7 / 8", "count")
	_check(not panel._pill.visible and panel._panel.visible, "desktop: no pill, panel always shown")
	_check(panel._panel.position.x == 16.0, "desktop: left edge (%s)" % panel._panel.position)
	_check(absf(panel._panel.position.y + panel._panel.size.y * 0.5 - 450.0) < 2.0, "desktop: vertically centred")
	var kicks := 0
	for col in panel._members.get_children():
		for row in col.get_children():
			if row.get_child_count() == 3:
				kicks += 1
	_check(kicks == 6, "leader sees 6 kick buttons (%d)" % kicks)
	panel._invite_btn.pressed.emit()
	await process_frame
	_check(panel._list.visible and panel._list_rows.get_child_count() == 3, "list shows the remaining 3")
	print("PARTY_TEST ", "PASS" if fails == 0 else "FAIL %d" % fails)
	quit(1 if fails > 0 else 0)
