# Port of src/client/UI/UIInteract.luau (scripts/ui/ui_interact.gd): what the pointer does on the
# map. So far the hover part: on_hover, _update_tooltip, hover_spec, _aim_spec, _crowding and the
# per-frame refresh, and the action ring: on_context, on_radial, donate_to, retreat, _float,
# show_inspect. Left clicks, the placement ghost, unit selection and the keys are still handled by
# main.gd and come over with MapInput.
class_name UIInteract
extends RefCounted

## Nations / tribes / commanders whose capital lies within ~88 full-size tiles count as neighbours
## of a spawn spot.
const CROWD_FULL_TILES := 88.0

var ctx: UICtx
var tooltip: Tooltip = null
var radial: RadialMenu = null
var bar: CommandBar = null
## The layer floating confirmations are added to.
var float_layer: Control = null
var _last_ctx_msec := -100000.0
var _range_focus := -1
## Current placement kind ("" = none): a structure, "warship" or a nuke.
var aim_kind := ""
var hover_tile := -1
var enabled := false
var _confirm_tile := -1
var _tip_accum := 0.0
var _tip_dirty := false
var _tip_wait := 0.0


func _init(c: UICtx) -> void:
	ctx = c


func on_hover(tile: int) -> void:
	hover_tile = tile
	if not enabled or ctx.state == null:
		ctx.world_call("set_hover_owner", [0])
		if tooltip.place == Tooltip.PLACE_FOLLOW:
			tooltip.hide_tip()
		return
	var s = ctx.state
	var own: int = s.tile_owner(tile) if tile >= 0 else 0
	ctx.world_call("set_hover_owner", [own])
	# The hover card is rebuilt at most ~16x per second (its hint may search the map).
	_tip_dirty = true
	if _tip_wait <= 0.0:
		_tip_wait = 0.06
		_tip_dirty = false
		_update_tooltip()


func _update_tooltip() -> void:
	if tooltip.place == Tooltip.PLACE_PINNED and tooltip.is_shown():
		return
	if tooltip.place == Tooltip.PLACE_ANCHOR and tooltip.is_shown():
		return
	if ctx.touch or (radial != null and radial.is_open) or not enabled:
		if tooltip.place == Tooltip.PLACE_FOLLOW:
			tooltip.hide_tip()
		return
	var spec := hover_spec(hover_tile)
	if spec.is_empty():
		tooltip.hide_tip()
	else:
		tooltip.show_follow(spec)


## Nations around a spawn spot (within CROWD_FULL_TILES full-size tiles).
func _crowding(tile: int) -> int:
	var s = ctx.state
	if s == null or tile < 0:
		return 0
	var w: int = s.map.W
	var r: float = CROWD_FULL_TILES / maxf(s.map.k_lin, 0.01)
	var r2 := r * r
	var hx := tile % w
	@warning_ignore("integer_division")
	var hy := tile / w
	var n := 0
	var mine := ctx.me()
	for o in s.owners():
		if not o.alive or o.id == mine:
			continue
		var t: int = o.get("label_tile", -1)
		if t >= 0:
			var dx := t % w - hx
			@warning_ignore("integer_division")
			var dy := t / w - hy
			if dx * dx + dy * dy <= r2:
				n += 1
	return n


