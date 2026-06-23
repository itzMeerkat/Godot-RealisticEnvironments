class_name BoatProjectileHitSmokeEffect
extends Node3D
## One-shot smoke puff for projectile impacts on boat hitboxes.

@export_range(1, 512, 1) var smoke_amount := 72
@export_range(0.01, 10.0, 0.01, "or_greater") var smoke_lifetime := 1.15
@export_range(0.0, 100.0, 0.1, "or_greater") var smoke_velocity_min := 0.8
@export_range(0.0, 100.0, 0.1, "or_greater") var smoke_velocity_max := 4.2
@export_range(0.0, 180.0, 0.1, "degrees") var smoke_spread := 180.0
@export_range(0.001, 10.0, 0.001, "or_greater") var smoke_scale_min := 0.18
@export_range(0.001, 10.0, 0.001, "or_greater") var smoke_scale_max := 0.75
@export var smoke_color := Color(0.24, 0.23, 0.22, 0.72)
@export var smoke_gravity := Vector3(0.0, 0.45, 0.0)
@export_range(0.0, 5.0, 0.01, "or_greater") var extra_lifetime := 0.45

var _particles: GPUParticles3D


func _ready() -> void:
	_build_effect()


func play() -> void:
	if _particles == null:
		_build_effect()
	_particles.restart()
	_particles.emitting = true
	if is_inside_tree():
		get_tree().create_timer(smoke_lifetime + extra_lifetime).timeout.connect(queue_free)


func _build_effect() -> void:
	if _particles != null:
		return
	_particles = GPUParticles3D.new()
	_particles.name = "SmokeParticles"
	_particles.amount = smoke_amount
	_particles.lifetime = smoke_lifetime
	_particles.one_shot = true
	_particles.explosiveness = 0.9
	_particles.randomness = 0.8
	_particles.local_coords = false
	_particles.emitting = false

	var process_material := ParticleProcessMaterial.new()
	process_material.direction = Vector3.UP
	process_material.spread = smoke_spread
	process_material.gravity = smoke_gravity
	process_material.initial_velocity_min = smoke_velocity_min
	process_material.initial_velocity_max = smoke_velocity_max
	process_material.scale_min = smoke_scale_min
	process_material.scale_max = smoke_scale_max
	process_material.color = smoke_color
	_particles.process_material = process_material

	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	_particles.draw_pass_1 = mesh
	add_child(_particles)
