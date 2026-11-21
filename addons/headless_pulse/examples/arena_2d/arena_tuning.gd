class_name ArenaTuning
extends Resource
## Balance knobs of the demo arena. This is the `.tres` an agent A/B tests:
##
##   godot ... -s res://addons/headless_pulse/cli/run_sim.gd -- --sim-mode --sim-runs=50 \
##       --sim-set=res://addons/headless_pulse/examples/arena_2d/arena_tuning.tres|wave_scale=3

@export var wave_interval: float = 4.0
@export var first_wave_delay: float = 1.0
@export var wave_base_count: int = 2
@export var wave_scale: int = 3
@export var enemy_cap: int = 70

@export var enemy_base_hp: float = 26.0
@export var enemy_hp_per_wave: float = 5.0
@export var enemy_base_speed: float = 96.0
@export var enemy_speed_per_wave: float = 5.0
@export var enemy_touch_damage: float = 8.0
@export var gold_per_kill: int = 5
@export var spawn_radius_min: float = 360.0
@export var spawn_radius_max: float = 450.0

@export var player_hp: float = 100.0
@export var player_speed: float = 260.0
@export var heal_per_kill: float = 0.0
