//! `bay release`: the one way a package releases. The version is the one its
//! CHANGELOG's `[Unreleased]` section makes; the section becomes the release,
//! the manifest takes the version, and both are committed as `Release vX.Y.Z`.
//! That exact commit is gated, here and on each of the person's machines, by
//! the package's own `gate` step (preflight's, at the version the package
//! pins); only then do the branch and the tag go to the remote, in one atomic
//! push over SSH, read back before the tag is made here.
//!
//! git is the record of a release under way: a red gate puts the branch back
//! where it was; a run that stops leaves its release commit at HEAD, which the
//! next run gates and pushes; `refs/bay/gated/vX.Y.Z` names a commit gated
//! green whose push did not go, so the next run pushes it without gating it
//! again. No tag is ever made on a commit no gate passed.
const std = @import("std");
const Io = std.Io;
const changelog = @import("changelog.zig");
const manifest = @import("manifest.zig");
const machines = @import("machines.zig");
const say = @import("say.zig");
const workspace = @import("workspace.zig");
const each = @import("each.zig");

pub const Context = struct {
    io: Io,
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    /// The package's directory.
    package: []const u8,
};

pub const Options = struct {
    /// Print the version, the section and the plan; change nothing.
    dry_run: bool = false,
    /// With an empty section and commits the remote has not (a train's development
    /// pins), gate them and push the branch with no tag.
    push_unreleased: bool = false,
};

pub const Outcome = union(enum) {
    /// Nothing to release, and nothing pushed.
    nothing,
    /// The branch pushed with no release.
    pushed,
    released: std.SemanticVersion,
};

/// A git command's outcome, its output trimmed.
const Ran = struct { ok: bool, out: []const u8, err: []const u8 };

fn git(c: Context, args: []const []const u8) !Ran {
    const argv = try std.mem.concat(c.a, []const u8, &.{ &.{"git"}, args });
    const result = std.process.run(c.a, c.io, .{ .argv = argv, .cwd = .{ .path = c.package }, .environ_map = c.environ }) catch |err|
        try say.fail(c.io, "could not run git: {t}", .{err});
    return .{
        .ok = result.term == .exited and result.term.exited == 0,
        .out = std.mem.trim(u8, result.stdout, " \r\n"),
        .err = std.mem.trim(u8, result.stderr, " \r\n"),
    };
}

/// `git <args>`, which must succeed; a failure is reported with what git said.
fn must(c: Context, args: []const []const u8) ![]const u8 {
    const ran = try git(c, args);
    if (!ran.ok) try say.fail(c.io, "git {s}: {s}", .{ args[0], ran.err });
    return ran.out;
}

/// Whether git pushes to `url` over SSH: `ssh://` (or `git+ssh://`), or the
/// `[user@]host:path` form, which a local path (`/x`, `C:\x`) is not.
pub fn isSsh(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "ssh://") or std.mem.startsWith(u8, url, "git+ssh://") or std.mem.startsWith(u8, url, "ssh+git://")) return true;
    if (std.mem.find(u8, url, "://") != null) return false;
    const colon = std.mem.findScalar(u8, url, ':') orelse return false;
    // A drive letter is a path; a host is more than one character.
    if (colon < 2) return false;
    return std.mem.findAny(u8, url[0..colon], "/\\") == null;
}

test "a push URL is SSH in either form, and a path or https is not" {
    for ([_][]const u8{ "git@github.com:o/r.git", "ssh://git@github.com/o/r", "host:/srv/r.git", "git+ssh://h/r" }) |url| try std.testing.expect(isSsh(url));
    for ([_][]const u8{ "https://github.com/o/r", "/srv/r.git", "C:\\r", "C:/r", "file:///srv/r", "./r:x", "git://h/r" }) |url| try std.testing.expect(!isSsh(url));
}

