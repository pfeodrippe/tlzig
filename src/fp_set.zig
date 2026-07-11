const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const Fingerprint = @import("fingerprint.zig").Fingerprint;

pub const FpSet = struct {
    slots: []Fingerprint,
    indices: []u32,
    cap: u32,
    count: u32,

    pub fn init(arena: *Arena, capacity: u32) !FpSet {
        assert(capacity > 0);
        const slots = try arena.alloc(Fingerprint, capacity);
        @memset(slots, 0);
        const indices = try arena.alloc(u32, capacity);
        @memset(indices, 0);
        return FpSet{
            .slots = slots,
            .indices = indices,
            .cap = capacity,
            .count = 0,
        };
    }

    pub fn put(self: *FpSet, fp: Fingerprint) bool {
        return self.put_with_index(fp, 0) == null;
    }

    /// Inserts fingerprint associated with the given state index.
    /// Returns null if the fingerprint was newly inserted.
    /// Returns the previously stored state index if the fingerprint already existed.
    pub fn put_with_index(self: *FpSet, fp: Fingerprint, state_index: u32) ?u32 {
        assert(self.cap > 0);
        assert(self.count <= self.cap);
        const effective = if (fp == 0) 0xdeadbeef else fp;
        if (self.count * 2 >= self.cap) return state_index;
        var idx: u32 = @intCast(effective % self.cap);
        var i: u32 = 0;
        while (i < self.cap) : (i += 1) {
            const slot = @atomicLoad(Fingerprint, &self.slots[idx], .acquire);
            if (slot == 0) {
                self.indices[idx] = state_index;
                @atomicStore(
                    Fingerprint,
                    &self.slots[idx],
                    effective,
                    .release,
                );
                self.count += 1;
                return null;
            }
            if (slot == effective) {
                return self.indices[idx];
            }
            idx = (idx + 1) % self.cap;
        }
        return state_index;
    }

    pub fn contains(self: FpSet, fp: Fingerprint) bool {
        return self.find(fp) != null;
    }

    pub fn find(self: FpSet, fp: Fingerprint) ?u32 {
        assert(self.cap > 0);
        const effective = if (fp == 0) 0xdeadbeef else fp;
        var idx: u32 = @intCast(effective % self.cap);
        var i: u32 = 0;
        while (i < self.cap) : (i += 1) {
            const slot = @atomicLoad(Fingerprint, &self.slots[idx], .acquire);
            if (slot == 0) return null;
            if (slot == effective) {
                assert(self.indices[idx] < self.cap);
                return self.indices[idx];
            }
            idx = (idx + 1) % self.cap;
        }
        return null;
    }

    pub fn size(self: FpSet) u32 {
        assert(self.count <= self.cap);
        return self.count;
    }
};
