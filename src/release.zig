//! `bay release`: the one way a package releases. The version is the one its
//! CHANGELOG's `[Unreleased]` section makes; the section becomes the release,
//! the manifest takes the version, and both are committed as `Release vX.Y.Z`.
//! That exact commit is gated, here and on each of the person's machines, by
//! the package's own `gate` step (preflight's, at the version the package
//! pins); only then do the branch and the tag go to the remote, in one atomic
//! push over SSH, read back before the tag is made here.
//!
//! A package on GitHub whose workflow runs a release tier (preflight's ci.yml) is
//! gated there too before its tag: the release commit goes to `release/vX.Y.Z` on
//! the remote, never to main, the release tier is dispatched on it through
//! GitHub's API with the person's own login (`gh auth token`, or GITHUB_TOKEN),
//! and waited on, one hosted run at a time on the machine (the release queue).
//! Only a green run lets the commit reach main, in the one atomic push that
//! carries the tag, an annotated one whose `Gated-by:` names the run, and deletes
//! the candidate branch. A release goes only to the remote's default branch.
//!
//! git is the record of a release under way: a red gate puts the branch back
//! where it was; a run that stops leaves its release commit at HEAD, which the
//! next run gates and pushes; a commit gated green whose push did not go is
//! recorded in bay's data directory on this machine, with the hosted run that
//! passed it, so the next run pushes it without gating it again. No tag is ever
//! made on a commit no gate passed.
const std = @import("std");
const aegis = @import("aegis");
const intake = @import("intake.zig");
const Io = std.Io;
const changelog = @import("changelog.zig");
const manifest = @import("manifest.zig");
const machines = @import("machines.zig");
const say = @import("say.zig");
const workspace = @import("workspace.zig");
const each = @import("each.zig");
const tidying = @import("tidy.zig");
const select = @import("select.zig");
const store = @import("store.zig");
const nuget_signature = @import("nuget_signature.zig");
const toolchain = @import("toolchain.zig");
const fetch = @import("fetch.zig");
const lock = @import("lock.zig");
const dirs = @import("dirs.zig");
const git_source = @import("git.zig");
const advertised = @import("remote.zig");
const github = @import("github.zig");

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
    /// Commit and gate, and push nothing: the gated commit waits, recorded, for a later
    /// `bay release` (another person's, it may be) to push it without gating it again.
    no_push: bool = false,
    /// With `push_unreleased`, push the commits with no tag whatever the section holds: a
    /// re-pin by `bay pin` alone, its entry left for the next release.
    no_tag: bool = false,
};

pub const Outcome = union(enum) {
    /// Nothing to release, and nothing pushed.
    nothing,
    /// The branch pushed with no release.
    pushed,
    /// Gated green and held here, for a later run to push.
    held: std.SemanticVersion,
    released: std.SemanticVersion,
};

/// A git command's outcome, its output trimmed.
const Ran = struct { ok: bool, out: []const u8, err: []const u8 };

