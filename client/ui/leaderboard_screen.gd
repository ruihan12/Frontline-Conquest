extends VBoxContainer

const API := preload("res://net/api.gd")
const LIMIT := 50

var api: API
var _generation := 0
var _rows: VBoxContainer
var _notice: Label


func _init(account_api: API) -> void:
	api = account_api
	name = "RankedLeaderboard"
	add_theme_constant_override("separation", 8)
	_notice = UITheme.label("", 14, 500, UITheme.TEXT_2)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_notice)
	_rows = UITheme.vbox(4)
	add_child(_rows)
	hide()


func open() -> void:
	show()
	_generation += 1
	var generation := _generation
	for row in _rows.get_children():
		_rows.remove_child(row)
		row.queue_free()
	_notice.text = "Loading rankings…"
	var result: Dictionary = await api.leaderboard(LIMIT)
	if generation != _generation:
		return
	if not result.ok:
		_notice.text = result.message
		return
	var players = result.data.get("players")
	if not players is Array:
		_notice.text = "The server returned invalid rankings."
		return
	_notice.text = "No rankings yet." if players.is_empty() else ""
	_notice.visible = players.is_empty()
	if not players.is_empty():
		_row("#", "Player", "Elo", "Matches", UITheme.TEXT_3)
	var rank := 0
	for player in players:
		if not player is Dictionary:
			continue
		rank += 1
		_row(str(rank), str(player.get("username", "")), str(player.get("elo", 0)), str(player.get("matches", 0)), UITheme.TEXT)


func close() -> void:
	_generation += 1
	_notice.show()
	hide()


func _row(rank: String, username: String, elo: String, matches: String, color: Color) -> void:
	var row := UITheme.hbox(8)
	_rows.add_child(row)
	var place := UITheme.label(rank, 13, 700, color)
	place.custom_minimum_size.x = 24
	row.add_child(place)
	var player := UITheme.label(username, 13, 600, color)
	player.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(player)
	for value in [elo, matches]:
		var field := UITheme.label(value, 13, 600, color)
		field.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		field.custom_minimum_size.x = 62
		row.add_child(field)
