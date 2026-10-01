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
 * Output texel: rgb = in-scattered radiance (premultiplied), a = opacity.
 * Both are already faded by aerial perspective, so the sky composites with
 * sky * (1 - a) + rgb.
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
	vec4 layer;           // x base altitude, y top altitude, z max distance, w aerial-perspective distance (m)
	vec4 weather_area;    // xy map centre (world XZ), z map extent (m), w extinction at density 1 (1/m)
	vec4 motion;          // xy wind offset (world XZ, m), z evolution time, w unused
	vec4 scales;          // x shape tile (m), y detail tile (m), z detail erosion, w scattering albedo
	vec4 light_direction; // xyz unit vector toward the key light (sun or moon)
	vec4 light_color;     // rgb key light radiance
	vec4 ambient_top;     // rgb ambient light at the top of the layer
	vec4 ambient_bottom;  // rgb ambient light at the base of the layer
	vec4 march;           // x view steps, y light steps, z first light step (m), w forward phase g
} params;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	ivec2 pattern_offset;
	int stride;
	int face_size;
	vec2 jitter;          // sub-texel ray offset, in texels
	float history_weight; // 0 replaces the texel
	float frame_seed;
} pc;

const int RENDERED_FACES[5] = int[](0, 1, 2, 4, 5); // every face but -Y
// Two-stream diffusion constant, about 0.75 (1 - g) for cloud droplets.
const float DIFFUSION = 0.15;
// Share of the key light that enters the cloud tops as diffuse light.
const float SUN_DIFFUSE = 0.5;

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

// Henyey-Greenstein, scaled so that an isotropic phase is 1.
float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cos_theta, 1.0e-4), 1.5);
}

float cloud_phase(float cos_theta, float g) {
	return mix(henyey_greenstein(cos_theta, g), henyey_greenstein(cos_theta, -0.25 * g), 0.3);
}

float layer_fraction(float altitude) {
	return (altitude - params.layer.x) / (params.layer.y - params.layer.x);
}

// Optical depth toward the key light, with steps growing along the ray.
float light_optical_depth(vec3 world_position, float altitude) {
	vec3 light_direction = params.light_direction.xyz;
	int steps = int(params.march.y);
	float step_length = params.march.z;
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
	vec3 light_color = params.light_color.rgb;
	float cos_theta = dot(direction, light_direction);
	float g = params.march.w;
	float extinction = params.weather_area.w;
	float albedo = params.scales.w;
	float planet_radius = params.camera.w;

	vec3 radiance = vec3(0.0);
	float transmittance = 1.0;
	float weighted_depth = 0.0;
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

			// The planet's shadow: clouds stay lit for a while after sunset.
			vec3 local_up = normalize(vec3(direction.x * t, planet_radius + camera_altitude + direction.y * t, direction.z * t));
			float sample_radius = planet_radius + altitude;
			float horizon_mu = -sqrt(max(altitude * (2.0 * planet_radius + altitude), 0.0)) / sample_radius;
			float light_visibility = smoothstep(horizon_mu - 0.01, horizon_mu + 0.01, dot(local_up, light_direction));

			// Multiple scattering approximated by octaves of ever weaker
			// attenuation and flatter phase.
			float scattering = 0.0;
			float octave_weight = 1.0;
			float octave_attenuation = 1.0;
			float octave_g = 1.0;
			for (int octave = 0; octave < 3; octave++) {
				scattering += octave_weight * cloud_phase(cos_theta, g * octave_g) * exp(-light_depth * octave_attenuation);
				octave_weight *= 0.5;
				octave_attenuation *= 0.35;
				octave_g *= 0.5;
			}
			// Light from above (sky, plus sunlight diffused through the cloud)
			// crosses the cloud column over the sample. Multiple scattering makes
			// that falloff close to two-stream diffusion, 1 / (1 + k tau), rather
			// than exp(-tau): thin cloud stays bright, deep storm bases go dark.
			float cloud_top = params.layer.x + (params.layer.y - params.layer.x) * mix(0.22, 1.0, weather.g);
			float column_depth = sigma_t * max(cloud_top - altitude, 0.0);
			float diffuse_transmission = 1.0 / (1.0 + DIFFUSION * column_depth);
			vec3 light_from_above = params.ambient_top.rgb + light_color * (SUN_DIFFUSE * light_visibility * max(light_direction.y, 0.0));
			// Light from below (sea, horizon glow) fades as the cover closes.
			vec3 light_from_below = params.ambient_bottom.rgb * (1.0 - clamp(height_fraction, 0.0, 1.0)) * (1.0 - 0.75 * weather.r);
			vec3 ambient = light_from_above * diffuse_transmission + light_from_below;
			vec3 source = albedo * (light_color * scattering * light_visibility + ambient);

			// Energy-conserving integration over the step.
			float step_transmittance = exp(-sigma_t * step_length);
			radiance += transmittance * source * (1.0 - step_transmittance);
			float next_transmittance = transmittance * step_transmittance;
			weighted_depth += t * (transmittance - next_transmittance);
			transmittance = next_transmittance;
			if (transmittance < 0.01) {
				break;
			}
		}
	}

	float opacity = 1.0 - transmittance;
	if (opacity <= 0.0) {
		return vec4(0.0);
	}
	// Aerial perspective: distant clouds dissolve into the sky behind them.
	float depth = weighted_depth / opacity;
	float fade = exp(-depth / params.layer.w);
	return vec4(radiance * fade, opacity * fade);
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
