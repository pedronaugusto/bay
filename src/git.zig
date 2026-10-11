//! Repositories Zig's own fetch cannot reach, fetched with the system's git:
//! `git+ssh://`, which git reaches with the keys and agent the person has set
//! up, as Go fetches private modules, and `git+file://`, a repository on disk.
//!
//! The commit's tree is written blob for blob as git stores it, with no
//! line-ending or filter conversion, and `zig fetch` of that directory gives
//! the hash Zig gives the same commit fetched over https and keeps the package
//! in Zig's cache, where every build then finds it. A manifest may pin such a
//! URL like any other: Zig builds it from the cache and never fetches it.
const std = @import("std");
const Io = std.Io;
const say = @import("say.zig");

/// Whether `url` is one bay fetches with git rather than Zig.
pub fn handles(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "git+ssh://") or std.mem.startsWith(u8, url, "git+file://");
}

/// A pinned URL's parts: `git+<repository>?ref=<ref>#<fragment>`.
pub const Parts = struct {
    repository: []const u8,
    ref: ?[]const u8,
    /// A commit, or a ref to resolve when no `?ref=` came with it.
    fragment: ?[]const u8,
};

pub fn parts(url: []const u8) Parts {
    const rest = url["git+".len..];
    const end = std.mem.findAny(u8, rest, "?#") orelse rest.len;
    var result: Parts = .{ .repository = rest[0..end], .ref = null, .fragment = null };
    const hash = std.mem.findScalar(u8, rest, '#');
    if (hash) |at| result.fragment = rest[at + 1 ..];
    if (std.mem.find(u8, rest[0 .. hash orelse rest.len], "?ref=")) |at| result.ref = rest[at + "?ref=".len .. hash orelse rest.len];
    return result;
}

/// What a fetch pinned: the URL as Zig records one, with the ref followed and
/// the commit it named, and the package's hash.
pub const Fetched = struct { url: []const u8, hash: []const u8 };

/// Fetches `url` at its commit into Zig's cache through a directory under
/// `scratch`; the recorded URL names the commit.
pub fn fetch(io: Io, a: std.mem.Allocator, zig: []const u8, scratch: []const u8, url: []const u8) !Fetched {
    const p = parts(url);
    // A commit is taken as it is; a ref is followed to the commit it names now,
    // and recorded as Zig records one.
    var ref: ?[]const u8 = p.ref;
    var commit: []const u8 = undefined;
    if (p.fragment != null and isCommit(p.fragment.?)) {
        commit = p.fragment.?;
    } else {
        if (p.fragment) |fragment| ref = fragment;
        commit = try resolve(io, a, p.repository, ref orelse "HEAD");
    }
    const repository = try std.fs.path.join(a, &.{ scratch, "repository" });
    const tree = try std.fs.path.join(a, &.{ scratch, "tree" });
    try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, tree);
    _ = try git(io, a, null, &.{ "init", "--quiet", "--bare", repository });
    _ = try git(io, a, repository, &.{ "fetch", "--quiet", "--depth", "1", p.repository, commit });
    try checkout(io, a, repository, commit, tree);
    const hashed = std.process.run(a, io, .{ .argv = &.{ zig, "fetch", tree }, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run {s} fetch: {t}", .{ zig, err });
    if (hashed.term != .exited or hashed.term.exited != 0) {
        try say.relay(io, hashed.stderr);
        try say.fail(io, "{s} at {s} is not a package Zig can hash", .{ p.repository, commit });
    }
    try Io.Dir.cwd().deleteTree(io, scratch);
    return .{
        .url = if (ref) |name| try a.print("git+{s}?ref={s}#{s}", .{ p.repository, name, commit }) else try a.print("git+{s}#{s}", .{ p.repository, commit }),
        .hash = try a.dupe(u8, std.mem.trim(u8, hashed.stdout, " \r\n")),
    };
}

/// The repository's tag listing, as `git ls-remote --tags` prints it.
pub fn tagListing(io: Io, a: std.mem.Allocator, url: []const u8) ![]const u8 {
    return git(io, a, null, &.{ "ls-remote", "--tags", parts(url).repository });
}

fn isCommit(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// The commit `ref` names on the remote: a tag's target, a branch's head, or HEAD.
fn resolve(io: Io, a: std.mem.Allocator, repository: []const u8, ref: []const u8) ![]const u8 {
    const listing = try git(io, a, null, &.{ "ls-remote", repository });
    const wanted = [_][]const u8{
        try a.print("refs/tags/{s}^{{}}", .{ref}),
        try a.print("refs/tags/{s}", .{ref}),
        try a.print("refs/heads/{s}", .{ref}),
        ref,
    };
    for (wanted) |name| {
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line[tab + 1 ..], "\r"), name)) return line[0..tab];
        }
    }
    try say.fail(io, "{s} has no ref {s}", .{ repository, ref });
}

/// Writes `commit`'s tree into `into` as git stores it: each blob's bytes, the
/// executable bit, and links; a submodule is no file of the package and is left out.
fn checkout(io: Io, a: std.mem.Allocator, repository: []const u8, commit: []const u8, into: []const u8) !void {
    const listing = try git(io, a, repository, &.{ "ls-tree", "-r", "-z", "--full-tree", commit });
    var out = try Io.Dir.cwd().openDir(io, into, .{});
    defer out.close(io);
    var reader = try Objects.open(io, a, repository);
    // A tree that fails to write ends git with it; one written lets git end as asked.
    write(io, listing, out, reader) catch |err| {
        reader.child.kill(io);
        return err;
    };
    try reader.finish();
}

