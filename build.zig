const std = @import("std");

/// The bay program, and its tests, which need nothing but std.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "bay", .root_module = program(b, b, target, optimize) });
    b.installArtifact(exe);
    b.step("run", "Run bay").dependOn(&b.addRunArtifact(exe).step);
    tests(b, b, target, optimize, b.step("test", "Run the tests"));
}

/// bay's development: the same tests under preflight's gate.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package = b.dependency("bay", .{ .target = target, .optimize = optimize }).builder;
    const step = b.step("test", "Run the tests");
    tests(b, package, target, optimize, step);
    tools.preflight.addCi(b, package, .{ .tests = step });
}

/// bay's root module from `package`'s sources, built in `b`.
fn program(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    return b.createModule(.{ .root_source_file = package.path("src/main.zig"), .target = target, .optimize = optimize });
}

/// The unit tests, and bay end to end over real packages, run with the Zig that builds it.
fn tests(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, step: *std.Build.Step) void {
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = program(b, package, target, optimize) })).step);
    const exe = b.addExecutable(.{ .name = "bay", .root_module = program(b, package, target, optimize) });
    const options = b.addOptions();
    options.addOptionPath("bay", exe.getEmittedBin());
    options.addOption([]const u8, "zig", b.graph.zig_exe);
    const end_to_end = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = package.path("test/resolution.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "options", .module = options.createModule() }},
    }) });
    step.dependOn(&b.addRunArtifact(end_to_end).step);
}
