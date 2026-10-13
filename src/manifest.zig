//! A package's `build.zig.zon`, read and edited through Zig's own ZON parser.
//! `.dev_dependencies` sits beside `.dependencies` with the same entries; Zig
//! ignores the field, so a package that depends on this one never sees it.
const std = @import("std");
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;

/// Which list a dependency belongs to: what the package ships, or what only
/// its development uses.
pub const Kind = enum {
    normal,
    dev,

    pub fn field(kind: Kind) []const u8 {
        return switch (kind) {
            .normal => "dependencies",
            .dev => "dev_dependencies",
        };
    }
};

/// Where a dependency comes from: fetched and pinned by hash, or a directory
/// relative to the manifest.
pub const Source = union(enum) {
    remote: struct { url: []const u8, hash: []const u8 },
    path: []const u8,
};

pub const Dependency = struct { name: []const u8, source: Source, lazy: bool = false };

/// One entry of the manifest in `directory` that must change: `from`, in the
/// list `kind`, becomes `to`.
pub const Repin = struct { directory: []const u8, kind: Kind, from: Dependency, to: Dependency };

/// What a Zig package hash names: `<name>-<version>-<44 characters>`.
pub const Named = struct { name: []const u8, version: std.SemanticVersion };

pub fn named(hash: []const u8) ?Named {
    const suffix = 44;
    const dash = std.mem.findScalar(u8, hash, '-') orelse return null;
    if (hash.len < dash + 1 + 1 + suffix or hash[hash.len - suffix - 1] != '-') return null;
    const version = std.SemanticVersion.parse(hash[dash + 1 .. hash.len - suffix - 1]) catch return null;
    return .{ .name = hash[0..dash], .version = version };
}

pub const Manifest = struct {
    name: []const u8,
    /// The package's `.version`; a manifest without one is 0.0.0.
    version: []const u8 = "0.0.0",
    /// With the name, what the package is whatever its revision; 0 when absent.
    fingerprint: u64 = 0,
    minimum_zig_version: ?[]const u8,
    normal: []const Dependency,
    dev: []const Dependency,
    /// bay's: packages replaced for the whole graph when this package is the root.
    overrides: []const Dependency = &.{},
    /// bay's: packages whose incompatible lines may be selected side by side.
    coexist: []const []const u8 = &.{},
    /// bay's: the exact Zig this package builds with; else `minimum_zig_version`.
    zig_version: ?[]const u8 = null,
    /// bay's: versions of this package no selection may pick, read from its newest manifest.
    retracted: []const []const u8 = &.{},
};

pub const ParseError = error{ InvalidManifest, OutOfMemory };

/// Reads the fields bay needs. Strings are owned by `arena`.
pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) ParseError!Manifest {
    const tree = try Ast.parse(arena, source, .{ .mode = .zon });
    if (tree.errors.len != 0) return error.InvalidManifest;
    const zoir = try std.zig.ZonGen.generate(arena, tree, .{});
    if (zoir.hasCompileErrors()) return error.InvalidManifest;
    const root = Zoir.Node.Index.root.get(&zoir);
    if (root != .struct_literal) return error.InvalidManifest;
    var manifest: Manifest = .{ .name = "", .minimum_zig_version = null, .normal = &.{}, .dev = &.{} };
    var fields: Fields = .of(root.struct_literal);
    while (fields.next(&zoir)) |entry| {
        const field = entry.name;
        const value = entry.value;
        if (std.mem.eql(u8, field, "name")) {
            if (value != .enum_literal) return error.InvalidManifest;
            manifest.name = try arena.dupe(u8, value.enum_literal.get(&zoir));
        } else if (std.mem.eql(u8, field, "minimum_zig_version")) {
            manifest.minimum_zig_version = try string(arena, value);
        } else if (std.mem.eql(u8, field, "version")) {
            manifest.version = try string(arena, value);
        } else if (std.mem.eql(u8, field, "zig_version")) {
            manifest.zig_version = try string(arena, value);
        } else if (std.mem.eql(u8, field, "fingerprint")) {
            manifest.fingerprint = switch (value) {
                .int_literal => |number| switch (number) {
                    .small => |small| std.math.cast(u64, small) orelse return error.InvalidManifest,
                    .big => |big| big.toInt(u64) catch return error.InvalidManifest,
                },
                else => return error.InvalidManifest,
            };
        } else if (std.mem.eql(u8, field, "overrides")) {
            manifest.overrides = try dependencies(arena, &zoir, value);
        } else if (std.mem.eql(u8, field, "coexist")) {
            manifest.coexist = try names(arena, &zoir, value);
        } else if (std.mem.eql(u8, field, "retracted")) {
            manifest.retracted = try strings(arena, &zoir, value);
        } else if (std.mem.eql(u8, field, Kind.normal.field())) {
            manifest.normal = try dependencies(arena, &zoir, value);
        } else if (std.mem.eql(u8, field, Kind.dev.field())) {
            manifest.dev = try dependencies(arena, &zoir, value);
        }
    }
    if (manifest.name.len == 0) return error.InvalidManifest;
    return manifest;
}

