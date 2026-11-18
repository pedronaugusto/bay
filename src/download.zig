//! The HTTP requests bay makes itself, through std.http: Zig's download index
//! and builds, and the ref listings of git remotes.
const std = @import("std");
const Io = std.Io;
const say = @import("say.zig");

/// What a request asks: at most `limit` bytes of body, with `headers` sent
/// beside bay's own (an API's media type, a token).
pub const Get = struct {
    limit: u64,
    headers: []const std.http.Header = &.{},
};

/// Streams the body `url` answers into `sink` and returns its length. Any
/// status but 200, and a body longer than `options.limit`, are refused by
/// name. `error.WriteFailed` is the sink's: its own error says why.
pub fn get(client: *std.http.Client, url: []const u8, sink: *Io.Writer, options: Get) !u64 {
    const io = client.io;
    const limit = options.limit;
    const headers = options.headers;
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

/// The body `url` answers, at most `options.limit` bytes, in memory.
pub fn getAlloc(client: *std.http.Client, a: std.mem.Allocator, url: []const u8, options: Get) ![]u8 {
    var body: Io.Writer.Allocating = .init(a);
    defer body.deinit();
    _ = get(client, url, &body.writer, options) catch |err| switch (err) {
        // The only way an allocating writer fails.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    // Owned at the length written, so the caller frees it with `a` as it would any slice.
    return body.toOwnedSlice();
}

test "a request sends the caller's headers beside bay's, and takes the body up to its limit" {
    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var server = try loopback.listen(io, .{});
    defer server.deinit(io);
    const Serve = struct {
        fn run(s: *std.Io.net.Server, saw: *bool) void {
            const stream = s.accept(std.testing.io) catch return;
            defer stream.close(std.testing.io);
            var in: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &in);
            var head: std.ArrayList(u8) = .empty;
            defer head.deinit(std.testing.allocator);
            while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) {
                const byte = reader.interface.takeByte() catch return;
                head.append(std.testing.allocator, byte) catch return;
            }
            saw.* = std.ascii.findIgnoreCase(head.items, "x-bay-test: asked") != null;
            var out: [256]u8 = undefined;
            var writer = stream.writer(std.testing.io, &out);
            writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok") catch return;
            writer.interface.flush() catch return;
        }
    };
    var saw = false;
    const thread = try std.Thread.spawn(.{}, Serve.run, .{ &server, &saw });
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    const body = try getAlloc(&client, std.testing.allocator, url, .{ .limit = 2, .headers = &.{.{ .name = "x-bay-test", .value = "asked" }} });
    defer std.testing.allocator.free(body);
    thread.join();
    try std.testing.expectEqualStrings("ok", body);
    try std.testing.expect(saw);
}
