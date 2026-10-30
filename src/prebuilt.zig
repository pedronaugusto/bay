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

/// The publisher's URL behind bay's prefix: https, or plain http to this machine's
/// loopback address by number (`127.0.0.0/8`, `[::1]`), which no network carries, as a
/// mirror on this machine serves.
pub fn publisherUrl(url: []const u8) error{NotHttps}![]const u8 {
    const rest = url[manifest.prebuilt_prefix.len..];
    if (std.mem.startsWith(u8, rest, "https://")) return rest;
    if (!std.mem.startsWith(u8, rest, "http://")) return error.NotHttps;
    const uri = std.Uri.parse(rest) catch return error.NotHttps;
    const host = switch (uri.host orelse return error.NotHttps) {
        inline else => |text| text,
    };
    if (std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1")) return rest;
    const address = Io.net.Ip4Address.parse(host, 0) catch return error.NotHttps;
    if (address.bytes[0] != 127) return error.NotHttps;
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

/// The hash Zig gives a package, read as `zig fetch` prints it: `name-version-` and 44
/// base64url characters, no longer than `Package.Hash.max_len`, the name an identifier's
/// characters and the version semver's. Zig keeps the tree under it as one folder's name, as
/// bay's store does, so it holds no separator and no `..`.
pub const ZigHash = struct {
    text: []const u8,

    pub const Error = error{NotPackageHash};

    pub fn parse(_: void, text: []const u8) Error!ZigHash {
        const hash = std.mem.trim(u8, text, " \r\n");
        if (hash.len < 44 or hash.len > 32 + 1 + 32 + 1 + 44) return error.NotPackageHash;
        const head = hash[0 .. hash.len - 44];
        const name_end = std.mem.findScalar(u8, head, '-') orelse return error.NotPackageHash;
        if (name_end == 0 or name_end > 32 or name_end + 2 >= head.len or head[head.len - 1] != '-') return error.NotPackageHash;
        for (head[0..name_end]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.NotPackageHash;
        const version = head[name_end + 1 .. head.len - 1];
        if (version.len > 32 or std.mem.find(u8, version, "..") != null) return error.NotPackageHash;
        for (version) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "-.+", byte) == null) return error.NotPackageHash;
        if (treeSize(hash) == null) return error.NotPackageHash;
        return .{ .text = hash };
    }
};

/// What bringing a prebuilt needs of this machine.
pub const Context = struct {
    io: Io,
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    /// The Zig whose cache takes the tree: the one the package builds with.
    zig: []const u8,
};

/// Puts the prebuilt pinned at `url` as `hash` in Zig's cache: its archive, kept or
/// downloaded and authenticated, unpacked within the size the hash records, and
/// fetched by Zig from the tree, refused unless Zig's hash is the pin's. An OpenPGP
/// publisher's key file is the path `fields` names, as the package holding the pin resolves it.
pub fn bring(c: Context, url: []const u8, hash: []const u8, fields: manifest.Prebuilt) !void {
    const io = c.io;
    const a = c.a;
    const https = try httpsOf(c, url, fields.publisher);
    const bound = treeSize(hash) orelse try say.fail(io, "{s} is pinned as {s}, which is no hash Zig gives a package", .{ url, hash });
    const kept = try keptDirectory(c);
    // One at a time: another bay bringing a prebuilt waits here, then finds what it brought.
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ kept, "fetch.lock" }), .{ .lock = .exclusive, .truncate = false });
    defer lock.close(io);
    const expected: archive.Expected = .{ .sha256 = fields.sha256, .size = fields.size };
    const authenticated = try keptArchive(c, try std.fs.path.join(a, &.{ kept, try a.print("{x}", .{&fields.sha256}) }), expected) orelse
        (try fetchArchive(c, https, kept, expected, fields.publisher, fields.publisher)).archive;
    const tree = try unpacked(c, url, authenticated, bound, hash);
    const fetched = try zigFetch(c, tree);
    if (!std.mem.eql(u8, fetched, hash)) try say.fail(io, "{s} unpacks to {s}, but it is pinned as {s}: the pin names another tree", .{ url, fetched, hash });
    try Io.Dir.cwd().deleteTree(io, tree);
}

