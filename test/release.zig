//! `bay release` end to end, on scratch repositories whose remotes are reached
//! over git's SSH transport (the tests' stand-in for ssh runs the command
//! here): the release cut, gated and pushed with its tag at once; every
//! refusal, each leaving the branch and the remote as they were; a red gate;
//! two branches adding lines under one group rebased with no conflict; a
//! release interrupted after its commit and after its push, finished or
//! refused, never a tag on a commit no gate passed; a machine gating beside
//! this one; a workspace's train of three members in order, none of which
//! releases alone and each of which says it is the family's; a release only to
//! the remote's default branch; the GitHub Release; and the release tier passed
//! on GitHub before the tag, green and red, against a scripted API.
const std = @import("std");
const Io = std.Io;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const refused = fixture.refused;
const succeeded = fixture.succeeded;

/// The package's gate: it records the commit it gated (a file named for it under
/// GATE_LOG, holding where it was told the portable jobs run, and on a second line the
/// members a train told it to build at its pins) and fails when the package holds a file `red`.
const gate_program =
    \\const std = @import("std");
    \\pub fn main(init: std.process.Init) !void {
    \\    const io = init.io;
    \\    const a = init.arena.allocator();
    \\    const head = try std.process.run(a, io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .environ_map = init.environ_map });
    \\    const sha = std.mem.trim(u8, head.stdout, " \r\n");
    \\    const log = init.environ_map.get("GATE_LOG") orelse return error.NoGateLog;
    \\    // Gates run side by side, and a clock may tick in microseconds (a Mac's): a name taken
    \\    // by another gate's record is passed over for the next free one, made exclusively.
    \\    const now = std.Io.Clock.real.now(io).toNanoseconds();
    \\    var n: usize = 0;
    \\    const file = while (true) : (n += 1) {
    \\        break std.Io.Dir.cwd().createFile(io, try std.fmt.allocPrint(a, "{s}/{s}-{d}-{d}", .{ log, sha, now, n }), .{ .exclusive = true }) catch |err| switch (err) {
    \\            error.PathAlreadyExists => continue,
    \\            else => |e| return e,
    \\        };
    \\    };
    \\    defer file.close(io);
    \\    try file.writeStreamingAll(io, init.environ_map.get("PREFLIGHT_PORTABLE") orelse "unset");
    \\    try file.writeStreamingAll(io, "\n");
    \\    try file.writeStreamingAll(io, init.environ_map.get("BAY_TRAIN_PINNED") orelse "");
    \\    if (std.Io.Dir.cwd().access(io, "red", .{})) |_| return error.Red else |_| {}
    \\}
    \\
;

/// The package's build: its gate, and a file made from its pins (`generate`), as
/// preflight makes a caller naming the preflight a package pins; its development's `check`
/// compiles `check.zig`.
const gate_build =
    \\const std = @import("std");
    \\pub fn dev(b: *std.Build, _: type) void {
    \\    const p = b.dependency(@tagName(@import("build.zig.zon").name), .{}).builder;
    \\    const object = b.addObject(.{ .name = "check", .root_module = b.createModule(.{ .root_source_file = p.path("check.zig"), .target = b.graph.host }) });
    \\    b.step("check", "Compile the package").dependOn(&object.step);
    \\}
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "gate", .root_module = b.createModule(.{ .root_source_file = b.path("gate.zig"), .target = b.graph.host }) });
    \\    const run = b.addRunArtifact(exe);
    \\    run.setCwd(b.path("."));
    \\    run.has_side_effects = true;
    \\    b.step("gate", "Gate the package").dependOn(&run.step);
    \\    const generated = b.addUpdateSourceFiles();
    \\    generated.addCopyFileToSource(b.path("build.zig.zon"), "pins.txt");
    \\    b.step("generate", "Make what follows from the pins").dependOn(&generated.step);
    \\}
    \\
;

const World = struct {
    f: Fixture,

    fn init(a: std.mem.Allocator) !World {
        var w: World = .{ .f = try .init(a) };
        // A release's gate builds with the Zig the manifest names, never `ZIG`.
        try w.f.installZig();
        try w.f.tmp.dir.createDirPath(w.f.io, "gates");
        try w.f.env.put("GATE_LOG", try std.fs.path.join(a, &.{ w.f.root, "gates" }));
        return w;
    }

    fn deinit(w: *World) void {
        w.f.deinit();
    }

    fn path(w: *World, dir: []const u8) ![]const u8 {
        return std.fs.path.join(w.f.a, &.{ w.f.root, dir });
    }

    /// The remote of the package in `dir` as git reaches it over SSH.
    fn sshUrl(w: *World, dir: []const u8) ![]const u8 {
        const absolute = try std.mem.replaceOwned(u8, w.f.a, try w.path(try w.f.a.print("remotes/{s}.git", .{dir})), "\\", "/");
        return w.f.a.print("scratch:{s}", .{absolute});
    }

    /// The same remote as a pin names it.
    fn pinUrl(w: *World, dir: []const u8) ![]const u8 {
        const absolute = try std.mem.replaceOwned(u8, w.f.a, try w.path(try w.f.a.print("remotes/{s}.git", .{dir})), "\\", "/");
        return w.f.a.print("git+file://{s}{s}", .{ if (absolute[0] == '/') "" else "/", absolute });
    }

    fn git(w: *World, dir: []const u8, args: []const []const u8) !void {
        try std.testing.expect(succeeded(try w.f.run(dir, try std.mem.concat(w.f.a, []const u8, &.{ &.{"git"}, args }))));
    }

    fn out(w: *World, dir: []const u8, args: []const []const u8) ![]const u8 {
        const result = try w.f.run(dir, try std.mem.concat(w.f.a, []const u8, &.{ &.{"git"}, args }));
        try std.testing.expect(succeeded(result));
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    fn read(w: *World, dir: []const u8, name: []const u8) ![]const u8 {
        return w.f.tmp.dir.readFileAlloc(w.f.io, try std.fs.path.join(w.f.a, &.{ dir, name }), w.f.a, .limited(1 << 20));
    }

    /// A package `name` at `version`, released and tagged, its remote a bare
    /// repository pushed to over SSH; `dependencies` its manifest's entries.
    fn package(w: *World, dir: []const u8, version: []const u8, dependencies: []const u8) !void {
        return w.made(dir, version, dependencies, .released);
    }

    /// As `package`, never released: no tag, and its first entry waiting in [Unreleased].
    fn unreleased(w: *World, dir: []const u8, version: []const u8) !void {
        return w.made(dir, version, "", .unreleased);
    }

    fn made(w: *World, dir: []const u8, version: []const u8, dependencies: []const u8, history: enum { released, unreleased }) !void {
        const f = &w.f;
        try f.tmp.dir.createDirPath(f.io, dir);
        try f.write(dir, "build.zig.zon", try f.a.print(".{{\n    .name = .{s},\n    .version = \"{s}\",\n    .fingerprint = 0x{x},\n    .minimum_zig_version = \"0.17.0\",\n    .paths = .{{\"\"}},\n    .dependencies = .{{{s}}},\n}}\n", .{ dir, version, fixture.fingerprint(dir), dependencies }));
        try f.write(dir, "build.zig", gate_build);
        try f.write(dir, "gate.zig", gate_program);
        try f.write(dir, "check.zig", "comptime {}\n");
        try f.write(dir, ".gitignore", ".zig-cache/\nzig-out/\nzig-pkg/\n");
        try f.write(dir, ".gitattributes", "CHANGELOG.md merge=union\n");
        try f.write(dir, "CHANGELOG.md", switch (history) {
            .released => try f.a.print("# Changelog\n\n## [Unreleased]\n\n## [{s}] - 2026-01-01\n\n### Added\n\n- First.\n", .{version}),
            .unreleased => "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- First.\n",
        });
        try w.git(dir, &.{ "init", "--quiet", "--initial-branch=main" });
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", "First" });
        if (history == .released) try w.git(dir, &.{ "tag", try f.a.print("v{s}", .{version}) });
        try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", try w.path(try f.a.print("remotes/{s}.git", .{dir})) });
        try w.git(dir, &.{ "remote", "add", "origin", try w.sshUrl(dir) });
        try w.git(dir, &.{ "push", "--quiet", "--set-upstream", "origin", "main", "--tags" });
    }

    /// `body` as the package's [Unreleased] section, and a change to a file it ships, committed.
    fn change(w: *World, dir: []const u8, body: []const u8) !void {
        const log = try w.read(dir, "CHANGELOG.md");
        const at = std.mem.find(u8, log, "## [Unreleased]\n\n").? + "## [Unreleased]\n\n".len;
        try w.f.write(dir, "CHANGELOG.md", try std.mem.concat(w.f.a, u8, &.{ log[0..at], body, "\n", log[at..] }));
        try w.f.write(dir, "lib.zig", try w.f.a.print("// {d}\n", .{std.Io.Clock.real.now(w.f.io).toNanoseconds()}));
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", "A change" });
    }

    /// The commit bay recorded as gated green for `tag` in `dir`'s repository and has not
    /// pushed, as bay keeps it in its data directory; empty when there is none.
    fn gateRecord(w: *World, dir: []const u8, tag: []const u8) ![]const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(try w.out(dir, &.{ "rev-parse", "--absolute-git-dir" }), &digest, .{});
        const record = try w.f.dataDir(&.{ "gated", &std.fmt.bytesToHex(digest, .lower), tag });
        return w.f.tmp.dir.readFileAlloc(w.f.io, record, w.f.a, .limited(256)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }

    /// How many times a gate ran on `commit`.
    fn gated(w: *World, commit: []const u8) !usize {
        var dir = try w.f.tmp.dir.openDir(w.f.io, "gates", .{ .iterate = true });
        defer dir.close(w.f.io);
        var count: usize = 0;
        var entries = dir.iterate();
        while (try entries.next(w.f.io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, commit)) count += 1;
        }
        return count;
    }

    /// Whether a gate of `commit` was told `portable`: where the jobs that say the same
    /// on any machine run.
    fn gatedWith(w: *World, commit: []const u8, portable: []const u8) !bool {
        var dir = try w.f.tmp.dir.openDir(w.f.io, "gates", .{ .iterate = true });
        defer dir.close(w.f.io);
        var entries = dir.iterate();
        while (try entries.next(w.f.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, commit)) continue;
            const record = try dir.readFileAlloc(w.f.io, entry.name, w.f.a, .limited(1 << 16));
            if (std.mem.eql(u8, record[0 .. std.mem.findScalar(u8, record, '\n') orelse record.len], portable)) return true;
        }
        return false;
    }

    /// The members a gate of `commit` was told to build at its pins (a train's), as one list.
    fn gatedPinned(w: *World, commit: []const u8) ![]const u8 {
        var dir = try w.f.tmp.dir.openDir(w.f.io, "gates", .{ .iterate = true });
        defer dir.close(w.f.io);
        var entries = dir.iterate();
        while (try entries.next(w.f.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, commit)) continue;
            const record = try dir.readFileAlloc(w.f.io, entry.name, w.f.a, .limited(1 << 16));
            const line = std.mem.findScalar(u8, record, '\n') orelse return "";
            return record[line + 1 ..];
        }
        return error.NotGated;
    }

    /// The directory of `dir` as the file system names it, as a workspace names its members.
    fn real(w: *World, dir: []const u8) ![]const u8 {
        return Io.Dir.cwd().realPathFileAlloc(w.f.io, try w.path(dir), w.f.a);
    }

    /// The commit the remote of `dir` holds at `ref`, an annotated tag peeled, or "" for nothing.
    fn remoteAt(w: *World, dir: []const u8, ref: []const u8) ![]const u8 {
        const peeled = try w.f.a.print("{s}^{{}}", .{ref});
        const listing = try w.out(dir, &.{ "ls-remote", "origin", ref, peeled });
        var named: []const u8 = "";
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, line[tab + 1 ..], peeled)) return line[0..tab];
            if (std.mem.eql(u8, line[tab + 1 ..], ref)) named = line[0..tab];
        }
        return named;
    }

    fn head(w: *World, dir: []const u8) ![]const u8 {
        return w.out(dir, &.{ "rev-parse", "HEAD" });
    }

    fn releaseIn(w: *World, dir: []const u8, args: []const []const u8) !std.process.RunResult {
        return w.f.bay(dir, try std.mem.concat(w.f.a, []const u8, &.{ &.{"release"}, args }));
    }
};

fn contains(text: []const u8, part: []const u8) bool {
    if (std.mem.find(u8, text, part) != null) return true;
    std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ part, text });
    return false;
}

fn today(a: std.mem.Allocator) ![]const u8 {
    const seconds: u64 = @intCast(@max(0, std.Io.Clock.real.now(std.testing.io).toSeconds()));
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

test "a release cuts the section, gates that commit, and pushes the branch and its tag at once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    // Released from a branch named other than the one it moves on the remote.
    try w.git("lib", &.{ "branch", "-m", "main", "road" });
    const before = try w.head("lib");
    const released = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(released));
    const commit = try w.head("lib");
    try std.testing.expect(contains(released.stderr, try w.f.a.print("released lib v0.1.1 at {s}: origin/main and the tag v0.1.1 on origin", .{commit[0..12]})));
    try std.testing.expect(!std.mem.eql(u8, before, commit));
    try std.testing.expectEqualStrings(before, try w.out("lib", &.{ "rev-parse", "HEAD^" }));
    try std.testing.expectEqualStrings("Release v0.1.1", try w.out("lib", &.{ "log", "-1", "--format=%s" }));
    try std.testing.expect(contains(try w.read("lib", "build.zig.zon"), ".version = \"0.1.1\""));
    try std.testing.expect(contains(try w.read("lib", "CHANGELOG.md"), try w.f.a.print("## [Unreleased]\n\n## [0.1.1] - {s}\n\n### Fixed\n\n- A fix.\n\n## [0.1.0]", .{try today(w.f.a)})));
    // The gate saw that commit, once; the remote holds it as main and as the tag, and so does the clone.
    try std.testing.expectEqual(1, try w.gated(commit));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/heads/main"));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/heads/road"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings(commit, try w.out("lib", &.{ "rev-parse", "v0.1.1^{commit}" }));
    // The tag is annotated, its message the version; no hosted run passed it, so it names none.
    try std.testing.expectEqualStrings("tag", try w.out("lib", &.{ "cat-file", "-t", "v0.1.1" }));
    try std.testing.expectEqualStrings("v0.1.1", try w.out("lib", &.{ "for-each-ref", "--format=%(contents)", "refs/tags/v0.1.1" }));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "for-each-ref", "refs/bay" }));
    // Released, it has nothing more to release.
    const again = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(again));
    try std.testing.expect(contains(again.stderr, "nothing to release"));
    try std.testing.expectEqualStrings(commit, try w.head("lib"));
}

