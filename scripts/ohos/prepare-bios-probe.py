"""Prepare the LOCAL-ONLY artifacts for the Pura70 arcade BIOS A/B probe.

This script contains NO copyrighted data. It reads a locally supplied MAME
``neogeo.zip`` (the user's own copy, never committed) and the GPL-3.0
PrivaBIOS from ``freeroms/bios/``, then writes test artifacts under
``build/bios_probe/`` (gitignored). Nothing here is committed or shipped in a
production HAP / soft-copyright / store deliverable.

For the OHOS PrivaBIOS run it additionally copies the *open-source* PrivaBIOS
bytes (128 KB, GPL-3.0) to ``app/assets/probe/privabios.rom`` so a debug probe
HAP can rebuild ``neogeo.zip`` inside the app sandbox: hdc cannot write into
that sandbox and the Flutter process cannot read /data/local/tmp. That asset is
gitignored, deleted again by run-bios-probe.ps1, and is NEVER present in a
normal production build.

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
ASSET_DIR = os.path.join(ROOT, "app", "assets", "probe")
ASSET_BIOS = os.path.join(ASSET_DIR, "privabios.rom")
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

    # OHOS probe asset: ONLY the GPL-3.0 PrivaBIOS bytes, never any SNK BIOS
    # member. app/assets/probe/*.rom is gitignored; a production HAP has just
    # .gitkeep in this directory.
    os.makedirs(ASSET_DIR, exist_ok=True)
    with open(ASSET_BIOS, "wb") as f:
        f.write(bios)
    print("probe asset:", ASSET_BIOS, len(bios), "bytes (GPL-3.0, gitignored)")


def scenario(tag: str, rom: str, *, drop_qsound: bool = False,
             drop_hle_only: bool = False, privabios: bool = False,
             priva_ohos: bool = False, restore: bool = False,
             settle_ms: int = 12000) -> dict:
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
        "privaOhos": priva_ohos,
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
        # H: OHOS baseline with the user's original neogeo.zip (no swap).
        "H-priva-baseline-ohos": scenario(
            "H-priva-baseline-ohos", "roms/peer/kof97.zip"
        ),
        # E: OHOS PrivaBIOS run. The probe reads the GPL-3.0 asset, replaces
        # sp-s2.sp1 inside the on-device neogeo.zip using package:archive,
        # writes it to all three rompaths, then boots kof97. Android OXF uses
        # scripts/mame/verify-privabios.ps1 instead (adb run-as can write the
        # sandbox directly).
        "E-privabios-ohos": scenario(
            "E-privabios-ohos", "roms/peer/kof97.zip", priva_ohos=True
        ),
        # F: put every original BIOS back (no launch).
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
