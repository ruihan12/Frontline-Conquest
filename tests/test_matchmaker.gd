extends SceneTree

const Queue := preload("res://net/matchmaker.gd")

var fails := 0


func _check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		print("FAIL ", message)


func _entry(id: int, elo: int, joined_at := 0.0) -> Dictionary:
	return {"account_id": id, "elo": elo, "joined_at": joined_at}


func _initialize() -> void:
	var widening := Queue.new(2, 4)
	widening.enqueue(_entry(1, 1000))
	widening.enqueue(_entry(2, 1125, 10.0))
	_check(widening.tick(9.9).is_empty(), "initial window is 100")
	_check(widening.tick(19.9).is_empty(), "one widened window is insufficient")
	_check(widening.tick(20.0) == [[1, 2]], "both windows widen by 25 every ten seconds")
	var capped := Queue.new(2, 4)
	capped.enqueue(_entry(1, 1000))
	capped.enqueue(_entry(2, 1601))
	_check(capped.tick(500.0).is_empty(), "window caps at 600")
	_check(capped.dequeue(2) and not capped.dequeue(2), "cancel removes the account once")
	_check(not capped.enqueue(_entry(1, 1700)), "duplicate enqueue preserves existing entry")
	capped.enqueue(_entry(2, 1600))
	_check(capped.tick(200.0) == [[1, 2]], "cap is inclusive")

	var close_first := Queue.new(3, 3)
	for id in 4:
		close_first.enqueue(_entry(id + 1, [1000, 1099, 1100, 1101][id]))
	_check(close_first.tick(0.0) == [[2, 3, 4]], "tightest eligible group forms before wider groups")
	var unequal := Queue.new(4, 4)
	unequal.enqueue(_entry(1, 1000))
	unequal.enqueue(_entry(2, 1020, 100.0))
	unequal.enqueue(_entry(3, 1121))
	unequal.enqueue(_entry(4, 1122))
	unequal.enqueue(_entry(5, 1123))
	_check(unequal.tick(100.0) == [[1, 3, 4, 5]], "an incompatible narrow-window player does not block a match")

	var forward := Queue.new(4, 8, 5516)
	var backward := Queue.new(4, 8, 5516)
	var another_seed := Queue.new(4, 8, 5517)
	for index in 25:
		forward.enqueue(_entry(index + 1, 1000))
		backward.enqueue(_entry(25 - index, 1000))
		another_seed.enqueue(_entry(index + 1, 1000))
	var tied := forward.tick(0)
	_check(tied == backward.tick(0), "seed order is independent of dictionary insertion order")
	_check(tied != another_seed.tick(0), "different seeds can resolve ties differently")
	_check(tied.size() == 3 and forward.queue_size() == 1, "ties fill matches up to max, leaving fewer than min")
	_check(forward.tick(1).is_empty(), "matched accounts are dequeued")

	for scenario in ["equal", "clustered", "sparse"]:
		var large := Queue.new()
		for index in 5000:
			var rating := 1000
			if scenario == "clustered":
				rating += (index * 37) % 101
			elif scenario == "sparse":
				rating = index * 701
			large.enqueue(_entry(index + 1, rating))
		var begin := Time.get_ticks_usec()
		var matches := large.tick(100)
		var elapsed := (Time.get_ticks_usec() - begin) / 1000.0
		_check(elapsed < 50.0, "5000 queued entries matched in under 50 ms")
		var seen := {}
		for match_ids: Array in matches:
			_check(match_ids.size() >= 4 and match_ids.size() <= 8, "match size bounds")
			for id: int in match_ids:
				_check(not seen.has(id), "no account appears in more than one match")
				seen[id] = true
		_check(seen.size() == (0 if scenario == "sparse" else 5000), "expected large-queue match count")
		print("5000 entries (%s): %.2f ms, %d matches" % [scenario, elapsed, matches.size()])

	print("MATCHMAKER_TEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
