//! The archives bay unpacks itself: a prebuilt pin's (designs/bay.md §11), which
//! Zig's fetch refuses. One format, a tar compressed by gzip or by zstd, told by
//! its first bytes, never by its name or what the server calls it. xz and zip are
//! refused by name, so std's xz reader, which panics where a tar is skipped through
//! (`discard`), and its unzip, which checks no CRC, are never reached; bzip2 has no
//! decoder in std.
//!
//! An archive is read only once it is authenticated (`authenticate`): its size and
//! SHA-256 those the pin holds, then its publisher's signature over its bytes, so
//! the readers below only ever see what the publisher signed, and the archive's own
//! checksums are not what its integrity rests on. It is read twice: once to check
//! every entry's name, kind, size and link, writing nothing, and once to write the
//! tree, links last, through tree.zig, as git's checkout is written. The tree is the
//! one Zig's own fetch makes of the same archive: a single top directory taken
//! away, empty directories dropped, programs marked by their first bytes.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const zstd = std.compress.zstd;
const flate = std.compress.flate;
const openpgp = @import("openpgp.zig");
const tree = @import("tree.zig");

/// A prebuilt archive's format.
pub const Format = enum { tar_gzip, tar_zstd };

/// The formats bay knows and refuses, and the bytes it does not know.
pub const FormatError = error{ Xz, Zip, Bzip2, UnknownFormat };

/// The format an archive's first bytes say.
pub fn formatOf(head: []const u8) FormatError!Format {
    if (std.mem.startsWith(u8, head, "\x1f\x8b")) return .tar_gzip;
    if (std.mem.startsWith(u8, head, "\x28\xb5\x2f\xfd")) return .tar_zstd;
    if (std.mem.startsWith(u8, head, "\xfd7zXZ\x00")) return error.Xz;
    if (std.mem.startsWith(u8, head, "PK\x03\x04") or std.mem.startsWith(u8, head, "PK\x05\x06")) return error.Zip;
    if (std.mem.startsWith(u8, head, "BZh")) return error.Bzip2;
    return error.UnknownFormat;
}

/// What the pin holds of the archive's bytes.
pub const Expected = struct {
    sha256: [Sha256.digest_length]u8,
    size: u64,
};

/// Who vouches for the archive's bytes besides the pin.
pub const Publisher = union(enum) {
    /// An OpenPGP detached signature over the archive by a key of `keys` (openpgp.zig),
    /// each as the bytes read from its file.
    openpgp: struct { keys: []const u8, signature: []const u8 },
    /// No one: chosen by hand, so the pin's digest is all that holds the archive.
    none,
};

/// An archive whose bytes are the pin's and its publisher's: the only thing `unpack` reads.
pub const Authenticated = struct {
    path: []const u8,
    format: Format,
};

pub const AuthenticateError = error{
    /// The archive is not as long as the pin says.
    SizeMismatch,
    /// Its SHA-256 is not the pin's.
    DigestMismatch,
    /// The publisher's key or signature cannot be read, or the signature is not over these bytes.
    SignatureMismatch,
} || FormatError;