fn git(c: Context, args: []const []const u8) !Ran {
    const argv = try std.mem.concat(c.a, []const u8, &.{ &.{"git"}, args });
    const result = intake.run(c.a, c.io, .{ .argv = argv, .cwd = .{ .path = c.package }, .environ_map = c.environ }) catch |err|
        try say.fail(c.io, "could not run git: {t}", .{err});
    return .{
        .ok = result.term == .exited and result.term.exited == 0,
        .out = std.mem.trim(u8, result.stdout.readForParse(), " \r\n"),
        .err = std.mem.trim(u8, result.stderr.readForParse(), " \r\n"),
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
    /// The branch on the remote as people name it, `<remote>/<name>`.
    onto: []const u8,
    /// The branch had no upstream: the push makes this its upstream, as `git push -u` does.
    set: bool,
};

fn upstream(c: Context) !Upstream {
    const branch = (try git(c, &.{ "symbolic-ref", "--short", "-q", "HEAD" })).out;
    if (branch.len == 0) try say.fail(c.io, "HEAD is detached: check out the branch to release", .{});
    var remote = (try git(c, &.{ "config", "--get", try c.a.print("branch.{s}.remote", .{branch}) })).out;
    var merge = (try git(c, &.{ "config", "--get", try c.a.print("branch.{s}.merge", .{branch}) })).out;
    // A branch with no upstream goes where `git push -u` would send it: its own name on the
    // remote git pushes to by default, or on the one remote there is.
    const set = remote.len == 0 or merge.len == 0 or std.mem.eql(u8, remote, ".");
    if (set) {
        remote = (try git(c, &.{ "config", "--get", "remote.pushDefault" })).out;
        if (remote.len == 0) {
            const remotes = try must(c, &.{"remote"});
            if (remotes.len == 0 or std.mem.findScalar(u8, remotes, '\n') != null)
                try say.fail(c.io, "{s} has no upstream, and {s}: push it once with git push -u <remote> {s}", .{ branch, if (remotes.len == 0) "there is no remote" else "more than one remote could take it", branch });
            remote = remotes;
        }
        merge = try c.a.print("refs/heads/{s}", .{branch});
    }
    const url = try must(c, &.{ "remote", "get-url", "--push", remote });
    if (!isSsh(url)) try say.fail(c.io, "{s} pushes to {s}, which is not SSH: a release goes over SSH (git remote set-url --push {s} <user>@<host>:<path>)", .{ remote, url, remote });
    const name = if (std.mem.startsWith(u8, merge, "refs/heads/")) merge["refs/heads/".len..] else merge;
    return .{ .branch = branch, .remote = remote, .url = url, .merge = merge, .tracking = try c.a.print("refs/remotes/{s}/{s}", .{ remote, name }), .onto = try c.a.print("{s}/{s}", .{ remote, name }), .set = set };
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

/// What a package has released before: CHANGELOG.md's newest release, and the commit the
/// tag of its manifest's version names here and on the remote.
const History = struct {
    newest: ?std.SemanticVersion,
    here: ?[]const u8,
    there: ?[]const u8,

    /// Nothing released and nothing tagged: the release to come is the first.
    fn first(h: History) bool {
        return h.newest == null and h.here == null and h.there == null;
    }
};

/// `History` read as a release and a train's plan both read it, from the package in `c`.
fn historyOf(c: Context, log: []const u8, current: std.SemanticVersion, tags: RemoteTags) !History {
    const tag = try tagName(c, current);
    return .{ .newest = changelog.newestReleased(log), .here = try localTag(c, tag), .there = tags.get(tag) };
}

/// The version a release takes, the one rule `bay release` and a train's dry run both follow:
/// the first release is the version the manifest names, as nothing came before it; any other
/// is the next one `change` asks for.
fn nextVersion(current: std.SemanticVersion, change: changelog.Change, history: History) std.SemanticVersion {
    return if (history.first()) current else changelog.next(current, change);
}

fn tagName(c: Context, version: std.SemanticVersion) ![]const u8 {
    return c.a.print("v{f}", .{version});
}

/// Where this machine records the commit `bay release` gated green for `tag` and has not
/// pushed: `<data>/gated/<repository>/<tag>`, the repository named by the SHA-256 of its git
/// directory's path. Only bay writes it, and nothing carries it: a ref would travel with a
/// fetch, a bundle or a mirror clone, and a record made anywhere but in this machine's gate
/// would push a commit no gate here passed.
fn gatedRecord(c: Context, tag: []const u8) ![]const u8 {
    return gatedPath(c.a, try dirs.data(c.io, c.a, c.environ), try must(c, &.{ "rev-parse", "--absolute-git-dir" }), tag);
}

fn gatedPath(a: std.mem.Allocator, data: []const u8, git_dir: []const u8, tag: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(git_dir, &digest, .{});
    return std.fs.path.join(a, &.{ data, "gated", &std.fmt.bytesToHex(digest, .lower), tag });
}

/// What a record holds: the commit gated green here, and the hosted run that passed it too,
/// where it had one.
const Recorded = struct { commit: []const u8, hosted: ?[]const u8 };

/// The record at `path`, or null when there is none: the commit on its first line, the hosted
/// run's page on a second.
fn recorded(io: Io, a: std.mem.Allocator, path: []const u8) !?Recorded {
    const text = if (intake.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(4096))) |taken| taken.readForParse() else |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    const commit = lines.next() orelse return null;
    return .{ .commit = commit, .hosted = lines.next() };
}

fn record(io: Io, a: std.mem.Allocator, path: []const u8, commit: []const u8, hosted: ?[]const u8) !void {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const text = if (hosted) |url| try a.print("{s}\n{s}\n", .{ commit, url }) else commit;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn forget(io: Io, path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn read(c: Context, name: []const u8) !?[:0]const u8 {
    var dir = try Io.Dir.cwd().openDir(c.io, c.package, .{});
    defer dir.close(c.io);
    const text = if (intake.readFile(c.io, dir, name, c.a, .fromRaw(16 << 20))) |taken| taken.readForParse() else |err| switch (err) {
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

/// `bay release` of one package. A workspace above it would build its other members'
/// trees in place of what the package pins, so the gate would pass on code no release
/// holds: refused. A train's members are gated in their workspace, as it is made for.
pub fn run(c: Context, options: Options) !Outcome {
    try alone(c);
    return releaseOne(c, options);
}

fn alone(c: Context) !void {
    const others = try workspace.members(c.io, c.a, c.package);
    if (others.len == 0) return;
    const names = try c.a.alloc([]const u8, others.len);
    for (names, others) |*name, member| name.* = std.fs.path.basename(member);
    const file = (try workspace.fileOf(c.io, c.a, c.package)).?; // safe: a workspace has other members only when its file is found
    try say.fail(c.io, "{s} holds this package with {s}: their trees would stand in for the pins, so the gate would not be the release's; release the workspace with bay --workspace release, or this package from a clone outside it", .{ file, try listed(c.a, names) });
}

/// Where a release goes, once the refusals that come before anything is made have passed: the
/// remote's default branch, from a clean tree that is not behind it; and whether the remote
/// has the branch yet.
fn releasable(c: Context) !struct { Upstream, bool } {
    const up = try upstream(c);
    const default = try defaultBranch(c, up.remote);
    if (!std.mem.eql(u8, up.merge, default))
        try say.fail(c.io, "{s} would go to {s}, and a release goes only to {s}'s default branch, {s}: releases are one line, made from it", .{ up.branch, up.onto, up.remote, default["refs/heads/".len..] });
    if ((try must(c, &.{ "status", "--porcelain" })).len != 0) try say.fail(c.io, "the tree has changes: a release tags a commit as it is, so commit them or put them away first", .{});
    // The remote's tags are read from it (`ls-remote`), never fetched here: a refused release changes nothing.
    _ = try must(c, &.{ "fetch", "--quiet", "--no-tags", up.remote });
    const remote_has_branch = (try git(c, &.{ "rev-parse", "-q", "--verify", up.tracking })).ok;
    if (remote_has_branch and !(try git(c, &.{ "merge-base", "--is-ancestor", up.tracking, "HEAD" })).ok)
        try say.fail(c.io, "{s} is behind {s}: bring it up to date, then release", .{ up.branch, up.tracking["refs/remotes/".len..] });
    return .{ up, remote_has_branch };
}

/// The package released, its pins resolved as wherever it stands resolves them.
fn releaseOne(c: Context, options: Options) !Outcome {
    const up, const remote_has_branch = try releasable(c);
    const head = try must(c, &.{ "rev-parse", "HEAD" });
    const manifest_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    const parsed = manifest.parse(c.a, manifest_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidManifest => try say.fail(c.io, "build.zig.zon is not a manifest bay can read", .{}),
    };
    const current = changelog.parseVersion(parsed.version) orelse try say.fail(c.io, "build.zig.zon's .version \"{s}\" is not major.minor.patch", .{parsed.version});
    const log = try read(c, "CHANGELOG.md") orelse try say.fail(c.io, "no CHANGELOG.md: a release is written from its `## [Unreleased]` section", .{});
    const tags = try remoteTags(c, up.remote);
    const history = try historyOf(c, log, current, tags);
    const newest = history.newest;
    if (newest) |n| if (n.order(current) != .eq)
        try say.fail(c.io, "build.zig.zon's .version is {f} and CHANGELOG.md's newest release is {f}: a tag names the one the manifest declares, so set them to one release", .{ current, n });
    const current_tag = try tagName(c, current);
    const current_here = history.here;
    const current_there = history.there;
    // A release the remote has at HEAD whose read-back this clone never saw: its tag, the one
    // the remote holds (annotated, with its Gated-by), fetched here.
    if (current_there) |sha| if (current_here == null and std.mem.eql(u8, sha, head)) {
        _ = try must(c, &.{ "fetch", "--quiet", "--no-tags", up.remote, try c.a.print("refs/tags/{s}:refs/tags/{s}", .{ current_tag, current_tag }) });
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
        if (change == .none or options.no_tag) {
            if (options.push_unreleased and remote_has_branch and !std.mem.eql(u8, head, try must(c, &.{ "rev-parse", up.tracking }))) {
                return pushUnreleased(c, up, head, options);
            }
            // A release this clone pushed, or another's, at HEAD: its GitHub Release finished.
            if (newest != null and current_there != null and std.mem.eql(u8, current_there.?, head) and !options.dry_run) try publishRelease(c, up, current_tag, current, .resumed);
            if (change == .none) {
                try say.note(c.io, "nothing to release: CHANGELOG.md's [Unreleased] lists nothing", .{});
            } else try say.note(c.io, "nothing pushed: {s} holds every commit here, and [Unreleased] waits for the next release", .{up.onto});
            return .nothing;
        }
        const version = nextVersion(current, change, history);
        const tag = try tagName(c, version);
        if (tags.get(tag)) |sha| try say.fail(c.io, "{s} is on {s} already, at {s}: a tag never moves; build.zig.zon's .version is behind the releases", .{ tag, up.remote, sha[0..12] });
        if (try localTag(c, tag)) |sha| try say.fail(c.io, "{s} is tagged here already, at {s}: a tag never moves; build.zig.zon's .version is behind the releases", .{ tag, sha[0..12] });
        break :plan .{ .version = version, .tag = tag, .start = head, .cut = .{ .from = current, .section = unreleased, .text = log, .manifest = manifest_text } };
    };
    try pinsAreReleases(c, parsed, &.{});
    // Where the release tier must pass on GitHub, a login to dispatch it is asked for first.
    const hosted = if (options.dry_run or options.no_push) null else try hostedTarget(c, up);
    const gate_machines = try machines.load(c.io, c.a, c.environ);
    if (options.dry_run) {
        try dryRun(c, up, plan, gate_machines, options);
        return .nothing;
    }
    if (plan.cut) |cut| {
        var problem: changelog.Problem = undefined;
        const cut_log = changelog.cut(c.a, cut.text, plan.version, try today(c.a, c.io), &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try say.fail(c.io, "CHANGELOG.md:{d}: {s}", .{ problem.line, problem.what }),
        };
        try write(c, "CHANGELOG.md", cut_log);
        const released = try manifest.setVersion(c.a, cut.manifest, plan.version);
        try write(c, "build.zig.zon", released);
        // What the build makes from the manifest, made again for the version it names now, in
        // the release commit. A release moves no pin: a tidy that would is refused, and the
        // tree, clean when the release began, is put back.
        try bayIn(c, &.{"tidy"});
        if (!std.mem.eql(u8, try read(c, "build.zig.zon") orelse "", released)) {
            _ = try must(c, &.{ "checkout", "--quiet", "--", "." });
            _ = try must(c, &.{ "clean", "--quiet", "-fd" });
            try say.fail(c.io, "build.zig.zon is not tidy: bay tidy moves its pins, which a release does not; tidy and commit it first", .{});
        }
        _ = try must(c, &.{ "add", "--all" });
        _ = try must(c, &.{ "commit", "--quiet", "-m", try c.a.print("Release {s}", .{plan.tag}) });
        try say.note(c.io, "{s} {f} -> {f}: committed as Release {s}", .{ parsed.name, cut.from, plan.version, plan.tag });
    }
    const commit = try must(c, &.{ "rev-parse", "HEAD" });
    const gated = try gatedRecord(c, plan.tag);
    var gated_by: ?[]const u8 = null;
    const held = try recorded(c.io, c.a, gated);
    if (held != null and std.mem.eql(u8, held.?.commit, commit)) {
        gated_by = held.?.hosted;
        try say.note(c.io, "{s} at {s} was gated green{s}; pushing it", .{ plan.tag, commit[0..12], if (gated_by != null) ", here and on GitHub" else "" });
    } else if (try gateEverywhere(c, gate_machines)) |red| {
        _ = try must(c, &.{ "reset", "--quiet", "--keep", plan.start });
        try say.fail(c.io, "the gate is red {s}: nothing was tagged or pushed, and {s} is back at {s}", .{ red, up.branch, plan.start[0..12] });
    } else try record(c.io, c.a, gated, commit, null);
    if (options.no_push) {
        try say.note(c.io, "{s} at {s} is gated green and held here: bay release pushes it, with no gate again", .{ plan.tag, commit[0..12] });
        return .{ .held = plan.version };
    }
    if (hosted != null and gated_by == null) {
        gated_by = try hostedGate(c, up, hosted.?, commit, plan.tag, plan.start, gated);
        try record(c.io, c.a, gated, commit, gated_by);
    }
    try push(c, up, commit, .{ .name = plan.tag, .gated_by = gated_by });
    try forget(c.io, gated);
    try say.note(c.io, "released {s} {s} at {s}: {s} and the tag {s} on {s}", .{ parsed.name, plan.tag, commit[0..12], up.onto, plan.tag, up.remote });
    try publishRelease(c, up, plan.tag, plan.version, .just_pushed);
    return .{ .released = plan.version };
}

/// The branch a remote's HEAD names, `refs/heads/main` where it names none (an empty one).
fn defaultBranch(c: Context, remote: []const u8) ![]const u8 {
    const listing = try git(c, &.{ "ls-remote", "--symref", remote, "HEAD" });
    var lines = std.mem.tokenizeScalar(u8, listing.out, '\n');
    while (lines.next()) |raw| {
        const line_text = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line_text, "ref: ")) continue;
        const tab = std.mem.findScalar(u8, line_text, '\t') orelse continue;
        const ref = line_text["ref: ".len..tab];
        if (std.mem.startsWith(u8, ref, "refs/heads/")) return ref;
    }
    return "refs/heads/main";
}

/// GitHub access for a release: GITHUB_TOKEN where it is set, else the login `gh` keeps
/// (`gh auth token`). bay stores no token of its own. Empty where there is neither.
fn githubToken(c: Context) ![]const u8 {
    if (c.environ.get("GITHUB_TOKEN")) |token| if (token.len != 0) return token;
    const asked = intake.run(c.a, c.io, .{ .argv = &.{ "gh", "auth", "token" }, .environ_map = c.environ }) catch return "";
    if (asked.term != .exited or asked.term.exited != 0) return "";
    return std.mem.trim(u8, asked.stdout.readForParse(), " \r\n");
}

/// Where a release's hosted gate runs: its repository on GitHub and the API with the person's
/// login. Null where the remote is not on github.com or the workflow runs no release tier.
const Hosted = struct { repository: []const u8, token: []const u8, base: []const u8 };

/// The workflow file a release tier is dispatched in, as preflight generates it.
const workflow = "ci.yml";

fn hostedTarget(c: Context, up: Upstream) !?Hosted {
    const repository = github.slug(up.url) orelse return null;
    const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
    var dir = try Io.Dir.cwd().openDir(c.io, top, .{});
    defer dir.close(c.io);
    const text = if (intake.readFile(c.io, dir, ".github/workflows/" ++ workflow, c.a, .fromRaw(4 << 20))) |taken| taken.readForParse() else |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    // A dispatch that takes the tier, and the release tier among its choices.
    if (std.mem.find(u8, text, "workflow_dispatch:") == null or std.mem.find(u8, text, "options: [ci, release") == null) return null;
    const token = try githubToken(c);
    if (token.len == 0) try say.fail(c.io, "{s}'s workflow runs a release tier, which a release passes on GitHub before its tag: log in with gh auth login, or set GITHUB_TOKEN", .{repository});
    const base = c.environ.get("GITHUB_API_URL") orelse "";
    return .{ .repository = repository, .token = token, .base = if (base.len == 0) github.default_api else base };
}

/// The candidate branch a release's hosted gate runs on: `refs/heads/release/vX.Y.Z`.
fn candidateRef(c: Context, tag: []const u8) ![]const u8 {
    return c.a.print("refs/heads/release/{s}", .{tag});
}

/// How long the hosted gate waits between two looks at GitHub: BAY_POLL_SECONDS, else 30.
fn pollInterval(c: Context) Io.Duration {
    const given = c.environ.get("BAY_POLL_SECONDS") orelse "";
    const seconds = std.fmt.parseInt(u32, given, 10) catch 30;
    return aegis.units.Duration(.second, u32).fromRaw(seconds).toIoDuration();
}

/// A minute before now in GitHub's form, `YYYY-MM-DDTHH:MM:SSZ`: the earliest a run of this
/// dispatch was made, a clock's skew allowed.
fn dispatchedSince(c: Context) ![]const u8 {
    const now = try aegis.units.Instant(.real, .second, i64).fromTimestamp(Io.Clock.real.now(c.io), .down);
    const seconds: u64 = @intCast(@max(60, now.raw()) - 60); // safe: at least sixty before the subtraction
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return c.a.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, month_day.month.numeric(), month_day.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}

/// The hosted gate: the release commit on the candidate branch, the release tier dispatched on
/// it and waited on, each job said as it ends, one run at a time on this machine. Green, the
/// run's page, for the tag's `Gated-by`; red, the candidate deleted, the branch put back and the
/// release refused, nothing reaching main or a tag.
fn hostedGate(c: Context, up: Upstream, hosted: Hosted, commit: []const u8, tag: []const u8, start: []const u8, gated: []const u8) ![]const u8 {
    const poll = pollInterval(c);
    var queue = try lock.wait(c.io, c.a, c.environ, .release_queue, try dirs.data(c.io, c.a, c.environ), poll);
    defer queue.release(c.io);
    const candidate = try candidateRef(c, tag);
    const branch = candidate["refs/heads/".len..];
    // A candidate a stopped run left is this release's own: replaced, never pushed onto.
    if ((try git(c, &.{ "ls-remote", "--exit-code", up.remote, candidate })).ok) _ = try must(c, &.{ "push", "--quiet", up.remote, try c.a.print(":{s}", .{candidate}) });
    _ = try must(c, &.{ "push", "--quiet", up.remote, try c.a.print("{s}:{s}", .{ commit, candidate }) });
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    const api: github.Api = .{ .client = &client, .a = c.a, .base = hosted.base, .token = hosted.token };
    var problem: github.Problem = .{};
    const since = try dispatchedSince(c);
    github.dispatch(api, hosted.repository, workflow, branch, "{\"tier\":\"release\"}", &problem) catch |err| try hostedFailed(c, up, err, problem, candidate, start, gated);
    // GitHub makes the run a moment after the dispatch: looked for until it shows.
    var looks: u32 = 0;
    const found = while (true) : (looks += 1) {
        if (github.newestRun(api, hosted.repository, branch, commit, since, &problem) catch |err| try hostedFailed(c, up, err, problem, candidate, start, gated)) |one| break one;
        if (looks == 40) {
            problem.what = try c.a.print("GitHub shows no run of {s} on {s} after {d} looks", .{ workflow, branch, looks });
            try hostedFailed(c, up, error.GitHub, problem, candidate, start, gated);
        }
        try c.io.sleep(poll, .awake);
    };
    try say.note(c.io, "{s} at {s}: the release tier runs on GitHub, {s}", .{ tag, commit[0..12], found.html_url });
    var said: std.StringHashMapUnmanaged(void) = .empty;
    const ended = while (true) {
        const now = github.run(api, hosted.repository, found.id, &problem) catch |err| try hostedFailed(c, up, err, problem, candidate, start, gated);
        const job_list = github.jobs(api, hosted.repository, found.id, &problem) catch |err| try hostedFailed(c, up, err, problem, candidate, start, gated);
        for (job_list) |job| if (job.conclusion) |conclusion| if (!said.contains(job.name)) {
            try said.put(c.a, job.name, {});
            try say.note(c.io, "hosted: {s}: {s}", .{ job.name, conclusion });
        };
        if (std.mem.eql(u8, now.status, "completed")) break .{ now, job_list };
        try c.io.sleep(poll, .awake);
    };
    const finished = ended[0];
    if (finished.conclusion != null and std.mem.eql(u8, finished.conclusion.?, "success")) {
        try say.note(c.io, "hosted: green, {s}", .{finished.html_url});
        return finished.html_url;
    }
    var red: std.ArrayList([]const u8) = .empty;
    for (ended[1]) |job| if (job.conclusion) |conclusion| if (!std.mem.eql(u8, conclusion, "success") and !std.mem.eql(u8, conclusion, "skipped")) try red.append(c.a, job.name);
    _ = try git(c, &.{ "push", "--quiet", up.remote, try c.a.print(":{s}", .{candidate}) });
    _ = try must(c, &.{ "reset", "--quiet", "--keep", start });
    try forget(c.io, gated);
    try say.fail(c.io, "the release tier is {s} on GitHub ({s}): {s}; nothing was tagged or pushed to {s}, {s} is deleted, and {s} is back at {s}", .{ finished.conclusion orelse "unfinished", if (red.items.len == 0) "no job named" else try std.mem.join(c.a, ", ", red.items), finished.html_url, up.onto, branch, up.branch, start[0..12] });
}

/// A hosted gate GitHub would not run or answer: refused as a red one is, nothing reaching main.
fn hostedFailed(c: Context, up: Upstream, err: github.Error, problem: github.Problem, candidate: []const u8, start: []const u8, gated: []const u8) !noreturn {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    _ = try git(c, &.{ "push", "--quiet", up.remote, try c.a.print(":{s}", .{candidate}) });
    _ = try must(c, &.{ "reset", "--quiet", "--keep", start });
    try forget(c.io, gated);
    try say.fail(c.io, "the release tier could not run on GitHub: {s}; nothing was tagged or pushed to {s}, and {s} is back at {s}", .{ problem.what, up.onto, up.branch, start[0..12] });
}

/// The annotated tag object of a release, written into the repository and not yet named by any
/// ref: the version as its message and, where the release tier passed it on GitHub, a
/// `Gated-by:` line with the run. The tagger is the committer git names.
fn annotate(c: Context, tag: Tag, commit: []const u8) ![]const u8 {
    const tagger = try must(c, &.{ "var", "GIT_COMMITTER_IDENT" });
    const message = if (tag.gated_by) |url| try c.a.print("{s}\n\nGated-by: {s}\n", .{ tag.name, url }) else try c.a.print("{s}\n", .{tag.name});
    const cache = try std.fs.path.join(c.a, &.{ c.package, ".zig-cache", "bay", "release" });
    try Io.Dir.cwd().createDirPath(c.io, cache);
    const file = try std.fs.path.join(c.a, &.{ cache, try c.a.print("tag-{s}", .{tag.name}) });
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = file, .data = try c.a.print("object {s}\ntype commit\ntag {s}\ntagger {s}\n\n{s}", .{ commit, tag.name, tagger, message }) });
    return must(c, &.{ "hash-object", "-t", "tag", "-w", file });
}

/// The run a tag's message names on its `Gated-by:` line, or null.
pub fn gatedBy(message: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, message, "\r\n");
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "Gated-by: ")) {
        const page = std.mem.trim(u8, line["Gated-by: ".len..], " \t");
        if (page.len != 0) return page;
    };
    return null;
}

