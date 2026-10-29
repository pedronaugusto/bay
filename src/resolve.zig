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
const aegis = @import("aegis");
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
    /// Whether the package's development takes part: not for an install, which
    /// builds the package as anything depending on it would, as `cargo install` does.
    development: bool = true,
};

pub const Resolution = struct {
    input: Input,
    store: *store.Store,
    graph: select.Graph,
    /// The one place of each package, by selection key.
    places: std.array_hash_map.String(select.Place),
    /// The entries the package's manifest, or a workspace member's, must change
    /// to name the one hash of each package.
    raises: []const manifest.Repin,

    /// The hash the package itself appears under, when something pins it: the
    /// development root pins it so, with a fork to the working tree.
    pub fn packagePin(r: Resolution) ?select.Place.Remote {
        const key = r.graph.keys.get(r.input.package).?; // safe: the package is a main module, read first
        const place = r.places.get(key) orelse return null;
        return if (place == .remote) place.remote else null;
    }

    /// The forks for one build, written under the package, as `--fork=` arguments
    /// relative to it. Only packages that build fetches by hash get one: Zig
    /// refuses a fork that matches nothing, and one it reaches only by a path
    /// (a workspace member's own directory) is built from there already.
    /// `from` is the directory Zig runs in, which is the build's root: Zig reads a
    /// fork's path from there.
    pub fn forks(r: Resolution, build: Build) ![]const []const u8 {
        const a = r.input.a;
        var arguments: std.ArrayList([]const u8) = .empty;
        for (try r.reachable(build)) |key| {
            const directory = try r.forkFor(key) orelse continue;
            // Absolute: Zig reads a fork against where it runs in one configure pass, and
            // against the build's root in the pass it makes after fetching lazy packages.
            try arguments.append(a, try a.print("--fork={s}", .{try std.fs.path.resolveAlloc(a, &.{directory})}));
        }
        return arguments.toOwnedSlice(a);
    }

    /// The selection keys a build's graph fetches by hash, from the package's pins
    /// (and, for the development root, its dev pins and the package itself). The
    /// walk goes through every pin; a key only a path reaches is left out.
    fn reachable(r: Resolution, build: Build) ![]const []const u8 {
        const a = r.input.a;
        var seen: std.array_hash_map.String(void) = .empty;
        var fetched: std.array_hash_map.String(void) = .empty;
        var queue: std.ArrayList(select.Pin) = .empty;
        try queue.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.normal));
        if (build == .development) {
            try queue.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.dev));
            if (r.packagePin()) |pin| try queue.append(a, .{ .key = r.input.parsed.name, .place = .{ .remote = pin } });
        }
        var next: usize = 0;
        while (next < queue.items.len) : (next += 1) {
            const key = r.graph.keys.get(queue.items[next].place.key()) orelse continue;
            if (queue.items[next].place == .remote) try fetched.put(a, key, {});
            if ((try seen.getOrPut(a, key)).found_existing) continue;
            const revision = r.graph.mains.get(key) orelse r.graph.selected.get(key).?; // safe: a key read is main or selected
            // What Zig builds: a dependency's dev pins are never part of it.
            for (revision.pins) |pin| if (!pin.dev) try queue.append(a, pin);
        }
        return fetched.keys();
    }

    /// The fork of one package, when its content differs from its one hash. A
    /// main module other than the package itself (a workspace member, a
    /// directory override) whose pins disagree with the selection is built from
    /// a copy of its working tree with only those pins rewritten: its manifest
    /// is its own to tidy, and no build needs it tidied first.
    fn forkFor(r: Resolution, key: []const u8) !?[]const u8 {
        const place = r.places.get(key) orelse return null;
        if (place != .remote) return null;
        const revision = r.graph.mains.get(key) orelse r.graph.selected.get(key).?; // safe: a placed key is main or selected
        const rewrites = try r.rewritesOf(revision);
        if (r.graph.mains.contains(key) and revision.place == .directory) {
            // The package's own pins agree, or its build stops before any fork.
            if (rewrites.len == 0 or std.mem.eql(u8, revision.place.directory, r.input.package)) return revision.place.directory;
            return try writeWorkingFork(r.input, revision, rewrites);
        }
        if (rewrites.len == 0) return null;
        return try writeFork(r.input, r.store, place.remote, rewrites);
    }

    /// The pins of `revision` that name another revision than the selection's.
    fn rewritesOf(r: Resolution, revision: select.Revision) ![]const manifest.Dependency {
        var rewrites: std.ArrayList(manifest.Dependency) = .empty;
        for (revision.pins) |pin| {
            const target = r.wanted(pin) orelse continue;
            // A dev pin is in no manifest Zig reads as a dependency's.
            if (pin.dev or target != .remote or std.mem.eql(u8, target.key(), pin.place.key())) continue;
            try rewrites.append(r.input.a, .{ .name = pin.key, .lazy = pin.lazy, .source = .{ .remote = .{ .url = target.remote.url, .hash = target.remote.hash } } });
        }
        return rewrites.toOwnedSlice(r.input.a);
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
    // Every package under development takes part with its development, as Go
    // counts each workspace module's tests: every member resolves one graph.
    // The package as `input.parsed` has it, which a writing command resolves before it writes.
    try mains.append(a, try store.revisionOf(input.io, a, input.package, .{ .directory = input.package }, input.parsed, input.development));
    for (input.members) |member| try mains.append(a, try store.developedAt(input.io, a, member));
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
    const graph = try select.select(a, packages, &.{}, mains.items, .{ .coexist = try coexisting(input), .chosen = chosen.items });
    if (graph.problem) |problem| try refuse(a, input.io, graph, problem);
    var resolution: Resolution = .{ .input = input, .store = packages, .graph = graph, .places = try places(a, graph, chosen.items), .raises = &.{} };
    try materializable(resolution);
    resolution.raises = try raises(resolution);
    return resolution;
}

