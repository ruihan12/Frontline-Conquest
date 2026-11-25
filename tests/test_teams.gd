extends SceneTree
const T = preload("res://net/teams.gd")
var fails := 0
func _ok(c: bool, m: String) -> void:
	if not c:
		fails += 1
		print("FAIL ", m)
func _init() -> void:
	_ok(T.resolve("Duos", 5).size() == 3 and T.resolve("Duos", 5)[0] == "Red", "5 players in Duos -> 3 teams")
	_ok(T.resolve("Quads", 3).size() == 2, "at least 2 teams")
	_ok(T.resolve(9, 9)[8] == "Team 9", "numbered teams")
	# packing: 5 players, Duos (3 teams, cap 2): teams fill one by one 2,2,1
	var ps := []
	for i in 5: ps.append({"id": i + 1})
	var a := T.assign(ps, 3, true)
	var cnt := [0, 0, 0]
	for id in a: cnt[a[id] - 1] += 1
	_ok(cnt == [2, 2, 1], "packing duos 2/2/1: %s" % str(cnt))
	# even fill for a plain number of teams: 6 players in 2 teams -> 3/3
	var ps6 := []
	for i in 6: ps6.append({"id": i + 1})
	var b := T.assign(ps6, 2, false)
	var c2 := [0, 0]
	for id in b: c2[b[id] - 1] += 1
	_ok(c2 == [3, 3], "even 3/3: %s" % str(c2))
	# a party of 2 stays together
	var pp := [{"id": 1, "group": "p"}, {"id": 2}, {"id": 3}, {"id": 4, "group": "p"}]
	var d := T.assign(pp, 2, false)
	_ok(d[1] == d[4], "party on one team")
	# colours: base is the team colour, shades differ and stay valid
	_ok(T.color("Red", 1, 0) == Color("#eb3333"), "shade 0 is the base")
	var s1 := T.color("Red", 1, 1)
	_ok(s1 != Color("#eb3333") and s1.r >= 0.0 and s1.r <= 1.0, "shade 1 differs")
	print("TEAMS_TEST ", "PASS" if fails == 0 else "FAIL", " fails=", fails)
	quit(fails)
