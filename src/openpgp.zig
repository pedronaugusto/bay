//! OpenPGP detached signatures, verified as RFC 9580 verifies a version 4
//! signature over a binary document: the file, then the signature's hashed
//! part and its trailer, digested with the hash it names, and that digest
//! signed by RSA (PKCS #1 v1.5) or Ed25519. The key is one the package ships
//! in a file, binary or armored; every key in the file may sign, and nothing
//! else is trusted: no keyring, no web of trust, no key server. What MSYS2
//! signs its packages with (RSA over SHA-512) is the first case.
const std = @import("std");
const aegis = @import("aegis");
const Certificate = std.crypto.Certificate;
const Ed25519 = std.crypto.sign.Ed25519;
const sha2 = std.crypto.hash.sha2;
const Sha1 = std.crypto.hash.Sha1;

pub const Error = error{
    /// The bytes are not OpenPGP packets, or not the packets a key or a signature is.
    Malformed,
    /// A key or signature of a version other than 4.
    UnsupportedVersion,
    /// A signature over something other than a binary document.
    UnsupportedSignatureType,
    /// A public-key algorithm other than RSA and Ed25519, or a key of a size std's RSA cannot take.
    UnsupportedAlgorithm,
    /// A hash other than SHA-256, SHA-384 and SHA-512: SHA-1 and MD5 are refused.
    UnsupportedHash,
    /// A hashed subpacket marked critical that this reader does not know.
    UnsupportedCritical,
    /// The signature names no key.
    UnnamedKey,
    /// The signature was made by a key the file does not hold.
    KeyMismatch,
    /// The file is not the one that was signed, or the signature does not verify.
    FileMismatch,
    OutOfMemory,
};

const Algorithm = enum { rsa, ed25519 };

pub const Key = struct {
    fingerprint: [20]u8,
    public: union(Algorithm) {
        rsa: Certificate.rsa.PublicKey,
        ed25519: Ed25519.PublicKey,
    },
};

/// The keys a key file holds: its primary key and its subkeys, each a v4 key of an
/// algorithm this reader verifies. Keys of other algorithms (an encryption subkey)
/// are passed over; a file with no key that can sign is refused.
pub const Keys = struct {
    list: []const Key,

    pub fn parse(a: std.mem.Allocator, text: []const u8) Error!Keys {
        const bytes = try dearmor(a, text, "PUBLIC KEY BLOCK");
        var list: std.ArrayList(Key) = .empty;
        var packets: Packets = .{ .rest = bytes };
        while (try packets.next()) |packet| {
            // 6: a public key; 14: a public subkey.
            if (packet.tag != 6 and packet.tag != 14) continue;
            const key = parseKey(packet.body) catch |err| switch (err) {
                error.UnsupportedAlgorithm => continue,
                else => |e| return e,
            };
            try list.append(a, key);
        }
        if (list.items.len == 0) return error.UnsupportedAlgorithm;
        return .{ .list = list.items };
    }

    fn find(keys: Keys, signature: Signature) Error!Key {
        for (keys.list) |key| {
            const named = if (signature.issuer) |issuer| std.mem.eql(u8, &issuer, &key.fingerprint) else std.mem.eql(u8, &signature.issuer_id.?, key.fingerprint[12..20]);
            if (!named) continue;
            if (std.meta.activeTag(key.public) != std.meta.activeTag(signature.value)) return error.KeyMismatch;
            return key;
        }
        return error.KeyMismatch;
    }
};

