# Port of src/client/UI/AlertBanner.luau (scripts/ui/alert_banner.gd, UIAlertBanner).
# Red pulsing "INCOMING NUKE" banner shown while nukes aimed at your land are in flight; turns green
# ("INTERCEPTED!") for a moment when a SAM shoots the last one down.
#
# Members: panel. Methods: apply_layout(y, right_x = -1), clear(), is_green(), track(uid) -> [new,
# first], resolve(uid, intercepted); per frame update(dt).
class_name AlertBanner
extends Control

const RED_TITLE := Color(1.0, 0.55, 0.58)
const RED_TINT := Color(0.26, 0.03, 0.07, 0.9)

var ctx: UICtx
var _incoming := {}  # uid -> true
var _t := 0.0
## Seconds left of the green "intercepted" state (0 = normal).
var _green := 0.0
## The incoming set changed since the text was written (update() writes it).
var _stale := false
var panel: GlassPanel
var _disc: PanelContainer
var _disc_icon: TextureRect
var _title: Label
var _detail: Label


func _init(c: UICtx) -> void:
	var T := UITheme
	ctx = c
	name = "AlertBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = GlassPanel.new(18.0, 10.0, 999, true, 24)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_tint(RED_TINT)
	panel.set_border(T.c(T.RED, 0.8))
	add_child(panel)
	var row := T.hbox(12)
	panel.add_child(row)
	_disc = PanelContainer.new()
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disc.custom_minimum_size = Vector2(34, 34)
	_disc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	T.set_disc(_disc, T.c(T.RED, 0.25), T.RED, 1.0)
	var ic := T.icon_rect("atom", 18.0, Color(1.0, 0.85, 0.85))
	_disc_icon = ic
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_disc.add_child(ic)
	row.add_child(_disc)
	var v := T.vbox(0)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title = T.label("INCOMING NUKE", 15, 800, RED_TITLE, 3)
	v.add_child(_title)
	_detail = T.label("", 12, 500, Color(1.0, 0.88, 0.88))
	v.add_child(_detail)
	row.add_child(v)
	visible = false


## Centred under the status pill on larger screens; right-aligned under the leaderboard pill on
## phones.
func apply_layout(y: float, right_x: float = -1.0) -> void:
	var T := UITheme
	var p := panel
	p.mouse_filter = Control.MOUSE_FILTER_STOP if ctx.touch else Control.MOUSE_FILTER_IGNORE
	# Fixed width: long nation names ellipsize instead of stretching the banner.
	var w := 330.0 if ctx.compact else 380.0
	T.fix_width(_detail, w, HORIZONTAL_ALIGNMENT_LEFT, false)
	T.fix_width(_title, w, HORIZONTAL_ALIGNMENT_LEFT, false)
	p.anchor_top = 0.0
	p.anchor_bottom = 0.0
	p.grow_vertical = Control.GROW_DIRECTION_END
	if right_x >= 0:
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		p.offset_left = -right_x
		p.offset_right = -right_x
	else:
		p.anchor_left = 0.5
		p.anchor_right = 0.5
		p.grow_horizontal = Control.GROW_DIRECTION_BOTH
		var pt := ctx.place_top(p.get_combined_minimum_size().x, y)
		p.offset_left = pt[0]
		p.offset_right = pt[0]
		y = pt[1]
	p.offset_top = y
	p.offset_bottom = y
	p.reset_size()


func clear() -> void:
	_incoming.clear()
	_green = 0.0
	visible = false
	_set_red()


func is_green() -> bool:
	return _green > 0


func _show_green(last: bool) -> void:
	var T := UITheme
	_green = 1.6
	visible = true
	modulate.a = 1.0
	_title.text = "INTERCEPTED!"
	T.set_font_color(_title, Color(0.6, 1.0, 0.72))
	_detail.text = "Shot down by a SAM" + ("" if last else " · more incoming")
	panel.set_tint(Color(0.03, 0.2, 0.09, 0.9))
	panel.set_border(T.c(T.GREEN, 0.9))
	T.set_disc(_disc, T.c(T.GREEN, 0.25), T.GREEN, 1.0)
	_disc_icon.texture = T.icon_texture("sam")
	_disc_icon.modulate = Color(0.85, 1.0, 0.9)
	panel.reset_size()


