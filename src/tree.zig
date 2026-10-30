//! A package's tree as bay writes it itself, from a git commit (`git.zig`) or a
//! prebuilt archive (`archive.zig`): one set of rules for the paths a source names
//! and the links it holds, and one way of writing them, links last, so no file is
//! ever written through a link. What Zig's own fetch does to a tree (the
//! executable bit from a file's first bytes) is done here too, so what bay writes
//! hashes as Zig's fetch of the same files.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const say = @import("say.zig");

/// Whether a path a tree names stays inside the tree: relative, with no empty,
/// `.` or `..` part, no `.git`, and nothing a Windows path reads as a drive or
/// separator. git's own checkout refuses the same.
pub fn contained(path: []const u8) bool {
    if (path.len == 0) return false;
    var names = std.mem.splitScalar(u8, path, '/');
    while (names.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
        if (std.mem.findAny(u8, part, "\\:") != null) return false;
    }
    return true;
}

/// A path a tree names that stays inside it (`contained`), read from what another
/// wrote: a prebuilt pin's licence or key file, by its package's manifest.
pub const Inside = struct {
    path: []const u8,

    pub const Error = error{Outside};

    pub fn parse(_: void, text: []const u8) Error!Inside {
        if (!contained(text)) return error.Outside;
        return .{ .path = text };
    }
};

/// A link's target as the tree stores it, written as it is, and the path inside the
/// tree it reaches when it stays inside: `..` and `.` resolved by name from the link's
/// folder. A target that leaves the tree, or is absolute, reaches nothing here.
pub const LinkTarget = struct {
    text: []const u8,
    within: ?[]const u8,

    pub const Where = struct { a: std.mem.Allocator, link: []const u8 };

    pub fn parse(where: Where, text: []const u8) error{OutOfMemory}!LinkTarget {
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

/// A link to write at `path`, a path inside the tree.
pub const Link = struct { path: []const u8, target: LinkTarget };

/// Writes `links` into `out`, once every file is there. A link refused for want of
/// the right to make one names the link and the right.
pub fn writeLinks(io: Io, out: Io.Dir, links: []const Link) !void {
    for (links) |link| {
        if (std.fs.path.dirname(link.path)) |parent| {
            // A folder on the way that is an earlier link (`A` where the file system
            // takes `a` for it) would carry this one outside the tree.
            if (try throughLink(io, out, parent)) try say.fail(io, "{s} is a link inside another link, which would leave its tree", .{link.path});
            try out.createDirPath(io, parent);
        }
        // Windows makes a link to a directory apart from one to a file: what it reaches in the
        // tree says which, and a link that leaves the tree is kept as a link to a file.
        const to_directory = if (link.target.within) |reached| if (out.statFile(io, reached, .{})) |stat| stat.kind == .directory else |err| switch (err) {
            error.FileNotFound => false, // a link to nothing in the tree is kept as a link to a file
            else => |e| return e,
        } else false;
        out.symLink(io, link.target.text, link.path, .{ .is_directory = to_directory }) catch |err| switch (err) {
            error.PermissionDenied => if (builtin.os.tag == .windows)
                try say.fail(io, "{s} is a link, to {s}, that this account may not make: Windows makes one only for an account with SeCreateSymbolicLinkPrivilege, the \"Create symbolic links\" right", .{ link.path, link.target.text })
            else
                return err,
            else => |e| return e,
        };
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

/// Gives each file in `path` that starts as a program does (`#!`, ELF, Mach-O)
/// the executable bit, as Zig 0.17 does when it unpacks a package: an archive's
/// own modes are ignored by both, so what bay copies from here is what Zig unpacks.
pub fn markExecutables(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    if (!Io.File.Permissions.has_executable_bit) return;
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        var header: [4]u8 = undefined;
        const length = try file.readPositional(io, &.{&header}, 0);
        if (startsAsProgram(header[0..length])) try file.setPermissions(io, .executable_file);
    }
}

fn startsAsProgram(header: []const u8) bool {
    if (std.mem.startsWith(u8, header, "#!")) return true;
    if (std.mem.startsWith(u8, header, std.elf.MAGIC)) return true;
    if (header.len < 4) return false;
    const magic = std.mem.readInt(u32, header[0..4], builtin.cpu.arch.endian());
    return switch (magic) {
        std.macho.MH_MAGIC, std.macho.MH_MAGIC_64, std.macho.FAT_MAGIC, std.macho.FAT_MAGIC_64, std.macho.MH_CIGAM, std.macho.MH_CIGAM_64, std.macho.FAT_CIGAM, std.macho.FAT_CIGAM_64 => true,
        else => false,
    };
}

test "a file is a program by its first bytes, as Zig takes it" {
    try std.testing.expect(startsAsProgram("#!/bin/sh"));
    try std.testing.expect(startsAsProgram("\x7fELF"));
    try std.testing.expect(!startsAsProgram("pub "));
    try std.testing.expect(!startsAsProgram("#"));
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

test "a folder that is a link is found on a path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real/inner");
    // A link to a folder any account makes: on Windows a junction, which std's stat
    // takes for a link, as it takes any name-surrogate reparse point.
    const a = std.testing.allocator;
    const where = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(where);
    const target = try std.fs.path.join(a, &.{ where, "real" });
    defer a.free(target);
    const link = try std.fs.path.join(a, &.{ where, "link" });
    defer a.free(link);
    try @import("link").folder(io, target, link);
    try std.testing.expect(try throughLink(io, tmp.dir, "link"));
    try std.testing.expect(try throughLink(io, tmp.dir, "link/inner"));
    try std.testing.expect(!try throughLink(io, tmp.dir, "real/inner"));
    try std.testing.expect(!try throughLink(io, tmp.dir, "missing/inner"));
}
