//! Where bay keeps what it owns on this machine, apart from any package.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const say = @import("say.zig");

/// bay's data directory, for its install records, build copies and Zig
/// toolchains: `$XDG_DATA_HOME/bay`, `~/.local/share/bay`, or
/// `%LOCALAPPDATA%\bay\data` on Windows.
pub fn data(io: Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) return std.fs.path.join(a, &.{ environ.get("LOCALAPPDATA") orelse try say.fail(io, "LOCALAPPDATA is not set", .{}), "bay", "data" });
    if (environ.get("XDG_DATA_HOME")) |home| return std.fs.path.join(a, &.{ home, "bay" });
    return std.fs.path.join(a, &.{ environ.get("HOME") orelse try say.fail(io, "HOME is not set", .{}), ".local", "share", "bay" });
}
