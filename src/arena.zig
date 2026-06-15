const std = @import("std");
const assert = std.debug.assert;

pub const Arena = struct {
    base: [*]u8,
    len: u64,
    cap: u64,

    pub fn init(capacity_bytes: u64) !Arena {
        assert(capacity_bytes > 0);
        const raw = try std.heap.page_allocator.alloc(u8, capacity_bytes + 64);
        assert(raw.len == capacity_bytes + 64);
        const aligned: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(raw.ptr), 64));
        assert(@intFromPtr(aligned) >= @intFromPtr(raw.ptr));
        var arena: Arena = undefined;
        arena.base = aligned;
        arena.len = 0;
        arena.cap = capacity_bytes;
        assert(arena.cap > 0);
        return arena;
    }

    pub fn deinit(self: *Arena) void {
        assert(self.cap > 0);
        assert(self.len <= self.cap);
        std.heap.page_allocator.free(self.base[0..self.cap]);
        self.* = undefined;
    }

    pub fn alloc(self: *Arena, comptime T: type, count: u64) ![]T {
        assert(count > 0);
        const size = std.math.mul(u64, @sizeOf(T), count) catch return error.OutOfMemory;
        const aligned_size = std.mem.alignForward(u64, size, @alignOf(T));
        const aligned_len = std.mem.alignForward(u64, self.len, @alignOf(T));
        const new_len = std.math.add(u64, aligned_len, aligned_size) catch return error.OutOfMemory;
        assert(aligned_len <= self.cap);
        if (new_len > self.cap) return error.OutOfMemory;
        const ptr: [*]T = @ptrCast(@alignCast(self.base + aligned_len));
        assert(@intFromPtr(ptr) % @alignOf(T) == 0);
        assert(@intFromPtr(ptr) >= @intFromPtr(self.base));
        self.len = new_len;
        assert(self.len <= self.cap);
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
        assert(self.len <= self.cap);
        self.len = 0;
    }

    pub fn used(self: Arena) u64 {
        assert(self.len <= self.cap);
        return self.len;
    }

    pub fn remaining(self: Arena) u64 {
        assert(self.len <= self.cap);
        return self.cap - self.len;
    }

    pub fn dup(self: *Arena, s: []const u8) ![]const u8 {
        assert(s.len > 0);
        const copy = try self.alloc(u8, s.len);
        @memcpy(copy, s);
        return copy;
    }
};
