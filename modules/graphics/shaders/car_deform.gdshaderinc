// Bodywork that crumples where the car was hit, like a real crash: the nose
// or tail is shoved in and folds up like an accordion with the bonnet / boot
// lid buckled into a peak behind it, offset hits crush one corner more than
// the other, and side hits cave the doors in around the hit, dragging the
// sill and roof rail in and down with them. Shared by the paint, the plain
// parts and the glass shaders, on every car.
// Works in car space (the mesh's own space: +X forward, +Y up, +Z right; every
// body part of a built car sits at the car's origin), so it bends the panels
// in the vertex shader with no cost on the CPU. CarView sets the uniforms
// from CarDamage.visual_parts()["crush"] and where the hits landed.

uniform vec4 crush = vec4(0.0);      // front, rear, left, right, 0..1
uniform vec4 dent_at = vec4(0.0);    // front hit z, rear hit z, left hit x, right hit x (m)
uniform vec4 dent_at2 = vec4(0.0);   // a second dent per zone (same axes)
uniform vec4 dent2_w = vec4(0.0);    // share of each zone's crush in the second dent, 0..0.5
uniform vec3 car_ext = vec3(2.3, -2.3, 0.95); // nose x, tail x, half width (m)
uniform float roof_crush = 0.0;      // m the roof is pushed down
uniform float roof_y = 1.4;          // roof height (m)
uniform float crush_depth = 0.65;    // m a fully wrecked end is pushed in

// Irregular -1..1 ripple, so no two folds look stamped out of one die.
float crumple_wave(vec3 v) {
	return sin(v.y * 13.0 + v.z * 7.0 + v.x * 2.0) * sin(v.z * 5.3 - v.x * 3.7 + v.y * 4.0);
}

// 1 at the hit, easing to 0 at `r` away (a soft-edged bowl).
float bell(float d, float r) {
	float t = clamp(abs(d) / r, 0.0, 1.0);
	return (1.0 - t * t) * (1.0 - t * t);
}

// How much of an end crush lands at this point across the car: most on the
// side that was hit, the far corner folding less (an offset crash).
float end_share(float z, float hit, float hit2, float w2, float hw) {
	float a = mix(0.4, 1.0, bell(z - hit, hw * 1.5));
	float b = mix(0.4, 1.0, bell(z - hit2, hw * 1.5));
	return mix(a, max(a, b), w2 * 2.0);
}

// One end of the car shoved in by `c` metres. `d` = distance in from that
// end, `dir` = +1 at the nose (pushes back) or -1 at the tail.
vec3 crush_end(vec3 v, vec3 o, float c, float d, float share, float dir, float w) {
	float hw = car_ext.z;
	float zone = 0.3 + c * 1.5;                  // how far back the crumple reaches
	float k = 1.0 - smoothstep(0.0, zone, d);    // 1 at the very end .. 0 behind the zone
	float cc = c * share;
	// Shoved in: the end moves most, panels behind it bunch up.
	o.x -= dir * cc * k * (1.0 + 0.22 * w);
	// Accordion folds across the panels, deeper towards the end.
	float fold = sin(d * 24.0 + v.z * 2.5 + w * 1.5) * cc * 0.16 * k;
	float top = smoothstep(0.35, 0.7, v.y);
	float below_roof = 1.0 - smoothstep(roof_y - 0.45, roof_y - 0.2, v.y);   // the cabin roof keeps its shape
	o.y += fold * (0.4 + 0.6 * top) * below_roof;
	o.z += sign(v.z) * fold * 0.55 * smoothstep(hw * 0.5, hw, abs(v.z));
	// The front / rear corners fold round, so the end narrows and droops.
	float edge = smoothstep(hw * 0.45, hw, abs(v.z));
	o.z -= sign(v.z) * cc * 0.28 * k * edge;
	o.y -= cc * 0.16 * k * (1.0 - 0.5 * top);
	// The bonnet / boot lid buckles up into a peak just behind the crumple.
	float lid = smoothstep(zone * 0.3, zone * 0.75, d) * (1.0 - smoothstep(zone * 0.75, zone * 1.3, d));
	o.y += cc * 0.45 * lid * top * below_roof * (1.0 - 0.75 * smoothstep(0.0, hw, abs(v.z))) * (0.9 + 0.2 * w);
	return o;
}

