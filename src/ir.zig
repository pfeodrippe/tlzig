const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");

/// A resolved reference to a definition.  The body is pre-resolved to IrExpr.
pub const IrDef = struct {
    name: []const u8,
    /// Pre-resolved parameter names (for higher-order operators and lambdas).
    params: []const []const u8,
    body: *IrExpr,
    is_function: bool = false,
    function_var: []const u8 = "",
    function_domain: ?*IrExpr = null,
    /// True if this definition is a constant that has been evaluated to a Value.
    is_constant_value: bool = false,
};

/// Resolved scope entry — a local binding (quantifier var, lambda param, let binding).
pub const ScopeEntry = struct {
    name: []const u8,
    /// The depth at which this entry was bound (for shadowing).
    depth: u16,
    /// The local slot index within the current evaluation context.
    slot: u16,
};

/// The resolved expression IR.  Every identifier is pre-linked — no runtime
/// string lookups during evaluation.
pub const IrExpr = union(enum(u8)) {
    bool_literal: bool,
    int_literal: i64,
    string_literal: []const u8,

    /// A reference to a state variable by index.
    var_ref: u16,
    /// A primed state variable by index (evaluates against next_state).
    primed_var_ref: u16,
    /// A constant value by index.
    const_ref: u16,
    /// A definition reference — the body is already resolved.
    def_ref: *IrDef,
    /// A context-local binding (quantifier/lambda/let slot).
    local_ref: u16,
    /// A builtin operator used as a value (operator reference).
    builtin_ref: BuiltinOp,

    binary: *IrBinary,
    unary: *IrUnary,
    quantifier: *IrQuantifier,
    choose: *IrChoose,
    if_then_else: *IrIfThenElse,
    /// Function/operator application: calling a def, lambda, or builtin.
    apply: *IrApply,
    /// Record/tuple field access.
    field: *IrField,
    tuple: []const *IrExpr,
    record: []const IrFieldInit,
    set_enum: []const *IrExpr,
    set_filter: *IrSetFilter,
    set_map: *IrSetMap,
    set_binary: *IrSetBinary,
    set_of_functions: *IrSetOfFunctions,
    function_literal: *IrFunctionLiteral,
    record_set: *IrRecordSet,
    except: *IrExcept,
    let_in: *IrLetIn,
    case_expr: *IrCaseExpr,
    box_action: *IrBoxAction,
    lambda: *IrLambda,
    /// UNCHANGED <<vars>> — list of variable indices.
    unchanged: []const u16,
    /// The @ value in EXCEPT.
    at,
};

pub const BuiltinOp = enum(u8) {
    plus,
    minus,
    times,
    div,
    mod,
    power,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    and_op,
    or_op,
    implies,
    equiv,
    in,
    notin,
    subseteq,
    range,
    concat,
    ooverride,
    recordto,
    leads_to,
    union_op,
    intersection_op,
    difference_op,
    cartesian_op,
};

pub const IrBinaryOp = enum(u8) {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    implies,
    equiv,
    in,
    notin,
    subseteq,
    plus,
    minus,
    times,
    div,
    mod,
    power,
    range,
    concat,
    ooverride,
    recordto,
    leads_to,
};

pub const IrSetBinaryOp = enum(u8) { union_op, intersection_op, difference_op, cartesian_op };

pub const IrBinary = struct {
    op: IrBinaryOp,
    left: *IrExpr,
    right: *IrExpr,
};

pub const IrUnaryOp = enum(u8) {
    not,
    neg,
    subset,
    union_all,
    domain,
    temporal_box,
    temporal_diamond,
    enabled,
};

pub const IrUnary = struct {
    op: IrUnaryOp,
    operand: *IrExpr,
};

pub const IrQuantifier = struct {
    kind: ast.QuantifierKind,
    /// Each bound variable has a slot index and a resolved domain expression.
    vars: []const IrBoundVar,
    body: *IrExpr,
};

pub const IrBoundVar = struct {
    name: []const u8,
    slot: u16,
    domain: *IrExpr,
};

