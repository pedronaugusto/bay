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
