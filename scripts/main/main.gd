extends Node

# Integer viewport scaling would clip the game in a smaller desktop window.
const MIN_WINDOW_SIZE := Vector2i(640, 360)


func _ready() -> void:
	get_window().min_size = MIN_WINDOW_SIZE
