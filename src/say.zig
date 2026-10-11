//! What bay tells the person running it.
const std = @import("std");

/// Reports a failure in a sentence; the run ends with code 1 and no trace.
pub fn fail(comptime format: []const u8, args: anytype) error{Reported} {
    std.debug.print("bay: " ++ format ++ "\n", args);
    return error.Reported;
}

/// Writes what a command reports as its result, to stdout, where a script reads it.
pub fn out(io: std.Io, a: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, format, args));
}
