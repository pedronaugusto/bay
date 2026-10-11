//! A git remote's tags, read as git reads them over smart HTTP: the ref
//! advertisement that `GET <repo>/info/refs?service=git-upload-pack` answers,
//! in pkt-lines. Nothing is cloned or fetched beyond that listing.
const std = @import("std");
const Io = std.Io;
const download = @import("download.zig");
const say = @import("say.zig");
const select = @import("select.zig");

pub const Tag = struct {
    /// The name after `refs/tags/`.
    name: []const u8,
    /// The object id in hex: an annotated tag's target (its peeled `^{}`
    /// entry), a lightweight tag's own.
    commit: []const u8,
};

/// The tags of the repository `url` names, in the order the remote lists them.
/// `url` is any form bay pins: `git+https://host/owner/repo?ref=x#commit`,
/// `git+https://host/owner/repo#commit`, or a plain `https://` URL.
pub fn tags(io: Io, a: std.mem.Allocator, url: []const u8) ![]const Tag {
    const repo = repository(url) orelse try say.fail(io, "{s} is not a git+https URL", .{url});
    const refs_url = try a.print("{s}/info/refs?service=git-upload-pack", .{repo});
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const body = try download.getAlloc(&client, a, refs_url, 64 << 20);
    return parse(a, body) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidAdvertisement => try say.fail(io, "{s} did not answer as a smart HTTP git server", .{repo}),
    };
}

/// The repository a pinned URL names: `git+` dropped, and the query (`?ref=`)
/// and fragment (`#commit`) after it. Null for anything but http(s) with a host.
pub fn repository(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "git+")) url["git+".len..] else url;
    if (!std.mem.startsWith(u8, rest, "https://") and !std.mem.startsWith(u8, rest, "http://")) return null;
    const repo = std.mem.trimEnd(u8, rest[0 .. std.mem.findAny(u8, rest, "?#") orelse rest.len], "/");
    const uri = std.Uri.parse(repo) catch return null;
    const host = uri.host orelse return null;
    if (host.isEmpty()) return null;
    return repo;
}

pub const ParseError = error{ InvalidAdvertisement, OutOfMemory };

/// The tags in a ref advertisement: the service line and a flush, then one
/// pkt-line per ref, `<id> <ref>`, the first carrying capabilities after a NUL,
/// and an annotated tag followed by `<id> <ref>^{}`, the object it peels to.
/// The list is allocated with `a`; its strings point into `body`.
pub fn parse(a: std.mem.Allocator, body: []const u8) ParseError![]const Tag {
    var rest = body;
    const service = try packet(&rest) orelse return error.InvalidAdvertisement;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, service, "\n"), "# service=git-upload-pack")) return error.InvalidAdvertisement;
    if (try packet(&rest) != null) return error.InvalidAdvertisement;
    var list: std.ArrayList(Tag) = .empty;
    errdefer list.deinit(a);
    var peeled: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer peeled.deinit(a);
    while (try packet(&rest)) |data| {
        var text = std.mem.trimEnd(u8, data, "\n");
        if (std.mem.findScalar(u8, text, 0)) |capabilities| text = text[0..capabilities];
        // Protocol v1 says so first; its listing is v0's.
        if (std.mem.eql(u8, text, "version 1")) continue;
        const space = std.mem.findScalar(u8, text, ' ') orelse return error.InvalidAdvertisement;
        const id = text[0..space];
        if (!objectId(id)) return error.InvalidAdvertisement;
        const ref = text[space + 1 ..];
        if (!std.mem.startsWith(u8, ref, "refs/tags/")) continue;
        const name = ref["refs/tags/".len..];
        if (std.mem.endsWith(u8, name, "^{}"))
            try peeled.put(a, name[0 .. name.len - "^{}".len], id)
        else
            try list.append(a, .{ .name = name, .commit = id });
    }
    if (rest.len != 0) return error.InvalidAdvertisement;
    for (list.items) |*tag| if (peeled.get(tag.name)) |target| {
        tag.commit = target;
    };
    return list.toOwnedSlice(a);
}

/// The next pkt-line's data, or null at a flush (`0000`); `rest` moves past it.
fn packet(rest: *[]const u8) error{InvalidAdvertisement}!?[]const u8 {
    if (rest.len < 4) return error.InvalidAdvertisement;
    const length = std.fmt.parseUnsigned(u16, rest.*[0..4], 16) catch return error.InvalidAdvertisement;
    if (length == 0) {
        rest.* = rest.*[4..];
        return null;
    }
    // 1 to 3 are v2's delimiters, which a v0 listing has none of.
    if (length < 4 or length > rest.len) return error.InvalidAdvertisement;
    const data = rest.*[4..length];
    rest.* = rest.*[length..];
    return data;
}

