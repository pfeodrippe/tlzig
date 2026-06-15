const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const parser = @import("parser.zig");

pub const ModuleLoader = struct {
    arena: *Arena,
    search_paths: []const []const u8,

    pub fn init(arena: *Arena, search_paths: []const []const u8) ModuleLoader {
        return ModuleLoader{ .arena = arena, .search_paths = search_paths };
    }

    pub fn load(self: ModuleLoader, path: []const u8) !ast.Module {
        const source = try self.read_file(path);
        var p = parser.Parser.init(self.arena, source);
        var module = try p.parse_module();
        const dir = std.fs.path.dirname(path) orelse ".";
        var loaded = std.ArrayList([]const u8).empty;
        defer loaded.deinit(std.heap.page_allocator);
        try self.load_extends(&module, dir, &loaded);
        return module;
    }

    fn load_extends(self: ModuleLoader, module: *ast.Module, dir: []const u8, loaded: *std.ArrayList([]const u8)) !void {
        for (module.extends) |name| {
            if (self.already_loaded(loaded.items, name)) continue;
            try loaded.append(std.heap.page_allocator, try self.dup(name));
            const path = try self.find_module(name, dir);
            const source = try self.read_file(path);
            var p = parser.Parser.init(self.arena, source);
            var child = try p.parse_module();
            try self.load_extends(&child, std.fs.path.dirname(path) orelse ".", loaded);
            try self.merge(module, child);
        }
    }

    fn already_loaded(self: ModuleLoader, loaded: []const []const u8, name: []const u8) bool {
        _ = self;
        for (loaded) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn find_module(self: ModuleLoader, name: []const u8, dir: []const u8) ![]const u8 {
        const filename = try std.mem.concat(std.heap.page_allocator, u8, &.{ name, ".tla" });
        const local = try std.fs.path.join(std.heap.page_allocator, &.{ dir, filename });
        if (file_exists(local)) return local;
        for (self.search_paths) |sp| {
            const candidate = try std.fs.path.join(std.heap.page_allocator, &.{ sp, filename });
            if (file_exists(candidate)) return candidate;
        }
        return error.ModuleNotFound;
    }

    fn merge(self: ModuleLoader, parent: *ast.Module, child: ast.Module) !void {
        if (child.definitions.len == 0) return;
        const total = parent.definitions.len + child.definitions.len;
        const merged = try self.arena.alloc(ast.Definition, total);
        @memcpy(merged[0..parent.definitions.len], parent.definitions);
        @memcpy(merged[parent.definitions.len..], child.definitions);
        parent.definitions = merged;
    }

    fn read_file(self: ModuleLoader, path: []const u8) ![]u8 {
        const path_z = try std.heap.page_allocator.alloc(u8, path.len + 1);
        defer std.heap.page_allocator.free(path_z);
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const file = std.c.fopen(@ptrCast(path_z.ptr), "rb") orelse return error.IoError;
        defer _ = std.c.fclose(file);
        var temp = std.ArrayList(u8).empty;
        defer temp.deinit(std.heap.page_allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, file);
            if (n == 0) break;
            try temp.appendSlice(std.heap.page_allocator, buf[0..n]);
        }
        const result = try self.arena.alloc(u8, temp.items.len);
        @memcpy(result, temp.items);
        return result;
    }

    fn dup(self: ModuleLoader, s: []const u8) ![]const u8 {
        const copy = try self.arena.alloc(u8, s.len);
        @memcpy(copy, s);
        return copy;
    }
};

fn file_exists(path: []const u8) bool {
    const path_z = std.heap.page_allocator.alloc(u8, path.len + 1) catch return false;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const file = std.c.fopen(@ptrCast(path_z.ptr), "rb");
    if (file) |f| {
        _ = std.c.fclose(f);
        return true;
    }
    return false;
}
