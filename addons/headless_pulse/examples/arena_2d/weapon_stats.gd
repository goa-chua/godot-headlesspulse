class_name WeaponStats
extends Resource
## Data-driven weapon definition. Balance experiments change these fields (or
## override them from the CLI with `--sim-set=...|damage=3.5`) without touching code.

@export var id: String = "smg"
@export var display_name: String = "SMG"
@export var damage: float = 7.0
@export var fire_interval: float = 0.09
@export var bullet_speed: float = 950.0
@export var pellets: int = 1
@export var spread_radians: float = 0.0
@export var bullet_lifetime: float = 1.2
@export var bullet_radius: float = 6.0


func dps() -> float:
	return damage * float(pellets) / maxf(fire_interval, 0.001)
