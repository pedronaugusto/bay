//! Minimal Version Selection, Go modules' algorithm, over Zig packages.
//!
//! A pin is a minimum. Every revision the package and its main modules reach
//! is read, following the pins of each, and for each package (its name and
//! fingerprint) the revision selected is the highest `.version` any of them
//! pins: the answer is the same in whatever order things are found, and
//! selections only rise. A main module (the package under development, a
//! workspace member, a local override) always wins over every revision of
//! itself, and what those revisions pin is not followed. Compatibility is then
//! checked over what is built: a pin from a selected revision must ask for the
//! same major version (below 1.0, the same minor) as the selection, unless the
//! package is one the root lets coexist, whose compatible lines are then
//! selected apart.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Version = std.SemanticVersion;

/// What a package is, whatever revision: its name and its fingerprint.
pub const Identity = struct {
    name: []const u8,
    fingerprint: u64,

    fn key(identity: Identity, a: Allocator) Allocator.Error![]const u8 {
        return a.print("{s}#{x}", .{ identity.name, identity.fingerprint });
    }
};

/// Where a revision is: pinned by hash, or a directory.
pub const Place = union(enum) {
    remote: Remote,
    directory: []const u8,

    pub const Remote = struct { url: []const u8, hash: []const u8 };

    /// The hash, or the directory: one key per place.
    pub fn key(place: Place) []const u8 {
        return switch (place) {
            .remote => |remote| remote.hash,
            .directory => |directory| directory,
        };
    }
};

/// One entry of a manifest's dependencies; `dev` for `.dev_dependencies`, which
/// Zig never builds as a dependency's and selection counts for a main module.
pub const Pin = struct { key: []const u8, lazy: bool = false, dev: bool = false, place: Place };

/// A revision read: what it is, where, and what it pins.
pub const Revision = struct {
    identity: Identity,
    version: Version,
    place: Place,
    pins: []const Pin,
    /// Versions of this package its manifest says no selection may pick.
    retracted: []const []const u8 = &.{},
};

/// Why there is no selection.
pub const Problem = union(enum) {
    /// Two contents claim one version of a package: which is meant is not known.
    same_version: struct { name: []const u8, version: Version, first: Place, second: Place },
    /// A selected revision asks for a version incompatible with the one selected.
    incompatible: struct { name: []const u8, selected: Version, wanted: Version, by: []const u8 },
    /// Selected revisions depend on each other in a ring.
    cycle: struct { name: []const u8 },
};

pub const Graph = struct {
    /// The selected revision of each package (of each compatible line, for one
    /// that may coexist), by selection key, in the order first reached.
    selected: std.array_hash_map.String(Revision),
    /// The main modules, by identity key.
    mains: std.array_hash_map.String(Revision),
    /// Every revision read, by place key.
    read: std.array_hash_map.String(Revision),
    /// The selection key of every place read.
    keys: std.array_hash_map.String([]const u8),
    problem: ?Problem,

    /// The revision a pin resolves to: the main module or the selection.
    pub fn resolve(graph: Graph, place: Place) ?Revision {
        const selection = graph.keys.get(place.key()) orelse return null;
        return graph.mains.get(selection) orelse graph.selected.get(selection);
    }
};

/// What the root decides beyond its pins.
pub const Options = struct {
    /// Packages whose incompatible lines may each be selected.
    coexist: []const []const u8 = &.{},
    /// Places the root names itself (its own pins, its remote overrides): among
    /// revisions that claim one version with different contents, the one named
    /// here is meant. Zig pins commits, so two can share a version.
    chosen: []const []const u8 = &.{},
};

