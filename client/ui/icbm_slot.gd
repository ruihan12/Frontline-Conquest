# Port-only slot (not in upstream): the ICBM toggle (+10% cost, 35% chance to evade SAMs), drawn like a
# BuildButton so it sits in the command bar's nuke group. On: bombs ignore silo range for +10% cost.
class_name IcbmSlot
extends Button

var ctx: UICtx
var _hover := false


func _init(c: UICtx) -> void:
	ctx = c
	name = "Build_icbm"
	flat = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(54, 60)
	for sn in ["normal", "hover", "pressed", "disabled", "focus"]:
		add_theme_stylebox_override(sn, StyleBoxEmpty.new())
	mouse_entered.connect(func() -> void:
		_hover = true
		queue_redraw()
		ctx.show_hint(self, hint_spec()))
	mouse_exited.connect(func() -> void:
		_hover = false
		queue_redraw()
		ctx.hide_hint(self))
	pressed.connect(func() -> void:
		var g = ctx.state.g
		g.select_build(16)
		queue_redraw())


func _on() -> bool:
	return ctx.state != null and bool(ctx.state.g.icbm_mode)


func refresh() -> void:
	queue_redraw()


func hint_spec() -> Dictionary:
	return {
		"title": "ICBM mode",
		"badge": "I",
		"badge_color": UITheme.TEXT_2,
		"body": "Each bomb you launch has a 35% chance to evade SAMs.",
		"rows": [["Cost", "+10% per launch", UITheme.GOLD], ["SAMs", "35% chance to evade SAMs", UITheme.AMBER]],
		"hint": "On" if _on() else "Click to switch on",
		"hint_color": UITheme.AMBER if _on() else UITheme.CYAN,
		"hint_icon": "target",
	}


func _draw() -> void:
	var on := _on()
	var bg := UITheme.c(UITheme.RED, 0.07)
	var border := UITheme.c(UITheme.RED, 0.22)
	if _hover:
		bg = UITheme.c(UITheme.RED, 0.16)
		border = UITheme.LINE_2
	if on:
		bg = UITheme.c(UITheme.AMBER, 0.2)
		border = UITheme.AMBER
	draw_style_box(UITheme.flat_draw(bg, UITheme.R_MD, border, 1), Rect2(Vector2.ZERO, size))
	var tex := UITheme.icon_texture("target")
	var ip := 24.0
	if tex != null:
		UITheme.draw_icon(self, tex, Rect2(floorf(size.x * 0.5 - ip * 0.5), floorf(size.y * 0.42 - ip * 0.5), ip, ip), UITheme.AMBER_HI if on else Color(1.0, 0.86, 0.84))
	draw_string(UITheme.font(700), Vector2(0, size.y - 7.0), "ON" if on else "+10%", HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, UITheme.AMBER_HI if on else UITheme.GOLD)
	draw_string(UITheme.font(600), Vector2(6, 13), "I", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UITheme.c(UITheme.TEXT_3, 0.9))
