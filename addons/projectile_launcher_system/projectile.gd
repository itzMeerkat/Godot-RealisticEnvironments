class_name Projectile
extends RigidBody3D
## Basic rigid-body projectile with configurable launch speed, mass, drag, and lifetime.

## Quadratic air drag coefficient applied as a central force each physics tick.
@export_range(0.0, 100.0, 0.001, "or_greater") var drag_coefficient := 0.0
## Seconds before the projectile frees itself. Set 0 to disable timed cleanup.
@export_range(0.0, 120.0, 0.01, "or_greater") var lifetime := 10.0
## Destroys this projectile when it reaches waterline_y and spawns water impact FX.
@export var destroy_below_water := true
## World Y height treated as the still-water impact plane for projectile cleanup.
@export var waterline_y := 0.0
@export_group("Water Impact")
## Optional effect scene spawned when destroy_below_water removes this projectile.
@export var water_impact_effect_scene: PackedScene
## Fallback seconds before a spawned water impact effect is freed if it does not self-delete.
@export_range(0.0, 10.0, 0.01, "or_greater") var water_impact_effect_lifetime := 1.25

var _age := 0.0
var _is_destroying := false


func _physics_process(delta: float) -> void:
	if _is_destroying:
		return
	if destroy_below_water and global_position.y <= waterline_y:
		_destroy_with_water_impact()
		return
	if lifetime > 0.0:
		_age += delta
		if _age >= lifetime:
			queue_free()
			return
	_apply_drag()


func launch(direction: Vector3, speed: float, projectile_mass: float, projectile_drag := -1.0, projectile_lifetime := -1.0) -> void:
	var launch_direction := direction.normalized()
	if launch_direction.length_squared() <= 0.0001:
		launch_direction = Vector3.FORWARD
	mass = maxf(projectile_mass, 0.001)
	if projectile_drag >= 0.0:
		drag_coefficient = projectile_drag
	if projectile_lifetime >= 0.0:
		lifetime = projectile_lifetime
	_age = 0.0
	linear_velocity = launch_direction * maxf(speed, 0.0)


func _apply_drag() -> void:
	if drag_coefficient <= 0.0:
		return
	var velocity := linear_velocity
	var speed_squared := velocity.length_squared()
	if speed_squared <= 0.0001:
		return
	apply_central_force(-velocity.normalized() * speed_squared * drag_coefficient)


func _destroy_with_water_impact() -> void:
	_is_destroying = true
	_spawn_water_impact_effect()
	queue_free()


func _spawn_water_impact_effect() -> void:
	if water_impact_effect_scene == null:
		return
	var effect := water_impact_effect_scene.instantiate()
	var parent := _get_effect_parent()
	parent.add_child(effect)

	var impact_position := global_position
	impact_position.y = waterline_y
	var effect_3d := effect as Node3D
	if effect_3d != null:
		effect_3d.global_position = impact_position
	if effect.has_method(&"play"):
		effect.call(&"play")
	elif effect is GPUParticles3D:
		(effect as GPUParticles3D).emitting = true
		if water_impact_effect_lifetime > 0.0 and is_inside_tree():
			get_tree().create_timer(water_impact_effect_lifetime).timeout.connect(effect.queue_free)
	elif water_impact_effect_lifetime > 0.0 and is_inside_tree():
		get_tree().create_timer(water_impact_effect_lifetime).timeout.connect(effect.queue_free)


func _get_effect_parent() -> Node:
	if is_inside_tree() and get_tree().current_scene != null:
		return get_tree().current_scene
	return get_parent() if get_parent() != null else self
