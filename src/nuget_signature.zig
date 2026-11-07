//! A NuGet package's author signature, checked by cloak's `cloak-nuget-check` (designs/bay.md
//! §11): bay carries no CMS and no trust store of its own. The pin names its root by the root
//! certificate's URL and SHA-256; the certificate is fetched and kept by its digest, as an
//! archive is. The tool is built from the cloak bay pins, as bay pins Zig, with the Zig bay
//! manages, once, and kept by the cloak it was built from.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const archive = @import("archive.zig");
const download = @import("download.zig");
const dirs = @import("dirs.zig");
const say = @import("say.zig");
const toolchain = @import("toolchain.zig");

pub const Context = struct {
    io: Io,
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
};

/// The cloak the check is built from: a commit until cloak releases one with `cms`, then
/// its tag (bay's release refuses a pin that is not a tag).
pub const cloak = .{
    .url = "git+https://github.com/pedronaugusto/cloak#7ba3b839adbac5e6ad0e2db0ae5540b6be47a5f5",
    .hash = "cloak-0.23.1-9onwcc4aWwQVFDKedS3qXp41Vwq0EeRPaUwNHgHcL2BE",
    .zig = "0.17.0",
};

/// The tool's name, as cloak's build installs it.
const tool_name = "cloak-nuget-check";

/// The largest root certificate fetched.
const largest_root = 64 * 1024;

/// Checks the package at `package` (an archive downloaded and held to its digest) against the
/// author signature it carries and the root `root` names. Fails, saying why, otherwise. When
/// `pinning`, the root is downloaded from its URL whatever bay keeps, so a pin never names a
/// URL that does not serve its root.
pub fn check(c: Context, client: *std.http.Client, package: []const u8, url: []const u8, root: manifest.NugetRoot, pinning: bool) !void {
    const io = c.io;
    const root_path = try rootFile(c, client, root, pinning);
    const tool = try toolPath(c);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&root.sha256}) catch unreachable; // 32 bytes are 64 digits
    const result = std.process.run(c.a, io, .{
        .argv = &.{ tool, "--root", root_path, "--root-sha256", &hex, package },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| try say.fail(io, "could not run {s}: {t}", .{ tool, err });
    if (result.term == .exited and result.term.exited == 0) return;
    try say.relay(io, result.stderr);
    try say.fail(io, "{s}: its author's signature does not hold to the root its pin names ({s})", .{ url, root.url });
}

/// The root certificate, kept by its SHA-256 in bay's data directory: fetched once (and always
/// when `fresh`), held to its digest every time.
fn rootFile(c: Context, client: *std.http.Client, root: manifest.NugetRoot, fresh: bool) ![]const u8 {
    const io = c.io;
    const a = c.a;
    const kept = try std.fs.path.join(a, &.{ try dirs.data(io, a, c.environ), "prebuilt", "roots" });
    try Io.Dir.cwd().createDirPath(io, kept);
    const path = try std.fs.path.join(a, &.{ kept, try a.print("{x}.der", .{&root.sha256}) });
    if (!fresh) if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(largest_root))) |bytes| {
        if (holds(bytes, root.sha256)) return path;
    } else |_| {};
    try say.note(io, "downloading {s}", .{root.url});
    const bytes = download.getAlloc(client, a, root.url, largest_root) catch |err| try say.fail(io, "could not download the root {s}: {t}", .{ root.url, err });
    if (!holds(bytes, root.sha256)) try say.fail(io, "{s} is not the root its pin names: its SHA-256 differs", .{root.url});
    const partial = try a.print("{s}.partial", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = bytes });
    try Io.Dir.rename(.cwd(), partial, .cwd(), path, io);
    return path;
}

fn holds(bytes: []const u8, sha256: [32]u8) bool {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    return std.mem.eql(u8, &actual, &sha256);
}

/// The tool, built from `cloak` the first time it is wanted and kept by cloak's hash.
fn toolPath(c: Context) ![]const u8 {
    const io = c.io;
    const a = c.a;
    const tools = try std.fs.path.join(a, &.{ try dirs.data(io, a, c.environ), "tools" });
    try Io.Dir.cwd().createDirPath(io, tools);
    const tool = try std.fs.path.join(a, &.{ tools, try a.print("{s}-{s}", .{ tool_name, cloak.hash }) });
    if (try exists(io, tool)) return tool;
    // One build at a time: another bay building waits here, then finds that build's tool.
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ tools, "build.lock" }), .{ .lock = .exclusive });
    defer lock.close(io);
    if (try exists(io, tool)) return tool;

    const zig = try toolchain.path(io, a, c.environ, cloak.zig);
    try say.note(io, "building {s} from cloak, once", .{tool_name});
    const fetched = std.process.run(a, io, .{ .argv = &.{ zig, "fetch", cloak.url }, .stdout_limit = .limited(1024), .stderr_limit = .limited(16 * 1024) }) catch |err|
        try say.fail(io, "could not run {s} fetch: {t}", .{ zig, err });
    if (fetched.term != .exited or fetched.term.exited != 0) {
        try say.relay(io, fetched.stderr);
        try say.fail(io, "{s} fetch refused {s}", .{ zig, cloak.url });
    }
    if (!std.mem.eql(u8, std.mem.trim(u8, fetched.stdout, " \n"), cloak.hash)) try say.fail(io, "{s} is not the cloak bay pins: it hashes to {s}", .{ cloak.url, fetched.stdout });

    // The package as Zig keeps it, unpacked as bay unpacks an archive, and built there.
    const tarball = try std.fs.path.join(a, &.{ try toolchain.globalCache(io, a, zig), "p", try a.print("{s}.tar.gz", .{cloak.hash}) });
    const work = try std.fs.path.join(a, &.{ tools, "build" });
    try Io.Dir.cwd().deleteTree(io, work);
    defer Io.Dir.cwd().deleteTree(io, work) catch |err| say.note(io, "{s} is left behind: {t}", .{ work, err }) catch {};
    const tree = try std.fs.path.join(a, &.{ work, "tree" });
    var diagnostic: archive.Diagnostic = .{};
    archive.unpack(io, a, .{ .path = tarball, .format = .tar_gzip }, tree, 1 << 30, &diagnostic) catch |err|
        try say.fail(io, "could not unpack cloak ({s}): {t}", .{ tarball, err });
    // bay unpacks as Zig's fetch does: the archive's one top directory is the tree.
    const source = tree;
    const prefix = try std.fs.path.join(a, &.{ work, "out" });
    const built = std.process.run(a, io, .{
        .argv = &.{ zig, "build", "--prefix", prefix, "-Doptimize=ReleaseSafe" },
        .cwd = .{ .path = source },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| try say.fail(io, "could not run {s} build: {t}", .{ zig, err });
    if (built.term != .exited or built.term.exited != 0) {
        try say.relay(io, built.stderr);
        try say.fail(io, "cloak's {s} did not build", .{tool_name});
    }
    try Io.Dir.rename(.cwd(), try std.fs.path.join(a, &.{ prefix, "bin", tool_name }), .cwd(), tool, io);
    return tool;
}

fn exists(io: Io, path: []const u8) !bool {
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}
