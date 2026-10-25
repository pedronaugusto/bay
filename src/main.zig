//! bay: dependencies for Zig packages, the ones a package ships and the ones
//! only its development uses, on Zig's own package manager.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const root = @import("root.zig");
const fetch = @import("fetch.zig");
const install = @import("install.zig");
const resolve = @import("resolve.zig");
const workspace = @import("workspace.zig");
const toolchain = @import("toolchain.zig");
const remotes = @import("remote.zig");
const graph = @import("graph.zig");
const git = @import("git.zig");
const published = @import("published.zig");
const each = @import("each.zig");
const store = @import("store.zig");
const licenses = @import("licenses.zig");
const audit = @import("audit.zig");
const say = @import("say.zig");
const steps = @import("steps.zig");
const own = @import("own");
const release = @import("release.zig");
const tidying = @import("tidy.zig");
const machines = @import("machines.zig");
const aegis = @import("aegis");
const ensign = @import("ensign");

/// bay's command line: what each command takes, its help and completions,
/// all read from this declaration by ensign.
pub const Cli = struct {
    locked: bool = false,
    workspace: bool = false,
    jobs: ?aegis.int.Ranged(u16, 1, 4096) = null,
    command: ?union(enum) {
        build: Pass,
        dev: Pass,
        add: Add,
        remove: Remove,
        update: Names,
        upgrade: Names,
        tidy,
        tree: Tree,
        outdated,
        licenses: Developed,
        audit,
        vendor,
        list,
        locate: Developed,
        fetch,
        new: New,
        init,
        install: install.Args,
        uninstall: install.Uninstall,
        release: Release,
        version,
        completions: Completions,
        step: ensign.External,
    } = null,

    pub const spec: ensign.Spec(@This()) = .{
        .name = "bay",
        .version = own.version,
        .about = "Dependencies for Zig packages, on Zig's own package manager",
        .description = "Each package builds with the exact Zig it names, which bay installs; ZIG names another by hand.",
        .options = .{
            .locked = .{ .global = true, .help = "Refuse to change a manifest, as CI should" },
            .workspace = .{ .help = "Run the command in every member of the workspace, each after the members it ships with and is developed with" },
            .jobs = .{ .short = 'j', .help = "With --workspace, run at most this many members at once; one per CPU by default" },
        },
        .commands = .{
            .build = .{ .help = "Run zig build, the package's install step, with the arguments given" },
            .dev = .{ .help = "Run zig build in the development build, with the arguments given" },
            .update = .{ .help = "Pin what each recorded ref names now: a branch at its head, a release tag at the newest release on its line" },
            .upgrade = .{ .help = "Pin each at the newest release tag of its repository, across lines, whether it was pinned at a tag or a commit" },
            .licenses = .{ .help = "Each package a build contains, with the license it states" },
            .locate = .{ .help = "The package's directory, or with --dev its development build's root, which a configured development build's paths are relative to" },
            .tidy = .{ .help = "Pin each package at the version selection picks: the highest any manifest in the graph asks for (Go's MVS); in a workspace, each member at its release" },
            .outdated = .{ .help = "Packages the builds use with a newer release, or at a version their newest release retracts" },
            .vendor = .{ .help = "Every package the builds use, into zig-pkg, for building offline" },
            .audit = .{ .help = "Each package the builds select checked against its repository's published security advisories and its own retractions; fails on any finding. GITHUB_TOKEN, when set, is sent to GitHub" },
            .list = .{ .help = "Both lists, with their pins" },
            .fetch = .{ .help = "Fetch every dependency of both kinds" },
            .init = .{ .help = "Make the package here one bay develops, adding only what is missing; zig init first where there is no package" },
            .version = .{ .help = "The version of bay" },
            .step = .{ .help = "The step from the package's build, or else from its development build, which has the dev dependencies; the arguments go to zig build" },
        },
        .examples = &.{
            .{ .command = "bay add https://github.com/pedronaugusto/aegis", .help = "Pin a dependency at its newest release" },
            .{ .command = "bay test -Dtest-filter=parse", .help = "Run a step, with arguments for zig build" },
            .{ .command = "bay release --dry-run", .help = "The version the CHANGELOG's [Unreleased] section makes, and what releasing it does" },
            .{ .command = "bay --workspace release", .help = "Release every member of a workspace that changed, in order, each pinned at the releases before it" },
        },
    };
};

/// The arguments a command passes on to zig build, as given.
const Pass = struct {
    args: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .args = .{ .positional = true, .raw = true, .help = "Passed to zig build as given" } } };
};

const Add = struct {
    dev: bool = false,
    lazy: bool = false,
    tidy: bool = true,
    name: ?[]const u8 = null,
    sources: []const []const u8,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Fetch and pin dependencies, then tidy once",
        .options = .{
            .dev = .{ .help = "A new dependency goes in .dev_dependencies; a name already pinned stays in its list" },
            .lazy = .{ .help = "Fetched only when a build uses it" },
            .tidy = .{ .help = "Tidy after writing; --no-tidy leaves it to a later bay tidy, as --workspace does until every member is written" },
            .name = .{ .help = "The name to pin the one source given under" },
            .sources = .{ .positional = true, .value_name = "URL-OR-DIRECTORY", .hint = .directory, .help = "A repository's URL (pinned at its newest release), a git URL with a ref, an archive URL, or a directory" },
        },
    };
};

const Release = struct {
    dry_run: bool = false,
    no_push: bool = false,
    gate_bundle: ?[]const u8 = null,
    package: []const u8 = ".",
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Release the package: the version its CHANGELOG's [Unreleased] section makes, committed, gated here and on the machines in bay's machines.zon, then the branch and its tag pushed at once over SSH",
        .options = .{
            .dry_run = .{ .help = "Print the version, the section as it will be written and the plan; change nothing" },
            .no_push = .{ .help = "Commit and gate, and push nothing: the gated commit is held here for a later bay release to push without gating it again" },
            .gate_bundle = .{ .hidden = true, .value_name = "DIRECTORY", .help = "A machine's side of a release: the commit on stdin, gated in a repository at DIRECTORY" },
            .package = .{ .hidden = true, .help = "With --gate-bundle, the package's directory in the repository" },
        },
    };
};