test "a tag's Gated-by line names its run, and a tag without one names none" {
    try std.testing.expectEqualStrings("https://github.com/o/r/actions/runs/5", gatedBy("v1.0.0\n\nGated-by: https://github.com/o/r/actions/runs/5\n").?);
    try std.testing.expect(gatedBy("v1.0.0\n") == null);
    try std.testing.expect(gatedBy("v1.0.0\n\nGated-by: \n") == null);
    try std.testing.expect(gatedBy("") == null);
}

/// `bay audit releases`: whether each release tag of the package's repository on GitHub is one
/// `bay release` made. A release made so is an annotated tag whose `Gated-by:` names a run of the
/// release tier, green, on that tag's commit and candidate branch, and a GitHub Release whose
/// notes name the same run. The tags before the first release gated on GitHub came before the
/// rule: they are named once, as history. Each later tag that falls short is named with what
/// it lacks. True when none does.
pub fn audit(c: Context) !bool {
    const remote = try auditedRemote(c);
    const url = try must(c, &.{ "remote", "get-url", remote });
    const repository = github.slug(url) orelse try say.fail(c.io, "{s} is {s}, no repository on github.com: the audit reads the runs and releases GitHub holds for its tags", .{ remote, url });
    const releases = try releaseTags(c, remote);
    var first: ?usize = null;
    for (releases, 0..) |*one, n| {
        if (one.annotated) one.gated_by = gatedBy(try tagMessage(c, remote, one.*));
        if (first == null and one.gated_by != null) first = n;
    }
    const start = first orelse {
        try say.out(c.io, "{s}: no release gated on GitHub yet, so its {d} release tag{s} history\n", .{ repository, releases.len, if (releases.len == 1) " is" else "s are" });
        return true;
    };
    if (start != 0) {
        const names = try c.a.alloc([]const u8, start);
        for (names, releases[0..start]) |*name, one| name.* = one.name;
        try say.out(c.io, "history: {s} came before the first release gated on GitHub, {s}\n", .{ try listed(c.a, names), releases[start].name });
    }
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    const base = c.environ.get("GITHUB_API_URL") orelse "";
    const api: github.Api = .{ .client = &client, .a = c.a, .base = if (base.len == 0) github.default_api else base, .token = try githubToken(c) };
    var short: usize = 0;
    for (releases[start..]) |one| {
        const lacks = try lacking(c, api, repository, one);
        if (lacks.len == 0) continue;
        short += 1;
        try say.out(c.io, "{s}: {s}\n", .{ one.name, try std.mem.join(c.a, "; ", lacks) });
    }
    const under = releases.len - start;
    if (short == 0)
        try say.out(c.io, "{s}: {d} release{s} since, each an annotated tag gated green on GitHub, with the GitHub Release bay made\n", .{ repository, under, if (under == 1) "" else "s" })
    else
        try say.out(c.io, "{s}: {d} of {d} releases since are not as bay release makes them\n", .{ repository, short, under });
    return short == 0;
}

/// The remote an audit reads: the branch's upstream, else the one remote, else origin.
fn auditedRemote(c: Context) ![]const u8 {
    const branch = (try git(c, &.{ "symbolic-ref", "--short", "-q", "HEAD" })).out;
    if (branch.len != 0) {
        const remote = (try git(c, &.{ "config", "--get", try c.a.print("branch.{s}.remote", .{branch}) })).out;
        if (remote.len != 0 and !std.mem.eql(u8, remote, ".")) return remote;
    }
    const remotes = try must(c, &.{"remote"});
    if (remotes.len == 0) try say.fail(c.io, "there is no remote: the audit reads the release tags of the package's repository", .{});
    if (std.mem.findScalar(u8, remotes, '\n') == null) return remotes;
    var names = std.mem.tokenizeAny(u8, remotes, "\r\n");
    while (names.next()) |name| if (std.mem.eql(u8, name, "origin")) return name;
    try say.fail(c.io, "more than one remote, and none is the branch's upstream or origin: check out a branch with an upstream", .{});
}

/// A release tag on the remote: `vX.Y.Z`, the object it names, and the commit under it.
const ReleaseTag = struct {
    name: []const u8,
    version: std.SemanticVersion,
    object: []const u8,
    commit: []const u8,
    annotated: bool = false,
    gated_by: ?[]const u8 = null,

    fn before(_: void, x: ReleaseTag, y: ReleaseTag) bool {
        return x.version.order(y.version) == .lt;
    }
};

/// The remote's release tags, oldest version first.
fn releaseTags(c: Context, remote: []const u8) ![]ReleaseTag {
    const listing = try must(c, &.{ "ls-remote", "--tags", remote });
    var tags: std.ArrayList(ReleaseTag) = .empty;
    var at: std.StringHashMapUnmanaged(usize) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line_text = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.findScalar(u8, line_text, '\t') orelse continue;
        const sha = line_text[0..tab];
        var name = line_text[tab + 1 ..];
        if (!std.mem.startsWith(u8, name, "refs/tags/v")) continue;
        name = name["refs/tags/".len..];
        const peeled = std.mem.endsWith(u8, name, "^{}");
        if (peeled) name = name[0 .. name.len - "^{}".len];
        const version = changelog.parseVersion(name[1..]) orelse continue;
        if (at.get(name)) |n| {
            // The peeled line names the commit under an annotated tag.
            if (peeled) {
                tags.items[n].commit = sha;
                tags.items[n].annotated = true;
            }
            continue;
        }
        try at.put(c.a, name, tags.items.len);
        try tags.append(c.a, .{ .name = name, .version = version, .object = sha, .commit = sha, .annotated = peeled });
    }
    std.mem.sort(ReleaseTag, tags.items, {}, ReleaseTag.before);
    return tags.items;
}

/// An annotated tag's object as git prints it, fetched from the remote where this clone does
/// not hold it; no ref here moves.
fn tagMessage(c: Context, remote: []const u8, tag: ReleaseTag) ![]const u8 {
    const held = try git(c, &.{ "cat-file", "tag", tag.object });
    if (held.ok) return held.out;
    _ = try must(c, &.{ "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, try c.a.print("refs/tags/{s}", .{tag.name}) });
    return must(c, &.{ "cat-file", "tag", tag.object });
}

/// What a release tag under the rule lacks, each said; empty where it has all.
fn lacking(c: Context, api: github.Api, repository: []const u8, tag: ReleaseTag) ![]const []const u8 {
    var lacks: std.ArrayList([]const u8) = .empty;
    var problem: github.Problem = .{};
    if (!tag.annotated) {
        try lacks.append(c.a, "a lightweight tag, which names no run");
    } else if (tag.gated_by == null) try lacks.append(c.a, "no Gated-by line: no run of the release tier passed it");
    if (tag.gated_by) |page| {
        const runs = try c.a.print("https://github.com/{s}/actions/runs/", .{repository});
        const id = if (std.mem.startsWith(u8, page, runs)) std.fmt.parseInt(u64, page[runs.len..], 10) catch null else null;
        if (id) |run_id| {
            if (github.run(api, repository, run_id, &problem)) |ran| {
                const candidate = try c.a.print("release/{s}", .{tag.name});
                if (ran.conclusion == null or !std.mem.eql(u8, ran.conclusion.?, "success"))
                    try lacks.append(c.a, try c.a.print("its run {s} ended {s}, not green", .{ page, ran.conclusion orelse ran.status }));
                if (!std.mem.eql(u8, ran.head_sha, tag.commit))
                    try lacks.append(c.a, try c.a.print("its run {s} ran on {s}, not on the tagged {s}", .{ page, ran.head_sha[0..@min(12, ran.head_sha.len)], tag.commit[0..12] }));
                if (ran.head_branch == null or !std.mem.eql(u8, ran.head_branch.?, candidate))
                    try lacks.append(c.a, try c.a.print("its run {s} ran on {s}, not on {s}", .{ page, ran.head_branch orelse "no branch", candidate }));
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.GitHub => try lacks.append(c.a, try c.a.print("its run {s} could not be read: {s}", .{ page, problem.what })),
            }
        } else try lacks.append(c.a, try c.a.print("its Gated-by names {s}, no run of {s}", .{ page, repository }));
    }
    if (github.releaseNotes(api, repository, tag.name, &problem)) |found| {
        if (found == null) {
            try lacks.append(c.a, "no GitHub Release");
        } else if (tag.gated_by) |page| if (std.mem.find(u8, found.?, page) == null)
            try lacks.append(c.a, "a GitHub Release whose notes name no Gated-by run, which bay release did not make");
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GitHub => try lacks.append(c.a, try c.a.print("its GitHub Release could not be read: {s}", .{problem.what})),
    }
    return lacks.items;
}

/// The GitHub Release of a version's tag: the section the CHANGELOG released it with as its
/// notes, and, where the build has a `dist` step, the programs it makes from the release
/// commit and their SHA256SUMS. A remote off github.com has none. GitHub makes the release
/// once and keeps it, so a run that stopped part way is finished by the next `bay release`
/// at the tag.
fn publishRelease(c: Context, up: Upstream, tag: []const u8, version: std.SemanticVersion, when: enum { just_pushed, resumed }) !void {
    const repository = github.slug(up.url) orelse return;
    const token = try githubToken(c);
    if (token.len == 0) {
        if (when == .just_pushed) try say.note(c.io, "{s} has no GitHub Release: GITHUB_TOKEN is not set and gh has no login, and bay release at {s} with either publishes one", .{ tag, tag });
        return;
    }
    const log = try read(c, "CHANGELOG.md") orelse "";
    const section_notes = changelog.released(log, version) orelse try say.fail(c.io, "CHANGELOG.md has no section for {s}: the GitHub Release takes its notes from it", .{tag});
    const message = (try git(c, &.{ "for-each-ref", "--format=%(contents)", try c.a.print("refs/tags/{s}", .{tag}) })).out;
    const notes = if (gatedBy(message)) |run_page| try c.a.print("{s}\n\nGated by the release tier on GitHub: {s}", .{ section_notes, run_page }) else section_notes;
    const assets = try programs(c, tag);
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    const base = c.environ.get("GITHUB_API_URL") orelse "";
    var problem: github.Problem = .{};
    const page = github.publish(.{ .client = &client, .a = c.a, .base = if (base.len == 0) github.default_api else base, .token = token }, repository, tag, notes, assets, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GitHub => try say.fail(c.io, "{s} is tagged and pushed, and its GitHub Release is not finished: {s}; bay release at {s} finishes it", .{ tag, problem.what, tag }),
    };
    try say.note(c.io, "{s} on GitHub: {s}{s}", .{ tag, page, if (assets.len == 0) "" else try c.a.print(", with {d} files", .{assets.len}) });
}

/// What a release ships beside its notes: each program the build's `dist` step installs into
/// `dist` under its prefix, built from the release commit into a directory of its own, and
/// their SHA256SUMS. Nothing where the build has no `dist` step.
fn programs(c: Context, tag: []const u8) ![]const github.Asset {
    if (!hasStep(try bayOut(c, &.{ "build", "-l" }), "dist")) return &.{};
    const prefix = try std.fs.path.join(c.a, &.{ c.package, ".zig-cache", "bay", "release", tag });
    try bayIn(c, &.{ "build", "dist", "--prefix", prefix });
    const built = try std.fs.path.join(c.a, &.{ prefix, "dist" });
    var dir = Io.Dir.cwd().openDir(c.io, built, .{ .iterate = true }) catch |err|
        try say.fail(c.io, "the dist step made no {s}: {t}", .{ built, err });
    defer dir.close(c.io);
    var assets: std.ArrayList(github.Asset) = .empty;
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = try c.a.dupe(u8, entry.name);
        try assets.append(c.a, .{ .name = name, .bytes = (try intake.readFile(c.io, dir, name, c.a, .fromRaw(512 << 20))).readForParse() });
    }
    if (assets.items.len == 0) try say.fail(c.io, "the dist step put nothing in {s}", .{built});
    try assets.append(c.a, .{ .name = "SHA256SUMS", .bytes = try github.sums(c.a, assets.items) });
    return assets.items;
}

/// Whether `zig build -l`'s listing names `step`: each step a line of its own, its name first.
fn hasStep(listing: []const u8, step: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        if (std.mem.eql(u8, words.next() orelse continue, step)) return true;
    }
    return false;
}

