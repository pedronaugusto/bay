//! Prebuilt pins end to end (designs/bay.md §11): an archive Zig's fetch refuses,
//! served from this machine's loopback address as its publisher would serve it,
//! brought into Zig's cache by bay, checked by its digest and its publisher's
//! signature, and built from by a package that names it as any dependency.
const std = @import("std");
const Io = std.Io;
const options = @import("options");
const flate = std.compress.flate;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const succeeded = fixture.succeeded;
const refused = fixture.refused;

/// A file the loopback server answers with, by its path.
const Served = struct { path: []const u8, body: []const u8 };

/// Answers each connection's one request with the file at its path, or 404, until canceled.
fn serve(io: Io, listener: *Io.net.Server, files: []const Served) !void {
    while (true) {
        const stream = try listener.accept(io);
        defer stream.close(io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var input = stream.reader(io, &read_buffer);
        var output = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&input.interface, &output.interface);
        var request = try server.receiveHead();
        const body = for (files) |file| {
            if (std.mem.eql(u8, file.path, request.head.target)) break file.body;
        } else null;
        if (body) |bytes| try request.respond(bytes, .{ .keep_alive = false }) else try request.respond("", .{ .status = .not_found, .keep_alive = false });
    }
}

/// `tar` in gzip, its deflate blocks stored.
fn gzipOf(a: std.mem.Allocator, tar: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    var compress: flate.Compress.Raw = try .init(&out.writer, try a.alloc(u8, flate.max_window_len), .gzip);
    try compress.writer.writeAll(tar);
    try compress.finish();
    return out.written();
}

/// A minisign key, and a signature it makes as minisign's legacy form writes one (`Ed`:
/// over the file itself), its trusted comment naming `file`.
const Signer = struct {
    pair: Ed25519.KeyPair,
    const id = "prebuilt".*;

    fn publicKey(signer: Signer, a: std.mem.Allocator) ![]const u8 {
        const bytes = "Ed".* ++ id ++ signer.pair.public_key.toBytes();
        const text = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        return std.base64.standard.Encoder.encode(text, &bytes);
    }

    fn sign(signer: Signer, a: std.mem.Allocator, bytes: []const u8, file: []const u8) ![]const u8 {
        const comment = try a.print("timestamp:1\tfile:{s}", .{file});
        const signature = (try signer.pair.sign(bytes, null)).toBytes();
        const global = (try signer.pair.sign(try std.mem.concat(a, u8, &.{ &signature, comment }), null)).toBytes();
        const encoder = std.base64.standard.Encoder;
        var line: [100]u8 = undefined;
        var global_line: [100]u8 = undefined;
        return a.print("untrusted comment: a prebuilt's publisher\n{s}\ntrusted comment: {s}\n{s}\n", .{ encoder.encode(&line, &("Ed".* ++ id ++ signature)), comment, encoder.encode(&global_line, &global) });
    }
};

test "a prebuilt pin is brought by bay fetch, checked by its digest and its publisher's signature, and built from" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const a = f.a;
    // What the publisher ships, under one top directory, as an archive Zig's fetch is not given.
    const files = [_]Served{
        .{ .path = "LICENSE", .body = "MIT License\n" },
        .{ .path = "lib/data.zig", .body = "pub const text = \"from the prebuilt\";\n" },
    };
    var tar: Io.Writer.Allocating = .init(a);
    var writer: std.tar.Writer = .{ .underlying_writer = &tar.writer };
    try writer.setRoot("layers-1");
    for (files) |file| try writer.writeFileBytes(file.path, file.body, .{});
    try writer.finishPedantically();
    const archive = try gzipOf(a, tar.written());
    var sha256: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(archive, &sha256, .{});
    // The hash Zig gives the tree the archive holds once its top directory is taken away;
    // then out of Zig's cache, so only bay can bring it back.
    for (files) |file| {
        try f.tmp.dir.createDirPath(f.io, try std.fs.path.join(a, &.{ "tree", std.fs.path.dirname(file.path) orelse "." }));
        try f.write("tree", file.path, file.body);
    }
    const hashed = try std.process.run(a, f.io, .{ .argv = &.{ options.zig, "fetch", try std.fs.path.join(a, &.{ f.root, "tree" }) }, .environ_map = &f.env });
    try std.testing.expect(succeeded(hashed));
    const hash = std.mem.trim(u8, hashed.stdout, "\r\n");
    const packages = try std.fs.path.join(a, &.{ f.env.get("ZIG_GLOBAL_CACHE_DIR").?, "p" });
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ packages, hash }));
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ packages, try a.print("{s}.tar.gz", .{hash}) }));

    const signer: Signer = .{ .pair = try .generateDeterministic(@splat(9)) };
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(f.io, .{});
    defer listener.deinit(f.io);
    const served = [_]Served{
        .{ .path = "/layers-1.tar.gz", .body = archive },
        .{ .path = "/layers-1.tar.gz.minisig", .body = try signer.sign(a, archive, "layers-1.tar.gz") },
    };
    var server = try f.io.concurrent(serve, .{ f.io, &listener, &served });
    defer server.cancel(f.io) catch {};
    const url = try a.print("bay+http://127.0.0.1:{d}/layers-1.tar.gz", .{listener.socket.address.getPort()});

    const build =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const layers = b.dependency("layers", .{});
        \\    const m = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host });
        \\    m.addImport("data", b.createModule(.{ .root_source_file = layers.path("lib/data.zig") }));
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = m });
        \\    b.step("run", "Run").dependOn(&b.addRunArtifact(exe).step);
        \\}
        \\
    ;
    for ([_][]const u8{ "app", "forged" }) |dir| {
        try f.tmp.dir.createDirPath(f.io, try std.fs.path.join(a, &.{ dir, "src" }));
        // The forged pin holds another digest than the archive's.
        var digest = sha256;
        if (std.mem.eql(u8, dir, "forged")) digest[0] ^= 1;
        try f.write(dir, "build.zig.zon", try a.print(
            \\.{{ .name = .{s}, .version = "0.1.0", .fingerprint = 0x{x}, .minimum_zig_version = "0.17.0", .paths = .{{""}}, .dependencies = .{{ .layers = .{{
            \\    .url = "{s}", .hash = "{s}", .sha256 = "{x}", .size = {d},
            \\    .publisher = .{{ .minisign = "{s}" }}, .license = "LICENSE",
            \\}} }} }}
            \\
        , .{ dir, fixture.fingerprint(dir), url, hash, &digest, archive.len, try signer.publicKey(a) }));
        try f.write(dir, "build.zig", build);
        try f.write(dir, "src/main.zig", "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"{s}\\n\", .{@import(\"data\").text}); }");
    }

    const fetched = try f.bay("app", &.{"fetch"});
    if (!succeeded(fetched)) std.debug.print("{s}\n", .{fetched.stderr});
    try std.testing.expect(succeeded(fetched));
    const ran = try f.bay("app", &.{ "build", "run" });
    if (!succeeded(ran)) std.debug.print("{s}\n", .{ran.stderr});
    try std.testing.expect(succeeded(ran));
    try std.testing.expect(std.mem.find(u8, ran.stderr, "from the prebuilt") != null);

    // A tree Zig holds by its hash is that tree: bay downloads nothing then, and checks
    // nothing. Out of Zig's cache again, the forged pin's archive is downloaded and refused.
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ packages, hash }));
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ packages, try a.print("{s}.tar.gz", .{hash}) }));
    const forged = try f.bay("forged", &.{"fetch"});
    try std.testing.expect(refused(forged));
    try std.testing.expect(std.mem.find(u8, forged.stderr, "SHA-256 is not its pin's") != null);
}
