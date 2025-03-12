const Builder = @import("std").Build;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "chip8",
        .root_source_file = b.path("chip8.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkSystemLibrary("SDL2");
    exe.linkLibC();
    b.installArtifact(exe);

    const run = b.step("run", "Run the chip8 emulator");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run.dependOn(&run_cmd.step);
}
