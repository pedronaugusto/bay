//! A package's graph resolved and handed to Zig.
//!
//! Selection runs over everything the package, its development and its
//! workspace pin (Go's module graph, the main module's test dependencies in
//! it). Zig then gets a graph in which every package appears under one hash:
//! the selected revision's, or for a main module the highest one its pins name.
//! The root's own pins must already be those hashes (`bay tidy` writes them, as
//! Go writes go.mod); a fork supplies the content wherever it differs from the
//! hash: a main module's directory, or a revision whose own pins differ, copied
//! with only its manifest's pins rewritten. `zig build --fork=<dir>` substitutes
//! each by name and fingerprint.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const select = @import("select.zig");
const store = @import("store.zig");
const say = @import("say.zig");

/// Where forks are written, under the package.
pub const forks_directory = ".zig-cache/bay/forks";

/// Which build the forks are for: the package's own, or its development root.
pub const Build = enum { package, development };

pub const Input = struct {
    io: Io,
    a: std.mem.Allocator,
    zig: []const u8,
    /// The package's absolute directory.
    package: []const u8,
    parsed: manifest.Manifest,
    /// Other packages developed with this one (a workspace): absolute directories.
    members: []const []const u8 = &.{},
};

/// A manifest entry that must change to name the one hash of its package: in
/// the package's manifest, or a workspace member's (`directory`).
pub const Raise = struct { directory: []const u8, kind: manifest.Kind, from: manifest.Dependency, to: manifest.Dependency };

pub const Resolution = struct {
    input: Input,
    store: *store.Store,
    graph: select.Graph,
    /// The one place of each package, by selection key.
    places: std.array_hash_map.String(select.Place),
    /// What the root manifest must change to agree with the selection.
    raises: []const Raise,

    /// The hash the package itself appears under, when something pins it: the
    /// development root pins it so, with a fork to the working tree.
    pub fn packagePin(r: Resolution) ?select.Place.Remote {
        const key = r.graph.keys.get(r.input.package).?; // safe: the package is a main module, read first
        const place = r.places.get(key) orelse return null;
        return if (place == .remote) place.remote else null;
    }

    /// The forks for one build, written under the package, as `--fork=` arguments
    /// relative to it. Only packages in that build's graph get one: Zig refuses a
    /// fork that matches nothing.
    /// `from` is the directory Zig runs in, which is the build's root: Zig reads a
    /// fork's path from there.
    pub fn forks(r: Resolution, build: Build, from: []const u8) ![]const []const u8 {
        const a = r.input.a;
        var arguments: std.ArrayList([]const u8) = .empty;
        for (try r.reachable(build)) |key| {
            const directory = try r.forkFor(key) orelse continue;
            const relative = try std.fs.path.relativeAlloc(a, from, null, from, directory);
            try arguments.append(a, try a.print("--fork={s}", .{if (relative.len == 0) "." else relative}));
        }
        return arguments.toOwnedSlice(a);
    }

    /// The selection keys in a build's graph, from the package's pins (and, for
    /// the development root, its dev pins and the package itself).
    fn reachable(r: Resolution, build: Build) ![]const []const u8 {
        const a = r.input.a;
        var seen: std.array_hash_map.String(void) = .empty;
        var queue: std.ArrayList(select.Pin) = .empty;
        try queue.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.normal));
        if (build == .development) {
            try queue.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.dev));
            if (r.packagePin()) |pin| try queue.append(a, .{ .key = r.input.parsed.name, .place = .{ .remote = pin } });
        }
        var next: usize = 0;
        while (next < queue.items.len) : (next += 1) {
            const key = r.graph.keys.get(queue.items[next].place.key()) orelse continue;
            if ((try seen.getOrPut(a, key)).found_existing) continue;
            const revision = r.graph.mains.get(key) orelse r.graph.selected.get(key).?; // safe: a key read is main or selected
            try queue.appendSlice(a, revision.pins);
        }
        return seen.keys();
    }

    /// The fork of one package, when its content differs from its one hash.
    fn forkFor(r: Resolution, key: []const u8) !?[]const u8 {
        const place = r.places.get(key) orelse return null;
        if (place != .remote) return null;
        if (r.graph.mains.get(key)) |main| if (main.place == .directory) return main.place.directory;
        const revision = r.graph.mains.get(key) orelse r.graph.selected.get(key).?; // safe: a placed key is main or selected
        var rewrites: std.ArrayList(manifest.Dependency) = .empty;
        for (revision.pins) |pin| {
            const target = r.wanted(pin) orelse continue;
            if (std.mem.eql(u8, target.key(), pin.place.key())) continue;
            try rewrites.append(r.input.a, .{ .name = pin.key, .lazy = pin.lazy, .source = .{ .remote = .{ .url = target.remote.url, .hash = target.remote.hash } } });
        }
        if (rewrites.items.len == 0) return null;
        return try writeFork(r.input, r.store, place.remote, rewrites.items);
    }

    /// The one place a pin must name: its package's.
    pub fn wanted(r: Resolution, pin: select.Pin) ?select.Place {
        const key = r.graph.keys.get(pin.place.key()) orelse return null;
        return r.places.get(key);
    }
};

