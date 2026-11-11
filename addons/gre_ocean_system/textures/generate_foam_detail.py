"""Generates foam_detail.png, the tiling pattern the water shader reveals foam with.

Run from this directory: python generate_foam_detail.py (needs numpy and Pillow).

The pattern is soft patches (smooth noise) textured by bubble lace (Worley cell
borders of two sizes, combined by max so their crossings are not brighter), so
thin foam shows as patches dissolving into a bubble network, not isolated
specks. Its values are histogram-equalized to a uniform 0-1 range, so showing
foam where pattern > 1 - coverage covers exactly `coverage` of the area.
"""
import numpy as np
from PIL import Image

SIZE = 512
SEED = 7


def worley_borders(rng, cells):
	"""F2 - F1 of a tiling Worley field with cells x cells feature points (0 on cell borders)."""
	points = rng.random((cells, cells, 2))
	coords = (np.arange(SIZE) + 0.5) / SIZE * cells
	x, y = np.meshgrid(coords, coords)
	cell_x = np.floor(x).astype(int)
	cell_y = np.floor(y).astype(int)
	f1 = np.full((SIZE, SIZE), np.inf)
	f2 = np.full((SIZE, SIZE), np.inf)
	for oy in (-1, 0, 1):
		for ox in (-1, 0, 1):
			nx = cell_x + ox
			ny = cell_y + oy
			point = points[ny % cells, nx % cells]
			d = np.hypot(nx + point[..., 0] - x, ny + point[..., 1] - y)
			f2 = np.where(d < f1, f1, np.minimum(f2, d))
			f1 = np.minimum(f1, d)
	return f2 - f1


def smooth_noise(rng, wavelength_px):
	"""Tiling Gaussian-filtered white noise, normalized to zero mean, unit variance."""
	white = rng.standard_normal((SIZE, SIZE))
	k = np.fft.fftfreq(SIZE)
	kx, ky = np.meshgrid(k, k)
	sigma = wavelength_px / (2.0 * np.pi)
	field = np.real(np.fft.ifft2(np.fft.fft2(white) * np.exp(-0.5 * (kx * kx + ky * ky) * (2.0 * np.pi * sigma) ** 2)))
	return (field - field.mean()) / field.std()


def main():
	rng = np.random.default_rng(SEED)
	lace = np.maximum(np.exp(-worley_borders(rng, 24) * 5.0), 0.8 * np.exp(-worley_borders(rng, 60) * 5.0))
	patches = smooth_noise(rng, 128.0) + 0.5 * smooth_noise(rng, 48.0)
	pattern = patches + 2.6 * lace
	# Histogram equalization: each texel's rank becomes its value.
	ranks = np.empty(pattern.size)
	ranks[np.argsort(pattern, axis=None)] = np.arange(pattern.size)
	uniform = (ranks / (pattern.size - 1)).reshape(SIZE, SIZE)
	Image.fromarray(np.round(uniform * 255.0).astype(np.uint8), mode="L").save("foam_detail.png")


if __name__ == "__main__":
	main()
