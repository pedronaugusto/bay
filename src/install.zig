//! Global installs, as `cargo install` makes them: a package's programs built
//! the way its author builds them, `zig build install -Doptimize=ReleaseSafe`,
//! from a copy of its sources, into a prefix: `~/.local` by default, so they land
//! in `~/.local/bin`. What each install put where is recorded in bay's data
//! directory, so `bay uninstall` removes exactly that and `--update` follows the
//! ref an install came from.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const manifest = @import("manifest.zig");
const fetch = @import("fetch.zig");
const dirs = @import("dirs.zig");
const say = @import("say.zig");
const store = @import("store.zig");
const resolve = @import("resolve.zig");
const toolchain = @import("toolchain.zig");

pub const Record = struct {
    name: []const u8,
    /// A URL as Zig records it, `?ref=` kept, or a directory.
    source: []const u8,
    prefix: []const u8,
    /// The installed files, relative to the prefix.
    files: []const []const u8,
};

const Records = struct { installs: []const Record = &.{} };

pub const Context = struct {
    io: Io,
    a: std.mem.Allocator,
    zig: []const u8,
    environ: *const std.process.Environ.Map,
    /// The package bay runs in, for `bay install` with no source; null outside one.
    package: ?[]const u8,
};

/// `bay install [--prefix <dir>] [--name <name>] [--force] [<url or directory>]`,
/// `bay install --list` and `bay install --update [name...]`.
pub fn command(c: Context, args: []const []const u8) !u8 {
    var prefix: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var force = false;
    var mode: enum { one, list, update } = .one;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list")) mode = .list else if (std.mem.eql(u8, arg, "--update")) mode = .update else if (std.mem.eql(u8, arg, "--force")) force = true else if (std.mem.eql(u8, arg, "--prefix") or std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i == args.len) try say.fail(c.io, "{s} needs a value", .{arg});
            if (std.mem.eql(u8, arg, "--prefix")) prefix = args[i] else name = args[i];
        } else try rest.append(c.a, arg);
    }
    var records = try load(c);
    switch (mode) {
        .list => {
            for (records.items) |record| {
                try say.out(c.io, "{s}  {s}\n", .{ record.name, record.source });
                for (record.files) |file| try say.out(c.io, "    {s}\n", .{try std.fs.path.join(c.a, &.{ record.prefix, file })});
            }
            if (records.items.len == 0) try say.note(c.io, "nothing installed", .{});
            return 0;
        },
        .update => {
            for (records.items) |record| {
                if (rest.items.len != 0 and !contains(rest.items, record.name)) continue;
                if (std.mem.find(u8, record.source, "://") == null) {
                    if (try one(c, &records, record.source, record.prefix, record.name, true) != 0) return 1;
                    continue;
                }
                const url = manifest.following(c.a, record.source) orelse {
                    try say.note(c.io, "{s} was installed from an exact commit; bay install it with a branch or tag to follow one", .{record.name});
                    continue;
                };
                if (try one(c, &records, url, record.prefix, record.name, true) != 0) return 1;
            }
            return 0;
        },
        .one => {
            if (rest.items.len > 1) try say.fail(c.io, "install takes one url or directory", .{});
            const source = if (rest.items.len == 1) rest.items[0] else c.package orelse try say.fail(c.io, "install needs a url or directory, or a package here", .{});
            return one(c, &records, source, prefix orelse try defaultPrefix(c), name, force);
        },
    }
}

/// `bay uninstall <name>`: removes the files the install of `name` put in place.
pub fn uninstall(c: Context, args: []const []const u8) !u8 {
    if (args.len != 1) try say.fail(c.io, "uninstall takes one name", .{});
    var records = try load(c);
    for (records.items, 0..) |record, index| {
        if (!std.mem.eql(u8, record.name, args[0])) continue;
        for (record.files) |file| Io.Dir.cwd().deleteFile(c.io, try std.fs.path.join(c.a, &.{ record.prefix, file })) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        _ = records.orderedRemove(index);
        try save(c, records.items);
        try say.note(c.io, "{s} uninstalled", .{record.name});
        return 0;
    }
    try say.fail(c.io, "{s} is not installed; bay install --list names what is", .{args[0]});
}

