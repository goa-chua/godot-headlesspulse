class_name SimRNG
extends RefCounted
## Deterministic RNG wrapper.
##
## All simulation randomness must go through this object: it is seeded from
## `--sim-seed`, it never touches the global RNG, and it counts every draw so
## the run digest can prove that two runs consumed the same random sequence.
##
## Example:
## [codeblock]
## var rng := SimRNG.new(1001)
## var enemy_pos := rng.rand_vec2(Vector2(-400, -200), Vector2(400, 200))
## [/codeblock]

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var draws: int = 0


func _init(p_seed: int = 0) -> void:
	reset(p_seed)


func reset(p_seed: int) -> void:
	_rng.seed = p_seed
	draws = 0


func get_seed() -> int:
	return _rng.seed


func randf() -> float:
	draws += 1
	return _rng.randf()


func randf_range(from: float, to: float) -> float:
	draws += 1
	return _rng.randf_range(from, to)


func randi() -> int:
	draws += 1
	return _rng.randi()


func randi_range(from: int, to: int) -> int:
	draws += 1
	return _rng.randi_range(from, to)


func rand_bool(probability: float = 0.5) -> bool:
	# NOTE: unqualified `randf()` would resolve to the @GlobalScope built-in, not
	# this class's seeded method, so composite helpers qualify with `self.`.
	return self.randf() < probability


func rand_vec2(from: Vector2, to: Vector2) -> Vector2:
	return Vector2(
		self.randf_range(from.x, to.x),
		self.randf_range(from.y, to.y)
	)


func rand_unit_vec2() -> Vector2:
	var angle: float = self.randf_range(0.0, TAU)
	return Vector2(cos(angle), sin(angle))


func pick(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[self.randi_range(0, items.size() - 1)]


## Deterministic shuffle (Array.shuffle() uses the global RNG, so it is banned).
func shuffle(items: Array) -> void:
	for i: int in range(items.size() - 1, 0, -1):
		var j: int = self.randi_range(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp


func rand_range_weighted(entries: Array, weight_key: String) -> Variant:
	## entries: Array[Dictionary]; returns one entry picked by float weight.
	var total: float = 0.0
	for entry: Dictionary in entries:
		total += float(entry.get(weight_key, 0.0))
	if total <= 0.0:
		return self.pick(entries)
	var roll: float = self.randf_range(0.0, total)
	var acc: float = 0.0
	for entry: Dictionary in entries:
		acc += float(entry.get(weight_key, 0.0))
		if roll <= acc:
			return entry
	return entries[entries.size() - 1]


func state() -> int:
	return _rng.state
