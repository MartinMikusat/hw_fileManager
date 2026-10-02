"""Headless dev log integration check: the app's error trail and the reader CLI."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def records(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def run(command, environment, **kwargs):
    return subprocess.run(command, env=environment, capture_output=True, timeout=60, **kwargs)


executable = Path(sys.argv[1]).resolve()
reader = Path(sys.argv[2]).resolve()

with tempfile.TemporaryDirectory(prefix="hw-fileManager-devlog-") as temporary:
    root = Path(temporary)
    journal = root / "journal"
    environment = dict(os.environ, HW_DEVLOG_DIR=str(journal), HW_DEVLOG_PROFILE="dev")
    fixture = root / "fixture"
    (fixture / "alpha").mkdir(parents=True)
    (fixture / "alpha" / "one.txt").write_text("one")
    frame = root / "frame.ppm"

    ok = run([str(executable), "--offscreen", str(frame), "--path=" + str(fixture / "alpha")], environment)
    assert ok.returncode == 0, ok.stderr.decode(errors="replace")
    assert frame.read_bytes().startswith(b"P6\n")
    journal_lines = records(journal / "devlog.jsonl")
    outcomes = [(record["operation"], record["outcome"]) for record in journal_lines]
    assert ("startup", "started") in outcomes
    assert ("read_directory", "succeeded") in outcomes
    assert ("render_offscreen", "succeeded") in outcomes
    assert outcomes[-1] == ("shutdown", "stopped")
    assert not any(record["outcome"] == "failed" for record in journal_lines)
    assert records(journal / "perf.jsonl")[0]["operation"] == "render_offscreen"
    assert not (journal / "running.marker").exists()
    assert str(root) not in (journal / "devlog.jsonl").read_text()
    clean = run([str(reader), "--dir", str(journal), "check"], environment)
    assert clean.returncode == 0, clean.stdout.decode(errors="replace") + clean.stderr.decode(errors="replace")

    bad = run([str(executable), "--offscreen", str(frame), "--path=" + str(fixture / "absent")], environment)
    assert bad.returncode == 2, bad.stderr.decode(errors="replace")
    journal_lines = records(journal / "devlog.jsonl")
    assert any(
        record["operation"] == "open_starting_directory" and record["outcome"] == "failed"
        for record in journal_lines
    )
    assert any(
        record["operation"] == "render_offscreen" and record["outcome"] == "failed"
        for record in journal_lines
    )
    assert not (journal / "running.marker").exists()
    dirty = run([str(reader), "--dir", str(journal), "check"], environment)
    assert dirty.returncode == 1, dirty.stdout.decode(errors="replace")
    summary = json.loads(run([str(reader), "--dir", str(journal), "summary"], environment).stdout)
    assert summary["errors"] >= 2
    assert {(item["feature"], item["operation"]) for item in summary["incidents"]} >= {
        ("files", "open_starting_directory"),
        ("app", "render_offscreen"),
    }

print("Dev logs: headless trails, performance sample, privacy and hw-devlog check passed.")
