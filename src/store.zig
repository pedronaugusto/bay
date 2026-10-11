//! Where pinned packages are, for reading their manifests and copying their
//! files: a project's `zig-pkg`, where Zig 0.17 unpacks a project's packages;
//! bay's own unpacked copy of an archive in Zig's global cache (`p/<hash>.tar.gz`);
//! else fetched by Zig itself, whose hash must be the pin's.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const select = @import("select.zig");
const say = @import("say.zig");
const git = @import("git.zig");

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

    pub fn loader(store: *Store) select.Loader {
        return .{ .context = store, .loadFn = load };
    }

    fn load(context: *anyopaque, place: select.Place) anyerror!select.Revision {
        const store: *Store = @ptrCast(@alignCast(context)); // safe: the loader is made from a *Store
        const directory = switch (place) {
            .remote => |remote| try store.directoryOf(remote),
            .directory => |directory| directory,
        };
        return revisionAt(store.io, store.a, directory, place);
    }

    /// The directory of a pinned package: unpacked already, unpacked from Zig's
    /// archive, or fetched by Zig first.
    pub fn directoryOf(store: *Store, remote: select.Place.Remote) ![]const u8 {
        if (store.found.get(remote.hash)) |directory| return directory;
        const directory = try store.search(remote.hash) orelse
            try store.unpack(remote.hash) orelse fetched: {
            try store.fetch(remote);
            break :fetched try store.unpack(remote.hash) orelse try say.fail(store.io, "{s} fetched, yet Zig's cache has no {s}", .{ remote.url, remote.hash });
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
        const result = std.process.run(store.a, store.io, .{ .argv = &.{ store.zig, "fetch", remote.url }, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 20) }) catch |err|
            try say.fail(store.io, "could not run {s} fetch: {t}", .{ store.zig, err });
        if (result.term != .exited or result.term.exited != 0) {
            try say.relay(store.io, result.stderr);
            try say.fail(store.io, "could not fetch {s}", .{remote.url});
        }
        const hash = std.mem.trim(u8, result.stdout, " \r\n");
        if (!std.mem.eql(u8, hash, remote.hash)) try say.fail(store.io, "{s} is {s} now, but it is pinned as {s}: the pin names other content", .{ remote.url, hash, remote.hash });
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
        try markExecutables(io, store.a, root);
        try Io.Dir.cwd().rename(root, Io.Dir.cwd(), destination, io);
        if (root.len != partial.len) try Io.Dir.cwd().deleteTree(io, partial);
        return destination;
    }
};

/// The revision whose files are in `directory`: its manifest read, its pins
/// with path dependencies made absolute. A package without a manifest pins
/// nothing and is known by its place.
pub fn revisionAt(io: Io, a: std.mem.Allocator, directory: []const u8, place: select.Place) !select.Revision {
    const path = try std.fs.path.join(a, &.{ directory, "build.zig.zon" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .identity = .{ .name = place.key(), .fingerprint = 0 }, .version = .{ .major = 0, .minor = 0, .patch = 0 }, .place = place, .pins = &.{} },
        else => |e| return e,
    };
    const parsed = manifest.parse(a, try a.dupeSentinel(u8, text, 0)) catch |err| switch (err) {
        error.InvalidManifest => try say.fail(io, "{s} is not a manifest bay can read", .{path}),
        error.OutOfMemory => |e| return e,
    };
    const version = std.SemanticVersion.parse(parsed.version) catch
        try say.fail(io, "{s}: .version \"{s}\" is not a semantic version", .{ path, parsed.version });
    return .{
        .identity = .{ .name = parsed.name, .fingerprint = parsed.fingerprint },
        .version = version,
        .place = place,
        .pins = try pins(a, directory, parsed.normal),
        .retracted = parsed.retracted,
    };
}

/// A manifest's dependencies as places, a path one made absolute against `directory`.
pub fn pins(a: std.mem.Allocator, directory: []const u8, dependencies: []const manifest.Dependency) ![]const select.Pin {
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

/// Gives each file in `path` that starts as a program does (`#!`, ELF, Mach-O)
/// the executable bit, as Zig 0.17 does when it unpacks a package: an archive's
/// own modes are ignored by both, so what bay copies from here is what Zig unpacks.
fn markExecutables(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    if (!Io.File.Permissions.has_executable_bit) return;
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        var header: [4]u8 = undefined;
        const length = try file.readPositional(io, &.{&header}, 0);
        if (startsAsProgram(header[0..length])) try file.setPermissions(io, .executable_file);
    }
}

fn startsAsProgram(header: []const u8) bool {
    if (std.mem.startsWith(u8, header, "#!")) return true;
    if (std.mem.startsWith(u8, header, std.elf.MAGIC)) return true;
    if (header.len < 4) return false;
    const magic = std.mem.readInt(u32, header[0..4], @import("builtin").cpu.arch.endian());
    return switch (magic) {
        std.macho.MH_MAGIC, std.macho.MH_MAGIC_64, std.macho.FAT_MAGIC, std.macho.FAT_MAGIC_64, std.macho.MH_CIGAM, std.macho.MH_CIGAM_64, std.macho.FAT_CIGAM, std.macho.FAT_CIGAM_64 => true,
        else => false,
    };
}

test "a file is a program by its first bytes, as Zig takes it" {
    try std.testing.expect(startsAsProgram("#!/bin/sh"));
    try std.testing.expect(startsAsProgram("\x7fELF"));
    try std.testing.expect(!startsAsProgram("pub "));
    try std.testing.expect(!startsAsProgram("#"));
}