const Remove = struct {
    dev: bool = false,
    tidy: bool = true,
    name: []const u8,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Drop a dependency",
        .options = .{
            .dev = .{ .help = "From .dev_dependencies, where the name is in both lists" },
            .tidy = .{ .help = "Tidy after writing; --no-tidy leaves it to a later bay tidy, as --workspace does until every member is written" },
            .name = .{ .positional = true },
        },
    };
};

const Names = struct {
    tidy: bool = true,
    names: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .tidy = .{ .help = "Tidy after writing; --no-tidy leaves it to a later bay tidy, as --workspace does until every member is written" },
        .names = .{ .positional = true, .value_name = "NAME", .help = "The dependencies to move; every one when none is named" },
    } };
};

const Tree = struct {
    why: ?[]const u8 = null,
    duplicates: bool = false,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The resolved graph",
        .options = .{
            .why = .{ .value_name = "NAME", .help = "The paths to one package" },
            .duplicates = .{ .help = "The packages pinned at more than one revision, and who pins each" },
        },
    };
};

/// A command that can look at the development build too.
const Developed = struct {
    dev: bool = false,
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .dev = .{ .help = "The development build too" } } };
};

const Completions = struct {
    shell: ensign.Shell,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The completion script for a shell, to write where the shell loads completions from",
        .options = .{ .shell = .{ .positional = true } },
    };
};

const New = struct {
    name: []const u8,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "A new package in a new directory: zig init, then the empty dev list and a `dev` function",
        .options = .{ .name = .{ .positional = true, .hint = .directory } },
    };
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cli = ensign.parseOrExit(Cli, init);
    const command = cli.command orelse {
        var buffer: [4096]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buffer);
        try ensign.writeHelp(Cli, &w.interface, "bay", ensign.terminalWidth(io, .stdout(), init.environ_map) orelse 80);
        return w.interface.flush();
    };
    switch (command) {
        .version => return Io.File.stdout().writeStreamingAll(io, "bay " ++ own.version ++ "\n"),
        .completions => |c| {
            var buffer: [4096]u8 = undefined;
            var w = Io.File.stdout().writer(io, &buffer);
            try ensign.writeCompletion(Cli, c.shell, &w.interface, "bay");
            return w.interface.flush();
        },
        else => {},
    }
    // Everything bay runs can run bay again, as the same program: a tool that builds
    // another checkout of the package (a benchmark comparison) needs its development build.
    try init.environ_map.put("BAY", try std.process.executablePathAlloc(io, a));
    // A reported failure has said what went wrong; it ends the run without a trace.
    const code = dispatch(io, a, init.environ_map, cli) catch |err| switch (err) {
        error.Reported => 1,
        else => return err,
    };
    std.process.exit(code);
}

/// Leaves tidying to the caller when `cli`'s command writes pins; whether it does.
fn deferTidy(cli: *Cli) bool {
    switch (cli.command.?) { // safe: dispatch runs only with a command
        .add => |*args| args.tidy = false,
        .remove => |*args| args.tidy = false,
        .update, .upgrade => |*args| args.tidy = false,
        else => return false,
    }
    return true;
}

fn dispatch(io: Io, a: std.mem.Allocator, environ: *std.process.Environ.Map, cli: Cli) !u8 {
    const command = cli.command.?; // safe: main answered a command line without one
    if (cli.jobs != null and !cli.workspace) try say.fail(io, "--jobs is for --workspace", .{});
    if (command == .release) return releaseCommand(io, a, environ, cli, command.release);
    // Each member runs this bay with the same command, --locked kept.
    if (cli.workspace) {
        var member = cli;
        member.workspace = false;
        member.jobs = null;
        const jobs: ?usize = if (cli.jobs) |j| j.raw() else null;
        // A command that writes pins writes every member before any tidies: a member
        // tidied first would resolve against members not yet moved, and refuse them.
        const writes = deferTidy(&member);
        const code = try each.run(io, a, environ, jobs, try ensign.render(Cli, a, member));
        if (!writes or code != 0) return code;
        member.command = .tidy;
        return each.run(io, a, environ, jobs, try ensign.render(Cli, a, member));
    }
    switch (command) {
        // Before a package exists, a Zig that names no version makes it (`toolchain.unpinned`).
        .init => return initCommand(io, a, try toolchain.unpinned(io, a, environ)),
        .new => |n| return newCommand(io, a, try toolchain.unpinned(io, a, environ), n.name),
        // Global: anywhere, as cargo install is.
        .install, .uninstall => {
            const here = try packageHere(io, a);
            const zig = if (here) |package| try toolchain.forPackage(io, a, environ, package) else try toolchain.unpinned(io, a, environ);
            const context: install.Context = .{ .io = io, .a = a, .zig = zig, .environ = environ, .package = here };
            return switch (command) {
                .install => |args| install.command(context, args),
                .uninstall => |args| install.uninstall(context, args.name),
                else => unreachable, // unreachable: the outer arm took only these two
            };
        },
        else => {},
    }
    const package = try findPackage(io, a);
    const env: Env = .{ .io = io, .a = a, .zig = try toolchain.forPackage(io, a, environ, package), .environ = environ, .package = package, .locked = cli.locked };
    return switch (command) {
        .add => |args| afterEdit(env, args.tidy, try add(env, args)),
        .remove => |args| afterEdit(env, args.tidy, try removeCommand(env, args)),
        .update => |args| afterEdit(env, args.tidy, try update(env, args.names)),
        .upgrade => |args| afterEdit(env, args.tidy, try upgrade(env, args.names)),
        .list => list(env),
        .tidy => tidy(env),
        .locate => |args| locate(env, args.dev),
        .tree => |args| treeCommand(env, args),
        .outdated => graphCommand(env, .outdated),
        .licenses => |args| licensesCommand(env, args.dev),
        .vendor => graphCommand(env, .vendor),
        .audit => auditCommand(env),
        .fetch => fetchAll(env),
        .build => |args| zigBuild(env, .package, &.{}, args.args),
        .dev => |args| zigBuild(env, .development, &.{}, args.args),
        .step => |args| step(env, args.name, args.args),
        .init, .new, .install, .uninstall, .version, .completions, .release => unreachable, // unreachable: answered above
    };
}

