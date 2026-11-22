class_name SimTimeseriesBuffer
extends RefCounted
## Bounded, deterministic buffer for the per-run time series.
##
## A run samples every `sample_interval` seconds; a long simulation would
## otherwise grow the per-run JSON without bound (and keep every sample in
## memory). The buffer keeps at most `max_samples` samples:
##
## - while collecting it decimates in place by two whenever the buffer reaches
##   twice the cap (amortised O(1) per append, memory bounded at 2x the cap);
## - `snapshot()` returns at most `max_samples` samples and always includes the
##   last one, so the report still shows how the run ended.
##
## Decimation is a pure function of the append order, so determinism is preserved.
## Every decimation doubles `stride`, which lets reports describe the effective
## sample spacing (`interval * stride` between kept samples in the early part).

## 0 disables the cap (unbounded, like before this class existed).
var max_samples: int = 600
## Current decimation factor: 1 = every sample kept, 2 = every second, ...
var stride: int = 1
var samples: Array[Dictionary] = []


func _init(p_max_samples: int = 600) -> void:
	max_samples = maxi(p_max_samples, 0)


func clear() -> void:
	samples.clear()
	stride = 1


func size() -> int:
	return samples.size()


## Append one sample; decimates in place once the buffer holds twice the cap.
func append(sample: Dictionary) -> void:
	samples.append(sample)
	if max_samples > 0 and samples.size() >= max_samples * 2:
		_decimate_in_place()


## At most `max_samples` samples (deep copies); the last appended sample is kept.
func snapshot() -> Array[Dictionary]:
	if max_samples <= 0 or samples.size() <= max_samples:
		return samples.duplicate(true)
	var step: int = ceili(float(samples.size()) / float(max_samples))
	var kept: Array[Dictionary] = []
	var index: int = 0
	while index < samples.size():
		kept.append(samples[index].duplicate(true))
		index += step
	if kept.size() > max_samples:
		kept.resize(max_samples)
	var last: Dictionary = samples[samples.size() - 1]
	if kept.is_empty():
		kept.append(last.duplicate(true))
		return kept
	if float(kept[kept.size() - 1].get("t", -1.0)) != float(last.get("t", -2.0)):
		if kept.size() < max_samples:
			kept.append(last.duplicate(true))
		else:
			kept[kept.size() - 1] = last.duplicate(true)
	return kept


func _decimate_in_place() -> void:
	var kept: Array[Dictionary] = []
	for index: int in range(0, samples.size(), 2):
		kept.append(samples[index])
	# Keep the most recent sample even when the buffer length is even (indices
	# 0, 2, ... then end at size - 2 and would drop the final sample).
	if not kept.is_empty():
		kept[kept.size() - 1] = samples[samples.size() - 1]
	samples = kept
	stride *= 2
