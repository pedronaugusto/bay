//! An upstream pinned with no manifest, as a C library's repository or a set of
//! headers is: Zig names it by its hash alone (`N-V-…`), with no name and no
//! version. bay knows it by the key that pins it and by its URL, the repository
//! and the tag that URL names. `outdated`, `audit`, `licenses` and `tree` read it
//! here, so they agree.
const std = @import("std");
const select = @import("select.zig");
const store = @import("store.zig");
const remotes = @import("remote.zig");
const git = @import("git.zig");

/// What a pinned URL says of the repository it comes from.
pub const Upstream = struct {
    /// A URL `remote.tags` lists: the pin's own git URL, or the repository a GitHub archive comes from.
    tags: ?[]const u8 = null,
    /// `owner/repo` on github.com, whose advisories `bay audit` reads.
    github: ?[]const u8 = null,
    /// The tag the URL names: its `?ref=`, or the archive's or release asset's tag.
    tag: ?[]const u8 = null,
};

/// The repository and tag of a pinned URL: a git URL's `?ref=`, or a GitHub
/// `archive/refs/tags/<tag>` archive or `releases/download/<tag>/` asset. Another
/// URL names neither.
pub fn of(a: std.mem.Allocator, url: []const u8) !Upstream {
    if (std.mem.startsWith(u8, url, "git+")) {
        const parts = git.parts(url);
        return .{ .tags = url, .github = github(parts.repository), .tag = parts.ref };
    }
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, url, prefix)) return .{};
    const path = url[prefix.len .. std.mem.findAny(u8, url, "?#") orelse url.len];
    var steps = std.mem.splitScalar(u8, path, '/');
    const owner = steps.first();
    const repo = steps.next() orelse return .{};
    if (owner.len == 0 or repo.len == 0) return .{};
    const slug = path[0 .. owner.len + 1 + repo.len];
    const rest = steps.rest();
    return .{ .tags = try a.print("git+https://github.com/{s}", .{slug}), .github = slug, .tag = archiveTag(rest) orelse assetTag(rest) };
}

/// The tag of `archive/refs/tags/<tag>.tar.gz` or `.zip`, as GitHub serves a tag's tree.
fn archiveTag(rest: []const u8) ?[]const u8 {
    const prefix = "archive/refs/tags/";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    const file = rest[prefix.len..];
    for ([_][]const u8{ ".tar.gz", ".zip" }) |extension| {
        if (std.mem.endsWith(u8, file, extension) and file.len > extension.len) return file[0 .. file.len - extension.len];
    }
    return null;
}

/// The tag of `releases/download/<tag>/<file>`, a release's asset.
fn assetTag(rest: []const u8) ?[]const u8 {
    const prefix = "releases/download/";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    const tail = rest[prefix.len..];
    const slash = std.mem.findScalar(u8, tail, '/') orelse return null;
    return if (slash == 0) null else tail[0..slash];
}

/// `owner/repo` of a github.com repository URL; null for another host or path.
pub fn github(repository: []const u8) ?[]const u8 {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, repository, prefix)) return null;
    var path = std.mem.trimEnd(u8, repository[prefix.len..], "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    if (std.mem.countScalar(u8, path, '/') != 1 or path[0] == '/' or path[path.len - 1] == '/') return null;
    return path;
}

/// The key each nameless place is pinned under, read from every revision's pins:
/// Zig's hash for it names nothing. The first key read stands for the place.
pub fn keys(a: std.mem.Allocator, graph: select.Graph) !std.array_hash_map.String([]const u8) {
    var found: std.array_hash_map.String([]const u8) = .empty;
    for ([_][]const select.Revision{ graph.mains.values(), graph.selected.values() }) |revisions| for (revisions) |revision| for (revision.pins) |pin| {
        const remote = switch (pin.place) {
            .remote => |remote| remote,
            .directory => continue,
        };
        if (!store.unnamed(remote.hash)) continue;
        const entry = try found.getOrPut(a, remote.hash);
        if (!entry.found_existing) entry.value_ptr.* = pin.key;
    };
    return found;
}

/// How a nameless pin is shown: its key, and the tag its URL names.
pub fn label(a: std.mem.Allocator, key: []const u8, url: []const u8) ![]const u8 {
    const tag = (try of(a, url)).tag orelse return key;
    return a.print("{s} {s}", .{ key, tag });
}

/// A tag read as numbers: what comes before its first digit (`v`, `VER-`), then
/// numbers joined by one separator, `.`, `-` or `_`, as upstreams tag releases
/// (`v1.15`, `VER-2-13-3`, `10.1.0`). A tag with anything after its numbers
/// (`v1.2.0-rc1`) is no release.
pub const Numbered = struct {
    prefix: []const u8,
    separator: u8,
    numbers: [4]u32,
    count: usize,

    /// Whether two tags are named alike: the same prefix and separator, a tag of one number agreeing with any.
    fn alike(x: Numbered, y: Numbered) bool {
        return std.mem.eql(u8, x.prefix, y.prefix) and (x.separator == y.separator or x.count == 1 or y.count == 1);
    }

    /// Their numbers in order, a missing one 0: `v1.15` is `v1.15.0`.
    fn order(x: Numbered, y: Numbered) std.math.Order {
        for (0..x.numbers.len) |i| {
            const o = std.math.order(if (i < x.count) x.numbers[i] else 0, if (i < y.count) y.numbers[i] else 0);
            if (o != .eq) return o;
        }
        return .eq;
    }
};

