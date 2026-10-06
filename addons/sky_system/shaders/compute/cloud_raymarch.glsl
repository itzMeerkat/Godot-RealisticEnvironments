#[compute]
#version 450
/**
 * Raymarches the cloud layer into the upper half of a cubemap, as seen from the
 * camera. The sky, the starfield and the ocean's sky reflection sample that
 * cubemap, so clouds are rendered once for all of them.
 *
 * Each dispatch refreshes one texel of every stride x stride block
 * (pattern_offset picks which), so the whole cube is refreshed every stride^2
 * frames. A refreshed texel is blended with its previous value; together with
 * the per-frame jitter this averages several sub-texel rays.
 *
 * Output texel: rgb = in-scattered radiance (premultiplied), a = opacity, as
 * seen at the cloud: the atmosphere between the camera and the clouds is left
 * to the consumers (the sky splits its view volume at the cloud base, see
 * atmosphere.gdshaderinc). Without it they composite sky * (1 - a) + rgb.
 *
 * Light: the key light as it reaches the cloud layer (SkySystem dims it by the
 * atmosphere), and the sky's light at the layer from above and below
 * (AtmosphereRenderer.sky_ambient_buffer, binding 5).
 *
 * Droplet optics: Henyey-Greenstein phase (g = march.w, about 0.85) and the preset's
 * scattering albedo. The phase's forward peak (g^2 of it) sends light on almost
 * unchanged, so light transport sees the cloud thinner (delta-Eddington, transport
 * extinction (1 - albedo g^2) of the true one):
 *   single scattering: the key light down the light march, the true beam with the
 *     whole phase, and what the peak scattered on the way (the transport beam less
 *     the true one) with the phase's broad rest;
 *   every higher order: the delta-Eddington two-stream field of the local column
 *     (optical depth above and below the sample, measured straight up and down),
 *     lit by the key light and by the sky's light falling on its top and bottom;
 *   in-scatter reaches the camera through the transport extinction, and the sky
 *     behind the cloud that the peak scatters only slightly is added to it; the
 *     opacity is the true one (consumers show the sky and the sun's disk behind
 *     through it).
 * Checked against a Monte Carlo reference of uniform layers (optical depth 2-100, sun
 * 15-60 degrees, sky light): within about 0.8-1.3, except within a few degrees of the
 * sun behind thin cloud, where the glow comes out up to 4x too bright (the peak's small
 * deflections spread it there).
 *
 * The planet is a sphere (radius camera.w) with its surface at world y = 0;
 * the cloud layer is a spherical shell, which bends the layer down to the
 * horizon. The camera must be below the cloud base (CloudRenderer clamps it).
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict imageCube cloud_image;
layout(set = 0, binding = 1) uniform sampler3D shape_noise;
layout(set = 0, binding = 2) uniform sampler3D detail_noise;
layout(set = 0, binding = 3) uniform sampler2D weather_map;
layout(set = 0, binding = 4, std430) restrict readonly buffer Params {
	vec4 camera;          // xyz world position, w planet radius (m)
	vec4 layer;           // x base altitude, y top altitude, z max distance, w unused
	vec4 weather_area;    // xy map centre (world XZ), z map extent (m), w extinction at density 1 (1/m)
	vec4 motion;          // xy wind offset (world XZ, m), z evolution time, w sky light scale
	vec4 scales;          // x shape tile (m), y detail tile (m), z detail erosion, w scattering albedo
	vec4 light_direction; // xyz unit vector toward the key light (sun or moon)
	vec4 light_color;     // rgb key light at the cloud layer: irradiance / pi (the light's energy)
	vec4 march;           // x view steps, y light steps, z longest light march (m), w phase g
} params;
// AtmosphereRenderer.sky_ambient_buffer (atmosphere_ambient.glsl).
layout(set = 0, binding = 5, std430) restrict readonly buffer SkyAmbient {
	vec4 above; // rgb mean radiance of the sky above the layer
	vec4 below; // rgb mean radiance of the sky and sea below it
	vec4 irradiance; // unused here
} sky_ambient;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	ivec2 pattern_offset;
	int stride;
	int face_size;
	vec2 jitter;          // sub-texel ray offset, in texels
	float history_weight; // 0 replaces the texel
	float frame_seed;
} pc;

const int RENDERED_FACES[5] = int[](0, 1, 2, 4, 5); // every face but -Y
const float PI = 3.14159265359;
// Samples of the local column above and below a sample (cheap density).
const int COLUMN_STEPS_ABOVE = 3;
const int COLUMN_STEPS_BELOW = 2;

// Inverse of the cube face selection in the Vulkan spec; st in [-1, 1], t grows downward.
vec3 cube_direction(int face, vec2 st) {
	switch (face) {
		case 0: return vec3(1.0, -st.y, -st.x);
		case 1: return vec3(-1.0, -st.y, st.x);
		case 2: return vec3(st.x, 1.0, st.y);
		case 3: return vec3(st.x, -1.0, -st.y);
		case 4: return vec3(st.x, -st.y, 1.0);
		default: return vec3(-st.x, -st.y, -1.0);
	}
}

float remap(float value, float old_min, float old_max, float new_min, float new_max) {
	return new_min + (value - old_min) / (old_max - old_min) * (new_max - new_min);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Distances along a ray to the sphere at `altitude`, for a ray starting at
// `origin_altitude` whose direction makes cosine `mu` with the local up.
// Factored so that planet-sized radii keep their precision. far < 0: no hit.
vec2 shell_intersection(float origin_altitude, float mu, float altitude) {
	float planet_radius = params.camera.w;
	float b = (planet_radius + origin_altitude) * mu;
	float c = (origin_altitude - altitude) * (2.0 * planet_radius + origin_altitude + altitude);
	float discriminant = b * b - c;
	if (discriminant < 0.0) {
		return vec2(-1.0);
	}
	float s = sqrt(discriminant);
	return vec2(-b - s, -b + s);
}

// Altitude after distance t along a ray from origin_altitude with cosine mu.
float altitude_along_ray(float origin_altitude, float mu, float t) {
	float r0 = params.camera.w + origin_altitude;
	float q = t * (2.0 * r0 * mu + t); // r^2 - r0^2
	return origin_altitude + q / (sqrt(r0 * r0 + q) + r0);
}

vec4 sample_weather(vec2 world_xz) {
	vec2 uv = (world_xz - params.weather_area.xy) / params.weather_area.z + 0.5;
	return textureLod(weather_map, uv, 0.0);
}

// Fraction of the layer a cloud of this type fills: stratus stays low and
// thin, cumulonimbus reaches the top. Flat bases, rounded tops.
float height_gradient(float height_fraction, float cloud_type) {
	float top = mix(0.22, 1.0, cloud_type);
	float base = smoothstep(0.0, 0.06, height_fraction);
	float crown = 1.0 - smoothstep(top * 0.45, top, height_fraction);
	return base * crown;
}

// Cloud density (extinction multiplier) at a world point. `detailed` adds the
// erosion noise; light rays skip it beyond their first steps.
float cloud_density(vec3 world_position, float height_fraction, vec4 weather, bool detailed) {
	float coverage = weather.r;
	if (coverage <= 0.001 || height_fraction <= 0.0 || height_fraction >= 1.0) {
		return 0.0;
	}
	vec3 drift = vec3(params.motion.x, 0.0, params.motion.y);
	float evolution = params.motion.z;
	// Rising sample position: cloud features slowly climb through the body.
	vec3 shape_position = (world_position - drift) / params.scales.x - vec3(0.0, evolution * 0.6, 0.0);
	float base = textureLod(shape_noise, shape_position, 0.0).r * height_gradient(height_fraction, weather.g);
	float covered = clamp(remap(base, 1.0 - coverage, 1.0, 0.0, 1.0), 0.0, 1.0) * coverage;
	if (covered <= 0.0) {
		return 0.0;
	}
	if (detailed) {
		vec3 detail_position = (world_position - drift) / params.scales.y - vec3(0.0, evolution * 4.0, 0.0);
		float detail = textureLod(detail_noise, detail_position, 0.0).r;
		// Wispy at the base, billowy higher up.
		float modifier = mix(detail, 1.0 - detail, clamp(height_fraction * 4.0, 0.0, 1.0));
		covered = clamp(remap(covered, modifier * params.scales.z, 1.0, 0.0, 1.0), 0.0, 1.0);
	}
	return covered * weather.b;
}

// Henyey-Greenstein phase function (1/sr).
float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 1.0e-6), 1.5));
}

float layer_fraction(float altitude) {
	return (altitude - params.layer.x) / (params.layer.y - params.layer.x);
}

// Optical depth toward the key light up to the top of the cloud layer (at most
// march.z away), with steps growing along the ray.
float light_optical_depth(vec3 world_position, float altitude) {
	vec3 light_direction = params.light_direction.xyz;
	int steps = int(params.march.y);
	float distance_to_top = min((params.layer.y - altitude) / max(light_direction.y, 0.05), params.march.z);
	// Segments 1, 2, ..., steps times this add up to the distance.
	float step_length = distance_to_top / (0.5 * float(steps * (steps + 1)));
	float travelled = 0.0;
	float optical_depth = 0.0;
	for (int i = 0; i < steps; i++) {
		float segment = step_length * float(i + 1);
		float along = travelled + segment * 0.5;
		float sample_altitude = altitude + light_direction.y * along;
		float height_fraction = layer_fraction(sample_altitude);
		if (height_fraction >= 1.0 || height_fraction <= 0.0) {
			break;
		}
		vec3 sample_position = world_position + light_direction * along;
		sample_position.y = sample_altitude;
		optical_depth += cloud_density(sample_position, height_fraction, sample_weather(sample_position.xz), i < 2) * segment;
		travelled += segment;
	}
	return optical_depth * params.weather_area.w;
}

/*
 * Optical depth of the local column straight above a sample (up to the cloud top) and
 * below it (down to the layer's base): the slab the two-stream field is solved in.
 */
