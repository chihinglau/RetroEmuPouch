"""Prepare the LOCAL-ONLY artifacts for the Pura70 arcade BIOS A/B probe.

This script contains NO copyrighted data. It reads a locally supplied MAME
``neogeo.zip`` (the user's own copy, never committed) and the GPL-3.0
PrivaBIOS from ``freeroms/bios/``, then writes test artifacts under
``build/bios_probe/`` (gitignored). Nothing here is shipped in the HAP, in the
repo, or in any soft-copyright / store deliverable.

Usage: python scripts/ohos/prepare-bios-probe.py
"""
from __future__ import annotations

import hashlib
import json
import os
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "build", "bios_probe")
NEOGEO_SRC = os.path.join(ROOT, ".tools", "gstest", "bios", "neogeo.zip")
PRIVABIOS = os.path.join(
    ROOT, "freeroms", "bios", "privabios-0.1.0-beta.3.rom"
)
TEST_ZIP = os.path.join(OUT, "neogeo_privabios.zip")
TMP = "/data/local/tmp"

# Every rompath the OHOS native staging code (gpretro.cpp StageArcadeContent)
# can look in. Dropping from all three makes the A/B result unambiguous.
QSOUND_PATHS = [
    "system/qsound.zip",
    "system/qsound_hle.zip",
    "system/mame/roms/qsound.zip",
    "system/mame/roms/qsound_hle.zip",
    "rom_cache/mame/qsound.zip",
    "rom_cache/mame/qsound_hle.zip",
]
QSOUND_HLE_PATHS = [
    "system/qsound_hle.zip",
    "system/mame/roms/qsound_hle.zip",
    "rom_cache/mame/qsound_hle.zip",
]
BACKUP = [
    "system/qsound.zip",
    "system/qsound_hle.zip",
    "system/neogeo.zip",
]


def make_test_zip() -> None:
    """Replace ``sp-s2.sp1`` (MAME BIOS index 0) with PrivaBIOS."""
    if not os.path.isfile(NEOGEO_SRC):
        raise SystemExit(
            "missing local neogeo.zip: %s (user-supplied, never committed)"
            % NEOGEO_SRC
        )
    if not os.path.isfile(PRIVABIOS):
        raise SystemExit("missing PrivaBIOS: %s" % PRIVABIOS)
    with open(PRIVABIOS, "rb") as f:
        bios = f.read()
    if len(bios) != 128 * 1024:
        raise SystemExit("unexpected PrivaBIOS size: %d" % len(bios))
    src = zipfile.ZipFile(NEOGEO_SRC, "r")
    with zipfile.ZipFile(TEST_ZIP, "w") as dst:
        for info in src.infolist():
            data = bios if info.filename == "sp-s2.sp1" else src.read(info)
            # ZipInfo carries the original compress_type / CRC metadata;
            # writestr recomputes the CRC for the replaced member.
            dst.writestr(info, data)
    src.close()
    sha = hashlib.sha256(open(TEST_ZIP, "rb").read()).hexdigest()
    print("test zip  :", TEST_ZIP)
    print("bytes     :", os.path.getsize(TEST_ZIP))
    print("sha256    :", sha)


def scenario(tag: str, rom: str, *, drop_qsound: bool = False,
             drop_hle_only: bool = False, privabios: bool = False,
             restore: bool = False, settle_ms: int = 12000) -> dict:
    drop = QSOUND_PATHS if drop_qsound else (
        QSOUND_HLE_PATHS if drop_hle_only else []
    )
    cfg: dict = {
        "tag": tag,
        "rom": rom,
        "core": "mame",
        "platform": "mame",
        "settleMs": settle_ms,
        "backup": BACKUP,
        "restore": restore,
        "drop": drop,
        "dropHleOnly": drop_hle_only,
        "copy": [],
    }
    if privabios:
        cfg["copy"] = [
            {"from": TMP + "/neogeo_privabios.zip", "to": "system/neogeo.zip"}
        ]
    return cfg


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.join(OUT, "scenarios"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "results"), exist_ok=True)
    make_test_zip()

    cases = {
        # A: baseline — QSound BIOS present, CPS1 QSound game must boot.
        "A-baseline": scenario("A-baseline", "roms/peer/dino.zip"),
        # B: QSound BIOS removed everywhere — does the same CPS1 game boot?
        "B-no-qsound": scenario(
            "B-no-qsound", "roms/peer/dino.zip", drop_qsound=True
        ),
        # C: control — a CPS1 game with no QSound hardware, BIOS still removed.
        "C-no-qsound-ffight": scenario(
            "C-no-qsound-ffight", "roms/peer/ffight.zip", drop_qsound=True
        ),
        # D: CPS2/QSound title, BIOS removed.
        "D-no-qsound-1944": scenario(
            "D-no-qsound-1944", "roms/peer/1944.zip", drop_qsound=True
        ),
        # G: keep qsound.zip, drop only the byte-identical duplicate
        # qsound_hle.zip. Proves the second bundle can be removed from the
        # product's BIOS list without breaking QSound games.
        "G-no-qsound-hle": scenario(
            "G-no-qsound-hle", "roms/peer/dino.zip", drop_hle_only=True
        ),
        # F: put every original BIOS back (no launch). The PrivaBIOS / NeoGeo
        # compatibility run is done on the Android OXF test device instead
        # (scripts/mame/verify-privabios.ps1), because OHOS Flutter cannot
        # read /data/local/tmp and the test neogeo.zip must not be bundled
        # into a HAP.
        "F-restore": scenario(
            "F-restore", "roms/peer/dino.zip", restore=True, settle_ms=0
        ),
    }
    for name, cfg in cases.items():
        p = os.path.join(OUT, "scenarios", name + ".json")
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        print("scenario  :", p)


if __name__ == "__main__":
    main()