pub fn numbered(tag: []const u8) ?Numbered {
    const start = std.mem.findAny(u8, tag, "0123456789") orelse return null;
    var result: Numbered = .{ .prefix = tag[0..start], .separator = '.', .numbers = @splat(0), .count = 0 };
    var rest = tag[start..];
    while (true) {
        const end = std.mem.findNone(u8, rest, "0123456789") orelse rest.len;
        if (end == 0 or result.count == result.numbers.len) return null;
        result.numbers[result.count] = std.fmt.parseUnsigned(u32, rest[0..end], 10) catch return null;
        result.count += 1;
        if (end == rest.len) return result;
        const separator = rest[end];
        if (std.mem.findScalar(u8, ".-_", separator) == null) return null;
        if (result.count > 1 and separator != result.separator) return null;
        result.separator = separator;
        rest = rest[end + 1 ..];
    }
}

/// The newest tag named as `pinned` is, when it is newer than `pinned`; null when
/// none is. `pinned` must be `numbered`.
pub fn newer(pinned: []const u8, listed: []const remotes.Tag) ?[]const u8 {
    const at = numbered(pinned).?; // safe: callers check that the pinned tag is numbered
    var newest = at;
    var name: ?[]const u8 = null;
    for (listed) |tag| {
        const candidate = numbered(tag.name) orelse continue;
        if (!candidate.alike(at) or candidate.order(newest) != .gt) continue;
        newest = candidate;
        name = tag.name;
    }
    return name;
}

/// The semantic version a tag names, for an advisory's range: up to three numbers, a missing one 0.
pub fn version(tag: []const u8) ?std.SemanticVersion {
    const n = numbered(tag) orelse return null;
    if (n.count > 3) return null;
    return .{ .major = n.numbers[0], .minor = n.numbers[1], .patch = n.numbers[2] };
}

const testing = std.testing;

test "a pinned URL names its repository and tag: a git ref, a GitHub archive or release asset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archive = try of(a, "https://github.com/microsoft/DirectX-Headers/archive/refs/tags/v1.619.5.tar.gz");
    try testing.expectEqualStrings("git+https://github.com/microsoft/DirectX-Headers", archive.tags.?);
    try testing.expectEqualStrings("microsoft/DirectX-Headers", archive.github.?);
    try testing.expectEqualStrings("v1.619.5", archive.tag.?);
    try testing.expectEqualStrings("VER-2-13-3", (try of(a, "https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-3.zip")).tag.?);
    try testing.expectEqualStrings("v5.2.0", (try of(a, "https://github.com/jrouwe/JoltPhysics/releases/download/v5.2.0/source.tar.gz")).tag.?);
    const pinned = try of(a, "git+https://github.com/KhronosGroup/Vulkan-Headers?ref=v1.4.367#9fbc2a78");
    try testing.expectEqualStrings("git+https://github.com/KhronosGroup/Vulkan-Headers?ref=v1.4.367#9fbc2a78", pinned.tags.?);
    try testing.expectEqualStrings("KhronosGroup/Vulkan-Headers", pinned.github.?);
    try testing.expectEqualStrings("v1.4.367", pinned.tag.?);
    // A commit's archive names no tag, though its repository is known.
    const commit = try of(a, "https://github.com/jkuhlmann/cgltf/archive/360db1a95480fe102ae9c69b27c5d101167ff5ba.tar.gz");
    try testing.expectEqualStrings("jkuhlmann/cgltf", commit.github.?);
    try testing.expectEqual(null, commit.tag);
    try testing.expectEqual(null, (try of(a, "git+https://codeberg.org/o/r#abc")).github);
    try testing.expectEqual(null, (try of(a, "https://example.org/r-1.0.tar.gz")).tags);
    try testing.expectEqual(null, (try of(a, "https://github.com/o")).tags);
    try testing.expectEqualStrings("directx_headers v1.619.5", try label(a, "directx_headers", "https://github.com/microsoft/DirectX-Headers/archive/refs/tags/v1.619.5.tar.gz"));
    try testing.expectEqualStrings("blob", try label(a, "blob", "https://example.org/blob.tar.gz"));
}

test "an upstream's newest tag is the newest named as its pinned one is, a pre-release never" {
    const listed = [_]remotes.Tag{
        .{ .name = "v1.619.5", .commit = "" },
        .{ .name = "v1.620.1", .commit = "" },
        .{ .name = "v1.620.0", .commit = "" },
        .{ .name = "v1.621.0-rc1", .commit = "" },
        .{ .name = "sdk-2.0.0", .commit = "" },
        .{ .name = "nightly", .commit = "" },
    };
    try testing.expectEqualStrings("v1.620.1", newer("v1.619.5", &listed).?);
    try testing.expectEqual(null, newer("v1.620.1", &listed));
    // cgltf's two numbers, FreeType's dashes.
    try testing.expectEqualStrings("v1.15.1", newer("v1.15", &.{ .{ .name = "v1.14", .commit = "" }, .{ .name = "v1.15.1", .commit = "" } }).?);
    try testing.expectEqualStrings("VER-2-14-0", newer("VER-2-13-3", &.{ .{ .name = "VER-2-14-0", .commit = "" }, .{ .name = "VER-2-9", .commit = "" }, .{ .name = "v3.0.0", .commit = "" } }).?);
    try testing.expectEqual(null, numbered("nightly"));
    try testing.expectEqual(null, numbered("v1.2.0-rc1"));
    try testing.expectEqual(null, numbered("v1.2-3"));
    try testing.expectEqual(null, numbered("v1..2"));
    try testing.expectEqual(null, numbered("v99999999999"));
    try testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 15, .patch = 0 }, version("v1.15").?);
    try testing.expectEqual(null, version("1.2.3.4"));
}
