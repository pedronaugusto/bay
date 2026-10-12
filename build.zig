const std = @import("std");
const zon = @import("build.zig.zon");

/// The bay program, and its tests: std and aegis.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "bay", .root_module = program(b, b, target, optimize) });
    b.installArtifact(exe);
    b.step("run", "Run bay").dependOn(&b.addRunArtifact(exe).step);
    tests(b, b, target, optimize, b.step("test", "Run the tests"), b.step("check", "Compile the program and the tests without running them"));
    dist(b);
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

/// bay's development: the same tests under preflight's gate.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package = b.dependency("bay", .{ .target = target, .optimize = optimize }).builder;
    const step = b.step("test", "Run the tests");
    const check = b.step("check", "Compile the program and the tests without running them");
    tests(b, package, target, optimize, step, check);
    tools.preflight.addCi(b, package, .{ .tests = step });
}

/// bay's root module from `package`'s sources, built in `b`, with aegis.
fn program(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const aegis = package.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const release = b.addOptions();
    release.addOption([]const u8, "version", zon.version);
    return b.createModule(.{ .root_source_file = package.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "aegis", .module = aegis },
        .{ .name = "release", .module = release.createModule() },
    } });
}

/// The unit tests, and bay end to end over real packages, run with the Zig that builds it.
/// `step` runs them; `check` only compiles them, and the program.
fn tests(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, step: *std.Build.Step, check: *std.Build.Step) void {
    const unit = b.addTest(.{ .root_module = program(b, package, target, optimize) });
    step.dependOn(&b.addRunArtifact(unit).step);
    check.dependOn(&unit.step);
    const exe = b.addExecutable(.{ .name = "bay", .root_module = program(b, package, target, optimize) });
    check.dependOn(&exe.step);
    const options = b.addOptions();
    options.addOptionPath("bay", exe.getEmittedBin());
    options.addOption([]const u8, "zig", b.graph.zig_exe);
    options.addOption([]const u8, "version", zon.version);
    const end_to_end = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = package.path("test/resolution.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "options", .module = options.createModule() }},
    }) });
    // The tests run bay, Zig and git on packages they write, none of which is an input
    // Zig tracks: a run is never taken from the cache.
    const run_end_to_end = b.addRunArtifact(end_to_end);
    run_end_to_end.has_side_effects = true;
    step.dependOn(&run_end_to_end.step);
    check.dependOn(&end_to_end.step);
}