/// Installs one package from `source`, a URL or a directory, replacing an
/// earlier install of the same name.
/// The install build of the copy in `work`, as bay builds any package: with the
/// Zig it names, its graph resolved, its pins raised to the selection in the copy
/// and a fork wherever content differs.
fn buildCommand(c: Context, work: []const u8, stage: []const u8, cache: []const u8) ![]const []const u8 {
    const zig = try toolchain.forPackage(c.io, c.a, c.environ, work);
    const manifest_path = try std.fs.path.join(c.a, &.{ work, "build.zig.zon" });
    var text = try c.a.dupeSentinel(u8, try Io.Dir.cwd().readFileAlloc(c.io, manifest_path, c.a, .limited(1 << 20)), 0);
    const resolution = try resolve.resolve(.{ .io = c.io, .a = c.a, .zig = zig, .package = work, .parsed = try manifest.parse(c.a, text) });
    for (resolution.raises) |raise| text = try manifest.put(c.a, text, raise.kind, raise.to);
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = manifest_path, .data = text });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ zig, "build", "install", "-Doptimize=ReleaseSafe", "--prefix", stage, "--cache-dir", cache });
    try argv.appendSlice(c.a, try resolution.forks(.package, work));
    return argv.toOwnedSlice(c.a);
}

fn one(c: Context, records: *std.ArrayList(Record), source: []const u8, prefix: []const u8, given_name: ?[]const u8, force: bool) !u8 {
    const data = try dirs.data(c.io, c.a, c.environ);
    var recorded = source;
    const package_dir = if (std.mem.find(u8, source, "://") == null)
        try Io.Dir.cwd().realPathFileAlloc(c.io, source, c.a)
    else directory: {
        const dependency = try fetch.fetch(c.io, c.a, c.zig, try std.fs.path.join(c.a, &.{ data, "fetch" }), source, given_name) orelse return 1;
        recorded = dependency.source.remote.url;
        const packages = try store.Store.init(c.io, c.a, c.zig, try std.fs.path.join(c.a, &.{ data, "fetch" }));
        break :directory try packages.directoryOf(.{ .url = dependency.source.remote.url, .hash = dependency.source.remote.hash });
    };
    const package_text = Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.a, &.{ package_dir, "build.zig.zon" }), c.a, .limited(1 << 20)) catch
        try say.fail(c.io, "{s} has no build.zig.zon", .{source});
    const name = given_name orelse (try manifest.parse(c.a, try c.a.dupeSentinel(u8, package_text, 0))).name;
    // The build runs in a copy, so Zig's package cache is never written to.
    const work = try std.fs.path.join(c.a, &.{ data, "work", name });
    const stage = try std.fs.path.join(c.a, &.{ data, "stage", name });
    try Io.Dir.cwd().deleteTree(c.io, work);
    try Io.Dir.cwd().deleteTree(c.io, stage);
    try copyTree(c, package_dir, work);
    const argv = try buildCommand(c, work, stage, try std.fs.path.join(c.a, &.{ data, "cache", name }));
    var child = std.process.spawn(c.io, .{ .argv = argv, .cwd = .{ .path = work } }) catch |err|
        try say.fail(c.io, "could not run {s}: {t}", .{ argv[0], err });
    switch (try child.wait(c.io)) {
        .exited => |code| if (code != 0) return code,
        else => return 1,
    }
    const files = try listTree(c, stage);
    if (files.len == 0) try say.fail(c.io, "{s} installs nothing", .{name});
    const previous = find(records.items, name);
    for (files) |file| {
        const destination = try std.fs.path.join(c.a, &.{ prefix, file });
        for (records.items) |record| {
            if (std.mem.eql(u8, record.name, name) or !std.mem.eql(u8, record.prefix, prefix)) continue;
            if (contains(record.files, file)) try say.fail(c.io, "{s} belongs to {s}; bay uninstall {s} first", .{ destination, record.name, record.name });
        }
        const ours = if (previous) |index| std.mem.eql(u8, records.items[index].prefix, prefix) and contains(records.items[index].files, file) else false;
        if (!ours and !force) if (Io.Dir.cwd().access(c.io, destination, .{})) |_| {
            try say.fail(c.io, "{s} exists and bay did not install it; --force replaces it", .{destination});
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }
    // What the earlier install put in place and this one does not: all of it, when the prefix moved.
    if (previous) |index| for (records.items[index].files) |file| {
        if (std.mem.eql(u8, records.items[index].prefix, prefix) and contains(files, file)) continue;
        Io.Dir.cwd().deleteFile(c.io, try std.fs.path.join(c.a, &.{ records.items[index].prefix, file })) catch |err| switch (err) {
            // Removed by hand since: nothing is left to remove.
            error.FileNotFound => {},
            else => |e| return e,
        };
    };
    var stage_dir = try Io.Dir.cwd().openDir(c.io, stage, .{});
    defer stage_dir.close(c.io);
    var prefix_dir = try Io.Dir.cwd().createDirPathOpen(c.io, prefix, .{});
    defer prefix_dir.close(c.io);
    for (files) |file| try stage_dir.copyFile(file, prefix_dir, file, c.io, .{ .make_path = true });
    const record: Record = .{ .name = name, .source = recorded, .prefix = prefix, .files = files };
    if (previous) |index| records.items[index] = record else try records.append(c.a, record);
    try save(c, records.items);
    try say.note(c.io, "{s} installed from {s}", .{ name, recorded });
    for (files) |file| try say.out(c.io, "{s}\n", .{try std.fs.path.join(c.a, &.{ prefix, file })});
    return 0;
}

