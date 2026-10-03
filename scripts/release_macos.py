#!/usr/bin/env python3
"""Project entry point for the shared macOS release tooling."""
import importlib.util
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
libraries = Path(os.environ.get("ODIN_LIBS", root.parent / "odin_libraries"))
spec = importlib.util.spec_from_file_location("native_release", libraries / "hw_odin_native_update/scripts/release_macos.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
release.configure(
    root,
    app_name="hw_fileManager",
    bundle_id="com.halwayland.filemanager",
    team_id="5242LK8KGW",
    repo="MartinMikusat/hw_fileManager",
    built_app="build/file_manager-release.app",
    artifact_prefix="hw_fileManager",
)
if __name__ == "__main__":
    release.main()
