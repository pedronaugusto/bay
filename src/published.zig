//! A workspace member as the other members pin it: at its published revision,
//! the tag of its own `.version` on its remote, as `go work sync` writes a
//! workspace's selection back into each module. A member is built from its
//! directory inside the workspace whatever it is pinned at; the pin is what
//! everyone outside sees, so it names the newest release there is. A member
//! whose version has no tag yet has unreleased work, and its pins stay.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const remotes = @import("remote.zig");
const fetch = @import("fetch.zig");
const say = @import("say.zig");
const select = @import("select.zig");
const store = @import("store.zig");

/// A manifest the workspace owns, where it is.
pub const Owned = struct { directory: []const u8, parsed: manifest.Manifest };

/// The pins, across `owners` (directories whose manifests the workspace owns),
/// that name a member by an older version than the member's published one.
/// `members` are every member's directory; `scratch` is where Zig fetches.
pub fn syncs(io: Io, a: std.mem.Allocator, zig: []const u8, packages: *store.Store, scratch: []const u8, owners: []const []const u8, members: []const []const u8) ![]const manifest.Repin {
    const owned = try a.alloc(Owned, owners.len);
    for (owned, owners) |*entry, directory| entry.* = .{ .directory = directory, .parsed = try read(io, a, directory) };
    const versioned = try a.alloc(manifest.Manifest, members.len);
    for (versioned, members) |*parsed, directory| parsed.* = try read(io, a, directory);
    var remote: Remote = .{ .io = io, .a = a, .zig = zig, .packages = packages, .scratch = scratch };
    return plan(a, owned, versioned, &remote);
}

/// What `syncs` decides, with `releases.find(url, name, version)` giving a
/// member's release at a version as Zig records it, or null when there is none.
pub fn plan(a: std.mem.Allocator, owners: []const Owned, members: []const manifest.Manifest, releases: anytype) ![]const manifest.Repin {
    const Member = struct { version: std.SemanticVersion, fingerprint: u64, released: ?manifest.Dependency = null, looked: bool = false };
    var versions: std.array_hash_map.String(Member) = .empty;
    for (members) |parsed| {
        const version = std.SemanticVersion.parse(parsed.version) catch continue;
        try versions.put(a, parsed.name, .{ .version = version, .fingerprint = parsed.fingerprint });
    }
    var list: std.ArrayList(manifest.Repin) = .empty;
    for (owners) |owner| {
        for ([_]manifest.Kind{ .normal, .dev }) |kind| for (if (kind == .dev) owner.parsed.dev else owner.parsed.normal) |dependency| {
            const remote = switch (dependency.source) {
                .remote => |remote| remote,
                .path => continue,
            };
            const pinned = manifest.named(remote.hash) orelse continue;
            const member = versions.getPtr(pinned.name) orelse continue;
            if (std.mem.eql(u8, pinned.name, owner.parsed.name)) continue;
            // Only ever up: a pin is a minimum.
            if (pinned.version.order(member.version) != .lt) continue;
            if (!member.looked) {
                member.looked = true;
                // A name is not what a package is: a release of another package of that name is not the member's.
                const release = try releases.find(remote.url, pinned.name, member.version);
                if (release) |found| {
                    if (found.fingerprint == member.fingerprint) member.released = found.dependency else try releases.foreign(pinned.name);
                }
            }
            var to = member.released orelse continue;
            to.name = dependency.name;
            to.lazy = dependency.lazy;
            try list.append(a, .{ .directory = owner.directory, .kind = kind, .from = dependency, .to = to });
        };
    }
    return list.toOwnedSlice(a);
}

/// A package's newest release, and the versions its manifest retracts: as Go
/// reads `retract` from a module's latest version, not from the build graph.
pub const Newest = struct { version: std.SemanticVersion, tag: []const u8, retracted: []const []const u8 };

/// The newest release on the remote `url` names, fetched to read what it
/// retracts; null when the remote has no release.
pub fn newest(io: Io, a: std.mem.Allocator, zig: []const u8, packages: *store.Store, scratch: []const u8, url: []const u8) !?Newest {
    // Only a git remote has tags: an archive URL names one file and nothing newer.
    if (!std.mem.startsWith(u8, url, "git+")) return null;
    const repository = remotes.repository(url) orelse return null;
    // A remote that cannot be read has said why; what it retracts is then not known.
    const listed = remotes.tags(io, a, url) catch |err| switch (err) {
        error.Reported => return null,
        else => |e| return e,
    };
    const found = remotes.newestVersion(listed) orelse return null;
    // Its name is not read; the fetch only needs one.
    const fetched = fetch.fetch(io, a, zig, scratch, try a.print("git+{s}#{s}", .{ repository, found.tag.name }), "release") catch |err| switch (err) {
        error.Reported => return null,
        else => |e| return e,
    };
    const release = fetched orelse {
        try say.note(io, "{s} at {s} is not a package bay can read: what it retracts is not known", .{ repository, found.tag.name });
        return null;
    };
    const place: select.Place.Remote = .{ .url = release.source.remote.url, .hash = release.source.remote.hash };
    const revision = try store.revisionAt(io, a, try packages.directoryOf(place), .{ .remote = place });
    return .{ .version = found.version, .tag = found.tag.name, .retracted = revision.retracted };
}

