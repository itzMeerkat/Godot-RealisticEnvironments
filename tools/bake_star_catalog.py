"""Bakes the Yale Bright Star Catalogue into SkySystem's StarCatalog resource.

    python tools/bake_star_catalog.py [catalog.gz]

Reads the catalogue (CDS V/50 `catalog.gz`; downloaded into build/ when no path
is given) and writes addons/sky_system/stars/bright_star_catalog.tres: per star its
J2000 direction, visual magnitude and the linear Rec. 709 colour (luminance 1) of a
blackbody at the temperature of its B-V index. Entries without a position or a
magnitude (a few novae and non-stellar objects) are left out.

The Bright Star Catalogue, 5th Revised Ed. (Hoffleit & Warren 1991), is distributed
by CDS (catalogue V/50) and NASA HEASARC.
"""
import gzip
import math
import pathlib
import random
import re
import sys
import urllib.request

PROJECT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_URL = "https://cdsarc.cds.unistra.fr/ftp/V/50/catalog.gz"
DOWNLOAD_PATH = PROJECT / "build" / "bsc5_catalog.gz"
OUTPUT_PATH = PROJECT / "addons" / "sky_system" / "stars" / "bright_star_catalog.tres"
SCRIPT_PATH = "res://addons/sky_system/star_catalog.gd"
SCRIPT_UID_PATH = PROJECT / "addons" / "sky_system" / "star_catalog.gd.uid"
# Stars without a B-V index get a sun-like colour.
DEFAULT_B_V = 0.6
# CIE 1931 XYZ to linear Rec. 709 (sRGB primaries, D65).
XYZ_TO_RGB = (
    (3.2406, -1.5372, -0.4986),
    (-0.9689, 1.8758, 0.0415),
    (0.0557, -0.2040, 1.0570),
)


def main() -> int:
    if len(sys.argv) > 1:
        source = pathlib.Path(sys.argv[1])
    else:
        source = DOWNLOAD_PATH
        if not source.exists():
            source.parent.mkdir(parents=True, exist_ok=True)
            print(f"Downloading {SOURCE_URL}")
            urllib.request.urlretrieve(SOURCE_URL, source)
    opener = gzip.open if source.suffix == ".gz" else open
    with opener(source, "rt", encoding="ascii", errors="replace") as file:
        stars = [star for star in map(parse_line, file) if star is not None]
    stars.sort(key=lambda star: star[1])
    write_resource(stars)
    print(f"{len(stars)} stars, magnitudes {stars[0][1]:.2f} to {stars[-1][1]:.2f} -> {OUTPUT_PATH.relative_to(PROJECT)}")
    return 0


def parse_line(line: str):
    """(direction, V magnitude, colour) of one catalogue record, or None."""
    line = line.rstrip("\n").ljust(197)
    ra_h, ra_m, ra_s = line[75:77], line[77:79], line[79:83]
    de_sign, de_d, de_m, de_s = line[83], line[84:86], line[86:88], line[88:90]
    vmag = line[102:107]
    if not ra_h.strip() or not de_d.strip() or not vmag.strip():
        return None
    ra = math.radians(15.0 * (int(ra_h) + int(ra_m) / 60.0 + float(ra_s) / 3600.0))
    dec = math.radians((int(de_d) + int(de_m) / 60.0 + int(de_s) / 3600.0) * (-1.0 if de_sign == "-" else 1.0))
    direction = (math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec))
    b_v = float(line[109:114]) if line[109:114].strip() else DEFAULT_B_V
    return direction, float(vmag), blackbody_color(b_v_temperature(b_v))


def b_v_temperature(b_v: float) -> float:
    """Effective temperature (K) of a star from its B-V index (Ballesteros 2012)."""
    b_v = min(max(b_v, -0.4), 2.0)
    return 4600.0 * (1.0 / (0.92 * b_v + 1.7) + 1.0 / (0.92 * b_v + 0.62))


def blackbody_color(temperature: float):
    """Linear Rec. 709 colour of a blackbody, luminance (Y) 1, channels >= 0."""
    x = y = z = 0.0
    for wavelength in range(380, 781):
        radiance = planck(wavelength * 1e-9, temperature)
        cx, cy, cz = cie_1931(wavelength)
        x += radiance * cx
        y += radiance * cy
        z += radiance * cz
    rgb = [max(row[0] * x + row[1] * y + row[2] * z, 0.0) / y for row in XYZ_TO_RGB]
    luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    return tuple(channel / luminance for channel in rgb)


def planck(wavelength: float, temperature: float) -> float:
    h, c, k = 6.62607015e-34, 2.99792458e8, 1.380649e-23
    return 1.0 / (wavelength ** 5 * (math.exp(h * c / (wavelength * k * temperature)) - 1.0))


def cie_1931(wavelength: float):
    """CIE 1931 2-degree colour matching functions, the multi-lobe fit of Wyman, Sloan
    and Shirley 2013 ("Simple analytic approximations to the CIE XYZ color matching
    functions")."""
    def g(mean, sigma_low, sigma_high):
        t = (wavelength - mean) / (sigma_low if wavelength < mean else sigma_high)
        return math.exp(-0.5 * t * t)
    x = 1.056 * g(599.8, 37.9, 31.0) + 0.362 * g(442.0, 16.0, 26.7) - 0.065 * g(501.1, 20.4, 26.2)
    y = 0.821 * g(568.8, 46.9, 40.5) + 0.286 * g(530.9, 16.3, 31.1)
    z = 1.217 * g(437.0, 11.8, 36.0) + 0.681 * g(459.0, 26.0, 13.8)
    return x, y, z


def write_resource(stars) -> None:
    uid = existing_uid(OUTPUT_PATH) or new_uid()
    script_uid = SCRIPT_UID_PATH.read_text(encoding="ascii").strip()
    directions = ", ".join(f"{c:.6g}" for star in stars for c in star[0])
    magnitudes = ", ".join(f"{star[1]:.2f}" for star in stars)
    colors = ", ".join(f"{c:.4g}" for star in stars for c in (*star[2], 1.0))
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        f'[gd_resource type="Resource" script_class="StarCatalog" format=3 uid="{uid}"]\n\n'
        f'[ext_resource type="Script" uid="{script_uid}" path="{SCRIPT_PATH}" id="1_catalog"]\n\n'
        "[resource]\n"
        'script = ExtResource("1_catalog")\n'
        f"directions = PackedVector3Array({directions})\n"
        f"magnitudes = PackedFloat32Array({magnitudes})\n"
        f"colors = PackedColorArray({colors})\n",
        encoding="ascii", newline="\n")


def existing_uid(path: pathlib.Path):
    if not path.exists():
        return None
    match = re.search(r'uid="(uid://[a-z0-9]+)"', path.read_text(encoding="ascii").split("\n", 1)[0])
    return match.group(1) if match else None


def new_uid() -> str:
    """A random resource UID in Godot's text form (ResourceUID::id_to_text)."""
    value = random.getrandbits(63)
    chars = ""
    while True:
        digit = value % 36
        chars = (chr(ord("a") + digit) if digit < 26 else chr(ord("0") + digit - 26)) + chars
        value //= 36
        if value == 0:
            return "uid://" + chars


if __name__ == "__main__":
    sys.exit(main())
