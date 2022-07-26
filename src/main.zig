const std = @import("std");
const vpk = @import("vpk.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var pak = vpk.Vpk.init(gpa.allocator());
    defer pak.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.skip();

    const pak_dir = args.next() orelse "vpk";
    try addFiles(&pak, gpa.allocator(), pak_dir);

    std.log.info("Writing output", .{});
    try pak.write(std.fs.cwd(), "pak01");
}

fn addFiles(pak: *vpk.Vpk, allocator: std.mem.Allocator, dir_name: []const u8) !void {
    var dir = try std.fs.cwd().openIterableDir(dir_name, .{});
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .File) continue;

        std.log.info("Adding file: {s}", .{entry.path});

        const buf = try entry.dir.readFileAlloc(allocator, entry.basename, std.math.maxInt(usize));
        defer allocator.free(buf);

        try pak.addFile(entry.path, buf);
    }
}