fn parseKey(body: []const u8) Error!Key {
    if (body.len < 6) return error.Malformed;
    if (body[0] != 4) return error.UnsupportedVersion;
    var fingerprint: Sha1 = .init(.{});
    fingerprint.update(&.{ 0x99, @intCast((body.len >> 8) & 0xff), @intCast(body.len & 0xff) });
    if (body.len > 0xffff) return error.Malformed;
    fingerprint.update(body);
    var key: Key = .{ .fingerprint = fingerprint.finalResult(), .public = undefined };
    var fields: Cursor = .{ .rest = body[6..] };
    switch (body[5]) {
        // RSA, and RSA sign-only.
        1, 3 => {
            const n = try fields.mpi();
            const e = try fields.mpi();
            key.public = .{ .rsa = Certificate.rsa.PublicKey.fromBytes(e, n) catch return error.UnsupportedAlgorithm };
        },
        // EdDSA as v4 keys carry it: the curve's OID, then the point, 0x40 and its 32 bytes.
        22 => {
            const oid = try fields.take(try fields.byte());
            if (!std.mem.eql(u8, oid, &ed25519_oid)) return error.UnsupportedAlgorithm;
            const point = try fields.mpi();
            if (point.len != 33 or point[0] != 0x40) return error.Malformed;
            key.public = .{ .ed25519 = Ed25519.PublicKey.fromBytes(point[1..33].*) catch return error.Malformed };
        },
        // Ed25519 as RFC 9580 names it: the 32 bytes alone.
        27 => key.public = .{ .ed25519 = Ed25519.PublicKey.fromBytes((try fields.take(32))[0..32].*) catch return error.Malformed },
        else => return error.UnsupportedAlgorithm,
    }
    return key;
}

/// The OID of Ed25519 as OpenPGP's EdDSA keys name the curve (1.3.6.1.4.1.11591.15.1).
const ed25519_oid = [_]u8{ 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01 };

