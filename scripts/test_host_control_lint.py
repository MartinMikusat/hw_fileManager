#!/usr/bin/env python3
"""Reject automated tests that can control or foreground desktop applications."""

from __future__ import annotations

import pathlib
import re
import sys


FORBIDDEN = (
    ("RegisterEventHotKey", r"\bRegisterEventHotKey\b"),
    ("CGEventPost", r"\bCGEventPost\b"),
    ("CGEventTapCreate", r"\bCGEventTapCreate\b"),
    ("AXUIElement", r"\bAXUIElement\w*\b"),
    ("activateIgnoringOtherApps", r"\bactivateIgnoringOtherApps\b"),
    ("makeKeyAndOrderFront", r"\bmakeKeyAndOrderFront\b"),
    ("orderFrontRegardless", r"\borderFrontRegardless\b"),
    ("hotkey_register", r"\bhotkey_register\s*\("),
    ("snippets_monitor_start", r"\bsnippets_monitor_start\s*\("),
    ("snippets_paste", r"\bsnippets_paste\s*\("),
    ("snippets_erase_typed", r"\bsnippets_erase_typed\s*\("),
    ("workspace_open_url", r"\bworkspace_open_url\s*\("),
    ("remote_autostart", r"\bremote_autostart\s*\("),
    ("settings_window_show", r"\bsettings_window_show\w*\s*\("),
    ("settings_window_hide", r"\bsettings_window_hide\s*\("),
    ("quicklinks_window_show", r"\bquicklinks_window_show\w*\s*\("),
    ("quicklinks_window_hide", r"\bquicklinks_window_hide\s*\("),
    ("snippets_window_show", r"\bsnippets_window_show\w*\s*\("),
    ("snippets_window_hide", r"\bsnippets_window_hide\s*\("),
    ("launcher_refocus_panel", r"\blauncher_refocus_panel\s*\("),
    ("panel_start", r"\bpanel_start\s*\("),
    ("launcher_app_initialize", r"\blauncher_app_initialize\s*\("),
    ("launcher.show", r"\blauncher\.show\s*\("),
    ("launcher.run", r"\blauncher\.run\s*\("),
    ("dev.sh", r"(?:^|[\s\"'])\.?/?dev\.sh(?:$|[\s\"'])"),
    ("osascript", r"\bosascript\b"),
    ("open -a", r"\bopen\s+-a\b"),
)


def source_files(path: pathlib.Path) -> list[pathlib.Path]:
    if path.is_file():
        return [path]
    tests = list(path.rglob("*_test.odin"))
    tests.extend(path.rglob("test.sh"))
    return sorted(tests)


def main(arguments: list[str]) -> int:
    failures: list[str] = []
    for argument in arguments:
        path = pathlib.Path(argument)
        for file in source_files(path):
            text = file.read_text(encoding="utf-8")
            for line_number, line in enumerate(text.splitlines(), start=1):
                for name, pattern in FORBIDDEN:
                    if re.search(pattern, line):
                        failures.append(f"{file}:{line_number}: forbidden host control: {name}")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
