//! Prebuilt pins (designs/bay.md §11): an archive Zig's fetch refuses, behind a
//! `bay+https://` URL, brought into Zig's cache by bay. The archive is downloaded no
//! longer than its pin says, checked against its digest and its publisher before a
//! byte of it is unpacked, and kept in bay's data directory by its digest, so a
//! cleared Zig cache is filled again with no network. It is unpacked as Zig's fetch
//! unpacks (archive.zig) and handed to Zig by `zig fetch <dir>`, whose hash must be
//! the pin's.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Sha512 = std.crypto.hash.sha2.Sha512;
const manifest = @import("manifest.zig");
const archive = @import("archive.zig");
const download = @import("download.zig");
const dirs = @import("dirs.zig");
const say = @import("say.zig");

/// Whether `url` is a prebuilt's: bay's prefix before the publisher's URL.
pub fn handles(url: []const u8) bool {
    return std.mem.startsWith(u8, url, manifest.prebuilt_prefix);
}

/// The publisher's URL behind bay's prefix: https alone is fetched.
pub fn publisherUrl(url: []const u8) error{NotHttps}![]const u8 {
    const rest = url[manifest.prebuilt_prefix.len..];
    if (!std.mem.startsWith(u8, rest, "https://")) return error.NotHttps;
    return rest;
}

/// The size of the tree a Zig package hash records (`Package.Hash.init`: the
/// little-endian u32 after the package id, in the base64 of its last 44 characters),
/// saturated at 4 GiB; null for a string that is no such hash.
pub fn treeSize(hash: []const u8) ?u64 {
    if (hash.len < 44) return null;
    var plus: [33]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&plus, hash[hash.len - 44 ..]) catch return null;
    return std.mem.readInt(u32, plus[4..8], .little);
}

/// What bringing a prebuilt needs of this machine.
pub const Context = struct {
    io: Io,
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    zig: []const u8,
    /// Zig's global cache, where `zig fetch` keeps the tree.
    global: []const u8,
    /// NuGet's service index, which names the catalog a `.nuget` publisher is read from.
    nuget_index: []const u8 = "https://api.nuget.org/v3/index.json",
};

/// Puts the prebuilt pinned at `url` as `hash` in Zig's cache: its archive, kept or
/// downloaded and authenticated, unpacked within the size the hash records, and
/// fetched by Zig from the tree, refused unless Zig's hash is the pin's. An OpenPGP
/// publisher's key file is the path `pin` names, as the package holding the pin resolves it.
pub fn bring(c: Context, url: []const u8, hash: []const u8, pin: manifest.Prebuilt) !void {
    const io = c.io;
    const a = c.a;
    const https = publisherUrl(url) catch try say.fail(io, "{s}: a prebuilt is fetched over https alone (bay+https://)", .{url});
    const bound = treeSize(hash) orelse try say.fail(io, "{s} is pinned as {s}, which is no hash Zig gives a package", .{ url, hash });
    const kept = try std.fs.path.join(a, &.{ try dirs.data(io, a, c.environ), "prebuilt" });
    try Io.Dir.cwd().createDirPath(io, kept);
    // One at a time: another bay bringing a prebuilt waits here, then finds what it brought.
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ kept, "fetch.lock" }), .{ .lock = .exclusive, .truncate = false });
    defer lock.close(io);
    const path = try std.fs.path.join(a, &.{ kept, try a.print("{x}", .{&pin.sha256}) });
    const expected: archive.Expected = .{ .sha256 = pin.sha256, .size = pin.size };
    const authenticated = try keptArchive(c, path, expected) orelse try fetchArchive(c, https, path, expected, pin.publisher);
    const tree = try a.print("{s}.tree", .{path});
    // What a bring that stopped left; the lock says no other is using it.
    try Io.Dir.cwd().deleteTree(io, tree);
    var diagnostic: archive.Diagnostic = .{};
    archive.unpack(io, a, authenticated, tree, bound, &diagnostic) catch |err| switch (err) {
        error.Malformed => try say.fail(io, "{s} is not an archive std reads", .{url}),
        error.WindowTooLarge => try say.fail(io, "{s} declares a zstd window above 128 MiB, or none", .{url}),
        error.UnsupportedEntry => try say.fail(io, "{s} holds {s}, which is neither a file, a directory nor a link", .{ url, diagnostic.entry }),
        error.UnsupportedMethod => try say.fail(io, "{s} holds {s}, compressed by a method other than stored or deflate", .{ url, diagnostic.entry }),
        error.Encrypted => try say.fail(io, "{s} holds an encrypted entry", .{url}),
        error.UnsafeName => try say.fail(io, "{s} holds {s}, a name that leaves the tree or that some system cannot hold", .{ url, diagnostic.entry }),
        error.NameClash => try say.fail(io, "{s} holds {s} twice where case folds, or as a file and a directory", .{ url, diagnostic.entry }),
        error.LinkOutside => try say.fail(io, "{s} holds {s}, a link out of its tree", .{ url, diagnostic.entry }),
        error.TooLarge => try say.fail(io, "{s} unpacks past {d} bytes, the size {s} records, at {s}", .{ url, bound, hash, diagnostic.entry }),
        error.ArchiveChanged => try say.fail(io, "{s} changed while it was read", .{path}),
        else => |e| return e,
    };
    const fetched = try zigFetch(c, tree);
    if (!std.mem.eql(u8, fetched, hash)) try say.fail(io, "{s} unpacks to {s}, but it is pinned as {s}: the pin names another tree", .{ url, fetched, hash });
    try Io.Dir.cwd().deleteTree(io, tree);
}