/// Checks the archive at `path` against the pin, then against its publisher, then
/// tells its format: nothing of it is read as an archive before each passes.
pub fn authenticate(io: Io, a: std.mem.Allocator, path: []const u8, expected: Expected, publisher: Publisher) !Authenticated {
    var verifier: ?openpgp.Verifier = switch (publisher) {
        .none => null,
        .openpgp => |signed| verifier: {
            const keys = aegis.input.Untrusted([]const u8).init(signed.keys).parse(a, openpgp.Keys.parse) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.SignatureMismatch,
            };
            const signature = aegis.input.Untrusted([]const u8).init(signed.signature).parse(a, openpgp.Signature.parse) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.SignatureMismatch,
            };
            break :verifier openpgp.Verifier.init(signature, keys) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.SignatureMismatch,
            };
        },
    };
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    var sha256: Sha256 = .init(.{});
    var head: [6]u8 = @splat(0);
    var length: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        try io.checkCancel();
        const n = reader.interface.readSliceShort(&buffer) catch return reader.err orelse error.ReadFailed;
        if (length < head.len) {
            const at: usize = @intCast(length); // safe: below the head's length
            const count = @min(head.len - at, n);
            @memcpy(head[at..][0..count], buffer[0..count]);
        }
        length += n;
        // A longer file is refused as soon as it is seen to be longer.
        if (length > expected.size) return error.SizeMismatch;
        sha256.update(buffer[0..n]);
        if (verifier) |*v| v.update(buffer[0..n]);
        if (n < buffer.len) break;
    }
    if (length != expected.size) return error.SizeMismatch;
    if (!std.mem.eql(u8, &sha256.finalResult(), &expected.sha256)) return error.DigestMismatch;
    if (verifier) |*v| v.verify() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.SignatureMismatch,
    };
    return .{ .path = path, .format = try formatOf(head[0..@min(head.len, length)]) };
}

/// The largest zstd window bay decodes: the reference decoder's default limit
/// (`ZSTD_WINDOWLOG_LIMIT_DEFAULT`, 2^27), with no override.
pub const zstd_window_max: u64 = 128 << 20;

pub const UnpackError = error{
    /// The compressed stream or the tar in it is not one std reads.
    Malformed,
    /// A zstd frame declares a window above `zstd_window_max`, or none.
    WindowTooLarge,
    /// An entry other than a file, a directory or a symbolic link: a hard link, a device.
    UnsupportedEntry,
    /// A name that is absolute, climbs out with `..`, or that some system cannot hold
    /// (a backslash, `:`, a control byte, a Windows device name, a trailing dot or space).
    UnsafeName,
    /// Two entries one name on a system that folds case, a name twice, or a name both
    /// a file and a directory.
    NameClash,
    /// A link whose target is absolute or leaves the tree.
    LinkOutside,
    /// The tree is larger than the pin says.
    TooLarge,
    /// The archive read otherwise the second time than the first.
    ArchiveChanged,
};

/// What an unpack refused, by name: the entry that made it refuse.
pub const Diagnostic = struct { entry: []const u8 = "" };

/// Unpacks `archive` into `into`, which it makes, as Zig's fetch unpacks a tar: every entry
/// checked first, the tree no larger than `bytes`, then written with links last.
pub fn unpack(io: Io, a: std.mem.Allocator, archive: Authenticated, into: []const u8, bytes: u64, diagnostic: *Diagnostic) !void {
    const plan = try check(io, a, archive, bytes, diagnostic);
    var out = try Io.Dir.cwd().createDirPathOpen(io, into, .{});
    defer out.close(io);
    try write(io, a, archive, plan, out, diagnostic);
    try tree.markExecutables(io, a, into);
}

/// An entry as the first reading found it, its name made relative and plain.
const Entry = struct {
    name: []const u8,
    kind: std.tar.FileKind,
    size: u64,
    link: []const u8,
};

/// What the first reading found: every entry, and the top directory taken away.
const Plan = struct {
    entries: []const Entry,
    root: []const u8,
};

