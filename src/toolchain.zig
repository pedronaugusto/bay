//! Zig toolchains, kept as Go's `toolchain` line and rustup keep theirs: an
//! exact Zig version's official build for this host, downloaded from
//! ziglang.org, its digest and minisign signature verified, unpacked under bay's
//! data directory in `zig/<version>`, and used from there without the network.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const dirs = @import("dirs.zig");
const download = @import("download.zig");
const minisign = @import("minisign.zig");
const say = @import("say.zig");

/// The key Zig signs its builds with, as ziglang.org/download publishes it.
const zig_key = minisign.PublicKey.parse("RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U") catch
    @compileError("Zig's public key does not parse");
const index_url = "https://ziglang.org/download/index.json";
/// This host as the index names builds: `aarch64-macos`, `x86_64-linux`, ...
const host = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
const executable = if (builtin.os.tag == .windows) "zig.exe" else "zig";

/// The zig executable of exactly `version`, installed first if it is not yet.
/// A version already installed is used without the network.
pub fn path(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, version: []const u8) ![]const u8 {
    // A version is also a directory name: only what semantic versions allow reaches the file system.
    _ = std.SemanticVersion.parse(version) catch try say.fail(io, "{s} is not a Zig version", .{version});
    const toolchains = try std.fs.path.join(a, &.{ try dirs.data(io, a, environ), "zig" });
    const home = try std.fs.path.join(a, &.{ toolchains, version });
    const zig = try std.fs.path.join(a, &.{ home, executable });
    if (try exists(io, zig)) return zig;
    try Io.Dir.cwd().createDirPath(io, toolchains);
    // One install at a time: another bay installing waits here, then finds that install's Zig.
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ toolchains, "install.lock" }), .{ .lock = .exclusive, .truncate = false });
    defer lock.close(io);
    if (try exists(io, zig)) return zig;
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    client.initDefaultProxies(a, environ) catch |err| try say.fail(io, "the proxy settings are not usable: {t}", .{err});
    try install(io, a, &client, version, home);
    return zig;
}

/// Downloads `version`'s build for this host, verifies it, and unpacks it to
/// `home` in one rename: a bay that finds `home` finds the whole toolchain.
fn install(io: Io, a: std.mem.Allocator, client: *std.http.Client, version: []const u8, home: []const u8) !void {
    const index = try download.getAlloc(client, a, index_url, 16 << 20);
    const build = lookup(a, index, version, host) catch |err| switch (err) {
        error.UnknownVersion => try say.fail(io, "ziglang.org has no Zig {s}; its index has {s}", .{ version, try known(a, index) }),
        error.NoBuildForHost => try say.fail(io, "Zig {s} has no build for {s} on ziglang.org", .{ version, host }),
        error.InvalidIndex => try say.fail(io, "{s} is not an index bay can read", .{index_url}),
        error.InvalidBuild => try say.fail(io, "{s} lists Zig {s} for {s} without a tarball, sha256 and size bay can read", .{ index_url, version, host }),
        error.OutOfMemory => |e| return e,
    };
    const file = std.fs.path.basenamePosix(build.url);
    const signature_url = try a.print("{s}.minisig", .{build.url});
    const signature_text = try download.getAlloc(client, a, signature_url, 4096);
    const signature = minisign.Signature.parse(signature_text) catch |err|
        try say.fail(io, "{s} is not a minisign signature: {t}", .{ signature_url, err });
    var verifier = minisign.Verifier.init(signature, zig_key) catch |err|
        try say.fail(io, "{s} is not Zig's signature: {t}", .{ signature_url, err });
    // A signature for another of Zig's files is still Zig's: the trusted comment names the file it signs.
    if (!signs(signature.trusted_comment, file)) try say.fail(io, "{s} signs another file than {s}: {s}", .{ signature_url, file, signature.trusted_comment });

    // Beside the toolchains, so the last step is a rename within one file system.
    const partial = try a.print("{s}.partial", .{home});
    // What an install that stopped left; the lock says no other is using it.
    try Io.Dir.cwd().deleteTree(io, partial);
    try Io.Dir.cwd().createDirPath(io, partial);
    // Named by bay, not by the index's URL, which no signature covers.
    const archive = try std.fs.path.join(a, &.{ partial, if (builtin.os.tag == .windows) "archive.zip" else "archive.tar.xz" });
    try say.note(io, "downloading Zig {s} for {s}", .{ version, host });
    try fetch(io, client, build, archive);
    try check(io, archive, build, &verifier);
    const tree = try std.fs.path.join(a, &.{ partial, "tree" });
    try unpack(io, a, archive, tree);
    const root = try std.fs.path.join(a, &.{ tree, try onlyDirectory(io, a, tree, file) });
    if (!try exists(io, try std.fs.path.join(a, &.{ root, executable }))) try say.fail(io, "{s} holds no {s}", .{ file, executable });
    Io.Dir.rename(.cwd(), root, .cwd(), home, io) catch |err| switch (err) {
        // Windows answers AccessDenied where POSIX answers DirNotEmpty.
        error.DirNotEmpty, error.AccessDenied => if (try exists(io, home))
            try say.fail(io, "{s} is in the way: it is not a whole Zig {s}; remove it", .{ home, version })
        else
            return err,
        else => |e| return e,
    };
    try Io.Dir.cwd().deleteTree(io, partial);
    try say.note(io, "Zig {s} installed in {s}", .{ version, home });
}

