extends Node

## CORE-01 standalone tests: shared state and the one-slot save service.
## The scripts are instantiated directly, so no autoload registration is required
## before INT-CORE-01. Run: godot --headless --path . res://tests/core/core_test.tscn

const GameStateScript = preload("res://scripts/core/game_state.gd")
const SaveServiceScript = preload("res://scripts/core/save_service.gd")

const TEST_PATH := "user://save_test_v1.json"
const TEST_TEMP_PATH := "user://save_test_v1.json.tmp"
const TEST_BACKUP_PATH := "user://save_test_v1.json.bak"

var _failures: Array[String] = []
var _checks := 0
var _signal_count := 0
var _game_state
var _save_service


func _ready() -> void:
	# Deferred so the tree, the scene and both test nodes are fully ready first.
	call_deferred("_run_tests")


func _run_tests() -> void:
	_cleanup_test_files()

	_game_state = GameStateScript.new()
	_game_state.name = "GameStateTest"
	add_child(_game_state)
	_game_state.state_changed.connect(_on_state_changed)

	_save_service = SaveServiceScript.new()
	_save_service.name = "SaveServiceTest"
	add_child(_save_service)

	_test_new_state()
	_test_flags()
	_test_relations()
	_test_party()
	_test_export_import()
	_test_module_storage()
	_test_save_and_load()
	_test_missing_file()
	_test_corrupted_file()
	_test_incompatible_version()
	_test_invalid_snapshot_rejected()
	_test_previous_slot_is_kept()

	_cleanup_test_files()

	if _failures.is_empty():
		print("CORE-01: %d checks passed." % _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error(failure)
	print("CORE-01: %d of %d checks failed." % [_failures.size(), _checks])
	get_tree().quit(1)


func _test_new_state() -> void:
	_game_state.reset_new_game()
	_expect_same(_game_state.get_party(), ["hero"], "A new state must start with the party [hero].")
	_expect(_game_state.get_flag("story.mira.helped") == false, "An unknown flag must be false.")
	_expect_eq(_game_state.get_relation("npc.mira"), 0, "An unknown relation must be 0.")
	_expect_same(
		_game_state.export_state(),
		{"flags": {}, "relations": {}, "party": ["hero"]},
		"A new state must export empty flags and relations."
	)
	_signal_count = 0
	_game_state.reset_new_game()
	_expect_eq(_signal_count, 1, "reset_new_game must emit state_changed once.")


func _test_flags() -> void:
	_game_state.reset_new_game()
	_signal_count = 0
	_game_state.set_flag("story.mira.helped", true)
	_expect(_game_state.get_flag("story.mira.helped"), "A set flag must be readable.")
	_expect_eq(_signal_count, 1, "Setting a new flag must emit one signal.")
	_game_state.set_flag("story.mira.helped", true)
	_expect_eq(_signal_count, 1, "Setting the same value must not emit a signal.")
	_game_state.set_flag("", true)
	_expect_eq(_signal_count, 1, "An empty flag id must be ignored without a signal.")
	_expect(_game_state.get_flag("") == false, "An empty flag id must read as false.")
	_game_state.set_flag("story.mira.helped", false)
	_expect(_game_state.get_flag("story.mira.helped") == false, "A cleared flag must read as false.")
	_expect_eq(_signal_count, 2, "Clearing a set flag must emit one signal.")


func _test_relations() -> void:
	_game_state.reset_new_game()
	_signal_count = 0
	var first := _game_state.change_relation("npc.mira", 1)
	_expect_eq(first, 1, "change_relation must return the new total.")
	_expect_eq(_signal_count, 1, "A relation change must emit one signal.")
	_expect_eq(_game_state.change_relation("npc.mira", 0), 1, "A zero change must keep the value.")
	_expect_eq(_signal_count, 1, "A zero change must not emit a signal.")
	_expect_eq(_game_state.change_relation("npc.mira", 1000), 100, "A relation must clamp to 100.")
	_expect_eq(_signal_count, 2, "Clamping to a new value must emit one signal.")
	_expect_eq(_game_state.change_relation("npc.mira", 5), 100, "A clamped relation must stay 100.")
	_expect_eq(_signal_count, 2, "An already clamped relation must not emit a signal.")
	_expect_eq(_game_state.change_relation("npc.mira", -1000), -100, "A relation must clamp to -100.")
	_expect_eq(_signal_count, 3, "Clamping down must emit one signal.")
	_expect_eq(_game_state.change_relation("", 5), 0, "An empty relation id must return 0.")
	_expect_eq(_signal_count, 3, "An empty relation id must not emit a signal.")
	_expect_eq(_game_state.get_relation(""), 0, "An empty relation id must read as 0.")


func _test_party() -> void:
	_game_state.reset_new_game()
	_signal_count = 0
	_expect(_game_state.add_party_member("companion.mira"), "A new member must be added.")
	_expect_eq(_signal_count, 1, "Adding a member must emit one signal.")
	_expect(_game_state.add_party_member("companion.mira") == false, "A duplicate must be refused.")
	_expect(_game_state.add_party_member("hero") == false, "The hero is already in the party.")
	_expect(_game_state.add_party_member("") == false, "An empty member id must be refused.")
	_expect_eq(_signal_count, 1, "Refused members must not emit a signal.")
	_expect_same(
		_game_state.get_party(),
		["hero", "companion.mira"],
		"The party must keep the agreed order."
	)

	var copy: Array = _game_state.get_party()
	copy.append("companion.other")
	_expect_eq(_game_state.get_party().size(), 2, "get_party must return an independent copy.")


func _test_export_import() -> void:
	_game_state.reset_new_game()
	_game_state.set_flag("story.mira.helped", true)
	_game_state.change_relation("npc.mira", 1)
	_game_state.add_party_member("companion.mira")

	var exported: Dictionary = _game_state.export_state()
	exported["flags"]["story.mira.helped"] = false
	exported["relations"]["npc.mira"] = -100
	exported["party"].append("companion.other")
	_expect(_game_state.get_flag("story.mira.helped"), "The export copy must not change flags.")
	_expect_eq(_game_state.get_relation("npc.mira"), 1, "The copy must not change relations.")
	_expect_eq(_game_state.get_party().size(), 2, "Changing an export copy must not change the party.")

	var imported := {
		"flags": {"story.mira.refused": true},
		"relations": {"npc.mira": 2.0},
		"party": ["hero"],
	}
	_signal_count = 0
	_expect(_game_state.import_state(imported), "A valid payload with JSON floats must import.")
	_expect_eq(_signal_count, 1, "A successful import must emit exactly one signal.")
	_expect(_game_state.get_flag("story.mira.refused"), "An imported flag must be readable.")
	_expect(_game_state.get_flag("story.mira.helped") == false, "An import must replace old flags.")
	_expect_eq(_game_state.get_relation("npc.mira"), 2, "An imported float relation must become int.")

	var before: Dictionary = _game_state.export_state()
	for invalid_payload in [
		{},
		{"flags": {}, "relations": {}},
		{"flags": {"a": true}, "relations": {}, "party": []},
		{"flags": {"a": true}, "relations": {}, "party": ["companion.mira"]},
		{"flags": {"a": true}, "relations": {}, "party": ["hero", "hero"]},
		{"flags": {"a": 1}, "relations": {}, "party": ["hero"]},
		{"flags": {}, "relations": {"npc.mira": 500}, "party": ["hero"]},
		{"flags": {}, "relations": {"npc.mira": 1.5}, "party": ["hero"]},
		{"flags": {"": true}, "relations": {}, "party": ["hero"]},
		{"flags": {}, "relations": {}, "party": ["hero"], "modules": {"unknown": {}}},
	]:
		_expect(_game_state.import_state(invalid_payload) == false, "Invalid payload must be refused.")
	_expect_eq(_signal_count, 1, "A refused import must not emit a signal.")
	_expect_same(_game_state.export_state(), before, "A refused import must not change the state.")


func _test_module_storage() -> void:
	_game_state.reset_new_game()
	var quests := {
		"quest.mira": {"state": "active", "steps_done": [1, 2.5, true]},
		"quest.empty": {},
	}
	_signal_count = 0
	_expect(_game_state.set_module_data("quests", quests), "JSON-safe module data must be accepted.")
	_expect_eq(_signal_count, 1, "Storing module data must emit one signal.")
	_expect_same(_game_state.get_module_data("quests"), quests, "Module data must round-trip.")
	var unknown_ok: bool = _game_state.set_module_data("dialogues", {})
	_expect(unknown_ok == false, "An unknown namespace must be refused.")

	var node := Node.new()
	var with_node := {"node": node}
	var with_vector := {"position": Vector2(1.0, 2.0)}
	var node_ok: bool = _game_state.set_module_data("inventory", with_node)
	_expect(node_ok == false, "A Node value must be refused.")
	var vector_ok: bool = _game_state.set_module_data("characters", with_vector)
	_expect(vector_ok == false, "A Vector2 value must be refused.")
	node.free()

	var exported: Dictionary = _game_state.export_state()
	_expect(exported.has("modules"), "Used module storage must appear in the export.")

	_game_state.reset_new_game()
	_expect(_game_state.has_module_data("quests") == false, "reset_new_game must clear module data.")
	_expect(_game_state.import_state(exported), "An export with modules must import again.")
	_expect_same(_game_state.get_module_data("quests"), quests, "Imported modules must round-trip.")


func _test_save_and_load() -> void:
	var snapshot := _make_snapshot()
	_remove_file(TEST_PATH)
	var code: int = _save_service.save_game(snapshot, TEST_PATH)
	_expect_eq(code, OK, "Saving a valid snapshot must return OK.")
	_expect(FileAccess.file_exists(TEST_PATH), "The save file must exist after saving.")
	_expect(FileAccess.file_exists(TEST_TEMP_PATH) == false, "The temporary file must be removed.")

	var loaded: Dictionary = _save_service.load_game(TEST_PATH)
	_expect(loaded["ok"] == true, "Loading a valid file must succeed: %s" % loaded["error"])
	_expect_eq(String(loaded["error"]), "", "A successful load must not report an error.")
	_expect_same(loaded["data"], snapshot, "The loaded snapshot must match the saved one.")

	var stored: Variant = JSON.parse_string(_read_text(TEST_PATH))
	_expect(typeof(stored) == TYPE_DICTIONARY, "The slot must contain a JSON object.")
	if typeof(stored) == TYPE_DICTIONARY:
		_expect_eq(int(stored["version"]), 1, "The written file must carry version 1.")

	_game_state.reset_new_game()
	_expect(_game_state.import_state(loaded["data"]["game_state"]), "The loaded state must import.")
	_expect(_game_state.get_flag("story.mira.helped"), "The loaded state must contain the saved flag.")


func _test_missing_file() -> void:
	_cleanup_test_files()
	_game_state.reset_new_game()
	_game_state.set_flag("story.mira.helped", true)

	var loaded: Dictionary = _save_service.load_game(TEST_PATH)
	_expect(loaded["ok"] == false, "A missing file must be reported as an error.")
	_expect(loaded["data"].is_empty(), "A failed load must return empty data.")
	_expect(String(loaded["error"]).is_empty() == false, "A failed load must explain the problem.")
	_expect(_game_state.get_flag("story.mira.helped"), "A failed load must not change the game state.")


func _test_corrupted_file() -> void:
	var corrupted := "{ \"version\": 1, \"world\": "
	_write_text(TEST_PATH, corrupted)
	_expect_load_fails("Damaged JSON must be reported as an error.")
	_expect_eq(_read_text(TEST_PATH), corrupted, "A damaged file must not be rewritten.")

	var wrong_structure := {
		"version": 1,
		"world": {"id": "world.demo"},
		"game_state": {"flags": {}, "relations": {}, "party": ["hero"]},
	}
	_write_text(TEST_PATH, JSON.stringify(wrong_structure))
	_expect_load_fails("A missing player_position must be reported as an error.")

	var wrong_types := _make_snapshot()
	wrong_types["game_state"]["relations"]["npc.mira"] = 500
	_write_text(TEST_PATH, JSON.stringify(wrong_types))
	_expect_load_fails("An out-of-range relation must be reported as an error.")

	var object_value := _make_snapshot()
	object_value["world"]["spawn"] = "ok"
	object_value["game_state"]["flags"]["story.mira.helped"] = "yes"
	_write_text(TEST_PATH, JSON.stringify(object_value))
	_expect_load_fails("A non-boolean flag value must be reported as an error.")
	_cleanup_test_files()


func _test_incompatible_version() -> void:
	var newer := _make_snapshot()
	newer["version"] = 2
	_write_text(TEST_PATH, JSON.stringify(newer))
	_expect_load_fails("An unsupported version must be refused.")
	var loaded: Dictionary = _save_service.load_game(TEST_PATH)
	_expect(
		String(loaded["error"]).contains("2"),
		"The error message must name the unsupported version: %s" % loaded["error"]
	)

	var text_before := _read_text(TEST_PATH)
	_expect(
		_save_service.save_game(newer, TEST_PATH) != OK,
		"Saving an unsupported version must be refused."
	)
	_expect_eq(_read_text(TEST_PATH), text_before, "A refused save must not rewrite the slot.")
	_cleanup_test_files()


func _test_invalid_snapshot_rejected() -> void:
	var valid := _make_snapshot()
	_expect_eq(_save_service.save_game(valid, TEST_PATH), OK, "The reference snapshot must save.")
	var text_before := _read_text(TEST_PATH)

	var empty_game_state := _make_snapshot()
	empty_game_state["game_state"] = {}
	var spatial_value := _make_snapshot()
	spatial_value["extra"] = Vector2(4.0, 5.0)
	var infinite_position := _make_snapshot()
	infinite_position["world"]["player_position"]["x"] = INF

	for invalid_snapshot in [{}, empty_game_state, spatial_value, infinite_position]:
		_expect_eq(
			_save_service.save_game(invalid_snapshot, TEST_PATH),
			ERR_INVALID_DATA,
			"An invalid snapshot must be refused with ERR_INVALID_DATA."
		)
	_expect_eq(_read_text(TEST_PATH), text_before, "A refused save must keep the previous slot.")
	_expect_eq(
		_save_service.save_game(valid, "res://save_core_test.json"),
		ERR_UNAUTHORIZED,
		"Writing outside user:// must be refused."
	)
	_expect(
		FileAccess.file_exists("res://save_core_test.json") == false,
		"A refused save must not create a project file."
	)
	_cleanup_test_files()


func _test_previous_slot_is_kept() -> void:
	var first := _make_snapshot(80.0)
	_expect_eq(_save_service.save_game(first, TEST_PATH), OK, "The first save must succeed.")
	_expect(FileAccess.file_exists(TEST_BACKUP_PATH) == false, "The first save has no backup.")
	var second := _make_snapshot(96.0)
	_expect_eq(_save_service.save_game(second, TEST_PATH), OK, "The second save must succeed.")
	_expect(FileAccess.file_exists(TEST_BACKUP_PATH), "The previous slot must be kept as a backup.")

	var backup: Dictionary = _save_service.load_game(TEST_BACKUP_PATH)
	_expect(backup["ok"] == true, "The backup must stay loadable: %s" % backup["error"])
	_expect_same(backup["data"], first, "The backup must hold the previous snapshot.")

	var current: Dictionary = _save_service.load_game(TEST_PATH)
	_expect_same(current["data"], second, "The slot must hold the newest snapshot.")

	_write_text(TEST_PATH, "not a save")
	var damaged: Dictionary = _save_service.load_game(TEST_PATH)
	_expect(damaged["ok"] == false, "A damaged slot must be reported as an error.")
	_expect(
		String(damaged["error"]).contains(TEST_BACKUP_PATH),
		"The error must point to the backup copy: %s" % damaged["error"]
	)


func _on_state_changed() -> void:
	_signal_count += 1


func _make_snapshot(position_x: float = 80.0) -> Dictionary:
	return {
		"version": 1,
		"world": {"id": "world.demo", "player_position": {"x": position_x, "y": 48.5}},
		"game_state": {
			"flags": {"story.mira.helped": true},
			"relations": {"npc.mira": 1},
			"party": ["hero", "companion.mira"],
		},
	}


func _expect_load_fails(message: String) -> void:
	var loaded: Dictionary = _save_service.load_game(TEST_PATH)
	_expect(loaded["ok"] == false, message)
	_expect(loaded["data"].is_empty(), "%s Data must stay empty." % message)


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write the test file: %s." % path)
		return
	file.store_string(text)
	file = null


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _cleanup_test_files() -> void:
	_remove_file(TEST_PATH)
	_remove_file(TEST_TEMP_PATH)
	_remove_file(TEST_BACKUP_PATH)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _expect_eq(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s Got %s, expected %s." % [message, actual, expected])


func _expect_same(actual: Variant, expected: Variant, message: String) -> void:
	_expect(
		JSON.stringify(actual) == JSON.stringify(expected),
		"%s Got %s, expected %s." % [message, JSON.stringify(actual), JSON.stringify(expected)]
	)
