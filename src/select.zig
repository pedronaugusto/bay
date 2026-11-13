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
//!
//! A version names one content only at a release: between releases many commits
//! carry the version their manifest last took. So a pin's version orders it only
//! when it is a release (a version tag that is the manifest's version, or a pin of
//! no commit, as an archive is). When any pin of a package is a commit pin, the
//! package's pinned commits are ordered by their history, as Go orders
//! pseudo-versions by their commits: the one selected is the commit every other
//! pinned commit is an ancestor of, a release counting as the commit its tag names.
//! Commits that no one of them contains have no newest, and are refused.
const std = @import("std");
const manifest = @import("manifest.zig");
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

    pub const Remote = struct {
        url: []const u8,
        hash: []const u8,
        /// A prebuilt's fields, an OpenPGP key file's path made whole: what bay checks before it unpacks.
        prebuilt: ?manifest.Prebuilt = null,
    };

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

/// A commit a git pin holds, and the repository it is fetched from.
pub const Commit = struct { repository: []const u8, id: []const u8 };

/// A revision read: what it is, where, and what it pins.
pub const Revision = struct {
    identity: Identity,
    version: Version,
    place: Place,
    pins: []const Pin,
    /// Versions of this package its manifest says no selection may pick.
    retracted: []const []const u8 = &.{},
    /// The commit a git pin holds, by which a commit pin is ordered: null for a pin that names none.
    commit: ?Commit = null,
    /// Whether `.version` orders this revision, for a revision with a commit: a release, its
    /// `?ref=` a version tag that is the manifest's version. A commit pin's version is what its
    /// manifest last took, which many commits share. A revision with no commit (an archive, a
    /// directory) is ordered by its version.
    release: bool = true,
};

/// Why there is no selection.
pub const Problem = union(enum) {
    /// Two contents claim one version of a package: which is meant is not known.
    same_version: struct { name: []const u8, version: Version, first: Place, second: Place },
    /// A selected revision asks for a version incompatible with the one selected.
    incompatible: struct { name: []const u8, selected: Version, wanted: Version, by: []const u8 },
    /// Selected revisions depend on each other in a ring.
    cycle: struct { name: []const u8 },
    /// Commits of one package that no one of them contains: none is the newest.
    diverged: struct { name: []const u8, heads: []const Revision },
    /// A package pinned at a commit and by a pin of no commit, which its history cannot place.
    unordered: struct { name: []const u8, commit: Revision, other: Revision },
};

pub const Graph = struct {
    /// The selected revision of each package a build uses (of each compatible line,
    /// for one that may coexist), by selection key.
    selected: std.array_hash_map.String(Revision),
    /// The main modules, by identity key.
    mains: std.array_hash_map.String(Revision),
    /// Every revision read, by place key.
    read: std.array_hash_map.String(Revision),
    /// The selection key of every place read.
    keys: std.array_hash_map.String([]const u8),
    /// The selection keys selected by history, among commit pins: their versions are
    /// compared with nothing, since the one selected contains every commit pinned.
    by_history: std.array_hash_map.String(void) = .empty,
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
/// among them, or among commit pins the newest commit (`newest`). A revision of a main module stands for nothing: the main module
/// is built, and what its other revisions pin is never followed.
/// `loader` reads the revision at a place: `loader.load(place)`, a fetch and a
/// parse, or a test's table; and orders a package's commits:
/// `loader.heads(identity, commits)`, the ids of those no other of them contains.
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
    // Every revision read by hash, by selection key.
    var reached: std.array_hash_map.String(std.ArrayList(Revision)) = .empty;
    while (frontier.pop()) |place| {
        if (graph.read.contains(place.key())) continue;
        const revision = try loader.load(place);
        const identity = try revision.identity.key(a);
        const selection = if (graph.mains.contains(identity)) identity else try selectionKey(a, revision, identity, options.coexist);
        try graph.read.put(a, place.key(), revision);
        try graph.keys.put(a, place.key(), selection);
        if (graph.mains.contains(identity)) continue;
        for (revision.pins) |pin| try frontier.append(a, pin.place);
        // A package reached by path is part of what holds it, not a version that
        // competes: it is built wherever a built revision reaches its directory.
        if (place == .directory) continue;
        const entry = try reached.getOrPut(a, selection);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, revision);
    }
    // The selection counts every revision reached; what is decided and
    // checked is what is built: what the main modules and roots pin, through the
    // revisions selected. A package only an unbuilt revision reaches is built by
    // nothing, so nothing about it can stop a build.
    var queue: std.ArrayList(Pin) = .empty;
    for (mains) |main| try queue.appendSlice(a, main.pins);
    try queue.appendSlice(a, roots);
    while (queue.pop()) |pin| {
        const selection = graph.keys.get(pin.place.key()) orelse continue;
        if (graph.mains.contains(selection) or graph.selected.contains(selection)) continue;
        if (pin.place == .directory) {
            // The directory a built revision reaches is the one built: another place
            // of the same package in the built graph is refused when it is materialized.
            const nested = graph.read.get(pin.place.key()).?; // safe: every place in the graph was read
            try graph.selected.put(a, selection, nested);
            for (nested.pins) |next| if (!next.dev) try queue.append(a, next);
            continue;
        }
        const candidates = (reached.get(selection) orelse continue).items;
        const chosen = switch (try newest(a, loader, candidates, options.chosen)) {
            .revision => |revision| revision,
            .problem => |problem| {
                graph.problem = problem;
                return graph;
            },
        };
        if (!released(candidates)) try graph.by_history.put(a, selection, {});
        try graph.selected.put(a, selection, chosen);
        for (chosen.pins) |next| if (!next.dev) try queue.append(a, next);
    }
    graph.problem = try compatible(graph) orelse try acyclic(a, graph);
    return graph;
}

