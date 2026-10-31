//! `bay audit`: what is known to be wrong with the packages a build selects.
//! Each package's published security advisories, read from its repository's
//! forge, matched against the version selected; and a version the package's
//! newest release retracts. Exits non-zero on any finding, so CI can gate on it.
const std = @import("std");
const Io = std.Io;
const resolve = @import("resolve.zig");
const remotes = @import("remote.zig");
const published = @import("published.zig");
const download = @import("download.zig");
const say = @import("say.zig");
const store = @import("store.zig");
const upstream = @import("upstream.zig");

/// One advisory as GitHub publishes it for a repository; the fields bay reads.
const Advisory = struct {
    ghsa_id: []const u8,
    summary: []const u8 = "",
    severity: ?[]const u8 = null,
    state: []const u8 = "published",
    html_url: []const u8 = "",
    vulnerabilities: []const Vulnerability = &.{},
};

const Vulnerability = struct {
    vulnerable_version_range: ?[]const u8 = null,
    patched_versions: ?[]const u8 = null,
};

/// Whether every package the build selects is clear: no published advisory
/// whose range holds its version, and no version its newest release retracts.
/// A package with no manifest is matched by the tag its URL names, its advisories
/// read from the repository that URL comes from (`upstream.zig`), as a package's
/// pinned by a GitHub archive are. `token` (GITHUB_TOKEN) lifts GitHub's
/// unauthenticated rate limit and reaches private repositories' advisories.
pub fn audit(r: resolve.Resolution, token: ?[]const u8) !bool {
    const a = r.input.a;
    const io = r.input.io;
    const scratch = try std.fs.path.join(a, &.{ r.input.package, ".zig-cache", "bay", "add" });
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const named = try upstream.keys(a, r.graph);
    var findings: usize = 0;
    var unread: std.ArrayList([]const u8) = .empty;
    var unmatched: std.ArrayList([]const u8) = .empty;
    for (r.graph.selected.values()) |selected| {
        const remote = switch (selected.place) {
            .remote => |remote| remote,
            .directory => continue,
        };
        const from = try upstream.of(a, remote.url);
        const unnamed = store.unnamed(remote.hash);
        const name = if (unnamed) named.get(remote.hash) orelse remote.hash else selected.identity.name;
        // A package with no manifest has no version but the tag its URL names, and no
        // release that could retract it.
        const version = if (!unnamed) selected.version else if (from.tag) |tag| upstream.version(tag) orelse {
            try unmatched.append(a, try a.print("{s} (its tag {s} is not a version)", .{ name, tag }));
            continue;
        } else {
            try unmatched.append(a, try a.print("{s} (its URL names no tag)", .{name}));
            continue;
        };
        const shown = if (unnamed) try upstream.label(a, name, remote.url) else try a.print("{s} {f}", .{ name, version });
        if (!unnamed) if (try published.newest(io, a, r.input.zig, r.store, scratch, remote.url)) |latest| {
            if (remotes.isRetracted(latest.retracted, version)) {
                findings += 1;
                try say.out(io, "{s}: retracted by its release {f}\n", .{ shown, latest.version });
            }
        };
        const api = try githubApi(a, from.github orelse {
            try unread.append(a, name);
            continue;
        });
        var body: Io.Writer.Allocating = .init(a);
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(a, .{ .name = "accept", .value = "application/vnd.github+json" });
        if (token) |t| try headers.append(a, .{ .name = "authorization", .value = try a.print("Bearer {s}", .{t}) });
        _ = try download.getWith(&client, api, &body.writer, 8 << 20, headers.items);
        const advisories = std.json.parseFromSliceLeaky([]const Advisory, a, body.written(), .{ .ignore_unknown_fields = true }) catch
            try say.fail(io, "{s} answered advisories bay cannot read", .{api});
        for (advisories) |advisory| {
            if (!std.mem.eql(u8, advisory.state, "published")) continue;
            for (advisory.vulnerabilities) |vulnerability| {
                if (!try affected(vulnerability.vulnerable_version_range, version)) continue;
                findings += 1;
                try say.out(io, "{s}: {s} ({s}) {s}\n", .{ shown, advisory.ghsa_id, advisory.severity orelse "unrated", advisory.summary });
                if (vulnerability.patched_versions) |patched| try say.out(io, "    patched: {s}\n", .{patched});
                if (advisory.html_url.len != 0) try say.out(io, "    {s}\n", .{advisory.html_url});
                break;
            }
        }
    }
    if (unread.items.len != 0) try say.note(io, "advisories are read from GitHub; not read for {s}", .{try std.mem.join(a, ", ", unread.items)});
    if (unmatched.items.len != 0) try say.note(io, "no version to match advisories against: {s}", .{try std.mem.join(a, "; ", unmatched.items)});
    if (findings == 0) try say.note(io, "no advisory or retraction holds a selected version", .{});
    return findings == 0;
}

