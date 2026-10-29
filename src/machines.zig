//! The person's machines a release is gated on besides this one, named once in
//! `machines.zon` in bay's configuration directory:
//!
//!     .{
//!         .{ .name = "bench", .bay = .{ "limactl", "shell", "bench", "bay" }, .directory = "/home/me/bay" },
//!     }
//!
//! `bay` is the command that runs bay there, `directory` where bay keeps its
//! copies there. A release commit goes to a machine as a git bundle on that
//! command's stdin; bay there checks it out in a repository of its own and runs
//! the package's gate, and its output comes back a line at a time, named.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const dirs = @import("dirs.zig");
const say = @import("say.zig");
const lock = @import("lock.zig");

pub const Machine = struct {
    name: []const u8,
    /// The command that runs bay on the machine, its arguments after it.
    bay: []const []const u8,
    /// Where bay keeps its copies of the packages it gates there.
    directory: []const u8,
};

pub const file_name = "machines.zon";

/// The machines the person named; none when there is no `machines.zon`.
pub fn load(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const Machine {
    const path = try std.fs.path.join(a, &.{ try dirs.config(io, a, environ), file_name });
    const text = aegis.own.readFile(io, Io.Dir.cwd(), path, a, .fromRaw(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => try say.fail(io, "could not read {s}: {t}", .{ path, err }),
    };
    return switch (try parse(a, try a.dupeSentinel(u8, text, 0))) {
        .machines => |machines| machines,
        .invalid => |why| try say.fail(io, "{s}: {s}", .{ path, why }),
    };
}

/// The machines a `machines.zon` names, or why it is refused.
const Parsed = union(enum) { machines: []const Machine, invalid: []const u8 };

fn parse(a: std.mem.Allocator, source: [:0]const u8) error{OutOfMemory}!Parsed {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const machines = std.zon.parse.fromSlice([]const Machine, .{ .gpa = a, .arena = a, .source = source, .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return .{ .invalid = try a.print("{f}", .{diagnostics.fmt(file_name)}) },
    };
    for (machines, 0..) |machine, index| {
        if (machine.name.len == 0 or machine.bay.len == 0 or machine.directory.len == 0)
            return .{ .invalid = try a.print("machine {d} needs a name, the command that runs bay there and a directory", .{index + 1}) };
        for (machines[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, machine.name))
            return .{ .invalid = try a.print("{s} is named twice", .{machine.name}) };
    }
    return .{ .machines = machines };
}

test "machines are read with their command and directory, and a name twice is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const machines = (try parse(a, ".{ .{ .name = \"bench\", .bay = .{ \"limactl\", \"shell\", \"bench\", \"bay\" }, .directory = \"/home/me/bay\" } }")).machines;
    try std.testing.expectEqual(1, machines.len);
    try std.testing.expectEqualStrings("limactl", machines[0].bay[0]);
    try std.testing.expectEqualStrings("x is named twice", (try parse(a, ".{ .{ .name = \"x\", .bay = .{\"bay\"}, .directory = \"/a\" }, .{ .name = \"x\", .bay = .{\"bay\"}, .directory = \"/b\" } }")).invalid);
    try std.testing.expectEqualStrings("machine 1 needs a name, the command that runs bay there and a directory", (try parse(a, ".{ .{ .name = \"x\", .bay = .{}, .directory = \"/a\" } }")).invalid);
    try std.testing.expect((try parse(a, ".{ .{ .name = \"x\" } }")) == .invalid);
}

/// The terminal the machines' lines share, each written whole.
pub const Terminal = aegis.BlockingGuarded(struct {
    /// The first write that failed, to the terminal or a log: the run has failed,
    /// whatever the machines did.
    unwritten: ?anyerror = null,
});

/// Where one gate's lines go: the terminal, after the machine's name (none for this
/// machine's), and the gate's log, whole, where a red gate's output is read after.
pub const Output = struct {
    name: ?[]const u8,
    log: Io.File,
    terminal: *Terminal,
};

/// What gating on one machine needs: the bundle holding the release commit and
/// tags, and where the package is in the repository.
pub const Request = struct {
    bundle: []const u8,
    /// The repository's copy on the machine is `<directory>/<repository>`.
    repository: []const u8,
    /// The package's directory in the repository, `.` at its top.
    package: []const u8,
};

/// Gates the commit at HEAD of the package at `package` on this machine, with its
/// `gate` step; whether it is green. Its lines go to `output`.
pub fn local(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, package: []const u8, output: *Output) !bool {
    // One gate in a directory at a time: a second would build over the first's files.
    var held = try lock.hold(io, a, environ, .gate, package);
    defer held.release(io);
    const bay = environ.get("BAY").?; // safe: main sets BAY before any command
    // This machine releases, so it runs the jobs that say the same on any machine; a
    // `PREFLIGHT_PORTABLE=elsewhere` it inherited would leave them to no one.
    var gate_environ = try environ.clone(a);
    _ = gate_environ.swapRemove("PREFLIGHT_PORTABLE");
    var child = try std.process.spawn(io, .{ .argv = &.{ bay, "gate" }, .cwd = .{ .path = package }, .environ_map = &gate_environ, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
    const streams = [_]Io.File{ child.stdout.?, child.stderr.? }; // safe: spawned with pipes
    child.stdout = null;
    child.stderr = null;
    try relayAll(io, &child, &streams, null, output);
    const term = try child.wait(io);
    return term == .exited and term.exited == 0;
}

/// Both streams relayed at once, until they end: either alone could fill its pipe and
/// stop the child. `fed`, given, writes the child's stdin meanwhile.
fn relayAll(io: Io, child: *std.process.Child, streams: []const Io.File, fed: ?*Feed, output: *Output) !void {
    var group: Io.Group = .init;
    var started: usize = 0;
    const unavailable: ?Io.ConcurrentError = start: {
        if (fed) |feed| group.concurrent(io, Feed.run, .{feed}) catch |err| break :start err;
        for (streams) |stream| {
            group.concurrent(io, relay, .{ io, stream, output }) catch |err| break :start err;
            started += 1;
        }
        break :start null;
    };
    if (unavailable) |err| {
        child.kill(io);
        if (fed) |feed| if (started == 0) feed.file.deinit(io);
        for (streams[started..]) |stream| stream.close(io);
        try group.await(io);
        return err;
    }
    try group.await(io);
}

/// The most a bundle holds: the package repository's history to the release commit. The
/// family's largest is warp's, about 120 MiB; a repository past this is refused, not read.
const bundle_limit: usize = 1 << 30;

/// Gates the bundle's commit on `machine`; whether its gate is green. Its lines go to `output`.
pub fn gate(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, machine: Machine, request: Request, output: *Output) !bool {
    const bundle = try aegis.own.readFile(io, Io.Dir.cwd(), request.bundle, a, .fromRaw(bundle_limit));
    // The machine's paths are its own: joined with `/`, which Windows takes too.
    const copy = try a.print("{s}/{s}", .{ std.mem.trimEnd(u8, machine.directory, "/\\"), request.repository });
    const argv = try std.mem.concat(a, []const u8, &.{ machine.bay, &.{ "release", "--gate-bundle", copy, "--package", request.package } });
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = environ, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe }) catch |err| {
        try line(io, output, try a.print("could not run {s}: {t}", .{ machine.bay[0], err }));
        return false;
    };
    var fed: Feed = .{ .io = io, .file = .init(child.stdin.?), .bytes = bundle }; // safe: spawned with a pipe
    const streams = [_]Io.File{ child.stdout.?, child.stderr.? }; // safe: spawned with pipes
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    try relayAll(io, &child, &streams, &fed, output);
    const term = try child.wait(io);
    if (fed.failed) |err| try line(io, output, try a.print("the release commit did not reach it: {t}", .{err}));
    return term == .exited and term.exited == 0 and fed.failed == null;
}

/// The bundle written to the machine's stdin, which then closes.
const Feed = struct {
    io: Io,
    file: aegis.own.OwnedIo(Io.File, closeFile),
    bytes: []const u8,
    failed: ?Io.File.Writer.Error = null,

    fn run(feed: *Feed) void {
        defer feed.file.deinit(feed.io);
        feed.file.lend().get().writeStreamingAll(feed.io, feed.bytes) catch |err| {
            feed.failed = err;
        };
    }
};

fn closeFile(file: *Io.File, io: Io) void {
    file.close(io);
}

/// Each line `file` gives, to `output`, until it ends.
fn relay(io: Io, file: Io.File, output: *Output) void {
    defer file.close(io);
    var buffer: [16 << 10]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    while (true) {
        const text = (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            // A line longer than the buffer goes in parts.
            error.StreamTooLong => {
                const part = reader.interface.buffered();
                line(io, output, part) catch return;
                reader.interface.toss(part.len);
                continue;
            },
            error.ReadFailed => return,
        }) orelse return;
        line(io, output, std.mem.trimEnd(u8, text, "\r")) catch return;
    }
}

/// One line to the terminal, after the machine's name, and to the gate's log, whole.
fn line(io: Io, output: *Output, text: []const u8) !void {
    var guard = output.terminal.acquireUncancelable(io);
    defer guard.deinit(io);
    const state = guard.value();
    if (state.unwritten != null) return;
    write(io, output, text) catch |err| {
        state.unwritten = err;
        return err;
    };
}

fn write(io: Io, output: *Output, text: []const u8) !void {
    if (output.name) |name| try say.named(io, name, text) else {
        try say.relay(io, text);
        try say.relay(io, "\n");
    }
    try output.log.writeStreamingAll(io, text);
    try output.log.writeStreamingAll(io, "\n");
}

/// The machine's side of `gate`: the bundle on stdin fetched into the
/// repository at `directory` (made when it is not there), its commit checked
/// out with nothing else in the tree, and the gate of the package at `package`
/// in it run. Returns the gate's exit code.
pub fn receive(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, directory: []const u8, package: []const u8) !u8 {
    var input_buffer: [64 << 10]u8 = undefined;
    var input = Io.File.stdin().readerStreaming(io, &input_buffer);
    const bytes = input.interface.allocRemaining(a, .limited(bundle_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try say.fail(io, "no release commit came on stdin: {t}", .{err}),
    };
    // One gate in this copy at a time: a second release's checkout would change the files the
    // first's build reads (two trains once gated one copy at once).
    var held = try lock.hold(io, a, environ, .gate, directory);
    defer held.release(io);
    // Beside the copy, and replaced by the next release's.
    const bundle = try a.print("{s}.bundle", .{std.mem.trimEnd(u8, directory, "/\\")});
    if (std.fs.path.dirname(bundle)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bundle, .data = bytes });
    const git_dir = try std.fs.path.join(a, &.{ directory, ".git" });
    if (Io.Dir.cwd().access(io, git_dir, .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => try git(io, a, environ, null, &.{ "init", "--quiet", directory }),
        else => return err,
    }
    try git(io, a, environ, directory, &.{ "fetch", "--quiet", "--force", "--tags", bundle, "+HEAD:refs/bay/gate" });
    try git(io, a, environ, directory, &.{ "checkout", "--quiet", "--force", "--detach", "refs/bay/gate" });
    // What an earlier gate left that git tracks not, but ignored files: its caches.
    try git(io, a, environ, directory, &.{ "clean", "--quiet", "-ffd" });
    const head = try gitOutput(io, a, environ, directory, &.{ "rev-parse", "HEAD" });
    try say.note(io, "gating {s} in {s}", .{ head[0..@min(head.len, 12)], directory });
    const bay = environ.get("BAY").?; // safe: main sets BAY before any command
    // The machine that releases runs the jobs that say the same on any machine (the
    // source checks, the compiles of named targets); a machine beside it leaves them.
    var gate_environ = try environ.clone(a);
    try gate_environ.put("PREFLIGHT_PORTABLE", "elsewhere");
    var child = std.process.spawn(io, .{ .argv = &.{ bay, "gate" }, .cwd = .{ .path = try std.fs.path.join(a, &.{ directory, package }) }, .environ_map = &gate_environ }) catch |err|
        try say.fail(io, "could not run bay gate: {t}", .{err});
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
    };
}

fn git(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, cwd: ?[]const u8, args: []const []const u8) !void {
    _ = try gitOutput(io, a, environ, cwd, args);
}

fn gitOutput(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, cwd: ?[]const u8, args: []const []const u8) ![]const u8 {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{"git"}, args });
    const result = std.process.run(a, io, .{ .argv = argv, .cwd = if (cwd) |path| .{ .path = path } else .inherit, .environ_map = environ }) catch |err|
        try say.fail(io, "could not run git: {t}", .{err});
    if (result.term != .exited or result.term.exited != 0) try say.fail(io, "git {s}: {s}", .{ args[0], std.mem.trim(u8, result.stderr, " \r\n") });
    return std.mem.trim(u8, result.stdout, " \r\n");
}
