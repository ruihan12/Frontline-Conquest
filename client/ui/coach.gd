# Port of src/client/UI/Coach.luau (scripts/ui/coach.gd, UICoach).
# First-match coach marks: one short tip at a time with a pulsing arrow to what it talks about
# (a spot on the globe or a HUD control). Each tip shows once per player; "seen" ids persist in
# the settings (tips_seen) and can be reset from the game menu.
class_name Coach
extends Control

## (Data/Tutorial: ROOKIE_FLOOR, ROOKIE_MATCHES)
const ROOKIE_FLOOR := 0.2
const ROOKIE_MATCHES := 5
const FLOOR_TIP := "Keep 20% of your army at home, or neighbours walk right in. In your first 5 matches, attacks hold that much back."
## `again`: shown each time it is offered, not once per player (UIAdvisor paces it).
const TIPS := {
	"floor": {"icon": "troops", "again": true, "desktop": FLOOR_TIP, "touch": FLOOR_TIP},
	"expand": {
		"icon": "attack",
		"desktop": "Click neutral land next to you to expand. Space does the same under the cursor.",
		"touch": "Tap neutral land next to you to expand.",
	},
	"ratio": {
		"icon": "troops",
		"desktop": "The Attack bar sets how many of your troops each click sends. Q / E change it.",
		"touch": "Tap a % on the Attack bar to choose how many troops each tap sends.",
	},
	"city": {
		"icon": "city",
		"desktop": "You can afford a City (1). Cities raise your troop cap: place one on your land.",
		"touch": "You can afford a City. Open BUILD and place one on your land to raise your troop cap.",
	},
	"contact": {
		"icon": "alliance",
		"desktop": "You now border %s. Click their land to attack, or right-click it to propose an alliance.",
		"touch": "You now border %s. Tap their land to size them up, tap again to attack. Long-press for more.",
	},
	"boat": {
		"icon": "boat",
		"desktop": "You reached the sea. Click a distant coast to send a boat invasion.",
		"touch": "You reached the sea. Tap a distant coast to send a boat invasion.",
	},
	"select": {
		"icon": "target",
		"desktop": "Target selected. Click it again, or press the big button, to send the order.",
		"touch": "Target selected: check their troops, then tap it again or press the big button to attack.",
	},
	"tray": {
		"icon": "city",
		"desktop": "Hover a slot to see what it does.",
		"touch": "Hold any slot to see what it does and why it may be locked.",
	},
	"attacked": {
		"icon": "defense",
		"desktop": "You are under attack! Track every front in the Attacks panel. Defense Posts (4) make borders much harder to take.",
		"touch": "You are under attack! Track every front in the Attacks panel. Defense Posts make borders much harder to take.",
	},
}
const PRIORITY: Array[String] = ["attacked", "floor", "select", "expand", "contact", "tray", "ratio", "city", "boat"]
const LIFETIME := 16.0
## Keep-out rects (the YOU label) cost this many times their overlap area, with this margin (px).
const KEEPOUT_WEIGHT := 12.0
const KEEPOUT_MARGIN := 6.0

var ctx: UICtx
var current := ""
var muted := false
## Callable() -> Array[Rect2]: HUD panels the card should not cover.
var blockers: Callable
## Callable() -> Array[Rect2]: map content the card must keep clear of (the player's own label).
var keepout: Callable
## The whole coach fades while the player aims or uses the action ring (the host sets this).
var eff_a := 1.0
var _target: Callable
var _queue: Array = []
var _age := 0.0
var _t := 0.0
var _point := Vector2(-1, -1)
var _point_hidden := false
var _arrow: Control
var _card: GlassPanel
var _disc: PanelContainer
var _icon: TextureRect
var _v: VBoxContainer
var _cap: Label
var _text: Label
var _ok: Button
var _x: Button


static func prio(id: String) -> int:
	return PRIORITY.find(id)


func _init(c: UICtx) -> void:
	ctx = c
	name = "Coach"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Arrow layer (dashed line, head, pulsing ring) under the card.
	_arrow = Control.new()
	_arrow.name = "CoachArrow"
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_arrow.draw.connect(_draw_arrow)
	add_child(_arrow)

	var card := GlassPanel.new(14.0, 11.0, UITheme.R_MD, true, 20)
	card.set_accent(UITheme.AMBER)
	card.set_border(UITheme.c(UITheme.AMBER, 0.45))
	card.custom_minimum_size = Vector2(320, 0)
	_card = card
	var h := UITheme.hbox(12)
	card.add_child(h)
	_disc = PanelContainer.new()
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disc.custom_minimum_size = Vector2(34, 34)
	_disc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_disc.add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(UITheme.AMBER, 0.16), 17, UITheme.c(UITheme.AMBER, 0.5), 1))
	_icon = UITheme.icon_rect("info", 17.0, UITheme.AMBER)
	_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_disc.add_child(_icon)
	h.add_child(_disc)
	_v = UITheme.vbox(6)
	_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cap = UITheme.caption("Tip", 10, UITheme.AMBER)
	_v.add_child(_cap)
	_text = UITheme.label("", 13, 500, UITheme.TEXT)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(230, 0)
	_v.add_child(_text)
	_ok = UITheme.button("Got it", "GhostButton", "", 30.0)
	_ok.add_theme_font_size_override("font_size", 12)
	_ok.size_flags_horizontal = Control.SIZE_SHRINK_END
	_ok.pressed.connect(dismiss)
	_v.add_child(_ok)
	h.add_child(_v)
	_x = UITheme.button("", "GhostButton", "close", 44.0)
	_x.expand_icon = true
	_x.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_x.add_theme_constant_override("icon_max_width", 12)
	_x.custom_minimum_size = Vector2(44, 44)
	_x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_x.pressed.connect(dismiss)
	_x.visible = false
	h.add_child(_x)
	add_child(card)
	card.visible = false
	set_process(true)


