# The UI's number display is upstream's (Core/NumberFormat + UITheme formatters):
#   godot --headless --path . -s res://tests/test_number_format.gd
extends SceneTree

var fails := 0


func _check(got: String, want: String, what: String) -> void:
	var ok := got == want
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + "%s: got %s want %s" % [what, got, want])


func _init() -> void:
	# NumberFormat.render_number: floored, never rounded; B is the last suffix
	for c in [[999.0, "999"], [1234.0, "1.23K"], [12345.0, "12.3K"], [123456.0, "123K"], [1259999.0, "1.25M"],
			[12.59e6, "12.5M"], [1.259e9, "1.25B"], [12.59e9, "12.5B"], [1.5e13, "15000.0B"], [-5.0, "0"]]:
		_check(UITheme.render_number(c[0]), c[1], "render_number(%s)" % c[0])
	# render_troops: the internal count / 10 (a 25,000-troop start reads 2.50K)
	_check(UITheme.fmt_troops(25000.0), "2.50K", "fmt_troops(25000)")
	_check(UITheme.fmt_troops(1.17e6), "117K", "fmt_troops(1.17M)")
	# UITheme.fmt_num (Defs.format_troops): M is the last suffix
	for c in [[850.0, "850"], [1500.0, "1.5K"], [250000.0, "250K"], [2.5e6, "2.50M"], [25e6, "25.0M"], [2.5e9, "2500.0M"], [-1500.0, "-1.5K"]]:
		_check(UITheme.fmt_num(c[0]), c[1], "fmt_num(%s)" % c[0])
	_check(UITheme.fmt_cost(125000.0), "125K", "fmt_cost(125K)")
	_check(UITheme.fmt_cost(1.5e6), "1.5M", "fmt_cost(1.5M)")
	_check(UITheme.fmt_rate(21200.0), "+21.2K/s", "fmt_rate")
	print("number format: %d fail(s)" % fails)
	quit(1 if fails else 0)
