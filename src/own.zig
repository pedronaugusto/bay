//! bay's own version, kept as bay keeps Zig's and Go keeps its `toolchain`
//! line: a package names the bay it is developed with (`.bay_version`), and any
//! other bay hands its command line to that one. The named release's program
//! for this host is downloaded from bay's releases, its minisign signature
//! checked against the key bay is built with, kept under bay's data directory
//! in `bay/<version>`, and used from there without the network.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const release = @import("release");
const dirs = @import("dirs.zig");
const download = @import("download.zig");
const manifest = @import("manifest.zig");
const minisign = @import("minisign.zig");
const say = @import("say.zig");

/// The key bay's releases are signed with, as minisign writes a public key file.
const release_key = minisign.PublicKey.parse(keyLine(@embedFile("release.pub"))) catch
    @compileError("src/release.pub is not a minisign public key");
const releases_url = "https://github.com/pedronaugusto/bay/releases/download";
/// This host's program as a release names it: `bay-aarch64-macos`, `bay-x86_64-windows.exe`.
const asset = "bay-" ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ builtin.target.exeFileExt();
const executable = if (builtin.os.tag == .windows) "bay.exe" else "bay";
/// What a release's program may weigh; bay's are a few MiB.
const program_limit = 64 << 20;

/// Which bay runs a command: this one, or the release of a version.
pub const Choice = union(enum) {
    this,
    version: []const u8,
};

/// `BAY_VERSION` when set: `local` is this bay, anything else the exact version
/// named. Else the version the package's manifest names. Else this bay.
pub fn choose(running: []const u8, override: ?[]const u8, pinned: ?[]const u8) Choice {
    const named = override orelse pinned orelse return .this;
    if (std.mem.eql(u8, named, "local") and override != null) return .this;
    if (std.mem.eql(u8, named, running)) return .this;
    return .{ .version = named };
}

/// Hands this command line to the bay that should run it and ends with that
/// bay's exit; returns when that bay is this one. `package` is the package
/// here, if any. A manifest bay cannot read leaves the command to this bay,
/// which reports it.
pub fn handOver(io: Io, a: std.mem.Allocator, init: std.process.Init, package: ?[]const u8) !void {
    const environ = init.environ_map;
    const pinned = if (package) |p| pinnedIn(io, a, p) else null;
    const version = switch (choose(release.version, environ.get("BAY_VERSION"), pinned)) {
        .this => return,
        .version => |v| v,
    };
    const from = if (environ.get("BAY_VERSION") != null) "BAY_VERSION" else try std.fs.path.join(a, &.{ package.?, "build.zig.zon" }); // safe: only a package pins
    _ = std.SemanticVersion.parse(version) catch try say.fail(io, "{s} names bay {s}, which is not a version: name one as \"0.2.0\", or BAY_VERSION=local for this bay", .{ from, version });
    const other = try path(io, a, environ, version);
    const args = try init.minimal.args.toSlice(a);
    const argv = try std.mem.concat(a, []const u8, &.{ &.{other}, args[1..] });
    // The bay handed to runs as asked, and so does every bay it runs: one bay per command.
    try environ.put("BAY_VERSION", "local");
    if (builtin.os.tag == .windows) {
        var child = std.process.spawn(io, .{ .argv = argv, .environ_map = environ }) catch |err| try say.fail(io, "could not run bay {s} at {s}: {t}", .{ version, other, err });
        std.process.exit(switch (try child.wait(io)) {
            .exited => |code| code,
            else => 1,
        });
    }
    const err = std.process.replace(io, .{ .argv = argv, .environ_map = environ });
    try say.fail(io, "could not run bay {s} at {s}: {t}", .{ version, other, err });
}

/// The bay version the manifest in `package` names; null when it names none or
/// cannot be read.
fn pinnedIn(io: Io, a: std.mem.Allocator, package: []const u8) ?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, std.fs.path.join(a, &.{ package, "build.zig.zon" }) catch return null, a, .limited(1 << 20)) catch return null;
    const parsed = manifest.parse(a, a.dupeSentinel(u8, text, 0) catch return null) catch return null;
    return parsed.bay_version;
}

