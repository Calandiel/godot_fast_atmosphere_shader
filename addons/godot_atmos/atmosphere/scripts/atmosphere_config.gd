class_name PrecomputedAtmosphereConfiguration
extends RefCounted

var planet_radius = 6370.0;
var atmosphere_height = 100.0;

# var sun_direction = Vector3(0, 0, 1); # TODO: handle this and sun intensity

var rayleigh_scale_height: float = 8.0;
var rayleigh_scattering: Vector3 = Vector3(0.0058, 0.0135, 0.0331);
# var rayleigh_absorption: Vector3 # Same as scattering...

var mie_scale_height: float = 1.2;
var mie_scattering: Vector3 = Vector3(0.004, 0.004, 0.004);
# var mie_absorption: float = 0.0044;
