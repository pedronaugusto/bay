# bay

**A package manager for Zig, built on Zig's own.** bay selects one version of every
package across the whole graph, keeps development tools out of what a package ships,
develops many packages together as one workspace, and builds each with the exact Zig
it names.

Zig fetches, hashes, caches and builds. bay decides what Zig fetches and writes the
packages Zig builds, adding what a Zig manifest has no words for:

- **Development dependencies**: test frameworks, linters and CI tools a package is
  developed with, kept out of what it ships.
- **One version of each package**: when two dependencies pin different revisions
  of a third, bay selects one, so a type that crosses between them is one type.
- **Workspaces**: several packages developed together, each built from its local
  checkout, run in dependency order, and pinned at each other's releases.
- **The exact Zig**: the version a package names, downloaded and verified.

A package developed with bay is still a plain Zig package. Anyone without bay builds
it with `zig build` from its manifest, as before.

Requires Zig 0.17.0. Work in progress.

## Install

From source, with Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bay install
```

bay installs itself into `~/.local/bin`. Installed from a URL
(`bay install git+https://github.com/pedronaugusto/bay#v0.1.14`), it updates with
`bay install --update bay`. After that no Zig is needed first: bay builds each
package with the Zig it names, installing it on first use, and starts a new package
with the Zig on the `PATH`, or else the release bay was built with. `zig build dist`
builds the program for every host into `zig-out/dist`: `bay-x86_64-linux`,
`bay-aarch64-linux`, `bay-x86_64-macos`, `bay-aarch64-macos`, `bay-x86_64-windows.exe`
and `bay-aarch64-windows.exe`.

## A first package

```sh
bay new example && cd example
bay add git+https://github.com/owner/library#v1.2.0   # a dependency it ships
bay add --dev git+https://github.com/owner/checker    # a tool it is developed with
bay test                                               # zig build test, with both
bay tree                                               # what it builds with
bay update                                             # library to its newest v1 release, never v2
```

An existing package adopts bay with `bay init` at its root, which adds an empty
`.dev_dependencies` and a `dev` function and changes nothing else. Move a tool out of
`.dependencies` with `bay remove <name>` and `bay add --dev <url>`, and its steps
from `build` into `dev`. Projects that depend on yours never see the difference.

## Development dependencies

`.dev_dependencies` sits beside `.dependencies`, with the same entries. Zig ignores
it, so a package that depends on yours never fetches what is in it, and a tool that
is itself developed with your package forms no cycle.

```zig
.{
    .name = .example,
    .version = "0.1.0",
    .minimum_zig_version = "0.17.0",
    .fingerprint = 0x...,
    .paths = .{ "build.zig", "build.zig.zon", "src" },
    .dependencies = .{},
    .dev_dependencies = .{
        .checker = .{
            .url = "git+https://example.org/checker?ref=main#...",
            .hash = "checker-0.3.0-...",
        },
    },
}
```

`build.zig` keeps `build` for what the package ships and adds `dev` for its
development:

```zig
pub fn build(b: *std.Build) void {
    // Modules, artifacts and steps that need only .dependencies.
}

pub fn dev(b: *std.Build, tools: type) void {
    // tools.checker is the checker's build.zig; the package is a dependency here.
    tools.checker.addChecks(b, b.dependency("example", .{}));
}
```

`bay <step>` runs the step from the package's own build, or, when it has none by
that name, from its development build. In `dev`, the package is
`b.dependency("example", ...)`, and a dependency it ships is reached by its own name,
the same package Zig gives the package. A dependency that is both shipped and used in
development is listed once, in `.dependencies`.

## One version of each package

Two dependencies may pin different revisions of a third. Zig builds both, and when a
value of one reaches the other the build fails with `expected type 'T', found 'T'`.
bay selects one, by Go's Minimal Version Selection: a pin is a minimum, every revision
the graph reaches is read, and each package builds at the highest `.version` any of
them pins. The answer is the same whatever order or depth packages are found in, and
it only rises as pins do.

