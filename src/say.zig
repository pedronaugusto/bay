//! What bay tells the person running it.
const std = @import("std");

/// Reports a failure in a sentence; the run ends with code 1 and no trace.
pub fn fail(comptime format: []const u8, args: anytype) error{Reported} {
    std.debug.print("bay: " ++ format ++ "\n", args);
    return error.Reported;
}
