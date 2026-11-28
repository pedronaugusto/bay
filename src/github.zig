//! GitHub's REST API as bay uses it: the release a version's tag is published
//! as, with its notes and the programs the package ships. GITHUB_TOKEN
//! authorizes it; GITHUB_API_URL, as GitHub's own runners set it, names another
//! server (GitHub Enterprise, or a test's).
const std = @import("std");
const Io = std.Io;
const download = @import("download.zig");

pub const default_api = "https://api.github.com";

/// The `owner/repo` a remote on github.com names: `git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r`, `https://github.com/o/r`. Null for any other
/// host or shape.
pub fn slug(url: []const u8) ?[]const u8 {
    const path = for ([_][]const u8{ "git@github.com:", "ssh://git@github.com/", "git+ssh://git@github.com/", "https://github.com/", "git+https://github.com/" }) |prefix| {
        if (std.mem.startsWith(u8, url, prefix)) break url[prefix.len..];
    } else return null;
    const bare = std.mem.trimEnd(u8, path[0 .. std.mem.findAny(u8, path, "?#") orelse path.len], "/");
    const named = if (std.mem.endsWith(u8, bare, ".git")) bare[0 .. bare.len - ".git".len] else bare;
    const slash = std.mem.findScalar(u8, named, '/') orelse return null;
    if (slash == 0 or slash == named.len - 1 or std.mem.findScalarPos(u8, named, slash + 1, '/') != null) return null;
    return named;
}

test "a GitHub remote names its repository in each form; another host or a deeper path names none" {
    for ([_][]const u8{ "git@github.com:o/r.git", "git@github.com:o/r", "ssh://git@github.com/o/r", "https://github.com/o/r.git", "git+https://github.com/o/r?ref=v1#abc" }) |url| try std.testing.expectEqualStrings("o/r", slug(url).?);
    for ([_][]const u8{ "git@gitlab.com:o/r.git", "https://github.com/o", "https://github.com/o/r/x", "git@github.com:/r" }) |url| try std.testing.expect(slug(url) == null);
}

/// A program a release carries, under the name a download asks for.
pub const Asset = struct { name: []const u8, bytes: []const u8 };

