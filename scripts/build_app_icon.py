#!/usr/bin/env python3
"""Regenerate the committed macOS icon from assets/app-icon/app-icon.svg with ImageMagick and iconutil."""
from pathlib import Path
import subprocess
import tempfile

assets = Path(__file__).resolve().parent.parent / "assets/app-icon"
with tempfile.TemporaryDirectory() as directory:
    iconset = Path(directory) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["magick", "-background", "none", "-density", "384", str(assets / "app-icon.svg"),
                            "-resize", f"{pixels}x{pixels}", "-depth", "8", str(iconset / name)], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(assets / "AppIcon.icns")], check=True)