/// Where a release goes: the branch checked out, and its upstream.
const Upstream = struct {
    branch: []const u8,
    remote: []const u8,
    url: []const u8,
    /// The branch on the remote, `refs/heads/<name>`.
    merge: []const u8,
    /// Its remote-tracking ref here.
    tracking: []const u8,
};

fn upstream(c: Context) !Upstream {
    const branch = (try git(c, &.{ "symbolic-ref", "--short", "-q", "HEAD" })).out;
    if (branch.len == 0) try say.fail(c.io, "HEAD is detached: check out the branch to release", .{});
    const remote = (try git(c, &.{ "config", "--get", try c.a.print("branch.{s}.remote", .{branch}) })).out;
    const merge = (try git(c, &.{ "config", "--get", try c.a.print("branch.{s}.merge", .{branch}) })).out;
    if (remote.len == 0 or merge.len == 0 or std.mem.eql(u8, remote, ".")) try say.fail(c.io, "{s} has no upstream on a remote: push it once with git push -u <remote> {s}", .{ branch, branch });
    const url = try must(c, &.{ "remote", "get-url", "--push", remote });
    if (!isSsh(url)) try say.fail(c.io, "{s} pushes to {s}, which is not SSH: a release goes over SSH (git remote set-url --push {s} <user>@<host>:<path>)", .{ remote, url, remote });
    const name = if (std.mem.startsWith(u8, merge, "refs/heads/")) merge["refs/heads/".len..] else merge;
    return .{ .branch = branch, .remote = remote, .url = url, .merge = merge, .tracking = try c.a.print("refs/remotes/{s}/{s}", .{ remote, name }) };
}

/// The commit a tag names here, or null.
fn localTag(c: Context, name: []const u8) !?[]const u8 {
    const ran = try git(c, &.{ "rev-parse", "-q", "--verify", try c.a.print("refs/tags/{s}^{{commit}}", .{name}) });
    return if (ran.ok and ran.out.len != 0) ran.out else null;
}

/// The commit each tag on the remote names, an annotated one peeled.
const RemoteTags = std.StringHashMapUnmanaged([]const u8);

fn remoteTags(c: Context, remote: []const u8) !RemoteTags {
    const listing = try must(c, &.{ "ls-remote", "--tags", remote });
    var tags: RemoteTags = .empty;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line_text = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.findScalar(u8, line_text, '\t') orelse continue;
        var ref = line_text[tab + 1 ..];
        if (!std.mem.startsWith(u8, ref, "refs/tags/")) continue;
        ref = ref["refs/tags/".len..];
        const peeled = std.mem.endsWith(u8, ref, "^{}");
        if (peeled) ref = ref[0 .. ref.len - 3];
        // The peeled line names the commit, and comes after the tag's own.
        if (peeled or !tags.contains(ref)) try tags.put(c.a, ref, line_text[0..tab]);
    }
    return tags;
}

fn tagName(c: Context, version: std.SemanticVersion) ![]const u8 {
    return c.a.print("v{f}", .{version});
}

/// The commit `bay release` gated green for `tag` and has not pushed yet.
fn gatedRef(c: Context, tag: []const u8) ![]const u8 {
    return c.a.print("refs/bay/gated/{s}", .{tag});
}

