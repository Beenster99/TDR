shader_type spatial;
// Grandstand seating: rows of brightly dressed spectators (random dots).
uniform float fill = 0.75;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec2 cell = floor(wp.xz / 0.55);
	float r = hash(cell);
	vec3 seat = vec3(0.16, 0.28, 0.55);
	vec3 shirt = vec3(hash(cell + 3.1), hash(cell + 7.7), hash(cell + 1.3));
	shirt = mix(shirt, vec3(0.9, 0.15, 0.1), step(0.75, hash(cell + 9.0)));
	vec2 f = fract(wp.xz / 0.55) - 0.5;
	float body = 1.0 - smoothstep(0.26, 0.32, length(f));
	vec3 c = mix(seat, shirt * 0.9 + 0.05, body * step(r, fill));
	ALBEDO = c;
	ROUGHNESS = 0.9;
}
