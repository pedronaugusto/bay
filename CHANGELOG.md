# Changelog

## [Unreleased]

## [0.1.7] - 2026-10-12

### Fixed

- A path dependency that is no workspace member is refused while its own pins are behind the selection, as a member is: Zig builds it from its directory with its manifest's pins, which no fork rewrites, so it built stale versions without a word.

## [0.1.6] - 2026-10-12

### Fixed

- A workspace member a build reaches by its directory is refused while its own pins are behind the selection, and when a pin by hash reaches it as well: Zig builds a path dependency with its own manifest's pins and cannot fork it, so 0.1.5 built the stale pins without a word, or the member twice. `bay --workspace tidy` settles the first.
- A workspace is one graph for `.coexist` too: the packages every member names may keep two lines, where only the package being built was read. A package naming itself there is refused.

## [0.1.5] - 2026-10-12

### Fixed

- A workspace member a build reaches only by a path, at the member's own directory, is no longer given a `--fork`: Zig refuses a fork that matches no package it fetched, so the build failed. bay forks only the packages a build fetches by hash.

### Changed

- Pins aegis 0.1.2.

## [0.1.4] - 2026-10-12

### Added

- `bay upgrade [name...]` pins each dependency named, or every one with a git URL, at the newest release tag of its repository that its newest release does not retract, across lines and from a bare commit too, in the list it is in. A repository with no release tag stays as it is, and is said to.
- `bay add` takes several URLs. It pins all of them, then tidies once, as `bay upgrade` does, so packages that pin each other can move together.

### Fixed

- `bay add <url>` for a dependency already pinned keeps it in the list it is in. Without `--dev` it wrote into `.dependencies` even when the package was pinned only in `.dev_dependencies`, and ended up in both; `--dev` now only chooses the list of a dependency not pinned yet.

### Changed

- Pins aegis 0.1.1 and preflight 0.3.4.

## [0.1.3] - 2026-10-12

### Fixed

- `bay add <url>?ref=<tag>` pins the commit the tag names. A `git+https` URL went to `zig fetch` as given, and Zig reads a ref only from the fragment, so it fetched HEAD and the pin recorded the tag beside the head's commit; the two agreed only while the tag was at the head.

## [0.1.2] - 2026-10-12

### Fixed

- A fork is named to Zig by its absolute path. A relative one was read against a different directory once Zig had fetched a package from a remote and configured again, and a cold development build of a package its own tools pin failed with `FileSystemFailure`.

### Added

- A `check` step, in the package build and the development build: the program and the tests compiled, nothing run, as the release tier compiles a package in ReleaseSmall.

## [0.1.1] - 2026-10-12

### Fixed

- A development build runs in the package's directory, as the package build does, so a test or tool it runs reads the package's files by their path in it; it ran in `.zig-cache/bay`, where none of them is.

## [0.1.0] - 2026-10-12

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
- `bay tree` with `--why` and `--duplicates`, `bay outdated`, `bay licenses [--dev]`, `bay locate` and `bay version`.
- `bay vendor`: Zig unpacks every package the graph reads into the project's `zig-pkg`, which both builds read, so a project resolves and builds with no remote reachable.
- `bay <step>` resolves and fetches before it looks for the step; a build runs in its own root, where Zig reads every path of it.
- `bay new`, `init`, `add`, `remove`, `update`, `list`, `fetch`, and `bay dev`; bay sets `BAY` to itself for what it runs.
- `bay install`, `install --list`, `install --update` and `uninstall`: global installs, as `cargo install` makes them, built as anything depending on the package would build it, without its development, and recorded by absolute place.
- `zig build dist`: the release programs for Linux, macOS and Windows on x86_64 and aarch64.
- Paths in a manifest bay writes use `/` on every host; on Windows links to directories are made as such, and a running program is moved aside before an install replaces it.

[Unreleased]: https://github.com/pedronaugusto/bay/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/pedronaugusto/bay/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/pedronaugusto/bay/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/pedronaugusto/bay/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/pedronaugusto/bay/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/pedronaugusto/bay/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/pedronaugusto/bay/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/pedronaugusto/bay/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/pedronaugusto/bay/releases/tag/v0.1.0
