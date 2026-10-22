//! `bay release` end to end, on scratch repositories whose remotes are reached
//! over git's SSH transport (the tests' stand-in for ssh runs the command
//! here): the release cut, gated and pushed with its tag at once; every
//! refusal, each leaving the branch and the remote as they were; a red gate;
//! two branches adding lines under one group rebased with no conflict; a
//! release interrupted after its commit and after its push, finished or
//! refused, never a tag on a commit no gate passed; a machine gating beside
//! this one; and a workspace's train of three members in order.
const std = @import("std");
const Io = std.Io;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const refused = fixture.refused;
const succeeded = fixture.succeeded;

/// The package's gate: it records the commit it gated (a file named for it under
/// GATE_LOG) and fails when the package holds a file `red`.
const gate_program =
    \\const std = @import("std");
    \\pub fn main(init: std.process.Init) !void {
    \\    const io = init.io;
    \\    const a = init.arena.allocator();
    \\    const head = try std.process.run(a, io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .environ_map = init.environ_map });
    \\    const sha = std.mem.trim(u8, head.stdout, " \r\n");
    \\    const log = init.environ_map.get("GATE_LOG") orelse return error.NoGateLog;
    \\    const now = std.Io.Clock.real.now(io).toNanoseconds();
    \\    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}-{d}", .{ log, sha, now }), .data = "" });
    \\    if (std.Io.Dir.cwd().access(io, "red", .{})) |_| return error.Red else |_| {}
    \\}
    \\
;

const gate_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "gate", .root_module = b.createModule(.{ .root_source_file = b.path("gate.zig"), .target = b.graph.host }) });
    \\    const run = b.addRunArtifact(exe);
    \\    run.setCwd(b.path("."));
    \\    run.has_side_effects = true;
    \\    b.step("gate", "Gate the package").dependOn(&run.step);
    \\}
    \\
;

