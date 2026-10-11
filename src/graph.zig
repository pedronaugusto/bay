//! Seeing a resolved graph and keeping it: `bay tree` shows it as Cargo's
//! `cargo tree` and Go's `go mod graph` do, `bay outdated` names newer
//! releases, `bay vendor` keeps every package a build uses in the project.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const select = @import("select.zig");
const resolve = @import("resolve.zig");
const store = @import("store.zig");
const remotes = @import("remote.zig");
const say = @import("say.zig");
const root = @import("root.zig");
const published = @import("published.zig");

pub const TreeOptions = struct {
    /// Only the paths from the package to this one: `--why <name>`.
    why: ?[]const u8 = null,
    /// Only the packages pinned at more than one revision, and who pins each: `--duplicates`.
    duplicates: bool = false,
};

/// `bay tree`: what the package builds with, from its own pins down; a package
/// shown before is marked `(*)` and not expanded again.
pub fn tree(r: resolve.Resolution, options: TreeOptions) !void {
    if (options.duplicates) return duplicates(r);
    const a = r.input.a;
    var shown: std.array_hash_map.String(void) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .dev) r.input.parsed.dev else r.input.parsed.normal;
        if (dependencies.len == 0) continue;
        if (options.why == null) try say.out(r.input.io, "{s}{s}\n", .{ r.input.parsed.name, if (kind == .dev) " (development)" else "" });
        for (try store.pins(a, r.input.package, dependencies)) |pin| try branch(r, pin, 1, &shown, &path, options.why);
    }
}

fn branch(r: resolve.Resolution, pin: select.Pin, depth: usize, shown: *std.array_hash_map.String(void), path: *std.ArrayList([]const u8), why: ?[]const u8) !void {
    const a = r.input.a;
    const revision = r.graph.resolve(pin.place) orelse return;
    const line = try a.print("{s} {f} {s}", .{ revision.identity.name, revision.version, describe(revision) });
    try path.append(a, line);
    defer _ = path.pop();
    if (why) |name| {
        if (std.mem.eql(u8, revision.identity.name, name)) {
            for (path.items, 0..) |step, i| try say.out(r.input.io, "{s}{s}", .{ if (i == 0) r.input.parsed.name else "", try a.print(" -> {s}", .{step}) });
            try say.out(r.input.io, "\n", .{});
            return;
        }
    } else {
        const again = (try shown.getOrPut(a, revision.place.key())).found_existing;
        try say.out(r.input.io, "{s}{s}{s}\n", .{ try indent(a, depth), line, if (again and revision.pins.len != 0) " (*)" else "" });
        if (again) return;
    }
    // Selection refuses a ring, so every path ends; --why follows only those that reach the package named.
    for (revision.pins) |child| {
        if (why) |name| if (!try reaches(r, child, name, shown)) continue;
        try branch(r, child, depth + 1, shown, path, why);
    }
}

/// Whether a pin leads to the package `name`; `known` keeps the places found not to.
fn reaches(r: resolve.Resolution, pin: select.Pin, name: []const u8, known: *std.array_hash_map.String(void)) !bool {
    const revision = r.graph.resolve(pin.place) orelse return false;
    if (std.mem.eql(u8, revision.identity.name, name)) return true;
    if (known.contains(revision.place.key())) return false;
    for (revision.pins) |child| if (try reaches(r, child, name, known)) return true;
    try known.put(r.input.a, revision.place.key(), {});
    return false;
}

/// How a revision is had: a directory, or its hash.
fn describe(revision: select.Revision) []const u8 {
    return switch (revision.place) {
        .directory => |directory| directory,
        .remote => |remote| remote.hash,
    };
}

fn indent(a: std.mem.Allocator, depth: usize) ![]const u8 {
    const text = try a.alloc(u8, depth * 2);
    @memset(text, ' ');
    return text;
}

