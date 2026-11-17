//! A Zig for bay's tests whose builds are killed before they exit, as the system kills a
//! program short of memory: `zig build` ends itself by SIGKILL and writes nothing, so what
//! bay says is all there is. Every other command is the Zig `KILLED_ZIG` names, run as given.
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "build")) {
        if (@import("builtin").os.tag == .windows) return 3;
        try std.posix.raise(.KILL);
    }
    const zig = init.environ_map.get("KILLED_ZIG") orelse return error.NoZig;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, zig);
    for (args[1..]) |arg| try argv.append(a, arg);
    var child = try std.process.spawn(init.io, .{ .argv = argv.items, .environ_map = init.environ_map });
    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => 1,
    };
}