/// Reads every revision the roots and the mains' own pins reach, following the
/// pins of each one read, then selects for each package the highest version
/// among them. A revision of a main module stands for nothing: the main module
/// is built, and what its other revisions pin is never followed.
/// `loader` reads the revision at a place: `loader.load(place)`, a fetch and a
/// parse, or a test's table.
pub fn select(a: Allocator, loader: anytype, roots: []const Pin, mains: []const Revision, options: Options) !Graph {
    var graph: Graph = .{ .selected = .empty, .mains = .empty, .read = .empty, .keys = .empty, .problem = null };
    var frontier: std.ArrayList(Place) = .empty;
    for (mains) |main| {
        const identity = try main.identity.key(a);
        try graph.mains.put(a, identity, main);
        try graph.read.put(a, main.place.key(), main);
        try graph.keys.put(a, main.place.key(), identity);
        for (main.pins) |pin| try frontier.append(a, pin.place);
    }
    for (roots) |pin| try frontier.append(a, pin.place);
    // Every revision at the highest version read, by selection key.
    var tops: std.array_hash_map.String(std.ArrayList(Revision)) = .empty;
    while (frontier.pop()) |place| {
        if (graph.read.contains(place.key())) continue;
        const revision = try loader.load(place);
        const identity = try revision.identity.key(a);
        const selection = if (graph.mains.contains(identity)) identity else try selectionKey(a, revision, identity, options.coexist);
        try graph.read.put(a, place.key(), revision);
        try graph.keys.put(a, place.key(), selection);
        if (graph.mains.contains(identity)) continue;
        for (revision.pins) |pin| try frontier.append(a, pin.place);
        const top = try tops.getOrPut(a, selection);
        if (!top.found_existing) top.value_ptr.* = .empty;
        if (top.value_ptr.items.len != 0) switch (revision.version.order(top.value_ptr.items[0].version)) {
            .gt => top.value_ptr.clearRetainingCapacity(),
            .eq => {},
            .lt => continue,
        };
        try top.value_ptr.append(a, revision);
    }
    for (tops.keys(), tops.values()) |selection, candidates| {
        try graph.selected.put(a, selection, decide(candidates.items, options.chosen) orelse {
            graph.problem = .{ .same_version = .{ .name = candidates.items[0].identity.name, .version = candidates.items[0].version, .first = candidates.items[0].place, .second = candidates.items[1].place } };
            return graph;
        });
    }
    graph.problem = try compatible(graph) orelse try acyclic(a, graph);
    return graph;
}

/// The one revision meant among those at the top version: the only one, or
/// the one the root names; null when that is not known.
fn decide(candidates: []const Revision, chosen: []const []const u8) ?Revision {
    if (candidates.len == 1) return candidates[0];
    var meant: ?Revision = null;
    for (candidates) |candidate| for (chosen) |place| if (std.mem.eql(u8, candidate.place.key(), place)) {
        if (meant != null) return null;
        meant = candidate;
    };
    return meant;
}

/// A package's selection key: its identity, and its compatible line when it may coexist.
fn selectionKey(a: Allocator, revision: Revision, identity: []const u8, coexist: []const []const u8) Allocator.Error![]const u8 {
    for (coexist) |name| if (std.mem.eql(u8, name, revision.identity.name)) {
        const line = revision.version;
        return if (line.major == 0) a.print("{s}@0.{d}", .{ identity, line.minor }) else a.print("{s}@{d}", .{ identity, line.major });
    };
    return identity;
}

/// Whether two versions are on one compatible line: one major, or below 1.0 one minor.
pub fn sameLine(x: Version, y: Version) bool {
    if (x.major != y.major) return false;
    return x.major != 0 or x.minor == y.minor;
}

fn compatible(graph: Graph) Allocator.Error!?Problem {
    for ([_][]const Revision{ graph.mains.values(), graph.selected.values() }) |revisions| for (revisions) |revision| {
        for (revision.pins) |pin| {
            const wanted = graph.read.get(pin.place.key()) orelse continue;
            const selection = graph.keys.get(pin.place.key()).?; // safe: every place read has its key
            if (graph.mains.contains(selection)) continue;
            const selected = graph.selected.get(selection).?; // safe: a non-main key is selected
            if (!sameLine(selected.version, wanted.version)) return .{ .incompatible = .{ .name = selected.identity.name, .selected = selected.version, .wanted = wanted.version, .by = revision.identity.name } };
        }
    };
    return null;
}

