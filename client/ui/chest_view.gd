# The cosmetic crate's 3D chest (port of src/client/UI/ChestView.luau + shared/Assets/CrateModel): a
# blocky wooden chest in a transparent SubViewport, seen from the same camera (fov 28, yaw 24 deg).
# The chest is the studio's own voxel chest: two meshes and a texture fetched from Roblox (assets
# 8562367045 lid, 8562367050 body, 8562367073 texture) and converted to assets/rw/crate/chest_*.obj/png.
# idle(t, every) is the small views' life: a bob, and every `every` seconds a wiggle with the lid cracking.
class_name ChestView
extends SubViewportContainer

const CAM_FOV := 28.0
const CAM_POS := Vector3(0, 6.2, -18)
const CAM_AT := Vector3(0, 2.3, 0)
const BASE_YAW := 24.0

var _vp: SubViewport
var _rig: Node3D
var _lid: Node3D
var _t := 0.0
var _every := 2.4
var running := true
static var _tex_cache := {}


static func _planks(horizontal: bool, base: Color, n: int) -> ImageTexture:
	var key := "%s%d%s" % [horizontal, n, base.to_html()]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var s := 32
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7 + n
	var per := s / n
	for i in n:
		var tone := base.darkened(rng.randf_range(0.0, 0.22)) if i % 2 == 0 else base.lightened(rng.randf_range(0.0, 0.1))
		for a in per:
			for b in s:
				var c := tone
				if a == 0:
					c = tone.darkened(0.45)  # the seam
				elif rng.randf() < 0.07:
					c = tone.darkened(0.12)  # grain
				var x := b if horizontal else i * per + a
				var y := i * per + a if horizontal else b
				img.set_pixel(x, y, c)
	var t := ImageTexture.create_from_image(img)
	_tex_cache[key] = t
	return t


static func _mat(tex: Texture2D = null, col := Color.WHITE, rough := 0.9, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _init() -> void:
	name = "ChestView"
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	_vp.add_child(cam)
	cam.look_at_from_position(CAM_POS, CAM_AT, Vector3.UP)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color8(150, 146, 150)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 200, 0)
	sun.light_energy = 0.9
	_vp.add_child(sun)
	_rig = Node3D.new()
	_rig.rotation_degrees.y = BASE_YAW
	_vp.add_child(_rig)
	_build()


## The real parts (the studio's BedWars voxel chest, shared/Assets/CrateModel.luau): two meshes, one
## texture, each part scaled 1.7012 about its centre; the lid hinges at the back top of the body.
func _build() -> void:
	var tex: Texture2D = load("res://assets/rw/crate/chest_tex.png")
	var m := _mat(tex, Color.WHITE, 0.85)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var bottom := MeshInstance3D.new()
	bottom.mesh = load("res://assets/rw/crate/chest_bottom.obj")
	bottom.material_override = m
	bottom.scale = Vector3.ONE * 1.7012
	bottom.position = Vector3(0, 1.1667, 0)
	_rig.add_child(bottom)
	# the lid: its pivot is the hinge, the part sits where it would at rest (relative to it)
	_lid = Node3D.new()
	_lid.position = Vector3(0, 1.6667, 2.5)
	_rig.add_child(_lid)
	var lid := MeshInstance3D.new()
	lid.mesh = load("res://assets/rw/crate/chest_lid.obj")
	lid.material_override = m
	lid.scale = Vector3.ONE * 1.7012
	lid.position = Vector3(0, 3.1666 - 1.6667, -2.5)
	_lid.add_child(lid)


## Bob and a wiggle every `every` s with the lid cracking (the small views' life).
func tick(dt: float) -> void:
	_t += dt
	_rig.position.y = sin(_t * 2.0) * 0.12
	var w := fmod(_t, _every)
	var dur := 0.7
	if w < dur:
		var k := 1.0 - w / dur
		_rig.rotation_degrees.z = sin(w * 32.0) * 5.0 * k
		_lid.rotation_degrees.x = sin(w / dur * PI) * 14.0
	else:
		_rig.rotation_degrees.z = 0.0
		_lid.rotation_degrees.x = 0.0


## The opening show's pose: shake 0..1 (the rattle before it opens), lid 0..1 (0 closed, 1 wide open).
func pose(shake: float, lid: float, t: float) -> void:
	_rig.position.y = 0.0
	_rig.rotation_degrees.z = sin(t * 55.0) * 7.0 * shake
	_rig.rotation_degrees.x = sin(t * 43.0 + 1.0) * 3.0 * shake
	_rig.scale = Vector3.ONE * (1.0 + 0.04 * shake)
	_lid.rotation_degrees.x = lid * 118.0


func _process(dt: float) -> void:
	if running and is_visible_in_tree():
		tick(dt)
