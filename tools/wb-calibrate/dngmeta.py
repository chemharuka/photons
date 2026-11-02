#!/usr/bin/env python3
"""Shared DNG metadata block for the synthetic chart writers.

Why this module exists: `make_chart256.py` and `make_marker.py` must tag their raw files
*identically*, or a geometry result measured on one chart would not carry over to the other.
Everything colour-related now lives here.

The colour fix (measured — see README「颜色」)
---------------------------------------------
The real body profile carries two matrix/illuminant pairs:

    CalibrationIlluminant1 = Standard Light A (17)  →  ColorMatrix1  (tungsten)
    CalibrationIlluminant2 = D65           (21)  →  ColorMatrix2  (daylight)

The textbook fixes do **not** work on this file: writing both pairs, writing ColorMatrix2 as
pair 1, and relabelling pair 1 as D65 all make Apple's decoder refuse the container
(supportedDecoderVersions [None], 120 px thumbnail). Only `CalibrationIlluminant1 = A` + its
ColorMatrix1 is accepted, and that pair is not self-consistent with the body's AsShotNeutral
(M·ASN has a negative X). So the shipped chart keeps the A matrix and **reverse-solves
AsShotNeutral** at the acceptance temperature (`tune_asn.py` → `asn_calibration.json`), which
brings the neutral rows' chroma spread from 36 to ≤1 at 6500 K. Raw neutrals stay proportional
to AsShotNeutral either way (hard constraint #1).

Everything is read out of the real DNG, so the numbers stay honest to the body.
"""
import json
import os
import shutil
import subprocess
from pathlib import Path

ILLUM = {"Standard Light A": 17, "Standard Light B": 18, "Standard Light C": 19, "D55": 20,
         "D65": 21, "D75": 22, "D50": 23, "Daylight": 1}


def _nums(s):
    return [float(x) for x in str(s).replace("[", " ").replace("]", " ").replace(";", " ").split()]