func _set_red() -> void:
	var T := UITheme
	T.set_font_color(_title, RED_TITLE)
	panel.set_tint(RED_TINT)
	panel.set_border(T.c(T.RED, 0.8))
	T.set_disc(_disc, T.c(T.RED, 0.25), T.RED, 1.0)
	_disc_icon.texture = T.icon_texture("atom")
	_disc_icon.modulate = Color(1.0, 0.85, 0.85)


## Returns [true when this nuke is newly aimed at the local player, true when it is the one that
## brings the banner up]. (The text is written once a frame, in update().)
func track(uid: int) -> Array:
	var s = ctx.state
	if s == null or not s.nukes().has(uid) or ctx.me() == 0:
		return [false, false]
	var n: Dictionary = s.nukes()[uid]
	# (this port: a MIRV bus names the nation it is aimed at)
	if n.owner == ctx.me() or (s.tile_owner(n.to_tile) != ctx.me() and n.get("target_owner", -1) != ctx.me()):
		return [false, false]
	var first := _incoming.is_empty()
	_incoming[uid] = true
	if first:
		visible = true
		UIFx.pop_in(panel, 0.0, 1.15, 0.35)
		_refresh()
	else:
		_stale = true
	return [true, first]


## `intercepted`: a SAM shot it down (the banner flashes green before it goes).
func resolve(uid: int, intercepted: bool = false) -> void:
	if not _incoming.has(uid):
		return
	_incoming.erase(uid)
	if intercepted:
		_show_green(_incoming.is_empty())
		return
	if _incoming.is_empty():
		var t := create_tween()
		t.tween_property(self, "modulate:a", 0.0, 0.4)
		t.tween_callback(func() -> void:
			if _incoming.is_empty():
				visible = false
			modulate.a = 1.0)
	else:
		_stale = true


func _refresh() -> void:
	_stale = false
	var s = ctx.state
	if s == null:
		return
	var nk: Dictionary = s.nukes()
	var soonest := 1e9
	var kind := -1
	var from := 0
	var count := 0
	for uid in _incoming.keys():
		var n = nk.get(uid)
		if n == null:
			_incoming.erase(uid)
		else:
			count += 1
			var left: float = (n.launch_tick + n.flight_ticks) - ctx.render_tick()
			if left < soonest:
				soonest = left
				kind = n.kind
				from = n.owner
	if count == 0:
		return
	# (this port's countdown: missile time, which the game speed stretches with everything else)
	var secs := maxi(0, int(ceil(soonest / Defs.TICK_RATE)))
	var what: String = Defs.NUKE_TITLES[kind] if (kind >= 0 and kind < Defs.NUKE_TITLES.size()) else "Nuke"
	if count > 1:
		_title.text = "INCOMING NUKES ×%d" % count
		_detail.text = "First impact in %ds · from %s" % [secs, s.owner_name(from)]
	else:
		_title.text = "INCOMING NUKE"
		_detail.text = "%s from %s · impact in %ds" % [what, s.owner_name(from), secs]
	panel.reset_size()


## Per frame.
func update(delta: float) -> void:
	if not visible:
		return
	var T := UITheme
	if _green > 0:
		_green -= delta
		if _green <= 0:
			_set_red()
			if _incoming.is_empty():
				var t := create_tween()
				t.tween_property(self, "modulate:a", 0.0, 0.35)
				t.tween_callback(func() -> void:
					if _incoming.is_empty() and _green <= 0:
						visible = false
					modulate.a = 1.0)
			else:
				_refresh()
		return
	var prev := _t
	_t += delta
	var p := 0.5 + 0.5 * sin(_t * 7.0)
	panel.set_border(T.c(T.RED, 0.45 + 0.5 * p))
	_disc.modulate.a = 0.75 + 0.25 * p
	if _stale or floorf(_t * 4.0) != floorf(prev * 4.0):
		_refresh()
