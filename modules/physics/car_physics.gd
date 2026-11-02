class_name CarPhysics
extends RefCounted
## Deterministic 2D vehicle model (bicycle model with per-tyre temperature).
## Pure function of (state, input, definition, compound, environment, track, dt).
##
## Axes: body X = forward, body Y = right. Positive yaw = clockwise on screen
## (Godot 2D is Y down), so positive steer turns right.

const G := 9.81
const LOW_SPEED := 3.0        ## slip-angle regularisation (m/s)
const ROLL_RESIST := 0.015
const FUEL_DENSITY := 0.74    ## kg per litre
const TC_LIMIT := 0.95        ## traction control: max share of grip used for drive
const ABS_LIMIT := 0.97
const REVERSE_FORCE := 3500.0
const REVERSE_MAX_SPEED := 6.0
## Stability assist (human drivers): how hard it fights a slide, the most
## yaw torque it may use (as a share of braking one front wheel), and how
## much automatic counter-steer it adds.
const ESC_GAIN := 6.0
const ESC_LIMIT := 1.6
const ESC_BETA_GAIN := 3.0
const COUNTER_STEER := 0.8
const STEER_SLIP_MARGIN := 1.3
## Track assist (light, strong): how hard it holds a straight line when the
## driver isn't steering (share of the yaw it cancels), how far from the edge
## it starts to steer the car back (m), and the most steering it ever adds
## (rad). Small on purpose: it helps, it doesn't drive the car.
const TRACK_HOLD := [0.0, 0.35, 0.6]
const TRACK_EDGE_M := [0.0, 2.5, 3.5]
const TRACK_PUSH := [0.0, 0.05, 0.09]
## Damage (see CarDamage): steering pull (rad) at full misalignment, grip
## left on a flat tyre, its extra rolling drag, and kerb wear on suspension.
const ALIGN_PULL := 0.035
const PUNCTURE_GRIP := 0.3
const PUNCTURE_ROLL := 0.06
const KERB_WEAR_SPEED := 30.0   ## m/s: kerbs below this do no harm
const KERB_WEAR := 0.004        ## suspension damage per second at +30 m/s over
const KERB_PUNCTURE := 0.03     ## chance per second of a flat, sliding fast over a kerb
## Tyre wear: grip lost on a fully worn tyre (falls off faster near the end),
## and the wear from just rolling, as if this much slip power (kW) at 50 m/s.
const WEAR_GRIP_LOSS := 0.32
const WEAR_BASE_KW := 2.0
## Setup (wave 4, see CarSetup in the cars module).
## Ground effect: downforce gained per mm the floor runs below its default
## height, and the floor touching the ground (bottoming) over this many mm
## costs up to these shares of grip and downforce.
const GROUND_EFFECT := 0.004
const BOTTOM_RANGE_MM := 10.0
const BOTTOM_GRIP := 0.45
const BOTTOM_AERO := 0.4
const BOTTOM_DRAG := 0.04
## Stiffer suspension: grip lost per unit of stiffness everywhere, and over
## bumps (dips, crests and kerbs). Softer gains it back.
const STIFF_GRIP := 0.03
const STIFF_BUMP_GRIP := 0.12
const KERB_BUMP := 0.35
## Camber: cornering grip lost one 1.5 deg off the best camber, braking and
## traction grip lost per degree of camber beyond the default, heat per degree.
const CAMBER_GRIP := 0.06
const CAMBER_LONG := 0.012
const CAMBER_HEAT := 0.08
## Toe: rear toe-in grip per degree, rolling drag and tyre heat per degree.
const TOE_REAR_GRIP := 0.08
const TOE_DRAG := 0.012
const TOE_HEAT := 1.2
## Limited-slip diff: locking left when fully open, and how hard a locked
## diff resists the car turning (understeer on power, stability off it).
const DIFF_MIN_LOCK := 0.35
const DIFF_YAW := 0.15

const SURFACE_GRIP := {
	TrackData.Surface.TRACK: 1.0,
	TrackData.Surface.KERB: 0.92,
	TrackData.Surface.GRASS: 0.55,
	TrackData.Surface.BARRIER: 0.5,
	TrackData.Surface.GRAVEL: 0.55,
	TrackData.Surface.RUNOFF: 0.95,
}
const SURFACE_ROLL := {
	TrackData.Surface.TRACK: 0.0,
	TrackData.Surface.KERB: 0.01,
	TrackData.Surface.GRASS: 0.07,
	TrackData.Surface.BARRIER: 0.1,
	TrackData.Surface.GRAVEL: 0.3,    # a gravel trap digs in and stops the car
	TrackData.Surface.RUNOFF: 0.0,
}
## Gravel digs in hard at speed (SURFACE_ROLL) but a car that has stopped in
## it can crawl out: below GRAVEL_CRAWL_SPEED the drag eases to
## GRAVEL_CRAWL_ROLL, back up to the full drag by GRAVEL_DIG_SPEED (m/s).
const GRAVEL_CRAWL_ROLL := 0.1
const GRAVEL_CRAWL_SPEED := 5.0
const GRAVEL_DIG_SPEED := 18.0


