//! bay: dependencies for Zig packages, the ones a package ships and the ones
//! only its development uses, on Zig's own package manager.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const root = @import("root.zig");
const fetch = @import("fetch.zig");
const install = @import("install.zig");
const say = @import("say.zig");

const usage =
    \\usage: bay <command> [arguments]
    \\
    \\  bay build [args]           zig build: the package's install step
    \\  bay <step> [args]          the step from the package's build, or else from its
    \\                             development build, which has the dev dependencies
    \\  bay dev [args]             zig build in the development build, as given
    \\  bay add [--dev] [--lazy] [--name <name>] <url or directory>
    \\                             fetch and pin a dependency; --dev for development only
    \\  bay remove [--dev] <name>  drop a dependency
    \\  bay update [name...]       re-resolve each pinned ref (?ref=) and pin what it names now
    \\  bay list                   both lists, with their pins
    \\  bay fetch                  fetch every dependency of both kinds
    \\
    \\  bay install [--prefix <dir>] [--force] [<url or directory>]
    \\                             build a package's programs (ReleaseSafe) into <dir>/bin,
    \\                             ~/.local/bin by default; with no source, the package here
    \\  bay install --list         what bay installed, and from where
    \\  bay install --update [name...]
    \\                             reinstall each from its recorded branch or tag
    \\  bay uninstall <name>       remove what its install put in place
    \\  bay new <name>             a new package in a new directory: zig init, then the
    \\                             empty dev list and a `dev` function
    \\  bay init                   the same for the package here, adding only what is
    \\                             missing; zig init first where there is no package
    \\
    \\Arguments after the step go to zig build. ZIG names the zig executable (default: zig).
    \\
;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = (try init.minimal.args.toSlice(a))[1..];
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return;
    }
    // Everything bay runs can run bay again, as the same program: a tool that builds
    // another checkout of the package (a benchmark comparison) needs its development build.
    try init.environ_map.put("BAY", try std.process.executablePathAlloc(io, a));
    // A reported failure has said what went wrong; it ends the run without a trace.
    const code = dispatch(io, a, init.environ_map, args) catch |err| switch (err) {
        error.Reported => 1,
        else => return err,
    };
    std.process.exit(code);
}

fn dispatch(io: Io, a: std.mem.Allocator, environ: *std.process.Environ.Map, args: []const []const u8) !u8 {
    const zig = environ.get("ZIG") orelse "zig";
    if (std.mem.eql(u8, args[0], "init")) return initCommand(io, a, zig);
    if (std.mem.eql(u8, args[0], "new")) return newCommand(io, a, zig, args[1..]);
    // Global: anywhere, as cargo install is.
    if (std.mem.eql(u8, args[0], "install") or std.mem.eql(u8, args[0], "uninstall")) {
        const context: install.Context = .{ .io = io, .a = a, .zig = zig, .environ = environ, .package = try packageHere(io, a) };
        return if (std.mem.eql(u8, args[0], "install")) install.command(context, args[1..]) else install.uninstall(context, args[1..]);
    }
    const env: Env = .{ .io = io, .a = a, .zig = zig, .environ = environ, .package = try findPackage(io, a) };
    const command = args[0];
    if (std.mem.eql(u8, command, "add")) return add(env, args[1..]);
    if (std.mem.eql(u8, command, "remove")) return removeCommand(env, args[1..]);
    if (std.mem.eql(u8, command, "update")) return update(env, args[1..]);
    if (std.mem.eql(u8, command, "list")) return list(env);
    if (std.mem.eql(u8, command, "fetch")) return fetchAll(env);
    if (std.mem.eql(u8, command, "build")) return zigBuild(env, .package, &.{}, args[1..]);
    if (std.mem.eql(u8, command, "dev")) return zigBuild(env, .development, &.{}, args[1..]);
    return step(env, command, args[1..]);
}

const Env = struct {
    io: Io,
    a: std.mem.Allocator,
    zig: []const u8,
    environ: *const std.process.Environ.Map,
    /// The package's directory: the nearest one up from here with a build.zig.zon.
    package: []const u8,

    fn dir(env: Env) !Io.Dir {
        return Io.Dir.cwd().openDir(env.io, env.package, .{});
    }

    fn readManifest(env: Env) ![:0]const u8 {
        var dir_handle = try env.dir();
        defer dir_handle.close(env.io);
        const text = try dir_handle.readFileAlloc(env.io, "build.zig.zon", env.a, .limited(1 << 20));
        return env.a.dupeSentinel(u8, text, 0);
    }
};

fn findPackage(io: Io, a: std.mem.Allocator) ![]const u8 {
    return try packageHere(io, a) orelse try say.fail(io, "no build.zig.zon here or in any directory above", .{});
}

