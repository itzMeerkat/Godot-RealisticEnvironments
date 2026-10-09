"""Bakes NASA SVS's Milky Way map into SkySystem's calibrated Milky Way texture.

    python tools/bake_milky_way.py [milkyway_2020_4k.exr]

Needs numpy and opencv-python (EXR support is switched on here). Reads the "Milky Way
background" of NASA SVS Deep Star Maps 2020 (https://svs.gsfc.nasa.gov/4851,
celestial coordinates, plate carree, RA 0h at the centre increasing to the left; the
stars brighter than V = 8 left out; downloaded into build/ when no path is given) and
writes addons/sky_system/stars/milky_way.exr:

- RA increasing to the right from 0h at the left edge, declination +90 at the top
  (u = RA / 360, v = (90 - dec) / 180), 2048 x 1024, area-averaged;
- rgb in micro-candela per square meter (luminance, Rec. 709), the map's colour kept.

The map's units are not published, so its brightness is calibrated: averaged over the
sky (by solid angle) it holds the integrated starlight the Bright Star Catalogue lacks,
~100 S10(V) for all stars (Benn & Ellison 1998, La Palma technical note 115) less the
catalogue's own share. The result follows their latitude profile (25 + 250 e^(-|b|/20)
S10 for all stars) to within the bright stars it leaves out.

Credit: NASA/Goddard Space Flight Center Scientific Visualization Studio. Gaia DR2:
ESA/Gaia/DPAC.
"""
import gzip
import os
import pathlib
import sys
import urllib.request

os.environ["OPENCV_IO_ENABLE_OPENEXR"] = "1"
import cv2  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import bake_star_catalog  # noqa: E402

PROJECT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_URL = "https://svs.gsfc.nasa.gov/vis/a000000/a004800/a004851/milkyway_2020_4k.exr"
DOWNLOAD_PATH = PROJECT / "build" / "milkyway_2020_4k.exr"
OUTPUT_PATH = PROJECT / "addons" / "sky_system" / "stars" / "milky_way.exr"
OUTPUT_SIZE = (2048, 1024)
# Mean integrated starlight of all stars over the sky, S10(V).
ALL_STARLIGHT_S10 = 100.0
SKY_SQUARE_DEGREES = 41252.96
# Luminance (cd/m2) of one S10(V): a V = 10 star per square degree.
S10_CANDELA = 2.54e-10 / np.radians(1.0) ** 2
LUMINANCE = np.array([0.2126, 0.7152, 0.0722])


def main() -> int:
    source = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DOWNLOAD_PATH
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {SOURCE_URL}")
        urllib.request.urlretrieve(SOURCE_URL, source)
    rgb = cv2.imread(str(source), cv2.IMREAD_UNCHANGED)[..., ::-1].astype(np.float64)
    height, width = rgb.shape[:2]
    # Source column x shows RA 180 - (x + 0.5) * 360 / width; column j of ours RA (j + 0.5) * 360 / width.
    columns = (width // 2 - np.arange(width) - 1) % width
    rgb = rgb[:, columns]

    # Calibrate: the solid-angle mean holds the starlight the catalogue lacks.
    declination = np.radians(90.0 - (np.arange(height) + 0.5) * 180.0 / height)
    weights = np.cos(declination)[:, None]
    mean = ((rgb @ LUMINANCE) * weights).sum() / (weights.sum() * width)
    target = (ALL_STARLIGHT_S10 - catalogue_mean_s10()) * S10_CANDELA
    rgb *= target / mean * 1e6

    rgb = cv2.resize(rgb, OUTPUT_SIZE, interpolation=cv2.INTER_AREA)
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(OUTPUT_PATH), rgb[..., ::-1].astype(np.float32),
                [cv2.IMWRITE_EXR_TYPE, cv2.IMWRITE_EXR_TYPE_HALF])
    print(f"Milky Way: mean {target * 1e6:.1f} ucd/m2, peak {(rgb @ LUMINANCE).max():.0f} ucd/m2 -> {OUTPUT_PATH.relative_to(PROJECT)}")
    return 0


def catalogue_mean_s10() -> float:
    """Mean S10(V) over the sky of the Bright Star Catalogue's stars."""
    source = PROJECT / "build" / "bsc5_catalog.gz"
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(bake_star_catalog.SOURCE_URL, source)
    with gzip.open(source, "rt", encoding="ascii", errors="replace") as file:
        stars = [star for star in map(bake_star_catalog.parse_line, file) if star is not None]
    return sum(10.0 ** (-0.4 * (magnitude - 10.0)) for _, magnitude, _ in stars) / SKY_SQUARE_DEGREES


if __name__ == "__main__":
    sys.exit(main())
