//! bay end to end over real packages: the diamond Zig alone cannot build, a
//! tie the root decides, tidy, the package under development linked by its own
//! tools, a vendored project built with no cache and no network, overrides, and
//! a command run across a workspace in order. Each test works in a directory of
//! its own, with a Zig cache, HOME and data directory of its own, and the Zig
//! that builds bay, so nothing is downloaded.
const std = @import("std");
const Io = std.Io;
const options = @import("options");

const Fixture = struct {
    a: std.mem.Allocator,
    io: Io,
    /// bay, by its absolute path: the tests run it from the fixture's directories.
    bay_path: []const u8,
    tmp: std.testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,

    fn init(a: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        var env = try std.testing.environ.createMap(a);
        try env.put("ZIG", options.zig);
        // One cache for every run, apart from the person's: packages are kept by content, so tests share it safely.
        try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ try Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", a), ".zig-cache", "bay-test-packages" }));
        try env.put("HOME", try std.fs.path.join(a, &.{ root, "home" }));
        try env.put("XDG_DATA_HOME", try std.fs.path.join(a, &.{ root, "data" }));
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

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    /// A package with one module, `name`, whose root is `source`, importing each dependency's module.
    fn package(f: *Fixture, dir: []const u8, name: []const u8, version: []const u8, dependencies: []const u8, imports: []const []const u8, source: []const u8) !void {
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
    fn application(f: *Fixture, dir: []const u8, dependencies: []const u8, imports: []const []const u8, main: []const u8) !void {
        try f.package(dir, "app", "0.1.0", dependencies, &.{}, "");
        var build: Io.Writer.Allocating = .init(f.a);
        try build.writer.writeAll("const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    const target = b.standardTargetOptions(.{});\n    const optimize = b.standardOptimizeOption(.{});\n    const m = b.createModule(.{ .root_source_file = b.path(\"src/main.zig\"), .target = target, .optimize = optimize });\n");
        for (imports) |import| try build.writer.print("    m.addImport(\"{s}\", b.dependency(\"{s}\", .{{ .target = target, .optimize = optimize }}).module(\"{s}\"));\n", .{ import, import, import });
        try build.writer.writeAll("    const exe = b.addExecutable(.{ .name = \"app\", .root_module = m });\n    b.installArtifact(exe);\n    b.step(\"run\", \"Run\").dependOn(&b.addRunArtifact(exe).step);\n}\n");
        try f.write(dir, "build.zig", build.written());
        try f.write(dir, "src/main.zig", main);
    }

    fn write(f: *Fixture, dir: []const u8, name: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(f.io, .{ .sub_path = try std.fs.path.join(f.a, &.{ dir, name }), .data = data });
    }

    /// A dependency entry pinning the package in `dir` by the hash Zig gives it.
    fn pin(f: *Fixture, key: []const u8, dir: []const u8) ![]const u8 {
        const absolute = try std.fs.path.join(f.a, &.{ f.root, dir });
        const fetched = try std.process.run(f.a, f.io, .{ .argv = &.{ options.zig, "fetch", absolute }, .environ_map = &f.env });
        try std.testing.expect(succeeded(fetched));
        // A file URL's path starts with `/` and has `/` between its parts: `file:///D:/a` on Windows.
        const path = try f.a.dupe(u8, absolute);
        std.mem.replaceScalar(u8, path, '\\', '/');
        return f.a.print(".{s} = .{{ .url = \"file://{s}{s}\", .hash = \"{s}\" }},", .{ key, if (path[0] == '/') "" else "/", path, std.mem.trim(u8, fetched.stdout, "\r\n") });
    }

    fn run(f: *Fixture, dir: []const u8, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(f.a, f.io, .{ .argv = argv, .cwd = .{ .path = try std.fs.path.join(f.a, &.{ f.root, dir }) }, .environ_map = &f.env });
    }

    fn bay(f: *Fixture, dir: []const u8, args: []const []const u8) !std.process.RunResult {
        return f.run(dir, try std.mem.concat(f.a, []const u8, &.{ &.{f.bay_path}, args }));
    }
};

/// A fingerprint Zig accepts for `name`: its checksum above an id.
fn fingerprint(name: []const u8) u64 {
    var id = std.hash.XxHash32.hash(0, name);
    if (id == 0 or id == std.math.maxInt(u32)) id = 1;
    return @as(u64, std.hash.Crc32.hash(name)) << 32 | id;
}

/// A command expected to fail: its output is the point, not a finding.
fn refused(result: std.process.RunResult) bool {
    return !(result.term == .exited and result.term.exited == 0);
}

fn succeeded(result: std.process.RunResult) bool {
    if (result.term == .exited and result.term.exited == 0) return true;
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    return false;
}

const shared = "pub const T = struct { x: u32 }; pub var count: u32 = 0;";
const using_a = "const c = @import(\"c\"); pub fn make() c.T { c.count += 1; return .{ .x = 1 }; } pub const seen = c.version;";
const using_b = "const c = @import(\"c\"); pub fn take(t: c.T) u32 { c.count += 1; return t.x + c.count; } pub const seen = c.version;";
const main_ab = "const std = @import(\"std\"); const a = @import(\"a\"); const b = @import(\"b\"); pub fn main() void { std.debug.print(\"a sees {s}, b sees {s}, total {d}\\n\", .{ a.seen, b.seen, b.take(a.make()) }); }";

/// c at 0.1.0 and 0.1.1; a pins the first, b the second.
fn diamond(f: *Fixture) !void {
    try f.package("c1", "c", "0.1.0", "", &.{}, "pub const version = \"0.1.0\"; " ++ shared);
    try f.package("c2", "c", "0.1.1", "", &.{}, "pub const version = \"0.1.1\"; " ++ shared);
    try f.package("a", "a", "0.1.0", try f.pin("c", "c1"), &.{"c"}, using_a);
    try f.package("b", "b", "0.1.0", try f.pin("c", "c2"), &.{"c"}, using_b);
}

test "the diamond Zig cannot build builds with one c, the highest pinned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b") }), &.{ "a", "b" }, main_ab);
    const plain = try f.run("app", &.{ options.zig, "build", "run" });
    if (std.mem.find(u8, plain.stderr, "expected type") == null) std.debug.print("plain zig build:\n{s}\n", .{plain.stderr});
    try std.testing.expect(std.mem.find(u8, plain.stderr, "expected type") != null);
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "a sees 0.1.1, b sees 0.1.1, total 3") != null);
    const duplicates = try f.bay("app", &.{ "tree", "--duplicates" });
    try std.testing.expect(succeeded(duplicates));
    try std.testing.expect(std.mem.find(u8, duplicates.stdout, "(built), pinned by b 0.1.0") != null);
}