func apply_layout() -> void:
	_ok.custom_minimum_size = Vector2(88 if ctx.touch else 0, 44 if ctx.touch else 30)
	if current != "":
		_place()


func seen(id: String) -> bool:
	var d = ctx.setting("tips_seen", {})
	return d is Dictionary and d.get(id, false) == true


func _mark_seen(id: String) -> void:
	var d = ctx.setting("tips_seen", {})
	var dict: Dictionary = d.duplicate() if d is Dictionary else {}
	dict[id] = true
	ctx.set_setting("tips_seen", dict)


func reset() -> void:
	ctx.set_setting("tips_seen", {})
	_queue.clear()
	dismiss()


## Queue a tip. `target` returns the screen point to point at (Vector2(-1, -1) = no arrow).
func offer(id: String, target: Callable = Callable(), arg: String = "") -> void:
	# (the tutorial's steps are the tips while it runs: UI/Tutorial)
	if muted or not TIPS.has(id) or id == current:
		return
	# the Settings > Tutorial switch off: no coach tips at all (owner request 2026-11-25), the "keep 20% at home" one included
	if bool(ctx.setting("tutorial_off", false)):
		return
	var tip: Dictionary = TIPS[id]
	if not tip.get("again", false) and seen(id):
		return
	for q in _queue:
		if q.id == id:
			return
	_queue.append({"id": id, "target": target, "arg": arg})
	_queue.sort_custom(func(a, b) -> bool: return prio(a.id) < prio(b.id))
	if current == "":
		_next()


## The player did what the tip asked: close it (and never offer it again).
func complete(id: String) -> void:
	if not seen(id):
		_mark_seen(id)
	for i in range(_queue.size() - 1, -1, -1):
		if _queue[i].id == id:
			_queue.remove_at(i)
	if current == id:
		dismiss()


func dismiss() -> void:
	if current == "":
		return
	current = ""
	_target = Callable()
	var t := _card.create_tween()
	t.tween_property(_card, "modulate:a", 0.0, 0.2)
	t.tween_callback(func() -> void:
		if current == "":
			_card.visible = false
			_arrow.queue_redraw()
			_next())
	_arrow.queue_redraw()


func clear() -> void:
	_queue.clear()
	current = ""
	_card.visible = false
	_arrow.queue_redraw()


func _next() -> void:
	if _queue.is_empty() or current != "":
		return
	var q: Dictionary = _queue.pop_front()
	var id: String = q.id
	var tip: Dictionary = TIPS[id]
	if not tip.get("again", false) and seen(id):
		_next()
		return
	current = id
	_target = q.target
	var txt: String = tip.touch if ctx.touch else tip.desktop
	if txt.contains("%s"):
		txt = txt % q.arg
	_text.text = txt
	_icon.texture = UITheme.icon_texture(tip.icon)
	if not tip.get("again", false):
		_mark_seen(id)
	_age = 0.0
	var c := ctx.compact
	_card.custom_minimum_size = Vector2(0 if c else 320, 0)
	_text.custom_minimum_size = Vector2(210 if c else 230, 0)
	_text.add_theme_font_size_override("font_size", 12 if c else 13)
	_cap.visible = not c
	_ok.visible = not c
	_x.visible = c
	_disc.custom_minimum_size = Vector2(26, 26) if c else Vector2(34, 34)
	_disc.size_flags_vertical = Control.SIZE_SHRINK_CENTER if c else Control.SIZE_SHRINK_BEGIN
	_icon.custom_minimum_size = Vector2(14, 14) if c else Vector2(17, 17)
	_v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_card.set_padding(10.0 if c else 14.0, 2.0 if c else 11.0, 2.0 if c else 14.0, 2.0 if c else 11.0)
	_card.visible = true
	_card.modulate.a = 0.0
	_card.reset_size()
	_place()
	UIFx.pop_in(_card, 0.0, 0.94, 0.35)
	ctx.sfx("open", -8.0)
	# (the wrapped text only knows its height once the card has its width)
	get_tree().process_frame.connect(func() -> void:
		if current == id:
			_card.reset_size()
			_place(), CONNECT_ONE_SHOT)


static func _overlap(a: Rect2, b: Rect2) -> float:
	var i := a.intersection(b)
	return i.size.x * i.size.y


