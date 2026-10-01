class_name BowSpray
extends Node3D
## Spray at a boat's stem. Place it at the stem, at about the waterline. It
## throws a steady sheet of spray to both sides while the stem cuts through
## water, and a slam burst when the bow nose-dives into a wave, with a splash
## ring in the ocean's interaction simulation.
##
## The water at the stem comes from OceanSystem's asynchronous surface query and
## the stem's velocity from this node's own transform history, so it works on
## any moving hull.

const MAX_PARTICLES := 2500
## Elevation range (radians) of slam jets, measured from the side direction.
const SLAM_JET_ELEVATION_MIN := 0.6
const SLAM_JET_ELEVATION_MAX := 1.4

## Enables spray and slam effects.
@export var enabled := true
## Optional OceanSystem. Empty uses the first node in group ocean_system.
@export var ocean_path: NodePath
## Spray starts up to this far (m) to either side of the stem: about half the
## bow's width a little aft of the stem.
@export_range(0.0, 10.0, 0.01, "or_greater") var emission_half_width := 0.3

@export_group("Spray")
## Stem speed into the water (m/s) at which spray starts.
@export_range(0.0, 20.0, 0.01, "or_greater") var spray_speed_min := 1.5
## Stem speed into the water (m/s) at which spray reaches spray_rate.
@export_range(0.0, 40.0, 0.01, "or_greater") var spray_speed_full := 6.0
## Particles per second at full spray.
@export_range(0.0, 2000.0, 1.0, "or_greater") var spray_rate := 220.0
## Sideways spray speed as a fraction of the stem speed.
@export_range(0.0, 2.0, 0.01, "or_greater") var spray_speed_ratio := 0.7

@export_group("Slam")
## Stem speed into the water surface (m/s, along its normal) that counts as a slam.
@export_range(0.0, 20.0, 0.01, "or_greater") var slam_speed_threshold := 2.0
## Jet speed as a multiple of the impact speed (bow-slamming jets leave several
## times faster than the entry speed).
@export_range(0.0, 10.0, 0.01, "or_greater") var slam_jet_ratio := 2.5
## Cap on the jet speed (m/s). Rises up to jet^2 / 2g: 18 m/s reaches 16 m.
@export_range(0.0, 60.0, 0.1, "or_greater") var slam_max_jet_speed := 18.0
## Particles per m/s of impact speed in one slam burst.
@export_range(0.0, 500.0, 1.0, "or_greater") var slam_particles_per_speed := 90.0
## Seconds the stem must have been out of the water before it can slam again.
@export_range(0.0, 5.0, 0.01, "or_greater") var slam_rearm_time := 0.25
## Radius (m) of the splash ring added to the interaction simulation.
@export_range(0.0, 20.0, 0.01, "or_greater") var slam_ring_radius := 1.5
## Ring amplitude (m) per m/s of impact speed. 0 adds no ring.
@export_range(0.0, 1.0, 0.001, "or_greater") var slam_ring_amplitude := 0.04

@export_group("Look")
## Particle lifetime in seconds.
@export_range(0.1, 10.0, 0.01, "or_greater") var particle_lifetime := 2.2
## Droplet streak width in meters at birth (grows to twice this as it fades).
## Streaks are four times longer than wide, along their velocity.
@export_range(0.01, 5.0, 0.01, "or_greater") var particle_size := 0.12
## Spray tint. Alpha is the starting opacity.
@export var spray_color := Color(0.92, 0.96, 1.0, 0.7)

## Emitted with the impact speed (m/s) and world position of every slam.
signal slammed(impact_speed: float, position: Vector3)

var ocean: OceanSystem
var _particles: GPUParticles3D
var _previous_position := Vector3.ZERO
var _velocity := Vector3.ZERO
var _has_previous_position := false
## Seconds the stem has been out of the water; 0 while it is in.
var _dry_time := 0.0
var _spray_budget := 0.0
var _query_point := PackedVector3Array([Vector3.ZERO])


func _ready() -> void:
	ocean = get_node(ocean_path) as OceanSystem if not ocean_path.is_empty() else get_tree().get_first_node_in_group(&"ocean_system") as OceanSystem
	assert(ocean != null, "BowSpray %s: no OceanSystem (set ocean_path or add one to group ocean_system)." % get_path())
	_build_particles()


func _exit_tree() -> void:
	if is_instance_valid(ocean):
		ocean.release_surface_query(self)