/// A ZON list's items in order, by the `u32` index Zoir gives them.
const Items = struct {
    range: Zoir.Node.Index.Range,
    index: u32 = 0,

    fn next(items: *Items, zoir: *const Zoir) ?Zoir.Node {
        if (items.index == items.range.len) return null;
        defer items.index += 1;
        return items.range.at(items.index).get(zoir);
    }
};

/// A ZON struct's fields in order: each name with its value, by the `u32` index Zoir gives them.
const Fields = struct {
    names: []const Zoir.NullTerminatedString,
    values: Zoir.Node.Index.Range,
    index: u32 = 0,

    const Field = struct { name: []const u8, value: Zoir.Node };

    fn of(literal: @FieldType(Zoir.Node, "struct_literal")) Fields {
        return .{ .names = literal.names, .values = literal.vals };
    }

    fn next(fields: *Fields, zoir: *const Zoir) ?Field {
        if (fields.index == fields.values.len) return null;
        defer fields.index += 1;
        return .{ .name = fields.names[fields.index].get(zoir), .value = fields.values.at(fields.index).get(zoir) };
    }
};

fn string(arena: std.mem.Allocator, node: Zoir.Node) ParseError![]const u8 {
    if (node != .string_literal) return error.InvalidManifest;
    return arena.dupe(u8, node.string_literal);
}

/// A list of strings: `.{ "0.2.1", "0.3.0" }`.
fn strings(arena: std.mem.Allocator, zoir: *const Zoir, node: Zoir.Node) ParseError![]const []const u8 {
    const range = switch (node) {
        .empty_literal => return &.{},
        .array_literal => |range| range,
        else => return error.InvalidManifest,
    };
    var list: std.ArrayList([]const u8) = .empty;
    var items: Items = .{ .range = range };
    while (items.next(zoir)) |item| try list.append(arena, try string(arena, item));
    return list.items;
}

/// A list of package names: `.{ .aegis, .glint }`.
fn names(arena: std.mem.Allocator, zoir: *const Zoir, node: Zoir.Node) ParseError![]const []const u8 {
    const range = switch (node) {
        .empty_literal => return &.{},
        .array_literal => |range| range,
        else => return error.InvalidManifest,
    };
    var list: std.ArrayList([]const u8) = .empty;
    var items: Items = .{ .range = range };
    while (items.next(zoir)) |item| {
        if (item != .enum_literal) return error.InvalidManifest;
        try list.append(arena, try arena.dupe(u8, item.enum_literal.get(zoir)));
    }
    return list.items;
}

