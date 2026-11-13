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
const aegis = @import("aegis");
const intake = @import("intake.zig");
const Io = std.Io;
const say = @import("say.zig");
const tree = @import("tree.zig");

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
    const files = try std.fs.path.join(a, &.{ scratch, "tree" });
    try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, files);
    _ = try git(io, a, null, &.{ "init", "--quiet", "--bare", repository });
    _ = try git(io, a, repository, &.{ "fetch", "--quiet", "--depth", "1", p.repository, commit });
    try checkout(io, a, repository, commit, files);
    const hashed = intake.run(a, io, .{ .argv = &.{ zig, "fetch", files }, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run {s} fetch: {t}", .{ zig, err });
    if (hashed.term != .exited or hashed.term.exited != 0) {
        try say.relay(io, hashed.stderr.readForParse());
        try say.fail(io, "{s} at {s} is not a package Zig can hash", .{ p.repository, commit });
    }
    try Io.Dir.cwd().deleteTree(io, scratch);
    return .{
        .url = if (ref) |name| try a.print("git+{s}?ref={s}#{s}", .{ p.repository, name, commit }) else try a.print("git+{s}#{s}", .{ p.repository, commit }),
        .hash = try a.dupe(u8, std.mem.trim(u8, hashed.stdout.readForParse(), " \r\n")),
    };
}

/// The repository's tag listing, as `git ls-remote --tags` prints it.
pub fn tagListing(io: Io, a: std.mem.Allocator, url: []const u8) ![]const u8 {
    return git(io, a, null, &.{ "ls-remote", "--tags", parts(url).repository });
}

/// A git pin as a release names one: `?ref=` a version (`v1.2.3`, or without the `v`) and
/// the commit after `#`. Null for a branch, a bare commit or no ref.
pub fn releasePin(url: []const u8) ?struct { ref: []const u8, commit: []const u8, version: std.SemanticVersion } {
    if (!std.mem.startsWith(u8, url, "git+")) return null;
    const p = parts(url);
    const ref = p.ref orelse return null;
    const commit = p.fragment orelse return null;
    const version = std.SemanticVersion.parse(if (std.mem.startsWith(u8, ref, "v")) ref[1..] else ref) catch return null;
    return .{ .ref = ref, .commit = commit, .version = version };
}

/// The commit a pinned git URL holds and the repository it is fetched from: null for a URL that is
/// no git URL or names no commit.
pub fn commitOf(url: []const u8) ?struct { repository: []const u8, id: []const u8 } {
    if (!std.mem.startsWith(u8, url, "git+")) return null;
    const p = parts(url);
    const id = p.fragment orelse return null;
    if (!isCommit(id)) return null;
    return .{ .repository = p.repository, .id = id };
}

pub fn isCommit(text: []const u8) bool {
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
    write(io, a, listing, out, reader) catch |err| {
        reader.child.deinit(io);
        return err;
    };
    try reader.finish();
}

fn write(io: Io, a: std.mem.Allocator, listing: []const u8, out: Io.Dir, reader: *Objects) !void {
    var links: std.ArrayList(tree.Link) = .empty;
    var entries = std.mem.tokenizeScalar(u8, listing, 0);
    while (entries.next()) |line| {
        // What git lists is the remote's to choose: each entry parsed, its path checked, before
        // anything is written.
        const entry = aegis.input.Untrusted([]const u8).init(line).parse({}, Entry.parse) catch |err| switch (err) {
            error.UnexpectedGitOutput => |e| return e,
            error.OutsideTree => try say.fail(io, "the commit names a file outside its own tree, which no package may: {s}", .{line[(std.mem.findScalar(u8, line, '\t') orelse 0)..]}),
        };
        if (entry.kind == .submodule) continue;
        const data = try reader.blob(entry.object);
        const path = entry.path.text;
        if (entry.kind == .link) {
            const target = try aegis.input.Untrusted([]const u8).init(data).parse(tree.LinkTarget.Where{ .a = a, .link = path }, tree.LinkTarget.parse);
            try links.append(a, .{ .path = path, .target = target });
            continue;
        }
        if (std.fs.path.dirname(path)) |parent| try out.createDirPath(io, parent);
        try out.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = if (entry.kind == .executable) .executable_file else .default_file } });
    }
    // Links last, so no file is ever written through one.
    try tree.writeLinks(io, out, links.items);
}

/// A path a tree names, which stays inside the tree (`contained`).
const TreePath = struct { text: []const u8 };

