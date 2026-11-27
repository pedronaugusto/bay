//! A release's proof: the full run of the head its tag names, on GitHub. The tier is the one
//! the package's ci.yml offers its dispatch for the full matrix, as the preflight it pins
//! generated it (`full`, or `release` before preflight 0.20.0); it runs on a candidate ref
//! (`release/vX.Y.Z`) at that exact commit, so a push to the default branch meanwhile cannot
//! move what it proves. Each run found is recorded on this machine under its commit, so a
//! batch stopped while it waits takes the same run up again rather than dispatching another.
//!
//! A batch's runs are paced to the account's runners. GitHub Free runs 20 jobs at once, 5 of
//! them on macOS, and a job left queued past its runner's wait is cancelled unrun (almanac
//! 44324896023): a run is dispatched only while the jobs its plan holds fit beside the jobs
//! the runs already going still hold, its plan read from the matrices ci.yml carries. What a
//! run going holds is read from GitHub at each look, its jobs queued or in progress, so the
//! next run starts as the last ones' tails leave room; a run dispatched and not yet shown, or
//! between its phases with no job listed, holds its plan. A run whose plan alone is past the
//! budget starts when the batch holds no runner.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const github = @import("github.zig");
const intake = @import("intake.zig");
const say = @import("say.zig");

/// The workflow file a full run is dispatched in, as preflight generates it.
pub const workflow = "ci.yml";

/// What a batch's runs may hold at once.
pub const Budget = struct { jobs: u32, macos: u32 };

/// GitHub Free's runners for an account: 20 jobs at once, 5 on macOS.
pub const account: Budget = .{ .jobs = 20, .macos = 5 };

/// The jobs a run holds at its most at once, and how many of them are on macOS.
pub const Demand = struct {
    jobs: u32 = 0,
    macos: u32 = 0,

    /// As much of `budget` as the run takes: all of it, where its plan is larger.
    fn within(demand: Demand, budget: Budget) Demand {
        return .{ .jobs = @min(demand.jobs, budget.jobs), .macos = @min(demand.macos, budget.macos) };
    }

    /// Whether a run of this plan may start beside `busy`: its jobs fit beside them, or the
    /// batch holds no runner at all.
    fn fits(demand: Demand, busy: Demand, budget: Budget) bool {
        if (busy.jobs == 0) return true;
        const takes = demand.within(budget);
        return busy.jobs + takes.jobs <= budget.jobs and busy.macos + takes.macos <= budget.macos;
    }
};

/// What a run going holds of the runners, as GitHub lists its jobs: those queued or in
/// progress. Null where none is (a run not started, or between its phases): its plan counts.
fn heldBy(job_list: []const github.Job) ?Demand {
    var held: Demand = .{};
    for (job_list) |job| if (job.active()) {
        held.jobs += 1;
        if (job.onMacos()) held.macos += 1;
    };
    return if (held.jobs == 0) null else held;
}

test "a run going holds its jobs queued or in progress, and the next starts once they leave room" {
    const tail = [_]github.Job{
        .{ .name = "a", .status = "completed", .labels = &.{"ubuntu-latest"} },
        .{ .name = "b", .status = "completed", .labels = &.{"macos-latest"} },
        .{ .name = "c", .status = "in_progress", .labels = &.{"windows-latest"} },
        .{ .name = "d", .status = "queued", .labels = &.{"macos-15"} },
    };
    const held = heldBy(&tail).?;
    try std.testing.expectEqual(2, held.jobs);
    try std.testing.expectEqual(1, held.macos);
    try std.testing.expect(heldBy(tail[0..2]) == null);
    // Beside a tail of 2: a plan of 18 fits, 19 does not; one past the budget waits for none held.
    try std.testing.expect((Demand{ .jobs = 18, .macos = 4 }).fits(held, account));
    try std.testing.expect(!(Demand{ .jobs = 19 }).fits(held, account));
    try std.testing.expect(!(Demand{ .jobs = 3, .macos = 5 }).fits(held, account));
    try std.testing.expect(!(Demand{ .jobs = 41, .macos = 9 }).fits(held, account));
    try std.testing.expect((Demand{ .jobs = 41, .macos = 9 }).fits(.{}, account));
}

/// The tier ci.yml's dispatch offers for the full matrix: `full`, or `release`, which preflight
/// named it before 0.20.0. Null where its dispatch offers neither: the package runs no full
/// tier on GitHub. Read from the generated workflow, never assumed.
pub fn tierOf(ci: []const u8) ?[]const u8 {
    const key = "options: [";
    const at = std.mem.find(u8, ci, key) orelse return null;
    const end = std.mem.findScalarPos(u8, ci, at, ']') orelse return null;
    var names = std.mem.tokenizeAny(u8, ci[at + key.len .. end], ", ");
    var release = false;
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "full")) return "full";
        if (std.mem.eql(u8, name, "release")) release = true;
    }
    return if (release) "release" else null;
}

