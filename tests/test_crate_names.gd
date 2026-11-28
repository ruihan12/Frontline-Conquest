# Item names fit their cards (owner report 2026-11-28: on the Open x10 reveal, "Central African Republic" and
# "Federated States of Micronesia" ran into the next card). The reveal cards of an x10 and of a single opening
# are built with the longest flag names; every name line, measured with the label's own font and size, must be
# no wider than the card's inner width, sit inside the card above the rarity line, and the card size and the
# rarity line's place must be what they were. Every one of the 258 flag names is checked the same way for both
# card sizes, and the two names from the report must show in full. The Locker grid's flag cards cut with an
# ellipsis inside the card (upstream Locker: TextTruncate AtEnd).
#   godot --headless --path . -s res://tests/test_crate_names.gd
extends SceneTree

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print(("  ok   " if ok else "  FAIL ") + what)


func _initialize() -> void:
	_run()


func _longest_flags(n: int) -> Array:
	var fl: Array = []
	for f: Array in RWCosmetics.FLAGS:
		fl.append(f)
	fl.sort_custom(func(a: Array, b: Array) -> bool: return str(a[1]).length() > str(b[1]).length())
	var ids: Array = []
	for f: Array in fl.slice(0, n):
		ids.append("flag_" + str(f[0]))
	return ids


func _id_of(name: String) -> String:
	for f: Array in RWCosmetics.FLAGS:
		if str(f[1]) == name: return "flag_" + str(f[0])
	return ""


# the reveal cards of one opening: [worst line width - inner width, cards checked, names shown in full]
func _reveal(cr, ids: Array, what: String) -> Dictionary:
	cr._rids = ids
	cr._build_show()
	cr._reveal_cards()
	var n := ids.size()
	var cw := 190.0 if n == 1 else 112.0
	var chh := 230.0 if n == 1 else 138.0
	var full := {}
	var bad: Array = []
	for i in cr._rcards.size():
		var card: Control = cr._rcards[i]
		var nm: Label = card.get_node("ItemName")
		var rl: Label = card.get_node("Rarity")
		var font: Font = nm.get_theme_font("font")
		var fs: int = nm.get_theme_font_size("font_size")
		var inner := card.size.x - 12.0
		var name := str(CosmeticsRules.item(ids[i]).name)
		var lines: PackedStringArray = nm.text.split("\n")
		var widest := 0.0
		for ln in lines:
			widest = maxf(widest, font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		var h := font.get_height(fs) * lines.size()
		if widest > inner + 0.01: bad.append("%s %.1f > %.1f px" % [name, widest, inner])
		if nm.position.x < 0.0 or nm.position.x + nm.size.x > card.size.x: bad.append("%s label outside the card" % name)
		if nm.position.y + nm.size.y > rl.position.y + 0.01 or nm.size.y + 0.01 < h: bad.append("%s over the rarity line" % name)
		if not card.size.is_equal_approx(Vector2(cw, chh)): bad.append("%s card size %s" % [name, card.size])
		if not is_equal_approx(rl.position.y, chh - (28.0 if n == 1 else 20.0)): bad.append("%s rarity moved" % name)
		var tr: TextureRect = null
		for ch in card.get_children():
			if ch is TextureRect: tr = ch
		if tr != null and tr.position.y + tr.size.y > nm.position.y: bad.append("%s picture under the name" % name)
		if " ".join(lines) == name: full[name] = true
	_check(bad.is_empty() and cr._rcards.size() == n, "%s: %d cards, every name inside its card%s"
		% [what, cr._rcards.size(), "" if bad.is_empty() else ": " + "; ".join(bad)])
	cr._end_show()
	return full


func _run() -> void:
	var hs = load("res://sim/headless_sim.gd").new(self)
	await hs.ready_async()
	var m = hs.m
	var cr = m.client.crates
	cr.open()
	for _i in 3: await process_frame
	# Open x10 with the ten longest flag names, and with the two from the report among them
	_reveal(cr, _longest_flags(10), "Open x10, the 10 longest flag names")
	var named: Array = [_id_of("Central African Republic"), _id_of("Federated States of Micronesia")]
	_check(not named.has(""), "the two names from the report are flags")
	var ten: Array = named.duplicate()
	for id in _longest_flags(12): if not ten.has(id): ten.append(id)
	var full: Dictionary = _reveal(cr, ten.slice(0, 10), "Open x10 with the reported names")
	_check(full.has("Central African Republic") and full.has("Federated States of Micronesia"),
		"\"Central African Republic\" and \"Federated States of Micronesia\" show in full on the x10 cards")
	_reveal(cr, _longest_flags(1), "single opening, the longest flag name")
	# every flag name, both card sizes, through the same fit
	var font: Font = UITheme.font(800.0)
	for conf in [[112.0, 12, 9, "x10"], [190.0, 18, 12, "single"]]:
		var inner: float = float(conf[0]) - 12.0
		var worst := 0.0
		var cut := 0
		var nbad := 0
		for f: Array in RWCosmetics.FLAGS:
			var r: Array = Crates.fit_name(font, str(f[1]), inner, int(conf[1]), int(conf[2]))
			var lines: PackedStringArray = r[0]
			for ln in lines:
				var w := font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, int(r[1])).x
				worst = maxf(worst, w)
				if w > inner + 0.01: nbad += 1
			if lines.size() > 2: nbad += 1
			if " ".join(lines) != str(f[1]): cut += 1
		_check(nbad == 0, "%s: all %d flag names fit %.0f px (widest line %.1f px, %d cut with an ellipsis)"
			% [conf[3], RWCosmetics.FLAGS.size(), inner, worst, cut])
	# the Locker grid's flag cards
	cr._tab = 1
	cr._refresh()
	for _i in 2: await process_frame
	var cards := 0
	var gbad: Array = []
	var stack: Array = [cr]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for ch in nd.get_children(): stack.append(ch)
		if nd is Button and nd.get_child_count() >= 3 and nd.get_child(1) is Label:
			var b: Button = nd
			var lb: Label = b.get_child(1)
			cards += 1
			if not (lb.clip_text and lb.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS) or lb.position.x < 0.0 \
					or lb.position.x + lb.size.x > b.custom_minimum_size.x:
				gbad.append(lb.text)
	_check(cards > 200 and gbad.is_empty(), "Locker grid: %d flag cards cut long names with an ellipsis inside the card%s"
		% [cards, "" if gbad.is_empty() else ": " + ", ".join(gbad.slice(0, 5))])
	cr.close()
	print("CRATE_NAMES_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