/// The nearest directory up from here with a build.zig.zon, or null outside a package.
fn packageHere(io: Io, a: std.mem.Allocator) !?[]const u8 {
    var path: []const u8 = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    while (true) {
        const candidate = try std.fs.path.join(a, &.{ path, "build.zig.zon" });
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| return path else |_| {}
        path = std.fs.path.dirname(path) orelse return null;
    }
}

const Where = enum { package, development };

/// Runs zig build in the package, or in its development root, and returns its exit code.
fn zigBuild(env: Env, where: Where, before: []const []const u8, after: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.a, &.{ env.zig, "build" });
    try argv.appendSlice(env.a, before);
    if (where == .development) {
        const parsed = try manifest.parse(env.a, try env.readManifest());
        var dir = try env.dir();
        defer dir.close(env.io);
        root.write(env.io, env.a, dir, parsed) catch |err| switch (err) {
            error.DevDependencyNamedAsPackage => try say.fail(env.io, "a dev dependency is named {s}, the package's own name", .{parsed.name}),
            error.PinnedTwiceDifferently => try say.fail(env.io, "a name is pinned differently in .dependencies and .dev_dependencies: one name is one dependency", .{}),
            else => |e| return e,
        };
        // The development build shares the package's cache and installs where the package does.
        try argv.appendSlice(env.a, &.{
            "--build-file", try std.fs.path.join(env.a, &.{ env.package, root.directory, "build.zig" }),
            "--cache-dir",  try std.fs.path.join(env.a, &.{ env.package, ".zig-cache" }),
            "--prefix",     try std.fs.path.join(env.a, &.{ env.package, "zig-out" }),
        });
    }
    try argv.appendSlice(env.a, after);
    var child = std.process.spawn(env.io, .{ .argv = argv.items, .cwd = .{ .path = env.package }, .environ_map = env.environ }) catch |err|
        try say.fail(env.io, "could not run {s}: {t}", .{ env.zig, err });
    return switch (try child.wait(env.io)) {
        .exited => |code| code,
        else => 1,
    };
}

/// `bay <step>`: the package's own steps are what ships and come first; a step
/// the package does not have is the development build's.
fn step(env: Env, name: []const u8, args: []const []const u8) !u8 {
    const listed = std.process.run(env.a, env.io, .{ .argv = &.{ env.zig, "build", "-l" }, .cwd = .{ .path = env.package }, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(env.io, "could not run {s}: {t}", .{ env.zig, err });
    if (listed.term != .exited or listed.term.exited != 0) {
        try say.relay(env.io, listed.stderr);
        return 1;
    }
    if (hasStep(listed.stdout, name)) return zigBuild(env, .package, &.{name}, args);
    const parsed = try manifest.parse(env.a, try env.readManifest());
    if (parsed.dev.len == 0) try say.fail(env.io, "the package has no step '{s}' and no dev dependencies", .{name});
    return zigBuild(env, .development, &.{name}, args);
}

/// Whether `zig build -l` lists `name`: each step is a line of two spaces, the name, then spaces.
fn hasStep(listing: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ")) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (std.mem.eql(u8, words.next() orelse continue, name)) return true;
    }
    return false;
}

fn fetchAll(env: Env) !u8 {
    const code = try zigBuild(env, .package, &.{"--fetch=all"}, &.{});
    if (code != 0) return code;
    const parsed = try manifest.parse(env.a, try env.readManifest());
    if (parsed.dev.len == 0) return 0;
    return zigBuild(env, .development, &.{"--fetch=all"}, &.{});
}

/// `bay add`: Zig fetches into a scratch manifest with `zig fetch --save`, so
/// the URL and hash are exactly what Zig records; bay puts the entry in the
/// package's list of that kind.
fn add(env: Env, args: []const []const u8) !u8 {
    var kind: manifest.Kind = .normal;
    var lazy = false;
    var name: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dev")) kind = .dev else if (std.mem.eql(u8, args[i], "--lazy")) lazy = true else if (std.mem.eql(u8, args[i], "--name")) {
            i += 1;
            if (i == args.len) try say.fail(env.io, "--name needs a value", .{});
            name = args[i];
        } else if (target == null) target = args[i] else try say.fail(env.io, "add takes one url or directory", .{});
    }
    const where = target orelse try say.fail(env.io, "add needs a url or directory", .{});
    const dependency = if (isDirectory(env, where)) try local(env, where, name) else try fetched(env, where, name) orelse return 1;
    var entry = dependency;
    // A new pin of a dependency already in this list keeps whether it is lazy; --lazy makes it so.
    const pinned = try manifest.parse(env.a, try env.readManifest());
    for (if (kind == .dev) pinned.dev else pinned.normal) |existing| {
        if (std.mem.eql(u8, existing.name, entry.name)) entry.lazy = existing.lazy;
    }
    if (lazy) entry.lazy = true;
    var dir = try env.dir();
    defer dir.close(env.io);
    // Each list is its own, as Cargo's are: a package may ship a dependency and
    // develop with it too, so a pin in one list leaves the other as it is.
    const edited = try manifest.put(env.a, try env.readManifest(), kind, entry);
    try dir.writeFile(env.io, .{ .sub_path = "build.zig.zon", .data = edited });
    try say.note(env.io, "{s} pinned in .{s}", .{ entry.name, kind.field() });
    return 0;
}