/// The packages whose lines may coexist: what the package names, and in a
/// workspace what every member names, as the workspace is one graph.
fn coexisting(input: Input) ![]const []const u8 {
    const a = input.a;
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(a, input.parsed.coexist);
    if (contains(input.parsed.coexist, input.parsed.name)) try say.fail(input.io, "{s} names itself in .coexist; a package builds one line of itself", .{input.parsed.name});
    for (input.members) |member| {
        const path = try std.fs.path.join(a, &.{ member, "build.zig.zon" });
        const text = try aegis.own.readFile(input.io, Io.Dir.cwd(), path, a, .fromRaw(1 << 20));
        const parsed = manifest.parse(a, try a.dupeSentinel(u8, text, 0)) catch |err| switch (err) {
            error.InvalidManifest => try say.fail(input.io, "{s} is not a manifest bay can read", .{path}),
            error.OutOfMemory => |e| return e,
        };
        if (contains(parsed.coexist, parsed.name)) try say.fail(input.io, "{s} names itself in .coexist; a package builds one line of itself", .{parsed.name});
        for (parsed.coexist) |name| if (!contains(names.items, name)) try names.append(a, name);
    }
    return names.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |each| if (std.mem.eql(u8, each, item)) return true;
    return false;
}

/// The one place of each package: the selected revision's, or the highest hash pinned for a main module.
/// Between equal versions of a main module, the hash the root names stands for it.
/// What Zig cannot build as one graph, refused in a sentence: a package that the
/// built graph has as a directory somewhere and at another place elsewhere (Zig
/// makes the directory a package of its own beside the other; `.overrides` makes
/// one of them), a package two of whose lines coexist while one needs a fork
/// (Zig matches a fork by what a package is, not by its line), and a main module
/// reached by its directory that Zig cannot build as selected (below).
fn materializable(r: Resolution) !void {
    const a = r.input.a;
    const io = r.input.io;
    var seen: std.array_hash_map.String(select.Place) = .empty;
    for (try builtPins(a, r.graph)) |pin| {
        const key = r.graph.keys.get(pin.place.key()) orelse continue;
        if (r.graph.mains.contains(key)) continue;
        const entry = try seen.getOrPut(a, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = pin.place;
            continue;
        }
        if (std.mem.eql(u8, entry.value_ptr.key(), pin.place.key())) continue;
        if (pin.place != .directory and entry.value_ptr.* != .directory) continue;
        const name = r.graph.read.get(pin.place.key()).?.identity.name; // safe: every place pinned in the graph was read
        for ([_]select.Place{ entry.value_ptr.*, pin.place }) |each| try say.note(io, "{s} at {s}, pinned by {s}", .{ name, each.key(), try pinners(a, r.graph, each) });
        try say.fail(io, "{s} is a directory in one place and pinned at another elsewhere, which Zig builds as two packages: name the one meant in .overrides", .{name});
    }
    var lines: std.array_hash_map.String(usize) = .empty;
    for (r.graph.selected.values()) |revision| (try lines.getOrPutValue(a, revision.identity.name, 0)).value_ptr.* += 1;
    for (r.graph.selected.values()) |revision| {
        if (lines.get(revision.identity.name).? < 2) continue; // safe: every selected name was counted
        if ((try r.rewritesOf(revision)).len == 0) continue;
        try say.fail(io, "{s} {f} coexists with another line of {s} and needs its pins rewritten, which Zig would apply to every line: pin it where its own pins agree with the selection", .{ revision.identity.name, revision.version, revision.identity.name });
    }
    try reachedByDirectory(r);
}