test "two contents at the selected version are refused, and the root's own pin decides" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    try f.package("c3", "c", "0.1.1", "", &.{}, "pub const version = \"0.1.1 again\"; " ++ shared);
    try f.package("d", "d", "0.1.0", try f.pin("c", "c3"), &.{"c"}, "const c = @import(\"c\"); pub const seen = c.version;");
    const pins = try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b"), try f.pin("d", "d") });
    try f.application("app", pins, &.{ "a", "b" }, main_ab);
    const tied = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(refused(tied));
    try std.testing.expect(std.mem.find(u8, tied.stderr, "c 0.1.1 is two contents") != null);
    try f.application("app", try std.mem.concat(f.a, u8, &.{ pins, try f.pin("c", "c3") }), &.{ "a", "b" }, main_ab);
    const decided = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(decided));
    try std.testing.expect(std.mem.find(u8, decided.stderr, "a sees 0.1.1 again") != null);
}

test "a root pinned below the selection is refused until tidy raises it, and --locked never writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b"), try f.pin("c", "c1") }), &.{ "a", "b", "c" }, main_ab);
    const below = try f.bay("app", &.{"build"});
    try std.testing.expect(refused(below));
    try std.testing.expect(std.mem.find(u8, below.stderr, "bay tidy writes it") != null);
    const locked = try f.bay("app", &.{ "--locked", "tidy" });
    try std.testing.expect(refused(locked));
    const tidied = try f.bay("app", &.{"tidy"});
    try std.testing.expect(succeeded(tidied));
    const text = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    try std.testing.expect(std.mem.find(u8, text, "c-0.1.1-") != null);
    try std.testing.expect(succeeded(try f.bay("app", &.{ "build", "run" })));
    try std.testing.expect(succeeded(try f.bay("app", &.{ "--locked", "tidy" })));
}

test "a dev tool built on the package links the package under development" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // c under development: the tool `a` pins c 0.1.0, yet links this working tree.
    try f.package("work", "c", "0.2.0", "", &.{}, "pub const version = \"0.2.0 working\"; " ++ shared);
    try f.write("work", "build.zig.zon", try f.a.print(".{{ .name = .c, .version = \"0.2.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{}}, .dev_dependencies = .{{ {s} }} }}\n", .{ fingerprint("c"), try f.pin("a", "a") }));
    try f.write("work", "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("c", .{ .root_source_file = b.path("src/root.zig"), .target = b.standardTargetOptions(.{}), .optimize = b.standardOptimizeOption(.{}) });
        \\}
        \\pub fn dev(b: *std.Build, tools: type) void {
        \\    _ = tools;
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const c = b.dependency("c", .{ .target = target, .optimize = optimize }).module("c");
        \\    const a = b.dependency("a", .{ .target = target, .optimize = optimize }).module("a");
        \\    const check = b.addWriteFiles().add("check.zig", "const std = @import(\"std\"); const c = @import(\"c\"); const a = @import(\"a\"); pub fn main() void { const t: c.T = a.make(); std.debug.print(\"under test {s}, the tool sees {s}, {d}\\n\", .{ c.version, a.seen, t.x }); }");
        \\    const exe = b.addExecutable(.{ .name = "check", .root_module = b.createModule(.{ .root_source_file = check, .target = target, .optimize = optimize, .imports = &.{ .{ .name = "c", .module = c }, .{ .name = "a", .module = a } } }) });
        \\    b.step("check", "Run the tool against the package").dependOn(&b.addRunArtifact(exe).step);
        \\}
        \\
    );
    const checked = try f.bay("work", &.{"check"});
    try std.testing.expect(succeeded(checked));
    try std.testing.expect(std.mem.find(u8, checked.stderr, "under test 0.2.0 working, the tool sees 0.2.0 working, 1") != null);
}

test "a vendored package resolves and builds with its packages in no cache and no remote" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // A development tool too: the development build reads the same zig-pkg.
    try f.package("tl", "tl", "0.1.0", "", &.{}, "pub const tool = true;");
    const pins = try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b") });
    try f.application("app", pins, &.{ "a", "b" }, main_ab);
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    const close = std.mem.findLast(u8, manifest, "}").?; // safe: the fixture's manifest ends in a brace
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .dev_dependencies = .{{ {s} }} }}\n", .{ std.mem.trimEnd(u8, manifest[0..close], " "), try f.pin("tl", "tl") }));
    const build = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig", f.a, .limited(1 << 20));
    try f.write("app", "build.zig", try f.a.print("{s}pub fn dev(b: *std.Build, tools: type) void {{\n    _ = tools;\n    _ = b.step(\"tool\", \"\");\n}}\n", .{build}));
    try std.testing.expect(succeeded(try f.bay("app", &.{"vendor"})));
    try f.tmp.dir.deleteTree(f.io, "app/.zig-cache");
    // The cache keeps what Zig compiled, which is no package: each package vendored
    // is taken out of it, extracted or archived.
    const packages = try std.fs.path.join(f.a, &.{ f.env.get("ZIG_GLOBAL_CACHE_DIR").?, "p" });
    var vendored = try f.tmp.dir.openDir(f.io, "app/zig-pkg", .{ .iterate = true });
    defer vendored.close(f.io);
    var count: usize = 0;
    var entries = vendored.iterate();
    while (try entries.next(f.io)) |entry| {
        count += 1;
        try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, entry.name }));
        try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, try f.a.print("{s}.tar.gz", .{entry.name}) }));
    }
    try std.testing.expect(count >= 3);
    // No remote: the fixtures' URLs are files that are no longer there.
    for ([_][]const u8{ "a", "b", "c1", "c2", "tl" }) |dir| try f.tmp.dir.deleteTree(f.io, dir);
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "total 3") != null);
    // The development build, with its tool, configures from zig-pkg alone.
    try std.testing.expect(succeeded(try f.bay("app", &.{ "dev", "-l" })));
}