func hover_spec(tile: int, pinned: bool = false) -> Dictionary:
	var Th := UITheme
	var s = ctx.state
	if s == null or tile < 0:
		return {}
	var map = s.map
	var own: int = s.tile_owner(tile)
	var terrain := ctx.terrain_title(tile)
	var spec := {}
	if aim_kind != "" and not pinned:
		return _aim_spec(tile)
	if own != 0:
		var o = s.get_owner(own)
		if o == null:
			return {}
		var rel := ctx.relation(own)
		spec["title"] = o.name
		spec["swatch"] = o.color
		spec["badge"] = rel
		spec["badge_color"] = ctx.relation_color(rel)
		spec["sub"] = "%s  ·  %s" % [ctx.kind_title(o.kind), terrain]
		var rows := [["Troops", Th.fmt_troops(o.troops), Th.TEXT], ["Land", Th.fmt_pct(s.land_share(own)), Th.TEXT]]
		if own == ctx.me() or pinned:
			rows.append(["Gold", Th.fmt_num(o.gold), Th.GOLD])
		var st = ctx.structure_at(tile, 1)
		if st != null and st.owner == own and st.kind >= 0:
			var lv := " · Lv %d" % st.level if st.level > 1 else ""
			rows.append(["Structure", Defs.STRUCT_TITLES[st.kind] + lv, Th.TEXT])
			if st.active_tick > s.tick:
				# Under construction: it does nothing yet (no cap, trade, defense, interception, launch).
				rows.append(["Building…", Th.fmt_time(ceil(float(st.active_tick - s.tick) / Defs.TICK_RATE)), Th.ORANGE])
		if s.is_traitor(own):
			rows.append(["Traitor", "%ds left" % int(ceil(float(o.traitor_until - s.tick) / Defs.TICK_RATE)), Th.RED])
		# the player panel's "Alliance Expires In": red in the last 30 s, yellow in the last 60 s
		var ai = s.alliance_info(ctx.me(), own) if own != ctx.me() else null
		if ai != null and ai.expires_at >= 0:
			var secs := int(ceil(float(ai.ticks_left) / Defs.TICK_RATE))
			var col: Color = Th.RED if secs <= 30 else (Th.AMBER if secs <= 60 else Th.GREEN)
			rows.append(["Alliance ends", Th.fmt_time(secs), col])
			if ai.me_asked or ai.other_asked:
				rows.append(["Renewal", "asked, waiting for them" if ai.me_asked else "they asked", Th.VIOLET])
		spec["rows"] = rows
	elif map.is_land(tile):
		var fallout: bool = s.has_fallout(tile)
		spec["title"] = ("Unclaimed  ·  " + terrain) if not fallout else "Fallout zone"
		spec["title_color"] = Th.TEXT_2 if not fallout else Th.ORANGE
		var st2 = ctx.structure_at(tile, 0)
		if st2 != null and st2.kind >= 0:
			spec["sub"] = Defs.STRUCT_TITLES[st2.kind]
	else:
		if not pinned:
			return {}
		spec["title"] = terrain
		spec["title_color"] = Th.TEXT_2
	if pinned:
		return spec
	var act: Dictionary = ctx.rules.primary(tile)
	var verb := "Tap" if ctx.touch else "Click"
	var ty := str(act.type)
	if ty == "spawn":
		spec["hint"] = verb + " to place your capital here"
		spec["hint_color"] = Th.AMBER
		spec["hint_icon"] = "target"
		var crowd := _crowding(tile)
		var rows2: Array = spec.get("rows", [])
		if crowd >= 6:
			rows2.append(["Neighbours", "%d nearby · crowded, tough start" % crowd, Th.ORANGE])
		elif crowd >= 3:
			rows2.append(["Neighbours", "%d nearby · contested" % crowd, Th.AMBER])
		else:
			rows2.append(["Neighbours", "%d nearby · open land, safer start" % crowd, Th.GREEN])
		spec["rows"] = rows2
	elif ty == "expand" or ty == "attack":
		if act.ok:
			spec["hint"] = "%s: %s with %s" % [verb, "expand" if ty == "expand" else "attack", Th.fmt_troops(act.troops)]
			spec["hint_color"] = Th.GREEN if ty == "expand" else Th.AMBER
			spec["hint_icon"] = "attack"
	elif ty == "boat":
		if act.ok:
			spec["hint"] = "%s: boat invasion with %s" % [verb, Th.fmt_troops(act.troops)]
			spec["hint_color"] = Th.CYAN
			spec["hint_icon"] = "boat"
		else:
			spec["hint"] = str(act.reason)
			spec["hint_color"] = Th.TEXT_3
			spec["hint_icon"] = "boat"
	elif ty == "none":
		if str(act.reason) != "":
			spec["hint"] = str(act.reason)
			spec["hint_color"] = Th.TEXT_3
			spec["hint_icon"] = "info"
	if s.phase == Defs.PHASE_PLAYING and ctx.alive_player():
		spec["footer"] = "Right-click for more actions"
	return spec


func _aim_spec(tile: int) -> Dictionary:
	var Th := UITheme
	var k := aim_kind
	var nuke := UIRules.is_nuke(k)
	var title: String = UIRules.TITLES.get(k, k)
	var spec := {"title": ("Launch " if nuke else "Build ") + title, "title_color": Th.RED if nuke else Th.TEXT}
	var av: Dictionary = ctx.rules.availability(k)
	var pl: Dictionary = ctx.rules.placement(k, tile)
	# Your own structure under the cursor: the click upgrades it.
	var upgrade: bool = pl.ok and pl.get("upgrade", false) == true and not nuke
	if upgrade:
		spec["title"] = "Upgrade %s → Lv %d" % [title, int(pl.get("level", 2))]
	var rows := [["Cost", Th.fmt_cost(av.cost) + " gold", Th.GOLD]]
	if nuke:
		rows.append(["Blast radius", ctx.rules.blast_text(k), Th.TEXT])
		if tile >= 0 and ctx.state.tile_owner(tile) != 0:
			rows.append(["Target", ctx.state.owner_name(ctx.state.tile_owner(tile)), Th.TEXT])
		# Hostile SAM cover of the aimed tile (the view counts it for the current aim).
		var ns = ctx.world_call("aim_sams", [tile])
		var n_sam := int(ns) if ns != null else 0
		if n_sam > 0 and k != "mirv":
			rows.append(["SAM cover", "%d SAM%s cover this target" % [n_sam, "" if n_sam == 1 else "s"], Th.RED])
	spec["rows"] = rows
	var verb := "Tap" if ctx.touch else "Click"
	if not pl.ok:
		spec["hint"] = str(pl.reason)
		spec["hint_color"] = Th.RED
		spec["hint_icon"] = "info"
	else:
		spec["hint"] = (verb + " to target") if nuke else ((verb + " to upgrade") if upgrade else (verb + " to build here"))
		spec["hint_color"] = Th.GREEN
		spec["hint_icon"] = "target"
		if str(pl.get("warn", "")) != "":
			spec["body"] = str(pl.warn)
	# (Esc opens the game menu's cancel here as well; right-click cancels.)
	spec["footer"] = "Right-click or Esc to cancel" if not ctx.touch else "Long-press to cancel"
	return spec


