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

pub const Manifest = struct {
    name: []const u8,
    minimum_zig_version: ?[]const u8,
    normal: []const Dependency,
    dev: []const Dependency,
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
    for (root.struct_literal.names, 0..) |name, i| {
        const field = name.get(&zoir);
        const value = root.struct_literal.vals.at(@intCast(i)).get(&zoir);
        if (std.mem.eql(u8, field, "name")) {
            if (value != .enum_literal) return error.InvalidManifest;
            manifest.name = try arena.dupe(u8, value.enum_literal.get(&zoir));
        } else if (std.mem.eql(u8, field, "minimum_zig_version")) {
            if (value != .string_literal) return error.InvalidManifest;
            manifest.minimum_zig_version = try arena.dupe(u8, value.string_literal);
        } else if (std.mem.eql(u8, field, Kind.normal.field())) {
            manifest.normal = try dependencies(arena, &zoir, value);
        } else if (std.mem.eql(u8, field, Kind.dev.field())) {
            manifest.dev = try dependencies(arena, &zoir, value);
        }
    }
    if (manifest.name.len == 0) return error.InvalidManifest;
    return manifest;
}

fn dependencies(arena: std.mem.Allocator, zoir: *const Zoir, node: Zoir.Node) ParseError![]const Dependency {
    const entries = switch (node) {
        .empty_literal => return &.{},
        .struct_literal => |entries| entries,
        else => return error.InvalidManifest,
    };
    const list = try arena.alloc(Dependency, entries.names.len);
    for (list, entries.names, 0..) |*dependency, name, i| {
        const value = entries.vals.at(@intCast(i)).get(zoir);
        if (value != .struct_literal) return error.InvalidManifest;
        var url: ?[]const u8 = null;
        var hash: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var lazy = false;
        for (value.struct_literal.names, 0..) |field_name, j| {
            const field = field_name.get(zoir);
            switch (value.struct_literal.vals.at(@intCast(j)).get(zoir)) {
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
        dependency.* = .{ .name = try arena.dupe(u8, name.get(zoir)), .source = source, .lazy = lazy };
    }
    return list;
}

/// `source` with `dependency` in the `kind` list, added or replaced in place,
/// formatted as `zig fmt` formats a manifest.
pub fn put(gpa: std.mem.Allocator, source: [:0]const u8, kind: Kind, dependency: Dependency) ![:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.fmt.allocPrint(a, ".{f} = {f},\n", .{ std.zig.fmtId(dependency.name), entryText(dependency) });
    const located = try locate(a, source, kind, dependency.name);
    const edited = if (located.entry) |range|
        try splice(a, source, range, text)
    else if (located.list) |list|
        try splice(a, source, .{ .start = list.close, .end = list.close }, try std.fmt.allocPrint(a, "{s}{s}", .{ if (list.needs_comma) "," else "", text }))
    else
        try splice(a, source, .{ .start = located.root_close, .end = located.root_close }, try std.fmt.allocPrint(a, "{s}.{s} = .{{\n{s}}},\n", .{ if (located.root_needs_comma) "," else "", kind.field(), text }));
    return format(gpa, edited);
}

/// `source` with an empty `kind` list when it has none, else `null`: nothing to change.
pub fn ensureList(gpa: std.mem.Allocator, source: [:0]const u8, kind: Kind) !?[:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const located = try locate(a, source, kind, "");
    if (located.list != null) return null;
    const text = try std.fmt.allocPrint(a, "{s}.{s} = .{{}},\n", .{ if (located.root_needs_comma) "," else "", kind.field() });
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

fn entryText(dependency: Dependency) std.fmt.Alt(Dependency, writeEntry) {
    return .{ .data = dependency };
}

fn writeEntry(dependency: Dependency, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(".{\n");
    switch (dependency.source) {
        .remote => |remote| try w.print(".url = \"{f}\",\n.hash = \"{f}\",\n", .{ std.zig.fmtString(remote.url), std.zig.fmtString(remote.hash) }),
        .path => |path| try w.print(".path = \"{f}\",\n", .{std.zig.fmtString(path)}),
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
    try std.testing.expect(std.mem.indexOf(u8, added, ".dev_dependencies = .{},") != null);
    try std.testing.expectEqual(null, try ensureList(gpa, added, .dev));
    try std.testing.expectEqual(null, try ensureList(gpa, sample, .normal));
}

test "a dependency missing its hash is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(), ".{ .name = .demo, .dev_dependencies = .{ .tool = .{ .url = \"x\" } } }"));
}