vec2 column_optical_depths(vec3 world_position, float altitude, float cloud_top, vec4 weather) {
	float extinction = params.weather_area.w;
	float above = 0.0;
	float span = max(cloud_top - altitude, 0.0) / float(COLUMN_STEPS_ABOVE);
	for (int i = 0; i < COLUMN_STEPS_ABOVE; i++) {
		float sample_altitude = altitude + span * (float(i) + 0.5);
		vec3 sample_position = vec3(world_position.x, sample_altitude, world_position.z);
		above += cloud_density(sample_position, layer_fraction(sample_altitude), weather, false) * span;
	}
	float below = 0.0;
	span = max(altitude - params.layer.x, 0.0) / float(COLUMN_STEPS_BELOW);
	for (int i = 0; i < COLUMN_STEPS_BELOW; i++) {
		float sample_altitude = params.layer.x + span * (float(i) + 0.5);
		vec3 sample_position = vec3(world_position.x, sample_altitude, world_position.z);
		below += cloud_density(sample_position, layer_fraction(sample_altitude), weather, false) * span;
	}
	return vec2(above, below) * extinction;
}

/*
 * The delta-Eddington two-stream field (Joseph, Wiscombe and Weinman 1976) at optical
 * depth tau from the top of a slab of optical depth tau_total (both transport-scaled,
 * scattering albedo omega and phase g of the scaled medium), lit by the sun (flux 1 on
 * a surface facing it, cosine mu0 to the up) and by isotropic radiance 1 falling on
 * the top and on the bottom. Returns the radiance each source scatters toward a
 * direction going down with cosine mu_v, per unit of scaled extinction: x sun, y top,
 * z bottom.
 */
