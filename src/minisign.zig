//! minisign signatures, verified as minisign verifies them: an Ed25519
//! signature over the file (algorithm `ED`: over its BLAKE2b-512 digest;
//! `Ed`, the legacy form: over the file itself) by the key the signature names,
//! and a global signature over that signature and the trusted comment, so the
//! comment cannot be changed either.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const base64 = std.base64.standard.Decoder;

pub const Error = error{
    /// The public key is not base64 of `Ed`, a key id and an Ed25519 key.
    InvalidPublicKey,
    /// The signature file is not the four lines minisign writes.
    InvalidSignature,
    /// The signature is neither `ED` nor `Ed`.
    UnsupportedAlgorithm,
    /// The signature was made by a key other than the one given.
    KeyMismatch,
    /// The global signature does not verify: the trusted comment or the
    /// signature was changed, or another key under the same id made them.
    TrustedCommentMismatch,
    /// The file is not the one that was signed.
    FileMismatch,
};

pub const Algorithm = enum { prehashed, legacy };

pub const PublicKey = struct {
    id: [8]u8,
    key: Ed25519.PublicKey,

    /// Reads a key in minisign's form, the base64 line of a `.pub` file.
    pub fn parse(text: []const u8) Error!PublicKey {
        var bytes: [2 + 8 + 32]u8 = undefined;
        decode(&bytes, std.mem.trim(u8, text, " \t\r\n")) catch return error.InvalidPublicKey;
        if (!std.mem.eql(u8, bytes[0..2], "Ed")) return error.InvalidPublicKey;
        return .{ .id = bytes[2..10].*, .key = Ed25519.PublicKey.fromBytes(bytes[10..42].*) catch return error.InvalidPublicKey };
    }
};

pub const Signature = struct {
    algorithm: Algorithm,
    key_id: [8]u8,
    /// The signature of the file, or of its digest.
    bytes: [64]u8,
    /// The text after `trusted comment: `, which the global signature covers.
    trusted_comment: []const u8,
    global: [64]u8,

    /// Reads a `.minisig` file: an untrusted comment, the signature, the
    /// trusted comment and the global signature, one per line. The trusted
    /// comment points into `text`.
    pub fn parse(text: []const u8) Error!Signature {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const untrusted = lines.next() orelse return error.InvalidSignature;
        if (!std.mem.startsWith(u8, untrusted, "untrusted comment: ")) return error.InvalidSignature;
        var bytes: [2 + 8 + 64]u8 = undefined;
        decode(&bytes, line(&lines) orelse return error.InvalidSignature) catch return error.InvalidSignature;
        const trusted = line(&lines) orelse return error.InvalidSignature;
        const prefix = "trusted comment: ";
        if (!std.mem.startsWith(u8, trusted, prefix)) return error.InvalidSignature;
        var global: [64]u8 = undefined;
        decode(&global, line(&lines) orelse return error.InvalidSignature) catch return error.InvalidSignature;
        // Only an empty line may follow: the file's last newline.
        while (lines.next()) |rest| if (std.mem.trim(u8, rest, " \t\r").len != 0) return error.InvalidSignature;
        const algorithm: Algorithm = if (std.mem.eql(u8, bytes[0..2], "ED"))
            .prehashed
        else if (std.mem.eql(u8, bytes[0..2], "Ed"))
            .legacy
        else
            return error.UnsupportedAlgorithm;
        return .{ .algorithm = algorithm, .key_id = bytes[2..10].*, .bytes = bytes[10..74].*, .trusted_comment = trusted[prefix.len..], .global = global };
    }
};

