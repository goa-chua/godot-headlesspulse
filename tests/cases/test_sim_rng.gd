extends HpTestCase
## SimRNG: deterministic stream, draw counter, reset, bounded helpers.


func run() -> void:
	var a := SimRNG.new(1234)
	var b := SimRNG.new(1234)
	var first_a: float = a.randf()
	var first_b: float = b.randf()
	assert_almost_eq(first_a, first_b, 0.0, "same seed gives the same first draw")
	for i: int in range(7):
		assert_almost_eq(a.randf(), b.randf(), 0.0, "same seed draw %d" % (i + 2))
	assert_eq(a.draws, 8, "randf increments the draw counter")
	assert_eq(a.get_seed(), 1234, "seed is readable")

	var c := SimRNG.new(4321)
	assert_ne(c.randf(), first_a, "different seeds diverge")

	a.reset(1234)
	assert_eq(a.draws, 0, "reset clears the draw counter")
	assert_almost_eq(a.randf(), first_a, 0.0, "reset replays the stream")

	var ranged := SimRNG.new(7)
	for i: int in range(50):
		var f: float = ranged.randf_range(-5.0, 5.0)
		assert_true(f >= -5.0 and f <= 5.0, "randf_range stays inside the bounds")
		var n: int = ranged.randi_range(2, 4)
		assert_true(n >= 2 and n <= 4, "randi_range stays inside the bounds")
	assert_eq(ranged.draws, 100, "range helpers count one draw each")

	var flags := SimRNG.new(99)
	flags.rand_bool(0.5)
	assert_eq(flags.draws, 1, "rand_bool counts one draw")

	# shuffle() is seeded (global Array.shuffle() is banned in simulated logic).
	var shuffled_a: Array = [1, 2, 3, 4, 5]
	var shuffled_b: Array = [1, 2, 3, 4, 5]
	SimRNG.new(55).shuffle(shuffled_a)
	SimRNG.new(55).shuffle(shuffled_b)
	assert_eq(shuffled_a, shuffled_b, "shuffle is deterministic")
	var sorted_copy: Array = shuffled_a.duplicate()
	sorted_copy.sort()
	assert_eq(sorted_copy, [1, 2, 3, 4, 5], "shuffle keeps the same items")

	assert_eq(SimRNG.new(1).pick([]), null, "pick on empty array returns null")
	assert_true(SimRNG.new(1).rand_vec2(Vector2.ZERO, Vector2.ONE).is_equal_approx(
			SimRNG.new(1).rand_vec2(Vector2.ZERO, Vector2.ONE)), "rand_vec2 is deterministic")