fn read(c: Context, name: []const u8) !?[:0]const u8 {
    var dir = try Io.Dir.cwd().openDir(c.io, c.package, .{});
    defer dir.close(c.io);
    const text = dir.readFileAlloc(c.io, name, c.a, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try c.a.dupeSentinel(u8, text, 0);
}

fn write(c: Context, name: []const u8, text: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(c.io, c.package, .{});
    defer dir.close(c.io);
    try dir.writeFile(c.io, .{ .sub_path = name, .data = text });
}

fn section(c: Context, text: []const u8) !changelog.Section {
    var problem: changelog.Problem = undefined;
    return changelog.unreleased(c.a, text, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoUnreleased => try say.fail(c.io, "CHANGELOG.md has no `## [Unreleased]` section: a release is written from it", .{}),
        error.Malformed => try say.fail(c.io, "CHANGELOG.md:{d}: {s}", .{ problem.line, problem.what }),
    };
}

/// What this run releases: a version cut from the section now, or a release
/// commit an earlier run made at HEAD, to gate and push.
const Plan = struct {
    version: std.SemanticVersion,
    tag: []const u8,
    /// The commit before the release: where a red gate puts the branch back.
    start: []const u8,
    /// The section to cut, or null when HEAD is the release commit already.
    cut: ?struct { from: std.SemanticVersion, section: changelog.Section, text: []const u8, manifest: [:0]const u8 },
};

pub fn run(c: Context, options: Options) !Outcome {
    const up = try upstream(c);
    if ((try must(c, &.{ "status", "--porcelain" })).len != 0) try say.fail(c.io, "the tree has changes: a release tags a commit as it is, so commit them or put them away first", .{});
    // The remote's tags are read from it (`ls-remote`), never fetched here: a refused release changes nothing.
    _ = try must(c, &.{ "fetch", "--quiet", "--no-tags", up.remote });
    const remote_has_branch = (try git(c, &.{ "rev-parse", "-q", "--verify", up.tracking })).ok;
    if (remote_has_branch and !(try git(c, &.{ "merge-base", "--is-ancestor", up.tracking, "HEAD" })).ok)
        try say.fail(c.io, "{s} is behind {s}: bring it up to date, then release", .{ up.branch, up.tracking["refs/remotes/".len..] });
    const head = try must(c, &.{ "rev-parse", "HEAD" });
    const manifest_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    const parsed = manifest.parse(c.a, manifest_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidManifest => try say.fail(c.io, "build.zig.zon is not a manifest bay can read", .{}),
    };
    const current = changelog.parseVersion(parsed.version) orelse try say.fail(c.io, "build.zig.zon's .version \"{s}\" is not major.minor.patch", .{parsed.version});
    const log = try read(c, "CHANGELOG.md") orelse try say.fail(c.io, "no CHANGELOG.md: a release is written from its `## [Unreleased]` section", .{});
    const tags = try remoteTags(c, up.remote);
    const newest = changelog.newestReleased(log);
    if (newest) |n| if (n.order(current) != .eq)
        try say.fail(c.io, "build.zig.zon's .version is {f} and CHANGELOG.md's newest release is {f}: a tag names the one the manifest declares, so set them to one release", .{ current, n });
    const current_tag = try tagName(c, current);
    const current_here = try localTag(c, current_tag);
    const current_there = tags.get(current_tag);
    // A release the remote has at HEAD whose read-back this clone never saw.
    if (current_there) |sha| if (current_here == null and std.mem.eql(u8, sha, head)) {
        _ = try must(c, &.{ "tag", current_tag, head });
        try say.note(c.io, "{s} is on {s} at {s}: tagged here too", .{ current_tag, up.remote, head[0..12] });
    };
    if (current_here != null and current_there == null)
        try say.fail(c.io, "{s} is tagged here and not on {s}: push it (git push {s} {s}) or delete it, then release", .{ current_tag, up.remote, up.remote, current_tag });
    const plan: Plan = plan: {
        // The CHANGELOG has released the version and nothing tags it: a release under way.
        if (newest != null and current_there == null) {
            const subject = try must(c, &.{ "log", "-1", "--format=%s", "HEAD" });
            const pushed = remote_has_branch and (try git(c, &.{ "merge-base", "--is-ancestor", "HEAD", up.tracking })).ok;
            if (!std.mem.eql(u8, subject, try c.a.print("Release {s}", .{current_tag})) or pushed or !(try section(c, log)).empty())
                try say.fail(c.io, "CHANGELOG.md releases {f}, and no tag names it: a release stopped before its push is finished from its own commit (check it out and run bay release), or dropped", .{current});
            try say.note(c.io, "{s} is under way at {s}: gating it and pushing it", .{ current_tag, head[0..12] });
            break :plan .{ .version = current, .tag = current_tag, .start = try must(c, &.{ "rev-parse", "HEAD^" }), .cut = null };
        }
        const unreleased = try section(c, log);
        const change = unreleased.change();
        if (change == .none) {
            if (options.push_unreleased and remote_has_branch and !std.mem.eql(u8, head, try must(c, &.{ "rev-parse", up.tracking }))) {
                return pushUnreleased(c, up, head, options);
            }
            try say.note(c.io, "nothing to release: CHANGELOG.md's [Unreleased] lists nothing", .{});
            return .nothing;
        }
        // The first release is the version the manifest names: nothing came before it.
        const first = newest == null and current_there == null and current_here == null;
        const version = if (first) current else changelog.next(current, change);
        const tag = try tagName(c, version);
        if (tags.get(tag)) |sha| try say.fail(c.io, "{s} is on {s} already, at {s}: a tag never moves; build.zig.zon's .version is behind the releases", .{ tag, up.remote, sha[0..12] });
        if (try localTag(c, tag)) |sha| try say.fail(c.io, "{s} is tagged here already, at {s}: a tag never moves; build.zig.zon's .version is behind the releases", .{ tag, sha[0..12] });
        break :plan .{ .version = version, .tag = tag, .start = head, .cut = .{ .from = current, .section = unreleased, .text = log, .manifest = manifest_text } };
    };
    const gate_machines = try machines.load(c.io, c.a, c.environ);
    if (options.dry_run) {
        try dryRun(c, up, plan, gate_machines);
        return .nothing;
    }
    if (plan.cut) |cut| {
        var problem: changelog.Problem = undefined;
        const cut_log = changelog.cut(c.a, cut.text, plan.version, try changelog.today(c.a, c.io), &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try say.fail(c.io, "CHANGELOG.md:{d}: {s}", .{ problem.line, problem.what }),
        };
        try write(c, "CHANGELOG.md", cut_log);
        try write(c, "build.zig.zon", try manifest.setVersion(c.a, cut.manifest, plan.version));
        _ = try must(c, &.{ "add", "--", "CHANGELOG.md", "build.zig.zon" });
        _ = try must(c, &.{ "commit", "--quiet", "-m", try c.a.print("Release {s}", .{plan.tag}) });
        try say.note(c.io, "{s} {f} -> {f}: committed as Release {s}", .{ parsed.name, cut.from, plan.version, plan.tag });
    }
    const commit = try must(c, &.{ "rev-parse", "HEAD" });
    const gated = try gatedRef(c, plan.tag);
    const recorded = (try git(c, &.{ "rev-parse", "-q", "--verify", gated })).out;
    if (std.mem.eql(u8, recorded, commit)) {
        try say.note(c.io, "{s} at {s} was gated green; pushing it", .{ plan.tag, commit[0..12] });
    } else if (!try gateEverywhere(c, gate_machines)) {
        _ = try must(c, &.{ "reset", "--quiet", "--keep", plan.start });
        try say.fail(c.io, "the gate is red: nothing was tagged or pushed, and {s} is back at {s}", .{ up.branch, plan.start[0..12] });
    } else _ = try must(c, &.{ "update-ref", gated, commit });
    try push(c, up, commit, plan.tag);
    _ = try must(c, &.{ "update-ref", "-d", gated });
    try say.note(c.io, "released {s} {s} at {s}: {s} and the tag on {s}", .{ parsed.name, plan.tag, commit[0..12], up.branch, up.remote });
    return .{ .released = plan.version };
}

/// Gates the commit at HEAD here and on every machine at once; whether all are green.
fn gateEverywhere(c: Context, gate_machines: []const machines.Machine) !bool {
    var terminal: machines.Terminal = .init(.{});
    var request: machines.Request = .{ .bundle = "", .repository = "", .package = "." };
    if (gate_machines.len != 0) {
        const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
        const prefix = (try git(c, &.{ "rev-parse", "--show-prefix" })).out;
        const cache = try std.fs.path.join(c.a, &.{ c.package, ".zig-cache", "bay", "release" });
        try Io.Dir.cwd().createDirPath(c.io, cache);
        request = .{
            .bundle = try std.fs.path.join(c.a, &.{ cache, "release.bundle" }),
            .repository = std.fs.path.basename(top),
            .package = if (prefix.len == 0) "." else std.mem.trimEnd(u8, prefix, "/"),
        };
        _ = try must(c, &.{ "bundle", "create", "--quiet", request.bundle, "HEAD", "--tags" });
    }
    const results = try c.a.alloc(Result, gate_machines.len + 1);
    @memset(results, .{});
    var group: Io.Group = .init;
    group.async(c.io, gateHere, .{ c, &results[0] });
    for (gate_machines, results[1..]) |machine, *result| group.async(c.io, gateThere, .{ c, machine, request, &terminal, result });
    try group.await(c.io);
    if (terminal.teardown().unwritten) |err| return err;
    var green = true;
    for (results, 0..) |result, index| {
        const where = if (index == 0) "here" else try c.a.print("on {s}", .{gate_machines[index - 1].name});
        if (result.failed) |err| try say.note(c.io, "gate {s}: could not run: {t}", .{ where, err });
        try say.note(c.io, "gate {s}: {s}", .{ where, if (result.green) "green" else "red" });
        green = green and result.green;
    }
    return green;
}

const Result = struct { green: bool = false, failed: ?anyerror = null };

fn gateHere(c: Context, result: *Result) void {
    const bay = c.environ.get("BAY").?; // safe: main sets BAY before any command
    var child = std.process.spawn(c.io, .{ .argv = &.{ bay, "gate" }, .cwd = .{ .path = c.package }, .environ_map = c.environ }) catch |err| {
        result.failed = err;
        return;
    };
    const term = child.wait(c.io) catch |err| {
        result.failed = err;
        return;
    };
    result.green = term == .exited and term.exited == 0;
}

fn gateThere(c: Context, machine: machines.Machine, request: machines.Request, terminal: *machines.Terminal, result: *Result) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    result.green = machines.gate(c.io, arena.allocator(), c.environ, machine, request, terminal) catch |err| {
        result.failed = err;
        return;
    };
}

