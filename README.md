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

Each release carries the program for every host: `bay-x86_64-linux`,
`bay-aarch64-linux`, `bay-x86_64-macos`, `bay-aarch64-macos`, `bay-x86_64-windows.exe`
and `bay-aarch64-windows.exe`. Put the one for yours on the `PATH` as `bay`:

```sh
curl -fL -o ~/.local/bin/bay https://github.com/pedronaugusto/bay/releases/latest/download/bay-aarch64-macos
chmod +x ~/.local/bin/bay
```

No Zig is needed first. bay builds each package with the Zig it names, installing it
on first use, and starts a new package with the Zig on the `PATH`, or else the release
bay was built with.

From source, with Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bay install
```

bay installs itself into `~/.local/bin`. Installed from a URL
(`bay install git+https://github.com/pedronaugusto/bay#v0.1.0`), it updates with
`bay install --update bay`. `zig build dist` builds the release programs into
`zig-out/dist`.

## A first package

```sh
bay new example && cd example
bay add git+https://github.com/owner/library#v1.2.0   # a dependency it ships
bay add --dev git+https://github.com/owner/checker    # a tool it is developed with
bay test                                               # zig build test, with both
bay tree                                               # what it builds with
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
bay selects one, by Go's Minimal Version Selection: a pin is a minimum, and each
package builds at the highest `.version` pinned by the package or by a revision
already selected. Selection runs in rounds over the whole graph, so the answer does
not depend on the order packages are found in, and what an older revision asked for
stops counting once a newer one is chosen.

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
| A version a newer revision retracts | Refused, naming the retracting version |
| Packages that depend on each other in a ring | Refused |

A version names one content, so every published change gets its own `.version`.

## Workspaces

A `bay.work` in the package's directory, or any directory above it, names packages
developed together:

```zig
.{ .members = .{ "aegis", "shakedown", "relic" } }
```

Every member is built from its directory wherever the graph pins it, so a change in
one is built and tested against the others before it is published anywhere.

A member's pins are what everyone outside the workspace builds with, so `bay tidy`
pins each member another member depends on at its release: the tag of the member's
own `.version` (`v1.4.0` or `1.4.0`) on its remote. A member whose version has no tag
yet has unreleased work, and pins to it stay. Pins of every other package go to the
one version selected.

`bay --workspace <command>` runs a command in every member, each after the members it
ships with, and members with nothing between them at once (`--jobs <n>` at most; one
per CPU by default). A member that fails skips the members that depend on it, and the
rest go on. Releasing a workspace is then one command per member in order: once a
member is tagged, `bay tidy` in the next pins that release.

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

## The exact Zig

bay builds each package with exactly the Zig it names: `.zig_version`, or else
`.minimum_zig_version`. A version not yet on the machine is downloaded from
ziglang.org, checked against the release index's SHA-256 and Zig's minisign key, and
kept in bay's data directory. Setting `ZIG` names another Zig by hand.

## In CI

```sh
bay --locked tidy     # fails if a manifest is not what the selection says
bay --locked test     # runs the step; nothing is written
```

`--locked` refuses any change to a manifest. `bay vendor` keeps every package the
graph reads in the project's `zig-pkg`, where Zig and bay look before the network, so
the project resolves and builds with no remote reachable.

## Commands

| Command | Does |
| --- | --- |
| `bay new <name>` | A new package in a new directory: `zig init`, then the empty dev list and a `dev` function |
| `bay init` | The same for the package here, adding only what is missing |
| `bay build [args]` | `zig build` of the package |
| `bay <step> [args]` | The step from the package's build, or else its development build |
| `bay dev [args]` | `zig build` in the development build, as given |
| `bay add [--dev] [--lazy] [--name <name>] <url or dir>` | Pin a dependency through `zig fetch`, in that list only |
| `bay remove [--dev] <name>` | Drop a dependency |
| `bay update [name...]` | Pin what each recorded ref names now: a branch at its head, a release tag at the newest release on its line |
| `bay tidy` | Pin each package at the version selection picks, and in a workspace each member at its release |
| `bay list` | Both lists, with their pins |
| `bay tree [--why <name>] [--duplicates]` | The resolved graph; the paths to one package; the packages pinned at several revisions, and by whom |
| `bay outdated` | Dependencies with a newer release on their remote |
| `bay licenses [--dev]` | Each package a build contains, with the license its files state; `--dev` adds the development tools |
| `bay vendor` | Every package the graph reads, into `zig-pkg` |
| `bay locate [--dev]` | The package's directory, or its development build's root |
| `bay fetch` | Fetch every dependency of both kinds |
| `bay install [--prefix <dir>] [--force] [<url or dir>]` | Build a package's programs (ReleaseSafe) into `<dir>/bin`, `~/.local/bin` by default; with no source, the package here |
| `bay install --list` | What bay installed, and from where |
| `bay install --update [name...]` | Reinstall each from its recorded branch or tag |
| `bay uninstall <name>` | Remove exactly what its install put in place |

`bay --locked <command>` refuses to write a manifest. `add`, `remove` and `update`
tidy after they write. `bay --workspace [--jobs <n>] <command>` runs the command in
every member of the workspace, in dependency order.

## Manifest fields

All are ignored by Zig.

| Field | Meaning |
| --- | --- |
| `.dev_dependencies` | Dependencies of the package's development only |
| `.overrides` | Packages replaced for the whole graph when this package is built |
| `.coexist = .{ .name }` | Packages whose incompatible lines may be selected side by side |
| `.retracted = .{ "0.4.0" }` | Versions of this package no selection may pick |
| `.zig_version` | The exact Zig to build with; `.minimum_zig_version` when absent |

## Global installs

`bay install` fetches a package as `zig fetch` does (a `git+https` or archive URL, at
a `#tag`, `#branch` or `#commit`), copies its sources and builds them as bay builds
any package, so Zig's package cache is never written to. bay records what each install
put where in `~/.local/share/bay/installed.zon` (`$XDG_DATA_HOME/bay`): `uninstall`
removes exactly that, and a file bay did not install is never replaced without
`--force`. Installed programs run without bay.

## How it works

The development build is a package bay writes under `.zig-cache/bay`. It depends on
the package, the package's dependencies and its dev dependencies, and its `build`
calls the package's `dev` with a `tools` type whose declarations are the dev
dependencies' build scripts. A build runs in its own root, the package's directory or
the development build's, which `bay locate --dev` names for a tool that reads a
configured build. Copies for rewritten pins live under `.zig-cache/bay/forks`, and an
archive bay must read is unpacked under `.zig-cache/bay/packages`. bay sets `BAY` to
its own path for everything it runs.

## License

MIT