/// What one package's revisions select: a revision, or why none.
const Newest = union(enum) { revision: Revision, problem: Problem };

/// The revision selected among every one of a package the graph reaches. When
/// every one is a release, the highest version, decided between two contents of it
/// as `decide` decides. When any is a commit pin, the newest commit: the one that
/// contains every other, a release counting as the commit its tag names, whatever
/// versions their manifests say; commits that no one of them contains are refused,
/// each named, and never one picked.
fn newest(a: Allocator, loader: anytype, candidates: []const Revision, chosen: []const []const u8) !Newest {
    const name = candidates[0].identity.name;
    if (released(candidates)) {
        var top: std.ArrayList(Revision) = .empty;
        for (candidates) |candidate| {
            if (top.items.len != 0) switch (candidate.version.order(top.items[0].version)) {
                .gt => top.clearRetainingCapacity(),
                .eq => {},
                .lt => continue,
            };
            try top.append(a, candidate);
        }
        if (decide(top.items, chosen)) |revision| return .{ .revision = revision };
        return .{ .problem = .{ .same_version = .{ .name = name, .version = top.items[0].version, .first = top.items[0].place, .second = top.items[1].place } } };
    }
    var commits: std.ArrayList(Commit) = .empty;
    var by_commit: std.array_hash_map.String(Revision) = .empty;
    var archive: ?Revision = null;
    for (candidates) |candidate| {
        const commit = candidate.commit orelse {
            archive = candidate;
            continue;
        };
        const entry = try by_commit.getOrPut(a, commit.id);
        if (entry.found_existing) continue;
        entry.value_ptr.* = candidate;
        try commits.append(a, commit);
    }
    // A commit pin is among them (`released`), so some candidate has a commit.
    const first = by_commit.values()[0];
    if (archive) |other| return .{ .problem = .{ .unordered = .{ .name = name, .commit = first, .other = other } } };
    if (commits.items.len == 1) return .{ .revision = first };
    const heads = try loader.heads(candidates[0].identity, commits.items);
    if (heads.len == 1) return .{ .revision = by_commit.get(heads[0]).? }; // safe: heads are commits asked about
    const diverged = try a.alloc(Revision, heads.len);
    for (diverged, heads) |*revision, id| revision.* = by_commit.get(id).?; // safe: as above
    return .{ .problem = .{ .diverged = .{ .name = name, .heads = diverged } } };
}

/// Whether every revision of a package is ordered by its version: none is a commit pin.
fn released(candidates: []const Revision) bool {
    for (candidates) |candidate| if (!candidate.release and candidate.commit != null) return false;
    return true;
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
            // The commit selected contains every one pinned: what its manifest says is no line.
            if (graph.by_history.contains(selection)) continue;
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
    /// The history: each commit and its parents.
    parents: []const Parents = &.{},
    /// How many times history was asked.
    asked: usize = 0,
    found: [8][]const u8 = undefined,

    const Parents = struct { []const u8, []const []const u8 };

    fn load(table: *Table, place: Place) !Revision {
        table.loads += 1;
        for (table.revisions) |revision| if (std.mem.eql(u8, revision.place.key(), place.key())) return revision;
        return error.NotFound;
    }

    fn heads(table: *Table, _: Identity, commits: []const Commit) ![]const []const u8 {
        table.asked += 1;
        var count: usize = 0;
        for (commits) |commit| {
            const contained = for (commits) |other| {
                if (!std.mem.eql(u8, other.id, commit.id) and table.contains(other.id, commit.id)) break true;
            } else false;
            if (contained) continue;
            table.found[count] = commit.id;
            count += 1;
        }
        return table.found[0..count];
    }

    /// Whether `older` is `newer` or one of its ancestors.
    fn contains(table: *Table, newer: []const u8, older: []const u8) bool {
        if (std.mem.eql(u8, newer, older)) return true;
        for (table.parents) |entry| if (std.mem.eql(u8, entry[0], newer)) {
            for (entry[1]) |parent| if (table.contains(parent, older)) return true;
        };
        return false;
    }
};

