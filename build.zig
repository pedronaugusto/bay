const std = @import("std");
const zon = @import("build.zig.zon");

/// The bay program: std, aegis, airlock and ensign; and the `changelog` module, std only. Its tests are
/// its development build's (`bay test`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "bay", .root_module = program(b, b, target, optimize) });
    b.installArtifact(exe);
    b.step("run", "Run bay").dependOn(&b.addRunArtifact(exe).step);
    dist(b);
    // CHANGELOG.md as bay releases it, for a tool that checks a package against it (preflight).
    _ = b.addModule("changelog", .{ .root_source_file = b.path("src/changelog.zig"), .target = target, .optimize = optimize });
}

/// The programs a release carries, one per host bay runs on, built ReleaseSafe
/// and stripped: `zig-out/dist/bay-<arch>-<os>`, static on Linux. With one, bay
/// needs no Zig installed first; it installs the Zig each package names.
fn dist(b: *std.Build) void {
    const step = b.step("dist", "Build the release programs for every host into zig-out/dist");
    const hosts = [_][]const u8{ "x86_64-linux-musl", "aarch64-linux-musl", "x86_64-macos", "aarch64-macos", "x86_64-windows-gnu", "aarch64-windows-gnu" };
    for (hosts) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable; // unreachable: the triples above parse
        const target = b.resolveTargetQuery(query);
        const module = program(b, b, target, .ReleaseSafe);
        // Safety checks stay; the debug information a person has no use for does not.
        module.strip = true;
        const exe = b.addExecutable(.{ .name = "bay", .root_module = module });
        const os = @tagName(target.result.os.tag);
        const name = b.fmt("bay-{s}-{s}{s}", .{ @tagName(target.result.cpu.arch), os, target.result.exeFileExt() });
        step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "dist" } }, .dest_sub_path = name, .pdb_dir = .disabled }).step);
    }
}

/// bay's development: its tests, on shakedown, under preflight's gate.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package = b.dependency("bay", .{ .target = target, .optimize = optimize }).builder;
    const step = b.step("test", "Run the tests");
    const check = b.step("check", "Compile the program and the tests without running them");
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown");
    tests(b, package, target, optimize, shakedown, step, check);
    // The release tier fuzzes the properties and runs the suite under ThreadSanitizer: a
    // workspace runs its members on threads of its own.
    tools.preflight.addCi(b, package, .{ .tests = step, .test_timeout = .{ .bound = .{ .limit = .fromSeconds(300), .reason = "an end-to-end test builds its fixtures' packages with Zig from cold, a build runner each, which a hosted Windows runner or a shared machine takes past two minutes" } }, .hardened = .{ .fuzz_step = "test", .tsan_step = "test" } });
}

/// bay's root module from `package`'s sources, built in `b`, with aegis, airlock and ensign.
fn program(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: ?std.lang.Optimize) *std.Build.Module {
    const aegis = package.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const airlock = package.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock");
    const ensign = package.dependency("ensign", .{ .target = target, .optimize = optimize }).module("ensign");
    const own = b.addOptions();
    own.addOption([]const u8, "version", zon.version);
    return b.createModule(.{ .root_source_file = package.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "aegis", .module = aegis },
        .{ .name = "airlock", .module = airlock },
        .{ .name = "ensign", .module = ensign },
        .{ .name = "own", .module = own.createModule() },
    } });
}

/// The unit tests, their properties on `shakedown`, and bay end to end over real packages,
/// run with the Zig that builds it. `step` runs them; `check` only compiles them, and the program.
fn tests(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: ?std.lang.Optimize, shakedown: *std.Build.Module, step: *std.Build.Step, check: *std.Build.Step) void {
    // The tests' one way of linking a folder, tested on its own.
    const link = b.createModule(.{ .root_source_file = package.path("test/link.zig"), .target = target, .optimize = optimize });
    const link_test = b.addTest(.{ .root_module = link });
    step.dependOn(&b.addRunArtifact(link_test).step);
    check.dependOn(&link_test.step);
    const unit_module = program(b, package, target, optimize);
    unit_module.addImport("shakedown", shakedown);
    unit_module.addImport("link", link);
    const unit = b.addTest(.{ .root_module = unit_module });
    step.dependOn(&b.addRunArtifact(unit).step);
    check.dependOn(&unit.step);
    const exe = b.addExecutable(.{ .name = "bay", .root_module = program(b, package, target, optimize) });
    check.dependOn(&exe.step);
    const options = b.addOptions();
    options.addOptionPath("bay", exe.getEmittedBin());
    options.addOption([]const u8, "zig", b.graph.zig_exe);
    options.addOption([]const u8, "version", zon.version);
    // The release tests push over git's SSH transport through this stand-in for ssh.
    const ssh = b.addExecutable(.{ .name = "ssh", .root_module = b.createModule(.{ .root_source_file = package.path("test/ssh.zig"), .target = target, .optimize = optimize }) });
    check.dependOn(&ssh.step);
    options.addOptionPath("ssh", ssh.getEmittedBin());
    const host = b.graph.host.result;
    for ([_][]const u8{ "test/resolution.zig", "test/release.zig" }) |root| {
        const end_to_end = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = package.path(root),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "options", .module = options.createModule() }, .{ .name = "link", .module = link } },
        }) });
        check.dependOn(&end_to_end.step);
        // End to end, bay runs the Zig that builds it, which runs on this host alone: a
        // build for another machine (the riscv64 kernel's leg) runs the unit tests there.
        if (target.result.cpu.arch != host.cpu.arch or target.result.os.tag != host.os.tag) continue;
        // The tests run bay, Zig and git on packages they write, none of which is an input
        // Zig tracks: a run is never taken from the cache.
        const run_end_to_end = b.addRunArtifact(end_to_end);
        run_end_to_end.has_side_effects = true;
        step.dependOn(&run_end_to_end.step);
    }
}
