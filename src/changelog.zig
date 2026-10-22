//! CHANGELOG.md as Keep a Changelog writes it: what its `## [Unreleased]`
//! section says changed, the version that makes, and the section cut into
//! that release. bay writes releases from it; preflight checks a package's
//! section against its API with the same reading. std only.
const std = @import("std");

/// A group of the section, in the order a release writes them: breaking
/// changes first, as the family writes them, then Keep a Changelog's own.
pub const Group = enum {
    breaking,
    added,
    changed,
    deprecated,
    removed,
    fixed,
    security,

    pub fn heading(group: Group) []const u8 {
        return switch (group) {
            .breaking => "Breaking",
            .added => "Added",
            .changed => "Changed",
            .deprecated => "Deprecated",
            .removed => "Removed",
            .fixed => "Fixed",
            .security => "Security",
        };
    }

    fn named(name: []const u8) ?Group {
        for (std.enums.values(Group)) |group| {
            if (std.ascii.eqlIgnoreCase(name, group.heading())) return group;
        }
        return null;
    }

    /// What an entry of the group asks of the version.
    pub fn change(group: Group) Change {
        return switch (group) {
            // Removing what a consumer used breaks it, as semver reads Removed.
            .breaking, .removed => .breaking,
            .added, .deprecated => .feature,
            .changed, .fixed, .security => .fix,
        };
    }
};

/// What a set of entries asks of the version, least to most.
pub const Change = enum {
    none,
    fix,
    feature,
    breaking,

    pub fn max(x: Change, y: Change) Change {
        return if (@backingInt(x) >= @backingInt(y)) x else y;
    }
};

/// The next release after `from` for `change`: below 1.0 a breaking change moves
/// the minor and anything else the last number; from 1.0, semver's major, minor
/// and patch. Pre-release and build parts are not versions a package releases.
pub fn next(from: std.SemanticVersion, change: Change) std.SemanticVersion {
    std.debug.assert(change != .none); // nothing changed makes no release
    if (from.major == 0) return switch (change) {
        .breaking => .{ .major = 0, .minor = from.minor + 1, .patch = 0 },
        else => .{ .major = 0, .minor = from.minor, .patch = from.patch + 1 },
    };
    return switch (change) {
        .none => unreachable, // unreachable: asserted above
        .breaking => .{ .major = from.major + 1, .minor = 0, .patch = 0 },
        .feature => .{ .major = from.major, .minor = from.minor + 1, .patch = 0 },
        .fix => .{ .major = from.major, .minor = from.minor, .patch = from.patch + 1 },
    };
}

/// A release number: major.minor.patch, no leading zeros, nothing after.
pub fn parseVersion(text: []const u8) ?std.SemanticVersion {
    const version = std.SemanticVersion.parse(text) catch return null;
    if (version.pre != null or version.build != null) return null;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| if (part.len > 1 and part[0] == '0') return null;
    return version;
}

/// One group's entries as the section holds them; `group` null for a heading
/// Keep a Changelog does not name, kept by `name`.
pub const Entries = struct {
    group: ?Group,
    name: []const u8,
    /// Each entry's lines, its bullet first, with no trailing newline.
    entries: []const []const u8,
};

pub const Section = struct {
    /// Every group with an entry, merged by heading, known ones in release
    /// order, then the others in the order they came.
    groups: []const Entries,

    pub fn change(section: Section) Change {
        var most: Change = .none;
        for (section.groups) |entries| most = most.max(if (entries.group) |g| g.change() else .fix);
        return most;
    }

    pub fn empty(section: Section) bool {
        return section.groups.len == 0;
    }

    /// The groups as a release writes them: `### Heading`, a blank line, the
    /// entries, and a blank line between groups.
    pub fn write(section: Section, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (section.groups, 0..) |entries, index| {
            if (index != 0) try w.writeByte('\n');
            try w.print("### {s}\n\n", .{entries.name});
            for (entries.entries) |entry| try w.print("{s}\n", .{entry});
        }
    }
};

pub const Problem = struct {
    /// The line, from 1, of the CHANGELOG.
    line: usize,
    what: []const u8,
};

pub const ParseError = error{ OutOfMemory, NoUnreleased, Malformed };

const unreleased_heading = "## [Unreleased]";

fn isLinkReference(line: []const u8) bool {
    if (line.len < 4 or line[0] != '[') return false;
    const close = std.mem.findScalar(u8, line, ']') orelse return false;
    return close + 1 < line.len and line[close + 1] == ':';
}