fn hashed(hash: []const u8) Place {
    return .{ .remote = .{ .url = "git+https://example.org", .hash = hash } };
}

fn rev(name: []const u8, fingerprint: u64, version: []const u8, hash: []const u8, pins: []const Pin) Revision {
    return .{ .identity = .{ .name = name, .fingerprint = fingerprint }, .version = Version.parse(version) catch unreachable, .place = hashed(hash), .pins = pins }; // glint-ignore: Z026 -- test versions are valid
}

/// A revision pinned at `commit` of its repository; a release when `tag` is its version's tag.
fn at(name: []const u8, version: []const u8, hash: []const u8, commit: []const u8, tag: bool, pins: []const Pin) Revision {
    var revision = rev(name, 7, version, hash, pins);
    revision.commit = .{ .repository = "https://example.org/c", .id = commit };
    revision.release = tag;
    return revision;
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

test "a package only an unbuilt revision reaches stops nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // b 1.0.0 loses to b 1.1.0; only it pins legacy, which asks for an older line of d.
    const b1 = rev("b", 2, "1.0.0", "b1", &.{pinTo("legacy", "legacy")});
    const b2 = rev("b", 2, "1.1.0", "b2", &.{});
    const legacy = rev("legacy", 6, "0.1.0", "legacy", &.{pinTo("d", "d3")});
    const d3 = rev("d", 8, "0.3.0", "d3", &.{});
    const d4 = rev("d", 8, "0.4.0", "d4", &.{});
    const e = rev("e", 9, "1.0.0", "e", &.{pinTo("d", "d4")});
    const x = rev("x", 3, "1.0.0", "x", &.{pinTo("b", "b1")});
    var table: Table = .{ .revisions = &.{ b1, b2, legacy, d3, d4, e, x } };
    const graph = try select(a, &table, &.{ pinTo("x", "x"), pinTo("b", "b2"), pinTo("e", "e") }, &.{}, .{});
    try std.testing.expectEqual(null, graph.problem);
    try std.testing.expect(!graph.selected.contains(try (Identity{ .name = "legacy", .fingerprint = 6 }).key(a)));
    try std.testing.expectEqualStrings("d4", graph.resolve(hashed("d3")).?.place.key());
}

test "commit pins on one line select the newest commit, whatever versions their manifests say" {
    // k1 <- k2 <- k3 on one line; k2's manifest says a higher version than k3's.
    const k1 = at("c", "0.7.5", "k1", "k1", false, &.{});
    const k2 = at("c", "0.7.6", "k2", "k2", false, &.{});
    const k3 = at("c", "0.7.5", "k3", "k3", false, &.{});
    const a_ = rev("a", 1, "1.0.0", "a", &.{pinTo("c", "k1")});
    const b = rev("b", 2, "1.0.0", "b", &.{pinTo("c", "k3")});
    const history = [_]Table.Parents{ .{ "k2", &.{"k1"} }, .{ "k3", &.{"k2"} } };
    for ([_][]const Pin{ &.{ pinTo("a", "a"), pinTo("b", "b"), pinTo("c", "k2") }, &.{ pinTo("c", "k2"), pinTo("b", "b"), pinTo("a", "a") } }) |roots| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var table: Table = .{ .revisions = &.{ k1, k2, k3, a_, b }, .parents = &history };
        const graph = try select(arena.allocator(), &table, roots, &.{}, .{});
        try std.testing.expectEqual(null, graph.problem);
        try std.testing.expectEqualStrings("k3", graph.resolve(hashed("k1")).?.place.key());
        try std.testing.expectEqualStrings("k3", graph.resolve(hashed("k2")).?.place.key());
        try std.testing.expectEqual(1, table.asked);
    }
}

