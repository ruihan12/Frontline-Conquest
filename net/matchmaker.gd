class_name Matchmaker
extends RefCounted

const INITIAL_WINDOW := 100
const MAX_WINDOW := 600
const WINDOW_STEP := 25
const WINDOW_SECONDS := 10.0

class Entry:
	var account_id: int
	var elo: int
	var joined_at: float
	var tie: int
	var lower: int
	var upper: int

class Neighbors:
	var previous := PackedInt32Array()
	var next := PackedInt32Array()

	func _init(count: int) -> void:
		previous.resize(count)
		next.resize(count)
		for index in count:
			previous[index] = index - 1
			next[index] = index + 1

	func remove(index: int) -> void:
		var left := previous[index]
		var right := next[index]
		if left >= 0:
			next[left] = right
		if right < previous.size():
			previous[right] = left


var _entries := {}
var _min_players: int
var _max_players: int
var _seed: int


func _init(min_players := 4, max_players := 8, tie_seed := 0) -> void:
	_min_players = maxi(1, min_players)
	_max_players = maxi(_min_players, max_players)
	_seed = tie_seed


func enqueue(data: Dictionary) -> bool:
	var id = data.get("account_id")
	var rating = data.get("elo")
	var time = data.get("joined_at")
	if not id is int or id <= 0 or _entries.has(id) or not rating is int or rating < -2147483648 or rating > 2147483647:
		return false
	if not (time is float or time is int) or not is_finite(float(time)):
		return false
	var entry := Entry.new()
	entry.account_id = id
	entry.elo = rating
	entry.joined_at = float(time)
	entry.tie = hash([_seed, id]) & 0xffffffff
	_entries[id] = entry
	return true


func dequeue(account_id: int) -> bool:
	return _entries.erase(account_id)


func queue_size() -> int:
	return _entries.size()


func tick(now: float) -> Array:
	var matches := []
	if not is_finite(now) or _entries.size() < _min_players:
		return matches
	var entries := _ordered_entries()
	if entries[0].elo == entries[-1].elo:
		return _match_identical(entries)
	for entry: Entry in entries:
		var steps := floori(clampf((now - entry.joined_at) / WINDOW_SECONDS, 0.0, float((MAX_WINDOW - INITIAL_WINDOW) / WINDOW_STEP)))
		var width := INITIAL_WINDOW + WINDOW_STEP * steps
		entry.lower = entry.elo - width
		entry.upper = entry.elo + width
	var neighbors := Neighbors.new(entries.size())
	var active := PackedByteArray()
	active.resize(entries.size())
	active.fill(1)

	# Buckets ordered by smallest feasible rating spread, from 0 to 600. Removing
	# players can only make an anchor's candidate spread wider, so stale candidates
	# can be recomputed lazily without revisiting earlier buckets.
	var buckets := []
	for spread in MAX_WINDOW + 1:
		buckets.append([])
	var candidates := []
	candidates.resize(entries.size())
	for anchor in entries.size() - _min_players + 1:
		var group := _closest(anchor, entries, neighbors)
		if not group.is_empty():
			candidates[anchor] = group
			buckets[_spread(group, entries)].append(_candidate_key(entries[anchor], anchor))
	for spread in buckets.size():
		var bucket: Array = buckets[spread]
		if bucket.is_empty():
			continue
		bucket.sort()
		for key: int in bucket:
			var anchor := key & 0xffffffff
			if not active[anchor]:
				continue
			var group: PackedInt32Array = candidates[anchor]
			for index in group:
				if not active[index]:
					group = _closest(anchor, entries, neighbors)
					break
			if group.is_empty():
				continue
			var updated_spread := _spread(group, entries)
			if updated_spread > spread:
				candidates[anchor] = group
				buckets[updated_spread].append(key)
				continue
			group = _expand(group, entries, neighbors)
			var ids: Array[int] = []
			for index in group:
				var id: int = entries[index].account_id
				ids.append(id)
				active[index] = 0
				neighbors.remove(index)
				_entries.erase(id)
			matches.append(ids)
		if _entries.size() < _min_players:
			break
	return matches


