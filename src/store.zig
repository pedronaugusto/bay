//! Where pinned packages are, for reading their manifests and copying their
//! files: a project's `zig-pkg`, where Zig 0.17 unpacks a project's packages;
//! bay's own unpacked copy of an archive in Zig's global cache (`p/<hash>.tar.gz`);
//! else fetched by Zig itself, whose hash must be the pin's.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const manifest = @import("manifest.zig");
const select = @import("select.zig");
const say = @import("say.zig");
const git = @import("git.zig");
const tree = @import("tree.zig");
const scratchManifest = @import("root.zig").scratchManifest;

/// Where bay unpacks an archived package to read it, under the package.
pub const unpacked_directory = ".zig-cache/bay/packages";

pub const Store = struct {
    io: Io,
    a: std.mem.Allocator,
    zig: []const u8,
    /// Directories holding unpacked packages by hash, searched in order.
    directories: []const []const u8,
    /// Zig's global cache, whose `p` holds packages as archives.
    global: []const u8,
    /// Where bay unpacks an archive: the last of `directories`.
    unpacked: []const u8,
    /// Package directories by hash, once found.
    found: std.array_hash_map.String([]const u8) = .empty,

    /// The store for a package: its `zig-pkg`, which both its builds use, and bay's unpacked copies.
    pub fn init(io: Io, a: std.mem.Allocator, zig: []const u8, package: []const u8) !*Store {
        const store = try a.create(Store);
        const unpacked = try std.fs.path.join(a, &.{ package, unpacked_directory });
        store.* = .{ .io = io, .a = a, .zig = zig, .global = try globalCache(io, a, zig), .unpacked = unpacked, .directories = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ package, "zig-pkg" }),
            unpacked,
        }) };
        return store;
    }

    /// The revision at a place, for selection: fetched and read.
    pub fn load(store: *Store, place: select.Place) !select.Revision {
        const directory = switch (place) {
            // A package with no manifest pins nothing and is known by its place, so it
            // has nothing to select and is not fetched: Zig fetches it when a build asks.
            .remote => |remote| if (unnamed(remote.hash)) return placed(place) else try store.directoryOf(remote),
            .directory => |directory| directory,
        };
        return revisionAt(store.io, store.a, directory, place);
    }

    /// The directory of a pinned package: unpacked already, unpacked from Zig's
    /// archive, or fetched by Zig first.
    pub fn directoryOf(store: *Store, remote: select.Place.Remote) ![]const u8 {
        // Zig never fetches what only git reaches: such a package must be where Zig
        // looks, the project's zig-pkg or Zig's cache, not only in bay's copy.
        if (git.handles(remote.url) and !try store.withZig(remote.hash)) try store.fetch(remote);
        if (store.found.get(remote.hash)) |directory| return directory;
        const directory = try store.search(remote.hash) orelse
            try store.unpack(remote.hash) orelse fetched: {
            try store.fetch(remote);
            break :fetched try store.search(remote.hash) orelse try store.unpack(remote.hash) orelse try say.fail(store.io, "{s} fetched, yet Zig has no {s}", .{ remote.url, remote.hash });
        };
        try store.found.put(store.a, remote.hash, directory);
        return directory;
    }

    fn fetch(store: *Store, remote: select.Place.Remote) !void {
        if (git.handles(remote.url)) {
            const fetched = try git.fetch(store.io, store.a, store.zig, try std.fs.path.join(store.a, &.{ store.unpacked, "git" }), remote.url);
            if (!std.mem.eql(u8, fetched.hash, remote.hash)) try say.fail(store.io, "{s} is {s} now, but it is pinned as {s}: the pin names other content", .{ remote.url, fetched.hash, remote.hash });
            return;
        }
        // Zig 0.17's `zig fetch <url>` prints an archive's hash with its one top
        // directory taken away, but keeps that directory in the copy it stores in its
        // cache, so every later build unpacks other content and refuses the pin. A
        // build's own fetch stores the package as it hashes it: the package is fetched
        // as the one dependency of a scratch build, checked against the pin by Zig,
        // and unpacked by Zig where bay reads it. Its lazy dependencies are not: bay
        // reads each manifest resolution needs on its own, and one Zig fetches for a
        // build on another host (a riscv64 machine's root file system, whose links
        // Windows makes only with SeCreateSymbolicLinkPrivilege) is no business of this one.
        const scratch = try std.fs.path.join(store.a, &.{ std.fs.path.dirname(store.unpacked).?, "fetch" });
        try Io.Dir.cwd().deleteTree(store.io, scratch);
        try Io.Dir.cwd().createDirPath(store.io, scratch);
        var dir = try Io.Dir.cwd().openDir(store.io, scratch, .{});
        defer dir.close(store.io);
        try dir.writeFile(store.io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *@import(\"std\").Build) void {}\n" });
        const dependency = try store.a.print(".pinned = .{{ .url = \"{f}\", .hash = \"{f}\" }},", .{ std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) });
        try dir.writeFile(store.io, .{ .sub_path = "build.zig.zon", .data = try scratchManifest(store.a, "bay_fetch", dependency) });
        // Where Zig unpacks, beside the scratch build: relative to it, since Zig 0.17 makes
        // the path dependencies of a package unpacked under an absolute --pkg-dir absolute,
        // then refuses them ("expected path relative to build root").
        const destination = try std.fs.path.join(store.a, &.{ "..", std.fs.path.basename(store.unpacked) });
        const result = std.process.run(store.a, store.io, .{ .argv = &.{ store.zig, "build", "--fetch", "--pkg-dir", destination }, .cwd = .{ .path = scratch }, .stderr_limit = .limited(1 << 20) }) catch |err|
            try say.fail(store.io, "could not run {s} build --fetch: {t}", .{ store.zig, err });
        if (result.term != .exited or result.term.exited != 0) {
            try say.relay(store.io, result.stderr);
            try say.fail(store.io, "could not fetch {s} as it is pinned, {s}", .{ remote.url, remote.hash });
        }
        try Io.Dir.cwd().deleteTree(store.io, scratch);
    }

    /// Whether Zig finds the package `hash` without fetching it: unpacked in the
    /// project's zig-pkg, or kept in Zig's cache.
    fn withZig(store: *Store, hash: []const u8) !bool {
        const places = [_][]const u8{
            try std.fs.path.join(store.a, &.{ store.directories[0], hash }),
            try std.fs.path.join(store.a, &.{ store.global, "p", hash }),
            try std.fs.path.join(store.a, &.{ store.global, "p", try store.a.print("{s}.tar.gz", .{hash}) }),
        };
        for (places) |place| {
            if (Io.Dir.cwd().access(store.io, place, .{})) |_| return true else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }
        return false;
    }

    fn search(store: *Store, hash: []const u8) !?[]const u8 {
        for (store.directories) |root| {
            const candidate = try std.fs.path.join(store.a, &.{ root, hash });
            if (Io.Dir.cwd().access(store.io, candidate, .{})) |_| return candidate else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }
        return null;
    }

    /// Unpacks Zig's archive of `hash`, as Zig unpacks it, beside its final
    /// place and then renamed, so no reader sees half a package; null when Zig
    /// has no archive of it.
    fn unpack(store: *Store, hash: []const u8) !?[]const u8 {
        const io = store.io;
        const archive_path = try std.fs.path.join(store.a, &.{ store.global, "p", try store.a.print("{s}.tar.gz", .{hash}) });
        const archive = Io.Dir.cwd().openFile(io, archive_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        defer archive.close(io);
        const destination = try std.fs.path.join(store.a, &.{ store.unpacked, hash });
        const partial = try store.a.print("{s}.partial", .{destination});
        try Io.Dir.cwd().deleteTree(io, partial);
        try Io.Dir.cwd().createDirPath(io, partial);
        var out = try Io.Dir.cwd().openDir(io, partial, .{});
        defer out.close(io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = archive.reader(io, &buffer);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
        var diagnostics: std.tar.Diagnostics = .{ .allocator = store.a };
        try std.tar.extract(io, out, &decompress.reader, .{ .diagnostics = &diagnostics, .mode_mode = .ignore, .exclude_empty_directories = true });
        if (diagnostics.errors.items.len != 0) try say.fail(io, "{s} did not unpack: {d} entries failed", .{ archive_path, diagnostics.errors.items.len });
        // An archive holding one directory holds the package in it.
        const root = if (diagnostics.root_dir.len != 0) try std.fs.path.join(store.a, &.{ partial, diagnostics.root_dir }) else partial;
        try tree.markExecutables(io, store.a, root);
        try Io.Dir.cwd().rename(root, Io.Dir.cwd(), destination, io);
        if (root.len != partial.len) try Io.Dir.cwd().deleteTree(io, partial);
        return destination;
    }
};

/// The revision whose files are in `directory`: its manifest read, its pins
/// with path dependencies made absolute. A package without a manifest pins
/// nothing and is known by its place.
pub fn revisionAt(io: Io, a: std.mem.Allocator, directory: []const u8, place: select.Place) !select.Revision {
    return read(io, a, directory, place, false);
}

/// A package under development in `directory`: its revision with its dev
/// dependencies among its pins, marked so, as Go counts a main module's tests.
pub fn developedAt(io: Io, a: std.mem.Allocator, directory: []const u8) !select.Revision {
    return read(io, a, directory, .{ .directory = directory }, true);
}

fn read(io: Io, a: std.mem.Allocator, directory: []const u8, place: select.Place, developed: bool) !select.Revision {
    const path = try std.fs.path.join(a, &.{ directory, "build.zig.zon" });
    const text = aegis.own.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return placed(place),
        else => |e| return e,
    };
    const parsed = manifest.parse(a, try a.dupeSentinel(u8, text, 0)) catch |err| switch (err) {
        error.InvalidManifest => try say.fail(io, "{s} is not a manifest bay can read", .{path}),
        error.OutOfMemory => |e| return e,
    };
    return revisionOf(io, a, directory, place, parsed, developed);
}