/// Verifies a signed file read in parts: `init` checks the key and the trusted
/// comment, `update` takes each part of the file in order, `verify` the end.
pub const Verifier = struct {
    state: union(Algorithm) { prehashed: Blake2b512, legacy: Ed25519.Verifier },
    signature: Signature,
    key: PublicKey,

    pub fn init(signature: Signature, key: PublicKey) Error!Verifier {
        if (!std.mem.eql(u8, &signature.key_id, &key.id)) return error.KeyMismatch;
        // The global signature binds the trusted comment to this signature; it needs nothing of the file.
        var global = (Ed25519.Signature.fromBytes(signature.global)).verifier(key.key) catch return error.TrustedCommentMismatch;
        global.update(&signature.bytes);
        global.update(signature.trusted_comment);
        global.verify() catch return error.TrustedCommentMismatch;
        return .{
            .state = switch (signature.algorithm) {
                .prehashed => .{ .prehashed = .init(.{}) },
                .legacy => .{ .legacy = Ed25519.Signature.fromBytes(signature.bytes).verifier(key.key) catch return error.FileMismatch },
            },
            .signature = signature,
            .key = key,
        };
    }

    pub fn update(verifier: *Verifier, bytes: []const u8) void {
        switch (verifier.state) {
            inline else => |*state| state.update(bytes),
        }
    }

    pub fn verify(verifier: *Verifier) Error!void {
        switch (verifier.state) {
            .prehashed => |*hash| {
                var digest: [Blake2b512.digest_length]u8 = undefined;
                hash.final(&digest);
                Ed25519.Signature.fromBytes(verifier.signature.bytes).verify(&digest, verifier.key.key) catch return error.FileMismatch;
            },
            .legacy => |*state| state.verify() catch return error.FileMismatch,
        }
    }
};

/// Verifies `file`, whole in memory, against `signature` by `key`.
pub fn verify(file: []const u8, signature: Signature, key: PublicKey) Error!void {
    var verifier: Verifier = try .init(signature, key);
    verifier.update(file);
    try verifier.verify();
}

/// The next line, without a carriage return before its newline.
fn line(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    return std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
}

/// Decodes base64 that must fill `out` exactly.
fn decode(out: []u8, text: []const u8) !void {
    if (try base64.calcSizeForSlice(text) != out.len) return error.InvalidLength;
    try base64.decode(out, text);
}

const testing = std.testing;
const encoder = std.base64.standard.Encoder;

/// A minisign key and the text of a signature it makes, as minisign writes them.
const Signer = struct {
    pair: Ed25519.KeyPair,
    id: [8]u8,

    fn init(seed: u8, id: [8]u8) !Signer {
        return .{ .pair = try .generateDeterministic(@splat(seed)), .id = id };
    }

    fn publicKey(signer: Signer, buffer: []u8) []const u8 {
        return encoder.encode(buffer, &("Ed".* ++ signer.id ++ signer.pair.public_key.toBytes()));
    }

    fn sign(signer: Signer, a: std.mem.Allocator, file: []const u8, algorithm: Algorithm, comment: []const u8) ![]u8 {
        var digest: [Blake2b512.digest_length]u8 = undefined;
        Blake2b512.hash(file, &digest, .{});
        const signed = switch (algorithm) {
            .prehashed => &digest,
            .legacy => file,
        };
        const signature = (try signer.pair.sign(signed, null)).toBytes();
        const global = (try signer.pair.sign(try std.mem.concat(a, u8, &.{ &signature, comment }), null)).toBytes();
        const tag = switch (algorithm) {
            .prehashed => "ED",
            .legacy => "Ed",
        };
        var line_buffer: [100]u8 = undefined;
        var global_buffer: [100]u8 = undefined;
        return a.print("untrusted comment: signature from minisign secret key\n{s}\ntrusted comment: {s}\n{s}\n", .{
            encoder.encode(&line_buffer, tag ++ signer.id ++ signature),
            comment,
            encoder.encode(&global_buffer, &global),
        });
    }
};

