package file_manager

SPRING_OMEGA :: f32(38)
SPRING_DAMPING :: f32(0.8)
SPRING_SUBSTEP :: f32(1.0/240.0)
SPRING_REST_DISTANCE :: f32(0.05)
SPRING_REST_SPEED :: f32(1.0)

// spring_step advances a damped spring toward target over dt seconds (semi-implicit
// Euler in fixed substeps, stable for any frame time) and returns true once it
// has come to rest on the target.
spring_step :: proc(value, velocity: ^f32, target, dt: f32) -> bool {
	remaining := dt
	for remaining > 0 {
		step := min(remaining, SPRING_SUBSTEP)
		remaining -= step
		acceleration := SPRING_OMEGA*SPRING_OMEGA*(target-value^)-2*SPRING_DAMPING*SPRING_OMEGA*velocity^
		velocity^ += acceleration*step
		value^ += velocity^*step
	}
	if abs(target-value^) < SPRING_REST_DISTANCE && abs(velocity^) < SPRING_REST_SPEED {
		value^ = target
		velocity^ = 0
		return true
	}
	return false
}