/// The revision `parsed`, the manifest of the package in `directory` as it
/// stands in memory, makes: what a command about to write it resolves.
pub fn revisionOf(io: Io, a: std.mem.Allocator, directory: []const u8, place: select.Place, parsed: manifest.Manifest, developed: bool) !select.Revision {
    const version = std.SemanticVersion.parse(parsed.version) catch
        try say.fail(io, "{s}/build.zig.zon: .version \"{s}\" is not a semantic version", .{ directory, parsed.version });
    const shipped = try pins(a, directory, parsed.normal);
    const developing = try pins(a, directory, if (developed) parsed.dev else &.{});
    for (developing) |*pin| pin.dev = true;
    return .{
        .identity = .{ .name = parsed.name, .fingerprint = parsed.fingerprint },
        .version = version,
        .place = place,
        .pins = try std.mem.concat(a, select.Pin, &.{ shipped, developing }),
        .retracted = parsed.retracted,
    };
}

/// The revision of a package with no manifest: it pins nothing and is known by its place.
fn placed(place: select.Place) select.Revision {
    return .{ .identity = .{ .name = place.key(), .fingerprint = 0 }, .version = .{ .major = 0, .minor = 0, .patch = 0 }, .place = place, .pins = &.{} };
}

/// Whether `hash` is one Zig gives a package with no manifest: `N-V-`, for no
/// name and no version (Zig 0.17, `Fetch.computedPackageHash`). A name is a Zig
/// identifier and a version a semantic one, so no package with a manifest has it.
pub fn unnamed(hash: []const u8) bool {
    return std.mem.startsWith(u8, hash, "N-V-");
}

