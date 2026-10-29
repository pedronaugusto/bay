//! Global installs, as `cargo install` makes them: a package's programs built
//! the way its author builds them, `zig build install -Doptimize=ReleaseSafe`,
//! from a copy of its sources, into a prefix: `~/.local` by default, so they land
//! in `~/.local/bin`. What each install put where is recorded in bay's data
//! directory, so `bay uninstall` removes exactly that and `--update` follows the
//! ref an install came from.
const std = @import("std");
const aegis = @import("aegis");
const airlock = @import("airlock");
const ensign = @import("ensign");
const builtin = @import("builtin");
const Io = std.Io;
const manifest = @import("manifest.zig");
const fetch = @import("fetch.zig");
const dirs = @import("dirs.zig");
const say = @import("say.zig");
const store = @import("store.zig");
const published = @import("published.zig");
const root = @import("root.zig");
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

/// `bay install`'s arguments.
pub const Args = struct {
    prefix: ?[]const u8 = null,
    name: ?[]const u8 = null,
    force: bool = false,
    list: bool = false,
    update: bool = false,
    sources: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build a package's programs (ReleaseSafe) into <prefix>/bin, ~/.local/bin by default; with no source, the package here",
        .options = .{
            .prefix = .{ .value_name = "DIR", .hint = .directory, .help = "Install under this directory's bin" },
            .name = .{ .help = "The name to record the install under" },
            .force = .{ .help = "Replace programs another install put in place" },
            .list = .{ .help = "What bay installed, and from where" },
            .update = .{ .help = "Reinstall each one named, or every one, from its recorded branch or tag" },
            .sources = .{ .positional = true, .value_name = "SOURCE", .hint = .directory, .help = "A URL or directory to install from; with --update, the names to reinstall" },
        },
        .conflicts = &.{&.{ .list, .update }},
    };
};

/// `bay uninstall`'s argument.
pub const Uninstall = struct {
    name: []const u8,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Remove what an install put in place",
        .options = .{ .name = .{ .positional = true } },
    };
};

/// `bay install [--prefix <dir>] [--name <name>] [--force] [<url or directory>]`,
/// `bay install --list` and `bay install --update [name...]`.
pub fn command(c: Context, args: Args) !u8 {
    const mode: enum { one, list, update } = if (args.list) .list else if (args.update) .update else .one;
    const rest = args.sources;
    const prefix = args.prefix;
    const name = args.name;
    const force = args.force;
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
                if (rest.len != 0 and !contains(rest, record.name)) continue;
                if (std.mem.find(u8, record.source, "://") == null) {
                    if (try one(c, &records, record.source, record.prefix, record.name, true) != 0) return 1;
                    continue;
                }
                const url = try manifest.following(c.a, record.source) orelse {
                    try say.note(c.io, "{s} was installed from an exact commit; bay install it with a branch or tag to follow one", .{record.name});
                    continue;
                };
                if (try one(c, &records, url, record.prefix, record.name, true) != 0) return 1;
            }
            return 0;
        },
        .one => {
            if (rest.len > 1) try say.fail(c.io, "install takes one url or directory", .{});
            const source = if (rest.len == 1) rest[0] else c.package orelse try say.fail(c.io, "install needs a url or directory, or a package here", .{});
            return one(c, &records, source, prefix orelse try defaultPrefix(c), name, force);
        },
    }
}

/// `bay uninstall <name>`: removes the files the install of `name` put in place.
pub fn uninstall(c: Context, name: []const u8) !u8 {
    var records = try load(c);
    for (records.items, 0..) |record, index| {
        if (!std.mem.eql(u8, record.name, name)) continue;
        for (record.files) |file| Io.Dir.cwd().deleteFile(c.io, try std.fs.path.join(c.a, &.{ record.prefix, file })) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        _ = records.orderedRemove(index);
        try save(c, records.items);
        try say.note(c.io, "{s} uninstalled", .{record.name});
        return 0;
    }
    try say.fail(c.io, "{s} is not installed; bay install --list names what is", .{name});
}

/// The install build of the copy in `work`, as bay builds any package: with the
/// Zig it names, its graph resolved, its pins raised to the selection in the copy
/// and a fork wherever content differs.
fn buildCommand(c: Context, work: []const u8, stage: []const u8, cache: []const u8) ![]const []const u8 {
    const zig = try toolchain.forPackage(c.io, c.a, c.environ, work);
    const manifest_path = try std.fs.path.join(c.a, &.{ work, "build.zig.zon" });
    var text = try c.a.dupeSentinel(u8, try aegis.own.readFile(c.io, Io.Dir.cwd(), manifest_path, c.a, .fromRaw(1 << 20)), 0);
    const resolution = try resolve.resolve(.{ .io = c.io, .a = c.a, .zig = zig, .package = work, .parsed = try manifest.parse(c.a, text), .development = false });
    for (resolution.raises) |raise| text = try manifest.put(c.a, text, raise.kind, raise.to);
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = manifest_path, .data = text });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ zig, "build", "install", "-Doptimize=ReleaseSafe", "--prefix", stage, "--cache-dir", cache });
    try argv.appendSlice(c.a, try resolution.forks(.package));
    return argv.toOwnedSlice(c.a);
}