func process_frame(delta: float) -> void:
	if _tip_wait > 0.0:
		_tip_wait -= delta
		if _tip_wait <= 0.0 and _tip_dirty:
			_tip_dirty = false
			_tip_wait = 0.06
			_update_tooltip()
	# Keep the hover card's numbers fresh while the pointer rests.
	_tip_accum += delta
	if _tip_accum >= 0.5:
		_tip_accum = 0.0
		if enabled and tooltip.place == Tooltip.PLACE_FOLLOW and tooltip.is_shown():
			_update_tooltip()


# ---------------------------------------------------------------------------------------------
# The action ring
# ---------------------------------------------------------------------------------------------
## Right-click (long-press) on the map: the ring of actions for that tile.
func on_context(tile: int, screen_pos: Vector2) -> void:
	if not enabled or ctx.state == null:
		return
	var now := UICtx.msec()
	if now - _last_ctx_msec < 350:
		return
	_last_ctx_msec = now
	if tile < 0:
		return
	var s = ctx.state
	if s.phase == Defs.PHASE_SPAWN:
		return
	tooltip.hide_tip()
	var own: int = s.tile_owner(tile)
	var title := ctx.terrain_title(tile)
	var col: Color = UITheme.TEXT_2
	if own != 0:
		title = s.owner_name(own)
		col = UITheme.owner_ui_color(s.owner_color(own))
	elif s.map.is_contestable(tile):
		title = "Unclaimed " + ctx.terrain_title(tile).to_lower()
	radial.open_at(tile, screen_pos, ctx.rules.radial_items(tile), title, col)


func on_radial(id: String, tile: int) -> void:
	var Th := UITheme
	var s = ctx.state
	if s == null:
		return
	var own: int = s.tile_owner(tile)
	var pos := radial.center
	# "build:<kind>" or "build:<kind>:<amount>" (the bulk ring: several levels at once), likewise nukes
	if id.begins_with("build:"):
		var parts := id.split(":")
		var k := parts[1]
		var n := maxi(1, int(parts[2]) if parts.size() > 2 else 1)
		var cost: float = ctx.rules.bulk_cost(k, n) if n > 1 else ctx.rules.cost(k)
		ctx.send({"type": "build", "kind": k, "tile": tile, "amount": n})
		_float("%s%s  ·  %s gold" % [UIRules.TITLES[k], " ×%d" % n if n > 1 else "", Th.fmt_cost(cost)], k, Th.GOLD, pos)
		return
	if id.begins_with("nuke:"):
		var nparts := id.split(":")
		var nk := nparts[1]
		var nn := maxi(1, int(nparts[2]) if nparts.size() > 2 else 1)
		ctx.send({"type": "nuke", "kind": nk, "tile": tile, "amount": nn})
		_float("%s%s launched at %s" % [UIRules.TITLES[nk], " ×%d" % nn if nn > 1 else "", s.owner_name(own)], nk, Th.RED, pos)
		return
	if id == "attack":
		var act: Dictionary = ctx.rules.primary(tile)
		ctx.send({"type": "attack", "tile": tile, "ratio": ctx.order_ratio()})
		_float(ctx.rules.confirm_text(act), "attack", Th.AMBER if own != 0 else Th.GREEN, pos)
	elif id == "boat":
		var landing: int = ctx.rules.boat_landing(tile)
		ctx.send({"type": "boat", "tile": landing if landing >= 0 else tile, "ratio": ctx.order_ratio()})
		var act2: Dictionary = ctx.rules.primary(tile)
		act2.type = "boat"
		_float(ctx.rules.confirm_text(act2), "boat", Th.CYAN, pos)
	elif id == "ally_request":
		ctx.send({"type": "ally_request", "target": own})
		ctx.sfx("click")
		_float("Alliance proposed to " + s.owner_name(own), "alliance", Th.VIOLET, pos)
	elif id == "ally_accept":
		ctx.send({"type": "ally_reply", "target": own, "accept": true})
		_float("Alliance accepted", "alliance", Th.VIOLET, pos)
	elif id == "ally_extend":
		ctx.send({"type": "ally_extend", "target": own})
	elif id == "ally_break:yes":
		# (upstream asks on the ally card; until that card is ported the ring's own sub-ring asks)
		ctx.send({"type": "ally_break", "target": own})
		ctx.sfx("deny", -2.0)
		_float("You broke your alliance with " + s.owner_name(own), "betray", Th.RED, pos)
	elif id == "donate":
		donate_to(own, pos)
	elif id == "donate_gold":
		ctx.send({"type": "donate_gold", "target": own})
	elif id == "retreat":
		var aid := my_attack_on(own)
		if aid >= 0:
			retreat(aid)
	elif id == "focus":
		ctx.world_call("focus_tile", [tile])
	elif id == "info":
		show_inspect(tile)


