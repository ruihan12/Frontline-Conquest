extends RefCounted
## Maintains border membership and insertion order after an ownership update.

# _upd_border with the map passed in (same test, same Dictionary operation, so key order is unchanged)
static func _refresh_tile(border: Array, t: int, om: PackedInt32Array, Wl: int, last_row: int) -> void:
	var o: int = om[t]
	if o <= 0: return
	var x := t % Wl
	var b := false
	var u: int
	if x > 0:
		u = om[t - 1]
		if u != o and u >= 0: b = true
	if not b and x < Wl - 1:
		u = om[t + 1]
		if u != o and u >= 0: b = true
	if not b and t >= Wl:
		u = om[t - Wl]
		if u != o and u >= 0: b = true
	if not b and t < last_row:
		u = om[t + Wl]
		if u != o and u >= 0: b = true
	var d: Dictionary = border[o]
	if b: d[t] = true
	else: d.erase(t)

static func refresh_after_capture(border: Array, i: int, o: int, x: int, om: PackedInt32Array, W: int, lr: int) -> void:
	_refresh_tile(border, i, om, W, lr)
	if o >= 0:
		# (perf) a neighbour owned by p != o now touches tile i (owner o >= 0): it is a border tile, so
		# _refresh_tile would do exactly border[p][t] = true; only o's own neighbours need the full test
		var t: int
		var p: int
		if x > 0:
			t = i - 1; p = om[t]
			if p > 0:
				if p != o: border[p][t] = true
				else: _refresh_tile(border, t, om, W, lr)
		if x < W - 1:
			t = i + 1; p = om[t]
			if p > 0:
				if p != o: border[p][t] = true
				else: _refresh_tile(border, t, om, W, lr)
		if i >= W:
			t = i - W; p = om[t]
			if p > 0:
				if p != o: border[p][t] = true
				else: _refresh_tile(border, t, om, W, lr)
		if i < lr:
			t = i + W; p = om[t]
			if p > 0:
				if p != o: border[p][t] = true
				else: _refresh_tile(border, t, om, W, lr)
	else:
		if x > 0: _refresh_tile(border, i - 1, om, W, lr)
		if x < W - 1: _refresh_tile(border, i + 1, om, W, lr)
		if i >= W: _refresh_tile(border, i - W, om, W, lr)
		if i < lr: _refresh_tile(border, i + W, om, W, lr)