test "a build's listing names a step by the first word of its line, never inside another's" {
    const listing = "  install (default)            Copy build artifacts to prefix path\n  dist                         Build the release programs\n  check                        Compile the dist programs\n";
    try std.testing.expect(hasStep(listing, "dist"));
    try std.testing.expect(hasStep(listing, "install"));
    try std.testing.expect(!hasStep(listing, "programs"));
    try std.testing.expect(!hasStep("  check   Compile the dist programs\n", "dist"));
}

/// Every remote pin of the manifest is fixed as a release must be (`pinRule`): a Zig package at
/// a version tag on its repository, an archive that is no package at its exact commit. A
/// release pinned on a branch or any ref that moves builds from code nothing fixes, and its
/// consumers would take it. A development pin is held to this as a runtime pin is. `before` names the members a train pins at their releases before this one: a
/// train's plan reads the manifest before they move, and the run checks them once moved.
fn pinsAreReleases(c: Context, parsed: manifest.Manifest, before: []const Released) !void {
    var wrong: std.ArrayList([]const u8) = .empty;
    for ([_]struct { list: []const manifest.Dependency, dev: bool }{
        .{ .list = parsed.normal, .dev = false },
        .{ .list = parsed.dev, .dev = true },
        .{ .list = parsed.overrides, .dev = false },
    }) |kind| for (kind.list) |dependency| if (releasedAs(before, dependency.name) == null) switch (dependency.source) {
        .path => {},
        .remote => |at| switch (try pinRule(c.a, dependency.name, at.url, at.hash)) {
            .fixed => {},
            .refused => |reason| try wrong.append(c.a, reason),
            .git_tag => |pin| {
                const tagged = for (try advertised.tags(c.io, c.a, at.url)) |tag| {
                    if (std.mem.eql(u8, tag.name, pin.ref)) break tag.commit;
                } else null;
                if (tagged == null or !std.mem.eql(u8, tagged.?, pin.commit))
                    try wrong.append(c.a, try c.a.print("{s} (a Zig package: {s} is no tag at {s} on its repository)", .{ dependency.name, pin.ref, pin.commit[0..@min(12, pin.commit.len)] }));
            },
            .archive_tag => |archive| if (!isRelease(try advertised.tags(c.io, c.a, try c.a.print("git+{s}", .{archive.repository})), archive.revision))
                try wrong.append(c.a, try c.a.print("{s} ({s}, an archive of {s}, no version tag of its repository)", .{ dependency.name, if (archive.package) "a Zig package" else "no Zig package", archive.revision })),
        },
    };
    if (wrong.items.len != 0) try say.fail(c.io, "{s} pinned at no release: a release builds from what is fixed, a Zig package at a version tag and an archive that is no package at its exact commit, never a branch or a ref that moves; pin each so (bay update) and release again", .{try listed(c.a, wrong.items)});
    try pinsHoldTheirHashes(c, parsed, before);
    try oneHashEach(c, parsed, before);
}

/// The graph Zig fetches from the manifest holds each package (its name and fingerprint) at a
/// version under one hash. Zig refuses a graph with two ("contradictory hash for package with
/// fingerprint ... and version ...", Zig master since 0.18.0-dev), and so would every build of
/// the release with Zig alone: bay's forks join them only in bay's own builds. Walked as Zig
/// fetches it, with no fork: the manifest's pins and development pins, then each pinned
/// package's own pins as its manifest at that hash has them, never its development ones. In a
/// train's plan, a pin that this member or a member in `before` makes of a member in `before`
/// is that member's release, read in its tree, as the train re-pins it before the run reads
/// it; a pin any other package makes stays what it is, as no train moves it.
fn oneHashEach(c: Context, parsed: manifest.Manifest, before: []const Released) !void {
    const package = try std.fs.path.resolveAlloc(c.a, &.{c.package});
    const zig = try toolchain.forPackage(c.io, c.a, c.environ, package);
    const packages = try store.Store.init(c.io, c.a, c.environ, zig, package, try nuget_signature.chosen(c.a, parsed, package));
    const Hashes = struct { hashes: std.ArrayList([]const u8) = .empty, by: std.ArrayList([]const u8) = .empty };
    var versions: std.array_hash_map.String(Hashes) = .empty;
    var followed: std.array_hash_map.String(void) = .empty;
    const Next = struct { pin: select.Pin, by: []const u8, by_member: bool };
    var queue: std.ArrayList(Next) = .empty;
    const root = try store.revisionOf(c.io, c.a, package, .{ .directory = package }, parsed, true);
    for (root.pins) |pin| try queue.append(c.a, .{ .pin = pin, .by = parsed.name, .by_member = true });
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const at = queue.items[next];
        // The release the train pins it at: a member's pin of it, or a pin of that very tag.
        const release: ?Released = if (releasedAs(before, at.pin.key)) |r| switch (at.pin.place) {
            .directory => null,
            .remote => |remote| if (at.by_member) r else if (git_source.releasePin(remote.url)) |tagged| (if (tagged.version.order(r.version) == .eq) r else null) else null,
        } else null;
        const revision = if (release) |r| try store.developedAt(c.io, c.a, r.directory) else switch (at.pin.place) {
            .remote => |remote| if (store.unnamed(remote.hash)) continue else try packages.load(at.pin.place),
            .directory => try packages.load(at.pin.place),
        };
        if (at.pin.place == .remote) {
            const version = if (release) |r| r.version else revision.version;
            const hash = if (release) |r| try c.a.print("its release {f} in the train", .{r.version}) else at.pin.place.remote.hash;
            const entry = try versions.getOrPut(c.a, try c.a.print("{s} {f} (fingerprint 0x{x})", .{ revision.identity.name, version, revision.identity.fingerprint }));
            if (!entry.found_existing) entry.value_ptr.* = .{};
            if (!among(entry.value_ptr.hashes.items, hash)) {
                try entry.value_ptr.hashes.append(c.a, hash);
                try entry.value_ptr.by.append(c.a, at.by);
            }
        }
        if ((try followed.getOrPut(c.a, if (release) |r| r.directory else at.pin.place.key())).found_existing) continue;
        for (revision.pins) |pin| if (!pin.dev) try queue.append(c.a, .{ .pin = pin, .by = revision.identity.name, .by_member = release != null });
    }
    var wrong: std.ArrayList([]const u8) = .empty;
    for (versions.keys(), versions.values()) |name, found| if (found.hashes.items.len > 1) {
        var each_hash: std.ArrayList([]const u8) = .empty;
        for (found.hashes.items, found.by.items) |hash, by| try each_hash.append(c.a, try c.a.print("{s} (pinned by {s})", .{ hash, by }));
        try wrong.append(c.a, try c.a.print("{s} under {s}", .{ name, try listed(c.a, each_hash.items) }));
    };
    if (wrong.items.len != 0) try say.fail(c.io, "{s}: the graph Zig fetches holds one package at one version under two hashes, which Zig refuses (\"contradictory hash\"), as would any build of the release with Zig alone; bay's forks join them only in bay's builds. Pin each at one release everywhere it is pinned (bay update), and release again", .{try listed(c.a, wrong.items)});
}

/// A member a train pins at a release before this one: its name, its directory, and the
/// version of the release, made by the train or there already.
/// The context a member's turn runs in: every other member the train has not released (`done`
/// false) named for bay's children (`workspace.pinned_variable`), so they build at its pins and
/// not from their trees, as its release and its hosted gate build them; a member the train
/// released is at its tag, its tree, and is built from the tree. Gantry, developed with
/// preflight a4c8d3c and gated in the workspace with preflight's tree, had its files made by
/// preflight 72a0988 and refused, where its hosted gate reads them with a4c8d3c.
fn pinnedFor(c: Context, cars: []const each.Car, car: each.Car, done: []const bool) !Context {
    var list: std.ArrayList(u8) = .empty;
    for (cars, done) |other, released| {
        if (released or std.mem.eql(u8, other.directory, car.directory)) continue;
        if (list.items.len != 0) try list.append(c.a, std.fs.path.delimiter);
        try list.appendSlice(c.a, other.directory);
    }
    const environ = try c.a.create(std.process.Environ.Map);
    environ.* = try c.environ.clone(c.a);
    try environ.put(workspace.pinned_variable, list.items);
    return .{ .io = c.io, .a = c.a, .environ = environ, .package = car.directory };
}

/// A development pin on a member the train builds at its pin names a commit the member's
/// origin holds, on a branch or a tag, or the hosted gate could not fetch what the gate here
/// built. Read from the member's own clone: its tags and the branches it has from its origin.
fn pinsFetchable(c: Context, parsed: manifest.Manifest, cars: []const each.Car, done: []const bool) !void {
    var wrong: std.ArrayList([]const u8) = .empty;
    for (parsed.dev) |dependency| {
        const at = for (cars, done) |other, released| {
            if (!released and std.mem.eql(u8, other.name, dependency.name) and !std.mem.eql(u8, other.directory, c.package)) break other;
        } else continue;
        const url = switch (dependency.source) {
            .remote => |remote| remote.url,
            .path => continue,
        };
        const fragment = git_source.parts(url).fragment orelse continue;
        if (!git_source.isCommit(fragment)) continue;
        var there = c;
        there.package = at.directory;
        const known = (try git(there, &.{ "cat-file", "-e", try c.a.print("{s}^{{commit}}", .{fragment}) })).ok;
        const held = known and ((try must(there, &.{ "branch", "--remotes", "--contains", fragment })).len != 0 or (try must(there, &.{ "tag", "--contains", fragment })).len != 0);
        if (!held) try wrong.append(c.a, try c.a.print("{s} develops with {s} at {s}, which no branch or tag of {s}'s origin holds", .{ parsed.name, dependency.name, fragment[0..12], at.directory }));
    }
    if (wrong.items.len != 0) try say.fail(c.io, "{s}: the hosted gate fetches what the pin names, and could not; push it, or pin a commit its origin holds", .{try listed(c.a, wrong.items)});
}

const Released = struct { name: []const u8, directory: []const u8, version: std.SemanticVersion };

fn releasedAs(before: []const Released, name: []const u8) ?Released {
    for (before) |member| if (std.mem.eql(u8, member.name, name)) return member;
    return null;
}

