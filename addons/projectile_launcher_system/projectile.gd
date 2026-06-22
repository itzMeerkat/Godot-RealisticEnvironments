class_name Projectile
extends RigidBody3D
## Basic rigid-body projectile with configurable launch speed, mass, drag, and lifetime.

@export_range(0.0, 100.0, 0.001, "or_greater") var drag_coefficient := 0.0
@export_range(0.0, 120.0, 0.01, "or_greater") var lifetime := 10.0

var _age := 0.0


func _physics_process(delta: float) -> void:
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