/// Installs one package from `source`, a URL or a directory, replacing an
/// earlier install of the same name. What it records is absolute, so an
/// `uninstall` or `--update` from anywhere names the same places.
fn one(c: Context, records: *std.ArrayList(Record), source: []const u8, given_prefix: []const u8, given_name: ?[]const u8, force: bool) !u8 {
    const data = try dirs.data(c.io, c.a, c.environ);
    var recorded = source;
    const prefix = try std.fs.path.resolveAlloc(c.a, &.{ try Io.Dir.cwd().realPathFileAlloc(c.io, ".", c.a), given_prefix });
    const package_dir = if (std.mem.find(u8, source, "://") == null) recorded: {
        recorded = try Io.Dir.cwd().realPathFileAlloc(c.io, source, c.a);
        break :recorded recorded;
    } else directory: {
        // As `bay add` keeps them: packages unpacked under the store's place, fetches in a
        // scratch beside them, which each fetch empties.
        const place = try std.fs.path.join(c.a, &.{ data, "fetch" });
        const packages = try store.Store.init(c.io, c.a, c.zig, place);
        const scratch = try std.fs.path.join(c.a, &.{ place, root.directory, "add" });
        // A repository's URL is installed at its newest release, as `bay add` pins it.
        const url = try published.fetchable(c.io, c.a, c.zig, packages, scratch, source);
        const dependency = try fetch.fetch(c.io, c.a, c.zig, scratch, url, given_name) orelse return 1;
        recorded = dependency.source.remote.url;
        break :directory try packages.directoryOf(.{ .url = dependency.source.remote.url, .hash = dependency.source.remote.hash });
    };
    const package_text = aegis.own.readFile(c.io, Io.Dir.cwd(), try std.fs.path.join(c.a, &.{ package_dir, "build.zig.zon" }), c.a, .fromRaw(1 << 20)) catch
        try say.fail(c.io, "{s} has no build.zig.zon", .{source});
    const name = given_name orelse (try manifest.parse(c.a, try c.a.dupeSentinel(u8, package_text, 0))).name;
    // The name names directories bay writes and deletes: it must be a Zig identifier, as a manifest's is.
    if (!identifier(name)) try say.fail(c.io, "{s} is not a package name: letters, digits and _, not starting with a digit", .{name});
    // The build runs in a copy, so Zig's package cache is never written to.
    const work = try std.fs.path.join(c.a, &.{ data, "work", name });
    const stage = try std.fs.path.join(c.a, &.{ data, "stage", name });
    try Io.Dir.cwd().deleteTree(c.io, work);
    try Io.Dir.cwd().deleteTree(c.io, stage);
    try resolve.copyTree(c.io, c.a, package_dir, work);
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
    for (files) |file| {
        try moveAside(c, prefix_dir, file);
        stage_dir.copyFile(file, prefix_dir, file, c.io, .{ .make_path = true }) catch |err|
            try say.fail(c.io, "could not put {s} in {s}: {t}", .{ file, prefix, err });
    }
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
    const text = aegis.own.readFile(c.io, Io.Dir.cwd(), path, c.a, .fromRaw(1 << 24)) catch |err| switch (err) {
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

/// Whether `name` is a Zig identifier: what a manifest's `.name` must be.
fn identifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

test "an install's name is an identifier, never a path" {
    try std.testing.expect(identifier("bay"));
    try std.testing.expect(identifier("zig_tool2"));
    for ([_][]const u8{ "", "2fast", "../..", "a/b", "a-b", "a.b" }) |name| try std.testing.expect(!identifier(name));
}

/// On Windows a running program cannot be written over, only renamed: the one
/// being replaced, bay itself among them, moves aside to `<file>.old` first.
fn moveAside(c: Context, dir: Io.Dir, file: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    dir.access(c.io, file, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    const aside = try c.a.print("{s}.old", .{file});
    dir.deleteFile(c.io, aside) catch |err| switch (err) {
        error.FileNotFound => {},
        error.AccessDenied, error.FileBusy => try say.fail(c.io, "{s} still runs from an earlier install: end it and install again", .{aside}),
        else => |e| try say.fail(c.io, "could not remove {s}, which an earlier install moved aside: {t}", .{ aside, e }),
    };
    // airlock's rename asks only to delete the name, which a running image allows;
    // std's asks to write it as well, which the image refuses (FileBusy).
    _ = airlock.rename(c.io, dir, file, dir, aside, .{}) catch |err|
        try say.fail(c.io, "could not move {s} aside to {s} to replace it: {t}", .{ file, aside, err });
}