/// `bay release`, its train with `--workspace`, and a machine's side of either.
fn releaseCommand(io: Io, a: std.mem.Allocator, environ: *std.process.Environ.Map, cli: Cli, args: Release) !u8 {
    if (args.gate_bundle) |directory| return machines.receive(io, a, environ, directory, args.package);
    if (cli.workspace) {
        if (cli.jobs != null) try say.fail(io, "a train releases one member at a time: --jobs is for other commands", .{});
        if (args.no_push) try say.fail(io, "a train pushes each release before the next member pins it: --no-push is for one package", .{});
        const here = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        return release.train(.{ .io = io, .a = a, .environ = environ, .package = here }, .{ .dry_run = args.dry_run });
    }
    _ = try release.run(.{ .io = io, .a = a, .environ = environ, .package = try findPackage(io, a) }, .{ .dry_run = args.dry_run, .no_push = args.no_push });
    return 0;
}

/// An open directory, which its one owner closes.
const OpenDir = aegis.own.OwnedIo(Io.Dir, closeDir);

fn closeDir(dir: *Io.Dir, io: Io) void {
    dir.close(io);
}

const Env = struct {
    io: Io,
    a: std.mem.Allocator,
    zig: []const u8,
    environ: *const std.process.Environ.Map,
    /// The package's directory: the nearest one up from here with a build.zig.zon.
    package: []const u8,
    /// `--locked`: no manifest may change, as in CI.
    locked: bool = false,

    /// The package's directory, open; its owner closes it.
    fn dir(env: Env) !OpenDir {
        return .init(try Io.Dir.cwd().openDir(env.io, env.package, .{}));
    }

    fn input(env: Env) tidying.Input {
        return .{ .io = env.io, .a = env.a, .zig = env.zig, .package = env.package };
    }

    fn readManifest(env: Env) ![:0]const u8 {
        var package_dir = try env.dir();
        defer package_dir.deinit(env.io);
        const text = try aegis.own.readFile(env.io, package_dir.lend().get(), "build.zig.zon", env.a, .fromRaw(1 << 20));
        return env.a.dupeSentinel(u8, text, 0);
    }
};

fn findPackage(io: Io, a: std.mem.Allocator) ![]const u8 {
    return try packageHere(io, a) orelse try say.fail(io, "no build.zig.zon here or in any directory above", .{});
}

/// The nearest directory up from here with a build.zig.zon, or null outside a package.
fn packageHere(io: Io, a: std.mem.Allocator) !?[]const u8 {
    var path: []const u8 = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    while (true) {
        const candidate = try std.fs.path.join(a, &.{ path, "build.zig.zon" });
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| return path else |_| {}
        path = std.fs.path.dirname(path) orelse return null;
    }
}

const Where = enum { package, development };

/// Runs zig build in the package, or in its development root, and returns its exit code.
fn zigBuild(env: Env, where: Where, before: []const []const u8, after: []const []const u8) !u8 {
    const parsed = try manifest.parse(env.a, try env.readManifest());
    return built(env, parsed, try buildable(env, parsed), where, before, after);
}

/// The package's graph resolved, and every package in it fetched, for a build;
/// a build never writes the manifest, so one that disagrees with the selection
/// is refused.
fn buildable(env: Env, parsed: manifest.Manifest) !resolve.Resolution {
    const resolution = try resolveHere(env, parsed);
    if (resolution.raises.len != 0) {
        for (resolution.raises) |raise| try say.note(env.io, "{s} is pinned below the selection: {s}", .{ raise.from.name, try tidying.describe(resolution, raise.to) });
        try say.fail(env.io, "build.zig.zon disagrees with the selection; bay tidy writes it", .{});
    }
    return resolution;
}

/// Runs zig build over a resolved graph.
fn built(env: Env, parsed: manifest.Manifest, resolution: resolve.Resolution, where: Where, before: []const []const u8, after: []const []const u8) !u8 {
    const argv = try buildArgv(env, parsed, resolution, where, before, after);
    var child = std.process.spawn(env.io, .{ .argv = argv, .cwd = .{ .path = env.package }, .environ_map = env.environ }) catch |err|
        try say.fail(env.io, "could not run {s}: {t}", .{ env.zig, err });
    return switch (try child.wait(env.io)) {
        .exited => |code| code,
        else => 1,
    };
}

/// Zig's listing of the steps of the package's build (`.package`) or its development
/// build: `configured` false when the build does not configure, its error in `stderr`.
const Listing = struct { configured: bool, stdout: []const u8, stderr: []const u8 };