/// One build in ziglang.org's index.
pub const Build = struct {
    url: []const u8,
    sha256: [Sha256.digest_length]u8,
    size: u64,
};

pub const LookupError = error{ UnknownVersion, NoBuildForHost, InvalidIndex, InvalidBuild, OutOfMemory };

/// The build of `version` for `target` (`aarch64-macos`) in the index `text`.
/// A release is found by its version; a development version only as the
/// index's `master`, when that is exactly it.
pub fn lookup(a: std.mem.Allocator, text: []const u8, version: []const u8, target: []const u8) LookupError!Build {
    const index = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.InvalidIndex,
    };
    if (index != .object) return error.InvalidIndex;
    const release = if (index.object.get("master")) |master| match: {
        if (master != .object) return error.InvalidIndex;
        const master_version = master.object.get("version") orelse return error.InvalidIndex;
        if (master_version == .string and std.mem.eql(u8, master_version.string, version)) break :match master;
        break :match index.object.get(version);
    } else index.object.get(version);
    const entry = release orelse return error.UnknownVersion;
    if (entry != .object) return error.InvalidIndex;
    const build = entry.object.get(target) orelse return error.NoBuildForHost;
    if (build != .object) return error.InvalidBuild;
    const url = string(build, "tarball") orelse return error.InvalidBuild;
    var digest: [Sha256.digest_length]u8 = undefined;
    const sha = string(build, "shasum") orelse return error.InvalidBuild;
    if (sha.len != 2 * digest.len) return error.InvalidBuild;
    _ = std.fmt.hexToBytes(&digest, sha) catch return error.InvalidBuild;
    const size = std.fmt.parseUnsigned(u64, string(build, "size") orelse return error.InvalidBuild, 10) catch return error.InvalidBuild;
    return .{ .url = url, .sha256 = digest, .size = size };
}

fn string(object: std.json.Value, field: []const u8) ?[]const u8 {
    const value = object.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// The versions the index `text` has, newest first as it lists them; master by
/// the development version it is.
fn known(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const index = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return "nothing bay can read";
    if (index != .object) return "nothing bay can read";
    var list: std.ArrayList(u8) = .empty;
    var it = index.object.iterator();
    while (it.next()) |entry| {
        if (list.items.len != 0) try list.appendSlice(a, ", ");
        const name = if (std.mem.eql(u8, entry.key_ptr.*, "master") and entry.value_ptr.* == .object) string(entry.value_ptr.*, "version") orelse "master" else entry.key_ptr.*;
        try list.appendSlice(a, name);
    }
    return list.items;
}

/// Whether minisign's trusted comment, tab-separated `key:value` fields as
/// Zig writes it, names `file` as the file signed.
fn signs(comment: []const u8, file: []const u8) bool {
    var fields = std.mem.splitScalar(u8, comment, '\t');
    while (fields.next()) |field| if (std.mem.startsWith(u8, field, "file:")) return std.mem.eql(u8, field["file:".len..], file);
    return false;
}

/// Downloads `build` to `archive`, no longer than the index says it is.
fn fetch(io: Io, client: *std.http.Client, build: Build, archive: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, archive, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const length = download.get(client, build.url, &writer.interface, build.size) catch |err| switch (err) {
        error.WriteFailed => return writer.err orelse err,
        else => |e| return e,
    };
    try writer.flush();
    if (length != build.size) try say.fail(io, "{s} is {d} bytes; the index says {d}", .{ build.url, length, build.size });
}

/// Refuses `archive` unless it is the build the index names and Zig signed.
fn check(io: Io, archive: []const u8, build: Build, verifier: *minisign.Verifier) !void {
    const file = try Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &.{});
    var sha256: Sha256 = .init(.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buffer) catch return reader.err orelse error.ReadFailed;
        sha256.update(buffer[0..n]);
        verifier.update(buffer[0..n]);
        if (n < buffer.len) break;
    }
    if (!std.mem.eql(u8, &sha256.finalResult(), &build.sha256)) try say.fail(io, "{s}'s sha256 is not the one ziglang.org's index gives", .{build.url});
    verifier.verify() catch |err| try say.fail(io, "{s} is not the file Zig signed: {t}", .{ build.url, err });
}