const Hash = enum {
    sha256,
    sha384,
    sha512,

    fn of(id: u8) Error!Hash {
        return switch (id) {
            8 => .sha256,
            9 => .sha384,
            10 => .sha512,
            else => error.UnsupportedHash,
        };
    }

    /// The DER `DigestInfo` that PKCS #1 v1.5 puts before the digest (RFC 8017 §9.2, note 1).
    fn digestInfo(hash: Hash) []const u8 {
        return switch (hash) {
            .sha256 => &.{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
            .sha384 => &.{ 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 },
            .sha512 => &.{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        };
    }
};

const Hasher = union(Hash) {
    sha256: sha2.Sha256,
    sha384: sha2.Sha384,
    sha512: sha2.Sha512,

    fn init(hash: Hash) Hasher {
        return switch (hash) {
            inline else => |tag| @unionInit(Hasher, @tagName(tag), .init(.{})),
        };
    }

    fn update(hasher: *Hasher, bytes: []const u8) void {
        switch (hasher.*) {
            inline else => |*h| h.update(bytes),
        }
    }

    /// The digest, into the front of `out`; its length.
    fn final(hasher: *Hasher, out: *[64]u8) usize {
        switch (hasher.*) {
            inline else => |*h| {
                const digest = h.finalResult();
                @memcpy(out[0..digest.len], &digest);
                return digest.len;
            },
        }
    }
};

pub const Signature = struct {
    hash: Hash,
    /// From the version byte to the end of the hashed subpackets: what the digest covers after the file.
    hashed: []const u8,
    /// The key that made it, by its v4 fingerprint (subpacket 33) or, failing that, its id (16).
    issuer: ?[20]u8,
    issuer_id: ?[8]u8,
    /// The digest's first two bytes, as the signature records them.
    left: [2]u8,
    value: union(Algorithm) {
        /// The signature as a big-endian integer, not wider than the key's modulus.
        rsa: []const u8,
        ed25519: [64]u8,
    },

    /// A signature file's one signature, binary or armored. Its slices point into
    /// `text`, or into what `a` decoded it into.
    pub fn parse(a: std.mem.Allocator, text: []const u8) Error!Signature {
        const bytes = try dearmor(a, text, "SIGNATURE");
        var packets: Packets = .{ .rest = bytes };
        const packet = try packets.next() orelse return error.Malformed;
        if (packet.tag != 2 or try packets.next() != null) return error.Malformed;
        return parseSignature(packet.body);
    }
};

fn parseSignature(body: []const u8) Error!Signature {
    var fields: Cursor = .{ .rest = body };
    if (try fields.byte() != 4) return error.UnsupportedVersion;
    // 0x00: a signature of a binary document.
    if (try fields.byte() != 0x00) return error.UnsupportedSignatureType;
    const algorithm = try fields.byte();
    const hash: Hash = try .of(try fields.byte());
    const hashed_subpackets = try fields.take(try fields.int(u16));
    var signature: Signature = .{ .hash = hash, .hashed = body[0 .. body.len - fields.rest.len], .issuer = null, .issuer_id = null, .left = undefined, .value = undefined };
    try readSubpackets(&signature, hashed_subpackets, true);
    try readSubpackets(&signature, try fields.take(try fields.int(u16)), false);
    if (signature.issuer == null and signature.issuer_id == null) return error.UnnamedKey;
    signature.left = (try fields.take(2))[0..2].*;
    switch (algorithm) {
        1, 3 => signature.value = .{ .rsa = try fields.mpi() },
        22 => {
            // r and s, each an integer of up to 32 bytes, made the 64 bytes Ed25519 checks.
            var value: [64]u8 = @splat(0);
            for ([_]usize{ 0, 32 }) |at| {
                const part = try fields.mpi();
                if (part.len > 32) return error.Malformed;
                @memcpy(value[at + 32 - part.len .. at + 32], part);
            }
            signature.value = .{ .ed25519 = value };
        },
        27 => signature.value = .{ .ed25519 = (try fields.take(64))[0..64].* },
        else => return error.UnsupportedAlgorithm,
    }
    if (fields.rest.len != 0) return error.Malformed;
    return signature;
}

fn readSubpackets(signature: *Signature, bytes: []const u8, hashed: bool) Error!void {
    var fields: Cursor = .{ .rest = bytes };
    while (fields.rest.len != 0) {
        const first = try fields.byte();
        const length: usize = switch (first) {
            0...191 => first,
            192...254 => (@as(usize, first - 192) << 8) + try fields.byte() + 192,
            255 => try fields.int(u32),
        };
        if (length == 0) return error.Malformed;
        const content = try fields.take(length);
        const critical = content[0] & 0x80 != 0;
        const data = content[1..];
        switch (content[0] & 0x7f) {
            // The creation time: the digest covers it; nothing here reads it.
            2 => {},
            16 => {
                if (data.len != 8) return error.Malformed;
                // An id the hashed part names is the one taken; one only outside it is a hint.
                if (signature.issuer_id == null or hashed) signature.issuer_id = data[0..8].*;
            },
            33 => {
                if (data.len != 21) {
                    if (data.len == 0) return error.Malformed;
                    // Another key version's fingerprint: not one this reader matches.
                    if (data[0] != 4) continue;
                    return error.Malformed;
                }
                if (data[0] != 4) continue;
                if (signature.issuer == null or hashed) signature.issuer = data[1..21].*;
            },
            else => if (critical and hashed) return error.UnsupportedCritical,
        }
    }
}

/// Checks a file against a signature as its bytes go by.
pub const Verifier = struct {
    signature: Signature,
    key: Key,
    hasher: Hasher,

    /// A verifier of `signature` by the key in `keys` it names.
    pub fn init(signature: Signature, keys: Keys) Error!Verifier {
        return .{ .signature = signature, .key = try keys.find(signature), .hasher = .init(signature.hash) };
    }

    pub fn update(verifier: *Verifier, bytes: []const u8) void {
        verifier.hasher.update(bytes);
    }

    /// Whether the file seen is the one the key signed.
    pub fn verify(verifier: *Verifier) Error!void {
        const signature = verifier.signature;
        verifier.hasher.update(signature.hashed);
        var trailer: [6]u8 = .{ 4, 0xff, 0, 0, 0, 0 };
        std.mem.writeInt(u32, trailer[2..6], @intCast(signature.hashed.len), .big);
        verifier.hasher.update(&trailer);
        var buffer: [64]u8 = undefined;
        const digest = buffer[0..verifier.hasher.final(&buffer)];
        if (!std.mem.eql(u8, digest[0..2], &signature.left)) return error.FileMismatch;
        switch (verifier.key.public) {
            .rsa => |key| try verifyRsa(key, signature.hash, digest, signature.value.rsa),
            .ed25519 => |key| Ed25519.Signature.fromBytes(signature.value.ed25519).verify(digest, key) catch return error.FileMismatch,
        }
    }
};

/// RSASSA-PKCS1-v1_5 (RFC 8017 §8.2.2) over a digest made elsewhere: the signature
/// raised to the key's exponent must be `00 01 FF..FF 00`, the DigestInfo, the digest.
fn verifyRsa(key: Certificate.rsa.PublicKey, hash: Hash, digest: []const u8, value: []const u8) Error!void {
    const Modulus = @TypeOf(key.n);
    const length = (key.n.bits() + 7) / 8;
    if (value.len > length) return error.FileMismatch;
    const info = hash.digestInfo();
    if (length < info.len + digest.len + 11) return error.UnsupportedAlgorithm;
    const s = Modulus.Fe.fromBytes(key.n, value, .big) catch return error.FileMismatch;
    const m = key.n.powPublic(s, key.e) catch return error.FileMismatch;
    var raised: [512]u8 = undefined;
    m.toBytes(raised[0..length], .big) catch return error.FileMismatch;
    var expected: [512]u8 = undefined;
    const padding = length - 3 - info.len - digest.len;
    expected[0] = 0;
    expected[1] = 1;
    @memset(expected[2 .. 2 + padding], 0xff);
    expected[2 + padding] = 0;
    @memcpy(expected[3 + padding ..][0..info.len], info);
    @memcpy(expected[length - digest.len .. length], digest);
    // Both sides are public: anyone can raise a signature to the public exponent, so the
    // comparison has no secret to keep in constant time.
    if (!std.mem.eql(u8, raised[0..length], expected[0..length])) return error.FileMismatch;
}

/// Packets one after another, in either header form; a length left open
/// (an old packet's indeterminate one, a new packet's partial one) is not
/// something a key or a signature is written with, and is refused.
const Packets = struct {
    /// The packets not read yet.
    rest: []const u8,

    const Packet = struct { tag: u8, body: []const u8 };

    fn next(packets: *Packets) Error!?Packet {
        if (packets.rest.len == 0) return null;
        var fields: Cursor = .{ .rest = packets.rest };
        const header = try fields.byte();
        if (header & 0x80 == 0) return error.Malformed;
        var tag: u8 = undefined;
        var length: usize = undefined;
        if (header & 0x40 == 0) {
            tag = (header >> 2) & 0x0f;
            length = switch (header & 3) {
                0 => try fields.byte(),
                1 => try fields.int(u16),
                2 => try fields.int(u32),
                else => return error.Malformed,
            };
        } else {
            tag = header & 0x3f;
            const first = try fields.byte();
            length = switch (first) {
                0...191 => first,
                192...223 => (@as(usize, first - 192) << 8) + try fields.byte() + 192,
                255 => try fields.int(u32),
                else => return error.Malformed,
            };
        }
        const body = try fields.take(length);
        packets.rest = fields.rest;
        return .{ .tag = tag, .body = body };
    }
};

/// Reads fields from the front of `rest`, the bytes not read yet, refusing to read past its end.
const Cursor = struct {
    rest: []const u8,

    fn take(cursor: *Cursor, length: usize) Error![]const u8 {
        const rest = cursor.rest;
        if (length > rest.len) return error.Malformed;
        cursor.rest = rest[length..];
        return rest[0..length];
    }

    fn byte(cursor: *Cursor) Error!u8 {
        return (try cursor.take(1))[0];
    }

    fn int(cursor: *Cursor, comptime T: type) Error!T {
        return std.mem.readInt(T, (try cursor.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    /// A multiprecision integer: its length in bits, then its bytes, high first.
    fn mpi(cursor: *Cursor) Error![]const u8 {
        const bits = try cursor.int(u16);
        return cursor.take((@as(usize, bits) + 7) / 8);
    }
};

/// The packets in `text`: the bytes themselves, or what its ASCII armors of
/// `kind` (`BEGIN PGP <kind>`) hold, one after another, as a keyring file
/// holds a block per key; each block's checksum is checked when it has one.
fn dearmor(a: std.mem.Allocator, text: []const u8, comptime kind: []const u8) Error![]const u8 {
    const begin = "-----BEGIN PGP " ++ kind ++ "-----";
    if (std.mem.find(u8, text, begin) == null) return text;
    var packets: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.find(u8, rest, begin)) |start| {
        var lines = std.mem.splitScalar(u8, rest[start + begin.len ..], '\n');
        _ = lines.next(); // the rest of the BEGIN line
        // Header lines (`Version: ...`) end at the first blank line.
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) break;
        } else return error.Malformed;
        var encoded: std.ArrayList(u8) = .empty;
        var checksum: ?[]const u8 = null;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "-----END PGP " ++ kind ++ "-----")) break;
            if (line.len != 0 and line[0] == '=') {
                checksum = line[1..];
                continue;
            }
            try encoded.appendSlice(a, line);
        } else return error.Malformed;
        rest = lines.rest();
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded.items) catch return error.Malformed;
        const bytes = try packets.addManyAsSlice(a, size);
        decoder.decode(bytes, encoded.items) catch return error.Malformed;
        if (checksum) |line| {
            var stated: [3]u8 = undefined;
            if ((decoder.calcSizeForSlice(line) catch return error.Malformed) != 3) return error.Malformed;
            decoder.decode(&stated, line) catch return error.Malformed;
            if (std.mem.readInt(u24, &stated, .big) != crc24(bytes)) return error.Malformed;
        }
    }
    return packets.items;
}