fn isDirectory(env: Env, path: []const u8) bool {
    if (std.mem.find(u8, path, "://") != null) return false;
    var dir = Io.Dir.cwd().openDir(env.io, path, .{}) catch return false;
    dir.close(env.io);
    return true;
}

/// A directory dependency, named as its own manifest names it, at its path from the package.
fn local(env: Env, path: []const u8, name: ?[]const u8) !manifest.Dependency {
    const absolute = try Io.Dir.cwd().realPathFileAlloc(env.io, path, env.a);
    const relative = try std.fs.path.relativeAlloc(env.a, env.package, null, env.package, absolute);
    if (name) |given| return .{ .name = given, .source = .{ .path = relative } };
    var dir = try Io.Dir.cwd().openDir(env.io, absolute, .{});
    defer dir.close(env.io);
    const text = dir.readFileAlloc(env.io, "build.zig.zon", env.a, .limited(1 << 20)) catch try say.fail(env.io, "{s} has no build.zig.zon; name it with --name", .{path});
    const parsed = try manifest.parse(env.a, try env.a.dupeSentinel(u8, text, 0));
    return .{ .name = parsed.name, .source = .{ .path = relative } };
}

fn fetched(env: Env, url: []const u8, name: ?[]const u8) !?manifest.Dependency {
    return fetch.fetch(env.io, env.a, env.zig, try std.fs.path.join(env.a, &.{ env.package, root.directory, "add" }), url, name);
}

fn removeCommand(env: Env, args: []const []const u8) !u8 {
    var kind: manifest.Kind = .normal;
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dev")) kind = .dev else if (name == null) name = arg else try say.fail(env.io, "remove takes one name", .{});
    }
    const target = name orelse try say.fail(env.io, "remove needs a name", .{});
    const edited = manifest.remove(env.a, try env.readManifest(), kind, target) catch |err| switch (err) {
        error.NotFound => try say.fail(env.io, "no {s} in .{s}", .{ target, kind.field() }),
        else => return err,
    };
    var dir = try env.dir();
    defer dir.close(env.io);
    try dir.writeFile(env.io, .{ .sub_path = "build.zig.zon", .data = edited });
    try say.note(env.io, "{s} removed from .{s}", .{ target, kind.field() });
    return 0;
}

/// `bay update`: each remote pin of either kind (or those named) fetched again
/// at the ref its URL records, and pinned to what that ref names now. A pin to
/// an exact commit, or a directory, has nothing to follow and stays.
fn update(env: Env, names: []const []const u8) !u8 {
    const parsed = try manifest.parse(env.a, try env.readManifest());
    var text = try env.readManifest();
    var found: usize = 0;
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .normal) parsed.normal else parsed.dev;
        for (dependencies) |dependency| {
            if (names.len != 0 and !contains(names, dependency.name)) continue;
            found += 1;
            const remote = switch (dependency.source) {
                .remote => |remote| remote,
                .path => continue,
            };
            const url = manifest.following(env.a, remote.url) orelse {
                try say.note(env.io, "{s} is pinned to an exact commit; bay add it with a branch or tag to follow one", .{dependency.name});
                continue;
            };
            var next = try fetched(env, url, dependency.name) orelse return 1;
            next.lazy = dependency.lazy;
            if (std.mem.eql(u8, next.source.remote.hash, remote.hash)) continue;
            text = try manifest.put(env.a, text, kind, next);
            try say.note(env.io, "{s} {s} -> {s}", .{ dependency.name, remote.hash, next.source.remote.hash });
        }
    }
    if (names.len != 0 and found < names.len) try say.fail(env.io, "not every name given is a dependency", .{});
    var dir = try env.dir();
    defer dir.close(env.io);
    try dir.writeFile(env.io, .{ .sub_path = "build.zig.zon", .data = text });
    return 0;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn list(env: Env) !u8 {
    const parsed = try manifest.parse(env.a, try env.readManifest());
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .normal) parsed.normal else parsed.dev;
        try say.out(env.io, ".{s}{s}\n", .{ kind.field(), if (dependencies.len == 0) ": none" else "" });
        for (dependencies) |dependency| switch (dependency.source) {
            .remote => |remote| try say.out(env.io, "  {s}{s}  {s}\n    {s}\n", .{ dependency.name, if (dependency.lazy) " (lazy)" else "", remote.url, remote.hash }),
            .path => |path| try say.out(env.io, "  {s}{s}  {s}\n", .{ dependency.name, if (dependency.lazy) " (lazy)" else "", path }),
        };
    }
    return 0;
}