/// The branch and, given one, the tag, onto the remote in one atomic push, then
/// read back; the tag is made here only once the remote holds both.
fn push(c: Context, up: Upstream, commit: []const u8, tag: ?[]const u8) !void {
    const branch_spec = try c.a.print("{s}:{s}", .{ commit, up.merge });
    const pushed = if (tag) |t|
        try git(c, &.{ "push", "--quiet", "--atomic", up.remote, branch_spec, try c.a.print("{s}:refs/tags/{s}", .{ commit, t }) })
    else
        try git(c, &.{ "push", "--quiet", up.remote, branch_spec });
    if (!pushed.ok) try say.fail(c.io, "the push to {s} failed, and nothing moved there: {s}; bay release again pushes the gated commit", .{ up.remote, pushed.err });
    const tag_ref = if (tag) |t| try c.a.print("refs/tags/{s}", .{t}) else up.merge;
    const listing = try must(c, &.{ "ls-remote", up.remote, up.merge, tag_ref });
    var branch_ok = false;
    var tag_ok = tag == null;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line_text = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.findScalar(u8, line_text, '\t') orelse continue;
        if (!std.mem.eql(u8, line_text[0..tab], commit)) continue;
        if (std.mem.eql(u8, line_text[tab + 1 ..], up.merge)) branch_ok = true;
        if (tag != null and std.mem.eql(u8, line_text[tab + 1 ..], tag_ref)) tag_ok = true;
    }
    if (!branch_ok or !tag_ok) try say.fail(c.io, "{s} took the push, but reading it back shows {s}{s} elsewhere than {s}", .{ up.remote, if (branch_ok) "" else up.merge, if (tag_ok) "" else " and the tag", commit[0..12] });
    if (tag) |t| _ = try must(c, &.{ "tag", t, commit });
    _ = try must(c, &.{ "update-ref", up.tracking, commit });
}