Zig then gets a graph in which each package appears once. A dependency whose own pins
name other revisions is built from a copy with only those pins rewritten, which
`zig build --fork` substitutes for it; no package's files are edited. The package's
own pins must already name the selection: a build that disagrees stops and says why,
and `bay tidy` writes them.

| Case | What bay does |
| --- | --- |
| The package is also a dependency of its own tools | The working tree wins over every revision of it: one copy, the one under test |
| Two contents claim one version | Refused, naming who pins each, unless the package pins one itself |
| Two lines of one package: a new major, or below 1.0 a new minor | Refused, naming who asks for each, unless the package lists it in `.coexist` |
| A package that is a directory in one place and pinned in another | Refused, naming both: Zig would build two; `.overrides` makes one |
| A coexisting line whose own pins must be rewritten | Refused: Zig would rewrite every line |
| A member reached by its directory whose pins are behind the selection, or reached by hash as well | Refused: Zig reads its pins as written, or builds it twice |
| A package naming itself in `.coexist` | Refused: a package builds one line of itself |
| A path dependency whose own pins are behind the selection | Refused: Zig builds it with its pins as written; name it in `bay.work` to have them tidied |
| Packages that depend on each other in a ring | Refused |

A version names one content, so every published change gets its own `.version`. A
release that is bad is withdrawn with `.retracted` in a newer release's manifest, as
Go's `retract`: `bay outdated` says when a build uses a withdrawn version, and `bay
update` never moves to one.

## Workspaces

A `bay.work` in the package's directory, or any directory above it, names packages
developed together:

```zig
.{ .members = .{ "aegis", "shakedown", "relic" } }
```

Every member is built from its directory wherever the graph pins it, so a change in
one is built and tested against the others before it is published anywhere. A member
whose own pins are behind the selection is built from a copy of its working tree with
only those pins rewritten, so no member's manifest has to change for another to build.
A member the graph reaches by its directory (a `.path` pin) is the exception: Zig builds
it from there with its own manifest's pins, so bay refuses it while those pins are behind
the selection, and when a pin by hash reaches it too, which Zig would build as a second
package. `bay --workspace tidy` settles the first.

A member's pins are what everyone outside the workspace builds with, so `bay tidy`
pins each member the package depends on at its release: the tag of the member's own
`.version` (`v1.4.0` or `1.4.0`) on its remote. A member whose version has no tag yet
has unreleased work, and pins to it stay. Pins of every other package go to the one
version selected, and the workspace is one graph, every member's development in it:
a tool one member develops with can raise the floor another member ships with, as in
a Go workspace. `bay tidy` writes only the package's own manifest; `bay --workspace
tidy` tidies every member.

`bay --workspace <command>` runs a command in every member, each after the members it
ships with and the members it is developed with (a linter or CI tool released in the
same workspace), and members with nothing between them at once (`--jobs <n>` at most;
one per CPU by default). A development dependency that would close a ring, as a tool
developed with a released copy of a package that ships it, is left out of the order:
that member uses the release it pins. A member that fails skips the members that
depend on it, and the rest go on. `bay --workspace release` releases them in that order
(below).

```sh
bay --workspace test
bay --workspace --jobs 4 build -Doptimize=ReleaseSafe
```

## Overrides

`.overrides` replaces a package for the whole graph, with a revision or a directory:

```zig
.overrides = .{
    .library = .{ .path = "../library" },
},
```

It applies only where the package that declares it is the one being built.

## Private repositories

Zig fetches over https, anonymously. A repository it cannot reach that way is pinned
by an ssh URL, which bay fetches with the system's git, using the keys and agent
already set up for it:

```sh
bay add git+ssh://git@github.com/owner/private#v1.0.0
```

bay writes the commit's tree as git stores it and has Zig hash it, so the pin is the
hash Zig gives the same commit over https, and Zig's cache keeps the package, where
every build finds it. `git+file://` works the same for a repository on disk. Tags,
`update` and `outdated` read such a remote through git too.

## Releasing