test "the full tier is the one ci.yml's dispatch offers, full before release, and none where it offers neither" {
    try std.testing.expectEqualStrings("full", tierOf("        options: [ci, full, fuzz]\n").?);
    try std.testing.expectEqualStrings("release", tierOf("        options: [ci, release, fuzz]\n").?);
    try std.testing.expect(tierOf("        options: [ci, fuzz]\n") == null);
    try std.testing.expect(tierOf("on: push\n") == null);
}

/// What a run of `tier` asks of the runners at its most, from the matrices ci.yml hands
/// preflight's workflow: the gate's jobs run beside the compile jobs, and then beside the jobs
/// that run what those compiled, with one more job beside each (the toolchain's, then Zig
/// master's). A matrix ci.yml does not carry holds no job.
pub fn demandOf(a: std.mem.Allocator, ci: []const u8, tier: []const u8) error{ OutOfMemory, Unreadable }!Demand {
    const gate = try matrix(a, ci, try a.print("{s}-matrix", .{tier}));
    const compile = try matrix(a, ci, try a.print("{s}-compile-matrix", .{tier}));
    const run = try matrix(a, ci, try a.print("{s}-run-matrix", .{tier}));
    return .{ .jobs = gate.jobs + @max(compile.jobs, run.jobs) + 1, .macos = gate.macos + @max(compile.macos, run.macos) };
}

/// One matrix of ci.yml, its key's line followed by its JSON (`key: >-`, then the object), as
/// preflight writes them; nothing where there is none.
fn matrix(a: std.mem.Allocator, ci: []const u8, key: []const u8) error{ OutOfMemory, Unreadable }!Demand {
    var lines = std.mem.splitScalar(u8, ci, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, trimmed, key) or !std.mem.eql(u8, trimmed[key.len..], ": >-")) continue;
        const json = std.mem.trim(u8, lines.next() orelse return error.Unreadable, " \r");
        const Job = struct { os: []const u8 = "" };
        const Listing = struct { include: []const Job = &.{} };
        const listed = std.json.parseFromSliceLeaky(Listing, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unreadable,
        };
        var demand: Demand = .{ .jobs = @intCast(listed.include.len) };
        for (listed.include) |job| if (std.mem.startsWith(u8, job.os, "macos")) {
            demand.macos += 1;
        };
        return demand;
    }
    return .{};
}

test "a run's demand is its gate beside the larger of its compile and run matrices, and one job more" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ci =
        \\      ci-matrix: >-
        \\        {"include":[{"os":"ubuntu-latest"}]}
        \\      release-matrix: >-
        \\        {"include":[{"os":"ubuntu-latest","name":"a"},{"os":"macos-latest"},{"os":"macos-15"},{"os":"windows-latest"}]}
        \\      release-compile-matrix: >-
        \\        {"include":[{"os":"windows-latest"},{"os":"windows-11-arm"}]}
        \\      release-run-matrix: >-
        \\        {"include":[{"os":"windows-latest"},{"os":"windows-11-arm"},{"os":"macos-latest"}]}
        \\
    ;
    const demand = try demandOf(arena.allocator(), ci, "release");
    try std.testing.expectEqual(4 + 3 + 1, demand.jobs);
    try std.testing.expectEqual(2 + 1, demand.macos);
    // No matrix of the tier: the one job beside them.
    try std.testing.expectEqual(1, (try demandOf(arena.allocator(), ci, "full")).jobs);
    try std.testing.expectError(error.Unreadable, demandOf(arena.allocator(), "      full-matrix: >-\n        {\"include\":[\n", "full"));
    try std.testing.expectEqual(20, (Demand{ .jobs = 37, .macos = 1 }).within(account).jobs);
}

/// A head to prove: the member it is of (for what is said), its repository, the candidate ref
/// at its commit, the tier, and what its run asks of the runners.
pub const Head = struct {
    name: []const u8,
    repository: []const u8,
    ref: []const u8,
    sha: []const u8,
    tier: []const u8,
    demand: Demand,
};

/// How a head's proof ended: green, with its run's page; red, with what failed; or never run,
/// as a red run elsewhere in the batch stopped the dispatches.
pub const Outcome = union(enum) { green: []const u8, red: []const u8, unrun };

/// Where this machine records the run found for a head: `<data>/proofs/<owner>/<repo>/<sha>`.
fn recordPath(a: std.mem.Allocator, data: []const u8, repository: []const u8, sha: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ data, "proofs", repository, sha });
}

fn recorded(io: Io, a: std.mem.Allocator, path: []const u8) !?u64 {
    const text = if (intake.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(64))) |taken| taken.readForParse() else |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \r\n"), 10) catch null;
}

