shader_type spatial;
// The ground around the circuit.
//
// Two kinds of mesh use it:
//  - the terrain itself (TrackView): grass with colour noise, mown stripes
//    near the track (COLOR.r : 1 near the track, 0 far away);
//  - the real land cover laid over it (Scenery, instance uniform drape = 1):
//    fields, woods, roads, car parks, water... modelled from map data, one
//    kind per triangle (COLOR.g = kind / 255, COLOR.b = variant / 255).
//    Their vertices come flat (y = 0) and are laid on the terrain here, on
//    exactly the terrain mesh's triangles, so they hug the hillside.
// Every surface's detail is drawn from world position (crop rows, tarmac
// grain, slab joints, ripples), so it stays sharp at any zoom.

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform vec3 grass : source_color = vec3(0.23, 0.38, 0.15);
uniform vec3 grass_dry : source_color = vec3(0.42, 0.42, 0.22);
uniform float dryness = 0.25;
uniform float hillshade = 0.0;
uniform vec3 light_dir = vec3(0.5, 0.6, 0.6);
uniform float wetness = 0.0;
uniform float stripe_angle = 0.0;
// The terrain grid's heights (TrackView), row by row: point (i, j) is at
// grid_origin + (i, j) * grid_cell.
uniform sampler2D heights : filter_nearest, repeat_disable;
uniform vec2 grid_origin = vec2(0.0);
uniform float grid_cell = 10.0;
uniform ivec2 grid_n = ivec2(0);
instance uniform float drape = 0.0;

// Keep in step with KINDS in tools/build_scenery.py.
const int K_GRASS = 0;
const int K_FIELD = 1;
const int K_MEADOW = 2;
const int K_SCRUB = 3;
const int K_WOOD = 4;
const int K_RESIDENTIAL = 5;
const int K_INDUSTRIAL = 6;
const int K_FARMYARD = 7;
const int K_WATER = 8;
const int K_SAND = 9;
const int K_DIRT = 10;
const int K_ASPHALT = 11;
const int K_PARKING = 12;
const int K_PARKING_GRASS = 13;
const int K_BAY_LINE = 14;
const int K_ROAD = 15;
const int K_ROAD_LINE = 16;
const int K_PATH = 17;
const int K_TRACK_DIRT = 18;
const int K_RACEWAY = 19;
const int K_HEDGE = 20;
const int K_FOOTPRINT = 21;
const int K_PITCH = 22;
const int K_ROAD_DASH = 23;

const float LIFT = 0.06;   // land cover sits this far above the grass

varying vec3 wn;
varying vec3 wp;
varying flat int kind;
varying flat int variant;

float h_at(ivec2 c) {
	return texelFetch(heights, clamp(c, ivec2(0), grid_n - 1), 0).r;
}

vec3 n_at(ivec2 c) {
	float l = h_at(c - ivec2(1, 0));
	float r = h_at(c + ivec2(1, 0));
	float d = h_at(c - ivec2(0, 1));
	float u = h_at(c + ivec2(0, 1));
	return normalize(vec3(l - r, 2.0 * grid_cell, d - u));
}