/// Where a section's lines run: from after its heading to the next `## ` heading
/// or the link references.
const Range = struct { heading: usize, start: usize, end: usize };

fn sectionAfter(text: []const u8, heading_at: usize) Range {
    const start = if (std.mem.findScalarPos(u8, text, heading_at, '\n')) |nl| nl + 1 else text.len;
    var offset = start;
    while (offset < text.len) {
        const end = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[offset..end], " \t\r");
        if (std.mem.startsWith(u8, line, "## ") or isLinkReference(line)) break;
        offset = end + 1;
    }
    return .{ .heading = heading_at, .start = start, .end = @min(offset, text.len) };
}

fn findUnreleased(text: []const u8) ?Range {
    var offset: usize = 0;
    while (offset < text.len) {
        const end = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, text[offset..end], " \t\r"), unreleased_heading)) return sectionAfter(text, offset);
        offset = end + 1;
    }
    return null;
}

fn lineOf(text: []const u8, offset: usize) usize {
    return std.mem.countScalar(u8, text[0..offset], '\n') + 1;
}

/// The `## [Unreleased]` section of `text`. A line with no group above it has
/// no kind and is refused, its line in `problem`.
pub fn unreleased(a: std.mem.Allocator, text: []const u8, problem: *Problem) ParseError!Section {
    const range = findUnreleased(text) orelse {
        problem.* = .{ .line = 0, .what = "no `## [Unreleased]` section" };
        return error.NoUnreleased;
    };
    return parseSection(a, text, range, problem);
}

/// The groups of the section `range` holds.
fn parseSection(a: std.mem.Allocator, text: []const u8, range: Range, problem: *Problem) ParseError!Section {
    const Open = struct { group: ?Group, name: []const u8, entries: std.ArrayList([]const u8) };
    var open: std.ArrayList(Open) = .empty;
    var current: ?usize = null;
    // The entry being read: where it starts in `text` and where its last line with text ends.
    var entry: ?struct { start: usize, end: usize } = null;
    const close = struct {
        fn close(arena: std.mem.Allocator, groups: []Open, at: ?usize, source: []const u8, read: anytype) !void {
            const span = read orelse return;
            const body = source[span.start..span.end];
            const entries = &groups[at.?].entries; // safe: an entry is read only inside a group
            for (entries.items) |kept| if (std.mem.eql(u8, kept, body)) return;
            try entries.append(arena, body);
        }
    }.close;
    var offset = range.start;
    while (offset < range.end) {
        const end = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
        const raw = std.mem.trimEnd(u8, text[offset..@min(end, range.end)], " \t\r");
        defer offset = end + 1;
        if (raw.len == 0) continue;
        const indented = raw[0] == ' ' or raw[0] == '\t';
        if (!indented and std.mem.startsWith(u8, raw, "### ")) {
            try close(a, open.items, current, text, entry);
            entry = null;
            const name = std.mem.trim(u8, raw["### ".len..], " \t");
            const group = Group.named(name);
            current = for (open.items, 0..) |existing, index| {
                const same = if (group) |g| existing.group == g else (existing.group == null and std.mem.eql(u8, existing.name, name));
                if (same) break index;
            } else blk: {
                try open.append(a, .{ .group = group, .name = if (group) |g| g.heading() else name, .entries = .empty });
                break :blk open.items.len - 1;
            };
            continue;
        }
        if (current == null) {
            problem.* = .{ .line = lineOf(text, offset), .what = "an entry under no group: put it under ### Breaking, ### Added, ### Changed, ### Deprecated, ### Removed, ### Fixed or ### Security" };
            return error.Malformed;
        }
        const bullet = !indented and (std.mem.startsWith(u8, raw, "- ") or std.mem.startsWith(u8, raw, "* ") or std.mem.eql(u8, raw, "-"));
        if (bullet or entry == null) {
            try close(a, open.items, current, text, entry);
            entry = .{ .start = offset, .end = offset + raw.len };
        } else entry.?.end = offset + raw.len; // safe: the branch above starts one when there is none
    }
    try close(a, open.items, current, text, entry);
    var groups: std.ArrayList(Entries) = .empty;
    // Known groups in release order, then the others as they came.
    for (std.enums.values(Group)) |group| {
        for (open.items) |o| if (o.group == group and o.entries.items.len != 0)
            try groups.append(a, .{ .group = o.group, .name = o.name, .entries = o.entries.items });
    }
    for (open.items) |o| if (o.group == null and o.entries.items.len != 0)
        try groups.append(a, .{ .group = null, .name = o.name, .entries = o.entries.items });
    return .{ .groups = groups.items };
}