/// A SHA-1 or SHA-256 object id in lowercase hex.
fn objectId(id: []const u8) bool {
    if (id.len != 40 and id.len != 64) return false;
    for (id) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub const Newest = struct { tag: Tag, version: std.SemanticVersion };

/// The tag naming the highest semantic version, with or without a leading
/// `v`. A release is newer than every pre-release, as Go's `latest` takes it:
/// a pre-release is newest only where there is no release. Null when no tag is
/// a version.
pub fn newestVersion(list: []const Tag) ?Newest {
    return newestWhere(list, null);
}

/// The newest version on `line`'s line (`sameLine`), as `newestVersion` picks one.
pub fn newestOnLine(list: []const Tag, line: std.SemanticVersion) ?Newest {
    return newestWhere(list, line);
}

/// The tag that names `version` exactly, with or without a leading `v`.
pub fn tagOf(list: []const Tag, version: std.SemanticVersion) ?Tag {
    for (list) |tag| {
        const named = versionOf(tag) orelse continue;
        if (named.order(version) == .eq) return tag;
    }
    return null;
}

/// The version a tag names: `v1.2.0` or `1.2.0`; null for any other tag.
pub fn versionOf(tag: Tag) ?std.SemanticVersion {
    const text = if (std.mem.startsWith(u8, tag.name, "v")) tag.name[1..] else tag.name;
    return std.SemanticVersion.parse(text) catch null;
}

fn newestWhere(list: []const Tag, line: ?std.SemanticVersion) ?Newest {
    var newest: ?Newest = null;
    var newest_release: ?Newest = null;
    for (list) |tag| {
        const version = versionOf(tag) orelse continue;
        if (line) |wanted| if (!select.sameLine(version, wanted)) continue;
        const candidate: Newest = .{ .tag = tag, .version = version };
        if (newest == null or version.order(newest.?.version) == .gt) newest = candidate;
        if (version.pre == null and (newest_release == null or version.order(newest_release.?.version) == .gt)) newest_release = candidate;
    }
    return newest_release orelse newest;
}

const testing = std.testing;

/// Part of what github.com/jedisct1/minisign's info/refs answered on
/// 2026-10-11, each pkt-line as it came: the service line, HEAD with its
/// capabilities, a branch, and three annotated tags with their peeled entries.
const recorded =
    "001e# service=git-upload-pack\n" ++
    "0000" ++
    "015bb6de4fe31b4c519887cef8b080eb1816b18795ae HEAD\x00multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed allow-tip-sha1-in-want allow-reachable-sha1-in-want no-done symref=HEAD:refs/heads/master filter object-format=sha1 agent=git/github-e0611d5c1305-Linux\n" ++
    "003fb6de4fe31b4c519887cef8b080eb1816b18795ae refs/heads/master\n" ++
    "003b3731e5c84b07a0b2174342d7d041492e1484200a refs/tags/0.1\n" ++
    "003e7ff02530f810f2138866b089b807d6e5b6bc41d7 refs/tags/0.1^{}\n" ++
    "003c03ebc0dafb08a77e0548e9cbc4668a3588128de5 refs/tags/0.12\n" ++
    "003fb85e15d45ac9eab34e44596fd309f5b07db9545c refs/tags/0.12^{}\n" ++
    "003d80df910969e193e0cde7cf8871fb55f7f4ffae89 refs/tags/0.7.4\n" ++
    "0040709fed6b739422f62dafce048669430fbc956770 refs/tags/0.7.4^{}\n" ++
    "0000";

/// A pkt-line of `data`, its length in four hex digits first.
fn pkt(comptime data: []const u8) []const u8 {
    return std.fmt.comptimePrint("{x:0>4}", .{data.len + 4}) ++ data;
}

test "a recorded advertisement gives each tag and the commit an annotated one peels to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), recorded);
    try testing.expectEqual(3, list.len);
    try testing.expectEqualStrings("0.1", list[0].name);
    try testing.expectEqualStrings("7ff02530f810f2138866b089b807d6e5b6bc41d7", list[0].commit);
    try testing.expectEqualStrings("0.7.4", list[2].name);
    try testing.expectEqualStrings("709fed6b739422f62dafce048669430fbc956770", list[2].commit);
}