/// A train's member whose new commits are development pins alone: gated, then
/// the branch pushed with no tag.
fn pushUnreleased(c: Context, up: Upstream, head: []const u8, options: Options) !Outcome {
    if (options.dry_run) {
        try say.out(c.io, "nothing to release; the commits {s} has not would be gated and pushed with no tag\n", .{up.remote});
        return .nothing;
    }
    if (!try gateEverywhere(c, try machines.load(c.io, c.a, c.environ))) try say.fail(c.io, "the gate is red: nothing was pushed", .{});
    try push(c, up, head, null);
    try say.note(c.io, "nothing to release; {s} pushed to {s} at {s}", .{ up.branch, up.remote, head[0..12] });
    return .pushed;
}

fn dryRun(c: Context, up: Upstream, plan: Plan, gate_machines: []const machines.Machine) !void {
    if (plan.cut) |cut| {
        try say.out(c.io, "{f} -> {f} ({t})\n\n## [{f}] - {s}\n\n", .{ cut.from, plan.version, cut.section.change(), plan.version, try changelog.today(c.a, c.io) });
        var out: Io.Writer.Allocating = .init(c.a);
        try cut.section.write(&out.writer);
        try say.out(c.io, "{s}\n", .{out.written()});
        try say.out(c.io, "commit Release {s} on {s}\n", .{ plan.tag, up.branch });
    } else try say.out(c.io, "{s} under way at HEAD\n", .{plan.tag});
    try say.out(c.io, "gate it here", .{});
    for (gate_machines) |machine| try say.out(c.io, ", on {s}", .{machine.name});
    try say.out(c.io, "\npush {s} and {s} to {s} ({s}) at once\n", .{ up.branch, plan.tag, up.remote, up.url });
}

