const std = @import("std");
const Arena = @import("arena.zig").Arena;

pub const ValueTag = enum(u8) {
    bool_v,
    int_v,
    set_v,
    function_v,
    tuple_v,
    record_v,
    string_v,
    model_v,
};

pub const Value = union(ValueTag) {
    bool_v: bool,
    int_v: i64,
    set_v: Set,
    function_v: Function,
    tuple_v: Tuple,
    record_v: Record,
    string_v: String,
    model_v: u32,

    pub fn is_truthy(self: Value) bool {
        return switch (self) {
            .bool_v => |b| b,
            else => false,
        };
    }

    pub fn as_int(self: Value) ?i64 {
        return switch (self) {
            .int_v => |i| i,
            else => null,
        };
    }

    pub fn as_bool(self: Value) ?bool {
        return switch (self) {
            .bool_v => |b| b,
            else => null,
        };
    }

    pub fn eql(a: Value, b: Value, pool: *const ValuePool) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .bool_v => |ba| ba == b.bool_v,
            .int_v => |ia| ia == b.int_v,
            .model_v => |ma| ma == b.model_v,
            .set_v => |sa| sa.eql(b.set_v, pool),
            .function_v => |fa| fa.eql(b.function_v, pool),
            .tuple_v => |ta| ta.eql(b.tuple_v, pool),
            .record_v => |ra| ra.eql(b.record_v, pool),
            .string_v => |sa| sa.eql(b.string_v, pool),
        };
    }

    pub fn compare(a: Value, b: Value, pool: *const ValuePool) ?i8 {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return null;
        return switch (a) {
            .bool_v => |ba| if (ba == b.bool_v) 0 else if (ba) 1 else -1,
            .int_v => |ia| {
                const ib = b.int_v;
                return if (ia < ib) -1 else if (ia > ib) 1 else 0;
            },
            .string_v => |sa| sa.compare(b.string_v, pool),
            else => null,
        };
    }

    pub fn clone(self: Value, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!Value {
        return switch (self) {
            .bool_v => |b| Value{ .bool_v = b },
            .int_v => |i| Value{ .int_v = i },
            .model_v => |m| Value{ .model_v = m },
            .string_v => |s| Value{ .string_v = try s.clone(source, target) },
            .set_v => |s| Value{ .set_v = try s.clone(source, target) },
            .function_v => |f| Value{ .function_v = try f.clone(source, target) },
            .tuple_v => |t| Value{ .tuple_v = try t.clone(source, target) },
            .record_v => |r| Value{ .record_v = try r.clone(source, target) },
        };
    }
};

