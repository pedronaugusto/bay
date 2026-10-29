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
    return switch (try take(io, a, environ, kind, relative)) {
        .held => |held| held,
        .busy => |busy| try say.fail(io, "a {t} holds {s} already{s}: one runs there at a time, so wait for it to end", .{ kind, busy.path, if (busy.holder.len == 0) "" else try a.print(" ({s})", .{busy.holder}) }),
    };
}

/// A lock taken, or the path another holds and what it says of itself.
const Taken = union(enum) {
    held: Held,
    busy: struct { path: []const u8, holder: []const u8 },
};

fn take(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, kind: Kind, relative: []const u8) !Taken {
    const path = try std.fs.path.resolveAlloc(a, &.{ try Io.Dir.cwd().realPathFileAlloc(io, ".", a), relative });
    const locks = try std.fs.path.join(a, &.{ try dirs.data(io, a, environ), "locks" });
    try Io.Dir.cwd().createDirPath(io, locks);
    const file_path = try std.fs.path.join(a, &.{ locks, try name(a, kind, path) });
    const file = Io.Dir.cwd().createFile(io, file_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false, .read = true }) catch |err| switch (err) {
        error.WouldBlock => return .{
            .busy = .{
                .path = path,
                .holder = aegis.own.readFile(io, Io.Dir.cwd(), file_path, a, .fromRaw(4096)) catch |read| switch (read) {
                    error.Canceled => |e| return e,
                    // Its holder is still writing what it is; the refusal stands without it.
                    else => "",
                },
            },
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
    return .{ .held = .{ .file = .init(file) } };
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
    var first = (try take(io, a, &environ, .train, "/w/ring")).held;
    // Another path, or another kind on this one, is its own lock.
    var other = (try take(io, a, &environ, .train, "/w/other")).held;
    other.release(io);
    var gate = (try take(io, a, &environ, .gate, "/w/ring")).held;
    gate.release(io);
    const busy = (try take(io, a, &environ, .train, "/w/ring")).busy;
    try std.testing.expectEqualStrings("ring", std.fs.path.basename(busy.path));
    try std.testing.expect(std.mem.startsWith(u8, busy.holder, "since ") and std.mem.endsWith(u8, busy.holder, " UTC"));
    first.release(io);
    var again = (try take(io, a, &environ, .train, "/w/ring")).held;
    again.release(io);
}
