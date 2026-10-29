//! One train per workspace and one gate per directory on a machine: each holds a lock that a
//! second refuses by name, never runs beside. Two trains once gated one checkout at once, and
//! the second's build failed on a file the first was writing. The locks are files in bay's data
//! directory, named for what they hold and its path, and the system lets them go when the
//! process ends, however it ends.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const dirs = @import("dirs.zig");
const say = @import("say.zig");

/// What a lock holds a directory for.
pub const Kind = enum { train, gate };

/// A held lock, let go by `release` or by the process ending.
pub const Held = struct {
    file: aegis.own.OwnedIo(Io.File, closeFile),

    pub fn release(held: *Held, io: Io) void {
        held.file.deinit(io);
    }
};

fn closeFile(file: *Io.File, io: Io) void {
    file.close(io);
}

/// The lock of `kind` on `path`, as an absolute path names it, or a refusal naming what holds it.
pub fn hold(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, kind: Kind, relative: []const u8) !Held {
    const path = try std.fs.path.resolveAlloc(a, &.{ try Io.Dir.cwd().realPathFileAlloc(io, ".", a), relative });
    const locks = try std.fs.path.join(a, &.{ try dirs.data(io, a, environ), "locks" });
    try Io.Dir.cwd().createDirPath(io, locks);
    const file_path = try std.fs.path.join(a, &.{ locks, try name(a, kind, path) });
    const file = Io.Dir.cwd().createFile(io, file_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false, .read = true }) catch |err| switch (err) {
        error.WouldBlock => {
            const holder = aegis.own.readFile(io, Io.Dir.cwd(), file_path, a, .fromRaw(4096)) catch |read| switch (read) {
                error.Canceled => |e| return e,
                // Its holder is still writing what it is; the refusal stands without it.
                else => "",
            };
            try say.fail(io, "a {t} holds {s} already{s}: one runs there at a time, so wait for it to end", .{ kind, path, if (holder.len == 0) "" else try a.print(" ({s})", .{holder}) });
        },
        else => |e| return e,
    };
    errdefer file.close(io);
    // What holds it, for the one refused.
    const now = try aegis.units.Instant(.real, .second, i64).fromTimestamp(Io.Clock.real.now(io), .down);
    // A clock set before 1970 reads as midnight.
    const seconds: u64 = @intCast(@max(0, now.raw())); // safe: clamped to zero and up
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getDaySeconds();
    try file.setLength(io, 0);
    try file.writePositionalAll(io, try a.print("since {d:0>2}:{d:0>2} UTC", .{ day.getHoursIntoDay(), day.getMinutesIntoHour() }), 0);
    // Owned from here: its owner binds it where the caller keeps it.
    return .{ .file = .init(file) };
}

/// The lock file's name: its kind and a digest of the path, so any path makes one name.
fn name(a: std.mem.Allocator, kind: Kind, path: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    return a.print("{t}-{x}.lock", .{ kind, digest[0..12] });
}

test "a second hold on one path is refused while the first holds it, and taken once it is let go" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ: std.process.Environ.Map = .init(a);
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    try environ.put("XDG_DATA_HOME", home);
    try environ.put("HOME", home);
    try environ.put("LOCALAPPDATA", home);
    var first = try hold(io, a, &environ, .train, "/w/ring");
    // Another path, or another kind on this one, is its own lock.
    var other = try hold(io, a, &environ, .train, "/w/other");
    other.release(io);
    var gate = try hold(io, a, &environ, .gate, "/w/ring");
    gate.release(io);
    try std.testing.expectError(error.Reported, hold(io, a, &environ, .train, "/w/ring"));
    first.release(io);
    var again = try hold(io, a, &environ, .train, "/w/ring");
    again.release(io);
}
