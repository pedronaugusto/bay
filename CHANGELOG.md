# Changelog

## [Unreleased]

### Added

- One version of each package, as Go selects it (Minimal Version Selection): each package builds at the highest `.version` any manifest in the graph pins; the package under development wins over every revision of itself. Zig gets a graph with each package once, a dependency whose pins differ built from a copy with only its pins rewritten (`zig build --fork`). Two contents claiming one version, two lines of one package, a ring and a retracted version are refused in a sentence that names who asks.
- `bay tidy` writes the package's pins to the selection; a build that disagrees stops; `bay --locked` never writes a manifest; `add`, `remove` and `update` tidy.
- Workspaces (`bay.work`), `.overrides`, `.coexist` and `.retracted`.
- `bay tidy` in a workspace pins each member another member depends on at its release: the tag of the member's own `.version`, when its remote has one.
- `bay --workspace [--jobs <n>] <command>`: the command in every member, each after the members it ships with and the rest at once; a failure skips what depends on it.
- `bay update` moves a pin to a release tag to the newest release on its line.
- `git+ssh://` and `git+file://` dependencies, fetched with the system's git to the hash Zig gives the same tree.
- Paths in a manifest bay writes use `/` on every host.
- `bay licenses [--dev]`: each package a build contains, with the license its files state.
- `zig build dist`: the release programs for Linux, macOS and Windows on x86_64 and aarch64; with no Zig named or on the `PATH`, bay starts a package with the Zig it was built with, installed as any other.
- The exact Zig a package names (`.zig_version`, else `.minimum_zig_version`), downloaded from ziglang.org and verified against the index's SHA-256 and Zig's minisign key.
- `bay tree` with `--why` and `--duplicates`, `bay outdated`, `bay vendor` and `bay locate`.
- A build runs in its own root, where Zig reads every path of it.
- The development build has the package's own dependencies as well as its dev dependencies, as a crate's tests have its dependencies in Cargo: a dependency the package ships and develops with is listed once. A name pinned differently in both lists is refused.
- `.dev_dependencies` beside `.dependencies`, and the development build that runs a package's `dev` function with them.
- `bay new`, `init`, `add`, `remove`, `update`, `list`, `fetch`, and `bay <step>`.
- `bay dev`: the development build, as given; bay sets `BAY` to itself for what it runs.
- `bay install`, `install --list`, `install --update` and `uninstall`: global installs, as `cargo install` makes them, built as bay builds any package.