/// The `SHA256SUMS` a release carries beside its programs: each program's
/// SHA-256 and its name, as `sha256sum` writes and `sha256sum -c` checks,
/// sorted by name.
pub fn sums(a: std.mem.Allocator, assets: []const Asset) ![]const u8 {
    const sorted = try a.dupe(Asset, assets);
    defer a.free(sorted);
    std.mem.sort(Asset, sorted, {}, struct {
        fn less(_: void, x: Asset, y: Asset) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    var out: Io.Writer.Allocating = .init(a);
    for (sorted) |asset| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(asset.bytes, &digest, .{});
        try out.writer.print("{s}  {s}\n", .{ &std.fmt.bytesToHex(digest, .lower), asset.name });
    }
    return out.toOwnedSlice();
}

test "SHA256SUMS lists each program's digest and name, sorted, as sha256sum writes them" {
    const text = try sums(std.testing.allocator, &.{ .{ .name = "b", .bytes = "" }, .{ .name = "a", .bytes = "abc" } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a\n" ++
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  b\n",
        text,
    );
}

pub const Api = struct {
    client: *std.http.Client,
    a: std.mem.Allocator,
    /// The API's base, `https://api.github.com` or GITHUB_API_URL.
    base: []const u8,
    token: []const u8,
    /// How long a request waits for all of its answer (`download.within`), then unanswered.
    deadline: Io.Duration = download.answer_deadline,
};

/// What bay reads of a release GitHub holds (`release` in GitHub's schema, where none of these
/// is nullable), as `GET /repos/{owner}/{repo}/releases/tags/{tag}` and `POST .../releases`
/// answer it. Every field bay does not read is left unread.
pub const Release = struct {
    id: u64,
    upload_url: []const u8,
    html_url: []const u8 = "",
    assets: []const struct { name: []const u8 } = &.{},
    /// The notes; nullable.
    body: ?[]const u8 = null,
};

/// A release as GitHub answers it.
pub fn readRelease(a: std.mem.Allocator, body: []const u8) !Release {
    return std.json.parseFromSliceLeaky(Release, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub const Error = error{ OutOfMemory, GitHub };

/// What went wrong with a request, for the caller to say.
pub const Problem = struct { what: []const u8 = "" };

/// The release for `tag` in `repository`, made with `notes` where GitHub holds
/// none, and given each of `assets` it does not hold yet: a run that stopped
/// part way is finished, never made twice. Returns the release's page.
pub fn publish(api: Api, repository: []const u8, tag: []const u8, notes: []const u8, assets: []const Asset, problem: *Problem) Error![]const u8 {
    const a = api.a;
    const at_tag = try a.print("{s}/repos/{s}/releases/tags/{s}", .{ api.base, repository, tag });
    const release: Release = found: {
        const held = try request(api, .GET, at_tag, null, "application/json", problem);
        if (held.status == .ok) break :found try parse(a, held.body, at_tag, problem);
        if (held.status != .not_found) return fail(a, problem, "{s} answered {d}: {s}", .{ at_tag, @backingInt(held.status), held.body });
        var body: Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(.{ .tag_name = tag, .name = tag, .body = notes }, .{}, &body.writer) catch return error.OutOfMemory;
        const releases = try a.print("{s}/repos/{s}/releases", .{ api.base, repository });
        const made = try request(api, .POST, releases, body.written(), "application/json", problem);
        if (made.status != .created) return fail(a, problem, "{s} answered {d}: {s}", .{ releases, @backingInt(made.status), made.body });
        break :found try parse(a, made.body, releases, problem);
    };
    // `upload_url` is a URI template: the part before `{?name,label}` takes the name.
    const upload = release.upload_url[0 .. std.mem.findScalar(u8, release.upload_url, '{') orelse release.upload_url.len];
    for (assets) |asset| {
        const held = for (release.assets) |one| {
            if (std.mem.eql(u8, one.name, asset.name)) break true;
        } else false;
        if (held) continue;
        if (!safeName(asset.name)) return fail(a, problem, "{s} is no name a release asset can take", .{asset.name});
        const url = try a.print("{s}?name={s}", .{ upload, asset.name });
        const sent = try request(api, .POST, url, asset.bytes, "application/octet-stream", problem);
        if (sent.status != .created) return fail(a, problem, "uploading {s} answered {d}: {s}", .{ asset.name, @backingInt(sent.status), sent.body });
    }
    return release.html_url;
}

/// A name of letters, digits, `.`, `-` and `_`: one that needs no escaping in a
/// query, as `zig build dist`'s programs and SHA256SUMS are.
fn safeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn parse(a: std.mem.Allocator, body: []const u8, url: []const u8, problem: *Problem) Error!Release {
    return readRelease(a, body) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(a, problem, "{s} answered a release bay cannot read ({t})", .{ url, err }),
    };
}

fn fail(a: std.mem.Allocator, problem: *Problem, comptime format: []const u8, args: anytype) Error {
    problem.what = try a.print(format, args);
    return error.GitHub;
}

const Answer = struct { status: std.http.Status, body: []const u8 };

/// One request with the token and GitHub's media type; the answer's body is
/// kept up to 1 MiB, which is all a release's JSON or an error says.
fn request(api: Api, method: std.http.Method, url: []const u8, payload: ?[]const u8, content_type: []const u8, problem: *Problem) Error!Answer {
    const a = api.a;
    var body: Io.Writer.Allocating = .init(a);
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/vnd.github+json" },
        .{ .name = "x-github-api-version", .value = "2022-11-28" },
    };
    // A payload (a release's program) adds a second for each 64 KiB it sends.
    const deadline: Io.Duration = .fromNanoseconds(api.deadline.nanoseconds + @as(i96, @intCast(if (payload) |sent| sent.len / (64 << 10) else 0)) * std.time.ns_per_s);
    // Given `deadline` for all of its answer: a connection gone silent is a look unanswered,
    // which the caller looks again after, where it would wait on it for good.
    const result = download.within(api.client.io, deadline, std.http.Client.fetch, .{
        api.client,
        .{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            // With no token, GitHub answers what it shows anyone: a public repository's runs and releases.
            .headers = .{ .content_type = .{ .override = content_type }, .user_agent = .{ .override = "bay" }, .authorization = if (api.token.len == 0) .omit else .{ .override = try a.print("Bearer {s}", .{api.token}) } },
            .extra_headers = &headers,
            // A redirect is answered, not followed: the token goes only to the host asked.
            .redirect_behavior = .unhandled,
            .response_writer = &body.writer,
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return fail(a, problem, "{s} did not answer within {f}", .{ url, download.Spoken{ .duration = deadline } }),
        else => return fail(a, problem, "could not reach {s}: {t}", .{ url, err }),
    };
    const written = body.written();
    return .{ .status = result.status, .body = written[0..@min(written.len, 1 << 20)] };
}

/// A workflow run as bay reads it: which commit it ran on, where it stands, and how it ended.
/// Each field GitHub's schema (`workflow-run`) allows to be null is optional here, and every
/// field bay does not read is left unread: a run GitHub answers is never one bay cannot read.
pub const Run = struct {
    id: u64,
    head_sha: []const u8,
    /// The branch it ran on: a release's candidate, `release/vX.Y.Z`. Nullable.
    head_branch: ?[]const u8 = null,
    /// `queued`, `in_progress`, `completed` (and GitHub's waiting states). Nullable.
    status: ?[]const u8 = null,
    /// Set once completed: `success`, `failure`, `cancelled`, `timed_out`, and the rest. Nullable.
    conclusion: ?[]const u8 = null,
    html_url: []const u8 = "",
    created_at: []const u8 = "",
    /// Which attempt of the run this is: one, then one more for each re-run.
    run_attempt: u32 = 1,

    pub fn completed(ran: Run) bool {
        return std.mem.eql(u8, ran.status orelse return false, "completed");
    }
};

/// One job of a run. GitHub's schema (`job`) allows `conclusion` and `runner_id` to be null:
/// a job not yet ended has no conclusion, and a skipped or queued one no runner (`null`), as a
/// job cancelled before any runner took it has none (`0`).
pub const Job = struct {
    name: []const u8,
    status: []const u8,
    conclusion: ?[]const u8 = null,
    /// The runner that took the job; null or zero for one no runner took.
    runner_id: ?u64 = null,
    steps: []const Step = &.{},
    /// The labels its `runs-on` asks a runner for (`macos-latest`, `ubuntu-24.04`, …).
    labels: []const []const u8 = &.{},

    pub const Step = struct { name: []const u8 = "" };

    /// Holding a runner, or waiting for one: queued, waiting or in progress, not completed.
    pub fn active(job: Job) bool {
        return !std.mem.eql(u8, job.status, "completed");
    }

    /// Asks for a macOS runner, which the account has fewer of.
    pub fn onMacos(job: Job) bool {
        for (job.labels) |label| if (std.mem.startsWith(u8, label, "macos")) return true;
        return false;
    }

    /// Passed: ended green, or skipped.
    pub fn passed(job: Job) bool {
        const conclusion = job.conclusion orelse return false;
        return std.mem.eql(u8, conclusion, "success") or std.mem.eql(u8, conclusion, "skipped");
    }

    /// Cancelled before any runner took it: GitHub found none (its annotation, "The job was not
    /// acquired by Runner of type hosted even after multiple attempts"), so the job never ran.
    pub fn unacquired(job: Job) bool {
        const conclusion = job.conclusion orelse return false;
        return std.mem.eql(u8, conclusion, "cancelled") and (job.runner_id orelse 0) == 0 and job.steps.len == 0;
    }

    /// preflight's `runners` job, which fails a run where a job had no runner ("Every job had a
    /// runner"): red only for what `unacquired` names.
    pub fn runnersCheck(job: Job) bool {
        return std.mem.eql(u8, job.name, "runners") or std.mem.endsWith(u8, job.name, "/ runners");
    }
};

/// Where a run stands for a release's hosted gate.
pub const Verdict = enum {
    /// Not completed yet: looked at again.
    waiting,
    green,
    /// Failed only because GitHub gave jobs no runner (and preflight's `runners` job said so):
    /// nothing failed that ran, so those jobs are run again.
    unacquired,
    /// Anything else completed: failed, cancelled by a person, timed out.
    red,
};

/// The verdict on run `ran`, its jobs `job_list`. A run a person cancelled ends "cancelled", never
/// "failure", so it is red, never run again.
pub fn verdict(ran: Run, job_list: []const Job) Verdict {
    if (!ran.completed()) return .waiting;
    const conclusion = ran.conclusion orelse return .red;
    if (std.mem.eql(u8, conclusion, "success")) return .green;
    if (!std.mem.eql(u8, conclusion, "failure")) return .red;
    var any = false;
    for (job_list) |job| {
        if (job.passed()) continue;
        if (job.unacquired()) {
            any = true;
        } else if (job.runnersCheck() and job.conclusion != null and std.mem.eql(u8, job.conclusion.?, "failure")) {
            continue;
        } else return .red;
    }
    return if (any) .unacquired else .red;
}

/// A run as GitHub's `GET /repos/{owner}/{repo}/actions/runs/{id}` answers it.
pub fn readRun(a: std.mem.Allocator, body: []const u8) !Run {
    return std.json.parseFromSliceLeaky(Run, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// The jobs as `GET /repos/{owner}/{repo}/actions/runs/{id}/jobs` answers them.
pub fn readJobs(a: std.mem.Allocator, body: []const u8) ![]const Job {
    const Listing = struct { jobs: []const Job = &.{} };
    return (try std.json.parseFromSliceLeaky(Listing, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).jobs;
}

/// The runs as `GET /repos/{owner}/{repo}/actions/runs` answers them.
pub fn readRuns(a: std.mem.Allocator, body: []const u8) ![]const Run {
    const Listing = struct { workflow_runs: []const Run = &.{} };
    return (try std.json.parseFromSliceLeaky(Listing, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).workflow_runs;
}

/// Starts `workflow` (its file name, `ci.yml`) on `ref` with `inputs` (a JSON object), as its
/// `workflow_dispatch` takes them. GitHub answers no run: `newestRun` finds it.
pub fn dispatch(api: Api, repository: []const u8, workflow: []const u8, ref: []const u8, inputs: []const u8, problem: *Problem) Error!void {
    const a = api.a;
    const url = try a.print("{s}/repos/{s}/actions/workflows/{s}/dispatches", .{ api.base, repository, workflow });
    var ref_json: Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(ref, .{}, &ref_json.writer) catch return error.OutOfMemory;
    const body = try a.print("{{\"ref\":{s},\"inputs\":{s}}}", .{ ref_json.written(), inputs });
    const sent = try request(api, .POST, url, body, "application/json", problem);
    if (sent.status != .no_content) return fail(a, problem, "{s} answered {d}: {s}", .{ url, @backingInt(sent.status), sent.body });
}

/// The newest run dispatched on `branch` at `head_sha` created at or after `since` (GitHub's
/// `YYYY-MM-DDTHH:MM:SSZ`, which orders as text), or null while GitHub shows none yet.
pub fn newestRun(api: Api, repository: []const u8, branch: []const u8, head_sha: []const u8, since: []const u8, problem: *Problem) Error!?Run {
    const a = api.a;
    var encoded: Io.Writer.Allocating = .init(a);
    for (branch) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '~' => encoded.writer.writeByte(byte) catch return error.OutOfMemory,
        else => encoded.writer.print("%{X:0>2}", .{byte}) catch return error.OutOfMemory,
    };
    const url = try a.print("{s}/repos/{s}/actions/runs?branch={s}&event=workflow_dispatch&per_page=20", .{ api.base, repository, encoded.written() });
    const answer = try request(api, .GET, url, null, "application/json", problem);
    if (answer.status != .ok) return fail(a, problem, "{s} answered {d}: {s}", .{ url, @backingInt(answer.status), answer.body });
    const listed = readRuns(a, answer.body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, problem, "{s} answered runs bay cannot read ({t})", .{ url, err }),
    };
    var newest: ?Run = null;
    for (listed) |one| {
        if (!std.mem.eql(u8, one.head_sha, head_sha)) continue;
        if (std.mem.order(u8, one.created_at, since) == .lt) continue;
        if (newest == null or one.id > newest.?.id) newest = one;
    }
    return newest;
}

/// The run `id` as it stands.
pub fn run(api: Api, repository: []const u8, id: u64, problem: *Problem) Error!Run {
    const a = api.a;
    const url = try a.print("{s}/repos/{s}/actions/runs/{d}", .{ api.base, repository, id });
    const answer = try request(api, .GET, url, null, "application/json", problem);
    if (answer.status != .ok) return fail(a, problem, "{s} answered {d}: {s}", .{ url, @backingInt(answer.status), answer.body });
    return readRun(a, answer.body) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(a, problem, "{s} answered a run bay cannot read ({t})", .{ url, err }),
    };
}

/// The jobs of run `id`, up to the first hundred: a release tier has a few dozen.
pub fn jobs(api: Api, repository: []const u8, id: u64, problem: *Problem) Error![]const Job {
    const a = api.a;
    const url = try a.print("{s}/repos/{s}/actions/runs/{d}/jobs?per_page=100", .{ api.base, repository, id });
    const answer = try request(api, .GET, url, null, "application/json", problem);
    if (answer.status != .ok) return fail(a, problem, "{s} answered {d}: {s}", .{ url, @backingInt(answer.status), answer.body });
    return readJobs(a, answer.body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, problem, "{s} answered jobs bay cannot read ({t})", .{ url, err }),
    };
}

/// Runs again the jobs of run `id` that did not pass, and the jobs that need them; those that
/// passed keep their result. GitHub makes a new attempt of the same run.
pub fn rerunFailed(api: Api, repository: []const u8, id: u64, problem: *Problem) Error!void {
    const a = api.a;
    const url = try a.print("{s}/repos/{s}/actions/runs/{d}/rerun-failed-jobs", .{ api.base, repository, id });
    const answer = try request(api, .POST, url, "", "application/json", problem);
    if (answer.status != .created) return fail(a, problem, "{s} answered {d}: {s}", .{ url, @backingInt(answer.status), answer.body });
}

/// The notes of the GitHub Release published at `tag`, or null where there is none.
pub fn releaseNotes(api: Api, repository: []const u8, tag: []const u8, problem: *Problem) Error!?[]const u8 {
    const a = api.a;
    const url = try a.print("{s}/repos/{s}/releases/tags/{s}", .{ api.base, repository, tag });
    const answer = try request(api, .GET, url, null, "application/json", problem);
    if (answer.status == .not_found) return null;
    if (answer.status != .ok) return fail(a, problem, "{s} answered {d}: {s}", .{ url, @backingInt(answer.status), answer.body });
    const Held = struct { body: ?[]const u8 = null };
    const held = std.json.parseFromSliceLeaky(Held, a, answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, problem, "{s} answered a release bay cannot read", .{url}),
    };
    return held.body orelse "";
}

test "a look at GitHub whose connection goes silent is unanswered at its deadline, where it waited for good" {
    const io = std.testing.io;
    var silent: download.Silent = try .init(io);
    defer silent.deinit(io);
    const thread = try std.Thread.spawn(.{}, download.Silent.serve, .{ &silent, io });
    // A request given up leaves its connection to the arena, as bay's own allocator holds it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var client: std.http.Client = .{ .allocator = a, .io = io };
    const api: Api = .{ .client = &client, .a = a, .base = try silent.url(a), .token = "t", .deadline = .fromMilliseconds(200) };
    var problem: Problem = .{};
    const looked = newestRun(api, "o/r", "release/v0.1.0", "1111111111111111111111111111111111111111", "2026-01-01T00:00:00Z", &problem);
    silent.stop(io);
    thread.join();
    try std.testing.expectError(error.GitHub, looked);
    try std.testing.expect(std.mem.find(u8, problem.what, "did not answer within 200 ms") != null);
}
