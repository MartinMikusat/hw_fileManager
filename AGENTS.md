# hw_fileManager

A super simple file manager/viewer for macOS. A directory is shown as a horizontal
cascade of columns: each column lists one directory's children, the selected entry
links to its child column through an orthogonal connector, and names are colored by
kind. Source lives at the repository root (`package file_manager`).

- Build with `./build.sh [debug|trace|asan|release]`. Test with `./test.sh`. Run the
  development watcher with `./dev.sh`; it never rebuilds on its own, so run
  `./dev.sh rebuild` to rebuild and relaunch the running app.
- Shared Odin libraries live in `/Users/martin/projects/odin_libraries`; they are
  pinned in `dependencies.lock` and checked at build start. Do not copy those packages
  into this tree. Read `/Users/martin/projects/odin_libraries/AGENTS_NATIVE_CONTRACT.md`
  before changing the native interface, watcher, or Metal rendering.
- Rendering is `hw_odin_ui_framework` (`draw`, `coretext`, `metal`, `macos`) driven
  directly. There is no hw_clay: `view.odin` computes every column, row, and connector
  position itself. Do not add a layout library.
- `references/*.jpg` is the binding visual spec: match it 1:1 (palette, type
  weight, selection treatment, connector geometry, alignment), deriving the
  theme constants from the images. The app-authoring defaults yield to it.
- The operation journal (`hw_odin_devlog`) is the dev error and debug path.
  `dev.sh` writes `.dev-logs/app/devlog.jsonl`; read it first when a run misbehaves.
  Record failures once at their root cause, and never put credentials, payloads or
  full paths in a record.
- A feature is a file-name prefix in this one package. Keep files small and cohesive.
- Interface verification is the operator's. Use
  `file_manager --offscreen <path.ppm> [--path=DIR] [--select=NAME] [--gather=NAME] [--font-size=N] [--settings] [--shift] [--sort-menu] [--safe]` for
  headless structural checks
  instead of launching the app.
- User-facing diagnostics come from the shared `hw_odin_diagnostics` library (`report.odin`
  here only holds this app's `Config`). `file_manager --diagnostics` writes a redacted report
  to the Desktop (`--out=PATH`, `--stdout`, `--reveal`) without opening the journal, so the
  crash marker survives; the Settings > Diagnostics row copies or exports the same report; and
  the standalone `hw_diagnostics` app collects it for any of our apps, including one that
  will not start. Safe mode after two crashed launches is `safe_update_count` in that library.
- Releases and updates: `python3 scripts/release_macos.py build <version> --notary-profile <profile>`
  signs, notarizes and packages `dist.noindex/<version>`; `publish dist.noindex/<version>` creates the GitHub
  release. Installed release apps check `releases/latest/download/update.json` hourly and swap
  in a staged update on quit (`update.odin`, `hw_odin_native_update`). Dev builds never update.
  Publish only when the operator asks for a specific version.

## Agent skills

### Issue tracker

GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily. See `docs/agents/domain.md`.