// One side caved in by `c` metres around `at` (x along the car). `out` = how
// far this point is in from that side's skin, `sgn` = +1 pushes towards +z.
vec3 cave_side(vec3 v, vec3 o, float c, float at, float inset, float sgn, float w) {
	float len = 0.6 + c * 1.0;                   // half length of the dent along the car
	float along = bell(v.x - at, len);
	float k = 1.0 - smoothstep(0.0, 0.25 + c * 1.4, inset);   // the skin, fading into the car
	// Deepest at door-handle height, less at the sill, roof rail dragged in.
	float hgt = mix(0.45, 1.0, smoothstep(0.1, 0.42, v.y)) * (1.0 - 0.35 * smoothstep(0.8, roof_y, v.y));
	float cc = c * along * k;
	// A sharp crease runs along the dent where the door folds.
	float crease = sin((v.x - at) * 16.0 + v.y * 6.0) * 0.12 * (1.0 - along);
	o.z += sgn * cc * hgt * (1.0 + 0.3 * w + crease);
	// Roof rail, window line and the top of the wing pulled down into it.
	float upper = smoothstep(0.55, roof_y * 0.9, v.y);
	o.y -= cc * 0.5 * upper;
	o.y += cc * 0.1 * w;
	// The door ends bulge out a little as the middle goes in.
	float rim = bell(abs(v.x - at) - len * 0.85, len * 0.35);
	o.z -= sgn * c * k * hgt * rim * 0.12;
	return o;
}

vec3 crumple(vec3 v) {
	float hw = car_ext.z;
	float w = crumple_wave(v);
	vec3 o = v;
	float cf = crush.x * crush_depth;
	if (cf > 0.0) {
		float share = end_share(v.z, dent_at.x, dent_at2.x, dent2_w.x, hw);
		o = crush_end(v, o, cf, car_ext.x - v.x, share, 1.0, w);
	}
	float cr = crush.y * crush_depth * 0.92;
	if (cr > 0.0) {
		float share = end_share(v.z, dent_at.y, dent_at2.y, dent2_w.y, hw);
		o = crush_end(v, o, cr, v.x - car_ext.y, share, -1.0, w);
	}
	// Sides: doors are thinner than crumple zones, so they cave in less far
	// but over a wide, bowl-shaped dent (two dents for hits far apart).
	float cl = crush.z * crush_depth * 0.7;
	if (cl > 0.0) {
		o = cave_side(v, o, cl * (1.0 - dent2_w.z), dent_at.z, v.z + hw, 1.0, w);
		if (dent2_w.z > 0.0) {
			o = cave_side(v, o, cl * dent2_w.z * 1.6, dent_at2.z, v.z + hw, 1.0, w);
		}
	}
	float cs = crush.w * crush_depth * 0.7;
	if (cs > 0.0) {
		o = cave_side(v, o, cs * (1.0 - dent2_w.w), dent_at.w, hw - v.z, -1.0, w);
		if (dent2_w.w > 0.0) {
			o = cave_side(v, o, cs * dent2_w.w * 1.6, dent_at2.w, hw - v.z, -1.0, w);
		}
	}
	// Roof: squashed down after a pile of hits (or a roll).
	if (roof_crush > 0.0) {
		float k = smoothstep(roof_y - 0.45, roof_y, v.y);
		o.y -= roof_crush * k * (1.0 + 0.3 * w);
	}
	return o;
}

// Moves a vertex and bends its normal to match (finite differences). `bent`
// = how creased the panel is here, 0..1 (the paint scuffs and darkens in the
// folds, so dents read from above whatever the light).
void apply_crumple_k(inout vec3 v, inout vec3 n, out float bent) {
	bent = 0.0;
	if (crush.x + crush.y + crush.z + crush.w + roof_crush <= 0.0005) {
		return;
	}
	vec3 a = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t1 = normalize(cross(n, a));
	vec3 t2 = cross(n, t1);
	float e = 0.03;
	vec3 p0 = crumple(v);
	vec3 p1 = crumple(v + t1 * e);
	vec3 p2 = crumple(v + t2 * e);
	vec3 nn = normalize(cross(p1 - p0, p2 - p0));
	if (dot(nn, n) < 0.0) {
		nn = -nn;
	}
	bent = clamp((1.0 - dot(nn, n)) * 5.0 + length(p0 - v) * 0.6, 0.0, 1.0);
	v = p0;
	n = nn;
}

void apply_crumple(inout vec3 v, inout vec3 n) {
	float bent;
	apply_crumple_k(v, n, bent);
}