/// `bay --workspace release`: the train. Members one at a time, each after the
/// members it ships and is developed with. Each is first pinned at the releases
/// of the members it depends on (`bay tidy`, §8), its normal dependencies'
/// re-pins named under `### Changed` and committed; then it is released when
/// its section has entries, or, with development pins alone, gated and pushed
/// with no tag. A member that fails stops the members that depend on it.
pub fn train(c: Context, options: Options) !u8 {
    const directories = try workspace.all(c.io, c.a, c.package) orelse try say.fail(c.io, "no {s} here or in any directory above", .{workspace.file_name});
    const cars = try each.train(c.io, c.a, directories);
    const Done = enum { released, pushed, nothing, failed, skipped };
    const done = try c.a.alloc(Done, cars.len);
    const versions = try c.a.alloc(?std.SemanticVersion, cars.len);
    @memset(versions, null);
    for (cars, done, versions) |car, *outcome, *version| {
        outcome.* = for (car.needs) |need| {
            if (done[need] == .failed or done[need] == .skipped) {
                try say.note(c.io, "{s}: skipped, since {s} did not release", .{ car.name, cars[need].name });
                break .skipped;
            }
        } else outcome: {
            try say.note(c.io, "{s}: {s}", .{ car.name, car.directory });
            var member = c;
            member.package = car.directory;
            repinned(member, options) catch |err| switch (err) {
                error.Reported => break :outcome .failed,
                else => return err,
            };
            break :outcome switch (run(member, .{ .dry_run = options.dry_run, .push_unreleased = true }) catch |err| switch (err) {
                error.Reported => break :outcome .failed,
                else => return err,
            }) {
                .nothing => .nothing,
                .pushed => .pushed,
                .released => |v| released: {
                    version.* = v;
                    break :released .released;
                },
            };
        };
    }
    var failed = false;
    for (cars, done, versions) |car, outcome, version| {
        if (version) |v| try say.note(c.io, "{s}: released {f}", .{ car.name, v }) else try say.note(c.io, "{s}: {t}", .{ car.name, outcome });
        if (outcome == .failed or outcome == .skipped) failed = true;
    }
    return if (failed) 1 else 0;
}