/// GitHub's advisories URL for the repository `owner/repo` on github.com.
fn githubApi(a: std.mem.Allocator, slug: []const u8) ![]const u8 {
    return a.print("https://api.github.com/repos/{s}/security-advisories?per_page=100", .{slug});
}

/// Whether `version` lies in a GitHub version range: constraints joined by
/// commas, each `<`, `<=`, `>`, `>=` or `=` and a version, a leading `v`
/// allowed. A missing range holds every version.
fn affected(range: ?[]const u8, version: std.SemanticVersion) error{InvalidRange}!bool {
    const text = range orelse return true;
    var constraints = std.mem.tokenizeScalar(u8, text, ',');
    while (constraints.next()) |raw| {
        const c = std.mem.trim(u8, raw, " ");
        if (c.len == 0) continue;
        const op_len: usize = if (c.len > 1 and (c[1] == '=')) 2 else if (c[0] == '<' or c[0] == '>' or c[0] == '=') 1 else 0;
        const op = c[0..op_len];
        var spelled = std.mem.trim(u8, c[op_len..], " ");
        if (spelled.len != 0 and spelled[0] == 'v') spelled = spelled[1..];
        const bound = std.SemanticVersion.parse(spelled) catch return error.InvalidRange;
        const order = version.order(bound);
        const holds = if (op.len == 0 or std.mem.eql(u8, op, "=")) order == .eq else if (std.mem.eql(u8, op, "<")) order == .lt else if (std.mem.eql(u8, op, "<=")) order != .gt else if (std.mem.eql(u8, op, ">")) order == .gt else if (std.mem.eql(u8, op, ">=")) order != .lt else return error.InvalidRange;
        if (!holds) return false;
    }
    return true;
}

test "a version is affected when every constraint of the range holds" {
    const v = try std.SemanticVersion.parse("1.2.3");
    try std.testing.expect(try affected("< 1.2.4", v));
    try std.testing.expect(!try affected("< 1.2.3", v));
    try std.testing.expect(try affected(">= 1.0.0, < 1.3.0", v));
    try std.testing.expect(!try affected(">= 1.2.4, < 2.0.0", v));
    try std.testing.expect(try affected("= 1.2.3", v));
    try std.testing.expect(try affected("<= v1.2.3", v));
    try std.testing.expect(!try affected("> 1.2.3", v));
    try std.testing.expect(try affected(null, v));
    try std.testing.expectError(error.InvalidRange, affected("~> 1.2", v));
}

test "advisories are read for github.com repositories only, an archive's from the repository it comes from" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const api = struct {
        fn of(arena_: std.mem.Allocator, url: []const u8) !?[]const u8 {
            return try githubApi(arena_, (try upstream.of(arena_, url)).github orelse return null);
        }
    }.of;
    try std.testing.expectEqualStrings("https://api.github.com/repos/o/r/security-advisories?per_page=100", (try api(a, "git+https://github.com/o/r.git#abc")).?);
    try std.testing.expectEqualStrings("https://api.github.com/repos/microsoft/DirectX-Headers/security-advisories?per_page=100", (try api(a, "https://github.com/microsoft/DirectX-Headers/archive/refs/tags/v1.619.5.tar.gz")).?);
    try std.testing.expectEqual(null, try api(a, "git+https://codeberg.org/o/r#abc"));
    try std.testing.expectEqual(null, try api(a, "git+https://github.com/o/r/tree/main#abc"));
}

test "GitHub's advisory listing is read, unknown fields left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\[{"ghsa_id":"GHSA-xxxx-yyyy-zzzz","summary":"A parser overflows","severity":"high","state":"published",
        \\  "html_url":"https://github.com/o/r/security/advisories/GHSA-xxxx-yyyy-zzzz","cwe_ids":["CWE-787"],
        \\  "vulnerabilities":[{"package":{"ecosystem":"other","name":"r"},"vulnerable_version_range":"< 0.4.1","patched_versions":"0.4.1"}]}]
    ;
    const advisories = try std.json.parseFromSliceLeaky([]const Advisory, arena.allocator(), body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(1, advisories.len);
    try std.testing.expect(try affected(advisories[0].vulnerabilities[0].vulnerable_version_range, try std.SemanticVersion.parse("0.4.0")));
    try std.testing.expect(!try affected(advisories[0].vulnerabilities[0].vulnerable_version_range, try std.SemanticVersion.parse("0.4.1")));
}
