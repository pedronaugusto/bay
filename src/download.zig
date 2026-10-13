//! The HTTP requests bay makes itself, through std.http: Zig's download index
//! and builds, and the ref listings of git remotes.
const std = @import("std");
const Io = std.Io;
const say = @import("say.zig");

/// Streams the body `url` answers into `sink` and returns its length. Any
/// status but 200, and a body longer than `limit`, are refused by name.
/// `error.WriteFailed` is the sink's: its own error says why.
pub fn get(client: *std.http.Client, url: []const u8, sink: *Io.Writer, limit: u64) !u64 {
    return getWith(client, url, sink, limit, &.{});
}

/// `get`, sending `headers` too: an API's media type, a token.
pub fn getWith(client: *std.http.Client, url: []const u8, sink: *Io.Writer, limit: u64, headers: []const std.http.Header) !u64 {
    const io = client.io;
    const uri = std.Uri.parse(url) catch try say.fail(io, "{s} is not a URL", .{url});
    // The body is wanted as the server stores it: a signature or a digest covers those bytes.
    var request = client.request(.GET, uri, .{ .headers = .{ .accept_encoding = .{ .override = "identity" } }, .extra_headers = headers }) catch |err|
        try say.fail(io, "could not reach {s}: {t}", .{ url, err });
    defer request.deinit();
    request.sendBodiless() catch |err| try say.fail(io, "could not ask {s}: {t}", .{ url, err });
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch |err| try say.fail(io, "{s} did not answer: {t}", .{ url, err });
    const status = response.head.status;
    if (status != .ok) try say.fail(io, "{s} answered {d} {s}", .{ url, @backingInt(status), status.phrase() orelse "" });
    if (response.head.content_encoding != .identity) try say.fail(io, "{s} answered {t}-encoded, not as stored", .{ url, response.head.content_encoding });
    var transfer_buffer: [64]u8 = undefined;
    const body = response.reader(&transfer_buffer);
    var length: u64 = 0;
    while (true) {
        length += body.stream(sink, .limited64(limit + 1 - length)) catch |err| switch (err) {
            error.EndOfStream => return length,
            error.ReadFailed => try say.fail(io, "reading {s} failed: {t}", .{ url, response.bodyErr() orelse error.ReadFailed }),
            error.WriteFailed => return error.WriteFailed,
        };
        if (length > limit) try say.fail(io, "{s} is longer than {d} bytes", .{ url, limit });
    }
}

/// The body `url` answers, at most `limit` bytes, in memory.
pub fn getAlloc(client: *std.http.Client, a: std.mem.Allocator, url: []const u8, limit: u64) ![]u8 {
    var body: Io.Writer.Allocating = .init(a);
    _ = get(client, url, &body.writer, limit) catch |err| switch (err) {
        // The only way an allocating writer fails.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return body.written();
}