fn among(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// What a release asks of one remote pin. A Zig package (its archive holds a `build.zig.zon`,
/// which Zig's hash records: an archive with none hashes as `N-V-…`) has versions, and is pinned
/// at a version tag: its tag is read from its repository (`git_tag`, `archive_tag`). An archive
/// that is no package (a grammar, a body of queries) has no version to tag, and its exact
/// commit with its hash fixes it as a tag would (`fixed`). A branch, or any ref that moves, is
/// refused for both, the reason saying which case it is. `pinsHoldTheirHashes` then proves the
/// hash, and so the case, is what the URL holds.
const PinRule = union(enum) {
    fixed,
    git_tag: struct { ref: []const u8, commit: []const u8 },
    archive_tag: struct { repository: []const u8, revision: []const u8, package: bool },
    refused: []const u8,
};

fn pinRule(a: std.mem.Allocator, name: []const u8, url: []const u8, hash: []const u8) !PinRule {
    const package = !std.mem.startsWith(u8, hash, "N-V-");
    if (std.mem.startsWith(u8, url, "git+")) {
        const p = git_source.parts(url);
        const at = p.ref orelse p.fragment orelse "its default branch";
        if (package) {
            const pin = git_source.releasePin(url) orelse return .{ .refused = try a.print("{s} (a Zig package at {s}: a package is released at a version tag)", .{ name, at }) };
            return .{ .git_tag = .{ .ref = pin.ref, .commit = pin.commit } };
        }
        const exact = if (p.fragment) |fragment| git_source.isCommit(fragment) else false;
        if (exact and (p.ref == null or git_source.releasePin(url) != null)) return .fixed;
        return .{ .refused = try a.print("{s} (no Zig package, at {s}, which moves: pin its exact commit, which its hash fixes as a tag would)", .{ name, at }) };
    }
    // A forge's archive of one revision is that revision of its repository. A known forge's URL
    // bay cannot read as one is refused; any other URL names no repository bay can read, and its
    // hash fixes the bytes its host published.
    switch (try forgeOf(a, url)) {
        .elsewhere, .published => return .fixed,
        .unread => |host| return .{ .refused = try a.print("{s} (a URL on {s} that bay cannot read as an archive of one revision; pin a version tag: bay update)", .{ name, host }) },
        .archive => |archive| {
            if (!package and git_source.isCommit(archive.revision)) return .fixed;
            if (isVersionName(archive.revision) or git_source.isCommit(archive.revision))
                return .{ .archive_tag = .{ .repository = archive.repository, .revision = archive.revision, .package = package } };
            return .{ .refused = if (package)
                try a.print("{s} (a Zig package, an archive of {s}, a ref that moves: a package is released at a version tag)", .{ name, archive.revision })
            else
                try a.print("{s} (no Zig package, an archive of {s}, a ref that moves: pin its exact commit, which its hash fixes as a tag would)", .{ name, archive.revision }) };
        },
    }
}

/// Whether `revision` names a version tag by its form (`v1.2.3`, `1.2.3`, `refs/tags/v1.2.3`):
/// the tag itself is read from the repository.
fn isVersionName(revision: []const u8) bool {
    const name = if (std.mem.startsWith(u8, revision, "refs/tags/")) revision["refs/tags/".len..] else revision;
    _ = std.SemanticVersion.parse(if (std.mem.startsWith(u8, name, "v")) name[1..] else name) catch return false;
    return true;
}

test "a Zig package is released at a version tag, an archive that is no package at its exact commit, and neither at a ref that moves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const commit = "910fdf6f49e9dee7e7257c7d11a76b040fdfb9de";
    const package = "aegis-0.2.4-rsxouoquDQApwYDuGdd2YyEeTeNp6CnJoOZKdVCfc3jt";
    const plain = "N-V-__8AAAQzGwBRCPcFD0BBMJFUJrNVB3b7gywG4pZsbsgl";
    // A Zig package: its version tag is read from its repository; a branch or a bare commit is refused, named a package.
    const tagged = try pinRule(a, "aegis", "git+https://github.com/o/aegis?ref=v0.3.0#" ++ commit, package);
    try std.testing.expectEqualStrings("v0.3.0", tagged.git_tag.ref);
    try std.testing.expectEqual(.archive_tag, std.meta.activeTag(try pinRule(a, "aegis", "https://github.com/o/aegis/archive/v0.3.0.tar.gz", package)));
    for ([_][]const u8{
        "git+https://github.com/o/aegis?ref=main#" ++ commit,
        "git+https://github.com/o/aegis#" ++ commit,
        "https://github.com/o/aegis/archive/main.tar.gz",
    }) |url| {
        const rule = try pinRule(a, "aegis", url, package);
        try std.testing.expect(std.mem.find(u8, rule.refused, "(a Zig package") != null);
    }
    // No package (no build.zig.zon): fixed by its exact commit, as an archive or a git pin.
    try std.testing.expectEqual(.fixed, std.meta.activeTag(try pinRule(a, "grammar_c", "https://github.com/o/tree-sitter-c/archive/" ++ commit ++ ".tar.gz", plain)));
    try std.testing.expectEqual(.fixed, std.meta.activeTag(try pinRule(a, "grammar_c", "git+https://github.com/o/tree-sitter-c#" ++ commit, plain)));
    // No package at a ref that moves: refused, named no package.
    for ([_][]const u8{
        "https://github.com/o/tree-sitter-c/archive/master.tar.gz",
        "https://github.com/o/tree-sitter-c/archive/refs/heads/master.tar.gz",
        "git+https://github.com/o/tree-sitter-c?ref=master#" ++ commit,
        "git+https://github.com/o/tree-sitter-c#master",
    }) |url| {
        const rule = try pinRule(a, "grammar_c", url, plain);
        try std.testing.expect(std.mem.find(u8, rule.refused, "(no Zig package") != null);
    }
    // A file a GitHub release publishes, as curl.se publishes its: fixed by its hash, which a
    // replaced file fails.
    try std.testing.expectEqual(.fixed, std.meta.activeTag(try pinRule(a, "held_git_nghttp2", "https://github.com/nghttp2/nghttp2/releases/download/v1.71.0/nghttp2-1.71.0.tar.gz", plain)));
}

/// Every remote pin's `.hash` is what its URL holds, fetched now as Zig records it. Zig takes
/// a package its cache holds by the hash alone, without the URL: a hash of other content
/// builds here, and fails or builds other code for anyone who fetches the release.
fn pinsHoldTheirHashes(c: Context, parsed: manifest.Manifest, before: []const Released) !void {
    const zig = try toolchain.forPackage(c.io, c.a, c.environ, c.package);
    // In the package's cache, which each fetch clears for itself.
    const scratch = try std.fs.path.join(c.a, &.{ c.package, ".zig-cache", "bay", "release-fetch" });
    var wrong: std.ArrayList([]const u8) = .empty;
    for ([_][]const manifest.Dependency{ parsed.normal, parsed.dev, parsed.overrides }) |list| for (list) |dependency| if (releasedAs(before, dependency.name) == null) switch (dependency.source) {
        .path => {},
        .remote => |at| {
            const fetched = try fetch.fetch(c.io, c.a, zig, scratch, at.url, dependency.name) orelse {
                try wrong.append(c.a, try c.a.print("{s} (its URL could not be fetched, so nothing shows its .hash is what the URL holds)", .{dependency.name}));
                continue;
            };
            const hash = fetched.source.remote.hash;
            if (!std.mem.eql(u8, hash, at.hash)) try wrong.append(c.a, try c.a.print("{s} (its .hash is {s}; what its URL holds is {s})", .{ dependency.name, at.hash, hash }));
        },
    };
    if (wrong.items.len != 0) try say.fail(c.io, "{s} pinned by a hash its URL does not hold: pin each again (bay update) and release again", .{try listed(c.a, wrong.items)});
}

/// Whether `revision` is a release of the repository whose tags are `tags`: a version tag by
/// its name (`v1.2.3`, `refs/tags/v1.2.3`), or a commit a version tag names.
fn isRelease(tags: []const advertised.Tag, revision: []const u8) bool {
    const name = if (std.mem.startsWith(u8, revision, "refs/tags/")) revision["refs/tags/".len..] else revision;
    for (tags) |tag| {
        // A tag that names no version is no release.
        if (advertised.versionOf(tag) == null) continue;
        if (std.mem.eql(u8, tag.name, name)) return true;
        if (git_source.isCommit(revision) and std.mem.eql(u8, tag.commit, revision)) return true;
    }
    return false;
}

/// What a pin's URL is as a forge's: an archive of one revision of a repository (`archive`), a
/// URL on a known forge that bay cannot read as one (`unread`, naming the host: refused, for a
/// release must show its pin is one), or a URL of no known forge (`elsewhere`: its hash fixes
/// the bytes its host published).
const Forge = union(enum) {
    archive: struct { repository: []const u8, revision: []const u8 },
    unread: []const u8,
    elsewhere,
    /// A file a forge's release publishes (GitHub's `/owner/repo/releases/download/<tag>/<file>`):
    /// as `elsewhere`, its hash fixes the bytes; a file replaced since fails the fetch.
    published,
};

/// The forges whose URLs bay reads. On any of them, a URL that is no archive form bay knows
/// is refused, never passed on its hash.
const known_forges = [_][]const u8{ "github.com", "api.github.com", "codeload.github.com", "gitlab.com", "bitbucket.org", "codeberg.org" };

/// The forms read, the repository as `https://host/owner/repo`:
/// - `/owner/repo/archive/<revision>.<ext>` (GitHub, Codeberg and any Forgejo or Gitea; the
///   revision may be `refs/tags/<tag>`);
/// - GitHub's `/owner/repo/{tarball,zipball}/<revision>`, `api.github.com/repos/owner/repo/
///   {tarball,zipball}/<revision>` and `codeload.github.com/owner/repo/<format>/<revision>`;
/// - GitLab's `/group/.../repo/-/archive/<revision>/<file>`, subgroups included;
/// - Bitbucket's `/owner/repo/get/<revision>.<ext>`.
/// A host is compared without its case. On a known forge, a URL with an empty path segment, a
/// query or a fragment, or not https, is unread.
fn forgeOf(a: std.mem.Allocator, url: []const u8) !Forge {
    const separator = std.mem.find(u8, url, "://") orelse return .elsewhere;
    const host_start = separator + "://".len;
    const host_end = std.mem.findAnyPos(u8, url, host_start, "/?#") orelse url.len;
    const host = try std.ascii.allocLowerString(a, url[host_start..host_end]);
    const known = for (known_forges) |forge| {
        if (std.mem.eql(u8, host, forge)) break true;
    } else false;
    if (releaseFile(host, url[0..separator], url[host_end..])) return .published;
    const archive_at = try archiveAt(a, host, url[0..separator], url[host_end..]);
    if (archive_at) |archive| return .{ .archive = .{ .repository = archive.repository, .revision = archive.revision } };
    return if (known) .{ .unread = host } else .elsewhere;
}

/// Whether the URL is a file a GitHub release publishes: `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`,
/// no segment empty, no query or fragment.
fn releaseFile(host: []const u8, scheme: []const u8, rest: []const u8) bool {
    if (!std.mem.eql(u8, host, "github.com") or !std.mem.eql(u8, scheme, "https") or std.mem.findAny(u8, rest, "?#") != null) return false;
    if (rest.len < 2 or rest[0] != '/') return false;
    var segments: [6][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, rest[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or count == segments.len) return false;
        segments[count] = part;
        count += 1;
    }
    return count == 6 and std.mem.eql(u8, segments[2], "releases") and std.mem.eql(u8, segments[3], "download");
}

const Archive = struct { repository: []const u8, revision: []const u8 };

fn archiveAt(a: std.mem.Allocator, host: []const u8, scheme: []const u8, rest: []const u8) !?Archive {
    if (!std.mem.eql(u8, scheme, "https") or rest.len < 2 or rest[0] != '/' or std.mem.findAny(u8, rest, "?#") != null) return null;
    const path = rest[1..];
    var segments: [64][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or count == segments.len) return null;
        segments[count] = part;
        count += 1;
    }
    const s = segments[0..count];
    // The path from segment `from` to segment `to`, inclusive, as the URL writes it.
    const span = struct {
        fn of(text: []const u8, all: []const []const u8, from: usize, to: usize) []const u8 {
            const start = @intFromPtr(all[from].ptr) - @intFromPtr(text.ptr);
            return text[start .. @intFromPtr(all[to].ptr) - @intFromPtr(text.ptr) + all[to].len];
        }
    }.of;
    const on_github = std.mem.eql(u8, host, "github.com");
    if (std.mem.eql(u8, host, "codeload.github.com")) {
        if (s.len < 4) return null;
        for ([_][]const u8{ "tar.gz", "zip", "legacy.tar.gz", "legacy.zip" }) |format| {
            if (std.mem.eql(u8, s[2], format)) return .{ .repository = try a.print("https://github.com/{s}", .{span(path, s, 0, 1)}), .revision = span(path, s, 3, s.len - 1) };
        }
        return null;
    }
    if (std.mem.eql(u8, host, "api.github.com")) {
        if (s.len < 5 or !std.mem.eql(u8, s[0], "repos")) return null;
        if (!std.mem.eql(u8, s[3], "tarball") and !std.mem.eql(u8, s[3], "zipball")) return null;
        return .{ .repository = try a.print("https://github.com/{s}", .{span(path, s, 1, 2)}), .revision = span(path, s, 4, s.len - 1) };
    }
    if (on_github and s.len >= 4 and (std.mem.eql(u8, s[2], "tarball") or std.mem.eql(u8, s[2], "zipball"))) {
        return .{ .repository = try a.print("https://{s}/{s}", .{ host, span(path, s, 0, 1) }), .revision = span(path, s, 3, s.len - 1) };
    }
    if (std.mem.eql(u8, host, "bitbucket.org")) {
        if (s.len != 4 or !std.mem.eql(u8, s[2], "get")) return null;
        const revision = withoutArchiveSuffix(s[3]) orelse return null;
        return .{ .repository = try a.print("https://{s}/{s}", .{ host, span(path, s, 0, 1) }), .revision = revision };
    }
    // GitLab's form, its project path any depth of groups: `/-/archive/<revision>/<file>`.
    for (s, 0..) |segment, i| if (std.mem.eql(u8, segment, "-")) {
        if (i < 2 or s.len < i + 4 or !std.mem.eql(u8, s[i + 1], "archive")) return null;
        return .{ .repository = try a.print("https://{s}/{s}", .{ host, span(path, s, 0, i - 1) }), .revision = span(path, s, i + 2, s.len - 2) };
    };
    if (s.len >= 4 and std.mem.eql(u8, s[2], "archive")) {
        const revision = withoutArchiveSuffix(span(path, s, 3, s.len - 1)) orelse return null;
        return .{ .repository = try a.print("https://{s}/{s}", .{ host, span(path, s, 0, 1) }), .revision = revision };
    }
    return null;
}

