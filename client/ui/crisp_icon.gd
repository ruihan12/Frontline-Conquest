# A UI glyph drawn pixel for pixel. The icon art is 128 px; drawn at 11-30 px through the GPU's
# mipmaps (box-filtered, then bilinear at a fractional offset) the small glyphs came out soft and
# muddy. Here the glyph is resampled once (Lanczos) to the exact number of device pixels it covers
# and drawn 1:1 with nearest filtering, so it stays sharp at any UI scale. Same node type and
# properties as UITheme.icon_rect's TextureRect: code that sets `texture` later still works (the new
# texture is picked up and resampled the same way).
class_name CrispIcon
extends TextureRect

## the size asked for, logical px (UITheme.icon_rect's px)
var base_px := 0.0
var _src: Texture2D
var _made: Texture2D
var _n := -1
var _scale := -1.0
var _queued := false
var _set_min := Vector2.ZERO
static var _cache := {}


func setup(src: Texture2D, px: float) -> void:
	base_px = px
	_src = src
	texture = src
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	custom_minimum_size = Vector2(px, px)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_TREE, NOTIFICATION_RESIZED, NOTIFICATION_VISIBILITY_CHANGED:
			_queue()
		NOTIFICATION_DRAW:
			# someone swapped in another glyph (texture = ...): resample that one
			if texture != null and texture != _made and texture != _src:
				_src = texture
				_n = -1
			if texture != _made or _scale != _device_scale():
				_queue()


func _queue() -> void:
	if _queued or not is_inside_tree():
		return
	_queued = true
	_refit.call_deferred()


## Device px per logical px for this control (the window's stretch, the canvas layer's scale).
func _device_scale() -> float:
	var vp := get_viewport()
	if vp == null:
		return 1.0
	return maxf(0.01, vp.get_final_transform().get_scale().x * get_canvas_transform().get_scale().x)


func _refit() -> void:
	_queued = false
	if not is_inside_tree() or _src == null or base_px <= 0.0:
		return
	if _set_min != Vector2.ZERO and not custom_minimum_size.is_equal_approx(_set_min):
		base_px = maxf(custom_minimum_size.x, custom_minimum_size.y)  # resized by its owner
	var s := _device_scale()
	var n := maxi(1, roundi(base_px * s))
	if n == _n and is_equal_approx(s, _scale) and texture == _made and _made != null:
		return
	var t := _resampled(_src, n)
	if t == null:
		return
	_n = n
	_scale = s
	_made = t
	texture = t
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# the box covers exactly n device px, so every texel lands on one pixel
	custom_minimum_size = Vector2(n, n) / s
	_set_min = custom_minimum_size


static func _resampled(src: Texture2D, n: int) -> Texture2D:
	var key := "%d:%d" % [src.get_rid().get_id(), n]
	if _cache.has(key):
		return _cache[key]
	var img := src.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.has_mipmaps():
		img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var k := float(n) / float(maxi(w, h))
	var tw := maxi(1, roundi(w * k))
	var th := maxi(1, roundi(h * k))
	# (the import's fix_alpha_border gives the clear pixels their neighbours' colour: no fringe)
	img.resize(tw, th, Image.INTERPOLATE_LANCZOS)
	var t := ImageTexture.create_from_image(img)
	_cache[key] = t
	return t