/// Resolves the package's graph; a graph with no selection is refused in a sentence.
pub fn resolve(input: Input) !Resolution {
    const a = input.a;
    const packages = try store.Store.init(input.io, a, input.zig, input.package);
    var mains: std.ArrayList(select.Revision) = .empty;
    var package = try store.revisionAt(input.io, a, input.package, .{ .directory = input.package });
    // The package's development takes part in selection, as a Go module's tests do.
    package.pins = try store.pins(a, input.package, try std.mem.concat(a, manifest.Dependency, &.{ input.parsed.normal, input.parsed.dev }));
    try mains.append(a, package);
    for (input.members) |member| try mains.append(a, try store.revisionAt(input.io, a, member, .{ .directory = member }));
    for (input.parsed.overrides) |override| try mains.append(a, switch (override.source) {
        .path => |path| main: {
            const directory = try std.fs.path.resolveAlloc(a, &.{ input.package, path });
            break :main try store.revisionAt(input.io, a, directory, .{ .directory = directory });
        },
        .remote => |remote| try store.revisionAt(input.io, a, try packages.directoryOf(.{ .url = remote.url, .hash = remote.hash }), .{ .remote = .{ .url = remote.url, .hash = remote.hash } }),
    });
    // What the root names itself decides between revisions that claim one version.
    var chosen: std.ArrayList([]const u8) = .empty;
    for ([_][]const manifest.Dependency{ input.parsed.normal, input.parsed.dev, input.parsed.overrides }) |dependencies| for (dependencies) |dependency| switch (dependency.source) {
        .remote => |remote| try chosen.append(a, remote.hash),
        .path => {},
    };
    const graph = try select.select(a, packages.loader(), &.{}, mains.items, .{ .coexist = input.parsed.coexist, .chosen = chosen.items });
    if (graph.problem) |problem| try refuse(a, input.io, graph, problem);
    var resolution: Resolution = .{ .input = input, .store = packages, .graph = graph, .places = try places(a, graph, chosen.items), .raises = &.{} };
    resolution.raises = try raises(resolution);
    return resolution;
}

/// The one place of each package: the selected revision's, or the highest hash pinned for a main module.
/// Between equal versions of a main module, the hash the root names stands for it.
fn places(a: std.mem.Allocator, graph: select.Graph, chosen: []const []const u8) !std.array_hash_map.String(select.Place) {
    var result: std.array_hash_map.String(select.Place) = .empty;
    for (graph.selected.keys(), graph.selected.values()) |key, revision| try result.put(a, key, revision.place);
    var best: std.array_hash_map.String(select.Revision) = .empty;
    for (graph.read.keys(), graph.read.values()) |place, revision| {
        const key = graph.keys.get(place).?; // safe: every place read has its key
        if (!graph.mains.contains(key) or revision.place != .remote) continue;
        const entry = try best.getOrPut(a, key);
        const replace = !entry.found_existing or switch (revision.version.order(entry.value_ptr.version)) {
            .gt => true,
            .eq => named(chosen, revision.place.key()) and !named(chosen, entry.value_ptr.place.key()),
            .lt => false,
        };
        if (replace) entry.value_ptr.* = revision;
    }
    for (best.keys(), best.values()) |key, revision| try result.put(a, key, revision.place);
    return result;
}

fn named(chosen: []const []const u8, key: []const u8) bool {
    for (chosen) |place| if (std.mem.eql(u8, place, key)) return true;
    return false;
}

/// The manifests a workspace owns, the package's first: each must pin every
/// package at its one hash, since Zig builds a main module from its directory.
fn raises(r: Resolution) ![]const Raise {
    const a = r.input.a;
    var list: std.ArrayList(Raise) = .empty;
    try raisesOf(r, &list, r.input.package, r.input.parsed);
    for (r.input.members) |member| {
        const path = try std.fs.path.join(a, &.{ member, "build.zig.zon" });
        const text = try Io.Dir.cwd().readFileAlloc(r.input.io, path, a, .limited(1 << 20));
        try raisesOf(r, &list, member, try manifest.parse(a, try a.dupeSentinel(u8, text, 0)));
    }
    return list.toOwnedSlice(a);
}