test "a release goes only to the remote's default branch, which a branch with no upstream takes as its upstream" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    const remote_main = try w.remoteAt("lib", "refs/heads/main");
    // A line of its own is refused, its dry run too: releases are one line.
    try w.git("lib", &.{ "checkout", "--quiet", "-b", "line-0.1" });
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const start = try w.head("lib");
    for ([_][]const []const u8{ &.{"--dry-run"}, &.{} }) |args| {
        const off = try w.releaseIn("lib", args);
        try std.testing.expect(refused(off));
        try std.testing.expect(contains(off.stderr, "line-0.1 would go to origin/line-0.1, and a release goes only to origin's default branch, main"));
        try std.testing.expectEqualStrings(start, try w.head("lib"));
        try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/heads/line-0.1"));
        try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));
        try std.testing.expectEqualStrings(remote_main, try w.remoteAt("lib", "refs/heads/main"));
    }
    // The default branch with no upstream goes to its own name there, which becomes its upstream.
    try w.git("lib", &.{ "checkout", "--quiet", "main" });
    try w.git("lib", &.{ "reset", "--quiet", "--hard", start });
    try w.git("lib", &.{ "branch", "--unset-upstream" });
    const dry = try w.releaseIn("lib", &.{"--dry-run"});
    try std.testing.expect(succeeded(dry));
    try std.testing.expect(contains(dry.stdout, "push it to origin/main and the tag v0.1.1 on origin"));
    try std.testing.expect(contains(dry.stdout, "which becomes the branch's upstream"));
    // The dry run set nothing.
    try std.testing.expect(!succeeded(try w.f.run("lib", &.{ "git", "config", "--get", "branch.main.remote" })));
    const released = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(released));
    const commit = try w.head("lib");
    try std.testing.expect(contains(released.stderr, "main has origin/main as its upstream now"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/heads/main"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings("origin/main", try w.out("lib", &.{ "rev-parse", "--abbrev-ref", "main@{upstream}" }));
    // From then on it releases as any branch with an upstream does.
    try w.change("lib", "### Fixed\n\n- Another.\n");
    const again = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(again));
    try std.testing.expect(std.mem.find(u8, again.stderr, "as its upstream now") == null);
    try std.testing.expectEqualStrings(try w.head("lib"), try w.remoteAt("lib", "refs/tags/v0.1.2"));
}

test "the version is the section's largest change, and a dry run changes nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.package("stable", "1.2.3", "");
    const Case = struct { dir: []const u8, body: []const u8, version: []const u8 };
    for ([_]Case{
        .{ .dir = "lib", .body = "### Added\n\n- More.\n\n### Fixed\n\n- A fix.\n", .version = "0.1.0 -> 0.1.1 (feature)" },
        .{ .dir = "lib", .body = "### Breaking\n\n- Less.\n", .version = "0.1.0 -> 0.2.0 (breaking)" },
        .{ .dir = "lib", .body = "### Removed\n\n- An option.\n", .version = "0.1.0 -> 0.2.0 (breaking)" },
        .{ .dir = "stable", .body = "### Added\n\n- More.\n", .version = "1.2.3 -> 1.3.0 (feature)" },
        .{ .dir = "stable", .body = "### Security\n\n- A check.\n", .version = "1.2.3 -> 1.2.4 (fix)" },
    }) |case| {
        try w.change(case.dir, case.body);
        const start = try w.head(case.dir);
        const dry = try w.releaseIn(case.dir, &.{"--dry-run"});
        try std.testing.expect(succeeded(dry));
        try std.testing.expect(contains(dry.stdout, case.version));
        try std.testing.expect(contains(dry.stdout, "gate it here"));
        try std.testing.expect(contains(dry.stdout, "push it to origin/main and the tag v"));
        // Nothing moved: the commit, the tree, the tags, the remote.
        try std.testing.expectEqualStrings(start, try w.head(case.dir));
        try std.testing.expectEqualStrings("", try w.out(case.dir, &.{ "status", "--porcelain" }));
        try std.testing.expectEqual(0, try w.gated(start));
        try w.git(case.dir, &.{ "reset", "--quiet", "--hard", "HEAD^" });
    }
}

test "each refusal names its cause and leaves the branch, the tags and the remote as they were" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const start = try w.head("lib");
    const remote_main = try w.remoteAt("lib", "refs/heads/main");
    const Expect = struct {
        fn refusal(world: *World, said: []const u8, at: []const u8, main: []const u8) !void {
            const result = try world.releaseIn("lib", &.{});
            try std.testing.expect(refused(result));
            try std.testing.expect(contains(result.stderr, said));
            try std.testing.expectEqualStrings(at, try world.head("lib"));
            try std.testing.expectEqualStrings("v0.1.0", try world.out("lib", &.{ "tag", "--list" }));
            try std.testing.expectEqualStrings(main, try world.remoteAt("lib", "refs/heads/main"));
            try std.testing.expectEqualStrings("", try world.remoteAt("lib", "refs/tags/v0.1.1"));
        }
    };
    // A tree with changes.
    try w.f.write("lib", "stray.txt", "x");
    try Expect.refusal(&w, "the tree has changes", start, remote_main);
    try w.f.tmp.dir.deleteFile(w.f.io, "lib/stray.txt");
    // A remote pushed to by anything but SSH.
    try w.git("lib", &.{ "remote", "set-url", "--push", "origin", try w.path("remotes/lib.git") });
    try Expect.refusal(&w, "which is not SSH", start, remote_main);
    try w.git("lib", &.{ "remote", "set-url", "--push", "origin", try w.sshUrl("lib") });
    // HEAD detached, and a branch with no upstream that more than one remote could take.
    try w.git("lib", &.{ "checkout", "--quiet", "--detach" });
    try Expect.refusal(&w, "HEAD is detached", start, remote_main);
    try w.git("lib", &.{ "checkout", "--quiet", "-b", "loose" });
    try w.git("lib", &.{ "remote", "add", "mirror", try w.sshUrl("lib") });
    try Expect.refusal(&w, "loose has no upstream, and more than one remote could take it", start, remote_main);
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/heads/loose"));
    try w.git("lib", &.{ "remote", "remove", "mirror" });
    try w.git("lib", &.{ "checkout", "--quiet", "main" });
    // The manifest and the CHANGELOG at different releases.
    try w.f.write("lib", "build.zig.zon", try std.mem.replaceOwned(u8, w.f.a, try w.read("lib", "build.zig.zon"), "\"0.1.0\"", "\"0.1.5\""));
    try w.git("lib", &.{ "commit", "--quiet", "-am", "Hand bump" });
    try Expect.refusal(&w, "build.zig.zon's .version is 0.1.5 and CHANGELOG.md's newest release is 0.1.0", try w.head("lib"), remote_main);
    try w.git("lib", &.{ "reset", "--quiet", "--hard", start });
    // An entry under no group.
    try w.change("lib", "- Loose.\n");
    try Expect.refusal(&w, "CHANGELOG.md:5: an entry under no group", try w.head("lib"), remote_main);
    try w.git("lib", &.{ "reset", "--quiet", "--hard", start });
    // A pin at no release: a Zig package on a branch, and on a version tag that does not name
    // the pinned commit; one at a release whose hash its URL does not hold; an archive that is
    // no package (an `N-V-` hash) on a branch; and a package that says it is none, at an exact
    // commit, which the hash its URL holds gives away.
    try w.package("dep", "0.1.0", "");
    const package_hash = "dep-0.1.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const plain_hash = "N-V-__8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const pins = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "?ref=main", try w.head("dep"), package_hash, "dep (a Zig package at main: a package is released at a version tag) pinned at no release" },
        .{ "?ref=v0.1.0", start, package_hash, "dep (a Zig package: v0.1.0 is no tag at " },
        // At the tag, by a hash of other content: Zig would take what its cache held under it
        // (review-1029b m-d).
        .{ "?ref=v0.1.0", try w.head("dep"), package_hash, "dep (its .hash is dep-0.1.0-AAAA" },
        .{ "?ref=main", try w.head("dep"), plain_hash, "dep (no Zig package, at main, which moves" },
        .{ "", try w.head("dep"), plain_hash, "dep (its .hash is N-V-__8AAAA" },
    };
    for (pins) |pin| {
        const ref, const commit, const hash, const said = pin;
        const dev = try w.f.a.print("    .dependencies = .{{}},\n    .dev_dependencies = .{{ .dep = .{{ .url = \"{s}{s}#{s}\", .hash = \"{s}\" }} }},\n", .{ try w.pinUrl("dep"), ref, commit, hash });
        try w.f.write("lib", "build.zig.zon", try std.mem.replaceOwned(u8, w.f.a, try w.read("lib", "build.zig.zon"), "    .dependencies = .{},\n", dev));
        try w.git("lib", &.{ "commit", "--quiet", "-am", "Pin dep" });
        try Expect.refusal(&w, said, try w.head("lib"), remote_main);
        try w.git("lib", &.{ "reset", "--quiet", "--hard", start });
    }
    // Until shakedown 0.7.0 is released, a development pin at an exact commit passes the rule,
    // named, and goes on to the hash proof (a hash of other content here, refused there); a
    // runtime pin at the same commit is refused, and so is the development pin once 0.7.0 is out.
    try w.package("shakedown", "0.6.0", "");
    const shakedown_commit = try w.head("shakedown");
    const shakedown_hash = "shakedown-0.6.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "dev_dependencies", "development pins at a commit, allowed until shakedown 0.7.0 is released: shakedown at ", "shakedown (its .hash is shakedown-0.6.0-AAAA" },
        .{ "dependencies", "shakedown (a Zig package at main: a package is released at a version tag) pinned at no release", "" },
    }) |case| {
        const key, const named, const then = case;
        const entry = try w.f.a.print(".{{ .shakedown = .{{ .url = \"{s}?ref=main#{s}\", .hash = \"{s}\" }} }}", .{ try w.pinUrl("shakedown"), shakedown_commit, shakedown_hash });
        const zon = try w.f.a.print("    .dependencies = {s},\n    .dev_dependencies = {s},\n", .{
            if (std.mem.eql(u8, key, "dependencies")) entry else ".{}",
            if (std.mem.eql(u8, key, "dev_dependencies")) entry else ".{}",
        });
        try w.f.write("lib", "build.zig.zon", try std.mem.replaceOwned(u8, w.f.a, try w.read("lib", "build.zig.zon"), "    .dependencies = .{},\n", zon));
        try w.git("lib", &.{ "commit", "--quiet", "-am", "Pin shakedown at a commit" });
        try Expect.refusal(&w, named, try w.head("lib"), remote_main);
        if (then.len != 0) try Expect.refusal(&w, then, try w.head("lib"), remote_main);
        try w.git("lib", &.{ "reset", "--quiet", "--hard", start });
    }
    try w.git("shakedown", &.{ "tag", "v0.7.0" });
    try w.git("shakedown", &.{ "push", "--quiet", "origin", "v0.7.0" });
    const released = try w.f.a.print("    .dependencies = .{{}},\n    .dev_dependencies = .{{ .shakedown = .{{ .url = \"{s}?ref=main#{s}\", .hash = \"{s}\" }} }},\n", .{ try w.pinUrl("shakedown"), shakedown_commit, shakedown_hash });
    try w.f.write("lib", "build.zig.zon", try std.mem.replaceOwned(u8, w.f.a, try w.read("lib", "build.zig.zon"), "    .dependencies = .{},\n", released));
    try w.git("lib", &.{ "commit", "--quiet", "-am", "Pin shakedown at a commit" });
    try Expect.refusal(&w, "shakedown (a Zig package at main: a package is released at a version tag) pinned at no release", try w.head("lib"), remote_main);
    try w.git("lib", &.{ "reset", "--quiet", "--hard", start });
    // The version to come tagged already, on the remote.
    try w.git(".", &.{ "clone", "--quiet", try w.path("remotes/lib.git"), "other" });
    try w.git("other", &.{ "tag", "v0.1.1" });
    try w.git("other", &.{ "push", "--quiet", "origin", "v0.1.1" });
    const tagged = try w.releaseIn("lib", &.{});
    try std.testing.expect(refused(tagged));
    try std.testing.expect(contains(tagged.stderr, "v0.1.1 is on origin already"));
    try std.testing.expectEqualStrings(start, try w.head("lib"));
    try w.git("other", &.{ "push", "--quiet", "origin", ":refs/tags/v0.1.1" });
    // A branch behind its remote.
    try w.f.write("other", "more.txt", "x");
    try w.git("other", &.{ "add", "." });
    try w.git("other", &.{ "commit", "--quiet", "-m", "Elsewhere" });
    try w.git("other", &.{ "push", "--quiet", "origin", "main" });
    try Expect.refusal(&w, "main is behind origin/main", start, try w.remoteAt("other", "refs/heads/main"));
    // Nothing in [Unreleased] is nothing to release, which is no failure.
    try w.git("lib", &.{ "reset", "--quiet", "--hard", "origin/main" });
    const empty = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(empty));
    try std.testing.expect(contains(empty.stderr, "nothing to release"));
}