## wear_rate: tyre wear multiplier (0 = tyres never wear, 1 = normal).
## wheel_tc: the compound on each wheel (FL, FR, RL, RR) when a car runs
## mixed tyres after a pit stop; empty = tc on all four.
static func step(s: CarState, inp: CarInput, d: CarDefinition, tc: TyreCompound,
		env: SimEnvironment, track: TrackData, dt: float, fuel_rate: float, events: Array, car_index: int,
		wear_rate: float = 0.0, wheel_tc: Array = []) -> void:
	var wtc: Array = wheel_tc if wheel_tc.size() == 4 else [tc, tc, tc, tc]
	var mixed: bool = wtc[0] != tc or wtc[1] != tc or wtc[2] != tc or wtc[3] != tc
	# --- Where are we on track? ------------------------------------------
	var q := track.project(s.pos, s.track_idx)
	s.track_idx = q["idx"]
	s.track_s = q["s"]
	s.lateral_offset = q["offset"]
	s.surface = track.surface_for(q)
	var surf_mu: float = SURFACE_GRIP[s.surface]
	var surf_roll: float = SURFACE_ROLL[s.surface]
	if s.surface == TrackData.Surface.GRAVEL:
		surf_roll = lerpf(GRAVEL_CRAWL_ROLL, surf_roll, smoothstep(GRAVEL_CRAWL_SPEED, GRAVEL_DIG_SPEED, s.vel.length()))
	# Slopes, banking and crests (all zero on a flat track).
	var slope := track.surface_gradient(q)          # uphill vector, rise per metre
	var slope_cos := 1.0 / sqrt(1.0 + slope.length_squared())
	var g_plane := -slope * G * slope_cos           # gravity along the road surface

	# --- Steering (rate limited, damage adds pull later) ------------------
	var steer_target := clampf(inp.steer, -1.0, 1.0) * d.max_steer
	if s.assist_track > 0:
		steer_target = _track_assist(s, inp, steer_target, d, track, q)
	if s.assist_stability:
		steer_target = _assisted_steer(s, steer_target, d, tc)
	s.steer_angle = move_toward(s.steer_angle, steer_target, d.steer_rate * dt)
	var full_damage := s.damage_level == CarDamage.Level.FULL
	var delta := s.steer_angle + (s.alignment * ALIGN_PULL if full_damage else 0.0)
	var cos_d := cos(delta)
	var sin_d := sin(delta)

	var fwd := s.forward()
	var rgt := s.right()
	var vx := s.vel.dot(fwd)
	var vy := s.vel.dot(rgt)
	var speed := s.vel.length()
	var rho := env.air_density()
	var m := d.mass + s.fuel_l * FUEL_DENSITY
	var a := d.cg_to_front
	var b := d.wheelbase - a
	var L := d.wheelbase

	# --- Vertical loads (static + aero + longitudinal/lateral transfer) ----
	# Aero damage takes downforce away from the end that was hit.
	var front_share := 0.5
	var bent := s.body_damage[CarDamage.FRONT] + s.body_damage[CarDamage.REAR]
	if bent > 0.001:
		front_share = s.body_damage[CarDamage.FRONT] / bent
	var q_air := 0.5 * rho * d.cla * vx * vx
	var lost := 0.6 * s.damage_aero * q_air
	# Weight pressing the car into the road: less on a slope, more in a dip,
	# less over a crest (enough speed over a sharp crest and the car goes light).
	var v_along := s.vel.dot(q["dir"])
	var load_g := clampf(slope_cos + v_along * v_along * track.vertical_curvature_at(s.track_s) / G, 0.2, 3.0)
	s.load_factor = load_g
	var mg := m * G * load_g
	# Ride height: the springs squash under downforce, braking/accelerating and
	# in dips (dampers slow the dips and crests down), and stretch over crests.
	var lon_transfer := m * s.ax * d.cg_height / L
	var heave := m * G * (load_g - 1.0)
	var aero_f0 := q_air * d.aero_balance_front
	var aero_r0 := q_air * (1.0 - d.aero_balance_front)
	var sink_f := (heave * b / L / sqrt(d.damper_front) - lon_transfer + aero_f0) / (2.0 * d.spring_front)
	var sink_r := (heave * a / L / sqrt(d.damper_rear) + lon_transfer + aero_r0) / (2.0 * d.spring_rear)
	s.ride_front = d.ride_front_mm - sink_f
	s.ride_rear = d.ride_rear_mm - sink_r
	var bottom_f := clampf((d.plank_mm - s.ride_front) / BOTTOM_RANGE_MM, 0.0, 1.0)
	var bottom_r := clampf((d.plank_mm - s.ride_rear) / BOTTOM_RANGE_MM, 0.0, 1.0)
	s.bottoming = maxf(bottom_f, bottom_r)
	# Lower floor, more downforce (until it hits the ground and stalls).
	var ground := clampf(1.0 + GROUND_EFFECT * (d.ride_ref_mm - (s.ride_front + s.ride_rear) * 0.5), 0.85, 1.2)
	var df_front := maxf(aero_f0 * ground * (1.0 - BOTTOM_AERO * bottom_f) - lost * front_share, 0.0)
	var df_rear := maxf(aero_r0 * ground * (1.0 - BOTTOM_AERO * bottom_r) - lost * (1.0 - front_share), 0.0)
	var fz_front := mg * b / L + df_front - lon_transfer
	var fz_rear := mg * a / L + df_rear + lon_transfer
	fz_front = maxf(fz_front, 0.15 * mg * b / L)
	fz_rear = maxf(fz_rear, 0.15 * mg * a / L)
	# Positive ay (turning right) moves load onto the left (outside) tyres.
	var lat_transfer := m * s.ay * d.cg_height / d.track_width
	var tf := lat_transfer * d.roll_stiffness_front
	var tr := lat_transfer - tf
	var fz := PackedFloat64Array([
		maxf(fz_front * 0.5 + tf, 0.0), maxf(fz_front * 0.5 - tf, 0.0),
		maxf(fz_rear * 0.5 + tr, 0.0), maxf(fz_rear * 0.5 - tr, 0.0)])
	var fz_nominal := m * G * 0.25

	# --- Per-tyre friction capacity -------------------------------------
	var off_line := s.lateral_offset - env.raceline_offset(s.track_idx)
	var surface_grip := env.grip_factor(tc, off_line, speed) * surf_mu
	var wheel_surface := PackedFloat64Array([surface_grip, surface_grip, surface_grip, surface_grip])
	if mixed:
		for i in 4:
			wheel_surface[i] = env.grip_factor(wtc[i], off_line, speed) * surf_mu
	# Setup: stiff suspension loses grip over bumps and kerbs, camber trades
	# cornering grip (best at the right camber once the body rolls) against
	# braking and traction, rear toe-in steadies the rear.
	var bump := absf(load_g - slope_cos) + (KERB_BUMP if s.surface == TrackData.Surface.KERB else 0.0)
	var stiff_f := 0.6 * d.spring_front / d.spring_ref_front + 0.4 * d.damper_front
	var stiff_r := 0.6 * d.spring_rear / d.spring_ref_rear + 0.4 * d.damper_rear
	var mech_f := clampf(1.0 - (stiff_f - 1.0) * (STIFF_GRIP + STIFF_BUMP_GRIP * bump), 0.85, 1.08) * (1.0 - BOTTOM_GRIP * bottom_f)
	var mech_r := clampf(1.0 - (stiff_r - 1.0) * (STIFF_GRIP + STIFF_BUMP_GRIP * bump), 0.85, 1.08) * (1.0 - BOTTOM_GRIP * bottom_r)
	var roll_deg := absf(s.ay) / G * d.roll_deg_per_g / maxf(d.roll_stiffness, 0.3)
	var cam_f := (d.camber_front + d.camber_gain * roll_deg - d.camber_opt_front) / 1.5
	var cam_r := (d.camber_rear + d.camber_gain * roll_deg - d.camber_opt_rear) / 1.5
	var lat_f := maxf(1.0 - CAMBER_GRIP * cam_f * cam_f, 0.88)
	var lat_r := maxf(1.0 - CAMBER_GRIP * cam_r * cam_r, 0.88) * (1.0 + TOE_REAR_GRIP * d.toe_rear)
	var lon_f := 1.0 - CAMBER_LONG * (absf(d.camber_front) - absf(d.camber_ref_front))
	var lon_r := 1.0 - CAMBER_LONG * (absf(d.camber_rear) - absf(d.camber_ref_rear))
	var cap := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])     # braking / traction
	var cap_y := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])   # cornering
	var p_heat := PackedFloat64Array([1.0, 1.0, 1.0, 1.0])
	for i in 4:
		var t_c: TyreCompound = wtc[i]
		var mu := t_c.peak_mu * t_c.temp_grip_factor(s.tyre_temp[i]) * wheel_surface[i] * wear_grip_factor(s.tyre_wear[i])
		mu *= 1.0 - t_c.load_sensitivity * (fz[i] / fz_nominal - 1.0)
		var cold_delta := (d.pressure_delta_front if i < 2 else d.pressure_delta_rear) + s.psi_trim[i]
		var p_hot := t_c.hot_psi(cold_delta, s.tyre_temp[i])
		s.tyre_psi[i] = p_hot
		mu *= t_c.pressure_grip_factor(p_hot)
		p_heat[i] = t_c.pressure_heat_factor(p_hot)
		if i >= 2:
			mu *= d.rear_grip * (1.0 - 0.3 * s.damage_suspension) * mech_r
		else:
			mu *= d.front_grip * (1.0 - 0.15 * s.damage_suspension) * mech_f
		if s.puncture[i] > 0.5:
			mu *= PUNCTURE_GRIP
		mu = maxf(mu, 0.1)
		cap[i] = mu * fz[i] * (lon_f if i < 2 else lon_r)
		cap_y[i] = mu * fz[i] * (lat_f if i < 2 else lat_r)
	var cap_f := cap[0] + cap[1]
	var cap_r := cap[2] + cap[3]
	var cap_yf := cap_y[0] + cap_y[1]
	var cap_yr := cap_y[2] + cap_y[3]

	# --- Engine & gearbox (automatic in wave 1) -----------------------------
	var n_gears := d.gear_count()
	var throttle := clampf(inp.throttle, 0.0, 1.0)
	var brake := clampf(inp.brake, 0.0, 1.0)
	if s.gear == -1:
		# In reverse, throttle pedal brakes, brake pedal drives backwards.
		if throttle > 0.1 and vx > -0.5:
			s.gear = 1
	elif brake > 0.5 and throttle < 0.05 and s.vel.length() < 0.4:
		s.gear = -1
	var drive_force := 0.0
	var power_kw := 0.0
	if s.gear >= 1:
		var ratio := d.gear_ratios[s.gear - 1] * d.final_drive
		var wheel_rpm := vx / d.wheel_radius * 60.0 / TAU
		s.rpm = maxf(d.idle_rpm, wheel_rpm * ratio)
		var top := CarDamage.usable_gears(s, n_gears) if full_damage else n_gears
		var gear_was := s.gear
		if s.manual_gears:
			_manual_shift(s, inp, d, wheel_rpm, top)
		elif s.rpm > d.shift_up_rpm and s.gear < top:
			s.gear += 1
		elif s.gear > top:
			s.gear = top
		elif s.rpm < d.shift_down_rpm and s.gear > 1:
			var lower := d.gear_ratios[s.gear - 2] * d.final_drive
			if wheel_rpm * lower < d.shift_up_rpm * 0.97:
				s.gear -= 1
		if s.gear != gear_was and full_damage and s.damage_gearbox > 0.05:
			s.shift_cut = CarDamage.GEARBOX_SHIFT_CUT * s.damage_gearbox
		ratio = d.gear_ratios[s.gear - 1] * d.final_drive
		s.rpm = maxf(d.idle_rpm, wheel_rpm * ratio)
		var eff_rpm := maxf(s.rpm, d.idle_rpm * 2.5)  # clutch slip off the line
		var torque := d.torque_at(eff_rpm) * throttle * (rho / 1.225) * (1.0 - 0.5 * s.damage_engine)
		if s.rpm >= d.redline_rpm:
			torque = 0.0
		if s.fuel_l <= 0.0 and fuel_rate > 0.0:
			torque = 0.0
		if full_damage:
			if s.shift_cut > 0.0:
				s.shift_cut = maxf(s.shift_cut - dt, 0.0)
				torque = 0.0
			if CarDamage.engine_failed(s):
				torque = 0.0
			elif s.damage_engine > CarDamage.ENGINE_LEAK_FROM:
				# A damaged engine gets worse the harder it is worked.
				var load := throttle * clampf(s.rpm / d.redline_rpm, 0.0, 1.0)
				s.damage_engine = minf(s.damage_engine + CarDamage.ENGINE_LEAK_RATE * s.damage_engine * load * dt, 1.0)
		drive_force = torque * ratio * d.drivetrain_efficiency / d.wheel_radius
		power_kw = torque * s.rpm * TAU / 60.0 / 1000.0
		if throttle < 0.05 and vx > 1.0:
			drive_force -= d.engine_brake_nm * (s.rpm / d.redline_rpm) * ratio / d.wheel_radius
	else:
		s.rpm = d.idle_rpm
		if s.manual_gears and inp.shift_up and not s.shift_held and vx > -1.0:
			s.gear = 1   # out of reverse
		s.shift_held = inp.shift_up or inp.shift_down
		if vx > -REVERSE_MAX_SPEED:
			drive_force = -brake * REVERSE_FORCE
		brake = throttle  # throttle acts as brake while reversing
	if fuel_rate > 0.0:
		s.fuel_l = maxf(0.0, s.fuel_l - power_kw * d.bsfc_l_per_kwh / 3600.0 * dt * fuel_rate)

	# --- Longitudinal forces per axle -------------------------------------
	var dir_sign := 1.0 if vx >= 0.0 else -1.0
	var brake_total := brake * d.brake_force
	# Do not let brakes push a nearly stopped car backwards.
	var brake_scale := clampf(absf(vx) / 0.5, 0.0, 1.0)
	var fx_f_demand := drive_force * d.front_drive_split - dir_sign * brake_total * d.brake_bias_front * brake_scale
	var fx_r_demand := drive_force * (1.0 - d.front_drive_split) - dir_sign * brake_total * (1.0 - d.brake_bias_front) * brake_scale
	# Under power the diff decides how much of the axle's grip can drive: an
	# open diff only what the lighter (inside) wheel holds, a locked one both.
	var drive_f := cap_f
	var drive_r := cap_r
	if fx_r_demand > 0.0:
		drive_r = lerpf(2.0 * minf(cap[2], cap[3]), cap_r, DIFF_MIN_LOCK + (1.0 - DIFF_MIN_LOCK) * d.diff_power)
	if fx_f_demand > 0.0:
		drive_f = lerpf(2.0 * minf(cap[0], cap[1]), cap_f, DIFF_MIN_LOCK + (1.0 - DIFF_MIN_LOCK) * d.diff_power)
	if s.assist_tc and drive_force > 0.0:
		# Traction/stability control: only use the grip the cornering force
		# (from last step) leaves spare, so full throttle mid-corner can't spin.
		var use_r := s.fy_rear / maxf(cap_yr, 1.0)
		var use_f := s.fy_front / maxf(cap_yf, 1.0)
		var spare_r := drive_r * sqrt(maxf(TC_LIMIT * TC_LIMIT - use_r * use_r, 0.0))
		var spare_f := drive_f * sqrt(maxf(TC_LIMIT * TC_LIMIT - use_f * use_f, 0.0))
		fx_r_demand = minf(fx_r_demand, maxf(spare_r, drive_r * 0.2))
		fx_f_demand = minf(fx_f_demand, maxf(spare_f, drive_f * 0.2))
	if s.assist_abs and brake_total > 0.0:
		# ABS keeps the wheels rolling and leaves room for cornering force.
		var ab_f := s.fy_front / maxf(cap_yf, 1.0)
		var ab_r := s.fy_rear / maxf(cap_yr, 1.0)
		var abs_f := maxf(cap_f * sqrt(maxf(ABS_LIMIT * ABS_LIMIT - ab_f * ab_f, 0.0)), cap_f * 0.35)
		var abs_r := maxf(cap_r * sqrt(maxf(ABS_LIMIT * ABS_LIMIT - ab_r * ab_r, 0.0)), cap_r * 0.35)
		fx_f_demand = clampf(fx_f_demand, -abs_f, abs_f)
		fx_r_demand = clampf(fx_r_demand, -abs_r, abs_r)
	var excess_f := maxf(absf(fx_f_demand) - drive_f, 0.0)
	var excess_r := maxf(absf(fx_r_demand) - drive_r, 0.0)
	var fx_f := clampf(fx_f_demand, -drive_f, drive_f)
	var fx_r := clampf(fx_r_demand, -drive_r, drive_r)
	# Spinning / locked tyres slide: kinetic friction is a bit lower.
	if excess_f > 0.0:
		fx_f *= 0.9
	if excess_r > 0.0:
		fx_r *= 0.9
	s.wheelspin = excess_r > 0.0 and drive_force > 0.0

	# --- Lateral forces (simplified Pacejka with friction circle) ----------
	var vy_front := vy + s.yaw_rate * a
	var v_wheel_long := vx * cos_d + vy_front * sin_d
	var v_wheel_lat := -vx * sin_d + vy_front * cos_d
	var alpha_f := atan2(v_wheel_lat, maxf(absf(v_wheel_long), LOW_SPEED))
	var vy_rear := vy - s.yaw_rate * b
	var alpha_r := atan2(vy_rear, maxf(absf(vx), LOW_SPEED))
	s.slip_angle_front = alpha_f
	s.slip_angle_rear = alpha_r
	var lat_cap_f := cap_yf * sqrt(maxf(1.0 - (fx_f / maxf(cap_f, 1.0)) ** 2, 0.0))
	var lat_cap_r := cap_yr * sqrt(maxf(1.0 - (fx_r / maxf(cap_r, 1.0)) ** 2, 0.0))
	var fy_f := -lat_cap_f * tc.lateral_curve(alpha_f)
	var fy_r := -lat_cap_r * tc.lateral_curve(alpha_r)
	if mixed:
		# Each axle's slip curve is the average of its two tyres.
		fy_f = -lat_cap_f * 0.5 * ((wtc[0] as TyreCompound).lateral_curve(alpha_f) + (wtc[1] as TyreCompound).lateral_curve(alpha_f))
		fy_r = -lat_cap_r * 0.5 * ((wtc[2] as TyreCompound).lateral_curve(alpha_r) + (wtc[3] as TyreCompound).lateral_curve(alpha_r))
	s.fy_front = fy_f
	s.fy_rear = fy_r
	s.grip_usage_rear = sqrt((fx_r / maxf(cap_r, 1.0)) ** 2 + (fy_r / maxf(cap_yr, 1.0)) ** 2)

	# --- Stability assist: brake one wheel to stop a slide ----------------
	var esc_torque := 0.0
	var esc_drag := 0.0
	if s.assist_stability and vx > 5.0:
		var r_ref := vx * tan(delta) / L
		var r_max := (cap_yf + cap_yr) / m / vx
		r_ref = clampf(r_ref, -r_max, r_max)
		var beta := atan2(vy, vx)
		# Positive yaw error = rotating clockwise more than the steering asks.
		var err := s.yaw_rate - r_ref
		var demand := 0.0
		if (signf(err) == signf(s.yaw_rate) and absf(err) > 0.03) or absf(beta) > 0.07:
			demand = -ESC_GAIN * err * d.inertia
			# Sideslip: the car points further round than it travels.
			var beta_x := beta - clampf(beta, -0.07, 0.07)
			demand += ESC_BETA_GAIN * beta_x * d.inertia * vx / L
		var lim := ESC_LIMIT * cap_yf * 0.5 * d.track_width * 0.5
		esc_torque = clampf(demand, -lim, lim)
		esc_drag = absf(esc_torque) / (d.track_width * 0.5)
		if fx_r > 0.0:
			fx_r *= 1.0 - 0.7 * absf(esc_torque) / maxf(lim, 1.0)
		if fx_f > 0.0:
			fx_f *= 1.0 - 0.7 * absf(esc_torque) / maxf(lim, 1.0)

	# --- Body forces ------------------------------------------------------
	var fx_body := fx_f * cos_d - fy_f * sin_d + fx_r - esc_drag
	var fy_body := fx_f * sin_d + fy_f * cos_d + fy_r
	fx_body -= 0.5 * rho * d.cda * (1.0 + 0.3 * s.damage_aero) * vx * absf(vx)
	fy_body -= 0.5 * rho * d.cda * 2.5 * vy * absf(vy)
	var scrub := TOE_DRAG * (absf(d.toe_front) + absf(d.toe_rear)) + BOTTOM_DRAG * s.bottoming
	var roll := (ROLL_RESIST + surf_roll + scrub) * mg * clampf(absf(vx) / 0.5, 0.0, 1.0)
	fx_body -= dir_sign * roll
	var yaw_torque := a * (fx_f * sin_d + fy_f * cos_d) - b * fy_r + esc_torque
	# A locked diff makes both driven wheels turn at the same speed, which
	# resists the car turning: understeer on power, stability when lifting.
	if s.gear >= 1 and absf(vx) > 3.0:
		var through_diff := drive_force * (1.0 - d.front_drive_split)
		var lock := d.diff_power if through_diff > 0.0 else d.diff_coast
		var rel := s.yaw_rate * d.track_width / absf(vx)
		yaw_torque -= DIFF_YAW * lock * minf(absf(through_diff), cap_r) * d.track_width * 0.5 * clampf(rel / 0.05, -1.0, 1.0)
	# A flat tyre drags: slows the car and pulls it towards that side.
	if full_damage and absf(vx) > 0.5:
		for i in 4:
			if s.puncture[i] > 0.5:
				var drag := PUNCTURE_ROLL * fz[i] * dir_sign
				fx_body -= drag
				yaw_torque += drag * d.track_width * 0.5 * (1.0 if i % 2 == 1 else -1.0)

	# ax / ay are what the driver feels (tyres and air); they drive load
	# transfer. Gravity along the slope adds to the motion on top: uphill
	# slows the car, downhill makes it harder to stop, banking holds it in.
	s.ax = fx_body / m
	s.ay = fy_body / m
	s.vel += (fwd * s.ax + rgt * s.ay + g_plane) * dt
	s.yaw_rate += yaw_torque / d.inertia * dt
	# Parking: kill creep when stationary with no drive. On a hill only the
	# brakes hold the car (if they're strong enough for the slope).
	if speed < 0.3 and absf(drive_force) < 1.0:
		if brake > 0.1 and brake * d.brake_force > g_plane.length() * m * 1.2:
			s.vel = Vector2.ZERO
			s.yaw_rate *= 0.5
		elif g_plane.length() < 0.3:
			s.vel *= 0.8
			s.yaw_rate *= 0.8
	s.pos += s.vel * dt
	s.heading = wrapf(s.heading + s.yaw_rate * dt, -PI, PI)

	# --- Outer barrier (soft wall at the edge of the run-off) ---------------
	if s.surface == TrackData.Surface.BARRIER:
		var side := 1.0 if s.lateral_offset >= 0.0 else -1.0
		var dirv: Vector2 = q["dir"]
		var normal := Vector2(-dirv.y, dirv.x) * side  # points away from track
		var vn := s.vel.dot(normal)
		if vn > 0.0:
			# Walls throw the car back, tyre walls and fencing soak it up.
			var kind := track.barrier_for(q)
			s.vel -= normal * vn * float(TrackData.BARRIER_REBOUND[kind])
			s.vel *= 0.85 if kind == TrackData.Barrier.WALL or kind == TrackData.Barrier.ARMCO else 0.7
			s.yaw_rate *= 0.6
			events.append({"type": "barrier_impact", "car": car_index, "speed": vn, "normal": normal, "barrier": kind})
		s.pos -= normal * 0.2

	# --- Kerbs taken flat out wear the suspension, and can cut a tyre ------
	if full_damage and s.surface == TrackData.Surface.KERB and speed > KERB_WEAR_SPEED:
		var over := (speed - KERB_WEAR_SPEED) / 30.0
		s.damage_suspension = minf(s.damage_suspension + KERB_WEAR * over * over * maxf(stiff_f, 0.5) * dt, 1.0)
		if absf(vy) > 3.0:
			var salt := int(s.pos.x * 64.0) * 92821 + int(s.pos.y * 64.0)
			if CarDamage.roll(salt) < KERB_PUNCTURE * dt:
				# The wheels on the kerb are the ones on that edge of the track.
				var wheel := CarState.FR if s.lateral_offset >= 0.0 else CarState.FL
				if s.puncture[wheel] < 0.5:
					s.puncture[wheel] = 1.0
					events.append({"type": "puncture", "car": car_index, "wheel": wheel, "cause": "kerb"})

	# --- Tyre temperatures ------------------------------------------------
	var slip_v_f := absf(v_wheel_lat)
	var slip_v_r := absf(vy_rear)
	var long_slip_f := 0.02 * absf(fx_f) / maxf(cap_f, 1.0) * absf(vx) + minf(excess_f / maxf(cap_f, 1.0), 1.0) * minf(absf(vx) + 5.0, 20.0)
	var long_slip_r := 0.02 * absf(fx_r) / maxf(cap_r, 1.0) * absf(vx) + minf(excess_r / maxf(cap_r, 1.0), 1.0) * minf(absf(vx) + 5.0, 20.0)
	var axle_power := PackedFloat64Array([
		(absf(fy_f) * slip_v_f + absf(fx_f) * long_slip_f) / 1000.0,
		(absf(fy_r) * slip_v_r + absf(fx_r) * long_slip_r) / 1000.0])
	for i in 4:
		var axle_fz := fz[0] + fz[1] if i < 2 else fz[2] + fz[3]
		var share := fz[i] / maxf(axle_fz, 1.0)
		var p_kw: float = axle_power[0 if i < 2 else 1] * share
		var t := s.tyre_temp[i]
		var t_c: TyreCompound = wtc[i]
		# Softer (lower pressure) tyres flex and heat more; camber works the
		# inside edge harder; toe scrubs.
		var camber := absf(d.camber_front if i < 2 else d.camber_rear)
		var toe := absf(d.toe_front if i < 2 else d.toe_rear)
		# Rolling heat follows the load against what that tyre carries at rest
		# (the rear tyres are bigger for the bigger static load).
		var fz_static := m * G * 0.5 * (b if i < 2 else a) / L
		var heat := (t_c.heat_from_slip * p_kw + t_c.heat_from_rolling * speed * (fz[i] / fz_static)) \
			* p_heat[i] * (1.0 + CAMBER_HEAT * (camber - 2.0)) + TOE_HEAT * toe * speed / 50.0
		var cool := t_c.cool_to_air * (1.0 + speed / t_c.cool_speed_ms) * (t - env.ambient_c) + t_c.cool_to_track * (t - env.track_c)
		cool += t_c.cool_to_water * env.wetness_at(off_line) * (1.0 + speed / 40.0) * (t - env.ambient_c)
		s.tyre_temp[i] = t + (heat - cool) * dt
		if wear_rate > 0.0:
			# Wear follows the sliding work, and grows fast on a tyre run
			# hotter than its window (e.g. wets on a drying track).
			var over := maxf(t - t_c.optimal_temp_c - t_c.temp_window_c * 0.5, 0.0) / t_c.temp_window_c
			var press := absf(s.tyre_psi[i] - t_c.optimal_hot_psi) / t_c.pressure_window_psi
			var w := t_c.wear_rate * wear_rate * (p_kw + WEAR_BASE_KW * speed / 50.0) * (1.0 + 3.0 * over) * (1.0 + 0.25 * press) * dt / 1000.0
			s.tyre_wear[i] = minf(s.tyre_wear[i] + w, 1.0)


