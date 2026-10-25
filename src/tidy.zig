//! A package's manifest tidied, as Go tidies go.mod: each workspace member pinned at
//! its release and each package at the one hash the selection picks. Computed in
//! memory and written by no one here: `bay tidy` writes it, and a train's dry run
//! reads what a tidy would make without changing the package.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const resolve = @import("resolve.zig");
const workspace = @import("workspace.zig");
const published = @import("published.zig");
const store = @import("store.zig");
const root = @import("root.zig");

pub const Input = struct {
    io: Io,
    a: std.mem.Allocator,
    /// The Zig the package builds with.
    zig: []const u8,
    /// The package's directory.
    package: []const u8,
};

/// A pin the tidy moves: its name, how it moves and where to, as a person reads it.
pub const Move = struct { name: []const u8, how: How, to: []const u8 };
pub const How = enum {
    /// A workspace member pinned at its release.
    released,
    /// A pin below the selection raised to it.
    raised,
};

pub const Tidied = struct { text: [:0]const u8, moves: []const Move };

/// `text`, the package's manifest, tidied; nothing is written, and a graph
/// that does not resolve is refused.
pub fn tidied(input: Input, text: [:0]const u8) !Tidied {
    const a = input.a;
    var out = text;
    var moves: std.ArrayList(Move) = .empty;
    const others = try workspace.members(input.io, a, input.package);
    if (others.len != 0) {
        // Releases first: what they pin is then part of the selection.
        const scratch = try std.fs.path.join(a, &.{ input.package, root.directory, "add" });
        const owner: published.Owned = .{ .directory = input.package, .parsed = try manifest.parse(a, out) };
        const syncs = try published.syncs(input.io, a, input.zig, try store.Store.init(input.io, a, input.zig, input.package), scratch, &.{owner}, try std.mem.concat(a, []const u8, &.{ &.{input.package}, others }));
        out = try repin(input, &moves, out, syncs, .released, null);
    }
    const resolution = try resolved(input, try manifest.parse(a, out));
    out = try repin(input, &moves, out, resolution.raises, .raised, resolution);
    return .{ .text = out, .moves = moves.items };
}

/// The package's graph, resolved: a workspace's members are main modules beside it.
pub fn resolved(input: Input, parsed: manifest.Manifest) !resolve.Resolution {
    return resolve.resolve(.{ .io = input.io, .a = input.a, .zig = input.zig, .package = input.package, .parsed = parsed, .members = try workspace.members(input.io, input.a, input.package) });
}

/// A dependency's selected revision as a person reads it: name, version, hash.
pub fn describe(resolution: resolve.Resolution, dependency: manifest.Dependency) ![]const u8 {
    const a = resolution.input.a;
    const hash = dependency.source.remote.hash;
    const revision = resolution.graph.read.get(hash) orelse return a.print("{s} {s}", .{ dependency.name, hash });
    return a.print("{s} {f} ({s})", .{ revision.identity.name, revision.version, hash });
}

/// `text` with each entry put in, each recorded in `moves`.
fn repin(input: Input, moves: *std.ArrayList(Move), text: [:0]const u8, pins: []const manifest.Repin, how: How, resolution: ?resolve.Resolution) ![:0]const u8 {
    var out = text;
    for (pins) |pin| {
        std.debug.assert(std.mem.eql(u8, pin.directory, input.package)); // a tidy writes only the package's manifest
        const to = if (resolution) |r| try describe(r, pin.to) else pin.to.source.remote.hash;
        try moves.append(input.a, .{ .name = pin.from.name, .how = how, .to = to });
        out = try manifest.put(input.a, out, pin.kind, pin.to);
    }
    return out;
}