/// The armor's checksum (RFC 9580 §6.1.1).
fn crc24(bytes: []const u8) u24 {
    var crc: u32 = 0xb704ce;
    for (bytes) |b| {
        crc ^= @as(u32, b) << 16;
        for (0..8) |_| {
            crc <<= 1;
            if (crc & 0x1000000 != 0) crc ^= 0x1864cfb;
        }
    }
    return @intCast(crc & 0xffffff);
}

/// Verifies `file` against the signature `signature_text` by a key of `key_text`,
/// both read as the untrusted bytes they are.
pub fn verifyAll(a: std.mem.Allocator, key_text: []const u8, signature_text: []const u8, file: []const u8) Error!void {
    const keys = try aegis.input.Untrusted([]const u8).init(key_text).parse(a, Keys.parse);
    const signature = try aegis.input.Untrusted([]const u8).init(signature_text).parse(a, Signature.parse);
    var verifier: Verifier = try .init(signature, keys);
    verifier.update(file);
    try verifier.verify();
}

/// A file signed by an RSA key, with the key and its armored signature, for the tests of
/// what verifies through this file.
pub const sample: struct { signed: []const u8, key: []const u8, signature: []const u8 } = .{
    .signed = signed,
    .key = rsa_key,
    .signature = rsa_sha256,
};