/// The archive kept at `path`, if it is there and still the pin's; one that is not
/// is removed, to be downloaded again. Its publisher was checked when it was kept.
fn keptArchive(c: Context, path: []const u8, expected: archive.Expected) !?archive.Authenticated {
    return archive.authenticate(c.io, c.a, path, expected, .none) catch |err| switch (err) {
        error.FileNotFound => null,
        error.SizeMismatch, error.DigestMismatch => {
            try Io.Dir.cwd().deleteFile(c.io, path);
            return null;
        },
        else => |e| return e,
    };
}

/// The archive downloaded to `path`, no longer than its pin says, then authenticated
/// by its pin and its publisher: kept only once both hold.
fn fetchArchive(c: Context, https: []const u8, path: []const u8, expected: archive.Expected, publisher: manifest.Publisher) !archive.Authenticated {
    const io = c.io;
    const a = c.a;
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    client.initDefaultProxies(a, c.environ) catch |err| try say.fail(io, "the proxy settings are not usable: {t}", .{err});
    const partial = try a.print("{s}.partial", .{path});
    {
        const file = try Io.Dir.cwd().createFile(io, partial, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try say.note(io, "downloading {s}", .{https});
        _ = download.get(&client, https, &writer.interface, expected.size) catch |err| switch (err) {
            error.WriteFailed => return writer.err orelse err,
            else => |e| return e,
        };
        try writer.interface.flush();
    }
    const word: archive.Publisher = switch (publisher) {
        .none => .none,
        .minisign => |key| .{ .minisign = .{ .key = key, .signature = try download.getAlloc(&client, a, try a.print("{s}.minisig", .{https}), 4096), .file = fileName(https) } },
        .openpgp => |key_file| .{ .openpgp = .{
            .keys = aegis.own.readFile(io, Io.Dir.cwd(), key_file, a, .fromRaw(1 << 20)) catch |err| try say.fail(io, "could not read {s}, the key {s}'s pin names: {t}", .{ key_file, https, err }),
            .signature = try download.getAlloc(&client, a, try a.print("{s}.sig", .{https}), 64 * 1024),
        } },
        .nuget => .{ .sha512 = try nugetHash(c, &client, https) },
    };
    const authenticated = archive.authenticate(io, a, partial, expected, word) catch |err| switch (err) {
        error.SizeMismatch => try say.fail(io, "{s} is not {d} bytes, as its pin says", .{ https, expected.size }),
        error.DigestMismatch => try say.fail(io, "{s}'s SHA-256 is not its pin's: it is another archive", .{https}),
        error.PublisherMismatch => try say.fail(io, "{s} is not what its publisher vouches for ({t})", .{ https, publisher }),
        error.Xz => try say.fail(io, "{s} is xz, which bay does not read", .{https}),
        error.Bzip2 => try say.fail(io, "{s} is bzip2, which bay does not read", .{https}),
        error.UnknownFormat => try say.fail(io, "{s} is no archive bay reads: a tar in gzip or zstd, or a zip", .{https}),
        else => |e| return e,
    };
    try Io.Dir.rename(.cwd(), partial, .cwd(), path, io);
    return .{ .path = path, .format = authenticated.format };
}

/// The last part of a URL's path: the file a publisher's signature names.
fn fileName(url: []const u8) []const u8 {
    const path = url[0 .. std.mem.findAny(u8, url, "?#") orelse url.len];
    return path[(std.mem.findScalarLast(u8, path, '/') orelse return path) + 1 ..];
}

/// Zig's hash of the tree at `tree`, as `zig fetch` prints it, the tree kept in Zig's cache.
fn zigFetch(c: Context, tree: []const u8) ![]const u8 {
    const result = std.process.run(c.a, c.io, .{ .argv = &.{ c.zig, "fetch", "--global-cache-dir", c.global, tree }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(c.io, "could not run {s} fetch: {t}", .{ c.zig, err });
    if (result.term != .exited or result.term.exited != 0) {
        try say.relay(c.io, result.stderr);
        try say.fail(c.io, "{s} fetch refused {s}", .{ c.zig, tree });
    }
    return std.mem.trim(u8, result.stdout, " \r\n");
}

/// The SHA-512 nuget.org's catalog holds for the package at `https`, which must be in
/// the index's package base, as `<id>/<version>/<id>.<version>.nupkg`: nuget.org's word
/// over TLS, read apart from the package (designs/bay.md §11).
fn nugetHash(c: Context, client: *std.http.Client, https: []const u8) ![Sha512.digest_length]u8 {
    const io = c.io;
    const a = c.a;
    const resources = nugetResources(a, try download.getAlloc(client, a, c.nuget_index, 1 << 20)) catch
        try say.fail(io, "{s} is not a NuGet service index bay can read", .{c.nuget_index});
    const package = nugetPackage(resources.base, https) orelse
        try say.fail(io, "{s} is not a package under {s}, the base {s} names, as <id>/<version>/<id>.<version>.nupkg", .{ https, resources.base, c.nuget_index });
    const registration_url = try a.print("{s}{s}/{s}.json", .{ resources.registrations, package.id, package.version });
    const entry = catalogEntry(a, try download.getAlloc(client, a, registration_url, 1 << 20)) catch
        try say.fail(io, "{s} names no catalog entry", .{registration_url});
    return packageHash(a, try download.getAlloc(client, a, entry, 1 << 20), package) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.OtherPackage => try say.fail(io, "{s} is the catalog entry of another package than {s} {s}", .{ entry, package.id, package.version }),
        error.NotSha512 => try say.fail(io, "{s} gives the package's hash by another algorithm than SHA-512", .{entry}),
        error.Unreadable => try say.fail(io, "{s} gives no package hash bay can read", .{entry}),
    };
}

/// The two resources of a NuGet service index a `.nuget` publisher reads.
const Resources = struct { base: []const u8, registrations: []const u8 };

fn nugetResources(a: std.mem.Allocator, text: []const u8) !Resources {
    const index = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const list = switch (index) {
        .object => |object| switch (object.get("resources") orelse return error.Unreadable) {
            .array => |array| array.items,
            else => return error.Unreadable,
        },
        else => return error.Unreadable,
    };
    var base: ?[]const u8 = null;
    var registrations: ?[]const u8 = null;
    for (list) |resource| {
        const kind = field(resource, "@type") orelse continue;
        const id = field(resource, "@id") orelse continue;
        // The registrations NuGet serves uncompressed: the base type, without a version.
        if (std.mem.eql(u8, kind, "PackageBaseAddress/3.0.0")) base = id else if (std.mem.eql(u8, kind, "RegistrationsBaseUrl")) registrations = id;
    }
    return .{ .base = base orelse return error.Unreadable, .registrations = registrations orelse return error.Unreadable };
}

/// A NuGet package's id and version, lowercase as the package base serves them.
const Package = struct { id: []const u8, version: []const u8 };

fn nugetPackage(base: []const u8, url: []const u8) ?Package {
    if (!std.mem.startsWith(u8, url, base)) return null;
    var parts = std.mem.splitScalar(u8, url[base.len..], '/');
    const id = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    const file = parts.next() orelse return null;
    if (parts.next() != null or id.len == 0 or version.len == 0) return null;
    // `<id>.<version>.nupkg`
    if (!std.mem.startsWith(u8, file, id) or file.len != id.len + 1 + version.len + ".nupkg".len) return null;
    if (file[id.len] != '.' or !std.mem.eql(u8, file[id.len + 1 ..][0..version.len], version) or !std.mem.endsWith(u8, file, ".nupkg")) return null;
    return .{ .id = id, .version = version };
}

fn catalogEntry(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return field(try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}), "catalogEntry") orelse error.Unreadable;
}