fn record(io: Io, a: std.mem.Allocator, path: []const u8, id: u64) !void {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try a.print("{d}\n", .{id}) });
}

/// A minute before now in GitHub's form, `YYYY-MM-DDTHH:MM:SSZ`: the earliest a run of a
/// dispatch made now was made, a clock's skew allowed.
fn dispatchedSince(io: Io, a: std.mem.Allocator) ![]const u8 {
    const now = try aegis.units.Instant(.real, .second, i64).fromTimestamp(Io.Clock.real.now(io), .down);
    const seconds: u64 = @intCast(@max(60, now.raw()) - 60); // safe: at least sixty before the subtraction
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, month_day.month.numeric(), month_day.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}

/// How many times a run's jobs GitHub gave no runner are run again before the proof is refused.
const unacquired_reruns = 3;

/// How many looks in a row GitHub may leave unanswered (a 5xx, a dropped connection) before a
/// proof gives up: a run waited on for an hour meets one, and it says nothing of the run.
const unanswered_looks = 5;

/// How many looks for a dispatched run before GitHub is taken to show none.
const looks_for_run = 40;

/// The jobs that neither passed nor were skipped, named and joined.
fn notPassed(a: std.mem.Allocator, job_list: []const github.Job) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (job_list) |job| if (job.conclusion != null and !job.passed()) try names.append(a, job.name);
    return std.mem.join(a, ", ", names.items);
}

const Running = struct {
    id: u64,
    /// The attempt looked for: a re-run's shows a moment after it is asked for.
    attempt: u32,
    reruns: u32 = 0,
    misses: u32 = 0,
    said: std.StringHashMapUnmanaged(void) = .empty,
    /// What it held at the last look (`heldBy`); null before any, or with none listed.
    holds: ?Demand = null,
};

const State = union(enum) {
    pending,
    looking: struct { since: []const u8, looks: u32 = 0 },
    running: Running,
    done,
};

/// Proves each of `heads`: its recorded run waited on, or its full run dispatched on its
/// candidate ref as the budget allows and waited on, each job said as it ends. A red run stops
/// further dispatches (those heads are `unrun`), and the runs going are waited on to their end.
/// `data` is bay's data directory, where runs are recorded.
pub fn prove(io: Io, a: std.mem.Allocator, api: github.Api, data: []const u8, heads: []const Head, budget: Budget, poll: Io.Duration) ![]Outcome {
    const states = try a.alloc(State, heads.len);
    const outcomes = try a.alloc(Outcome, heads.len);
    for (states, outcomes, heads) |*state, *outcome, head| {
        outcome.* = .unrun;
        state.* = if (try recorded(io, a, try recordPath(a, data, head.repository, head.sha))) |id| running: {
            try say.note(io, "{s}: its full run at {s} is run {d}, dispatched before: waiting on it", .{ head.name, head.sha[0..12], id });
            break :running .{ .running = .{ .id = id, .attempt = 0 } };
        } else .pending;
    }
    var stopped = false;
    while (true) {
        // What the runs going hold: their jobs queued or in progress at the last look, or their
        // plan where none was listed.
        var busy: Demand = .{};
        for (states, heads) |state, head| {
            const holds = switch (state) {
                .looking => head.demand.within(budget),
                .running => |running| running.holds orelse head.demand.within(budget),
                .pending, .done => continue,
            };
            busy.jobs += holds.jobs;
            busy.macos += holds.macos;
        }
        if (!stopped) for (states, outcomes, heads) |*state, *outcome, head| {
            if (state.* != .pending) continue;
            if (!head.demand.fits(busy, budget)) continue;
            const takes = head.demand.within(budget);
            const since = try dispatchedSince(io, a);
            var problem: github.Problem = .{};
            const inputs = try a.print("{{\"tier\":\"{s}\"}}", .{head.tier});
            github.dispatch(api, head.repository, workflow, head.ref, inputs, &problem) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                outcome.* = .{ .red = try a.print("its full run could not be dispatched: {s}", .{problem.what}) };
                try say.note(io, "{s}: {s}", .{ head.name, outcome.red });
                state.* = .done;
                stopped = true;
                break;
            };
            try say.note(io, "{s}: its full run ({s} tier, {d} jobs, {d} on macOS) dispatched at {s}", .{ head.name, head.tier, head.demand.jobs, head.demand.macos, head.sha[0..12] });
            state.* = .{ .looking = .{ .since = since } };
            busy.jobs += takes.jobs;
            busy.macos += takes.macos;
        };
        var open = false;
        for (states, outcomes, heads) |*state, *outcome, head| {
            try step(io, a, api, data, head, state, outcome);
            switch (state.*) {
                .done => if (outcome.* == .red) {
                    stopped = true;
                },
                .pending => if (stopped) {
                    state.* = .done;
                } else {
                    open = true;
                },
                .looking, .running => open = true,
            }
        }
        if (!open) break;
        try io.sleep(poll, .awake);
    }
    return outcomes;
}