/// An entry of `git ls-tree -z`, `<mode> <type> <object>\t<path>`: what it is, its
/// object, and its path inside the tree.
const Entry = struct {
    kind: enum { file, executable, link, submodule },
    object: []const u8,
    path: TreePath,

    const Error = error{ UnexpectedGitOutput, OutsideTree };

    fn parse(_: void, line: []const u8) Error!Entry {
        const tab = std.mem.findScalar(u8, line, '\t') orelse return error.UnexpectedGitOutput;
        var fields = std.mem.tokenizeScalar(u8, line[0..tab], ' ');
        const mode = fields.next() orelse return error.UnexpectedGitOutput;
        _ = fields.next() orelse return error.UnexpectedGitOutput;
        const object = fields.next() orelse return error.UnexpectedGitOutput;
        const path = line[tab + 1 ..];
        if (!tree.contained(path)) return error.OutsideTree;
        const kind: @FieldType(Entry, "kind") = if (std.mem.eql(u8, mode, "160000"))
            .submodule
        else if (std.mem.eql(u8, mode, "120000"))
            .link
        else if (std.mem.eql(u8, mode, "100755"))
            .executable
        else
            .file;
        return .{ .kind = kind, .object = object, .path = .{ .text = path } };
    }
};

/// The most one file of a package holds, as git gives it: a larger one is refused, not read.
const blob_limit: aegis.bounded.Limit(usize) = .init(1 << 30);

/// Blobs read through one `git cat-file --batch`, a request and its answer at a time.
const Objects = struct {
    io: Io,
    a: std.mem.Allocator,
    /// git, which its owner kills unless `finish` ends it as asked.
    child: aegis.own.OwnedIo(std.process.Child, kill),
    in_buffer: [256]u8 = undefined,
    out_buffer: [64 * 1024]u8 = undefined,
    in: Io.File.Writer = undefined,
    out: Io.File.Reader = undefined,

    fn open(io: Io, a: std.mem.Allocator, repository: []const u8) !*Objects {
        const objects = try a.create(Objects);
        objects.* = .{ .io = io, .a = a, .child = .init(try std.process.spawn(io, .{
            .argv = &.{ "git", "-C", repository, "cat-file", "--batch" },
            .stdin = .pipe,
            .stdout = .pipe,
        })) };
        const child = objects.child.borrow();
        objects.in = child.stdin.?.writerStreaming(io, &objects.in_buffer); // safe: stdin is piped
        objects.out = intake.readerStreaming(child.stdout.?, io, &objects.out_buffer); // safe: stdout is piped
        return objects;
    }

    fn kill(child: *std.process.Child, io: Io) void {
        child.kill(io);
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
        if (blob_limit.exceeds(size)) return error.BlobTooLarge;
        const data = try objects.a.alloc(u8, size);
        try reader.readSliceAll(data);
        if (try reader.takeByte() != '\n') return error.UnexpectedGitOutput;
        return data;
    }

    /// Ends git once every blob is read: it must have ended as asked.
    fn finish(objects: *Objects) !void {
        var child: std.process.Child = undefined;
        objects.child.take(&child);
        child.stdin.?.close(objects.io); // safe: stdin is piped
        child.stdin = null;
        const term = try child.wait(objects.io);
        if (term != .exited or term.exited != 0) return error.GitFailed;
    }
};