fn packageHash(a: std.mem.Allocator, text: []const u8, package: Package) error{ OutOfMemory, OtherPackage, NotSha512, Unreadable }![Sha512.digest_length]u8 {
    const entry = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.Unreadable,
    };
    // NuGet's ids are compared ignoring case; the catalog spells the id as its author did.
    if (!std.ascii.eqlIgnoreCase(field(entry, "id") orelse "", package.id) or !std.ascii.eqlIgnoreCase(field(entry, "version") orelse "", package.version)) return error.OtherPackage;
    if (!std.mem.eql(u8, field(entry, "packageHashAlgorithm") orelse "", "SHA512")) return error.NotSha512;
    const encoded = field(entry, "packageHash") orelse return error.Unreadable;
    var hash: [Sha512.digest_length]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    if ((decoder.calcSizeForSlice(encoded) catch return error.Unreadable) != hash.len) return error.Unreadable;
    decoder.decode(&hash, encoded) catch return error.Unreadable;
    return hash;
}

/// An object's string field, or null.
fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
    return switch (value) {
        .object => |object| switch (object.get(name) orelse return null) {
            .string => |text| text,
            else => null,
        },
        else => null,
    };
}

const testing = std.testing;

test "a prebuilt's URL is bay's prefix before https; any other scheme is refused" {
    try testing.expect(handles("bay+https://repo.msys2.org/a.pkg.tar.zst"));
    try testing.expect(!handles("https://repo.msys2.org/a.tar.gz"));
    try testing.expectEqualStrings("https://repo.msys2.org/a.pkg.tar.zst", try publisherUrl("bay+https://repo.msys2.org/a.pkg.tar.zst"));
    try testing.expectError(error.NotHttps, publisherUrl("bay+http://repo.msys2.org/a.pkg.tar.zst"));
    try testing.expectError(error.NotHttps, publisherUrl("bay+file:///tmp/a.zip"));
}