test "a package archived under one top directory, with a package nested by path, is fetched as Zig builds it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    // As a forge serves a commit: the package's files under one directory, here `t-1.0`,
    // with a package of its own inside taken by a relative path, as ghostty takes its pkg/.
    try f.package("t-1.0/sub", "sub", "0.1.0", "", &.{}, "pub const n = 1;");
    try f.package("t-1.0", "t", "1.0.0", ".sub = .{ .path = \"sub\" },", &.{"sub"}, "pub const version = \"1.0.0\"; pub const n = @import(\"sub\").n;");
    var archive_file = try f.tmp.dir.createFile(f.io, "t.tar", .{});
    var buffer: [4096]u8 = undefined;
    var file_writer = archive_file.writer(f.io, &buffer);
    var archive: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
    try archive.setRoot("t-1.0");
    for ([_][]const u8{ "build.zig", "build.zig.zon", "src/root.zig", "sub/build.zig", "sub/build.zig.zon", "sub/src/root.zig" }) |name| {
        try archive.writeFileBytes(name, try f.tmp.dir.readFileAlloc(f.io, try std.fs.path.join(f.a, &.{ "t-1.0", name }), f.a, .limited(1 << 16)), .{});
    }
    try archive.finishPedantically();
    try file_writer.interface.flush();
    archive_file.close(f.io);
    // The hash Zig gives the package is its files', the directory's as the archive's.
    // Taken in the tests' cache, whose build runner is built already (a cache of its
    // own builds it again, past the watchdog on a hosted runner); the package is then
    // taken out of the cache, so bay fetches it.
    const hashed = try std.process.run(f.a, f.io, .{ .argv = &.{ options.zig, "fetch", try std.fs.path.join(f.a, &.{ f.root, "t-1.0" }) }, .environ_map = &f.env });
    try std.testing.expect(succeeded(hashed));
    const hash = std.mem.trim(u8, hashed.stdout, "\r\n");
    const packages = try std.fs.path.join(f.a, &.{ f.env.get("ZIG_GLOBAL_CACHE_DIR").?, "p" });
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, hash }));
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, try f.a.print("{s}.tar.gz", .{hash}) }));
    const path = try std.fs.path.join(f.a, &.{ f.root, "t.tar" });
    std.mem.replaceScalar(u8, path, '\\', '/');
    const pin = try f.a.print(".t = .{{ .url = \"file://{s}{s}\", .hash = \"{s}\" }},", .{ if (path[0] == '/') "" else "/", path, hash });
    try f.application("app", pin, &.{"t"}, "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"t {s}\\n\", .{@import(\"t\").version}); }");
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "t 1.0.0") != null);
}

/// An application on the diamond whose manifest, before its last brace, is
/// returned, for a test to add a field to it.
fn overridden(f: *Fixture) ![]const u8 {
    try diamond(f);
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b") }), &.{ "a", "b" }, main_ab);
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    const close = std.mem.findLast(u8, manifest, "}").?; // safe: the fixture's manifest ends in a brace
    return std.mem.trimEnd(u8, manifest[0..close], " ");
}

test "an override with a directory builds the local checkout wherever the graph pins the package" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const manifest = try overridden(&f);
    try f.package("local", "c", "0.1.1", "", &.{}, "pub const version = \"local\"; " ++ shared);
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .overrides = .{{ .c = .{{ .path = \"../local\" }} }} }}\n", .{manifest}));
    const local = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(local));
    try std.testing.expect(std.mem.find(u8, local.stderr, "a sees local, b sees local") != null);
}

test "an override with a revision builds it, below what the graph pins, because the package says so" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const manifest = try overridden(&f);
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .overrides = .{{ {s} }} }}\n", .{ manifest, try f.pin("c", "c1") }));
    const older = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(older));
    try std.testing.expect(std.mem.find(u8, older.stderr, "a sees 0.1.0, b sees 0.1.0") != null);
}

test "a command runs in every workspace member after what it ships with, and a failure skips its dependents" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("c", "c", "0.1.0", "", &.{}, shared);
    try f.package("a", "a", "0.1.0", ".c = .{ .path = \"../c\" },", &.{"c"}, using_a);
    try f.package("side", "side", "0.1.0", ".c = .{ .path = \"../c\" },", &.{"c"}, "pub const c = @import(\"c\");");
    try f.package("top", "top", "0.1.0", ".a = .{ .path = \"../a\" },", &.{"a"}, "pub const a = @import(\"a\");");
    // a's build no longer configures: top, which ships with a, is never run.
    try f.write("a", "build.zig", "pub fn build(b: *@import(\"std\").Build) void { _ = b; @compileError(\"a is broken\"); }\n");
    try f.write(".", "bay.work", ".{ .members = .{ \"top\", \"side\", \"a\", \"c\" } }\n");
    const result = try f.bay(".", &.{ "--workspace", "--jobs", "2", "build" });
    try std.testing.expect(refused(result));
    try std.testing.expect(std.mem.find(u8, result.stderr, "bay: c: ok") != null);
    try std.testing.expect(std.mem.find(u8, result.stderr, "bay: side: ok") != null);
    try std.testing.expect(std.mem.find(u8, result.stderr, "bay: a: failed") != null);
    try std.testing.expect(std.mem.find(u8, result.stderr, "bay: top: skipped, since a failed") != null);
    // c went before a and side, which ship with it.
    try std.testing.expect(std.mem.find(u8, result.stderr, "bay: c: ok").? < std.mem.find(u8, result.stderr, "bay: side: ok").?);
    try std.testing.expect(std.mem.find(u8, result.stderr, "bay: 2 of 4 members ok") != null);
    // A ring of members that ship with each other cannot be ordered.
    try f.package("a", "a", "0.1.0", ".top = .{ .path = \"../top\" },", &.{}, "");
    try std.testing.expect(std.mem.find(u8, (try f.bay(".", &.{ "--workspace", "build" })).stderr, "depend on each other") != null);
}

/// A git repository `lib` with release v0.1.0 tagged, an application `app` that
/// imports it, and the URL bay fetches it by; `expected` is the hash Zig gives the tree.
const Repository = struct { url: []const u8, expected: []const u8 };

fn gitRepository(f: *Fixture) !Repository {
    try f.package("lib", "lib", "0.1.0", "", &.{}, "pub const version = \"0.1.0\";");
    for ([_][]const []const u8{ &.{ "git", "init", "--quiet", "--initial-branch=main" }, &.{ "git", "add", "." }, &.{ "git", "commit", "--quiet", "-m", "0.1.0" }, &.{ "git", "tag", "v0.1.0" } }) |argv|
        try std.testing.expect(succeeded(try f.run("lib", argv)));
    // The same tree with no repository: what Zig hashes from a fetch over https.
    try f.package("plain", "lib", "0.1.0", "", &.{}, "pub const version = \"0.1.0\";");
    const expected = std.mem.trim(u8, (try f.run(".", &.{ options.zig, "fetch", try std.fs.path.join(f.a, &.{ f.root, "plain" }) })).stdout, "\r\n");
    try std.testing.expect(std.mem.startsWith(u8, expected, "lib-0.1.0-"));
    try f.application("app", "", &.{"lib"}, "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"lib {s}\\n\", .{@import(\"lib\").version}); }");
    const url = try f.a.print("git+file://{s}{s}", .{ if (f.root[0] == '/') "" else "/", try std.mem.replaceOwned(u8, f.a, try std.fs.path.join(f.a, &.{ f.root, "lib" }), "\\", "/") });
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", try f.a.print("{s}#v0.1.0", .{url}) })));
    return .{ .url = url, .expected = expected };
}

