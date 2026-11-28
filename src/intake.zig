//! Where bytes from outside enter bay: the files it is handed or finds (manifests, archives,
//! keys, a lock's holder), what the programs it runs print, and its standard input. Each read
//! is made here, so the entry points are these few; a whole file and a program's output come
//! back as `aegis.input.Untrusted`, which the parsers that refine them read by
//! `readForParse`. glint's A009 seam is this file alone (glint.json).
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// Bytes from outside, before a parser refines them.
pub const Bytes = aegis.input.Untrusted([]const u8);

/// A file's whole contents, at most `limit` bytes, as aegis reads them: a cancel that lands on
/// the file's length is `Canceled`. The bytes are `gpa`'s.
pub fn readFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: aegis.units.Bytes(u64)) aegis.own.ReadFileError!Bytes {
    return .init(try aegis.own.readFile(io, dir, path, gpa, limit));
}

/// `readFile`, its bytes ending in `sentinel` (a manifest read for Zig's ZON parser).
pub fn readFileSentinel(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: aegis.units.Bytes(u64), comptime sentinel: u8) aegis.own.ReadFileError!aegis.input.Untrusted([:sentinel]const u8) {
    return .init(try aegis.own.readFileSentinel(io, dir, path, gpa, limit, sentinel));
}

/// A program run to its end: how it ended, and what it printed, each `gpa`'s.
pub const Ran = struct {
    term: std.process.Child.Term,
    stdout: Bytes,
    stderr: Bytes,
};

/// Runs a program and collects what it prints, as `std.process.run`.
pub fn run(gpa: std.mem.Allocator, io: Io, options: std.process.RunOptions) std.process.RunError!Ran {
    const result = try std.process.run(gpa, io, options);
    return .{ .term = result.term, .stdout = .init(result.stdout), .stderr = .init(result.stderr) };
}

/// A wait bay gives what it asks of the network or of a program: a request's answer, a retry's
/// pause, a program's whole run.
pub const Wait = aegis.units.Duration(.millisecond, u32);

/// How long a program bay runs against a remote may take in all (git listing a remote's refs,
/// fetching or pushing; Zig fetching a package) before it is stopped: a connection gone silent
/// ends in no error of its own, and the program would wait on it for good.
pub const remote_deadline: Wait = .literal("15m");

/// `run`, given `deadline` in all: past it the program is stopped and `error.Timeout` returned.
pub fn runWithin(gpa: std.mem.Allocator, io: Io, options: std.process.RunOptions, deadline: Wait) std.process.RunError!Ran {
    var bounded = options;
    // One deadline for every read of what it prints: its whole run, not each wait between lines.
    bounded.timeout = (Io.Timeout{ .duration = .{ .raw = deadline.toIoDuration(), .clock = .awake } }).toDeadline(io);
    return run(gpa, io, bounded);
}

test "a program that runs past its deadline is stopped there, where it was waited on to its end" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Ten seconds of doing nothing, on each system's own tools.
    const sleeper: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "ping", "-n", "11", "127.0.0.1" } else &.{ "sleep", "10" };
    const started = Io.Clock.awake.now(io);
    const ran = runWithin(arena.allocator(), io, .{ .argv = sleeper }, .literal("300ms"));
    const waited = started.durationTo(Io.Clock.awake.now(io));
    try std.testing.expectError(error.Timeout, ran);
    try std.testing.expect(waited.nanoseconds < 5 * std.time.ns_per_s);
}

/// A reader over `file` (a positional one where the file has a position, as `File.reader`).
pub fn reader(file: Io.File, io: Io, buffer: []u8) Io.File.Reader {
    return file.reader(io, buffer);
}

/// A streaming reader over `file`: a pipe, standard input, or a file read once from its start.
pub fn readerStreaming(file: Io.File, io: Io, buffer: []u8) Io.File.Reader {
    return file.readerStreaming(io, buffer);
}

/// Reads `file` at `offset` into `buffers`, as `File.readPositional`.
pub fn readPositional(file: Io.File, io: Io, buffers: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    return file.readPositional(io, buffers, offset);
}

/// A symbolic link's target, written into `buffer`, as `Dir.readLink`.
pub fn readLink(dir: Io.Dir, io: Io, path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    return dir.readLink(io, path, buffer);
}
