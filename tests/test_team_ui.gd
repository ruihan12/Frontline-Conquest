extends SceneTree

class GameStub:
	const W := 10
	const H := 10
	const PLAYER := 1
	var state := "play"
	var name := ""
	var team_mode := true
	var team_names := ["Red", "Blue"]
	var land_total := 110
	var fallout_count := 10
	var sim_atk = null
	var nations := [{},
		{"team": 1, "land": 12, "alive": true},
		{"team": 1, "land": 13, "alive": true},
		{"team": 2, "land": 45, "alive": true},
		{"team": 2, "land": 10, "alive": false},
	]

func _initialize() -> void:
	var game := GameStub.new()
	var state := RWGameState.new(game)
	var ctx := UICtx.new()
	ctx.state = state
	var top := TopStatus.new(ctx)
	var board := Leaderboard.new(ctx)
	var ok := true
	top._refresh_teams(1)
	ok = ok and top._you.text == "Red team 25.0%" and top._lead.text == "Blue team 45.0%"
	board._refresh_teams()
	ok = ok and board._team_box.get_child(0).get_child(1).text == "Blue team"
	ok = ok and board._team_box.get_child(0).get_child(3).text == "45.0%"
	ctx.compact = true
	top._refresh_teams(1)
	ok = ok and top._you.text == "#2 · 25.0%"
	game.team_mode = false
	board._refresh_teams()
	ok = ok and not board._team_box.visible and not state.same_team(1, 2)
	top.free()
	board.free()
	ctx.rules = null
	print("TEAM_UI_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
