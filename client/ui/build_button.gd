# Port of src/client/UI/BuildButton.luau (scripts/ui/build_button.gd, UIBuildButton).
# One build / nuke slot of the command bar: icon, cost, hotkey badge, owned count and a clear
# disabled state. Stays clickable when unavailable so a click can explain why.
# An Arsenal kind the player hasn't unlocked (UIRules.availability: `arsenal`) wears a gold lock
# where its cost would be; its card shows what it does and what unlocks it.
class_name BuildButton
extends Button

signal chosen(kind: String)

var ctx: UICtx
var kind: String
var hotkey: String
var active := false
var icon_px := 24.0
## Phones (tray): taller slots with the short name under the icon, since there is no hover.
var show_name := false
var slot_w := 0.0  # 0: the usual 60
var _av := {"ok": false, "locked": true, "reason": "", "cost": 0.0, "arsenal": null}
var _owned := 0
var _flash := 0.0
var _hint_serial := 0
var _pressing := false
var _long := false
var _hover := false
var _down := false


func _init(c: UICtx, k: String, hk: String) -> void:
	ctx = c
	kind = k
	name = "Build_" + k
	hotkey = hk
	flat = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(54, 60)
	# (the slot draws its own box)
	for sn in ["normal", "hover", "pressed", "disabled", "focus"]:
		add_theme_stylebox_override(sn, StyleBoxEmpty.new())
	set_process(false)
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)
	button_down.connect(_touch_down)
	button_up.connect(func() -> void:
		# The card stays up until the next tap anywhere (UIInteract hides it).
		_pressing = false
		_down = false
		queue_redraw())


func set_active(on: bool) -> void:
	active = on
	queue_redraw()


func set_compact(on: bool, touch: bool) -> void:
	show_name = on and touch
	var ms := Vector2(46, 46) if on else Vector2(54, 60)
	if touch and not on:
		ms = Vector2(56, 62)
	if show_name:
		ms = Vector2(slot_w if slot_w > 0 else 60.0, 64)
	custom_minimum_size = ms
	icon_px = 20.0 if on else 24.0
	queue_redraw()


## Phone tray: the slot's width when the row is tight (0: the usual 60).
func set_slot_width(w: float) -> void:
	if w == slot_w:
		return
	slot_w = w
	if show_name:
		custom_minimum_size = Vector2(w if w > 0 else 60.0, 64)
		queue_redraw()


static func _av_equal(a: Dictionary, b: Dictionary) -> bool:
	return a.ok == b.ok and a.locked == b.locked and a.reason == b.reason and a.cost == b.cost and a.get("arsenal") == b.get("arsenal")


func refresh() -> void:
	var rules: UIRules = ctx.rules
	if rules == null:
		return
	var av := rules.availability(kind)
	var own := rules.owned(kind)
	# (the reason alone is not drawn, only told by the hint card)
	var old := _av
	if own == _owned and av.ok == old.ok and av.locked == old.locked and av.cost == old.cost and av.get("arsenal") == old.get("arsenal") and av.reason != old.reason:
		old.reason = str(av.reason)
		return
	if not _av_equal(av, _av) or own != _owned:
		_av = {"ok": av.ok == true, "locked": av.locked == true, "reason": str(av.reason), "cost": float(av.cost), "arsenal": av.get("arsenal")}
		_owned = own
		queue_redraw()


func is_available() -> bool:
	return _av.ok == true


func reason() -> String:
	return str(_av.reason)


## Short shake + red flash when a disabled slot is used.
func deny() -> void:
	_flash = 1.0
	var t := create_tween()
	var base := position.x
	t.tween_property(self, "position:x", base - 3.0, 0.04)
	t.tween_property(self, "position:x", base + 3.0, 0.06)
	t.tween_property(self, "position:x", base, 0.05)
	set_process(true)


func _process(delta: float) -> void:
	if _flash > 0:
		_flash = maxf(0.0, _flash - delta * 2.5)
		queue_redraw()
	else:
		set_process(false)


func _on_pressed() -> void:
	if _long:
		_long = false
		return
	ctx.hide_hint(self)
	chosen.emit(kind)


## Touch: long-press shows the slot's card (costs, what it does, why it is unavailable).
func _touch_down() -> void:
	_down = true
	queue_redraw()
	if not ctx.touch:
		return
	_pressing = true
	_long = false
	_hint_serial += 1
	var serial := _hint_serial
	get_tree().create_timer(0.45).timeout.connect(func() -> void:
		if _pressing and serial == _hint_serial and is_inside_tree():
			_long = true
			ctx.show_hint(self, hint_spec(), true))


func _on_enter() -> void:
	_hover = true
	queue_redraw()
	_hint_serial += 1
	var serial := _hint_serial
	get_tree().create_timer(0.28).timeout.connect(func() -> void:
		if _hover and serial == _hint_serial and is_inside_tree():
			ctx.show_hint(self, hint_spec()))


func _on_exit() -> void:
	_hover = false
	_hint_serial += 1
	_pressing = false
	queue_redraw()
	ctx.hide_hint(self)


