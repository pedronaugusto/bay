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

/// An archive a publisher ships: a tar.gz of `files` under one top directory, its
/// SHA-256, and the hash Zig gives the tree it holds, which is then taken out of Zig's
/// cache, so only bay brings it back.
const Published = struct {
    archive: []const u8,
    sha256: [Sha256.digest_length]u8,
    hash: []const u8,

    fn init(f: *Fixture, top: []const u8, files: []const Served) !Published {
        const a = f.a;
        var tar: Io.Writer.Allocating = .init(a);
        var writer: std.tar.Writer = .{ .underlying_writer = &tar.writer };
        try writer.setRoot(top);
        for (files) |file| try writer.writeFileBytes(file.path, file.body, .{});
        try writer.finishPedantically();
        const archive = try gzipOf(a, tar.written());
        var sha256: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(archive, &sha256, .{});
        const tree = try a.print("{s}-tree", .{top});
        for (files) |file| {
            try f.tmp.dir.createDirPath(f.io, try std.fs.path.join(a, &.{ tree, std.fs.path.dirname(file.path) orelse "." }));
            try f.write(tree, file.path, file.body);
        }
        const hashed = try std.process.run(a, f.io, .{ .argv = &.{ options.zig, "fetch", try std.fs.path.join(a, &.{ f.root, tree }) }, .environ_map = &f.env });
        try std.testing.expect(succeeded(hashed));
        const published: Published = .{ .archive = archive, .sha256 = sha256, .hash = std.mem.trim(u8, hashed.stdout, "\r\n") };
        try published.uncached(f);
        return published;
    }

    /// Zig's copy of the tree gone from its cache.
    fn uncached(published: Published, f: *Fixture) !void {
        const packages = try std.fs.path.join(f.a, &.{ f.env.get("ZIG_GLOBAL_CACHE_DIR").?, "p" });
        try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, published.hash }));
        try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(f.a, &.{ packages, try f.a.print("{s}.tar.gz", .{published.hash}) }));
    }

    /// Whether bay keeps the archive in its data directory: it was brought.
    fn kept(published: Published, f: *Fixture) bool {
        const path = std.fs.path.join(f.a, &.{ f.root, "data", "bay", "prebuilt", f.a.print("{x}", .{&published.sha256}) catch return false }) catch return false;
        Io.Dir.cwd().access(f.io, path, .{}) catch return false;
        return true;
    }

    /// A dependency entry pinning the archive at `url`, its publisher `publisher` (ZON).
    fn pin(published: Published, f: *Fixture, name: []const u8, url: []const u8, publisher: []const u8, lazy: bool) ![]const u8 {
        return f.a.print(".{s} = .{{ .url = \"{s}\", .hash = \"{s}\", .lazy = {}, .sha256 = \"{x}\", .size = {d}, .publisher = {s}, .license = \"LICENSE\" }},", .{ name, url, published.hash, lazy, &published.sha256, published.archive.len, publisher });
    }
};

/// A package `dir` whose build is `build` and whose program prints `@import("data").text`.
fn consumer(f: *Fixture, dir: []const u8, dependencies: []const u8, build: []const u8) !void {
    try f.tmp.dir.createDirPath(f.io, try std.fs.path.join(f.a, &.{ dir, "src" }));
    try f.write(dir, "build.zig.zon", try f.a.print(".{{ .name = .{s}, .version = \"0.1.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .paths = .{{\"\"}}, .dependencies = .{{ {s} }} }}\n", .{ dir, fixture.fingerprint(dir), dependencies }));
    try f.write(dir, "build.zig", build);
    try f.write(dir, "src/main.zig", "const std = @import(\"std\"); pub fn main() void { std.debug.print(\"{s}\\n\", .{@import(\"data\").text}); }");
}

/// A build whose program's `data` is the prebuilt `layers`' `lib/data.zig`.
const build_from_layers =
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

