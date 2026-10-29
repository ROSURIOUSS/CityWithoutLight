extends Node

## CORE-01: the single source of shared game facts (INTEGRATION_CONTRACT.md, sections 3-4).
##
## Registered by the integrator as the autoload `GameState` after INT-CORE-01.
## The autoload name is intentionally not duplicated through `class_name`.
## Other modules never touch the internal dictionaries or arrays: they only use the
## methods below, so the stored form stays serialisable and validated.

signal state_changed()

const HERO_ID := "hero"
const RELATION_MIN := -100
const RELATION_MAX := 100
## Opt-in storage namespaces for systems that are not part of the MVP contract.
## They hold plain JSON-safe data only; no quest, inventory or battle logic lives here.
const MODULE_IDS := ["quests", "inventory", "characters", "location"]

var _flags: Dictionary = {}
var _relations: Dictionary = {}
var _party: Array[String] = []
var _modules: Dictionary = {}


func _init() -> void:
	_party.append(HERO_ID)


## Clears every stored fact and restores the starting party. Always emits one signal.
func reset_new_game() -> void:
	_flags.clear()
	_relations.clear()
	_modules.clear()
	_party.clear()
	_party.append(HERO_ID)
	state_changed.emit()


## Unknown or empty ids are reported as `false` (INTEGRATION_CONTRACT.md, section 3).
func get_flag(id: String) -> bool:
	if id.is_empty():
		return false
	return _flags.get(id, false) == true


## Ignores an empty id. Emits `state_changed` only when the stored value really changes.
func set_flag(id: String, value: bool) -> void:
	if id.is_empty():
		return
	if value:
		if _flags.get(id, false) == true:
			return
		_flags[id] = true
	else:
		if not _flags.has(id):
			return
		_flags.erase(id)
	state_changed.emit()


## Unknown or empty ids default to `0`.
func get_relation(id: String) -> int:
	if id.is_empty():
		return 0
	return _as_int(_relations.get(id, 0))


## Adds `delta` for a non-empty id, clamps to -100..100 and returns the new value.
## An empty id changes nothing and returns `0`; no signal is emitted without a change.
func change_relation(id: String, delta: int) -> int:
	if id.is_empty():
		return 0
	var current := get_relation(id)
	var updated := clampi(current + delta, RELATION_MIN, RELATION_MAX)
	if updated == current:
		return current
	if updated == 0:
		_relations.erase(id)
	else:
		_relations[id] = updated
	state_changed.emit()
	return updated


## Returns a copy of the ordered party; the first entry is always `hero`.
func get_party() -> Array[String]:
	var copy: Array[String] = _party.duplicate()
	return copy


## Adds a non-empty id that is not in the party yet. No duplicates, never removes `hero`.
func add_party_member(id: String) -> bool:
	if id.is_empty() or _party.has(id):
		return false
	_party.append(id)
	state_changed.emit()
	return true


## Deep copy of the stored facts in the documented save form. Changing the copy
## never changes the game. The optional `modules` key appears only when used.
func export_state() -> Dictionary:
	var result := {
		"flags": _flags.duplicate(true),
		"relations": _relations.duplicate(true),
		"party": get_party(),
	}
	if not _modules.is_empty():
		result["modules"] = _modules.duplicate(true)
	return result


## Validates the whole payload first, then replaces the state and emits exactly one
## `state_changed`. On any error nothing changes and no signal is emitted.
func import_state(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	var normalized := _normalize_state(data)
	if normalized.is_empty():
		return false
	_flags = normalized["flags"]
	_relations = normalized["relations"]
	_party.assign(normalized["party"])
	_modules = normalized["modules"]
	state_changed.emit()
	return true


## Returns a deep copy of one storage namespace, or `{}` for an unknown id.
func get_module_data(module_id: String) -> Dictionary:
	if not MODULE_IDS.has(module_id):
		return {}
	var stored: Dictionary = _modules.get(module_id, {})
	return stored.duplicate(true)


## Replaces one storage namespace with JSON-safe data. An unknown id, or data holding
## `Node`, `Resource`, `Vector2` and other engine objects, is rejected without changes.
func set_module_data(module_id: String, data: Dictionary) -> bool:
	if not MODULE_IDS.has(module_id):
		return false
	if not _is_json_safe(data):
		return false
	_modules[module_id] = data.duplicate(true)
	state_changed.emit()
	return true


## Reports whether a namespace currently holds data.
func has_module_data(module_id: String) -> bool:
	return _modules.has(module_id)


## Returns the normalised payload, or `{}` when the payload is not valid.
func _normalize_state(data: Dictionary) -> Dictionary:
	var flags: Variant = _normalize_flags(data.get("flags"))
	if flags == null:
		return {}
	var relations: Variant = _normalize_relations(data.get("relations"))
	if relations == null:
		return {}
	var party: Variant = _normalize_party(data.get("party"))
	if party == null:
		return {}
	var modules: Variant = _normalize_modules(data.get("modules", {}))
	if modules == null:
		return {}
	return {"flags": flags, "relations": relations, "party": party, "modules": modules}


func _normalize_flags(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var flags := {}
	for flag_id in value:
		if not _is_valid_id(flag_id):
			return null
		if typeof(value[flag_id]) != TYPE_BOOL:
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
	if typeof(value) != TYPE_ARRAY:
		return null
	var party: Array[String] = []
	for member in value:
		if not _is_valid_id(member) or party.has(member):
			return null
		party.append(member)
	if party.is_empty() or party[0] != HERO_ID:
		return null
	return party


## `modules` is optional so that MVP save files without it stay valid.
func _normalize_modules(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var modules := {}
	for module_id in value:
		if typeof(module_id) != TYPE_STRING or not MODULE_IDS.has(module_id):
			return null
		var module_data: Variant = value[module_id]
		if typeof(module_data) != TYPE_DICTIONARY or not _is_json_safe(module_data):
			return null
		modules[module_id] = module_data.duplicate(true)
	return modules


func _is_valid_id(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var id: String = value
	return not id.is_empty()


## Accepts `int` and integral `float` values: JSON reads every number as `float`.
func _is_integral_number(value: Variant) -> bool:
	match typeof(value):
		TYPE_INT:
			return true
		TYPE_FLOAT:
			var number: float = value
			return is_finite(number) and number == floor(number)
		_:
			return false


func _as_int(value: Variant) -> int:
	return int(value)


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