const dev_function =
    \\
    \\/// The development build: `bay <step>` runs the steps added here, with the
    \\/// dev dependencies of build.zig.zon as `tools` (`tools.<name>` is that
    \\/// package's build.zig). A package that depends on this one never runs it.
    \\pub fn dev(b: *std.Build, tools: type) void {
    \\    _ = b;
    \\    _ = tools;
    \\}
    \\
;

/// `bay init`: the package here becomes a bay package. Where there is none yet,
/// Zig's own template makes one; then the empty dev list and a `dev` function,
/// each only when it is missing. Inside a package but not at its root, nothing.
fn initCommand(io: Io, a: std.mem.Allocator, zig: []const u8) !u8 {
    const here = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    if (Io.Dir.cwd().access(io, "build.zig.zon", .{})) |_| {} else |_| {
        if (enclosing(io, a, here)) |package| try say.fail(io, "this is inside the package at {s}: run bay init there, or bay new <name> for a package of its own", .{package});
    }
    return prepare(io, a, zig, here);
}

/// `bay new <name>`: a new package in a new directory `name` here.
fn newCommand(io: Io, a: std.mem.Allocator, zig: []const u8, args: []const []const u8) !u8 {
    if (args.len != 1) try say.fail(io, "new takes one name: the directory and the package", .{});
    Io.Dir.cwd().createDir(io, args[0], .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => try say.fail(io, "{s} exists; bay init inside it makes it a package", .{args[0]}),
        else => return err,
    };
    return prepare(io, a, zig, try Io.Dir.cwd().realPathFileAlloc(io, args[0], a));
}

/// The nearest directory above `path` with a build.zig.zon.
fn enclosing(io: Io, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(path);
    while (dir) |candidate| : (dir = std.fs.path.dirname(candidate)) {
        const zon = std.fs.path.join(a, &.{ candidate, "build.zig.zon" }) catch return null;
        if (Io.Dir.cwd().access(io, zon, .{})) |_| return candidate else |_| {}
    }
    return null;
}

fn prepare(io: Io, a: std.mem.Allocator, zig: []const u8, path: []const u8) !u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    if (dir.access(io, "build.zig.zon", .{})) |_| {} else |_| {
        var child = std.process.spawn(io, .{ .argv = &.{ zig, "init" }, .cwd = .{ .path = path } }) catch |err| try say.fail(io, "could not run {s}: {t}", .{ zig, err });
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) return code,
            else => return 1,
        }
    }
    const text = try dir.readFileAlloc(io, "build.zig.zon", a, .limited(1 << 20));
    if (try manifest.ensureList(a, try a.dupeSentinel(u8, text, 0), .dev)) |edited| try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = edited });
    const build = dir.readFileAlloc(io, "build.zig", a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => try say.fail(io, "build.zig.zon has no build.zig beside it", .{}),
        else => return err,
    };
    if (std.mem.find(u8, build, "pub fn dev(") == null) {
        try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.mem.concat(a, u8, &.{ build, dev_function }) });
    }
    try say.note(io, "{s} is ready; bay add --dev <url> pins a development tool, bay <step> runs its steps", .{path});
    return 0;
}

test "update follows a recorded ref and leaves a commit pin" {
    const a = std.testing.allocator;
    const branch = manifest.following(a, "git+https://example.org/x?ref=main#5d2a92141f0298d76dc5fd602526d55a62b4e11a").?;
    defer a.free(branch);
    try std.testing.expectEqualStrings("git+https://example.org/x#main", branch);
    try std.testing.expectEqual(null, manifest.following(a, "git+https://example.org/x#5d2a92141f0298d76dc5fd602526d55a62b4e11a"));
    try std.testing.expectEqualStrings("https://example.org/x.tar.gz", manifest.following(a, "https://example.org/x.tar.gz").?);
}

test "a step is found in zig build -l's listing" {
    const listing =
        \\  install (default)            Copy build artifacts to prefix path
        \\  uninstall                    Remove build artifacts from prefix path
        \\  test                         Run the tests
        \\
    ;
    try std.testing.expect(hasStep(listing, "test"));
    try std.testing.expect(hasStep(listing, "install"));
    try std.testing.expect(!hasStep(listing, "preflight"));
}

test {
    _ = manifest;
    _ = root;
    _ = @import("select.zig");
}
