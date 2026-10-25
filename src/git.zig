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
    const Link = struct { path: []const u8, target: LinkTarget };
    var links: std.ArrayList(Link) = .empty;
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
            const target = try aegis.input.Untrusted([]const u8).init(data).parse(LinkTarget.Where{ .a = a, .link = path }, LinkTarget.parse);
            try links.append(a, .{ .path = path, .target = target });
            continue;
        }
        if (std.fs.path.dirname(path)) |parent| try out.createDirPath(io, parent);
        try out.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = if (entry.kind == .executable) .executable_file else .default_file } });
    }
    // Links last, so no file is ever written through one.
    for (links.items) |link| {
        if (std.fs.path.dirname(link.path)) |parent| {
            // A folder on the way that is an earlier link (`A` where the file system
            // takes `a` for it) would carry this one outside the tree.
            if (try throughLink(io, out, parent)) try say.fail(io, "the commit names a link inside another link, which would leave its tree: {s}", .{link.path});
            try out.createDirPath(io, parent);
        }
        // Windows makes a link to a directory apart from one to a file: what it reaches in the
        // tree says which, and a link that leaves the tree is kept as a link to a file.
        const to_directory = if (link.target.within) |reached| if (out.statFile(io, reached, .{})) |stat| stat.kind == .directory else |err| switch (err) {
            error.FileNotFound => false, // a link to nothing in the tree is kept as a link to a file
            else => |e| return e,
        } else false;
        try out.symLink(io, link.target.text, link.path, .{ .is_directory = to_directory });
    }
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
        if (!contained(path)) return error.OutsideTree;
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

/// A link's target as the tree stores it, written as it is, and the path inside the
/// tree it reaches when it stays inside: `..` and `.` resolved by name from the link's
/// folder. A target that leaves the tree, or is absolute, reaches nothing here.
const LinkTarget = struct {
    text: []const u8,
    within: ?[]const u8,

    const Where = struct { a: std.mem.Allocator, link: []const u8 };

    fn parse(where: Where, text: []const u8) error{OutOfMemory}!LinkTarget {
        if (text.len == 0 or text[0] == '/' or std.mem.findAny(u8, text, "\\:") != null) return .{ .text = text, .within = null };
        var reached: std.ArrayList([]const u8) = .empty;
        var folders = std.mem.splitScalar(u8, std.fs.path.dirname(where.link) orelse "", '/');
        while (folders.next()) |folder| if (folder.len != 0) try reached.append(where.a, folder);
        var names = std.mem.splitScalar(u8, text, '/');
        while (names.next()) |name| {
            if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
            if (std.mem.eql(u8, name, "..")) {
                if (reached.pop() == null) return .{ .text = text, .within = null };
            } else try reached.append(where.a, name);
        }
        const within = try std.mem.join(where.a, "/", reached.items);
        return .{ .text = text, .within = if (within.len == 0 or !contained(within)) null else within };
    }
};

/// Whether a path a tree names stays inside the tree: relative, with no empty,
/// `.` or `..` part, no `.git`, and nothing a Windows path reads as a drive or
/// separator. git's own checkout refuses the same.
fn contained(path: []const u8) bool {
    if (path.len == 0) return false;
    var names = std.mem.splitScalar(u8, path, '/');
    while (names.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
        if (std.mem.findAny(u8, part, "\\:") != null) return false;
    }
    return true;
}

/// The most one file of a package holds, as git gives it: a larger one is refused, not read.
const blob_limit: usize = 1 << 30;

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
        objects.out = child.stdout.?.readerStreaming(io, &objects.out_buffer); // safe: stdout is piped
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
        if (size > blob_limit) return error.BlobTooLarge;
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

test "a tree's path stays inside the tree" {
    try std.testing.expect(contained("src/root.zig"));
    try std.testing.expect(contained("a/.gitignore"));
    for ([_][]const u8{ "", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", ".git/hooks/pre-commit", "a/.GIT/config", "C:x", "a\\b" }) |path|
        try std.testing.expect(!contained(path));
}

test "a link's target reaches a path inside the tree, or nothing when it leaves it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { link: []const u8, target: []const u8, within: ?[]const u8 };
    for ([_]Case{
        .{ .link = "a/b/link", .target = "../c", .within = "a/c" },
        .{ .link = "a/link", .target = "./x/../y", .within = "a/y" },
        .{ .link = "link", .target = "src", .within = "src" },
        .{ .link = "a/link", .target = "../../outside", .within = null },
        .{ .link = "a/link", .target = "..", .within = null },
        .{ .link = "link", .target = "/etc", .within = null },
        .{ .link = "link", .target = "C:x", .within = null },
        .{ .link = "link", .target = "a/.git/config", .within = null },
    }) |case| {
        const target = try LinkTarget.parse(.{ .a = a, .link = case.link }, case.target);
        try std.testing.expectEqualStrings(case.target, target.text);
        if (case.within) |within| try std.testing.expectEqualStrings(within, target.within.?) else try std.testing.expectEqual(null, target.within);
    }
}

/// Whether a folder on `path`, as `dir` resolves it, is a link.
fn throughLink(io: Io, dir: Io.Dir, path: []const u8) !bool {
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.findScalarPos(u8, path, end + 1, '/') orelse path.len;
        const stat = dir.statFile(io, path[0..end], .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false, // what is not there yet is made as a folder
            else => |e| return e,
        };
        if (stat.kind == .sym_link) return true;
    }
    return false;
}

test "a folder that is a link is found on a path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real/inner");
    // A link to a folder any account makes: on Windows a junction, which needs no
    // privilege where a symbolic link needs SeCreateSymbolicLinkPrivilege; std's stat
    // takes either for a link, as it takes any name-surrogate reparse point.
    if (@import("builtin").os.tag == .windows) {
        const a = std.testing.allocator;
        const where = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(where);
        const target = try std.fs.path.join(a, &.{ where, "real" });
        defer a.free(target);
        const made = try std.process.run(a, io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", "link", target }, .cwd = .{ .path = where } });
        defer a.free(made.stdout);
        defer a.free(made.stderr);
        try std.testing.expect(made.term == .exited and made.term.exited == 0);
    } else try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });
    try std.testing.expect(try throughLink(io, tmp.dir, "link"));
    try std.testing.expect(try throughLink(io, tmp.dir, "link/inner"));
    try std.testing.expect(!try throughLink(io, tmp.dir, "real/inner"));
    try std.testing.expect(!try throughLink(io, tmp.dir, "missing/inner"));
}