const World = struct {
    f: Fixture,

    fn init(a: std.mem.Allocator) !World {
        var w: World = .{ .f = try .init(a) };
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
        const f = &w.f;
        try f.tmp.dir.createDirPath(f.io, dir);
        try f.write(dir, "build.zig.zon", try f.a.print(".{{\n    .name = .{s},\n    .version = \"{s}\",\n    .fingerprint = 0x{x},\n    .minimum_zig_version = \"0.17.0\",\n    .paths = .{{\"\"}},\n    .dependencies = .{{{s}}},\n}}\n", .{ dir, version, fixture.fingerprint(dir), dependencies }));
        try f.write(dir, "build.zig", gate_build);
        try f.write(dir, "gate.zig", gate_program);
        try f.write(dir, ".gitignore", ".zig-cache/\nzig-out/\nzig-pkg/\n");
        try f.write(dir, ".gitattributes", "CHANGELOG.md merge=union\n");
        try f.write(dir, "CHANGELOG.md", try f.a.print("# Changelog\n\n## [Unreleased]\n\n## [{s}] - 2026-01-01\n\n### Added\n\n- First.\n", .{version}));
        try w.git(dir, &.{ "init", "--quiet", "--initial-branch=main" });
        try w.git(dir, &.{ "add", "." });
        try w.git(dir, &.{ "commit", "--quiet", "-m", "First" });
        try w.git(dir, &.{ "tag", try f.a.print("v{s}", .{version}) });
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

    /// What the remote of `dir` holds at `ref`, or "" for nothing.
    fn remoteAt(w: *World, dir: []const u8, ref: []const u8) ![]const u8 {
        const listing = try w.out(dir, &.{ "ls-remote", "origin", ref });
        return if (std.mem.findScalar(u8, listing, '\t')) |tab| listing[0..tab] else "";
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
    const before = try w.head("lib");
    try std.testing.expect(succeeded(try w.releaseIn("lib", &.{})));
    const commit = try w.head("lib");
    try std.testing.expect(!std.mem.eql(u8, before, commit));
    try std.testing.expectEqualStrings(before, try w.out("lib", &.{ "rev-parse", "HEAD^" }));
    try std.testing.expectEqualStrings("Release v0.1.1", try w.out("lib", &.{ "log", "-1", "--format=%s" }));
    try std.testing.expect(contains(try w.read("lib", "build.zig.zon"), ".version = \"0.1.1\""));
    try std.testing.expect(contains(try w.read("lib", "CHANGELOG.md"), try w.f.a.print("## [Unreleased]\n\n## [0.1.1] - {s}\n\n### Fixed\n\n- A fix.\n\n## [0.1.0]", .{try today(w.f.a)})));
    // The gate saw that commit, once; the remote holds it as main and as the tag, and so does the clone.
    try std.testing.expectEqual(1, try w.gated(commit));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/heads/main"));
    try std.testing.expectEqualStrings(commit, try w.remoteAt("lib", "refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings(commit, try w.out("lib", &.{ "rev-parse", "v0.1.1^{commit}" }));
    try std.testing.expectEqualStrings("", try w.out("lib", &.{ "for-each-ref", "refs/bay" }));
    // Released, it has nothing more to release.
    const again = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(again));
    try std.testing.expect(contains(again.stderr, "nothing to release"));
    try std.testing.expectEqualStrings(commit, try w.head("lib"));
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
    // HEAD detached, and a branch with no upstream.
    try w.git("lib", &.{ "checkout", "--quiet", "--detach" });
    try Expect.refusal(&w, "HEAD is detached", start, remote_main);
    try w.git("lib", &.{ "checkout", "--quiet", "-b", "loose" });
    try Expect.refusal(&w, "loose has no upstream", start, remote_main);
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
    try std.testing.expectEqualStrings(commit, try w.out("lib", &.{ "rev-parse", "refs/bay/gated/v0.1.1" }));
    try std.testing.expectEqualStrings("v0.1.0", try w.out("lib", &.{ "tag", "--list" }));
    try std.testing.expectEqualStrings("", try w.remoteAt("lib", "refs/tags/v0.1.1"));
    // A run stopped before its gate ended has no record: the next run gates the commit again.
    try w.git("lib", &.{ "update-ref", "-d", "refs/bay/gated/v0.1.1" });
    try w.f.tmp.dir.deleteFile(w.f.io, hook);
    const resumed = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(resumed));
    try std.testing.expect(contains(resumed.stderr, "v0.1.1 is under way"));
    try std.testing.expectEqual(2, try w.gated(commit));
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
    try std.testing.expectEqualStrings(third, try w.out("lib", &.{ "rev-parse", "refs/bay/gated/v0.1.3" }));
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

/// The remote of `lib` refuses every push while its pre-receive hook is there.
fn refusePushes(w: *World, hook: []const u8) !void {
    try w.f.write(".", hook, "#!/bin/sh\nexit 1\n");
    const file = try w.f.tmp.dir.openFile(w.f.io, hook, .{});
    defer file.close(w.f.io);
    try file.setPermissions(w.f.io, .executable_file);
}

test "a machine gates the release beside this one, and its red stops it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: World = try .init(arena.allocator());
    defer w.deinit();
    try w.package("lib", "0.1.0", "");
    try w.f.tmp.dir.createDirPath(w.f.io, "config/bay");
    const machine = try std.mem.replaceOwned(u8, w.f.a, try w.path("machine"), "\\", "/");
    try w.f.write("config/bay", "machines.zon", try w.f.a.print(".{{ .{{ .name = \"elsewhere\", .bay = .{{\"{s}\"}}, .directory = \"{s}\" }} }}\n", .{ try std.mem.replaceOwned(u8, w.f.a, w.f.bay_path, "\\", "\\\\"), machine }));
    try w.change("lib", "### Fixed\n\n- A fix.\n");
    const result = try w.releaseIn("lib", &.{});
    try std.testing.expect(succeeded(result));
    const commit = try w.head("lib");
    // Gated here and there, the machine's lines named.
    try std.testing.expectEqual(2, try w.gated(commit));
    try std.testing.expect(contains(result.stderr, "elsewhere: bay: gating"));
    try std.testing.expect(contains(result.stderr, "gate on elsewhere: green"));
    try std.testing.expectEqualStrings(commit, try w.out("machine/lib", &.{ "rev-parse", "HEAD" }));
    // A machine whose gate is red: nothing is tagged.
    try w.f.write("config/bay", "machines.zon", ".{ .{ .name = \"broken\", .bay = .{ \"git\", \"no-such-command\" }, .directory = \"/nowhere\" } }\n");
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
        try w.git(dir, &.{ "commit", "--quiet", "-am", "Pin" });
        try w.git(dir, &.{ "push", "--quiet", "origin", "main" });
    }
    try w.f.write(".", "bay.work", ".{ .members = .{ \"c\", \"b\", \"a\" } }\n");
    try w.change("a", "### Fixed\n\n- A fix.\n");
    const train = try w.f.bay(".", &.{ "--workspace", "release" });
    try std.testing.expect(succeeded(train));
    // In order: a, then b pinning it, then c pinning b; each released and pushed with its tag.
    const said = train.stderr;
    try std.testing.expect(std.mem.find(u8, said, "released a v0.1.1").? < std.mem.find(u8, said, "released b v0.1.1").?);
    try std.testing.expect(std.mem.find(u8, said, "released b v0.1.1").? < std.mem.find(u8, said, "released c v0.1.1").?);
    for ([_][]const u8{ "a", "b", "c" }) |dir| try std.testing.expectEqualStrings(try w.head(dir), try w.remoteAt(dir, "refs/tags/v0.1.1"));
    for ([_][]const u8{ "b", "c" }, [_][]const u8{ "a", "b" }) |dir, dependency| {
        try std.testing.expect(contains(try w.read(dir, "build.zig.zon"), "?ref=v0.1.1#"));
        try std.testing.expect(contains(try w.read(dir, "CHANGELOG.md"), try w.f.a.print("## [0.1.1] - {s}\n\n### Changed\n\n- Pins {s} 0.1.1.\n", .{ try today(w.f.a), dependency })));
        try std.testing.expectEqualStrings("Release v0.1.1", try w.out(dir, &.{ "log", "-1", "--format=%s" }));
        try std.testing.expectEqualStrings(try w.f.a.print("Pin {s} 0.1.1", .{dependency}), try w.out(dir, &.{ "log", "-1", "--format=%s", "HEAD^" }));
    }
}
