const std = @import("std");
const assert = std.debug.assert;

pub const Arena = struct {
    base: [*]u8,
    len: u64,
    cap: u64,

    pub fn init(capacity_bytes: u64) !Arena {
        const raw = try std.heap.page_allocator.alloc(u8, capacity_bytes + 64);
        const aligned: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(raw.ptr), 64));
        var arena: Arena = undefined;
        arena.base = aligned;
        arena.len = 0;
        arena.cap = capacity_bytes;
        return arena;
    }

    pub fn deinit(self: *Arena) void {
        std.heap.page_allocator.free(self.base[0..self.cap]);
        self.* = undefined;
    }

    pub fn alloc(self: *Arena, comptime T: type, count: u64) ![]T {
        assert(count > 0);
        const size = std.math.mul(u64, @sizeOf(T), count) catch return error.OutOfMemory;
        const aligned_size = std.mem.alignForward(u64, size, @alignOf(T));
        const aligned_len = std.mem.alignForward(u64, self.len, @alignOf(T));
        const new_len = std.math.add(u64, aligned_len, aligned_size) catch return error.OutOfMemory;
        if (new_len > self.cap) return error.OutOfMemory;
        const ptr: [*]T = @ptrCast(@alignCast(self.base + aligned_len));
        std.debug.assert(@intFromPtr(ptr) % @alignOf(T) == 0);
        self.len = new_len;
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
        self.len = 0;
    }

    pub fn used(self: Arena) u64 {
        return self.len;
    }

    pub fn remaining(self: Arena) u64 {
        return self.cap - self.len;
    }
};
