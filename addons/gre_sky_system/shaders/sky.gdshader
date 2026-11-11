shader_type sky;
/*
 * The sky: space (the sun's and the moon's disks) seen through the atmosphere, whose
 * view volume holds everything else (the blue sky, twilight, the haze's glow, the sea
 * below the horizon), with the clouds inside it where the ray enters their layer. The
 * camera's own view leaves the clouds to GREVolumetricCloudEffect (screen_clouds).
 */

#include "res://addons/gre_sky_system/shaders/atmosphere.gdshaderinc"

// Where the sun is seen (refracted by the air; GRESkySystem.get_sun_direction()), and where
// it is: its disk is drawn by bending each view ray back (unrefracted()), so near the
// horizon, where the lower limb is lifted more, it comes out flattened.
uniform vec3 sun_direction = vec3(1.0, 0.0, 0.0);
uniform vec3 sun_disk_direction = vec3(1.0, 0.0, 0.0);
// Colour of the sun's light at the sea (brightest channel 1).
uniform vec4 sun_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
// Share of the disk above the horizon.
uniform float sun_visibility : hint_range(0.0, 1.0) = 1.0;
// The sun's light above the atmosphere, pi * energy (irradiance in the units of the
// scene's lights). The disk shows it spread over its solid angle; the atmosphere's view
// volume dims it along each view ray (air and haze, spectrally).
uniform vec3 sun_irradiance = vec3(3.0);
uniform float sun_disk_size : hint_range(0.001, 0.05) = 0.00465;
uniform float sun_halo_size : hint_range(0.01, 0.5) = 0.075;
uniform float radiance_sun_disk_strength : hint_range(0.0, 3.0) = 0.16;
uniform float radiance_sun_halo_strength : hint_range(0.0, 1.0) = 0.18;

uniform vec3 moon_direction = vec3(-1.0, 0.0, 0.0);
uniform vec3 moon_disk_direction = vec3(-1.0, 0.0, 0.0);
// As the sun's: the full moon's light, so the lit part of the disk shows it.
uniform vec4 moon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec3 moon_irradiance = vec3(0.1);
uniform float moon_visibility : hint_range(0.0, 1.0) = 0.0;
uniform float moon_disk_size : hint_range(0.001, 0.05) = 0.00465;
// Lit share of the disk.
uniform float moon_phase : hint_range(0.0, 1.0) = 1.0;
// The lit part's radiance over the Lommel-Seeliger law's (moon_lighting()): its rough
// surface's shadows and opposition surge (GRESkySystem._lunar_phase_brightness() over the
// law's disk-integrated phase function).
uniform float moon_surface_brightness : hint_range(0.0, 2.0) = 1.0;
// Radiance of the moon's night side lit by the earth, as a share of the full moon's.
uniform float moon_earthshine = 0.0;

// Volumetric clouds seen from the camera (GRECloudRenderer.camera_cubemap): rgb is
// premultiplied radiance, a is opacity. GRESkySystem sets the cloud uniforms through the
// RenderingServer so the runtime texture is never saved into the material. The
// radiance map (ambient light and reflections) shows them; the camera's own view does
// only without screen_clouds.
uniform bool clouds_enabled = false;
// GREVolumetricCloudEffect draws the clouds over the camera's view: the sky leaves them out.
uniform bool screen_clouds = false;
// Altitudes (m above the sea) of the cloud layer's base and top: the atmosphere in front
// of the clouds ends where the ray enters the layer.
uniform float cloud_base_altitude = 1500.0;
uniform float cloud_top_altitude = 4500.0;
uniform samplerCube cloud_cubemap : filter_linear_mipmap;

// The Milky Way (stars/milky_way.exr: rgb in ucd/m2, plate carree in J2000 right
// ascension and declination), part of space: milky_way_basis turns world directions into
// the equatorial frame (it follows the sidereal time), milky_way_scale turns its values
// into scene radiance. Set by GRESkySystem.
uniform sampler2D milky_way : filter_linear_mipmap, repeat_enable;
uniform mat3 milky_way_basis = mat3(1.0);
uniform float milky_way_scale = 0.0;

/*
 * Atmospheric refraction (rad) of light seen at apparent elevation h (rad): Bennett's
 * (1982) formula for standard air at the sea, about 34' at the horizon.
 */
float refraction_at_apparent(float h) {
	float degrees_h = max(degrees(h), -1.0);
	return radians(1.0 / 60.0) / tan(radians(degrees_h + 7.31 / (degrees_h + 4.4)));
}

// Air's refractivity (n - 1) at the r, g and b bands' wavelengths (680, 550, 440 nm) over
// its value at 550 nm (Ciddor 1996): blue is bent most. At the horizon the sun's blue
// image stands about 0.6' above its red one, so its upper rim turns green as it sets (the
// green flash: the blue is gone through that much air). A rim that thin needs a long lens.
const vec3 AIR_DISPERSION = vec3(0.99338, 1.0, 1.01107);