fn stepsOf(env: Env, parsed: manifest.Manifest, resolution: resolve.Resolution, where: Where) !Listing {
    const argv = try buildArgv(env, parsed, resolution, where, &.{"-l"}, &.{});
    const listed = std.process.run(env.a, env.io, .{ .argv = argv, .cwd = .{ .path = env.package }, .environ_map = env.environ, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        try say.fail(env.io, "could not run {s}: {t}", .{ env.zig, err });
    return .{ .configured = listed.term == .exited and listed.term.exited == 0, .stdout = listed.stdout, .stderr = listed.stderr };
}

/// The zig build command line over a resolved graph: `before` ahead of the
/// development build's own arguments, `after` behind them.
fn buildArgv(env: Env, parsed: manifest.Manifest, resolution: resolve.Resolution, where: Where, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    // Zig runs in the package's directory, as Cargo runs a crate's tests in its own:
    // what a build runs (a test, a tool) reads the package's files by their path in
    // it, as under plain `zig build`, whichever root builds it. The development root
    // is the build's root through `--build-file`.
    const build_root = if (where == .development) try std.fs.path.join(env.a, &.{ env.package, root.directory }) else env.package;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.a, &.{ env.zig, "build" });
    try argv.appendSlice(env.a, try resolution.forks(if (where == .development) .development else .package));
    try argv.appendSlice(env.a, before);
    if (where == .development) {
        var dir = try env.dir();
        defer dir.deinit(env.io);
        root.write(env.io, env.a, dir.lend().get(), parsed, resolution.packagePin()) catch |err| switch (err) {
            error.DevDependencyNamedAsPackage => try say.fail(env.io, "a dev dependency is named {s}, the package's own name", .{parsed.name}),
            error.PinnedTwiceDifferently => try say.fail(env.io, "a name is pinned differently in .dependencies and .dev_dependencies: one name is one dependency", .{}),
            else => |e| return e,
        };
        // The development build shares the package's cache, the one Zig picks for the
        // package build (ZIG_LOCAL_CACHE_DIR when set), and installs where the package does.
        if (env.environ.get("ZIG_LOCAL_CACHE_DIR") == null)
            try argv.appendSlice(env.a, &.{ "--cache-dir", try std.fs.path.join(env.a, &.{ env.package, ".zig-cache" }) });
        try argv.appendSlice(env.a, &.{
            "--build-file", try std.fs.path.join(env.a, &.{ build_root, "build.zig" }),
            "--prefix",     try std.fs.path.join(env.a, &.{ env.package, "zig-out" }),
            // One package directory for both builds: what the package build or `bay vendor` put there.
            // Relative to the package, where Zig runs: under an absolute one, Zig 0.17 refuses
            // the path dependencies of the packages it unpacks there.
            "--pkg-dir",    "zig-pkg",
        });
    }
    try argv.appendSlice(env.a, after);
    return argv.items;
}

/// `bay locate [--dev]`: the package's directory, or its development root, on
/// stdout, as `cargo locate-project` names a project to a script. A configured
/// build's paths are relative to its root, so a tool reading one resolves them there.
fn locate(env: Env, dev: bool) !u8 {
    const directory = if (dev) try std.fs.path.join(env.a, &.{ env.package, root.directory }) else env.package;
    try say.out(env.io, "{s}\n", .{directory});
    return 0;
}

/// `bay tree [--why <name>] [--duplicates]`.
fn treeCommand(env: Env, args: Tree) !u8 {
    const options: graph.TreeOptions = .{ .why = args.why, .duplicates = args.duplicates };
    try graph.tree(try resolveHere(env, try manifest.parse(env.a, try env.readManifest())), options);
    return 0;
}

/// `bay licenses [--dev]`.
fn licensesCommand(env: Env, dev: bool) !u8 {
    try licenses.list(try resolveHere(env, try manifest.parse(env.a, try env.readManifest())), dev);
    return 0;
}

/// A writing command's manifest (null: it failed, having said why), tidied
/// when `tidy_after`, then written once, and what the build makes from the pins
/// with it. A graph the edit cannot resolve is refused before anything is written;
/// untidied, the pins wait for a `bay tidy`, which makes what follows from them.
fn afterEdit(env: Env, tidy_after: bool, text_or_failed: ?[:0]const u8) !u8 {
    const text = text_or_failed orelse return 1;
    if (tidy_after) return writeTidied(env, text, .when_written);
    _ = try writeChanged(env, text);
    return 0;
}

/// `bay audit`: 1 when an advisory or a retraction holds a selected version.
fn auditCommand(env: Env) !u8 {
    const resolution = try resolveHere(env, try manifest.parse(env.a, try env.readManifest()));
    const token = if (env.environ.get("GITHUB_TOKEN")) |t| if (t.len != 0) t else null else null;
    return if (try audit.audit(resolution, token)) 0 else 1;
}

/// `bay outdated` and `bay vendor`, over the resolved graph.
fn graphCommand(env: Env, comptime which: enum { outdated, vendor }) !u8 {
    const resolution = try resolveHere(env, try manifest.parse(env.a, try env.readManifest()));
    switch (which) {
        .outdated => try graph.outdated(resolution),
        .vendor => try graph.vendor(resolution),
    }
    return 0;
}

/// Writes the package's manifest; `--locked` refuses, since it would change.
fn writeManifest(env: Env, text: []const u8) !void {
    if (env.locked) try say.fail(env.io, "--locked: build.zig.zon would change", .{});
    var dir = try env.dir();
    defer dir.deinit(env.io);
    const package = dir.lend().get();
    // Written beside and renamed over: a member resolving at the same moment reads
    // the old manifest or the new one, never half of one.
    try package.writeFile(env.io, .{ .sub_path = "build.zig.zon.bay-partial", .data = text });
    try package.rename("build.zig.zon.bay-partial", package, "build.zig.zon", env.io);
}

/// `bay tidy`: the package's manifest pins each workspace member at its release
/// and each package at its one hash, as Go writes go.mod; what moves is named,
/// and nothing to write says nothing. Only this manifest is written: every
/// member's is its own (`bay --workspace tidy` tidies them all). What the build
/// makes from the pins is made again even when nothing moves here: the pins may
/// have been written by a command told not to tidy, or by hand.
fn tidy(env: Env) !u8 {
    return writeTidied(env, try env.readManifest(), .always);
}

/// `text`, the package's manifest, tidied in memory and written when that
/// changes what is on disk: nothing is written unless the graph resolves.
/// Then what the build makes from the pins, `always` or `when_written`.
fn writeTidied(env: Env, text: [:0]const u8, generate: enum { always, when_written }) !u8 {
    const tidied = try tidying.tidied(env.input(), text);
    for (tidied.moves) |move| try say.note(env.io, "{s} {s}{s} {s}", .{ move.name, if (env.locked) "would be " else "", switch (move.how) {
        .released => "pinned at its release",
        .raised => "raised to",
    }, move.to });
    const written = try writeChanged(env, tidied.text);
    if (written or generate == .always) try regenerate(env);
    return 0;
}

/// Writes `text` as the package's manifest unless it is what is there; whether it wrote.
fn writeChanged(env: Env, text: []const u8) !bool {
    if (std.mem.eql(u8, text, try env.readManifest())) return false;
    try writeManifest(env, text);
    return true;
}

/// What the package's build makes from its pins, made again once they are written:
/// its `generate` step, the package's or its development build's (preflight's writes
/// the CI caller, which names the preflight pinned), so the pins and what follows
/// from them are never committed apart. A package with no such step makes nothing;
/// `--locked` writes nothing. A build that does not configure with the pins written
/// (a dependency removed that build.zig still names) is said to, and left to the
/// `bay tidy` after it is fixed.
fn regenerate(env: Env) !void {
    if (env.locked) return;
    const parsed = try manifest.parse(env.a, try env.readManifest());
    const resolution = try buildable(env, parsed);
    const builds: []const Where = if (parsed.dev.len == 0) &.{.package} else &.{ .package, .development };
    const where = for (builds) |build| {
        const listed = try stepsOf(env, parsed, resolution, build);
        if (!listed.configured) {
            try say.note(env.io, "the {s} build does not configure with these pins, so what it makes from them (its `generate` step) is not made again: bay tidy makes it once it configures", .{if (build == .development) "development" else "package"});
            return;
        }
        if (steps.listed(listed.stdout, "generate")) break build;
    } else return;
    if (try built(env, parsed, resolution, where, &.{"generate"}, &.{}) != 0)
        try say.fail(env.io, "the pins are written, but `generate` failed: what the build makes from them is not", .{});
}

/// The package's graph, resolved: a workspace's members are main modules beside it.
fn resolveHere(env: Env, parsed: manifest.Manifest) !resolve.Resolution {
    return tidying.resolved(env.input(), parsed);
}

/// `bay <step>`: the package's own steps are what ships and come first; a step
/// the package does not have is the development build's.
fn step(env: Env, name: []const u8, args: []const []const u8) !u8 {
    // Resolved first: the listing configures the build, and Zig must find every
    // package there, a fork's and a git-fetched one's too, as the build will.
    const parsed = try manifest.parse(env.a, try env.readManifest());
    const resolution = try buildable(env, parsed);
    const listed = try stepsOf(env, parsed, resolution, .package);
    if (!listed.configured) {
        try say.relay(env.io, listed.stderr);
        return 1;
    }
    if (steps.listed(listed.stdout, name)) return built(env, parsed, resolution, .package, &.{name}, args);
    if (parsed.dev.len == 0) try say.fail(env.io, "the package has no step '{s}' and no dev dependencies", .{name});
    return built(env, parsed, resolution, .development, &.{name}, args);
}

fn fetchAll(env: Env) !u8 {
    const code = try zigBuild(env, .package, &.{"--fetch=all"}, &.{});
    if (code != 0) return code;
    const parsed = try manifest.parse(env.a, try env.readManifest());
    if (parsed.dev.len == 0) return 0;
    return zigBuild(env, .development, &.{"--fetch=all"}, &.{});
}

/// `bay add`: Zig fetches into a scratch manifest with `zig fetch --save`, so
/// the URL and hash are exactly what Zig records; bay puts the entry in the
/// package's list of that kind. Every pin is written first and the package is
/// tidied once, so pins that must move together (two packages that pin each
/// other) are not checked one at a time against the old other.
fn add(env: Env, args: Add) !?[:0]const u8 {
    if (args.name != null and args.sources.len > 1) try say.fail(env.io, "--name names one dependency; add takes one source with it", .{});
    const pinned = try manifest.parse(env.a, try env.readManifest());
    var text = try env.readManifest();
    const kind: manifest.Kind = if (args.dev) .dev else .normal;
    for (args.sources) |where| {
        const dependency = if (isDirectory(env, where)) try local(env, where, args.name) else try fetched(env, try addable(env, where), args.name) orelse return null;
        text = try pinInto(env, pinned, text, dependency, kind, args.lazy);
    }
    return text;
}

/// What `bay add` fetches for `where`: a repository's page URL (`https://host/
/// owner/repo`, as a browser shows it) is the git repository there, and a git
/// URL that names no ref is pinned at its newest release, as `go get` takes
/// `@latest`; with no release it is the default branch, as Zig fetches it.
/// An archive URL, a URL with a ref or commit, and what git fetches stay as given.
fn addable(env: Env, where: []const u8) ![]const u8 {
    const url = try repositoryUrl(env.a, where);
    if (!std.mem.startsWith(u8, url, "git+") or git.handles(url)) return url;
    const p = git.parts(url);
    if (p.ref != null or p.fragment != null) return url;
    const packages = try store.Store.init(env.io, env.a, env.zig, env.package);
    const scratch = try std.fs.path.join(env.a, &.{ env.package, root.directory, "add" });
    const latest = try published.newest(env.io, env.a, env.zig, packages, scratch, url) orelse return url;
    return env.a.print("{s}#{s}", .{ url, latest.tag });
}

/// `where` as a git URL when it is an http(s) URL of a repository rather than
/// of an archive: Zig fetches a plain https URL as a file, and a repository's
/// page is HTML, which it refuses by its Content-Type.
fn repositoryUrl(a: std.mem.Allocator, where: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, where, "https://") and !std.mem.startsWith(u8, where, "http://")) return where;
    const path = where[0 .. std.mem.findAny(u8, where, "?#") orelse where.len];
    for ([_][]const u8{ ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar", ".zip" }) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return where;
    }
    return a.print("git+{s}", .{std.mem.trimEnd(u8, where, "/")});
}