/// `name` without the archive format it ends in, or null when it ends in none or is nothing more.
fn withoutArchiveSuffix(name: []const u8) ?[]const u8 {
    for ([_][]const u8{ ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar", ".zip" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix) and name.len > suffix.len) return name[0 .. name.len - suffix.len];
    }
    return null;
}

test "a forge's archive names its repository and revision; a known forge's URL bay cannot read is unread; any other URL is elsewhere" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const commit = "5d2a92141f0298d76dc5fd602526d55a62b4e11a";
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "https://github.com/o/r/archive/" ++ commit ++ ".tar.gz", "https://github.com/o/r", commit },
        .{ "https://github.com/o/r/archive/refs/tags/v1.2.0.tar.gz", "https://github.com/o/r", "refs/tags/v1.2.0" },
        .{ "https://github.com/o/r/archive/v1.2.0.zip", "https://github.com/o/r", "v1.2.0" },
        .{ "https://GITHUB.COM/o/r/archive/v1.2.0.zip", "https://github.com/o/r", "v1.2.0" },
        .{ "https://github.com/o/r/tarball/" ++ commit, "https://github.com/o/r", commit },
        .{ "https://github.com/o/r/zipball/refs/tags/v1.2.0", "https://github.com/o/r", "refs/tags/v1.2.0" },
        .{ "https://api.github.com/repos/o/r/tarball/v1.2.0", "https://github.com/o/r", "v1.2.0" },
        .{ "https://codeload.github.com/o/r/tar.gz/refs/tags/v1.2.0", "https://github.com/o/r", "refs/tags/v1.2.0" },
        .{ "https://codeload.github.com/o/r/legacy.tar.gz/" ++ commit, "https://github.com/o/r", commit },
        .{ "https://codeberg.org/o/r/archive/v1.2.0.tar.gz", "https://codeberg.org/o/r", "v1.2.0" },
        .{ "https://gitlab.com/o/r/-/archive/v1.2.0/r-v1.2.0.tar.gz", "https://gitlab.com/o/r", "v1.2.0" },
        .{ "https://gitlab.com/g/sub/r/-/archive/" ++ commit ++ "/r-" ++ commit ++ ".tar.gz", "https://gitlab.com/g/sub/r", commit },
        .{ "https://bitbucket.org/o/r/get/v1.2.0.tar.gz", "https://bitbucket.org/o/r", "v1.2.0" },
        .{ "https://git.example.org/o/r/archive/v1.2.0.tar.gz", "https://git.example.org/o/r", "v1.2.0" },
    }) |case| {
        const got = (try forgeOf(a, case[0])).archive;
        try std.testing.expectEqualStrings(case[1], got.repository);
        try std.testing.expectEqualStrings(case[2], got.revision);
    }
    // review-1029b N9: each passed on its hash.
    for ([_][]const u8{
        "https://github.com//o/r/archive/" ++ commit ++ ".tar.gz",
        "https://github.com/o/r.git?ref=main#" ++ commit,
        "https://github.com/o/r/archive/.tar.gz",
        "https://github.com/o/r/releases/download/v1.2.0/",
        "https://github.com/o/r/releases/download/v1.2.0/r.tar.gz?x=1",
        "http://github.com/o/r/archive/v1.2.0.tar.gz",
        "https://api.github.com/repos/o/r/tarball",
        "https://gitlab.com/o/-/archive/v1.2.0/r.tar.gz",
        "https://bitbucket.org/o/r/get/v1.2.0",
        "https://codeberg.org/o/r/archive/v1.2.0.tar.gz?x=1",
    }) |url| try std.testing.expect(try forgeOf(a, url) == .unread);
    for ([_][]const u8{
        "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64/alpine-minirootfs-3.24.2-riscv64.tar.gz",
        "https://example.org/lib-1.0.tar.gz",
    }) |url| try std.testing.expect(try forgeOf(a, url) == .elsewhere);
    // A file a GitHub release publishes: its hash fixes the bytes, as another host's.
    for ([_][]const u8{
        "https://github.com/o/r/releases/download/v1.2.0/r-1.2.0.tar.gz",
        "https://GitHub.com/o/r/releases/download/v1.2.0/r-1.2.0.tar.gz",
    }) |url| try std.testing.expect(try forgeOf(a, url) == .published);
}

test "a revision is a release at a version tag, by name or by the commit it names" {
    const at = "5d2a92141f0298d76dc5fd602526d55a62b4e11a";
    const mid = "cfcf9dceb3ab6d5e5a198a0ac0784e2108251b9f";
    const tags = [_]advertised.Tag{ .{ .name = "v1.2.0", .commit = at }, .{ .name = "nightly", .commit = mid } };
    for ([_][]const u8{ "v1.2.0", "refs/tags/v1.2.0", at }) |revision| try std.testing.expect(isRelease(&tags, revision));
    for ([_][]const u8{ mid, "nightly", "main", "refs/heads/main", "v1.3.0" }) |revision| try std.testing.expect(!isRelease(&tags, revision));
}

/// Gates the commit at HEAD here and on every machine at once, each gate's output
/// also kept whole in a log of its own under `.zig-cache/bay/release`. Null when all
/// are green; else each red gate and where its log is, for the refusal to name.
fn gateEverywhere(c: Context, gate_machines: []const machines.Machine) !?[]const u8 {
    var terminal: machines.Terminal = .init(.{});
    const cache = try std.fs.path.join(c.a, &.{ c.package, ".zig-cache", "bay", "release" });
    try Io.Dir.cwd().createDirPath(c.io, cache);
    var request: machines.Request = .{ .bundle = "", .repository = "", .package = "." };
    if (gate_machines.len != 0) {
        const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
        const prefix = (try git(c, &.{ "rev-parse", "--show-prefix" })).out;
        request = .{
            .bundle = try std.fs.path.join(c.a, &.{ cache, "release.bundle" }),
            .repository = std.fs.path.basename(top),
            .package = if (prefix.len == 0) "." else std.mem.trimEnd(u8, prefix, "/"),
        };
        _ = try must(c, &.{ "bundle", "create", "--quiet", request.bundle, "HEAD", "--tags" });
    }
    const gates = try c.a.alloc(Gate, gate_machines.len + 1);
    for (gates, 0..) |*one, index| {
        const name = if (index == 0) "here" else gate_machines[index - 1].name;
        const log = try std.fs.path.join(c.a, &.{ cache, try c.a.print("gate-{s}.log", .{name}) });
        one.* = .{ .where = if (index == 0) "here" else try c.a.print("on {s}", .{name}), .log = log, .output = .{
            .name = if (index == 0) null else name,
            .log = .init(try Io.Dir.cwd().createFile(c.io, log, .{})),
            .terminal = &terminal,
        } };
    }
    defer for (gates) |*one| one.output.log.deinit(c.io);
    var group: Io.Group = .init;
    group.async(c.io, gateHere, .{ c, &gates[0] });
    for (gate_machines, gates[1..]) |machine, *one| group.async(c.io, gateThere, .{ c, machine, request, one });
    try group.await(c.io);
    if (terminal.teardown().unwritten) |err| return err;
    var red: std.ArrayList([]const u8) = .empty;
    for (gates) |one| {
        if (one.failed) |err| try say.note(c.io, "gate {s}: could not run: {t}", .{ one.where, err });
        try say.note(c.io, "gate {s}: {s}", .{ one.where, if (one.green) "green" else "red" });
        if (!one.green) try red.append(c.a, try c.a.print("{s} (its output: {s})", .{ one.where, one.log }));
    }
    if (red.items.len == 0) return null;
    return try std.mem.join(c.a, "; ", red.items);
}

/// One gate: where it runs, its log and its output, and how it ended.
const Gate = struct { where: []const u8, log: []const u8, output: machines.Output, green: bool = false, failed: ?anyerror = null };

fn gateHere(c: Context, one: *Gate) void {
    one.green = machines.local(c.io, c.a, c.environ, c.package, &one.output) catch |err| {
        one.failed = err;
        return;
    };
}

fn gateThere(c: Context, machine: machines.Machine, request: machines.Request, one: *Gate) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    one.green = machines.gate(c.io, arena.allocator(), c.environ, machine, request, &one.output) catch |err| {
        one.failed = err;
        return;
    };
}

/// A release's tag as the push makes it: an annotated tag, its message the version and, where
/// the release tier ran on GitHub, a `Gated-by:` line naming the run.
const Tag = struct { name: []const u8, gated_by: ?[]const u8 };

/// The branch and, given one, the tag, onto the remote in one atomic push, which also deletes
/// the release's candidate branch where the hosted gate made one, then read back; the tag is
/// made here only once the remote holds both.
fn push(c: Context, up: Upstream, commit: []const u8, tag: ?Tag) !void {
    const branch_spec = try c.a.print("{s}:{s}", .{ commit, up.merge });
    var object: []const u8 = commit;
    const pushed = if (tag) |t| pushed: {
        object = try annotate(c, t, commit);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(c.a, &.{ "push", "--quiet", "--atomic", up.remote, branch_spec, try c.a.print("{s}:refs/tags/{s}", .{ object, t.name }) });
        const candidate = try candidateRef(c, t.name);
        if ((try git(c, &.{ "ls-remote", "--exit-code", up.remote, candidate })).ok) try args.append(c.a, try c.a.print(":{s}", .{candidate}));
        break :pushed try git(c, args.items);
    } else try git(c, &.{ "push", "--quiet", up.remote, branch_spec });
    if (!pushed.ok) try say.fail(c.io, "the push to {s} failed, and nothing moved there: {s}; bay release again pushes the gated commit", .{ up.remote, pushed.err });
    const tag_ref = if (tag) |t| try c.a.print("refs/tags/{s}", .{t.name}) else up.merge;
    const listing = try must(c, &.{ "ls-remote", up.remote, up.merge, tag_ref });
    var branch_ok = false;
    var tag_ok = tag == null;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line_text = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.findScalar(u8, line_text, '\t') orelse continue;
        const sha = line_text[0..tab];
        if (std.mem.eql(u8, line_text[tab + 1 ..], up.merge) and std.mem.eql(u8, sha, commit)) branch_ok = true;
        if (tag != null and std.mem.eql(u8, line_text[tab + 1 ..], tag_ref) and std.mem.eql(u8, sha, object)) tag_ok = true;
    }
    if (!branch_ok or !tag_ok) try say.fail(c.io, "{s} took the push, but reading it back shows {s}{s} elsewhere than {s}", .{ up.remote, if (branch_ok) "" else up.merge, if (tag_ok) "" else " and the tag", commit[0..12] });
    if (tag) |t| _ = try must(c, &.{ "update-ref", try c.a.print("refs/tags/{s}", .{t.name}), object });
    _ = try must(c, &.{ "update-ref", up.tracking, commit });
    if (up.set) {
        _ = try must(c, &.{ "config", try c.a.print("branch.{s}.remote", .{up.branch}), up.remote });
        _ = try must(c, &.{ "config", try c.a.print("branch.{s}.merge", .{up.branch}), up.merge });
        try say.note(c.io, "{s} has {s} as its upstream now", .{ up.branch, up.onto });
    }
}

