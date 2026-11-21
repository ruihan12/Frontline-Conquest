# Live big-number formatter: K M B T Qd, then 6-digit scientific notation past Qd (1e18+).
#   godot --headless --path . -s res://tests/test_number_format.gd
extends SceneTree

var fails := 0


func _check(got: String, want: String, what: String) -> void:
	var ok := got == want
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + "%s: got %s want %s" % [what, got, want])


func _init() -> void:
	# UITheme.big is the shared live formatter (HUD, gold pops, and _fmt's sci fallback).
	var cases := {
		999.0: "999",
		1500.0: "1.50K",
		2.5e6: "2.50M",
		3e12: "3.00T",
		4.2e15: "4.20Qd",
		999.9e15: "999.9Qd",
		1e18: "1.000000e18",
		1.343452e23: "1.343452e23",
		-1500.0: "-1.50K",
		-4.2e15: "-4.20Qd",
		-1e18: "-1.000000e18",
		-1.343452e23: "-1.343452e23",
	}
	for n in cases:
		_check(UITheme.big(n), cases[n], "big(%s)" % n)

	# fmt_num uses big() from 1e9 up, so Qd / e-notation match. Smaller values keep their own style.
	_check(UITheme.fmt_num(999.0), "999", "fmt_num(999)")
	_check(UITheme.fmt_num(1500.0), "1.5K", "fmt_num(1500) keeps short K style")
	_check(UITheme.fmt_num(2.5e6), "2.50M", "fmt_num(2.5e6)")
	_check(UITheme.fmt_num(3e12), "3.00T", "fmt_num(3e12)")
	_check(UITheme.fmt_num(4.2e15), "4.20Qd", "fmt_num(4.2e15)")
	_check(UITheme.fmt_num(1e18), "1.000000e18", "fmt_num(1e18)")
	_check(UITheme.fmt_num(-1.343452e23), "-1.343452e23", "fmt_num(-1.343452e23)")

	# Costs at/above 1B share big(); ordinary shop prices stay compact.
	_check(UITheme.fmt_cost(1500000.0), "1.5M", "fmt_cost(1.5M)")
	_check(UITheme.fmt_cost(125000.0), "125K", "fmt_cost(125K)")
	_check(UITheme.fmt_cost(4.2e15), "4.20Qd", "fmt_cost(4.2e15)")
	_check(UITheme.fmt_cost(1e18), "1.000000e18", "fmt_cost(1e18)")

	# Gold pops use big() from 1B up, so they follow the same Qd / e-notation rule.
	_check(FxLayer.format_gold(999.0), "999", "format_gold(999)")
	_check(FxLayer.format_gold(12345.0), "12.3K", "format_gold(12.3K)")
	_check(FxLayer.format_gold(4.2e15), "4.20Qd", "format_gold(4.2e15)")
	_check(FxLayer.format_gold(1e18), "1.000000e18", "format_gold(1e18)")

	# Qa/Qi and the later names must be gone; 1e18 is already scientific, not a suffix.
	_check(str("Qa" in UITheme.big(1e18) or "Qi" in UITheme.big(1e18) or "Qt" in UITheme.big(1e18)), "false", "no Qa/Qi/Qt at 1e18")

	print("NUMBER_FORMAT_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
