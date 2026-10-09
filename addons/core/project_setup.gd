@tool
class_name ProjectSetup
extends RefCounted
## Adds the project settings an addon needs (global shader uniforms, input
## actions, rendering options) to project.godot, for the addons' editor plugins.
## Each call only adds what is missing and never changes a value the project
## already has; call save() once afterwards.

## Messages of what was added since the last save(), for the plugin to print.
var added : PackedStringArray = []


## Declares the global shader uniform `name` (type as in project.godot, e.g.
## "float", "vec4", "sampler3D") unless the project has it, and registers it with
## the editor's RenderingServer at once, so shaders that use it compile without a
## restart.
func add_shader_global(name: StringName, type: String, value: Variant) -> void:
	var setting := "shader_globals/" + name
	if ProjectSettings.has_setting(setting):
		return
	var server_type := _global_shader_parameter_type(type)
	if server_type < 0:
		push_error("ProjectSetup: unknown global shader uniform type \"%s\" for %s." % [type, name])
		return
	var is_sampler := type.begins_with("sampler")
	ProjectSettings.set_setting(setting, {"type": type, "value": "" if is_sampler else value})
	RenderingServer.global_shader_parameter_add(name, server_type, null if is_sampler else value)
	added.push_back("global shader uniform %s (%s)" % [name, type])


## Adds the input action `name` bound to the given physical keys unless the
## project has it.
func add_input_action(name: StringName, physical_keys: Array[Key], deadzone := 0.2) -> void:
	var setting := "input/" + name
	if ProjectSettings.has_setting(setting):
		return
	var events : Array[InputEvent] = []
	for key in physical_keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		events.push_back(event)
	ProjectSettings.set_setting(setting, {"deadzone": deadzone, "events": events})
	var names := PackedStringArray()
	for key in physical_keys:
		names.push_back(OS.get_keycode_string(key))
	added.push_back("input action %s (%s)" % [name, ", ".join(names)])


## Sets `setting` to `value` unless it has that value or the project sets it to
## something else (a value equal to the engine default counts as unset: Godot
## does not save defaults).
func add_setting(setting: String, value: Variant, reason: String) -> void:
	if ProjectSettings.get_setting(setting) == value or _is_set_in_project(setting):
		return
	ProjectSettings.set_setting(setting, value)
	added.push_back("%s = %s (%s)" % [setting, value, reason])


## Saves project.godot if anything was added and prints what, under `addon_name`.
func save(addon_name: String) -> void:
	if added.is_empty():
		return
	var error := ProjectSettings.save()
	if error != OK:
		push_error("%s: saving project.godot failed (%s); add these settings by hand: %s." % [addon_name, error_string(error), "; ".join(added)])
	else:
		print("%s added to project.godot: %s." % [addon_name, "; ".join(added)])
	added.clear()


## Whether project.godot itself sets `setting` (not just the engine's default).
static func _is_set_in_project(setting: String) -> bool:
	return ProjectSettings.has_setting(setting) and ProjectSettings.property_get_revert(setting) != ProjectSettings.get_setting(setting)


static func _global_shader_parameter_type(type: String) -> int:
	match type:
		"bool": return RenderingServer.GLOBAL_VAR_TYPE_BOOL
		"int": return RenderingServer.GLOBAL_VAR_TYPE_INT
		"float": return RenderingServer.GLOBAL_VAR_TYPE_FLOAT
		"vec2": return RenderingServer.GLOBAL_VAR_TYPE_VEC2
		"vec3": return RenderingServer.GLOBAL_VAR_TYPE_VEC3
		"vec4": return RenderingServer.GLOBAL_VAR_TYPE_VEC4
		"color": return RenderingServer.GLOBAL_VAR_TYPE_COLOR
		"sampler2D": return RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D
		"sampler2DArray": return RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY
		"sampler3D": return RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D
		"samplerCube": return RenderingServer.GLOBAL_VAR_TYPE_SAMPLERCUBE
	return -1
