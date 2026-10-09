@tool
extends EditorPlugin
## Enables the Floating Boat Template addon. Runtime nodes are available through class_name and scenes.
##
## When enabled, it adds the input actions the template's defaults read, unless
## the project has them: boat_forward / boat_back / boat_turn_left /
## boat_turn_right (W, S, A, D) and fire_projectile (Space).


func _enable_plugin() -> void:
	var setup := ProjectSetup.new()
	setup.add_input_action(&"boat_forward", [KEY_W])
	setup.add_input_action(&"boat_back", [KEY_S])
	setup.add_input_action(&"boat_turn_left", [KEY_A])
	setup.add_input_action(&"boat_turn_right", [KEY_D])
	setup.add_input_action(&"fire_projectile", [KEY_SPACE])
	setup.save("Floating Boat Template")
