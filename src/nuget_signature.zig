//! A NuGet package's author signature, checked by cloak's `cloak-nuget-check` (designs/bay.md
//! §11): bay carries no CMS and no trust store of its own. The pin names its root by the root
//! certificate's URL and SHA-256; the certificate is fetched and kept by its digest, as an
//! archive is. The tool is built from the cloak bay pins, as bay pins Zig, with the Zig bay
//! manages, once, and kept by the cloak it was built from; a project that lists cloak among its
//! own dependencies or tools has its cloak's tool instead (`chosen`).
const std = @import("std");
const intake = @import("intake.zig");
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
    /// The Zig the project builds with: the one a project's own cloak is built with.
    zig: []const u8,
    /// The project's own cloak (`chosen`), or null for bay's.
    cloak: ?Cloak = null,
};

/// A cloak the check is built from.
pub const Cloak = union(enum) {
    /// Fetched by Zig, held to its hash, built once and kept by it.
    remote: struct { url: []const u8, hash: []const u8 },
    /// A checkout, built from where it is each time it is wanted.
    path: []const u8,
};

/// The cloak bay pins, as it pins Zig: a commit until cloak releases one with `cms`, then
/// its tag (bay's release refuses a pin that is not a tag).
pub const pinned = .{
    .url = "git+https://github.com/pedronaugusto/cloak#7ba3b839adbac5e6ad0e2db0ae5540b6be47a5f5",
    .hash = "cloak-0.23.1-9onwcc4aWwQVFDKedS3qXp41Vwq0EeRPaUwNHgHcL2BE",
    .zig = "0.17.0",
};

/// The project's own cloak, which wins over bay's: the dependency named `cloak` among its
/// tools (`.dev_dependencies`) or, failing that, its dependencies; a path is resolved from
/// `directory`, the project's. Null: bay's.
pub fn chosen(a: std.mem.Allocator, project: manifest.Manifest, directory: []const u8) !?Cloak {
    for ([_][]const manifest.Dependency{ project.dev, project.normal }) |list| for (list) |dependency| {
        if (!std.mem.eql(u8, dependency.name, "cloak")) continue;
        return switch (dependency.source) {
            .remote => |remote| .{ .remote = .{ .url = remote.url, .hash = remote.hash } },
            .path => |path| .{ .path = try std.fs.path.resolveAlloc(a, &.{ directory, path }) },
        };
    };
    return null;
}

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
    const hex = std.fmt.bytesToHex(root.sha256, .lower);
    const result = intake.run(c.a, io, .{
        .argv = &.{ tool, "--root", root_path, "--root-sha256", &hex, package },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| try say.fail(io, "could not run {s}: {t}", .{ tool, err });
    if (result.term == .exited and result.term.exited == 0) return;
    try say.relay(io, result.stderr.readForParse());
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
    // glint-ignore: Z026 -- a kept root that cannot be read is downloaded again below
    if (!fresh) if (intake.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(largest_root))) |kept_root_read| {
        const kept_root = kept_root_read.readForParse();
        if (holds(kept_root, root.sha256)) return path;
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

/// The tool: from the project's own cloak when it lists one, else from bay's; a fetched one
/// built the first time it is wanted and kept by its hash.
fn toolPath(c: Context) ![]const u8 {
    const io = c.io;
    const a = c.a;
    const tools = try std.fs.path.join(a, &.{ try dirs.data(io, a, c.environ), "tools" });
    try Io.Dir.cwd().createDirPath(io, tools);
    const remote: struct { url: []const u8, hash: []const u8, zig: []const u8 } = switch (c.cloak orelse Cloak{ .remote = .{ .url = pinned.url, .hash = pinned.hash } }) {
        .path => |path| return build(c, tools, path, c.zig, try std.fs.path.join(a, &.{ tools, try a.print("{s}-checkout", .{tool_name}) })),
        .remote => |r| .{ .url = r.url, .hash = r.hash, .zig = if (c.cloak == null) try toolchain.path(io, a, c.environ, pinned.zig) else c.zig },
    };
    const tool = try std.fs.path.join(a, &.{ tools, try a.print("{s}-{s}", .{ tool_name, remote.hash }) });
    if (try exists(io, tool)) return tool;
    // One build at a time: another bay building waits here, then finds that build's tool.
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ tools, "build.lock" }), .{ .lock = .exclusive });
    defer lock.close(io);
    if (try exists(io, tool)) return tool;
    try say.note(io, "building {s} from cloak {s}, once", .{ tool_name, remote.hash });
    const fetched = intake.run(a, io, .{ .argv = &.{ remote.zig, "fetch", remote.url }, .stdout_limit = .limited(1024), .stderr_limit = .limited(16 * 1024) }) catch |err|
        try say.fail(io, "could not run {s} fetch: {t}", .{ remote.zig, err });
    if (fetched.term != .exited or fetched.term.exited != 0) {
        try say.relay(io, fetched.stderr.readForParse());
        try say.fail(io, "{s} fetch refused {s}", .{ remote.zig, remote.url });
    }
    if (!std.mem.eql(u8, std.mem.trim(u8, fetched.stdout.readForParse(), " \n"), remote.hash)) try say.fail(io, "{s} is not the cloak pinned as {s}: it hashes to {s}", .{ remote.url, remote.hash, fetched.stdout.readForParse() });
    // The package as Zig keeps it, unpacked as bay unpacks an archive (its one top directory
    // the tree), and built there.
    const tarball = try std.fs.path.join(a, &.{ try toolchain.globalCache(io, a, remote.zig), "p", try a.print("{s}.tar.gz", .{remote.hash}) });
    const work = try std.fs.path.join(a, &.{ tools, "build" });
    try Io.Dir.cwd().deleteTree(io, work);
    // glint-ignore: Z026 -- a note that cannot be written leaves the tree behind unsaid, nothing worse
    defer Io.Dir.cwd().deleteTree(io, work) catch |err| say.note(io, "{s} is left behind: {t}", .{ work, err }) catch {};
    const tree = try std.fs.path.join(a, &.{ work, "tree" });
    var diagnostic: archive.Diagnostic = .{};
    archive.unpack(io, a, .{ .path = tarball, .format = .tar_gzip }, tree, 1 << 30, &diagnostic) catch |err|
        try say.fail(io, "could not unpack cloak ({s}): {t}", .{ tarball, err });
    return build(c, tools, tree, remote.zig, tool);
}