fn dependencies(arena: std.mem.Allocator, zoir: *const Zoir, node: Zoir.Node) ParseError![]const Dependency {
    const entries = switch (node) {
        .empty_literal => return &.{},
        .struct_literal => |entries| entries,
        else => return error.InvalidManifest,
    };
    var list: std.ArrayList(Dependency) = .empty;
    var each: Fields = .of(entries);
    while (each.next(zoir)) |entry| {
        const value = entry.value;
        if (value != .struct_literal) return error.InvalidManifest;
        var url: ?[]const u8 = null;
        var hash: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var lazy = false;
        var fields: Fields = .of(value.struct_literal);
        while (fields.next(zoir)) |pair| {
            const field = pair.name;
            switch (pair.value) {
                .string_literal => |text| {
                    const copy = try arena.dupe(u8, text);
                    if (std.mem.eql(u8, field, "url")) url = copy else if (std.mem.eql(u8, field, "hash")) hash = copy else if (std.mem.eql(u8, field, "path")) path = copy else return error.InvalidManifest;
                },
                .true => if (std.mem.eql(u8, field, "lazy")) {
                    lazy = true;
                } else return error.InvalidManifest,
                .false => if (!std.mem.eql(u8, field, "lazy")) return error.InvalidManifest,
                else => return error.InvalidManifest,
            }
        }
        const source: Source = if (path) |p| .{ .path = p } else .{ .remote = .{ .url = url orelse return error.InvalidManifest, .hash = hash orelse return error.InvalidManifest } };
        try list.append(arena, .{ .name = try arena.dupe(u8, entry.name), .source = source, .lazy = lazy });
    }
    return list.items;
}

/// `source` with `dependency` in the `kind` list, added or replaced in place,
/// formatted as `zig fmt` formats a manifest.
pub fn put(gpa: std.mem.Allocator, source: [:0]const u8, kind: Kind, dependency: Dependency) ![:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try a.print(".{f} = {f},\n", .{ std.zig.fmtId(dependency.name), entryText(dependency) });
    const located = try locate(a, source, kind, dependency.name);
    const edited = if (located.entry) |range|
        try splice(a, source, range, text)
    else if (located.list) |list|
        try splice(a, source, .{ .start = list.close, .end = list.close }, try a.print("{s}{s}", .{ if (list.needs_comma) "," else "", text }))
    else
        try splice(a, source, .{ .start = located.root_close, .end = located.root_close }, try a.print("{s}.{s} = .{{\n{s}}},\n", .{ if (located.root_needs_comma) "," else "", kind.field(), text }));
    return format(gpa, edited);
}

/// `source` with an empty `kind` list when it has none, else `null`: nothing to change.
pub fn ensureList(gpa: std.mem.Allocator, source: [:0]const u8, kind: Kind) !?[:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const located = try locate(a, source, kind, "");
    if (located.list != null) return null;
    const text = try a.print("{s}.{s} = .{{}},\n", .{ if (located.root_needs_comma) "," else "", kind.field() });
    return try format(gpa, try splice(a, source, .{ .start = located.root_close, .end = located.root_close }, text));
}

/// `source` without the dependency `name` in the `kind` list; `error.NotFound` when there is none.
pub fn remove(gpa: std.mem.Allocator, source: [:0]const u8, kind: Kind, name: []const u8) ![:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const range = (try locate(a, source, kind, name)).entry orelse return error.NotFound;
    return format(gpa, try splice(a, source, range, ""));
}

/// A path as a manifest holds it: escaped as a ZON string, with `/` between its
/// parts on every host, so a manifest written on Windows reads the same elsewhere.
pub fn portable(path: []const u8) std.fmt.Alt([]const u8, writePortable) {
    return .{ .data = path };
}

fn writePortable(path: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var parts = std.mem.splitScalar(u8, path, '\\');
    var first = true;
    while (parts.next()) |part| : (first = false) {
        if (!first) try w.writeByte('/');
        try w.print("{f}", .{std.zig.fmtString(part)});
    }
}

fn entryText(dependency: Dependency) std.fmt.Alt(Dependency, writeEntry) {
    return .{ .data = dependency };
}

fn writeEntry(dependency: Dependency, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(".{\n");
    switch (dependency.source) {
        .remote => |remote| try w.print(".url = \"{f}\",\n.hash = \"{f}\",\n", .{ std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) }),
        .path => |path| try w.print(".path = \"{f}\",\n", .{portable(path)}),
    }
    if (dependency.lazy) try w.writeAll(".lazy = true,\n");
    try w.writeAll("}");
}

