@tool
extends EditorPlugin
## Enables the Boat Template addon. Runtime nodes are available through class_name
## and boat.tscn.
##
## When enabled, it adds the input actions FloatingBoat drives with by default,
## unless the project has them: boat_forward / boat_back / boat_turn_left /
## boat_turn_right (W, S, A, D).


func _enable_plugin() -> void:
	var setup := ProjectSetup.new()
	setup.add_input_action(&"boat_forward", [KEY_W])
	setup.add_input_action(&"boat_back", [KEY_S])
	setup.add_input_action(&"boat_turn_left", [KEY_A])
	setup.add_input_action(&"boat_turn_right", [KEY_D])
	setup.save("Boat Template")