func hint_spec() -> Dictionary:
	var c: float = _av.cost
	var nuke := UIRules.is_nuke(kind)
	var rows: Array = [["Cost", UITheme.fmt_cost(c) + " gold" if c > 0 else "Free", UITheme.GOLD]]
	if kind == "reinforce":
		var o = ctx.my()
		var troops: float = SimRules.reinforce_troops(o.troops, o.max_troops) if o != null else 0.0
		rows.append(["Brings", UITheme.fmt_troops(troops) + " troops", UITheme.TEXT])
	elif not nuke:
		rows.append(["Owned", str(_owned), UITheme.TEXT])
	else:
		rows.append(["Blast radius", ctx.rules.blast_text(kind), UITheme.TEXT])
	var item = UIRules.arsenal_item(kind)
	if _av.get("arsenal") != null and item != null:
		# locked: what unlocks it
		rows = []
		if item.get("stars") != null:
			rows.append(["Unlock", UICtx.commas(item.stars) + " Stars", UITheme.GOLD])
	var spec := {
		"title": UIRules.TITLES.get(kind, kind),
		"badge": hotkey if not ctx.touch else "",
		"badge_color": UITheme.TEXT_2,
		"body": ctx.rules.blurb(kind),
		"rows": rows,
	}
	if _av.get("arsenal") != null:
		spec["hint"] = "Locked: " + ("tap" if ctx.touch else "click") + " to unlock it in the Arsenal"
		spec["hint_color"] = UITheme.GOLD
		spec["hint_icon"] = "lock"
	elif _av.ok:
		spec["hint"] = "Click to call them in" if kind == "reinforce" else ("Click, then pick a target" if nuke else "Click, then choose a spot on your land")
		spec["hint_color"] = UITheme.CYAN
		spec["hint_icon"] = "target"
	else:
		spec["hint"] = reason()
		spec["hint_color"] = UITheme.RED
		spec["hint_icon"] = "info"
	return spec


static func _a(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


## Godot draw_string(pos = (x, baseline), width, align).
func _text(x: float, baseline: float, w: float, align: HorizontalAlignment, fsize: int, weight: int, s: String, col: Color) -> void:
	if s == "":
		return
	draw_string(UITheme.font(weight), Vector2(x, baseline), s, align, w if w > 0 else -1.0, fsize, col)


func _draw() -> void:
	if ctx == null:
		return
	var ok: bool = _av.ok == true
	var locked: bool = _av.locked == true
	var arsenal_locked: bool = _av.get("arsenal") != null
	var nuke := UIRules.is_nuke(kind)
	var bg := Color(1, 1, 1, 0.035)
	var border := Color(1, 1, 1, 0.07)
	if arsenal_locked:
		bg = _a(UITheme.GOLD, 0.05)
		border = _a(UITheme.GOLD, 0.28)
	if nuke and ok:
		bg = _a(UITheme.RED, 0.07)
		border = _a(UITheme.RED, 0.22)
	if _hover:
		bg = Color(1, 1, 1, 0.1) if not nuke else _a(UITheme.RED, 0.16)
		border = UITheme.LINE_2
	if button_pressed or (_hover and _down):
		bg = Color(1, 1, 1, 0.05)
	if active:
		bg = _a(UITheme.AMBER, 0.2)
		border = UITheme.AMBER
	if _flash > 0:
		bg = bg.lerp(_a(UITheme.RED, 0.35), _flash)
		border = border.lerp(UITheme.RED, _flash)
	draw_style_box(UITheme.flat(bg, UITheme.R_MD, border, 1), Rect2(Vector2.ZERO, size))

	var icol: Color = UITheme.TEXT
	if nuke:
		icol = Color(1.0, 0.86, 0.84)
	if not ok:
		icol = _a(icol, 0.55 if arsenal_locked else (0.2 if locked else 0.5))
	if active:
		icol = UITheme.AMBER_HI
	var cy := size.y * (0.4 if size.y < 50 else 0.42)
	if show_name:
		cy = 17.0
	var ip := icon_px
	var tex := UITheme.icon_texture(kind)
	if tex != null:
		draw_texture_rect(tex, Rect2(floorf(size.x * 0.5 - ip * 0.5), floorf(cy - ip * 0.5), ip, ip), false, icol)

	var fs := 11
	var c: float = _av.cost
	var ctext := UITheme.fmt_cost(c) if c > 0 else ("FREE" if c == 0 else "-")
	var ccol: Color = UITheme.GOLD
	if locked:
		ccol = _a(UITheme.TEXT_3, 0.8)
	elif not ok:
		ccol = _a(UITheme.RED, 0.95)
	# a locked Arsenal kind: a gold lock where the cost would be
	if arsenal_locked:
		ctext = ""
		var lt := UITheme.icon_texture("lock")
		if lt != null:
			draw_texture_rect(lt, Rect2(floorf(size.x * 0.5) - 6, floorf(size.y - (4.0 if size.y < 50 else 6.0)) - 12, 12, 12), false, UITheme.GOLD)
	_text(0, size.y - (5.0 if size.y < 50 else 7.0), size.x, HORIZONTAL_ALIGNMENT_CENTER, fs, 700, ctext, ccol)
	if show_name:
		var ncol := _a(UITheme.TEXT, 0.9 if ok else (0.45 if locked else 0.7))
		_text(0, 42.0, size.x, HORIZONTAL_ALIGNMENT_CENTER, 12, 600, UIRules.SHORT.get(kind, kind), ncol)
	if not ctx.touch and hotkey != "":
		_text(6.0, 13.0, 0, HORIZONTAL_ALIGNMENT_LEFT, 9, 600, hotkey, _a(UITheme.TEXT_3, 0.9))
	if _owned > 0 and not nuke:
		_text(0, 4.0 + 9, size.x - 5.0, HORIZONTAL_ALIGNMENT_RIGHT, 9, 600, "×" + str(_owned), _a(UITheme.TEXT_2, 0.9))