/// `dependency` put into each list that pins its name already, keeping whether it
/// is lazy (`lazy` makes it so); into `fresh` when neither does. Each list is its
/// own, as Cargo's are: a package may ship a dependency and develop with it too.
fn pinInto(env: Env, pinned: manifest.Manifest, text: [:0]const u8, dependency: manifest.Dependency, fresh: manifest.Kind, lazy: bool) ![:0]const u8 {
    var edited = text;
    var found = false;
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        for (if (kind == .normal) pinned.normal else pinned.dev) |existing| {
            if (!std.mem.eql(u8, existing.name, dependency.name)) continue;
            found = true;
            var entry = dependency;
            entry.lazy = existing.lazy or lazy;
            edited = try putNoted(env, edited, kind, entry);
        }
    }
    if (found) return edited;
    var entry = dependency;
    entry.lazy = lazy;
    return putNoted(env, edited, fresh, entry);
}

fn putNoted(env: Env, text: [:0]const u8, kind: manifest.Kind, entry: manifest.Dependency) ![:0]const u8 {
    try say.note(env.io, "{s} pinned in .{s}", .{ entry.name, kind.field() });
    return manifest.put(env.a, text, kind, entry);
}

fn isDirectory(env: Env, path: []const u8) bool {
    if (std.mem.find(u8, path, "://") != null) return false;
    var dir = Io.Dir.cwd().openDir(env.io, path, .{}) catch return false;
    dir.close(env.io);
    return true;
}