const Range = struct { start: usize, end: usize };

const Located = struct {
    /// The whole `.name = .{...},` of an existing entry, trailing comma included.
    entry: ?Range = null,
    /// The list's literal: where an entry is inserted.
    list: ?struct { close: usize, needs_comma: bool } = null,
    /// The manifest's closing brace: where a missing list is inserted.
    root_close: usize,
    root_needs_comma: bool,
};

fn locate(a: std.mem.Allocator, source: [:0]const u8, kind: Kind, name: []const u8) !Located {
    const tree = try Ast.parse(a, source, .{ .mode = .zon });
    if (tree.errors.len != 0) return error.InvalidManifest;
    var buffer: [2]Ast.Node.Index = undefined;
    const root_node = tree.nodeData(.root).node;
    const root = tree.fullStructInit(&buffer, root_node) orelse return error.InvalidManifest;
    var located: Located = .{ .root_close = tree.tokenStart(tree.lastToken(root_node)), .root_needs_comma = needsComma(tree, root_node, root.ast.fields) };
    for (root.ast.fields) |field| {
        if (!std.mem.eql(u8, fieldName(tree, field), kind.field())) continue;
        var list_buffer: [2]Ast.Node.Index = undefined;
        const list = tree.fullStructInit(&list_buffer, field) orelse return error.InvalidManifest;
        located.list = .{ .close = tree.tokenStart(tree.lastToken(field)), .needs_comma = needsComma(tree, field, list.ast.fields) };
        for (list.ast.fields) |entry| {
            if (!std.mem.eql(u8, fieldName(tree, entry), name)) continue;
            // `.name = value`: the dot is three tokens before the value.
            const start = tree.tokenStart(tree.firstToken(entry) - 3);
            var last = tree.lastToken(entry);
            if (tree.tokenTag(last + 1) == .comma) last += 1;
            located.entry = .{ .start = start, .end = tree.tokenStart(last) + tree.tokenSlice(last).len };
        }
    }
    return located;
}

/// The field name of a struct literal's value node, `@"..."` quoting removed.
fn fieldName(tree: Ast, value: Ast.Node.Index) []const u8 {
    const slice = tree.tokenSlice(tree.firstToken(value) - 2);
    return if (std.mem.startsWith(u8, slice, "@\"")) slice[2 .. slice.len - 1] else slice;
}

/// Whether a field inserted before the literal's closing brace needs a comma first.
fn needsComma(tree: Ast, literal: Ast.Node.Index, fields: []const Ast.Node.Index) bool {
    if (fields.len == 0) return false;
    return tree.tokenTag(tree.lastToken(literal) - 1) != .comma;
}

fn splice(a: std.mem.Allocator, source: []const u8, range: Range, text: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{ source[0..range.start], text, source[range.end..] }, 0);
}

fn format(gpa: std.mem.Allocator, source: [:0]const u8) ![:0]u8 {
    var tree = try Ast.parse(gpa, source, .{ .mode = .zon });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.InvalidManifest;
    const rendered = try tree.renderAlloc(gpa);
    defer gpa.free(rendered);
    return gpa.dupeSentinel(u8, rendered, 0);
}

/// The URL to fetch to follow a pin: a git URL's recorded `?ref=` as its
/// fragment, or the URL as it is for an archive. Null when a git URL names
/// only a commit.
pub fn following(a: std.mem.Allocator, url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "git+")) return url;
    const without_commit = url[0 .. std.mem.findScalar(u8, url, '#') orelse url.len];
    const query = std.mem.find(u8, without_commit, "?ref=") orelse return null;
    return a.print("{s}#{s}", .{ without_commit[0..query], without_commit[query + "?ref=".len ..] }) catch null;
}

const sample =
    \\.{
    \\    .name = .demo,
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.17.0",
    \\    .fingerprint = 0x1,
    \\    .paths = .{""},
    \\    .dependencies = .{},
    \\}
    \\