/// The first reading: every entry's name, kind, size and link checked, nothing written.
fn check(io: Io, a: std.mem.Allocator, archive: Authenticated, bytes: u64, diagnostic: *Diagnostic) !Plan {
    var tar: Tar = undefined;
    try tar.open(io, a, archive);
    defer tar.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var names: std.StringHashMapUnmanaged(Seen) = .empty;
    var total: u64 = 0;
    var root: ?[]const u8 = null;
    while (try tar.next(a, diagnostic)) |file| {
        const name = try plain(a, file.name, diagnostic);
        if (name.len == 0) continue;
        try entries.append(a, .{ .name = name, .kind = file.kind, .size = file.size, .link = try a.dupe(u8, file.link_name) });
        total +|= file.size;
        if (total > bytes) {
            diagnostic.entry = name;
            return error.TooLarge;
        }
        // Zig's root rule (`std.tar.Diagnostics.findRoot`): every entry under one top
        // directory, a top directory's own entry among them.
        const first = name[0 .. std.mem.findScalar(u8, name, '/') orelse name.len];
        const top = if (first.len < name.len or file.kind == .directory) first else "";
        if (root) |seen| {
            if (!std.mem.eql(u8, seen, top)) root = "";
        } else root = top;
        try claim(a, &names, name, file.kind, diagnostic);
    }
    const plan: Plan = .{ .entries = entries.items, .root = root orelse "" };
    for (plan.entries) |entry| {
        if (entry.kind != .sym_link) continue;
        const path = stripped(plan.root, entry.name) orelse {
            diagnostic.entry = entry.name;
            return error.LinkOutside;
        };
        const target = try tree.LinkTarget.parse(.{ .a = a, .link = path }, entry.link);
        if (target.within == null) {
            diagnostic.entry = entry.name;
            return error.LinkOutside;
        }
    }
    return plan;
}

/// The second reading: the tree written as the first found it, links last.
fn write(io: Io, a: std.mem.Allocator, archive: Authenticated, plan: Plan, out: Io.Dir, diagnostic: *Diagnostic) !void {
    var tar: Tar = undefined;
    try tar.open(io, a, archive);
    defer tar.close(io);
    var links: std.ArrayList(tree.Link) = .empty;
    var index: usize = 0;
    var contents: [16 * 1024]u8 = undefined;
    while (try tar.next(a, diagnostic)) |file| {
        const name = try plain(a, file.name, diagnostic);
        if (name.len == 0) continue;
        if (index == plan.entries.len) return error.ArchiveChanged;
        const entry = plan.entries[index];
        index += 1;
        if (!std.mem.eql(u8, entry.name, name) or entry.kind != file.kind or entry.size != file.size or !std.mem.eql(u8, entry.link, file.link_name)) return error.ArchiveChanged;
        // The top directory's own entry, or a directory: made by what is in it, and an empty one dropped.
        const path = stripped(plan.root, name) orelse continue;
        switch (file.kind) {
            .directory => {},
            .file => {
                if (std.fs.path.dirname(path)) |parent| try out.createDirPath(io, parent);
                const written = try out.createFile(io, path, .{ .exclusive = true });
                defer written.close(io);
                var writer = written.writer(io, &contents);
                tar.iterator.streamRemaining(file, &writer.interface) catch |err| switch (err) {
                    error.WriteFailed => return writer.err orelse err,
                    error.ReadFailed, error.EndOfStream => return tar.failure(),
                };
                try writer.interface.flush();
            },
            .sym_link => try links.append(a, .{ .path = path, .target = try tree.LinkTarget.parse(.{ .a = a, .link = path }, entry.link) }),
        }
    }
    if (index != plan.entries.len) return error.ArchiveChanged;
    try tree.writeLinks(io, out, links.items);
}

/// `name` below the top directory `root`; null for the top directory's own entry.
fn stripped(root: []const u8, name: []const u8) ?[]const u8 {
    if (root.len == 0) return name;
    if (name.len == root.len) return null;
    return name[root.len + 1 ..];
}

fn closeFile(file: *Io.File, io: Io) void {
    file.close(io);
}