test "the tree's size is what Zig's hash records" {
    try testing.expectEqual(null, treeSize("N-V-short"));
    var plus: [33]u8 = @splat(0);
    std.mem.writeInt(u32, plus[4..8], 6218920, .little);
    var encoded: [44]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &plus);
    try testing.expectEqual(6218920, treeSize("N-V-" ++ encoded));
}

test "a publisher's signature names the file at the URL's end" {
    try testing.expectEqualStrings("layers-1.4.363.0-1-any.pkg.tar.zst", fileName("https://repo.msys2.org/mingw/clang64/layers-1.4.363.0-1-any.pkg.tar.zst"));
    try testing.expectEqualStrings("a.zip", fileName("https://example.org/a.zip?download=1"));
}

// nuget.org's documents for Microsoft.Direct3D.D3D12 1.619.6, read 2026-10-30, cut to what bay reads.
const recorded_index =
    \\{"version":"3.0.0","resources":[
    \\{"@id":"https://api.nuget.org/v3-flatcontainer/","@type":"PackageBaseAddress/3.0.0"},
    \\{"@id":"https://api.nuget.org/v3/registration5-gz-semver2/","@type":"RegistrationsBaseUrl/3.6.0"},
    \\{"@id":"https://api.nuget.org/v3/registration5-semver1/","@type":"RegistrationsBaseUrl"}]}