const testing = std.testing;

// Made with GnuPG 2.4.9 in a scratch GNUPGHOME on 2026-10-25: an RSA-3072 key and an
// Ed25519 key (EdDSA, algorithm 22), each signing `signed` with --detach-sign.
const signed = "a prebuilt archive, signed\n";

const rsa_key =
    \\-----BEGIN PGP PUBLIC KEY BLOCK-----
    \\
    \\mQGNBGreK3QBDADGm7BZHauVN2/I6VlyJwBUPCTvaIeGpGG82equGI5Gettpe6aY
    \\KORZNDoiqQeT9BHGVWl8O04qqyHl3qI1YbXJZ3ym5I5rIV3muiHghv+sUXkQO0LK
    \\iIqN2iLZpn4YZd52xaXT10wCZpzz/lIVQ0EbmatMgulAiM1wPQ7+9dnfVwzQ3ZAR
    \\+P6sT4rbXxZSgGRr1qQ69KyaTgnuiAxKcM48wt//dGMSDCSpQNjCQvh8IkYFm0ta
    \\LJZlTTwQgn8kOjWfVjaWTJEG7JKyBgWnGMCkV63YWt2ffzotMBGTOq/XnRlREufW
    \\AE8wYhKVRhoZ0yKKj6ki1rfO+5FoFNTmfliNYylJI51ADNttfDB75LxK6vekYPsu
    \\OwLoTtOVkE9q1FYOg0INuxU0DZ8iZLW/n6rJ64YWJW1KtHOdc1IvsG7XddqiRnsT
    \\JwqhV4I7lpXeZ5Sz+BTwRVc9vRrHgVu7srIBFMr7jwU/i/wxXBNBnZTKglJl8igo
    \\Bh6MsxhdQ/VSGcUAEQEAAbQiYmF5IHRlc3QgcnNhIDxyc2FAZXhhbXBsZS5pbnZh
    \\bGlkPokBzgQTAQoAOBYhBIKXkGrR8GNZqR/7pr2RhDlZbq9zBQJq3it0AhsDBQsJ
    \\CAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJEL2RhDlZbq9zxS4L/30y4Kpcs+9rRIcG
    \\dkPvRRf+UanvdVxVhIXV1OQGIK1zAqXJeev2V2G+rzVLocvJl1VAtnTiYxQzzjoh
    \\JxOu2xpBzB/TpXad+eCzNA4gLCWNTqMbN0nO6/cXX+cuiS8X3KhlrsA6/uAP7PHD
    \\uIrYGDN7ZyvBGWA26DdyNg0W4xwVIt4b0WnepqoX0PmZaTFbEcUIXm5NEltbo1xq
    \\8XvrMA5OXpg8WiPJ5WSuZ6Df7rRb5lSkf9YTyf6rY7D/4x+LqCxQK7jzGuAVbwiV
    \\JjIwbknSDx3uVeTkbKGcn5SaT3lsmuM2pywKanS3iepVTW9NHPhyYRc462WItDW2
    \\zd/RDVsWW5cjtE0ffa3JP7vcVL3eo17ZM1GiDKW1J1q2CE/FofhBPGmWCol7c9W2
    \\Yv9m+OYfgNxmZI+ez2q2NhbAhdzmR2c1Phd5KfdlA41gyTyZxG4Dl5ABjqrW+X3L
    \\H1UWcIFaJHZC7oWWHMd0QVMHAeosFp9nWQzEjyYoPJ1o9fsYHA==
    \\=z/gZ
    \\-----END PGP PUBLIC KEY BLOCK-----
    \\
