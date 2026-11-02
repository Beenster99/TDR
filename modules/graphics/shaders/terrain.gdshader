shader_type spatial;
// Grass around the circuit: colour noise, mown stripes near the track,
// optional hillshade boost for elevation.
//   COLOR.r : 1 near the track (mown stripes), 0 far away (rougher meadow)

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform vec3 grass : source_color = vec3(0.23, 0.38, 0.15);
uniform vec3 grass_dry : source_color = vec3(0.42, 0.42, 0.22);
uniform float dryness = 0.25;
uniform float hillshade = 0.0;
uniform vec3 light_dir = vec3(0.5, 0.6, 0.6);
uniform float wetness = 0.0;
uniform float stripe_angle = 0.0;
// Real ground from map data (Scenery): RGB colour, A how much it replaces the grass.
uniform sampler2D ground_map : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 ground_rect = vec4(0.0, 0.0, 1.0, 1.0);   // origin x, y and size in metres
uniform float ground_on = 0.0;

varying vec3 wn;
varying vec3 wp;

void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wp.xz;
	float n1 = texture(noise, p * 0.004).r;
	float n2 = texture(noise, p * 0.03).r;
	float n3 = texture(noise, p * 0.4).r;
	vec3 c = mix(grass, grass_dry, clamp(dryness + (n1 - 0.5) * 0.9, 0.0, 1.0));
	c *= 0.82 + 0.3 * n2;
	c *= 0.92 + 0.12 * n3;
	// mown stripes close to the circuit
	vec2 dir = vec2(cos(stripe_angle), sin(stripe_angle));
	float st = step(0.5, fract(dot(p, dir) / 16.0));
	c *= 1.0 + COLOR.r * (st * 0.09 - 0.03);
	if (ground_on > 0.0) {
		vec2 guv = (p - ground_rect.xy) / ground_rect.zw;
		if (guv.x >= 0.0 && guv.y >= 0.0 && guv.x <= 1.0 && guv.y <= 1.0) {
			vec4 g = texture(ground_map, guv);
			// keep some texture from the noise so fields and car parks aren't flat paint
			vec3 gc = g.rgb * (0.86 + 0.24 * n2) * (0.94 + 0.1 * n3);
			c = mix(c, gc, g.a);
		}
	}
	vec3 L = normalize(light_dir);
	c *= clamp(1.0 + hillshade * (dot(normalize(wn), L) - L.y), 0.55, 1.5);
	c *= 1.0 - 0.2 * wetness;
	ALBEDO = c;
	ROUGHNESS = mix(0.95, 0.6, wetness);
	SPECULAR = 0.3;
}
