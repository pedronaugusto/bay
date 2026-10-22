//! Everything bay tells the person running it: a command's result on stdout,
//! where a script reads it; what it did, and why it stopped, on stderr after
//! `bay: `. A write that fails is returned, never dropped.
const std = @import("std");
const Io = std.Io;

/// A failure reported in a sentence: the run ends with code 1 and no trace.
/// `WriteFailed` when stderr took no sentence.
pub const Failure = error{ Reported, WriteFailed };

/// Reports a failure in a sentence. `try say.fail(...)` ends the command.
pub fn fail(io: Io, comptime format: []const u8, args: anytype) Failure!noreturn {
    try note(io, format, args);
    return error.Reported;
}

/// Tells what a command did, on stderr.
pub fn note(io: Io, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    try write(io, Io.File.stderr(), "bay: " ++ format ++ "\n", args);
}

/// Writes a command's result to stdout.
pub fn out(io: Io, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    try write(io, Io.File.stdout(), format, args);
}

/// Passes on what a program bay ran wrote to stderr, as it wrote it.
pub fn relay(io: Io, text: []const u8) Io.Writer.Error!void {
    try write(io, Io.File.stderr(), "{s}", .{text});
}

fn write(io: Io, file: Io.File, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

/// Passes on a line another machine's bay wrote, after the machine's name.
pub fn named(io: Io, name: []const u8, text: []const u8) Io.Writer.Error!void {
    try write(io, Io.File.stderr(), "{s}: {s}\n", .{ name, text });
}