/// cloak's tool built from the cloak at `source` with `zig`, put at `tool`.
fn build(c: Context, tools: []const u8, source: []const u8, zig: []const u8, tool: []const u8) ![]const u8 {
    const io = c.io;
    const a = c.a;
    const prefix = try std.fs.path.join(a, &.{ tools, "build-out" });
    try Io.Dir.cwd().deleteTree(io, prefix);
    // glint-ignore: Z026 -- a note that cannot be written leaves the tree behind unsaid, nothing worse
    defer Io.Dir.cwd().deleteTree(io, prefix) catch |err| say.note(io, "{s} is left behind: {t}", .{ prefix, err }) catch {};
    const built = intake.run(a, io, .{
        .argv = &.{ zig, "build", "--prefix", prefix, "-Doptimize=ReleaseSafe" },
        .cwd = .{ .path = source },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| try say.fail(io, "could not run {s} build in {s}: {t}", .{ zig, source, err });
    if (built.term != .exited or built.term.exited != 0) {
        try say.relay(io, built.stderr.readForParse());
        try say.fail(io, "cloak's {s} did not build in {s}", .{ tool_name, source });
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

const testing = std.testing;

fn projectWith(a: std.mem.Allocator, deps: []const u8) !manifest.Manifest {
    return manifest.parse(a, try a.dupeSentinel(u8, try a.print(".{{ .name = .p, .version = \"0.0.0\", .fingerprint = 0x1, .dependencies = .{{}}, .dev_dependencies = .{{ {s} }} }}", .{deps}), 0));
}

test "a project with cloak among its tools has its own cloak's check, and one without has bay's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const own = try projectWith(a, ".cloak = .{ .url = \"git+https://github.com/pedronaugusto/cloak#0123456789abcdef0123456789abcdef01234567\", .hash = \"cloak-0.24.0-AAAA\" }");
    const remote = (try chosen(a, own, "/p")).?.remote;
    try testing.expectEqualStrings("cloak-0.24.0-AAAA", remote.hash);
    const checkout = try projectWith(a, ".cloak = .{ .path = \"../cloak\" }");
    // Resolved as the system writes paths: `\cloak` on Windows.
    try testing.expectEqualStrings(std.fs.path.sep_str ++ "cloak", (try chosen(a, checkout, "/p")).?.path);
    const none = try projectWith(a, ".other = .{ .path = \"../cloak\" }");
    try testing.expectEqual(@as(?Cloak, null), try chosen(a, none, "/p"));
}
