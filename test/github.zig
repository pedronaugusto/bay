//! bay's readers of GitHub's REST answers, run on answers GitHub gave, kept under `github/` as
//! `gh api` printed them: each is read, and each run reaches the verdict a release's hosted gate
//! acts on. A field GitHub's schema allows to be null is null in some of them (a skipped job's
//! `runner_id`, a queued job's `conclusion`), which a hand-written answer left out.
const std = @import("std");
const github = @import("github");

fn verdictOf(run_json: []const u8, jobs_json: []const u8) !github.Verdict {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    return github.verdict(try github.readRun(a, run_json), try github.readJobs(a, jobs_json));
}

test "a release tier GitHub ran green is green: preflight's, 50 jobs, a skipped one with no runner among them" {
    const jobs = @embedFile("github/preflight-release-green.jobs.json");
    try std.testing.expectEqual(github.Verdict.green, try verdictOf(@embedFile("github/preflight-release-green.run.json"), jobs));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const read = try github.readJobs(arena.allocator(), jobs);
    try std.testing.expectEqual(50, read.len);
}

test "a run a person cancelled is red, never run again: glint's release tier, skipped and cancelled jobs with no runner" {
    try std.testing.expectEqual(github.Verdict.red, try verdictOf(@embedFile("github/glint-release-cancelled.run.json"), @embedFile("github/glint-release-cancelled.jobs.json")));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jobs = try github.readJobs(a, @embedFile("github/glint-release-cancelled.jobs.json"));
    // The answer bay could not read: "gate / tier", skipped, has `"runner_id": null`.
    const tier = for (jobs) |job| {
        if (std.mem.eql(u8, job.name, "gate / tier")) break job;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u64, null), tier.runner_id);
    try std.testing.expect(tier.passed());
    const run = try github.readRun(a, @embedFile("github/glint-release-cancelled.run.json"));
    try std.testing.expectEqualStrings("release/v0.8.0", run.head_branch.?);
}

test "a run that failed only for a job GitHub gave no runner is run again, preflight's runners job red for it" {
    try std.testing.expectEqual(github.Verdict.unacquired, try verdictOf(@embedFile("github/glint-push-unacquired.run.json"), @embedFile("github/glint-push-unacquired.jobs.json")));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const jobs = try github.readJobs(arena.allocator(), @embedFile("github/glint-push-unacquired.jobs.json"));
    var unacquired: usize = 0;
    for (jobs) |job| if (job.unacquired()) {
        unacquired += 1;
        try std.testing.expectEqualStrings("gate / test (macos-latest, Debug)", job.name);
    };
    try std.testing.expectEqual(1, unacquired);
}

test "a run still running is waited on, its queued jobs with no runner and no conclusion" {
    try std.testing.expectEqual(github.Verdict.waiting, try verdictOf(@embedFile("github/bay-push-in-progress.run.json"), @embedFile("github/bay-push-in-progress.jobs.json")));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A release tier's jobs as GitHub listed them mid-run: queued, in progress and ended.
    const jobs = try github.readJobs(a, @embedFile("github/glint-release-in-progress.jobs.json"));
    var queued: usize = 0;
    for (jobs) |job| if (std.mem.eql(u8, job.status, "queued")) {
        queued += 1;
        try std.testing.expectEqual(@as(?[]const u8, null), job.conclusion);
    };
    try std.testing.expect(queued != 0);
    // The same jobs, the run not completed: waited on, whatever the jobs say.
    const run = try github.readRun(a, @embedFile("github/bay-push-in-progress.run.json"));
    try std.testing.expect(!run.completed());
    try std.testing.expectEqual(github.Verdict.waiting, github.verdict(run, jobs));
}

test "the runs a dispatch is looked for among are read, each with its commit and when it was made" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const runs = try github.readRuns(arena.allocator(), @embedFile("github/preflight-dispatched.runs.json"));
    try std.testing.expect(runs.len != 0);
    for (runs) |run| {
        try std.testing.expectEqual(40, run.head_sha.len);
        try std.testing.expect(run.created_at.len != 0);
        try std.testing.expect(run.completed());
    }
}

test "a published release is read as the GitHub Release step reads it: its id, its upload template, its page and its files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const release = try github.readRelease(arena.allocator(), @embedFile("github/bay-v0.3.0.release.json"));
    try std.testing.expect(std.mem.startsWith(u8, release.upload_url, "https://uploads.github.com/repos/pedronaugusto/bay/releases/"));
    try std.testing.expect(std.mem.endsWith(u8, release.upload_url, "/assets{?name,label}"));
    try std.testing.expectEqualStrings("https://github.com/pedronaugusto/bay/releases/tag/v0.3.0", release.html_url);
    try std.testing.expect(release.assets.len != 0);
    for (release.assets) |asset| try std.testing.expect(asset.name.len != 0);
    try std.testing.expect(release.body != null);
}