/// Every package the graph pins at more than one revision: the one built, and
/// which packages pin each other one.
fn duplicates(r: resolve.Resolution) !void {
    const a = r.input.a;
    var pinners: std.array_hash_map.String(std.ArrayList([]const u8)) = .empty;
    for (r.graph.read.values()) |revision| for (revision.pins) |pin| {
        const entry = try pinners.getOrPut(a, pin.place.key());
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, try a.print("{s} {f}", .{ revision.identity.name, revision.version }));
    };
    var groups: std.array_hash_map.String(std.ArrayList(select.Revision)) = .empty;
    for (r.graph.read.keys(), r.graph.read.values()) |place, revision| {
        const entry = try groups.getOrPut(a, r.graph.keys.get(place).?); // safe: every place read has its key
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, revision);
    }
    var any = false;
    for (groups.keys(), groups.values()) |key, revisions| {
        if (revisions.items.len < 2) continue;
        any = true;
        const built = r.places.get(key);
        try say.out(r.input.io, "{s}\n", .{revisions.items[0].identity.name});
        for (revisions.items) |revision| {
            const chosen = built != null and std.mem.eql(u8, built.?.key(), revision.place.key());
            const by = if (pinners.get(revision.place.key())) |list| try std.mem.join(a, ", ", list.items) else "the package";
            try say.out(r.input.io, "  {f} {s}{s}, pinned by {s}\n", .{ revision.version, revision.place.key(), if (chosen) " (built)" else "", by });
        }
    }
    if (!any) try say.note(r.input.io, "every package is pinned at one revision", .{});
}

/// `bay outdated`: each package the builds use whose remote has a newer
/// release, and each built at a version its newest release retracts.
pub fn outdated(r: resolve.Resolution) !void {
    const a = r.input.a;
    const scratch = try std.fs.path.join(a, &.{ r.input.package, ".zig-cache", "bay", "add" });
    var any = false;
    for (r.graph.selected.values()) |selected| {
        const remote = switch (selected.place) {
            .remote => |remote| remote,
            .directory => continue,
        };
        const latest = try published.newest(r.input.io, a, r.input.zig, r.store, scratch, remote.url) orelse continue;
        if (remotes.isRetracted(latest.retracted, selected.version)) {
            any = true;
            try say.out(r.input.io, "{s} {f} is retracted by its release {f}\n", .{ selected.identity.name, selected.version, latest.version });
        }
        if (latest.version.order(selected.version) != .gt) continue;
        any = true;
        const line: []const u8 = if (select.sameLine(latest.version, selected.version)) "" else ", a new line";
        try say.out(r.input.io, "{s} {f} -> {f} (tag {s}{s})\n", .{ selected.identity.name, selected.version, latest.version, latest.tag, line });
    }
    if (!any) try say.note(r.input.io, "every package is at its newest release, and none is retracted", .{});
}

/// `bay vendor`: every package the graph reaches, what is built and every
/// revision selection reads to choose it, unpacked by Zig itself into the
/// project's `zig-pkg`, which both its builds use and Zig reads before any
/// network: the project resolves and builds with no remote reachable.
pub fn vendor(r: resolve.Resolution) !void {
    const a = r.input.a;
    const io = r.input.io;
    var dependencies: Io.Writer.Allocating = .init(a);
    var count: usize = 0;
    for (r.graph.read.values()) |revision| {
        const remote = switch (revision.place) {
            .remote => |remote| remote,
            .directory => continue,
        };
        // Zig fetches what only git reaches from its cache, where resolution put it.
        _ = try r.store.directoryOf(remote);
        try dependencies.writer.print(".p{d} = .{{ .url = \"{f}\", .hash = \"{f}\" }}, ", .{ count, std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) });
        count += 1;
    }
    const scratch = try std.fs.path.join(a, &.{ r.input.package, ".zig-cache", "bay", "vendor" });
    try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, scratch);
    var dir = try Io.Dir.cwd().openDir(io, scratch, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *@import(\"std\").Build) void {}\n" });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try root.scratchManifest(a, "bay_vendor", dependencies.written()) });
    const destination = try std.fs.path.join(a, &.{ r.input.package, "zig-pkg" });
    const result = std.process.run(a, io, .{ .argv = &.{ r.input.zig, "build", "--fetch=all", "--pkg-dir", destination }, .cwd = .{ .path = scratch }, .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run {s}: {t}", .{ r.input.zig, err });
    if (result.term != .exited or result.term.exited != 0) {
        try say.relay(io, result.stderr);
        try say.fail(io, "Zig could not unpack the packages into {s}", .{destination});
    }
    try say.note(io, "{d} packages vendored into {s}", .{ count, destination });
}
