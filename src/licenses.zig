//! `bay licenses [--dev]`: every package a build of this one contains, with the
//! license its files state, for whoever ships the build. Zig manifests have no
//! license field, so it is read from the package's license files: an
//! `SPDX-License-Identifier` line when one is there, else the license's text.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const manifest = @import("manifest.zig");
const select = @import("select.zig");
const resolve = @import("resolve.zig");
const store = @import("store.zig");
const say = @import("say.zig");

/// Lists the packages the package's builds contain, its dependencies' dependencies
/// included; `dev` adds what only its development uses. A prebuilt is listed by the name
/// its pin gives, with what its pin's licence file says, or that bay does not read it.
pub fn list(r: resolve.Resolution, dev: bool) !void {
    const a = r.input.a;
    const io = r.input.io;
    const Listed = struct { name: []const u8, revision: select.Revision, prebuilt: ?manifest.Prebuilt };
    var seen: std.array_hash_map.String(Listed) = .empty;
    var pending: std.ArrayList(select.Pin) = .empty;
    try pending.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.normal));
    if (dev) try pending.appendSlice(a, try store.pins(a, r.input.package, r.input.parsed.dev));
    while (pending.pop()) |pin| {
        const revision = r.graph.resolve(pin.place) orelse continue;
        const entry = try seen.getOrPut(a, revision.identity.name);
        if (entry.found_existing) continue;
        const prebuilt = if (pin.place == .remote) pin.place.remote.prebuilt else null;
        entry.value_ptr.* = .{ .name = if (prebuilt != null) pin.key else revision.identity.name, .revision = revision, .prebuilt = prebuilt };
        try pending.appendSlice(a, revision.pins);
    }
    const Order = struct {
        listed: []const Listed,
        pub fn lessThan(order: @This(), x: usize, y: usize) bool {
            return std.mem.order(u8, order.listed[x].name, order.listed[y].name) == .lt;
        }
    };
    seen.sort(Order{ .listed = seen.values() });
    var unknown: usize = 0;
    for (seen.values()) |listed| {
        const directory = switch (listed.revision.place) {
            .remote => |remote| try r.store.directoryOf(remote),
            .directory => |directory| directory,
        };
        if (listed.prebuilt) |fields| {
            try say.out(io, "{s} (prebuilt)  {s}\n", .{ listed.name, try prebuiltLicense(io, a, directory, fields.license) });
            continue;
        }
        const stated = try licenseOf(io, a, directory);
        if (stated == null) unknown += 1;
        try say.out(io, "{s} {f}  {s}\n", .{ listed.name, listed.revision.version, stated orelse "no license found" });
    }
    if (seen.count() == 0) try say.note(io, "the package has no dependencies", .{});
    if (unknown != 0) try say.note(io, "{d} {s} no license bay can read: look at {s} before shipping", .{ unknown, if (unknown == 1) "package states" else "packages state", if (unknown == 1) "it" else "them" });
}

/// What a prebuilt's licence file, `file` in its tree at `directory`, states: its SPDX line
/// or wording, read as a package's is, else that bay does not read it.
fn prebuiltLicense(io: Io, a: std.mem.Allocator, directory: []const u8, file: []const u8) ![]const u8 {
    const text = aegis.own.readFile(io, Io.Dir.cwd(), try std.fs.path.join(a, &.{ directory, file }), a, .fromRaw(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return a.print("no {s} in its tree, which its pin names: look before shipping", .{file}),
        else => |e| return e,
    };
    return try identify(a, text) orelse a.print("terms in {s} that bay does not read: look before shipping", .{file});
}

/// The license a package's files state, as SPDX names it: each license file's,
/// joined with `AND` when there are several (`LICENSE-MIT` and `LICENSE-APACHE`
/// together are usually a choice, which the files themselves say).
fn licenseOf(io: Io, a: std.mem.Allocator, directory: []const u8) !?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return err,
        // No directory to read is no license stated.
        else => return null,
    };
    defer dir.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var unread: usize = 0;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !isLicenseFile(entry.name)) continue;
        const text = try aegis.own.readFile(io, dir, entry.name, a, .fromRaw(1 << 20));
        if (try identify(a, text)) |id| {
            for (found.items) |known| {
                if (std.mem.eql(u8, known, id)) break;
            } else try found.append(a, id);
        } else unread += 1;
    }
    if (found.items.len == 0) return null;
    std.mem.sort([]const u8, found.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    const joined = try std.mem.join(a, " AND ", found.items);
    return if (unread == 0) joined else try a.print("{s} (and {d} license file{s} bay cannot read)", .{ joined, unread, if (unread == 1) "" else "s" });
}

fn isLicenseFile(name: []const u8) bool {
    for ([_][]const u8{ "LICENSE", "LICENCE", "COPYING", "UNLICENSE" }) |stem| {
        if (std.ascii.startsWithIgnoreCase(name, stem)) return true;
    }
    return false;
}