/// A tar's entries, read through the archive's decompressor.
const Tar = struct {
    file: aegis.own.OwnedIo(Io.File, closeFile),
    reader: Io.File.Reader,
    buffer: [64 * 1024]u8,
    /// The decompressor the tar is read through, and its window.
    decompress: union(Format) { tar_gzip: flate.Decompress, tar_zstd: zstd.Decompress },
    window: []u8,
    iterator: std.tar.Iterator,
    diagnostics: std.tar.Diagnostics,
    file_name: [Io.Dir.max_path_bytes]u8,
    link_name: [Io.Dir.max_path_bytes]u8,

    /// Opens the archive in place: the readers point into `tar`.
    fn open(tar: *Tar, io: Io, a: std.mem.Allocator, archive: Authenticated) !void {
        tar.file = .init(try Io.Dir.cwd().openFile(io, archive.path, .{}));
        errdefer tar.file.deinit(io);
        tar.reader = tar.file.borrow().reader(io, &tar.buffer);
        tar.diagnostics = .{ .allocator = a };
        const input = &tar.reader.interface;
        const decompressed = switch (archive.format) {
            .tar_gzip => gzip: {
                tar.window = try a.alloc(u8, flate.max_window_len);
                tar.decompress = .{ .tar_gzip = .init(input, .gzip, tar.window) };
                break :gzip &tar.decompress.tar_gzip.reader;
            },
            .tar_zstd => zstd: {
                const window = try windowOf(io, tar.file.borrow().*);
                tar.window = try a.alloc(u8, window + zstd.block_size_max);
                tar.decompress = .{ .tar_zstd = .init(input, tar.window, .{ .window_len = window }) };
                break :zstd &tar.decompress.tar_zstd.reader;
            },
        };
        tar.iterator = .init(decompressed, .{ .file_name_buffer = &tar.file_name, .link_name_buffer = &tar.link_name, .diagnostics = &tar.diagnostics });
    }

    fn close(tar: *Tar, io: Io) void {
        tar.file.deinit(io);
    }

    /// The next file, directory or link; an entry of another kind is refused by name.
    fn next(tar: *Tar, a: std.mem.Allocator, diagnostic: *Diagnostic) !?std.tar.Iterator.File {
        const file = tar.iterator.next() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ReadFailed => return tar.failure(),
            else => return error.Malformed,
        };
        for (tar.diagnostics.errors.items) |refused| switch (refused) {
            .unsupported_file_type => |entry| {
                diagnostic.entry = try a.dupe(u8, entry.file_name);
                return error.UnsupportedEntry;
            },
            else => return error.Malformed,
        };
        return file;
    }

    /// Why reading stopped: the file's error, or the stream's being no archive.
    fn failure(tar: *Tar) anyerror {
        if (tar.reader.err) |err| return err;
        return switch (tar.decompress) {
            .tar_zstd => |d| if (d.err) |err| switch (err) {
                error.WindowOversize, error.WindowSizeUnknown => error.WindowTooLarge,
                else => error.Malformed,
            } else error.Malformed,
            .tar_gzip => error.Malformed,
        };
    }
};

/// The window the archive's first zstd frame declares, refused above `zstd_window_max`;
/// a later frame declaring more than the first is refused by the decoder.
fn windowOf(io: Io, file: Io.File) !u32 {
    var bytes: [18]u8 = undefined;
    const length = try file.readPositional(io, &.{&bytes}, 0);
    var in: Io.Reader = .fixed(bytes[0..length]);
    _ = in.takeInt(u32, .little) catch return error.Malformed;
    const header = zstd.Decompress.Frame.Zstandard.Header.decode(&in) catch return error.Malformed;
    const window = header.windowSize() orelse return error.WindowTooLarge;
    if (window > zstd_window_max) return error.WindowTooLarge;
    return @intCast(window); // safe: at most zstd_window_max
}

/// `name` made relative and plain, as Zig's tar reader takes it (`.` and empty parts
/// dropped), or refused: absolute, `..`, or a part some system cannot hold. Empty for
/// the archive's own top entry (`./`).
fn plain(a: std.mem.Allocator, name: []const u8, diagnostic: *Diagnostic) ![]const u8 {
    if (name.len == 0 or name[0] == '/') return refuse(a, name, diagnostic);
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") or !portable(part)) return refuse(a, name, diagnostic);
        try parts.append(a, part);
    }
    return std.mem.join(a, "/", parts.items);
}