/// What `bay add` pins of a prebuilt: Zig's hash of its tree, and bay's fields.
pub const Pinned = struct { hash: []const u8, prebuilt: manifest.Prebuilt };

/// The largest archive `pin` downloads, and the largest tree it unpacks: past 4 GiB, Zig's
/// hash no longer records the tree's size (`treeSize`), so no later fetch could bound it.
const largest: u64 = std.math.maxInt(u32);

/// Where a pin's licence is read in its tree: the path `--license` gives, which must be there;
/// the path the pin held before it moved, kept while the tree still holds it; else, and when
/// neither is given, the tree's one licence file.
pub const License = union(enum) { given: []const u8, before: []const u8, found };

/// The prebuilt at `url` pinned as it is served now, its publisher `publisher`, and its
/// licence where `license` says: the archive downloaded and checked against its publisher,
/// unpacked, and fetched by Zig for its hash. An OpenPGP key file is the path `publisher`
/// names in `package`, and must be inside it.
pub fn pin(c: Context, url: []const u8, publisher: manifest.Publisher, package: []const u8, license: License) !Pinned {
    const io = c.io;
    const a = c.a;
    const https = try httpsOf(c, url, publisher);
    const word: manifest.Publisher = switch (publisher) {
        .openpgp => |key_file| key: {
            const whole = try std.fs.path.resolveAlloc(a, &.{ package, key_file });
            if (!std.mem.startsWith(u8, whole, package) or whole.len == package.len or !std.fs.path.isSep(whole[package.len]))
                try say.fail(io, "{s} is not in the package: a dependency's pin is checked with the key its package ships", .{key_file});
            break :key .{ .openpgp = whole };
        },
        .minisign, .nuget, .none => publisher,
    };
    const kept = try keptDirectory(c);
    const lock = try Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ kept, "fetch.lock" }), .{ .lock = .exclusive, .truncate = false });
    defer lock.close(io);
    const fetched = try fetchArchive(c, https, kept, null, word, publisher);
    const tree = try unpacked(c, url, fetched.archive, largest, null);
    const hash = try zigFetch(c, tree);
    const stated = try licenseIn(c, url, tree, license);
    try Io.Dir.cwd().deleteTree(io, tree);
    return .{ .hash = hash, .prebuilt = .{ .sha256 = fetched.expected.sha256, .size = fetched.expected.size, .publisher = publisher, .license = stated } };
}

/// The publisher's URL a pin names, refused by name before anything is downloaded: one
/// over neither https nor loopback http, or one `.nuget` vouches for that is not nuget.org's.
fn httpsOf(c: Context, url: []const u8, publisher: manifest.Publisher) ![]const u8 {
    const https = publisherUrl(url) catch try say.fail(c.io, "{s}: a prebuilt is fetched over https (bay+https://), or plain http from this machine's loopback address", .{url});
    if (publisher == .nuget and !onNuget(https)) try say.fail(c.io, "{s}: .nuget is nuget.org's word, read from {s}; a package on another feed is refused until its pin can name that feed's index", .{ url, nuget_index });
    return https;
}

/// Where bay keeps prebuilt archives, by their SHA-256: in its data directory.
fn keptDirectory(c: Context) ![]const u8 {
    const kept = try std.fs.path.join(c.a, &.{ try dirs.data(c.io, c.a, c.environ), "prebuilt" });
    try Io.Dir.cwd().createDirPath(c.io, kept);
    return kept;
}