pub const Set = extern struct {
    offset: u32,
    len: u32,

    pub fn items(self: Set, pool: *const ValuePool) []const Value {
        return pool.values[self.offset..][0..self.len];
    }

    pub fn contains(self: Set, pool: *const ValuePool, v: Value) bool {
        for (self.items(pool)) |it| {
            if (it.eql(v, pool)) return true;
        }
        return false;
    }

    pub fn is_subset(self: Set, pool: *const ValuePool, other: Set) bool {
        for (self.items(pool)) |it| {
            if (!other.contains(pool, it)) return false;
        }
        return true;
    }

    pub fn eql(self: Set, other: Set, pool: *const ValuePool) bool {
        if (self.len != other.len) return false;
        return self.is_subset(pool, other);
    }

    pub fn clone(self: Set, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!Set {
        const src_items = self.items(source);
        const dest = try target.alloc_values(@intCast(src_items.len));
        for (src_items, 0..) |it, i| {
            dest[i] = try it.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        return Set{ .offset = offset, .len = @intCast(src_items.len) };
    }
};

pub const Function = extern struct {
    domain: Set,
    offset: u32,
    len: u32,

    pub fn entries(self: Function, pool: *const ValuePool) []const Value {
        std.debug.assert(self.len == self.domain.len);
        return pool.values[self.offset..][0..self.len];
    }

    pub fn apply(self: Function, pool: *const ValuePool, key: Value) ?Value {
        const keys = self.domain.items(pool);
        for (keys, 0..) |k, i| {
            if (k.eql(key, pool)) return self.entries(pool)[i];
        }
        return null;
    }

    pub fn eql(self: Function, other: Function, pool: *const ValuePool) bool {
        if (!self.domain.eql(other.domain, pool)) return false;
        const a = self.entries(pool);
        const b = other.entries(pool);
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y, pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Function, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!Function {
        const dom = try self.domain.clone(source, target);
        const vals = self.entries(source);
        const dest = try target.alloc_values(@intCast(vals.len));
        for (vals, 0..) |v, i| {
            dest[i] = try v.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        return Function{
            .domain = dom,
            .offset = offset,
            .len = @intCast(vals.len),
        };
    }
};

pub const Tuple = extern struct {
    offset: u32,
    len: u32,

    pub fn items(self: Tuple, pool: *const ValuePool) []const Value {
        return pool.values[self.offset..][0..self.len];
    }

    pub fn eql(self: Tuple, other: Tuple, pool: *const ValuePool) bool {
        if (self.len != other.len) return false;
        for (self.items(pool), other.items(pool)) |a, b| {
            if (!a.eql(b, pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Tuple, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!Tuple {
        const src_items = self.items(source);
        const dest = try target.alloc_values(@intCast(src_items.len));
        for (src_items, 0..) |it, i| {
            dest[i] = try it.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        return Tuple{ .offset = offset, .len = @intCast(src_items.len) };
    }
};

pub const Record = extern struct {
    offset: u32,
    len: u32,

    pub fn fields(self: Record, pool: *const ValuePool) []const Value {
        return pool.values[self.offset..][0 .. self.len * 2];
    }

    pub fn lookup(self: Record, pool: *const ValuePool, name: []const u8) ?Value {
        const fs = self.fields(pool);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const key = fs[i * 2].string_v;
            if (std.mem.eql(u8, key.slice(pool), name)) {
                return fs[i * 2 + 1];
            }
        }
        return null;
    }

    pub fn eql(self: Record, other: Record, pool: *const ValuePool) bool {
        if (self.len != other.len) return false;
        const a = self.fields(pool);
        const b = other.fields(pool);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            if (!a[i * 2].string_v.eql(b[i * 2].string_v, pool)) return false;
            if (!a[i * 2 + 1].eql(b[i * 2 + 1], pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Record, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!Record {
        const fs = self.fields(source);
        const dest = try target.alloc_values(@intCast(fs.len));
        for (fs, 0..) |v, i| {
            dest[i] = try v.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        return Record{ .offset = offset, .len = self.len };
    }
};

pub const String = extern struct {
    offset: u32,
    len: u32,

    pub fn slice(self: String, pool: *const ValuePool) []const u8 {
        return pool.strings[self.offset..][0..self.len];
    }

    pub fn eql(self: String, other: String, pool: *const ValuePool) bool {
        return std.mem.eql(u8, self.slice(pool), other.slice(pool));
    }

    pub fn compare(self: String, other: String, pool: *const ValuePool) i8 {
        const order = std.mem.order(u8, self.slice(pool), other.slice(pool));
        return switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    pub fn clone(self: String, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!String {
        return try target.push_string(self.slice(source));
    }
};

pub const ModelTable = struct {
    arena: *Arena,
    names: [][]const u8,
    count: u32,
    cap: u32,

    pub fn init(arena: *Arena, cap: u32) !ModelTable {
        const names = try arena.alloc([]const u8, cap);
        return ModelTable{
            .arena = arena,
            .names = names,
            .count = 0,
            .cap = cap,
        };
    }

    pub fn intern(self: *ModelTable, name: []const u8) !u32 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i], name)) return @intCast(i);
        }
        if (self.count >= self.cap) return error.OutOfMemory;
        const copy = try self.arena.alloc(u8, name.len);
        @memcpy(copy, name);
        const id = self.count;
        self.names[id] = copy;
        self.count += 1;
        return id;
    }

    pub fn get_name(self: *const ModelTable, id: u32) []const u8 {
        std.debug.assert(id < self.count);
        return self.names[id];
    }
};

pub const ValuePool = struct {
    arena: *Arena,
    values: []Value,
    strings: []u8,
    value_count: u32,
    string_count: u32,
    value_cap: u32,
    string_cap: u32,

    pub fn init(arena: *Arena, value_cap: u32, string_cap: u32) !ValuePool {
        return ValuePool{
            .arena = arena,
            .values = try arena.alloc(Value, value_cap),
            .strings = try arena.alloc(u8, string_cap),
            .value_count = 0,
            .string_count = 0,
            .value_cap = value_cap,
            .string_cap = string_cap,
        };
    }

    pub fn push_value(self: *ValuePool, v: Value) !u32 {
        if (self.value_count >= self.value_cap) return error.OutOfMemory;
        const idx = self.value_count;
        self.values[idx] = v;
        self.value_count += 1;
        return idx;
    }

    pub fn alloc_values(self: *ValuePool, count: u32) ![]Value {
        if (self.value_count + count > self.value_cap) return error.OutOfMemory;
        const start = self.value_count;
        self.value_count += count;
        return self.values[start..][0..count];
    }

    pub fn push_string(self: *ValuePool, s: []const u8) !String {
        if (self.string_count + s.len > self.string_cap) return error.OutOfMemory;
        const start = self.string_count;
        @memcpy(self.strings[start..][0..s.len], s);
        self.string_count += @intCast(s.len);
        return String{ .offset = start, .len = @intCast(s.len) };
    }

    pub fn snapshot(self: ValuePool) Snapshot {
        return .{
            .value_count = self.value_count,
            .string_count = self.string_count,
        };
    }

    pub fn restore(self: *ValuePool, snap: Snapshot) void {
        self.value_count = snap.value_count;
        self.string_count = snap.string_count;
    }

    pub const Snapshot = struct {
        value_count: u32,
        string_count: u32,
    };
};
