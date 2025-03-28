pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "Whether to use the LLVM backend to compile.") orelse true;

    const exe = b.addExecutable(.{
        .name = "zvpk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);
}

const std = @import("std");