/// Refuses a ring among the selected revisions, as Cargo refuses one among
/// dependencies: a main module ends a path, since it is built from its directory.
fn acyclic(a: Allocator, graph: Graph) Allocator.Error!?Problem {
    const State = enum { open, done };
    var states: std.array_hash_map.String(State) = .empty;
    var stack: std.ArrayList(struct { key: []const u8, pin: usize }) = .empty;
    for (graph.selected.keys()) |start| {
        if (states.contains(start)) continue;
        try states.put(a, start, .open);
        try stack.append(a, .{ .key = start, .pin = 0 });
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const pins = graph.selected.get(top.key).?.pins; // safe: only selected keys are pushed
            if (top.pin == pins.len) {
                try states.put(a, top.key, .done);
                _ = stack.pop();
                continue;
            }
            const pin = pins[top.pin];
            top.pin += 1;
            const target = graph.keys.get(pin.place.key()) orelse continue;
            if (graph.mains.contains(target)) continue;
            if (states.get(target)) |state| switch (state) {
                .open => return .{ .cycle = .{ .name = graph.selected.get(target).?.identity.name } }, // safe: open keys are selected
                .done => continue,
            };
            try states.put(a, target, .open);
            try stack.append(a, .{ .key = target, .pin = 0 });
        }
    }
    return null;
}

// Tests: a table of revisions by place key stands for the network.

const Table = struct {
    revisions: []const Revision,
    loads: usize = 0,

    fn load(table: *Table, place: Place) !Revision {
        table.loads += 1;
        for (table.revisions) |revision| if (std.mem.eql(u8, revision.place.key(), place.key())) return revision;
        return error.NotFound;
    }
};

fn hashed(hash: []const u8) Place {
    return .{ .remote = .{ .url = "git+https://example.org", .hash = hash } };
}

fn rev(name: []const u8, fingerprint: u64, version: []const u8, hash: []const u8, pins: []const Pin) Revision {
    return .{ .identity = .{ .name = name, .fingerprint = fingerprint }, .version = Version.parse(version) catch unreachable, .place = hashed(hash), .pins = pins }; // unreachable: test versions are valid
}

fn pinTo(name: []const u8, hash: []const u8) Pin {
    return .{ .key = name, .place = hashed(hash) };
}

test "the highest version pinned anywhere is selected, whatever the order" {
    const c1 = rev("c", 7, "0.1.0", "c1", &.{});
    const c2 = rev("c", 7, "0.1.1", "c2", &.{});
    const a_ = rev("a", 1, "1.0.0", "a", &.{pinTo("c", "c1")});
    const b = rev("b", 2, "1.0.0", "b", &.{pinTo("c", "c2")});
    for ([_][]const Pin{ &.{ pinTo("a", "a"), pinTo("b", "b") }, &.{ pinTo("b", "b"), pinTo("a", "a") } }) |roots| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var table: Table = .{ .revisions = &.{ c1, c2, a_, b } };
        const graph = try select(arena.allocator(), &table, roots, &.{}, .{});
        try std.testing.expectEqual(null, graph.problem);
        try std.testing.expectEqualStrings("c2", graph.resolve(hashed("c1")).?.place.key());
        try std.testing.expectEqual(3, graph.selected.count());
    }
}

test "a main module stands for every revision of itself, and its pins are its own" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const aegis_old = rev("aegis", 9, "0.4.0", "aegis-old", &.{pinTo("never", "never")});
    const shakedown = rev("shakedown", 3, "0.2.0", "sd", &.{pinTo("aegis", "aegis-old")});
    const working: Revision = .{ .identity = .{ .name = "aegis", .fingerprint = 9 }, .version = try Version.parse("0.5.0"), .place = .{ .directory = "/work/aegis" }, .pins = &.{} };
    var table: Table = .{ .revisions = &.{ aegis_old, shakedown } };
    const graph = try select(a, &table, &.{pinTo("shakedown", "sd")}, &.{working}, .{});
    try std.testing.expectEqual(null, graph.problem);
    try std.testing.expectEqualStrings("/work/aegis", graph.resolve(hashed("aegis-old")).?.place.key());
    // The old revision is read to learn what it is, never followed.
    try std.testing.expect(!graph.read.contains("never"));
}