/// `text` with `entry` (a `- ` line) under `group` in the Unreleased section:
/// after the group's last entry, or in a group of its own at the section's end.
pub fn addEntry(a: std.mem.Allocator, text: []const u8, group: Group, entry: []const u8) ParseError![]const u8 {
    const range = findUnreleased(text) orelse return error.NoUnreleased;
    // Where the heading's line ends, and where the last line with text in the group, and in the section, end.
    var heading_end = std.mem.findScalarPos(u8, text, range.heading, '\n') orelse text.len;
    heading_end = @min(heading_end, text.len);
    var section_end = heading_end;
    var in_group = false;
    var group_end: ?usize = null;
    var group_has_entry = false;
    var offset = range.start;
    while (offset < range.end) {
        const end = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[offset..@min(end, range.end)], " \t\r");
        defer offset = end + 1;
        if (line.len == 0) continue;
        section_end = offset + line.len;
        if (std.mem.startsWith(u8, line, "### ")) {
            in_group = Group.named(std.mem.trim(u8, line["### ".len..], " \t")) == group;
            if (in_group) {
                group_end = offset + line.len;
                group_has_entry = false;
            }
            continue;
        }
        if (in_group) {
            group_end = offset + line.len;
            group_has_entry = true;
        }
    }
    if (group_end) |at| return std.mem.concat(a, u8, &.{ text[0..at], if (group_has_entry) "\n" else "\n\n", entry, text[at..] });
    return std.mem.concat(a, u8, &.{ text[0..section_end], "\n\n### ", group.heading(), "\n\n", entry, text[section_end..] });
}

test "an entry goes under its group, or in a group of its own at the section's end" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "## [Unreleased]\n\n### Changed\n\n- Pins x 1.0.0.\n\n## [0.1.0] - x\n",
        try addEntry(a, "## [Unreleased]\n\n## [0.1.0] - x\n", .changed, "- Pins x 1.0.0."),
    );
    try std.testing.expectEqualStrings(
        "## [Unreleased]\n\n### Changed\n\n- A.\n- Pins x 1.0.0.\n\n### Fixed\n\n- F.\n",
        try addEntry(a, "## [Unreleased]\n\n### Changed\n\n- A.\n\n### Fixed\n\n- F.\n", .changed, "- Pins x 1.0.0."),
    );
    try std.testing.expectEqualStrings(
        "## [Unreleased]\n\n### Fixed\n\n- F.\n\n### Changed\n\n- Pins x 1.0.0.\n",
        try addEntry(a, "## [Unreleased]\n\n### Fixed\n\n- F.\n", .changed, "- Pins x 1.0.0."),
    );
    try std.testing.expectEqualStrings(
        "## [Unreleased]\n\n### Changed\n\n- Pins x 1.0.0.\n\n### Fixed\n",
        try addEntry(a, "## [Unreleased]\n\n### Changed\n\n### Fixed\n", .changed, "- Pins x 1.0.0."),
    );
}

/// The newest release the changelog records: its first `## [X.Y.Z]` heading,
/// or null before any.
pub fn newestReleased(text: []const u8) ?std.SemanticVersion {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## [")) continue;
        const end = std.mem.findScalar(u8, line, ']') orelse continue;
        return parseVersion(line["## [".len..end]) orelse continue;
    }
    return null;
}

/// What the changelog says changed after release `since` (null: since the start):
/// its Unreleased section and every release newer than `since`, as one.
pub fn changedSince(a: std.mem.Allocator, text: []const u8, since: ?std.SemanticVersion, problem: *Problem) ParseError!Change {
    var most: Change = (try unreleased(a, text, problem)).change();
    var offset: usize = 0;
    while (offset < text.len) {
        const end = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = text[offset..end];
        defer offset = end + 1;
        if (!std.mem.startsWith(u8, line, "## [")) continue;
        const close = std.mem.findScalar(u8, line, ']') orelse continue;
        const version = parseVersion(line["## [".len..close]) orelse continue;
        if (since) |s| if (version.order(s) != .gt) continue;
        most = most.max((try parseSection(a, text, sectionAfter(text, offset), problem)).change());
    }
    return most;
}

