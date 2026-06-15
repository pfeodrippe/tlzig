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
        try self.load_instances(&module, dir, &loaded);
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

    fn merge_instance(self: ModuleLoader, parent: *ast.Module, child: ast.Module, subs: []const ast.Substitution) !void {
        if (child.definitions.len == 0) return;
        const total = parent.definitions.len + child.definitions.len;
        const merged = try self.arena.alloc(ast.Definition, total);
        @memcpy(merged[0..parent.definitions.len], parent.definitions);
        for (child.definitions, 0..) |def, i| {
            const new_body = try copy_expr(self.arena, def.body, subs);
            merged[parent.definitions.len + i] = ast.Definition{
                .name = def.name,
                .params = def.params,
                .body = new_body,
            };
        }
        parent.definitions = merged;
    }

    fn load_instances(self: ModuleLoader, module: *ast.Module, dir: []const u8, loaded: *std.ArrayList([]const u8)) !void {
        for (module.instances) |inst| {
            if (self.already_loaded(loaded.items, inst.module_name)) continue;
            try loaded.append(std.heap.page_allocator, try self.dup(inst.module_name));
            const path = try self.find_module(inst.module_name, dir);
            const source = try self.read_file(path);
            var p = parser.Parser.init(self.arena, source);
            var child = try p.parse_module();
            try self.load_extends(&child, std.fs.path.dirname(path) orelse ".", loaded);
            try self.load_instances(&child, std.fs.path.dirname(path) orelse ".", loaded);
            try self.merge_instance(module, child, inst.substitutions);
        }
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

fn copy_expr(arena: *Arena, expr: *const ast.Expr, subs: []const ast.Substitution) !*ast.Expr {
    switch (expr.*) {
        .ident => |name| {
            for (subs) |s| {
                if (std.mem.eql(u8, name, s.local_name)) {
                    return try copy_expr(arena, s.expr, &[_]ast.Substitution{});
                }
            }
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .ident = try arena.dup(name) };
            return ptr;
        },
        .bool_literal => |b| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .bool_literal = b };
            return ptr;
        },
        .int_literal => |i| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .int_literal = i };
            return ptr;
        },
        .string_literal => |s| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .string_literal = try arena.dup(s) };
            return ptr;
        },
        .primed => |name| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .primed = try arena.dup(name) };
            return ptr;
        },
        .unchanged => |names| {
            const ptr = try arena.alloc_object(ast.Expr);
            const copy: []const []const u8 = if (names.len == 0) &[_][]const u8{} else blk: {
                const c = try arena.alloc([]const u8, names.len);
                for (names, 0..) |n, i| c[i] = try arena.dup(n);
                break :blk c;
            };
            ptr.* = .{ .unchanged = copy };
            return ptr;
        },
        .at => {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .at;
            return ptr;
        },
        .binary => |b| {
            const bp = try arena.alloc_object(ast.Binary);
            bp.* = .{
                .op = b.op,
                .left = try copy_expr(arena, b.left, subs),
                .right = try copy_expr(arena, b.right, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .binary = bp };
            return ptr;
        },
        .unary => |u| {
            const up = try arena.alloc_object(ast.Unary);
            up.* = .{
                .op = u.op,
                .operand = try copy_expr(arena, u.operand, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .unary = up };
            return ptr;
        },
        .if_then_else => |ite| {
            const ip = try arena.alloc_object(ast.IfThenElse);
            ip.* = .{
                .cond = try copy_expr(arena, ite.cond, subs),
                .then_branch = try copy_expr(arena, ite.then_branch, subs),
                .else_branch = try copy_expr(arena, ite.else_branch, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .if_then_else = ip };
            return ptr;
        },
        .apply => |ap| {
            const app = try arena.alloc_object(ast.Apply);
            const args: []const *ast.Expr = if (ap.args.len == 0) &[_]*ast.Expr{} else blk: {
                const c = try arena.alloc(*ast.Expr, ap.args.len);
                for (ap.args, 0..) |a, i| c[i] = try copy_expr(arena, a, subs);
                break :blk c;
            };
            app.* = .{
                .func = try copy_expr(arena, ap.func, subs),
                .args = args,
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .apply = app };
            return ptr;
        },
        .field => |f| {
            const fp = try arena.alloc_object(ast.Field);
            fp.* = .{
                .expr = try copy_expr(arena, f.expr, subs),
                .name = try arena.dup(f.name),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .field = fp };
            return ptr;
        },
        .tuple => |items| {
            const copy: []const *ast.Expr = if (items.len == 0) &[_]*ast.Expr{} else blk: {
                const c = try arena.alloc(*ast.Expr, items.len);
                for (items, 0..) |it, i| c[i] = try copy_expr(arena, it, subs);
                break :blk c;
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .tuple = copy };
            return ptr;
        },
        .record => |fields| {
            const copy: []const ast.FieldInit = if (fields.len == 0) &[_]ast.FieldInit{} else blk: {
                const c = try arena.alloc(ast.FieldInit, fields.len);
                for (fields, 0..) |f, i| {
                    c[i] = .{
                        .name = try arena.dup(f.name),
                        .value = try copy_expr(arena, f.value, subs),
                    };
                }
                break :blk c;
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .record = copy };
            return ptr;
        },
        .set_enum => |items| {
            const copy: []const *ast.Expr = if (items.len == 0) &[_]*ast.Expr{} else blk: {
                const c = try arena.alloc(*ast.Expr, items.len);
                for (items, 0..) |it, i| c[i] = try copy_expr(arena, it, subs);
                break :blk c;
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_enum = copy };
            return ptr;
        },
        .set_filter => |sf| {
            const sp = try arena.alloc_object(ast.SetFilter);
            sp.* = .{
                .var_name = try arena.dup(sf.var_name),
                .domain = try copy_expr(arena, sf.domain, subs),
                .pred = try copy_expr(arena, sf.pred, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_filter = sp };
            return ptr;
        },
        .set_map => |sm| {
            const sp = try arena.alloc_object(ast.SetMap);
            sp.* = .{
                .var_name = try arena.dup(sm.var_name),
                .domain = try copy_expr(arena, sm.domain, subs),
                .value = try copy_expr(arena, sm.value, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_map = sp };
            return ptr;
        },
        .set_binary => |sb| {
            const bp = try arena.alloc_object(ast.SetBinary);
            bp.* = .{
                .op = sb.op,
                .left = try copy_expr(arena, sb.left, subs),
                .right = try copy_expr(arena, sb.right, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_binary = bp };
            return ptr;
        },
        .set_of_functions => |sf| {
            const sp = try arena.alloc_object(ast.SetOfFunctions);
            sp.* = .{
                .domain = try copy_expr(arena, sf.domain, subs),
                .codomain = try copy_expr(arena, sf.codomain, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_of_functions = sp };
            return ptr;
        },
        .function_literal => |fl| {
            const fp = try arena.alloc_object(ast.FunctionLiteral);
            const vars: []const ast.BoundVar = if (fl.vars.len == 0) &[_]ast.BoundVar{} else blk: {
                const c = try arena.alloc(ast.BoundVar, fl.vars.len);
                for (fl.vars, 0..) |v, i| {
                    c[i] = .{
                        .name = try arena.dup(v.name),
                        .domain = try copy_expr(arena, v.domain, subs),
                    };
                }
                break :blk c;
            };
            fp.* = .{ .vars = vars, .body = try copy_expr(arena, fl.body, subs) };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .function_literal = fp };
            return ptr;
        },
        .record_set => |rs| {
            const rp = try arena.alloc_object(ast.RecordSet);
            const fields: []const ast.RecordFieldDomain = if (rs.fields.len == 0) &[_]ast.RecordFieldDomain{} else blk: {
                const c = try arena.alloc(ast.RecordFieldDomain, rs.fields.len);
                for (rs.fields, 0..) |f, i| {
                    c[i] = .{
                        .name = try arena.dup(f.name),
                        .domain = try copy_expr(arena, f.domain, subs),
                    };
                }
                break :blk c;
            };
            rp.* = .{ .fields = fields };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .record_set = rp };
            return ptr;
        },
        .except => |e| {
            const ep = try arena.alloc_object(ast.Except);
            const steps: []const ast.AccessStep = if (e.steps.len == 0) &[_]ast.AccessStep{} else blk: {
                const c = try arena.alloc(ast.AccessStep, e.steps.len);
                for (e.steps, 0..) |s, i| {
                    c[i] = switch (s) {
                        .field => |f| .{ .field = try arena.dup(f) },
                        .index => |ix| .{ .index = try copy_expr(arena, ix, subs) },
                    };
                }
                break :blk c;
            };
            ep.* = .{
                .func = try copy_expr(arena, e.func, subs),
                .steps = steps,
                .value = try copy_expr(arena, e.value, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .except = ep };
            return ptr;
        },
        .let_in => |li| {
            const lp = try arena.alloc_object(ast.LetIn);
            const defs: []const ast.Definition = if (li.defs.len == 0) &[_]ast.Definition{} else blk: {
                const c = try arena.alloc(ast.Definition, li.defs.len);
                for (li.defs, 0..) |d, i| {
                    const params: []const []const u8 = if (d.params.len == 0) &[_][]const u8{} else blk_p: {
                        const cp = try arena.alloc([]const u8, d.params.len);
                        for (d.params, 0..) |p, j| cp[j] = try arena.dup(p);
                        break :blk_p cp;
                    };
                    c[i] = .{
                        .name = try arena.dup(d.name),
                        .params = params,
                        .body = try copy_expr(arena, d.body, subs),
                    };
                }
                break :blk c;
            };
            lp.* = .{
                .defs = defs,
                .body = try copy_expr(arena, li.body, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .let_in = lp };
            return ptr;
        },
        .case_expr => |ce| {
            const cp = try arena.alloc_object(ast.CaseExpr);
            const arms: []const ast.CaseArm = if (ce.arms.len == 0) &[_]ast.CaseArm{} else blk: {
                const c = try arena.alloc(ast.CaseArm, ce.arms.len);
                for (ce.arms, 0..) |a, i| {
                    c[i] = .{
                        .cond = try copy_expr(arena, a.cond, subs),
                        .value = try copy_expr(arena, a.value, subs),
                    };
                }
                break :blk c;
            };
            cp.* = .{
                .arms = arms,
                .otherwise = if (ce.otherwise) |o| try copy_expr(arena, o, subs) else null,
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .case_expr = cp };
            return ptr;
        },
        .box_action => |ba| {
            const bp = try arena.alloc_object(ast.BoxAction);
            bp.* = .{
                .action_name = try arena.dup(ba.action_name),
                .vars = try copy_expr(arena, ba.vars, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .box_action = bp };
            return ptr;
        },
        .lambda => |l| {
            const lp = try arena.alloc_object(ast.Lambda);
            const params: []const []const u8 = if (l.params.len == 0) &[_][]const u8{} else blk: {
                const c = try arena.alloc([]const u8, l.params.len);
                for (l.params, 0..) |p, i| c[i] = try arena.dup(p);
                break :blk c;
            };
            lp.* = .{ .params = params, .body = try copy_expr(arena, l.body, subs) };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .lambda = lp };
            return ptr;
        },
        .quantifier => |q| {
            const qp = try arena.alloc_object(ast.Quantifier);
            const vars: []const ast.BoundVar = if (q.vars.len == 0) &[_]ast.BoundVar{} else blk: {
                const c = try arena.alloc(ast.BoundVar, q.vars.len);
                for (q.vars, 0..) |v, i| {
                    c[i] = .{
                        .name = try arena.dup(v.name),
                        .domain = try copy_expr(arena, v.domain, subs),
                    };
                }
                break :blk c;
            };
            qp.* = .{
                .kind = q.kind,
                .vars = vars,
                .body = try copy_expr(arena, q.body, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .quantifier = qp };
            return ptr;
        },
        .choose => |c| {
            const cp = try arena.alloc_object(ast.Choose);
            cp.* = .{
                .var_name = try arena.dup(c.var_name),
                .domain = try copy_expr(arena, c.domain, subs),
                .body = try copy_expr(arena, c.body, subs),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .choose = cp };
            return ptr;
        },
    }
}
