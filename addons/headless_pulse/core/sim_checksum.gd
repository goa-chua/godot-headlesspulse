class_name SimChecksum
extends RefCounted
## Streaming digest of deterministic per-tick simulation state.
##
## Two runs of the same seed must feed identical bytes; the resulting SHA-256 is
## the "bit-exact" proof used by the determinism acceptance test. Only values
## that are part of the simulation belong here - never wall-clock time.

var _ctx: HashingContext = HashingContext.new()
var samples: int = 0
var _digest_cache: String = ""


func _init() -> void:
	_ctx.start(HashingContext.HASH_SHA256)


func reset() -> void:
	_ctx = HashingContext.new()
	_ctx.start(HashingContext.HASH_SHA256)
	samples = 0
	_digest_cache = ""


## Feed one sampled state (Array of Variants: floats/ints/strings).
func feed(state: Array) -> void:
	var bytes: PackedByteArray = var_to_bytes(state)
	_ctx.update(bytes)
	samples += 1


func update_bytes(bytes: PackedByteArray) -> void:
	_ctx.update(bytes)
	samples += 1


## Finalize once and cache: HashingContext.finish() invalidates the context, so
## calling digest() twice (result + log line) must not finish twice.
func digest() -> String:
	if _digest_cache.is_empty():
		_digest_cache = _ctx.finish().hex_encode()
	return _digest_cache
