@tool
extends EditorPlugin
## Enables the Sky System addon. Runtime types are registered through
## class_name scripts; instance sky_system.tscn for the complete setup.
##
## Sets up the project: declares the atmosphere's global shader uniforms
## (AtmosphereGlobals.DECLARATIONS; the sky's shaders do not compile without them)
## whenever the editor loads the plugin, and turns on debanding when it is
## enabled (night skies band into contours without it). It only adds what is
## missing and never removes anything.


func _enter_tree() -> void:
	_set_up_project(false)


func _enable_plugin() -> void:
	_set_up_project(true)


func _set_up_project(enabling: bool) -> void:
	var setup := ProjectSetup.new()
	for declaration : Array in AtmosphereGlobals.DECLARATIONS:
		setup.add_shader_global(declaration[0], declaration[1], declaration[2])
	if enabling:
		setup.add_setting("rendering/anti_aliasing/quality/use_debanding", true, "night skies band without it")
	setup.save("Sky System")
