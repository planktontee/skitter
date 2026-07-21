const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("skitter", .{
        .root_source_file = b.path("skitter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .ReleaseFast,
        .omit_frame_pointer = optimize == .ReleaseFast,
    });
    const regent = b.dependency("regent", .{
        .target = target,
        .optimize = optimize,
    }).module("regent");
    const zcasp = b.dependency("zcasp", .{
        .target = target,
        .optimize = optimize,
    }).module("zcasp");

    module.addImport("regent", regent);
    module.addImport("zcasp", zcasp);
    zcasp.addImport("regent", regent);

    const unit_tests = b.addTest(.{
        .root_module = module,
        .use_llvm = true,
        // TODO: add test filter options
    });
    b.installArtifact(unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const exe = b.addExecutable(.{
        .name = "skitter",
        .root_module = module,
        .use_llvm = true,
    });
    exe.lto = if (optimize == .Debug) .none else .full;
    exe.step.dependOn(&run_unit_tests.step);

    b.installArtifact(exe);
}