test "a lightweight tag is its own commit; v1 and SHA-256 listings read the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sha256: [64]u8 = @splat('c');
    const body = comptime pkt("# service=git-upload-pack\n") ++ "0000" ++ pkt("version 1\n") ++
        pkt(sha256 ++ " HEAD\x00object-format=sha256\n") ++ pkt(sha256 ++ " refs/tags/v1.2.0\n") ++ "0000";
    const list = try parse(arena.allocator(), body);
    try testing.expectEqual(1, list.len);
    try testing.expectEqualStrings("v1.2.0", list[0].name);
    try testing.expectEqualStrings(&sha256, list[0].commit);
    // An empty repository advertises no refs, only its capabilities.
    try testing.expectEqual(0, (try parse(arena.allocator(), comptime pkt("# service=git-upload-pack\n") ++ "0000" ++ pkt(@as([40]u8, @splat('0')) ++ " capabilities^{}\x00agent=git\n") ++ "0000")).len);
}

test "what is not a smart HTTP listing is refused" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidAdvertisement, parse(a, "<!DOCTYPE html><html>"));
    try testing.expectError(error.InvalidAdvertisement, parse(a, ""));
    try testing.expectError(error.InvalidAdvertisement, parse(a, recorded[0 .. recorded.len - 10]));
    try testing.expectError(error.InvalidAdvertisement, parse(a, comptime pkt("# service=git-upload-pack\n") ++ "0000" ++ pkt("not-an-id refs/tags/v1\n") ++ "0000"));
    try testing.expectError(error.InvalidAdvertisement, parse(a, recorded ++ "trailing"));
}

test "a pinned URL names its repository" {
    try testing.expectEqualStrings("https://github.com/pedronaugusto/aegis", repository("git+https://github.com/pedronaugusto/aegis?ref=main#5d2a92141f0298d76dc5fd602526d55a62b4e11a").?);
    try testing.expectEqualStrings("https://github.com/pedronaugusto/aegis", repository("git+https://github.com/pedronaugusto/aegis#5d2a92141f0298d76dc5fd602526d55a62b4e11a").?);
    try testing.expectEqualStrings("https://example.org/x.git", repository("https://example.org/x.git/").?);
    try testing.expectEqualStrings("http://example.org/x", repository("git+http://example.org/x").?);
    try testing.expectEqual(null, repository("git+ssh://example.org/x"));
    try testing.expectEqual(null, repository("git+https://"));
    try testing.expectEqual(null, repository("../a/directory"));
}

test "the newest version is the highest release, a pre-release only when there is none" {
    const at = struct {
        fn tag(name: []const u8) Tag {
            return .{ .name = name, .commit = &@as([40]u8, @splat('0')) };
        }
    }.tag;
    const list = [_]Tag{ at("v0.9.0"), at("0.10.0"), at("v0.10.1-rc.1"), at("latest"), at("v0.2"), at("v0.10.0-rc.2") };
    try testing.expectEqualStrings("0.10.0", newestVersion(&list).?.tag.name);
    try testing.expectEqual(10, newestVersion(&list).?.version.minor);
    const pre = [_]Tag{ at("v1.0.0-rc.1"), at("v1.0.0-rc.10"), at("v1.0.0-rc.2") };
    try testing.expectEqualStrings("v1.0.0-rc.10", newestVersion(&pre).?.tag.name);
    try testing.expectEqual(null, newestVersion(&[_]Tag{ at("latest"), at("0.1") }));
    try testing.expectEqual(null, newestVersion(&.{}));
}

test "the newest on a line stays on it; a version's tag is found with or without v" {
    const at = struct {
        fn tag(name: []const u8) Tag {
            return .{ .name = name, .commit = &@as([40]u8, @splat('0')) };
        }
    }.tag;
    const list = [_]Tag{ at("v0.2.0"), at("v0.2.3"), at("v0.3.0"), at("1.4.0"), at("v1.9.2"), at("v2.0.0") };
    try testing.expectEqualStrings("v0.2.3", newestOnLine(&list, .{ .major = 0, .minor = 2, .patch = 0 }).?.tag.name);
    try testing.expectEqualStrings("v1.9.2", newestOnLine(&list, .{ .major = 1, .minor = 0, .patch = 0 }).?.tag.name);
    try testing.expectEqual(null, newestOnLine(&list, .{ .major = 0, .minor = 1, .patch = 0 }));
    try testing.expectEqualStrings("1.4.0", tagOf(&list, .{ .major = 1, .minor = 4, .patch = 0 }).?.name);
    try testing.expectEqual(null, tagOf(&list, .{ .major = 1, .minor = 4, .patch = 1 }));
}
