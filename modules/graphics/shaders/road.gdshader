shader_type spatial;
// Track surfaces: asphalt (with a rubbered racing line and painted edge
// lines), tarmac/gravel run-off and kerbs, chosen per vertex:
//   COLOR.a  : 1 = asphalt, 0.75 = kerb, 0.5 = tarmac run-off, 0.25 = gravel, 0 = pit lane
//   COLOR.r  : 1 - loose surface (rallycross dirt: 0 = all dirt), on asphalt
//              and kerbs; eased over metres, 0.5 = the real join, which is
//              drawn as a ragged edge with dust and loose stones around it
//   COLOR.g  : 1 - dirt the tyres drag out onto tarmac after a dirt stretch
//   COLOR.b  : 1 - fray: the joker lane frays out (ragged cut) over the lap
//   UV.x     : distance along the track (m), UV.y : lateral offset (m)
//   UV2.x    : offset from the racing line (m), UV2.y : distance to the track edge (m)
//   (pit lane: UV.y = offset, + towards the garages; UV2.x = 1 where hatched;
//    UV2.y = distance inside the lane's painted edge)
// Height cue for elevation: hillshade by slope.

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
// 1 m x 1 m of close-up asphalt (tools/build_asphalt.py): R = stone tone,
// GB = normal (x, z), A = height. Mipmaps average it out far away.
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform float detail_normal = 1.0;  // how strongly the aggregate catches the sun
uniform float wetness = 0.0;
uniform float dry_line = 0.0;      // 0..1 how dry the racing line is (SimEnvironment)
uniform float dry_line_width = 2.2;
uniform float hillshade = 0.0;
uniform vec3 light_dir = vec3(0.5, 0.6, 0.6);
uniform vec3 kerb_a : source_color = vec3(0.78, 0.1, 0.09);
uniform vec3 kerb_b : source_color = vec3(0.93, 0.93, 0.92);
uniform float kerb_len = 1.0;

varying vec3 wn;
varying vec3 wp;