/// Releases `versions` of `lib` in order, each tagged; `retracting` names a version
/// the last of them retracts.
fn releaseLib(f: *Fixture, versions: []const []const u8, retracting: ?[]const u8) !void {
    var previous: []const u8 = "0.1.0";
    for (versions, 0..) |version, i| {
        try f.write("lib", "src/root.zig", try f.a.print("pub const version = \"{s}\";", .{version}));
        var text = try std.mem.replaceOwned(u8, f.a, try f.tmp.dir.readFileAlloc(f.io, "lib/build.zig.zon", f.a, .limited(1 << 16)), try f.a.print("\"{s}\"", .{previous}), try f.a.print("\"{s}\"", .{version}));
        if (i + 1 == versions.len) if (retracting) |withdrawn| {
            text = try std.mem.replaceOwned(u8, f.a, text, ".paths", try f.a.print(".retracted = .{{\"{s}\"}}, .paths", .{withdrawn}));
        };
        try f.write("lib", "build.zig.zon", text);
        for ([_][]const []const u8{ &.{ "git", "commit", "--quiet", "-am", version }, &.{ "git", "tag", try f.a.print("v{s}", .{version}) } }) |argv|
            try std.testing.expect(succeeded(try f.run("lib", argv)));
        previous = version;
    }
}

test "a repository Zig cannot fetch is fetched with git, to the hash Zig gives its tree" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const repository = try gitRepository(&f);
    const pinned = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 16));
    try std.testing.expect(std.mem.find(u8, pinned, repository.expected) != null);
    try std.testing.expect(std.mem.find(u8, pinned, "?ref=v0.1.0#") != null);
    try std.testing.expect(std.mem.find(u8, (try f.bay("app", &.{ "build", "run" })).stderr, "lib 0.1.0") != null);
}

test "a repository's release line is followed by update, a new line and a retracted version are named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const repository = try gitRepository(&f);
    // A release on the line is taken by update, unless the newest release retracts it;
    // a new line is not taken.
    try releaseLib(&f, &.{ "0.1.1", "0.1.2", "0.2.0" }, "0.1.2");
    try std.testing.expect(succeeded(try f.bay("app", &.{"update"})));
    try std.testing.expect(std.mem.find(u8, try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 16)), "?ref=v0.1.1#") != null);
    const outdated = try f.bay("app", &.{"outdated"});
    try std.testing.expect(succeeded(outdated));
    try std.testing.expect(std.mem.find(u8, outdated.stdout, "lib 0.1.1 -> 0.2.0 (tag v0.2.0, a new line)") != null);
    // A version the newest release retracts is said to be, once a build uses it.
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", try f.a.print("{s}#v0.1.2", .{repository.url}) })));
    try std.testing.expect(std.mem.find(u8, (try f.bay("app", &.{"outdated"})).stdout, "lib 0.1.2 is retracted by its release 0.2.0") != null);
}

test "upgrade takes the newest release that its newest release does not retract" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    _ = try gitRepository(&f);
    // 0.3.0 retracts itself: across lines, upgrade stops at 0.2.0.
    try releaseLib(&f, &.{ "0.1.1", "0.2.0", "0.3.0" }, "0.3.0");
    try std.testing.expect(succeeded(try f.bay("app", &.{"upgrade"})));
    try std.testing.expect(std.mem.find(u8, try manifestOf(&f, "app"), "?ref=v0.2.0#") != null);
}

fn gitUrl(f: *Fixture, dir: []const u8) ![]const u8 {
    return f.a.print("git+file://{s}{s}", .{ if (f.root[0] == '/') "" else "/", try std.mem.replaceOwned(u8, f.a, try std.fs.path.join(f.a, &.{ f.root, dir }), "\\", "/") });
}

/// `version` of the package `name` committed and tagged in the git repository `dir`.
fn tagRelease(f: *Fixture, dir: []const u8, name: []const u8, version: []const u8, dependencies: []const u8) !void {
    try f.package(dir, name, version, dependencies, &.{}, "");
    for ([_][]const []const u8{ &.{ "git", "init", "--quiet", "--initial-branch=main" }, &.{ "git", "add", "." }, &.{ "git", "commit", "--quiet", "-m", version }, &.{ "git", "tag", try f.a.print("v{s}", .{version}) } }) |argv|
        try std.testing.expect(succeeded(try f.run(dir, argv)));
}

/// x and y, each released as 0.1.0 and 0.2.0, y pinning the x of its own version
/// (the same trees as plain directories, whose hashes y's manifests record).
fn pair(f: *Fixture) !void {
    for ([_][]const u8{ "0.1.0", "0.2.0" }) |version| {
        const plain = try f.a.print("x{s}", .{version});
        try f.package(plain, "x", version, "", &.{}, "");
        try tagRelease(f, "x", "x", version, "");
        try tagRelease(f, "y", "y", version, try f.pin("x", plain));
    }
}

fn manifestOf(f: *Fixture, dir: []const u8) ![]const u8 {
    return f.tmp.dir.readFileAlloc(f.io, try std.fs.path.join(f.a, &.{ dir, "build.zig.zon" }), f.a, .limited(1 << 16));
}

test "a dependency pinned again stays in the list it is in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const repository = try gitRepository(&f);
    const tag = try f.a.print("{s}#v0.1.0", .{repository.url});
    try std.testing.expect(succeeded(try f.bay("app", &.{ "remove", "lib" })));
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", "--dev", tag })));
    // Without --dev, lib is still only a dev dependency.
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", tag })));
    const listed = try f.bay("app", &.{"list"});
    try std.testing.expect(succeeded(listed));
    try std.testing.expect(std.mem.startsWith(u8, listed.stdout, ".dependencies: none\n"));
    try std.testing.expect(std.mem.find(u8, listed.stdout, ".dev_dependencies\n  lib  ") != null);
}

test "several urls are pinned, then tidied once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try pair(&f);
    const x = try gitUrl(&f, "x");
    const y = try gitUrl(&f, "y");
    try f.application("app", "", &.{}, "pub fn main() void {}");
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", try f.a.print("{s}#v0.1.0", .{x}), try f.a.print("{s}#v0.1.0", .{y}) })));
    // Moved one at a time, x leaves y behind on the line below it: two lines of x.
    const old = try manifestOf(&f, "app");
    const one = try f.bay("app", &.{ "add", try f.a.print("{s}#v0.2.0", .{x}) });
    try std.testing.expect(refused(one));
    try f.write("app", "build.zig.zon", old);
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", try f.a.print("{s}#v0.2.0", .{x}), try f.a.print("{s}#v0.2.0", .{y}) })));
    const pinned = try manifestOf(&f, "app");
    try std.testing.expect(std.mem.count(u8, pinned, "?ref=v0.2.0#") == 2);
}