/// The member pinned at the releases of the members it depends on, as `bay tidy`
/// pins them in a workspace; its normal dependencies' re-pins named in its
/// CHANGELOG, and the change committed. A dry run says what would move.
fn repinned(c: Context, options: Options) !void {
    const bay = c.environ.get("BAY").?; // safe: main sets BAY before any command
    if (options.dry_run) {
        // --locked names what would move and writes nothing; a refusal to write is its answer.
        var child = try std.process.spawn(c.io, .{ .argv = &.{ bay, "--locked", "tidy" }, .cwd = .{ .path = c.package }, .environ_map = c.environ });
        _ = try child.wait(c.io);
        return;
    }
    const before_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    var child = std.process.spawn(c.io, .{ .argv = &.{ bay, "tidy" }, .cwd = .{ .path = c.package }, .environ_map = c.environ }) catch |err|
        try say.fail(c.io, "could not run bay tidy: {t}", .{err});
    switch (try child.wait(c.io)) {
        .exited => |code| if (code != 0) try say.fail(c.io, "bay tidy failed in {s}", .{c.package}),
        else => try say.fail(c.io, "bay tidy failed in {s}", .{c.package}),
    }
    const after_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    if (std.mem.eql(u8, before_text, after_text)) return;
    const before = try manifest.parse(c.a, before_text);
    const after = try manifest.parse(c.a, after_text);
    const shipped = try moved(c.a, before.normal, after.normal);
    const developed = try moved(c.a, before.dev, after.dev);
    if (shipped.len != 0) {
        const log = try read(c, "CHANGELOG.md") orelse try say.fail(c.io, "no CHANGELOG.md: a re-pin is named in it", .{});
        const entry = try c.a.print("- Pins {s}.", .{try listed(c.a, shipped)});
        try write(c, "CHANGELOG.md", changelog.addEntry(c.a, log, .changed, entry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try say.fail(c.io, "CHANGELOG.md has no `## [Unreleased]` section to name the re-pins in", .{}),
        });
    }
    _ = try must(c, &.{ "add", "--", "build.zig.zon", "CHANGELOG.md" });
    const all = try std.mem.concat(c.a, []const u8, &.{ shipped, developed });
    _ = try must(c, &.{ "commit", "--quiet", "-m", try c.a.print("Pin {s}", .{try listed(c.a, all)}) });
}

/// `name version` of each dependency `after` pins at another hash than `before`.
fn moved(a: std.mem.Allocator, before: []const manifest.Dependency, after: []const manifest.Dependency) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (after) |dependency| {
        const now = switch (dependency.source) {
            .remote => |remote| remote.hash,
            .path => continue,
        };
        const was: ?[]const u8 = for (before) |old| {
            if (std.mem.eql(u8, old.name, dependency.name)) break switch (old.source) {
                .remote => |remote| remote.hash,
                .path => null,
            };
        } else null;
        if (was) |hash| if (std.mem.eql(u8, hash, now)) continue;
        const named = manifest.named(now) orelse {
            try out.append(a, dependency.name);
            continue;
        };
        try out.append(a, try a.print("{s} {f}", .{ dependency.name, named.version }));
    }
    return out.items;
}

/// "a", "a and b", "a, b and c".
fn listed(a: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    std.debug.assert(items.len != 0); // a re-pin names what moved
    if (items.len == 1) return items[0];
    return a.print("{s} and {s}", .{ try std.mem.join(a, ", ", items[0 .. items.len - 1]), items[items.len - 1] });
}

test "re-pins are listed as a sentence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("x 1.0.0", try listed(a, &.{"x 1.0.0"}));
    try std.testing.expectEqualStrings("x 1.0.0, y 0.2.0 and z 0.3.1", try listed(a, &.{ "x 1.0.0", "y 0.2.0", "z 0.3.1" }));
}
