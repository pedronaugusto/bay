//! One package fetched as Zig records it: by Zig itself, `zig fetch --save`
//! into a scratch manifest, or by git where Zig cannot reach (`git.zig`).
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const root = @import("root.zig");
const say = @import("say.zig");
const git = @import("git.zig");

/// The entry Zig records for `url`, named `name` or by the package's own
/// manifest; null when the fetch failed, which Zig has reported. A URL Zig
/// cannot reach (`git.handles`) is fetched with git, and recorded the same way.
pub fn fetch(io: Io, a: std.mem.Allocator, zig: []const u8, scratch: []const u8, url: []const u8, name: ?[]const u8) !?manifest.Dependency {
    if (git.handles(url)) {
        const fetched = try git.fetch(io, a, zig, scratch, url);
        const given = name orelse (manifest.named(fetched.hash) orelse try say.fail(io, "{s} has no name in its hash {s}; name it with --name", .{ url, fetched.hash })).name;
        return .{ .name = given, .source = .{ .remote = .{ .url = fetched.url, .hash = fetched.hash } } };
    }
    try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, scratch);
    var dir = try Io.Dir.cwd().openDir(io, scratch, .{});
    defer dir.close(io);
    // zig fetch --save edits the manifest beside the nearest build.zig up from here: this one.
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *@import(\"std\").Build) void {}\n" });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try root.scratchManifest(a, "bay_add", "") });
    const save = if (name) |given| try a.print("--save={s}", .{given}) else "--save";
    var child = std.process.spawn(io, .{ .argv = &.{ zig, "fetch", save, url }, .cwd = .{ .path = scratch } }) catch |err|
        try say.fail(io, "could not run {s}: {t}", .{ zig, err });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const text = try dir.readFileAlloc(io, "build.zig.zon", a, .limited(1 << 20));
    const parsed = try manifest.parse(a, try a.dupeSentinel(u8, text, 0));
    if (parsed.normal.len != 1) try say.fail(io, "zig fetch saved {d} dependencies; expected one", .{parsed.normal.len});
    return parsed.normal[0];
}
