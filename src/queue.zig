const std = @import("std");
const Arena = @import("arena.zig").Arena;

pub const StateQueue = struct {
    buffer: []u32,
    head: u32,
    tail: u32,
    cap: u32,
    count: u32,

    pub fn init(arena: *Arena, capacity: u32) !StateQueue {
        return StateQueue{
            .buffer = try arena.alloc(u32, capacity),
            .head = 0,
            .tail = 0,
            .cap = capacity,
            .count = 0,
        };
    }

    pub fn enqueue(self: *StateQueue, state_idx: u32) bool {
        if (self.count >= self.cap) return false;
        self.buffer[self.tail] = state_idx;
        self.tail = (self.tail + 1) % self.cap;
        self.count += 1;
        return true;
    }

    pub fn dequeue(self: *StateQueue) ?u32 {
        if (self.count == 0) return null;
        const idx = self.buffer[self.head];
        self.head = (self.head + 1) % self.cap;
        self.count -= 1;
        return idx;
    }

    pub fn is_empty(self: StateQueue) bool {
        return self.count == 0;
    }

    pub fn len(self: StateQueue) u32 {
        return self.count;
    }
};