;
const recorded_registration =
    \\{"@id":"https://api.nuget.org/v3/registration5-semver1/microsoft.direct3d.d3d12/1.619.6.json","catalogEntry":"https://api.nuget.org/v3/catalog0/data/2026.09.14.18.31.16/microsoft.direct3d.d3d12.1.619.6.json","listed":true}
;
const recorded_catalog =
    \\{"id":"Microsoft.Direct3D.D3D12","version":"1.619.6","packageHash":"V7Lh8h7KdHNjYEZZOEofKRaxDWseDIOMgIZduG+bEBUEFHy+mBZRnKD5DDgKLrSweW08mbpgJ8UoIYZWiDiLkw==","packageHashAlgorithm":"SHA512"}
;

test "nuget.org's index, registration and catalog give the package's SHA-512" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resources = try nugetResources(a, recorded_index);
    try testing.expectEqualStrings("https://api.nuget.org/v3-flatcontainer/", resources.base);
    try testing.expectEqualStrings("https://api.nuget.org/v3/registration5-semver1/", resources.registrations);
    const package = nugetPackage(resources.base, "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/1.619.6/microsoft.direct3d.d3d12.1.619.6.nupkg").?;
    try testing.expectEqualStrings("microsoft.direct3d.d3d12", package.id);
    try testing.expectEqualStrings("1.619.6", package.version);
    try testing.expectEqualStrings("https://api.nuget.org/v3/catalog0/data/2026.09.14.18.31.16/microsoft.direct3d.d3d12.1.619.6.json", try catalogEntry(a, recorded_registration));
    const hash = try packageHash(a, recorded_catalog, package);
    try testing.expectEqualStrings("57b2e1f21eca74", &std.fmt.bytesToHex(hash[0..7], .lower));
}

test "a package outside the index's base, or a catalog of another package or algorithm, is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "https://api.nuget.org/v3-flatcontainer/";
    try testing.expectEqual(null, nugetPackage(base, "https://example.org/v3-flatcontainer/x/1.0.0/x.1.0.0.nupkg"));
    try testing.expectEqual(null, nugetPackage(base, base ++ "x/1.0.0/y.1.0.0.nupkg"));
    try testing.expectEqual(null, nugetPackage(base, base ++ "x/1.0.0/x.1.0.1.nupkg"));
    try testing.expectEqual(null, nugetPackage(base, base ++ "x/1.0.0/x.1.0.0.nupkg/more"));
    const package: Package = .{ .id = "microsoft.direct3d.d3d12", .version = "1.619.6" };
    try testing.expectError(error.OtherPackage, packageHash(a, recorded_catalog, .{ .id = "microsoft.direct3d.d3d12", .version = "1.619.5" }));
    try testing.expectError(error.NotSha512, packageHash(a, "{\"id\":\"Microsoft.Direct3D.D3D12\",\"version\":\"1.619.6\",\"packageHash\":\"AA==\",\"packageHashAlgorithm\":\"SHA256\"}", package));
    try testing.expectError(error.Unreadable, packageHash(a, "{\"id\":\"Microsoft.Direct3D.D3D12\",\"version\":\"1.619.6\",\"packageHash\":\"AA==\",\"packageHashAlgorithm\":\"SHA512\"}", package));
    try testing.expectError(error.Unreadable, nugetResources(a, "{\"resources\":[]}"));
}
