extends Node

## CORE-01: one-slot save/load of a snapshot in `user://` (INTEGRATION_CONTRACT.md, section 4).
##
## Registered by the integrator as the autoload `SaveService` after INT-CORE-01.
## The service owns files only: it never reads nodes, never calls `GameState` and never
## restores the game itself. `Main` builds the snapshot and applies it after a successful
## load, so a damaged file can never silently replace the current game.

const DEFAULT_SAVE_PATH := "user://save_v1.json"
const SAVE_VERSION := 1
const TEMP_SUFFIX := ".tmp"
const BACKUP_SUFFIX := ".bak"
const RELATION_MIN := -100
const RELATION_MAX := 100


## Validates the snapshot and writes it as JSON. Returns `OK` or a Godot error code.
## The slot is replaced only after a reusable temporary file was written and re-read;
## the previous slot is kept next to it as a `.bak` backup.
## Paths outside `user://` are refused. On any error the current slot is left untouched.
func save_game(snapshot: Dictionary, path: String = DEFAULT_SAVE_PATH) -> int:
	if not _is_user_path(path):
		return ERR_UNAUTHORIZED
	var normalized := _normalize_snapshot(snapshot)
	if normalized.is_empty():
		return ERR_INVALID_DATA

	var temp_path := path + TEMP_SUFFIX
	var staged_error := _stage_snapshot(temp_path, normalized)
	if staged_error != OK:
		_remove_file(temp_path)
		return staged_error
	return _replace_slot(temp_path, path)


## Reads and validates a snapshot. Never changes game state.
## Returns `{"ok": bool, "data": Dictionary, "error": String}`; on success `error` is empty
## and `data` is the validated snapshot. On failure `data` is empty and `error` explains
## the problem, including the path of a backup copy when one exists.
func load_game(path: String = DEFAULT_SAVE_PATH) -> Dictionary:
	if path.is_empty():
		return _failure("Путь файла сохранения не задан.")
	var result := _read_snapshot(path)
	if result["ok"] == true:
		return result
	return _failure_with_backup(path, String(result["error"]))


## Writes the snapshot and re-reads it so a truncated write is caught before the swap.
func _stage_snapshot(temp_path: String, snapshot: Dictionary) -> int:
	var write_error := _write_json(temp_path, snapshot)
	if write_error != OK:
		return write_error
	return _verify_file(temp_path)


## Keeps the previous slot as `<slot>.bak` and only then moves the new file into place.
func _replace_slot(temp_path: String, path: String) -> int:
	var backup_path := path + BACKUP_SUFFIX
	if FileAccess.file_exists(path):
		_remove_file(backup_path)
		var backup_error := DirAccess.rename_absolute(path, backup_path)
		if backup_error != OK:
			_remove_file(temp_path)
			return backup_error

	var replace_error := DirAccess.rename_absolute(temp_path, path)
	if replace_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, path)
		_remove_file(temp_path)
	return replace_error


func _read_snapshot(path: String) -> Dictionary:
	var read_result := _read_text_file(path)
	if read_result["ok"] == false:
		return _failure(String(read_result["error"]))
	return _parse_snapshot(String(read_result["text"]), path)


