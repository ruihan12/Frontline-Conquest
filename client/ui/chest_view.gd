# The cosmetic crate's 3D chest (port of src/client/UI/ChestView.luau + shared/Assets/CrateModel): a
# blocky wooden chest in a transparent SubViewport, seen from the same camera (fov 28, yaw 24 deg).
# Upstream's meshes are Roblox uploads this port does not have, so the parts are boxes with generated
# pixel-art planks: planked body, a red-brown rim, a tall lid with vertical planks, dark straps at the
# corners and a grey latch. idle(t, every) is the small views' life: a bob, and every `every` seconds a
# wiggle with the lid cracking.
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


func _build() -> void:
	var wood := Color8(160, 108, 70)
	var body_m := _mat(_planks(true, wood, 4))
	var lid_m := _mat(_planks(false, wood.lightened(0.06), 5))
	var rim_m := _mat(null, Color8(138, 70, 56))
	var strap_m := _mat(null, Color8(70, 44, 32))
	var latch_m := _mat(null, Color8(112, 134, 150), 0.5, 0.3)
	# body (bottom 2.33) and rim ledge
	_box(_rig, Vector3(4.67, 2.33, 4.67), Vector3(0, 1.17, 0), body_m)
	_box(_rig, Vector3(5.0, 0.3, 5.0), Vector3(0, 2.4, 0), rim_m)
	# corner straps on the body (front corners and back)
	for sx in [-1, 1]:
		_box(_rig, Vector3(0.55, 2.4, 4.9), Vector3(sx * 2.0, 1.2, 0), strap_m)
	# the lid (hinged at the back top of the body)
	_lid = Node3D.new()
	_lid.position = Vector3(0, 2.55, 2.5)
	_rig.add_child(_lid)
	_box(_lid, Vector3(4.8, 2.4, 5.0), Vector3(0, 1.2, -2.5), lid_m)
	for sx in [-1, 1]:
		_box(_lid, Vector3(0.45, 2.45, 5.1), Vector3(sx * 1.9, 1.2, -2.5), strap_m)
	# the latch on the front seam
	_box(_rig, Vector3(0.9, 1.1, 0.35), Vector3(0, 2.5, -2.6), latch_m)
	_box(_rig, Vector3(0.35, 0.35, 0.2), Vector3(0, 2.25, -2.82), _mat(null, Color8(40, 48, 58)))


## Bob and a wiggle every `every` s with the lid cracking (the small views' life).
func tick(dt: float) -> void:
	_t += dt
	_rig.position.y = sin(_t * 2.0) * 0.12
	var w := fmod(_t, _every)
	var dur := 0.7
	if w < dur:
		var k := 1.0 - w / dur
		_rig.rotation_degrees.z = sin(w * 32.0) * 5.0 * k
		_lid.rotation_degrees.x = -sin(w / dur * PI) * 14.0
	else:
		_rig.rotation_degrees.z = 0.0
		_lid.rotation_degrees.x = 0.0


func _process(dt: float) -> void:
	if running and is_visible_in_tree():
		tick(dt)