fn refuse(a: std.mem.Allocator, name: []const u8, diagnostic: *Diagnostic) ![]const u8 {
    diagnostic.entry = try a.dupe(u8, name);
    return error.UnsafeName;
}

/// Whether every system bay builds on can hold `part` as one file name: no
/// separator or drive mark, no control byte, no Windows device name, no trailing
/// dot or space, which Windows takes away.
fn portable(part: []const u8) bool {
    for (part) |byte| if (byte < 0x20 or byte == 0x7f or std.mem.findScalar(u8, "\\:*?\"<>|", byte) != null) return false;
    if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
    const stem = part[0 .. std.mem.findScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    if (stem.len == 4 and std.ascii.isDigit(stem[3]) and stem[3] != '0') {
        if (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) return false;
    }
    return true;
}

/// A name the first reading has seen, as written, and whether it is a directory.
const Seen = struct { name: []const u8, directory: bool };

/// Takes `name`, and each directory above it, in `names`, keyed as a system that folds
/// case reads it: a second spelling of one key, a name twice, or a name both a file and
/// a directory is refused.
fn claim(a: std.mem.Allocator, names: *std.StringHashMapUnmanaged(Seen), name: []const u8, kind: std.tar.FileKind, diagnostic: *Diagnostic) !void {
    var end: usize = 0;
    while (std.mem.findScalarPos(u8, name, end, '/')) |slash| : (end = slash + 1) try take(a, names, name[0..slash], true, diagnostic);
    try take(a, names, name, kind == .directory, diagnostic);
}

fn take(a: std.mem.Allocator, names: *std.StringHashMapUnmanaged(Seen), name: []const u8, directory: bool, diagnostic: *Diagnostic) !void {
    const slot = try names.getOrPut(a, try std.ascii.allocLowerString(a, name));
    if (!slot.found_existing) {
        slot.value_ptr.* = .{ .name = name, .directory = directory };
        return;
    }
    if (std.mem.eql(u8, slot.value_ptr.name, name) and slot.value_ptr.directory and directory) return;
    diagnostic.entry = name;
    return error.NameClash;
}

const testing = std.testing;

/// What a test archive holds.
const Member = struct {
    name: []const u8,
    kind: enum { file, directory, link, hard_link } = .file,
    data: []const u8 = "",
};

/// A tar of `members`, as std's tar writer writes one; a hard link by hand, which it does not write.
fn tarOf(a: std.mem.Allocator, members: []const Member) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    var writer: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (members) |member| switch (member.kind) {
        .file => try writer.writeFileBytes(member.name, member.data, .{}),
        .directory => try writer.writeDir(member.name, .{}),
        .link => try writer.writeLink(member.name, member.data, .{}),
        .hard_link => {
            // A link's header with its type made a hard link's ('1') and its checksum summed again.
            var header: std.tar.Writer.Header = .init(.symbolic_link);
            try header.setPath("", member.name);
            try header.setLinkname(member.data);
            const bytes = std.mem.asBytes(&header);
            bytes[156] = '1';
            var sum: u32 = ' '; // the checksum field counts as spaces, its last byte too
            for (bytes) |byte| sum += byte;
            _ = try std.mem.print(bytes[148..156], "{o:0>6}\x00 ", .{sum});
            try out.writer.writeAll(bytes);
        },
    };
    return out.written();
}

/// `data` in gzip, its deflate blocks stored.
fn gzipOf(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    const buffer = try a.alloc(u8, flate.max_window_len);
    var compress: flate.Compress.Raw = try .init(&out.writer, buffer, .gzip);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.written();
}

