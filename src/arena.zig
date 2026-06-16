const std = @import("std");
const assert = std.debug.assert;

pub const Arena = struct {
    chunks: std.ArrayList(Chunk),
    cur_chunk: usize,
    total_len: u64,
    /// Initial chunk size and growth increment.
    chunk_size: u64,

    const Chunk = struct {
        raw: [*]u8,
        raw_len: usize,
        base: [*]u8,
        len: u64,
        cap: u64,
    };

    pub fn init(capacity_bytes: u64) !Arena {
        assert(capacity_bytes > 0);
        var chunks: std.ArrayList(Chunk) = .empty;
        try Arena.grow_chunk(&chunks, capacity_bytes);
        return Arena{
            .chunks = chunks,
            .cur_chunk = 0,
            .total_len = 0,
            .chunk_size = capacity_bytes,
        };
    }

    fn grow_chunk(chunks: *std.ArrayList(Chunk), size: u64) !void {
        const raw = try std.heap.page_allocator.alloc(u8, size + 64);
        const aligned: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(raw.ptr), 64));
        try chunks.append(std.heap.page_allocator, .{
            .raw = raw.ptr,
            .raw_len = raw.len,
            .base = aligned,
            .len = 0,
            .cap = size,
        });
    }

    pub fn deinit(self: *Arena) void {
        for (self.chunks.items) |c| {
            std.heap.page_allocator.free(c.raw[0..c.raw_len]);
        }
        self.chunks.deinit(std.heap.page_allocator);
        self.* = undefined;
    }

    pub fn alloc(self: *Arena, comptime T: type, count: u64) ![]T {
        if (count == 0) return &[_]T{};
        const size = std.math.mul(u64, @sizeOf(T), count) catch return error.OutOfMemory;
        const aligned_size = std.mem.alignForward(u64, size, @alignOf(T));

        // Try current chunk.
        var chunk = &self.chunks.items[self.cur_chunk];
        const aligned_len = std.mem.alignForward(u64, chunk.len, @alignOf(T));
        const new_len = aligned_len + aligned_size;
        if (new_len > chunk.cap) {
            // Need a new chunk. Grow by at least 2x or enough for this alloc.
            const grow_size = @max(self.chunk_size * 2, aligned_size + @alignOf(T));
            self.chunk_size = grow_size;
            try Arena.grow_chunk(&self.chunks, grow_size);
            self.cur_chunk = self.chunks.items.len - 1;
            chunk = &self.chunks.items[self.cur_chunk];
        }

        const final_aligned = std.mem.alignForward(u64, chunk.len, @alignOf(T));
        const ptr: [*]T = @ptrCast(@alignCast(chunk.base + final_aligned));
        chunk.len = final_aligned + aligned_size;
        self.total_len += aligned_size;
        return ptr[0..count];
    }

    pub fn alloc_object(self: *Arena, comptime T: type) !*T {
        const slice = try self.alloc(T, 1);
        return &slice[0];
    }

    pub fn alloc_bytes(self: *Arena, count: u64) ![]u8 {
        return self.alloc(u8, count);
    }

    pub fn reset(self: *Arena) void {
        // Only reset eval-arena style: free all extra chunks, reset first chunk.
        while (self.chunks.items.len > 1) {
            const c = self.chunks.pop();
            std.heap.page_allocator.free(c.raw[0..c.raw_len]);
        }
        self.cur_chunk = 0;
        self.chunks.items[0].len = 0;
        self.total_len = 0;
    }

    pub fn used(self: Arena) u64 {
        return self.total_len;
    }

    pub fn remaining(_: Arena) u64 {
        // Always can grow.
        return std.math.maxInt(u64);
    }

    pub fn dup(self: *Arena, s: []const u8) ![]const u8 {
        const copy = try self.alloc(u8, s.len);
        @memcpy(copy, s);
        return copy;
    }
};
