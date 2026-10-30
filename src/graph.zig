//! Seeing a resolved graph and keeping it: `bay tree` shows it as Cargo's
//! `cargo tree` and Go's `go mod graph` do, `bay outdated` names newer
//! releases, `bay vendor` keeps every package a build uses in the project.
const std = @import("std");
const builtin = @import("builtin");
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
/// release, and each built at a version its newest release retracts. A prebuilt is
/// not listed, as no version protocol is common to its sources, and bay says so.
pub fn outdated(r: resolve.Resolution) !void {
    const a = r.input.a;
    const scratch = try std.fs.path.join(a, &.{ r.input.package, ".zig-cache", "bay", "add" });
    var prebuilts: std.array_hash_map.String(void) = .empty;
    for ([_][]const select.Revision{ r.graph.mains.values(), r.graph.selected.values() }) |revisions| for (revisions) |revision| for (revision.pins) |pin| {
        if (pin.place == .remote and pin.place.remote.prebuilt != null) try prebuilts.put(a, pin.key, {});
    };
    var any = false;
    for (r.graph.selected.values()) |selected| {
        const remote = switch (selected.place) {
            .remote => |remote| remote,
            .directory => continue,
        };
        if (remote.prebuilt != null) continue;
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
    if (prebuilts.count() != 0) try say.note(r.input.io, "not listed, as prebuilts follow no version bay can read: {s}; bay update <name> <bay+https://…> moves one", .{try std.mem.join(a, ", ", prebuilts.keys())});
}

/// The hosts a vendored `zig-pkg` builds on.
pub const Hosts = enum {
    /// What the builds take besides the revisions selection reads, a package with no
    /// manifest or a lazy one, their configuration on this host brings (`main.zig`'s vendor).
    this_host,
    /// Every package below every revision, lazy ones included: what a build on any host
    /// may ask for. One revision is fetched at a time, so a failure names its package.
    all_hosts,
};

/// `bay vendor`'s first half: every revision selection reads to choose the graph,
/// unpacked by Zig itself into the project's `zig-pkg`, which both its builds use
/// and Zig reads before any network, so the project resolves with no remote
/// reachable.
pub fn vendor(r: resolve.Resolution, hosts: Hosts) !void {
    const a = r.input.a;
    const io = r.input.io;
    var dependencies: Io.Writer.Allocating = .init(a);
    var count: usize = 0;
    for (r.graph.read.values()) |revision| {
        const remote = switch (revision.place) {
            .remote => |remote| remote,
            .directory => continue,
        };
        // A package with no manifest is read by no selection, and a build that takes it fetches
        // it. Zig fetches no prebuilt: bay brings one into Zig's cache, from which Zig unpacks it
        // with the rest, by its hash, never reaching its URL.
        const unnamed = store.unnamed(remote.hash);
        if (unnamed and remote.prebuilt == null and hosts == .this_host) continue;
        // Zig fetches what only git reaches from its cache, where resolution put it.
        if (!unnamed or remote.prebuilt != null) _ = try r.store.directoryOf(remote);
        const entry = try a.print(".p{d} = .{{ .url = \"{f}\", .hash = \"{f}\" }}, ", .{ count, std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) });
        count += 1;
        switch (hosts) {
            .this_host => try dependencies.writer.writeAll(entry),
            .all_hosts => try unpack(r, entry, "--fetch=all", revision.identity.name),
        }
    }
    if (hosts == .this_host) try unpack(r, dependencies.written(), "--fetch", null);
    try say.note(io, "{d} packages vendored into {s}", .{ count, try std.fs.path.join(a, &.{ r.input.package, "zig-pkg" }) });
}

/// Zig unpacks the packages `dependencies` lists, fetched by `mode`, into the project's
/// `zig-pkg`, as the dependencies of a scratch build. `name`, when the list is one
/// package, is the package a failure names.
fn unpack(r: resolve.Resolution, dependencies: []const u8, mode: []const u8, name: ?[]const u8) !void {
    const a = r.input.a;
    const io = r.input.io;
    const scratch = try std.fs.path.join(a, &.{ r.input.package, ".zig-cache", "bay", "vendor" });
    try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, scratch);
    var dir = try Io.Dir.cwd().openDir(io, scratch, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *@import(\"std\").Build) void {}\n" });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try root.scratchManifest(a, "bay_vendor", dependencies) });
    const destination = try std.fs.path.join(a, &.{ r.input.package, "zig-pkg" });
    // Relative to the scratch build, as the store's fetch passes it: Zig 0.17 refuses the
    // path dependencies of a package unpacked under an absolute --pkg-dir.
    const relative = try std.fs.path.join(a, &.{ "..", "..", "..", "zig-pkg" });
    const result = std.process.run(a, io, .{ .argv = &.{ r.input.zig, "build", mode, "--pkg-dir", relative }, .cwd = .{ .path = scratch }, .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run {s}: {t}", .{ r.input.zig, err });
    if (result.term != .exited or result.term.exited != 0) {
        // Windows makes a symbolic link only for an account holding the privilege. Zig
        // notes every link it could not make; bay names the first, and what to do.
        if (builtin.os.tag == .windows) if (linkRefused(result.stderr)) |link|
            try say.fail(io, "{s}, with every package below it, lazy ones included, holds a link this account may not make, {s}: Windows makes one only for an account with SeCreateSymbolicLinkPrivilege, the \"Create symbolic links\" right; `bay vendor` without --all-hosts vendors what this host's builds take", .{ name orelse "the graph", link });
        try say.relay(io, result.stderr);
        try say.fail(io, "Zig could not unpack the packages into {s}", .{destination});
    }
}

/// The first link Zig's output says it was not permitted to make, `from 'a' to 'b'`,
/// from its note `unable to create symlink from 'a' to 'b': PermissionDenied`.
fn linkRefused(stderr: []const u8) ?[]const u8 {
    const note = "unable to create symlink ";
    const denied = ": PermissionDenied";
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const start = std.mem.find(u8, line, note) orelse continue;
        const text = std.mem.trimEnd(u8, line[start + note.len ..], "\r");
        if (std.mem.endsWith(u8, text, denied)) return text[0 .. text.len - denied.len];
    }
    return null;
}

test linkRefused {
    try std.testing.expectEqualStrings("from 'bin/sh' to 'busybox'", linkRefused("error: unable to unpack\r\nnote: unable to create symlink from 'bin/sh' to 'busybox': PermissionDenied\r\n").?);
    try std.testing.expectEqual(null, linkRefused("note: unable to create symlink from 'a' to 'b': NameTooLong\n"));
    try std.testing.expectEqual(null, linkRefused("error: hash mismatch\n"));
}
