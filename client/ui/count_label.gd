# Port of src/client/UI/CountLabel.luau (scripts/ui/count_label.gd, UICount).
# Label that animates between numeric values (troops, gold, percentages). Tabular digits keep the
# rolling number from jittering.
class_name CountLabel
extends Label

var formatter: Callable = Callable()  # (value: float) -> String
var rolling := true
var duration := 0.45
var value := 0.0
var _shown := 0.0
var _tween: Tween = null
var _init_done := false


func _init(font_size: int = 18, weight: int = 700, color: Color = UITheme.TEXT, fmt: Callable = Callable()) -> void:
	formatter = fmt
	UITheme.style_label(self, font_size, weight, color)
	add_theme_font_override("font", UITheme.font(weight, 0, true))
	_refresh()


func set_value(v: float, animate: bool = true) -> void:
	if _init_done and absf(v - value) < 1e-9:
		return
	value = v
	if not animate or not _init_done or not is_inside_tree():
		_init_done = true
		_shown = v
		_refresh()
		return
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_shown, _shown, v, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _set_shown(v: float) -> void:
	_shown = v
	_refresh()


func _refresh() -> void:
	var t: String
	if formatter.is_valid():
		t = formatter.call(_shown)
	else:
		var r := _shown
		t = UITheme.big(floorf(r + 0.5) if r >= 0 else -floorf(-r + 0.5))
	text = t