test "a red gate tags nothing, pushes nothing, and puts the branch back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.f.write("lib", "red", "");
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const start = try w.head("lib");
    const remote_main = try w.remoteAt("lib", "refs/heads/main");
    const result = try w.releaseIn("lib", &.{});
    // Refused is exit 1, never 0: a script reads the code, not the sentence.
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(contains(result.stderr, "the gate is red here (its output: "));
    try std.testing.expect(contains(result.stderr, "gate-here.log): nothing was tagged or pushed"));
    // The log holds the red gate's own output.
    try std.testing.expect(contains(try w.read("lib", ".zig-cache/bay/release/gate-here.log"), "error: Red"));
    try std.testing.expectEqualStrings(start, try w.head("lib"));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "status", "--porcelain" }));
    try std.testing.expect(contains(try w.read("lib", "CHANGELOG.md"), "## [Unreleased]\n\n### Fixed\n\n- A fix.\n"));
    try std.testing.expectEqualStrings("v0.1.0", try w.out("lib", &.{ "tag", "--list" }));
    try std.testing.expectEqualStrings(remote_main, try w.remoteAt("lib", "refs/heads/main"));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));
}

test "two branches adding lines under one group rebase with no conflict, and release as one group" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.change("lib", "### Fixed\n\n- Base.\n");
    try w.git("lib", &.{ "push", "--quiet", "origin", "main" });
    try w.git(".", &.{ "clone", "--quiet", try w.path("remotes/lib.git"), "other" });
    // Each adds its line under Fixed, at the same place.
    for ([_][]const u8{ "lib", "other" }, [_][]const u8{ "- Ours.", "- Theirs." }) |dir, line| {
        try w.f.write(dir, "CHANGELOG.md", try std.mem.replaceOwned(u8, w.f.a, try w.read(dir, "CHANGELOG.md"), "- Base.\n", try w.f.a.print("- Base.\n{s}\n", .{line})));
        try w.git(dir, &.{ "commit", "--quiet", "-am", line });
    }
    try w.git("other", &.{ "push", "--quiet", "origin", "main" });
    try w.git("lib", &.{ "fetch", "--quiet", "origin" });
    try w.git("lib", &.{ "rebase", "--quiet", "origin/main" });
    const merged = try w.read("lib", "CHANGELOG.md");
    try std.testing.expect(contains(merged, "- Ours.") and contains(merged, "- Theirs."));
    try std.testing.expect(std.mem.find(u8, merged, "<<<<<<<") == null);
    try std.testing.expect(succeeded(try w.releaseIn("lib", &.{})));
    try std.testing.expect(contains(try w.read("lib", "CHANGELOG.md"), "## [0.1.1]"));
    const released = try w.read("lib", "CHANGELOG.md");
    try std.testing.expectEqual(1, std.mem.count(u8, released, "### Fixed\n\n- Base.\n"));
    try std.testing.expect(contains(released, "- Theirs.") and contains(released, "- Ours."));
    // Without the union driver, git leaves the same rebase in conflict.
    try w.package("plain", "0.1.0", "");
    try w.f.write("plain", ".gitattributes", "");
    try w.change("plain", "### Fixed\n\n- Base.\n");
    try w.git("plain", &.{ "push", "--quiet", "origin", "main" });
    try w.git(".", &.{ "clone", "--quiet", try w.path("remotes/plain.git"), "plain-other" });
    for ([_][]const u8{ "plain", "plain-other" }, [_][]const u8{ "- Ours.", "- Theirs." }) |dir, line| {
        try w.f.write(dir, "CHANGELOG.md", try std.mem.replaceOwned(u8, w.f.a, try w.read(dir, "CHANGELOG.md"), "- Base.\n", try w.f.a.print("- Base.\n{s}\n", .{line})));
        try w.git(dir, &.{ "commit", "--quiet", "-am", line });
    }
    try w.git("plain-other", &.{ "push", "--quiet", "origin", "main" });
    try w.git("plain", &.{ "fetch", "--quiet", "origin" });
    try std.testing.expect(refused(try w.f.run("plain", &.{ "git", "rebase", "--quiet", "origin/main" })));
}

test "a release stopped after its commit or its push is finished, and never tags a commit no gate passed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    const hook = "remotes/lib.git/hooks/pre-receive";
    // A gate that passed and a push the remote refused: the gated commit stays, recorded.
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    try refusePushes(&w, hook);
    const stopped = try w.releaseIn("lib", &.{});
    try std.testing.expect(refused(stopped));
    try std.testing.expect(contains(stopped.stderr, "the push to origin failed, and nothing moved there"));
    const commit = try w.head("lib");
    try std.testing.expectEqualStrings("Release v0.1.1", try w.out("lib", &.{ "log", "-1", "--format=%s" }));
    try std.testing.expectEqualStrings(commit, try w.gateRecord("lib", "v0.1.1"));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "for-each-ref", "refs/bay" }));
    try std.testing.expectEqualStrings("v0.1.0", try w.out("lib", &.{ "tag", "--list" }));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));
    // A run stopped before its gate ended has no record: the next run gates the commit again,
    // and a ref made by hand where bay once kept the record is no gate passed.
    try w.f.tmp.dir.deleteTree(w.f.io, try w.f.dataDir(&.{"gated"}));
    try w.git("lib", &.{ "update-ref", "refs/bay/gated/v0.1.1", commit });
    try w.f.tmp.dir.deleteFile(w.f.io, hook);
    const resumed = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(resumed));
    try std.testing.expect(contains(resumed.stderr, "v0.1.1 is under way"));
    try std.testing.expectEqual(2, try w.gated(commit));
    try std.testing.expectEqualStrings("", try w.gateRecord("lib", "v0.1.1"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/tags/v0.1.1"));
    // With the record, the next run pushes the gated commit without gating it again.
    try w.change("lib", "### Fixed\n\n- Another fix.\n");
    try refusePushes(&w, hook);
    try std.testing.expect(refused(try w.releaseIn("lib", &.{})));
    const second = try w.head("lib");
    try w.f.tmp.dir.deleteFile(w.f.io, hook);
    const pushed = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(pushed));
    try std.testing.expect(contains(pushed.stderr, "was gated green; pushing it"));
    try std.testing.expectEqual(1, try w.gated(second));
    try std.testing.expectEqualStrings(second, try w.remoteAt("lib", "refs/tags/v0.1.2"));
    // Held with --no-push: gated, recorded, nothing on the remote; the next run pushes it ungated.
    try w.change("lib", "### Fixed\n\n- A held fix.\n");
    const held = try w.releaseIn("lib", &.{"--no-push"});
    try std.testing.expect(succeeded(held));
    try std.testing.expect(contains(held.stderr, "v0.1.3 at"));
    const third = try w.head("lib");
    try std.testing.expectEqualStrings(third, try w.gateRecord("lib", "v0.1.3"));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.3"));
    try std.testing.expect(succeeded(try w.releaseIn("lib", &.{})));
    try std.testing.expectEqual(1, try w.gated(third));
    try std.testing.expectEqualStrings(third, try w.remoteAt("lib", "refs/tags/v0.1.3"));
    // Pushed, with the tag here lost before the read-back: the remote's is taken.
    try w.git("lib", &.{ "tag", "--delete", "v0.1.3" });
    const confirmed = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(confirmed));
    try std.testing.expect(contains(confirmed.stderr, "v0.1.3 is on origin at"));
    try std.testing.expectEqualStrings(third, try w.out("lib", &.{ "rev-parse", "v0.1.3^{commit}" }));
    try std.testing.expectEqualStrings("tag", try w.out("lib", &.{ "cat-file", "-t", "v0.1.3" }));
    // A stopped release under later commits is refused, naming it; so is a tag made here and never pushed.
    try w.change("lib", "### Fixed\n\n- A third fix.\n");
    try refusePushes(&w, hook);
    try std.testing.expect(refused(try w.releaseIn("lib", &.{})));
    try w.f.tmp.dir.deleteFile(w.f.io, hook);
    try w.f.write("lib", "later.txt", "x");
    try w.git("lib", &.{ "add", "." });
    try w.git("lib", &.{ "commit", "--quiet", "-m", "Later" });
    const buried = try w.releaseIn("lib", &.{});
    try std.testing.expect(refused(buried));
    try std.testing.expect(contains(buried.stderr, "CHANGELOG.md releases 0.1.4, and no tag names it"));
    try w.git("lib", &.{ "reset", "--quiet", "--hard", "v0.1.3" });
    try w.change("lib", "### Fixed\n\n- A fourth fix.\n");
    try w.git("lib", &.{ "tag", "v0.1.4" });
    const local = try w.releaseIn("lib", &.{});
    try std.testing.expect(refused(local));
    try std.testing.expect(contains(local.stderr, "is tagged here already"));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.4"));
}

/// `policy` as the package's policy in its ci/preflight.json, committed and pushed.
fn familyPolicy(w: *World, dir: []const u8, policy: []const u8) !void {
    try w.f.tmp.dir.createDirPath(w.f.io, try std.fs.path.join(w.f.a, &.{ dir, "ci" }));
    try w.f.write(dir, "ci/preflight.json", try w.f.a.print("{{\n  \"policy\": \"{s}\",\n  \"glint\": {{}}\n}}\n", .{policy}));
    try w.git(dir, &.{ "add", "." });
    try w.git(dir, &.{ "commit", "--quiet", "-m", "Policy" });
    try w.git(dir, &.{ "push", "--quiet", "origin", "main" });
}

/// The remote of `lib` refuses every push while its pre-receive hook is there.
fn refusePushes(w: *World, hook: []const u8) !void {
    try w.f.write(".", hook, "#!/bin/sh\nexit 1\n");
    // Opened for writing: Windows changes a file's attributes only through a handle that may write them.
    const file = try w.f.tmp.dir.openFile(w.f.io, hook, .{ .mode = .read_write });
    defer file.close(w.f.io);
    try file.setPermissions(w.f.io, .executable_file);
}

test "the machine that releases runs the jobs any machine runs, whatever its environment says" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    // Inherited, it would have left the source checks to a machine that is not there
    // (review-1029 M4).
    try w.f.env.put("PREFLIGHT_PORTABLE", "elsewhere");
    const result = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(result));
    const commit = try w.head("lib");
    try std.testing.expect(try w.gatedWith(commit, "unset"));
    try std.testing.expect(!try w.gatedWith(commit, "elsewhere"));
}

test "a release's gate builds with the Zig the manifest names, never the shell's ZIG" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    // A stand-in that passed every build called the gate green (review-1029b N6); this one
    // is no program at all, so a gate that took it could not run.
    try w.f.env.put("ZIG", try w.path("no-zig-here"));
    const result = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(result));
    try std.testing.expect(try w.gatedWith(try w.head("lib"), "unset"));
}

test "a machine gates the release beside this one, and its red stops it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.f.tmp.dir.createDirPath(w.f.io, fixture.config_dir);
    const machine = try std.mem.replaceOwned(u8, w.f.a, try w.path("machine"), "\\", "/");
    try w.f.write(fixture.config_dir, "machines.zon", try w.f.a.print(".{{ .{{ .name = \"elsewhere\", .bay = .{{\"{s}\"}}, .directory = \"{s}\" }} }}\n", .{ try std.mem.replaceOwned(u8, w.f.a, w.f.bay_path, "\\", "\\\\"), machine }));
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const result = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(result));
    const commit = try w.head("lib");
    // Gated here and there, the machine's lines named.
    try std.testing.expect(contains(result.stderr, "elsewhere: bay: gating"));
    try std.testing.expect(contains(result.stderr, "gate on elsewhere: green"));
    try std.testing.expectEqualStrings(commit, try w.out("machine/lib", &.{ "rev-parse", "HEAD" }));
    if (try w.gated(commit) != 2) {
        std.debug.print("{s} gated {d} times; bay said:\n{s}\n", .{ commit, try w.gated(commit), result.stderr });
        return error.TestUnexpectedResult;
    }
    // The source checks run once: here, where the release is made, and not on the machine beside it.
    try std.testing.expect(try w.gatedWith(commit, "unset"));
    try std.testing.expect(try w.gatedWith(commit, "elsewhere"));
    // A machine whose gate is red: nothing is tagged.
    try w.f.write(fixture.config_dir, "machines.zon", ".{ .{ .name = \"broken\", .bay = .{ \"git\", \"no-such-command\" }, .directory = \"/nowhere\" } }\n");
    try w.change("lib", "### Fixed\n\n- Another fix.\n");
    const start = try w.head("lib");
    const red = try w.releaseIn("lib", &.{});
    try std.testing.expect(refused(red));
    try std.testing.expect(red.term == .exited and red.term.exited == 1);
    try std.testing.expect(contains(red.stderr, "the gate is red on broken (its output: "));
    try std.testing.expect(contains(red.stderr, "gate-broken.log)"));
    try std.testing.expectEqualStrings(start, try w.head("lib"));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.2"));
}