;

/// rsa_key over `signed` with SHA-256, armored.
const rsa_sha256 =
    \\-----BEGIN PGP SIGNATURE-----
    \\
    \\iQGzBAABCAAdFiEEgpeQatHwY1mpH/umvZGEOVlur3MFAmreK3UACgkQvZGEOVlu
    \\r3Pp7Qv8D7EdvLWs3h/KXuo1mJcGblH692pGS/p4fuyylOvU/7uxXNG24gD2kEto
    \\4A0x8utFf7PXPQ9HD7UlntlUvYRU1YrEzS+sNOJvw0o8QX68I5WfsDXcjH5G7s7C
    \\g/hF7Gm/ibIPze4Dx3Hzzv3xHaAl5o9nAENJOtxY81i/6nzFC+B4h5pCxG1OgHgc
    \\NXzRcoHZvXQtem8dPpVal299OPXUpg/Y7ec0K1CQ99iX/HHCDkMqK5QDrau4fFYk
    \\hVhccAY8Aprgiv+s/wYgfQRTkVDbnW7UrePfr4gIgTTtNuj4tJNI8USxfwbfnRp4
    \\kI6tXPi21aH+oBxDpIB66l87pcwVWreEoWnlt6krFQ/shL/tNwM13AcqWqvqIles
    \\1F4u+qU//9Lnz5kHl4vCvcyZs7dv+tXO9LcZnPiLkPa5i/OLv5VDAaM/gTnC1bU1
    \\hMO/rf0CuO4ZddF3dMMYYxKDb9YCJEK6dPl+0OSxRmi9gKT+n7SoEGg27UWUI8JR
    \\3fmyvzQR
    \\=Q8+B
    \\-----END PGP SIGNATURE-----
    \\
;