/// A directory dependency, named as its own manifest names it, at its path from the package.
fn local(env: Env, path: []const u8, name: ?[]const u8) !manifest.Dependency {
    const absolute = try Io.Dir.cwd().realPathFileAlloc(env.io, path, env.a);
    const relative = try std.fs.path.relativeAlloc(env.a, env.package, null, env.package, absolute);
    if (name) |given| return .{ .name = given, .source = .{ .path = relative } };
    var dir = try Io.Dir.cwd().openDir(env.io, absolute, .{});
    defer dir.close(env.io);
    const text = aegis.own.readFile(env.io, dir, "build.zig.zon", env.a, .fromRaw(1 << 20)) catch try say.fail(env.io, "{s} has no build.zig.zon; name it with --name", .{path});
    const parsed = try manifest.parse(env.a, try env.a.dupeSentinel(u8, text, 0));
    return .{ .name = parsed.name, .source = .{ .path = relative } };
}

fn fetched(env: Env, url: []const u8, name: ?[]const u8) !?manifest.Dependency {
    return fetch.fetch(env.io, env.a, env.zig, try std.fs.path.join(env.a, &.{ env.package, root.directory, "add" }), url, name);
}

fn removeCommand(env: Env, args: Remove) !?[:0]const u8 {
    const target = args.name;
    const dev = args.dev;
    const parsed = try manifest.parse(env.a, try env.readManifest());
    const kind = removedFrom(parsed, target, dev) orelse if (dev)
        try say.fail(env.io, "no {s} in .dev_dependencies", .{target})
    else
        try say.fail(env.io, "{s} is in neither .dependencies nor .dev_dependencies", .{target});
    const edited = try manifest.remove(env.a, try env.readManifest(), kind, target);
    try say.note(env.io, "{s} removed from .{s}", .{ target, kind.field() });
    if (kind == .normal and among(parsed.dev, target)) try say.note(env.io, "its development pin stays; bay remove --dev {s} removes it", .{target});
    return edited;
}

/// The list `bay remove` takes a name from: `.dev_dependencies` when `--dev`
/// is given; otherwise `.dependencies`, or `.dev_dependencies` when the name
/// is only there. A package may ship a dependency and develop with it, so a
/// name in both lists leaves its development pin unless `--dev` names it.
fn removedFrom(parsed: manifest.Manifest, name: []const u8, dev: bool) ?manifest.Kind {
    if (dev) return if (among(parsed.dev, name)) .dev else null;
    if (among(parsed.normal, name)) return .normal;
    if (among(parsed.dev, name)) return .dev;
    return null;
}

/// `bay update`: each remote pin of either kind (or those named) fetched again
/// at the ref its URL records, and pinned to what that ref names now: a branch
/// at its head, a release tag at the newest release on its line, as `cargo update`
/// and `go get -u` move within what is compatible. A pin to an exact commit, or a
/// directory, has nothing to follow and stays; a new line is `bay add` at its tag.
fn update(env: Env, names: []const []const u8) !?[:0]const u8 {
    const parsed = try manifest.parse(env.a, try env.readManifest());
    // Each name given must be a dependency, in either list.
    for (names) |name| {
        if (!among(parsed.normal, name) and !among(parsed.dev, name)) try say.fail(env.io, "{s} is not a dependency", .{name});
    }
    var text = try env.readManifest();
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .normal) parsed.normal else parsed.dev;
        for (dependencies) |dependency| {
            if (names.len != 0 and !contains(names, dependency.name)) continue;
            const remote = switch (dependency.source) {
                .remote => |remote| remote,
                .path => continue,
            };
            const url = manifest.following(env.a, remote.url) orelse {
                try say.note(env.io, "{s} is pinned to an exact commit; bay add it with a branch or tag to follow one", .{dependency.name});
                continue;
            };
            var next = try fetched(env, try releaseOnLine(env, url), dependency.name) orelse return null;
            next.lazy = dependency.lazy;
            if (std.mem.eql(u8, next.source.remote.hash, remote.hash)) continue;
            text = try manifest.put(env.a, text, kind, next);
            try say.note(env.io, "{s} {s} -> {s}", .{ dependency.name, remote.hash, next.source.remote.hash });
        }
    }
    return text;
}

