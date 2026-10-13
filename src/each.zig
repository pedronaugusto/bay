//! `bay --workspace [--jobs <n>] <command> [arguments]`: the command in every
//! member of the workspace, each after the members it ships with (its normal
//! dependencies) and the members it is developed with (a tool its gate runs,
//! such as a linter released in the same train), and members with nothing
//! between them at once, as `go test ./...` runs packages. A member that fails skips the members that depend on
//! it, and the rest go on. Each member's output is printed whole when it ends.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const workspace = @import("workspace.zig");
const say = @import("say.zig");
const aegis = @import("aegis");

const Outcome = enum { pending, ok, failed, skipped };

const Member = struct {
    directory: []const u8,
    name: []const u8,
    /// Indices of the members it depends on.
    needs: []const usize,
    done: Io.Event = .unset,
    outcome: Outcome = .pending,
    /// The member that failed, for one skipped.
    because: ?usize = null,
};

const Run = struct {
    io: Io,
    environ: *const std.process.Environ.Map,
    /// The bay to run in each member: this one.
    bay: []const u8,
    command: []const []const u8,
    members: []Member,
    permits: Io.Semaphore,
    /// The terminal, which members write to whole, one at a time.
    terminal: aegis.BlockingGuarded(Terminal) = .init(.{}),
};

/// What the members share through the terminal's guard.
const Terminal = struct {
    /// The first write to it that failed: the run has then failed, whatever its members did.
    unwritten: ?Io.Writer.Error = null,
};

pub fn run(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, jobs: ?usize, command: []const []const u8) !u8 {
    if (command.len == 0) try say.fail(io, "--workspace needs a command to run in each member", .{});
    const here = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const directories = try workspace.all(io, a, here) orelse try say.fail(io, "no {s} here or in any directory above", .{workspace.file_name});
    const members = try order(io, a, directories);
    const width = jobs orelse std.Thread.getCpuCount() catch 1;
    var state: Run = .{
        .io = io,
        .environ = environ,
        .bay = environ.get("BAY").?, // safe: main sets BAY before any command
        .command = command,
        .members = members,
        .permits = .{ .permits = @max(width, 1) },
    };
    var group: Io.Group = .init;
    for (0..members.len) |index| group.concurrent(io, one, .{ &state, index }) catch |err| {
        // Members not started count as failed, so those that wait on them go on.
        for (members[index..]) |*member| {
            member.outcome = .failed;
            member.done.set(io);
        }
        try group.await(io);
        try say.fail(io, "could not start a task per member: {t}", .{err});
    };
    try group.await(io);
    // Every task has ended: the terminal's state is read without its guard.
    if (state.terminal.teardown().unwritten) |err| return err;
    var failed: usize = 0;
    for (members) |member| if (member.outcome != .ok) {
        failed += 1;
    };
    try say.note(io, "{d} of {d} members ok", .{ members.len - failed, members.len });
    return if (failed == 0) 0 else 1;
}

/// The members with what each depends on among them; a ring is refused, since
/// no member of it could go first.
fn order(io: Io, a: std.mem.Allocator, directories: []const []const u8) ![]Member {
    const manifests = try a.alloc(manifest.Manifest, directories.len);
    for (manifests, directories) |*parsed, directory| {
        const text = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ directory, "build.zig.zon" }), a, .limited(1 << 20));
        parsed.* = manifest.parse(a, try a.dupeSentinel(u8, text, 0)) catch |err| switch (err) {
            error.InvalidManifest => try say.fail(io, "{s}/build.zig.zon is not a manifest bay can read", .{directory}),
            else => |e| return e,
        };
    }
    const all = try needs(a, manifests, directories);
    const members = try a.alloc(Member, directories.len);
    for (members, manifests, directories, all) |*member, parsed, directory, member_needs| {
        member.* = .{ .directory = directory, .name = parsed.name, .needs = member_needs };
    }
    if (try ring(a, members)) |name| try say.fail(io, "{s} and the members it ships with depend on each other: no member of a ring can go first", .{name});
    return members;
}