func _place() -> void:
	var vp := ctx.vp
	var ins := ctx.insets
	var sz := _card.get_combined_minimum_size()
	var blocked: Array = blockers.call() if blockers.is_valid() else []
	var m := 12.0
	# Free band for the card: below the top bar, above the panels docked to the bottom edge (the
	# command bar).
	var top_lim := 70.0 + ins.y
	var bot_lim := vp.y - m - ins.w
	for b: Rect2 in blocked:
		var docked := b.end.y >= vp.y - ins.w - 40.0 and b.size.x >= vp.x * 0.25
		if docked and b.position.y - 8.0 - top_lim >= sz.y:
			bot_lim = minf(bot_lim, b.position.y - 8.0)
	# A target under a panel (or off the free band) gets no arrow: the card parks in the band.
	var pt := _point
	var hidden := false
	if pt.x >= 0.0:
		if pt.y > bot_lim + m or pt.x < ins.x or pt.x > vp.x - ins.z:
			hidden = true
		else:
			for b: Rect2 in blocked:
				if b.has_point(pt):
					hidden = true
					break
	_point_hidden = hidden
	var cands: Array[Vector2] = []
	if pt.x >= 0.0 and not hidden:
		var gap := 70.0
		cands.append(Vector2(pt.x - sz.x * 0.5, pt.y - sz.y - gap))  # above
		cands.append(Vector2(pt.x - sz.x - gap, pt.y - sz.y * 0.5))  # left
		cands.append(Vector2(pt.x - sz.x * 0.5, pt.y + gap))  # below
		cands.append(Vector2(pt.x + gap, pt.y - sz.y * 0.5))  # right
	else:
		cands.append(Vector2((vp.x - sz.x) * 0.5, vp.y * 0.24))
	# The player's own label: the card goes beside it, not on top.
	var keep: Array = keepout.call() if keepout.is_valid() else []
	var best := cands[0]
	var best_cost := INF
	for i in cands.size():
		var p := cands[i]
		var x := clampf(p.x, m + ins.x, maxf(m + ins.x, vp.x - sz.x - m - ins.z))
		var y := clampf(p.y, top_lim, maxf(top_lim, bot_lim - sz.y))
		var r := Rect2(Vector2(x, y), sz)
		var cost := i * 400.0
		for b: Rect2 in blocked:
			cost += _overlap(r, b)
		for b2: Rect2 in keep:
			cost += _overlap(r.grow(KEEPOUT_MARGIN), b2) * KEEPOUT_WEIGHT
		if pt.x >= 0.0 and not hidden and r.grow(8.0).has_point(pt):
			cost += 1e6
		if cost < best_cost:
			best_cost = cost
			best = Vector2(x, y)
	var cur := _card.position
	var np := cur.lerp(best, 0.25) if _card.modulate.a > 0.5 else best
	if np.distance_to(best) < 0.25:
		np = best
	_card.position = np
	_card.size = sz


func card_rect() -> Rect2:
	return _card.get_global_rect() if current != "" and _card.visible else Rect2()


func _process(delta: float) -> void:
	if current == "":
		return
	_t += delta
	_age += delta
	if _age > (LIFETIME * 0.65 if ctx.compact else LIFETIME):
		dismiss()
		return
	var p := Vector2(-1, -1)
	if _target.is_valid():
		var v = _target.call()
		if v is Vector2:
			p = v
	_point = p
	_card.self_modulate.a = 1.0
	_place()
	_arrow.queue_redraw()


## Dashed line from the card to the target, an arrow head and a pulsing ring.
func _draw_arrow() -> void:
	var card := _card
	if current == "" or _point.x < 0.0 or _point_hidden or not card.visible:
		return
	var a := card.modulate.a * eff_a
	if a <= 0.001:
		return
	var r := card.get_global_rect()
	var to := _point
	var from := Vector2(clampf(to.x, r.position.x + 18.0, maxf(r.position.x + 18.0, r.end.x - 18.0)), r.end.y if to.y > r.end.y else r.position.y)
	var dirv := to - from
	var dist := dirv.length()
	if dist < 24.0:
		return
	var dir := dirv / dist
	var col := Color(UITheme.AMBER, 0.9 * a)
	# Dashed line: 8 px dashes every 14.4 px, 2 px wide.
	var dash := 8.0
	var d := 0.0
	while d < dist - 16.0:
		_arrow.draw_line(from + dir * d, from + dir * minf(d + dash, dist - 16.0), col, 2.0, true)
		d += dash * 1.8
	# Arrow head: tip 10 px ahead of the line's end, 14 px wide at its base.
	var tip_base := to - dir * 16.0
	var n := Vector2(-dir.y, dir.x)
	_arrow.draw_colored_polygon(PackedVector2Array([tip_base + dir * 10.0, tip_base - dir * 4.0 + n * 7.0, tip_base - dir * 4.0 - n * 7.0]), col)
	# Pulsing ring on the target
	var k := fmod(_t, 1.2) / 1.2
	_arrow.draw_arc(to, 8.0 + 18.0 * k, 0.0, TAU, 40, Color(UITheme.AMBER, (1.0 - k) * 0.9 * a), 2.0, true)
	_arrow.draw_circle(to, 4.0, Color(UITheme.AMBER, a), true, -1.0, true)