test "a workspace's train releases its members in order, each pinned at the release before it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // a; b ships a; c ships b. Only a has changed.
    try w.package("a", "0.1.0", "");
    for ([_][]const u8{ "b", "c" }, [_][]const u8{ "a", "b" }) |dir, dependency| {
        try w.package(dir, "0.1.0", "");
        try std.testing.expect(succeeded(try w.f.bay(dir, &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl(dependency)}) })));
        // The pins and what the build makes from them, committed together.
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", "Pin" });
        try w.git(dir, &.{ "push", "--quiet", "origin", "main" });
    }
    // a is developed with c, which ships b, which ships a: that pin would close a ring, so a
    // goes first and pins c's new release once c has one.
    try std.testing.expect(succeeded(try w.f.bay("a", &.{ "add", "--dev", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("c")}) })));
    try w.git("a", &.{ "add", "." });
    try w.git("a", &.{ "commit", "--quiet", "-m", "Develop with c" });
    try w.git("a", &.{ "push", "--quiet", "origin", "main" });
    try w.f.write(".", "bay.work", ".{ .members = .{ \"c\", \"b\", \"a\" } }\n");
    // Each member says it is the family's, in its own ci/preflight.json; one that does not, or
    // names another policy, refuses the train before anything moves, its dry run too.
    for ([_][]const u8{ "b", "c" }) |dir| try familyPolicy(&w, dir, "family");
    for ([_]struct { []const u8, []const u8 }{
        .{ "", "the train releases the family's packages, and a has no \"policy\": \"family\" in ci/preflight.json: add it to each, so preflight gates it as the family's" },
        .{ "famliy", "the train releases the family's packages, and the one policy is \"family\": a (\"famliy\") names another in ci/preflight.json" },
    }) |case| {
        const policy, const said = case;
        if (policy.len != 0) try familyPolicy(&w, "a", policy);
        for ([_][]const []const u8{ &.{ "--workspace", "release", "--dry-run" }, &.{ "--workspace", "release" } }) |args| {
            const off = try w.f.bay(".", args);
            try std.testing.expect(refused(off));
            try std.testing.expect(contains(off.stderr, said));
        }
    }
    try familyPolicy(&w, "a", "family");
    try w.change("a", "### Fixed\n\n- A fix.\n");
    // The plan, changing nothing: each release, the pins that make it, the closing pass.
    const heads = [_][]const u8{ try w.head("a"), try w.head("b"), try w.head("c") };
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    try std.testing.expect(succeeded(plan));
    for ([_][]const u8{
        "1. a 0.1.0 -> 0.1.1 (fix): its [Unreleased] section\n",
        "2. b 0.1.0 -> 0.1.1 (fix): pins a 0.1.1\n",
        "3. c 0.1.0 -> 0.1.1 (fix): pins b 0.1.1\n",
        "then a develops with c 0.1.1, gated and pushed with no tag\n",
        // Each car's steps, after its tidy run as a dry run.
        "   then: the re-pin committed and built here (bay dev check), if a pin moves; v0.1.1 written from its section and committed; gated here; the branch and the tag pushed\n",
    }) |line| if (!contains(plan.stdout, line)) {
        std.debug.print("expected the line:\n{s}in the plan:\n{s}\n", .{ line, plan.stdout });
        return error.TestUnexpectedResult;
    };
    // Each member's tidy, run as the train runs it, runs the generate step that would follow,
    // and a's again for its closing re-pin.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, plan.stderr, "then the package build's `generate` step would run, and runs clean with those pins"));
    for ([_][]const u8{ "a", "b", "c" }, heads) |dir, head| {
        try std.testing.expectEqualStrings(head, try w.head(dir));
        try std.testing.expectEqualStrings("", try w.out(dir, &.{ "status", "--porcelain" }));
    }
    // One member released alone would gate with the others' trees in place of its pins.
    const alone = try w.releaseIn("a", &.{});
    try std.testing.expect(refused(alone));
    try std.testing.expect(contains(alone.stderr, "bay.work holds this package with c and b: their trees would stand in for the pins"));
    try std.testing.expectEqualStrings(heads[0], try w.head("a"));
    try std.testing.expectEqualStrings("", try w.remoteAt("a", "refs/tags/v0.1.1"));
    const train = try w.f.bay(".", &.{ "--workspace", "release" });
    try std.testing.expect(succeeded(train));
    // In order: a, then b pinning it, then c pinning b; each released and pushed with its tag.
    const said = train.stderr;
    try std.testing.expect(std.mem.find(u8, said, "released a v0.1.1").? < std.mem.find(u8, said, "released b v0.1.1").?);
    try std.testing.expect(std.mem.find(u8, said, "released b v0.1.1").? < std.mem.find(u8, said, "released c v0.1.1").?);
    for ([_][]const u8{ "b", "c" }) |dir| try std.testing.expectEqualStrings(try w.head(dir), try w.remoteAt(dir, "refs/tags/v0.1.1"));
    for ([_][]const u8{ "b", "c" }, [_][]const u8{ "a", "b" }) |dir, dependency| {
        try std.testing.expect(contains(try w.read(dir, "build.zig.zon"), "?ref=v0.1.1#"));
        // What follows from the pins made again with them, in the re-pin's commit.
        try std.testing.expectEqualStrings(try w.out(dir, &.{ "show", "HEAD^:build.zig.zon" }), try w.out(dir, &.{ "show", "HEAD^:pins.txt" }));
        try std.testing.expect(contains(try w.read(dir, "CHANGELOG.md"), try w.f.a.print("## [0.1.1] - {s}\n\n### Changed\n\n- Pins {s} 0.1.1.\n", .{ try today(w.f.a), dependency })));
        try std.testing.expectEqualStrings("Release v0.1.1", try w.out(dir, &.{ "log", "-1", "--format=%s" }));
        try std.testing.expectEqualStrings(try w.f.a.print("Pin {s} 0.1.1", .{dependency}), try w.out(dir, &.{ "log", "-1", "--format=%s", "HEAD^" }));
    }
    // Each gated on what its release publishes. a went first, developed with c, which ships b,
    // which ships a: its release was gated with c and b at its pins (c v0.1.0), not their trees.
    const a_release = try w.remoteAt("a", "refs/tags/v0.1.1");
    for ([_][]const u8{ "b", "c" }) |dir| try std.testing.expect(contains(try w.gatedPinned(a_release), try w.real(dir)));
    // b ships a, released before it: gated on a's new tag, its tree, and c, not yet released, at its pin.
    const b_pinned = try w.gatedPinned(try w.remoteAt("b", "refs/tags/v0.1.1"));
    try std.testing.expect(std.mem.find(u8, b_pinned, try w.real("a")) == null);
    try std.testing.expect(contains(b_pinned, try w.real("c")));
    // c, last, on both releases.
    try std.testing.expectEqualStrings("", try w.gatedPinned(try w.remoteAt("c", "refs/tags/v0.1.1")));
    // a's development pin moved after c's tag: gated and pushed, a release of nothing.
    try std.testing.expectEqualStrings("Pin c 0.1.1", try w.out("a", &.{ "log", "-1", "--format=%s" }));
    try std.testing.expectEqualStrings(try w.head("a"), try w.remoteAt("a", "refs/heads/main"));
    try std.testing.expectEqualStrings(try w.out("a", &.{ "rev-parse", "HEAD^" }), try w.remoteAt("a", "refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings("", try w.remoteAt("a", "refs/tags/v0.1.2"));
    try std.testing.expectEqual(1, std.mem.count(u8, try w.read("a", "build.zig.zon"), "?ref=v0.1.1#"));
    try std.testing.expectEqual(1, try w.gated(try w.head("a")));
    try std.testing.expectEqualStrings("", try w.gatedPinned(try w.head("a")));
}

test "a train refuses a development pin on a member it builds at the pin, at a commit the member's origin does not hold" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // tool releases nothing in the train, so user's gate builds it at user's pin: a commit pushed
    // once to a branch since deleted, which the hosted gate could not fetch.
    try w.package("tool", "0.1.0", "");
    try w.git("tool", &.{ "checkout", "--quiet", "-b", "aside" });
    try w.f.write("tool", "aside.txt", "aside\n");
    try w.git("tool", &.{ "add", "aside.txt" });
    try w.git("tool", &.{ "commit", "--quiet", "-m", "Aside" });
    const aside = try w.head("tool");
    try w.git("tool", &.{ "push", "--quiet", "origin", "aside" });
    try w.git("tool", &.{ "checkout", "--quiet", "main" });
    try w.package("user", "0.1.0", "");
    try std.testing.expect(succeeded(try w.f.bay("user", &.{ "add", "--dev", try w.f.a.print("{s}#{s}", .{ try w.pinUrl("tool"), aside }) })));
    try w.git("tool", &.{ "push", "--quiet", "origin", "--delete", "aside" });
    try w.git("user", &.{ "add", "." });
    try w.git("user", &.{ "commit", "--quiet", "-m", "Develop with tool aside" });
    try w.git("user", &.{ "push", "--quiet", "origin", "main" });
    for ([_][]const u8{ "tool", "user" }) |dir| try familyPolicy(&w, dir, "family");
    try w.change("user", "### Fixed\n\n- A fix.\n");
    try w.f.write(".", "bay.work", ".{ .members = .{ \"tool\", \"user\" } }\n");
    const head = try w.head("user");
    for ([_][]const []const u8{ &.{ "--workspace", "release", "--dry-run" }, &.{ "--workspace", "release" } }) |args| {
        const refusal = try w.f.bay(".", args);
        try std.testing.expect(refused(refusal));
        try std.testing.expect(contains(refusal.stderr, try w.f.a.print("user develops with tool at {s}, which no branch or tag of {s}'s origin holds", .{ aside[0..12], try w.real("tool") })));
        try std.testing.expectEqualStrings(head, try w.head("user"));
        try std.testing.expectEqualStrings("", try w.remoteAt("user", "refs/tags/v0.1.1"));
    }
}

test "a train's plan is what its run tags: a first release the manifest's version, a later one its change's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // new has never been released; old has, and has a change since.
    try w.unreleased("new", "0.1.0");
    try w.package("old", "0.1.0", "");
    try w.change("old", "### Added\n\n- More.\n");
    for ([_][]const u8{ "new", "old" }) |dir| try familyPolicy(&w, dir, "family");
    try w.f.write(".", "bay.work", ".{ .members = .{ \"new\", \"old\" } }\n");
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    try std.testing.expect(succeeded(plan));
    for ([_][]const u8{ "new 0.1.0 -> 0.1.0 (feature, its first release): its [Unreleased] section\n", "old 0.1.0 -> 0.1.1 (feature): its [Unreleased] section\n" }) |line| if (!contains(plan.stdout, line)) {
        std.debug.print("expected the line:\n{s}in the plan:\n{s}\n", .{ line, plan.stdout });
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release" })));
    // What the plan said is what the run tagged, and no other version.
    try std.testing.expectEqualStrings(try w.head("new"), try w.remoteAt("new", "refs/tags/v0.1.0"));
    try std.testing.expectEqualStrings("", try w.remoteAt("new", "refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings(try w.head("old"), try w.remoteAt("old", "refs/tags/v0.1.1"));
}

test "a train's plan refuses the pins its run refuses: a package no member, pinned at a commit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // user ships ext, released and no member of the workspace, pinned at a commit: the train
    // moves no pin of ext.
    try w.package("ext", "0.1.0", "");
    try w.package("user", "0.1.0", "");
    try std.testing.expect(succeeded(try w.f.bay("user", &.{ "add", try w.f.a.print("{s}#{s}", .{ try w.pinUrl("ext"), try w.head("ext") }) })));
    try w.git("user", &.{ "add", "." });
    try w.git("user", &.{ "commit", "--quiet", "-m", "Pin ext at a commit" });
    try w.git("user", &.{ "push", "--quiet", "origin", "main" });
    try familyPolicy(&w, "user", "family");
    try w.change("user", "### Fixed\n\n- A fix.\n");
    try w.f.write(".", "bay.work", ".{ .members = .{\"user\"} }\n");
    const head = try w.head("user");
    for ([_][]const []const u8{ &.{ "--workspace", "release", "--dry-run" }, &.{ "--workspace", "release" } }) |args| {
        const refusal = try w.f.bay(".", args);
        try std.testing.expect(refused(refusal));
        try std.testing.expect(contains(refusal.stderr, "ext (a Zig package at "));
        try std.testing.expect(contains(refusal.stderr, ") pinned at no release"));
        try std.testing.expectEqualStrings(head, try w.head("user"));
        try std.testing.expectEqualStrings("", try w.remoteAt("user", "refs/tags/v0.1.1"));
    }
    try std.testing.expect(contains((try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" })).stderr, "user: the train would stop at it, at its pins, before it releases"));
    // At its release, the plan and the run both go through.
    try std.testing.expect(succeeded(try w.f.bay("user", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("ext")}) })));
    try w.git("user", &.{ "add", "." });
    try w.git("user", &.{ "commit", "--quiet", "-m", "Pin ext at its release" });
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" })));
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release" })));
    try std.testing.expectEqualStrings(try w.head("user"), try w.remoteAt("user", "refs/tags/v0.1.1"));
}

test "a release's graph holds each package at a version under one hash, in the plan and the run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // dep 0.1.0, and a copy of it published elsewhere whose v0.1.0 is other content: one
    // package, one version, two hashes.
    try w.package("dep", "0.1.0", "");
    try w.git(".", &.{ "clone", "--quiet", try w.path("remotes/dep.git"), "copy" });
    try w.f.write("copy", "lib.zig", "// other content\n");
    try w.git("copy", &.{ "add", "." });
    try w.git("copy", &.{ "commit", "--quiet", "-m", "Other content" });
    try w.git("copy", &.{ "tag", "--force", "v0.1.0" });
    try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", try w.path("remotes/copy.git") });
    try w.git("copy", &.{ "push", "--quiet", try w.path("remotes/copy.git"), "main", "--tags" });
    // mid ships dep, released; top ships mid and the copy's dep, each pin a release.
    try w.package("mid", "0.1.0", "");
    try std.testing.expect(succeeded(try w.f.bay("mid", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("dep")}) })));
    try w.git("mid", &.{ "add", "." });
    try w.git("mid", &.{ "commit", "--quiet", "-m", "Pin dep" });
    try w.git("mid", &.{ "push", "--quiet", "origin", "main" });
    try w.change("mid", "### Changed\n\n- Pins dep 0.1.0.\n");
    try std.testing.expect(succeeded(try w.releaseIn("mid", &.{})));
    try w.package("top", "0.1.0", "");
    for ([_][]const u8{ try w.f.a.print("{s}#v0.1.1", .{try w.pinUrl("mid")}), try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("copy")}) }) |pin|
        try std.testing.expect(succeeded(try w.f.bay("top", &.{ "add", pin })));
    try w.git("top", &.{ "add", "." });
    try w.git("top", &.{ "commit", "--quiet", "-m", "Pin mid and the copy" });
    try w.git("top", &.{ "push", "--quiet", "origin", "main" });
    try familyPolicy(&w, "top", "family");
    try w.change("top", "### Fixed\n\n- A fix.\n");
    try w.f.write(".", "bay.work", ".{ .members = .{\"top\"} }\n");
    const head = try w.head("top");
    for ([_][]const []const u8{ &.{ "--workspace", "release", "--dry-run" }, &.{ "--workspace", "release" } }) |args| {
        const refusal = try w.f.bay(".", args);
        try std.testing.expect(refused(refusal));
        try std.testing.expect(contains(refusal.stderr, "dep 0.1.0 (fingerprint 0x"));
        try std.testing.expect(contains(refusal.stderr, "(pinned by mid)"));
        try std.testing.expect(contains(refusal.stderr, "(pinned by top)"));
        try std.testing.expect(contains(refusal.stderr, "the graph Zig fetches holds one package at one version under two hashes"));
        try std.testing.expectEqualStrings(head, try w.head("top"));
        try std.testing.expectEqualStrings("", try w.remoteAt("top", "refs/tags/v0.1.1"));
    }
    // Pinned where mid pins it, one hash: the plan and the run both go through.
    try std.testing.expect(succeeded(try w.f.bay("top", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("dep")}) })));
    try w.git("top", &.{ "add", "." });
    try w.git("top", &.{ "commit", "--quiet", "-m", "Pin dep where mid does" });
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" })));
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release" })));
    try std.testing.expectEqualStrings(try w.head("top"), try w.remoteAt("top", "refs/tags/v0.1.1"));
}

