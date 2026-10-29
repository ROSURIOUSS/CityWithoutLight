extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	# Run after the root window is in the tree so Main._ready() is exercised.
	call_deferred("_run_tests")


func _run_tests() -> void:
	_check_version()
	_check_project_settings()
	_check_input_map()
	_check_main_scene()

	if _failures.is_empty():
		print("BASE-01: all headless checks passed.")
		quit(0)
		return

	for failure in _failures:
		push_error(failure)
	quit(1)


func _check_version() -> void:
	var version := Engine.get_version_info()
	_expect(
		version.get("major") == 4 and version.get("minor") == 4 and version.get("patch") == 1,
		"The agreed engine version is Godot 4.4.1."
	)


func _check_project_settings() -> void:
	var expected_settings := {
		"application/run/main_scene": "res://scenes/main/main.tscn",
		"display/window/size/viewport_width": 640,
		"display/window/size/viewport_height": 360,
		"display/window/stretch/mode": "viewport",
		"display/window/stretch/aspect": "keep",
		"display/window/stretch/scale_mode": "integer",
		"rendering/renderer/rendering_method": "gl_compatibility",
		"rendering/textures/canvas_textures/default_texture_filter": 0,
	}
	for setting in expected_settings:
		_expect(
			ProjectSettings.get_setting(setting) == expected_settings[setting],
			"Unexpected project setting: %s." % setting
		)

	var features: PackedStringArray = ProjectSettings.get_setting("application/config/features")
	_expect(features.has("4.4"), "Godot 4.4 project feature is missing.")
	_expect(features.has("GL Compatibility"), "Compatibility project feature is missing.")


func _check_input_map() -> void:
	_check_key(&"move_up", KEY_W, true)
	_check_key(&"move_up", KEY_UP, false)
	_check_key(&"move_down", KEY_S, true)
	_check_key(&"move_down", KEY_DOWN, false)
	_check_key(&"move_left", KEY_A, true)
	_check_key(&"move_left", KEY_LEFT, false)
	_check_key(&"move_right", KEY_D, true)
	_check_key(&"move_right", KEY_RIGHT, false)
	_check_key(&"interact", KEY_E, true)
	_check_key(&"save_game", KEY_F2, false)
	_check_key(&"load_game", KEY_F3, false)

	for action in [&"ui_accept", &"ui_cancel", &"ui_up", &"ui_down", &"ui_left", &"ui_right"]:
		_expect(InputMap.has_action(action), "Built-in UI action missing: %s." % action)

	var wrong_key := InputEventKey.new()
	wrong_key.physical_keycode = KEY_A
	wrong_key.pressed = true
	_expect(not wrong_key.is_action_pressed(&"move_right"), "A must not trigger move_right.")


func _check_key(action: StringName, key_code: int, physical: bool) -> void:
	if not InputMap.has_action(action):
		_failures.append("Input action missing: %s." % action)
		return

	var event := InputEventKey.new()
	event.device = 0
	if physical:
		# A different logical key simulates a non-US keyboard layout.
		event.keycode = KEY_Q
		event.physical_keycode = key_code
	else:
		event.keycode = key_code
		event.physical_keycode = key_code

	event.pressed = true
	_expect(event.is_action_pressed(action), "Press is not mapped: %s / %s." % [action, key_code])
	event.pressed = false
	_expect(event.is_action_released(action), "Release is not mapped: %s / %s." % [action, key_code])


func _check_main_scene() -> void:
	var scene := load("res://scenes/main/main.tscn") as PackedScene
	if scene == null:
		_failures.append("Main scene could not be loaded.")
		return

	var main := scene.instantiate()
	root.add_child(main)
	_expect(main.name == "Main", "The root scene node must be named Main.")
	_expect(root.min_size == Vector2i(640, 360), "Main must set the minimum window size.")
	_expect(main.get_node_or_null("WorldHost") is Node2D, "WorldHost must be a Node2D.")
	_expect(main.get_node_or_null("Overlay") is CanvasLayer, "Overlay must be a CanvasLayer.")

	for path in [
		"Overlay/UIRoot",
		"Overlay/UIRoot/BattleHost",
		"Overlay/UIRoot/DialogueHost",
		"Overlay/UIRoot/EndingHost",
		"Overlay/UIRoot/Status",
	]:
		var control := main.get_node_or_null(path) as Control
		_expect(control != null, "Missing UI control: %s." % path)
		if control != null:
			_expect(
				control.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"UI host must not block mouse input: %s." % path
			)
	_expect(main.get_node_or_null("Overlay/UIRoot/Status") is Label, "Status must be a Label.")
	main.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