/// Releases as the remote has them: a tag of the version, fetched by Zig.
/// A member's release as the remote has it, and the fingerprint its manifest names.
pub const Release = struct { dependency: manifest.Dependency, fingerprint: u64 };

const Remote = struct {
    io: Io,
    a: std.mem.Allocator,
    zig: []const u8,
    packages: *store.Store,
    scratch: []const u8,

    fn find(r: *Remote, url: []const u8, name: []const u8, version: std.SemanticVersion) !?Release {
        const repository = remotes.repository(url) orelse return null;
        const tag = remotes.tagOf(try remotes.tags(r.io, r.a, url), version) orelse {
            try say.note(r.io, "{s} {f} is not released yet; its pins stay", .{ name, version });
            return null;
        };
        const dependency = try fetch.fetch(r.io, r.a, r.zig, r.scratch, try r.a.print("git+{s}#{s}", .{ repository, tag.name }), name) orelse
            try say.fail(r.io, "could not fetch {s} at {s}", .{ name, tag.name });
        const place: select.Place.Remote = .{ .url = dependency.source.remote.url, .hash = dependency.source.remote.hash };
        const released = try store.revisionAt(r.io, r.a, try r.packages.directoryOf(place), .{ .remote = place });
        if (released.version.order(version) != .eq)
            try say.fail(r.io, "{s}'s tag {s} holds a manifest of another version: a tag names the version it releases", .{ name, tag.name });
        return .{ .dependency = dependency, .fingerprint = released.identity.fingerprint };
    }

    fn foreign(r: *Remote, name: []const u8) !void {
        try say.note(r.io, "{s}'s release is another package of that name; pins to it stay", .{name});
    }
};

fn read(io: Io, a: std.mem.Allocator, directory: []const u8) !manifest.Manifest {
    const text = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ directory, "build.zig.zon" }), a, .limited(1 << 20));
    return manifest.parse(a, try a.dupeSentinel(u8, text, 0)) catch |err| switch (err) {
        error.InvalidManifest => try say.fail(io, "{s}/build.zig.zon is not a manifest bay can read", .{directory}),
        else => |e| return e,
    };
}

test "a member pinned below its release moves up to it, in either list, never down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hash = struct {
        fn of(comptime name: []const u8, comptime version: []const u8, comptime fill: u8) []const u8 {
            return name ++ "-" ++ version ++ "-" ++ &@as([44]u8, @splat(fill));
        }
    }.of;
    const pin = struct {
        fn of(name: []const u8, h: []const u8) manifest.Dependency {
            return .{ .name = name, .source = .{ .remote = .{ .url = "git+https://example.org/x?ref=v0.1.0#0000", .hash = h } } };
        }
    }.of;
    const Releases = struct {
        asked: usize = 0,
        foreigners: usize = 0,
        fn find(r: *@This(), url: []const u8, name: []const u8, version: std.SemanticVersion) !?Release {
            _ = url;
            r.asked += 1;
            if (std.mem.eql(u8, name, "core") and version.minor == 2) return .{ .dependency = pin("core", hash("core", "0.2.0", 'R')), .fingerprint = 0 };
            // tool 0.3.0 is released, by another package of that name.
            if (std.mem.eql(u8, name, "tool")) return .{ .dependency = pin("tool", hash("tool", "0.3.0", 'X')), .fingerprint = 99 };
            return null;
        }
        fn foreign(r: *@This(), name: []const u8) !void {
            _ = name;
            r.foreigners += 1;
        }
    };
    const core: manifest.Manifest = .{ .name = "core", .version = "0.2.0", .minimum_zig_version = null, .normal = &.{}, .dev = &.{pin("tool", hash("tool", "0.1.0", 'T'))} };
    const tool: manifest.Manifest = .{ .name = "tool", .version = "0.3.0", .minimum_zig_version = null, .normal = &.{pin("core", hash("core", "0.1.0", 'A'))}, .dev = &.{} };
    const app: manifest.Manifest = .{ .name = "app", .version = "1.0.0", .minimum_zig_version = null, .normal = &.{pin("core", hash("core", "0.1.0", 'A'))}, .dev = &.{pin("ahead", hash("core", "0.3.0", 'B'))} };
    var releases: Releases = .{};
    const owners = [_]Owned{ .{ .directory = "core", .parsed = core }, .{ .directory = "tool", .parsed = tool }, .{ .directory = "app", .parsed = app } };
    const pins = try plan(a, &owners, &.{ core, tool, app }, &releases);
    // core 0.1.0 rises to its release in tool and app; tool 0.3.0 is released only by another
    // package of that name, so core's dev pin stays; a pin above the member's version is never lowered.
    try std.testing.expectEqual(2, pins.len);
    try std.testing.expectEqualStrings("tool", pins[0].directory);
    try std.testing.expectEqualStrings("app", pins[1].directory);
    try std.testing.expectEqualStrings(hash("core", "0.2.0", 'R'), pins[1].to.source.remote.hash);
    // Each member's release is looked up once.
    try std.testing.expectEqual(2, releases.asked);
    try std.testing.expectEqual(1, releases.foreigners);
}