test "a train's plan moves a member it releases in every tree it reaches, as the run does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // x 0.1.0, and a commit after it that still says 0.1.0: two contents of one version.
    try w.package("x", "0.1.0", "");
    try w.change("x", "### Fixed\n\n- A fix.\n");
    try w.git("x", &.{ "push", "--quiet", "origin", "main" });
    // y pins that commit and u the release; z pins y and u, and x only through them.
    for ([_][]const u8{ "y", "u" }, [_][]const u8{ try w.head("x"), "v0.1.0" }) |dir, at| {
        try w.package(dir, "0.1.0", "");
        try std.testing.expect(succeeded(try w.f.bay(dir, &.{ "add", try w.f.a.print("{s}#{s}", .{ try w.pinUrl("x"), at }) })));
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", "Pin x" });
        try w.git(dir, &.{ "push", "--quiet", "origin", "main" });
    }
    try w.package("z", "0.1.0", "");
    for ([_][]const u8{ "y", "u" }) |dependency| try std.testing.expect(succeeded(try w.f.bay("z", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl(dependency)}) })));
    try w.git("z", &.{ "add", "." });
    try w.git("z", &.{ "commit", "--quiet", "-m", "Pin y and u" });
    try w.git("z", &.{ "push", "--quiet", "origin", "main" });
    for ([_][]const u8{ "y", "u", "z" }) |dir| try w.change(dir, "### Fixed\n\n- A fix.\n");
    for ([_][]const u8{ "x", "y", "u", "z" }) |dir| try familyPolicy(&w, dir, "family");
    try w.f.write(".", "bay.work", ".{ .members = .{ \"x\", \"y\", \"u\", \"z\" } }\n");
    // The train releases x first and pins y and u at it: z's graph holds x once, in the plan
    // as in the run.
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    if (!succeeded(plan)) {
        std.debug.print("the plan refused what the run releases:\n{s}\n", .{plan.stderr});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(contains(plan.stdout, "z 0.1.0 -> 0.1.1 (fix): its [Unreleased] section, and pins "));
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release" })));
    for ([_][]const u8{ "x", "y", "u", "z" }) |dir| try std.testing.expectEqualStrings(try w.head(dir), try w.remoteAt(dir, "refs/tags/v0.1.1"));
}

test "a train's plan pins a member with nothing to release at its release, in every member's tree, as the run does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // l before its first release: two commits that both say 0.0.0, a pinning one and b the
    // other. Then l is released as 0.1.0, and has nothing more to release.
    try w.unreleased("l", "0.0.0");
    const first = try w.head("l");
    try w.f.write("l", "lib.zig", "// second\n");
    try w.git("l", &.{ "add", "." });
    try w.git("l", &.{ "commit", "--quiet", "-m", "Second" });
    try w.git("l", &.{ "push", "--quiet", "origin", "main" });
    for ([_][]const u8{ "a", "b" }, [_][]const u8{ first, try w.head("l") }) |dir, at| {
        try w.package(dir, "0.1.0", "");
        try std.testing.expect(succeeded(try w.f.bay(dir, &.{ "add", try w.f.a.print("{s}#{s}", .{ try w.pinUrl("l"), at }) })));
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", "Pin l" });
        try w.git(dir, &.{ "push", "--quiet", "origin", "main" });
    }
    try w.f.write("l", "build.zig.zon", try std.mem.replaceOwned(u8, w.f.a, try w.read("l", "build.zig.zon"), "\"0.0.0\"", "\"0.1.0\""));
    try w.git("l", &.{ "commit", "--quiet", "-am", "Version 0.1.0" });
    try w.git("l", &.{ "push", "--quiet", "origin", "main" });
    try std.testing.expect(succeeded(try w.releaseIn("l", &.{})));
    // z pins a and b, and l only through them.
    try w.package("z", "0.1.0", "");
    for ([_][]const u8{ "a", "b" }) |dependency| try std.testing.expect(succeeded(try w.f.bay("z", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl(dependency)}) })));
    try w.git("z", &.{ "add", "." });
    try w.git("z", &.{ "commit", "--quiet", "-m", "Pin a and b" });
    try w.git("z", &.{ "push", "--quiet", "origin", "main" });
    for ([_][]const u8{ "a", "b", "z" }) |dir| try w.change(dir, "### Fixed\n\n- A fix.\n");
    for ([_][]const u8{ "l", "a", "b", "z" }) |dir| try familyPolicy(&w, dir, "family");
    try w.f.write(".", "bay.work", ".{ .members = .{ \"l\", \"a\", \"b\", \"z\" } }\n");
    // The train pins a and b at l 0.1.0 before z: z's graph holds l once, in the plan as in
    // the run.
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    if (!succeeded(plan)) {
        std.debug.print("the plan refused what the run releases:\n{s}\n", .{plan.stderr});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(contains(plan.stdout, "1. l 0.1.0: nothing to release\n"));
    try std.testing.expect(succeeded(try w.f.bay(".", &.{ "--workspace", "release" })));
    for ([_][]const u8{ "a", "b", "z" }) |dir| try std.testing.expectEqualStrings(try w.head(dir), try w.remoteAt(dir, "refs/tags/v0.1.1"));
}

test "a train builds each member on the pins it moved it to, and one that does not build goes no further" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // y ships x 0.1.0, and does not compile against x 0.1.1, the release the train makes.
    try w.package("x", "0.1.0", "");
    try w.package("y", "0.1.0", "");
    try std.testing.expect(succeeded(try w.f.bay("y", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("x")}) })));
    try w.f.write("y", "check.zig", "comptime {\n    if (@import(\"std\").mem.find(u8, @embedFile(\"build.zig.zon\"), \"?ref=v0.1.1#\") != null) @compileError(\"x 0.1.1 changed what y calls\");\n}\n");
    try w.git("y", &.{ "add", "." });
    try w.git("y", &.{ "commit", "--quiet", "-m", "Pin x" });
    try w.git("y", &.{ "push", "--quiet", "origin", "main" });
    for ([_][]const u8{ "x", "y" }) |dir| {
        try w.change(dir, "### Fixed\n\n- A fix.\n");
        try familyPolicy(&w, dir, "family");
    }
    try w.f.write(".", "bay.work", ".{ .members = .{ \"x\", \"y\" } }\n");
    const head = try w.head("y");
    const remote_main = try w.remoteAt("y", "refs/heads/main");
    const train = try w.f.bay(".", &.{ "--workspace", "release" });
    try std.testing.expect(refused(train));
    try std.testing.expect(contains(train.stderr, "y: does not build on the pins the train moved it to (bay dev check)"));
    try std.testing.expect(contains(train.stderr, "x 0.1.1 changed what y calls"));
    // x went out; y is as it was, here and on its remote, and was never gated.
    try std.testing.expectEqualStrings(try w.head("x"), try w.remoteAt("x", "refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings(head, try w.head("y"));
    try std.testing.expectEqualStrings("", try w.out("y", &.{ "status", "--porcelain" }));
    try std.testing.expectEqualStrings(remote_main, try w.remoteAt("y", "refs/heads/main"));
    try std.testing.expectEqualStrings("", try w.remoteAt("y", "refs/tags/v0.1.1"));
    try std.testing.expectEqual(0, try w.gated(head));
}

/// GitHub's API as a test scripts it: a server on the loopback that answers each request in
/// turn, one connection per request, and keeps what each asked. `stop` ends `serve`.
const FakeGitHub = struct {
    server: Io.net.Server,
    replies: []const Reply = &.{},
    seen: std.ArrayList(Seen) = .empty,
    /// Set by `stop`: the connection `serve` takes next ends it, unanswered.
    stopping: std.atomic.Value(bool) = .init(false),
    /// A ref file of the remote, read as each reply is sent: its commit stands for `{head}` in
    /// the reply, as GitHub names the commit a run is on.
    head_from: []const u8 = "",

    const Reply = struct { status: std.http.Status, body: []const u8 };
    const Seen = struct { method: std.http.Method, target: []const u8, authorization: []const u8, body: []const u8 };

    fn init(io: Io) !FakeGitHub {
        var address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .server = try address.listen(io, .{ .reuse_address = true }) };
    }

    fn url(f: *FakeGitHub, a: std.mem.Allocator) ![]const u8 {
        return a.print("http://127.0.0.1:{d}", .{f.server.socket.address.getPort()});
    }

    fn serve(f: *FakeGitHub, io: Io, a: std.mem.Allocator) void {
        for (f.replies) |reply| {
            const stream = f.server.accept(io) catch return;
            defer stream.close(io);
            if (f.stopping.load(.acquire)) return;
            f.answer(io, a, stream, reply) catch return;
        }
    }

    /// Ends `serve`: a connection it takes once `stopping` is set, which wakes it where it
    /// waits in `accept` for a reply bay did not ask for. Where it has answered every reply,
    /// the connection waits in the listen queue until the server is closed.
    fn stop(f: *FakeGitHub, io: Io) !void {
        f.stopping.store(true, .release);
        const wake = try f.server.socket.address.connect(io, .{ .mode = .stream });
        wake.close(io);
    }

    fn answer(f: *FakeGitHub, io: Io, a: std.mem.Allocator, stream: Io.net.Stream, reply: Reply) !void {
        var in_buffer: [16 * 1024]u8 = @splat(0);
        var out_buffer: [16 * 1024]u8 = @splat(0);
        var in = stream.reader(io, &in_buffer);
        var out = stream.writer(io, &out_buffer);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        var asked = try http.receiveHead();
        const target = try a.dupe(u8, asked.head.target);
        const method = asked.head.method;
        var authorization: []const u8 = "";
        var headers = asked.iterateHeaders();
        while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            authorization = try a.dupe(u8, header.value);
        };
        var body_buffer: [4096]u8 = @splat(0);
        const body = try (asked.readerExpectNone(&body_buffer)).allocRemaining(a, .limited(1 << 20));
        try f.seen.append(a, .{ .method = method, .target = target, .authorization = authorization, .body = body });
        const sent = if (f.head_from.len != 0 and std.mem.find(u8, reply.body, "{head}") != null) sent: {
            const commit = std.mem.trim(u8, try Io.Dir.cwd().readFileAlloc(io, f.head_from, a, .limited(256)), " \r\n");
            break :sent try std.mem.replaceOwned(u8, a, reply.body, "{head}", commit);
        } else reply.body;
        try asked.respond(sent, .{ .status = reply.status, .keep_alive = false });
    }

    /// `bay release` in `dir` with this API and `token`, the replies answered in turn.
    fn release(f: *FakeGitHub, w: *World, dir: []const u8, token: []const u8, replies: []const Reply) !std.process.RunResult {
        return f.bay(w, dir, &.{"release"}, token, replies);
    }

    /// bay's `command` in `dir` with this API and `token`, the replies answered in turn.
    fn bay(f: *FakeGitHub, w: *World, dir: []const u8, command: []const []const u8, token: []const u8, replies: []const Reply) !std.process.RunResult {
        f.replies = replies;
        f.seen = .empty;
        try w.f.env.put("GITHUB_API_URL", try f.url(w.f.a));
        try w.f.env.put("GITHUB_TOKEN", token);
        defer _ = w.f.env.swapRemove("GITHUB_TOKEN");
        const thread = try std.Thread.spawn(.{}, serve, .{ f, w.f.io, w.f.a });
        const result = w.f.bay(dir, command);
        // `serve` ends before the server it accepts on is closed.
        try f.stop(w.f.io);
        thread.join();
        f.server.deinit(w.f.io);
        f.* = .{ .server = (try init(w.f.io)).server, .seen = f.seen, .head_from = f.head_from };
        return result;
    }
};

/// The package's build with a `dist` step: its program, `p-program`, the release's file.
const dist_build = gate_build[0 .. gate_build.len - "}\n".len] ++
    "    b.step(\"dist\", \"Build the release programs\").dependOn(&b.addInstallFile(b.path(\"lib.zig\"), \"dist/p-program\").step);\n}\n";