/// `text` with its Unreleased section released as `version` on `date`
/// (`YYYY-MM-DD`): the groups in release order under `## [X.Y.Z] - date`, a
/// fresh empty `## [Unreleased]` above, and the link references following:
/// `[Unreleased]` compares from the new tag, the release the previous tag with it.
pub fn cut(a: std.mem.Allocator, text: []const u8, version: std.SemanticVersion, date: []const u8, problem: *Problem) ParseError![]const u8 {
    const range = findUnreleased(text) orelse {
        problem.* = .{ .line = 0, .what = "no `## [Unreleased]` section" };
        return error.NoUnreleased;
    };
    const section = try parseSection(a, text, range, problem);
    return written(a, text, range, section, version, date) catch |err| switch (err) {
        // An allocating writer fails only for memory.
        error.WriteFailed => error.OutOfMemory,
    };
}

fn written(a: std.mem.Allocator, text: []const u8, range: Range, section: Section, version: std.SemanticVersion, date: []const u8) std.Io.Writer.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s}{s}\n\n## [{f}] - {s}\n\n", .{ text[0..range.heading], unreleased_heading, version, date });
    try section.write(w);
    if (range.end < text.len) try w.print("\n{s}", .{text[range.end..]});
    return links(a, out.written(), version);
}

/// The link references after a cut to `version`: `[Unreleased]` from its tag,
/// and the release's own line. A changelog with none keeps none.
fn links(a: std.mem.Allocator, text: []const u8, version: std.SemanticVersion) std.Io.Writer.Error![]const u8 {
    const reference = "[Unreleased]: ";
    const line_start = if (std.mem.startsWith(u8, text, reference)) 0 else (std.mem.find(u8, text, "\n" ++ reference) orelse return text) + 1;
    const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
    const url = std.mem.trim(u8, text[line_start + reference.len .. line_end], " \t\r");
    const compare = "/compare/";
    const base_end = std.mem.find(u8, url, compare) orelse return text;
    const base = url[0..base_end];
    const range = url[base_end + compare.len ..];
    const dots = std.mem.find(u8, range, "...") orelse return text;
    const previous = range[0..dots];
    var result: std.Io.Writer.Allocating = .init(a);
    const r = &result.writer;
    try r.writeAll(text[0..line_start]);
    try r.print("{s}{s}/compare/v{f}...HEAD\n", .{ reference, base, version });
    if (previous.len > 0 and !std.mem.eql(u8, previous, "HEAD")) {
        try r.print("[{f}]: {s}/compare/{s}...v{f}", .{ version, base, previous, version });
    } else try r.print("[{f}]: {s}/releases/tag/v{f}", .{ version, base, version });
    try r.writeAll(text[@min(line_end, text.len)..]);
    return result.written();
}

/// `YYYY-MM-DD` of the current UTC day.
pub fn today(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const seconds: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds())); // safe: clamped to zero and up
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

// Tests ------------------------------------------------------------------

const sample =
    \\# Changelog
    \\
    \\## [Unreleased]
    \\
    \\### Fixed
    \\
    \\- A fix.
    \\
    \\### Breaking
    \\
    \\- Less.
    \\  Said over two lines.
    \\
    \\### Fixed
    \\- Another fix.
    \\
    \\### Performance
    \\
    \\- Faster.
    \\
    \\### Added
    \\
    \\## [0.1.0] - 2026-01-01
    \\
    \\### Added
    \\
    \\- First.
    \\
    \\[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD
    \\[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0
    \\
;

test "a section's groups are merged by heading, in release order, and its change is the largest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = undefined;
    const section = try unreleased(arena.allocator(), sample, &problem);
    try std.testing.expectEqual(3, section.groups.len);
    try std.testing.expectEqual(Group.breaking, section.groups[0].group.?);
    try std.testing.expectEqualStrings("- Less.\n  Said over two lines.", section.groups[0].entries[0]);
    try std.testing.expectEqual(Group.fixed, section.groups[1].group.?);
    try std.testing.expectEqual(2, section.groups[1].entries.len);
    try std.testing.expectEqualStrings("Performance", section.groups[2].name);
    try std.testing.expectEqual(Change.breaking, section.change());
}

test "an entry under no group is refused with its line, and a missing section is named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = undefined;
    try std.testing.expectError(error.Malformed, unreleased(arena.allocator(), "# C\n\n## [Unreleased]\n\n- Loose.\n", &problem));
    try std.testing.expectEqual(5, problem.line);
    try std.testing.expectError(error.NoUnreleased, unreleased(arena.allocator(), "# C\n", &problem));
    // Headings with nothing under them are no change.
    try std.testing.expect((try unreleased(arena.allocator(), "## [Unreleased]\n\n### Added\n\n### Fixed\n\n## [0.1.0] - x\n\n- Old.\n", &problem)).empty());
}