pub const IrChoose = struct {
    var_slot: u16,
    var_name: []const u8,
    domain: ?*IrExpr,
    body: *IrExpr,
};

pub const IrIfThenElse = struct {
    cond: *IrExpr,
    then_branch: *IrExpr,
    else_branch: *IrExpr,
};

pub const IrApply = struct {
    /// The function being applied — could be a def_ref, lambda, local_ref, etc.
    func: *IrExpr,
    args: []const *IrExpr,
};

pub const IrField = struct {
    expr: *IrExpr,
    name: []const u8,
};

pub const IrFieldInit = struct {
    name: []const u8,
    value: *IrExpr,
};

pub const IrSetFilter = struct {
    vars: []const IrBoundVar,
    pred: *IrExpr,
};

pub const IrSetMap = struct {
    vars: []const IrBoundVar,
    value: *IrExpr,
};

pub const IrSetBinary = struct {
    op: IrSetBinaryOp,
    left: *IrExpr,
    right: *IrExpr,
};

pub const IrSetOfFunctions = struct {
    domain: *IrExpr,
    codomain: *IrExpr,
};

pub const IrFunctionLiteral = struct {
    vars: []const IrBoundVar,
    body: *IrExpr,
};

pub const IrRecordFieldDomain = struct {
    name: []const u8,
    domain: *IrExpr,
};

pub const IrRecordSet = struct {
    fields: []const IrRecordFieldDomain,
};

pub const IrAccessStep = union(enum(u8)) {
    field: []const u8,
    index: *IrExpr,
};

pub const IrExcept = struct {
    func: *IrExpr,
    steps: []const IrAccessStep,
    value: *IrExpr,
};

pub const IrLetIn = struct {
    defs: []const IrDef,
    body: *IrExpr,
};

pub const IrCaseArm = struct {
    cond: *IrExpr,
    value: *IrExpr,
};

pub const IrCaseExpr = struct {
    arms: []const IrCaseArm,
    otherwise: ?*IrExpr,
};

pub const IrBoxAction = struct {
    action: *IrExpr,
    vars: *IrExpr,
};

pub const IrLambda = struct {
    /// Parameter names — each gets a local slot when the lambda is called.
    params: []const []const u8,
    body: *IrExpr,
};

/// A resolved module — all definitions have resolved bodies.
pub const IrModule = struct {
    name: []const u8,
    variables: []const []const u8,
    /// All definitions in the module, with bodies resolved to IrExpr.
    defs: []const IrDef,
};

// ---------------------------------------------------------------------------
// Resolver — walks AST and builds resolved IR.
// ---------------------------------------------------------------------------

pub const ResolveError = error{
    UndefinedSymbol,
    NotImplemented,
    OutOfMemory,
};

const Scope = struct {
    entries: std.ArrayList(Entry),

    const Entry = struct {
        name: []const u8,
        kind: Kind,
        depth: u16,

        const Kind = union(enum) {
            local: u16, // slot index
            def: *IrDef,
        };
    };

    fn init(alloc: std.mem.Allocator) Scope {
        return .{ .entries = std.ArrayList(Entry).init(alloc) };
    }
};