/// `data` in one zstd frame declaring a window of 2^(10 + `exponent`) bytes, its blocks raw.
fn zstdOf(a: std.mem.Allocator, data: []const u8, exponent: u5) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("\x28\xb5\x2f\xfd\x00");
    try out.writer.writeByte(@as(u8, exponent) << 3);
    var rest = data;
    while (true) {
        const size = @min(rest.len, 1 << 16);
        const last = size == rest.len;
        try out.writer.writeInt(u24, @as(u24, @intCast(size)) << 3 | @intFromBool(last), .little);
        try out.writer.writeAll(rest[0..size]);
        rest = rest[size..];
        if (last) return out.written();
    }
}

/// A scratch directory with `bytes` written as `archive`, and the pin of those bytes.
const Fixture = struct {
    tmp: testing.TmpDir,
    path: []const u8,
    expected: Expected,

    fn init(a: std.mem.Allocator, bytes: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "archive", .data = bytes });
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        const where = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
        return .{ .tmp = tmp, .path = try std.fs.path.join(a, &.{ where, "archive" }), .expected = .{ .sha256 = digest, .size = bytes.len } };
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    /// The archive authenticated by its digest alone and unpacked into `tree`.
    fn unpacked(f: *Fixture, a: std.mem.Allocator, diagnostic: *Diagnostic) ![]const u8 {
        const archive = try authenticate(testing.io, a, f.path, f.expected, .none);
        const into = try std.fs.path.join(a, &.{ std.fs.path.dirname(f.path).?, "tree" });
        try unpack(testing.io, a, archive, into, 1 << 20, diagnostic);
        return into;
    }
};

fn expectFile(a: std.mem.Allocator, directory: []const u8, name: []const u8, data: []const u8) !void {
    const text = try aegis.own.readFile(testing.io, Io.Dir.cwd(), try std.fs.path.join(a, &.{ directory, name }), a, .fromRaw(1 << 20));
    try testing.expectEqualStrings(data, text);
}

test "an archive's format is its first bytes: gzip and zstd are read, xz, zip and bzip2 refused by name" {
    try testing.expectEqual(Format.tar_gzip, try formatOf("\x1f\x8b\x08\x00"));
    try testing.expectEqual(Format.tar_zstd, try formatOf("\x28\xb5\x2f\xfd\x00"));
    try testing.expectError(error.Xz, formatOf("\xfd7zXZ\x00\x00"));
    try testing.expectError(error.Zip, formatOf("PK\x03\x04"));
    try testing.expectError(error.Zip, formatOf("PK\x05\x06"));
    try testing.expectError(error.Bzip2, formatOf("BZh91AY"));
    try testing.expectError(error.UnknownFormat, formatOf("ustar"));
    try testing.expectError(error.UnknownFormat, formatOf(""));
}

test "a tar in gzip or in zstd unpacks as Zig's fetch unpacks it: its one top directory taken away, links inside it kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarOf(a, &.{
        .{ .name = "pkg", .kind = .directory },
        .{ .name = "pkg/bin/tool", .data = "#!/bin/sh\n" },
        .{ .name = "pkg/lib/libc++.dll", .data = "library" },
        .{ .name = "pkg/empty", .kind = .directory },
        .{ .name = "pkg/bin/lib", .kind = .link, .data = "../lib" },
    });
    for ([_][]const u8{ try gzipOf(a, tar), try zstdOf(a, tar, 10) }) |bytes| {
        var fixture: Fixture = try .init(a, bytes);
        defer fixture.deinit();
        var diagnostic: Diagnostic = .{};
        const into = try fixture.unpacked(a, &diagnostic);
        try expectFile(a, into, "bin/tool", "#!/bin/sh\n");
        try expectFile(a, into, "lib/libc++.dll", "library");
        try expectFile(a, into, "bin/lib/libc++.dll", "library");
        try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, try std.fs.path.join(a, &.{ into, "empty" }), .{}));
        if (Io.File.Permissions.has_executable_bit) {
            const stat = try Io.Dir.cwd().statFile(testing.io, try std.fs.path.join(a, &.{ into, "bin/tool" }), .{});
            try testing.expect(stat.permissions.toMode() & 0o100 != 0);
        }
    }
}