test "two contents at the selected version are refused; a higher version settles them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = rev("c", 7, "0.1.0", "x", &.{});
    const y = rev("c", 7, "0.1.0", "y", &.{});
    const z = rev("c", 7, "0.1.2", "z", &.{});
    var table: Table = .{ .revisions = &.{ x, y, z } };
    const tied = try select(a, &table, &.{ pinTo("c", "x"), pinTo("c", "y") }, &.{}, .{});
    try std.testing.expect(tied.problem.? == .same_version);
    const settled = try select(a, &table, &.{ pinTo("c", "x"), pinTo("c", "y"), pinTo("c", "z") }, &.{}, .{});
    try std.testing.expectEqual(null, settled.problem);
    // The root naming one of them decides.
    const decided = try select(a, &table, &.{ pinTo("c", "x"), pinTo("c", "y") }, &.{}, .{ .chosen = &.{"y"} });
    try std.testing.expectEqual(null, decided.problem);
    try std.testing.expectEqualStrings("y", decided.resolve(hashed("x")).?.place.key());
}

test "an incompatible line is refused unless the package may coexist" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c3 = rev("c", 7, "0.3.0", "c3", &.{});
    const c4 = rev("c", 7, "0.4.0", "c4", &.{});
    const old = rev("old", 1, "1.0.0", "old", &.{pinTo("c", "c3")});
    var table: Table = .{ .revisions = &.{ c3, c4, old } };
    const refused = try select(a, &table, &.{ pinTo("old", "old"), pinTo("c", "c4") }, &.{}, .{});
    try std.testing.expect(refused.problem.? == .incompatible);
    try std.testing.expectEqualStrings("old", refused.problem.?.incompatible.by);
    const apart = try select(a, &table, &.{ pinTo("old", "old"), pinTo("c", "c4") }, &.{}, .{ .coexist = &.{"c"} });
    try std.testing.expectEqual(null, apart.problem);
    try std.testing.expectEqualStrings("c3", apart.resolve(hashed("c3")).?.place.key());
    try std.testing.expectEqualStrings("c4", apart.resolve(hashed("c4")).?.place.key());
}

test "every revision reached counts, however deep it is found" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // x pins b 1.0.0, which asks for c 0.4.1; y reaches b 1.1.0 through z, and it asks for c 0.4.0.
    const b1 = rev("b", 2, "1.0.0", "b1", &.{pinTo("c", "c41")});
    const b2 = rev("b", 2, "1.1.0", "b2", &.{pinTo("c", "c40")});
    const c40 = rev("c", 7, "0.4.0", "c40", &.{});
    const c41 = rev("c", 7, "0.4.1", "c41", &.{});
    const x = rev("x", 3, "1.0.0", "x", &.{pinTo("b", "b1")});
    const z = rev("z", 4, "1.0.0", "z", &.{pinTo("b", "b2")});
    const y = rev("y", 5, "1.0.0", "y", &.{pinTo("z", "z")});
    var table: Table = .{ .revisions = &.{ b1, b2, c40, c41, x, y, z } };
    // b 1.0.0 is not built, yet what it asks for counts: the answer does not depend on
    // how deep each b is found.
    for ([_][]const Pin{ &.{ pinTo("x", "x"), pinTo("y", "y") }, &.{ pinTo("x", "x"), pinTo("z", "z") }, &.{ pinTo("y", "y"), pinTo("x", "x") } }) |roots| {
        const graph = try select(a, &table, roots, &.{}, .{});
        try std.testing.expectEqual(null, graph.problem);
        try std.testing.expectEqualStrings("b2", graph.resolve(hashed("b1")).?.place.key());
        try std.testing.expectEqualStrings("c41", graph.resolve(hashed("c40")).?.place.key());
    }
}

test "selected revisions that depend on each other are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const x = rev("x", 1, "1.0.0", "x", &.{pinTo("y", "y")});
    const y = rev("y", 2, "1.0.0", "y", &.{pinTo("x", "x")});
    var table: Table = .{ .revisions = &.{ x, y } };
    const graph = try select(arena.allocator(), &table, &.{pinTo("x", "x")}, &.{}, .{});
    try std.testing.expect(graph.problem.? == .cycle);
}
