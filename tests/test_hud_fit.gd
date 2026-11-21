# Assert fit_label never leaves a string wider than the budget (or grows min width).
#   godot --headless --path . -s res://tests/test_hud_fit.gd
extends SceneTree

const RK := preload("res://ui_upstream/rw_kit.gd")

var fails := 0

func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
	print(("  ok   " if cond else "  FAIL ") + what)

func _init() -> void:
	var cases := ["9.999e99", "999.9Qd", "1.000e100", "-9.999e99", "+9.999e99/s"]
	# Tight budgets that force shrinking, and generous ones that keep 24 px.
	var budgets := [48.0, 72.0, 96.0, 120.0, 160.0, 220.0]
	for text in cases:
		for max_w in budgets:
			var l := RK.label("", 24, 800, RK.GOLD)
			# Must be in the tree for theme fallbacks; a stray Control is enough.
			var host := Control.new()
			root.add_child(host)
			host.add_child(l)
			var need: float = RK.fit_label(l, text, max_w, 24, 9)
			var f := RK.label_font_of(l)
			var fs := int(l.get_theme_font_size("font_size"))
			var measured := RK.shaped_width(f, l.text, fs) + RK.label_pad_x(l)
			_ok(l.text == text, "text preserved (%s at %.0f)" % [text, max_w])
			_ok(l.clip_text == false, "clip_text off (%s at %.0f)" % [text, max_w])
			# Drawn width equals the reported need and is either <= budget or the min width grew to need.
			_ok(absf(measured - need) <= 0.51, "need matches measure %s @%.0f: need=%.1f meas=%.1f fs=%d" % [text, max_w, need, measured, fs])
			if need <= max_w + 0.5:
				_ok(true, "fits budget %s @%.0f: %.1f <= %.1f (fs=%d)" % [text, max_w, need, max_w, fs])
			else:
				_ok(l.custom_minimum_size.x >= need - 0.5, "grows min width instead of clipping %s @%.0f: min=%.1f need=%.1f" % [text, max_w, l.custom_minimum_size.x, need])
				_ok(fs == 9, "hit min font before growing %s @%.0f (fs=%d)" % [text, max_w, fs])
			host.queue_free()

	# Worst-case preferred-size widths (24 px / 12 px) are finite and ordered.
	var w24 := RK.hud_num_width(24, 800)
	var w_rate := RK.hud_rate_width(12, 700)
	_ok(w24 > 40.0, "hud_num_width(24) is usable (%.1f)" % w24)
	_ok(w_rate > 20.0, "hud_rate_width(12) is usable (%.1f)" % w_rate)
	# 1.000e100 is at least as wide as 9.999e99 at the same size.
	var f := RK.font(800)
	_ok(RK.shaped_width(f, "1.000e100", 24) >= RK.shaped_width(f, "9.999e99", 24) - 0.5, "1.000e100 is not narrower than 9.999e99")

	# The visible command bar uses UITheme + tabular digits, not rw_kit. Same contract.
	UITheme.init()
	var cases_t := ["9.999e99", "999.9Qd", "1.000e100", "-9.999e99", "+9.999e99/s"]
	for text in cases_t:
		for max_w in budgets:
			var l := UITheme.label("", 20, 700, UITheme.GOLD)
			l.add_theme_font_override("font", UITheme.font(700, 0, true))
			var host := Control.new()
			root.add_child(host)
			host.add_child(l)
			var need: float = UITheme.fit_label(l, text, max_w, 20, 9)
			var measured := UITheme.label_need_width(l, l.text, l.get_theme_font_size("font_size"))
			_ok(l.text == text, "theme text preserved (%s at %.0f)" % [text, max_w])
			_ok(l.clip_text == false, "theme clip_text off (%s at %.0f)" % [text, max_w])
			_ok(absf(measured - need) <= 0.51, "theme need matches %s @%.0f: need=%.1f meas=%.1f" % [text, max_w, need, measured])
			if need <= max_w + 0.5:
				_ok(true, "theme fits %s @%.0f: %.1f <= %.1f" % [text, max_w, need, max_w])
			else:
				_ok(l.custom_minimum_size.x >= need - 0.5, "theme grows min %s @%.0f: min=%.1f need=%.1f" % [text, max_w, l.custom_minimum_size.x, need])
			host.queue_free()
	_ok(UITheme.hud_count_width(20, 700) > 40.0, "hud_count_width(20) usable (%.1f)" % UITheme.hud_count_width(20, 700))
	_ok(UITheme.hud_rate_width(11, 700) > 20.0, "hud_rate_width(11) usable (%.1f)" % UITheme.hud_rate_width(11, 700))

	print("HUD_FIT_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