test "a release on GitHub is published with its section as notes and the dist step's programs; one left without a token is finished at its tag" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: World = try .init(a);
    defer w.deinit();
    try w.package("p", "1.0.0", "");
    try w.f.write("p", "build.zig", dist_build);
    try w.git("p", &.{ "commit", "--quiet", "-am", "A dist step" });
    // Its remote named as GitHub names it; the ssh stand-in reaches it under its home.
    const home = try w.path("ssh-home");
    try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", try std.fs.path.join(a, &.{ home, "o", "p.git" }) });
    try w.f.env.put("SSH_HOME", home);
    try w.git("p", &.{ "remote", "set-url", "origin", "git@github.com:o/p.git" });
    try w.git("p", &.{ "push", "--quiet", "--set-upstream", "origin", "main", "--tags" });
    var fake: FakeGitHub = try .init(w.f.io);
    defer fake.server.deinit(w.f.io);
    const api = try fake.url(a);

    // Released with a token: GitHub holds no release for the tag, so one is made with the
    // section as its notes, and the program and its SHA256SUMS are uploaded.
    try w.change("p", "### Added\n\n- A step.\n");
    const program = try w.read("p", "lib.zig");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(program, &digest, .{});
    const sums = try a.print("{s}  p-program\n", .{&std.fmt.bytesToHex(digest, .lower)});
    const made = try a.print("{{\"id\":7,\"upload_url\":\"{s}/upload{{?name,label}}\",\"html_url\":\"https://github.com/o/p/releases/tag/v1.1.0\"}}", .{api});
    const published = try fake.release(&w, "p", "t", &.{
        .{ .status = .not_found, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = .created, .body = made },
        .{ .status = .created, .body = "{}" },
        .{ .status = .created, .body = "{}" },
    });
    try std.testing.expect(succeeded(published));
    try std.testing.expect(contains(published.stderr, "v1.1.0 on GitHub: https://github.com/o/p/releases/tag/v1.1.0, with 2 files"));
    const seen = fake.seen.items;
    try std.testing.expectEqual(4, seen.len);
    try std.testing.expectEqualStrings("/repos/o/p/releases/tags/v1.1.0", seen[0].target);
    try std.testing.expectEqualStrings("Bearer t", seen[0].authorization);
    try std.testing.expectEqual(std.http.Method.POST, seen[1].method);
    try std.testing.expectEqualStrings("/repos/o/p/releases", seen[1].target);
    try std.testing.expectEqualStrings("{\"tag_name\":\"v1.1.0\",\"name\":\"v1.1.0\",\"body\":\"### Added\\n\\n- A step.\"}", seen[1].body);
    try std.testing.expectEqualStrings("/upload?name=p-program", seen[2].target);
    try std.testing.expectEqualStrings(program, seen[2].body);
    try std.testing.expectEqualStrings("/upload?name=SHA256SUMS", seen[3].target);
    try std.testing.expectEqualStrings(sums, seen[3].body);

    // Released with no token: tagged and pushed, its GitHub Release left for a later run.
    try w.change("p", "### Fixed\n\n- A bug.\n");
    const later = try w.read("p", "lib.zig");
    const tokenless = try fake.release(&w, "p", "", &.{});
    try std.testing.expect(succeeded(tokenless));
    try std.testing.expect(contains(tokenless.stderr, "v1.1.1 has no GitHub Release: GITHUB_TOKEN is not set"));
    try std.testing.expectEqual(0, fake.seen.items.len);
    try std.testing.expectEqualStrings(try w.head("p"), try w.remoteAt("p", "refs/tags/v1.1.1"));
    // Run again at the tag with one, it finishes the release a run that stopped part way left:
    // only the file GitHub does not hold yet is uploaded.
    std.crypto.hash.sha2.Sha256.hash(later, &digest, .{});
    const held = try a.print("{{\"id\":8,\"upload_url\":\"{s}/upload{{?name,label}}\",\"html_url\":\"https://github.com/o/p/releases/tag/v1.1.1\",\"assets\":[{{\"name\":\"p-program\"}}]}}", .{try fake.url(a)});
    const finished = try fake.release(&w, "p", "t", &.{
        .{ .status = .ok, .body = held },
        .{ .status = .created, .body = "{}" },
    });
    try std.testing.expect(succeeded(finished));
    try std.testing.expect(contains(finished.stderr, "nothing to release"));
    try std.testing.expectEqual(2, fake.seen.items.len);
    try std.testing.expectEqualStrings("/repos/o/p/releases/tags/v1.1.1", fake.seen.items[0].target);
    try std.testing.expectEqualStrings("/upload?name=SHA256SUMS", fake.seen.items[1].target);
    try std.testing.expectEqualStrings(try a.print("{s}  p-program\n", .{&std.fmt.bytesToHex(digest, .lower)}), fake.seen.items[1].body);
}

/// A workflow as preflight generates one: dispatched with a tier, the release tier among them.
const hosted_workflow =
    \\name: CI
    \\on:
    \\  push:
    \\  workflow_dispatch:
    \\    inputs:
    \\      tier:
    \\        type: choice
    \\        options: [ci, release, fuzz]
    \\
;

test "a release whose workflow runs a release tier passes it on GitHub before its tag; a red run tags nothing and puts the branch back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: World = try .init(a);
    defer w.deinit();
    try w.package("h", "1.0.0", "");
    try w.f.tmp.dir.createDirPath(w.f.io, "h/.github/workflows");
    try w.f.write("h", ".github/workflows/ci.yml", hosted_workflow);
    try w.git("h", &.{ "add", "." });
    try w.git("h", &.{ "commit", "--quiet", "-m", "A workflow" });
    const home = try w.path("ssh-home");
    const bare = try std.fs.path.join(a, &.{ home, "o", "h.git" });
    try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", bare });
    try w.f.env.put("SSH_HOME", home);
    try w.f.env.put("BAY_POLL_SECONDS", "0");
    try w.git("h", &.{ "remote", "set-url", "origin", "git@github.com:o/h.git" });
    try w.git("h", &.{ "push", "--quiet", "--set-upstream", "origin", "main", "--tags" });
    var fake: FakeGitHub = try .init(w.f.io);
    defer fake.server.deinit(w.f.io);

    // With no login to dispatch it, refused before anything is made.
    try w.change("h", "### Added\n\n- A step.\n");
    const start = try w.head("h");
    const logged_out = try fake.release(&w, "h", "", &.{});
    try std.testing.expect(refused(logged_out));
    try std.testing.expect(contains(logged_out.stderr, "o/h's workflow runs a release tier, which a release passes on GitHub before its tag: log in with gh auth login, or set GITHUB_TOKEN"));
    try std.testing.expectEqualStrings(start, try w.head("h"));
    try std.testing.expectEqual(0, fake.seen.items.len);

    // Green: the commit on release/v1.1.0, the tier dispatched and read job by job, then main and
    // an annotated tag naming the run, pushed with the candidate's deletion; the release made.
    fake.head_from = try std.fs.path.join(a, &.{ bare, "refs", "heads", "release", "v1.1.0" });
    const runs = "{\"workflow_runs\":[{\"id\":4,\"head_sha\":\"0000\",\"status\":\"completed\",\"created_at\":\"2999-01-01T00:00:00Z\"},{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"queued\",\"created_at\":\"2999-01-01T00:00:00Z\",\"html_url\":\"https://github.com/o/h/actions/runs/5\"}]}";
    const page = "https://github.com/o/h/actions/runs/5";
    const green = try fake.release(&w, "h", "t", &.{
        .{ .status = .no_content, .body = "" },
        .{ .status = .ok, .body = "{\"workflow_runs\":[]}" },
        .{ .status = .ok, .body = runs },
        .{ .status = .ok, .body = "{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"in_progress\",\"html_url\":\"https://github.com/o/h/actions/runs/5\"}" },
        .{ .status = .ok, .body = "{\"jobs\":[{\"name\":\"linux\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"macos\",\"status\":\"in_progress\",\"conclusion\":null}]}" },
        .{ .status = .ok, .body = "{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"https://github.com/o/h/actions/runs/5\"}" },
        .{ .status = .ok, .body = "{\"jobs\":[{\"name\":\"linux\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"macos\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" },
        .{ .status = .not_found, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = .created, .body = "{\"id\":7,\"upload_url\":\"x\",\"html_url\":\"https://github.com/o/h/releases/tag/v1.1.0\"}" },
    });
    try std.testing.expect(succeeded(green));
    const commit = try w.head("h");
    const seen = fake.seen.items;
    try std.testing.expectEqual(9, seen.len);
    try std.testing.expectEqual(std.http.Method.POST, seen[0].method);
    try std.testing.expectEqualStrings("/repos/o/h/actions/workflows/ci.yml/dispatches", seen[0].target);
    try std.testing.expectEqualStrings("Bearer t", seen[0].authorization);
    try std.testing.expectEqualStrings("{\"ref\":\"release/v1.1.0\",\"inputs\":{\"tier\":\"release\"}}", seen[0].body);
    try std.testing.expectEqualStrings("/repos/o/h/actions/runs?branch=release%2Fv1.1.0&event=workflow_dispatch&per_page=20", seen[1].target);
    try std.testing.expectEqualStrings("/repos/o/h/actions/runs/5", seen[3].target);
    try std.testing.expectEqualStrings("/repos/o/h/actions/runs/5/jobs?per_page=100", seen[4].target);
    try std.testing.expect(contains(seen[8].body, try a.print("Gated by the release tier on GitHub: {s}", .{page})));
    try std.testing.expect(contains(green.stderr, try a.print("v1.1.0 at {s}: the release tier runs on GitHub, {s}", .{ commit[0..12], page })));
    try std.testing.expectEqual(1, std.mem.count(u8, green.stderr, "hosted: linux: success"));
    try std.testing.expectEqual(1, std.mem.count(u8, green.stderr, "hosted: macos: success"));
    try std.testing.expect(contains(green.stderr, try a.print("hosted: green, {s}", .{page})));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("h", "refs/heads/main"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("h", "refs/tags/v1.1.0"));
    try std.testing.expectEqualStrings("", try w.remoteAt("h", "refs/heads/release/v1.1.0"));
    try std.testing.expectEqualStrings(try a.print("v1.1.0\n\nGated-by: {s}", .{page}), try w.out("h", &.{ "for-each-ref", "--format=%(contents)", "refs/tags/v1.1.0" }));
    try std.testing.expectEqualStrings("", try w.gateRecord("h", "v1.1.0"));

    // Red: the candidate deleted, the branch back where it was, nothing on main or tagged, the
    // failing jobs named.
    fake.head_from = try std.fs.path.join(a, &.{ bare, "refs", "heads", "release", "v1.1.1" });
    try w.change("h", "### Fixed\n\n- A bug.\n");
    const before = try w.head("h");
    const red = try fake.release(&w, "h", "t", &.{
        .{ .status = .no_content, .body = "" },
        .{ .status = .ok, .body = try std.mem.replaceOwned(u8, a, runs, "runs/5", "runs/6") },
        .{ .status = .ok, .body = "{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"completed\",\"conclusion\":\"failure\",\"html_url\":\"https://github.com/o/h/actions/runs/6\"}" },
        .{ .status = .ok, .body = "{\"jobs\":[{\"name\":\"linux\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"windows\",\"status\":\"completed\",\"conclusion\":\"failure\"},{\"name\":\"freebsd\",\"status\":\"completed\",\"conclusion\":\"skipped\"}]}" },
    });
    try std.testing.expect(refused(red));
    try std.testing.expect(contains(red.stderr, "hosted: windows: failure"));
    try std.testing.expect(contains(red.stderr, "the release tier is failure on GitHub (windows): https://github.com/o/h/actions/runs/6; nothing was tagged or pushed to origin/main, release/v1.1.1 is deleted"));
    try std.testing.expectEqualStrings(before, try w.head("h"));
    try std.testing.expectEqualStrings("", try w.out("h", &.{ "status", "--porcelain" }));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("h", "refs/heads/main"));
    try std.testing.expectEqualStrings("", try w.remoteAt("h", "refs/tags/v1.1.1"));
    try std.testing.expectEqualStrings("", try w.remoteAt("h", "refs/heads/release/v1.1.1"));
    try std.testing.expectEqualStrings("", try w.gateRecord("h", "v1.1.1"));
}