/// What each member waits for: the members it ships with, then the members it
/// is developed with, each only where it closes no ring. A development edge
/// that would close one is a tool developing with its own released self or
/// with a package that ships it (glint pins a released preflight, which ships
/// glint): that member checks itself with the release it pins, so nothing in
/// the train needs it to go first. Development edges are taken in member and
/// manifest order, so the same workspace is always ordered the same way.
fn needs(a: std.mem.Allocator, manifests: []const manifest.Manifest, directories: []const []const u8) ![]const []const usize {
    const lists = try a.alloc(std.ArrayList(usize), manifests.len);
    for (lists) |*list| list.* = .empty;
    for (manifests, directories, lists) |parsed, directory, *list| {
        try among(a, manifests, directories, parsed, directory, parsed.normal, list);
    }
    for (manifests, directories, 0..) |parsed, directory, index| {
        var developed: std.ArrayList(usize) = .empty;
        try among(a, manifests, directories, parsed, directory, parsed.dev, &developed);
        for (developed.items) |target| {
            if (std.mem.findScalar(usize, lists[index].items, target) != null) continue;
            if (try reaches(a, lists, target, index)) continue;
            try lists[index].append(a, target);
        }
    }
    const result = try a.alloc([]const usize, manifests.len);
    for (result, lists) |*slot, *list| slot.* = try list.toOwnedSlice(a);
    return result;
}

/// The members `dependencies` of the member `parsed` at `directory` name,
/// appended to `out`: a path names a member's directory, a pin a package by
/// the name in its hash.
fn among(a: std.mem.Allocator, manifests: []const manifest.Manifest, directories: []const []const u8, parsed: manifest.Manifest, directory: []const u8, dependencies: []const manifest.Dependency, out: *std.ArrayList(usize)) !void {
    for (dependencies) |dependency| switch (dependency.source) {
        .path => |path| {
            const target = try std.fs.path.resolveAlloc(a, &.{ directory, path });
            for (directories, 0..) |other, index| if (std.mem.eql(u8, other, target) and !std.mem.eql(u8, other, directory)) try out.append(a, index);
        },
        .remote => |remote| {
            const name = (manifest.named(remote.hash) orelse continue).name;
            for (manifests, 0..) |other, index| if (std.mem.eql(u8, other.name, name) and !std.mem.eql(u8, other.name, parsed.name)) try out.append(a, index);
        },
    };
}

/// Whether `from` waits, through the edges so far, on `to`.
fn reaches(a: std.mem.Allocator, lists: []const std.ArrayList(usize), from: usize, to: usize) !bool {
    const seen = try a.alloc(bool, lists.len);
    defer a.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(a);
    try stack.append(a, from);
    while (stack.pop()) |at| {
        if (at == to) return true;
        if (seen[at]) continue;
        seen[at] = true;
        try stack.appendSlice(a, lists[at].items);
    }
    return false;
}

/// A member on a ring of normal dependencies, or null.
fn ring(a: std.mem.Allocator, members: []const Member) !?[]const u8 {
    const State = enum { new, open, closed };
    const states = try a.alloc(State, members.len);
    @memset(states, .new);
    const Visit = struct {
        fn visit(all: []const Member, marks: []State, index: usize) ?usize {
            switch (marks[index]) {
                .closed => return null,
                .open => return index,
                .new => {},
            }
            marks[index] = .open;
            for (all[index].needs) |need| if (visit(all, marks, need)) |found| return found;
            marks[index] = .closed;
            return null;
        }
    };
    for (0..members.len) |index| if (Visit.visit(members, states, index)) |found| return members[found].name;
    return null;
}

/// One member: after what it needs, and within the permits.
fn one(state: *Run, index: usize) void {
    const io = state.io;
    const member = &state.members[index];
    defer member.done.set(io);
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const said = attempt(state, member, arena.allocator());
    report(state, member, said);
}

/// What a member's run wrote, once it has an outcome.
const Said = struct { stdout: []const u8 = "", stderr: []const u8 = "" };

