//! The HTTP requests bay makes itself, through std.http: Zig's download index
//! and builds, and the ref listings of git remotes.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const say = @import("say.zig");
const intake = @import("intake.zig");
pub const Wait = intake.Wait;

/// What a request asks: at most `limit` bytes of body, with `headers` sent
/// beside bay's own (an API's media type, a token), asked again as `retry` says
/// where the network fails it before an answer, and given `answer` to answer.
pub const Get = struct {
    limit: u64,
    headers: []const std.http.Header = &.{},
    retry: Retry = .{},
    answer: Wait = answer_deadline,
};

/// How long any request bay makes waits for its answer (reached, asked, and its head; all of
/// it, for GitHub's API) before it is given up as unanswered: a connection gone silent ends in
/// no error of its own, and a train once waited on one for an hour, its run long green.
pub const answer_deadline: Wait = .literal("60s");

/// How long a body may take to arrive once its head has: an archive of hundreds of megabytes
/// over a slow link, and no longer.
pub const body_deadline: Wait = .literal("15m");

fn Within(comptime function: anytype) type {
    const returned = @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union;
    return (returned.error_set || error{Timeout} || Io.ConcurrentError || Io.Cancelable)!returned.payload;
}

/// `function(args)`, given until `deadline`: its result, or `error.Timeout` where it has not
/// returned by then, when it is canceled (a read it is blocked in interrupted) and waited for.
pub fn within(io: Io, deadline: Wait, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Within(function) {
    const Ends = union(enum) { done: @typeInfo(@TypeOf(function)).@"fn".return_type.?, late: Io.Cancelable!void };
    var buffer: [2]Ends = undefined;
    var select: Io.Select(Ends) = .init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.done, function, args);
    try select.concurrent(.late, Io.sleep, .{ io, deadline.toIoDuration(), .awake });
    return switch (try select.await()) {
        .done => |result| result,
        .late => error.Timeout,
    };
}

/// How a request the network failed before any answer (`transient`) is asked
/// again: up to `tries` times in all, `wait` before the second and twice as
/// long before each after it.
pub const Retry = struct {
    tries: u8 = 4,
    wait: Wait = .literal("1s"),
};

/// The errors of a network that is briefly not there: a name its resolver could
/// not look up then, a route gone, a connection reset or timed out. An answer
/// the server gives (a status, a body that is not the one pinned) is none of
/// them, and is never asked again.
const transient_errors = [_]anyerror{
    error.UnknownHostName,
    error.TemporaryNameServerFailure,
    error.NameServerFailure,
    error.NetworkUnreachable,
    error.HostUnreachable,
    error.NetworkDown,
    error.ConnectionResetByPeer,
    error.ConnectionTimedOut,
    // No answer within its deadline (`within`): a connection gone silent.
    error.Timeout,
};

pub fn transient(err: anyerror) bool {
    for (transient_errors) |kind| if (err == kind) return true;
    return false;
}

/// `ask.once()` until it succeeds: asked again on `io` where it fails with a
/// transient error (`transient`), as `retry` says, and then failing with that
/// error; any other error is returned at once.
pub fn retried(io: Io, retry: Retry, ask: anytype) !void {
    var wait = retry.wait;
    var tries: u8 = 1;
    while (true) : (tries += 1) {
        ask.once() catch |err| {
            if (tries >= retry.tries or !transient(err)) return err;
            try io.sleep(wait.toIoDuration(), .awake);
            wait = wait.saturatingMul(2);
            continue;
        };
        return;
    }
}