void vertex() {
	kind = 0;
	variant = 0;
	if (grid_n.x > 1) {
		vec2 g = (VERTEX.xz - grid_origin) / grid_cell;
		if (drape > 0.5) {
			// lay it on the terrain triangle it falls in: (a, b, c) or (b, d, c)
			ivec2 c = clamp(ivec2(floor(g)), ivec2(0), grid_n - 2);
			vec2 f = clamp(g - vec2(c), 0.0, 1.0);
			ivec2 ia = c, ib = c + ivec2(1, 0), ic = c + ivec2(0, 1), id = c + ivec2(1, 1);
			float y;
			vec3 n;
			if (f.x + f.y <= 1.0) {
				float a = h_at(ia);
				vec3 na = n_at(ia);
				y = a + (h_at(ib) - a) * f.x + (h_at(ic) - a) * f.y;
				n = na + (n_at(ib) - na) * f.x + (n_at(ic) - na) * f.y;
			} else {
				float d = h_at(id);
				vec3 nd = n_at(id);
				y = d + (h_at(ic) - d) * (1.0 - f.x) + (h_at(ib) - d) * (1.0 - f.y);
				n = nd + (n_at(ic) - nd) * (1.0 - f.x) + (n_at(ib) - nd) * (1.0 - f.y);
			}
			VERTEX.y = y + LIFT;
			NORMAL = normalize(n);
			kind = int(round(COLOR.g * 255.0));
			variant = int(round(COLOR.b * 255.0));
		} else {
			// the terrain's own grid points: the same normals as the land on top
			NORMAL = n_at(ivec2(round(g)));
		}
	}
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float nz(vec2 p, float s) {
	return texture(noise, p * s).r;
}

// How much fine detail of this size (metres) survives at this zoom (fades out
// before it would shimmer).
float detail(vec2 p, float size) {
	float px = length(fwidth(p));
	return 1.0 - smoothstep(size * 0.25, size * 0.6, px);
}

// Parallel rows across a field: returns the ridge height (-1..1) and its
// slope along `across` (for lighting), fading out when too small to see.
vec2 rows(vec2 p, vec2 across, float spacing) {
	float u = dot(p, across) / spacing;
	float k = detail(p, spacing);
	return vec2(sin(u * 6.2832), cos(u * 6.2832) * 6.2832 / spacing) * k;
}

vec3 field_colour(int v) {
	int c = v % 7;
	if (c == 0) return vec3(0.42, 0.33, 0.23);   // ploughed
	if (c == 1) return vec3(0.41, 0.44, 0.23);   // young wheat
	if (c == 2) return vec3(0.6, 0.53, 0.33);    // ripe barley
	if (c == 3) return vec3(0.54, 0.46, 0.31);   // stubble
	if (c == 4) return vec3(0.33, 0.4, 0.2);     // beans
	if (c == 5) return vec3(0.45, 0.48, 0.26);   // grass ley
	return vec3(0.49, 0.42, 0.29);               // harrowed
}

void fragment() {
	vec2 p = wp.xz;
	float n1 = nz(p, 0.004);
	float n2 = nz(p, 0.03);
	float n3 = nz(p, 0.4);
	float n4 = nz(p, 2.3);   // grain (gravel, tarmac)
	vec3 c = mix(grass, grass_dry, clamp(dryness + (n1 - 0.5) * 0.9, 0.0, 1.0));
	c *= 0.82 + 0.3 * n2;
	c *= 0.92 + 0.12 * n3;
	float rough = 0.95;
	float spec = 0.3;
	vec2 bump = vec2(0.0);   // world-space slope (x, z) of fine relief
	float wet_k = 1.0;
	if (kind == K_GRASS) {
		// mown stripes close to the circuit
		vec2 dir = vec2(cos(stripe_angle), sin(stripe_angle));
		float st = step(0.5, fract(dot(p, dir) / 16.0));
		c *= 1.0 + COLOR.r * (st * 0.09 - 0.03);
	} else {
		// land colours below are written in sRGB (like a paint chart); the
		// grass they sometimes start from is turned into sRGB first
		c = pow(c, vec3(1.0 / 2.2));
		float ang = float(variant >> 3) * (3.14159 / 32.0);
		vec2 along = vec2(cos(ang), sin(ang));
		vec2 across = vec2(-along.y, along.x);
		if (kind == K_FIELD) {
			vec3 fc = field_colour(variant);
			fc *= 0.86 + 0.24 * n2;
			fc *= 0.93 + 0.12 * n3;
			// crop rows every 0.75 m, with real relief under the sun
			vec2 r = rows(p, across, 0.75);
			bump += across * r.y * 0.05;
			fc *= 1.0 + r.x * 0.07;
			// tramlines every 24 m: two bare wheel tracks
			float t = abs(fract(dot(p, across) / 24.0 + 0.5) - 0.5) * 24.0;
			float tram = (1.0 - smoothstep(0.2, 0.32, abs(t - 0.95))) * detail(p, 0.6);
			fc = mix(fc, fc * vec3(0.88, 0.85, 0.8), tram);
			c = fc;
		} else if (kind == K_MEADOW || kind == K_PARKING_GRASS) {
			c = mix(c, c * vec3(1.12, 1.05, 0.8), 0.6);
			if (kind == K_PARKING_GRASS) {
				// worn tyre tracks across the grass
				float t = abs(fract(dot(p, across) / 5.5) - 0.5);
				c = mix(c, vec3(0.45, 0.4, 0.3), (1.0 - smoothstep(0.03, 0.09, t)) * 0.5 * detail(p, 0.5) * n2);
			}
		} else if (kind == K_SCRUB) {
			float clump = smoothstep(0.45, 0.62, nz(p, 0.18));
			c = mix(c * 0.9, vec3(0.2, 0.27, 0.13), clump);
			bump += (vec2(nz(p + vec2(0.4, 0.0), 0.18), nz(p + vec2(0.0, 0.4), 0.18)) - nz(p, 0.18)) * 1.5;
		} else if (kind == K_WOOD) {
			c = mix(vec3(0.13, 0.19, 0.09), vec3(0.22, 0.22, 0.13), n3) * (0.8 + 0.4 * n2);
		} else if (kind == K_HEDGE) {
			c = vec3(0.15, 0.23, 0.1) * (0.7 + 0.6 * nz(p, 0.9));
			bump += (vec2(nz(p + vec2(0.15, 0.0), 0.9), nz(p + vec2(0.0, 0.15), 0.9)) - nz(p, 0.9)) * 3.0;
		} else if (kind == K_RESIDENTIAL) {
			// gardens: lawn with paths and patios
			float pave = smoothstep(0.55, 0.6, nz(p, 0.09));
			c = mix(c * 1.05, vec3(0.55, 0.53, 0.5) * (0.85 + 0.2 * n3), pave);
		} else if (kind == K_INDUSTRIAL || kind == K_FOOTPRINT || kind == K_FARMYARD) {
			vec3 base = kind == K_FARMYARD ? vec3(0.47, 0.44, 0.37) : vec3(0.47, 0.47, 0.45);
			c = base * (0.82 + 0.25 * n2) * (0.94 + 0.1 * n4);
			// concrete slab joints every 6 m
			vec2 g = abs(fract(p / 6.0) - 0.5) * 6.0;
			float joint = (1.0 - smoothstep(2.9, 2.97, max(g.x, g.y))) ;
			c *= 1.0 - (1.0 - joint) * 0.25 * detail(p, 0.15);
			rough = 0.85;
		} else if (kind == K_WATER) {
			c = vec3(0.14, 0.22, 0.26) * (0.9 + 0.2 * n2);
			vec2 q = p + vec2(TIME * 0.35, TIME * 0.21);
			vec2 q2 = p * 1.7 - vec2(TIME * 0.27, -TIME * 0.31);
			bump += (vec2(nz(q + vec2(0.3, 0.0), 0.25), nz(q + vec2(0.0, 0.3), 0.25)) - nz(q, 0.25)) * 0.9;
			bump += (vec2(nz(q2 + vec2(0.2, 0.0), 0.25), nz(q2 + vec2(0.0, 0.2), 0.25)) - nz(q2, 0.25)) * 0.6;
			rough = 0.06;
			spec = 0.7;
			wet_k = 0.0;
		} else if (kind == K_SAND || kind == K_PATH) {
			vec3 base = kind == K_SAND ? vec3(0.77, 0.71, 0.55) : vec3(0.59, 0.56, 0.5);
			c = base * (0.88 + 0.2 * n2) * (0.85 + 0.3 * n4);
			bump += (vec2(nz(p + vec2(0.05, 0.0), 2.3), nz(p + vec2(0.0, 0.05), 2.3)) - n4) * 2.0 * detail(p, 0.1);
		} else if (kind == K_DIRT || kind == K_TRACK_DIRT) {
			c = vec3(0.5, 0.42, 0.31) * (0.85 + 0.25 * n2) * (0.88 + 0.24 * n4);
			if (kind == K_TRACK_DIRT) {
				// grass growing down the middle
				float mid = smoothstep(0.35, 0.5, nz(p, 0.6));
				c = mix(c, pow(grass, vec3(1.0 / 2.2)) * 0.9, mid * 0.5);
			}
		} else if (kind == K_ROAD || kind == K_ASPHALT || kind == K_PARKING || kind == K_RACEWAY) {
			float base = kind == K_PARKING ? 0.33 : kind == K_ASPHALT ? 0.3 : kind == K_RACEWAY ? 0.27 : 0.25;
			c = vec3(base) * (0.92 + 0.12 * n2) * (0.95 + 0.08 * n4);
			// patch repairs on public roads
			if (kind == K_ROAD) {
				c *= 1.0 + 0.12 * smoothstep(0.6, 0.64, nz(p, 0.07));
			}
			bump += (vec2(nz(p + vec2(0.04, 0.0), 2.3), nz(p + vec2(0.0, 0.04), 2.3)) - n4) * 0.3 * detail(p, 0.1);
			rough = 0.82;
		} else if (kind == K_BAY_LINE || kind == K_ROAD_LINE || kind == K_ROAD_DASH) {
			c = vec3(0.86, 0.86, 0.82) * (0.92 + 0.08 * n2);
			rough = 0.6;
		} else if (kind == K_PITCH) {
			c = vec3(0.3, 0.48, 0.2) * (0.9 + 0.15 * n2);
			float st = step(0.5, fract(dot(p, along) / 5.0));
			c *= 1.0 + st * 0.1 - 0.04;
		}
	}
	if (kind != K_GRASS) {
		c = pow(max(c, vec3(0.0)), vec3(2.2));
	}
	vec3 L = normalize(light_dir);
	c *= clamp(1.0 + hillshade * (dot(normalize(wn), L) - L.y), 0.55, 1.5);
	c *= 1.0 - 0.2 * wetness * wet_k;
	ALBEDO = c;
	ROUGHNESS = mix(rough, min(rough, 0.55), wetness * wet_k);
	SPECULAR = spec;
	if (bump != vec2(0.0)) {
		vec3 nw = normalize(normalize(wn) - vec3(bump.x, 0.0, bump.y));
		NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	}
}
