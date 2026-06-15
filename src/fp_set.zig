const std = @import("std");
const Arena = @import("arena.zig").Arena;
const Fingerprint = @import("fingerprint.zig").Fingerprint;

pub const FpSet = struct {
    slots: []?Fingerprint,
    cap: u32,
    count: u32,

    pub fn init(arena: *Arena, capacity: u32) !FpSet {
        const slots = try arena.alloc(?Fingerprint, capacity);
        @memset(slots, null);
        return FpSet{
            .slots = slots,
            .cap = capacity,
            .count = 0,
        };
    }

    pub fn put(self: *FpSet, fp: Fingerprint) bool {
        const effective = if (fp == 0) 0xdeadbeef else fp;
        if (self.count * 2 >= self.cap) return false;
        var idx: u32 = @intCast(effective % self.cap);
        var i: u32 = 0;
        while (i < self.cap) : (i += 1) {
            const slot = &self.slots[idx];
            if (slot.* == null) {
                slot.* = effective;
                self.count += 1;
                return true;
            }
            if (slot.*.? == effective) {
                return false;
            }
            idx = (idx + 1) % self.cap;
        }
        return false;
    }

    pub fn contains(self: FpSet, fp: Fingerprint) bool {
        const effective = if (fp == 0) 0xdeadbeef else fp;
        var idx: u32 = @intCast(effective % self.cap);
        var i: u32 = 0;
        while (i < self.cap) : (i += 1) {
            const slot = self.slots[idx];
            if (slot == null) return false;
            if (slot.? == fp) return true;
            idx = (idx + 1) % self.cap;
        }
        return false;
    }

    pub fn size(self: FpSet) u32 {
        return self.count;
    }
};