/// rsa_key over `signed` with SHA-512, binary, as MSYS2 signs (base64 here).
const rsa_sha512 = "iQGzBAABCgAdFiEEgpeQatHwY1mpH/umvZGEOVlur3MFAmreK3UACgkQvZGEOVlur3OOCQwAoTOwq87R0KGDOKtccyXVEZXZ/ORGY/jhRliBjnhlCjE52HDsI5djjrHZiJT1PkJ1k81xjt0CRems5jVo+mkBmNAgnwAmzCDsS5rR/h7F/yzlKPqk/HZSAt2UtLZUrIXcOJ2BWU/payYyzh9VTAM6BidGb1EXjbdoR3mrqDs3NDAJu75BtKbcUbq2FPYwQIAV9v2092Pv47SZoojS7N+aoBbTbbBeF4zctNZTZq6B7b1qds7pL/bXd/U41Ff1ltJW64TA9DF3qeWQD9qbLHB9rgBBISItAzWm4Uu9nJcAlyqAcfFg8rnMzdsLbFP5TH9RD0tZnXwPSw50nttEtHnU3A85pOx80p7pSzUzsUnuf75JGVM2MpooMMIt/0XLJQRRvdGRl9xuxunc3FSXMKjFbEs3F5qL58uM6RlaEy16KUsgU+4R2O+mFkbZCgSMpfNZWiHe0+5afBgcB3N/SWwsu9A+nCQ3dOJzdg0DeCRD0NRRsLZDsBqm2tp5q9/gRjdL";

/// The Ed25519 key, binary (base64 here), and its SHA-256 signature over `signed`, binary.
const ed_key = "mDMEat4rdRYJKwYBBAHaRw8BAQdAgzIv8uN9LhOkIq7mO+3+UTSFwkFCikeafUdZcgPb83a0IGJheSB0ZXN0IGVkIDxlZEBleGFtcGxlLmludmFsaWQ+iJAEExYKADgWIQSi74nR5vO0VtBycWANjERUUuRu9QUCat4rdQIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAKCRANjERUUuRu9VOLAQDd3AHfiIY5XMEXpp+CfuNTq7pqHrbJxXRT9KMxOnm/vQEA5vmAy3fxVNkle8IGjN3MKgkw1n44dapRBtFH2Pacfw0=";
const ed_sha256 = "iHUEABYIAB0WIQSi74nR5vO0VtBycWANjERUUuRu9QUCat4rdQAKCRANjERUUuRu9RlOAQCpTBSCLhKpUlZGdHcZsGHpJBIYOwRceOyBvo6lS6eI+gEA69fBVWeYwnXUtRCel9UdiJrRfi6DZjtLfRV2RVEMBAg=";

/// The Ed25519 key, armored.
const ed_key_armored =
    \\-----BEGIN PGP PUBLIC KEY BLOCK-----
    \\
    \\mDMEat4rdRYJKwYBBAHaRw8BAQdAgzIv8uN9LhOkIq7mO+3+UTSFwkFCikeafUdZ
    \\cgPb83a0IGJheSB0ZXN0IGVkIDxlZEBleGFtcGxlLmludmFsaWQ+iJAEExYKADgW
    \\IQSi74nR5vO0VtBycWANjERUUuRu9QUCat4rdQIbAwULCQgHAgYVCgkICwIEFgID
    \\AQIeAQIXgAAKCRANjERUUuRu9VOLAQDd3AHfiIY5XMEXpp+CfuNTq7pqHrbJxXRT
    \\9KMxOnm/vQEA5vmAy3fxVNkle8IGjN3MKgkw1n44dapRBtFH2Pacfw0=
    \\=FoZp
    \\-----END PGP PUBLIC KEY BLOCK-----
    \\
;

test "a key file of several armored blocks, as a keyring is, holds every key in it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keyring = rsa_key ++ ed_key_armored;
    try testing.expectEqual(2, (try Keys.parse(a, keyring)).list.len);
    try verifyAll(a, keyring, rsa_sha256, signed);
    try verifyAll(a, keyring, try decoded(a, ed_sha256), signed);
}

fn decoded(a: std.mem.Allocator, base64: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(base64));
    try decoder.decode(bytes, base64);
    return bytes;
}

