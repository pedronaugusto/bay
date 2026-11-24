//! A workspace: packages developed together, as Go's go.work names them. A
//! `bay.work` in the package's directory or one above it lists their
//! directories, relative to it:
//!
//!     .{ .members = .{ "aegis", "shakedown", "relic" } }
//!
//! Every member is a main module: wherever the graph pins one, its directory
//! is what builds, so a change in one is tested against the others before it
//! lands anywhere.
const std = @import("std");
const intake = @import("intake.zig");
const Io = std.Io;
const say = @import("say.zig");
const manifest = @import("manifest.zig");

pub const file_name = "bay.work";

/// The members a train builds at the pins of the member it gates, not from their trees, as
/// that member's release builds them: the members it has not released, named by bay for its
/// own children, as absolute directories split by the path list separator. Never a person's.
pub const pinned_variable = "BAY_TRAIN_PINNED";

/// The other members of the workspace holding `package`, as absolute
/// directories; none outside a workspace. A member that is the package itself,
/// at its own directory or checked out elsewhere (a landing's scratch worktree,
/// a second clone), is left out: the package under development stands for it.
/// A workspace holds only its members: a package below a `bay.work` that lists
/// it neither by directory nor as a checkout of a member (a scratch clone of
/// something else) is outside it, and builds with its own pins alone.
pub fn members(io: Io, a: std.mem.Allocator, package: []const u8) ![]const []const u8 {
    return membersBut(io, a, package, "");
}

/// The members that build from their trees: `members`, but those a train names in
/// `pinned_variable`, which build at the package's pins.
pub fn building(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, package: []const u8) ![]const []const u8 {
    return membersBut(io, a, package, environ.get(pinned_variable) orelse "");
}

fn membersBut(io: Io, a: std.mem.Allocator, package: []const u8, pinned: []const u8) ![]const []const u8 {
    const every = try all(io, a, package) orelse return &.{};
    const own = try identity(io, a, package);
    var held = false;
    var list: std.ArrayList([]const u8) = .empty;
    for (every) |member| {
        if (std.mem.eql(u8, member, package)) {
            held = true;
            continue;
        }
        if (named(pinned, member)) continue;
        const theirs = try identity(io, a, member);
        if (std.mem.eql(u8, theirs.name, own.name) and theirs.fingerprint == own.fingerprint) {
            held = true;
            continue;
        }
        try list.append(a, member);
    }
    if (!held) return &.{};
    return list.toOwnedSlice(a);
}

/// Whether `list`, directories split by the path list separator, names `directory`.
fn named(list: []const u8, directory: []const u8) bool {
    var each = std.mem.splitScalar(u8, list, std.fs.path.delimiter);
    while (each.next()) |entry| if (std.mem.eql(u8, entry, directory)) return true;
    return false;
}

test "a train's list of members built at their pins names each directory whole" {
    const list = "/w/aegis" ++ [_]u8{std.fs.path.delimiter} ++ "/w/preflight";
    try std.testing.expect(named(list, "/w/preflight"));
    try std.testing.expect(named(list, "/w/aegis"));
    try std.testing.expect(!named(list, "/w/aegi"));
    try std.testing.expect(!named("", "/w/aegis"));
}

const Identity = struct { name: []const u8, fingerprint: u64 };

/// What a package is, as its manifest names it.
fn identity(io: Io, a: std.mem.Allocator, directory: []const u8) !Identity {
    const path = try std.fs.path.join(a, &.{ directory, "build.zig.zon" });
    const text = (try intake.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(1 << 20))).readForParse();
    const parsed = manifest.parse(a, try a.dupeSentinel(u8, text, 0)) catch |err| switch (err) {
        error.InvalidManifest => try say.fail(io, "{s} is not a manifest bay can read", .{path}),
        error.OutOfMemory => |e| return e,
    };
    return .{ .name = parsed.name, .fingerprint = parsed.fingerprint };
}

/// Every member of the workspace found from `from` up, as absolute directories
/// in the order `bay.work` lists them; null outside a workspace.
pub fn all(io: Io, a: std.mem.Allocator, from: []const u8) !?[]const []const u8 {
    const found = try find(io, a, from) orelse return null;
    const Work = struct { members: []const []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    // ZON is UTF-8, which std's literal parsing takes for granted (`manifest.parse`).
    const read = if (std.unicode.utf8ValidateSlice(found.text)) std.zon.parse.fromSlice(Work, .{ .gpa = a, .arena = a, .source = found.text, .diagnostics = &diagnostics }) else error.ParseZon;
    const work = read catch |err| switch (err) {
        error.ParseZon => try say.fail(io, "{s} is not a workspace bay can read: .{{ .members = .{{ \"dir\", ... }} }}", .{found.path}),
        error.OutOfMemory => |e| return e,
    };
    const directory = std.fs.path.dirname(found.path).?; // safe: a found file has a directory
    var list: std.ArrayList([]const u8) = .empty;
    for (work.members) |member| {
        const absolute = try std.fs.path.resolveAlloc(a, &.{ directory, member });
        const manifest_path = try std.fs.path.join(a, &.{ absolute, "build.zig.zon" });
        Io.Dir.cwd().access(io, manifest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => try say.fail(io, "{s} names {s}, which has no build.zig.zon", .{ found.path, member }),
            else => |e| return e,
        };
        // As the file system names it, as the package's own directory is: one spelling of each.
        try list.append(a, try Io.Dir.cwd().realPathFileAlloc(io, absolute, a));
    }
    return try list.toOwnedSlice(a);
}

/// The `bay.work` found from `from` up, or null outside a workspace.
pub fn fileOf(io: Io, a: std.mem.Allocator, from: []const u8) !?[]const u8 {
    const found = try find(io, a, from) orelse return null;
    return found.path;
}

const Found = struct { path: []const u8, text: [:0]const u8 };

fn find(io: Io, a: std.mem.Allocator, from: []const u8) !?Found {
    var directory: []const u8 = from;
    while (true) {
        const path = try std.fs.path.join(a, &.{ directory, file_name });
        if (intake.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(1 << 20))) |text_read| {
            const text = text_read.readForParse();
            return .{ .path = path, .text = try a.dupeSentinel(u8, text, 0) };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        directory = std.fs.path.dirname(directory) orelse return null;
    }
}