fn find(records: []const Record, name: []const u8) ?usize {
    for (records, 0..) |record, index| if (std.mem.eql(u8, record.name, name)) return index;
    return null;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |candidate| if (std.mem.eql(u8, candidate, item)) return true;
    return false;
}

/// Directories a build makes or a checkout keeps, which are not the package's sources.
fn skipped(name: []const u8) bool {
    for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" }) |skip| if (std.mem.eql(u8, name, skip)) return true;
    return false;
}

fn copyTree(c: Context, from: []const u8, to: []const u8) !void {
    var source = try Io.Dir.cwd().openDir(c.io, from, .{ .iterate = true });
    defer source.close(c.io);
    var target = try Io.Dir.cwd().createDirPathOpen(c.io, to, .{});
    defer target.close(c.io);
    var walker = try source.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (skipped(entry.basename)) {
            if (entry.kind == .directory) walker.leave(c.io);
            continue;
        }
        switch (entry.kind) {
            .directory => try target.createDirPath(c.io, entry.path),
            .file => try source.copyFile(entry.path, target, entry.path, c.io, .{ .make_path = true }),
            else => {},
        }
    }
}

/// The files under `path`, relative to it.
fn listTree(c: Context, path: []const u8) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(c.io, path, .{ .iterate = true }) catch return &.{};
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(c.io)) |entry| if (entry.kind == .file) try files.append(c.a, try c.a.dupe(u8, entry.path));
    return files.items;
}

/// `~/.local`, whose `bin` is on PATH on most systems; `%LOCALAPPDATA%\bay` on Windows.
fn defaultPrefix(c: Context) ![]const u8 {
    if (builtin.os.tag == .windows) return std.fs.path.join(c.a, &.{ c.environ.get("LOCALAPPDATA") orelse try say.fail(c.io, "LOCALAPPDATA is not set; give --prefix", .{}), "bay" });
    return std.fs.path.join(c.a, &.{ c.environ.get("HOME") orelse try say.fail(c.io, "HOME is not set; give --prefix", .{}), ".local" });
}

fn load(c: Context) !std.ArrayList(Record) {
    const path = try std.fs.path.join(c.a, &.{ try dirs.data(c.io, c.a, c.environ), "installed.zon" });
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    const records = std.zon.parse.fromSlice(Records, .{ .gpa = c.a, .arena = c.a, .source = try c.a.dupeSentinel(u8, text, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch
        try say.fail(c.io, "{s} is not a record bay can read", .{path});
    var list: std.ArrayList(Record) = .empty;
    try list.appendSlice(c.a, records.installs);
    return list;
}

fn save(c: Context, records: []const Record) !void {
    const data = try dirs.data(c.io, c.a, c.environ);
    try Io.Dir.cwd().createDirPath(c.io, data);
    var out: Io.Writer.Allocating = .init(c.a);
    try std.zon.stringify.serialize(Records{ .installs = records }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.fs.path.join(c.a, &.{ data, "installed.zon" }), .data = out.written() });
}
