extends HpTestCase
## SimChecksum: deterministic SHA-256 over fed state, caching, reset.


func run() -> void:
	var state: Array = [1, 2.5, "player", Vector2(10.0, -20.0)]
	var a := SimChecksum.new()
	var b := SimChecksum.new()
	a.feed(state)
	b.feed(state)
	assert_eq(a.samples, 1, "feed counts a sample")
	assert_eq(a.digest(), b.digest(), "identical state gives identical digest")
	assert_eq(a.digest().length(), 64, "digest is hex-encoded SHA-256")
	assert_eq(a.digest(), a.digest(), "digest is cached and stable")

	var c := SimChecksum.new()
	c.feed([1, 2.5, "player", Vector2(10.0, -19.0)])
	assert_ne(c.digest(), a.digest(), "different state gives a different digest")

	var empty_digest: String = SimChecksum.new().digest()
	var reset := SimChecksum.new()
	reset.feed([0])
	reset.reset()
	assert_eq(reset.samples, 0, "reset clears the sample counter")
	assert_eq(reset.digest(), empty_digest, "reset restores the empty digest")

	var stream_a := SimChecksum.new()
	stream_a.feed([1])
	stream_a.feed([2])
	var stream_b := SimChecksum.new()
	stream_b.feed([1])
	stream_b.feed([2])
	assert_eq(stream_a.samples, 2, "streamed feeds count twice")
	assert_eq(stream_a.digest(), stream_b.digest(), "streamed feeds are deterministic")

	var bytes := SimChecksum.new()
	bytes.update_bytes(PackedByteArray([1, 2, 3]))
	assert_eq(bytes.samples, 1, "update_bytes counts a sample")
	assert_eq(bytes.digest().length(), 64, "byte digest is hex-encoded SHA-256")
