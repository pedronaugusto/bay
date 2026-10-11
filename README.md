# bay

bay gives Zig packages development dependencies: the test frameworks, linters,
benchmark drivers and CI tools a package is developed with, kept apart from what
it ships. Everything else is Zig's own: `zig fetch` fetches and hashes, Zig's
cache holds the packages, and `zig build` runs the steps.

Work in progress. Requires Zig 0.17.0.

## Why

A Zig manifest has one list of dependencies. A test tool listed there is part of
the package's graph for everyone who depends on it, and when the tool is itself
developed with the package, the graph has a cycle: each version pins an older one
of the other, and Zig walks every one of them it finds on disk.

bay adds `.dev_dependencies` beside `.dependencies`. Zig ignores the field, so a
package that depends on yours never sees it, and nothing in it can form a cycle.

## A package with bay

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

`zig build` works as before for everything in `build`. `bay <step>` runs a step
of the package's own build, or else of its development build: a package that
bay writes under `.zig-cache/bay`, whose dependencies are this package and its
dev dependencies, and whose build calls `dev`. In `dev`, `b` is that build's;
the package's own files are reached through `b.dependency("<its name>", ...)`.

## Commands

```
bay new <name>             a new package in a new directory: zig init, then the
                           empty dev list and a `dev` function
bay init                   the same for the package here, adding only what is missing
bay build | test | run     zig build, zig build test, zig build run
bay <step> [args]          the step from the package's build, or else its development build
bay add [--dev] [--lazy] [--name <name>] <url or directory>
                           pin a dependency through zig fetch; a name pinned in the
                           other list moves to this one
bay remove [--dev] <name>  drop a dependency
bay update [name...]       pin what each recorded ref (?ref=) names now
bay list                   both lists, with their pins
bay fetch                  fetch every dependency of both kinds
```

`bay init` at a package's root changes only what is missing; inside a package
but not at its root it refuses. `ZIG` names the zig executable (default: `zig`).

## License

MIT