test "a release tier whose jobs GitHub gave no runner runs them again, three times at most, then refuses naming them; a run a person cancelled is refused at once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: World = try .init(a);
    defer w.deinit();
    try w.package("h", "1.0.0", "");
    try w.f.tmp.dir.createDirPath(w.f.io, "h/.github/workflows");
    try w.f.write("h", ".github/workflows/ci.yml", hosted_workflow);
    try w.git("h", &.{ "add", "." });
    try w.git("h", &.{ "commit", "--quiet", "-m", "A workflow" });
    const home = try w.path("ssh-home");
    const bare = try std.fs.path.join(a, &.{ home, "o", "h.git" });
    try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", bare });
    try w.f.env.put("SSH_HOME", home);
    try w.f.env.put("BAY_POLL_SECONDS", "0");
    try w.git("h", &.{ "remote", "set-url", "origin", "git@github.com:o/h.git" });
    try w.git("h", &.{ "push", "--quiet", "--set-upstream", "origin", "main", "--tags" });
    var fake: FakeGitHub = try .init(w.f.io);
    defer fake.server.deinit(w.f.io);
    const runs = "{\"workflow_runs\":[{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"queued\",\"created_at\":\"2999-01-01T00:00:00Z\",\"html_url\":\"https://github.com/o/h/actions/runs/5\"}]}";
    const page = "https://github.com/o/h/actions/runs/5";
    // GitHub's shape for a job no hosted runner took: cancelled, no runner, no steps; the run a failure.
    const unacquired = "{\"jobs\":[{\"name\":\"linux\",\"status\":\"completed\",\"conclusion\":\"success\",\"runner_id\":3,\"steps\":[{\"name\":\"Set up job\"}]},{\"name\":\"macos\",\"status\":\"completed\",\"conclusion\":\"cancelled\",\"runner_id\":0,\"steps\":[]},{\"name\":\"profile\",\"status\":\"completed\",\"conclusion\":\"skipped\",\"runner_id\":0,\"steps\":[]}]}";
    const failed_at = "{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"completed\",\"conclusion\":\"failure\",\"run_attempt\":N,\"html_url\":\"https://github.com/o/h/actions/runs/5\"}";
    const rerun: FakeGitHub.Reply = .{ .status = .created, .body = "{}" };

    // Run again once, the new attempt read only once GitHub shows it, then green: tagged.
    fake.head_from = try std.fs.path.join(a, &.{ bare, "refs", "heads", "release", "v1.1.0" });
    try w.change("h", "### Added\n\n- A step.\n");
    const green = try fake.release(&w, "h", "t", &.{
        .{ .status = .no_content, .body = "" },
        .{ .status = .ok, .body = runs },
        .{ .status = .ok, .body = try std.mem.replaceOwned(u8, a, failed_at, "N", "1") },
        .{ .status = .ok, .body = unacquired },
        rerun,
        .{ .status = .ok, .body = try std.mem.replaceOwned(u8, a, failed_at, "N", "1") },
        .{ .status = .ok, .body = unacquired },
        .{ .status = .ok, .body = "{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"completed\",\"conclusion\":\"success\",\"run_attempt\":2,\"html_url\":\"https://github.com/o/h/actions/runs/5\"}" },
        .{ .status = .ok, .body = "{\"jobs\":[{\"name\":\"linux\",\"status\":\"completed\",\"conclusion\":\"success\",\"runner_id\":3,\"steps\":[{\"name\":\"Set up job\"}]},{\"name\":\"macos\",\"status\":\"completed\",\"conclusion\":\"success\",\"runner_id\":4,\"steps\":[{\"name\":\"Set up job\"}]},{\"name\":\"profile\",\"status\":\"completed\",\"conclusion\":\"success\",\"runner_id\":5,\"steps\":[{\"name\":\"Set up job\"}]}]}" },
        .{ .status = .not_found, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = .created, .body = "{\"id\":7,\"upload_url\":\"x\",\"html_url\":\"https://github.com/o/h/releases/tag/v1.1.0\"}" },
    });
    try std.testing.expect(succeeded(green));
    try std.testing.expectEqual(std.http.Method.POST, fake.seen.items[4].method);
    try std.testing.expectEqualStrings("/repos/o/h/actions/runs/5/rerun-failed-jobs", fake.seen.items[4].target);
    try std.testing.expect(contains(green.stderr, "hosted: GitHub gave macos no runner; re-running its jobs, 1 of 3"));
    try std.testing.expectEqual(1, std.mem.count(u8, green.stderr, "hosted: macos: cancelled"));
    try std.testing.expect(contains(green.stderr, "hosted: macos: success"));
    try std.testing.expect(contains(green.stderr, try a.print("hosted: green, {s}", .{page})));
    const commit = try w.head("h");
    try std.testing.expectEqualStrings(commit, try w.remoteAt("h", "refs/tags/v1.1.0"));

    // No runner three re-runs running: refused, the jobs GitHub never ran named, and no red claimed.
    fake.head_from = try std.fs.path.join(a, &.{ bare, "refs", "heads", "release", "v1.1.1" });
    try w.change("h", "### Fixed\n\n- A bug.\n");
    const before = try w.head("h");
    var replies: std.ArrayList(FakeGitHub.Reply) = .empty;
    try replies.appendSlice(a, &.{ .{ .status = .no_content, .body = "" }, .{ .status = .ok, .body = runs } });
    for ([_][]const u8{ "1", "2", "3", "4" }, 0..) |n, k| {
        try replies.append(a, .{ .status = .ok, .body = try std.mem.replaceOwned(u8, a, failed_at, "N", n) });
        try replies.append(a, .{ .status = .ok, .body = unacquired });
        if (k < 3) try replies.append(a, rerun);
    }
    const starved = try fake.release(&w, "h", "t", replies.items);
    try std.testing.expect(refused(starved));
    try std.testing.expectEqual(replies.items.len, fake.seen.items.len);
    try std.testing.expect(contains(starved.stderr, "re-running its jobs, 3 of 3"));
    try std.testing.expect(std.mem.find(u8, starved.stderr, "4 of 3") == null);
    try std.testing.expect(contains(starved.stderr, try a.print("GitHub gave macos no runner, re-run 3 times ({s}): they never ran, so the release tier neither passed nor failed; nothing was tagged or pushed to origin/main, release/v1.1.1 is deleted", .{page})));
    try std.testing.expectEqualStrings(before, try w.head("h"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("h", "refs/heads/main"));
    try std.testing.expectEqualStrings("", try w.remoteAt("h", "refs/tags/v1.1.1"));
    try std.testing.expectEqualStrings("", try w.remoteAt("h", "refs/heads/release/v1.1.1"));

    // A person cancelled it: the run ends "cancelled", and is refused as it stands, never run again.
    const cancelled = try fake.release(&w, "h", "t", &.{
        .{ .status = .no_content, .body = "" },
        .{ .status = .ok, .body = runs },
        .{ .status = .ok, .body = "{\"id\":5,\"head_sha\":\"{head}\",\"status\":\"completed\",\"conclusion\":\"cancelled\",\"run_attempt\":1,\"html_url\":\"https://github.com/o/h/actions/runs/5\"}" },
        .{ .status = .ok, .body = unacquired },
    });
    try std.testing.expect(refused(cancelled));
    try std.testing.expectEqual(4, fake.seen.items.len);
    try std.testing.expect(std.mem.find(u8, cancelled.stderr, "re-running") == null);
    try std.testing.expect(contains(cancelled.stderr, try a.print("the release tier is cancelled on GitHub (macos): {s}; nothing was tagged", .{page})));
}

test "bay audit releases names each tag since the first gated release that bay release did not make, and the ones before it once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: World = try .init(a);
    defer w.deinit();
    // v1.0.0, a plain tag from before the rule; v1.1.0 as bay release makes it; v1.2.0 pushed by
    // hand; v1.3.0 annotated with a run that went red and a GitHub Release made by hand.
    try w.package("h", "1.0.0", "");
    const home = try w.path("ssh-home");
    try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", try std.fs.path.join(a, &.{ home, "o", "h.git" }) });
    try w.f.env.put("SSH_HOME", home);
    try w.git("h", &.{ "remote", "set-url", "origin", "git@github.com:o/h.git" });
    const runs = "https://github.com/o/h/actions/runs/";
    var commits: [3][]const u8 = undefined;
    for ([_][]const u8{ "v1.1.0", "v1.2.0", "v1.3.0" }, [_]?[]const u8{ "5", null, "6" }, &commits) |tag, run, *commit| {
        try w.change("h", "### Fixed\n\n- A fix.\n");
        commit.* = try w.head("h");
        if (run) |id| {
            try w.git("h", &.{ "tag", "--annotate", tag, "--message", try a.print("{s}\n\nGated-by: {s}{s}", .{ tag, runs, id }) });
        } else try w.git("h", &.{ "tag", tag });
    }
    try w.git("h", &.{ "push", "--quiet", "--set-upstream", "origin", "main", "--tags" });
    // Audited from a clone that holds no tag: their messages are fetched, no ref made.
    try w.git(".", &.{ "clone", "--quiet", "--no-tags", "git@github.com:o/h.git", "fresh" });
    var fake: FakeGitHub = try .init(w.f.io);
    defer fake.server.deinit(w.f.io);
    const audited = try fake.bay(&w, "fresh", &.{ "audit", "releases" }, "t", &.{
        .{ .status = .ok, .body = try a.print("{{\"id\":5,\"head_sha\":\"{s}\",\"head_branch\":\"release/v1.1.0\",\"status\":\"completed\",\"conclusion\":\"success\"}}", .{commits[0]}) },
        .{ .status = .ok, .body = "{\"body\":\"### Fixed\\n\\n- A fix.\\n\\nGated by the release tier on GitHub: https://github.com/o/h/actions/runs/5\"}" },
        .{ .status = .not_found, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = .ok, .body = try a.print("{{\"id\":6,\"head_sha\":\"{s}\",\"head_branch\":\"main\",\"status\":\"completed\",\"conclusion\":\"failure\"}}", .{commits[1]}) },
        .{ .status = .ok, .body = "{\"body\":\"By hand.\"}" },
    });
    try std.testing.expect(refused(audited));
    const seen = fake.seen.items;
    try std.testing.expectEqual(5, seen.len);
    try std.testing.expectEqualStrings("/repos/o/h/actions/runs/5", seen[0].target);
    try std.testing.expectEqualStrings("/repos/o/h/releases/tags/v1.1.0", seen[1].target);
    try std.testing.expectEqualStrings("/repos/o/h/releases/tags/v1.2.0", seen[2].target);
    try std.testing.expectEqualStrings("/repos/o/h/actions/runs/6", seen[3].target);
    try std.testing.expectEqualStrings("/repos/o/h/releases/tags/v1.3.0", seen[4].target);
    const said = audited.stdout;
    try std.testing.expect(contains(said, "history: v1.0.0 came before the first release gated on GitHub, v1.1.0\n"));
    try std.testing.expect(std.mem.find(u8, said, "v1.1.0:") == null);
    try std.testing.expect(contains(said, "v1.2.0: a lightweight tag, which names no run; no GitHub Release\n"));
    try std.testing.expect(contains(said, try a.print("v1.3.0: its run {s}6 ended failure, not green; its run {s}6 ran on {s}, not on the tagged {s}; its run {s}6 ran on main, not on release/v1.3.0; a GitHub Release whose notes name no Gated-by run, which bay release did not make\n", .{ runs, runs, commits[1][0..12], commits[2][0..12], runs })));
    try std.testing.expect(contains(said, "o/h: 2 of 3 releases since are not as bay release makes them\n"));
    try std.testing.expectEqualStrings("", try w.out("fresh", &.{ "tag", "--list" }));

    // A repository whose tags all came before the rule passes, with nothing asked of GitHub.
    try w.package("old", "0.1.0", "");
    try w.git(".", &.{ "init", "--quiet", "--bare", "--initial-branch=main", try std.fs.path.join(a, &.{ home, "o", "old.git" }) });
    try w.git("old", &.{ "remote", "set-url", "origin", "git@github.com:o/old.git" });
    try w.git("old", &.{ "push", "--quiet", "origin", "main", "--tags" });
    const before = try fake.bay(&w, "old", &.{ "audit", "releases" }, "t", &.{});
    try std.testing.expect(succeeded(before));
    try std.testing.expect(contains(before.stdout, "o/old: no release gated on GitHub yet, so its 1 release tag is history\n"));
    try std.testing.expectEqual(0, fake.seen.items.len);
    // A remote off github.com is refused: the audit reads what GitHub holds for its tags.
    try w.package("elsewhere", "0.1.0", "");
    const off = try w.f.bay("elsewhere", &.{ "audit", "releases" });
    try std.testing.expect(refused(off));
    try std.testing.expect(contains(off.stderr, "no repository on github.com"));
}

test "bay pin moves a package onto a dependency's release: pushed with no tag alone, released with the entries before it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("dep", "0.1.0", "");
    try w.package("lib", "0.1.0", "");
    try std.testing.expect(succeeded(try w.f.bay("lib", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("dep")}) })));
    try w.git("lib", &.{ "add", "." });
    try w.git("lib", &.{ "commit", "--quiet", "-m", "Pin" });
    try w.git("lib", &.{ "push", "--quiet", "origin", "main" });
    for ([_][]const u8{ "0.1.1", "0.1.2" }) |_| {
        try w.change("dep", "### Fixed\n\n- A fix.\n");
        try std.testing.expect(succeeded(try w.releaseIn("dep", &.{})));
    }
    const start = try w.head("lib");
    // Refused before anything is written: a name it does not pin, no version, a version with no tag.
    for ([_]struct { []const []const u8, []const u8 }{
        .{ &.{ "pin", "nope", "0.1.1" }, "nope is not a dependency of lib" },
        .{ &.{ "pin", "dep", "one" }, "one is no version" },
        .{ &.{ "pin", "dep", "0.9.0" }, "bay add failed in " },
    }) |case| {
        const args, const said = case;
        const off = try w.f.bay("lib", args);
        try std.testing.expect(refused(off));
        try std.testing.expect(contains(off.stderr, said));
        try std.testing.expectEqualStrings(start, try w.head("lib"));
        try std.testing.expectEqualStrings("", try w.out("lib", &.{ "status", "--porcelain" }));
    }
    // A re-pin alone: named, committed, gated, pushed with no tag.
    const dry = try w.f.bay("lib", &.{ "pin", "--dry-run", "dep", "v0.1.1" });
    try std.testing.expect(succeeded(dry));
    try std.testing.expect(contains(dry.stdout, "pin dep at v0.1.1 and tidy; name the re-pin under ### Changed and commit it; then gate it and push it with no tag"));
    try std.testing.expectEqualStrings(start, try w.head("lib"));
    const alone = try w.f.bay("lib", &.{ "pin", "dep", "0.1.1" });
    try std.testing.expect(succeeded(alone));
    const pinned = try w.head("lib");
    try std.testing.expectEqualStrings("Pin dep 0.1.1", try w.out("lib", &.{ "log", "-1", "--format=%s" }));
    try std.testing.expect(contains(try w.read("lib", "build.zig.zon"), "?ref=v0.1.1#"));
    try std.testing.expect(contains(try w.read("lib", "CHANGELOG.md"), "## [Unreleased]\n\n### Changed\n\n- Pins dep 0.1.1.\n"));
    try std.testing.expectEqual(1, try w.gated(pinned));
    try std.testing.expectEqualStrings(pinned, try w.remoteAt("lib", "refs/heads/main"));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));
    // Pinned there already: nothing moves.
    const again = try w.f.bay("lib", &.{ "pin", "dep", "0.1.1" });
    try std.testing.expect(succeeded(again));
    try std.testing.expect(contains(again.stderr, "dep is pinned at v0.1.1 already: nothing moved"));
    try std.testing.expectEqualStrings(pinned, try w.head("lib"));
    // With entries of its own waiting, the re-pin is released with them.
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const released = try w.f.bay("lib", &.{ "pin", "dep", "0.1.2" });
    try std.testing.expect(succeeded(released));
    const commit = try w.head("lib");
    try std.testing.expectEqualStrings("Release v0.1.1", try w.out("lib", &.{ "log", "-1", "--format=%s" }));
    try std.testing.expectEqualStrings("Pin dep 0.1.2", try w.out("lib", &.{ "log", "-1", "--format=%s", "HEAD^" }));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/tags/v0.1.1"));
    const log = try w.read("lib", "CHANGELOG.md");
    try std.testing.expect(contains(log, "- Pins dep 0.1.2.\n"));
    try std.testing.expect(contains(log, "### Fixed\n\n- A fix.\n"));
}

/// A tool's build as preflight's is: the package's gate, and `addGenerate`, which a member
/// developed with it calls from its development build, running the tool's own generator over
/// the member's config, as preflight's `generate` reads ci/preflight.json.
const tool_build = gate_build ++
    \\pub fn addGenerate(b: *std.Build, package: *std.Build) void {
    \\    const own = b.dependencyFromBuildZig(@This(), .{}).builder;
    \\    const exe = b.addExecutable(.{ .name = "generate", .root_module = b.createModule(.{ .root_source_file = own.path("generate.zig"), .target = b.graph.host }) });
    \\    const run = b.addRunArtifact(exe);
    \\    run.setCwd(package.path("."));
    \\    run.has_side_effects = true;
    \\    b.step("generate", "Make what follows from the pins").dependOn(&run.step);
    \\}
    \\
;

