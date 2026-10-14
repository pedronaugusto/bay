# Changelog

## [Unreleased]

### Fixed

- A package pinned by an archive URL is fetched as a build fetches it, as the one dependency of a scratch build. `zig fetch <url>` in Zig 0.17.0 keeps an archive's top directory in the copy it stores in Zig's cache while printing the hash without it, so every later build unpacked other content and refused the pin ("hash mismatch ... the fetched package has N-V-..."); ghostty's dependencies in morse's and visor's conformance builds met it. A copy an earlier bay left in a cache (`p/<hash>.tar.gz` holding one more directory) is not repaired: delete it.

## [0.1.11] - 2026-10-14

### Fixed

- `bay --workspace update`, `upgrade`, `add` and `remove` write every member before any is tidied, then tidy them all: a member tidied first resolved against members not yet moved, and was refused for a mix of lines. `--no-tidy` leaves the tidy to a later `bay tidy` by hand too.

### Changed

- Pins aegis 0.1.6, ensign 0.2.2.

## [0.1.10] - 2026-10-13

### Fixed

- `build.zig` configures on Zig master, where `standardOptimizeOption` returns an optional mode: the build functions take `?std.lang.Optimize`, which 0.17 passes as well.

### Changed

- Pins aegis 0.1.5.

## [0.1.9] - 2026-10-13

### Added

- `bay audit`: each package the builds select, checked against its repository's published security advisories on GitHub (with `GITHUB_TOKEN` when set) and against its own newest release's retractions; it fails on any finding, so CI can gate on it.
- `bay completions <shell>`: the completion script for bash, zsh, fish or PowerShell.
- `bay --help` and `bay <command> --help`: help for every command, generated with the command line itself.

### Changed

- The command line is read by [ensign](https://github.com/pedronaugusto/ensign) from one declaration: mistakes are named with the nearest command or option, `--locked` is accepted after the command too, and `--jobs` (`-j`) takes 1 to 4096. A new dependency: ensign.
- `bay --workspace` runs each member after the members it is developed with too, so a member whose gate runs a tool released in the same workspace (a linter, preflight) lands after it; a development dependency that would close a ring is left out, and that member uses the release it pins.

### Fixed

- `bay remove <name>` finds a development pin without `--dev` when the name is only there; a name in both lists keeps its development pin unless `--dev` names it.
- `bay add https://host/owner/repo`, a repository's page URL, adds the git repository there (Zig fetched it as a file and refused its HTML); a git URL with no ref is pinned at its newest release, or the default branch where there is none.

## [0.1.8] - 2026-10-13

### Fixed

- A test of the train itself: a dependent landed from a scratch checkout pins its dependency's new release.
- A workspace member checked out a second time (a landing's scratch worktree, another clone) is that member, not a second package beside it: the stale copy replaced the one being built, so `tidy` there pinned what the stale copy pinned and left a landing behind a dependency's new release. A raise that would lower a pin is refused, naming both versions.

### Changed

- Pins aegis 0.1.3.

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

[Unreleased]: https://github.com/pedronaugusto/bay/compare/v0.1.10...HEAD
[0.1.10]: https://github.com/pedronaugusto/bay/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/pedronaugusto/bay/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/pedronaugusto/bay/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/pedronaugusto/bay/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/pedronaugusto/bay/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/pedronaugusto/bay/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/pedronaugusto/bay/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/pedronaugusto/bay/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/pedronaugusto/bay/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/pedronaugusto/bay/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/pedronaugusto/bay/releases/tag/v0.1.0