pub const Resolver = struct {
    arena: *Arena,
    variables: []const []const u8,
    /// All IrDef objects created during resolution.
    defs_list: std.ArrayList(*IrDef),
    /// Scope stack for local bindings.
    scope: Scope,
    next_slot: u16 = 0,
    depth: u16 = 0,
    alloc: std.mem.Allocator,

    pub fn init(arena: *Arena, variables: []const []const u8, module_defs: []const ast.Definition) !Resolver {
        var r = Resolver{
            .arena = arena,
            .variables = variables,
            .defs_list = std.ArrayList(*IrDef).init(std.heap.page_allocator),
            .scope = Scope.init(std.heap.page_allocator),
            .alloc = std.heap.page_allocator,
        };

        // Pre-create IrDef stubs for all module-level definitions so they can
        // reference each other (including recursively).
        for (module_defs) |d| {
            const ir_def = try arena.alloc_object(IrDef);
            ir_def.* = .{
                .name = d.name,
                .params = d.params,
                .body = undefined, // will be filled in resolve_module
                .is_function = d.is_function,
                .function_var = d.function_var,
                .function_domain = null, // will be resolved
            };
            try r.defs_list.append(ir_def);
        }
        return r;
    }

    pub fn deinit(self: *Resolver) void {
        self.defs_list.deinit();
        self.scope.entries.deinit();
    }

    fn find_def(self: *Resolver, name: []const u8) ?*IrDef {
        for (self.defs_list.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    fn find_var(self: *Resolver, name: []const u8) ?u16 {
        for (self.variables, 0..) |v, i| {
            if (std.mem.eql(u8, v, name)) return @intCast(i);
        }
        return null;
    }

    fn lookup_local(self: *Resolver, name: []const u8) ?u16 {
        var i = self.scope.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.scope.entries.items[i];
            if (std.mem.eql(u8, e.name, name)) {
                return switch (e.kind) {
                    .local => |slot| slot,
                    .def => null,
                };
            }
        }
        return null;
    }

    fn lookup_scope(self: *Resolver, name: []const u8) ?Scope.Entry.Kind {
        var i = self.scope.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.scope.entries.items[i];
            if (std.mem.eql(u8, e.name, name)) return e.kind;
        }
        return null;
    }

    fn push_local(self: *Resolver, name: []const u8) !u16 {
        const slot = self.next_slot;
        self.next_slot += 1;
        try self.scope.entries.append(.{
            .name = name,
            .kind = .{ .local = slot },
            .depth = self.depth,
        });
        return slot;
    }

    fn push_def_scope(self: *Resolver, d: *IrDef) !void {
        try self.scope.entries.append(.{
            .name = d.name,
            .kind = .{ .def = d },
            .depth = self.depth,
        });
    }

    fn push_scope(self: *Resolver) void {
        self.depth += 1;
    }

    fn pop_scope(self: *Resolver) void {
        assert(self.depth > 0);
        self.depth -= 1;
        // Remove entries at the current depth.
        while (self.scope.entries.items.len > 0) {
            const last = self.scope.entries.items[self.scope.entries.items.len - 1];
            if (last.depth > self.depth) {
                _ = self.scope.entries.pop();
            } else break;
        }
    }

    fn alloc_expr(self: *Resolver, e: IrExpr) !*IrExpr {
        const ptr = try self.arena.alloc_object(IrExpr);
        ptr.* = e;
        return ptr;
    }

    /// Resolve a full module: resolve all definition bodies.
    /// (Unused — resolution is done in resolve_all. Kept for API completeness.)
    pub fn resolve_module(self: *Resolver) !void {
        _ = self;
    }

    /// Resolve an AST expression into an IrExpr.
    pub fn resolve(self: *Resolver, expr: *ast.Expr) ResolveError!*IrExpr {
        assert(@intFromPtr(expr) != 0);
        switch (expr.*) {
            .bool_literal => |b| return try self.alloc_expr(.{ .bool_literal = b }),
            .int_literal => |i| return try self.alloc_expr(.{ .int_literal = i }),
            .string_literal => |s| return try self.alloc_expr(.{ .string_literal = s }),

            .ident => |name| {
                // Check scope first (locals shadow everything).
                if (self.lookup_scope(name)) |kind| {
                    return switch (kind) {
                        .local => |slot| try self.alloc_expr(.{ .local_ref = slot }),
                        .def => |d| try self.alloc_expr(.{ .def_ref = d }),
                    };
                }
                if (self.find_var(name)) |idx| {
                    return try self.alloc_expr(.{ .var_ref = idx });
                }
                if (self.find_def(name)) |d| {
                    return try self.alloc_expr(.{ .def_ref = d });
                }
                // Check for builtin operator references.
                if (builtin_op_from_name(name)) |bop| {
                    return try self.alloc_expr(.{ .builtin_ref = bop });
                }
                // Unknown symbol — could be a model value or override.
                // For now, leave as a string literal placeholder that the
                // evaluator will resolve. This preserves backward compatibility.
                return try self.alloc_expr(.{ .string_literal = name });
            },

            .primed => |name| {
                if (self.find_var(name)) |idx| {
                    return try self.alloc_expr(.{ .primed_var_ref = idx });
                }
                return try self.alloc_expr(.{ .string_literal = name });
            },
            .primed_expr => return error.NotImplemented,

            .unchanged => |names| {
                const indices = try self.arena.alloc(u16, names.len);
                for (names, 0..) |n, i| {
                    indices[i] = self.find_var(n) orelse 0;
                }
                return try self.alloc_expr(.{ .unchanged = indices });
            },
            .unchanged_expr => return error.NotImplemented,

            .binary => |b| {
                const left = try self.resolve(b.left);
                const right = try self.resolve(b.right);
                const op = ir_binary_op(b.op);
                const irb = try self.arena.alloc_object(IrBinary);
                irb.* = .{ .op = op, .left = left, .right = right };
                return try self.alloc_expr(.{ .binary = irb });
            },

            .unary => |u| {
                const operand = try self.resolve(u.operand);
                const op = ir_unary_op(u.op);
                const iru = try self.arena.alloc_object(IrUnary);
                iru.* = .{ .op = op, .operand = operand };
                return try self.alloc_expr(.{ .unary = iru });
            },

            .if_then_else => |ite| {
                const cond = try self.resolve(ite.cond);
                const then_b = try self.resolve(ite.then_branch);
                const else_b = try self.resolve(ite.else_branch);
                const irite = try self.arena.alloc_object(IrIfThenElse);
                irite.* = .{ .cond = cond, .then_branch = then_b, .else_branch = else_b };
                return try self.alloc_expr(.{ .if_then_else = irite });
            },

            .tuple => |items| {
                const resolved = try self.arena.alloc(*IrExpr, items.len);
                for (items, 0..) |it, i| {
                    resolved[i] = try self.resolve(it);
                }
                return try self.alloc_expr(.{ .tuple = resolved });
            },

            .record => |fields| {
                const resolved = try self.arena.alloc(IrFieldInit, fields.len);
                for (fields, 0..) |f, i| {
                    resolved[i] = .{
                        .name = f.name,
                        .value = try self.resolve(f.value),
                    };
                }
                return try self.alloc_expr(.{ .record = resolved });
            },

            .set_enum => |items| {
                const resolved = try self.arena.alloc(*IrExpr, items.len);
                for (items, 0..) |it, i| {
                    resolved[i] = try self.resolve(it);
                }
                return try self.alloc_expr(.{ .set_enum = resolved });
            },

            .set_filter => |sf| {
                self.push_scope();
                const vars = try self.arena.alloc(IrBoundVar, sf.vars.len);
                for (sf.vars, 0..) |v, i| {
                    const slot = try self.push_local(v.name);
                    vars[i] = .{
                        .name = v.name,
                        .slot = slot,
                        .domain = try self.resolve(v.domain),
                    };
                }
                const pred = try self.resolve(sf.pred);
                self.pop_scope();
                const irsf = try self.arena.alloc_object(IrSetFilter);
                irsf.* = .{ .vars = vars, .pred = pred };
                return try self.alloc_expr(.{ .set_filter = irsf });
            },

            .set_map => |sm| {
                self.push_scope();
                const vars = try self.arena.alloc(IrBoundVar, sm.vars.len);
                for (sm.vars, 0..) |v, i| {
                    const slot = try self.push_local(v.name);
                    vars[i] = .{
                        .name = v.name,
                        .slot = slot,
                        .domain = try self.resolve(v.domain),
                    };
                }
                const value = try self.resolve(sm.value);
                self.pop_scope();
                const irsm = try self.arena.alloc_object(IrSetMap);
                irsm.* = .{ .vars = vars, .value = value };
                return try self.alloc_expr(.{ .set_map = irsm });
            },

            .set_binary => |sb| {
                const left = try self.resolve(sb.left);
                const right = try self.resolve(sb.right);
                const op: IrSetBinaryOp = switch (sb.op) {
                    .union_op => .union_op,
                    .intersection_op => .intersection_op,
                    .difference_op => .difference_op,
                    .cartesian_op => .cartesian_op,
                };
                const irsb = try self.arena.alloc_object(IrSetBinary);
                irsb.* = .{ .op = op, .left = left, .right = right };
                return try self.alloc_expr(.{ .set_binary = irsb });
            },

            .set_of_functions => |sf| {
                const domain = try self.resolve(sf.domain);
                const codomain = try self.resolve(sf.codomain);
                const irsf = try self.arena.alloc_object(IrSetOfFunctions);
                irsf.* = .{ .domain = domain, .codomain = codomain };
                return try self.alloc_expr(.{ .set_of_functions = irsf });
            },

            .function_literal => |fl| {
                self.push_scope();
                const vars = try self.arena.alloc(IrBoundVar, fl.vars.len);
                for (fl.vars, 0..) |v, i| {
                    const slot = try self.push_local(v.name);
                    vars[i] = .{
                        .name = v.name,
                        .slot = slot,
                        .domain = try self.resolve(v.domain),
                    };
                }
                const body = try self.resolve(fl.body);
                self.pop_scope();
                const irfl = try self.arena.alloc_object(IrFunctionLiteral);
                irfl.* = .{ .vars = vars, .body = body };
                return try self.alloc_expr(.{ .function_literal = irfl });
            },

            .record_set => |rs| {
                const fields = try self.arena.alloc(IrRecordFieldDomain, rs.fields.len);
                for (rs.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = f.name,
                        .domain = try self.resolve(f.domain),
                    };
                }
                const irrs = try self.arena.alloc_object(IrRecordSet);
                irrs.* = .{ .fields = fields };
                return try self.alloc_expr(.{ .record_set = irrs });
            },

            .except => |ex| {
                const func = try self.resolve(ex.func);
                const steps = try self.arena.alloc(IrAccessStep, ex.steps.len);
                for (ex.steps, 0..) |s, i| {
                    steps[i] = switch (s) {
                        .field => |fname| .{ .field = fname },
                        .index => |e| .{ .index = try self.resolve(e) },
                    };
                }
                const value = try self.resolve(ex.value);
                const irex = try self.arena.alloc_object(IrExcept);
                irex.* = .{ .func = func, .steps = steps, .value = value };
                return try self.alloc_expr(.{ .except = irex });
            },

            .quantifier => |q| {
                self.push_scope();
                const vars = try self.arena.alloc(IrBoundVar, q.vars.len);
                for (q.vars, 0..) |v, i| {
                    const slot = try self.push_local(v.name);
                    vars[i] = .{
                        .name = v.name,
                        .slot = slot,
                        .domain = try self.resolve(v.domain),
                    };
                }
                const body = try self.resolve(q.body);
                self.pop_scope();
                const irq = try self.arena.alloc_object(IrQuantifier);
                irq.* = .{ .kind = q.kind, .vars = vars, .body = body };
                return try self.alloc_expr(.{ .quantifier = irq });
            },

            .choose => |c| {
                self.push_scope();
                const slot = try self.push_local(c.var_name);
                const domain: ?*IrExpr = if (c.domain) |d| try self.resolve(d) else null;
                const body = try self.resolve(c.body);
                self.pop_scope();
                const irc = try self.arena.alloc_object(IrChoose);
                irc.* = .{
                    .var_slot = slot,
                    .var_name = c.var_name,
                    .domain = domain,
                    .body = body,
                };
                return try self.alloc_expr(.{ .choose = irc });
            },

            .apply => |ap| {
                const func = try self.resolve(ap.func);
                const args = try self.arena.alloc(*IrExpr, ap.args.len);
                for (ap.args, 0..) |a, i| {
                    args[i] = try self.resolve(a);
                }
                const irap = try self.arena.alloc_object(IrApply);
                irap.* = .{ .func = func, .args = args };
                return try self.alloc_expr(.{ .apply = irap });
            },

            .field => |f| {
                const e = try self.resolve(f.expr);
                const irf = try self.arena.alloc_object(IrField);
                irf.* = .{ .expr = e, .name = f.name };
                return try self.alloc_expr(.{ .field = irf });
            },

            .let_in => |li| {
                self.push_scope();
                // Create heap-allocated IrDefs for let bindings so they can be
                // referenced by pointer in the scope (for recursion).
                const def_ptrs = try self.alloc.alloc(*IrDef, li.defs.len);
                for (li.defs, 0..) |d, i| {
                    def_ptrs[i] = try self.arena.alloc_object(IrDef);
                    def_ptrs[i].* = .{
                        .name = d.name,
                        .params = d.params,
                        .body = undefined,
                        .is_function = d.is_function,
                        .function_var = d.function_var,
                    };
                    // Add to scope so body can reference it (recursion).
                    try self.scope.entries.append(.{
                        .name = d.name,
                        .kind = .{ .def = def_ptrs[i] },
                        .depth = self.depth,
                    });
                    // Resolve body.
                    def_ptrs[i].body = try self.resolve_definition_body(d);
                }
                const body = try self.resolve(li.body);
                self.pop_scope();
                // Build the defs slice from the heap-allocated pointers.
                const defs_slice = try self.arena.alloc(IrDef, li.defs.len);
                for (def_ptrs, 0..) |dp, i| defs_slice[i] = dp.*;
                const irli = try self.arena.alloc_object(IrLetIn);
                irli.* = .{ .defs = defs_slice, .body = body };
                return try self.alloc_expr(.{ .let_in = irli });
            },

            .case_expr => |ce| {
                const arms = try self.arena.alloc(IrCaseArm, ce.arms.len);
                for (ce.arms, 0..) |arm, i| {
                    arms[i] = .{
                        .cond = try self.resolve(arm.cond),
                        .value = try self.resolve(arm.value),
                    };
                }
                const otherwise: ?*IrExpr = if (ce.otherwise) |o| try self.resolve(o) else null;
                const irce = try self.arena.alloc_object(IrCaseExpr);
                irce.* = .{ .arms = arms, .otherwise = otherwise };
                return try self.alloc_expr(.{ .case_expr = irce });
            },

            .box_action => |ba| {
                const action = try self.resolve(ba.action);
                const vars = try self.resolve(ba.vars);
                const irba = try self.arena.alloc_object(IrBoxAction);
                irba.* = .{ .action = action, .vars = vars };
                return try self.alloc_expr(.{ .box_action = irba });
            },

            .lambda => |l| {
                self.push_scope();
                // We need to resolve the body with params in scope, but params
                // get their slots at call time. For now, push locals for params
                // and record the slots.
                const params = try self.arena.alloc([]const u8, l.params.len);
                for (l.params, 0..) |p, i| {
                    const slot = try self.push_local(p);
                    params[i] = p;
                    _ = slot;
                }
                const body = try self.resolve(l.body);
                self.pop_scope();
                const irl = try self.arena.alloc_object(IrLambda);
                irl.* = .{ .params = params, .body = body };
                return try self.alloc_expr(.{ .lambda = irl });
            },

            .at => return try self.alloc_expr(.at),
        }
    }

    fn resolve_definition_body(self: *Resolver, d: ast.Definition) !*IrExpr {
        if (d.is_function) {
            // Recursive function: F[x \in S] == body
            // Resolve as a function literal.
            self.push_scope();
            const slot = try self.push_local(d.function_var);
            const domain = if (d.function_domain) |dom| try self.resolve(dom) else {
                self.pop_scope();
                return error.UndefinedSymbol;
            };
            const body = try self.resolve(d.body);
            self.pop_scope();
            const vars = try self.arena.alloc(IrBoundVar, 1);
            vars[0] = .{
                .name = d.function_var,
                .slot = slot,
                .domain = domain,
            };
            const irfl = try self.arena.alloc_object(IrFunctionLiteral);
            irfl.* = .{ .vars = vars, .body = body };
            return try self.alloc_expr(.{ .function_literal = irfl });
        }
        return try self.resolve(d.body);
    }

    /// Resolve all module definitions and return the completed IrModule.
    pub fn resolve_all(self: *Resolver, module_defs: []const ast.Definition) !IrModule {
        // The stubs are already in defs_list from init().
        // Push all defs into scope.
        for (self.defs_list.items) |d| {
            try self.scope.entries.append(.{
                .name = d.name,
                .kind = .{ .def = d },
                .depth = 0,
            });
        }
        // Resolve each definition body.
        for (module_defs, 0..) |d, i| {
            const ir_def = self.defs_list.items[i];
            ir_def.body = try self.resolve_definition_body(d);
        }
        const defs = try self.arena.alloc(IrDef, self.defs_list.items.len);
        for (self.defs_list.items, defs) |source, *target| {
            target.* = source.*;
        }
        return IrModule{
            .name = "",
            .variables = self.variables,
            .defs = defs,
        };
    }
};

