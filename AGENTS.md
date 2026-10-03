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
  `file_manager --offscreen <path.ppm> [--path=DIR] [--select=NAME] [--gather=NAME] [--font-size=N] [--settings] [--shift]` for
  headless structural checks
  instead of launching the app.