fn attempt(state: *Run, member: *Member, a: std.mem.Allocator) Said {
    const io = state.io;
    for (member.needs) |need| {
        state.members[need].done.waitUncancelable(io);
        if (state.members[need].outcome != .ok) {
            member.outcome = .skipped;
            member.because = if (state.members[need].outcome == .failed) need else state.members[need].because;
            return .{};
        }
    }
    state.permits.waitUncancelable(io);
    defer state.permits.post(io);
    member.outcome = .failed;
    const argv = std.mem.concat(a, []const u8, &.{ &.{state.bay}, state.command }) catch return .{ .stderr = "bay: out of memory\n" };
    const result = std.process.run(a, io, .{
        .argv = argv,
        .cwd = .{ .path = member.directory },
        .environ_map = state.environ,
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(64 << 20),
    }) catch |err| return .{ .stderr = a.print("bay: could not run bay: {t}\n", .{err}) catch "bay: could not run bay\n" };
    if (result.term == .exited and result.term.exited == 0) member.outcome = .ok;
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

/// A member's output, whole, under its outcome.
fn report(state: *Run, member: *const Member, said: Said) void {
    var guard = state.terminal.acquireUncancelable(state.io);
    defer guard.deinit(state.io);
    const terminal = guard.value();
    if (terminal.unwritten != null) return;
    write(state, member, said) catch |err| {
        terminal.unwritten = err;
    };
}

fn write(state: *Run, member: *const Member, said: Said) Io.Writer.Error!void {
    const io = state.io;
    switch (member.outcome) {
        .skipped => return say.note(io, "{s}: skipped, since {s} failed", .{ member.name, state.members[member.because.?].name }), // safe: a skipped member names the failure
        .ok, .failed => try say.note(io, "{s}: {t}", .{ member.name, member.outcome }),
        .pending => unreachable, // safe: a member is reported once it has an outcome
    }
    try say.out(io, "{s}", .{said.stdout});
    try say.relay(io, said.stderr);
}

test "members are ordered by what they ship with, and a ring is found" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var members = [_]Member{
        .{ .directory = "a", .name = "a", .needs = &.{} },
        .{ .directory = "b", .name = "b", .needs = &.{0} },
        .{ .directory = "c", .name = "c", .needs = &.{ 0, 1 } },
    };
    try std.testing.expectEqual(null, try ring(a, &members));
    members[0].needs = &.{2};
    try std.testing.expect(try ring(a, &members) != null);
}

test "a member waits for the tools it is developed with, unless that closes a ring" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // aegis ← glint (ships it) ← preflight (ships glint); glint and ensign develop with preflight.
    const texts = [_][:0]const u8{
        \\.{ .name = .aegis, .version = "0.1.0", .fingerprint = 0x1, .paths = .{""} }
        ,
        \\.{ .name = .glint, .version = "0.1.0", .fingerprint = 0x2, .paths = .{""},
        \\  .dependencies = .{ .aegis = .{ .path = "../aegis" } },
        \\  .dev_dependencies = .{ .preflight = .{ .path = "../preflight" } } }
        ,
        \\.{ .name = .preflight, .version = "0.1.0", .fingerprint = 0x3, .paths = .{""},
        \\  .dependencies = .{ .glint = .{ .path = "../glint" } } }
        ,
        \\.{ .name = .ensign, .version = "0.1.0", .fingerprint = 0x4, .paths = .{""},
        \\  .dependencies = .{ .aegis = .{ .path = "../aegis" } },
        \\  .dev_dependencies = .{ .preflight = .{ .path = "../preflight" } } }
        ,
    };
    var manifests: [texts.len]manifest.Manifest = undefined;
    for (&manifests, texts) |*m, text| m.* = try manifest.parse(a, text);
    // Resolved as the members' directories are, so they compare on every platform.
    var directories: [texts.len][]const u8 = undefined;
    for (&directories, [_][]const u8{ "aegis", "glint", "preflight", "ensign" }) |*d, name| d.* = try std.fs.path.resolveAlloc(a, &.{ "w", name });
    const all = try needs(a, &manifests, &directories);
    try std.testing.expectEqualSlices(usize, &.{}, all[0]);
    // glint's development edge to preflight would close a ring: glint uses the released preflight.
    try std.testing.expectEqualSlices(usize, &.{0}, all[1]);
    try std.testing.expectEqualSlices(usize, &.{1}, all[2]);
    // ensign lands after preflight, the tool its gate runs.
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, all[3]);
}