fn raisesOf(r: Resolution, list: *std.ArrayList(Raise), directory: []const u8, parsed: manifest.Manifest) !void {
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .dev) parsed.dev else parsed.normal;
        for (dependencies, try store.pins(r.input.a, directory, dependencies)) |dependency, pin| {
            if (pin.place != .remote) continue; // a path dependency names a directory, not a version
            const target = r.wanted(pin) orelse continue;
            if (target != .remote or std.mem.eql(u8, target.remote.hash, pin.place.remote.hash)) continue;
            try list.append(r.input.a, .{ .directory = directory, .kind = kind, .from = dependency, .to = .{ .name = dependency.name, .lazy = dependency.lazy, .source = .{ .remote = .{ .url = target.remote.url, .hash = target.remote.hash } } } });
        }
    }
}

/// A copy of the package at `remote` with `rewrites` in its manifest, named by
/// its hash and the rewrites, so an unchanged selection reuses it.
fn writeFork(input: Input, packages: *store.Store, remote: select.Place.Remote, rewrites: []const manifest.Dependency) ![]const u8 {
    const a = input.a;
    var digest = std.hash.Wyhash.init(0);
    for (rewrites) |rewrite| {
        digest.update(rewrite.name);
        digest.update(rewrite.source.remote.hash);
    }
    const name = try a.print("{s}-{x}", .{ remote.hash, digest.final() });
    const directory = try std.fs.path.join(a, &.{ input.package, forks_directory, name });
    if (Io.Dir.cwd().access(input.io, directory, .{})) |_| return directory else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    const source = try packages.directoryOf(remote);
    // Written beside, then renamed: a fork is never seen half copied.
    const partial = try a.print("{s}.partial", .{directory});
    try Io.Dir.cwd().deleteTree(input.io, partial);
    try copyTree(input.io, a, source, partial);
    const manifest_path = try std.fs.path.join(a, &.{ partial, "build.zig.zon" });
    var text = try a.dupeSentinel(u8, try Io.Dir.cwd().readFileAlloc(input.io, manifest_path, a, .limited(1 << 20)), 0);
    for (rewrites) |rewrite| text = try manifest.put(a, text, .normal, rewrite);
    try Io.Dir.cwd().writeFile(input.io, .{ .sub_path = manifest_path, .data = text });
    try Io.Dir.cwd().rename(partial, Io.Dir.cwd(), directory, input.io);
    return directory;
}

pub fn copyTree(io: Io, a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, to);
    var source = try Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const target = try std.fs.path.join(a, &.{ to, entry.path });
        switch (entry.kind) {
            .directory => try Io.Dir.cwd().createDirPath(io, target),
            .file => try source.copyFile(entry.path, Io.Dir.cwd(), target, io, .{}),
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link = try source.readLink(io, entry.path, &buffer);
                try Io.Dir.cwd().symLink(io, buffer[0..link], target, .{});
            },
            else => {},
        }
    }
}

/// The revisions that pin `place`, as a person reads them.
fn pinners(a: std.mem.Allocator, graph: select.Graph, place: select.Place) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (graph.read.values()) |revision| for (revision.pins) |pin| if (std.mem.eql(u8, pin.place.key(), place.key())) {
        try names.append(a, try a.print("{s} {f}", .{ revision.identity.name, revision.version }));
    };
    return if (names.items.len == 0) "the package" else std.mem.join(a, ", ", names.items);
}

/// Why there is no selection, in a sentence, ending the command.
fn refuse(a: std.mem.Allocator, io: Io, graph: select.Graph, problem: select.Problem) !noreturn {
    switch (problem) {
        .same_version => |p| {
            for ([_]select.Place{ p.first, p.second }) |place| try say.note(io, "{s} {f} at {s}, pinned by {s}", .{ p.name, p.version, place.key(), try pinners(a, graph, place) });
            try say.fail(io, "{s} {f} is two contents: a version names one, so the one meant is not known. Pin the one meant in .dependencies or .overrides, develop {s} in a workspace, or give each change its own version", .{ p.name, p.version, p.name });
        },
        .incompatible => |p| try say.fail(io, "{s} asks for {s} {f}, but {s} {f} is selected, a different line (below 1.0, a new minor is a new line): move {s} to {s} {f}, or name {s} in .coexist", .{ p.by, p.name, p.wanted, p.name, p.selected, p.by, p.name, p.selected, p.name }),
        .cycle => |p| try say.fail(io, "{s} and what it depends on depend on each other: a ring of dependencies cannot be built", .{p.name}),
        .retracted => |p| try say.fail(io, "{s} {f} is retracted by {s} {f}: pin {f} or newer", .{ p.name, p.version, p.name, p.by, p.by }),
    }
}