/// The archive's tree, unpacked beside it as Zig's fetch unpacks, no larger than `bound`
/// (the size `hash` records, when a pin gives one); every refusal named.
fn unpacked(c: Context, url: []const u8, authenticated: archive.Authenticated, bound: u64, hash: ?[]const u8) ![]const u8 {
    const io = c.io;
    const tree = try c.a.print("{s}.tree", .{authenticated.path});
    // What a fetch that stopped left; the lock says no other is using it.
    try Io.Dir.cwd().deleteTree(io, tree);
    var diagnostic: archive.Diagnostic = .{};
    archive.unpack(io, c.a, authenticated, tree, bound, &diagnostic) catch |err| switch (err) {
        error.Malformed => try say.fail(io, "{s} is not an archive std reads", .{url}),
        error.WindowTooLarge => try say.fail(io, "{s} declares a zstd window above 128 MiB, or none", .{url}),
        error.UnsupportedEntry => try say.fail(io, "{s} holds {s}, which is neither a file, a directory nor a link", .{ url, diagnostic.entry }),
        error.UnsupportedMethod => try say.fail(io, "{s} holds {s}, compressed by a method other than stored or deflate", .{ url, diagnostic.entry }),
        error.Encrypted => try say.fail(io, "{s} holds an encrypted entry", .{url}),
        error.UnsafeName => try say.fail(io, "{s} holds {s}, a name that leaves the tree or that some system cannot hold", .{ url, diagnostic.entry }),
        error.NameClash => try say.fail(io, "{s} holds {s} twice where case folds, or as a file and a directory", .{ url, diagnostic.entry }),
        error.LinkOutside => try say.fail(io, "{s} holds {s}, a link out of its tree", .{ url, diagnostic.entry }),
        error.TooLarge => if (hash) |pinned|
            try say.fail(io, "{s} unpacks past {d} bytes, the size {s} records, at {s}", .{ url, bound, pinned, diagnostic.entry })
        else
            try say.fail(io, "{s} unpacks past 4 GiB, at {s}: Zig's hash records no larger tree", .{ url, diagnostic.entry }),
        error.ArchiveChanged => try say.fail(io, "{s} changed while it was read", .{authenticated.path}),
        else => |e| return e,
    };
    return tree;
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

/// An archive downloaded, checked and kept, and its digest.
const Fetched = struct { archive: archive.Authenticated, expected: archive.Expected };

/// The archive downloaded, no longer than `expected` says when a pin gives it (else than
/// `largest`, and taken as served), then authenticated by its digest and by `publisher`,
/// whose key file is found where `word` says: kept in `kept` by its SHA-256 only once both hold.
fn fetchArchive(c: Context, https: []const u8, kept: []const u8, expected: ?archive.Expected, word: manifest.Publisher, publisher: manifest.Publisher) !Fetched {
    const io = c.io;
    const a = c.a;
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    client.initDefaultProxies(a, c.environ) catch |err| try say.fail(io, "the proxy settings are not usable: {t}", .{err});
    const partial = try std.fs.path.join(a, &.{ kept, "download.partial" });
    {
        const file = try Io.Dir.cwd().createFile(io, partial, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try say.note(io, "downloading {s}", .{https});
        _ = download.get(&client, https, &writer.interface, if (expected) |pinned| pinned.size else largest) catch |err| switch (err) {
            error.WriteFailed => return writer.err orelse err,
            else => |e| return e,
        };
        try writer.interface.flush();
    }
    const checked = expected orelse try digestOf(c, partial);
    const vouched: archive.Publisher = switch (word) {
        .none => .none,
        .minisign => |key| .{ .minisign = .{ .key = key, .signature = try download.getAlloc(&client, a, try a.print("{s}.minisig", .{https}), 4096), .file = fileName(https) } },
        .openpgp => |key_file| .{ .openpgp = .{
            .keys = aegis.own.readFile(io, Io.Dir.cwd(), key_file, a, .fromRaw(1 << 20)) catch |err| try say.fail(io, "could not read {s}, the key {s}'s pin names: {t}", .{ key_file, https, err }),
            .signature = try download.getAlloc(&client, a, try a.print("{s}.sig", .{https}), 64 * 1024),
        } },
        .nuget => .{ .sha512 = try nugetHash(c, &client, https) },
    };
    const authenticated = archive.authenticate(io, a, partial, checked, vouched) catch |err| switch (err) {
        error.SizeMismatch => try say.fail(io, "{s} is not {d} bytes, as its pin says", .{ https, checked.size }),
        error.DigestMismatch => try say.fail(io, "{s}'s SHA-256 is not its pin's: it is another archive", .{https}),
        error.PublisherMismatch => try say.fail(io, "{s} is not what its publisher vouches for ({t})", .{ https, publisher }),
        error.Xz => try say.fail(io, "{s} is xz, which bay does not read", .{https}),
        error.Bzip2 => try say.fail(io, "{s} is bzip2, which bay does not read", .{https}),
        error.UnknownFormat => try say.fail(io, "{s} is no archive bay reads: a tar in gzip or zstd, or a zip", .{https}),
        else => |e| return e,
    };
    const path = try std.fs.path.join(a, &.{ kept, try a.print("{x}", .{&checked.sha256}) });
    try Io.Dir.rename(.cwd(), partial, .cwd(), path, io);
    return .{ .archive = .{ .path = path, .format = authenticated.format }, .expected = checked };
}

/// The SHA-256 and length of the file at `path`, as served.
fn digestOf(c: Context, path: []const u8) !archive.Expected {
    const file = try Io.Dir.cwd().openFile(c.io, path, .{});
    defer file.close(c.io);
    var reader = file.readerStreaming(c.io, &.{});
    var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var length: u64 = 0;
    while (true) {
        try c.io.checkCancel();
        const n = reader.interface.readSliceShort(&buffer) catch return reader.err orelse error.ReadFailed;
        sha256.update(buffer[0..n]);
        length += n;
        if (n < buffer.len) break;
    }
    return .{ .sha256 = sha256.finalResult(), .size = length };
}

/// The file in `tree` that states the licence, as `license` says, else the tree's one file
/// named as a licence (LICENSE, LICENCE or COPYING, any case, any extension); none, or
/// several, is refused naming them, for `--license` to choose.
fn licenseIn(c: Context, url: []const u8, tree: []const u8, license: License) ![]const u8 {
    const io = c.io;
    const a = c.a;
    switch (license) {
        .given, .before => |path| if (Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ tree, path }), .{})) |_| return path else |err| switch (err) {
            error.FileNotFound => if (license == .given) try say.fail(io, "{s} holds no {s}: --license names a file in the archive's tree", .{ url, path }),
            else => |e| return e,
        },
        .found => {},
    }
    var dir = try Io.Dir.cwd().openDir(io, tree, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var found: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !licenseName(entry.basename)) continue;
        const relative = try a.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, relative, '\\', '/');
        try found.append(a, relative);
    }
    if (found.items.len == 1) return found.items[0];
    if (found.items.len == 0) try say.fail(io, "{s} holds no file named as a licence: give --license <path in the archive>", .{url});
    try say.fail(io, "{s} holds several licence files ({s}): give --license <one of them>", .{ url, try std.mem.join(a, ", ", found.items) });
}