/*
 * The direction a view ray came from above the air: bent back down by the refraction,
 * times dispersion (AIR_DISPERSION's channel) for that colour.
 */
vec3 unrefracted(vec3 view_direction, float dispersion) {
	vec3 direction = normalize(view_direction);
	float horizontal = length(direction.xz);
	if (horizontal < 1e-5) {
		return direction;
	}
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float true_elevation = elevation - max(refraction_at_apparent(elevation), 0.0) * dispersion;
	return vec3(direction.x / horizontal * cos(true_elevation), sin(true_elevation), direction.z / horizontal * cos(true_elevation));
}

/*
 * Coverage (0-1) of a body's disk of angular radius disk_size (true_direction: where the
 * body is) along a view ray, and (r) the ray's distance from its centre in radii, per
 * colour: each is refracted by its own amount (AIR_DISPERSION). The edge is softened over
 * about a pixel (edge_size, rad).
 */
vec3 body_disk(vec3 view_direction, vec3 true_direction, float disk_size, float edge_size, out vec3 r) {
	vec3 coverage;
	for (int c = 0; c < 3; ++c) {
		float alignment = dot(unrefracted(view_direction, AIR_DISPERSION[c]), normalize(true_direction));
		float angular_distance = acos(clamp(alignment, -1.0, 1.0));
		r[c] = angular_distance / disk_size;
		coverage[c] = 1.0 - smoothstep(disk_size - 0.5 * edge_size, disk_size + 0.5 * edge_size, angular_distance);
	}
	return coverage;
}

/*
 * The sun's limb darkening: radiance at r radii from the centre over the disk's mean,
 * per channel. I(mu) = mu^a (Hestroffer and Magnan 1998, a = -0.023 + 0.292 / lambda in
 * micrometres at 680, 550 and 440 nm), whose mean over the disk is 2 / (a + 2).
 */
vec3 sun_limb_darkening(vec3 r) {
	const vec3 exponent = vec3(0.406, 0.508, 0.641);
	vec3 mu = sqrt(max(vec3(1.0) - r * r, vec3(0.0)));
	return pow(max(mu, vec3(1e-4)), exponent) * (exponent + 2.0) * 0.5;
}

float body_halo(vec3 view_direction, vec3 body_direction, float halo_size) {
	float alignment = dot(normalize(view_direction), normalize(body_direction));
	float angular_distance = acos(clamp(alignment, -1.0, 1.0));
	return 1.0 - smoothstep(0.0, halo_size, angular_distance);
}

/*
 * The moon's surface along a view ray as a share of the full moon's radiance: the
 * Lommel-Seeliger law of its dusty surface, 2 mu0 / (mu0 + mu) for the sun's cosine mu0
 * and the viewer's mu to the surface: flat at full moon, darkening only near the
 * terminator, 0 on the night side.
 */
float moon_lighting(vec3 view_direction, vec3 body_direction, vec3 light_direction, float disk_size) {
	vec3 moon_dir = normalize(body_direction);
	vec3 view_dir = unrefracted(view_direction, 1.0);
	vec3 sun_dir = normalize(light_direction);
	vec3 tangent_x = sun_dir - moon_dir * dot(sun_dir, moon_dir);
	float tangent_len = length(tangent_x);
	if (tangent_len < 0.0001) {
		tangent_x = cross(moon_dir, vec3(0.0, 1.0, 0.0));
		if (length(tangent_x) < 0.0001) {
			tangent_x = cross(moon_dir, vec3(1.0, 0.0, 0.0));
		}
		tangent_x = normalize(tangent_x);
	} else {
		tangent_x /= tangent_len;
	}
	vec3 tangent_y = normalize(cross(moon_dir, tangent_x));
	vec3 offset = view_dir - moon_dir * dot(view_dir, moon_dir);
	float x = dot(offset, tangent_x) / max(disk_size, 0.0001);
	float y = dot(offset, tangent_y) / max(disk_size, 0.0001);
	float radius_sq = clamp(x * x + y * y, 0.0, 1.0);
	float z = sqrt(1.0 - radius_sq);
	vec3 surface_normal = normalize(tangent_x * x + tangent_y * y - moon_dir * z);
	float mu0 = max(dot(surface_normal, sun_dir), 0.0);
	return 2.0 * mu0 / max(mu0 + z, 1e-4);
}

vec3 milky_way_radiance(vec3 direction, float lod) {
	vec3 equatorial = milky_way_basis * direction;
	vec2 uv = vec2(fract(atan(equatorial.y, equatorial.x) / (2.0 * PI)), 0.5 - asin(clamp(equatorial.z, -1.0, 1.0)) / PI);
	// Explicit LOD: the longitude wraps at the texture's edge.
	return textureLod(milky_way, uv, lod).rgb * milky_way_scale;
}

/*
 * Distance (m) along direction to where it enters the cloud layer: its base from below,
 * its top from above; 0 inside it, or for a ray from above that misses it.
 */
