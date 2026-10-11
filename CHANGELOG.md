# Changelog

## [Unreleased]

### Added

- `.dev_dependencies` beside `.dependencies`, and the development build that runs a package's `dev` function with them. The development build has the package's own dependencies too, as a crate's tests have its dependencies in Cargo: a dependency the package ships and develops with is listed once, and a name pinned differently in both lists is refused.
- One version of each package, as Go selects it (Minimal Version Selection): every revision the graph reaches is read, and each package builds at the highest `.version` any of them pins, whatever the order or depth they are found in; the package under development wins over every revision of itself. Zig gets a graph with each package once, a dependency whose pins differ built from a copy with only its pins rewritten (`zig build --fork`). Two contents claiming one version, two lines of one package, a package that is a directory in one place and pinned in another, a coexisting line that needs a fork, and a ring are refused in a sentence that names who asks.
- `bay tidy` writes the package's own pins to the selection; a build that disagrees stops; `bay --locked` never writes a manifest; `add`, `remove` and `update` tidy. Manifests are written whole, never half.
- Workspaces (`bay.work`): every member is built from its directory, and the workspace resolves as one graph with every member's development in it. `bay tidy` pins each member the package depends on at its release, the tag of the member's own `.version`; a member whose pins are behind builds from a copy of its tree with them rewritten, so no command writes outside its package.
- `bay --workspace [--jobs <n>] <command>`: the command in every member, each after the members it ships with and the rest at once; a failure skips what depends on it.
- `.overrides`, `.coexist`, and `.retracted`: a newer release withdraws versions, as Go's `retract`; `bay outdated` names a withdrawn version in use and `bay update` never moves to one.
- `bay update` follows a recorded ref: a branch to its head, a release tag to the newest release on its line.
- `git+ssh://` and `git+file://` dependencies, fetched with the system's git to the hash Zig gives the same tree; a tree's paths stay inside it.
- The exact Zig a package names (`.zig_version`, else `.minimum_zig_version`, 0.17.0 or newer), downloaded from ziglang.org and verified against the index's SHA-256 and Zig's minisign key. With no Zig named or on the `PATH`, bay starts a package with the Zig it was built with, installed as any other.
- `bay tree` with `--why` and `--duplicates`, `bay outdated`, `bay licenses [--dev]` and `bay locate`.
- `bay vendor`: Zig unpacks every package the graph reads into the project's `zig-pkg`, which both builds read, so a project resolves and builds with no remote reachable.
- `bay <step>` resolves and fetches before it looks for the step; a build runs in its own root, where Zig reads every path of it.
- `bay new`, `init`, `add`, `remove`, `update`, `list`, `fetch`, and `bay dev`; bay sets `BAY` to itself for what it runs.
- `bay install`, `install --list`, `install --update` and `uninstall`: global installs, as `cargo install` makes them, built as anything depending on the package would build it, without its development, and recorded by absolute place.
- `zig build dist`: the release programs for Linux, macOS and Windows on x86_64 and aarch64.
- Paths in a manifest bay writes use `/` on every host; on Windows links to directories are made as such, and a running program is moved aside before an install replaces it.
