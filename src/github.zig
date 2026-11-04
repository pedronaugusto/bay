//! GitHub's REST API as bay uses it: the release a version's tag is published
//! as, with its notes and the programs the package ships. GITHUB_TOKEN
//! authorizes it; GITHUB_API_URL, as GitHub's own runners set it, names another
//! server (GitHub Enterprise, or a test's).
const std = @import("std");
const Io = std.Io;

pub const default_api = "https://api.github.com";

/// The `owner/repo` a remote on github.com names: `git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r`, `https://github.com/o/r`. Null for any other
/// host or shape.
pub fn slug(url: []const u8) ?[]const u8 {
    const path = for ([_][]const u8{ "git@github.com:", "ssh://git@github.com/", "git+ssh://git@github.com/", "https://github.com/", "git+https://github.com/" }) |prefix| {
        if (std.mem.startsWith(u8, url, prefix)) break url[prefix.len..];
    } else return null;
    const bare = std.mem.trimEnd(u8, path[0 .. std.mem.findAny(u8, path, "?#") orelse path.len], "/");
    const named = if (std.mem.endsWith(u8, bare, ".git")) bare[0 .. bare.len - ".git".len] else bare;
    const slash = std.mem.findScalar(u8, named, '/') orelse return null;
    if (slash == 0 or slash == named.len - 1 or std.mem.findScalarPos(u8, named, slash + 1, '/') != null) return null;
    return named;
}

test "a GitHub remote names its repository in each form; another host or a deeper path names none" {
    for ([_][]const u8{ "git@github.com:o/r.git", "git@github.com:o/r", "ssh://git@github.com/o/r", "https://github.com/o/r.git", "git+https://github.com/o/r?ref=v1#abc" }) |url| try std.testing.expectEqualStrings("o/r", slug(url).?);
    for ([_][]const u8{ "git@gitlab.com:o/r.git", "https://github.com/o", "https://github.com/o/r/x", "git@github.com:/r" }) |url| try std.testing.expect(slug(url) == null);
}

/// A program a release carries, under the name a download asks for.
pub const Asset = struct { name: []const u8, bytes: []const u8 };

/// The `SHA256SUMS` a release carries beside its programs: each program's
/// SHA-256 and its name, as `sha256sum` writes and `sha256sum -c` checks,
/// sorted by name.
pub fn sums(a: std.mem.Allocator, assets: []const Asset) ![]const u8 {
    const sorted = try a.dupe(Asset, assets);
    defer a.free(sorted);
    std.mem.sort(Asset, sorted, {}, struct {
        fn less(_: void, x: Asset, y: Asset) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    var out: Io.Writer.Allocating = .init(a);
    for (sorted) |asset| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(asset.bytes, &digest, .{});
        try out.writer.print("{s}  {s}\n", .{ &std.fmt.bytesToHex(digest, .lower), asset.name });
    }
    return out.toOwnedSlice();
}

test "SHA256SUMS lists each program's digest and name, sorted, as sha256sum writes them" {
    const text = try sums(std.testing.allocator, &.{ .{ .name = "b", .bytes = "" }, .{ .name = "a", .bytes = "abc" } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a\n" ++
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  b\n",
        text,
    );
}

pub const Api = struct {
    client: *std.http.Client,
    a: std.mem.Allocator,
    /// The API's base, `https://api.github.com` or GITHUB_API_URL.
    base: []const u8,
    token: []const u8,
};

/// What bay reads of a release GitHub holds.
const Release = struct {
    id: u64,
    upload_url: []const u8,
    html_url: []const u8 = "",
    assets: []const struct { name: []const u8 } = &.{},
};

pub const Error = error{ OutOfMemory, GitHub };

/// What went wrong with a request, for the caller to say.
pub const Problem = struct { what: []const u8 = "" };

/// The release for `tag` in `repository`, made with `notes` where GitHub holds
/// none, and given each of `assets` it does not hold yet: a run that stopped
/// part way is finished, never made twice. Returns the release's page.
pub fn publish(api: Api, repository: []const u8, tag: []const u8, notes: []const u8, assets: []const Asset, problem: *Problem) Error![]const u8 {
    const a = api.a;
    const at_tag = try a.print("{s}/repos/{s}/releases/tags/{s}", .{ api.base, repository, tag });
    const release: Release = found: {
        const held = try request(api, .GET, at_tag, null, "application/json", problem);
        if (held.status == .ok) break :found try parse(a, held.body, at_tag, problem);
        if (held.status != .not_found) return fail(a, problem, "{s} answered {d}: {s}", .{ at_tag, @backingInt(held.status), held.body });
        var body: Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(.{ .tag_name = tag, .name = tag, .body = notes }, .{}, &body.writer) catch return error.OutOfMemory;
        const releases = try a.print("{s}/repos/{s}/releases", .{ api.base, repository });
        const made = try request(api, .POST, releases, body.written(), "application/json", problem);
        if (made.status != .created) return fail(a, problem, "{s} answered {d}: {s}", .{ releases, @backingInt(made.status), made.body });
        break :found try parse(a, made.body, releases, problem);
    };
    // `upload_url` is a URI template: the part before `{?name,label}` takes the name.
    const upload = release.upload_url[0 .. std.mem.findScalar(u8, release.upload_url, '{') orelse release.upload_url.len];
    for (assets) |asset| {
        const held = for (release.assets) |one| {
            if (std.mem.eql(u8, one.name, asset.name)) break true;
        } else false;
        if (held) continue;
        if (!safeName(asset.name)) return fail(a, problem, "{s} is no name a release asset can take", .{asset.name});
        const url = try a.print("{s}?name={s}", .{ upload, asset.name });
        const sent = try request(api, .POST, url, asset.bytes, "application/octet-stream", problem);
        if (sent.status != .created) return fail(a, problem, "uploading {s} answered {d}: {s}", .{ asset.name, @backingInt(sent.status), sent.body });
    }
    return release.html_url;
}

/// A name of letters, digits, `.`, `-` and `_`: one that needs no escaping in a
/// query, as `zig build dist`'s programs and SHA256SUMS are.
fn safeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn parse(a: std.mem.Allocator, body: []const u8, url: []const u8, problem: *Problem) Error!Release {
    return std.json.parseFromSliceLeaky(Release, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(a, problem, "{s} answered a release bay cannot read", .{url}),
    };
}

fn fail(a: std.mem.Allocator, problem: *Problem, comptime format: []const u8, args: anytype) Error {
    problem.what = try a.print(format, args);
    return error.GitHub;
}

const Answer = struct { status: std.http.Status, body: []const u8 };

/// One request with the token and GitHub's media type; the answer's body is
/// kept up to 1 MiB, which is all a release's JSON or an error says.
fn request(api: Api, method: std.http.Method, url: []const u8, payload: ?[]const u8, content_type: []const u8, problem: *Problem) Error!Answer {
    const a = api.a;
    var body: Io.Writer.Allocating = .init(a);
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/vnd.github+json" },
        .{ .name = "x-github-api-version", .value = "2022-11-28" },
    };
    const result = api.client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = content_type }, .user_agent = .{ .override = "bay" }, .authorization = .{ .override = try a.print("Bearer {s}", .{api.token}) } },
        .extra_headers = &headers,
        // A redirect is answered, not followed: the token goes only to the host asked.
        .redirect_behavior = .unhandled,
        .response_writer = &body.writer,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, problem, "could not reach {s}: {t}", .{ url, err }),
    };
    const written = body.written();
    return .{ .status = result.status, .body = written[0..@min(written.len, 1 << 20)] };
}