float cloud_distance(vec3 direction) {
	float h = atmosphere_observer.w;
	if (h < cloud_base_altitude) {
		return atmosphere_distance_to_altitude(direction, cloud_base_altitude);
	}
	if (h <= cloud_top_altitude) {
		return 0.0;
	}
	// From above: the nearer root of the top's sphere, if the ray meets it.
	float r = ATMOSPHERE_EARTH_RADIUS + h;
	float b = r * direction.y;
	float c = (h - cloud_top_altitude) * (2.0 * ATMOSPHERE_EARTH_RADIUS + h + cloud_top_altitude);
	float discriminant = b * b - c;
	return discriminant >= 0.0 && b < 0.0 ? c / (-b + sqrt(discriminant)) : 0.0;
}

void sky() {
	// A pixel's angular size (the radiance map's texels are far coarser: a soft edge there).
	float edge_size = AT_CUBEMAP_PASS ? max(sun_disk_size * 0.18, 0.0005) : max(length(fwidth(EYEDIR)), 1e-5);
	vec3 sun_r;
	vec3 sun_disk = body_disk(EYEDIR, sun_disk_direction, sun_disk_size, edge_size, sun_r);
	float sun_halo = body_halo(EYEDIR, sun_direction, sun_halo_size) * 0.32;
	vec3 moon_r;
	vec3 moon_disk = body_disk(EYEDIR, moon_disk_direction, moon_disk_size, edge_size, moon_r);
	float moon_halo = body_halo(EYEDIR, moon_direction, sun_halo_size) * 0.32;
	float moon_lit = moon_lighting(EYEDIR, moon_disk_direction, sun_disk_direction, moon_disk_size) * moon_surface_brightness + moon_earthshine;

	// The disks at their real radiance: the light's irradiance over the disk's solid
	// angle, far brighter than anything around them, the haze's glow included; that glow
	// is their halo (the atmosphere's forward lobe). The radiance map (ambient light and
	// reflections) keeps faint disks and halos instead (radiance_sun_*_strength times the
	// radiance of a white diffuser in their light): disks that bright would sparkle in
	// every glossy reflection.
	vec3 sun_disk_color = sun_irradiance / (PI * sun_disk_size * sun_disk_size) * sun_limb_darkening(sun_r);
	vec3 moon_disk_color = moon_irradiance / (PI * moon_disk_size * moon_disk_size);
	vec3 sun_halo_color = vec3(0.0);
	vec3 moon_halo_color = vec3(0.0);
	if (AT_CUBEMAP_PASS) {
		sun_disk_color = sun_irradiance / PI * radiance_sun_disk_strength;
		moon_disk_color = moon_irradiance / PI * radiance_sun_disk_strength;
		sun_halo_color = sun_irradiance / PI * radiance_sun_halo_strength;
		moon_halo_color = moon_irradiance * moon_surface_brightness / PI * radiance_sun_halo_strength * moon_phase;
	}
	// The camera's view needs no share above the horizon: the sea in front hides the rest,
	// and the last rim stays as bright as it is (the green flash). The radiance map has no
	// sea in front of it.
	float sun_shown = AT_CUBEMAP_PASS ? sun_visibility : 1.0;
	float moon_shown = AT_CUBEMAP_PASS ? moon_visibility : 1.0;
	vec3 space = sun_disk_color * sun_disk * sun_shown + sun_halo_color * sun_halo * sun_visibility
			+ moon_disk_color * moon_disk * moon_lit * moon_shown + moon_halo_color * moon_halo * moon_visibility;
	if (milky_way_scale > 0.0) {
		// The radiance map's faces are coarser than the texture: read a blurred mip.
		space += milky_way_radiance(EYEDIR, AT_CUBEMAP_PASS ? 2.0 : 0.0);
	}

	bool show_clouds = clouds_enabled && (AT_CUBEMAP_PASS || !screen_clouds);
	vec4 cloud = show_clouds ? textureLod(cloud_cubemap, EYEDIR, 0.0) : vec4(0.0);
	if (atmosphere_enabled) {
		// The camera's altitude comes from the atmosphere, not POSITION: a sky that reads
		// POSITION re-renders its radiance map whenever the camera moves (GRESkySystem
		// refreshes it instead, see _refresh_sky_radiance()). The atmosphere and the
		// clouds are pre-exposed; Godot exposes the sky's output itself.
		COLOR = atmosphere_sky_with_clouds(EYEDIR, cloud, cloud_distance(EYEDIR), space * atmosphere_exposure) / atmosphere_exposure;
		// Godot renders the radiance map exposed, then exposes the light it gives again
		// (Godot 4.8): the map gets the sky unexposed.
		if (AT_CUBEMAP_PASS) {
			COLOR /= atmosphere_exposure;
		}
	} else {
		COLOR = space * (1.0 - cloud.a) + cloud.rgb;
	}
}
