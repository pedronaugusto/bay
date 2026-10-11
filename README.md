# bay

bay is a package manager on top of Zig's. Zig fetches, hashes and builds; bay
decides what to fetch, and writes the packages Zig builds. It adds what a Zig
manifest has no words for: development dependencies, one version of each
package when several are asked for, packages developed together, and the exact
Zig a package builds with. Every package stays plain Zig: `zig build` works
without bay, from each manifest's own pins.

Work in progress. Requires Zig 0.17.0.

## Install

From a clone, with Zig 0.17.0 on the PATH:

```
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bay install
```

bay installs itself into `~/.local/bin` (put it on the PATH) and records what it
put there. Installed from a URL instead (`bay install git+https://...#v0.1.0`), it
updates with `bay install --update bay`. From then on bay
fetches the exact Zig each package names; the one on the PATH only starts a new
package.

## Getting started

A new package:

```
bay new example && cd example
bay add git+https://github.com/owner/library#v1.2.0     # a dependency it ships
bay add --dev git+https://github.com/owner/checker      # a tool it is developed with
bay test                                                 # its tests, as zig build test runs them
bay tree                                                 # what it builds with
```

An existing package: `bay init` at its root adds the empty `.dev_dependencies`
and a `dev` function and changes nothing else; `zig build` keeps working. Move a
tool from `.dependencies` with `bay remove <name>` and `bay add --dev <url>`, and
its steps from `build` into `dev`. A project that depends on yours never runs
bay: it sees `build` and `.dependencies`, as before.

Developing several packages together: put a `bay.work` above them naming each
(see Workspaces), and every build uses the local checkouts. `bay tidy` keeps
their pins on one version of each.

In CI: install bay, then `bay --locked tidy` fails if a manifest is not what the
selection says, and `bay --locked <step>` runs the step without changing
anything. `bay vendor` keeps every package in the project for a build with no
network.

## Development dependencies

A Zig manifest has one list of dependencies. A test tool listed there is part of
the package's graph for everyone who depends on it, and when the tool is itself
developed with the package, the graph has a cycle. bay adds `.dev_dependencies`
beside `.dependencies`. Zig ignores the field, so a package that depends on yours
never sees it.

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

`build.zig` keeps `build` for what the package ships, and adds `dev` for its
development:

```zig
pub fn build(b: *std.Build) void {
    // Modules, artifacts and steps that need only .dependencies.
}

pub fn dev(b: *std.Build, tools: type) void {
    // tools.checker is the checker's build.zig.
    tools.checker.addChecks(b, b.dependency("example", .{}));
}
```

`bay <step>` runs a step of the package's own build, or else of its development
build: a package bay writes under `.zig-cache/bay` whose dependencies are this
package, its dependencies and its dev dependencies, and whose build calls `dev`.
In `dev`, the package is `b.dependency("<its name>", ...)` and a dependency it
ships is `b.dependency("<that name>", ...)`, the same package Zig gives the
package. One a package ships and also develops with is listed once.

## One version of each package

Two dependencies may pin different revisions of a third. Zig builds both, and
when a type of one reaches the other the build fails: `expected type 'T', found
'T'`. bay selects one, as Go's modules do (Minimal Version Selection): a pin is
a minimum, and each package builds at the highest `.version` any manifest in the
graph pins. Every revision the graph reaches is read, so the answer does not
depend on the order they are found in.

bay then gives Zig a graph in which each package appears once. A dependency whose
own pins name other revisions is built from a copy of it with only its manifest's
pins rewritten, which `zig build --fork` substitutes; the package's own files
are never touched. The package's own pins must already name the selection: a
build that disagrees stops and says so, and `bay tidy` writes them, as Go writes
go.mod. `bay --locked <command>` never writes a manifest, for CI.

- The package under development always wins over every revision of itself: a
  test tool that depends on the package links the working tree, one copy.
- Two revisions that claim one version with different contents are refused,
  naming who pins each, unless the package pins one of them itself. A version
  names one content; give each change its own.
- A different major version, or below 1.0 a different minor, is a new line. A
  graph that asks for two lines of one package is refused, with who asks for
  each, unless the package names it in `.coexist = .{ .name }`.
- A package's manifest may list versions of it that no selection may pick:
  `.retracted = .{ "0.4.0" }`.

## Workspaces and overrides

A `bay.work` in the package's directory or one above it names packages developed
together, as Go's go.work does:

```zig
.{ .members = .{ "aegis", "shakedown", "relic" } }
```

Each member is built from its directory wherever the graph pins it, so a change
in one is tested against the others before it is published. `bay tidy` keeps
every member's pins on the one version selected.

`.overrides` in the package's manifest replaces a package for the whole graph,
with a revision or a directory, as Go's `replace` and Cargo's `[patch]` do. It
applies only where the package is the one being built.

## The Zig a package builds with

bay runs exactly the Zig a package names: `.zig_version`, else
`.minimum_zig_version`. A version not yet installed is downloaded from
ziglang.org, checked against the index's SHA-256 and Zig's minisign key, and kept
in bay's data directory. `ZIG` names another one by hand.

## Commands

```
bay new <name>             a new package in a new directory: zig init, then the
                           empty dev list and a `dev` function
bay init                   the same for the package here, adding only what is missing
bay build [args]           zig build: the package's install step
bay <step> [args]          the step from the package's build, or else its development build
bay dev [args]             zig build in the development build, as given
bay add [--dev] [--lazy] [--name <name>] <url or directory>
                           pin a dependency through zig fetch in that list alone
bay remove [--dev] <name>  drop a dependency
bay update [name...]       pin what each recorded ref (?ref=) names now
bay tidy                   pin each package at the version selection picks
bay list                   both lists, with their pins
bay tree [--why <name>] [--duplicates]
                           the resolved graph; the paths to one package; the ones
                           pinned at more than one revision, and who pins each
bay outdated               dependencies with a newer release on their remote
bay vendor                 every package the graph reads, into zig-pkg, to build offline
bay locate [--dev]         the package's directory, or its development build's root
bay fetch                  fetch every dependency of both kinds

bay install [--prefix <dir>] [--force] [<url or directory>]
                           build a package's programs (ReleaseSafe) into <dir>/bin,
                           ~/.local/bin by default; with no source, the package here
bay install --list         what bay installed, and from where
bay install --update [name...]
                           reinstall each from its recorded branch or tag
bay uninstall <name>       remove what its install put in place
```

`add`, `remove` and `update` tidy after they write. A build runs in its own
root: the package's directory, or the development build's, which `bay locate
--dev` names to a tool reading the configured build. bay sets `BAY` to its own
path for everything it runs, so a tool that builds another checkout of the
package runs the same bay.

## Global installs

`bay install` is to Zig what `cargo install` is to Rust. It fetches the package as
`zig fetch` does (a `git+https` or archive URL; `#tag`, `#branch` or `#commit`),
copies its sources, and builds them as bay builds any package, into the prefix,
so Zig's package cache is never written to. bay records what each install put
where in `~/.local/share/bay/installed.zon` (`$XDG_DATA_HOME/bay`): `uninstall`
removes exactly that, and a file bay did not install is never replaced without
`--force`. Installed programs do not need bay to run.

## License

MIT
