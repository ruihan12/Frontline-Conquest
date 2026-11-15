# Port of src/client/UI/TrayFit.luau: how the phone tray's slots and the SHOP button share a row.
class_name TrayFit
extends RefCounted

const SLOT_MAX := 60.0
const SLOT_MIN := 54.0
const SEP := 8.0
const SEP_TIGHT := 5.0
const CHROME := 33.0
const SHOP_W := 72.0


static func shop_width(n: int) -> float:
	return SHOP_W if n > 0 else 0.0


static func _need(slots: int, slot_w: float, sep: float, shop_w: float) -> float:
	return slots * (slot_w + sep) + shop_w + sep + CHROME


## {slot_w, sep, shop_w, two_rows}
static func fit(avail: float, slots: int, locked: int) -> Dictionary:
	var want := shop_width(locked)
	var slot_w := SLOT_MAX
	var sep := SEP
	var shop_w := maxf(want, slot_w)
	if _need(slots, slot_w, sep, shop_w) <= avail:
		return {"slot_w": slot_w, "sep": sep, "shop_w": shop_w, "two_rows": false}
	sep = SEP_TIGHT
	while slot_w > SLOT_MIN and _need(slots, slot_w, sep, maxf(want, slot_w)) > avail:
		slot_w -= 1
	shop_w = maxf(want, slot_w)
	if _need(slots, slot_w, sep, shop_w) > avail:
		shop_w = maxf(slot_w, floorf(avail - _need(slots, slot_w, sep, 0.0)))
	if _need(slots, slot_w, sep, shop_w) > avail:
		return {"slot_w": SLOT_MAX, "sep": SEP, "shop_w": maxf(want, SLOT_MAX), "two_rows": true}
	return {"slot_w": slot_w, "sep": sep, "shop_w": shop_w, "two_rows": false}