vec3 two_stream(float tau_total, float tau, float mu0, float mu_v, float omega, float g) {
	float a = 1.0 - omega * g;
	float b = 3.0 * (1.0 - omega);
	// A floor on the decay rate keeps the system well conditioned for conservative scattering.
	float k = max(sqrt(a * b), 0.01);
	float p = -k / a;
	// Particular solution for the sun: I0 = alpha e, I1 = beta e, e = exp(-tau / mu0).
	float c = 3.0 * omega / (4.0 * PI);
	float d = c * g * mu0;
	float det = a * b - 1.0 / (mu0 * mu0);
	float alpha = (a * c + d / mu0) / det;
	float beta = (c / mu0 + b * d) / det;
	// Homogeneous part I0 = A' e^{k (tau - T)} + B e^{-k tau}, I1 = p (A' e^{k (tau - T)} - B e^{-k tau}),
	// boundaries: diffuse flux in at the top (I0 + 2/3 I1) and at the bottom (I0 - 2/3 I1).
	float e_kt = exp(-k * tau_total);
	float m00 = e_kt * (1.0 + 2.0 / 3.0 * p);
	float m01 = 1.0 - 2.0 / 3.0 * p;
	float inverse_det = 1.0 / (m00 * m00 - m01 * m01);
	float e_top = exp(-tau_total / mu0);
	vec3 rhs_top = vec3(-(alpha + 2.0 / 3.0 * beta), 1.0, 0.0);
	vec3 rhs_bottom = vec3(-(alpha - 2.0 / 3.0 * beta) * e_top, 0.0, 1.0);
	vec3 coefficient_a = (m00 * rhs_top - m01 * rhs_bottom) * inverse_det;
	vec3 coefficient_b = (m00 * rhs_bottom - m01 * rhs_top) * inverse_det;
	float rising = exp(k * (tau - tau_total));
	float falling = exp(-k * tau);
	float e = exp(-tau / mu0);
	vec3 i0 = coefficient_a * rising + coefficient_b * falling + vec3(alpha * e, 0.0, 0.0);
	vec3 i1 = p * (coefficient_a * rising - coefficient_b * falling) + vec3(beta * e, 0.0, 0.0);
	return omega * max(i0 + g * mu_v * i1, vec3(0.0));
}