fn write(io: Io, listing: []const u8, out: Io.Dir, reader: *Objects) !void {
    var entries = std.mem.tokenizeScalar(u8, listing, 0);
    while (entries.next()) |entry| {
        // `<mode> <type> <object>\t<path>`
        const tab = std.mem.findScalar(u8, entry, '\t') orelse return error.UnexpectedGitOutput;
        var fields = std.mem.tokenizeScalar(u8, entry[0..tab], ' ');
        const mode = fields.next() orelse return error.UnexpectedGitOutput;
        _ = fields.next() orelse return error.UnexpectedGitOutput;
        const object = fields.next() orelse return error.UnexpectedGitOutput;
        const path = entry[tab + 1 ..];
        if (std.mem.eql(u8, mode, "160000")) continue;
        const data = try reader.blob(object);
        if (std.fs.path.dirname(path)) |parent| try out.createDirPath(io, parent);
        if (std.mem.eql(u8, mode, "120000")) {
            try out.symLink(io, data, path, .{});
        } else {
            const executable = std.mem.eql(u8, mode, "100755");
            try out.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = if (executable) .executable_file else .default_file } });
        }
    }
}

/// Blobs read through one `git cat-file --batch`, a request and its answer at a time.
const Objects = struct {
    io: Io,
    a: std.mem.Allocator,
    child: std.process.Child,
    in_buffer: [256]u8 = undefined,
    out_buffer: [64 * 1024]u8 = undefined,
    in: Io.File.Writer = undefined,
    out: Io.File.Reader = undefined,

    fn open(io: Io, a: std.mem.Allocator, repository: []const u8) !*Objects {
        const objects = try a.create(Objects);
        objects.* = .{ .io = io, .a = a, .child = try std.process.spawn(io, .{
            .argv = &.{ "git", "-C", repository, "cat-file", "--batch" },
            .stdin = .pipe,
            .stdout = .pipe,
        }) };
        objects.in = objects.child.stdin.?.writerStreaming(io, &objects.in_buffer); // safe: stdin is piped
        objects.out = objects.child.stdout.?.readerStreaming(io, &objects.out_buffer); // safe: stdout is piped
        return objects;
    }

    fn blob(objects: *Objects, object: []const u8) ![]const u8 {
        try objects.in.interface.print("{s}\n", .{object});
        try objects.in.interface.flush();
        // `<object> blob <size>\n<bytes>\n`, each part read as it arrives.
        const reader = &objects.out.interface;
        const header = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\n");
        const space = std.mem.findScalarLast(u8, header, ' ') orelse return error.UnexpectedGitOutput;
        if (std.mem.find(u8, header, " blob ") == null) return error.UnexpectedGitOutput;
        const size = std.fmt.parseUnsigned(usize, header[space + 1 ..], 10) catch return error.UnexpectedGitOutput;
        const data = try objects.a.alloc(u8, size);
        try reader.readSliceAll(data);
        if (try reader.takeByte() != '\n') return error.UnexpectedGitOutput;
        return data;
    }

    /// Ends git once every blob is read: it must have ended as asked.
    fn finish(objects: *Objects) !void {
        objects.child.stdin.?.close(objects.io); // safe: stdin is piped
        objects.child.stdin = null;
        const term = try objects.child.wait(objects.io);
        if (term != .exited or term.exited != 0) return error.GitFailed;
    }
};

/// Runs git, in `directory` when given, and returns its stdout; a failure is
/// reported with what git said.
fn git(io: Io, a: std.mem.Allocator, directory: ?[]const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "git");
    if (directory) |path| try argv.appendSlice(a, &.{ "-C", path });
    try argv.appendSlice(a, args);
    const result = std.process.run(a, io, .{ .argv = argv.items, .stdout_limit = .limited(256 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run git: {t}", .{err});
    if (result.term != .exited or result.term.exited != 0) {
        try say.relay(io, result.stderr);
        try say.fail(io, "git {s} failed", .{args[0]});
    }
    return result.stdout;
}

test "a pinned git URL's repository, ref and commit" {
    const pinned = parts("git+ssh://git@example.org/owner/repo.git?ref=v1.2.0#5d2a92141f0298d76dc5fd602526d55a62b4e11a");
    try std.testing.expectEqualStrings("ssh://git@example.org/owner/repo.git", pinned.repository);
    try std.testing.expectEqualStrings("v1.2.0", pinned.ref.?);
    try std.testing.expect(isCommit(pinned.fragment.?));
    const asked = parts("git+file:///srv/repo#main");
    try std.testing.expectEqualStrings("file:///srv/repo", asked.repository);
    try std.testing.expectEqual(null, asked.ref);
    try std.testing.expectEqualStrings("main", asked.fragment.?);
    try std.testing.expect(handles("git+ssh://git@example.org/a"));
    try std.testing.expect(!handles("git+https://example.org/a"));
}
