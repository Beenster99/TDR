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
## Damage (see CarDamage): steering pull (rad) at full misalignment, grip
## left on a flat tyre, its extra rolling drag, and kerb wear on suspension.
const ALIGN_PULL := 0.035
const PUNCTURE_GRIP := 0.3
const PUNCTURE_ROLL := 0.06
const KERB_WEAR_SPEED := 30.0   ## m/s: kerbs below this do no harm
const KERB_WEAR := 0.004        ## suspension damage per second at +30 m/s over
const KERB_PUNCTURE := 0.03     ## chance per second of a flat, sliding fast over a kerb

const SURFACE_GRIP := {
	TrackData.Surface.TRACK: 1.0,
	TrackData.Surface.KERB: 0.92,
	TrackData.Surface.GRASS: 0.55,
	TrackData.Surface.BARRIER: 0.5,
}
const SURFACE_ROLL := {
	TrackData.Surface.TRACK: 0.0,
	TrackData.Surface.KERB: 0.01,
	TrackData.Surface.GRASS: 0.07,
	TrackData.Surface.BARRIER: 0.1,
}


static func step(s: CarState, inp: CarInput, d: CarDefinition, tc: TyreCompound,
		env: SimEnvironment, track: TrackData, dt: float, fuel_rate: float, events: Array, car_index: int) -> void:
	# --- Where are we on track? ------------------------------------------
	var q := track.project(s.pos, s.track_idx)
	s.track_idx = q["idx"]
	s.track_s = q["s"]
	s.lateral_offset = q["offset"]
	s.surface = track.surface_for(q)
	var surf_mu: float = SURFACE_GRIP[s.surface]
	var surf_roll: float = SURFACE_ROLL[s.surface]
	# Slopes, banking and crests (all zero on a flat track).
	var slope := track.surface_gradient(q)          # uphill vector, rise per metre
	var slope_cos := 1.0 / sqrt(1.0 + slope.length_squared())
	var g_plane := -slope * G * slope_cos           # gravity along the road surface

	# --- Steering (rate limited, damage adds pull later) ------------------
	var steer_target := clampf(inp.steer, -1.0, 1.0) * d.max_steer
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
	var df_front := maxf(q_air * d.aero_balance_front - lost * front_share, 0.0)
	var df_rear := maxf(q_air * (1.0 - d.aero_balance_front) - lost * (1.0 - front_share), 0.0)
	# Weight pressing the car into the road: less on a slope, more in a dip,
	# less over a crest (enough speed over a sharp crest and the car goes light).
	var v_along := s.vel.dot(q["dir"])
	var load_g := clampf(slope_cos + v_along * v_along * track.vertical_curvature_at(s.track_s) / G, 0.2, 3.0)
	s.load_factor = load_g
	var mg := m * G * load_g
	var fz_front := mg * b / L + df_front - m * s.ax * d.cg_height / L
	var fz_rear := mg * a / L + df_rear + m * s.ax * d.cg_height / L
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
	var cap := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for i in 4:
		var mu := tc.peak_mu * tc.temp_grip_factor(s.tyre_temp[i]) * surface_grip
		mu *= 1.0 - tc.load_sensitivity * (fz[i] / fz_nominal - 1.0)
		if i >= 2:
			mu *= d.rear_grip * (1.0 - 0.3 * s.damage_suspension)
		else:
			mu *= d.front_grip * (1.0 - 0.15 * s.damage_suspension)
		if s.puncture[i] > 0.5:
			mu *= PUNCTURE_GRIP
		cap[i] = maxf(mu, 0.1) * fz[i]
	var cap_f := cap[0] + cap[1]
	var cap_r := cap[2] + cap[3]

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
		if s.rpm > d.shift_up_rpm and s.gear < top:
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
	if s.assist_tc and drive_force > 0.0:
		# Traction/stability control: only use the grip the cornering force
		# (from last step) leaves spare, so full throttle mid-corner can't spin.
		var spare_r := sqrt(maxf(cap_r * cap_r * TC_LIMIT * TC_LIMIT - s.fy_rear * s.fy_rear, 0.0))
		var spare_f := sqrt(maxf(cap_f * cap_f * TC_LIMIT * TC_LIMIT - s.fy_front * s.fy_front, 0.0))
		fx_r_demand = minf(fx_r_demand, maxf(spare_r, cap_r * 0.2))
		fx_f_demand = minf(fx_f_demand, maxf(spare_f, cap_f * 0.2))
	if s.assist_abs and brake_total > 0.0:
		# ABS keeps the wheels rolling and leaves room for cornering force.
		var abs_f := maxf(sqrt(maxf(cap_f * cap_f * ABS_LIMIT * ABS_LIMIT - s.fy_front * s.fy_front, 0.0)), cap_f * 0.35)
		var abs_r := maxf(sqrt(maxf(cap_r * cap_r * ABS_LIMIT * ABS_LIMIT - s.fy_rear * s.fy_rear, 0.0)), cap_r * 0.35)
		fx_f_demand = clampf(fx_f_demand, -abs_f, abs_f)
		fx_r_demand = clampf(fx_r_demand, -abs_r, abs_r)
	var excess_f := maxf(absf(fx_f_demand) - cap_f, 0.0)
	var excess_r := maxf(absf(fx_r_demand) - cap_r, 0.0)
	var fx_f := clampf(fx_f_demand, -cap_f, cap_f)
	var fx_r := clampf(fx_r_demand, -cap_r, cap_r)
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
	var lat_cap_f := sqrt(maxf(cap_f * cap_f - fx_f * fx_f, 0.0))
	var lat_cap_r := sqrt(maxf(cap_r * cap_r - fx_r * fx_r, 0.0))
	var fy_f := -lat_cap_f * tc.lateral_curve(alpha_f)
	var fy_r := -lat_cap_r * tc.lateral_curve(alpha_r)
	s.fy_front = fy_f
	s.fy_rear = fy_r
	s.grip_usage_rear = sqrt(fx_r * fx_r + fy_r * fy_r) / maxf(cap_r, 1.0)

	# --- Stability assist: brake one wheel to stop a slide ----------------
	var esc_torque := 0.0
	var esc_drag := 0.0
	if s.assist_stability and vx > 5.0:
		var r_ref := vx * tan(delta) / L
		var r_max := (cap_f + cap_r) / m / vx
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
		var lim := ESC_LIMIT * cap_f * 0.5 * d.track_width * 0.5
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
	var roll := (ROLL_RESIST + surf_roll) * mg * clampf(absf(vx) / 0.5, 0.0, 1.0)
	fx_body -= dir_sign * roll
	var yaw_torque := a * (fx_f * sin_d + fy_f * cos_d) - b * fy_r + esc_torque
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
			s.vel -= normal * vn * 1.3
			s.vel *= 0.85
			s.yaw_rate *= 0.6
			events.append({"type": "barrier_impact", "car": car_index, "speed": vn, "normal": normal})
		s.pos -= normal * 0.2

	# --- Kerbs taken flat out wear the suspension, and can cut a tyre ------
	if full_damage and s.surface == TrackData.Surface.KERB and speed > KERB_WEAR_SPEED:
		var over := (speed - KERB_WEAR_SPEED) / 30.0
		s.damage_suspension = minf(s.damage_suspension + KERB_WEAR * over * over * dt, 1.0)
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
		var heat := tc.heat_from_slip * p_kw + tc.heat_from_rolling * speed * (fz[i] / fz_nominal)
		var cool := tc.cool_to_air * (1.0 + speed / 25.0) * (t - env.ambient_c) + tc.cool_to_track * (t - env.track_c)
		cool += tc.cool_to_water * env.wetness_at(off_line) * (1.0 + speed / 40.0) * (t - env.ambient_c)
		s.tyre_temp[i] = t + (heat - cool) * dt


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
