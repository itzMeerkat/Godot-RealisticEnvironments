// The atmosphere seen from the camera, for Godot shaders: SkySystem's AtmosphereRenderer
// builds the camera's view volume once per frame and publishes it through these global
// uniforms (declared in project.godot [shader_globals], see the sky_system README).
//
// atmosphere_view_uvw() and the phase are copies of shaders/compute/atmosphere_common.glslinc
// (also copied into the ocean's water.gdshader). Change them together.

#define ATMOSPHERE_PI 3.14159265359
#define ATMOSPHERE_EARTH_RADIUS 6371000.0

// False until a SkySystem renders the atmosphere; then nothing below is valid.
global uniform bool atmosphere_enabled;
// View volume (AtmosphereRenderer.view_*): rgb transmittance, rgb isotropic in-scatter,
// rgb in-scatter of the haze's forward lobe per unit phase function.
global uniform sampler3D atmosphere_view_transmittance;
global uniform sampler3D atmosphere_view_inscatter;
global uniform sampler3D atmosphere_view_inscatter_lobe;
// World position of the observer the volume was built for, and (w) its altitude above
// the sea as the volume uses it.
global uniform vec4 atmosphere_observer;
// xyz toward the key light, w the Henyey-Greenstein g of the haze's forward lobe.
global uniform vec4 atmosphere_light;
// Distance (m) of the volume's last regular slice.
global uniform float atmosphere_max_distance;
// The camera's exposure (CameraAttributes.exposure_multiplier) the in-scatter is stored
// at: pre-exposed like Godot's colour buffer, as are the clouds. FOG and the colour
// buffer take it as is; anything Godot exposes itself (sky, EMISSION) divides by it.
global uniform float atmosphere_exposure;

float atmosphere_unit_to_uv(float x, float n) {
	return 0.5 / n + x * (1.0 - 1.0 / n);
}

float atmosphere_horizon_mu(float h) {
	float hh = max(h, 0.0);
	return -sqrt(hh * (2.0 * ATMOSPHERE_EARTH_RADIUS + hh)) / (ATMOSPHERE_EARTH_RADIUS + hh);
}

float atmosphere_view_y(float h, float mu) {
	float horizon_mu = atmosphere_horizon_mu(h);
	float beta = acos(clamp(-horizon_mu, -1.0, 1.0));
	float zenith_horizon = ATMOSPHERE_PI - beta;
	float zenith = acos(clamp(mu, -1.0, 1.0));
	if (zenith < zenith_horizon) {
		return 0.5 * (1.0 - sqrt(max(1.0 - zenith / zenith_horizon, 0.0)));
	}
	return 0.5 + 0.5 * sqrt(clamp((zenith - zenith_horizon) / max(beta, 1e-6), 0.0, 1.0));
}

float atmosphere_view_x(vec3 direction, vec3 light_direction) {
	float d = length(direction.xz);
	float l = length(light_direction.xz);
	float cos_phi = d > 1e-5 && l > 1e-5 ? dot(direction.xz, light_direction.xz) / (d * l) : 1.0;
	return acos(clamp(cos_phi, -1.0, 1.0)) / ATMOSPHERE_PI;
}

/* View-volume coordinates; distance < 0 is the ray's end (the sky). */
vec3 atmosphere_view_uvw(vec3 direction, float distance, vec3 size) {
	float x = atmosphere_unit_to_uv(atmosphere_view_x(direction, atmosphere_light.xyz), size.x);
	float y = clamp(atmosphere_view_y(atmosphere_observer.w, direction.y), 0.5 / size.y, 1.0 - 0.5 / size.y);
	float slice = distance < 0.0 ? size.z - 1.0 : sqrt(clamp(distance / atmosphere_max_distance, 0.0, 1.0)) * (size.z - 2.0);
	return vec3(x, y, (slice + 0.5) / size.z);
}

float atmosphere_henyey_greenstein(float cos_theta, float g) {
	float denominator = 1.0 + g * g - 2.0 * g * cos_theta;
	return (1.0 - g * g) / (4.0 * ATMOSPHERE_PI * denominator * sqrt(denominator));
}

