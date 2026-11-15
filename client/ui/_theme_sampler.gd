# Dev scene script: every UITheme button variation, the glass panel, labels and icons on one screen.
# Run: godot --path . client/ui/theme_sampler.tscn  (or with -- --shot=<png> to save a capture and quit)
extends Control

func _ready() -> void:
	theme = UITheme.theme()
	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.36, 0.56)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var stripes := ColorRect.new()
	stripes.color = Color(0.45, 0.62, 0.35)
	stripes.position = Vector2(500, 0); stripes.size = Vector2(500, 900)
	add_child(stripes)
	var col := UITheme.vbox(UITheme.S4)
	col.position = Vector2(40, 40)
	add_child(col)

	var p := GlassPanel.new()
	var pv := UITheme.vbox(UITheme.S2)
	p.add_child(pv)
	pv.add_child(UITheme.caption("Troops"))
	var row := UITheme.hbox(UITheme.S3)
	pv.add_child(row)
	row.add_child(UITheme.icon_rect("troops", 28, UITheme.TEXT_2))
	row.add_child(UITheme.label(UITheme.fmt_troops(47300.0), 28, 800))
	row.add_child(UITheme.label("/ " + UITheme.fmt_troops(121000.0), 15, 500, UITheme.TEXT_3))
	row.add_child(UITheme.label(UITheme.fmt_rate(4000.0), 13, 700, UITheme.GREEN))
	row.add_child(UITheme.vdivider())
	row.add_child(UITheme.icon_rect("gold", 24, UITheme.GOLD))
	row.add_child(UITheme.label(UITheme.fmt_num(6000.0), 28, 800, UITheme.GOLD))
	col.add_child(p)

	var p2 := GlassPanel.new()
	p2.set_accent(UITheme.VIOLET)
	var p2v := UITheme.vbox(UITheme.S2)
	p2.add_child(p2v)
	p2v.add_child(UITheme.label("East Antarctica wants an alliance", 15, 600))
	var br := UITheme.hbox(UITheme.S2)
	p2v.add_child(br)
	br.add_child(UITheme.button("ACCEPT", "PrimaryButton", "check"))
	br.add_child(UITheme.button("Decline", "GhostButton", "close"))
	col.add_child(p2)

	var p3 := GlassPanel.new()
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", UITheme.S3)
	g.add_theme_constant_override("v_separation", UITheme.S3)
	p3.add_child(g)
	for v in ["GlassButton", "PublicButton", "GhostButton", "DangerButton", "ChipButton", "PrimaryButton", "SurrenderButton"]:
		g.add_child(UITheme.button(v.trim_suffix("Button").to_upper(), v, "play" if v == "PrimaryButton" else ""))
	var dis := UITheme.button("DISABLED", "PrimaryButton")
	dis.disabled = true
	g.add_child(dis)
	col.add_child(p3)

	var p4 := GlassPanel.new(12, 10)
	var ih := UITheme.hbox(UITheme.S2)
	p4.add_child(ih)
	for n in ["city", "port", "factory", "defense", "sam", "silo", "warship", "atom", "hydrogen", "mirv", "artillery", "airfield", "railgun", "alliance", "attack", "crown", "target", "skull", "settings", "leaderboard", "star", "lock"]:
		ih.add_child(UITheme.icon_rect(n, 26))
	col.add_child(p4)

	var p5 := GlassPanel.new(12, 8, UITheme.R_MD)
	var mv := UITheme.vbox(UITheme.S1)
	p5.add_child(mv)
	for cat in 5:
		var mr := UITheme.hbox(UITheme.S2)
		mr.add_child(UITheme.icon_rect(UITheme.msg_icon(cat), 16, UITheme.msg_color(cat)))
		mr.add_child(UITheme.swatch(UITheme.msg_color(cat)))
		mr.add_child(UITheme.label(["Trade ship arrived: +%s gold" % UITheme.fmt_cost(125000.0), "You conquered Brazil", "Peru attacks you", "INCOMING NUKE: impact in 9s", "Alliance with Chile formed"][cat], 13, 500))
		mv.add_child(mr)
	col.add_child(p5)

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			await get_tree().create_timer(0.6).timeout
			get_viewport().get_texture().get_image().save_png(a.trim_prefix("--shot="))
			get_tree().quit()
