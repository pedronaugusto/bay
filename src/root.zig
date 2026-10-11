//! The development root: a package bay writes under `.zig-cache/bay`, whose
//! dependencies are the package itself, its dependencies and its dev dependencies, and whose
//! build runs the package's `pub fn dev(b: *std.Build, tools: type) void`.
//! Zig fetches, hashes and caches it like any other package.
const std = @import("std");
const manifest = @import("manifest.zig");
const select = @import("select.zig");

/// Where the development root lives, relative to the package.
pub const directory = ".zig-cache/bay";

/// The root's own package name: one no dependency can take, since a dependency
/// key is the package's name and `bay` reserves this one.
const root_name = "bay_development";

/// The root's `build.zig.zon`.
/// The package is a path dependency of the root, or, when something in the graph pins
/// it, that hash (`pinned`), which a fork turns into the working tree: a package
/// appears under one hash only.
pub fn manifestText(a: std.mem.Allocator, package: manifest.Manifest, pinned: ?select.Place.Remote) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print(
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x{x},
        \\
    , .{ root_name, fingerprint(root_name, package.name) });
    if (package.minimum_zig_version) |version| try w.print("    .minimum_zig_version = \"{f}\",\n", .{std.zig.fmtString(version)});
    try w.print(
        \\    .paths = .{{""}},
        \\    .dependencies = .{{
        \\
    , .{});
    if (pinned) |remote|
        try w.print("        .{f} = .{{ .url = \"{f}\", .hash = \"{f}\" }},\n", .{ std.zig.fmtId(package.name), std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) })
    else
        try w.print("        .{f} = .{{ .path = \"../..\" }},\n", .{std.zig.fmtId(package.name)});
    // The package's own dependencies too, as Cargo gives a crate's tests its
    // dependencies: `dev` reaches a shipped one by name, and Zig shares it with
    // the package by hash. A name in both lists is one dependency, pinned once.
    for (package.normal) |dependency| {
        if (find(package.dev, dependency.name)) |dev| {
            if (!sameSource(dev.source, dependency.source)) return error.PinnedTwiceDifferently;
            continue;
        }
        try entry(a, w, dependency);
    }
    for (package.dev) |dependency| {
        if (std.mem.eql(u8, dependency.name, package.name)) return error.DevDependencyNamedAsPackage;
        try entry(a, w, dependency);
    }
    try w.writeAll("    },\n}\n");
    return out.toOwnedSlice();
}

fn entry(a: std.mem.Allocator, w: *std.Io.Writer, dependency: manifest.Dependency) !void {
    const lazy = if (dependency.lazy) ", .lazy = true" else "";
    switch (dependency.source) {
        .remote => |remote| try w.print("        .{f} = .{{ .url = \"{f}\", .hash = \"{f}\"{s} }},\n", .{ std.zig.fmtId(dependency.name), std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash), lazy }),
        // A relative path is relative to the package; the root sits two directories below it.
        .path => |path| try w.print("        .{f} = .{{ .path = \"{f}\"{s} }},\n", .{ std.zig.fmtId(dependency.name), std.zig.fmtString(if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(a, &.{ "..", "..", path })), lazy }),
    }
}

fn find(dependencies: []const manifest.Dependency, name: []const u8) ?manifest.Dependency {
    for (dependencies) |dependency| if (std.mem.eql(u8, dependency.name, name)) return dependency;
    return null;
}

fn sameSource(x: manifest.Source, y: manifest.Source) bool {
    return switch (x) {
        .remote => |remote| y == .remote and std.mem.eql(u8, remote.hash, y.remote.hash),
        .path => |path| y == .path and std.mem.eql(u8, path, y.path),
    };
}

/// The root's `build.zig`: each dev dependency's build script as a declaration
/// of the `tools` it passes (analyzed only where `dev` uses it), then the call.
pub fn buildText(a: std.mem.Allocator, package: manifest.Manifest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\//! Written by bay from build.zig.zon; it is rewritten when the manifest changes.
        \\const std = @import("std");
        \\
    );
    for (package.dev) |dependency| try w.print("pub const {f} = @import(\"{f}\");\n", .{ std.zig.fmtId(dependency.name), std.zig.fmtString(dependency.name) });
    try w.print(
        \\const package = @import("{f}");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    if (!@hasDecl(package, "dev")) @compileError("build.zig has no `pub fn dev(b: *std.Build, tools: type) void`, which bay runs with the dev dependencies");
        \\    package.dev(b, @This());
        \\}}
        \\
    , .{std.zig.fmtString(package.name)});
    return out.toOwnedSlice();
}

/// A manifest with no dependencies, for `zig fetch --save` to write one into.
pub fn scratchManifest(a: std.mem.Allocator) ![]u8 {
    return a.print(".{{ .name = .bay_add, .version = \"0.0.0\", .fingerprint = 0x{x}, .paths = .{{\"\"}}, .dependencies = .{{}} }}\n", .{fingerprint("bay_add", "bay_add")});
}

/// A fingerprint Zig accepts for `name`: the checksum of the name above an id.
/// The id is derived from the package's name, so the root of one package keeps
/// one identity across runs and machines.
fn fingerprint(name: []const u8, package: []const u8) u64 {
    var id: u32 = @truncate(std.hash.Wyhash.hash(0, package));
    if (id == 0 or id == std.math.maxInt(u32)) id = 1;
    return @as(u64, std.hash.Crc32.hash(name)) << 32 | id;
}

