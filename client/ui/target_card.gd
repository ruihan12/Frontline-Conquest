# Port of src/client/UI/TargetCard.luau (scripts/ui/target_card.gd, UITargetCard).
# "Look before you act" card: the first tap on a foreign nation (or a coast reached by boat)
# selects it and shows who it is, with a big primary order button ("Attack · 12.3K"). A second
# tap on the same target, or the button, fires; Ally proposes an alliance; the close button or a
# tap elsewhere closes it. For an ally (kind "ally") it offers Donate and Break alliance, which
# first asks for confirmation and spells out the Traitor penalty.
class_name TargetCard
extends Control

signal fire
signal ally
signal closed
## Break the alliance; `attack` = also attack them right away (a betrayal).
signal betray(attack: bool)
signal donate

const LIFETIME := 12.0

var ctx: UICtx
var tile := -1
var owner_id := 0
var kind := ""  # "attack", "boat" or "ally"
var confirming := false
var shown_msec := 0.0
var is_open := false
## the command bar (the card sits above it)
var bar: CommandBar = null
var _age := 0.0
var _panel: GlassPanel
var _sw: PanelContainer
var _name: Label
var _badge: PanelContainer
var _badge_l: Label
var _close: Button
var _sub: Label
var _stats: HBoxContainer
var _troops: Label
var _land: Label
var _odds: Label
var _odds_warn := false
var _warn: Label
var _go: Button
var _donate: Button
var _ally: Button
var _btns2: HBoxContainer
var _break_only: Button
var _keep: Button


static func close_button(icon_px: int) -> Button:
	var b := UITheme.button("", "GhostButton", "close", 44.0)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_constant_override("icon_max_width", icon_px)
	b.custom_minimum_size = Vector2(44, 44)
	return b


func _init(c: UICtx) -> void:
	ctx = c
	name = "TargetCard"
	theme = UITheme.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := GlassPanel.new(12.0, 10.0, UITheme.R_LG, true, 20)
	panel.set_accent(UITheme.AMBER)
	_panel = panel
	add_child(panel)
	var v := UITheme.vbox(8)
	panel.add_child(v)

	var head := UITheme.hbox(8)
	_sw = UITheme.swatch(UITheme.TEXT, 12.0, 3)
	head.add_child(_sw)
	_name = UITheme.label("", 15, 700)
	UITheme.fix_width(_name, 150.0, HORIZONTAL_ALIGNMENT_LEFT, false)
	_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_name)
	_badge = PanelContainer.new()
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_badge_l = UITheme.label("", 12, 700, UITheme.TEXT_2, 1)
	_badge.add_child(_badge_l)
	head.add_child(_badge)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(sp)
	_close = close_button(14)
	_close.pressed.connect(func() -> void: hide_card(true))
	head.add_child(_close)
	v.add_child(head)

	_sub = UITheme.label("", 12, 500, UITheme.TEXT_2)
	v.add_child(_sub)
	var stats := UITheme.hbox(14)
	_stats = stats
	_troops = UITheme.label("", 13, 600)
	UITheme.fix_width(_troops, 110.0, HORIZONTAL_ALIGNMENT_LEFT, false)
	stats.add_child(_troops)
	_land = UITheme.label("", 13, 600, UITheme.TEXT_2)
	UITheme.fix_width(_land, 96.0, HORIZONTAL_ALIGNMENT_LEFT, false)
	stats.add_child(_land)
	v.add_child(stats)
	_odds = UITheme.label("", 12, 600, UITheme.TEXT_3)
	v.add_child(_odds)
	_warn = UITheme.label("", 13, 600, Color(1.0, 0.82, 0.8))
	_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warn.custom_minimum_size = Vector2(240, 0)
	_warn.visible = false
	v.add_child(_warn)

	var btns := UITheme.hbox(8)
	_go = UITheme.button("Attack", "PrimaryButton", "attack", 48.0)
	_go.add_theme_font_size_override("font_size", 15)
	_go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_go.pressed.connect(_on_go)
	btns.add_child(_go)
	_donate = UITheme.button("Donate", "GlassButton", "donate", 48.0)
	_donate.add_theme_font_size_override("font_size", 13)
	_donate.pressed.connect(func() -> void: donate.emit())
	_donate.visible = false
	btns.add_child(_donate)
	_ally = UITheme.button("Ally", "GlassButton", "alliance", 48.0)
	_ally.add_theme_font_size_override("font_size", 13)
	_ally.pressed.connect(func() -> void: ally.emit())
	btns.add_child(_ally)
	v.add_child(btns)

	# Confirmation row: break without attacking, or keep the alliance.
	_btns2 = UITheme.hbox(8)
	_break_only = UITheme.button("Break only", "GlassButton", "betray", 44.0)
	_break_only.add_theme_font_size_override("font_size", 13)
	_break_only.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_break_only.pressed.connect(func() -> void: betray.emit(false))
	_btns2.add_child(_break_only)
	_keep = UITheme.button("Keep ally", "GlassButton", "alliance", 44.0)
	_keep.add_theme_font_size_override("font_size", 13)
	_keep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_keep.pressed.connect(func() -> void: hide_card(true))
	_btns2.add_child(_keep)
	_btns2.visible = false
	v.add_child(_btns2)

	panel.custom_minimum_size = Vector2(300, 0)
	visible = false
	set_process(true)


