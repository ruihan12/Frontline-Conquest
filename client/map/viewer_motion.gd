extends RefCounted
## Renderer-only samples stored on the receiver's copies of entity records.

const FIELDS := {"boats": "d", "traders": "d", "warships": "pos", "missiles": "t", "planes": "t"}
var _received := {}


func update(list_name: String, old: Array, incoming: Array) -> void:
	if not FIELDS.has(list_name):
		return
	var now := Time.get_ticks_msec()
	var duration := 100 if not _received.has(list_name) else clampi(now - _received[list_name], 16, 250)
	_received[list_name] = now
	var field: String = FIELDS[list_name]
	var previous := {}
	for item: Dictionary in old:
		if item.has(field):
			previous[_key(item, list_name)] = sample(item, field, float(now))
	for item: Dictionary in incoming:
		if not item.has(field):
			continue
		var from = previous.get(_key(item, list_name))
		if from == null:
			continue
		if from is Vector2:
			if from.distance_to(item[field]) > 6.0:
				continue
		elif float(from) > float(item[field]):
			continue  # same-route replacement at the start of a new flight
		item["_draw_previous"] = from
		item["_draw_received"] = now
		item["_draw_duration"] = duration


static func sample(item: Dictionary, field: String, now := -1.0):
	var current = item[field]
	if not item.has("_draw_previous"):
		return current
	if now < 0.0:
		now = float(Time.get_ticks_msec())
	var f := clampf((now - float(item._draw_received)) / float(item._draw_duration), 0.0, 1.0)
	return lerp(item._draw_previous, current, f)


static func _key(item: Dictionary, list_name: String):
	if item.has("uid"):
		return int(item.uid)
	if list_name == "traders":
		return [item.get("o", 0), item.get("pts")]
	return [item.get("o"), item.get("lt"), item.get("nk"), item.get("from"), item.get("to")]