/// Whether `name` names a licence file: LICENSE, LICENCE or COPYING, any case, any extension.
fn licenseName(name: []const u8) bool {
    for ([_][]const u8{ "license", "licence", "copying" }) |stem| if (std.ascii.startsWithIgnoreCase(name, stem)) return true;
    return false;
}

/// The last part of a URL's path: the file a publisher's signature names.
fn fileName(url: []const u8) []const u8 {
    const path = url[0 .. std.mem.findAny(u8, url, "?#") orelse url.len];
    return path[(std.mem.findScalarLast(u8, path, '/') orelse return path) + 1 ..];
}

/// Zig's hash of the tree at `tree`, as `zig fetch` prints it, the tree kept in Zig's cache.
fn zigFetch(c: Context, tree: []const u8) ![]const u8 {
    const result = std.process.run(c.a, c.io, .{ .argv = &.{ c.zig, "fetch", tree }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(c.io, "could not run {s} fetch: {t}", .{ c.zig, err });
    if (result.term != .exited or result.term.exited != 0) {
        try say.relay(c.io, result.stderr);
        try say.fail(c.io, "{s} fetch refused {s}", .{ c.zig, tree });
    }
    const hash = aegis.input.Untrusted([]const u8).init(result.stdout).parse({}, ZigHash.parse) catch
        try say.fail(c.io, "{s} fetch printed no package hash for {s}: {s}", .{ c.zig, tree, result.stdout });
    return hash.text;
}

/// The SHA-512 nuget.org's catalog holds for the package at `https`, which must be in the
/// package base its service index names, as `<id>/<version>/<id>.<version>.nupkg`: nuget.org's
/// word over TLS, read apart from the package (designs/bay.md §11).
fn nugetHash(c: Context, client: *std.http.Client, https: []const u8) ![Sha512.digest_length]u8 {
    const io = c.io;
    const a = c.a;
    const index = nuget_index;
    const resources = nugetResources(a, try download.getAlloc(client, a, index, 1 << 20)) catch
        try say.fail(io, "{s} is not a NuGet service index bay can read", .{index});
    const package = nugetPackage(resources.base, https) orelse
        try say.fail(io, "{s} is not a package under {s}, the base {s} names, as <id>/<version>/<id>.<version>.nupkg", .{ https, resources.base, index });
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

/// nuget.org's service index: `.nuget` is nuget.org's word, read from there alone.
const nuget_index = "https://api.nuget.org/v3/index.json";

/// Whether `url` is nuget.org's, which a `.nuget` publisher vouches for. Another feed keeps
/// its index where it likes (Azure Artifacts under `/_packaging/<feed>/nuget/v3/`), so its
/// URL tells nothing of it: refused until a pin can name its feed's index.
pub fn onNuget(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://api.nuget.org/");
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
    // Plain http only to this machine's loopback address, by number: a name could be anywhere.
    try testing.expectEqualStrings("http://127.0.0.1:8080/a.zip", try publisherUrl("bay+http://127.0.0.1:8080/a.zip"));
    try testing.expectEqualStrings("http://[::1]:8080/a.zip", try publisherUrl("bay+http://[::1]:8080/a.zip"));
    try testing.expectError(error.NotHttps, publisherUrl("bay+http://localhost:8080/a.zip"));
    try testing.expectError(error.NotHttps, publisherUrl("bay+http://10.0.0.1/a.zip"));
    try testing.expectError(error.NotHttps, publisherUrl("bay+http://127.0.0.1.example.org/a.zip"));
}

test "the tree's size is what Zig's hash records" {
    try testing.expectEqual(null, treeSize("N-V-short"));
    var plus: [33]u8 = @splat(0);
    std.mem.writeInt(u32, plus[4..8], 6218920, .little);
    var encoded: [44]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &plus);
    try testing.expectEqual(6218920, treeSize("N-V-" ++ encoded));
}

test "zig fetch's output is read as a package hash, one folder's name" {
    const plus = "AAAAACj6XgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try testing.expectEqualStrings("app-0.1.0-" ++ plus, (try ZigHash.parse({}, "app-0.1.0-" ++ plus ++ "\n")).text);
    try testing.expectEqualStrings("zlib_ng-2.2.4+zig.1-rc-" ++ plus, (try ZigHash.parse({}, "zlib_ng-2.2.4+zig.1-rc-" ++ plus)).text);
    for ([_][]const u8{ "", "app-0.1.0-short", "app-" ++ plus, "-0.1.0-" ++ plus, "app--" ++ plus, "../a-0.1.0-" ++ plus, "app-0.1/..-" ++ plus, "app-..-" ++ plus, "a\\b-0.1.0-" ++ plus, "app-0.1.0-" ++ plus[0..43] ++ "/", "app-0.1.0-" ++ plus[0..43] ++ "=" }) |text|
        try testing.expectError(error.NotPackageHash, ZigHash.parse({}, text));
    try testing.expectError(error.NotPackageHash, ZigHash.parse({}, &@as([33]u8, @splat('a')) ++ "-0.1.0-" ++ plus));
    try testing.expectError(error.NotPackageHash, ZigHash.parse({}, "app-" ++ &@as([33]u8, @splat('1')) ++ "-" ++ plus));
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
    try testing.expect(onNuget("https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/1.619.6/microsoft.direct3d.d3d12.1.619.6.nupkg"));
    try testing.expect(!onNuget("https://pkgs.dev.azure.com/org/_packaging/feed/nuget/v3/flat2/x/1.0.0/x.1.0.0.nupkg"));
    try testing.expect(!onNuget("https://api.nuget.org.example.com/x.nupkg"));
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