## Select `t` for order `k` ("attack" / "boat" / "ally"); `act` is UIRules.primary() for that tile.
func show_target(t: int, k: String, act: Dictionary) -> void:
	var s = ctx.state
	if s == null:
		return
	tile = t
	kind = k
	confirming = false
	owner_id = s.tile_owner(t)
	shown_msec = UICtx.msec()
	_age = 0.0
	var mine := float(act.get("troops", 0.0))
	var troops := UITheme.fmt_troops(mine)
	var c := ctx.compact
	if owner_id != 0:
		var o = s.get_owner(owner_id)
		UITheme.set_swatch_color(_sw, o.color if o != null else UITheme.TEXT)
		_sw.visible = true
		_name.text = s.owner_name(owner_id)
		var rel := ctx.relation(owner_id)
		_badge.visible = rel != ""
		var rc := ctx.relation_color(rel)
		_badge_l.text = rel.to_upper()
		UITheme.set_font_color(_badge_l, rc)
		_badge.add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(rc, 0.14), 999, UITheme.c(rc, 0.5), 1, 8.0, 1.0))
		_sub.text = "%s  ·  %s" % [ctx.kind_title(o.kind if o != null else 0), ctx.terrain_title(t)]
		_troops.text = "Troops " + UITheme.fmt_troops(o.troops if o != null else 0)
		_land.text = "Land " + UITheme.fmt_pct(s.land_share(owner_id))
		var theirs: float = float(o.troops) if o != null else 0.0
		_odds.visible = true
		if theirs > mine * 1.5:
			_odds.text = "They outnumber the %s troops you would send" % troops
			UITheme.set_font_color(_odds, UITheme.ORANGE)
			_odds_warn = true
		else:
			_odds.text = "You would send %s troops" % troops
			UITheme.set_font_color(_odds, UITheme.TEXT_3)
			_odds_warn = false
		_ally.visible = kind == "attack" or kind == "boat"
		_ally.disabled = s.has_request(ctx.me(), owner_id)
	else:
		_sw.visible = false
		_name.text = "Unclaimed land"
		_badge.visible = false
		_sub.text = ctx.terrain_title(t) + "  ·  across the sea"
		_troops.text = ""
		_land.text = ""
		_odds.visible = true
		_odds.text = "A transport lands %s troops here" % troops
		UITheme.set_font_color(_odds, UITheme.TEXT_3)
		_odds_warn = false
		_ally.visible = false
	_sub.visible = true
	var plan = null
	if kind == "ally" and owner_id != 0:
		var oa = s.get_owner(owner_id)
		plan = ctx.rules.donate_plan(owner_id) if ctx.rules != null else null
		# Near their troop cap: say how much still fits (a gift above the cap evaporates).
		var who := "Your teammate" if s.same_team(ctx.me(), owner_id) else "Your ally"
		var their := UITheme.fmt_troops(oa.troops if oa != null else 0)
		if plan != null and plan.get("capped", false):
			_sub.text = "%s · %s troops · room for %s" % [who, their, UITheme.fmt_troops(plan.room)]
		else:
			_sub.text = "%s · %s troops · %s land" % [who, their, UITheme.fmt_pct(s.land_share(owner_id))]
	# Phones: one info line (who · troops · land); the odds line only when it is a warning.
	_stats.visible = not c
	if c and owner_id != 0 and kind != "ally":
		var o2 = s.get_owner(owner_id)
		_sub.text = "%s · %s troops · %s land" % [ctx.kind_title(o2.kind if o2 != null else 0), UITheme.fmt_troops(o2.troops if o2 != null else 0), UITheme.fmt_pct(s.land_share(owner_id))]
		_odds.visible = _odds_warn
	elif c and owner_id == 0:
		_odds.visible = false
		_sub.text = "%s · across the sea · lands %s troops" % [ctx.terrain_title(t), troops]
	for b: Button in [_go, _ally]:
		b.custom_minimum_size.y = 44.0 if c else 48.0
	_panel.custom_minimum_size = Vector2(250 if c else 300, 0)
	UITheme.fix_width(_name, 110.0 if c else 150.0, HORIZONTAL_ALIGNMENT_LEFT, false)
	_panel.set_padding(10.0 if c else 12.0, 2.0 if c else 10.0, 4.0 if c else 12.0, 8.0 if c else 10.0)
	var verb := "Attack" if kind == "attack" else "Invade"
	_go.text = "%s · %s" % [verb, troops]
	_go.icon = UITheme.icon_texture("attack" if kind == "attack" else "boat")
	_go.theme_type_variation = "PrimaryButton"
	_panel.set_accent(UITheme.AMBER if kind == "attack" else UITheme.CYAN)
	_warn.visible = false
	_btns2.visible = false
	_donate.visible = false
	_go.visible = true
	if kind == "ally":
		_odds.visible = false
		# (a teammate: no alliance to break)
		_go.visible = not s.same_team(ctx.me(), owner_id)
		_ally.visible = false
		_donate.visible = true
		var amt: float = float(plan.amount) if plan != null else ctx.troops_for_ratio()
		var full: bool = plan != null and plan.get("full", false)
		_donate.text = "At troop cap" if full else "Donate " + UITheme.fmt_troops(amt)
		_donate.disabled = amt < 1.0 or full
		_go.text = "Break alliance"
		_go.icon = UITheme.icon_texture("betray")
		_go.theme_type_variation = "DangerButton"
		_panel.set_accent(UITheme.VIOLET)
	var was := is_open
	is_open = true
	visible = true
	modulate.a = 1.0
	place()
	if not was:
		UIFx.pop_in(_panel, 0.0, 0.94, 0.25)
	ctx.sfx("click", -8.0)