/// A train's member whose new commits are development pins alone: gated, then
/// the branch pushed with no tag.
fn pushUnreleased(c: Context, up: Upstream, head: []const u8, options: Options) !Outcome {
    if (options.dry_run) {
        try say.out(c.io, "nothing to release; the commits {s} has not would be gated and pushed with no tag\n", .{up.onto});
        return .nothing;
    }
    if (try gateEverywhere(c, try machines.load(c.io, c.a, c.environ))) |red| try say.fail(c.io, "the gate is red {s}: nothing was pushed", .{red});
    try push(c, up, head, null);
    try say.note(c.io, "nothing to release; {s} is at {s}, pushed with no tag", .{ up.onto, head[0..12] });
    return .pushed;
}

fn dryRun(c: Context, up: Upstream, plan: Plan, gate_machines: []const machines.Machine, options: Options) !void {
    if (plan.cut) |cut| {
        try say.out(c.io, "{f} -> {f} ({t})\n\n## [{f}] - {s}\n\n", .{ cut.from, plan.version, cut.section.change(), plan.version, try today(c.a, c.io) });
        var out: Io.Writer.Allocating = .init(c.a);
        try cut.section.write(&out.writer);
        try say.out(c.io, "{s}\n", .{out.written()});
        try say.out(c.io, "commit Release {s} on {s}\n", .{ plan.tag, up.branch });
    } else try say.out(c.io, "{s} under way at HEAD\n", .{plan.tag});
    try say.out(c.io, "gate it here", .{});
    for (gate_machines) |machine| try say.out(c.io, ", on {s}", .{machine.name});
    if (options.no_push) {
        try say.out(c.io, "\nhold it here, gated, for a later bay release to push\n", .{});
    } else {
        if (try hostedTarget(c, up)) |hosted| try say.out(c.io, "\nrun its release tier on GitHub ({s}) at {s}, waiting for it green, one hosted run at a time", .{ hosted.repository, (try candidateRef(c, plan.tag))["refs/heads/".len..] });
        try say.out(c.io, "\npush it to {s} and the tag {s} on {s} at once ({s}){s}\n", .{ up.onto, plan.tag, up.remote, up.url, if (up.set) ", which becomes the branch's upstream" else "" });
    }
    if (!options.no_push) if (github.slug(up.url)) |repository| {
        const unset = (try githubToken(c)).len == 0;
        const left: []const u8 = if (unset) " (GITHUB_TOKEN is not set and gh has no login: it would be left for a later run)" else "";
        try say.out(c.io, "publish its GitHub Release on {s}: the section as its notes, and the dist step's programs and their SHA256SUMS where the build has one{s}\n", .{ repository, left });
    };
}

/// `bay --workspace release`: the train. Members one at a time, each after the
/// members it ships and is developed with. Each is first pinned at the releases
/// of the members it depends on (`bay tidy`, §8), its normal dependencies'
/// re-pins named under `### Changed` and committed; then it is released when
/// its section has entries, or, with development pins alone, gated and pushed
/// with no tag. A member that fails stops the members that depend on it. Every member says
/// it is the family's (`"policy": "family"` in its ci/preflight.json), or nothing rides.
pub fn train(c: Context, options: Options) !u8 {
    const directories = try workspace.all(c.io, c.a, c.package) orelse try say.fail(c.io, "no {s} here or in any directory above", .{workspace.file_name});
    const cars = try each.train(c.io, c.a, directories);
    try familyPolicy(c, cars);
    if (options.dry_run) return trainPlan(c, cars);
    // One train in a workspace at a time: a second would gate the same members at once.
    var held = try lock.hold(c.io, c.a, c.environ, .train, (try workspace.fileOf(c.io, c.a, c.package)).?); // safe: `all` found it above
    defer held.release(c.io);
    const done = try c.a.alloc(Done, cars.len);
    const versions = try c.a.alloc(?std.SemanticVersion, cars.len);
    @memset(versions, null);
    for (cars, done, versions) |car, *outcome, *version| {
        outcome.* = for (car.needs) |need| {
            if (done[need] == .failed or done[need] == .skipped) {
                try say.note(c.io, "{s}: skipped, since {s} did not release", .{ car.name, cars[need].name });
                break .skipped;
            }
        } else try ride(c, cars, versions, car, .always, version);
    }
    // A development pin that would close a ring is left out of the order (a tool developed
    // with a release of a member that ships it): its member went first, and now pins the
    // release made after it, gated again and pushed.
    for (cars, done, versions) |car, *outcome, *version| {
        if (outcome.* == .failed or outcome.* == .skipped) continue;
        const again = try ride(c, cars, versions, car, .when_repinned, version);
        if (again == .failed or again == .released or again == .pushed) outcome.* = again;
    }
    var failed = false;
    for (cars, done, versions) |car, outcome, version| {
        if (version) |v| try say.note(c.io, "{s}: released {f}", .{ car.name, v }) else try say.note(c.io, "{s}: {t}", .{ car.name, outcome });
        if (outcome == .failed or outcome == .skipped) failed = true;
    }
    return if (failed) 1 else 0;
}

/// A train's members are the family's packages, and each says so itself: `"policy": "family"`
/// in its `ci/preflight.json`, the one key preflight's configuration and build both read. A
/// member without it would be gated with a stranger's defaults, unseen, so the train is refused
/// first, each such member named. bay never writes the key.
fn familyPolicy(c: Context, cars: []const each.Car) !void {
    var missing: std.ArrayList([]const u8) = .empty;
    var wrong: std.ArrayList([]const u8) = .empty;
    for (cars) |car| switch (try policyOf(c, car.directory)) {
        .family => {},
        .none => try missing.append(c.a, car.name),
        .other => |said| try wrong.append(c.a, try c.a.print("{s} (\"{s}\")", .{ car.name, said })),
        .unreadable => try wrong.append(c.a, try c.a.print("{s} (ci/preflight.json is no JSON bay can read)", .{car.name})),
    };
    if (wrong.items.len != 0)
        try say.fail(c.io, "the train releases the family's packages, and the one policy is \"family\": {s} name{s} another in ci/preflight.json", .{ try listed(c.a, wrong.items), if (wrong.items.len == 1) "s" else "" });
    if (missing.items.len != 0)
        try say.fail(c.io, "the train releases the family's packages, and {s} {s} no \"policy\": \"family\" in ci/preflight.json: add it to each, so preflight gates {s} as the family's", .{ try listed(c.a, missing.items), if (missing.items.len == 1) "has" else "have", if (missing.items.len == 1) "it" else "them" });
}

const Policy = union(enum) { family, none, other: []const u8, unreadable };

fn policyOf(c: Context, directory: []const u8) !Policy {
    var dir = try Io.Dir.cwd().openDir(c.io, directory, .{});
    defer dir.close(c.io);
    const text = if (intake.readFile(c.io, dir, "ci/preflight.json", c.a, .fromRaw(1 << 20))) |taken| taken.readForParse() else |err| switch (err) {
        error.FileNotFound => return .none,
        else => return err,
    };
    const Config = struct { policy: ?[]const u8 = null };
    const config = std.json.parseFromSliceLeaky(Config, c.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unreadable,
    };
    const policy = config.policy orelse return .none;
    return if (std.mem.eql(u8, policy, "family")) .family else .{ .other = policy };
}

const Done = enum { released, pushed, nothing, failed, skipped };

/// One member's turn: pinned at the releases before it, then released, or gated and pushed
/// with development pins alone. `.when_repinned` takes a turn only when the pins moved.
fn ride(c: Context, cars: []const each.Car, versions: []const ?std.SemanticVersion, car: each.Car, when: enum { always, when_repinned }, version: *?std.SemanticVersion) !Done {
    // Gated on what its release publishes: the members the train released are at their tags,
    // their trees; every other one builds at its pins, its tidy, its build and its gate alike.
    const done = try c.a.alloc(bool, cars.len);
    for (done, versions) |*released, v| released.* = v != null;
    const member = try pinnedFor(c, cars, car, done);
    const pins_moved = repinned(member) catch |err| switch (err) {
        error.Reported => return .failed,
        else => return err,
    };
    if (when == .when_repinned and !pins_moved) return .nothing;
    try say.note(c.io, "{s}: {s}", .{ car.name, car.directory });
    const now = try manifest.parse(c.a, try read(member, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{car.directory}));
    pinsFetchable(member, now, cars, done) catch |err| switch (err) {
        error.Reported => {
            if (pins_moved) _ = try must(member, &.{ "reset", "--quiet", "--hard", "HEAD^" });
            try say.note(c.io, "{s}: {s}nothing of it is gated or pushed", .{ car.name, if (pins_moved) "its re-pin is undone, and " else "" });
            return .failed;
        },
        else => return err,
    };
    // Built on the pins it moved to, here, before anything of it is gated or pushed: a compile
    // error the re-pin brings would otherwise first show in the hosted run of its release.
    if (pins_moved) bayIn(member, &.{ "dev", "check" }) catch |err| switch (err) {
        error.Reported => {
            _ = try must(member, &.{ "reset", "--quiet", "--hard", "HEAD^" });
            try say.note(c.io, "{s}: does not build on the pins the train moved it to (bay dev check): its re-pin is undone, and nothing of it is gated or pushed", .{car.name});
            return .failed;
        },
        else => return err,
    };
    return switch (releaseOne(member, .{ .push_unreleased = true }) catch |err| switch (err) {
        error.Reported => return .failed,
        else => return err,
    }) {
        .nothing => .nothing,
        .pushed => .pushed,
        .held => unreachable, // unreachable: a train pushes each release before the next pins it
        .released => |v| released: {
            version.* = v;
            break :released .released;
        },
    };
}

/// The member pinned at the releases of the members it depends on, as `bay tidy`
/// pins them in a workspace, which makes again what the build makes from the pins
/// (preflight's caller names the preflight it pins); its normal dependencies'
/// re-pins named in its CHANGELOG, and the change committed; whether anything moved,
/// a pin or a file made from the pins.
fn repinned(c: Context) !bool {
    const before_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    try bayIn(c, &.{"tidy"});
    return committed(c, before_text);
}

/// What moved since the manifest was `before_text`, its normal dependencies' re-pins named in
/// the CHANGELOG, committed; whether anything moved.
fn committed(c: Context, before_text: [:0]const u8) !bool {
    const after_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    // The tree was clean (a release refuses one that is not): what changed is the tidy's.
    if ((try must(c, &.{ "status", "--porcelain" })).len == 0) return false;
    const before = try manifest.parse(c.a, before_text);
    const after = try manifest.parse(c.a, after_text);
    const shipped = (try moved(c.a, before.normal, after.normal)).items;
    const developed = (try moved(c.a, before.dev, after.dev)).items;
    if (shipped.len != 0) {
        const log = try read(c, "CHANGELOG.md") orelse try say.fail(c.io, "no CHANGELOG.md: a re-pin is named in it", .{});
        const entry = try c.a.print("- Pins {s}.", .{try listed(c.a, shipped)});
        try write(c, "CHANGELOG.md", changelog.addEntry(c.a, log, .changed, entry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try say.fail(c.io, "CHANGELOG.md has no `## [Unreleased]` section to name the re-pins in", .{}),
        });
    }
    _ = try must(c, &.{ "add", "--all" });
    const all = try std.mem.concat(c.a, []const u8, &.{ shipped, developed });
    const message = if (all.len == 0) "What the build makes from the pins, made again" else try c.a.print("Pin {s}", .{try listed(c.a, all)});
    _ = try must(c, &.{ "commit", "--quiet", "-m", message });
    return true;
}