void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash12(vec2 q) {
	vec3 p3 = fract(vec3(q.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// The aggregate texture sampled twice (a second copy turned and scaled) and
// switched between by a slow noise, so the 1 m tile never visibly repeats.
// xy = world-space normal tilt (x, z), z = stone tone, w = height.
vec4 aggregate(vec2 p, float scale, float pick) {
	vec4 a = texture(detail, p * scale);
	const mat2 R = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	vec4 b = texture(detail, R * p * (scale * 0.613) + vec2(0.37, 0.71));
	vec2 na = a.gb * 2.0 - 1.0;
	vec2 nb = transpose(R) * (b.gb * 2.0 - 1.0);
	float t = smoothstep(0.42, 0.58, pick);
	return vec4(mix(na, nb, t), mix(a.r, b.r, t), mix(a.a, b.a, t));
}

// Thin line (0..1) where v crosses `at`, w wide in v's units, anti-aliased.
float thin_line(float v, float at, float w) {
	float aa = fwidth(v) * 0.8 + 1e-5;
	return 1.0 - smoothstep(w - aa, w + aa, abs(v - at));
}

void fragment() {
	float kind = COLOR.a;
	vec2 p = wp.xz;
	float n1 = texture(noise, p * 0.11).r;
	float n2 = texture(noise, p * 0.9).r;
	float n3 = texture(noise, p * 3.7).r;
	// ragged edges: big lobes with finer bites out of them
	float ragged = texture(noise, p * 0.05).r * 0.55 + texture(noise, p * 0.23).r * 0.3 + n2 * 0.15 - 0.5;
	float fray = 1.0 - COLOR.b;
	if (fray > 0.001 && fray + clamp(ragged * 2.2, -0.45, 0.45) > 0.5) {
		discard;
	}
	float n0 = texture(noise, p * 0.023).r;   // ~40 m blotches
	vec4 ag = aggregate(p, 1.0, n1);
	float stone = ag.z;                        // 0 bitumen .. 1 pale stone
	float hgt = ag.w;                          // 0 pores .. 1 stone tops
	vec2 tilt = ag.xy;
	float tilt_k = 1.0;
	vec3 c;
	float rough;
	float aa = fwidth(UV.y) * 1.2 + 0.001;
	if (kind > 0.875) {
		// Racing asphalt, built up like the real thing seen from above:
		// grey aggregate in black bitumen, laid in paving strips with faint
		// joints, then patched, crack-sealed and rubbered in by the cars.
		// Aggregate showing through the binder: more where the surface is
		// worn and dusty, less where it is fresh.
		float expose = 0.55 + 0.35 * n0;
		vec3 bitumen = vec3(0.075, 0.074, 0.071);
		vec3 rock = vec3(0.29, 0.285, 0.276) * (0.55 + 0.9 * stone);
		c = mix(bitumen, rock, expose * smoothstep(0.38, 0.62, hgt) * smoothstep(0.08, 0.3, stone));
		// mottling at 0.3-10 m: binder and stone never quite even
		c *= (0.84 + 0.3 * n1) * (0.9 + 0.2 * n3) * (0.93 + 0.14 * n2);
		// paving strips ~4.5 m wide and a few hundred metres long, each
		// laid a slightly different shade, with a thin dark joint between
		float sy = (UV.y + 200.0) / 4.6;
		vec2 strip = vec2(floor(UV.x / 380.0), floor(sy));
		float sh = hash12(strip);
		c *= 0.93 + 0.14 * sh;
		c *= vec3(1.0 + 0.03 * (sh - 0.5), 1.0, 1.0 - 0.03 * (sh - 0.5));
		float joint = thin_line(fract(sy), 0.0, 0.012) + thin_line(fract(sy), 1.0, 0.012);
		joint *= step(0.6, UV2.y);
		c *= 1.0 - 0.22 * joint;
		// repair patches: rectangles of newer, blacker asphalt with a
		// sealed (shiny tar) border
		vec2 pc = vec2(UV.x / 23.0, (UV.y + 200.0) / 3.1);
		vec2 cell = floor(pc);
		float ph = hash12(cell + 17.0);
		float patch_on = step(ph, 0.05);
		vec2 lo = vec2(hash12(cell + 3.1), hash12(cell + 5.7)) * 0.35;
		vec2 hi = 1.0 - vec2(hash12(cell + 7.3), hash12(cell + 9.9)) * 0.35;
		vec2 f = fract(pc);
		vec2 fw = fwidth(pc) + 1e-5;
		vec2 inside2 = smoothstep(lo - fw, lo + fw, f) * (1.0 - smoothstep(hi - fw, hi + fw, f));
		float in_patch = patch_on * inside2.x * inside2.y;
		vec2 bw = vec2(0.09 / 23.0, 0.09 / 3.1);
		vec2 ob = smoothstep(lo - bw - fw, lo - bw + fw, f) * (1.0 - smoothstep(hi + bw - fw, hi + bw + fw, f));
		float seal = patch_on * clamp(ob.x * ob.y - in_patch, 0.0, 1.0);
		float fresh = 0.72 + 0.2 * hash12(cell + 1.3);
		c = mix(c, c * fresh, in_patch);
		c = mix(c, vec3(0.035), seal * 0.85);
		// crack sealing ("tar snakes"): thin wandering lines of black
		// sealant, here and there
		float cn = texture(noise, p * 0.014 + vec2(0.13, 0.57)).r;
		float cmask = smoothstep(0.6, 0.68, texture(noise, p * 0.006 + vec2(0.71, 0.2)).r);
		float snake = thin_line(cn, 0.5, 0.0018) * cmask;
		c = mix(c, vec3(0.03), snake * 0.85);
		// cars' tyre streaks running with the track, strongest on the line
		float streak = texture(noise, vec2(UV.x * 0.0035, UV.y * 0.32)).r;
		float rl = exp(-pow(abs(UV2.x) / 1.55, 2.2));
		// rubbered racing line: about 4 m wide, darkest in the middle and
		// fading out softly to the edges (no hard border); rubber fills
		// the pores so less stone shows
		// two darker tyre tracks inside the line, a car's track width apart
		float twin = exp(-pow((abs(UV2.x) - 0.82) / 0.45, 2.0));
		float rub = rl * (0.5 + 0.3 * twin + 0.35 * smoothstep(0.3, 0.7, streak));
		c = mix(c, vec3(0.035, 0.035, 0.037), clamp(rub, 0.0, 1.0) * 0.62);
		c *= 1.0 - 0.22 * (streak - 0.5) * (0.5 + rl);
		// dusty, unused grey near the edges and well off the line
		float dust = smoothstep(2.5, 7.0, abs(UV2.x));
		dust *= 0.5 + 0.5 * smoothstep(3.0, 0.4, UV2.y);
		c = mix(c, vec3(0.16, 0.155, 0.148) * (0.85 + 0.3 * n2), dust * 0.18);
		// marbles just outside the line
		float marb = smoothstep(2.6, 3.6, abs(UV2.x)) * (1.0 - smoothstep(3.6, 6.0, abs(UV2.x)));
		c = mix(c, vec3(0.03), marb * 0.35 * smoothstep(0.55, 0.8, n3));
		// white edge lines (painted 0.1-0.3 m in from the edge), painted
		// over the stone texture and worn into its pores
		float line = smoothstep(0.08 - aa, 0.08 + aa, UV2.y) * (1.0 - smoothstep(0.3 - aa, 0.3 + aa, UV2.y));
		float paint = line * (0.72 + 0.28 * smoothstep(0.15, 0.5, hgt)) * (0.9 + 0.1 * n3);
		c = mix(c, vec3(0.8, 0.8, 0.78), paint);
		rough = mix(0.86, 0.68, rub) - 0.12 * smoothstep(0.6, 0.95, hgt) * (1.0 - rub);
		rough = mix(rough, 0.45, seal + snake * 0.7);
		rough = mix(rough, 0.6, line);
		tilt_k = 1.0 - 0.5 * rub - 0.4 * line;
	} else if (kind > 0.625) {
		// kerb: red/white blocks along the track, painted over concrete, worn
		float k = step(0.5, fract(UV.x / (2.0 * kerb_len)));
		c = mix(kerb_a, kerb_b, k) * (0.85 + 0.1 * n3 + 0.1 * hgt);
		c = mix(c, vec3(0.1), 0.15 * n2 + 0.2 * smoothstep(0.6, 0.85, texture(noise, vec2(UV.x * 0.01, UV.y * 0.5)).r));
		rough = 0.55;
		tilt_k = 0.6;
	} else if (kind > 0.375) {
		// tarmac run-off: older, sun-bleached asphalt with more stone showing
		vec3 bitumen = vec3(0.085, 0.083, 0.08) * (0.88 + 0.22 * n1);
		vec3 rock = vec3(0.32, 0.31, 0.3) * (0.55 + 0.9 * stone);
		c = mix(bitumen, rock, 0.75 * smoothstep(0.35, 0.6, hgt) * smoothstep(0.08, 0.3, stone));
		c *= (0.86 + 0.26 * n1) * (0.9 + 0.2 * n3);
		rough = 0.9;
	} else if (kind > 0.125) {
		// gravel trap: the stone texture at three times the size, sandy beige
		vec4 gv = aggregate(p, 0.33, n1);
		vec3 sand = vec3(0.5, 0.41, 0.28) * (0.85 + 0.25 * n1);
		vec3 peb = mix(vec3(0.42, 0.36, 0.28), vec3(0.72, 0.66, 0.55), gv.z);
		c = mix(sand * (0.85 + 0.15 * n3), peb, smoothstep(0.3, 0.55, gv.w));
		c *= 0.8 + 0.3 * gv.w;
		tilt = gv.xy;
		tilt_k = 1.6;
		rough = 0.97;
	} else {
		// pit lane asphalt (smoother, a touch lighter, finer stone), with painted edge
		// lines (UV2.y = distance inside the lane's edge) and white hatching
		// on the track side where the lane splits off or merges (UV2.x = 1,
		// UV.y < 0 = track side of the lane, UV.x = metres along the lane)
		vec4 pg = aggregate(p, 1.6, n1);
		vec3 bitumen = vec3(0.07, 0.069, 0.067) * (0.9 + 0.15 * n1);
		vec3 rock = vec3(0.27, 0.265, 0.26) * (0.6 + 0.8 * pg.z);
		c = mix(bitumen, rock, 0.55 * smoothstep(0.4, 0.62, pg.w) * smoothstep(0.08, 0.3, pg.z));
		c *= (0.86 + 0.26 * n1) * (0.92 + 0.16 * n3);
		// cars' tyre streaks along the lane, darkest down the middle
		float pstreak = texture(noise, vec2(UV.x * 0.004, UV.y * 0.35)).r;
		c *= 1.0 - 0.2 * (pstreak - 0.5) - 0.12 * exp(-pow(UV.y / 2.0, 2.0)) * pstreak;
		tilt = pg.xy;
		tilt_k = 0.7;
		float paa = fwidth(UV2.y) * 1.2 + 0.001;
		float pline = smoothstep(0.1 - paa, 0.1 + paa, UV2.y) * (1.0 - smoothstep(0.35 - paa, 0.35 + paa, UV2.y));
		float gore = step(0.5, UV2.x) * step(UV.y, 0.0) * smoothstep(0.6, 0.9, -UV2.y);
		float hx = fract((UV.x + UV.y * 1.2) / 3.0);
		float haa = fwidth(UV.x) / 3.0 + 0.002;
		float hatch = gore * smoothstep(0.0, haa, hx) * (1.0 - smoothstep(0.22 - haa, 0.22 + haa, hx));
		float pp = max(pline, hatch * 0.9) * (0.75 + 0.25 * smoothstep(0.15, 0.5, pg.w));
		c = mix(c, vec3(0.8, 0.8, 0.78) * (0.92 + 0.08 * n3), pp);
		rough = 0.8 - 0.15 * pp;
	}
	// Rallycross dirt: packed brown earth with a darker, polished groove
	// along the racing line, loose stones and ruts either side of it.
	// Where it meets tarmac the join is ragged (the eased COLOR.r cut with
	// noise), with a dusty film and scattered stones on the tarmac beside it
	// and tyre tracks of dirt carried out onto the tarmac after it.
	float ease = (kind > 0.625) ? clamp(1.0 - COLOR.r, 0.0, 1.0) : 0.0;
	float trail = (kind > 0.625) ? clamp(1.0 - COLOR.g, 0.0, 1.0) : 0.0;
	float dirt = 0.0;
	if (ease > 0.001 || trail > 0.001) {
		float eaa = fwidth(ease) * 1.5 + 0.03;
		dirt = smoothstep(0.5 - eaa, 0.5 + eaa, ease + clamp(ragged * 2.2, -0.45, 0.45));
		// tracks: the cars' wheel paths along the racing line, streaky
		// (two wheel tracks either side of the line, the cars spread a little)
		float wobble = (texture(noise, vec2(UV.x * 0.02, 0.37)).r - 0.5) * 3.0;
		float lx = abs(UV2.x + wobble);
		float paths = exp(-pow((lx - 0.85) / 0.5, 2.0)) + 0.5 * exp(-pow(lx / 3.5, 2.0));
		float streak = texture(noise, vec2(UV.x * 0.06, UV2.x * 0.3)).r + n3 * 0.15;
		float tracks = clamp(paths, 0.0, 1.0) * smoothstep(0.5, 0.62, streak + trail * 0.35 - 0.12) * trail;
		dirt = max(dirt, smoothstep(0.05, 0.5, tracks) * 0.8);
		// dust: a pale film thinning away from the join
		float dust = (smoothstep(0.05, 0.5, ease) * 0.55 + trail * paths * 0.35) * (1.0 - dirt);
		c = mix(c, vec3(0.5, 0.43, 0.34) * (0.85 + 0.3 * n1), dust * (0.55 + 0.45 * n2) * 0.45);
		// stones flung onto the tarmac near the join
		float flung = smoothstep(0.2, 0.5, ease) * (1.0 - dirt) * smoothstep(0.7, 0.8, n3);
		c = mix(c, vec3(0.5, 0.44, 0.36), flung * 0.6);
		rough = mix(rough, 0.95, dust);
	}
	if (dirt > 0.001) {
		vec3 earth = vec3(0.47, 0.35, 0.23) * (0.8 + 0.32 * n1) * (0.86 + 0.26 * n3);
		float groove = exp(-pow(abs(UV2.x) / 2.4, 2.0));
		earth = mix(earth, vec3(0.33, 0.25, 0.17) * (0.9 + 0.2 * n2), groove * 0.55);
		float rut = exp(-pow((abs(UV2.x) - 0.85) / 0.25, 2.0)) * (0.6 + 0.4 * n2);
		earth *= 1.0 - 0.25 * rut;
		float stones = smoothstep(0.62, 0.78, n3) * (1.0 - groove);
		earth = mix(earth, vec3(0.55, 0.5, 0.44), stones * 0.45);
		c = mix(c, earth, dirt);
		rough = mix(rough, 0.98, dirt);
	}
	vec3 L = normalize(light_dir);
	c *= clamp(1.0 + hillshade * 0.6 * (dot(normalize(wn), L) - L.y), 0.5, 1.5);
	// wet: darker and shinier, puddles in the low noise spots; water fills
	// the pores between the stones first, and puddles drown the texture
	float wet = wetness * (1.0 - dry_line * exp(-pow(UV2.x / dry_line_width, 2.0)) * step(0.875, kind));
	if (kind > 0.125 && kind < 0.375) { wet *= 0.4; }
	wet *= 1.0 - 0.45 * dirt;  // mud darkens but stays dull
	float puddle = wet * smoothstep(0.55, 0.75, n1 * 0.7 + n2 * 0.3);
	c *= 1.0 - 0.35 * wet;
	ALBEDO = c;
	float film = wet * smoothstep(0.75, 0.25, hgt + 0.35 * (1.0 - wet));
	ROUGHNESS = mix(rough, 0.08, max(max(wet * 0.55, film * 0.8), puddle));
	SPECULAR = 0.5;
	// the stones' relief catches the sun (flattened by standing water)
	float tk = detail_normal * tilt_k * (1.0 - dirt) * (1.0 - puddle) * 0.6;
	vec3 nw = normalize(normalize(wn) + vec3(tilt.x, 0.0, tilt.y) * tk);
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
}