/// Writes the root under `package_dir`, touching a file only when its text changes,
/// so an unchanged manifest leaves Zig's configure cache warm.
pub fn write(io: std.Io, a: std.mem.Allocator, package_dir: std.Io.Dir, package: manifest.Manifest, pinned: ?select.Place.Remote) !void {
    try package_dir.createDirPath(io, directory);
    var dir = try package_dir.openDir(io, directory, .{});
    defer dir.close(io);
    try writeIfChanged(io, a, dir, "build.zig.zon", try manifestText(a, package, pinned));
    try writeIfChanged(io, a, dir, "build.zig", try buildText(a, package));
}

fn writeIfChanged(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, text: []const u8) !void {
    if (dir.readFileAlloc(io, name, a, .limited(1 << 20))) |old| {
        if (std.mem.eql(u8, old, text)) return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
}

test "the root depends on the package and each dev dependency" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const package: manifest.Manifest = .{ .name = "demo", .minimum_zig_version = "0.17.0", .normal = &.{}, .dev = &.{
        .{ .name = "tool", .source = .{ .remote = .{ .url = "git+https://example.org/tool#v1", .hash = "tool-0.1.0-AAAA" } } },
        .{ .name = "local", .source = .{ .path = "../local" } },
    } };
    const text = try manifestText(a, package, null);
    const parsed = try manifest.parse(a, try a.dupeSentinel(u8, text, 0));
    try std.testing.expectEqualStrings(root_name, parsed.name);
    try std.testing.expect(std.mem.find(u8, text, ".demo = .{ .path = \"../..\" }") != null);
    try std.testing.expect(std.mem.find(u8, text, ".local = .{ .path = \"../../../local\" }") != null);
    try std.testing.expect(std.mem.find(u8, text, ".hash = \"tool-0.1.0-AAAA\"") != null);
    const build = try buildText(a, package);
    try std.testing.expect(std.mem.find(u8, build, "pub const tool = @import(\"tool\");") != null);
    try std.testing.expect(std.mem.find(u8, build, "const package = @import(\"demo\");") != null);
}

test "the fingerprint carries the checksum Zig checks" {
    const value = fingerprint(root_name, "demo");
    try std.testing.expectEqual(std.hash.Crc32.hash(root_name), @as(u32, @truncate(value >> 32)));
    try std.testing.expectEqual(value, fingerprint(root_name, "demo"));
    try std.testing.expect(value != fingerprint(root_name, "other"));
}

test "a dev dependency cannot take the package's own name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const package: manifest.Manifest = .{ .name = "demo", .minimum_zig_version = null, .normal = &.{}, .dev = &.{.{ .name = "demo", .source = .{ .path = "x" } }} };
    try std.testing.expectError(error.DevDependencyNamedAsPackage, manifestText(arena.allocator(), package, null));
}

test "the root carries the package's own dependencies, a name in both lists once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shipped: manifest.Dependency = .{ .name = "fault", .source = .{ .remote = .{ .url = "git+https://example.org/fault#v1", .hash = "fault-0.1.0-AAAA" } }, .lazy = true };
    const package: manifest.Manifest = .{ .name = "demo", .minimum_zig_version = null, .normal = &.{ shipped, .{ .name = "core", .source = .{ .path = "../core" } } }, .dev = &.{shipped} };
    const text = try manifestText(a, package, null);
    try std.testing.expectEqual(1, std.mem.count(u8, text, ".fault = "));
    try std.testing.expect(std.mem.find(u8, text, ".hash = \"fault-0.1.0-AAAA\", .lazy = true") != null);
    try std.testing.expect(std.mem.find(u8, text, ".core = .{ .path = \"../../../core\" }") != null);
    const parsed = try manifest.parse(a, try a.dupeSentinel(u8, text, 0));
    try std.testing.expectEqual(3, parsed.normal.len);
    // One name pinned two ways is two dependencies under one name: refused.
    const other: manifest.Dependency = .{ .name = "fault", .source = .{ .remote = .{ .url = "git+https://example.org/fault#v2", .hash = "fault-0.2.0-BBBB" } } };
    const split: manifest.Manifest = .{ .name = "demo", .minimum_zig_version = null, .normal = &.{shipped}, .dev = &.{other} };
    try std.testing.expectError(error.PinnedTwiceDifferently, manifestText(a, split, null));
}

test "a lazy dev dependency stays lazy in the root, so Zig fetches it only when a build asks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const emulator: manifest.Dependency = .{ .name = "emulator", .source = .{ .remote = .{ .url = "git+https://example.org/emulator#v1", .hash = "emulator-1.0.0-AAAA" } }, .lazy = true };
    const package: manifest.Manifest = .{ .name = "demo", .minimum_zig_version = null, .normal = &.{}, .dev = &.{emulator} };
    const parsed = try manifest.parse(a, try a.dupeSentinel(u8, try manifestText(a, package, null), 0));
    for (parsed.normal) |dependency| if (std.mem.eql(u8, dependency.name, "emulator")) return std.testing.expect(dependency.lazy);
    return error.TestExpectedEqual;
}