/// A main module other than the package (a workspace member) that the built
/// graph reaches by its directory is built from that directory with its own
/// manifest's pins: Zig forks only what it fetches by hash. So its pins must be
/// the selection's, and no pin may reach it by hash as well, which Zig would
/// build as a second package.
fn reachedByDirectory(r: Resolution) !void {
    const a = r.input.a;
    const io = r.input.io;
    // The pins Zig reads: every built revision's own, and the package's development ones.
    var read: std.ArrayList(select.Pin) = .empty;
    for (try builtPins(a, r.graph)) |pin| if (!pin.dev) try read.append(a, pin);
    try read.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.dev));
    for (r.graph.mains.keys(), r.graph.mains.values()) |key, main| {
        if (main.place != .directory or std.mem.eql(u8, main.place.directory, r.input.package)) continue;
        var by_directory = false;
        var by_hash = false;
        for (read.items) |pin| {
            const reached = r.graph.keys.get(pin.place.key()) orelse continue;
            if (!std.mem.eql(u8, reached, key)) continue;
            switch (pin.place) {
                .directory => by_directory = true,
                .remote => by_hash = true,
            }
        }
        if (!by_directory) continue;
        const name = main.identity.name;
        if (by_hash) try say.fail(io, "{s} is reached by its directory and pinned by hash, which Zig builds as two packages: reach it one way", .{name});
        if ((try r.rewritesOf(main)).len != 0) try say.fail(io, "{s} is reached by its directory, where Zig reads its own pins, and they are behind the selection: tidy it (bay --workspace tidy), or pin it at its release", .{name});
    }
    // A path dependency that is no member is built the same way: from its
    // directory, with its own manifest's pins, which no fork can rewrite.
    for (r.graph.selected.values()) |revision| {
        if (revision.place != .directory) continue;
        if ((try r.rewritesOf(revision)).len == 0) continue;
        try say.fail(io, "{s} is a path dependency, which Zig builds with its own manifest's pins, and they are behind the selection: raise them in {s}, or name it in bay.work, where bay --workspace tidy does", .{ revision.identity.name, revision.place.directory });
    }
}

/// Every pin of what is built: the main modules' and the selected revisions'.
fn builtPins(a: std.mem.Allocator, graph: select.Graph) ![]const select.Pin {
    var list: std.ArrayList(select.Pin) = .empty;
    for ([_][]const select.Revision{ graph.mains.values(), graph.selected.values() }) |revisions| for (revisions) |revision| try list.appendSlice(a, revision.pins);
    return list.items;
}

fn places(a: std.mem.Allocator, graph: select.Graph, chosen: []const []const u8) !std.array_hash_map.String(select.Place) {
    var result: std.array_hash_map.String(select.Place) = .empty;
    for (graph.selected.keys(), graph.selected.values()) |key, revision| try result.put(a, key, revision.place);
    var best: std.array_hash_map.String(select.Revision) = .empty;
    // A main module's one hash: the highest revision of it the built graph pins.
    for (try builtPins(a, graph)) |pin| {
        if (pin.place != .remote) continue;
        const revision = graph.read.get(pin.place.key()) orelse continue;
        const key = graph.keys.get(pin.place.key()).?; // safe: every place read has its key
        if (!graph.mains.contains(key)) continue;
        const entry = try best.getOrPut(a, key);
        const replace = !entry.found_existing or switch (revision.version.order(entry.value_ptr.version)) {
            .gt => true,
            .eq => named(chosen, revision.place.key()) and !named(chosen, entry.value_ptr.place.key()),
            .lt => false,
        };
        if (replace) entry.value_ptr.* = revision;
    }
    for (best.keys(), best.values()) |key, revision| try result.put(a, key, revision.place);
    // A main module that is a revision (an override by hash) is its own one hash.
    for (graph.mains.keys(), graph.mains.values()) |key, main| if (main.place == .remote) try result.put(a, key, main.place);
    return result;
}

fn named(chosen: []const []const u8, key: []const u8) bool {
    for (chosen) |place| if (std.mem.eql(u8, place, key)) return true;
    return false;
}

/// The package's own pins that name another revision than the selection's:
/// its manifest is the one its build reads, so each must name the one hash.
/// A member's pins are its own to tidy; its build reads a rewritten copy.
fn raises(r: Resolution) ![]const manifest.Repin {
    var list: std.ArrayList(manifest.Repin) = .empty;
    try raisesOf(r, &list, r.input.package, r.input.parsed);
    return list.toOwnedSlice(r.input.a);
}