test "a cut writes the release in order under a fresh Unreleased, and its links" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = undefined;
    const text = try cut(arena.allocator(), sample, .{ .major = 0, .minor = 2, .patch = 0 }, "2026-02-03", &problem);
    try std.testing.expectEqualStrings(
        \\# Changelog
        \\
        \\## [Unreleased]
        \\
        \\## [0.2.0] - 2026-02-03
        \\
        \\### Breaking
        \\
        \\- Less.
        \\  Said over two lines.
        \\
        \\### Fixed
        \\
        \\- A fix.
        \\- Another fix.
        \\
        \\### Performance
        \\
        \\- Faster.
        \\
        \\## [0.1.0] - 2026-01-01
        \\
        \\### Added
        \\
        \\- First.
        \\
        \\[Unreleased]: https://github.com/o/r/compare/v0.2.0...HEAD
        \\[0.2.0]: https://github.com/o/r/compare/v0.1.0...v0.2.0
        \\[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0
        \\
    , text);
    // The first release has no tag before it; a changelog with no links gets none.
    const first = try cut(arena.allocator(), "## [Unreleased]\n\n### Added\n\n- A.\n\n[Unreleased]: https://github.com/o/r/compare/HEAD...HEAD\n", .{ .major = 0, .minor = 1, .patch = 0 }, "2026-02-03", &problem);
    try std.testing.expect(std.mem.find(u8, first, "[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0") != null);
    const plain = try cut(arena.allocator(), "## [Unreleased]\n\n### Added\n\n- A.\n", .{ .major = 0, .minor = 1, .patch = 0 }, "2026-02-03", &problem);
    try std.testing.expectEqualStrings("## [Unreleased]\n\n## [0.1.0] - 2026-02-03\n\n### Added\n\n- A.\n", plain);
}

test "lines two branches both added under one group, as a union merge leaves them, cut as one group" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = undefined;
    const merged = "## [Unreleased]\n\n### Fixed\n\n- Ours.\n### Fixed\n\n- Theirs.\n\n- Ours.\n\n## [0.1.0] - x\n";
    const text = try cut(arena.allocator(), merged, .{ .major = 0, .minor = 1, .patch = 1 }, "2026-02-03", &problem);
    try std.testing.expectEqualStrings("## [Unreleased]\n\n## [0.1.1] - 2026-02-03\n\n### Fixed\n\n- Ours.\n- Theirs.\n\n## [0.1.0] - x\n", text);
}

test "the version follows the largest change: below 1.0 breaking moves the minor, from 1.0 semver" {
    const v = parseVersion("0.3.4").?;
    try std.testing.expectEqual(std.SemanticVersion{ .major = 0, .minor = 3, .patch = 5 }, next(v, .fix));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 0, .minor = 3, .patch = 5 }, next(v, .feature));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 0, .minor = 4, .patch = 0 }, next(v, .breaking));
    const stable = parseVersion("1.2.3").?;
    try std.testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 2, .patch = 4 }, next(stable, .fix));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 3, .patch = 0 }, next(stable, .feature));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 2, .minor = 0, .patch = 0 }, next(stable, .breaking));
    for ([_][]const u8{ "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-rc1", "" }) |bad| try std.testing.expectEqual(null, parseVersion(bad));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = undefined;
    for ([_]struct { group: []const u8, change: Change }{
        .{ .group = "Removed", .change = .breaking },
        .{ .group = "Deprecated", .change = .feature },
        .{ .group = "Security", .change = .fix },
        .{ .group = "Notes", .change = .fix },
    }) |case| {
        const text = try arena.allocator().print("## [Unreleased]\n\n### {s}\n\n- X.\n", .{case.group});
        try std.testing.expectEqual(case.change, (try unreleased(arena.allocator(), text, &problem)).change());
    }
}

test "what changed since a release counts the releases after it and Unreleased" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = undefined;
    const text = "## [Unreleased]\n\n## [0.2.0] - x\n\n### Breaking\n\n- Gone.\n\n## [0.1.1] - x\n\n### Fixed\n\n- F.\n\n## [0.1.0] - x\n\n### Added\n\n- First.\n";
    try std.testing.expectEqual(Change.breaking, try changedSince(arena.allocator(), text, parseVersion("0.1.1").?, &problem));
    try std.testing.expectEqual(Change.none, try changedSince(arena.allocator(), text, parseVersion("0.2.0").?, &problem));
    try std.testing.expectEqual(Change.breaking, try changedSince(arena.allocator(), text, null, &problem));
    try std.testing.expectEqual(parseVersion("0.2.0").?, newestReleased(text).?);
}