test unnamed {
    try std.testing.expect(unnamed("N-V-__8AAIMAbQDh5mA2AUF0Pyrm-UxpzkldsIiukdrGCem4"));
    try std.testing.expect(!unnamed("aegis-0.1.17-rsxouvg5CABaJmNEkRXQIkVJ6JqVOG7NN60ctSBvSzO_"));
    try std.testing.expect(!unnamed("N-0.1.0-rsxouvg5CABaJmNEkRXQIkVJ6JqVOG7NN60ctSBvSzO_"));
    try std.testing.expect(!unnamed("1220aabbccdd"));
}

/// A manifest's dependencies as places, a path one made absolute against `directory`.
pub fn pins(a: std.mem.Allocator, directory: []const u8, dependencies: []const manifest.Dependency) ![]select.Pin {
    const list = try a.alloc(select.Pin, dependencies.len);
    for (list, dependencies) |*pin, dependency| pin.* = .{
        .key = dependency.name,
        .lazy = dependency.lazy,
        .place = switch (dependency.source) {
            .remote => |remote| .{ .remote = .{ .url = remote.url, .hash = remote.hash } },
            .path => |relative| .{ .directory = try std.fs.path.resolveAlloc(a, &.{ directory, relative }) },
        },
    };
    return list;
}

/// Zig's global cache, as `zig env` reports it.
pub fn globalCache(io: Io, a: std.mem.Allocator, zig: []const u8) ![]const u8 {
    const result = std.process.run(a, io, .{ .argv = &.{ zig, "env" }, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run {s} env: {t}", .{ zig, err });
    const Env = struct { global_cache_dir: []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const env = std.zon.parse.fromSlice(Env, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, result.stdout, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch
        try say.fail(io, "could not read {s} env", .{zig});
    return env.global_cache_dir;
}
