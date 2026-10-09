@tool
extends EditorPlugin
## Enables the Projectile Launcher System addon. Runtime nodes are available through class_name.
##
## When enabled, it adds the input action ProjectileWeaponController fires on by
## default, fire_projectile (Space), unless the project has it.


func _enable_plugin() -> void:
	var setup := ProjectSetup.new()
	setup.add_input_action(&"fire_projectile", [KEY_SPACE])
	setup.save("Projectile Launcher System")