/// The SPDX identifier of a license's text: the identifier line it carries,
/// else what its wording is. Null for text bay does not know.
pub fn identify(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (std.mem.find(u8, text, "SPDX-License-Identifier:")) |at| {
        const rest = std.mem.trimStart(u8, text[at + "SPDX-License-Identifier:".len ..], " \t");
        const end = std.mem.findAny(u8, rest, "\r\n*/") orelse rest.len;
        const id = std.mem.trimEnd(u8, rest[0..end], " \t");
        if (id.len != 0) return id;
    }
    const Known = struct { id: []const u8, all: []const []const u8, none: []const []const u8 = &.{} };
    // The most specific first: a wording that holds another's is checked before it.
    const known = [_]Known{
        .{ .id = "AGPL-3.0", .all = &.{"GNU AFFERO GENERAL PUBLIC LICENSE"} },
        .{ .id = "LGPL-3.0", .all = &.{ "GNU LESSER GENERAL PUBLIC LICENSE", "Version 3" } },
        .{ .id = "LGPL-2.1", .all = &.{ "GNU LESSER GENERAL PUBLIC LICENSE", "Version 2.1" } },
        .{ .id = "GPL-3.0", .all = &.{ "GNU GENERAL PUBLIC LICENSE", "Version 3" } },
        .{ .id = "GPL-2.0", .all = &.{ "GNU GENERAL PUBLIC LICENSE", "Version 2" } },
        .{ .id = "MPL-2.0", .all = &.{"Mozilla Public License Version 2.0"} },
        .{ .id = "Apache-2.0 WITH LLVM-exception", .all = &.{ "Apache License", "Version 2.0", "LLVM Exceptions to the Apache 2.0 License" } },
        .{ .id = "Apache-2.0", .all = &.{ "Apache License", "Version 2.0" } },
        .{ .id = "Unlicense", .all = &.{"This is free and unencumbered software released into the public domain"} },
        .{ .id = "BSL-1.0", .all = &.{"Boost Software License - Version 1.0"} },
        .{ .id = "BSD-3-Clause", .all = &.{ "Redistribution and use in source and binary forms", "Neither the name" } },
        .{ .id = "BSD-2-Clause", .all = &.{"Redistribution and use in source and binary forms"} },
        .{ .id = "MIT", .all = &.{"Permission is hereby granted, free of charge, to any person obtaining a copy"} },
        .{ .id = "ISC", .all = &.{ "Permission to use, copy, modify, and/or distribute this software for any", "provided that the above copyright notice" } },
        .{ .id = "0BSD", .all = &.{"Permission to use, copy, modify, and/or distribute this software for any"} },
        .{ .id = "Zlib", .all = &.{ "This software is provided 'as-is'", "Altered source versions must be plainly marked" } },
    };
    const flat = try flatten(a, text);
    for (known) |license| {
        for (license.all) |phrase| {
            if (std.mem.find(u8, flat, try flatten(a, phrase)) == null) break;
        } else return license.id;
    }
    return null;
}

/// Text with every run of whitespace one space, so wrapping does not change wording.
fn flatten(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var flat: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        if (flat.items.len != 0) try flat.append(a, ' ');
        try flat.appendSlice(a, word);
    }
    return flat.toOwnedSlice(a);
}

test "a license is known by its identifier line or its wording, however it is wrapped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "MIT", "MIT License\n\nPermission is hereby granted, free of charge, to any\nperson obtaining a copy of this software" },
        .{ "MIT OR Apache-2.0", "// SPDX-License-Identifier: MIT OR Apache-2.0\n" },
        .{ "Apache-2.0", "                                 Apache License\n                           Version 2.0, January 2004" },
        // LLVM's, as libc++ ships it: Apache's text with LLVM's exceptions after it.
        .{ "Apache-2.0 WITH LLVM-exception", "The LLVM Project is under the Apache License v2.0 with LLVM Exceptions:\n\n                                 Apache License\n                           Version 2.0, January 2004\n...\n---- LLVM Exceptions to the Apache 2.0 License ----\n\nAs an exception, if, as a result of your compiling your source code" },
        .{ "BSD-3-Clause", "Redistribution and use in source and binary forms, with or without\nmodification... 3. Neither the name of the copyright holder" },
        .{ "BSD-2-Clause", "Redistribution and use in source and binary forms, with or without modification" },
        .{ "ISC", "Permission to use, copy, modify, and/or distribute this software for any\npurpose with or without fee is hereby granted, provided that the above\ncopyright notice" },
        .{ "0BSD", "Permission to use, copy, modify, and/or distribute this software for any\npurpose with or without fee is hereby granted." },
        .{ "LGPL-2.1", "GNU LESSER GENERAL PUBLIC LICENSE\n Version 2.1, February 1999" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[0], (try identify(a, case[1])).?);
    try std.testing.expectEqual(null, try identify(a, "All rights reserved."));
}
