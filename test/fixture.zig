//! The end-to-end tests' scratch world: a directory of their own with a Zig cache,
//! HOME, data and configuration directories of its own, git reading none of the
//! person's configuration, and bay and the Zig that builds it run there.
const std = @import("std");
const Io = std.Io;
const options = @import("options");

/// Where bay reads its configuration in a fixture, as `dirs.config` finds it on this
/// host: `%APPDATA%\bay` on Windows, `$XDG_CONFIG_HOME/bay` elsewhere.
pub const config_dir = if (@import("builtin").os.tag == .windows) "appdata/bay" else "config/bay";

pub const Fixture = struct {
    a: std.mem.Allocator,
    io: Io,
    /// bay, by its absolute path: the tests run it from the fixture's directories.
    bay_path: []const u8,
    tmp: std.testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,

    pub fn init(a: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        var env = try std.testing.environ.createMap(a);
        try env.put("ZIG", options.zig);
        // One cache for every run, apart from the person's: packages are kept by content, so tests share it safely.
        try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ try Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", a), ".zig-cache", "bay-test-packages" }));
        // And one for what Zig compiles: a fixture's package cloned, checked out to gate or
        // copied to a machine builds once, not once per directory, as do the build runners
        // fixtures share. Zig keys it by content and locks it, so runs share it safely.
        try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ try Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", a), ".zig-cache", "bay-test-builds" }));
        try env.put("HOME", try std.fs.path.join(a, &.{ root, "home" }));
        try env.put("XDG_DATA_HOME", try std.fs.path.join(a, &.{ root, "data" }));
        // bay's configuration (the machines a release is gated on) is the fixture's: none unless a test writes one.
        try env.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ root, "config" }));
        try env.put("APPDATA", try std.fs.path.join(a, &.{ root, "appdata" }));
        // An SSH remote is reached through the tests' stand-in for ssh, never the person's keys or agent.
        try env.put("GIT_SSH", try Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.ssh, a));
        try env.put("GIT_SSH_VARIANT", "simple");
        _ = env.swapRemove("SSH_AUTH_SOCK");
        // Windows keeps bay's data under LOCALAPPDATA: the fixture's too.
        try env.put("LOCALAPPDATA", try std.fs.path.join(a, &.{ root, "local" }));
        // git reads no configuration of the person's: none of the system's, an empty global one.
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(a, &.{ root, "gitconfig" }));
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gitconfig", .data = "" });
        for ([_][]const u8{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" }) |name| try env.put(name, "bay test");
        for ([_][]const u8{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" }) |name| try env.put(name, "test@example.org");
        try env.put("GIT_TERMINAL_PROMPT", "0");
        return .{ .a = a, .io = std.testing.io, .bay_path = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.bay, a), .tmp = tmp, .root = root, .env = env };
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    /// A package with one module, `name`, whose root is `source`, importing each dependency's module.
    pub fn package(f: *Fixture, dir: []const u8, name: []const u8, version: []const u8, dependencies: []const u8, imports: []const []const u8, source: []const u8) !void {
        try f.tmp.dir.createDirPath(f.io, try std.fs.path.join(f.a, &.{ dir, "src" }));
        try f.write(dir, "build.zig.zon", try f.a.print(".{{ .name = .{s}, .version = \"{s}\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{ {s} }} }}\n", .{ name, version, fingerprint(name), dependencies }));
        var build: Io.Writer.Allocating = .init(f.a);
        try build.writer.print("const std = @import(\"std\");\npub fn build(b: *std.Build) void {{\n    const target = b.standardTargetOptions(.{{}});\n    const optimize = b.standardOptimizeOption(.{{}});\n    {s} = b.addModule(\"{s}\", .{{ .root_source_file = b.path(\"src/root.zig\"), .target = target, .optimize = optimize }});\n", .{ if (imports.len == 0) "_" else "const m", name });
        for (imports) |import| try build.writer.print("    m.addImport(\"{s}\", b.dependency(\"{s}\", .{{ .target = target, .optimize = optimize }}).module(\"{s}\"));\n", .{ import, import, import });
        try build.writer.writeAll("}\n");
        try f.write(dir, "build.zig", build.written());
        try f.write(dir, "src/root.zig", source);
    }

    /// An application that runs `main`, importing each dependency's module.
    pub fn application(f: *Fixture, dir: []const u8, dependencies: []const u8, imports: []const []const u8, main: []const u8) !void {
        try f.package(dir, "app", "0.1.0", dependencies, &.{}, "");
        var build: Io.Writer.Allocating = .init(f.a);
        try build.writer.writeAll("const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    const target = b.standardTargetOptions(.{});\n    const optimize = b.standardOptimizeOption(.{});\n    const m = b.createModule(.{ .root_source_file = b.path(\"src/main.zig\"), .target = target, .optimize = optimize });\n");
        for (imports) |import| try build.writer.print("    m.addImport(\"{s}\", b.dependency(\"{s}\", .{{ .target = target, .optimize = optimize }}).module(\"{s}\"));\n", .{ import, import, import });
        try build.writer.writeAll("    const exe = b.addExecutable(.{ .name = \"app\", .root_module = m });\n    b.installArtifact(exe);\n    b.step(\"run\", \"Run\").dependOn(&b.addRunArtifact(exe).step);\n}\n");
        try f.write(dir, "build.zig", build.written());
        try f.write(dir, "src/main.zig", main);
    }

    /// A link at `link`, under the fixture, to the folder `target`, absolute, which any
    /// account makes (`link.folder`).
    /// The tests' Zig installed where bay keeps toolchains, as the version bay was built with,
    /// so that what builds with the Zig a manifest names downloads nothing: its folder linked
    /// there whole, Zig's lib beside it.
    pub fn installZig(f: *Fixture) !void {
        const data: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "local", "bay", "data" } else &.{ "data", "bay" };
        const toolchains = try std.fs.path.join(f.a, try std.mem.concat(f.a, []const u8, &.{ data, &.{"zig"} }));
        try f.tmp.dir.createDirPath(f.io, toolchains);
        const installed = std.fs.path.dirname(try Io.Dir.cwd().realPathFileAlloc(f.io, options.zig, f.a)).?; // safe: a file's real path has a folder
        try f.folderLink(installed, try std.fs.path.join(f.a, &.{ toolchains, @import("builtin").zig_version_string }));
    }

    pub fn folderLink(f: *Fixture, target: []const u8, link: []const u8) !void {
        try @import("link").folder(f.io, target, try std.fs.path.join(f.a, &.{ f.root, link }));
    }

    pub fn write(f: *Fixture, dir: []const u8, name: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(f.io, .{ .sub_path = try std.fs.path.join(f.a, &.{ dir, name }), .data = data });
    }

    /// A dependency entry pinning the package in `dir` by the hash Zig gives it.
    pub fn pin(f: *Fixture, key: []const u8, dir: []const u8) ![]const u8 {
        const absolute = try std.fs.path.join(f.a, &.{ f.root, dir });
        const fetched = try std.process.run(f.a, f.io, .{ .argv = &.{ options.zig, "fetch", absolute }, .environ_map = &f.env });
        try std.testing.expect(succeeded(fetched));
        return f.a.print(".{s} = .{{ .url = \"{s}\", .hash = \"{s}\" }},", .{ key, try fileUrl(f.a, absolute), std.mem.trim(u8, fetched.stdout, "\r\n") });
    }

    /// A URL for the file at `absolute` that Zig's fetch opens: it opens a file URL's
    /// path as written, so a Windows path keeps its drive first (`file:D:/a/t.tar`, the
    /// DOS form RFC 8089 allows), where `file:///D:/a` would be opened as `/D:/a`.
    pub fn fileUrl(a: std.mem.Allocator, absolute: []const u8) ![]const u8 {
        const path = try a.dupe(u8, absolute);
        std.mem.replaceScalar(u8, path, '\\', '/');
        return a.print("file:{s}{s}", .{ if (path[0] == '/') "//" else "", path });
    }

    pub fn run(f: *Fixture, dir: []const u8, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(f.a, f.io, .{ .argv = argv, .cwd = .{ .path = try std.fs.path.join(f.a, &.{ f.root, dir }) }, .environ_map = &f.env });
    }

    pub fn bay(f: *Fixture, dir: []const u8, args: []const []const u8) !std.process.RunResult {
        return f.run(dir, try std.mem.concat(f.a, []const u8, &.{ &.{f.bay_path}, args }));
    }
};

/// A fingerprint Zig accepts for `name`: its checksum above an id.
pub fn fingerprint(name: []const u8) u64 {
    var id = std.hash.XxHash32.hash(0, name);
    if (id == 0 or id == std.math.maxInt(u32)) id = 1;
    return (@as(u64, std.hash.Crc32.hash(name)) << 32) | id;
}

/// A command expected to fail: its output is the point, not a finding.
pub fn refused(result: std.process.RunResult) bool {
    return !(result.term == .exited and result.term.exited == 0);
}

pub fn succeeded(result: std.process.RunResult) bool {
    if (result.term == .exited and result.term.exited == 0) return true;
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    return false;
}
