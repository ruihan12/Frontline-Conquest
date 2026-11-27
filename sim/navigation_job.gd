extends RefCounted
## Builds detached map navigation. Ownership of the result returns to the
## caller only after joining the thread.

const Nav = preload("res://sim/nav.gd")

var _owners: PackedInt32Array
var _width: int
var _height: int
var _water: int

func _init(owners: PackedInt32Array, width: int, height: int, water: int) -> void:
	_owners = owners
	_width = width
	_height = height
	_water = water

func build() -> Array:
	var census := SimNaval.scan_water(_owners, _width, _water)
	var navigation := Nav.new()
	navigation.build(census[0], _width, _height)
	return [census[0], census[1], navigation, census[2], census[3]]
