//! ssh for bay's release tests: git runs it as `ssh <host> <command>`
//! (`GIT_SSH`, `GIT_SSH_VARIANT=simple`), and it runs the command on this
//! machine, so a release goes through git's own SSH transport to a scratch
//! repository. The command is `git-upload-pack '<path>'` or
//! `git-receive-pack '<path>'`, its path quoted as git quotes it.
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) return error.Usage;
    const command = args[args.len - 1];
    const space = std.mem.findScalar(u8, command, ' ') orelse return error.Usage;
    const program = command[0..space];
    if (!std.mem.startsWith(u8, program, "git-")) return error.Usage;
    var path: std.ArrayList(u8) = .empty;
    // `'...'` with each `'` inside written `'\''`, as git quotes a path for a shell.
    var rest = std.mem.trim(u8, command[space + 1 ..], " ");
    while (rest.len != 0) {
        if (rest[0] == '\'') {
            const close = std.mem.findScalarPos(u8, rest, 1, '\'') orelse return error.Usage;
            try path.appendSlice(a, rest[1..close]);
            rest = rest[close + 1 ..];
        } else if (rest[0] == '\\' and rest.len > 1) {
            try path.append(a, rest[1]);
            rest = rest[2..];
        } else return error.Usage;
    }
    // ssh://host/C:/x reaches here as /C:/x.
    var directory = path.items;
    if (directory.len > 2 and directory[0] == '/' and directory[2] == ':') directory = directory[1..];
    var child = try std.process.spawn(init.io, .{ .argv = &.{ "git", program["git-".len..], directory }, .environ_map = init.environ_map });
    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => 1,
    };
}
