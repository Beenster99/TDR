// Demolition Derby bodywork that crumples where the car was hit. Shared by
// the paint, the derby parts and the cracked glass shaders. Works in car
// space (the mesh's own space: +X forward, +Y up, +Z right; every body part
// of a built car sits at the car's origin), so it bends the panels in the
// vertex shader with no cost on the CPU. CarView sets the uniforms from
// CarDamage.visual_parts()["crush"] and where the hits landed.

uniform vec4 crush = vec4(0.0);      // front, rear, left, right, 0..1
uniform vec4 dent_at = vec4(0.0);    // front hit z, rear hit z, left hit x, right hit x (m)
uniform vec3 car_ext = vec3(2.3, -2.3, 0.95); // nose x, tail x, half width (m)
uniform float roof_crush = 0.0;      // m the roof is pushed down
uniform float roof_y = 1.4;          // roof height (m)
uniform float crush_depth = 0.65;    // m a fully wrecked end is pushed in

float crumple_wave(vec3 v) {
	return sin(v.y * 13.0 + v.z * 7.0 + v.x * 2.0) * sin(v.z * 5.3 - v.x * 3.7 + v.y * 4.0);
}

vec3 crumple(vec3 v) {
	float hw = car_ext.z;
	float w = crumple_wave(v);
	vec3 o = v;
	// Nose: pushed back, folding up and down, most where it was hit; the
	// bonnet buckles up behind the crumple.
	float cf = crush.x * crush_depth;
	if (cf > 0.0) {
		float zone = 0.35 + cf * 2.4;
		float d = car_ext.x - v.x;
		float k = 1.0 - smoothstep(0.0, zone, d);
		float lat = 1.0 - 0.6 * smoothstep(0.0, hw * 1.7, abs(v.z - dent_at.x));
		o.x -= cf * k * lat * (1.0 + 0.25 * w);
		o.y += cf * k * lat * 0.22 * w;
		o.y += cf * 0.3 * smoothstep(zone * 0.5, zone, d) * (1.0 - smoothstep(zone, zone * 1.7, d)) * smoothstep(0.55, 0.85, v.y);
	}
	// Tail: the same at the back.
	float cr = crush.y * crush_depth;
	if (cr > 0.0) {
		float zone = 0.35 + cr * 2.2;
		float d = v.x - car_ext.y;
		float k = 1.0 - smoothstep(0.0, zone, d);
		float lat = 1.0 - 0.6 * smoothstep(0.0, hw * 1.7, abs(v.z - dent_at.y));
		o.x += cr * k * lat * (1.0 + 0.25 * w);
		o.y += cr * k * lat * 0.2 * w;
		o.y += cr * 0.22 * smoothstep(zone * 0.5, zone, d) * (1.0 - smoothstep(zone, zone * 1.7, d)) * smoothstep(0.55, 0.85, v.y);
	}
	// Sides: caved in around where it was hit (doors fold in, sills less).
	float cl = crush.z * crush_depth * 0.6;
	if (cl > 0.0) {
		float k = 1.0 - smoothstep(0.0, 0.3 + cl * 2.2, v.z + hw);
		float along = 1.0 - smoothstep(0.0, 1.1 + cl * 2.0, abs(v.x - dent_at.z));
		float hgt = smoothstep(0.15, 0.55, v.y);
		o.z += cl * k * along * hgt * (1.0 + 0.3 * w);
		o.y += cl * k * along * 0.12 * w;
	}
	float cs = crush.w * crush_depth * 0.6;
	if (cs > 0.0) {
		float k = 1.0 - smoothstep(0.0, 0.3 + cs * 2.2, hw - v.z);
		float along = 1.0 - smoothstep(0.0, 1.1 + cs * 2.0, abs(v.x - dent_at.w));
		float hgt = smoothstep(0.15, 0.55, v.y);
		o.z -= cs * k * along * hgt * (1.0 + 0.3 * w);
		o.y += cs * k * along * 0.12 * w;
	}
	// Roof: squashed down after a pile of hits (or a roll).
	if (roof_crush > 0.0) {
		float k = smoothstep(roof_y - 0.45, roof_y, v.y);
		o.y -= roof_crush * k * (1.0 + 0.3 * w);
	}
	return o;
}

// Moves a vertex and bends its normal to match (finite differences).
void apply_crumple(inout vec3 v, inout vec3 n) {
	if (crush.x + crush.y + crush.z + crush.w + roof_crush <= 0.0005) {
		return;
	}
	vec3 a = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t1 = normalize(cross(n, a));
	vec3 t2 = cross(n, t1);
	float e = 0.04;
	vec3 p0 = crumple(v);
	vec3 p1 = crumple(v + t1 * e);
	vec3 p2 = crumple(v + t2 * e);
	vec3 nn = normalize(cross(p1 - p0, p2 - p0));
	if (dot(nn, n) < 0.0) {
		nn = -nn;
	}
	v = p0;
	n = nn;
}