test "an archive of several top entries keeps them all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = try .init(a, try zstdOf(a, try tarOf(a, &.{
        .{ .name = ".PKGINFO", .data = "pkgname = layers" },
        .{ .name = "./clang64/bin/VkLayer_khronos_validation.json", .data = "{}" },
    }), 15));
    defer fixture.deinit();
    var diagnostic: Diagnostic = .{};
    const into = try fixture.unpacked(a, &diagnostic);
    try expectFile(a, into, ".PKGINFO", "pkgname = layers");
    try expectFile(a, into, "clang64/bin/VkLayer_khronos_validation.json", "{}");
}

test "an archive that is not the pin's, or not its publisher's, is refused before it is read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The bytes openpgp.zig's samples sign, and those bytes with one changed.
    var signed: Fixture = try .init(a, openpgp.sample.signed);
    defer signed.deinit();
    const by_key: Publisher = .{ .openpgp = .{ .keys = openpgp.sample.key, .signature = openpgp.sample.signature } };
    // Signed and the pin's: authenticated, then refused as no archive bay reads.
    try testing.expectError(error.UnknownFormat, authenticate(testing.io, a, signed.path, signed.expected, by_key));
    var wrong = signed.expected;
    wrong.sha256[0] ^= 1;
    try testing.expectError(error.DigestMismatch, authenticate(testing.io, a, signed.path, wrong, by_key));
    wrong = signed.expected;
    wrong.size -= 1;
    try testing.expectError(error.SizeMismatch, authenticate(testing.io, a, signed.path, wrong, by_key));
    wrong.size += 2;
    try testing.expectError(error.SizeMismatch, authenticate(testing.io, a, signed.path, wrong, by_key));
    const changed = try a.dupe(u8, openpgp.sample.signed);
    changed[0] ^= 1;
    var forged: Fixture = try .init(a, changed);
    defer forged.deinit();
    // The pin follows the changed bytes; the publisher's signature does not.
    try testing.expectError(error.SignatureMismatch, authenticate(testing.io, a, forged.path, forged.expected, by_key));
    try testing.expectError(error.SignatureMismatch, authenticate(testing.io, a, forged.path, forged.expected, .{ .openpgp = .{ .keys = "not a key", .signature = openpgp.sample.signature } }));
    // An xz or a zip that is the pin's is refused by name once authenticated.
    for ([_]struct { bytes: []const u8, err: anyerror }{
        .{ .bytes = "\xfd7zXZ\x00\x00\x04", .err = error.Xz },
        .{ .bytes = "PK\x03\x04\x14\x00", .err = error.Zip },
    }) |case| {
        var fixture: Fixture = try .init(a, case.bytes);
        defer fixture.deinit();
        try testing.expectError(case.err, authenticate(testing.io, a, fixture.path, fixture.expected, .none));
    }
}

