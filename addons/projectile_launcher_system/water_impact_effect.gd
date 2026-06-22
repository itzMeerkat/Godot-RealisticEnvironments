class_name ProjectileWaterImpactEffect
extends Node3D
## Configurable one-shot water impact particles for projectile types.

@export_range(1, 512, 1) var splash_amount := 42
@export_range(0.01, 5.0, 0.01, "or_greater") var splash_lifetime := 0.85
@export_range(0.0, 100.0, 0.1, "or_greater") var splash_velocity_min := 3.0
@export_range(0.0, 100.0, 0.1, "or_greater") var splash_velocity_max := 10.0
@export_range(0.0, 180.0, 0.1, "degrees") var splash_spread := 55.0
@export_range(0.001, 5.0, 0.001, "or_greater") var splash_scale_min := 0.04
@export_range(0.001, 5.0, 0.001, "or_greater") var splash_scale_max := 0.18
@export var splash_color := Color(0.72, 0.9, 1.0, 0.85)
@export var splash_gravity := Vector3(0.0, -9.8, 0.0)
@export_range(0.0, 5.0, 0.01, "or_greater") var extra_lifetime := 0.35

var _splash_particles: GPUParticles3D


func _ready() -> void:
	_build_effect()


func play() -> void:
	if _splash_particles == null:
		_build_effect()
	_splash_particles.restart()
	_splash_particles.emitting = true
	if is_inside_tree():
		get_tree().create_timer(splash_lifetime + extra_lifetime).timeout.connect(queue_free)


func _build_effect() -> void:
	if _splash_particles != null:
		return
	_splash_particles = GPUParticles3D.new()
	_splash_particles.name = "SplashParticles"
	_splash_particles.amount = splash_amount
	_splash_particles.lifetime = splash_lifetime
	_splash_particles.one_shot = true
	_splash_particles.explosiveness = 0.92
	_splash_particles.randomness = 0.65
	_splash_particles.local_coords = false
	_splash_particles.emitting = false

	var process_material := ParticleProcessMaterial.new()
	process_material.direction = Vector3.UP
	process_material.spread = splash_spread
	process_material.gravity = splash_gravity
	process_material.initial_velocity_min = splash_velocity_min
	process_material.initial_velocity_max = splash_velocity_max
	process_material.scale_min = splash_scale_min
	process_material.scale_max = splash_scale_max
	process_material.color = splash_color
	_splash_particles.process_material = process_material

	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	_splash_particles.draw_pass_1 = mesh
	add_child(_splash_particles)