/// `bay pin <dependency> <version>`: one package moved onto a release of one of its
/// dependencies, as the train moves a member: pinned at the tag `v<version>` and tidied, the
/// re-pin named under `### Changed` and committed, then gated and pushed. It is released when
/// its [Unreleased] section held entries before the re-pin; a re-pin alone is pushed with no
/// tag, its entry waiting for the next release. The refusals of a release come first, before
/// anything is written.
pub fn pinAtRelease(c: Context, name: []const u8, version_text: []const u8, options: Options) !Outcome {
    try alone(c);
    _ = try releasable(c);
    const bare = if (std.mem.startsWith(u8, version_text, "v")) version_text[1..] else version_text;
    const version = changelog.parseVersion(bare) orelse try say.fail(c.io, "{s} is no version: a pin moves to a release, major.minor.patch", .{version_text});
    const tag = try tagName(c, version);
    const before_text = try read(c, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{c.package});
    const parsed = manifest.parse(c.a, before_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidManifest => try say.fail(c.io, "build.zig.zon is not a manifest bay can read", .{}),
    };
    const dependency = found: for ([_][]const manifest.Dependency{ parsed.normal, parsed.dev }) |list| {
        for (list) |one| if (std.mem.eql(u8, one.name, name)) break :found one;
    } else try say.fail(c.io, "{s} is not a dependency of {s}", .{ name, parsed.name });
    const url = switch (dependency.source) {
        .remote => |remote| remote.url,
        .path => |path| try say.fail(c.io, "{s} is the directory {s}, which has no releases to pin", .{ name, path }),
    };
    if (dependency.prebuilt != null) try say.fail(c.io, "{s} is a prebuilt: bay update {s} <url> moves it to another archive", .{ name, name });
    const log = try read(c, "CHANGELOG.md") orelse try say.fail(c.io, "no CHANGELOG.md: a re-pin is named in it", .{});
    const held_entries = !(try section(c, log)).empty();
    if (options.dry_run) {
        try say.out(c.io, "pin {s} at {s} and tidy; name the re-pin under ### Changed and commit it; then {s}\n", .{ name, tag, if (held_entries) "release it, as bay release does" else "gate it and push it with no tag, the entry waiting for the next release" });
        return .nothing;
    }
    const source = try c.a.print("{s}#{s}", .{ url[0 .. std.mem.findAny(u8, url, "?#") orelse url.len], tag });
    // A pin bay could not move leaves the tree as it was.
    const changed = pinAt(c, name, source, before_text) catch |err| {
        _ = try git(c, &.{ "checkout", "--quiet", "--", "." });
        _ = try git(c, &.{ "clean", "--quiet", "-fd" });
        return err;
    };
    if (!changed) {
        try say.note(c.io, "{s} is pinned at {s} already: nothing moved", .{ name, tag });
        return .nothing;
    }
    return releaseOne(c, .{ .push_unreleased = true, .no_tag = !held_entries });
}

fn pinAt(c: Context, name: []const u8, source: []const u8, before_text: [:0]const u8) !bool {
    try bayIn(c, &.{ "add", "--no-tidy", "--name", name, source });
    try bayIn(c, &.{"tidy"});
    return committed(c, before_text);
}

/// What `bay <args>` writes to its output, run in the package; a failure says so.
fn bayOut(c: Context, args: []const []const u8) ![]const u8 {
    const bay = c.environ.get("BAY").?; // safe: main sets BAY before any command
    const argv = try std.mem.concat(c.a, []const u8, &.{ &.{bay}, args });
    const result = intake.run(c.a, c.io, .{ .argv = argv, .cwd = .{ .path = c.package }, .environ_map = c.environ }) catch |err|
        try say.fail(c.io, "could not run bay {s}: {t}", .{ args[0], err });
    if (result.term != .exited or result.term.exited != 0) try say.fail(c.io, "bay {s} failed in {s}: {s}", .{ args[0], c.package, std.mem.trim(u8, result.stderr.readForParse(), " \r\n") });
    return result.stdout.readForParse();
}

/// This bay run in the package with `args`; a failure stops the member.
fn bayIn(c: Context, args: []const []const u8) !void {
    const bay = c.environ.get("BAY").?; // safe: main sets BAY before any command
    const argv = try std.mem.concat(c.a, []const u8, &.{ &.{bay}, args });
    var child = std.process.spawn(c.io, .{ .argv = argv, .cwd = .{ .path = c.package }, .environ_map = c.environ }) catch |err|
        try say.fail(c.io, "could not run bay {s}: {t}", .{ args[0], err });
    switch (try child.wait(c.io)) {
        .exited => |code| if (code != 0) try say.fail(c.io, "bay {s} failed in {s}", .{ args[0], c.package }),
        else => try say.fail(c.io, "bay {s} failed in {s}", .{ args[0], c.package }),
    }
}

/// What a train would do, member by member, changing nothing: each member pinned at the
/// releases before it, those there now and those the train makes; the release its section
/// and its moved pins make; and the development pins the closing pass moves after it.
fn trainPlan(c: Context, cars: []const each.Car) !u8 {
    const versions = try c.a.alloc(?std.SemanticVersion, cars.len);
    @memset(versions, null);
    // The version each member stands at before the train: its release, when it makes none.
    const currents = try c.a.alloc(std.SemanticVersion, cars.len);
    // Where each car is gated, as `ride` gates it.
    var gated: std.Io.Writer.Allocating = .init(c.a);
    try gated.writer.writeAll("here");
    for (try machines.load(c.io, c.a, c.environ)) |machine| try gated.writer.print(", on {s}", .{machine.name});
    const developed_with = try c.a.alloc([]const manifest.Dependency, cars.len);
    for (cars, versions, developed_with, 1..) |car, *version, *dev, number| {
        // In its turn, the members the plan releases before it are at their tags, their trees;
        // the rest build at its pins (`pinnedFor`), as the run builds them.
        const done_before = try c.a.alloc(bool, cars.len);
        for (done_before, versions, 0..) |*released, v, index| released.* = index < number - 1 and v != null;
        const planned = try pinnedFor(c, cars, car, done_before);
        const member = planned;
        const before_text = try read(member, "build.zig.zon") orelse try say.fail(c.io, "no build.zig.zon in {s}", .{car.directory});
        // Tidied as the train tidies it, in memory: the dry run writes nothing.
        const zig = try toolchain.forPackage(c.io, c.a, c.environ, car.directory);
        const tidied = tidying.tidied(.{ .io = c.io, .a = c.a, .environ = planned.environ, .zig = zig, .package = car.directory }, before_text) catch |err| switch (err) {
            error.Reported => try say.fail(c.io, "{s}: bay tidy fails there, so the train would stop at it", .{car.name}),
            else => return err,
        };
        const after_text = tidied.text;
        const before = try manifest.parse(c.a, before_text);
        const after = try manifest.parse(c.a, after_text);
        dev.* = after.dev;
        var shipped = try moved(c.a, before.normal, after.normal);
        var developed = try moved(c.a, before.dev, after.dev);
        // The members before it that the train releases: pinned at those releases.
        for (car.needs) |need| if (versions[need]) |v| {
            const name = cars[need].name;
            const pin = try c.a.print("{s} {f}", .{ name, v });
            if (pinned(after.normal, name)) try put(c.a, &shipped, name, pin) else if (pinned(after.dev, name)) try put(c.a, &developed, name, pin);
        };
        const log = try read(member, "CHANGELOG.md") orelse try say.fail(c.io, "{s}: no CHANGELOG.md", .{car.name});
        const unreleased = try section(member, log);
        const change = if (shipped.items.len != 0) unreleased.change().max(.fix) else unreleased.change();
        const current = changelog.parseVersion(before.version) orelse try say.fail(c.io, "{s}: .version \"{s}\" is not major.minor.patch", .{ car.name, before.version });
        currents[number - 1] = current;
        // The version the run would tag, by the rule the run follows, from what it reads.
        const history = try historyOf(member, log, current, try remoteTags(member, (try upstream(member)).remote));
        try say.out(c.io, "{d}. {s} {f}", .{ number, car.name, current });
        if (change != .none) {
            version.* = nextVersion(current, change, history);
            try say.out(c.io, " -> {f} ({t}{s}):", .{ version.*.?, change, if (history.first()) ", its first release" else "" });
            if (!unreleased.empty()) try say.out(c.io, " its [Unreleased] section", .{});
            if (shipped.items.len != 0) try say.out(c.io, "{s} pins {s}", .{ if (unreleased.empty()) "" else ", and", try listed(c.a, shipped.items) });
        } else try say.out(c.io, ": nothing to release", .{});
        if (developed.items.len != 0) try say.out(c.io, "; develops with {s}{s}", .{ try listed(c.a, developed.items), if (change == .none) ", gated and pushed with no tag" else "" });
        try say.out(c.io, "\n", .{});
        // What the train runs in it, run as a dry run (its tidy, and the `generate` step after),
        // then the steps it takes, so a clash shows before the first car moves.
        bayIn(member, &.{ "tidy", "--dry-run" }) catch |err| switch (err) {
            error.Reported => try say.fail(c.io, "{s}: bay tidy fails there, so the train would stop at it", .{car.name}),
            else => return err,
        };
        // Gated as the run gates it: the members not released before it at its pins, whose
        // development pins must name what their origins hold.
        if (version.* != null or developed.items.len != 0) pinsFetchable(planned, after, cars, done_before) catch |err| switch (err) {
            error.Reported => try say.fail(c.io, "{s}: the train would stop at it, at its pins, before it is gated", .{car.name}),
            else => return err,
        };
        // The pins the run refuses, as it reads them: tidied, and every member before this one
        // at its release, the train's or the one there already, wherever a member's tree pins
        // it: the run reads those trees after their re-pins.
        if (version.* != null) {
            const earlier_ones = try c.a.alloc(Released, number - 1);
            for (earlier_ones, cars[0 .. number - 1], versions[0 .. number - 1], currents[0 .. number - 1]) |*at, earlier, released, standing| at.* = .{ .name = earlier.name, .directory = earlier.directory, .version = released orelse standing };
            pinsAreReleases(member, after, earlier_ones) catch |err| switch (err) {
                error.Reported => try say.fail(c.io, "{s}: the train would stop at it, at its pins, before it releases", .{car.name}),
                else => return err,
            };
        }
        if (version.*) |v| {
            try say.out(c.io, "   then: the re-pin committed and built here (bay dev check), if a pin moves; v{f} written from its section and committed; gated {s}; the branch and the tag pushed\n", .{ v, gated.written() });
        } else if (developed.items.len != 0) {
            try say.out(c.io, "   then: the re-pin committed and built here (bay dev check); gated {s}; the branch pushed, with no tag\n", .{gated.written()});
        } else try say.out(c.io, "   then: nothing\n", .{});
    }
    // The closing pass: a development pin left out of the order, on a member after it.
    for (cars, developed_with) |car, dev| for (cars, versions) |later, version| {
        const v = version orelse continue;
        if (!pinned(dev, later.name) or std.mem.eql(u8, later.name, car.name)) continue;
        for (car.needs) |need| {
            if (std.mem.eql(u8, cars[need].name, later.name)) break;
        } else try say.out(c.io, "then {s} develops with {s} {f}, gated and pushed with no tag\n", .{ car.name, later.name, v });
    };
    return 0;
}

fn pinned(dependencies: []const manifest.Dependency, name: []const u8) bool {
    for (dependencies) |dependency| if (std.mem.eql(u8, dependency.name, name)) return true;
    return false;
}

/// `pin` in `list` in place of what names `name`, or added.
fn put(a: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8, pin: []const u8) !void {
    for (list.items) |*item| if (std.mem.startsWith(u8, item.*, name) and item.*.len > name.len and item.*[name.len] == ' ') {
        item.* = pin;
        return;
    };
    try list.append(a, pin);
}

/// `name version` of each dependency `after` pins at another hash than `before`.
fn moved(a: std.mem.Allocator, before: []const manifest.Dependency, after: []const manifest.Dependency) !std.ArrayList([]const u8) {
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
    return out;
}

/// `YYYY-MM-DD` of the current UTC day, which a release is dated with.
fn today(a: std.mem.Allocator, io: Io) ![]const u8 {
    const now = try aegis.units.Instant(.real, .second, i64).fromTimestamp(Io.Clock.real.now(io), .down);
    // The epoch's calendar counts seconds from 1970 up: a clock set before it reads as 1970.
    const seconds: u64 = @intCast(@max(0, now.raw())); // safe: clamped to zero and up
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

/// "a", "a and b", "a, b and c".
fn listed(a: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    aegis.assert.invariant(items.len != 0, "a re-pin names what moved");
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

test "a gated commit is recorded per repository and tag in bay's data directory, and forgotten once pushed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const here = try gatedPath(a, data, "/work/one/.git", "v0.2.0");
    const there = try gatedPath(a, data, "/work/two/.git", "v0.2.0");
    try std.testing.expect(!std.mem.eql(u8, here, there));
    try std.testing.expect(std.mem.startsWith(u8, here, data));
    try std.testing.expect(try recorded(std.testing.io, a, here) == null);
    try record(std.testing.io, a, here, "0123456789abcdef0123456789abcdef01234567", null);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", (try recorded(std.testing.io, a, here)).?.commit);
    try std.testing.expect((try recorded(std.testing.io, a, here)).?.hosted == null);
    // The hosted run that passed it is kept beside it.
    try record(std.testing.io, a, here, "0123456789abcdef0123456789abcdef01234567", "https://github.com/o/r/actions/runs/7");
    try std.testing.expectEqualStrings("https://github.com/o/r/actions/runs/7", (try recorded(std.testing.io, a, here)).?.hosted.?);
    // Another repository's gate says nothing of this one.
    try std.testing.expect(try recorded(std.testing.io, a, there) == null);
    try forget(std.testing.io, here);
    try forget(std.testing.io, here);
    try std.testing.expect(try recorded(std.testing.io, a, here) == null);
}
