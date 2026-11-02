/* Lap time of a racing line for a point-mass GT3 car, and its gradient.
 * Used by raceline.py (built on the fly with the system C compiler).
 *
 * The line is the centre line moved sideways: p[i] = c[i] + nrm[i] * off[i].
 * Speed: corner limit from curvature and grip (with downforce), then a
 * backward braking pass and a forward acceleration pass, both sharing the
 * tyre's grip with the cornering force (friction ellipse). Acceleration is
 * limited by engine power and by rear-tyre traction, which is what makes a
 * late apex pay: the car can only use full throttle once the corner opens.
 */
#include <math.h>
#include <string.h>

typedef struct {
	double mu;          /* tyre grip */
	double g;
	double mass;
	double aero;        /* 0.5 rho ClA */
	double drag;        /* 0.5 rho CdA */
	double power;       /* W at the wheels */
	double traction;    /* share of total grip the driven wheels can put down */
	double brake;       /* share of grip usable in a straight-line stop */
	double vmax;
	int    half;        /* curvature chord: points either side */
} Car;

static int wr(int i, int n) { i %= n; return i < 0 ? i + n : i; }

/* Fills k (signed curvature) and ds (segment length to next point). */
static void geometry(int n, const double *cx, const double *cy, const double *nx, const double *ny,
                     const double *off, int half, double *k, double *ds, double *px, double *py) {
	for (int i = 0; i < n; i++) {
		px[i] = cx[i] + nx[i] * off[i];
		py[i] = cy[i] + ny[i] * off[i];
	}
	for (int i = 0; i < n; i++) {
		int a = wr(i - half, n), c = wr(i + half, n), j = wr(i + 1, n);
		double abx = px[i] - px[a], aby = py[i] - py[a];
		double bcx = px[c] - px[i], bcy = py[c] - py[i];
		double cax = px[a] - px[c], cay = py[a] - py[c];
		double cross = abx * bcy - aby * bcx;
		double den = sqrt(abx * abx + aby * aby) * sqrt(bcx * bcx + bcy * bcy) * sqrt(cax * cax + cay * cay);
		k[i] = 2.0 * cross / (den > 1e-6 ? den : 1e-6);
		double dx = px[j] - px[i], dy = py[j] - py[i];
		ds[i] = sqrt(dx * dx + dy * dy);
	}
	/* Average over neighbours: with a chord of 2+ points a zigzag on every
	 * other point would be invisible to the curvature. */
	double first = k[0], prev = k[n - 1];
	for (int i = 0; i < n; i++) {
		double cur = k[i], next = i + 1 < n ? k[i + 1] : first;
		k[i] = 0.25 * prev + 0.5 * cur + 0.25 * next;
		prev = cur;
	}
}

static double grip_at(const Car *c, double v) { return c->mu * (c->g + c->aero * v * v / c->mass); }

/* Share of grip left for braking/accelerating with lateral accel ay. */
static double ellipse(double ay, double lim) {
	double r = ay / lim;
	return r >= 1.0 ? 0.0 : sqrt(1.0 - r * r);
}

/* Speed profile into v (n), returns lap time. scratch: 5n doubles. */
double profile(int n, const double *cx, const double *cy, const double *nx, const double *ny,
               const double *off, const Car *c, double *v, double *scratch) {
	double *k = scratch, *ds = scratch + n, *px = scratch + 2 * n, *py = scratch + 3 * n, *vl = scratch + 4 * n;
	geometry(n, cx, cy, nx, ny, off, c->half, k, ds, px, py);
	int slow = 0;
	for (int i = 0; i < n; i++) {
		double kk = fabs(k[i]) > 1e-6 ? fabs(k[i]) : 1e-6;
		double den = c->mass * kk - c->mu * c->aero;
		double lim = den <= 0.0 ? c->vmax : sqrt(c->mu * c->mass * c->g / den);
		vl[i] = lim < c->vmax ? lim : c->vmax;
		v[i] = vl[i];
		if (vl[i] < vl[slow]) slow = i;
	}
	/* Backward pass (braking), twice round from the slowest point. */
	for (int t = 0; t < 2 * n; t++) {
		int i = wr(slow - 1 - t, n), j = wr(i + 1, n);
		double vn = v[j];
		double lim = grip_at(c, vn);
		double ay = vn * vn * fabs(k[i]);
		double dec = c->brake * lim * ellipse(ay, lim) + c->drag * vn * vn / c->mass;
		double vb = sqrt(vn * vn + 2.0 * dec * ds[i]);
		if (vb < v[i]) v[i] = vb;
	}
	/* Forward pass (power and traction). */
	for (int t = 0; t < 2 * n; t++) {
		int i = wr(slow + t, n), j = wr(i + 1, n);
		double vi = v[i];
		double lim = grip_at(c, vi);
		double ay = vi * vi * fabs(k[i]);
		double trac = c->traction * lim * ellipse(ay, lim);
		double pw = c->power / (c->mass * (vi > 5.0 ? vi : 5.0));
		double acc = (pw < trac ? pw : trac) - c->drag * vi * vi / c->mass;
		double va = sqrt(fmax(vi * vi + 2.0 * acc * ds[i], 0.0));
		if (va < v[j]) v[j] = va;
	}
	double time = 0.0;
	for (int i = 0; i < n; i++) {
		int j = wr(i + 1, n);
		time += 2.0 * ds[i] / (v[i] + v[j] + 1e-6);
	}
	return time;
}

/* Central-difference gradient of the lap time w.r.t. every offset. */
void gradient(int n, const double *cx, const double *cy, const double *nx, const double *ny,
              double *off, const Car *c, double h, double *grad, double *v, double *scratch) {
	for (int i = 0; i < n; i++) {
		double o = off[i];
		off[i] = o + h;
		double tp = profile(n, cx, cy, nx, ny, off, c, v, scratch);
		off[i] = o - h;
		double tm = profile(n, cx, cy, nx, ny, off, c, v, scratch);
		off[i] = o;
		grad[i] = (tp - tm) / (2.0 * h);
	}
}