/// Unpacks the archive: a tar.xz, or on Windows a zip.
fn unpack(io: Io, a: std.mem.Allocator, archive: []const u8, into: []const u8) !void {
    var dir = try Io.Dir.cwd().createDirPathOpen(io, into, .{});
    defer dir.close(io);
    const file = try Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    if (builtin.os.tag == .windows) {
        std.zip.extract(dir, &reader, .{}) catch |err| try say.fail(io, "could not unzip {s}: {t}", .{ archive, err });
        return;
    }
    var xz = std.compress.xz.Decompress.init(&reader.interface, a, &.{}) catch |err|
        try say.fail(io, "{s} is not xz: {t}", .{ archive, err });
    defer xz.deinit();
    std.tar.extract(io, dir, &xz.reader, .{}) catch |err| switch (err) {
        error.ReadFailed => {
            if (reader.err) |cause| try say.fail(io, "could not read {s}: {t}", .{ archive, cause });
            try say.fail(io, "could not unpack {s}: {t}", .{ archive, xz.err orelse err });
        },
        else => try say.fail(io, "could not unpack {s}: {t}", .{ archive, err }),
    };
}

/// The one directory `tree` holds, as Zig's archives hold their build.
fn onlyDirectory(io: Io, a: std.mem.Allocator, tree: []const u8, archive: []const u8) ![]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, tree, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    const first = try it.next(io) orelse try say.fail(io, "{s} is empty", .{archive});
    if (first.kind != .directory or try it.next(io) != null) try say.fail(io, "{s} does not hold one directory", .{archive});
    return a.dupe(u8, first.name);
}

fn exists(io: Io, file: []const u8) !bool {
    Io.Dir.cwd().access(io, file, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

const testing = std.testing;

/// Two entries of ziglang.org's index as it read on 2026-10-11, trimmed to two hosts.
const recorded_index =
    \\{
    \\  "master": {
    \\    "version": "0.18.0-dev.146+35accc06e",
    \\    "date": "2026-10-09",
    \\    "aarch64-macos": {
    \\      "tarball": "https://ziglang.org/builds/zig-aarch64-macos-0.18.0-dev.146+35accc06e.tar.xz",
    \\      "shasum": "7200a37ab074878c28e4baa3608667b99ceef2bdccd7fa8009014a71f529a242",
    \\      "size": "55278412"
    \\    }
    \\  },
    \\  "0.17.0": {
    \\    "date": "2026-10-01",
    \\    "aarch64-macos": {
    \\      "tarball": "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
    \\      "shasum": "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    \\      "size": "53985220"
    \\    },
    \\    "x86_64-windows": {
    \\      "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
    \\      "shasum": "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
    \\      "size": "100268137"
    \\    }
    \\  }
    \\}
;

test "a release is found by its version, a development version only as master" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const release = try lookup(a, recorded_index, "0.17.0", "x86_64-windows");
    try testing.expectEqualStrings("https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip", release.url);
    try testing.expectEqual(100268137, release.size);
    try testing.expectEqual(0xb5, release.sha256[0]);
    const master = try lookup(a, recorded_index, "0.18.0-dev.146+35accc06e", "aarch64-macos");
    try testing.expectEqualStrings("https://ziglang.org/builds/zig-aarch64-macos-0.18.0-dev.146+35accc06e.tar.xz", master.url);
    try testing.expectError(error.UnknownVersion, lookup(a, recorded_index, "0.18.0-dev.140+0123abcde", "aarch64-macos"));
    try testing.expectError(error.UnknownVersion, lookup(a, recorded_index, "0.9.0", "aarch64-macos"));
    try testing.expectError(error.NoBuildForHost, lookup(a, recorded_index, "0.17.0", "riscv64-linux"));
    try testing.expectError(error.InvalidIndex, lookup(a, "[]", "0.17.0", "aarch64-macos"));
    try testing.expectError(error.InvalidBuild, lookup(a, "{\"0.17.0\": {\"aarch64-macos\": {\"tarball\": \"x\", \"shasum\": \"00\", \"size\": \"1\"}}}", "0.17.0", "aarch64-macos"));
    try testing.expectEqualStrings("0.18.0-dev.146+35accc06e, 0.17.0", try known(a, recorded_index));
}

test "the trusted comment must name the file downloaded" {
    try testing.expect(signs("timestamp:1790965659\tfile:zig-aarch64-macos-0.17.0.tar.xz\thashed", "zig-aarch64-macos-0.17.0.tar.xz"));
    try testing.expect(!signs("timestamp:1790965659\tfile:zig-aarch64-macos-0.16.0.tar.xz\thashed", "zig-aarch64-macos-0.17.0.tar.xz"));
    try testing.expect(!signs("timestamp:1790965659", "zig-aarch64-macos-0.17.0.tar.xz"));
}

test {
    _ = minisign;
}