## Grip left on a tyre with this much wear (0 = new .. 1 = worn out).
static func wear_grip_factor(wear: float) -> float:
	return 1.0 - WEAR_GRIP_LOSS * pow(clampf(wear, 0.0, 1.0), 1.6)


## Manual gearbox: one gear per press. A downshift that would over-rev the
## engine is refused (the gearbox protects itself), like most race cars.
static func _manual_shift(s: CarState, inp: CarInput, d: CarDefinition, wheel_rpm: float, top: int) -> void:
	var pressed := inp.shift_up or inp.shift_down
	if pressed and not s.shift_held:
		if inp.shift_up and s.gear < top:
			s.gear += 1
		elif inp.shift_down and s.gear > 1:
			if wheel_rpm * d.gear_ratios[s.gear - 2] * d.final_drive < d.redline_rpm * 1.02:
				s.gear -= 1
	s.shift_held = pressed
	if s.gear > top:
		s.gear = top


## Track assist: with no steering input it cancels part of any yaw so the
## car runs straight, and near the edge it steers gently back towards the
## track when the car is heading off. Only on the track and kerbs, only
## forwards at speed.
static func _track_assist(s: CarState, inp: CarInput, target: float, d: CarDefinition,
		track: TrackData, q: Dictionary) -> float:
	var vx := s.vel.dot(s.forward())
	if vx < 8.0 or s.surface > TrackData.Surface.KERB:
		return target
	var lvl := clampi(s.assist_track, 0, 2)
	var add := 0.0
	# Straight line: the steering it takes to cancel the yaw, faded out as
	# the driver steers.
	var hands_off := 1.0 - clampf(absf(inp.steer) / 0.08, 0.0, 1.0)
	add -= TRACK_HOLD[lvl] * hands_off * s.yaw_rate * d.wheelbase / vx
	# Edge: closer to the edge and heading out faster = more push back.
	var dirv: Vector2 = q["dir"]
	var nrm := Vector2(-dirv.y, dirv.x)   # + = right of the track
	var off: float = q["offset"]
	var edge: float = (q["w_right"] if off >= 0.0 else q["w_left"])
	var side := 1.0 if off >= 0.0 else -1.0
	var room := edge - absf(off)
	var reach: float = TRACK_EDGE_M[lvl]
	var out_v := s.vel.dot(nrm) * side     # m/s towards that edge
	if room < reach and out_v > 0.0:
		var near := 1.0 - clampf(room / reach, 0.0, 1.0)
		var heading_out := clampf(out_v / maxf(vx * 0.12, 1.0), 0.0, 1.0)
		add -= side * TRACK_PUSH[lvl] * near * heading_out
	add = clampf(add, -TRACK_PUSH[lvl], TRACK_PUSH[lvl])
	return clampf(target + add, -d.max_steer, d.max_steer)


## Steering help: adds counter-steer when the rear slides, and at speed keeps
## the front tyres from being turned far past their best slip angle (where
## they just scrub and then snap the car round when they grip again).
static func _assisted_steer(s: CarState, target: float, d: CarDefinition, tc: TyreCompound) -> float:
	var excess := s.slip_angle_rear - clampf(s.slip_angle_rear, -0.05, 0.05)
	target += COUNTER_STEER * excess
	var vx := s.vel.dot(s.forward())
	if vx > 8.0:
		var kin := d.wheelbase * 2.0 * G / (vx * vx)
		var cap := kin + tc.peak_slip_angle * STEER_SLIP_MARGIN + absf(excess) * COUNTER_STEER
		target = clampf(target, -cap, cap)
	return clampf(target, -d.max_steer, d.max_steer)
