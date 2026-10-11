//! One package fetched by Zig itself: `zig fetch --save` into a scratch
//! manifest, so its URL and hash are exactly what Zig would record.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const root = @import("root.zig");
const say = @import("say.zig");

/// The entry Zig records for `url`, named `name` or by the package's own
/// manifest; null when the fetch failed, which Zig has reported.
pub fn fetch(io: Io, a: std.mem.Allocator, zig: []const u8, scratch: []const u8, url: []const u8, name: ?[]const u8) !?manifest.Dependency {
    try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, scratch);
    var dir = try Io.Dir.cwd().openDir(io, scratch, .{});
    defer dir.close(io);
    // zig fetch --save edits the manifest beside the nearest build.zig up from here: this one.
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *@import(\"std\").Build) void {}\n" });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try root.scratchManifest(a) });
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