test "upgrade pins every git dependency at its newest release, across lines, together" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try pair(&f);
    const x = try gitUrl(&f, "x");
    const y = try gitUrl(&f, "y");
    // x at the commit of its first release, y at its tag, both lazy.
    const commit = std.mem.trim(u8, (try f.run("x", &.{ "git", "rev-parse", "v0.1.0^{commit}" })).stdout, "\r\n");
    try f.application("app", "", &.{}, "pub fn main() void {}");
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", try f.a.print("{s}#{s}", .{ x, commit }), "--lazy", try f.a.print("{s}#v0.1.0", .{y}) })));
    // A repository with no release tag stays as it is, and is said to.
    try tagRelease(&f, "bare", "bare", "0.1.0", "");
    try std.testing.expect(succeeded(try f.run("bare", &.{ "git", "tag", "-d", "v0.1.0" })));
    try std.testing.expect(succeeded(try f.bay("app", &.{ "add", "--dev", try f.a.print("{s}#main", .{try gitUrl(&f, "bare")}) })));
    const before = try manifestOf(&f, "app");
    const upgraded = try f.bay("app", &.{"upgrade"});
    try std.testing.expect(succeeded(upgraded));
    try std.testing.expect(std.mem.find(u8, upgraded.stderr, "bare has no release tag") != null);
    const pinned = try manifestOf(&f, "app");
    try std.testing.expect(std.mem.count(u8, pinned, "?ref=v0.2.0#") == 2);
    try std.testing.expect(std.mem.find(u8, pinned, "?ref=main#") != null);
    try std.testing.expect(std.mem.find(u8, before, "?ref=v0.2.0#") == null);
    const listed = try f.bay("app", &.{"list"});
    try std.testing.expect(std.mem.find(u8, listed.stdout, "y (lazy)") != null);
    try std.testing.expect(std.mem.find(u8, listed.stdout, "x (lazy)") != null);
    // A name that is no dependency is refused.
    try std.testing.expect(refused(try f.bay("app", &.{ "upgrade", "nothing" })));
}

test "a package fetched with git is fetched again when Zig's copy of it is gone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const repository = try gitRepository(&f);
    const hash = repository.expected;
    const packages = try std.fs.path.join(f.a, &.{ f.env.get("ZIG_GLOBAL_CACHE_DIR").?, "p" });
    // With the package gone from Zig's cache, a step fetches it with git again:
    // bay resolves and fetches before Zig lists the steps.
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, hash }));
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, try f.a.print("{s}.tar.gz", .{hash}) }));
    try f.tmp.dir.deleteTree(f.io, "app/.zig-cache");
    try f.tmp.dir.deleteTree(f.io, "app/zig-pkg");
    try std.testing.expect(std.mem.find(u8, (try f.bay("app", &.{"run"})).stderr, "lib 0.1.0") != null);
    // Zig's copies gone and bay's own kept, as a CI that caches only .zig-cache has it:
    // bay puts the package back where Zig looks.
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, hash }));
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, try f.a.print("{s}.tar.gz", .{hash}) }));
    try f.tmp.dir.deleteTree(f.io, "app/zig-pkg");
    try std.testing.expect(std.mem.find(u8, (try f.bay("app", &.{ "build", "run" })).stderr, "lib 0.1.0") != null);
}

test "with no Zig named and none on the PATH, a new package is made by the Zig bay was built with" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    // That Zig installed where bay keeps toolchains, so nothing is downloaded.
    const data: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "local", "bay", "data" } else &.{ "data", "bay" };
    const home = try std.fs.path.join(f.a, try std.mem.concat(f.a, []const u8, &.{ data, &.{ "zig", @import("builtin").zig_version_string } }));
    try f.tmp.dir.createDirPath(f.io, home);
    try f.tmp.dir.symLink(f.io, options.zig, try std.fs.path.join(f.a, &.{ home, if (@import("builtin").os.tag == .windows) "zig.exe" else "zig" }), .{});
    _ = f.env.swapRemove("ZIG");
    try f.env.put("PATH", "");
    try std.testing.expect(succeeded(try f.bay(".", &.{ "new", "fresh" })));
    const made = try f.tmp.dir.readFileAlloc(f.io, "fresh/build.zig.zon", f.a, .limited(1 << 16));
    try std.testing.expect(std.mem.find(u8, made, ".dev_dependencies") != null);
}

test "a member whose pins are behind builds from a copy with them rewritten, and only its own tidy writes it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b"), try f.pin("c", "c2") }), &.{ "a", "b" }, main_ab);
    // a is worked on beside the app, and still pins c 0.1.0 where the graph selects 0.1.1.
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"a\" } }\n");
    const before = try f.tmp.dir.readFileAlloc(f.io, "a/build.zig.zon", f.a, .limited(1 << 16));
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "a sees 0.1.1, b sees 0.1.1") != null);
    try std.testing.expect(succeeded(try f.bay("app", &.{"tidy"})));
    try std.testing.expectEqualStrings(before, try f.tmp.dir.readFileAlloc(f.io, "a/build.zig.zon", f.a, .limited(1 << 16)));
    // Each member tidied by itself: a's pin rises to the selection.
    try std.testing.expect(succeeded(try f.bay(".", &.{ "--workspace", "tidy" })));
    const after = try f.tmp.dir.readFileAlloc(f.io, "a/build.zig.zon", f.a, .limited(1 << 16));
    try std.testing.expect(std.mem.find(u8, after, "c-0.1.1-") != null);
}

test "a member a build reaches by path is built from that path, with no fork Zig would refuse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("c", "c", "0.1.0", "", &.{}, "pub const version = \"0.1.0\"; " ++ shared);
    // a is developed with c pinned by hash, so the workspace selects c at a pin...
    try f.package("a", "a", "0.1.0", "", &.{}, "");
    try f.write("a", "build.zig.zon", try f.a.print(".{{ .name = .a, .version = \"0.1.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{}}, .dev_dependencies = .{{ {s} }} }}\n", .{ fingerprint("a"), try f.pin("c", "c") }));
    // ...while the app takes c by path, from the member's own directory.
    try f.application("app", ".c = .{ .path = \"../c\" },", &.{"c"}, "const std = @import(\"std\"); const c = @import(\"c\"); pub fn main() void { std.debug.print(\"c {s}\\n\", .{c.version}); }");
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"a\", \"c\" } }\n");
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "c 0.1.0") != null);
}

