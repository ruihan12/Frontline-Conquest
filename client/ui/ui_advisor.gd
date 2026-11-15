# Port of src/client/UI/UIAdvisor.luau: the parts this port needs.
# Ported: cool-downs, the "a neighbour has 5x your army" warning, the first-match coach tips, the
# new player's troop floor and its tip, the frontier point, and "THE WAR BEGINS".
#
# Not ported: the event handlers (on_nuke_launched, on_sam_launched, on_attack_started,
# on_alliance_changed, on_owner_eliminated, on_game_over, ...). Upstream turns sim events into feed
# cards there; this port's game already writes those lines itself (notify) and they reach the
# ported EventFeed through ClientHud.toast. Alliance renewal cards are raised by game/diplomacy.gd.
class_name UIAdvisor
extends RefCounted

## (Data/Tutorial)
const ROOKIE_MATCHES := 5
const ROOKIE_FLOOR := 0.2
const FLOOR_ARM := 0.35
const FLOOR_ARM_S := 10.0

var ui  # ClientHud
var ctx: UICtx
## Cool-downs for warnings, keyed "big:<id>" / "floor" -> msec.
var _warned := {}


func _init(root) -> void:
	ui = root
	ctx = root.ctx


func reset() -> void:
	_warned.clear()


func cooldown(key: String, ms: float) -> bool:
	var now := UICtx.msec()
	if _warned.has(key) and now - float(_warned[key]) < ms:
		return false
	_warned[key] = now
	return true


## A neighbour massing 5x our army is worth a warning before it strikes.
func check_threats() -> void:
	var s = ctx.state
	var o = ctx.my()
	if s == null or o == null or not ctx.alive_player() or s.phase != Defs.PHASE_PLAYING or o.troops <= 0:
		return
	var worst := 0
	var worst_troops := 0.0
	for id in ctx.borders.neighbour_ids():
		var n = s.get_owner(id)
		if n == null or not n.alive or s.are_allies(o.id, id):
			continue
		if n.troops >= 5 * o.troops and n.troops > worst_troops:
			worst = id
			worst_troops = n.troops
	if worst != 0 and cooldown("big:%d" % worst, 120000) and cooldown("big:any", 25000):
		var ratio_x := int(floor(worst_troops / maxf(o.troops, 1.0)))
		ui.feed.toast(Defs.MSG_BAD, "%s (%s troops) borders you with %d× your army. Fortify or find allies." % [s.owner_name(worst), UITheme.fmt_troops(worst_troops), ratio_x], "defense")


static func _centre_of(c) -> Vector2:
	if c is Control and c.is_visible_in_tree():
		return c.get_global_rect().get_center()
	return Vector2(-1, -1)


## First-match coach marks driven by what is happening.
func check_tips() -> void:
	var s = ctx.state
	var o = ctx.my()
	if s == null or o == null or not ctx.alive_player() or s.phase != Defs.PHASE_PLAYING or ui.screen() != "play":
		return
	var coach: Coach = ui.coach
	var secs := ctx.match_seconds()
	if secs > 3.4:  # after "THE WAR BEGINS" has faded
		coach.offer("expand", frontier_point)
	if secs > 22.0:
		coach.offer("ratio", func() -> Vector2: return _centre_of(ui.bar._slider))
	var city_cost: float = ctx.rules.cost("city")
	if secs > 25.0 and o.gold >= city_cost and city_cost > 0:
		coach.offer("city", func() -> Vector2:
			var cb = ui.bar.button("city")
			var b = cb if (cb != null and cb.is_visible_in_tree()) else ui.bar._tray_btn
			return _centre_of(b))
	var ns: Array[int] = ctx.borders.neighbour_ids()
	if not ns.is_empty() and secs > 8.0:
		var first := ns[0]
		coach.offer("contact", func() -> Vector2:
			var fo = s.get_owner(first)
			return ctx.tile_screen_pos(int(fo.label_tile)) if fo != null and fo.alive else Vector2(-1, -1), s.owner_name(first))
	if ctx.borders.has_coast() and secs > 40.0:
		coach.offer("boat")