func _physics_process(delta: float) -> void:
	var stem := global_position
	if _has_previous_position:
		_velocity = _velocity.lerp((stem - _previous_position) / delta, 1.0 - exp(-delta / 0.05))
	_previous_position = stem
	_has_previous_position = true
	if not enabled:
		return

	_query_point[0] = stem
	ocean.submit_surface_query(self, _query_point)
	var result := ocean.get_surface_query_result(self)
	# The first readback arrives a few frames after the first submit.
	if result == null:
		return
	var sample := result.samples[0]
	var water_height := sample.extrapolated_height(ocean.time - result.dispatch_time)
	var depth := water_height - stem.y
	var relative_velocity := _velocity - sample.surface_velocity
	var surface_point := Vector3(stem.x, minf(stem.y, water_height), stem.z)

	if depth < 0.0:
		_dry_time += delta
		return

	# Slam: the stem just entered the surface fast, along the surface normal.
	var impact_speed := -relative_velocity.dot(sample.normal)
	if _dry_time >= slam_rearm_time and impact_speed >= slam_speed_threshold:
		_slam(surface_point, impact_speed)
	_dry_time = 0.0

	# Steady spray: the stem cutting through water.
	var forward := -global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var cut_speed := Vector3(relative_velocity.x, 0.0, relative_velocity.z).dot(forward)
	var intensity := smoothstep(spray_speed_min, spray_speed_full, cut_speed)
	_spray_budget += intensity * spray_rate * delta
	while _spray_budget >= 1.0:
		_spray_budget -= 1.0
		_emit_spray(surface_point, forward, cut_speed)


func _slam(point: Vector3, impact_speed: float) -> void:
	var jet_speed := minf(impact_speed * slam_jet_ratio, slam_max_jet_speed)
	var forward := -global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var inherited := Vector3(_velocity.x, 0.0, _velocity.z)
	for i in int(slam_particles_per_speed * impact_speed):
		# A sheet thrown up and out to both sides of the stem, some forward.
		var side := right * (1.0 if i % 2 == 0 else -1.0)
		var elevation := randf_range(SLAM_JET_ELEVATION_MIN, SLAM_JET_ELEVATION_MAX)
		var direction := (side * cos(elevation) + Vector3.UP * sin(elevation) + forward * randf_range(-0.1, 0.5)).normalized()
		_emit(point + side * randf_range(0.0, emission_half_width), inherited + direction * jet_speed * randf_range(0.35, 1.0))
	if slam_ring_amplitude > 0.0 and ocean.interaction_enabled:
		ocean.add_water_impulse(point, slam_ring_radius, slam_ring_amplitude * impact_speed)
	slammed.emit(impact_speed, point)


func _emit_spray(point: Vector3, forward: Vector3, cut_speed: float) -> void:
	var side := forward.cross(Vector3.UP) * (1.0 if randf() < 0.5 else -1.0)
	var speed := cut_speed * spray_speed_ratio * randf_range(0.6, 1.0)
	var direction := (side + Vector3.UP * randf_range(0.3, 0.9) + forward * randf_range(-0.2, 0.3)).normalized()
	_emit(point + side * randf_range(0.0, emission_half_width), Vector3(_velocity.x, 0.0, _velocity.z) + direction * speed)


func _emit(point: Vector3, velocity: Vector3) -> void:
	_particles.emit_particle(Transform3D(Basis.IDENTITY, point), velocity, Color.WHITE, Color.WHITE,
		GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY)


func _build_particles() -> void:
	var fade := Gradient.new()
	fade.set_color(0, spray_color)
	fade.set_color(1, Color(spray_color, 0.0))
	var fade_texture := GradientTexture1D.new()
	fade_texture.gradient = fade
	var growth := Curve.new()
	growth.add_point(Vector2(0.0, 0.5))
	growth.add_point(Vector2(1.0, 1.0))
	var growth_texture := CurveTexture.new()
	growth_texture.curve = growth

	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3(0.0, -9.8, 0.0)
	process.damping_min = 0.4
	process.damping_max = 1.2
	process.scale_min = particle_size * 0.6 * 2.0
	process.scale_max = particle_size * 1.4 * 2.0
	process.scale_curve = growth_texture
	process.color_ramp = fade_texture

	var droplet := Gradient.new()
	droplet.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	droplet.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var droplet_texture := GradientTexture2D.new()
	droplet_texture.gradient = droplet
	droplet_texture.fill = GradientTexture2D.FILL_RADIAL
	droplet_texture.fill_from = Vector2(0.5, 0.5)
	droplet_texture.fill_to = Vector2(0.5, 0.0)
	droplet_texture.width = 64
	droplet_texture.height = 64

	# Streaks: quads stretched along the particle velocity, facing the camera.
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = droplet_texture
	material.roughness = 0.35
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 4.0)
	quad.material = material

	_particles = GPUParticles3D.new()
	_particles.name = "SprayParticles"
	_particles.amount = MAX_PARTICLES
	_particles.lifetime = particle_lifetime
	_particles.local_coords = false
	_particles.emitting = false
	_particles.process_material = process
	_particles.draw_pass_1 = quad
	_particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	# Slam spray can climb well above the stem; keep it from being culled.
	_particles.visibility_aabb = AABB(Vector3(-30.0, -10.0, -30.0), Vector3(60.0, 50.0, 60.0))
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_particles, false, INTERNAL_MODE_BACK)