vec4 march_clouds(vec3 direction, vec2 noise_position) {
	float camera_altitude = params.camera.y;
	float base_altitude = params.layer.x;
	float top_altitude = params.layer.y;
	float mu = direction.y;

	// A ray that meets the sea first sees no cloud.
	vec2 ground = shell_intersection(camera_altitude, mu, 0.0);
	if (ground.x > 0.0) {
		return vec4(0.0);
	}
	float t_start = shell_intersection(camera_altitude, mu, base_altitude).y;
	float t_end = min(shell_intersection(camera_altitude, mu, top_altitude).y, params.layer.z);
	if (t_start >= t_end) {
		return vec4(0.0);
	}

	// Steps are spaced quadratically: short near the cloud base, where the
	// detail is, long far away. The whole pattern is jittered per texel and frame.
	int steps = int(params.march.x);
	float path = t_end - t_start;
	float jitter = hash12(noise_position + pc.frame_seed);

	vec3 light_direction = params.light_direction.xyz;
	// Irradiance on a surface facing the light.
	vec3 light_flux = params.light_color.rgb * PI;
	vec3 sky_above = sky_ambient.above.rgb * params.motion.w;
	vec3 sky_below = sky_ambient.below.rgb * params.motion.w;
	float cos_theta = dot(direction, light_direction);
	float g = params.march.w;
	float extinction = params.weather_area.w;
	float albedo = params.scales.w;
	float planet_radius = params.camera.w;
	// Delta-Eddington: the peak's share, the transport extinction's share and the scaled medium.
	float peak = g * g;
	float transport_share = 1.0 - albedo * peak;
	float scaled_albedo = (1.0 - peak) * albedo / transport_share;
	float scaled_g = g / (1.0 + g);
	float phase = henyey_greenstein(cos_theta, g);
	float phase_rest = (1.0 - peak) * henyey_greenstein(cos_theta, scaled_g);
	float mu0 = max(light_direction.y, 0.05);
	// The camera sees light going down toward it.
	float mu_view = max(direction.y, 0.0);

	vec3 radiance = vec3(0.0);
	float transmittance = 1.0;
	float transport = 1.0;
	for (int i = 0; i < steps; i++) {
		float x = (float(i) + jitter) / float(steps);
		float t = t_start + path * x * x;
		float step_length = path * (2.0 * x + 1.0 / float(steps)) / float(steps);
		float altitude = altitude_along_ray(camera_altitude, mu, t);
		float height_fraction = layer_fraction(altitude);
		vec2 world_xz = params.camera.xz + direction.xz * t;
		vec4 weather = sample_weather(world_xz);
		vec3 world_position = vec3(world_xz.x, altitude, world_xz.y);
		float density = cloud_density(world_position, height_fraction, weather, true);
		if (density > 0.0) {
			float sigma_t = density * extinction;
			float light_depth = light_optical_depth(world_position, altitude);
			float cloud_top = params.layer.x + (params.layer.y - params.layer.x) * mix(0.22, 1.0, weather.g);
			vec2 column = column_optical_depths(world_position, altitude, cloud_top, weather);

			// The planet's shadow: clouds stay lit for a while after sunset.
			vec3 local_up = normalize(vec3(direction.x * t, planet_radius + camera_altitude + direction.y * t, direction.z * t));
			float sample_radius = planet_radius + altitude;
			float horizon_mu = -sqrt(max(altitude * (2.0 * planet_radius + altitude), 0.0)) / sample_radius;
			float light_visibility = smoothstep(horizon_mu - 0.01, horizon_mu + 0.01, dot(local_up, light_direction));

			vec3 sun = light_flux * light_visibility;
			// Single scattering, per unit of true extinction.
			float beam = exp(-light_depth);
			float beam_transport = exp(-light_depth * transport_share);
			vec3 source = sun * (albedo * (beam * phase + (beam_transport - beam) * phase_rest));
			// Every higher order: the two-stream field of the column, per unit of true extinction.
			vec3 field = two_stream((column.x + column.y) * transport_share, column.x * transport_share, mu0, mu_view, scaled_albedo, scaled_g);
			source += transport_share * (sun * field.x + sky_above * field.y + sky_below * field.z);

			// Integrated over the step through the transport extinction.
			float step_transport = exp(-sigma_t * transport_share * step_length);
			radiance += transport * source * (1.0 - step_transport) / transport_share;
			transport *= step_transport;
			transmittance *= exp(-sigma_t * step_length);
			if (transport < 0.01) {
				break;
			}
		}
	}

	// The sky behind, scattered on by the peak only: it arrives as if through the gaps.
	radiance += (transport - transmittance) * sky_above;
	// What is left is taken as opaque: the sun disk behind is so bright that even 1 %
	// of it would show through as a bright spot.
	if (transmittance < 0.01) {
		transmittance = 0.0;
	}
	return vec4(radiance, 1.0 - transmittance);
}

void main() {
	int face = RENDERED_FACES[gl_GlobalInvocationID.z];
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy) * pc.stride + pc.pattern_offset;
	if (any(greaterThanEqual(texel, ivec2(pc.face_size)))) {
		return;
	}
	// Side faces: only the rows above the horizon, plus one for filtering.
	if (face != 2 && texel.y > pc.face_size / 2 + 1) {
		return;
	}
	vec2 st = (vec2(texel) + 0.5 + pc.jitter) / float(pc.face_size) * 2.0 - 1.0;
	vec3 direction = normalize(cube_direction(face, st));
	vec4 cloud = march_clouds(direction, vec2(texel) + vec2(float(face) * 1031.0, 0.0));
	ivec3 coordinate = ivec3(texel, face);
	vec4 history = imageLoad(cloud_image, coordinate);
	imageStore(cloud_image, coordinate, mix(cloud, history, pc.history_weight));
}
