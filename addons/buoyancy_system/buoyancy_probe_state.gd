class_name BuoyancyProbeState
extends RefCounted
## Water contact state of one buoyancy probe. BuoyancyProbeVolume creates one per
## probe and keeps it for the probe's lifetime; BuoyantBody updates it in place
## every physics tick.

var probe : Node3D
## Contact (FX) probes are sampled like physical probes but apply no force.
var is_fx_probe := false
## "bow", "side" or "stern" for generated contact probes; empty for physical probes.
var tag := ""
## Wet/dry hysteresis: depth (m) at which a dry probe becomes wet, and at which a
## wet probe becomes dry again.
var enter_depth_threshold := 0.03
var exit_depth_threshold := -0.03
## Minimum seconds between two wet/dry changes.
var min_event_interval := 0.08

## False until the first water sample for this probe has arrived.
var has_sample := false
var world_position := Vector3.ZERO
## Water surface point straight above or below world_position.
var water_position := Vector3.ZERO
## Water height minus probe height: positive when the probe is under water.
var depth := 0.0
## Physical probes: fraction of the probe's water column below the surface (0-1).
var submersion := 0.0
var is_wet := false
var was_wet := false
## True on the tick the probe became wet / dry.
var entered := false
var exited := false
## Force the probe applied this tick. Zero for contact probes and dry probes.
var force := Vector3.ZERO
var normal := Vector3.UP
var surface_velocity := Vector3.ZERO
## Seconds (Time.get_ticks_msec() / 1000) of the last update.
var time := 0.0

var _last_event_time := -1.0e20


func _init(probe_node : Node3D, fx_probe : bool, probe_tag : String, enter_threshold : float, exit_threshold : float, event_interval : float) -> void:
	assert(enter_threshold > exit_threshold, "Probe %s: enter depth threshold (%f) must be above the exit threshold (%f)." % [probe_node.get_path(), enter_threshold, exit_threshold])
	probe = probe_node
	is_fx_probe = fx_probe
	tag = probe_tag
	enter_depth_threshold = enter_threshold
	exit_depth_threshold = exit_threshold
	min_event_interval = event_interval


## water_height is the sampled surface height, already extrapolated to now.
func update(sample_position : Vector3, sample : WaterSurfaceSample, water_height : float, applied_force : Vector3, probe_submersion : float, now : float) -> void:
	has_sample = true
	world_position = sample_position
	water_position = Vector3(sample_position.x, water_height, sample_position.z)
	depth = water_height - sample_position.y
	submersion = probe_submersion
	force = applied_force
	normal = sample.normal
	surface_velocity = sample.surface_velocity
	time = now

	was_wet = is_wet
	var wet := is_wet
	if is_wet and depth <= exit_depth_threshold:
		wet = false
	elif not is_wet and depth >= enter_depth_threshold:
		wet = true
	if wet != is_wet:
		if now - _last_event_time < min_event_interval:
			wet = is_wet
		else:
			_last_event_time = now
	is_wet = wet
	entered = is_wet and not was_wet
	exited = was_wet and not is_wet