/// A package's history as far as its pins need it, in a repository of bay's own: commit objects
/// alone (`--filter=tree:0`, no tree or file), fetched from each pin's own repository, so a fork's
/// commits stand beside the original's. Each commit fetched is kept by a ref of its own
/// (`refs/pins/<commit>`), which no gc takes away and which says it is held without asking the
/// network; the commits below it come with it, and only a commit no ref holds is fetched.
pub const History = struct {
    io: Io,
    a: std.mem.Allocator,
    directory: []const u8,

    /// The history kept in `directory`, made empty when it is not there yet.
    pub fn open(io: Io, a: std.mem.Allocator, directory: []const u8) !History {
        const head = try std.fs.path.join(a, &.{ directory, "HEAD" });
        if (Io.Dir.cwd().access(io, head, .{})) |_| {} else |err| switch (err) {
            error.FileNotFound => {
                try Io.Dir.cwd().createDirPath(io, directory);
                _ = try git(io, a, null, &.{ "init", "--quiet", "--bare", directory });
            },
            else => |e| return e,
        }
        return .{ .io = io, .a = a, .directory = directory };
    }

    /// Makes `commit` held, fetching it from `repository` when no ref holds it yet;
    /// `error.FetchFailed` once what git said is passed on.
    pub fn hold(history: History, repository: []const u8, commit: []const u8) !void {
        const ref = try history.a.print("refs/pins/{s}", .{commit});
        if ((try status(history.io, history.a, history.directory, &.{ "show-ref", "--verify", "--quiet", ref })).code == 0) return;
        const spec = try history.a.print("{s}:{s}", .{ commit, ref });
        const fetched = try status(history.io, history.a, history.directory, &.{ "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--filter=tree:0", repository, spec });
        if (fetched.code == 0) return;
        try say.relay(history.io, fetched.stderr);
        return error.FetchFailed;
    }

    /// The commits of `commits` that no other of them contains, as git finds them
    /// (`merge-base --independent`): one when they lie on one line, its newest. Every one
    /// must be held.
    pub fn heads(history: History, commits: []const []const u8) ![]const []const u8 {
        const out = try git(history.io, history.a, history.directory, try std.mem.concat(history.a, []const u8, &.{ &.{ "merge-base", "--independent" }, commits }));
        var list: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeAny(u8, out, "\r\n");
        while (lines.next()) |line| {
            // What git printed is one of the commits asked about, or nothing bay takes.
            const asked = for (commits) |commit| {
                if (std.mem.eql(u8, commit, line)) break commit;
            } else return error.UnexpectedGitOutput;
            try list.append(history.a, asked);
        }
        if (list.items.len == 0) return error.UnexpectedGitOutput;
        return list.items;
    }
};

/// Runs git in `directory` and returns how it exited and what it said on stderr: for a
/// question git answers by its exit code.
fn status(io: Io, a: std.mem.Allocator, directory: []const u8, args: []const []const u8) !struct { code: u8, stderr: []const u8 } {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-C", directory }, args });
    const result = intake.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run git: {t}", .{err});
    return switch (result.term) {
        .exited => |code| .{ .code = code, .stderr = result.stderr.readForParse() },
        else => try say.fail(io, "git {s} did not end as asked", .{args[0]}),
    };
}

/// Runs git, in `directory` when given, and returns its stdout; a failure is
/// reported with what git said.
fn git(io: Io, a: std.mem.Allocator, directory: ?[]const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "git");
    if (directory) |path| try argv.appendSlice(a, &.{ "-C", path });
    try argv.appendSlice(a, args);
    const result = intake.run(a, io, .{ .argv = argv.items, .stdout_limit = .limited(256 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(io, "could not run git: {t}", .{err});
    if (result.term != .exited or result.term.exited != 0) {
        try say.relay(io, result.stderr.readForParse());
        try say.fail(io, "git {s} failed", .{args[0]});
    }
    return result.stdout.readForParse();
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

test "a release pin names a version tag and its commit; a branch, a bare commit or no ref does not" {
    const commit = "5d2a92141f0298d76dc5fd602526d55a62b4e11a";
    const pin = releasePin("git+https://github.com/o/r?ref=v1.2.0#" ++ commit).?;
    try std.testing.expectEqualStrings("v1.2.0", pin.ref);
    try std.testing.expectEqualStrings(commit, pin.commit);
    try std.testing.expect(releasePin("git+https://github.com/o/r?ref=0.3.0-rc.1#" ++ commit) != null);
    for ([_][]const u8{
        "git+https://github.com/o/r?ref=aegis-0.2#" ++ commit,
        "git+https://github.com/o/r?ref=main#" ++ commit,
        "git+https://github.com/o/r#" ++ commit,
        "git+https://github.com/o/r?ref=v1.2.0",
        "git+https://github.com/o/r",
        "https://github.com/o/r/archive/v1.2.0.tar.gz",
    }) |url| try std.testing.expect(releasePin(url) == null);
}

test "a pin's commit is its fragment when the fragment is one" {
    const commit = "5d2a92141f0298d76dc5fd602526d55a62b4e11a";
    const at = commitOf("git+https://github.com/o/r?ref=main#" ++ commit).?;
    try std.testing.expectEqualStrings("https://github.com/o/r", at.repository);
    try std.testing.expectEqualStrings(commit, at.id);
    try std.testing.expect(commitOf("git+https://github.com/o/r#main") == null);
    try std.testing.expect(commitOf("https://example.org/r.tar.gz#" ++ commit) == null);
}