test "a member reached by its directory with pins behind the selection is refused, and builds once tidied" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // a pins c 0.1.0 and is taken by path, where Zig reads its own pin; b selects c 0.1.1.
    try f.application("app", try std.mem.concat(f.a, u8, &.{ ".a = .{ .path = \"../a\" },", try f.pin("b", "b") }), &.{ "a", "b" }, main_ab);
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"a\" } }\n");
    const refusal = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "a is reached by its directory, where Zig reads its own pins, and they are behind the selection") != null);
    try std.testing.expect(succeeded(try f.bay(".", &.{ "--workspace", "tidy" })));
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "a sees 0.1.1, b sees 0.1.1") != null);
}

test "a member reached by its directory and pinned by hash in one build is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("c", "c", "0.1.0", "", &.{}, "pub const version = \"0.1.0\"; " ++ shared);
    try f.package("d", "d", "0.1.0", try f.pin("c", "c"), &.{"c"}, "pub const seen = @import(\"c\").version;");
    try f.application("app", try std.mem.concat(f.a, u8, &.{ ".c = .{ .path = \"../c\" },", try f.pin("d", "d") }), &.{ "c", "d" }, "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"{s} {s}\\n\", .{ @import(\"c\").version, @import(\"d\").seen }); }");
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"c\" } }\n");
    const refusal = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "c is reached by its directory and pinned by hash, which Zig builds as two packages") != null);
}

test "a workspace's members may each name packages whose lines coexist, and a package naming itself is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("c1", "c", "0.1.0", "", &.{}, "pub const version = \"0.1.0\";");
    try f.package("c3", "c", "0.2.0", "", &.{}, "pub const version = \"0.2.0\";");
    try f.package("a", "a", "0.1.0", try f.pin("c", "c1"), &.{"c"}, "pub const seen = @import(\"c\").version;");
    // lib moves to c 0.2.0 and says the old line may stay beside it.
    try f.package("lib", "lib", "0.1.0", "", &.{"c"}, "pub const seen = @import(\"c\").version;");
    try f.write("lib", "build.zig.zon", try f.a.print(".{{ .name = .lib, .version = \"0.1.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{ {s} }}, .coexist = .{{ .c }} }}\n", .{ fingerprint("lib"), try f.pin("c", "c3") }));
    try f.application("app", try f.pin("a", "a"), &.{"a"}, "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"a sees {s}\\n\", .{@import(\"a\").seen}); }");
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"lib\" } }\n");
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "a sees 0.1.0") != null);
    // A package has one line of itself.
    try f.write("lib", "build.zig.zon", try f.a.print(".{{ .name = .lib, .version = \"0.1.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{ {s} }}, .coexist = .{{ .c, .lib }} }}\n", .{ fingerprint("lib"), try f.pin("c", "c3") }));
    const refusal = try f.bay("lib", &.{"build"});
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "lib names itself in .coexist") != null);
}

test "a path dependency with pins behind the selection is refused, as Zig would build them as written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // a pins c 0.1.0 and is no member, taken by path; b selects c 0.1.1.
    try f.application("app", try std.mem.concat(f.a, u8, &.{ ".a = .{ .path = \"../a\" },", try f.pin("b", "b") }), &.{ "a", "b" }, main_ab);
    const refusal = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "a is a path dependency, which Zig builds with its own manifest's pins, and they are behind the selection") != null);
    // Developed in the workspace, its pins are tidied with the rest.
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"a\" } }\n");
    try std.testing.expect(succeeded(try f.bay(".", &.{ "--workspace", "tidy" })));
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "a sees 0.1.1, b sees 0.1.1") != null);
}

test "a member checked out a second time is that member, and tidy there keeps its own pins" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("c1", "c", "0.1.0", "", &.{}, "pub const version = \"0.1.0\";");
    try f.package("c2", "c", "0.1.1", "", &.{}, "pub const version = \"0.1.1\";");
    // c is developed beside them. lib is a member at c 0.1.0; a landing's scratch
    // checkout of lib has moved it to 0.1.1, which a stale copy must not undo.
    try f.package("lib", "lib", "0.1.0", try f.pin("c", "c1"), &.{"c"}, "pub const seen = @import(\"c\").version;");
    try f.package("work/lib-copy", "lib", "0.1.0", try f.pin("c", "c2"), &.{"c"}, "pub const seen = @import(\"c\").version;");
    try f.write(".", "bay.work", ".{ .members = .{ \"lib\", \"c2\" } }\n");
    try std.testing.expect(succeeded(try f.bay("work/lib-copy", &.{"tidy"})));
    const after = try f.tmp.dir.readFileAlloc(f.io, "work/lib-copy/build.zig.zon", f.a, .limited(1 << 16));
    try std.testing.expect(std.mem.find(u8, after, "c-0.1.1-") != null);
}

test "a workspace's train: a dependent landed from a scratch checkout pins its dependency's new release" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    // lib is released at v0.1.0 and app pins it; both are developed in one workspace.
    _ = try gitRepository(&f);
    for ([_][]const []const u8{ &.{ "git", "init", "--quiet", "--initial-branch=main" }, &.{ "git", "add", "." }, &.{ "git", "commit", "--quiet", "-m", "app" } }) |argv|
        try std.testing.expect(succeeded(try f.run("app", argv)));
    try f.write(".", "bay.work", ".{ .members = .{ \"lib\", \"app\" } }\n");
    // lib lands first and is tagged.
    try releaseLib(&f, &.{"0.1.1"}, null);
    // app lands next, from a checkout of its own inside its git directory, as preflight's land makes one.
    try std.testing.expect(succeeded(try f.run("app", &.{ "git", "worktree", "add", "--quiet", "--detach", ".git/landing", "HEAD" })));
    try std.testing.expect(succeeded(try f.bay("app/.git/landing", &.{"tidy"})));
    try std.testing.expect(std.mem.find(u8, try manifestOf(&f, "app/.git/landing"), "?ref=v0.1.1#") != null);
    // And it builds against the release it now pins.
    try std.testing.expect(std.mem.find(u8, (try f.bay("app/.git/landing", &.{ "build", "run" })).stderr, "lib 0.1.1") != null);
}

test "a package that is a directory in one place and pinned in another is refused, and an override makes it one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // The app works on c beside it, by path, while a pins c 0.1.0 by hash.
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), ".c = .{ .path = \"../c2\" }," }), &.{ "a", "c" }, "const std = @import(\"std\"); const a = @import(\"a\"); const c = @import(\"c\"); pub fn main() void { const t: c.T = a.make(); std.debug.print(\"{s} {d}\\n\", .{ a.seen, t.x }); }");
    const refusal = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "c is a directory in one place and pinned at another elsewhere") != null);
    // Pinned as a, and replaced for the whole graph by the directory: one c.
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    const close = std.mem.findLast(u8, manifest, "}").?; // safe: the fixture's manifest ends in a brace
    const pinned = try std.mem.replaceOwned(u8, f.a, std.mem.trimEnd(u8, manifest[0..close], " "), ".c = .{ .path = \"../c2\" },", try f.pin("c", "c1"));
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .overrides = .{{ .c = .{{ .path = \"../c2\" }} }} }}\n", .{pinned}));
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "0.1.1 1") != null);
}