/*
 * The atmosphere between the observer and a point `distance` meters along direction
 * (a unit world vector from atmosphere_observer.xyz); distance < 0 looks past
 * everything to the sky. Composite: background * transmittance + inscatter.
 */
void atmosphere_along(vec3 direction, float distance, out vec3 transmittance, out vec3 inscatter) {
	vec3 uvw = atmosphere_view_uvw(direction, distance, vec3(textureSize(atmosphere_view_transmittance, 0)));
	transmittance = textureLod(atmosphere_view_transmittance, uvw, 0.0).rgb;
	float phase = atmosphere_henyey_greenstein(dot(direction, atmosphere_light.xyz), atmosphere_light.w);
	inscatter = textureLod(atmosphere_view_inscatter, uvw, 0.0).rgb + textureLod(atmosphere_view_inscatter_lobe, uvw, 0.0).rgb * phase;
}

/*
 * Distance (m) from the observer along direction to the sphere at altitude (m) above
 * the sea, ahead of the observer; 0 when the observer is at or above it.
 */
float atmosphere_distance_to_altitude(vec3 direction, float altitude) {
	float h = atmosphere_observer.w;
	if (h >= altitude) {
		return 0.0;
	}
	float c = (altitude - h) * (2.0 * ATMOSPHERE_EARTH_RADIUS + altitude + h);
	float b = (ATMOSPHERE_EARTH_RADIUS + h) * direction.y;
	float root = sqrt(b * b + c);
	return direction.y >= 0.0 ? c / max(b + root, 1e-6) : root - b;
}

/*
 * What the observer sees along direction with clouds in the way: the atmosphere up to
 * the clouds, the cloud (rgb premultiplied radiance, a opacity, as seen at the cloud)
 * at cloud_distance, and behind it the rest of the atmosphere and space (radiance
 * arriving from beyond the atmosphere: the sun and moon disks, nothing else). Pre-exposed
 * (atmosphere_exposure), like the in-scatter and the clouds: space too.
 */
vec3 atmosphere_sky_with_clouds(vec3 direction, vec4 cloud, float cloud_distance, vec3 space) {
	vec3 transmittance_end;
	vec3 inscatter_end;
	atmosphere_along(direction, -1.0, transmittance_end, inscatter_end);
	if (cloud.a <= 0.0) {
		return inscatter_end + transmittance_end * space;
	}
	vec3 transmittance_cloud;
	vec3 inscatter_cloud;
	atmosphere_along(direction, cloud_distance, transmittance_cloud, inscatter_cloud);
	// Behind the cloud: the atmosphere from the cloud to the ray's end, then space.
	return inscatter_cloud + transmittance_cloud * cloud.rgb
			+ (1.0 - cloud.a) * (inscatter_end - inscatter_cloud + transmittance_end * space);
}

/*
 * Aerial perspective for a spatial shader's FOG output, at a world position: Godot
 * blends the lit color toward FOG.rgb by FOG.a, after lighting and before alpha
 * blending, so transparent surfaces are hazed for their own distance. FOG.a uses the
 * mean transmittance: exact for grey haze, a little off in hue where the air's blue
 * colours it (far away). Transparent materials call it; opaque ones are hazed by
 * AerialPerspectiveEffect and must not.
 */
vec4 atmosphere_fog(vec3 world_position) {
	if (!atmosphere_enabled) {
		return vec4(0.0);
	}
	vec3 offset = world_position - atmosphere_observer.xyz;
	float distance = length(offset);
	if (distance < 1e-3) {
		return vec4(0.0);
	}
	vec3 transmittance;
	vec3 inscatter;
	atmosphere_along(offset / distance, distance, transmittance, inscatter);
	float opacity = 1.0 - dot(transmittance, vec3(1.0 / 3.0));
	return opacity > 1e-5 ? vec4(inscatter / opacity, opacity) : vec4(0.0);
}