## Matches finished before this one. (Port: there is no account; a save that already holds Stars
## is a player who has played.)
func matches_before() -> int:
	var n := int(ctx.setting("matches", 0))
	var g = ctx.session.g
	if int(g.save.get("stars", 0)) > 0:
		n += ROOKIE_MATCHES
	return n


## A new player's floor under the army: in the first ROOKIE_MATCHES matches an order leaves
## ROOKIE_FLOOR of the army's cap at home, from the time it arms (FLOOR_ARM of the cap, or
## FLOOR_ARM_S seconds in play). The host clears ctx.troop_floor for every new match.
func check_floor() -> void:
	var played := ctx.alive_seconds()
	if not is_nan(ctx.troop_floor) or not ctx.alive_player():
		return
	var o = ctx.my()
	if o == null or matches_before() >= ROOKIE_MATCHES:
		return
	var cap := float(o.get("max_troops", 0))
	if played >= FLOOR_ARM_S or (cap > 0 and float(o.troops) >= FLOOR_ARM * cap):
		ctx.troop_floor = ROOKIE_FLOOR


## The floor held an order back (UICtx.floor_held): the first time in a match, and then at most
## once a minute, a tip on the Attack bar says why.
func on_floor_held() -> void:
	if (ui.tutorial != null and ui.tutorial.active) or not cooldown("floor", 60000):
		return
	ui.coach.offer("floor", func() -> Vector2: return _centre_of(ui.bar._slider))


## Screen point of a neutral tile on our frontier (for the "expand" tip), or (-1, -1).
func frontier_point() -> Vector2:
	var s = ctx.state
	if s == null:
		return Vector2(-1, -1)
	var me := ctx.me()
	var map = s.map
	var w: int = map.W
	var total: int = w * int(map.H)
	var n := 0
	for t: int in ctx.borders.border():
		n += 1
		if n > 400:
			break
		for d: int in [1, -1, w, -w]:
			var nb := t + d
			if nb < 0 or nb >= total:
				continue
			if s.tile_owner(nb) == 0 and map.is_contestable(nb) and not s.has_fallout(nb):
				var p := ctx.tile_screen_pos(nb)
				if p.x >= 0.0:
					return p
	var mo = s.get_owner(me) if me != 0 else null
	return ctx.tile_screen_pos(int(mo.label_tile)) if mo != null else Vector2(-1, -1)


## Spawn -> play: a short "the war begins" moment and a glide to the capital.
func war_begins() -> void:
	var me := ctx.me()
	if me != 0:
		ctx.world_call("focus_owner", [me])
	# The camera lands the capital in the middle of the HUD-free band; use the roomier side of it,
	# and a title-only banner on very short screens.
	var band := ctx.clear_rect()
	if ui.bar.visible:
		band.end.y = minf(band.end.y, ui.bar.top_edge())
	if ui.top.visible:
		var cut := maxf(0.0, ui.top.bottom_edge() - band.position.y)
		band.position.y += cut
		band.size.y = maxf(1.0, band.size.y - cut)
	var cap_y := band.get_center().y
	var gap := 30.0 if ctx.compact else 60.0
	var above := cap_y - gap - band.position.y
	var below := band.end.y - (cap_y + gap)
	var h := 70.0 if ctx.compact else 96.0
	var small := maxf(above, below) < h
	if small:
		h = 38.0
	var top_y := cap_y - gap - h if above >= below else cap_y + gap
	top_y = maxf(top_y, band.position.y - 12.0)
	var nations := 0
	for o in ctx.state.owners():
		if int(o.kind) == Defs.KIND_NATION and o.alive:
			nations += 1
	var banner := Banner.make(ctx, "THE WAR BEGINS", "Expand, build and outlast %d nations" % nations, UITheme.AMBER, 1.6, top_y, h, small)
	banner.min_top = band.position.y - 12.0
	banner.max_bottom = band.end.y
	ui.float_layer.add_child(banner)