test "a coexisting line that needs its pins rewritten is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("d1", "d", "0.1.0", "", &.{}, "pub const v = 1;");
    try f.package("d2", "d", "0.1.1", "", &.{}, "pub const v = 2;");
    try f.package("c04", "c", "0.4.0", try f.pin("d", "d1"), &.{"d"}, "pub const d = @import(\"d\");");
    try f.package("c10", "c", "1.0.0", "", &.{}, "pub const v = 10;");
    try f.package("old", "old", "0.1.0", try f.pin("c", "c04"), &.{"c"}, "pub const c = @import(\"c\");");
    // c 0.4.0 pins d 0.1.0, but d 0.1.1 is selected: its copy would be a fork Zig gives every c.
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("c", "c10"), try f.pin("old", "old"), try f.pin("d", "d2") }), &.{ "c", "old", "d" }, "pub fn main() void {}");
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    const close = std.mem.findLast(u8, manifest, "}").?; // safe: the fixture's manifest ends in a brace
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .coexist = .{{ .c }} }}\n", .{std.mem.trimEnd(u8, manifest[0..close], " ")}));
    const refusal = try f.bay("app", &.{"build"});
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "c 0.4.0 coexists with another line of c and needs its pins rewritten") != null);
}

test "a workspace is one graph: its tidy settles in one pass, development pins included" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // The app develops with c 0.1.1; a, beside it, pins c 0.1.0.
    try f.application("app", try f.pin("a", "a"), &.{"a"}, "pub fn main() void {}");
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    const close = std.mem.findLast(u8, manifest, "}").?; // safe: the fixture's manifest ends in a brace
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .dev_dependencies = .{{ {s} }} }}\n", .{ std.mem.trimEnd(u8, manifest[0..close], " "), try f.pin("c", "c2") }));
    try f.write(".", "bay.work", ".{ .members = .{ \"app\", \"a\" } }\n");
    try std.testing.expect(succeeded(try f.bay(".", &.{ "--workspace", "--jobs", "2", "tidy" })));
    // a's pin rose to what the app's development asks for, in the same pass.
    try std.testing.expect(std.mem.find(u8, try f.tmp.dir.readFileAlloc(f.io, "a/build.zig.zon", f.a, .limited(1 << 16)), "c-0.1.1-") != null);
    const settled = try f.bay(".", &.{ "--locked", "--workspace", "tidy" });
    try std.testing.expect(succeeded(settled));
}

test "a package naming a Zig older than bay builds with is refused in a sentence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("old", "old", "0.1.0", "", &.{}, "");
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "old/build.zig.zon", f.a, .limited(1 << 16));
    try f.write("old", "build.zig.zon", try std.mem.replaceOwned(u8, f.a, manifest, "\"0.17.0\"", "\"0.16.0\""));
    _ = f.env.swapRemove("ZIG");
    const refusal = try f.bay("old", &.{"build"});
    try std.testing.expect(refused(refusal));
    try std.testing.expect(std.mem.find(u8, refusal.stderr, "names Zig 0.16.0; bay builds with Zig 0.17.0 or newer") != null);
}

test "a diamond on a package with a package nested by path builds one of each" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    // m keeps sub inside it, by path; its two releases each carry their own sub.
    for ([_][2][]const u8{ .{ "m1", "0.1.0" }, .{ "m2", "0.1.1" } }) |release| {
        try f.package(try f.a.print("{s}/sub", .{release[0]}), "sub", release[1], "", &.{}, try f.a.print("pub const n = \"{s}\";", .{release[1]}));
        try f.package(release[0], "m", release[1], ".sub = .{ .path = \"sub\" },", &.{"sub"}, "pub const sub = @import(\"sub\");");
    }
    try f.package("a", "a", "0.1.0", try f.pin("m", "m1"), &.{"m"}, "pub const m = @import(\"m\");");
    try f.package("b", "b", "0.1.0", try f.pin("m", "m2"), &.{"m"}, "pub const m = @import(\"m\");");
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("a", "a"), try f.pin("b", "b") }), &.{ "a", "b" }, "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"a sub {s} b sub {s}\\n\", .{ @import(\"a\").m.sub.n, @import(\"b\").m.sub.n }); }");
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "a sub 0.1.1 b sub 0.1.1") != null);
}

test "a diamond on a package whose nested package keeps its version builds the selected one's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    // n bumps; the sub it holds by path does not: one version, a copy in each release.
    for ([_][2][]const u8{ .{ "n1", "0.1.0" }, .{ "n2", "0.1.1" } }) |release| {
        try f.package(try f.a.print("{s}/sub", .{release[0]}), "sub", "0.1.0", "", &.{}, "pub const n = \"same\";");
        try f.package(release[0], "n", release[1], ".sub = .{ .path = \"sub\" },", &.{"sub"}, try f.a.print("pub const sub = @import(\"sub\"); pub const v = \"{s}\";", .{release[1]}));
    }
    try f.package("na", "na", "0.1.0", try f.pin("n", "n1"), &.{"n"}, "pub const n = @import(\"n\");");
    try f.package("nb", "nb", "0.1.0", try f.pin("n", "n2"), &.{"n"}, "pub const n = @import(\"n\");");
    try f.application("app", try std.mem.concat(f.a, u8, &.{ try f.pin("na", "na"), try f.pin("nb", "nb") }), &.{ "na", "nb" }, "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"{s} {s} {s}\\n\", .{ @import(\"na\").n.v, @import(\"nb\").n.v, @import(\"na\").n.sub.n }); }");
    const built = try f.bay("app", &.{ "build", "run" });
    try std.testing.expect(succeeded(built));
    try std.testing.expect(std.mem.find(u8, built.stderr, "0.1.1 0.1.1 same") != null);
}