/// The bay program of exactly `version`, installed first if it is not yet.
/// A version already installed is used without the network.
fn path(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, version: []const u8) ![]const u8 {
    const programs = try std.fs.path.join(a, &.{ try dirs.data(io, a, environ), "bay" });
    const home = try std.fs.path.join(a, &.{ programs, version });
    const program = try std.fs.path.join(a, &.{ home, executable });
    if (try exists(io, program)) return program;
    try Io.Dir.cwd().createDirPath(io, programs);
    // One install at a time: another bay installing waits here, then finds that install's program.
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ programs, "install.lock" }), .{ .lock = .exclusive, .truncate = false });
    defer lock.close(io);
    if (try exists(io, program)) return program;
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    client.initDefaultProxies(a, environ) catch |err| try say.fail(io, "the proxy settings are not usable: {t}", .{err});
    const url = try a.print("{s}/v{s}/{s}", .{ releases_url, version, asset });
    try say.note(io, "downloading bay {s} for {s}", .{ version, asset });
    const bytes = try download.getAlloc(&client, a, url, program_limit);
    const signature_url = try a.print("{s}.minisig", .{url});
    const signature = try download.getAlloc(&client, a, signature_url, 4096);
    checked(bytes, signature, asset, release_key) catch |err| switch (err) {
        error.NotSigned => try say.fail(io, "{s} is not a minisign signature", .{signature_url}),
        error.OtherFile => try say.fail(io, "{s} signs another file than {s}", .{ signature_url, asset }),
        error.Refused => try say.fail(io, "{s} is not the program bay's release key signed: refused", .{url}),
    };
    // Beside the programs, so the last step is a rename within one file system.
    const partial = try a.print("{s}.partial", .{home});
    // What an install that stopped left; the lock says no other is using it.
    try Io.Dir.cwd().deleteTree(io, partial);
    try Io.Dir.cwd().createDirPath(io, partial);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ partial, executable }), .data = bytes, .flags = .{ .permissions = .executable_file } });
    Io.Dir.rename(.cwd(), partial, .cwd(), home, io) catch |err| switch (err) {
        // Windows answers AccessDenied where POSIX answers DirNotEmpty.
        error.DirNotEmpty, error.AccessDenied => if (try exists(io, home))
            try say.fail(io, "{s} is in the way: it is not a whole bay {s}; remove it", .{ home, version })
        else
            return err,
        else => |e| return e,
    };
    try say.note(io, "bay {s} installed in {s}", .{ version, home });
    return program;
}

const CheckError = error{ NotSigned, OtherFile, Refused };

/// Accepts `program` only when `signature_text` is `key`'s signature of it,
/// its trusted comment naming `file`: a signature of another of bay's
/// programs is still bay's.
fn checked(program: []const u8, signature_text: []const u8, file: []const u8, key: minisign.PublicKey) CheckError!void {
    const signature = minisign.Signature.parse(signature_text) catch return error.NotSigned;
    if (!names(signature.trusted_comment, file)) return error.OtherFile;
    minisign.verify(program, signature, key) catch return error.Refused;
}

/// Whether minisign's trusted comment, tab-separated `key:value` fields,
/// names `file` as the file signed.
fn names(comment: []const u8, file: []const u8) bool {
    var fields = std.mem.splitScalar(u8, comment, '\t');
    while (fields.next()) |field| if (std.mem.startsWith(u8, field, "file:")) return std.mem.eql(u8, field["file:".len..], file);
    return false;
}

/// The key itself in a minisign public key file: its last line with text.
fn keyLine(text: []const u8) []const u8 {
    var key: []const u8 = "";
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| key = std.mem.trim(u8, line, " \t");
    return key;
}

fn exists(io: Io, file: []const u8) !bool {
    Io.Dir.cwd().access(io, file, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

const testing = std.testing;

test "the package's bay runs a command, BAY_VERSION overrides it, and local is this bay" {
    try testing.expectEqual(Choice.this, choose("0.2.0", null, null));
    try testing.expectEqual(Choice.this, choose("0.2.0", null, "0.2.0"));
    try testing.expectEqualStrings("0.2.1", choose("0.2.0", null, "0.2.1").version);
    try testing.expectEqualStrings("0.1.9", choose("0.2.0", "0.1.9", "0.2.1").version);
    try testing.expectEqual(Choice.this, choose("0.2.0", "local", "0.2.1"));
    try testing.expectEqual(Choice.this, choose("0.2.0", "0.2.0", "0.2.1"));
    // `local` means this bay only where a person or a bay set it; a manifest names versions.
    try testing.expectEqualStrings("local", choose("0.2.0", null, "local").version);
}

test "a release program is accepted only with the release key's signature naming it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signer: minisign.Signer = try .init(3, "baykey01".*);
    var key_buffer: [64]u8 = undefined;
    const key = try minisign.PublicKey.parse(signer.publicKey(&key_buffer));
    const program = "the bay program for aarch64-macos";
    const signature = try signer.sign(a, program, .prehashed, "timestamp:1\tfile:bay-aarch64-macos");
    try checked(program, signature, "bay-aarch64-macos", key);
    try testing.expectError(error.OtherFile, checked(program, signature, "bay-x86_64-linux", key));
    try testing.expectError(error.Refused, checked("another program", signature, "bay-aarch64-macos", key));
    const stranger: minisign.Signer = try .init(4, "stranger".*);
    try testing.expectError(error.Refused, checked(program, try stranger.sign(a, program, .prehashed, "timestamp:1\tfile:bay-aarch64-macos"), "bay-aarch64-macos", key));
    try testing.expectError(error.NotSigned, checked(program, "not a signature", "bay-aarch64-macos", key));
}

test "a public key file's key is its last line" {
    try testing.expectEqualStrings("RWSabc", keyLine("untrusted comment: minisign public key 1234\nRWSabc\n"));
    try testing.expectEqualStrings("RWSabc", keyLine("RWSabc"));
}