`bay release` releases the package from its `CHANGELOG.md`, written as
[Keep a Changelog](https://keepachangelog.com) writes one: each change that reaches users
adds a line under `## [Unreleased]`, in its group.

```markdown
## [Unreleased]

### Fixed

- A manifest that is not UTF-8 is refused.
```

The version is what the section asks for: `### Breaking` and `### Removed` move the minor
below 1.0 and the major from it, `### Added` and `### Deprecated` the minor from 1.0, and
anything else the last number. An empty section releases nothing. The section becomes
`## [X.Y.Z] - date` (its groups in order, a group written twice made one), the manifest's
`.version` takes the version, and both are committed as `Release vX.Y.Z`. That commit is
gated by the package's own `gate` step (preflight's, from its development build), and only
when the gate is green do the branch and the tag `vX.Y.Z` go to the branch's remote, in
one atomic push over SSH, read back before the tag is made here. A red gate leaves the
branch where it was. `bay release --dry-run` prints the version, the section and the plan;
`bay release --no-push` commits and gates, and holds the gated commit for a later `bay
release`, someone else's it may be, to push without gating it again.

It refuses a tree with changes, a branch behind its remote or with none, a remote that is
not SSH, a version already tagged, a manifest and a changelog at different releases, and a
line under no group. A release stopped after its commit is finished by the next `bay
release`, which gates the commit again; one whose push failed after a green gate is pushed
without gating it again; one pushed whose tag never reached this clone is tagged here.

Two branches adding lines under one group merge with no conflict when git merges
CHANGELOG.md with its `union` driver:

```text
# .gitattributes
CHANGELOG.md merge=union
```

A gate runs what its machine can run (a Mac its macOS suites, Linux its own). The machines
a release is gated on besides this one are named in `machines.zon` in bay's configuration
directory (`$XDG_CONFIG_HOME/bay`, `~/.config/bay`, `%APPDATA%\bay`), each with the command
that runs bay there and a directory there for its copies:

```zig
.{
    .{ .name = "linux", .bay = .{ "ssh", "linux-box", "bay" }, .directory = "/home/me/bay" },
}
```

The release commit reaches each as a git bundle on that command's stdin, and every machine
gates at once with this one, its lines named; the tag waits for all of them.

`bay --workspace release` is the train: the members in dependency order, one at a time.
Each is pinned at the releases of the members before it (as `bay tidy` pins them), its
re-pinned dependencies named in its CHANGELOG (`- Pins a 0.3.1.` under `### Changed`) and
committed, then released. A member whose only change is development pins is gated and
pushed with no tag; a member that fails stops the members that depend on it.

## The exact Zig

bay builds each package with exactly the Zig it names: `.zig_version`, or else
`.minimum_zig_version`, 0.17.0 or newer. bay keeps its own copy of each version,
downloaded from ziglang.org on first use and checked against the release index's
SHA-256 and Zig's minisign key; the Zig on the `PATH` builds only what names no
version. Setting `ZIG` names another Zig by hand.

## In CI

```sh
bay --locked tidy     # fails if a manifest is not what the selection says
bay --locked test     # runs the step; nothing is written
```

`--locked` refuses any change to a manifest. `bay vendor` has Zig unpack every package
the graph reads into the project's `zig-pkg`, which the package's build and its
development build both read before the network, so the project resolves and builds
with no remote reachable.

## Commands