/// One look at a head that is looking for its run or running it: the run found and recorded,
/// its jobs said as they end, and its end taken (green, red, or its jobs with no runner run
/// again, a bounded number of times).
fn step(io: Io, a: std.mem.Allocator, api: github.Api, data: []const u8, head: Head, state: *State, outcome: *Outcome) !void {
    var problem: github.Problem = .{};
    if (state.* == .looking) {
        const looking = &state.looking;
        const shown = github.newestRun(api, head.repository, head.ref, head.sha, looking.since, &problem) catch |err| unanswered: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try say.note(io, "{s}: {s}; looking again", .{ head.name, problem.what });
            break :unanswered null;
        };
        const found = shown orelse {
            looking.looks += 1;
            if (looking.looks == looks_for_run) {
                outcome.* = .{ .red = try a.print("GitHub shows no run of {s} on {s} at {s} after {d} looks", .{ workflow, head.ref, head.sha[0..12], looks_for_run }) };
                try say.note(io, "{s}: {s}", .{ head.name, outcome.red });
                state.* = .done;
            }
            return;
        };
        try record(io, a, try recordPath(a, data, head.repository, head.sha), found.id);
        try say.note(io, "{s}: its full run is {s}", .{ head.name, found.html_url });
        state.* = .{ .running = .{ .id = found.id, .attempt = found.run_attempt } };
    }
    if (state.* != .running) return;
    const running = &state.running;
    const now = github.run(api, head.repository, running.id, &problem) catch |err| return missed(io, a, head, state, outcome, err, problem);
    const job_list = github.jobs(api, head.repository, running.id, &problem) catch |err| return missed(io, a, head, state, outcome, err, problem);
    running.misses = 0;
    running.holds = heldBy(job_list);
    if (now.run_attempt < running.attempt) return;
    for (job_list) |job| if (job.conclusion) |conclusion| if (!running.said.contains(job.name)) {
        try running.said.put(a, job.name, {});
        try say.note(io, "{s}: {s}: {s}", .{ head.name, job.name, conclusion });
    };
    const stands = github.verdict(now, job_list);
    switch (stands) {
        .waiting => return,
        .green => {
            outcome.* = .{ .green = now.html_url };
            try say.note(io, "{s}: its full run is green, {s}", .{ head.name, now.html_url });
            state.* = .done;
            return;
        },
        .unacquired => if (running.reruns < unacquired_reruns) {
            running.reruns += 1;
            const names = try notPassed(a, job_list);
            for (job_list) |job| if (!job.passed()) {
                _ = running.said.remove(job.name);
            };
            try say.note(io, "{s}: GitHub gave {s} no runner; re-running its jobs, {d} of {d}", .{ head.name, names, running.reruns, unacquired_reruns });
            github.rerunFailed(api, head.repository, running.id, &problem) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                outcome.* = .{ .red = try a.print("its jobs with no runner could not be run again: {s} ({s})", .{ problem.what, now.html_url }) };
                try say.note(io, "{s}: {s}", .{ head.name, outcome.red });
                state.* = .done;
                return;
            };
            running.attempt = now.run_attempt + 1;
            return;
        },
        .red => {},
    }
    const red = try notPassed(a, job_list);
    outcome.* = .{ .red = if (stands == .unacquired)
        try a.print("GitHub gave {s} no runner, re-run {d} times ({s}): they never ran, so the full run neither passed nor failed", .{ red, unacquired_reruns, now.html_url })
    else
        try a.print("its full run is {s} ({s}): {s}", .{ now.conclusion orelse "unfinished", if (red.len == 0) "no job named" else red, now.html_url }) };
    try say.note(io, "{s}: {s}", .{ head.name, outcome.red });
    state.* = .done;
}

/// A look GitHub left unanswered: taken again, a few in a row at most, then the proof refused.
fn missed(io: Io, a: std.mem.Allocator, head: Head, state: *State, outcome: *Outcome, err: github.Error, problem: github.Problem) !void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const running = &state.running;
    if (running.misses == unanswered_looks) {
        outcome.* = .{ .red = try a.print("GitHub did not answer {d} looks in a row at run {d}: {s}", .{ unanswered_looks, running.id, problem.what }) };
        try say.note(io, "{s}: {s}", .{ head.name, outcome.red });
        state.* = .done;
        return;
    }
    running.misses += 1;
    try say.note(io, "{s}: {s}; looking again, {d} of {d}", .{ head.name, problem.what, running.misses, unanswered_looks });
}