/// Streams the body `url` answers into `sink` and returns its length. Any
/// status but 200, and a body longer than `options.limit`, are refused by
/// name. `error.WriteFailed` is the sink's: its own error says why.
pub fn get(client: *std.http.Client, url: []const u8, sink: *Io.Writer, options: Get) !u64 {
    const io = client.io;
    const limit = options.limit;
    const headers = options.headers;
    const uri = std.Uri.parse(url) catch try say.fail(io, "{s} is not a URL", .{url});
    // Reached, asked and answered as one try, given `deadline`, asked again while the network fails it.
    const Ask = struct {
        client: *std.http.Client,
        uri: std.Uri,
        headers: []const std.http.Header,
        deadline: Wait,
        request: std.http.Client.Request = undefined,
        response: std.http.Client.Response = undefined,
        redirect_buffer: [8 * 1024]u8 = undefined,
        /// How far the last try came, for what a failure says.
        step: enum { reach, ask, answer } = .reach,

        fn once(ask: *@This()) !void {
            return within(ask.client.io, ask.deadline, unbounded, .{ask});
        }

        fn unbounded(ask: *@This()) anyerror!void {
            ask.step = .reach;
            // The body is wanted as the server stores it: a signature or a digest covers those bytes.
            ask.request = try ask.client.request(.GET, ask.uri, .{ .headers = .{ .accept_encoding = .{ .override = "identity" } }, .extra_headers = ask.headers });
            errdefer ask.request.deinit();
            ask.step = .ask;
            try ask.request.sendBodiless();
            ask.step = .answer;
            ask.response = try ask.request.receiveHead(&ask.redirect_buffer);
        }
    };
    var ask: Ask = .{ .client = client, .uri = uri, .headers = headers, .deadline = options.answer };
    retried(io, options.retry, &ask) catch |err| switch (ask.step) {
        .reach => try say.fail(io, "could not reach {s}: {t}", .{ url, err }),
        .ask => try say.fail(io, "could not ask {s}: {t}", .{ url, err }),
        .answer => try say.fail(io, "{s} did not answer: {t}", .{ url, err }),
    };
    defer ask.request.deinit();
    const response = &ask.response;
    const status = response.head.status;
    if (status != .ok) try say.fail(io, "{s} answered {d} {s}", .{ url, @backingInt(status), status.phrase() orelse "" });
    if (response.head.content_encoding != .identity) try say.fail(io, "{s} answered {t}-encoded, not as stored", .{ url, response.head.content_encoding });
    // The body, given `body_deadline`: a stream gone silent ends as one that failed.
    const Body = struct {
        fn take(from: *std.http.Client.Response, into: *Io.Writer, most: u64) anyerror!u64 {
            var transfer_buffer: [64]u8 = undefined;
            const body = from.reader(&transfer_buffer);
            var length: u64 = 0;
            while (true) {
                length += body.stream(into, .limited64(most + 1 - length)) catch |err| switch (err) {
                    error.EndOfStream => return length,
                    else => |e| return e,
                };
                if (length > most) return error.StreamTooLong;
            }
        }
    };
    return within(io, body_deadline, Body.take, .{ response, sink, limit }) catch |err| switch (err) {
        error.ReadFailed => try say.fail(io, "reading {s} failed: {t}", .{ url, response.bodyErr() orelse error.ReadFailed }),
        error.WriteFailed => return error.WriteFailed,
        error.StreamTooLong => try say.fail(io, "{s} is longer than {d} bytes", .{ url, limit }),
        error.Timeout => try say.fail(io, "{s} sent its head and then not all of its body within {f}", .{ url, body_deadline }),
        else => |e| return e,
    };
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

test "a fetch the network fails twice is asked again and answers, and one the server refuses is asked once" {
    const io = std.testing.io;
    const quick: Retry = .{ .wait = .literal("1ms") };
    // A fetch whose first tries fail as `fails` says, and whose next one answers.
    const Stub = struct {
        fails: []const anyerror,
        tries: usize = 0,

        fn once(stub: *@This()) !void {
            stub.tries += 1;
            if (stub.tries <= stub.fails.len) return stub.fails[stub.tries - 1];
        }
    };
    var blips: Stub = .{ .fails = &.{ error.TemporaryNameServerFailure, error.ConnectionResetByPeer } };
    try retried(io, quick, &blips);
    try std.testing.expectEqual(3, blips.tries);
    // A refusal (a status said, a hash that is not the one pinned) is the answer: never asked again.
    var refused: Stub = .{ .fails = &.{error.Reported} };
    try std.testing.expectError(error.Reported, retried(io, quick, &refused));
    try std.testing.expectEqual(1, refused.tries);
    // A network that stays away fails with its own error once the tries are spent.
    var down: Stub = .{ .fails = &.{ error.NetworkUnreachable, error.NetworkUnreachable, error.NetworkUnreachable, error.NetworkUnreachable, error.NetworkUnreachable } };
    try std.testing.expectError(error.NetworkUnreachable, retried(io, quick, &down));
    try std.testing.expectEqual(4, down.tries);
}

/// A server on the loopback that never answers, as a connection gone silent: it listens and
/// accepts nothing, so the system completes each connection from its backlog and the request
/// sent on it waits for good. For the tests of what a request does then.
pub const Silent = struct {
    server: aegis.own.Server,

    pub fn init(io: Io) !Silent {
        const loopback: Io.net.IpAddress = try .parse("127.0.0.1", 0);
        return .{ .server = .init(try loopback.listen(io, .{})) };
    }

    pub fn url(s: *Silent, a: std.mem.Allocator) ![]const u8 {
        return a.print("http://127.0.0.1:{d}", .{s.server.borrow().socket.address.getPort()});
    }

    pub fn deinit(s: *Silent, io: Io) void {
        s.server.deinit(io);
    }
};

test "a request whose connection goes silent is unanswered at its deadline, asked again, and then refused, where it waited for good" {
    const io = std.testing.io;
    var silent: Silent = try .init(io);
    defer silent.deinit(io);
    // A request given up leaves its connection to the arena, as bay's own allocator holds it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = arena.allocator(), .io = io };
    const url = try silent.url(arena.allocator());
    const started = Io.Clock.awake.now(io);
    const asked = getAlloc(&client, arena.allocator(), url, .{ .limit = 16, .answer = .literal("200ms"), .retry = .{ .tries = 2, .wait = .literal("1ms") } });
    const waited = started.durationTo(Io.Clock.awake.now(io));
    try std.testing.expectError(error.Reported, asked);
    // Two tries, each given up at its deadline: well inside a few seconds, and never for good.
    try std.testing.expect(waited.nanoseconds < 5 * std.time.ns_per_s);
}