func _ordered_entries() -> Array:
	# The high bits sort signed Elo and the low bits sort seeded priorities using
	# Godot's native integer sort. Resolve the rare hash collision by account ID.
	var keys := PackedInt64Array()
	var by_key := {}
	var collisions := {}
	for entry: Entry in _entries.values():
		var key := (entry.elo << 32) | entry.tie
		if by_key.has(key):
			if not collisions.has(key):
				collisions[key] = [by_key[key]]
			collisions[key].append(entry)
		else:
			keys.append(key)
			by_key[key] = entry
	keys.sort()
	var ordered := []
	for key in keys:
		if collisions.has(key):
			var group: Array = collisions[key]
			group.sort_custom(func(a: Entry, b: Entry) -> bool: return a.account_id < b.account_id)
			ordered.append_array(group)
		else:
			ordered.append(by_key[key])
	return ordered


func _match_identical(entries: Array) -> Array:
	var matches := []
	var offset := 0
	while entries.size() - offset >= _min_players:
		var end := mini(offset + _max_players, entries.size())
		var ids: Array[int] = []
		for index in range(offset, end):
			var id: int = entries[index].account_id
			ids.append(id)
			_entries.erase(id)
		matches.append(ids)
		offset = end
	return matches


func _candidate_key(entry: Entry, anchor: int) -> int:
	return ((entry.tie - 0x80000000) << 32) | anchor


func _seed_order(a: Entry, b: Entry) -> bool:
	return a.tie < b.tie if a.tie != b.tie else a.account_id < b.account_id


func _spread(group: PackedInt32Array, entries: Array) -> int:
	return entries[group[-1]].elo - entries[group[0]].elo


func _closest(anchor: int, entries: Array, neighbors: Neighbors) -> PackedInt32Array:
	var first: Entry = entries[anchor]
	var group := PackedInt32Array([anchor])
	if _min_players == 1:
		return group
	var cursor := neighbors.next[anchor]
	while cursor < entries.size():
		var other: Entry = entries[cursor]
		if other.elo > first.upper:
			break
		if other.lower <= first.elo:
			# As the right endpoint moves, a narrower interior window can
			# become incompatible even though it still reaches the left endpoint.
			for position in range(group.size() - 1, 0, -1):
				if entries[group[position]].upper < other.elo:
					group.remove_at(position)
			group.append(cursor)
			if group.size() == _min_players:
				return group
		cursor = neighbors.next[cursor]
	return PackedInt32Array()


func _expand(group: PackedInt32Array, entries: Array, neighbors: Neighbors) -> PackedInt32Array:
	if group.size() >= _max_players:
		return group
	var first: Entry = entries[group[0]]
	var last: Entry = entries[group[-1]]
	var low := first.elo
	var high := last.elo
	var lower_limit := first.lower
	var upper_limit := first.upper
	for index in group:
		lower_limit = maxi(lower_limit, entries[index].lower)
		upper_limit = mini(upper_limit, entries[index].upper)
	var left := neighbors.previous[group[0]]
	var right := neighbors.next[group[-1]]
	while group.size() < _max_players:
		var left_entry: Entry = entries[left] if left >= 0 else null
		var right_entry: Entry = entries[right] if right < entries.size() else null
		if left_entry != null and left_entry.elo < lower_limit:
			left_entry = null
		if right_entry != null and right_entry.elo > upper_limit:
			right_entry = null
		if left_entry == null and right_entry == null:
			break
		var take_left := right_entry == null
		if left_entry != null and right_entry != null:
			var left_distance := low - left_entry.elo
			var right_distance := right_entry.elo - high
			take_left = left_distance < right_distance or (left_distance == right_distance and _seed_order(left_entry, right_entry))
		var candidate := left_entry if take_left else right_entry
		var index := left if take_left else right
		if take_left:
			left = neighbors.previous[left]
		else:
			right = neighbors.next[right]
		if candidate.lower > low or candidate.upper < high:
			continue
		group.append(index)
		low = mini(low, candidate.elo)
		high = maxi(high, candidate.elo)
		lower_limit = maxi(lower_limit, candidate.lower)
		upper_limit = mini(upper_limit, candidate.upper)
	group.sort()
	return group