/// `bay upgrade`: each dependency named, or every one with a git URL when none
/// is, pinned at the newest release tag of its repository, as `cargo upgrade`
/// moves a requirement: across lines, whether it was pinned at a tag or at a
/// bare commit, in the list or lists it is in, leaving out what its newest
/// release retracts. All are written, then the package is tidied once. A
/// repository without a release tag stays as it is.
fn upgrade(env: Env, names: []const []const u8) !?[:0]const u8 {
    const parsed = try manifest.parse(env.a, try env.readManifest());
    for (names) |name| {
        if (!among(parsed.normal, name) and !among(parsed.dev, name)) try say.fail(env.io, "{s} is not a dependency", .{name});
    }
    var text = try env.readManifest();
    const packages = try store.Store.init(env.io, env.a, env.zig, env.package);
    const scratch = try std.fs.path.join(env.a, &.{ env.package, root.directory, "add" });
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        for (if (kind == .normal) parsed.normal else parsed.dev) |dependency| {
            if (names.len != 0 and !contains(names, dependency.name)) continue;
            const remote = switch (dependency.source) {
                .remote => |remote| remote,
                .path => continue,
            };
            if (!std.mem.startsWith(u8, remote.url, "git+")) continue;
            const repository = remotes.repository(remote.url) orelse continue;
            const tags = try remotes.tags(env.io, env.a, remote.url);
            // What the newest release retracts is left out, as `update` leaves it.
            const latest = try published.newest(env.io, env.a, env.zig, packages, scratch, remote.url);
            const newest = remotes.newestKept(tags, if (latest) |l| l.retracted else &.{}) orelse {
                try say.note(env.io, "{s} has no release tag; it stays as it is", .{dependency.name});
                continue;
            };
            const to = try env.a.print("git+{s}#{s}", .{ repository, newest.tag.name });
            var next = try fetched(env, to, dependency.name) orelse return null;
            next.lazy = dependency.lazy;
            if (std.mem.eql(u8, next.source.remote.url, remote.url)) continue;
            text = try manifest.put(env.a, text, kind, next);
            try say.note(env.io, "{s} {s} -> {s}", .{ dependency.name, remote.hash, next.source.remote.hash });
        }
    }
    return text;
}

fn among(dependencies: []const manifest.Dependency, name: []const u8) bool {
    for (dependencies) |dependency| if (std.mem.eql(u8, dependency.name, name)) return true;
    return false;
}

/// `url` (`git+<repo>#<ref>`) at the newest release on its line when the ref is
/// a release tag, leaving out what the package's newest release retracts; as it
/// is otherwise: a branch follows itself.
fn releaseOnLine(env: Env, url: []const u8) ![]const u8 {
    const hash = std.mem.findScalarLast(u8, url, '#') orelse return url;
    const pinned = remotes.versionOf(.{ .name = url[hash + 1 ..], .commit = "" }) orelse return url;
    const repository = remotes.repository(url) orelse return url;
    const packages = try store.Store.init(env.io, env.a, env.zig, env.package);
    const scratch = try std.fs.path.join(env.a, &.{ env.package, root.directory, "add" });
    const latest = try published.newest(env.io, env.a, env.zig, packages, scratch, url) orelse return url;
    const newest = remotes.newestOnLine(try remotes.tags(env.io, env.a, url), pinned, latest.retracted) orelse return url;
    if (newest.version.order(pinned) != .gt) return url;
    return env.a.print("git+{s}#{s}", .{ repository, newest.tag.name });
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn list(env: Env) !u8 {
    const parsed = try manifest.parse(env.a, try env.readManifest());
    for ([_]manifest.Kind{ .normal, .dev }) |kind| {
        const dependencies = if (kind == .normal) parsed.normal else parsed.dev;
        try say.out(env.io, ".{s}{s}\n", .{ kind.field(), if (dependencies.len == 0) ": none" else "" });
        for (dependencies) |dependency| switch (dependency.source) {
            .remote => |remote| try say.out(env.io, "  {s}{s}  {s}\n    {s}\n", .{ dependency.name, if (dependency.lazy) " (lazy)" else "", remote.url, remote.hash }),
            .path => |path| try say.out(env.io, "  {s}{s}  {s}\n", .{ dependency.name, if (dependency.lazy) " (lazy)" else "", path }),
        };
    }
    return 0;
}

const dev_function =
    \\
    \\/// The development build: `bay <step>` runs the steps added here, with the
    \\/// dev dependencies of build.zig.zon as `tools` (`tools.<name>` is that
    \\/// package's build.zig). A package that depends on this one never runs it.
    \\pub fn dev(b: *std.Build, tools: type) void {
    \\    _ = b;
    \\    _ = tools;
    \\}
    \\
;

/// `bay init`: the package here becomes a bay package. Where there is none yet,
/// Zig's own template makes one; then the empty dev list and a `dev` function,
/// each only when it is missing. Inside a package but not at its root, nothing.
fn initCommand(io: Io, a: std.mem.Allocator, zig: []const u8) !u8 {
    const here = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    if (Io.Dir.cwd().access(io, "build.zig.zon", .{})) |_| {} else |_| {
        if (enclosing(io, a, here)) |package| try say.fail(io, "this is inside the package at {s}: run bay init there, or bay new <name> for a package of its own", .{package});
    }
    return prepare(io, a, zig, here);
}

/// `bay new <name>`: a new package in a new directory `name` here.
fn newCommand(io: Io, a: std.mem.Allocator, zig: []const u8, name: []const u8) !u8 {
    Io.Dir.cwd().createDir(io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => try say.fail(io, "{s} exists; bay init inside it makes it a package", .{name}),
        else => return err,
    };
    return prepare(io, a, zig, try Io.Dir.cwd().realPathFileAlloc(io, name, a));
}

/// The nearest directory above `path` with a build.zig.zon.
fn enclosing(io: Io, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(path);
    while (dir) |candidate| : (dir = std.fs.path.dirname(candidate)) {
        const zon = std.fs.path.join(a, &.{ candidate, "build.zig.zon" }) catch return null;
        if (Io.Dir.cwd().access(io, zon, .{})) |_| return candidate else |_| {}
    }
    return null;
}

fn prepare(io: Io, a: std.mem.Allocator, zig: []const u8, path: []const u8) !u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    if (dir.access(io, "build.zig.zon", .{})) |_| {} else |_| {
        var child = std.process.spawn(io, .{ .argv = &.{ zig, "init" }, .cwd = .{ .path = path } }) catch |err| try say.fail(io, "could not run {s}: {t}", .{ zig, err });
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) return code,
            else => return 1,
        }
    }
    const text = try aegis.own.readFile(io, dir, "build.zig.zon", a, .fromRaw(1 << 20));
    if (try manifest.ensureList(a, try a.dupeSentinel(u8, text, 0), .dev)) |edited| try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = edited });
    const build = aegis.own.readFile(io, dir, "build.zig", a, .fromRaw(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => try say.fail(io, "build.zig.zon has no build.zig beside it", .{}),
        else => return err,
    };
    if (std.mem.find(u8, build, "pub fn dev(") == null) {
        try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.mem.concat(a, u8, &.{ build, dev_function }) });
    }
    try say.note(io, "{s} is ready; bay add --dev <url> pins a development tool, bay <step> runs its steps", .{path});
    return 0;
}