fn raisesOf(r: Resolution, list: *std.ArrayList(manifest.Repin), directory: []const u8, parsed: manifest.Manifest) !void {
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .dev) parsed.dev else parsed.normal;
        for (dependencies, try store.pins(r.input.a, directory, dependencies)) |dependency, pin| {
            if (pin.place != .remote) continue; // a path dependency names a directory, not a version
            const target = r.wanted(pin) orelse continue;
            if (target != .remote or std.mem.eql(u8, target.remote.hash, pin.place.remote.hash)) continue;
            // Selection never goes below a pin it counted: a lower one means the
            // graph read is not the one this manifest makes, so nothing is written.
            if (r.graph.read.get(pin.place.key())) |pinned| if (r.graph.read.get(target.key())) |selected| {
                if (selected.version.order(pinned.version) == .lt) try say.fail(r.input.io, "{s}: {s} would go from {f} down to {f}, below what the manifest pins; the workspace holds another copy of a package, or its graph is stale", .{ directory, dependency.name, pinned.version, selected.version });
            };
            try list.append(r.input.a, .{ .directory = directory, .kind = kind, .from = dependency, .to = .{ .name = dependency.name, .lazy = dependency.lazy, .source = .{ .remote = .{ .url = target.remote.url, .hash = target.remote.hash } } } });
        }
    }
}

/// A copy of the package at `remote` with `rewrites` in its manifest, named by
/// its hash and the rewrites, so an unchanged selection reuses it.
fn writeFork(input: Input, packages: *store.Store, remote: select.Place.Remote, rewrites: []const manifest.Dependency) ![]const u8 {
    const directory = try std.fs.path.join(input.a, &.{ input.package, forks_directory, try input.a.print("{s}-{x}", .{ remote.hash, digestOf(rewrites) }) });
    if (Io.Dir.cwd().access(input.io, directory, .{})) |_| return directory else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    try materialize(input, try packages.directoryOf(remote), directory, rewrites);
    return directory;
}

/// A copy of a main module's working tree with `rewrites` in its manifest,
/// made afresh for every build, since the tree is being worked on.
fn writeWorkingFork(input: Input, main: select.Revision, rewrites: []const manifest.Dependency) ![]const u8 {
    const directory = try std.fs.path.join(input.a, &.{ input.package, forks_directory, try input.a.print("{s}-working-{x}", .{ main.identity.name, digestOf(rewrites) }) });
    try materialize(input, main.place.directory, directory, rewrites);
    return directory;
}

fn digestOf(rewrites: []const manifest.Dependency) u64 {
    var digest = std.hash.Wyhash.init(0);
    for (rewrites) |rewrite| {
        digest.update(rewrite.name);
        digest.update(rewrite.source.remote.hash);
    }
    return digest.final();
}

/// Copies `source` to `directory` with `rewrites` in its manifest: written
/// beside and then renamed over any older copy, so a fork is never seen half made.
fn materialize(input: Input, source: []const u8, directory: []const u8, rewrites: []const manifest.Dependency) !void {
    const a = input.a;
    const partial = try a.print("{s}.partial", .{directory});
    try Io.Dir.cwd().deleteTree(input.io, partial);
    try copyTree(input.io, a, source, partial);
    const manifest_path = try std.fs.path.join(a, &.{ partial, "build.zig.zon" });
    var text = try a.dupeSentinel(u8, try aegis.own.readFile(input.io, Io.Dir.cwd(), manifest_path, a, .fromRaw(1 << 20)), 0);
    for (rewrites) |rewrite| text = try manifest.put(a, text, .normal, rewrite);
    try Io.Dir.cwd().writeFile(input.io, .{ .sub_path = manifest_path, .data = text });
    try Io.Dir.cwd().deleteTree(input.io, directory);
    try Io.Dir.cwd().rename(partial, Io.Dir.cwd(), directory, input.io);
}

/// Copies a package's files from `from` to `to`, leaving out what building and
/// version control keep beside them: `.git`, `.zig-cache`, `zig-out`, `zig-pkg`.
pub fn copyTree(io: Io, a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, to);
    var source = try Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (beside(entry.basename)) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        const target = try std.fs.path.join(a, &.{ to, entry.path });
        switch (entry.kind) {
            .directory => try Io.Dir.cwd().createDirPath(io, target),
            .file => try source.copyFile(entry.path, Io.Dir.cwd(), target, io, .{}),
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link = try source.readLink(io, entry.path, &buffer);
                // Windows makes a link to a directory apart from one to a file: what it reaches says which.
                const to_directory = if (source.statFile(io, entry.path, .{})) |stat| stat.kind == .directory else |err| switch (err) {
                    error.FileNotFound => false, // a link to nothing is kept as a link to a file
                    else => |e| return e,
                };
                // aegis: no-danger(A009): the link's target, copied as the text the new link holds: nothing here opens it
                try Io.Dir.cwd().symLink(io, buffer[0..link], target, .{ .is_directory = to_directory });
            },
            else => {},
        }
    }
}

fn beside(name: []const u8) bool {
    for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" }) |kept| if (std.mem.eql(u8, name, kept)) return true;
    return false;
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
    }
}