test "a file signed by the key verifies, prehashed and legacy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signer: Signer = try .init(7, "keyid-01".*);
    var key_buffer: [64]u8 = undefined;
    const key = try PublicKey.parse(signer.publicKey(&key_buffer));
    const file = "zig-x86_64-linux-0.17.0.tar.xz, as published";
    for ([_]Algorithm{ .prehashed, .legacy }) |algorithm| {
        const signature = try Signature.parse(try signer.sign(a, file, algorithm, "timestamp:1\tfile:zig.tar.xz\thashed"));
        try testing.expectEqual(algorithm, signature.algorithm);
        try testing.expectEqualStrings("timestamp:1\tfile:zig.tar.xz\thashed", signature.trusted_comment);
        try verify(file, signature, key);
        // In parts, as a download arrives.
        var verifier: Verifier = try .init(signature, key);
        verifier.update(file[0..10]);
        verifier.update(file[10..]);
        try verifier.verify();
    }
}

test "a changed file, comment, key or algorithm is refused, each by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signer: Signer = try .init(7, "keyid-01".*);
    var key_buffer: [64]u8 = undefined;
    const key = try PublicKey.parse(signer.publicKey(&key_buffer));
    const file = "the published archive";
    const text = try signer.sign(a, file, .prehashed, "file:zig.tar.xz");
    try testing.expectError(error.FileMismatch, verify("the published archivE", try Signature.parse(text), key));

    const forged = try std.mem.replaceOwned(u8, a, text, "file:zig.tar.xz", "file:old.tar.xz");
    try testing.expectError(error.TrustedCommentMismatch, verify(file, try Signature.parse(forged), key));

    // Another key under the same id signs nothing this key made.
    const impostor: Signer = try .init(8, "keyid-01".*);
    try testing.expectError(error.TrustedCommentMismatch, verify(file, try Signature.parse(try impostor.sign(a, file, .prehashed, "file:zig.tar.xz")), key));
    const other: Signer = try .init(8, "keyid-02".*);
    try testing.expectError(error.KeyMismatch, verify(file, try Signature.parse(try other.sign(a, file, .prehashed, "c")), key));

    var line_buffer: [100]u8 = undefined;
    var global_buffer: [100]u8 = undefined;
    const zeros: [64]u8 = @splat(0);
    const unknown = try a.print("untrusted comment: x\n{s}\ntrusted comment: c\n{s}\n", .{ encoder.encode(&line_buffer, "XX" ++ signer.id ++ zeros), encoder.encode(&global_buffer, &zeros) });
    try testing.expectError(error.UnsupportedAlgorithm, Signature.parse(unknown));
    try testing.expectError(error.InvalidSignature, Signature.parse("untrusted comment: x\nnot base64\n"));
    try testing.expectError(error.InvalidSignature, Signature.parse(try std.mem.concat(a, u8, &.{ text, "a fifth line\n" })));
    try testing.expectError(error.InvalidPublicKey, PublicKey.parse("RWQ="));
}

test "Zig's published signature of its 0.17.0 aarch64-macos build carries a trusted comment its key signed" {
    // As ziglang.org published them: the key on its download page, the signature beside the tarball.
    const key = try PublicKey.parse("RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U");
    const text = "untrusted comment: signature from minisign secret key\n" ++
        "RUSGOq2NVecA2Qso9uzqlH38Gxi7akzTeQeEKtkRJQXxgCvTzfc5XY3SRtzuWQYwnV8+VTuLDzq8AdyuP9aEp2jpdgM8OBBiCgk=\n" ++
        "trusted comment: timestamp:1790965659\tfile:zig-aarch64-macos-0.17.0.tar.xz\thashed\n" ++
        "HtSM4OeDtYztRTod8yiwAqPPIaClGsYaZYQE2ZZnNSE7CCVkFm8wEY3cY/qmsnfu+UWdYwmILx3GQO9cjoJjCQ==\n";
    const signature = try Signature.parse(text);
    try testing.expectEqual(.prehashed, signature.algorithm);
    _ = try Verifier.init(signature, key);
    const forged = try std.mem.replaceOwned(u8, testing.allocator, text, "0.17.0.tar.xz", "0.16.0.tar.xz");
    defer testing.allocator.free(forged);
    try testing.expectError(error.TrustedCommentMismatch, Verifier.init(try Signature.parse(forged), key));
}