test "an entry that climbs out, a link that leaves the tree, a hard link and a name some system cannot hold are refused, naming it, with nothing written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { members: []const Member, err: anyerror, entry: []const u8 }{
        .{ .members = &.{ .{ .name = "pkg/a", .data = "a" }, .{ .name = "pkg/../escape", .data = "x" } }, .err = error.UnsafeName, .entry = "pkg/../escape" },
        .{ .members = &.{.{ .name = "/etc/passwd", .data = "x" }}, .err = error.UnsafeName, .entry = "/etc/passwd" },
        .{ .members = &.{.{ .name = "pkg/a\\b", .data = "x" }}, .err = error.UnsafeName, .entry = "pkg/a\\b" },
        .{ .members = &.{.{ .name = "pkg/C:x", .data = "x" }}, .err = error.UnsafeName, .entry = "pkg/C:x" },
        .{ .members = &.{.{ .name = "pkg/aux.h", .data = "x" }}, .err = error.UnsafeName, .entry = "pkg/aux.h" },
        .{ .members = &.{.{ .name = "pkg/name.", .data = "x" }}, .err = error.UnsafeName, .entry = "pkg/name." },
        .{ .members = &.{ .{ .name = "pkg/a", .data = "a" }, .{ .name = "pkg/out", .kind = .link, .data = "../../etc/passwd" } }, .err = error.LinkOutside, .entry = "pkg/out" },
        .{ .members = &.{ .{ .name = "pkg/a", .data = "a" }, .{ .name = "pkg/out", .kind = .link, .data = "/etc/passwd" } }, .err = error.LinkOutside, .entry = "pkg/out" },
        // Inside the archive, but outside the tree once its top directory is taken away.
        .{ .members = &.{ .{ .name = "pkg/a", .data = "a" }, .{ .name = "pkg/out", .kind = .link, .data = "../pkg/a" } }, .err = error.LinkOutside, .entry = "pkg/out" },
        .{ .members = &.{ .{ .name = "pkg/a", .data = "a" }, .{ .name = "pkg/b", .kind = .hard_link, .data = "pkg/a" } }, .err = error.UnsupportedEntry, .entry = "pkg/b" },
        .{ .members = &.{ .{ .name = "pkg/Readme", .data = "a" }, .{ .name = "pkg/README", .data = "b" } }, .err = error.NameClash, .entry = "pkg/README" },
        .{ .members = &.{ .{ .name = "pkg/a", .data = "a" }, .{ .name = "pkg/a", .data = "b" } }, .err = error.NameClash, .entry = "pkg/a" },
        // A file written through a link: the link is a name, and nothing goes under it.
        .{ .members = &.{ .{ .name = "pkg/dir", .kind = .link, .data = "real" }, .{ .name = "pkg/real/x", .data = "a" }, .{ .name = "pkg/dir/y", .data = "b" } }, .err = error.NameClash, .entry = "pkg/dir" },
        .{ .members = &.{.{ .name = "pkg/big", .data = &@as([2048]u8, @splat('x')) }}, .err = error.TooLarge, .entry = "pkg/big" },
    }) |case| {
        var fixture: Fixture = try .init(a, try gzipOf(a, try tarOf(a, case.members)));
        defer fixture.deinit();
        const archive = try authenticate(testing.io, a, fixture.path, fixture.expected, .none);
        const into = try std.fs.path.join(a, &.{ std.fs.path.dirname(fixture.path).?, "tree" });
        var diagnostic: Diagnostic = .{};
        try testing.expectError(case.err, unpack(testing.io, a, archive, into, 1024, &diagnostic));
        try testing.expectEqualStrings(case.entry, diagnostic.entry);
        try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, into, .{}));
    }
}

test "a zstd window above 128 MiB is refused from the frame's header, before any of it is decoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarOf(a, &.{.{ .name = "a", .data = "a" }});
    // 2^27 is the bound, taken; 2^28 is past it.
    var at_bound: Fixture = try .init(a, try zstdOf(a, tar, 17));
    defer at_bound.deinit();
    var diagnostic: Diagnostic = .{};
    try expectFile(a, try at_bound.unpacked(a, &diagnostic), "a", "a");
    var past: Fixture = try .init(a, try zstdOf(a, tar, 18));
    defer past.deinit();
    try testing.expectError(error.WindowTooLarge, past.unpacked(a, &diagnostic));
}

test "a stream cut short or damaged is refused as malformed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gzip = try gzipOf(a, try tarOf(a, &.{.{ .name = "pkg/a", .data = &@as([600]u8, @splat('a')) }}));
    var cut: Fixture = try .init(a, gzip[0 .. gzip.len / 2]);
    defer cut.deinit();
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.Malformed, cut.unpacked(a, &diagnostic));
}