def read_meta(real_dng):
    """exiftool -j -G1 → {tag: value}.

    The body file carries the DNG tags **twice**: once in IFD0 (the DNG-spec `ColorMatrix1/2`,
    what CIRAWFilter reads) and once in a `ProfileIFD` for the embedded DCP profile, whose numbers
    are slightly different (1.2943 vs 1.2357). Prefer IFD0 — taking "whatever exiftool printed last"
    silently swapped in the profile's matrix.
    """
    if shutil.which("exiftool") is None:
        raise SystemExit("dngmeta: `exiftool` is not on PATH — install it (brew install exiftool)")
    proc = subprocess.run(["exiftool", "-j", "-G1", real_dng], capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise SystemExit(f"dngmeta: exiftool could not read {real_dng}\n{proc.stderr.strip()}")
    info = json.loads(proc.stdout)[0]
    tags = {}
    for k, v in info.items():
        group = k.split(":")[0].strip("[] ")
        name = k.split(":")[-1]
        if group == "IFD0" or name not in tags:
            tags[name] = v
    return tags


def as_shot_neutral(meta):
    """Camera-space white, G-normalised. Accepts a tag dict or a path to the real DNG."""
    tags = read_meta(meta) if isinstance(meta, str) else meta
    asn = _nums(tags.get("AsShotNeutral") or "1 1 1")
    if len(asn) != 3:
        asn = [1.0, 1.0, 1.0]
    return [v / asn[1] for v in asn]          # normalise to G = 1


CALIB = Path(__file__).with_name("asn_calibration.json")


def asn_effective(real_dng):
    """AsShotNeutral to *write*.

    The body's own AsShotNeutral describes the shot it took, and the body's DNG colour matrices are
    not consistent with it (M·ASN has a negative X — see README「颜色」). Feeding it to a 6500 K
    decode leaves a residual cast. `tune_asn.py` measures the camera-space white that this decoder
    actually neutralises at the acceptance temperature and stores it in `asn_calibration.json`;
    when that file exists it wins. Raw neutrals stay proportional to AsShotNeutral either way.
    """
    base = as_shot_neutral(real_dng)
    if os.environ.get("DNG_ASN"):            # tune_asn.py drives the iteration through this
        v = [float(x) for x in os.environ["DNG_ASN"].split(",")]
        if len(v) == 3:
            return [x / v[1] for x in v]
    if CALIB.exists():
        v = json.loads(CALIB.read_text()).get("asn")
        if v and len(v) == 3:
            return [float(x) / float(v[1]) for x in v]
    return base


def rat(x, den=1000000):
    return (int(round(x * den)), den)


def srat(x, den=10000):
    return (int(round(x * den)), den)


def extratags(real_dng, black_level=0, white_level=16383, cm="a", illum1=None, with_d65=False,
              unique_model=None):
    """Complete DNG tag list for a 16-bit single-plane CFA image of a known size.

    Colour knobs exist because Apple's acceptance is picky (measured, see README「颜色」):
      cm="a"      → ColorMatrix1 from the body (illuminant A numbers, the DNG default)
      cm="d65"    → ColorMatrix2 from the body (daylight numbers)
      illum1=None → CalibrationIlluminant1 follows cm (A for "a", D65 for "d65"); override to
                    probe whether the decoder rejects the *matrix* or the *illuminant code*
      with_d65    → also emit the second pair (ColorMatrix2 + CalibrationIlluminant2 = D65).
                    Apple rejects this file outright, which is why the shipped chart does not
                    use it — recorded so nobody re-tries it.
    """
    t = read_meta(real_dng)
    cm_key = "ColorMatrix1" if cm == "a" else "ColorMatrix2"
    illum_key = "CalibrationIlluminant1" if cm == "a" else "CalibrationIlluminant2"
    missing = [k for k in (cm_key, illum_key, "ColorMatrix2", "CalibrationIlluminant2", "Make", "Model")
               if k not in t]
    if missing:
        raise SystemExit(f"dngmeta: {real_dng} has no {', '.join(missing)} — "
                         f"this is not a DNG with a colour matrix")
    cm1 = _nums(t[cm_key])
    cm2 = _nums(t["ColorMatrix2"])
    asn = asn_effective(real_dng)
    default_illum = ILLUM[t["CalibrationIlluminant1" if cm == "a" else "CalibrationIlluminant2"]]
    illum1 = default_illum if illum1 is None else illum1
    illum2 = ILLUM[t["CalibrationIlluminant2"]]
    assert len(cm1) == 9 and len(asn) == 3

    tags = [
        (271, "s", 0, str(t["Make"])),
        (272, "s", 0, str(t["Model"])),
        (33421, "H", 2, (2, 2)),                       # CFARepeatPatternDim
        (33422, "B", 4, (0, 1, 1, 2)),                 # CFAPattern2  RGGB
        (50706, "B", 4, (1, 4, 0, 0)),                 # DNGVersion
        (50707, "B", 4, (1, 1, 0, 0)),                 # DNGBackwardVersion
        (50708, "s", 0, str(unique_model or t["UniqueCameraModel"])),   # UniqueCameraModel
        (50710, "B", 3, (0, 1, 2)),                    # CFAPlaneColor R,G,B
        (50711, "H", 1, 1),                            # CFALayout rectangular
        (50713, "H", 2, (2, 2)),                       # BlackLevelRepeatDim
        (50714, "H", 4, (black_level,) * 4),           # BlackLevel (per CFA plane)
        (50717, "I", 1, white_level),                  # WhiteLevel
        (50721, "2i", 9, [x for v in cm1 for x in srat(v)]),   # ColorMatrix1  (A)
        (50728, "2I", 3, [x for v in asn for x in rat(v)]),    # AsShotNeutral
        (50778, "H", 1, illum1),                       # CalibrationIlluminant1
    ]
    if with_d65:
        tags += [
            (50722, "2i", 9, [x for v in cm2 for x in srat(v)]),  # ColorMatrix2  (D65)
            (50779, "H", 1, illum2),                              # CalibrationIlluminant2
        ]
    return sorted(tags, key=lambda e: e[0])