test "an install builds what the package ships, whatever its development pins" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try diamond(&f);
    // Two contents of c 0.1.2 among the app's development tools: its development cannot resolve.
    try f.package("c3", "c", "0.1.2", "", &.{}, "pub const version = \"three\"; " ++ shared);
    try f.package("c4", "c", "0.1.2", "", &.{}, "pub const version = \"four\"; " ++ shared);
    try f.application("app", try f.pin("c", "c2"), &.{}, "pub fn main() void {}");
    const manifest = try f.tmp.dir.readFileAlloc(f.io, "app/build.zig.zon", f.a, .limited(1 << 20));
    const close = std.mem.findLast(u8, manifest, "}").?; // safe: the fixture's manifest ends in a brace
    try f.write("app", "build.zig.zon", try f.a.print("{s}, .dev_dependencies = .{{ {s} {s} }} }}\n", .{ std.mem.trimEnd(u8, manifest[0..close], " "), try f.pin("three", "c3"), try f.pin("four", "c4") }));
    try std.testing.expect(refused(try f.bay("app", &.{"tidy"})));
    const installed = try f.bay("app", &.{ "install", "--prefix", try std.fs.path.join(f.a, &.{ f.root, "prefix" }) });
    try std.testing.expect(succeeded(installed));
    try f.tmp.dir.access(f.io, if (@import("builtin").os.tag == .windows) "prefix/bin/app.exe" else "prefix/bin/app", .{});
}

test "bay names its version, the one its manifest gives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    for ([_][]const u8{ "version", "--version" }) |command| {
        const said = try f.bay(".", &.{command});
        try std.testing.expect(succeeded(said));
        try std.testing.expectEqualStrings("bay " ++ options.version ++ "\n", said.stdout);
    }
}

test "a development build runs what it builds in the package's directory, wherever bay is run from" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    try f.package("work", "w", "0.1.0", "", &.{}, "pub const x = 1;");
    try f.write("work", "build.zig.zon", try f.a.print(".{{ .name = .w, .version = \"0.1.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{}}, .dev_dependencies = .{{}} }}\n", .{fingerprint("w")}));
    try f.write("work", "marker.txt", "the package's own file\n");
    try f.write("work/src", "keep.txt", "");
    try f.write("work", "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("w", .{ .root_source_file = b.path("src/root.zig"), .target = b.standardTargetOptions(.{}), .optimize = b.standardOptimizeOption(.{}) });
        \\}
        \\pub fn dev(b: *std.Build, tools: type) void {
        \\    _ = tools;
        \\    const read = b.addWriteFiles().add("read.zig", "const std = @import(\"std\"); pub fn main(init: std.process.Init) !void { const text = try std.Io.Dir.cwd().readFileAlloc(init.io, \"marker.txt\", init.arena.allocator(), .limited(64)); std.debug.print(\"read: {s}\", .{text}); }");
        \\    const exe = b.addExecutable(.{ .name = "read", .root_module = b.createModule(.{ .root_source_file = read, .target = b.graph.host }) });
        \\    b.step("read", "Read the package's marker").dependOn(&b.addRunArtifact(exe).step);
        \\}
        \\
    );
    for ([_][]const u8{ "work", "work/src" }) |from| {
        const read = try f.bay(from, &.{ "dev", "read" });
        if (!succeeded(read)) std.debug.print("{s}\n", .{read.stderr});
        try std.testing.expect(succeeded(read));
        try std.testing.expect(std.mem.find(u8, read.stderr, "read: the package's own file") != null);
    }
}

test "a development build that fetches lazy packages while it configures builds the package under development where bay forked it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    // A tool that pins the package under development, and builds a lazy package of its own.
    // Two levels of lazy packages: Zig fetches one, configures again, fetches the other
    // and configures a third time.
    try f.package("deeper", "deeper", "0.1.0", "", &.{}, "pub const y = 2;");
    const deeper_pin = try f.pin("deeper", "deeper");
    try f.package("lazy", "lazy", "0.1.0", try std.mem.concat(f.a, u8, &.{ deeper_pin[0 .. deeper_pin.len - 2], ", .lazy = true }," }), &.{}, "pub const x = 1;");
    try f.write("lazy", "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("lazy", .{ .root_source_file = b.path("src/root.zig") });
        \\    if (b.lazyDependency("deeper", .{})) |deeper| _ = deeper.module("deeper");
        \\}
        \\
    );
    try f.package("c1", "c", "0.1.0", "", &.{}, "pub const version = \"0.1.0\";");
    const lazy_pin = try f.pin("lazy", "lazy");
    try f.package("tool", "tool", "0.1.0", try std.mem.concat(f.a, u8, &.{ try f.pin("c", "c1"), lazy_pin[0 .. lazy_pin.len - 2], ", .lazy = true }," }), &.{"c"}, "pub const seen = @import(\"c\").version;");
    try f.write("tool", "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const c = b.dependency("c", .{}).module("c");
        \\    _ = b.addModule("tool", .{ .root_source_file = b.path("src/root.zig"), .imports = &.{.{ .name = "c", .module = c }} });
        \\    if (b.lazyDependency("lazy", .{})) |lazy| _ = lazy.module("lazy");
        \\}
        \\
    );
    try f.package("work", "c", "0.2.0", "", &.{}, "pub const version = \"0.2.0 working\";");
    try f.write("work", "build.zig.zon", try f.a.print(".{{ .name = .c, .version = \"0.2.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{}}, .dev_dependencies = .{{ {s} }} }}\n", .{ fingerprint("c"), try f.pin("tool", "tool") }));
    try f.write("work", "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("c", .{ .root_source_file = b.path("src/root.zig") });
        \\}
        \\pub fn dev(b: *std.Build, tools: type) void {
        \\    _ = tools;
        \\    const tool = b.dependency("tool", .{}).module("tool");
        \\    const check = b.addWriteFiles().add("check.zig", "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"the tool sees {s}\\n\", .{@import(\"tool\").seen}); }");
        \\    const exe = b.addExecutable(.{ .name = "check", .root_module = b.createModule(.{ .root_source_file = check, .target = b.graph.host, .imports = &.{.{ .name = "tool", .module = tool }} }) });
        \\    b.step("check", "Run the tool").dependOn(&b.addRunArtifact(exe).step);
        \\}
        \\
    );
    // Zig's cache without the lazy package: the build fetches it and configures again.
    const hash = lazy_pin[std.mem.find(u8, lazy_pin, "lazy-0.1.0-").?..std.mem.findScalarPos(u8, lazy_pin, std.mem.find(u8, lazy_pin, "lazy-0.1.0-").?, '"').?];
    const deeper_hash = deeper_pin[std.mem.find(u8, deeper_pin, "deeper-0.1.0-").?..std.mem.findScalarPos(u8, deeper_pin, std.mem.find(u8, deeper_pin, "deeper-0.1.0-").?, '"').?];
    for ([_][]const u8{ hash, deeper_hash }) |each| try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ f.env.get("ZIG_GLOBAL_CACHE_DIR").?, "p", each }));
    const checked = try f.bay("work", &.{ "dev", "check" });
    if (!succeeded(checked)) std.debug.print("{s}\n", .{checked.stderr});
    try std.testing.expect(succeeded(checked));
    try std.testing.expect(std.mem.find(u8, checked.stderr, "the tool sees 0.2.0 working") != null);
}