test "update follows a recorded ref and leaves a commit pin" {
    const a = std.testing.allocator;
    const branch = manifest.following(a, "git+https://example.org/x?ref=main#5d2a92141f0298d76dc5fd602526d55a62b4e11a").?;
    defer a.free(branch);
    try std.testing.expectEqualStrings("git+https://example.org/x#main", branch);
    try std.testing.expectEqual(null, manifest.following(a, "git+https://example.org/x#5d2a92141f0298d76dc5fd602526d55a62b4e11a"));
    try std.testing.expectEqualStrings("https://example.org/x.tar.gz", manifest.following(a, "https://example.org/x.tar.gz").?);
}

test "bay's command lines read as they did by hand, and --workspace hands each member the same command" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { given: []const []const u8, member: []const []const u8 };
    const cases = [_]Case{
        .{ .given = &.{ "build", "-Doptimize=ReleaseSafe" }, .member = &.{ "build", "--", "-Doptimize=ReleaseSafe" } },
        .{ .given = &.{ "test", "-Dtest-filter=x", "--summary", "all" }, .member = &.{ "test", "-Dtest-filter=x", "--summary", "all" } },
        .{ .given = &.{ "--workspace", "--jobs", "4", "--locked", "land" }, .member = &.{ "--locked", "land" } },
        .{ .given = &.{ "add", "--dev", "--name", "tool", "../tool" }, .member = &.{ "add", "--dev", "--name=tool", "../tool" } },
        .{ .given = &.{ "remove", "shakedown" }, .member = &.{ "remove", "shakedown" } },
        .{ .given = &.{ "install", "--update" }, .member = &.{ "install", "--update" } },
    };
    for (cases) |case| {
        var cli = switch (try ensign.parse(Cli, a, case.given, .{})) {
            .parsed => |v| v,
            else => return error.TestUnexpectedResult,
        };
        cli.workspace = false;
        cli.jobs = null;
        const member = try ensign.render(Cli, a, cli);
        try std.testing.expectEqual(case.member.len, member.len);
        for (case.member, member) |expected, got| try std.testing.expectEqualStrings(expected, got);
    }
    // A writing command runs in each member untidied; the workspace tidies them all after.
    var upgrade_all = switch (try ensign.parse(Cli, a, &.{ "--workspace", "upgrade" }, .{})) {
        .parsed => |v| v,
        else => return error.TestUnexpectedResult,
    };
    upgrade_all.workspace = false;
    try std.testing.expect(deferTidy(&upgrade_all));
    const written = try ensign.render(Cli, a, upgrade_all);
    try std.testing.expectEqual(2, written.len);
    try std.testing.expectEqualStrings("--no-tidy", written[1]);
    var listing: Cli = .{ .command = .list };
    try std.testing.expect(!deferTidy(&listing));
    try std.testing.expectError(error.Conflict, ensign.parse(Cli, a, &.{ "install", "--list", "--update" }, .{}));
    try std.testing.expectError(error.InvalidValue, ensign.parse(Cli, a, &.{ "--workspace", "--jobs", "0", "test" }, .{}));
}

test "remove finds a name in the list that holds it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try manifest.parse(arena.allocator(),
        \\.{
        \\    .name = .sample,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x1,
        \\    .paths = .{""},
        \\    .dependencies = .{ .both = .{ .path = "both" }, .shipped = .{ .path = "shipped" } },
        \\    .dev_dependencies = .{ .both = .{ .path = "both" }, .tool = .{ .path = "tool" } },
        \\}
    );
    try std.testing.expectEqual(manifest.Kind.dev, removedFrom(parsed, "tool", false).?);
    try std.testing.expectEqual(manifest.Kind.normal, removedFrom(parsed, "shipped", false).?);
    try std.testing.expectEqual(manifest.Kind.normal, removedFrom(parsed, "both", false).?);
    try std.testing.expectEqual(manifest.Kind.dev, removedFrom(parsed, "both", true).?);
    try std.testing.expectEqual(null, removedFrom(parsed, "shipped", true));
    try std.testing.expectEqual(null, removedFrom(parsed, "absent", false));
}

test "a repository's page URL is added as its git repository, an archive as a file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("git+https://github.com/o/r", try repositoryUrl(a, "https://github.com/o/r"));
    try std.testing.expectEqualStrings("git+https://github.com/o/r", try repositoryUrl(a, "https://github.com/o/r/"));
    try std.testing.expectEqualStrings("git+https://codeberg.org/o/r.git", try repositoryUrl(a, "https://codeberg.org/o/r.git"));
    try std.testing.expectEqualStrings("https://example.org/r-1.0.tar.gz", try repositoryUrl(a, "https://example.org/r-1.0.tar.gz"));
    try std.testing.expectEqualStrings("https://example.org/r.zip?x=1", try repositoryUrl(a, "https://example.org/r.zip?x=1"));
    try std.testing.expectEqualStrings("git+https://github.com/o/r#v1.0.0", try repositoryUrl(a, "git+https://github.com/o/r#v1.0.0"));
}

// Every file's tests, each named: one left out would never run.
test {
    _ = @import("changelog.zig");
    _ = @import("dirs.zig");
    _ = @import("download.zig");
    _ = each;
    _ = fetch;
    _ = git;
    _ = graph;
    _ = install;
    _ = licenses;
    _ = audit;
    _ = machines;
    _ = manifest;
    _ = @import("minisign.zig");
    _ = published;
    _ = release;
    _ = remotes;
    _ = resolve;
    _ = root;
    _ = say;
    _ = @import("select.zig");
    _ = @import("steps.zig");
    _ = store;
    _ = toolchain;
    _ = workspace;
}
