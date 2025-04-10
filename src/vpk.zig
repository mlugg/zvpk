const std = @import("std");

pub const Vpk = struct {
    arena: std.heap.ArenaAllocator,
    dir_tree: DirTree1,

    // indexed by file extensions
    const DirTree1 = std.StringArrayHashMapUnmanaged(DirTree2);

    // indexed by directory path
    const DirTree2 = std.StringArrayHashMapUnmanaged(DirTree3);

    // indexed by filename
    const DirTree3 = std.StringArrayHashMapUnmanaged(DirEntry);

    const DirEntry = struct {
        crc: u32,
        data: []u8,
    };

    const ArchiveWriteInfo = struct {
        files: []Entry,

        const Entry = struct {
            skip_preload: u16,
            entry: *DirEntry,
        };
    };

    const max_archive_size = 256 * 1024 * 1024; // 256 MiB

    pub fn init(allocator: std.mem.Allocator) Vpk {
        return Vpk{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .dir_tree = .{},
        };
    }

    pub fn deinit(self: *Vpk) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn addFile(self: *Vpk, path: []const u8, data: []const u8) !void {
        if (path.len == 0) return error.BadPath;
        if (path[0] == '/' or path[path.len - 1] == '/') return error.BadPath;
        if (path[0] == '\\' or path[path.len - 1] == '\\') return error.BadPath;

        const path1 = try self.arena.allocator().alloc(u8, path.len);
        _ = std.mem.replace(u8, path, "\\", "/", path1);

        var dir_str: []const u8 = undefined;
        var filename: []const u8 = undefined;

        if (std.mem.lastIndexOfScalar(u8, path1, '/')) |idx| {
            dir_str = path1[0..idx];
            filename = path1[idx + 1 ..];
        } else {
            dir_str = "";
            filename = path1;
        }

        var file_str: []const u8 = undefined;
        var ext_str: []const u8 = undefined;

        // Ignore the last byte because filenames like 'foo.' should include the dot in the name part
        if (std.mem.lastIndexOfScalar(u8, filename[0 .. filename.len - 1], '.')) |last_idx| {
            // The VPK implementation that ships with Portal 2 has a bug here where filenames like
            // 'model.dx90.vtx' ignore the middle part, and become 'model.vtx'. However, many builds
            // of VPK lack this bug, and it does more harm than good to replicate it. In particular,
            // it seems that the Portal 2 game files are themselves packed using a version of VPK
            // which does *not* suffer from this bug. As such, we do not replicate it.
            file_str = filename[0..last_idx];
            ext_str = filename[last_idx + 1 ..];
        } else {
            file_str = filename;
            ext_str = "";
        }

        const ext = try self.dir_tree.getOrPut(self.arena.allocator(), ext_str);
        if (!ext.found_existing) ext.value_ptr.* = .{};

        const dir = try ext.value_ptr.getOrPut(self.arena.allocator(), dir_str);
        if (!dir.found_existing) dir.value_ptr.* = .{};

        const file = try dir.value_ptr.getOrPut(self.arena.allocator(), file_str);
        if (file.found_existing) {
            return error.FileInArchive;
        } else {
            const data1 = try self.arena.allocator().dupe(u8, data);
            file.value_ptr.* = .{
                .crc = std.hash.Crc32.hash(data1),
                .data = data1,
            };
        }
    }

    pub fn write(self: *Vpk, dir: std.fs.Dir, comptime name: []const u8) !void {
        var dir_file = try dir.createFile(name ++ "_dir.vpk", .{});
        defer dir_file.close();

        const archives = try self.writeDir(dir_file);

        if (archives.len > 0) {
            try writeArchive(dir_file.writer(), archives[0]);
        }

        for (archives[1..], 0..) |archive, i| {
            var name_buf: [name.len + 8]u8 = undefined;
            const name_str = std.fmt.bufPrint(&name_buf, "{s}_{d:0>3}.vpk", .{ name, i }) catch unreachable;

            var f = try dir.createFile(name_str, .{});
            defer f.close();

            try writeArchive(f.writer(), archive);
        }
    }

    fn writeDir(self: *Vpk, f: std.fs.File) ![]ArchiveWriteInfo {
        // Header
        try f.writer().writeInt(u32, 0x55aa1234, .little); // Signature
        try f.writer().writeInt(u32, 1, .little); // Version

        // Write placeholder size to be filled in later
        const dir_size_pos = try f.getPos();
        try f.writer().writeInt(u32, 0, .little);

        // Write dir tree, tracking its size
        var counting = std.io.countingWriter(f.writer());
        const archives = try self.writeDirTree(counting.writer());

        // Overwrite dir tree size
        try f.seekTo(dir_size_pos);
        try f.writer().writeInt(u32, @intCast(counting.bytes_written), .little);

        // Skip back past dir tree
        try f.seekBy(@intCast(counting.bytes_written));

        return archives;
    }

    fn writeArchive(w: anytype, archive: ArchiveWriteInfo) !void {
        var bw = std.io.bufferedWriter(w);

        for (archive.files) |file| {
            try bw.writer().writeAll(file.entry.data[file.skip_preload..]);
        }

        try bw.flush();
    }

    // Write the directory tree and returns information on the position of
    // every file in the archive
    fn writeDirTree(self: *Vpk, w: anytype) ![]ArchiveWriteInfo {
        // archive number 0 = dir
        var archives = std.ArrayList(ArchiveWriteInfo).init(self.arena.allocator());
        defer archives.deinit();

        var cur_archive = std.ArrayList(ArchiveWriteInfo.Entry).init(self.arena.allocator());
        defer archives.deinit();

        var cur_archive_off: u32 = 0;

        var it1 = self.dir_tree.iterator();
        while (it1.next()) |extension| {
            try writeName(w, extension.key_ptr.*);

            var it2 = extension.value_ptr.iterator();
            while (it2.next()) |directory| {
                try writeName(w, directory.key_ptr.*);

                var it3 = directory.value_ptr.iterator();
                while (it3.next()) |file| {
                    try writeName(w, file.key_ptr.*);

                    const size: u32 = @intCast(file.value_ptr.data.len);
                    if (size > max_archive_size) {
                        return error.FileTooLarge;
                    }

                    // Go to the next archive if necessary
                    if (cur_archive_off + size > max_archive_size) {
                        try archives.ensureUnusedCapacity(1);
                        const files = try cur_archive.toOwnedSlice();
                        archives.appendAssumeCapacity(.{ .files = files });
                        cur_archive_off = 0;
                    }

                    const archive_idx: u16 = if (archives.items.len == 0)
                        0x7FFF
                    else
                        @intCast(archives.items.len - 1);

                    // Write the entry data
                    try w.writeInt(u32, file.value_ptr.crc, .little);
                    try w.writeInt(u16, 0, .little); // PreloadBytes
                    try w.writeInt(u16, archive_idx, .little); // ArchiveIndex
                    try w.writeInt(u32, cur_archive_off, .little); // EntryOffset
                    try w.writeInt(u32, size, .little); // EntryLength
                    try w.writeInt(u16, 0xFFFF, .little); // Terminator

                    // Append the record to the archive
                    try cur_archive.append(.{
                        .skip_preload = 0,
                        .entry = file.value_ptr,
                    });
                    cur_archive_off += size;
                }
                try writeString(w, ""); // terminator
            }
            try writeString(w, ""); // terminator
        }
        try writeString(w, ""); // terminator

        if (cur_archive.items.len > 0) {
            // Flush final archive
            try archives.ensureUnusedCapacity(1);
            const files = try cur_archive.toOwnedSlice();
            archives.appendAssumeCapacity(.{ .files = files });
        }

        return archives.toOwnedSlice();
    }

    fn writeName(w: anytype, str: []const u8) !void {
        if (std.mem.eql(u8, str, "")) {
            try writeString(w, " "); // empty names represented by a single space
        } else {
            try writeString(w, str);
        }
    }

    fn writeString(w: anytype, str: []const u8) !void {
        try w.writeAll(str);
        try w.writeByte(0);
    }
};