;

test "a manifest without dependencies has none of either kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(), sample);
    try std.testing.expectEqualStrings("demo", manifest.name);
    try std.testing.expectEqualStrings("0.17.0", manifest.minimum_zig_version.?);
    try std.testing.expectEqual(0, manifest.normal.len);
    try std.testing.expectEqual(0, manifest.dev.len);
}

test "put adds the dev list, then entries, then replaces one in place" {
    const gpa = std.testing.allocator;
    const first = try put(gpa, sample, .dev, .{ .name = "tool", .source = .{ .remote = .{ .url = "git+https://example.org/tool#v1", .hash = "tool-0.1.0-AAAA" } } });
    defer gpa.free(first);
    try std.testing.expectEqualStrings(
        \\.{
        \\    .name = .demo,
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.17.0",
        \\    .fingerprint = 0x1,
        \\    .paths = .{""},
        \\    .dependencies = .{},
        \\    .dev_dependencies = .{
        \\        .tool = .{
        \\            .url = "git+https://example.org/tool#v1",
        \\            .hash = "tool-0.1.0-AAAA",
        \\        },
        \\    },
        \\}
        \\
    , first);
    const second = try put(gpa, first, .dev, .{ .name = "local", .source = .{ .path = "../local" } });
    defer gpa.free(second);
    const third = try put(gpa, second, .dev, .{ .name = "tool", .source = .{ .remote = .{ .url = "git+https://example.org/tool#v2", .hash = "tool-0.2.0-BBBB" } } });
    defer gpa.free(third);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(), third);
    try std.testing.expectEqual(0, manifest.normal.len);
    try std.testing.expectEqual(2, manifest.dev.len);
    try std.testing.expectEqualStrings("tool", manifest.dev[0].name);
    try std.testing.expectEqualStrings("tool-0.2.0-BBBB", manifest.dev[0].source.remote.hash);
    try std.testing.expectEqualStrings("local", manifest.dev[1].name);
    try std.testing.expectEqualStrings("../local", manifest.dev[1].source.path);
    const removed = try remove(gpa, third, .dev, "tool");
    defer gpa.free(removed);
    const after = try parse(arena.allocator(), removed);
    try std.testing.expectEqual(1, after.dev.len);
    try std.testing.expectEqualStrings("local", after.dev[0].name);
    try std.testing.expectError(error.NotFound, remove(gpa, removed, .dev, "tool"));
}

test "a normal dependency goes in .dependencies, lazy when asked" {
    const gpa = std.testing.allocator;
    const result = try put(gpa, sample, .normal, .{ .name = "lib", .source = .{ .remote = .{ .url = "https://example.org/lib.tar.gz", .hash = "lib-1.0.0-CCCC" } }, .lazy = true });
    defer gpa.free(result);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(), result);
    try std.testing.expectEqual(1, manifest.normal.len);
    try std.testing.expect(manifest.normal[0].lazy);
    try std.testing.expectEqual(0, manifest.dev.len);
}

test "put into a manifest whose last field has no trailing comma" {
    const gpa = std.testing.allocator;
    const result = try put(gpa, ".{ .name = .demo, .version = \"0.1.0\" }", .dev, .{ .name = "tool", .source = .{ .path = "tool" } });
    defer gpa.free(result);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(), result);
    try std.testing.expectEqualStrings("tool", manifest.dev[0].source.path);
}

test "ensureList adds an empty list once" {
    const gpa = std.testing.allocator;
    const added = (try ensureList(gpa, sample, .dev)).?;
    defer gpa.free(added);
    try std.testing.expect(std.mem.find(u8, added, ".dev_dependencies = .{},") != null);
    try std.testing.expectEqual(null, try ensureList(gpa, added, .dev));
    try std.testing.expectEqual(null, try ensureList(gpa, sample, .normal));
}

test "a dependency missing its hash is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(), ".{ .name = .demo, .dev_dependencies = .{ .tool = .{ .url = \"x\" } } }"));
}