fn ir_binary_op(op: ast.BinaryOp) IrBinaryOp {
    return switch (op) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .and_op => .and_op,
        .or_op => .or_op,
        .implies => .implies,
        .equiv => .equiv,
        .in => .in,
        .notin => .notin,
        .subseteq => .subseteq,
        .plus => .plus,
        .minus => .minus,
        .times => .times,
        .div => .div,
        .mod => .mod,
        .power => .power,
        .range => .range,
        .concat => .concat,
        .ooverride => .ooverride,
        .recordto => .recordto,
        .leads_to => .leads_to,
    };
}

fn ir_unary_op(op: ast.UnaryOp) IrUnaryOp {
    return switch (op) {
        .not => .not,
        .neg => .neg,
        .subset => .subset,
        .union_all => .union_all,
        .domain => .domain,
        .temporal_box => .temporal_box,
        .temporal_diamond => .temporal_diamond,
        .enabled => .enabled,
    };
}

fn builtin_op_from_name(name: []const u8) ?BuiltinOp {
    const map = std.static_string_map.StaticStringMap(BuiltinOp).initComptime(.{
        .{ "+", .plus },
        .{ "-", .minus },
        .{ "*", .times },
        .{ "/", .div },
        .{ "\\", .difference_op },
        .{ "^", .power },
        .{ "<", .lt },
        .{ "<=", .le },
        .{ ">", .gt },
        .{ ">=", .ge },
        .{ "=", .eq },
        .{ "#", .ne },
        .{ "..", .range },
        .{ "\\o", .concat },
        .{ "\\cup", .union_op },
        .{ "\\cap", .intersection_op },
        .{ "\\X", .cartesian_op },
        .{ "\\in", .in },
        .{ "\\notin", .notin },
        .{ "\\subseteq", .subseteq },
    });
    return map.get(name);
}

test "resolve_all exports resolved definition bodies" {
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE IrResolve ----------------------
        \\A == 1
        \\B == A + 1
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    var resolver = try Resolver.init(
        &arena,
        module.variables,
        module.definitions,
    );
    defer resolver.deinit();
    const resolved = try resolver.resolve_all(module.definitions);

    try std.testing.expectEqual(@as(usize, 2), resolved.defs.len);
    try std.testing.expectEqualStrings("A", resolved.defs[0].name);
    try std.testing.expectEqualStrings("B", resolved.defs[1].name);
    try std.testing.expect(resolved.defs[0].body.* == .int_literal);
    try std.testing.expect(resolved.defs[1].body.* == .binary);
    try std.testing.expect(
        resolved.defs[1].body.binary.left.* == .def_ref,
    );
}
