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
	vec3 c;
	float rough;
	float aa = fwidth(UV.y) * 1.2 + 0.001;
	if (kind > 0.875) {
		// asphalt: aggregate speckle, patches, rubber line
		c = vec3(0.105, 0.102, 0.098) * (0.86 + 0.22 * n1) * (0.93 + 0.14 * n3);
		// rubbered racing line: about 4 m wide, darkest in the middle and
		// fading out softly to the edges (no hard border)
		float rl = exp(-pow(abs(UV2.x) / 1.55, 2.2));
		c *= 1.0 - 0.3 * rl * (0.7 + 0.3 * n2);
		// marbles just outside the line
		float marb = smoothstep(2.6, 3.6, abs(UV2.x)) * (1.0 - smoothstep(3.6, 6.0, abs(UV2.x)));
		c = mix(c, vec3(0.1, 0.1, 0.1), marb * 0.25 * n2);
		// white edge lines (painted 0.1-0.3 m in from the edge)
		float line = smoothstep(0.08 - aa, 0.08 + aa, UV2.y) * (1.0 - smoothstep(0.3 - aa, 0.3 + aa, UV2.y));
		c = mix(c, vec3(0.8, 0.8, 0.78) * (0.92 + 0.08 * n3), line);
		rough = mix(0.82, 0.6, rl) - 0.05 * line;
	} else if (kind > 0.625) {
		// kerb: red/white blocks along the track, slight wear
		float k = step(0.5, fract(UV.x / (2.0 * kerb_len)));
		c = mix(kerb_a, kerb_b, k) * (0.88 + 0.12 * n3);
		c = mix(c, vec3(0.1), 0.15 * n2);
		rough = 0.55;
	} else if (kind > 0.375) {
		// tarmac run-off: lighter, older asphalt
		c = vec3(0.17, 0.165, 0.16) * (0.85 + 0.25 * n1) * (0.94 + 0.1 * n3);
		rough = 0.88;
	} else if (kind > 0.125) {
		// gravel trap
		c = vec3(0.5, 0.4, 0.26) * (0.8 + 0.35 * n3) * (0.9 + 0.15 * n1);
		rough = 0.97;
	} else {
		// pit lane asphalt (smoother, a touch lighter), with painted edge
		// lines (UV2.y = distance inside the lane's edge) and white hatching
		// on the track side where the lane splits off or merges (UV2.x = 1,
		// UV.y < 0 = track side of the lane, UV.x = metres along the lane)
		c = vec3(0.13, 0.127, 0.123) * (0.9 + 0.15 * n1);
		float paa = fwidth(UV2.y) * 1.2 + 0.001;
		float pline = smoothstep(0.1 - paa, 0.1 + paa, UV2.y) * (1.0 - smoothstep(0.35 - paa, 0.35 + paa, UV2.y));
		float gore = step(0.5, UV2.x) * step(UV.y, 0.0) * smoothstep(0.6, 0.9, -UV2.y);
		float hx = fract((UV.x + UV.y * 1.2) / 3.0);
		float haa = fwidth(UV.x) / 3.0 + 0.002;
		float hatch = gore * smoothstep(0.0, haa, hx) * (1.0 - smoothstep(0.22 - haa, 0.22 + haa, hx));
		c = mix(c, vec3(0.8, 0.8, 0.78) * (0.92 + 0.08 * n3), max(pline, hatch * 0.9));
		rough = 0.75 - 0.05 * pline;
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
	// wet: darker and shinier, puddles in the low noise spots
	float wet = wetness * (1.0 - dry_line * exp(-pow(UV2.x / dry_line_width, 2.0)) * step(0.875, kind));
	if (kind > 0.125 && kind < 0.375) { wet *= 0.4; }
	wet *= 1.0 - 0.45 * dirt;  // mud darkens but stays dull
	float puddle = wet * smoothstep(0.55, 0.75, n1 * 0.7 + n2 * 0.3);
	c *= 1.0 - 0.35 * wet;
	ALBEDO = c;
	ROUGHNESS = mix(rough, 0.08, max(wet * 0.7, puddle));
	SPECULAR = 0.5;
}