test "an RSA signature over SHA-256 or SHA-512, armored or binary, verifies the file it signs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try verifyAll(a, rsa_key, rsa_sha256, signed);
    try verifyAll(a, rsa_key, try decoded(a, rsa_sha512), signed);
    const keys = try Keys.parse(a, rsa_key);
    try testing.expectEqualStrings("8297906AD1F06359A91FFBA6BD918439596EAF73", &std.fmt.bytesToHex(keys.list[0].fingerprint, .upper));
}

test "an Ed25519 signature verifies the file it signs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try verifyAll(a, try decoded(a, ed_key), try decoded(a, ed_sha256), signed);
}

test "another file, or the file read in part, is not the one signed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.FileMismatch, verifyAll(a, rsa_key, rsa_sha256, "a prebuilt archive, signed!\n"));
    try testing.expectError(error.FileMismatch, verifyAll(a, rsa_key, try decoded(a, rsa_sha512), signed[0 .. signed.len - 1]));
    try testing.expectError(error.FileMismatch, verifyAll(a, try decoded(a, ed_key), try decoded(a, ed_sha256), ""));
}

test "a signature passes the digest's first bytes, and still does not verify when only they match" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The last byte of the RSA value changed: the left bytes still match the digest.
    const changed = try decoded(a, rsa_sha512);
    changed[changed.len - 1] ^= 1;
    try testing.expectError(error.FileMismatch, verifyAll(a, rsa_key, changed, signed));
    const ed_changed = try decoded(a, ed_sha256);
    ed_changed[ed_changed.len - 1] ^= 1;
    try testing.expectError(error.FileMismatch, verifyAll(a, try decoded(a, ed_key), ed_changed, signed));
}

test "a signature by a key the file does not hold is refused, naming the mismatch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.KeyMismatch, verifyAll(a, try decoded(a, ed_key), rsa_sha256, signed));
    try testing.expectError(error.KeyMismatch, verifyAll(a, rsa_key, try decoded(a, ed_sha256), signed));
}

test "an armor whose checksum is wrong is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const broken = try a.dupe(u8, rsa_sha256);
    const at = std.mem.find(u8, broken, "=Q8+B").?;
    broken[at + 1] = 'R';
    try testing.expectError(error.Malformed, Signature.parse(a, broken));
}

test "a SHA-1 signature, a text signature and a hashed critical subpacket bay does not know are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try decoded(a, ed_sha256);
    // The body follows the old-format header's two bytes: version, type, algorithm, hash.
    const sha1 = try a.dupe(u8, base);
    sha1[2 + 3] = 2;
    try testing.expectError(error.UnsupportedHash, Signature.parse(a, sha1));
    const text = try a.dupe(u8, base);
    text[2 + 1] = 1;
    try testing.expectError(error.UnsupportedSignatureType, Signature.parse(a, text));
    // The first hashed subpacket (the issuer's fingerprint, 33) marked critical stays known;
    // the creation time's type changed to an unknown one (99) and marked critical is refused.
    const critical = try a.dupe(u8, base);
    const creation = std.mem.find(u8, critical[8..], &.{ 5, 2 }).? + 8;
    critical[creation + 1] = 0x80 | 99;
    try testing.expectError(error.UnsupportedCritical, Signature.parse(a, critical));
}

test "any bytes parse as a key or a signature, or are refused" {
    const shakedown = @import("shakedown");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const examples: []const []const u8 = &.{ try decoded(arena.allocator(), ed_key), try decoded(arena.allocator(), ed_sha256), try decoded(arena.allocator(), rsa_sha512), rsa_key, rsa_sha256 };
    const property = struct {
        fn body(seeds: []const []const u8, case: *shakedown.Case) anyerror!void {
            var bytes: [4096]u8 = undefined;
            const input = shakedown.gen.mutated(case.source, &bytes, seeds);
            var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const keys = Keys.parse(a, input) catch null;
            const signature = Signature.parse(a, input) catch null;
            if (keys != null and signature != null) {
                var verifier = Verifier.init(signature.?, keys.?) catch return;
                verifier.update(input);
                // The bytes signed hold the signature itself, which no signature can cover:
                // one that verifies here is a forgery.
                const verified = if (verifier.verify()) true else |_| false;
                try testing.expect(!verified);
            }
        }
    };
    try shakedown.check(testing.allocator, examples, property.body, .{});
}
