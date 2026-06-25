class_name ProjectileMuzzleFlash
extends Node3D
## Small configurable one-shot flash used by the default projectile launcher scene.

## Number of particles emitted by the one-shot muzzle flash.
@export_range(1, 256, 1) var amount := 18
## Particle lifetime in seconds.
@export_range(0.01, 2.0, 0.01, "or_greater") var particle_lifetime := 0.08
## Minimum initial particle speed.
@export_range(0.0, 100.0, 0.1, "or_greater") var velocity_min := 5.0
## Maximum initial particle speed.
@export_range(0.0, 100.0, 0.1, "or_greater") var velocity_max := 12.0
## Particle emission cone angle in degrees.
@export_range(0.0, 180.0, 0.1, "degrees") var spread := 25.0
## Minimum particle draw scale.
@export_range(0.001, 2.0, 0.001, "or_greater") var particle_scale_min := 0.03
## Maximum particle draw scale.
@export_range(0.001, 2.0, 0.001, "or_greater") var particle_scale_max := 0.12
## Particle color tint.
@export var color := Color(1.0, 0.55, 0.12, 1.0)
## Short-lived light color.
@export var light_color := Color(1.0, 0.46, 0.12, 1.0)
## Short-lived light energy while the flash is active.
@export_range(0.0, 20.0, 0.01, "or_greater") var light_energy := 3.0
## Short-lived light radius.
@export_range(0.0, 20.0, 0.01, "or_greater") var light_range := 2.0
## Extra seconds kept alive after particle_lifetime so late particles can finish.
@export_range(0.0, 2.0, 0.01, "or_greater") var extra_lifetime := 0.08

var _particles: GPUParticles3D
var _light: OmniLight3D


func _ready() -> void:
	_build_effect()
	play()


func play() -> void:
	if _particles == null:
		_build_effect()
	_particles.restart()
	_particles.emitting = true
	if _light != null:
		_light.light_energy = light_energy
	if is_inside_tree():
		get_tree().create_timer(particle_lifetime + extra_lifetime).timeout.connect(queue_free)


func _build_effect() -> void:
	if _particles != null:
		return
	_particles = GPUParticles3D.new()
	_particles.name = "Particles"
	_particles.amount = amount
	_particles.lifetime = particle_lifetime
	_particles.one_shot = true
	_particles.explosiveness = 1.0
	_particles.randomness = 0.45
	_particles.local_coords = true
	_particles.emitting = false

	var process_material := ParticleProcessMaterial.new()
	process_material.direction = Vector3.FORWARD
	process_material.spread = spread
	process_material.gravity = Vector3.ZERO
	process_material.initial_velocity_min = velocity_min
	process_material.initial_velocity_max = velocity_max
	process_material.scale_min = particle_scale_min
	process_material.scale_max = particle_scale_max
	process_material.color = color
	_particles.process_material = process_material

	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	_particles.draw_pass_1 = mesh
	add_child(_particles)

	_light = OmniLight3D.new()
	_light.name = "FlashLight"
	_light.light_color = light_color
	_light.light_energy = light_energy
	_light.omni_range = light_range
	add_child(_light)