## Same target as the current selection (owner for attacks; nearby coast for boats), still fresh.
func matches(t: int, k: String) -> bool:
	if not is_open or k != kind or UICtx.msec() - shown_msec > LIFETIME * 1000.0:
		return false
	var s = ctx.state
	if s == null:
		return false
	if k == "attack":
		return s.tile_owner(t) == owner_id and owner_id != 0
	return _tile_distance(t, tile) <= 4.0 or (owner_id != 0 and s.tile_owner(t) == owner_id)


func _tile_distance(a: int, b: int) -> float:
	var w: int = ctx.state.map.W
	return Vector2(a % w - b % w, a / w - b / w).length()


## Ally card: ask before breaking the alliance (the Traitor penalty is spelled out).
func confirm_betray() -> void:
	if not is_open or kind != "ally":
		return
	confirming = true
	_age = 0.0
	var secs := Defs.round_i(float(SimRules.TRAITOR_TICKS) / SimRules.TICK_RATE)
	_warn.text = "Break the alliance with %s? For %d s you are a TRAITOR: every nation sees it and attacks on you cost only %d%% of the troops." % [
		ctx.state.owner_name(owner_id) if ctx.state != null else "them", secs, Defs.round_i(SimRules.TRAITOR_DEFENSE_DEBUFF * 100.0)]
	_warn.visible = true
	_sub.visible = false
	_donate.visible = false
	_btns2.visible = true
	_go.text = "Betray & attack · " + UITheme.fmt_troops(ctx.troops_for_ratio())
	_go.icon = UITheme.icon_texture("attack")
	_panel.set_accent(UITheme.RED)
	place()
	ctx.sfx("open", -8.0)


func _on_go() -> void:
	if kind != "ally":
		fire.emit()
	elif not confirming:
		confirm_betray()
	else:
		betray.emit(true)


func hide_card(user: bool = false) -> void:
	if not is_open:
		return
	is_open = false
	var t := create_tween()
	t.tween_property(self, "modulate:a", 0.0, 0.12)
	t.tween_callback(func() -> void:
		if not is_open:
			visible = false
		modulate.a = 1.0)
	if user:
		ctx.sfx("close", -8.0)
	closed.emit()


## Bottom-left above the command bar on phones (the thumb side, clear of the Attacks column);
## centred above the bar on larger screens.
func place() -> void:
	var area := ctx.clear_rect()
	var sz := _panel.get_combined_minimum_size()
	var bottom := area.end.y
	if bar != null and bar.is_visible_in_tree():
		bottom = minf(bottom, bar.top_edge())
	var y := maxf(bottom - sz.y - 10.0, area.position.y + 4.0)
	var left := Vector2(area.position.x + 10.0, y)
	var right := Vector2(area.end.x - sz.x - 10.0, y)
	var top_y := area.position.y + 4.0
	var cands: Array[Vector2] = []
	if not ctx.compact:
		cands.append(Vector2((ctx.vp.x - sz.x) * 0.5, y))
	cands.append(left)
	cands.append(right)
	# Narrow screens: a mid-screen target can sit under both bottom corners; try the top ones.
	cands.append(Vector2(left.x, top_y))
	cands.append(Vector2(right.x, top_y))
	# Never cover the target itself (the second tap must reach it).
	var tp := ctx.tile_screen_pos(tile) if tile >= 0 else Vector2(-1, -1)
	var p := cands[0]
	for cnd in cands:
		if not (tp.x >= 0 and Rect2(cnd, sz).grow(24.0).has_point(tp)):
			p = cnd
			break
	_panel.position = Vector2(floorf(p.x + 0.5), floorf(p.y + 0.5))
	_panel.reset_size()


func panel_rect() -> Rect2:
	return _panel.get_global_rect() if is_open else Rect2()


func _process(delta: float) -> void:
	if not is_open:
		return
	# The betray confirm is a destructive choice: it waits for an answer (Break only / Keep ally /
	# close) instead of closing under the pointer. Any card also holds while the mouse rests on it.
	if confirming:
		# ...unless the question is moot (the alliance already ended some other way).
		var s = ctx.state
		if s == null or not s.are_allies(ctx.me(), owner_id):
			hide_card()
		return
	if not ctx.touch and _panel.get_global_rect().has_point(ctx.mouse_pos()):
		return
	_age += delta
	if _age > LIFETIME:
		hide_card()