test "a prebuilt pin is brought by bay fetch, checked by its digest and its publisher's signature, and built from" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const a = f.a;
    const layers: Published = try .init(&f, "layers-1", &.{
        .{ .path = "LICENSE", .body = "MIT License\n" },
        .{ .path = "lib/data.zig", .body = "pub const text = \"from the prebuilt\";\n" },
    });
    const signer: Signer = .{ .pair = try .generateDeterministic(@splat(9)) };
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(f.io, .{});
    defer listener.deinit(f.io);
    const served = [_]Served{
        .{ .path = "/layers-1.tar.gz", .body = layers.archive },
        .{ .path = "/layers-1.tar.gz.minisig", .body = try signer.sign(a, layers.archive, "layers-1.tar.gz") },
    };
    var server = try f.io.concurrent(serve, .{ f.io, &listener, &served });
    defer server.cancel(f.io) catch {};
    const url = try a.print("bay+http://127.0.0.1:{d}/layers-1.tar.gz", .{listener.socket.address.getPort()});
    const publisher = try a.print(".{{ .minisign = \"{s}\" }}", .{try signer.publicKey(a)});
    try consumer(&f, "app", try layers.pin(&f, "layers", url, publisher, false), build_from_layers);
    // The forged pin holds another digest than the archive's.
    var forged_pin = layers;
    forged_pin.sha256[0] ^= 1;
    try consumer(&f, "forged", try forged_pin.pin(&f, "layers", url, publisher, false), build_from_layers);

    const fetched = try f.bay("app", &.{"fetch"});
    if (!succeeded(fetched)) std.debug.print("{s}\n", .{fetched.stderr});
    try std.testing.expect(succeeded(fetched));
    const ran = try f.bay("app", &.{ "build", "run" });
    if (!succeeded(ran)) std.debug.print("{s}\n", .{ran.stderr});
    try std.testing.expect(succeeded(ran));
    try std.testing.expect(std.mem.find(u8, ran.stderr, "from the prebuilt") != null);

    // Vendored, the prebuilt is in the package's zig-pkg: gone from Zig's cache and from bay's,
    // the build takes it from there and downloads nothing.
    // The build unpacked it there already, as Zig 0.17 unpacks what a build takes, and Zig and
    // bay keep it: all gone first, so vendoring brings it.
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ f.root, "app", "zig-pkg" }));
    try layers.uncached(&f);
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ f.root, "data", "bay", "prebuilt" }));
    const vendored = try f.bay("app", &.{"vendor"});
    if (!succeeded(vendored)) std.debug.print("{s}\n", .{vendored.stderr});
    try std.testing.expect(succeeded(vendored));
    try layers.uncached(&f);
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ f.root, "data", "bay", "prebuilt" }));
    const offline = try f.bay("app", &.{ "build", "run" });
    if (!succeeded(offline)) std.debug.print("{s}\n", .{offline.stderr});
    try std.testing.expect(succeeded(offline));
    try std.testing.expect(!layers.kept(&f));

    // A tree Zig holds by its hash is that tree: bay downloads nothing then, and checks
    // nothing. Out of Zig's cache again, the forged pin's archive is downloaded and refused.
    try layers.uncached(&f);
    const forged = try f.bay("forged", &.{"fetch"});
    try std.testing.expect(refused(forged));
    try std.testing.expect(std.mem.find(u8, forged.stderr, "SHA-256 is not its pin's") != null);
}

test "a build brings the prebuilts it takes: one not lazy before it runs, a lazy one only when its configuration asks for it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var f: Fixture = try .init(arena.allocator());
    defer f.deinit();
    const a = f.a;
    const always: Published = try .init(&f, "always-1", &.{
        .{ .path = "LICENSE", .body = "MIT License\n" },
        .{ .path = "lib/data.zig", .body = "pub const text = \"from the one always taken\";\n" },
    });
    const asked: Published = try .init(&f, "asked-1", &.{
        .{ .path = "LICENSE", .body = "MIT License\n" },
        .{ .path = "lib/data.zig", .body = "pub const text = \"from the one asked for\";\n" },
    });
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(f.io, .{});
    defer listener.deinit(f.io);
    const served = [_]Served{
        .{ .path = "/always-1.tar.gz", .body = always.archive },
        .{ .path = "/asked-1.tar.gz", .body = asked.archive },
    };
    var server = try f.io.concurrent(serve, .{ f.io, &listener, &served });
    defer server.cancel(f.io) catch {};
    const port = listener.socket.address.getPort();
    const pins = try std.mem.concat(a, u8, &.{
        try always.pin(&f, "always", try a.print("bay+http://127.0.0.1:{d}/always-1.tar.gz", .{port}), ".none", false),
        try asked.pin(&f, "asked", try a.print("bay+http://127.0.0.1:{d}/asked-1.tar.gz", .{port}), ".none", true),
    });
    try consumer(&f, "app", pins,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const always = b.dependency("always", .{});
        \\    const data = if (b.option(bool, "asked", "Take the lazy prebuilt") orelse false)
        \\        (b.lazyDependency("asked", .{}) orelse return).path("lib/data.zig")
        \\    else
        \\        always.path("lib/data.zig");
        \\    const m = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host });
        \\    m.addImport("data", b.createModule(.{ .root_source_file = data }));
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = m });
        \\    b.step("run", "Run").dependOn(&b.addRunArtifact(exe).step);
        \\}
        \\
    );

    const plain = try f.bay("app", &.{ "build", "run" });
    if (!succeeded(plain)) std.debug.print("{s}\n", .{plain.stderr});
    try std.testing.expect(succeeded(plain));
    try std.testing.expect(std.mem.find(u8, plain.stderr, "from the one always taken") != null);
    try std.testing.expect(always.kept(&f));
    try std.testing.expect(!asked.kept(&f));

    // The line bay's probe reads, as this Zig writes it: a Zig that changes it turns this red.
    const probed = try f.run("app", &.{ options.zig, "build", "-Dasked", "-l" });
    try std.testing.expect(std.mem.find(u8, probed.stderr, try a.print("info: fetching lazy dependency {s}\n", .{asked.hash})) != null);
    const asking = try f.bay("app", &.{ "build", "-Dasked", "run" });
    if (!succeeded(asking)) std.debug.print("{s}\n", .{asking.stderr});
    try std.testing.expect(succeeded(asking));
    try std.testing.expect(std.mem.find(u8, asking.stderr, "from the one asked for") != null);
    try std.testing.expect(asked.kept(&f));
}