test "commits that diverge are refused, each named, and none picked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // base <- left, base <- right.
    const left = at("c", "0.7.5", "left", "left", false, &.{});
    const right = at("c", "0.7.5", "right", "right", false, &.{});
    const x = rev("x", 1, "1.0.0", "x", &.{pinTo("c", "left")});
    const y = rev("y", 2, "1.0.0", "y", &.{pinTo("c", "right")});
    const history = [_]Table.Parents{ .{ "left", &.{"base"} }, .{ "right", &.{"base"} } };
    var table: Table = .{ .revisions = &.{ left, right, x, y }, .parents = &history };
    const graph = try select(a, &table, &.{ pinTo("x", "x"), pinTo("y", "y") }, &.{}, .{});
    const diverged = graph.problem.?.diverged;
    try std.testing.expectEqualStrings("c", diverged.name);
    try std.testing.expectEqual(2, diverged.heads.len);
    var names: [2][]const u8 = .{ diverged.heads[0].place.key(), diverged.heads[1].place.key() };
    std.mem.sort([]const u8, &names, {}, struct {
        fn less(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.less);
    try std.testing.expectEqualStrings("left", names[0]);
    try std.testing.expectEqualStrings("right", names[1]);
    // A commit that contains both settles them.
    const merged = at("c", "0.7.5", "merged", "merged", false, &.{});
    const settled_history = [_]Table.Parents{ .{ "left", &.{"base"} }, .{ "right", &.{"base"} }, .{ "merged", &.{ "left", "right" } } };
    var settled_table: Table = .{ .revisions = &.{ left, right, x, y, merged }, .parents = &settled_history };
    const settled = try select(a, &settled_table, &.{ pinTo("x", "x"), pinTo("y", "y"), pinTo("c", "merged") }, &.{}, .{});
    try std.testing.expectEqual(null, settled.problem);
    try std.testing.expectEqualStrings("merged", settled.resolve(hashed("left")).?.place.key());
}

test "a release and a commit that descends from its tag select the commit, across what the manifests say" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // v0.23.0 tags t; s descends from t and from x, a fix whose manifest still says 0.22.2.
    const t = at("c", "0.23.0", "t", "t", true, &.{});
    const s = at("c", "0.23.0", "s", "s", false, &.{});
    const x = at("c", "0.22.2", "x", "x", false, &.{});
    const uplink = rev("uplink", 1, "1.0.0", "uplink", &.{pinTo("c", "t")});
    const clearance = rev("clearance", 2, "1.0.0", "clearance", &.{pinTo("c", "x")});
    const history = [_]Table.Parents{ .{ "t", &.{"base"} }, .{ "x", &.{"base"} }, .{ "s", &.{ "t", "x" } } };
    var table: Table = .{ .revisions = &.{ t, s, x, uplink, clearance }, .parents = &history };
    const graph = try select(a, &table, &.{ pinTo("uplink", "uplink"), pinTo("clearance", "clearance"), pinTo("c", "s") }, &.{}, .{});
    // Not two contents of 0.23.0, nor 0.22.2 a line below it: s contains both.
    try std.testing.expectEqual(null, graph.problem);
    try std.testing.expectEqualStrings("s", graph.resolve(hashed("t")).?.place.key());
    try std.testing.expectEqualStrings("s", graph.resolve(hashed("x")).?.place.key());
}

test "a release and a commit that does not descend from its tag are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = at("c", "0.23.0", "t", "t", true, &.{});
    const x = at("c", "0.22.2", "x", "x", false, &.{});
    const uplink = rev("uplink", 1, "1.0.0", "uplink", &.{pinTo("c", "t")});
    const clearance = rev("clearance", 2, "1.0.0", "clearance", &.{pinTo("c", "x")});
    const history = [_]Table.Parents{ .{ "t", &.{"base"} }, .{ "x", &.{"base"} } };
    var table: Table = .{ .revisions = &.{ t, x, uplink, clearance }, .parents = &history };
    const graph = try select(a, &table, &.{ pinTo("uplink", "uplink"), pinTo("clearance", "clearance") }, &.{}, .{});
    try std.testing.expectEqual(2, graph.problem.?.diverged.heads.len);
}

test "releases alone are selected by version, and history is never asked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t1 = at("c", "0.1.0", "t1", "t1", true, &.{});
    const t2 = at("c", "0.1.1", "t2", "t2", true, &.{});
    var table: Table = .{ .revisions = &.{ t1, t2 } };
    const graph = try select(arena.allocator(), &table, &.{ pinTo("c", "t2"), pinTo("c", "t1") }, &.{}, .{});
    try std.testing.expectEqual(null, graph.problem);
    try std.testing.expectEqualStrings("t2", graph.resolve(hashed("t1")).?.place.key());
    try std.testing.expectEqual(0, table.asked);
}

test "a commit pin beside a pin of no commit is refused: history cannot place an archive" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const k = at("c", "0.1.0", "k", "k", false, &.{});
    const archive = rev("c", 7, "0.1.0", "archive", &.{});
    var table: Table = .{ .revisions = &.{ k, archive } };
    const graph = try select(arena.allocator(), &table, &.{ pinTo("c", "k"), pinTo("c", "archive") }, &.{}, .{});
    try std.testing.expectEqualStrings("archive", graph.problem.?.unordered.other.place.key());
}
