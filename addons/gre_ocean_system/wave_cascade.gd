@tool
class_name GREWaveCascade extends Resource
## One FFT tile of GREOceanSystem.spectrum's waves. Several cascades with different tile
## lengths combine long swell, mid waves and small surface detail: they split the
## spectrum by wavelength, each drawing waves up to tile_length / 6 and leaving the
## longer ones to the next larger tile (GREOceanSystem keeps the bands).
##
## A cascade holds only settings; GREOceanSystem keeps the simulation state, so one
## cascade resource can be shared by several oceans.

## Repeating world-space size of this tile in meters. Larger tiles hold broad swell
## and long waves; smaller ones local chop and surface detail. Pick lengths that don't
## divide each other, so the tiles never repeat in step. Changing it regenerates the
## spectra at once (no crossfade).
@export_range(1.0, 2000.0, 0.1, "or_greater", "suffix:m") var tile_length := 50.0 :
	set(value):
		tile_length = maxf(value, 0.01)
		emit_changed()

@export_group("Foam")
## Foam forms where the Jacobian of the drawn surface (GREWaveSpectrum.displacement_scale
## included) drops below this value: 1 is flat, lower is compressed into a crest, 0
## and below folds over. Higher values put foam on gentler crests. 0.8 gives about the
## whitecaps of a real sea (GREWaveSpectrum.displacement_scale 1): scattered at 10 m/s.
@export_range(-1.0, 1.5, 0.01) var whitecap := 0.8
## Foam coverage added per second for each unit the Jacobian is below whitecap.
## Higher values whiten a crest faster.
@export_range(0.0, 100.0, 0.1, "or_greater") var foam_generation := 10.0
## Seconds for foam to fade to 1/e once its crest has passed. Longer leaves
## patches and streaks behind breaking waves.
@export_range(0.05, 30.0, 0.05, "or_greater", "suffix:s") var foam_lifetime := 2.0 :
	set(value):
		foam_lifetime = maxf(value, 0.05)