## Send troops to ally `own` (ratio share, capped at their troop headroom; see UIRules.donate_plan)
## with a float at `pos`. False (and a deny float) when nothing useful can be sent.
func donate_to(own: int, pos: Vector2) -> bool:
	var Th := UITheme
	var plan: Dictionary = ctx.rules.donate_plan(own)
	var nm: String = ctx.state.owner_name(own)
	if plan.want < 1 or plan.full or plan.amount < 1:
		ctx.sfx("deny", -4.0)
		_float("No troops to spare" if plan.want < 1 else nm + " is at its troop cap", "info", Th.RED, pos)
		return false
	ctx.send({"type": "donate", "target": own, "troops": plan.amount})
	_float("Sent %s troops  ·  %s is now at its troop cap" % [Th.fmt_troops(plan.amount), nm] if plan.capped else "Sent %s troops to %s" % [Th.fmt_troops(plan.amount), nm], "donate", Th.GREEN, pos)
	return true


## Our newest outgoing attack against `target` (0 = expansion), or -1.
func my_attack_on(target: int) -> int:
	var best := -1
	if ctx.state == null:
		return best
	var mine := ctx.me()
	for a in ctx.state.attacks():
		if a.attacker == mine and a.target == target and a.aid > best:
			best = a.aid
	return best


func retreat(aid: int) -> void:
	var s = ctx.state
	if s == null:
		return
	for a in s.attacks():
		if a.aid == aid:
			ctx.send({"type": "retreat", "attack_id": aid})
			ctx.sfx("click")
			var who: String = s.owner_name(a.target) if a.target != 0 else "neutral land"
			_float("Retreating from " + who, "retreat", UITheme.CYAN, ctx.mouse_pos())
			return


## Backspace: pull back the most recent outgoing attack.
func retreat_latest() -> bool:
	var s = ctx.state
	if s == null:
		return false
	var best := -1
	var mine := ctx.me()
	for a in s.attacks():
		if a.attacker == mine and a.aid > best:
			best = a.aid
	if best < 0:
		return false
	retreat(best)
	return true


func _float(text: String, icon_name: String, col: Color, pos: Vector2) -> void:
	if not FloatText.bounds_provider.is_valid():
		FloatText.bounds_provider = float_bounds
	FloatText.spawn(float_layer, pos, text, icon_name, col, float_bounds())


## Where floating confirmations may appear: below the top bar row, above the command bar / tray.
func float_bounds() -> Rect2:
	var area := ctx.clear_rect()
	var bottom: float = bar.top_edge() if (bar != null and bar.is_visible_in_tree()) else area.end.y
	return Rect2(area.position, Vector2(area.size.x, minf(area.end.y, bottom) - area.position.y))


## The pinned card for a tile (the ring's Info).
func show_inspect(tile: int) -> void:
	var spec := hover_spec(tile, true)
	if spec.is_empty():
		return
	# Bottom-left above the command bar: the right column holds the Attacks panel on phones.
	var area := ctx.clear_rect()
	var bottom: float = bar.top_edge() - 8.0 if bar.is_visible_in_tree() else area.end.y
	tooltip.show_pinned(spec, Rect2(area.position.x, area.position.y, 0.0, bottom - area.position.y))
	# Never cover the tapped spot: move to the right when it lies under the card.
	var tp := ctx.tile_screen_pos(tile)
	if tp.x >= 0 and tooltip.target_rect().grow(24.0).has_point(tp):
		tooltip.show_pinned(spec, Rect2(area.end.x, area.position.y, 0.0, bottom - area.position.y))
	# A tapped SAM / defense post shows its range ring while the card is open.
	_range_focus = tile
	ctx.world_call("set_range_focus", [tile])
