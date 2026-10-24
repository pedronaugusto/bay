//! A build's steps as `zig build -l` lists them.
const std = @import("std");

/// Whether `zig build -l` lists `name`: each step is a line of two spaces, the name, then spaces.
pub fn listed(listing: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ")) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (std.mem.eql(u8, words.next() orelse continue, name)) return true;
    }
    return false;
}

test "a step is found in zig build -l's listing" {
    const listing =
        \\  install (default)            Copy build artifacts to prefix path
        \\  uninstall                    Remove build artifacts from prefix path
        \\  test                         Run the tests
        \\
    ;
    try std.testing.expect(listed(listing, "test"));
    try std.testing.expect(listed(listing, "install"));
    try std.testing.expect(!listed(listing, "preflight"));
}
