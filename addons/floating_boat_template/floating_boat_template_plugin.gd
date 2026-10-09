@tool
extends EditorPlugin
## Enables the Floating Boat Template addon: the development boat, boat_template's
## boat.tscn plus weapons. Needs the Boat Template plugin for its drive actions.
##
## When enabled, it adds the fire_projectile input action (Space) unless the
## project has it.


func _enable_plugin() -> void:
	var setup := ProjectSetup.new()
	setup.add_input_action(&"fire_projectile", [KEY_SPACE])
	setup.save("Floating Boat Template")
