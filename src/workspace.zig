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
const Io = std.Io;
const say = @import("say.zig");

pub const file_name = "bay.work";

/// The other members of the workspace holding `package`, as absolute
/// directories; none outside a workspace.
pub fn members(io: Io, a: std.mem.Allocator, package: []const u8) ![]const []const u8 {
    const every = try all(io, a, package) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    for (every) |member| if (!std.mem.eql(u8, member, package)) try list.append(a, member);
    return list.toOwnedSlice(a);
}

/// Every member of the workspace found from `from` up, as absolute directories
/// in the order `bay.work` lists them; null outside a workspace.
pub fn all(io: Io, a: std.mem.Allocator, from: []const u8) !?[]const []const u8 {
    const found = try find(io, a, from) orelse return null;
    const Work = struct { members: []const []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const work = std.zon.parse.fromSlice(Work, .{ .gpa = a, .arena = a, .source = found.text, .diagnostics = &diagnostics }) catch |err| switch (err) {
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
        try list.append(a, absolute);
    }
    return try list.toOwnedSlice(a);
}

const Found = struct { path: []const u8, text: [:0]const u8 };

fn find(io: Io, a: std.mem.Allocator, from: []const u8) !?Found {
    var directory: []const u8 = from;
    while (true) {
        const path = try std.fs.path.join(a, &.{ directory, file_name });
        if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20))) |text| {
            return .{ .path = path, .text = try a.dupeSentinel(u8, text, 0) };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        directory = std.fs.path.dirname(directory) orelse return null;
    }
}
