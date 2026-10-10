@tool
class_name StarCatalog
extends Resource
## Stars for SkySystem's starfield, one entry per star at the same index in every
## array. Baked by tools/bake_star_catalog.py from the Yale Bright Star Catalogue
## (all stars to visual magnitude ~6.5); don't edit by hand.

## Unit vector toward the star in J2000 equatorial coordinates: x toward right
## ascension 0h, y toward 6h, z toward the north celestial pole.
@export var directions := PackedVector3Array()
## Visual (V) magnitude.
@export var magnitudes := PackedFloat32Array()
## Linear Rec. 709 colour of the star's light (its blackbody from the B-V index),
## luminance 1.
@export var colors := PackedColorArray()


## Number of stars.
func get_star_count() -> int:
	return directions.size()


## Whether every array has one entry per star.
func is_valid() -> bool:
	return magnitudes.size() == directions.size() and colors.size() == directions.size()
