@tool
class_name HullProfile
extends Resource
## Baked description of a hull's inside, in the local space of the
## HullWaterFootprint that baked it. The hull is treated as mirror-symmetric
## about x = center_x. Created by HullWaterFootprint.bake_profile().
##
## image is LENGTH_SAMPLES x PROFILE_SAMPLES, FORMAT_RGBH. Column i is the length
## station z = min_z + (i + 0.5) / LENGTH_SAMPLES * (max_z - min_z).
## - R, row j: inner half-width at height y = min_y + (j + 0.5) / PROFILE_SAMPLES
##   * (max_y - min_y). 0 above the hull or below the keel.
## - G, row j: lowest height inside the hull at lateral offset
##   |x - center_x| = (j + 0.5) / PROFILE_SAMPLES * max_half_width, or max_y
##   where the hull does not reach that far out (no draft).
## - B, every row: top of the hull at this station, as the height coordinate
##   (0..1 over min_y..max_y) of its highest row with a non-zero half-width.
##   The cutout clamps heights above it to it (HullWaterFootprint.cutout_height_offset).

const LENGTH_SAMPLES := 64
const PROFILE_SAMPLES := 32

@export var image : Image
@export var min_z := 0.0
@export var max_z := 0.0
@export var min_y := 0.0
@export var max_y := 0.0
@export var max_half_width := 0.0
@export var center_x := 0.0


## Bakes a profile from hull triangles given in the footprint's local space.
## inset shrinks every half-width so the cutout stays inside the hull shell.
## Returns null (reported) when the triangles cannot make a profile.
static func build(triangles : PackedVector3Array, inset : float) -> HullProfile:
	if triangles.size() < 3:
		push_error("HullProfile.build() needs at least one triangle.")
		return null
	var bounds := AABB(triangles[0], Vector3.ZERO)
	for vertex in triangles:
		bounds = bounds.expand(vertex)
	if bounds.size.y <= HullSlicer.EPSILON or bounds.size.z <= HullSlicer.EPSILON:
		push_error("Hull triangles are flat; cannot bake a profile.")
		return null

	var profile := HullProfile.new()
	profile.min_z = bounds.position.z
	profile.max_z = bounds.end.z
	profile.min_y = bounds.position.y
	profile.max_y = bounds.end.y
	profile.center_x = bounds.get_center().x

	# half_widths[row * LENGTH_SAMPLES + column]
	var half_widths := PackedFloat32Array()
	half_widths.resize(LENGTH_SAMPLES * PROFILE_SAMPLES)
	for row in PROFILE_SAMPLES:
		var segments := HullSlicer.slice(triangles, profile.get_row_height(row))
		var station_widths := _max_half_widths_at_stations(segments, profile)
		for column in LENGTH_SAMPLES:
			half_widths[row * LENGTH_SAMPLES + column] = maxf(station_widths[column] - inset, 0.0)

	for width in half_widths:
		profile.max_half_width = maxf(profile.max_half_width, width)
	if profile.max_half_width <= 0.0:
		push_error("Hull profile is empty after the inset; reduce bake_inset.")
		return null

	profile.image = Image.create_empty(LENGTH_SAMPLES, PROFILE_SAMPLES, false, Image.FORMAT_RGBH)
	for column in LENGTH_SAMPLES:
		var top := 0.0
		for row in PROFILE_SAMPLES:
			if half_widths[row * LENGTH_SAMPLES + column] > 0.0:
				top = (float(row) + 0.5) / float(PROFILE_SAMPLES)
		for row in PROFILE_SAMPLES:
			var half_width := half_widths[row * LENGTH_SAMPLES + column]
			var keel := profile._find_keel(half_widths, column, profile.get_row_offset(row))
			profile.image.set_pixel(column, row, Color(half_width, keel, top, 1.0))
	return profile


func get_row_height(row : int) -> float:
	return lerpf(min_y, max_y, (float(row) + 0.5) / float(PROFILE_SAMPLES))


func get_row_offset(row : int) -> float:
	return max_half_width * (float(row) + 0.5) / float(PROFILE_SAMPLES)


func get_station_z(column : int) -> float:
	return lerpf(min_z, max_z, (float(column) + 0.5) / float(LENGTH_SAMPLES))


## Local-space box covered by the profile.
func get_local_bounds() -> AABB:
	return AABB(
		Vector3(center_x - max_half_width, min_y, min_z),
		Vector3(max_half_width * 2.0, max_y - min_y, max_z - min_z)
	)


func _find_keel(half_widths : PackedFloat32Array, column : int, lateral_offset : float) -> float:
	for row in PROFILE_SAMPLES:
		if half_widths[row * LENGTH_SAMPLES + column] >= lateral_offset:
			return get_row_height(row)
	return max_y


static func _max_half_widths_at_stations(segments : PackedVector2Array, profile : HullProfile) -> PackedFloat32Array:
	var widths := PackedFloat32Array()
	widths.resize(LENGTH_SAMPLES)
	var station_step := (profile.max_z - profile.min_z) / float(LENGTH_SAMPLES)
	for i in range(0, segments.size(), 2):
		var a := segments[i]
		var b := segments[i + 1]
		var z_min := minf(a.y, b.y)
		var z_max := maxf(a.y, b.y)
		var first := maxi(ceili((z_min - profile.min_z) / station_step - 0.5), 0)
		var last := mini(floori((z_max - profile.min_z) / station_step - 0.5), LENGTH_SAMPLES - 1)
		for column in range(first, last + 1):
			var z := profile.get_station_z(column)
			var x : float
			if z_max - z_min <= HullSlicer.EPSILON:
				x = a.x if absf(a.x - profile.center_x) > absf(b.x - profile.center_x) else b.x
			else:
				x = lerpf(a.x, b.x, (z - a.y) / (b.y - a.y))
			widths[column] = maxf(widths[column], absf(x - profile.center_x))
	return widths