test "any bytes parse or are refused, and a dependency put into what parses parses back" {
    const shakedown = @import("shakedown");
    const examples: []const []const u8 = &.{
        ".{ .name = .demo, .version = \"0.0.0\", .dependencies = .{} }",
        ".{ .name = .demo, .dependencies = .{ .a = .{ .url = \"git+https://example.org/a#1\", .hash = \"a-1\", .lazy = true } }, .dev_dependencies = .{ .t = .{ .path = \"../t\" } } }",
        ".{ .name = .demo, .paths = .{\"\"} }",
    };
    const property = struct {
        fn body(_: void, case: *shakedown.Case) anyerror!void {
            var bytes: [4096]u8 = undefined;
            try parseAny(shakedown.gen.mutated(case.source, &bytes, examples));
        }
    };
    for (examples) |example| try parseAny(example);
    try shakedown.check(std.testing.allocator, {}, property.body, .{});
}

fn parseAny(bytes: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8, bytes, 0);
    _ = parse(a, source) catch |err| switch (err) {
        error.InvalidManifest => return,
        error.OutOfMemory => return err,
    };
    const added: Dependency = .{ .name = "fuzzed", .source = .{ .path = "../fuzzed" } };
    for ([_]Kind{ .normal, .dev }) |kind| {
        const edited = try put(a, source, kind, added);
        const back = try parse(a, edited);
        const list = if (kind == .dev) back.dev else back.normal;
        var found = false;
        for (list) |dependency| found = found or std.mem.eql(u8, dependency.name, added.name);
        try std.testing.expect(found);
    }
}

test "the fields resolution reads: version, fingerprint, overrides, coexist, the Zig, retractions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\.{
        \\    .name = .demo,
        \\    .version = "0.4.1",
        \\    .fingerprint = 0xa1b2c3d4e5f60718,
        \\    .minimum_zig_version = "0.17.0",
        \\    .zig_version = "0.17.0",
        \\    .dependencies = .{},
        \\    .overrides = .{ .aegis = .{ .path = "../aegis" } },
        \\    .coexist = .{ .strand, .warp },
        \\    .retracted = .{ "0.4.0" },
        \\}
    ;
    const parsed = try parse(arena.allocator(), text);
    try std.testing.expectEqualStrings("0.4.1", parsed.version);
    try std.testing.expectEqual(0xa1b2c3d4e5f60718, parsed.fingerprint);
    try std.testing.expectEqualStrings("0.17.0", parsed.zig_version.?);
    try std.testing.expectEqualStrings("../aegis", parsed.overrides[0].source.path);
    try std.testing.expectEqualStrings("warp", parsed.coexist[1]);
    try std.testing.expectEqualStrings("0.4.0", parsed.retracted[0]);
}

test "a path is written with / between its parts on every host" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A quote is still escaped as ZON escapes it.
    try std.testing.expectEqualStrings("a\\\"b/c", try a.print("{f}", .{portable("a\"b\\c")}));
    try std.testing.expectEqualStrings("../core", try a.print("{f}", .{portable("..\\core")}));
    try std.testing.expectEqualStrings("C:/work/core", try a.print("{f}", .{portable("C:\\work\\core")}));
}

test "a package hash names the package and its version" {
    const ghostty = named("ghostty-1.3.2-dev-5UdBC-lZeAVJbemF7Fz8y5ApP0uA6wTc2uzECn3c6Z_Y").?;
    try std.testing.expectEqualStrings("ghostty", ghostty.name);
    try std.testing.expectEqualStrings("dev", ghostty.version.pre.?);
    const aegis = named("aegis-0.2.1-" ++ &@as([44]u8, @splat('A'))).?;
    try std.testing.expectEqualStrings("aegis", aegis.name);
    try std.testing.expectEqual(1, aegis.version.patch);
    try std.testing.expectEqual(null, named("aegis-0.2.1-short"));
    try std.testing.expectEqual(null, named("1220" ++ &@as([64]u8, @splat('0'))));
}
