//! A package's manifest tidied, as Go tidies go.mod: each workspace member pinned at
//! its release and each package at the one hash the selection picks; and each other
//! manifest under the package (a sample, a fixture, a conformance build) pinning what
//! the package pins as the package does. Computed in memory and written by no one
//! here: `bay tidy` writes it, and a train's dry run reads what a tidy would make
//! without changing the package.
const std = @import("std");
const aegis = @import("aegis");
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

/// A manifest under the package, its path relative to the package, and its text with the
/// pins it shares with the package given the package's.
pub const Nested = struct { path: []const u8, text: [:0]const u8, moves: []const Shared };

/// A nested manifest's pin given the package's: its name, and the hash it takes.
pub const Shared = struct { name: []const u8, to: []const u8 };

pub const Tidied = struct { text: [:0]const u8, moves: []const Move, nested: []const Nested };

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
    return .{ .text = out, .moves = moves.items, .nested = try nested(input, try manifest.parse(a, out)) };
}

/// Every other manifest under the package whose remote pins of a package `own` pins
/// remotely differ from its pin, with them given `own`'s: a sample built on the package
/// develops with what the package does, where a copy of its own would test a revision
/// nothing ships and fall below the selection at the package's next re-pin. A package
/// the package does not pin is the nested manifest's own business, as is one it takes by
/// path. Hidden directories (`.zig-cache`, `.git`) and Zig's `zig-out` and `zig-pkg` hold
/// no source of the package and are not read.
fn nested(input: Input, own: manifest.Manifest) ![]const Nested {
    const a = input.a;
    var found: std.ArrayList(Nested) = .empty;
    var dir = try Io.Dir.cwd().openDir(input.io, input.package, .{ .iterate = true });
    defer dir.close(input.io);
    var walker = try dir.walkSelectively(a);
    defer walker.deinit();
    while (try walker.next(input.io)) |entry| {
        if (entry.kind == .directory) {
            const generated = entry.basename[0] == '.' or std.mem.eql(u8, entry.basename, "zig-out") or std.mem.eql(u8, entry.basename, "zig-pkg");
            if (!generated) try walker.enter(input.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "build.zig.zon") or std.mem.eql(u8, entry.path, "build.zig.zon")) continue;
        const path = try a.dupe(u8, entry.path);
        const text = try a.dupeSentinel(u8, try aegis.own.readFile(input.io, dir, path, a, .fromRaw(1 << 20)), 0);
        // A manifest bay cannot read is a fixture's business, as preflight's lint names it.
        const theirs = manifest.parse(a, text) catch |err| switch (err) {
            error.InvalidManifest => continue,
            error.OutOfMemory => |e| return e,
        };
        var out = text;
        var moves: std.ArrayList(Shared) = .empty;
        for ([_]manifest.Kind{ .normal, .dev }) |kind| for (if (kind == .dev) theirs.dev else theirs.normal) |pin| {
            if (pin.source != .remote) continue;
            const ours = shared(own, pin.name) orelse continue;
            if (std.mem.eql(u8, ours.url, pin.source.remote.url) and std.mem.eql(u8, ours.hash, pin.source.remote.hash)) continue;
            out = try manifest.put(a, out, kind, .{ .name = pin.name, .source = .{ .remote = ours }, .lazy = pin.lazy });
            try moves.append(a, .{ .name = pin.name, .to = ours.hash });
        };
        if (moves.items.len != 0) try found.append(a, .{ .path = path, .text = out, .moves = moves.items });
    }
    return found.items;
}

/// The package's remote pin of `name`, shipped or developed with.
fn shared(own: manifest.Manifest, name: []const u8) ?@FieldType(manifest.Source, "remote") {
    for ([_][]const manifest.Dependency{ own.normal, own.dev }) |list| for (list) |dependency| {
        if (dependency.source == .remote and std.mem.eql(u8, dependency.name, name)) return dependency.source.remote;
    };
    return null;
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