/// The tool's generator, refusing every key of ci/preflight.json it does not know.
fn toolGenerator(a: std.mem.Allocator, known: []const u8) ![]const u8 {
    return a.print(
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {{
        \\    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, "ci/preflight.json", init.arena.allocator(), .limited(1 << 16));
        \\    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, init.arena.allocator(), text, .{{}});
        \\    for (parsed.object.keys()) |key| {{
        \\        for ([_][]const u8{{ {s} }}) |name| {{
        \\            if (std.mem.eql(u8, key, name)) break;
        \\        }} else {{
        \\            std.debug.print("generate: unknown key \"{{s}}\" in ci/preflight.json\n", .{{key}});
        \\            std.process.exit(1);
        \\        }}
        \\    }}
        \\}}
        \\
    , .{known});
}

test "a train's dry run runs each closing re-pin's generate against the trees being released, and refuses with what it says" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    // tool ships rider; rider develops with tool, as preflight ships aegis and aegis develops
    // with preflight: that pin closes a ring, so rider goes first and re-pins tool's release
    // in the closing pass.
    try w.package("rider", "0.1.0", "");
    try w.package("tool", "0.1.0", "");
    for ([_][]const u8{ "rider", "tool" }) |dir| try familyPolicy(&w, dir, "family");
    // The tool's generator at the release rider develops with knows "compile_once".
    try w.f.write("tool", "build.zig", tool_build);
    try w.f.write("tool", "generate.zig", try toolGenerator(w.f.a, "\"policy\", \"glint\", \"compile_once\""));
    try w.git("tool", &.{ "add", "." });
    try w.git("tool", &.{ "commit", "--quiet", "-m", "Generate" });
    // Its release, v0.1.0, is that commit: the fixture's first tag moves to it.
    try w.git("tool", &.{ "tag", "--force", "v0.1.0" });
    try w.git("tool", &.{ "push", "--quiet", "--force", "origin", "main", "v0.1.0" });
    try std.testing.expect(succeeded(try w.f.bay("tool", &.{ "add", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("rider")}) })));
    try w.git("tool", &.{ "add", "." });
    try w.git("tool", &.{ "commit", "--quiet", "-m", "Pin rider" });
    try w.git("tool", &.{ "push", "--quiet", "origin", "main" });
    // rider's development build generates through the tool, its config carrying the key.
    try w.f.write("rider", "build.zig",
        \\const std = @import("std");
        \\pub fn dev(b: *std.Build, tools: type) void {
        \\    tools.tool.addGenerate(b, b.dependency("rider", .{}).builder);
        \\}
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "gate", .root_module = b.createModule(.{ .root_source_file = b.path("gate.zig"), .target = b.graph.host }) });
        \\    const run = b.addRunArtifact(exe);
        \\    run.setCwd(b.path("."));
        \\    run.has_side_effects = true;
        \\    b.step("gate", "Gate the package").dependOn(&run.step);
        \\}
        \\
    );
    try w.f.write("rider", "ci/preflight.json", "{\n  \"policy\": \"family\",\n  \"glint\": {},\n  \"compile_once\": true\n}\n");
    try std.testing.expect(succeeded(try w.f.bay("rider", &.{ "add", "--dev", try w.f.a.print("{s}#v0.1.0", .{try w.pinUrl("tool")}) })));
    try w.git("rider", &.{ "add", "." });
    try w.git("rider", &.{ "commit", "--quiet", "-m", "Develop with tool" });
    try w.git("rider", &.{ "push", "--quiet", "origin", "main" });
    // The tool's tree, which its next release is made from, no longer knows the key.
    try w.f.write("tool", "generate.zig", try toolGenerator(w.f.a, "\"policy\", \"glint\""));
    try w.git("tool", &.{ "add", "." });
    try w.git("tool", &.{ "commit", "--quiet", "-m", "Refuse compile_once" });
    try w.git("tool", &.{ "push", "--quiet", "origin", "main" });
    try w.f.write(".", "bay.work", ".{ .members = .{ \"tool\", \"rider\" } }\n");
    try w.change("rider", "### Fixed\n\n- A fix.\n");
    const heads = [_][]const u8{ try w.head("rider"), try w.head("tool") };

    // rider's own turn generates with the tool at its pin, and passes; the closing pass, with
    // the tool's tree, is refused before anything moves, with the generator's own words.
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    try std.testing.expect(refused(plan));
    try std.testing.expect(contains(plan.stdout, "then rider develops with tool 0.1.1, gated and pushed with no tag\n"));
    try std.testing.expect(contains(plan.stderr, "generate: unknown key \"compile_once\" in ci/preflight.json"));
    try std.testing.expect(contains(plan.stderr, "rider: its closing re-pin would stop the train there, once the releases before it are tagged and pushed"));
    for ([_][]const u8{ "rider", "tool" }, heads) |dir, head| {
        try std.testing.expectEqualStrings(head, try w.head(dir));
        try std.testing.expectEqualStrings("", try w.out(dir, &.{ "status", "--porcelain" }));
    }

    // Without the key, the plan passes, the closing pass's generate among it.
    try familyPolicy(&w, "rider", "family");
    const clean = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    if (!succeeded(clean)) std.debug.print("{s}\n{s}\n", .{ clean.stdout, clean.stderr });
    try std.testing.expect(succeeded(clean));
}

test "a train's dry run refuses a member not on its remote's default branch, as its run does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try familyPolicy(&w, "lib", "family");
    try w.f.write(".", "bay.work", ".{ .members = .{ \"lib\" } }\n");
    // A clone on a line of its own: the run refuses it at its turn, so the plan does too.
    try w.git("lib", &.{ "checkout", "--quiet", "-b", "line" });
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const start = try w.head("lib");
    const remote_main = try w.remoteAt("lib", "refs/heads/main");
    for ([_][]const []const u8{ &.{ "--workspace", "release", "--dry-run" }, &.{ "--workspace", "release" } }) |args| {
        const off = try w.f.bay(".", args);
        try std.testing.expect(refused(off));
        try std.testing.expect(contains(off.stderr, "line would go to origin/line, and a release goes only to origin's default branch, main"));
        try std.testing.expectEqualStrings(start, try w.head("lib"));
        try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));
        try std.testing.expectEqualStrings(remote_main, try w.remoteAt("lib", "refs/heads/main"));
    }
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    try std.testing.expect(contains(plan.stderr, "lib: the train would stop at it before anything of it moves"));
    // On the default branch, the plan passes.
    try w.git("lib", &.{ "checkout", "--quiet", "main" });
    try w.git("lib", &.{ "merge", "--quiet", "--ff-only", "line" });
    const clean = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    if (!succeeded(clean)) std.debug.print("{s}\n{s}\n", .{ clean.stdout, clean.stderr });
    try std.testing.expect(succeeded(clean));
    try std.testing.expect(contains(clean.stdout, "1. lib 0.1.0 -> 0.1.1 (fix): its [Unreleased] section\n"));
}

test "a dry run makes the release commit in a copy at its version and configures it, refusing one that does not configure there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    // A build that refuses a manifest whose version differs from a file of its own: the
    // release sets the manifest's alone, so its commit does not configure.
    try w.f.write("lib", "version.zig", "pub const version = \"0.1.0\";\n");
    try w.f.write("lib", "build.zig", gate_build ++
        \\comptime {
        \\    const zon = @import("build.zig.zon").version;
        \\    const own = @import("version.zig").version;
        \\    if (!std.mem.eql(u8, zon, own)) @compileError("version.zig names " ++ own ++ "; build.zig.zon names " ++ zon);
        \\}
        \\
    );
    try w.git("lib", &.{ "add", "." });
    try w.git("lib", &.{ "commit", "--quiet", "-m", "A version of its own" });
    try w.git("lib", &.{ "push", "--quiet", "origin", "main" });
    try familyPolicy(&w, "lib", "family");
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const start = try w.head("lib");
    const candidate = try std.fs.path.join(w.f.a, &.{ "lib", ".zig-cache", "bay", "release-candidate" });

    // Alone, and as a train's car: refused in the plan, before any commit, with Zig's words.
    const alone = try w.releaseIn("lib", &.{"--dry-run"});
    try std.testing.expect(refused(alone));
    try std.testing.expect(contains(alone.stderr, "version.zig names 0.1.0; build.zig.zon names 0.1.1"));
    try std.testing.expect(contains(alone.stderr, "the release commit, at 0.1.1, does not configure, so its gate would be red"));
    try w.f.write(".", "bay.work", ".{ .members = .{ \"lib\" } }\n");
    const plan = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    try std.testing.expect(refused(plan));
    try std.testing.expect(contains(plan.stderr, "version.zig names 0.1.0; build.zig.zon names 0.1.1"));
    try std.testing.expect(contains(plan.stderr, "lib: its release commit, at 0.1.1, does not configure, so the train would stop at its gate"));
    try std.testing.expectEqualStrings(start, try w.head("lib"));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "status", "--porcelain" }));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));

    // A build that reads the manifest's version alone configures at any: the plan passes, and
    // the copy goes. Its `generate` asks git where it stands, as preflight's does, and is
    // refused anywhere but at its repository's top: each copy is a repository of its own.
    const generate_line = "    b.step(\"generate\", \"Make what follows from the pins\").dependOn(&generated.step);\n";
    try w.f.write("lib", "build.zig", try std.mem.replaceOwned(u8, w.f.a, gate_build, generate_line,
        \\    const where = b.addSystemCommand(&.{ "git", "rev-parse", "--show-prefix" });
        \\    where.setCwd(b.path("."));
        \\    where.has_side_effects = true;
        \\    where.expectStdOutEqual("\n");
        \\    generated.step.dependOn(&where.step);
        \\
    ++ generate_line));
    try w.git("lib", &.{ "rm", "--quiet", "version.zig" });
    try w.git("lib", &.{ "add", "." });
    try w.git("lib", &.{ "commit", "--quiet", "-m", "The manifest's version alone" });
    const clean = try w.f.bay(".", &.{ "--workspace", "release", "--dry-run" });
    if (!succeeded(clean)) std.debug.print("{s}\n{s}\n", .{ clean.stdout, clean.stderr });
    try std.testing.expect(succeeded(clean));
    try std.testing.expect(contains(clean.stderr, "its release commit, at 0.1.1, configures (made in a copy)"));
    try std.testing.expectError(error.FileNotFound, w.f.tmp.dir.access(w.f.io, candidate, .{}));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "status", "--porcelain" }));
}

test "a dry run's tidy resolves the package itself in its copy, with tidy's pins: a member pinned at an older release builds once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: World = try .init(a);
    defer w.deinit();
    // shuttle's shape: shuttle pinned aegis 0.2.4, aegis is a member at its release 0.5.0, and
    // shuttle develops with shakedown, which depends on shuttle. Here lib pins core 0.1.0, core
    // is a member at its release 0.1.1, and lib develops with tool, which depends on lib: tool's
    // lib is the package itself, and its core the member's tree.
    const loads = struct {
        fn one(comptime name: []const u8) []const u8 {
            return "pub fn build(b: *std.Build) void {\n    _ = b.dependency(\"" ++ name ++ "\", .{});\n";
        }
    };
    // No build has a `generate` step, as shuttle's package build has none: the dry run
    // configures both builds, the development build among them.
    const no_generate = try std.mem.replaceOwned(u8, a, gate_build, "    b.step(\"generate\", \"Make what follows from the pins\").dependOn(&generated.step);\n", "");
    try w.package("core", "0.1.0", "");
    // Its next release, a commit of its own at 0.1.1: another hash than 0.1.0's.
    try w.f.write("core", "build.zig.zon", try std.mem.replaceOwned(u8, a, try w.read("core", "build.zig.zon"), "\"0.1.0\"", "\"0.1.1\""));
    try w.git("core", &.{ "commit", "--quiet", "-am", "0.1.1" });
    try w.git("core", &.{ "push", "--quiet", "origin", "main" });
    try w.git("core", &.{ "tag", "v0.1.1" });
    try w.git("core", &.{ "push", "--quiet", "origin", "v0.1.1" });
    // lib 0.1.0 pins core 0.1.0, and tool 0.1.0 depends on lib 0.1.0.
    for ([_][]const u8{ "lib", "tool" }, [_][]const u8{ "core", "lib" }, [_][]const u8{ loads.one("core"), loads.one("lib") }) |dir, on, header| {
        try w.package(dir, "0.1.0", "");
        try std.testing.expect(succeeded(try w.f.bay(dir, &.{ "add", try a.print("{s}#v0.1.0", .{try w.pinUrl(on)}) })));
        try w.f.write(dir, "build.zig", try std.mem.replaceOwned(u8, a, no_generate, "pub fn build(b: *std.Build) void {\n", header));
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", try a.print("Depend on {s}", .{on}) });
        try w.git(dir, &.{ "push", "--quiet", "origin", "main" });
        try w.git(dir, &.{ "tag", "--force", "v0.1.0" });
        try w.git(dir, &.{ "push", "--quiet", "--force", "origin", "v0.1.0" });
    }
    try std.testing.expect(succeeded(try w.f.bay("lib", &.{ "add", "--dev", try a.print("{s}#v0.1.0", .{try w.pinUrl("tool")}) })));
    try w.f.write("lib", "build.zig", try std.mem.replaceOwned(u8, a, try w.read("lib", "build.zig"), "pub fn dev(b: *std.Build, _: type) void {\n", "pub fn dev(b: *std.Build, _: type) void {\n    _ = b.dependency(\"tool\", .{});\n"));
    try w.git("lib", &.{ "add", "." });
    try w.git("lib", &.{ "commit", "--quiet", "-m", "Develop with tool" });
    try w.git("lib", &.{ "push", "--quiet", "origin", "main" });
    try w.f.write(".", "bay.work", ".{ .members = .{ \"core\", \"lib\" } }\n");
    const head = try w.head("lib");

    const plan = try w.f.bay("lib", &.{ "tidy", "--dry-run" });
    if (!succeeded(plan)) std.debug.print("{s}\n{s}\n", .{ plan.stdout, plan.stderr });
    try std.testing.expect(succeeded(plan));
    try std.testing.expect(contains(plan.stderr, "core would be pinned at its release"));
    try std.testing.expect(std.mem.find(u8, plan.stderr, "file exists in modules") == null);
    try std.testing.expectEqualStrings(head, try w.head("lib"));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "status", "--porcelain" }));
}