| Command | Does |
| --- | --- |
| `bay new <name>` | A new package in a new directory: `zig init`, then the empty dev list and a `dev` function |
| `bay init` | The same for the package here, adding only what is missing |
| `bay build [args]` | `zig build` of the package, the arguments passed on as given |
| `bay <step> [args]` | The step from the package's build, or else its development build |
| `bay dev [args]` | `zig build` in the development build, as given |
| `bay add [--dev] [--lazy] [--name <name>] <url or dir>...` | Pin dependencies through `zig fetch`, then tidy once; a repository's URL (`https://github.com/owner/repo`) is pinned at its newest release; a name already pinned stays in its list, `--dev` picks the list of a new one |
| `bay remove [--dev] <name>` | Drop a dependency from the list that holds it; `--dev` where it is in both |
| `bay update [name...]` | Pin what each recorded ref names now: a branch at its head, a release tag at the newest release on its line |
| `bay upgrade [name...]` | Pin each at the newest release tag of its repository, across lines, whether it was pinned at a tag or a commit; a repository with no release tag stays |
| `bay tidy` | Pin each package at the version selection picks, and in a workspace each member at its release |
| `bay list` | Both lists, with their pins |
| `bay tree [--why <name>] [--duplicates]` | The resolved graph; the paths to one package; the packages pinned at several revisions, and by whom |
| `bay outdated` | Packages the builds use with a newer release on their remote, or at a version their newest release retracts |
| `bay licenses [--dev]` | Each package a build contains, with the license its files state; `--dev` adds the development tools |
| `bay audit` | Each package the builds select, checked against its repository's published security advisories (GitHub; `GITHUB_TOKEN` when set) and its own retractions; fails on any finding |
| `bay vendor` | Every package the graph reads, into `zig-pkg` |
| `bay release [--dry-run] [--no-push]` | Release the package from its CHANGELOG's `[Unreleased]` section: commit, gate here and on the machines in `machines.zon`, push the branch and its tag at once over SSH |
| `bay --workspace release` | Release every member that changed, in dependency order, each pinned at the releases before it |
| `bay locate [--dev]` | The package's directory, or its development build's root |
| `bay fetch` | Fetch every dependency of both kinds |
| `bay install [--prefix <dir>] [--name <name>] [--force] [<url or dir>]` | Build a package's programs (ReleaseSafe) into `<dir>/bin`, `~/.local/bin` by default; with no source, the package here |
| `bay install --list` | What bay installed, and from where |
| `bay install --update [name...]` | Reinstall each from its recorded branch or tag |
| `bay uninstall <name>` | Remove exactly what its install put in place |
| `bay completions <shell>` | The completion script for bash, zsh, fish or PowerShell |

`bay --help` and `bay <command> --help` say what each takes. `bay --locked <command>` refuses to write a manifest. `add`, `remove`, `update` and `upgrade`
tidy after they write, once for all they pinned. `bay --workspace [--jobs <n>] <command>` runs the command in
every member of the workspace, after what each ships with and is developed with.

## Manifest fields

All are ignored by Zig.

| Field | Meaning |
| --- | --- |
| `.dev_dependencies` | Dependencies of the package's development only |
| `.overrides` | Packages replaced for the whole graph when this package is built |
| `.coexist = .{ .name }` | Packages whose incompatible lines may be selected side by side |
| `.retracted = .{ "0.4.0" }` | Versions of this package a newer release withdraws: `outdated` names them in use, `update` skips them |
| `.zig_version` | The exact Zig to build with; `.minimum_zig_version` when absent |

## Global installs

`bay install` fetches a package as `zig fetch` does (a `git+https` or archive URL, at
a `#tag`, `#branch` or `#commit`), copies its sources and builds them as anything that
depends on the package would: what it ships, without its development dependencies, as
`cargo install` does. Zig's package cache is never written to. bay records what each
install put where in `~/.local/share/bay/installed.zon` (`$XDG_DATA_HOME/bay`):
`uninstall` removes exactly that, and a file bay did not install is never replaced
without `--force`. Installed programs run without bay.

## How it works

The development build is a package bay writes under `.zig-cache/bay`. It depends on
the package, the package's dependencies and its dev dependencies, and its `build`
calls the package's `dev` with a `tools` type whose declarations are the dev
dependencies' build scripts. Either build runs in the package's directory, as Cargo
runs a crate's tests in its own, so what it runs reads the package's files by their
path in it; the development build's root, which its paths are relative to, is what
`bay locate --dev` names for a tool that reads a configured build. Copies for rewritten pins live under `.zig-cache/bay/forks`, and an
archive bay must read is unpacked under `.zig-cache/bay/packages`. bay sets `BAY` to
its own path for everything it runs.

## License

MIT