func _read_text_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure_text("Файл сохранения не найден: %s." % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_error := FileAccess.get_open_error()
		return _failure_text(
			"Не удалось открыть файл сохранения: %s (код %d)." % [path, open_error]
		)
	var text := file.get_as_text()
	var read_error := file.get_error()
	file = null
	if read_error != OK:
		return _failure_text(
			"Не удалось прочитать файл сохранения: %s (код %d)." % [path, read_error]
		)
	return {"ok": true, "text": text, "error": ""}


func _parse_snapshot(text: String, path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _failure("Файл сохранения повреждён: это не JSON-объект (%s)." % path)

	var version_value: Variant = parsed.get("version")
	if not _is_integral_number(version_value):
		return _failure("Файл сохранения повреждён: нет версии формата (%s)." % path)
	var version := _as_int(version_value)
	if version != SAVE_VERSION:
		return _failure(
			"Неподдерживаемая версия сохранения %d, поддерживается только %d. Файл не изменён."
			% [version, SAVE_VERSION]
		)

	var normalized := _normalize_snapshot(parsed)
	if normalized.is_empty():
		return _failure("Файл сохранения повреждён: неверная структура (%s)." % path)
	return {"ok": true, "data": normalized, "error": ""}


## Only `user://` is writable and `..` is refused, so a save cannot escape the user folder.
## `String.is_absolute_path()` is not used here: in Godot 4.4 it also reports `user://`
## and `res://` as absolute paths.
func _is_user_path(path: String) -> bool:
	if not path.begins_with("user://"):
		return false
	return path.length() > "user://".length() and not path.contains("..")


func _write_json(path: String, snapshot: Dictionary) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(snapshot, "\t"))
	file.flush()
	var write_error := file.get_error()
	file = null
	return write_error


## Re-reads the temporary file so a truncated or unparsable write is caught early.
func _verify_file(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var text := file.get_as_text()
	file = null
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return ERR_FILE_CORRUPT
	if _normalize_snapshot(parsed).is_empty():
		return ERR_FILE_CORRUPT
	return OK


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _failure(message: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": message}


func _failure_text(message: String) -> Dictionary:
	return {"ok": false, "text": "", "error": message}


func _failure_with_backup(path: String, message: String) -> Dictionary:
	var backup_path := path + BACKUP_SUFFIX
	if FileAccess.file_exists(backup_path):
		return _failure(
			"%s Резервная копия: %s." % [message, backup_path]
		)
	return _failure(message)


## Returns the canonical snapshot, or `{}` when the data is not a valid v1 snapshot.
## Unknown top-level and `world` keys are kept if they are JSON-safe, so later systems
## (for example a spawn point) can extend the snapshot without breaking v1 readers.
func _normalize_snapshot(snapshot: Dictionary) -> Dictionary:
	var version_value: Variant = snapshot.get("version")
	if not _is_integral_number(version_value):
		return {}
	var version := _as_int(version_value)
	if version != SAVE_VERSION:
		return {}

	var world: Variant = _normalize_world(snapshot.get("world"))
	if world == null:
		return {}
	var game_state: Variant = _normalize_game_state(snapshot.get("game_state"))
	if game_state == null:
		return {}

	var result := {"version": version, "world": world, "game_state": game_state}
	for key in snapshot:
		if typeof(key) != TYPE_STRING or result.has(key):
			continue
		if not _is_json_safe(snapshot[key]):
			return {}
		result[key] = _copy_value(snapshot[key])
	return result


func _normalize_world(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var world_id: Variant = value.get("id")
	if not _is_valid_id(world_id):
		return null
	var position: Variant = value.get("player_position")
	if typeof(position) != TYPE_DICTIONARY:
		return null
	var x: Variant = position.get("x")
	var y: Variant = position.get("y")
	if not _is_finite_number(x) or not _is_finite_number(y):
		return null

	var result := {"id": world_id, "player_position": {"x": float(x), "y": float(y)}}
	for key in value:
		if typeof(key) != TYPE_STRING or result.has(key):
			continue
		if not _is_json_safe(value[key]):
			return null
		result[key] = _copy_value(value[key])
	return result


## Structure and value types of section 3. The state invariants (`hero` first in the
## party) stay in `GameState.import_state`, which validates again before applying.
func _normalize_game_state(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var flags: Variant = _normalize_flags(value.get("flags"))
	if flags == null:
		return null
	var relations: Variant = _normalize_relations(value.get("relations"))
	if relations == null:
		return null
	var party: Variant = _normalize_party(value.get("party"))
	if party == null:
		return null
	var result := {"flags": flags, "relations": relations, "party": party}
	if value.has("modules"):
		var modules: Variant = _normalize_modules(value["modules"])
		if modules == null:
			return null
		result["modules"] = modules
	return result


func _normalize_flags(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var flags := {}
	for flag_id in value:
		if not _is_valid_id(flag_id) or typeof(value[flag_id]) != TYPE_BOOL:
			return null
		flags[flag_id] = value[flag_id]
	return flags


func _normalize_relations(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var relations := {}
	for relation_id in value:
		if not _is_valid_id(relation_id) or not _is_integral_number(value[relation_id]):
			return null
		var relation := _as_int(value[relation_id])
		if relation < RELATION_MIN or relation > RELATION_MAX:
			return null
		relations[relation_id] = relation
	return relations


func _normalize_party(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY or value.is_empty():
		return null
	var party: Array[String] = []
	for member in value:
		if not _is_valid_id(member) or party.has(member):
			return null
		party.append(member)
	return party


func _normalize_modules(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var modules := {}
	for module_id in value:
		if not _is_valid_id(module_id):
			return null
		if typeof(value[module_id]) != TYPE_DICTIONARY:
			return null
		if not _is_json_safe(value[module_id]):
			return null
		modules[module_id] = value[module_id].duplicate(true)
	return modules


func _is_valid_id(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var id: String = value
	return not id.is_empty()


func _is_finite_number(value: Variant) -> bool:
	match typeof(value):
		TYPE_INT:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		_:
			return false


## Accepts `int` and integral `float` values: JSON reads every number as `float`.
func _is_integral_number(value: Variant) -> bool:
	if not _is_finite_number(value):
		return false
	if typeof(value) == TYPE_INT:
		return true
	return value == floor(value)


func _as_int(value: Variant) -> int:
	return int(value)


func _copy_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY:
			return value.duplicate(true)
		_:
			return value


## Plain JSON values only: this rejects `Node`, `Resource`, `Vector2` and other
## engine objects that cannot be restored reliably from a text file.
func _is_json_safe(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_ARRAY:
			return _is_json_safe_items(value)
		TYPE_DICTIONARY:
			return _has_valid_keys(value) and _is_json_safe_items(value.values())
		_:
			return false


func _is_json_safe_items(items: Array) -> bool:
	for item in items:
		if not _is_json_safe(item):
			return false
	return true


func _has_valid_keys(data: Dictionary) -> bool:
	for key in data:
		if not _is_valid_id(key):
			return false
	return true
