const std = @import("std");
const ast = @import("ast.zig");
const overrides = @import("overrides.zig");

pub const Result = struct {
    source: []const u8,
    generated_count: u32,
    native_count: u32,
    fallback_count: u32,
    unsupported: []const []const u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.unsupported);
    }
};

pub const Options = struct {
    extra_roots: []const []const u8 = &.{},
    type_invariants: []const []const u8 = &.{},
};

const DefinitionKind = enum {
    generated,
    native,
    unsupported,
};

const GeneratedExpressionMeta = struct {
    expression: *const ast.Expr,
    params: [32][]const u8,
    param_count: u8,
    identity: u32,

    fn param_slice(self: *const GeneratedExpressionMeta) []const []const u8 {
        return self.params[0..self.param_count];
    }
};

pub fn emit_module(
    allocator: std.mem.Allocator,
    module: ast.Module,
) !Result {
    return emit_module_with_roots(allocator, module, &.{});
}

pub fn emit_module_with_roots(
    allocator: std.mem.Allocator,
    module: ast.Module,
    extra_roots: []const []const u8,
) !Result {
    return emit_module_with_options(allocator, module, .{
        .extra_roots = extra_roots,
    });
}

pub fn emit_module_with_options(
    allocator: std.mem.Allocator,
    module: ast.Module,
    options: Options,
) !Result {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const reachable = try compute_reachable(
        allocator,
        module,
        options.extra_roots,
    );
    defer allocator.free(reachable);

    try append(&output, allocator,
        \\const std = @import("std");
        \\const tlzig = @import("tlzig");
        \\const Value = tlzig.value.Value;
        \\const Error = tlzig.Error;
        \\const runtime = tlzig.generated_runtime;
        \\
    );
    const module_metadata = try std.fmt.allocPrint(
        allocator,
        "pub const module_name = \"{f}\";\n" ++
            "pub const config_replacements_hash: u64 = 0x{x};\n" ++
            "pub const root_names = [_][]const u8{{",
        .{
            std.zig.fmtString(module.name),
            config_replacements_hash(module.config_replacements),
        },
    );
    defer allocator.free(module_metadata);
    try append(&output, allocator, module_metadata);
    for (options.extra_roots, 0..) |root, index| {
        const separator = if (index == 0) "" else ", ";
        const root_metadata = try std.fmt.allocPrint(
            allocator,
            "{s}\"{f}\"",
            .{ separator, std.zig.fmtString(root) },
        );
        defer allocator.free(root_metadata);
        try append(&output, allocator, root_metadata);
    }
    try append(&output, allocator, "};\n\n");
    try append(&output, allocator, "pub const type_invariant_names = [_][]const u8{");
    for (options.type_invariants, 0..) |name, index| {
        const separator = if (index == 0) "" else ", ";
        const invariant_metadata = try std.fmt.allocPrint(
            allocator,
            "{s}\"{f}\"",
            .{ separator, std.zig.fmtString(name) },
        );
        defer allocator.free(invariant_metadata);
        try append(&output, allocator, invariant_metadata);
    }
    try append(&output, allocator, "};\n\n");

    var generated_count: u32 = 0;
    var native_count: u32 = 0;
    var fallback_count: u32 = 0;
    var unsupported = std.ArrayList([]const u8).empty;
    defer unsupported.deinit(allocator);
    var generated_expressions =
        std.ArrayList(GeneratedExpressionMeta).empty;
    defer generated_expressions.deinit(allocator);
    var emitted_helpers = std.StringHashMap(void).init(allocator);
    defer {
        var key_iterator = emitted_helpers.keyIterator();
        while (key_iterator.next()) |key| allocator.free(key.*);
        emitted_helpers.deinit();
    }
    for (module.definitions, 0..) |definition, definition_index| {
        if (!reachable[definition_index]) continue;
        switch (definition_kind(module, definition)) {
            .generated => {
                generated_count += 1;
                try emit_operator(
                    &output,
                    allocator,
                    module,
                    definition,
                    definition_index,
                );
            },
            .native => native_count += 1,
            .unsupported => {
                fallback_count += 1;
                try unsupported.append(allocator, definition.name);
            },
        }
    }
    var expression_index: usize = 0;
    for (module.definitions, 0..) |definition, definition_index| {
        try collect_generated_expressions(
            allocator,
            module,
            definition.body,
            definition.params,
            reachable[definition_index],
            &expression_index,
            &generated_expressions,
        );
        if (definition.function_domain) |domain| {
            try collect_generated_expressions(
                allocator,
                module,
                domain,
                definition.params,
                false,
                &expression_index,
                &generated_expressions,
            );
        }
    }
    for (module.assumptions) |assumption| {
        try collect_generated_expressions(
            allocator,
            module,
            assumption,
            &.{},
            false,
            &expression_index,
            &generated_expressions,
        );
    }
    for (module.definitions, 0..) |definition, definition_index| {
        if (reachable[definition_index] and
            operator_supported(module, definition, 0))
        {
            try emit_helpers(
                &output,
                allocator,
                module,
                definition.body,
                definition.params,
                &emitted_helpers,
            );
        }
    }
    for (generated_expressions.items) |entry| {
        const expression_params = entry.param_slice();
        try emit_helpers(
            &output,
            allocator,
            module,
            entry.expression,
            expression_params,
            &emitted_helpers,
        );
        const header = try std.fmt.allocPrint(
            allocator,
            "fn expr_{d}(context: *runtime.CallContext, args: []const Value) Error!Value {{\n" ++
                "    std.debug.assert(args.len == {d});\n" ++
                "    runtime.keep_expression_parameters(context, args);\n" ++
                "    return ",
            .{ entry.identity, expression_params.len },
        );
        defer allocator.free(header);
        try append(&output, allocator, header);
        if (expr_is_boolean(module, entry.expression, 0)) {
            try append(
                &output,
                allocator,
                "Value{ .bool_v = try ",
            );
            const bool_name = try expression_boolean_name(
                allocator,
                entry.identity,
            );
            defer allocator.free(bool_name);
            try append(&output, allocator, bool_name);
            try append(&output, allocator, "(context, args) }");
        } else {
            try emit_expr(
                &output,
                allocator,
                module,
                entry.expression,
                expression_params,
            );
        }
        try append(&output, allocator, ";\n}\n\n");
        if (expr_is_boolean(module, entry.expression, 0)) {
            const bool_header = try std.fmt.allocPrint(
                allocator,
                "fn expr_{d}_bool(context: *runtime.CallContext, args: []const Value) Error!bool {{\n" ++
                    "    std.debug.assert(args.len == {d});\n" ++
                    "    runtime.keep_expression_parameters(context, args);\n" ++
                    "    return ",
                .{ entry.identity, expression_params.len },
            );
            defer allocator.free(bool_header);
            try append(&output, allocator, bool_header);
            try emit_boolean_expr(
                &output,
                allocator,
                module,
                entry.expression,
                expression_params,
            );
            try append(&output, allocator, ";\n}\n\n");
        }
    }

    try append(&output, allocator,
        \\pub const operators = [_]runtime.Operator{
        \\
    );
    for (module.definitions, 0..) |definition, definition_index| {
        if (!reachable[definition_index]) continue;
        const supported = definition_kind(module, definition) == .generated;
        if (!supported) continue;
        const function_name = try zig_operator_name(allocator, definition_index);
        defer allocator.free(function_name);
        const line = try std.fmt.allocPrint(
            allocator,
            "    .{{ .name = \"{f}\", .arity = {d}, .function = {s} }},\n",
            .{
                std.zig.fmtString(definition.name),
                definition.params.len,
                if (supported) function_name else "null",
            },
        );
        defer allocator.free(line);
        try append(&output, allocator, line);
    }
    try append(&output, allocator, "};\n");
    try append(&output, allocator,
        \\pub const expressions = [_]runtime.Expression{
        \\
    );
    for (generated_expressions.items) |entry| {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "    .{{ .identity = {d}, .arg_names = &[_][]const u8{{",
            .{entry.identity},
        );
        defer allocator.free(prefix);
        try append(&output, allocator, prefix);
        const expression_params = entry.param_slice();
        for (expression_params, 0..) |param, param_index_v| {
            if (param_index_v > 0) try append(&output, allocator, ", ");
            const name = try std.fmt.allocPrint(
                allocator,
                "\"{f}\"",
                .{std.zig.fmtString(param)},
            );
            defer allocator.free(name);
            try append(&output, allocator, name);
        }
        const suffix = try std.fmt.allocPrint(
            allocator,
            "}}, .arg_required = &[_]bool{{",
            .{},
        );
        defer allocator.free(suffix);
        try append(&output, allocator, suffix);
        for (expression_params, 0..) |param, param_index_v| {
            if (param_index_v > 0) try append(&output, allocator, ", ");
            try append(
                &output,
                allocator,
                if (expr_references_identifier(
                    entry.expression,
                    param,
                ))
                    "true"
                else
                    "false",
            );
        }
        const expression_suffix = if (expr_is_boolean(
            module,
            entry.expression,
            0,
        ))
            try std.fmt.allocPrint(
                allocator,
                "}}, .function = expr_{d}, .boolean_function = expr_{d}_bool }},\n",
                .{ entry.identity, entry.identity },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "}}, .function = expr_{d} }},\n",
                .{entry.identity},
            );
        defer allocator.free(expression_suffix);
        try append(&output, allocator, expression_suffix);
    }
    try append(&output, allocator, "};\n");
    const coverage = try std.fmt.allocPrint(
        allocator,
        "pub const generated_count: u32 = {d};\n" ++
            "pub const native_count: u32 = {d};\n" ++
            "pub const fallback_count: u32 = {d};\n",
        .{ generated_count, native_count, fallback_count },
    );
    defer allocator.free(coverage);
    try append(&output, allocator, coverage);

    return .{
        .source = try output.toOwnedSlice(allocator),
        .generated_count = generated_count,
        .native_count = native_count,
        .fallback_count = fallback_count,
        .unsupported = try allocator.dupe(
            []const u8,
            unsupported.items,
        ),
    };
}

fn definition_kind(
    module: ast.Module,
    definition: ast.Definition,
) DefinitionKind {
    if (!is_codegen_definition_name(definition.name) or
        is_native_override(definition.name))
    {
        return .native;
    }
    if (expr_is_temporal(module, definition.body, 0)) return .native;
    return if (operator_supported(module, definition, 0))
        .generated
    else
        .unsupported;
}

fn config_replacements_hash(
    replacements: []const ast.ConfigReplacement,
) u64 {
    var hasher = std.hash.Wyhash.init(0x544c_5a49_475f_4347);
    for (replacements) |replacement| {
        hash_bytes(&hasher, replacement.name);
        hash_bytes(&hasher, replacement.value);
        hasher.update(&.{if (replacement.is_substitution) 1 else 0});
        hasher.update(&.{switch (replacement.kind) {
            .alias => 1,
            .constant => 2,
        }});
    }
    return hasher.final();
}

fn hash_bytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    const len: u64 = bytes.len;
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

fn definition_is_boolean(
    module: ast.Module,
    definition: ast.Definition,
) bool {
    return expr_is_boolean(module, definition.body, 0);
}

fn definition_context_free(
    module: ast.Module,
    definition: ast.Definition,
) bool {
    if (definition.params.len != 0) return false;
    return expr_context_free(module, definition.body, 0);
}

fn expr_context_free(
    module: ast.Module,
    expr: *const ast.Expr,
    depth: u32,
) bool {
    if (depth > 64) return false;
    return switch (expr.*) {
        .bool_literal,
        .int_literal,
        .string_literal,
        .at,
        => true,
        .ident => |name| blk: {
            if (variable_index(module, name) != null) break :blk false;
            const resolved_name = resolved_definition_name(
                module,
                name,
            ) orelse break :blk true;
            const definition = find_definition(module, resolved_name) orelse
                break :blk true;
            break :blk expr_context_free(module, definition.body, depth + 1);
        },
        .primed,
        .primed_expr,
        .unchanged,
        .unchanged_expr,
        .box_action,
        => false,
        .field => |field_value| expr_context_free(
            module,
            field_value.expr,
            depth + 1,
        ),
        .tuple, .set_enum => |items| blk: {
            for (items) |item| {
                if (!expr_context_free(module, item, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .record => |fields| blk: {
            for (fields) |field_value| {
                if (!expr_context_free(module, field_value.value, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .set_filter => |filter_value| blk: {
            for (filter_value.vars) |bound| {
                if (!expr_context_free(module, bound.domain, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk expr_context_free(module, filter_value.pred, depth + 1);
        },
        .set_map => |map_value| blk: {
            for (map_value.vars) |bound| {
                if (!expr_context_free(module, bound.domain, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk expr_context_free(module, map_value.value, depth + 1);
        },
        .set_binary => |set_binary| expr_context_free(
            module,
            set_binary.left,
            depth + 1,
        ) and expr_context_free(module, set_binary.right, depth + 1),
        .set_of_functions => |function_set| expr_context_free(
            module,
            function_set.domain,
            depth + 1,
        ) and expr_context_free(module, function_set.codomain, depth + 1),
        .function_literal => |function_literal| blk: {
            for (function_literal.vars) |bound| {
                if (!expr_context_free(module, bound.domain, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk expr_context_free(
                module,
                function_literal.body,
                depth + 1,
            );
        },
        .record_set => |record_set_value| blk: {
            for (record_set_value.fields) |field_value| {
                if (!expr_context_free(module, field_value.domain, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .unary => |unary| expr_context_free(module, unary.operand, depth + 1),
        .binary => |binary| expr_context_free(
            module,
            binary.left,
            depth + 1,
        ) and expr_context_free(module, binary.right, depth + 1),
        .quantifier => |quantifier| blk: {
            for (quantifier.vars) |bound| {
                if (!expr_context_free(module, bound.domain, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk expr_context_free(module, quantifier.body, depth + 1);
        },
        .choose => |choose_value| blk: {
            if (choose_value.domain) |domain| {
                if (!expr_context_free(module, domain, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk expr_context_free(module, choose_value.body, depth + 1);
        },
        .if_then_else => |conditional| expr_context_free(
            module,
            conditional.cond,
            depth + 1,
        ) and expr_context_free(
            module,
            conditional.then_branch,
            depth + 1,
        ) and expr_context_free(module, conditional.else_branch, depth + 1),
        .apply => |application| blk: {
            if (variable_application_index(module, application) != null) {
                break :blk false;
            }
            if (!expr_context_free(module, application.func, depth + 1)) {
                break :blk false;
            }
            for (application.args) |argument| {
                if (!expr_context_free(module, argument, depth + 1)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .except => |except_value| blk: {
            if (!expr_context_free(module, except_value.func, depth + 1)) {
                break :blk false;
            }
            for (except_value.steps) |step| {
                if (step == .index and
                    !expr_context_free(module, step.index, depth + 1))
                {
                    break :blk false;
                }
            }
            break :blk expr_context_free(module, except_value.value, depth + 1);
        },
        .let_in => |let_value| blk: {
            for (let_value.defs) |local_definition| {
                if (!expr_context_free(module, local_definition.body, depth + 1)) {
                    break :blk false;
                }
                if (local_definition.function_domain) |domain| {
                    if (!expr_context_free(module, domain, depth + 1)) {
                        break :blk false;
                    }
                }
            }
            break :blk expr_context_free(module, let_value.body, depth + 1);
        },
        .case_expr => |case_value| blk: {
            for (case_value.arms) |arm| {
                if (!expr_context_free(module, arm.cond, depth + 1) or
                    !expr_context_free(module, arm.value, depth + 1))
                {
                    break :blk false;
                }
            }
            if (case_value.otherwise) |otherwise| {
                break :blk expr_context_free(module, otherwise, depth + 1);
            }
            break :blk true;
        },
        .lambda => |lambda_value| expr_context_free(
            module,
            lambda_value.body,
            depth + 1,
        ),
    };
}

fn expr_is_boolean(
    module: ast.Module,
    expr: *const ast.Expr,
    depth: u32,
) bool {
    if (depth > 64) return false;
    return switch (expr.*) {
        .bool_literal,
        .quantifier,
        .unchanged,
        .unchanged_expr,
        => true,
        .binary => |binary| switch (binary.op) {
            .eq,
            .ne,
            .lt,
            .le,
            .gt,
            .ge,
            .and_op,
            .or_op,
            .implies,
            .equiv,
            .in,
            .notin,
            .subseteq,
            => true,
            else => false,
        },
        .unary => |unary| unary.op == .not,
        .if_then_else => |conditional| expr_is_boolean(
            module,
            conditional.then_branch,
            depth + 1,
        ) and expr_is_boolean(
            module,
            conditional.else_branch,
            depth + 1,
        ),
        .case_expr => |case_value| blk: {
            for (case_value.arms) |arm| {
                if (!expr_is_boolean(module, arm.value, depth + 1)) {
                    break :blk false;
                }
            }
            if (case_value.otherwise) |otherwise| {
                break :blk expr_is_boolean(
                    module,
                    otherwise,
                    depth + 1,
                );
            }
            break :blk true;
        },
        .let_in => |let_value| expr_is_boolean(
            module,
            let_value.body,
            depth + 1,
        ),
        .ident => |name| blk: {
            const definition = find_definition(module, name) orelse
                break :blk false;
            if (definition.params.len != 0) break :blk false;
            break :blk expr_is_boolean(
                module,
                definition.body,
                depth + 1,
            );
        },
        .apply => |application| blk: {
            if (application.func.* != .ident) break :blk false;
            const definition = find_definition(
                module,
                application.func.ident,
            ) orelse break :blk false;
            break :blk expr_is_boolean(
                module,
                definition.body,
                depth + 1,
            );
        },
        else => false,
    };
}

fn expr_is_temporal(
    module: ast.Module,
    expr: *const ast.Expr,
    depth: u32,
) bool {
    if (depth > 64) return false;
    return switch (expr.*) {
        .box_action => true,
        .unary => |unary| switch (unary.op) {
            .temporal_box, .temporal_diamond => true,
            else => expr_is_temporal(module, unary.operand, depth + 1),
        },
        .binary => |binary| binary.op == .leads_to or
            expr_is_temporal(module, binary.left, depth + 1) or
            expr_is_temporal(module, binary.right, depth + 1),
        .quantifier => |quantifier| expr_is_temporal(
            module,
            quantifier.body,
            depth + 1,
        ),
        .if_then_else => |conditional| expr_is_temporal(
            module,
            conditional.cond,
            depth + 1,
        ) or expr_is_temporal(
            module,
            conditional.then_branch,
            depth + 1,
        ) or expr_is_temporal(
            module,
            conditional.else_branch,
            depth + 1,
        ),
        .ident => |name| blk: {
            const resolved_name = resolved_definition_name(
                module,
                name,
            ) orelse break :blk false;
            const definition = find_definition(module, resolved_name) orelse
                break :blk false;
            break :blk expr_is_temporal(
                module,
                definition.body,
                depth + 1,
            );
        },
        else => false,
    };
}

fn emit_operator(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    definition: ast.Definition,
    definition_index: usize,
) !void {
    const function_name = try zig_operator_name(allocator, definition_index);
    defer allocator.free(function_name);
    const source_path = if (definition.source_path.len > 0)
        definition.source_path
    else
        module.name;
    const provenance = try std.fmt.allocPrint(
        allocator,
        "// TLA+ source: {s}:{d}\n// TLA+ operator: {s}",
        .{ source_path, definition.source_line, definition.name },
    );
    defer allocator.free(provenance);
    try append(output, allocator, provenance);
    if (definition.params.len > 0) {
        try append(output, allocator, "(");
        for (definition.params, 0..) |parameter, index| {
            if (index > 0) try append(output, allocator, ", ");
            try append(output, allocator, parameter);
        }
        try append(output, allocator, ")");
    }
    try append(output, allocator, "\n");
    if (definition.source_excerpt.len > 0) {
        const excerpt = try std.fmt.allocPrint(
            allocator,
            "// TLA+ declaration: {s}\n",
            .{definition.source_excerpt},
        );
        defer allocator.free(excerpt);
        try append(output, allocator, excerpt);
    }
    const header = try std.fmt.allocPrint(
        allocator,
        "pub fn {s}(context: *runtime.CallContext, args: []const Value) Error!Value {{\n" ++
            "    std.debug.assert(args.len == {d});\n" ++
            "    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);\n",
        .{ function_name, definition.params.len },
    );
    defer allocator.free(header);
    try append(output, allocator, header);
    if (definition_is_boolean(module, definition)) {
        const boolean_name = try zig_boolean_operator_name(
            allocator,
            definition_index,
        );
        defer allocator.free(boolean_name);
        const wrapper = try std.fmt.allocPrint(
            allocator,
            "    return Value{{ .bool_v = try {s}(context, args) }};\n" ++
                "}}\n\n" ++
                "fn {s}(context: *runtime.CallContext, args: []const Value) Error!bool {{\n" ++
                "    std.debug.assert(args.len == {d});\n" ++
                "    runtime.keep_expression_parameters(context, args);\n",
            .{
                boolean_name,
                boolean_name,
                definition.params.len,
            },
        );
        defer allocator.free(wrapper);
        try append(output, allocator, wrapper);
        try emit_boolean_function_body(
            output,
            allocator,
            module,
            definition.body,
            definition.params,
        );
        try append(output, allocator, "}\n\n");
        return;
    }
    if (definition_context_free(module, definition)) {
        const cache_prefix = try std.fmt.allocPrint(
            allocator,
            "    if (try runtime.cached_definition(context, {d})) |cached| return cached;\n" ++
                "    const result = ",
            .{definition_index},
        );
        defer allocator.free(cache_prefix);
        try append(output, allocator, cache_prefix);
        try emit_expr(
            output,
            allocator,
            module,
            definition.body,
            definition.params,
        );
        const cache_suffix = try std.fmt.allocPrint(
            allocator,
            ";\n    return try runtime.put_cached_definition(context, {d}, result);\n",
            .{definition_index},
        );
        defer allocator.free(cache_suffix);
        try append(output, allocator, cache_suffix);
        try append(output, allocator, "}\n\n");
        return;
    }
    try emit_function_body(
        output,
        allocator,
        module,
        definition.body,
        definition.params,
    );
    try append(output, allocator, "}\n\n");
}

fn emit_boolean_function_body(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    body: *const ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!void {
    if (body.* == .binary and
        (body.binary.op == .and_op or body.binary.op == .or_op))
    {
        var operands: [256]*const ast.Expr = undefined;
        var operand_count: usize = 0;
        flatten_boolean_operands(
            body,
            body.binary.op,
            &operands,
            &operand_count,
        );
        for (operands[0..operand_count], 0..) |operand, index| {
            if (try emit_boolean_unchanged_guards(
                output,
                allocator,
                module,
                operand,
                body.binary.op,
            )) continue;
            const prefix = try std.fmt.allocPrint(
                allocator,
                "    const condition_{d} = ",
                .{index},
            );
            defer allocator.free(prefix);
            try append(output, allocator, prefix);
            try emit_boolean_expr(
                output,
                allocator,
                module,
                operand,
                params,
            );
            try append(output, allocator, ";\n");
            const branch = if (body.binary.op == .and_op)
                try std.fmt.allocPrint(
                    allocator,
                    "    if (!condition_{d}) return false;\n",
                    .{index},
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "    if (condition_{d}) return true;\n",
                    .{index},
                );
            defer allocator.free(branch);
            try append(output, allocator, branch);
        }
        try append(
            output,
            allocator,
            if (body.binary.op == .and_op)
                "    return true;\n"
            else
                "    return false;\n",
        );
        return;
    }
    try append(output, allocator, "    return ");
    try emit_boolean_expr(output, allocator, module, body, params);
    try append(output, allocator, ";\n");
}

fn emit_boolean_expr(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!void {
    switch (expr.*) {
        .bool_literal => |value| {
            try append(output, allocator, if (value) "true" else "false");
        },
        .ident => |name| {
            if (find_definition_index(module, name)) |index| {
                const definition = module.definitions[index];
                if (definition.params.len == 0 and
                    !is_native_override(name) and
                    definition_kind(module, definition) == .generated and
                    definition_is_boolean(module, definition))
                {
                    const function_name = try zig_boolean_operator_name(
                        allocator,
                        index,
                    );
                    defer allocator.free(function_name);
                    const call = try std.fmt.allocPrint(
                        allocator,
                        "try {s}(context, &.{{}})",
                        .{function_name},
                    );
                    defer allocator.free(call);
                    try append(output, allocator, call);
                    return;
                }
            }
            try append(output, allocator, "try runtime.boolean(");
            try emit_expr(output, allocator, module, expr, params);
            try append(output, allocator, ")");
        },
        .apply => |application| {
            if (application.func.* == .ident) {
                if (find_definition_index(
                    module,
                    application.func.ident,
                )) |index| {
                    const definition = module.definitions[index];
                    if (!is_native_override(application.func.ident) and
                        definition_kind(module, definition) == .generated and
                        definition_is_boolean(module, definition))
                    {
                        const function_name =
                            try zig_boolean_operator_name(
                                allocator,
                                index,
                            );
                        defer allocator.free(function_name);
                        const prefix = try std.fmt.allocPrint(
                            allocator,
                            "try {s}(context, &[_]Value{{",
                            .{function_name},
                        );
                        defer allocator.free(prefix);
                        try append(output, allocator, prefix);
                        for (application.args, 0..) |argument, arg_index| {
                            if (arg_index > 0) {
                                try append(output, allocator, ", ");
                            }
                            try emit_expr(
                                output,
                                allocator,
                                module,
                                argument,
                                params,
                            );
                        }
                        try append(output, allocator, "})");
                        return;
                    }
                }
            }
            try append(output, allocator, "try runtime.boolean(");
            try emit_expr(output, allocator, module, expr, params);
            try append(output, allocator, ")");
        },
        .binary => |binary| {
            switch (binary.op) {
                .and_op, .or_op, .implies, .equiv => {
                    if (binary.op == .implies) {
                        try append(output, allocator, "!(");
                    } else {
                        try append(output, allocator, "(");
                    }
                    try emit_boolean_expr(
                        output,
                        allocator,
                        module,
                        binary.left,
                        params,
                    );
                    try append(
                        output,
                        allocator,
                        switch (binary.op) {
                            .and_op => ") and (",
                            .or_op => ") or (",
                            .implies => ") or (",
                            .equiv => ") == (",
                            else => unreachable,
                        },
                    );
                    try emit_boolean_expr(
                        output,
                        allocator,
                        module,
                        binary.right,
                        params,
                    );
                    try append(output, allocator, ")");
                },
                .eq,
                .ne,
                .lt,
                .le,
                .gt,
                .ge,
                .in,
                .notin,
                .subseteq,
                => {
                    if (binary.op == .in or binary.op == .notin) {
                        if (try emit_string_literal_set_membership(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                            .boolean,
                        )) return;
                        if (try emit_field_path_membership(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                        )) return;
                        if (try emit_variable_path_membership(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                        )) return;
                    }
                    if (binary.op == .eq or binary.op == .ne) {
                        if (try emit_primed_except_update_comparison(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                        )) return;
                        if (try emit_field_path_comparison(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                        )) return;
                        if (try emit_variable_path_comparison(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                        )) return;
                        if (try emit_variable_comparison(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                        )) return;
                    }
                    const function_name = switch (binary.op) {
                        .eq => "equal_bool",
                        .ne => "not_equal_bool",
                        .lt => "less_than_bool",
                        .le => "less_equal_bool",
                        .gt => "greater_than_bool",
                        .ge => "greater_equal_bool",
                        .in => "member_bool",
                        .notin => "not_member_bool",
                        .subseteq => "subset_equal_bool",
                        else => unreachable,
                    };
                    const prefix = if (binary.op == .in or
                        binary.op == .notin or
                        binary.op == .subseteq)
                        try std.fmt.allocPrint(
                            allocator,
                            "try runtime.{s}(context, ",
                            .{function_name},
                        )
                    else
                        try std.fmt.allocPrint(
                            allocator,
                            "try runtime.{s}(context.eval_pool, ",
                            .{function_name},
                        );
                    defer allocator.free(prefix);
                    try append(output, allocator, prefix);
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.left,
                        params,
                    );
                    try append(output, allocator, ", ");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.right,
                        params,
                    );
                    try append(output, allocator, ")");
                },
                else => unreachable,
            }
        },
        .unary => |unary| {
            if (unary.op == .not) {
                try append(output, allocator, "!(");
                try emit_boolean_expr(
                    output,
                    allocator,
                    module,
                    unary.operand,
                    params,
                );
                try append(output, allocator, ")");
                return;
            }
            unreachable;
        },
        .if_then_else => |conditional| {
            try append(output, allocator, "if (");
            try emit_boolean_expr(
                output,
                allocator,
                module,
                conditional.cond,
                params,
            );
            try append(output, allocator, ") ");
            try emit_boolean_expr(
                output,
                allocator,
                module,
                conditional.then_branch,
                params,
            );
            try append(output, allocator, " else ");
            try emit_boolean_expr(
                output,
                allocator,
                module,
                conditional.else_branch,
                params,
            );
        },
        .let_in => {
            const helper = try let_boolean_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            const call = try std.fmt.allocPrint(
                allocator,
                "try {s}(context, args)",
                .{helper},
            );
            defer allocator.free(call);
            try append(output, allocator, call);
        },
        .quantifier => {
            try append(output, allocator, "try runtime.boolean(");
            try emit_expr(output, allocator, module, expr, params);
            try append(output, allocator, ")");
        },
        .unchanged => |names| {
            if (names.len == 0) {
                try append(output, allocator, "true");
                return;
            }
            try emit_unchanged_terms(output, allocator, module, names);
        },
        .unchanged_expr => |tuple_expr| {
            var names = try allocator.alloc([]const u8, tuple_expr.tuple.len);
            defer allocator.free(names);
            for (tuple_expr.tuple, 0..) |item, index| {
                names[index] = item.ident;
            }
            try emit_unchanged_terms(output, allocator, module, names);
        },
        .field => {
            if (try emit_field_path_boolean(
                output,
                allocator,
                module,
                expr,
                params,
            )) return;
            try append(output, allocator, "try runtime.boolean(");
            try emit_expr(output, allocator, module, expr, params);
            try append(output, allocator, ")");
        },
        else => {
            try append(output, allocator, "try runtime.boolean(");
            try emit_expr(output, allocator, module, expr, params);
            try append(output, allocator, ")");
        },
    }
}

fn emit_expr(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!void {
    switch (expr.*) {
        .bool_literal => |value| try append(
            output,
            allocator,
            if (value)
                "Value{ .bool_v = true }"
            else
                "Value{ .bool_v = false }",
        ),
        .int_literal => |value| {
            const text = try std.fmt.allocPrint(
                allocator,
                "Value{{ .int_v = {d} }}",
                .{value},
            );
            defer allocator.free(text);
            try append(output, allocator, text);
        },
        .string_literal => |value| {
            const text = try std.fmt.allocPrint(
                allocator,
                "try runtime.string(context, \"{f}\")",
                .{std.zig.fmtString(value)},
            );
            defer allocator.free(text);
            try append(output, allocator, text);
        },
        .ident => |name| {
            const text = if (param_index(params, name)) |index|
                try std.fmt.allocPrint(allocator, "args[{d}]", .{index})
            else if (variable_index(module, name)) |index|
                try std.fmt.allocPrint(
                    allocator,
                    "try runtime.variable(context, {d})",
                    .{index},
                )
            else if (resolved_config_symbol(module, name)) |symbol|
                switch (symbol) {
                    .constant => |constant_name| try std.fmt.allocPrint(
                        allocator,
                        "try runtime.constant(context, \"{f}\")",
                        .{std.zig.fmtString(constant_name)},
                    ),
                    .name => |resolved_name| if (constant_index(
                        module,
                        resolved_name,
                    )) |index|
                        try std.fmt.allocPrint(
                            allocator,
                            "try runtime.constant_at(context, {d})",
                            .{index},
                        )
                    else if (builtin_value_runtime_name(resolved_name)) |runtime_name|
                        try std.fmt.allocPrint(
                            allocator,
                            "try runtime.{s}(context)",
                            .{runtime_name},
                        )
                    else if (find_definition_index(
                        module,
                        resolved_name,
                    )) |index| blk: {
                        const definition = module.definitions[index];
                        break :blk if (definition.params.len == 0)
                            try std.fmt.allocPrint(
                                allocator,
                                "try op_{d}(context, &.{{}})",
                                .{index},
                            )
                        else
                            try std.fmt.allocPrint(
                                allocator,
                                "try runtime.operator(context, op_{d}, {d}, &.{{}})",
                                .{ index, definition.params.len },
                            );
                    } else unreachable,
                }
            else if (constant_index(module, name)) |index|
                try std.fmt.allocPrint(
                    allocator,
                    "try runtime.constant_at(context, {d})",
                    .{index},
                )
            else if (builtin_value_runtime_name(name)) |runtime_name|
                try std.fmt.allocPrint(
                    allocator,
                    "try runtime.{s}(context)",
                    .{runtime_name},
                )
            else if (find_definition_index(module, name)) |index| blk: {
                const definition = module.definitions[index];
                break :blk if (definition.params.len == 0)
                    try std.fmt.allocPrint(
                        allocator,
                        "try op_{d}(context, &.{{}})",
                        .{index},
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "try runtime.operator(context, op_{d}, {d}, &.{{}})",
                        .{ index, definition.params.len },
                    );
            } else unreachable;
            defer allocator.free(text);
            try append(output, allocator, text);
        },
        .primed => |name| {
            const text = if (variable_index(module, name)) |index|
                try std.fmt.allocPrint(
                    allocator,
                    "try runtime.primed_variable(context, {d})",
                    .{index},
                )
            else blk: {
                const resolved_name = resolved_definition_name(
                    module,
                    name,
                ) orelse unreachable;
                const index = find_definition_index(
                    module,
                    resolved_name,
                ) orelse unreachable;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "try runtime.primed_expression(context, &.{{}}, op_{d})",
                    .{index},
                );
            };
            defer allocator.free(text);
            try append(output, allocator, text);
        },
        .primed_expr => {
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try append(
                output,
                allocator,
                "try runtime.primed_expression(context, args, ",
            );
            try append(output, allocator, helper);
            try append(output, allocator, ")");
        },
        .unchanged => |names| try emit_unchanged(
            output,
            allocator,
            module,
            names,
        ),
        .unchanged_expr => |unchanged_expr| {
            try emit_unchanged_tuple(
                output,
                allocator,
                module,
                unchanged_expr,
            );
        },
        .field => |field| {
            try append(output, allocator, "try runtime.field(context, ");
            try emit_expr(
                output,
                allocator,
                module,
                field.expr,
                params,
            );
            const suffix = try std.fmt.allocPrint(
                allocator,
                ", \"{f}\")",
                .{std.zig.fmtString(field.name)},
            );
            defer allocator.free(suffix);
            try append(output, allocator, suffix);
        },
        .tuple => |items| try emit_value_array(
            output,
            allocator,
            module,
            "tuple",
            items,
            params,
        ),
        .set_enum => |items| try emit_value_array(
            output,
            allocator,
            module,
            "set",
            items,
            params,
        ),
        .record => |fields| {
            try append(
                output,
                allocator,
                "try runtime.record(context, &[_]Value{",
            );
            for (fields, 0..) |field, index| {
                if (index > 0) try append(output, allocator, ", ");
                const key = try std.fmt.allocPrint(
                    allocator,
                    "try runtime.string(context, \"{f}\"), ",
                    .{std.zig.fmtString(field.name)},
                );
                defer allocator.free(key);
                try append(output, allocator, key);
                try emit_expr(
                    output,
                    allocator,
                    module,
                    field.value,
                    params,
                );
            }
            try append(output, allocator, "})");
        },
        .set_binary => |set_binary| {
            if (try emit_permutations_union(
                output,
                allocator,
                module,
                expr,
                params,
            )) return;
            const function_name = switch (set_binary.op) {
                .union_op => "set_union",
                .intersection_op => "set_intersection",
                .difference_op => "set_difference",
                .cartesian_op => "cartesian_product",
            };
            const prefix = try std.fmt.allocPrint(
                allocator,
                "try runtime.{s}(context, ",
                .{function_name},
            );
            defer allocator.free(prefix);
            try append(output, allocator, prefix);
            try emit_expr(
                output,
                allocator,
                module,
                set_binary.left,
                params,
            );
            try append(output, allocator, ", ");
            try emit_expr(
                output,
                allocator,
                module,
                set_binary.right,
                params,
            );
            try append(output, allocator, ")");
        },
        .function_literal => |function_literal| {
            const dependent = expr_references_identifier(
                function_literal.body,
                function_literal.vars[0].name,
            );
            try append(output, allocator, if (dependent)
                "try runtime.function_map(context, args, "
            else
                "try runtime.constant_function(context, ");
            try emit_expr(
                output,
                allocator,
                module,
                function_literal.vars[0].domain,
                params,
            );
            try append(output, allocator, ", ");
            if (dependent) {
                const helper = try helper_name(
                    allocator,
                    expression_identity(module, expr),
                );
                defer allocator.free(helper);
                try append(output, allocator, helper);
            } else {
                try emit_expr(
                    output,
                    allocator,
                    module,
                    function_literal.body,
                    params,
                );
            }
            try append(output, allocator, ")");
        },
        .quantifier => |quantifier| {
            if (filtered_power_set_domain(
                module,
                quantifier,
            )) |filtered| {
                if (quantifier.kind == .exists) {
                    if (carrier_of_cartesian(module, filtered.base)) |carrier| {
                        const filter_node = filtered.filter_expr.set_filter;
                        const relation_name = filter_node.vars[0].name;
                        if (is_total_order_filter(
                            module,
                            filter_node.pred,
                            relation_name,
                            carrier,
                        )) {
                            try append(
                                output,
                                allocator,
                                "try runtime.exists_total_order_relation(context, args, ",
                            );
                            try emit_expr(
                                output,
                                allocator,
                                module,
                                filtered.base,
                                params,
                            );
                            const predicate_helper = try helper_name(
                                allocator,
                                expression_identity(module, expr),
                            );
                            defer allocator.free(predicate_helper);
                            const suffix = try std.fmt.allocPrint(
                                allocator,
                                ", {s})",
                                .{predicate_helper},
                            );
                            defer allocator.free(suffix);
                            try append(output, allocator, suffix);
                            return;
                        }
                    }
                }
                try append(
                    output,
                    allocator,
                    "try runtime.quantify_filtered_power_set(context, args, ",
                );
                try emit_expr(
                    output,
                    allocator,
                    module,
                    filtered.base,
                    params,
                );
                const filter_helper = try helper_name(
                    allocator,
                    expression_identity(module, filtered.filter_expr),
                );
                defer allocator.free(filter_helper);
                const predicate_helper = try helper_name(
                    allocator,
                    expression_identity(module, expr),
                );
                defer allocator.free(predicate_helper);
                const suffix = try std.fmt.allocPrint(
                    allocator,
                    ", .{s}, {s}, {s})",
                    .{
                        if (quantifier.kind == .exists)
                            "exists"
                        else
                            "forall",
                        filter_helper,
                        predicate_helper,
                    },
                );
                defer allocator.free(suffix);
                try append(output, allocator, suffix);
                return;
            }
            if (quantifier_constant_domain_index(module, quantifier)) |constant_domain_index| {
                const helper = try helper_name(
                    allocator,
                    expression_identity(module, expr),
                );
                defer allocator.free(helper);
                const call = try std.fmt.allocPrint(
                    allocator,
                    "try runtime.quantify_constant_at(context, args, {d}, .{s}, {s}, {d})",
                    .{
                        constant_domain_index,
                        if (quantifier.kind == .exists)
                            "exists"
                        else
                            "forall",
                        helper,
                        expression_identity(module, expr),
                    },
                );
                defer allocator.free(call);
                try append(output, allocator, call);
                return;
            }
            try append(output, allocator, "try runtime.quantify_at(context, args, &[_]Value{");
            for (quantifier.vars, 0..) |bound, index| {
                if (index > 0) try append(output, allocator, ", ");
                try emit_expr(
                    output,
                    allocator,
                    module,
                    bound.domain,
                    params,
                );
            }
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            const suffix = try std.fmt.allocPrint(
                allocator,
                "}}, .{s}, {s}, {d})",
                .{
                    if (quantifier.kind == .exists)
                        "exists"
                    else
                        "forall",
                    helper,
                    expression_identity(module, expr),
                },
            );
            defer allocator.free(suffix);
            try append(output, allocator, suffix);
        },
        .set_filter => |filter_value| {
            try append(output, allocator, "try runtime.filter_at(context, args, ");
            try emit_expr(
                output,
                allocator,
                module,
                filter_value.vars[0].domain,
                params,
            );
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try append(output, allocator, ", ");
            try append(output, allocator, helper);
            const suffix = try std.fmt.allocPrint(
                allocator,
                ", {d})",
                .{expression_identity(module, expr)},
            );
            defer allocator.free(suffix);
            try append(output, allocator, suffix);
        },
        .set_map => |map_value| {
            try append(output, allocator, "try runtime.map_set(context, args, ");
            try emit_expr(
                output,
                allocator,
                module,
                map_value.vars[0].domain,
                params,
            );
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try append(output, allocator, ", ");
            try append(output, allocator, helper);
            try append(output, allocator, ")");
        },
        .choose => |choose_value| {
            try append(output, allocator, "try runtime.choose(context, args, ");
            try emit_expr(
                output,
                allocator,
                module,
                choose_value.domain.?,
                params,
            );
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try append(output, allocator, ", ");
            try append(output, allocator, helper);
            const suffix = try std.fmt.allocPrint(
                allocator,
                ", {d})",
                .{expression_identity(module, expr)},
            );
            defer allocator.free(suffix);
            try append(output, allocator, suffix);
        },
        .let_in => |let_value| {
            try append(
                output,
                allocator,
                "try runtime.let_expression(context, args, &[_]runtime.LetDefinition{",
            );
            for (let_value.defs, 0..) |definition, index| {
                if (index > 0) try append(output, allocator, ", ");
                const helper = try let_helper_name(
                    allocator,
                    expression_identity(module, expr),
                    index,
                );
                defer allocator.free(helper);
                const entry = try std.fmt.allocPrint(
                    allocator,
                    ".{{ .function = {s}, .arity = {d} }}",
                    .{ helper, definition.params.len },
                );
                defer allocator.free(entry);
                try append(output, allocator, entry);
            }
            const body_helper = try let_body_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(body_helper);
            try append(output, allocator, "}, ");
            try append(output, allocator, body_helper);
            try append(output, allocator, ")");
        },
        .except => |except_value| {
            try append(
                output,
                allocator,
                "try runtime.except_update(context, args, ",
            );
            try emit_expr(
                output,
                allocator,
                module,
                except_value.func,
                params,
            );
            try append(output, allocator, ", &[_]Value{");
            for (except_value.steps, 0..) |step, index| {
                if (index > 0) try append(output, allocator, ", ");
                switch (step) {
                    .field => |field_name| {
                        const field = try std.fmt.allocPrint(
                            allocator,
                            "try runtime.string(context, \"{f}\")",
                            .{std.zig.fmtString(field_name)},
                        );
                        defer allocator.free(field);
                        try append(output, allocator, field);
                    },
                    .index => |index_expr| try emit_expr(
                        output,
                        allocator,
                        module,
                        index_expr,
                        params,
                    ),
                }
            }
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try append(output, allocator, "}, ");
            try append(output, allocator, helper);
            try append(output, allocator, ")");
        },
        .at => {
            std.debug.assert(params.len > 0);
            const text = try std.fmt.allocPrint(
                allocator,
                "args[{d}]",
                .{params.len - 1},
            );
            defer allocator.free(text);
            try append(output, allocator, text);
        },
        .set_of_functions => |function_set| {
            try append(
                output,
                allocator,
                "try runtime.function_set(context, ",
            );
            try emit_expr(
                output,
                allocator,
                module,
                function_set.domain,
                params,
            );
            try append(output, allocator, ", ");
            try emit_expr(
                output,
                allocator,
                module,
                function_set.codomain,
                params,
            );
            try append(output, allocator, ")");
        },
        .record_set => |record_set| {
            try append(
                output,
                allocator,
                "try runtime.record_set(context, &[_]Value{",
            );
            for (record_set.fields, 0..) |field, index| {
                if (index > 0) try append(output, allocator, ", ");
                const key = try std.fmt.allocPrint(
                    allocator,
                    "try runtime.string(context, \"{f}\"), ",
                    .{std.zig.fmtString(field.name)},
                );
                defer allocator.free(key);
                try append(output, allocator, key);
                try emit_expr(
                    output,
                    allocator,
                    module,
                    field.domain,
                    params,
                );
            }
            try append(output, allocator, "})");
        },
        .unary => |unary| {
            try append(
                output,
                allocator,
                switch (unary.op) {
                    .not => "try runtime.logical_not(",
                    .neg => "try runtime.negate(",
                    .subset => "try runtime.power_set(context, ",
                    .union_all => "try runtime.union_all(context, ",
                    .domain => "try runtime.domain(context, ",
                    else => unreachable,
                },
            );
            try emit_expr(
                output,
                allocator,
                module,
                unary.operand,
                params,
            );
            try append(output, allocator, ")");
        },
        .binary => |binary| {
            switch (binary.op) {
                .and_op => {
                    try append(output, allocator, "if (try runtime.boolean(");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.left,
                        params,
                    );
                    try append(output, allocator, ")) ");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.right,
                        params,
                    );
                    try append(
                        output,
                        allocator,
                        " else Value{ .bool_v = false }",
                    );
                },
                .or_op => {
                    try append(output, allocator, "if (try runtime.boolean(");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.left,
                        params,
                    );
                    try append(
                        output,
                        allocator,
                        ")) Value{ .bool_v = true } else ",
                    );
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.right,
                        params,
                    );
                },
                .implies => {
                    try append(output, allocator, "if (try runtime.boolean(");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.left,
                        params,
                    );
                    try append(output, allocator, ")) ");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.right,
                        params,
                    );
                    try append(
                        output,
                        allocator,
                        " else Value{ .bool_v = true }",
                    );
                },
                else => {
                    if (binary.op == .in or binary.op == .notin) {
                        if (try emit_string_literal_set_membership(
                            output,
                            allocator,
                            module,
                            binary,
                            params,
                            .value,
                        )) return;
                    }
                    try append(output, allocator, binary_runtime(binary.op));
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.left,
                        params,
                    );
                    try append(output, allocator, ", ");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        binary.right,
                        params,
                    );
                    try append(output, allocator, ")");
                },
            }
        },
        .if_then_else => |conditional| {
            try append(output, allocator, "if (try runtime.boolean(");
            try emit_expr(
                output,
                allocator,
                module,
                conditional.cond,
                params,
            );
            try append(output, allocator, ")) ");
            try emit_expr(
                output,
                allocator,
                module,
                conditional.then_branch,
                params,
            );
            try append(output, allocator, " else ");
            try emit_expr(
                output,
                allocator,
                module,
                conditional.else_branch,
                params,
            );
        },
        .apply => |application| {
            if (application.func.* == .ident) {
                if (constant_substitution_name(
                    module,
                    application.func.*.ident,
                )) |constant_name| {
                    const text = try std.fmt.allocPrint(
                        allocator,
                        "try runtime.constant(context, \"{f}\")",
                        .{std.zig.fmtString(constant_name)},
                    );
                    defer allocator.free(text);
                    try append(output, allocator, text);
                    return;
                }
                if (std.mem.eql(u8, application.func.ident, "Cardinality") and
                    application.args.len == 1)
                {
                    if (expr_constant_index(module, application.args[0])) |index| {
                        const text = try std.fmt.allocPrint(
                            allocator,
                            "try runtime.constant_cardinality_at(context, {d})",
                            .{index},
                        );
                        defer allocator.free(text);
                        try append(output, allocator, text);
                        return;
                    }
                }
            }
            if (is_select_sequence_call(application)) {
                try append(
                    output,
                    allocator,
                    "try runtime.select_sequence(context, args, ",
                );
                try emit_expr(
                    output,
                    allocator,
                    module,
                    application.args[0],
                    params,
                );
                const helper = try helper_name(
                    allocator,
                    expression_identity(module, application.args[1]),
                );
                defer allocator.free(helper);
                try append(output, allocator, ", ");
                try append(output, allocator, helper);
                try append(output, allocator, ")");
                return;
            }
            if (is_reduce_sequence_call(application)) {
                const lambda = application.args[0].*.lambda;
                try append(
                    output,
                    allocator,
                    "try runtime.reduce_sequence(context, args, ",
                );
                try emit_expr(
                    output,
                    allocator,
                    module,
                    application.args[1],
                    params,
                );
                try append(output, allocator, ", ");
                try emit_expr(
                    output,
                    allocator,
                    module,
                    application.args[2],
                    params,
                );
                const helper = try helper_name(
                    allocator,
                    expression_identity(module, application.args[0]),
                );
                defer allocator.free(helper);
                try append(output, allocator, ", ");
                try append(output, allocator, helper);
                try append(output, allocator, ")");
                std.debug.assert(lambda.params.len == 2);
                return;
            }
            if (variable_application_index(
                module,
                application,
            )) |variable| {
                const prefix = try std.fmt.allocPrint(
                    allocator,
                    "try runtime.variable_path(context, {d}, &[_]Value{{",
                    .{variable},
                );
                defer allocator.free(prefix);
                try append(output, allocator, prefix);
                try emit_variable_application_keys(
                    output,
                    allocator,
                    module,
                    application,
                    params,
                );
                try append(output, allocator, "})");
                return;
            }
            const target_name = if (application.func.* == .ident)
                resolved_definition_name(
                    module,
                    application.func.*.ident,
                )
            else
                null;
            const target = if (target_name) |name|
                find_definition(module, name)
            else
                null;
            if (target) |definition| {
                if (definition.params.len != application.args.len) {
                    std.debug.assert(definition.params.len == 0);
                    const definition_index = find_definition_index(
                        module,
                        definition.name,
                    ).?;
                    const function_name = try zig_operator_name(
                        allocator,
                        definition_index,
                    );
                    defer allocator.free(function_name);
                    const prefix = try std.fmt.allocPrint(
                        allocator,
                        "try runtime.call(context, try {s}(context, &.{{}}), &[_]Value{{",
                        .{function_name},
                    );
                    defer allocator.free(prefix);
                    try append(output, allocator, prefix);
                    for (application.args, 0..) |argument, index| {
                        if (index > 0) try append(output, allocator, ", ");
                        try emit_expr(
                            output,
                            allocator,
                            module,
                            argument,
                            params,
                        );
                    }
                    try append(output, allocator, "})");
                    return;
                }
                if (definition_kind(module, definition) == .generated) {
                    const definition_index = find_definition_index(
                        module,
                        definition.name,
                    ).?;
                    const function_name = try zig_operator_name(
                        allocator,
                        definition_index,
                    );
                    defer allocator.free(function_name);
                    try append(output, allocator, "try ");
                    try append(output, allocator, function_name);
                    try append(output, allocator, "(context, &[_]Value{");
                } else if (direct_native_name(definition.name)) |native_name| {
                    const prefix = try std.fmt.allocPrint(
                        allocator,
                        "try runtime.{s}(context, &[_]Value{{",
                        .{native_name},
                    );
                    defer allocator.free(prefix);
                    try append(output, allocator, prefix);
                } else {
                    const prefix = try std.fmt.allocPrint(
                        allocator,
                        "try runtime.native(context, \"{f}\", &[_]Value{{",
                        .{std.zig.fmtString(definition.name)},
                    );
                    defer allocator.free(prefix);
                    try append(output, allocator, prefix);
                }
                for (application.args, 0..) |argument, index| {
                    if (index > 0) try append(output, allocator, ", ");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        argument,
                        params,
                    );
                }
                try append(output, allocator, "})");
            } else {
                if (application.func.* == .ident) {
                    if (direct_native_name(application.func.ident)) |native_name| {
                        const prefix = try std.fmt.allocPrint(
                            allocator,
                            "try runtime.{s}(context, &[_]Value{{",
                            .{native_name},
                        );
                        defer allocator.free(prefix);
                        try append(output, allocator, prefix);
                        for (application.args, 0..) |argument, index| {
                            if (index > 0) try append(output, allocator, ", ");
                            try emit_expr(
                                output,
                                allocator,
                                module,
                                argument,
                                params,
                            );
                        }
                        try append(output, allocator, "})");
                        return;
                    }
                }
                try append(output, allocator, "try runtime.call(context, ");
                try emit_expr(
                    output,
                    allocator,
                    module,
                    application.func,
                    params,
                );
                try append(output, allocator, ", &[_]Value{");
                for (application.args, 0..) |argument, index| {
                    if (index > 0) try append(output, allocator, ", ");
                    try emit_expr(
                        output,
                        allocator,
                        module,
                        argument,
                        params,
                    );
                }
                try append(output, allocator, "})");
            }
        },
        else => unreachable,
    }
}

fn emit_permutations_union(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
) !bool {
    var domains = std.ArrayList(*const ast.Expr).empty;
    defer domains.deinit(allocator);
    collect_permutations_union_domains(expr, &domains, allocator) catch
        return false;
    if (domains.items.len < 2) return false;
    try append(
        output,
        allocator,
        "try runtime.permutations_union(context, &[_]Value{",
    );
    for (domains.items, 0..) |domain, index| {
        if (index > 0) try append(output, allocator, ", ");
        try emit_expr(output, allocator, module, domain, params);
    }
    try append(output, allocator, "})");
    return true;
}

fn collect_permutations_union_domains(
    expr: *const ast.Expr,
    domains: *std.ArrayList(*const ast.Expr),
    allocator: std.mem.Allocator,
) error{ OutOfMemory, NotPermutationUnion }!void {
    switch (expr.*) {
        .set_binary => |set_binary| {
            if (set_binary.op != .union_op) return error.NotPermutationUnion;
            try collect_permutations_union_domains(
                set_binary.left,
                domains,
                allocator,
            );
            try collect_permutations_union_domains(
                set_binary.right,
                domains,
                allocator,
            );
        },
        .apply => |application| {
            if (application.func.* != .ident or
                !std.mem.eql(u8, application.func.ident, "Permutations") or
                application.args.len != 1)
            {
                return error.NotPermutationUnion;
            }
            try domains.append(allocator, application.args[0]);
        },
        else => return error.NotPermutationUnion,
    }
}

fn operator_supported(
    module: ast.Module,
    definition: ast.Definition,
    depth: u32,
) bool {
    if (depth > 64 or
        definition.is_function or
        definition_kind_shallow(definition) != .generated)
    {
        return false;
    }
    return expr_supported(
        module,
        definition.body,
        definition.params,
        depth,
    );
}

fn definition_kind_shallow(definition: ast.Definition) DefinitionKind {
    if (!is_codegen_definition_name(definition.name) or
        is_native_override(definition.name))
    {
        return .native;
    }
    if (definition.is_function) return .unsupported;
    return .generated;
}

fn is_codegen_definition_name(name: []const u8) bool {
    if (name.len == 0 or
        !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
    {
        return false;
    }
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or
            byte == '_' or
            byte == '!'))
        {
            return false;
        }
    }
    return true;
}

fn is_native_override(name: []const u8) bool {
    if (std.mem.eql(u8, name, "TLCEval")) return true;
    const registry = overrides.default_registry(
        overrides.OverrideContext.default(),
    );
    return registry.find(name) != null or
        registry.find_value(name) != null;
}

fn native_operator(name: []const u8) bool {
    const registry = overrides.default_registry(
        overrides.OverrideContext.default(),
    );
    return registry.find(name) != null;
}

fn expr_supported(
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
    depth: u32,
) bool {
    return expr_supported_impl(
        module,
        expr,
        params,
        depth,
    );
}

fn expr_supported_impl(
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
    depth: u32,
) bool {
    return switch (expr.*) {
        .bool_literal, .int_literal, .string_literal => true,
        .ident => |name| param_index(params, name) != null or
            variable_index(module, name) != null or
            constant_index(module, name) != null or
            definition_value_supported(
                module,
                name,
                depth,
            ),
        .primed => |name| variable_index(module, name) != null or blk: {
            const resolved_name = resolved_definition_name(
                module,
                name,
            ) orelse break :blk false;
            const definition = find_definition(
                module,
                resolved_name,
            ) orelse break :blk false;
            const supported = definition.params.len == 0 and
                operator_supported(module, definition, depth + 1);
            break :blk supported;
        },
        .primed_expr => |operand| expr_supported(
            module,
            operand,
            params,
            depth,
        ),
        .unchanged => |names| variable_names_supported(module, names),
        .unchanged_expr => |unchanged_expr| unchanged_tuple_supported(module, unchanged_expr),
        .tuple, .set_enum => |items| expressions_supported(
            module,
            items,
            params,
            depth,
        ),
        .record => |fields| blk: {
            for (fields) |field| {
                if (!expr_supported(
                    module,
                    field.value,
                    params,
                    depth,
                )) break :blk false;
            }
            break :blk true;
        },
        .set_binary => |set_binary| expr_supported(
            module,
            set_binary.left,
            params,
            depth,
        ) and
            expr_supported(
                module,
                set_binary.right,
                params,
                depth,
            ),
        .function_literal => |function_literal| bound_expression_supported(
            module,
            function_literal.vars,
            function_literal.body,
            params,
            depth,
        ),
        .quantifier => |quantifier| bound_expression_supported(
            module,
            quantifier.vars,
            quantifier.body,
            params,
            depth,
        ),
        .set_filter => |filter_value| filter_value.vars.len == 1 and
            bound_expression_supported(
                module,
                filter_value.vars,
                filter_value.pred,
                params,
                depth,
            ),
        .set_map => |map_value| map_value.vars.len == 1 and
            bound_expression_supported(
                module,
                map_value.vars,
                map_value.value,
                params,
                depth,
            ),
        .choose => |choose_value| choose_value.domain != null and
            bound_expression_supported(
                module,
                &.{.{
                    .name = choose_value.var_name,
                    .domain = choose_value.domain.?,
                }},
                choose_value.body,
                params,
                depth,
            ),
        .let_in => |let_value| let_supported(
            module,
            let_value,
            params,
            depth,
        ),
        .except => |except_value| blk: {
            if (!expr_supported(
                module,
                except_value.func,
                params,
                depth,
            )) break :blk false;
            for (except_value.steps) |step| {
                if (step == .index and !expr_supported(
                    module,
                    step.index,
                    params,
                    depth,
                )) break :blk false;
            }
            if (params.len >= 64) break :blk false;
            var extended: [64][]const u8 = undefined;
            @memcpy(extended[0..params.len], params);
            extended[params.len] = "$at";
            break :blk expr_supported(
                module,
                except_value.value,
                extended[0 .. params.len + 1],
                depth,
            );
        },
        .at => params.len > 0 and
            std.mem.eql(u8, params[params.len - 1], "$at"),
        .set_of_functions => |function_set| expr_supported(
            module,
            function_set.domain,
            params,
            depth,
        ) and expr_supported(
            module,
            function_set.codomain,
            params,
            depth,
        ),
        .record_set => |record_set| blk: {
            for (record_set.fields) |field| {
                if (!expr_supported(
                    module,
                    field.domain,
                    params,
                    depth,
                )) break :blk false;
            }
            break :blk true;
        },
        .field => |field| expr_supported(
            module,
            field.expr,
            params,
            depth,
        ),
        .unary => |unary| switch (unary.op) {
            .not, .neg, .subset, .union_all, .domain => expr_supported(
                module,
                unary.operand,
                params,
                depth,
            ),
            else => false,
        },
        .binary => |binary| binary_supported(binary.op) and
            expr_supported(module, binary.left, params, depth) and
            expr_supported(module, binary.right, params, depth),
        .if_then_else => |conditional| expr_supported(module, conditional.cond, params, depth) and
            expr_supported(
                module,
                conditional.then_branch,
                params,
                depth,
            ) and
            expr_supported(
                module,
                conditional.else_branch,
                params,
                depth,
            ),
        .apply => |application| blk: {
            if (application.func.* == .ident and
                constant_substitution_name(
                    module,
                    application.func.*.ident,
                ) != null)
            {
                break :blk true;
            }
            if (is_select_sequence_call(application)) {
                const lambda = application.args[1].*.lambda;
                if (lambda.params.len != 1 or
                    params.len + 1 > 64 or
                    !expr_supported(
                        module,
                        application.args[0],
                        params,
                        depth,
                    ))
                {
                    break :blk false;
                }
                var extended: [64][]const u8 = undefined;
                @memcpy(extended[0..params.len], params);
                extended[params.len] = lambda.params[0];
                break :blk expr_supported(
                    module,
                    lambda.body,
                    extended[0 .. params.len + 1],
                    depth,
                );
            }
            if (is_reduce_sequence_call(application)) {
                const lambda = application.args[0].*.lambda;
                if (lambda.params.len != 2 or
                    params.len + lambda.params.len > 64 or
                    !expr_supported(
                        module,
                        application.args[1],
                        params,
                        depth,
                    ) or
                    !expr_supported(
                        module,
                        application.args[2],
                        params,
                        depth,
                    ))
                {
                    break :blk false;
                }
                var extended: [64][]const u8 = undefined;
                @memcpy(extended[0..params.len], params);
                @memcpy(
                    extended[params.len..][0..lambda.params.len],
                    lambda.params,
                );
                break :blk expr_supported(
                    module,
                    lambda.body,
                    extended[0 .. params.len + lambda.params.len],
                    depth,
                );
            }
            if (application.func.* == .ident and
                direct_native_name(application.func.ident) != null)
            {
                for (application.args) |argument| {
                    if (!expr_supported(
                        module,
                        argument,
                        params,
                        depth,
                    )) break :blk false;
                }
                break :blk true;
            }
            const target_name = if (application.func.* == .ident)
                resolved_definition_name(
                    module,
                    application.func.*.ident,
                )
            else
                null;
            if (target_name == null) {
                if (!expr_supported(
                    module,
                    application.func,
                    params,
                    depth,
                )) break :blk false;
                for (application.args) |argument| {
                    if (!expr_supported(
                        module,
                        argument,
                        params,
                        depth,
                    )) break :blk false;
                }
                break :blk true;
            }
            const target = find_definition(
                module,
                target_name.?,
            ) orelse break :blk false;
            if (target.params.len != application.args.len) {
                if (target.params.len != 0 or
                    !operator_supported(module, target, depth + 1))
                {
                    break :blk false;
                }
                for (application.args) |argument| {
                    if (!expr_supported(
                        module,
                        argument,
                        params,
                        depth,
                    )) break :blk false;
                }
                break :blk true;
            }
            if (!operator_supported(module, target, depth + 1) and
                !native_operator(target.name))
            {
                break :blk false;
            }
            for (application.args) |argument| {
                if (!expr_supported(
                    module,
                    argument,
                    params,
                    depth,
                )) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn definition_value_supported(
    module: ast.Module,
    name: []const u8,
    depth: u32,
) bool {
    if (configured_constant_name(module, name) != null) return true;
    if (builtin_value_runtime_name(name) != null) return true;
    const resolved_name = resolved_definition_name(module, name) orelse
        return false;
    if (builtin_value_runtime_name(resolved_name) != null) return true;
    const definition = find_definition(module, resolved_name) orelse
        return false;
    return operator_supported(module, definition, depth + 1);
}

fn bound_expression_supported(
    module: ast.Module,
    vars: []const ast.BoundVar,
    body: *const ast.Expr,
    params: []const []const u8,
    depth: u32,
) bool {
    if (vars.len == 0 or params.len + vars.len > 64) return false;
    for (vars) |bound| {
        for (vars) |other| {
            if (expr_references_identifier(
                bound.domain,
                other.name,
            )) return false;
        }
        if (!expr_supported(
            module,
            bound.domain,
            params,
            depth,
        )) return false;
    }
    var extended: [64][]const u8 = undefined;
    @memcpy(extended[0..params.len], params);
    for (vars, 0..) |bound, index| {
        extended[params.len + index] = bound.name;
    }
    return expr_supported(
        module,
        body,
        extended[0 .. params.len + vars.len],
        depth,
    );
}

fn emit_helpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
    emitted_helpers: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    switch (expr.*) {
        .primed_expr => |operand| {
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try emit_named_helper(
                output,
                allocator,
                module,
                helper,
                operand,
                params,
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                operand,
                params,
                emitted_helpers,
            );
        },
        .quantifier => |quantifier| {
            try emit_bound_helper(
                output,
                allocator,
                module,
                expr,
                quantifier.vars,
                quantifier.body,
                params,
                emitted_helpers,
            );
            for (quantifier.vars) |bound| {
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    bound.domain,
                    params,
                    emitted_helpers,
                );
            }
            var extended: [64][]const u8 = undefined;
            @memcpy(extended[0..params.len], params);
            for (quantifier.vars, 0..) |bound, index| {
                extended[params.len + index] = bound.name;
            }
            try emit_helpers(
                output,
                allocator,
                module,
                quantifier.body,
                extended[0 .. params.len + quantifier.vars.len],
                emitted_helpers,
            );
        },
        .set_filter => |filter_value| {
            try emit_bound_helper(
                output,
                allocator,
                module,
                expr,
                filter_value.vars,
                filter_value.pred,
                params,
                emitted_helpers,
            );
            try emit_bound_children(
                output,
                allocator,
                module,
                filter_value.vars,
                filter_value.pred,
                params,
                emitted_helpers,
            );
        },
        .set_map => |map_value| {
            try emit_bound_helper(
                output,
                allocator,
                module,
                expr,
                map_value.vars,
                map_value.value,
                params,
                emitted_helpers,
            );
            try emit_bound_children(
                output,
                allocator,
                module,
                map_value.vars,
                map_value.value,
                params,
                emitted_helpers,
            );
        },
        .choose => |choose_value| {
            const vars = [_]ast.BoundVar{.{
                .name = choose_value.var_name,
                .domain = choose_value.domain.?,
            }};
            try emit_bound_helper(
                output,
                allocator,
                module,
                expr,
                &vars,
                choose_value.body,
                params,
                emitted_helpers,
            );
            try emit_bound_children(
                output,
                allocator,
                module,
                &vars,
                choose_value.body,
                params,
                emitted_helpers,
            );
        },
        .let_in => |let_value| try emit_let_helpers(
            output,
            allocator,
            module,
            expr,
            let_value,
            params,
            emitted_helpers,
        ),
        .except => |except_value| {
            try emit_helpers(
                output,
                allocator,
                module,
                except_value.func,
                params,
                emitted_helpers,
            );
            for (except_value.steps) |step| {
                if (step == .index) {
                    try emit_helpers(
                        output,
                        allocator,
                        module,
                        step.index,
                        params,
                        emitted_helpers,
                    );
                }
            }
            var extended: [64][]const u8 = undefined;
            @memcpy(extended[0..params.len], params);
            extended[params.len] = "$at";
            const helper = try helper_name(
                allocator,
                expression_identity(module, expr),
            );
            defer allocator.free(helper);
            try emit_named_helper(
                output,
                allocator,
                module,
                helper,
                except_value.value,
                extended[0 .. params.len + 1],
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                except_value.value,
                extended[0 .. params.len + 1],
                emitted_helpers,
            );
        },
        .function_literal => |function_literal| {
            if (expr_references_identifier(
                function_literal.body,
                function_literal.vars[0].name,
            )) {
                try emit_bound_helper(
                    output,
                    allocator,
                    module,
                    expr,
                    function_literal.vars,
                    function_literal.body,
                    params,
                    emitted_helpers,
                );
            }
            try emit_bound_children(
                output,
                allocator,
                module,
                function_literal.vars,
                function_literal.body,
                params,
                emitted_helpers,
            );
        },
        .binary => |binary| {
            try emit_helpers(
                output,
                allocator,
                module,
                binary.left,
                params,
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                binary.right,
                params,
                emitted_helpers,
            );
        },
        .unary => |unary| try emit_helpers(
            output,
            allocator,
            module,
            unary.operand,
            params,
            emitted_helpers,
        ),
        .if_then_else => |conditional| {
            try emit_helpers(
                output,
                allocator,
                module,
                conditional.cond,
                params,
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                conditional.then_branch,
                params,
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                conditional.else_branch,
                params,
                emitted_helpers,
            );
        },
        .apply => |application| {
            if (is_select_sequence_call(application)) {
                const lambda_expr = application.args[1];
                const lambda = lambda_expr.*.lambda;
                var extended: [64][]const u8 = undefined;
                @memcpy(extended[0..params.len], params);
                extended[params.len] = lambda.params[0];
                const helper = try helper_name(
                    allocator,
                    expression_identity(module, lambda_expr),
                );
                defer allocator.free(helper);
                try emit_named_helper(
                    output,
                    allocator,
                    module,
                    helper,
                    lambda.body,
                    extended[0 .. params.len + 1],
                    emitted_helpers,
                );
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    lambda.body,
                    extended[0 .. params.len + 1],
                    emitted_helpers,
                );
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    application.args[0],
                    params,
                    emitted_helpers,
                );
                return;
            }
            if (is_reduce_sequence_call(application)) {
                const lambda_expr = application.args[0];
                const lambda = lambda_expr.*.lambda;
                var extended: [64][]const u8 = undefined;
                @memcpy(extended[0..params.len], params);
                @memcpy(
                    extended[params.len..][0..lambda.params.len],
                    lambda.params,
                );
                const helper = try helper_name(
                    allocator,
                    expression_identity(module, lambda_expr),
                );
                defer allocator.free(helper);
                try emit_named_helper(
                    output,
                    allocator,
                    module,
                    helper,
                    lambda.body,
                    extended[0 .. params.len + lambda.params.len],
                    emitted_helpers,
                );
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    lambda.body,
                    extended[0 .. params.len + lambda.params.len],
                    emitted_helpers,
                );
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    application.args[1],
                    params,
                    emitted_helpers,
                );
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    application.args[2],
                    params,
                    emitted_helpers,
                );
                return;
            }
            try emit_helpers(
                output,
                allocator,
                module,
                application.func,
                params,
                emitted_helpers,
            );
            for (application.args) |argument| {
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    argument,
                    params,
                    emitted_helpers,
                );
            }
        },
        .field => |field_value| try emit_helpers(
            output,
            allocator,
            module,
            field_value.expr,
            params,
            emitted_helpers,
        ),
        .tuple, .set_enum => |items| {
            for (items) |item| {
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    item,
                    params,
                    emitted_helpers,
                );
            }
        },
        .record => |fields| {
            for (fields) |field_value| {
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    field_value.value,
                    params,
                    emitted_helpers,
                );
            }
        },
        .set_binary => |set_binary| {
            try emit_helpers(
                output,
                allocator,
                module,
                set_binary.left,
                params,
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                set_binary.right,
                params,
                emitted_helpers,
            );
        },
        .set_of_functions => |function_set| {
            try emit_helpers(
                output,
                allocator,
                module,
                function_set.domain,
                params,
                emitted_helpers,
            );
            try emit_helpers(
                output,
                allocator,
                module,
                function_set.codomain,
                params,
                emitted_helpers,
            );
        },
        .record_set => |record_set_value| {
            for (record_set_value.fields) |field_value| {
                try emit_helpers(
                    output,
                    allocator,
                    module,
                    field_value.domain,
                    params,
                    emitted_helpers,
                );
            }
        },
        else => {},
    }
}

fn emit_bound_children(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    vars: []const ast.BoundVar,
    body: *const ast.Expr,
    params: []const []const u8,
    emitted_helpers: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    for (vars) |bound| {
        try emit_helpers(
            output,
            allocator,
            module,
            bound.domain,
            params,
            emitted_helpers,
        );
    }
    var extended: [64][]const u8 = undefined;
    @memcpy(extended[0..params.len], params);
    for (vars, 0..) |bound, index| {
        extended[params.len + index] = bound.name;
    }
    try emit_helpers(
        output,
        allocator,
        module,
        body,
        extended[0 .. params.len + vars.len],
        emitted_helpers,
    );
}

fn let_supported(
    module: ast.Module,
    let_value: *const ast.LetIn,
    params: []const []const u8,
    depth: u32,
) bool {
    if (params.len + let_value.defs.len > 64) return false;
    var extended: [64][]const u8 = undefined;
    @memcpy(extended[0..params.len], params);
    for (let_value.defs, 0..) |definition, index| {
        if (definition.is_function or
            params.len + index + definition.params.len > 64)
        {
            return false;
        }
        var definition_params: [64][]const u8 = undefined;
        @memcpy(
            definition_params[0 .. params.len + index],
            extended[0 .. params.len + index],
        );
        @memcpy(
            definition_params[params.len + index ..][0..definition.params.len],
            definition.params,
        );
        if (!expr_supported(
            module,
            definition.body,
            definition_params[0 .. params.len + index + definition.params.len],
            depth,
        )) return false;
        extended[params.len + index] = definition.name;
    }
    return expr_supported(
        module,
        let_value.body,
        extended[0 .. params.len + let_value.defs.len],
        depth,
    );
}

fn is_reduce_sequence_call(application: *const ast.Apply) bool {
    if (application.func.* != .ident or
        application.args.len != 3 or
        application.args[0].* != .lambda)
    {
        return false;
    }
    const name = application.func.*.ident;
    return std.mem.eql(u8, name, "ReduceSeq") or
        std.mem.endsWith(u8, name, "!ReduceSeq");
}

fn is_select_sequence_call(application: *const ast.Apply) bool {
    if (application.func.* != .ident or
        application.args.len != 2 or
        application.args[1].* != .lambda)
    {
        return false;
    }
    const name = application.func.*.ident;
    return std.mem.eql(u8, name, "SelectSeq") or
        std.mem.endsWith(u8, name, "!SelectSeq");
}

fn direct_native_name(name: []const u8) ?[]const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, name, '!');
    const unqualified = if (separator) |index| name[index + 1 ..] else name;
    const direct = [_]struct {
        tla: []const u8,
        zig: []const u8,
    }{
        .{ .tla = "Cardinality", .zig = "cardinality" },
        .{ .tla = "Len", .zig = "sequence_len" },
        .{ .tla = "Head", .zig = "sequence_head" },
        .{ .tla = "Tail", .zig = "sequence_tail" },
        .{ .tla = "Append", .zig = "sequence_append" },
        .{ .tla = "Seq", .zig = "sequence_set" },
        .{ .tla = "Range", .zig = "function_range" },
        .{ .tla = "SeqToSet", .zig = "sequence_to_set" },
        .{ .tla = "Index", .zig = "sequence_index" },
        .{ .tla = "PermSeqs", .zig = "permutation_sequences" },
        .{ .tla = "Permutations", .zig = "permutations" },
        .{ .tla = "INTERSECTION", .zig = "intersection_all" },
        .{ .tla = "SetToBag", .zig = "set_to_bag" },
        .{ .tla = "BagOfSet", .zig = "set_to_bag" },
        .{ .tla = "(+)", .zig = "bag_cup" },
        .{ .tla = "BagCup", .zig = "bag_cup" },
        .{ .tla = "(-)", .zig = "bag_difference" },
        .{ .tla = "BagDifference", .zig = "bag_difference" },
    };
    for (direct) |entry| {
        if (std.mem.eql(u8, unqualified, entry.tla)) return entry.zig;
    }
    return null;
}

fn builtin_value_runtime_name(name: []const u8) ?[]const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, name, '!');
    const unqualified = if (separator) |index| name[index + 1 ..] else name;
    const direct = [_]struct {
        tla: []const u8,
        zig: []const u8,
    }{
        .{ .tla = "Nat", .zig = "nat_set" },
        .{ .tla = "Int", .zig = "int_set" },
        .{ .tla = "BOOLEAN", .zig = "boolean_set" },
        .{ .tla = "STRING", .zig = "string_set" },
    };
    for (direct) |entry| {
        if (std.mem.eql(u8, unqualified, entry.tla)) return entry.zig;
    }
    return null;
}

fn emit_let_helpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    owner: *const ast.Expr,
    let_value: *const ast.LetIn,
    params: []const []const u8,
    emitted_helpers: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    var extended: [64][]const u8 = undefined;
    @memcpy(extended[0..params.len], params);
    for (let_value.defs, 0..) |definition, index| {
        const helper = try let_helper_name(
            allocator,
            expression_identity(module, owner),
            index,
        );
        defer allocator.free(helper);
        var definition_params: [64][]const u8 = undefined;
        @memcpy(
            definition_params[0 .. params.len + index],
            extended[0 .. params.len + index],
        );
        @memcpy(
            definition_params[params.len + index ..][0..definition.params.len],
            definition.params,
        );
        const helper_params =
            definition_params[0 .. params.len + index + definition.params.len];
        try emit_named_helper(
            output,
            allocator,
            module,
            helper,
            definition.body,
            helper_params,
            emitted_helpers,
        );
        try emit_helpers(
            output,
            allocator,
            module,
            definition.body,
            helper_params,
            emitted_helpers,
        );
        extended[params.len + index] = definition.name;
    }
    const body_helper = try let_body_name(
        allocator,
        expression_identity(module, owner),
    );
    defer allocator.free(body_helper);
    try emit_named_helper(
        output,
        allocator,
        module,
        body_helper,
        let_value.body,
        extended[0 .. params.len + let_value.defs.len],
        emitted_helpers,
    );
    try emit_helpers(
        output,
        allocator,
        module,
        let_value.body,
        extended[0 .. params.len + let_value.defs.len],
        emitted_helpers,
    );
    if (expr_is_boolean(module, let_value.body, 0)) {
        try emit_lazy_boolean_let(
            output,
            allocator,
            module,
            owner,
            let_value,
            params,
            extended[0 .. params.len + let_value.defs.len],
            emitted_helpers,
        );
    }
}

fn emit_lazy_boolean_let(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    owner: *const ast.Expr,
    let_value: *const ast.LetIn,
    outer_params: []const []const u8,
    extended_params: []const []const u8,
    emitted_helpers: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    const identity = expression_identity(module, owner);
    const function_name = try let_boolean_name(allocator, identity);
    defer allocator.free(function_name);
    if (emitted_helpers.contains(function_name)) return;
    const owned_name = try allocator.dupe(u8, function_name);
    errdefer allocator.free(owned_name);
    try emitted_helpers.put(owned_name, {});
    const header = try std.fmt.allocPrint(
        allocator,
        "fn {s}(context: *runtime.CallContext, operator_args: []const Value) Error!bool {{\n" ++
            "    std.debug.assert(operator_args.len == {d});\n" ++
            "    var values: [64]Value = undefined;\n" ++
            "    @memcpy(values[0..operator_args.len], operator_args);\n",
        .{ function_name, outer_params.len },
    );
    defer allocator.free(header);
    try append(output, allocator, header);

    var operands: [256]*const ast.Expr = undefined;
    var operand_count: usize = 0;
    const operation: ast.BinaryOp =
        if (let_value.body.* == .binary and
        (let_value.body.binary.op == .and_op or
            let_value.body.binary.op == .or_op))
            let_value.body.binary.op
        else
            .and_op;
    if (let_value.body.* == .binary and
        let_value.body.binary.op == operation)
    {
        flatten_boolean_operands(
            let_value.body,
            operation,
            &operands,
            &operand_count,
        );
    } else {
        operands[0] = let_value.body;
        operand_count = 1;
    }

    var emitted: [64]bool = @splat(false);
    for (operands[0..operand_count], 0..) |operand, operand_index| {
        var required: [64]bool = @splat(false);
        for (let_value.defs, 0..) |definition, definition_index| {
            if (expr_references_identifier(operand, definition.name)) {
                mark_required_let_definitions(
                    let_value,
                    definition_index,
                    &required,
                );
            }
        }
        for (let_value.defs, 0..) |definition, definition_index| {
            if (!required[definition_index] or emitted[definition_index]) {
                continue;
            }
            const helper = try let_helper_name(
                allocator,
                identity,
                definition_index,
            );
            defer allocator.free(helper);
            const assignment = if (definition.params.len == 0)
                try std.fmt.allocPrint(
                    allocator,
                    "    values[{d}] = try {s}(context, values[0..{d}]);\n",
                    .{
                        outer_params.len + definition_index,
                        helper,
                        outer_params.len + definition_index,
                    },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "    values[{d}] = try runtime.operator(context, {s}, {d}, values[0..{d}]);\n",
                    .{
                        outer_params.len + definition_index,
                        helper,
                        definition.params.len,
                        outer_params.len + definition_index,
                    },
                );
            defer allocator.free(assignment);
            try append(output, allocator, assignment);
            emitted[definition_index] = true;
        }
        const args_line = try std.fmt.allocPrint(
            allocator,
            "    const args_{d} = values[0..{d}];\n",
            .{ operand_index, extended_params.len },
        );
        defer allocator.free(args_line);
        try append(output, allocator, args_line);
        const condition_prefix = try std.fmt.allocPrint(
            allocator,
            "    const condition_{d} = blk: {{ const args = args_{d}; runtime.keep_expression_parameters(context, args); break :blk ",
            .{ operand_index, operand_index },
        );
        defer allocator.free(condition_prefix);
        try append(output, allocator, condition_prefix);
        try emit_boolean_expr(
            output,
            allocator,
            module,
            operand,
            extended_params,
        );
        try append(output, allocator, "; };\n");
        const branch = if (operation == .and_op)
            try std.fmt.allocPrint(
                allocator,
                "    if (!condition_{d}) return false;\n",
                .{operand_index},
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "    if (condition_{d}) return true;\n",
                .{operand_index},
            );
        defer allocator.free(branch);
        try append(output, allocator, branch);
    }
    try append(
        output,
        allocator,
        if (operation == .and_op)
            "    return true;\n}\n\n"
        else
            "    return false;\n}\n\n",
    );
}

fn mark_required_let_definitions(
    let_value: *const ast.LetIn,
    definition_index: usize,
    required: *[64]bool,
) void {
    if (required[definition_index]) return;
    required[definition_index] = true;
    const body = let_value.defs[definition_index].body;
    for (let_value.defs[0..definition_index], 0..) |
        dependency,
        dependency_index,
    | {
        if (expr_references_identifier(body, dependency.name)) {
            mark_required_let_definitions(
                let_value,
                dependency_index,
                required,
            );
        }
    }
}

fn emit_bound_helper(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    owner: *const ast.Expr,
    vars: []const ast.BoundVar,
    body: *const ast.Expr,
    params: []const []const u8,
    emitted_helpers: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    var extended: [64][]const u8 = undefined;
    @memcpy(extended[0..params.len], params);
    for (vars, 0..) |bound, index| {
        extended[params.len + index] = bound.name;
    }
    const helper = try helper_name(
        allocator,
        expression_identity(module, owner),
    );
    defer allocator.free(helper);
    try emit_named_helper(
        output,
        allocator,
        module,
        helper,
        body,
        extended[0 .. params.len + vars.len],
        emitted_helpers,
    );
}

fn emit_named_helper(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    name: []const u8,
    body: *const ast.Expr,
    params: []const []const u8,
    emitted_helpers: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    if (emitted_helpers.contains(name)) return;
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try emitted_helpers.put(owned_name, {});
    const header = try std.fmt.allocPrint(
        allocator,
        "fn {s}(context: *runtime.CallContext, args: []const Value) Error!Value {{\n" ++
            "    std.debug.assert(args.len == {d});\n" ++
            "    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);\n",
        .{ name, params.len },
    );
    defer allocator.free(header);
    try append(output, allocator, header);
    try emit_function_body(
        output,
        allocator,
        module,
        body,
        params,
    );
    try append(output, allocator, "}\n\n");
}

fn emit_function_body(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    body: *const ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!void {
    if (body.* == .binary and
        (body.binary.op == .and_op or body.binary.op == .or_op))
    {
        var operands: [256]*const ast.Expr = undefined;
        var operand_count: usize = 0;
        flatten_boolean_operands(
            body,
            body.binary.op,
            &operands,
            &operand_count,
        );
        std.debug.assert(operand_count > 1);
        for (operands[0..operand_count], 0..) |operand, index| {
            if (try emit_unchanged_guards(
                output,
                allocator,
                module,
                operand,
                body.binary.op,
            )) continue;
            const prefix = try std.fmt.allocPrint(
                allocator,
                "    const condition_{d} = try runtime.boolean(",
                .{index},
            );
            defer allocator.free(prefix);
            try append(output, allocator, prefix);
            try emit_expr(output, allocator, module, operand, params);
            try append(output, allocator, ");\n");
            const branch = if (body.binary.op == .and_op)
                try std.fmt.allocPrint(
                    allocator,
                    "    if (!condition_{d}) return Value{{ .bool_v = false }};\n",
                    .{index},
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "    if (condition_{d}) return Value{{ .bool_v = true }};\n",
                    .{index},
                );
            defer allocator.free(branch);
            try append(output, allocator, branch);
        }
        try append(
            output,
            allocator,
            if (body.binary.op == .and_op)
                "    return Value{ .bool_v = true };\n"
            else
                "    return Value{ .bool_v = false };\n",
        );
        return;
    }
    if (body.* == .if_then_else) {
        try append(output, allocator, "    if (try runtime.boolean(");
        try emit_expr(
            output,
            allocator,
            module,
            body.if_then_else.cond,
            params,
        );
        try append(output, allocator, ")) {\n        return ");
        try emit_expr(
            output,
            allocator,
            module,
            body.if_then_else.then_branch,
            params,
        );
        try append(output, allocator, ";\n    }\n    return ");
        try emit_expr(
            output,
            allocator,
            module,
            body.if_then_else.else_branch,
            params,
        );
        try append(output, allocator, ";\n");
        return;
    }
    try append(output, allocator, "    return ");
    try emit_expr(output, allocator, module, body, params);
    try append(output, allocator, ";\n");
}

fn emit_unchanged_guards(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    operand: *const ast.Expr,
    operation: ast.BinaryOp,
) error{OutOfMemory}!bool {
    if (operation != .and_op) return false;
    switch (operand.*) {
        .unchanged => |names| {
            try emit_unchanged_guard(
                output,
                allocator,
                module,
                names,
                "Value{ .bool_v = false }",
            );
            return true;
        },
        .unchanged_expr => |tuple_expr| {
            if (tuple_expr.* != .tuple) return false;
            var names = try allocator.alloc([]const u8, tuple_expr.tuple.len);
            defer allocator.free(names);
            for (tuple_expr.tuple, 0..) |item, index| {
                if (item.* != .ident) return false;
                names[index] = item.ident;
            }
            try emit_unchanged_guard(
                output,
                allocator,
                module,
                names,
                "Value{ .bool_v = false }",
            );
            return true;
        },
        else => return false,
    }
}

fn emit_boolean_unchanged_guards(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    operand: *const ast.Expr,
    operation: ast.BinaryOp,
) error{OutOfMemory}!bool {
    if (operation != .and_op) return false;
    switch (operand.*) {
        .unchanged => |names| {
            try emit_unchanged_guard(
                output,
                allocator,
                module,
                names,
                "false",
            );
            return true;
        },
        .unchanged_expr => |tuple_expr| {
            if (tuple_expr.* != .tuple) return false;
            var names = try allocator.alloc([]const u8, tuple_expr.tuple.len);
            defer allocator.free(names);
            for (tuple_expr.tuple, 0..) |item, index| {
                if (item.* != .ident) return false;
                names[index] = item.ident;
            }
            try emit_unchanged_guard(
                output,
                allocator,
                module,
                names,
                "false",
            );
            return true;
        },
        else => return false,
    }
}

fn emit_unchanged_guard(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    names: []const []const u8,
    return_value: []const u8,
) error{OutOfMemory}!void {
    try append(output, allocator, "    if (!(");
    try emit_unchanged_terms(output, allocator, module, names);
    try append(output, allocator, ")) return ");
    try append(output, allocator, return_value);
    try append(output, allocator, ";\n");
}

fn flatten_boolean_operands(
    expr: *const ast.Expr,
    operation: ast.BinaryOp,
    operands: *[256]*const ast.Expr,
    count: *usize,
) void {
    if (expr.* == .binary and expr.binary.op == operation) {
        flatten_boolean_operands(
            expr.binary.left,
            operation,
            operands,
            count,
        );
        flatten_boolean_operands(
            expr.binary.right,
            operation,
            operands,
            count,
        );
        return;
    }
    std.debug.assert(count.* < operands.len);
    operands[count.*] = expr;
    count.* += 1;
}

fn let_helper_name(
    allocator: std.mem.Allocator,
    identity: usize,
    index: usize,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "let_{x}_{d}",
        .{ identity, index },
    );
}

fn let_body_name(
    allocator: std.mem.Allocator,
    identity: usize,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "let_{x}_body",
        .{identity},
    );
}

fn let_boolean_name(
    allocator: std.mem.Allocator,
    identity: usize,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "let_{x}_boolean",
        .{identity},
    );
}

fn helper_name(
    allocator: std.mem.Allocator,
    identity: usize,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "bound_{x}",
        .{identity},
    );
}

fn expression_boolean_name(
    allocator: std.mem.Allocator,
    identity: usize,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "expr_{d}_bool",
        .{identity},
    );
}

fn binary_supported(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .and_op,
        .or_op,
        .implies,
        .equiv,
        .in,
        .notin,
        .subseteq,
        .set_union,
        .set_intersection,
        .set_difference,
        .plus,
        .minus,
        .times,
        .div,
        .mod,
        .power,
        .range,
        .concat,
        .ooverride,
        .recordto,
        => true,
        else => false,
    };
}

fn binary_runtime(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .eq => "runtime.equal(context.eval_pool, ",
        .ne => "runtime.not_equal(context.eval_pool, ",
        .lt => "try runtime.less_than(context.eval_pool, ",
        .le => "try runtime.less_equal(context.eval_pool, ",
        .gt => "try runtime.greater_than(context.eval_pool, ",
        .ge => "try runtime.greater_equal(context.eval_pool, ",
        .equiv => "try runtime.equivalent(",
        .in => "try runtime.member(context, ",
        .notin => "try runtime.not_member(context, ",
        .subseteq => "try runtime.subset_equal(context, ",
        .set_union => "try runtime.set_union(context, ",
        .set_intersection => "try runtime.set_intersection(context, ",
        .set_difference => "try runtime.set_difference(context, ",
        .plus => "try runtime.add(",
        .minus => "try runtime.subtract(",
        .times => "try runtime.multiply(",
        .div => "try runtime.divide(",
        .mod => "try runtime.modulo(",
        .power => "try runtime.power(",
        .range => "try runtime.range(",
        .concat => "try runtime.sequence_concat(context, ",
        .ooverride => "try runtime.override(context, ",
        .recordto => "try runtime.record_to(context, ",
        else => unreachable,
    };
}

fn emit_value_array(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    function_name: []const u8,
    items: []const *ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!void {
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.{s}(context, &[_]Value{{",
        .{function_name},
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    for (items, 0..) |item, index| {
        if (index > 0) try append(output, allocator, ", ");
        try emit_expr(
            output,
            allocator,
            module,
            item,
            params,
        );
    }
    try append(output, allocator, "})");
}

fn expressions_supported(
    module: ast.Module,
    expressions: []const *ast.Expr,
    params: []const []const u8,
    depth: u32,
) bool {
    for (expressions) |expression| {
        if (!expr_supported(
            module,
            expression,
            params,
            depth,
        )) return false;
    }
    return true;
}

fn emit_unchanged(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    names: []const []const u8,
) error{OutOfMemory}!void {
    try append(output, allocator, "Value{ .bool_v = ");
    if (names.len == 0) {
        try append(output, allocator, "true");
    } else {
        try emit_unchanged_terms(output, allocator, module, names);
    }
    try append(output, allocator, " }");
}

fn variable_names_supported(
    module: ast.Module,
    names: []const []const u8,
) bool {
    for (names) |name| {
        if (variable_index(module, name) != null) continue;
        const definition = find_definition(module, name) orelse return false;
        if (definition.params.len != 0 or
            !operator_supported(module, definition, 0))
        {
            return false;
        }
    }
    return true;
}

fn unchanged_tuple_supported(
    module: ast.Module,
    expr: *const ast.Expr,
) bool {
    if (expr.* != .tuple) return false;
    const items = expr.*.tuple;
    for (items) |item| {
        if (item.* != .ident or
            !variable_names_supported(module, &.{item.*.ident}))
        {
            return false;
        }
    }
    return true;
}

fn emit_unchanged_tuple(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
) error{OutOfMemory}!void {
    const items = expr.*.tuple;
    try append(output, allocator, "Value{ .bool_v = ");
    if (items.len == 0) {
        try append(output, allocator, "true");
    } else {
        var names = try allocator.alloc([]const u8, items.len);
        defer allocator.free(names);
        for (items, 0..) |item, index| {
            names[index] = item.*.ident;
        }
        try emit_unchanged_terms(output, allocator, module, names);
    }
    try append(output, allocator, " }");
}

fn emit_unchanged_terms(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    names: []const []const u8,
) error{OutOfMemory}!void {
    var emitted = false;
    var variable_count: usize = 0;
    for (names) |name| {
        if (variable_index(module, name) != null) variable_count += 1;
    }
    if (variable_count > 0) {
        try append(
            output,
            allocator,
            "(try runtime.unchanged_variables(context, &[_]u32{",
        );
        var index: usize = 0;
        for (names) |name| {
            const variable = variable_index(module, name) orelse continue;
            if (index > 0) try append(output, allocator, ", ");
            const text = try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{variable},
            );
            defer allocator.free(text);
            try append(output, allocator, text);
            index += 1;
        }
        try append(output, allocator, "}))");
        emitted = true;
    }
    for (names) |name| {
        if (variable_index(module, name) != null) continue;
        if (emitted) try append(output, allocator, " and ");
        try emit_unchanged_term(output, allocator, module, name);
        emitted = true;
    }
    if (!emitted) try append(output, allocator, "true");
}

fn emit_unchanged_term(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    name: []const u8,
) error{OutOfMemory}!void {
    const expression = if (variable_index(module, name)) |variable|
        try std.fmt.allocPrint(
            allocator,
            "(try runtime.unchanged_variable(context, {d}))",
            .{variable},
        )
    else blk: {
        const definition_index = find_definition_index(
            module,
            name,
        ) orelse unreachable;
        break :blk try std.fmt.allocPrint(
            allocator,
            "(try runtime.unchanged_expression(context, args, op_{d}))",
            .{definition_index},
        );
    };
    defer allocator.free(expression);
    try append(output, allocator, expression);
}

fn expr_references_identifier(
    expr: *const ast.Expr,
    name: []const u8,
) bool {
    return switch (expr.*) {
        .ident => |identifier| std.mem.eql(u8, identifier, name),
        .primed => |identifier| std.mem.eql(u8, identifier, name),
        .primed_expr => |operand| expr_references_identifier(operand, name),
        .binary => |binary| expr_references_identifier(binary.left, name) or
            expr_references_identifier(binary.right, name),
        .unary => |unary| expr_references_identifier(unary.operand, name),
        .if_then_else => |conditional| expr_references_identifier(
            conditional.cond,
            name,
        ) or expr_references_identifier(
            conditional.then_branch,
            name,
        ) or expr_references_identifier(
            conditional.else_branch,
            name,
        ),
        .apply => |application| blk: {
            if (expr_references_identifier(application.func, name)) {
                break :blk true;
            }
            for (application.args) |argument| {
                if (expr_references_identifier(argument, name)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .field => |field_value| expr_references_identifier(
            field_value.expr,
            name,
        ),
        .tuple, .set_enum => |items| blk: {
            for (items) |item| {
                if (expr_references_identifier(item, name)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .record => |fields| blk: {
            for (fields) |field_value| {
                if (expr_references_identifier(field_value.value, name)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .set_binary => |set_binary| expr_references_identifier(
            set_binary.left,
            name,
        ) or expr_references_identifier(set_binary.right, name),
        .set_of_functions => |function_set| expr_references_identifier(
            function_set.domain,
            name,
        ) or expr_references_identifier(function_set.codomain, name),
        .record_set => |record_set_value| blk: {
            for (record_set_value.fields) |field_value| {
                if (expr_references_identifier(field_value.domain, name)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .function_literal => |function_literal| blk: {
            for (function_literal.vars) |bound| {
                if (expr_references_identifier(bound.domain, name)) {
                    break :blk true;
                }
                if (std.mem.eql(u8, bound.name, name)) break :blk false;
            }
            break :blk expr_references_identifier(
                function_literal.body,
                name,
            );
        },
        .set_filter => |filter_value| blk: {
            for (filter_value.vars) |bound| {
                if (expr_references_identifier(bound.domain, name)) {
                    break :blk true;
                }
                if (std.mem.eql(u8, bound.name, name)) break :blk false;
            }
            break :blk expr_references_identifier(
                filter_value.pred,
                name,
            );
        },
        .set_map => |map_value| blk: {
            for (map_value.vars) |bound| {
                if (expr_references_identifier(bound.domain, name)) {
                    break :blk true;
                }
                if (std.mem.eql(u8, bound.name, name)) break :blk false;
            }
            break :blk expr_references_identifier(map_value.value, name);
        },
        .bool_literal,
        .int_literal,
        .string_literal,
        .unchanged,
        .at,
        => false,
        else => true,
    };
}

pub fn expression_references_identifier(
    expr: *const ast.Expr,
    name: []const u8,
) bool {
    return expr_references_identifier(expr, name);
}

fn compute_reachable(
    allocator: std.mem.Allocator,
    module: ast.Module,
    extra_roots: []const []const u8,
) error{OutOfMemory}![]bool {
    const reachable = try allocator.alloc(bool, module.definitions.len);
    @memset(reachable, false);
    mark_named_definition(module, reachable, module.init_name);
    mark_named_definition(module, reachable, module.next_name);
    for (module.invariants) |name| {
        mark_named_definition(module, reachable, name);
    }
    for (extra_roots) |name| {
        mark_named_definition(module, reachable, name);
    }
    for (module.assumptions) |assumption| {
        mark_reachable_expr(module, reachable, assumption);
    }
    var any = false;
    for (reachable) |is_reachable| any = any or is_reachable;
    if (!any) @memset(reachable, true);
    return reachable;
}

fn mark_named_definition(
    module: ast.Module,
    reachable: []bool,
    name: []const u8,
) void {
    if (name.len == 0) return;
    const resolved_name = resolved_definition_name(module, name) orelse
        return;
    const index = find_definition_index(module, resolved_name) orelse return;
    mark_definition(module, reachable, index);
}

fn mark_definition(
    module: ast.Module,
    reachable: []bool,
    index: usize,
) void {
    if (reachable[index]) return;
    reachable[index] = true;
    mark_reachable_expr(
        module,
        reachable,
        module.definitions[index].body,
    );
    if (module.definitions[index].function_domain) |domain_expr| {
        mark_reachable_expr(module, reachable, domain_expr);
    }
}

fn mark_reachable_expr(
    module: ast.Module,
    reachable: []bool,
    expr: *const ast.Expr,
) void {
    switch (expr.*) {
        .ident, .primed => |name| {
            if (is_native_override(name)) return;
            const resolved_name = resolved_definition_name(
                module,
                name,
            ) orelse return;
            if (find_definition_index(module, resolved_name)) |index| {
                mark_definition(module, reachable, index);
            }
        },
        .primed_expr, .unchanged_expr => |operand| {
            mark_reachable_expr(module, reachable, operand);
        },
        .unchanged => |names| {
            for (names) |name| {
                if (find_definition_index(module, name)) |index| {
                    mark_definition(module, reachable, index);
                }
            }
        },
        .binary => |binary| {
            mark_reachable_expr(module, reachable, binary.left);
            mark_reachable_expr(module, reachable, binary.right);
        },
        .unary => |unary| {
            mark_reachable_expr(module, reachable, unary.operand);
        },
        .quantifier => |quantifier| {
            for (quantifier.vars) |bound| {
                mark_reachable_expr(module, reachable, bound.domain);
            }
            mark_reachable_expr(module, reachable, quantifier.body);
        },
        .choose => |choose_value| {
            if (choose_value.domain) |domain_expr| {
                mark_reachable_expr(module, reachable, domain_expr);
            }
            mark_reachable_expr(module, reachable, choose_value.body);
        },
        .if_then_else => |conditional| {
            mark_reachable_expr(module, reachable, conditional.cond);
            mark_reachable_expr(module, reachable, conditional.then_branch);
            mark_reachable_expr(module, reachable, conditional.else_branch);
        },
        .apply => |application| {
            if (application.func.* == .ident) {
                const name = application.func.*.ident;
                if (constant_substitution_name(module, name) != null) {
                    return;
                }
                if (resolved_definition_name(module, name)) |resolved_name| {
                    if (find_definition_index(module, resolved_name)) |index| {
                        mark_definition(module, reachable, index);
                    }
                } else if (!is_reduce_sequence_call(application) and
                    !is_select_sequence_call(application) and
                    !is_native_override(name))
                {
                    mark_reachable_expr(
                        module,
                        reachable,
                        application.func,
                    );
                }
            } else if (!is_reduce_sequence_call(application) and
                !is_select_sequence_call(application))
            {
                mark_reachable_expr(
                    module,
                    reachable,
                    application.func,
                );
            }
            for (application.args) |argument| {
                mark_reachable_expr(module, reachable, argument);
            }
        },
        .field => |field_value| {
            mark_reachable_expr(module, reachable, field_value.expr);
        },
        .tuple, .set_enum => |items| {
            for (items) |item| {
                mark_reachable_expr(module, reachable, item);
            }
        },
        .record => |fields| {
            for (fields) |field_value| {
                mark_reachable_expr(
                    module,
                    reachable,
                    field_value.value,
                );
            }
        },
        .set_filter => |filter_value| {
            for (filter_value.vars) |bound| {
                mark_reachable_expr(module, reachable, bound.domain);
            }
            mark_reachable_expr(module, reachable, filter_value.pred);
        },
        .set_map => |map_value| {
            for (map_value.vars) |bound| {
                mark_reachable_expr(module, reachable, bound.domain);
            }
            mark_reachable_expr(module, reachable, map_value.value);
        },
        .set_binary => |set_binary| {
            mark_reachable_expr(module, reachable, set_binary.left);
            mark_reachable_expr(module, reachable, set_binary.right);
        },
        .set_of_functions => |function_set| {
            mark_reachable_expr(module, reachable, function_set.domain);
            mark_reachable_expr(module, reachable, function_set.codomain);
        },
        .function_literal => |function_literal| {
            for (function_literal.vars) |bound| {
                mark_reachable_expr(module, reachable, bound.domain);
            }
            mark_reachable_expr(module, reachable, function_literal.body);
        },
        .record_set => |record_set_value| {
            for (record_set_value.fields) |field_value| {
                mark_reachable_expr(
                    module,
                    reachable,
                    field_value.domain,
                );
            }
        },
        .except => |except_value| {
            mark_reachable_expr(module, reachable, except_value.func);
            for (except_value.steps) |step| {
                if (step == .index) {
                    mark_reachable_expr(
                        module,
                        reachable,
                        step.index,
                    );
                }
            }
            mark_reachable_expr(module, reachable, except_value.value);
        },
        .let_in => |let_value| {
            for (let_value.defs) |definition| {
                mark_reachable_expr(
                    module,
                    reachable,
                    definition.body,
                );
                if (definition.function_domain) |domain_expr| {
                    mark_reachable_expr(
                        module,
                        reachable,
                        domain_expr,
                    );
                }
            }
            mark_reachable_expr(module, reachable, let_value.body);
        },
        .case_expr => |case_value| {
            for (case_value.arms) |arm| {
                mark_reachable_expr(module, reachable, arm.cond);
                mark_reachable_expr(module, reachable, arm.value);
            }
            if (case_value.otherwise) |otherwise| {
                mark_reachable_expr(module, reachable, otherwise);
            }
        },
        .box_action => |box_action| {
            mark_reachable_expr(module, reachable, box_action.action);
            mark_reachable_expr(module, reachable, box_action.vars);
        },
        .lambda => |lambda_value| {
            mark_reachable_expr(module, reachable, lambda_value.body);
        },
        .bool_literal,
        .int_literal,
        .string_literal,
        .at,
        => {},
    }
}

fn expression_identity(
    module: ast.Module,
    target: *const ast.Expr,
) usize {
    return find_expression_identity(module, target) orelse unreachable;
}

fn collect_generated_expressions(
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
    enabled: bool,
    identity: *usize,
    entries: *std.ArrayList(GeneratedExpressionMeta),
) !void {
    identity.* += 1;
    if (enabled and expr_supported(module, expr, params, 0)) {
        if (params.len > 32) return error.OutOfMemory;
        var params_copy: [32][]const u8 = @splat("");
        @memcpy(params_copy[0..params.len], params);
        try entries.append(allocator, .{
            .expression = expr,
            .params = params_copy,
            .param_count = @intCast(params.len),
            .identity = @intCast(identity.*),
        });
    }
    switch (expr.*) {
        .primed_expr, .unchanged_expr => |operand| try collect_generated_expressions(allocator, module, operand, params, enabled, identity, entries),
        .binary => |binary| {
            try collect_generated_expressions(allocator, module, binary.left, params, enabled, identity, entries);
            try collect_generated_expressions(allocator, module, binary.right, params, enabled, identity, entries);
        },
        .unary => |unary| try collect_generated_expressions(allocator, module, unary.operand, params, enabled, identity, entries),
        .quantifier => |quantifier| {
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + quantifier.vars.len > scoped_storage.len) {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            var scoped_len = params.len;
            for (quantifier.vars) |bound| {
                try collect_generated_expressions(allocator, module, bound.domain, scoped_storage[0..scoped_len], enabled, identity, entries);
                scoped_storage[scoped_len] = bound.name;
                scoped_len += 1;
            }
            try collect_generated_expressions(allocator, module, quantifier.body, scoped_storage[0..scoped_len], enabled, identity, entries);
        },
        .choose => |choose_value| {
            if (choose_value.domain) |domain| {
                try collect_generated_expressions(allocator, module, domain, params, enabled, identity, entries);
            }
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + 1 > scoped_storage.len) {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            scoped_storage[params.len] = choose_value.var_name;
            try collect_generated_expressions(allocator, module, choose_value.body, scoped_storage[0 .. params.len + 1], enabled, identity, entries);
        },
        .if_then_else => |conditional| {
            try collect_generated_expressions(allocator, module, conditional.cond, params, enabled, identity, entries);
            try collect_generated_expressions(allocator, module, conditional.then_branch, params, enabled, identity, entries);
            try collect_generated_expressions(allocator, module, conditional.else_branch, params, enabled, identity, entries);
        },
        .apply => |application| {
            if (application.func.* == .ident and
                constant_substitution_name(
                    module,
                    application.func.*.ident,
                ) != null)
            {
                return;
            }
            const native_call = application.func.* == .ident and
                is_native_override(application.func.*.ident);
            if (!is_reduce_sequence_call(application) and
                !is_select_sequence_call(application) and
                !native_call)
            {
                try collect_generated_expressions(
                    allocator,
                    module,
                    application.func,
                    params,
                    enabled,
                    identity,
                    entries,
                );
            }
            for (application.args) |argument| {
                try collect_generated_expressions(allocator, module, argument, params, enabled, identity, entries);
            }
        },
        .field => |field_value| try collect_generated_expressions(allocator, module, field_value.expr, params, enabled, identity, entries),
        .tuple, .set_enum => |items| {
            for (items) |item| {
                try collect_generated_expressions(allocator, module, item, params, enabled, identity, entries);
            }
        },
        .record => |fields| {
            for (fields) |field_value| {
                try collect_generated_expressions(allocator, module, field_value.value, params, enabled, identity, entries);
            }
        },
        .set_filter => |filter_value| {
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + filter_value.vars.len > scoped_storage.len) {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            var scoped_len = params.len;
            for (filter_value.vars) |bound| {
                try collect_generated_expressions(allocator, module, bound.domain, scoped_storage[0..scoped_len], enabled, identity, entries);
                scoped_storage[scoped_len] = bound.name;
                scoped_len += 1;
            }
            try collect_generated_expressions(allocator, module, filter_value.pred, scoped_storage[0..scoped_len], enabled, identity, entries);
        },
        .set_map => |map_value| {
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + map_value.vars.len > scoped_storage.len) {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            var scoped_len = params.len;
            for (map_value.vars) |bound| {
                try collect_generated_expressions(allocator, module, bound.domain, scoped_storage[0..scoped_len], enabled, identity, entries);
                scoped_storage[scoped_len] = bound.name;
                scoped_len += 1;
            }
            try collect_generated_expressions(allocator, module, map_value.value, scoped_storage[0..scoped_len], enabled, identity, entries);
        },
        .set_binary => |set_binary| {
            try collect_generated_expressions(allocator, module, set_binary.left, params, enabled, identity, entries);
            try collect_generated_expressions(allocator, module, set_binary.right, params, enabled, identity, entries);
        },
        .set_of_functions => |function_set| {
            try collect_generated_expressions(allocator, module, function_set.domain, params, enabled, identity, entries);
            try collect_generated_expressions(allocator, module, function_set.codomain, params, enabled, identity, entries);
        },
        .function_literal => |function_literal| {
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + function_literal.vars.len >
                scoped_storage.len)
            {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            var scoped_len = params.len;
            for (function_literal.vars) |bound| {
                try collect_generated_expressions(allocator, module, bound.domain, scoped_storage[0..scoped_len], enabled, identity, entries);
                scoped_storage[scoped_len] = bound.name;
                scoped_len += 1;
            }
            try collect_generated_expressions(allocator, module, function_literal.body, scoped_storage[0..scoped_len], enabled, identity, entries);
        },
        .record_set => |record_set_value| {
            for (record_set_value.fields) |field_value| {
                try collect_generated_expressions(allocator, module, field_value.domain, params, enabled, identity, entries);
            }
        },
        .except => |except_value| {
            try collect_generated_expressions(allocator, module, except_value.func, params, enabled, identity, entries);
            for (except_value.steps) |step| {
                if (step == .index) {
                    try collect_generated_expressions(allocator, module, step.index, params, enabled, identity, entries);
                }
            }
            if (params.len == 32) return error.OutOfMemory;
            var extended: [32][]const u8 = @splat("");
            @memcpy(extended[0..params.len], params);
            extended[params.len] = "$at";
            try collect_generated_expressions(
                allocator,
                module,
                except_value.value,
                extended[0 .. params.len + 1],
                enabled,
                identity,
                entries,
            );
        },
        .let_in => |let_value| {
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + let_value.defs.len > scoped_storage.len) {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            var scoped_len = params.len;
            for (let_value.defs) |definition| {
                var definition_storage: [32][]const u8 = @splat("");
                if (scoped_len + definition.params.len >
                    definition_storage.len)
                {
                    return error.OutOfMemory;
                }
                @memcpy(
                    definition_storage[0..scoped_len],
                    scoped_storage[0..scoped_len],
                );
                @memcpy(
                    definition_storage[scoped_len..][0..definition.params.len],
                    definition.params,
                );
                try collect_generated_expressions(allocator, module, definition.body, definition_storage[0 .. scoped_len + definition.params.len], enabled, identity, entries);
                if (definition.function_domain) |domain| {
                    try collect_generated_expressions(allocator, module, domain, scoped_storage[0..scoped_len], enabled, identity, entries);
                }
                scoped_storage[scoped_len] = definition.name;
                scoped_len += 1;
            }
            try collect_generated_expressions(allocator, module, let_value.body, scoped_storage[0..scoped_len], enabled, identity, entries);
        },
        .case_expr => |case_value| {
            for (case_value.arms) |arm| {
                try collect_generated_expressions(allocator, module, arm.cond, params, enabled, identity, entries);
                try collect_generated_expressions(allocator, module, arm.value, params, enabled, identity, entries);
            }
            if (case_value.otherwise) |otherwise| {
                try collect_generated_expressions(allocator, module, otherwise, params, enabled, identity, entries);
            }
        },
        .box_action => |box_action| {
            try collect_generated_expressions(allocator, module, box_action.action, params, enabled, identity, entries);
            try collect_generated_expressions(allocator, module, box_action.vars, params, enabled, identity, entries);
        },
        .lambda => |lambda_value| {
            var scoped_storage: [32][]const u8 = @splat("");
            if (params.len + lambda_value.params.len > scoped_storage.len) {
                return error.OutOfMemory;
            }
            @memcpy(scoped_storage[0..params.len], params);
            @memcpy(
                scoped_storage[params.len..][0..lambda_value.params.len],
                lambda_value.params,
            );
            try collect_generated_expressions(allocator, module, lambda_value.body, scoped_storage[0 .. params.len + lambda_value.params.len], enabled, identity, entries);
        },
        .ident,
        .primed,
        .unchanged,
        .bool_literal,
        .int_literal,
        .string_literal,
        .at,
        => {},
    }
}

pub fn find_expression_identity(
    module: ast.Module,
    target: *const ast.Expr,
) ?usize {
    var identity: usize = 0;
    for (module.definitions) |definition| {
        if (visit_expression(module, definition.body, target, &identity)) {
            return identity;
        }
        if (definition.function_domain) |domain| {
            if (visit_expression(module, domain, target, &identity)) {
                return identity;
            }
        }
    }
    for (module.assumptions) |assumption| {
        if (visit_expression(module, assumption, target, &identity)) {
            return identity;
        }
    }
    return null;
}

fn visit_expression(
    module: ast.Module,
    expr: *const ast.Expr,
    target: *const ast.Expr,
    identity: *usize,
) bool {
    identity.* += 1;
    if (expr == target) return true;
    switch (expr.*) {
        .primed_expr, .unchanged_expr => |operand| {
            return visit_expression(module, operand, target, identity);
        },
        .binary => |binary| {
            return visit_expression(module, binary.left, target, identity) or
                visit_expression(module, binary.right, target, identity);
        },
        .unary => |unary| {
            return visit_expression(module, unary.operand, target, identity);
        },
        .quantifier => |quantifier| {
            for (quantifier.vars) |bound| {
                if (visit_expression(module, bound.domain, target, identity)) {
                    return true;
                }
            }
            return visit_expression(module, quantifier.body, target, identity);
        },
        .choose => |choose_value| {
            if (choose_value.domain) |domain| {
                if (visit_expression(module, domain, target, identity)) return true;
            }
            return visit_expression(module, choose_value.body, target, identity);
        },
        .if_then_else => |conditional| {
            return visit_expression(module, conditional.cond, target, identity) or
                visit_expression(
                    module,
                    conditional.then_branch,
                    target,
                    identity,
                ) or
                visit_expression(
                    module,
                    conditional.else_branch,
                    target,
                    identity,
                );
        },
        .apply => |application| {
            if (application.func.* == .ident and
                constant_substitution_name(
                    module,
                    application.func.*.ident,
                ) != null)
            {
                return false;
            }
            const native_call = application.func.* == .ident and
                is_native_override(application.func.*.ident);
            if (!is_reduce_sequence_call(application) and
                !is_select_sequence_call(application) and
                !native_call)
            {
                if (visit_expression(module, application.func, target, identity)) {
                    return true;
                }
            }
            for (application.args) |argument| {
                if (visit_expression(module, argument, target, identity)) return true;
            }
            return false;
        },
        .field => |field_value| {
            return visit_expression(module, field_value.expr, target, identity);
        },
        .tuple, .set_enum => |items| {
            for (items) |item| {
                if (visit_expression(module, item, target, identity)) return true;
            }
            return false;
        },
        .record => |fields| {
            for (fields) |field_value| {
                if (visit_expression(
                    module,
                    field_value.value,
                    target,
                    identity,
                )) return true;
            }
            return false;
        },
        .set_filter => |filter_value| {
            for (filter_value.vars) |bound| {
                if (visit_expression(module, bound.domain, target, identity)) {
                    return true;
                }
            }
            return visit_expression(module, filter_value.pred, target, identity);
        },
        .set_map => |map_value| {
            for (map_value.vars) |bound| {
                if (visit_expression(module, bound.domain, target, identity)) {
                    return true;
                }
            }
            return visit_expression(module, map_value.value, target, identity);
        },
        .set_binary => |set_binary| {
            return visit_expression(module, set_binary.left, target, identity) or
                visit_expression(module, set_binary.right, target, identity);
        },
        .set_of_functions => |function_set| {
            return visit_expression(
                module,
                function_set.domain,
                target,
                identity,
            ) or visit_expression(
                module,
                function_set.codomain,
                target,
                identity,
            );
        },
        .function_literal => |function_literal| {
            for (function_literal.vars) |bound| {
                if (visit_expression(module, bound.domain, target, identity)) {
                    return true;
                }
            }
            return visit_expression(
                module,
                function_literal.body,
                target,
                identity,
            );
        },
        .record_set => |record_set_value| {
            for (record_set_value.fields) |field_value| {
                if (visit_expression(
                    module,
                    field_value.domain,
                    target,
                    identity,
                )) return true;
            }
            return false;
        },
        .except => |except_value| {
            if (visit_expression(module, except_value.func, target, identity)) {
                return true;
            }
            for (except_value.steps) |step| {
                if (step == .index and
                    visit_expression(module, step.index, target, identity))
                {
                    return true;
                }
            }
            return visit_expression(module, except_value.value, target, identity);
        },
        .let_in => |let_value| {
            for (let_value.defs) |definition| {
                if (visit_expression(
                    module,
                    definition.body,
                    target,
                    identity,
                )) return true;
                if (definition.function_domain) |domain| {
                    if (visit_expression(module, domain, target, identity)) {
                        return true;
                    }
                }
            }
            return visit_expression(module, let_value.body, target, identity);
        },
        .case_expr => |case_value| {
            for (case_value.arms) |arm| {
                if (visit_expression(module, arm.cond, target, identity) or
                    visit_expression(module, arm.value, target, identity))
                {
                    return true;
                }
            }
            if (case_value.otherwise) |otherwise| {
                return visit_expression(module, otherwise, target, identity);
            }
            return false;
        },
        .box_action => |box_action| {
            return visit_expression(
                module,
                box_action.action,
                target,
                identity,
            ) or visit_expression(
                module,
                box_action.vars,
                target,
                identity,
            );
        },
        .lambda => |lambda_value| {
            return visit_expression(module, lambda_value.body, target, identity);
        },
        .ident,
        .primed,
        .unchanged,
        .bool_literal,
        .int_literal,
        .string_literal,
        .at,
        => return false,
    }
}

fn find_definition(
    module: ast.Module,
    name: []const u8,
) ?ast.Definition {
    const index = find_definition_index(module, name) orelse return null;
    return module.definitions[index];
}

const ResolvedConfigSymbol = union(enum) {
    name: []const u8,
    constant: []const u8,
};

fn find_config_replacement(
    module: ast.Module,
    name: []const u8,
) ?ast.ConfigReplacement {
    for (module.config_replacements) |replacement| {
        if (std.mem.eql(u8, replacement.name, name)) return replacement;
    }
    return null;
}

fn resolved_config_symbol(
    module: ast.Module,
    original_name: []const u8,
) ?ResolvedConfigSymbol {
    var name = original_name;
    var depth: u8 = 0;
    while (depth < 64) : (depth += 1) {
        const replacement = find_config_replacement(module, name) orelse
            return if (depth == 0) null else .{ .name = name };
        switch (replacement.kind) {
            .constant => return .{ .constant = name },
            .alias => name = replacement.value,
        }
    }
    std.debug.assert(false);
    return null;
}

fn configured_constant_name(
    module: ast.Module,
    name: []const u8,
) ?[]const u8 {
    const symbol = resolved_config_symbol(module, name) orelse return null;
    return switch (symbol) {
        .constant => |constant_name| constant_name,
        .name => null,
    };
}

fn constant_substitution_name(
    module: ast.Module,
    name: []const u8,
) ?[]const u8 {
    const replacement = find_config_replacement(module, name) orelse
        return null;
    if (!replacement.is_substitution or replacement.kind != .constant) {
        return null;
    }
    return replacement.name;
}

fn resolved_definition_name(
    module: ast.Module,
    name: []const u8,
) ?[]const u8 {
    const symbol = resolved_config_symbol(module, name) orelse
        return if (find_definition_index(module, name) != null) name else null;
    return switch (symbol) {
        .constant => null,
        .name => |resolved_name| if (find_definition_index(
            module,
            resolved_name,
        ) != null)
            resolved_name
        else
            null,
    };
}

const FilteredPowerSetDomain = struct {
    filter_expr: *const ast.Expr,
    base: *const ast.Expr,
};

fn quantifier_constant_domain_index(
    module: ast.Module,
    quantifier: *const ast.Quantifier,
) ?usize {
    if (quantifier.vars.len != 1) return null;
    return expr_constant_index(module, quantifier.vars[0].domain);
}

fn expr_constant_index(
    module: ast.Module,
    expr: *const ast.Expr,
) ?usize {
    if (expr.* != .ident) return null;
    const name = expr.ident;
    if (resolved_config_symbol(module, name)) |symbol| {
        return switch (symbol) {
            .constant => |constant_name| constant_index(module, constant_name),
            .name => |resolved_name| constant_index(module, resolved_name),
        };
    }
    return constant_index(module, name);
}

fn filtered_power_set_domain(
    module: ast.Module,
    quantifier: *const ast.Quantifier,
) ?FilteredPowerSetDomain {
    if (quantifier.vars.len != 1) return null;
    var domain = quantifier.vars[0].domain;
    var depth: u8 = 0;
    while (domain.* == .ident and depth < 16) : (depth += 1) {
        const definition_name = resolved_definition_name(
            module,
            domain.ident,
        ) orelse return null;
        const definition = find_definition(module, definition_name) orelse
            return null;
        if (definition.params.len != 0) return null;
        domain = definition.body;
    }
    if (domain.* != .set_filter) return null;
    const filter_value = domain.set_filter;
    if (filter_value.vars.len != 1) return null;
    const filter_domain = filter_value.vars[0].domain;
    if (filter_domain.* != .unary or
        filter_domain.unary.op != .subset)
    {
        return null;
    }
    return .{
        .filter_expr = domain,
        .base = filter_domain.unary.operand,
    };
}

fn carrier_of_cartesian(
    module: ast.Module,
    base: *const ast.Expr,
) ?[]const u8 {
    if (base.* != .set_binary) return null;
    const set_binary = base.set_binary;
    if (set_binary.op != .cartesian_op) return null;
    if (set_binary.left.* != .ident or set_binary.right.* != .ident) {
        return null;
    }
    const left_name = resolved_definition_name(
        module,
        set_binary.left.ident,
    ) orelse return null;
    const right_name = resolved_definition_name(
        module,
        set_binary.right.ident,
    ) orelse return null;
    if (!std.mem.eql(u8, left_name, right_name)) return null;
    return left_name;
}

const ConjunctList = struct {
    items: [16]*const ast.Expr = undefined,
    len: usize = 0,

    fn append(self: *ConjunctList, expr: *const ast.Expr) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = expr;
        self.len += 1;
    }
};

fn flatten_and(expr: *const ast.Expr, out: *ConjunctList) void {
    if (expr.* == .binary and expr.binary.op == .and_op) {
        flatten_and(expr.binary.left, out);
        flatten_and(expr.binary.right, out);
        return;
    }
    out.append(expr);
}

fn flatten_or(expr: *const ast.Expr, out: *ConjunctList) void {
    if (expr.* == .binary and expr.binary.op == .or_op) {
        flatten_or(expr.binary.left, out);
        flatten_or(expr.binary.right, out);
        return;
    }
    out.append(expr);
}

fn is_named_ident(expr: *const ast.Expr, name: []const u8) bool {
    return expr.* == .ident and std.mem.eql(u8, expr.ident, name);
}

fn is_pair_of(
    expr: *const ast.Expr,
    first: []const u8,
    second: []const u8,
) bool {
    if (expr.* != .tuple or expr.tuple.len != 2) return false;
    return is_named_ident(expr.tuple[0], first) and
        is_named_ident(expr.tuple[1], second);
}

fn is_member_pair(
    expr: *const ast.Expr,
    relation: []const u8,
    first: []const u8,
    second: []const u8,
) bool {
    if (expr.* != .binary or expr.binary.op != .in) return false;
    if (!is_named_ident(expr.binary.right, relation)) return false;
    return is_pair_of(expr.binary.left, first, second);
}

fn is_irreflexive_body(
    body: *const ast.Expr,
    relation: []const u8,
    x: []const u8,
) bool {
    if (body.* != .binary or body.binary.op != .notin) return false;
    if (!is_named_ident(body.binary.right, relation)) return false;
    return is_pair_of(body.binary.left, x, x);
}

fn is_connex_body(
    body: *const ast.Expr,
    relation: []const u8,
    x: []const u8,
    y: []const u8,
) bool {
    var disjuncts = ConjunctList{};
    flatten_or(body, &disjuncts);
    if (disjuncts.len != 3) return false;

    var found_equal = false;
    var found_forward = false;
    var found_backward = false;
    for (disjuncts.items[0..disjuncts.len]) |disjunct| {
        if (disjunct.* == .binary and disjunct.binary.op == .eq and
            is_named_ident(disjunct.binary.left, x) and
            is_named_ident(disjunct.binary.right, y))
        {
            found_equal = true;
        } else if (is_member_pair(disjunct, relation, x, y)) {
            found_forward = true;
        } else if (is_member_pair(disjunct, relation, y, x)) {
            found_backward = true;
        } else {
            return false;
        }
    }
    return found_equal and found_forward and found_backward;
}

fn is_transitive_body(
    body: *const ast.Expr,
    relation: []const u8,
    x: []const u8,
    y: []const u8,
    z: []const u8,
) bool {
    if (body.* != .binary or body.binary.op != .implies) return false;
    var antecedent = ConjunctList{};
    flatten_and(body.binary.left, &antecedent);
    if (antecedent.len != 2) return false;

    var found_xy = false;
    var found_yz = false;
    for (antecedent.items[0..antecedent.len]) |conjunct| {
        if (is_member_pair(conjunct, relation, x, y)) {
            found_xy = true;
        } else if (is_member_pair(conjunct, relation, y, z)) {
            found_yz = true;
        } else {
            return false;
        }
    }
    return found_xy and found_yz and
        is_member_pair(body.binary.right, relation, x, z);
}

fn is_total_order_filter(
    module: ast.Module,
    filter_expr: *const ast.Expr,
    relation: []const u8,
    carrier: []const u8,
) bool {
    var conjuncts = ConjunctList{};
    flatten_and(filter_expr, &conjuncts);
    if (conjuncts.len != 3) return false;

    var found_connex = false;
    var found_transitive = false;
    var found_irreflexive = false;
    for (conjuncts.items[0..conjuncts.len]) |conjunct| {
        if (conjunct.* != .quantifier) return false;
        const quantifier = conjunct.quantifier;
        if (quantifier.kind != .forall) return false;
        for (quantifier.vars) |bound| {
            if (bound.domain.* != .ident) return false;
            const resolved = resolved_definition_name(
                module,
                bound.domain.ident,
            ) orelse bound.domain.ident;
            if (!std.mem.eql(u8, resolved, carrier)) return false;
        }
        switch (quantifier.vars.len) {
            1 => {
                if (!is_irreflexive_body(
                    quantifier.body,
                    relation,
                    quantifier.vars[0].name,
                )) return false;
                found_irreflexive = true;
            },
            2 => {
                if (!is_connex_body(
                    quantifier.body,
                    relation,
                    quantifier.vars[0].name,
                    quantifier.vars[1].name,
                )) return false;
                found_connex = true;
            },
            3 => {
                if (!is_transitive_body(
                    quantifier.body,
                    relation,
                    quantifier.vars[0].name,
                    quantifier.vars[1].name,
                    quantifier.vars[2].name,
                )) return false;
                found_transitive = true;
            },
            else => return false,
        }
    }
    return found_connex and found_transitive and found_irreflexive;
}

fn find_definition_index(
    module: ast.Module,
    name: []const u8,
) ?usize {
    for (module.definitions, 0..) |definition, index| {
        if (std.mem.eql(u8, definition.name, name)) return index;
    }
    return null;
}

fn param_index(
    params: []const []const u8,
    name: []const u8,
) ?usize {
    for (params, 0..) |param, index| {
        if (std.mem.eql(u8, param, name)) return index;
    }
    return null;
}

fn variable_index(module: ast.Module, name: []const u8) ?usize {
    for (module.variables, 0..) |variable, index| {
        if (std.mem.eql(u8, variable, name)) return index;
    }
    return null;
}

fn constant_index(module: ast.Module, name: []const u8) ?usize {
    for (module.constants, 0..) |constant_name, index| {
        if (std.mem.eql(u8, constant_name, name)) return index;
    }
    return null;
}

fn variable_application_index(
    module: ast.Module,
    application: *const ast.Apply,
) ?u32 {
    if (application.args.len != 1) return null;
    return switch (application.func.*) {
        .ident => |name| if (variable_index(module, name)) |index|
            @intCast(index)
        else
            null,
        .apply => |parent| variable_application_index(module, parent),
        else => null,
    };
}

fn emit_field_path_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (try emit_sequence_head_field_path_comparison(
        output,
        allocator,
        module,
        binary,
        params,
    )) return true;

    const left_is_field_path = binary.left.* == .field and
        binary.left.field.expr.* == .apply and
        variable_application_index(module, binary.left.field.expr.apply) != null and
        binary.right.* != .field;
    const right_is_field_path = binary.right.* == .field and
        binary.right.field.expr.* == .apply and
        variable_application_index(module, binary.right.field.expr.apply) != null and
        binary.left.* != .field;
    if (!left_is_field_path and !right_is_field_path) return false;

    const field_expr = if (left_is_field_path)
        binary.left.field
    else
        binary.right.field;
    const other = if (left_is_field_path) binary.right else binary.left;
    const variable = variable_application_index(
        module,
        field_expr.expr.apply,
    ).?;
    const function_name = if (binary.op == .eq)
        "variable_path_field_equal_bool"
    else
        "variable_path_field_not_equal_bool";
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.{s}(context, {d}, &[_]Value{{",
        .{ function_name, variable },
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    try emit_variable_application_keys(
        output,
        allocator,
        module,
        field_expr.expr.apply,
        params,
    );
    const middle = try std.fmt.allocPrint(
        allocator,
        "}}, \"{f}\", ",
        .{std.zig.fmtString(field_expr.name)},
    );
    defer allocator.free(middle);
    try append(output, allocator, middle);
    try emit_expr(output, allocator, module, other, params);
    try append(output, allocator, ")");
    return true;
}

fn emit_field_path_boolean(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    expr: *const ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (sequence_head_field_path(module, expr)) |field_path| {
        try emit_field_path_call(
            output,
            allocator,
            module,
            "variable_path_sequence_head_field_boolean",
            field_path.variable,
            field_path.application,
            field_path.field_name,
            params,
            null,
        );
        return true;
    }
    if (direct_field_path(module, expr)) |field_path| {
        try emit_field_path_call(
            output,
            allocator,
            module,
            "variable_path_field_boolean",
            field_path.variable,
            field_path.application,
            field_path.field_name,
            params,
            null,
        );
        return true;
    }
    return false;
}

fn emit_field_path_membership(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (binary.right.* == .field) return false;
    const sequence_path = sequence_head_field_path(module, binary.left);
    const direct_path = direct_field_path(module, binary.left);
    const field_path = sequence_path orelse direct_path orelse return false;
    const function_name = if (sequence_path != null)
        "variable_path_sequence_head_field_member_bool"
    else
        "variable_path_field_member_bool";
    if (binary.op == .notin) try append(output, allocator, "!(");
    try emit_field_path_call(
        output,
        allocator,
        module,
        function_name,
        field_path.variable,
        field_path.application,
        field_path.field_name,
        params,
        binary.right,
    );
    if (binary.op == .notin) try append(output, allocator, ")");
    return true;
}

const MembershipResult = enum {
    boolean,
    value,
};

fn emit_string_literal_set_membership(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
    result: MembershipResult,
) error{OutOfMemory}!bool {
    if (binary.op != .in and binary.op != .notin) return false;
    const items = string_literal_set_items(binary.right) orelse return false;
    if (result == .value) {
        try append(output, allocator, "Value{ .bool_v = ");
    }
    if (binary.op == .notin) try append(output, allocator, "!");
    try append(
        output,
        allocator,
        "try runtime.string_literal_member_bool(context, ",
    );
    try emit_expr(output, allocator, module, binary.left, params);
    try append(output, allocator, ", &[_][]const u8{");
    for (items, 0..) |item, index| {
        if (index > 0) try append(output, allocator, ", ");
        const literal = try std.fmt.allocPrint(
            allocator,
            "\"{f}\"",
            .{std.zig.fmtString(item.string_literal)},
        );
        defer allocator.free(literal);
        try append(output, allocator, literal);
    }
    try append(output, allocator, "})");
    if (result == .value) {
        try append(output, allocator, " }");
    }
    return true;
}

fn string_literal_set_items(expr: *const ast.Expr) ?[]const *ast.Expr {
    if (expr.* != .set_enum) return null;
    if (expr.set_enum.len == 0) return null;
    for (expr.set_enum) |item| {
        if (item.* != .string_literal) return null;
    }
    return expr.set_enum;
}

fn emit_sequence_head_field_path_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    const left = sequence_head_field_path(module, binary.left);
    const right = sequence_head_field_path(module, binary.right);
    if (left == null and right == null) return false;
    if (left != null and right != null) return false;
    const field_path = left orelse right.?;
    const other = if (left != null) binary.right else binary.left;
    const function_name = if (binary.op == .eq)
        "variable_path_sequence_head_field_equal_bool"
    else
        "variable_path_sequence_head_field_not_equal_bool";
    try emit_field_path_call(
        output,
        allocator,
        module,
        function_name,
        field_path.variable,
        field_path.application,
        field_path.field_name,
        params,
        other,
    );
    return true;
}

fn emit_field_path_call(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    function_name: []const u8,
    variable: u32,
    application: *const ast.Apply,
    field_name: []const u8,
    params: []const []const u8,
    extra_arg: ?*const ast.Expr,
) error{OutOfMemory}!void {
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.{s}(context, {d}, &[_]Value{{",
        .{ function_name, variable },
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    try emit_variable_application_keys(
        output,
        allocator,
        module,
        application,
        params,
    );
    const middle = try std.fmt.allocPrint(
        allocator,
        "}}, \"{f}\"",
        .{std.zig.fmtString(field_name)},
    );
    defer allocator.free(middle);
    try append(output, allocator, middle);
    if (extra_arg) |argument| {
        try append(output, allocator, ", ");
        try emit_expr(output, allocator, module, argument, params);
    }
    try append(output, allocator, ")");
}

const SequenceHeadFieldPath = struct {
    variable: u32,
    application: *const ast.Apply,
    field_name: []const u8,
};

fn direct_field_path(
    module: ast.Module,
    expr: *const ast.Expr,
) ?SequenceHeadFieldPath {
    if (expr.* != .field) return null;
    const field_value = expr.field;
    if (field_value.expr.* != .apply) return null;
    const variable = variable_application_index(
        module,
        field_value.expr.apply,
    ) orelse return null;
    return .{
        .variable = variable,
        .application = field_value.expr.apply,
        .field_name = field_value.name,
    };
}

fn sequence_head_field_path(
    module: ast.Module,
    expr: *const ast.Expr,
) ?SequenceHeadFieldPath {
    if (expr.* != .field) return null;
    const field_value = expr.field;
    if (field_value.expr.* != .apply) return null;
    const head = field_value.expr.apply;
    if (head.func.* != .ident or
        !std.mem.eql(u8, head.func.ident, "Head") or
        head.args.len != 1 or
        head.args[0].* != .apply)
    {
        return null;
    }
    const variable = variable_application_index(
        module,
        head.args[0].apply,
    ) orelse return null;
    return .{
        .variable = variable,
        .application = head.args[0].apply,
        .field_name = field_value.name,
    };
}

fn emit_variable_path_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (binary.left.* == .apply and binary.right.* != .apply) {
        if (variable_application_index(module, binary.left.apply)) |index| {
            return try emit_one_sided_path_comparison(
                output,
                allocator,
                module,
                binary,
                index,
                binary.left.apply,
                binary.right,
                params,
            );
        }
    }
    if (binary.right.* == .apply and binary.left.* != .apply) {
        if (variable_application_index(module, binary.right.apply)) |index| {
            return try emit_one_sided_path_comparison(
                output,
                allocator,
                module,
                binary,
                index,
                binary.right.apply,
                binary.left,
                params,
            );
        }
    }
    return false;
}

fn emit_variable_path_membership(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (binary.right.* != .apply) return false;
    const variable = variable_application_index(
        module,
        binary.right.apply,
    ) orelse return false;
    const function_name = if (binary.op == .in)
        "variable_path_member_bool"
    else
        "variable_path_not_member_bool";
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.{s}(context, {d}, &[_]Value{{",
        .{ function_name, variable },
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    try emit_variable_application_keys(
        output,
        allocator,
        module,
        binary.right.apply,
        params,
    );
    try append(output, allocator, "}, ");
    try emit_expr(output, allocator, module, binary.left, params);
    try append(output, allocator, ")");
    return true;
}

fn emit_primed_except_update_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (binary.op != .eq and binary.op != .ne) return false;

    if (try emit_one_sided_primed_except_update_comparison(
        output,
        allocator,
        module,
        binary.op,
        binary.left,
        binary.right,
        params,
    )) return true;

    return try emit_one_sided_primed_except_update_comparison(
        output,
        allocator,
        module,
        binary.op,
        binary.right,
        binary.left,
        params,
    );
}

fn emit_one_sided_primed_except_update_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    operator: ast.BinaryOp,
    primed_expr: *ast.Expr,
    except_expr: *ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    const variable = primed_variable_index(module, primed_expr) orelse
        return false;
    if (except_expr.* != .except) return false;
    const except_value = except_expr.except;
    if (except_value.func.* != .ident) return false;
    const updated_variable: u32 = @intCast(
        variable_index(module, except_value.func.ident) orelse return false,
    );
    if (variable != updated_variable) return false;

    if (operator == .ne) try append(output, allocator, "!(");
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.primed_variable_except_update_equal_bool(context, args, {d}, &[_]Value{{",
        .{variable},
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    try emit_except_update_steps(
        output,
        allocator,
        module,
        except_value.steps,
        params,
    );
    const helper = try helper_name(
        allocator,
        expression_identity(module, except_expr),
    );
    defer allocator.free(helper);
    try append(output, allocator, "}, ");
    try append(output, allocator, helper);
    try append(output, allocator, ")");
    if (operator == .ne) try append(output, allocator, ")");
    return true;
}

fn primed_variable_index(
    module: ast.Module,
    expr: *const ast.Expr,
) ?u32 {
    if (expr.* != .primed) return null;
    const index = variable_index(module, expr.primed) orelse return null;
    return @intCast(index);
}

fn emit_except_update_steps(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    steps: []const ast.AccessStep,
    params: []const []const u8,
) error{OutOfMemory}!void {
    for (steps, 0..) |step, index| {
        if (index > 0) try append(output, allocator, ", ");
        switch (step) {
            .field => |field_name| {
                const field = try std.fmt.allocPrint(
                    allocator,
                    "try runtime.string(context, \"{f}\")",
                    .{std.zig.fmtString(field_name)},
                );
                defer allocator.free(field);
                try append(output, allocator, field);
            },
            .index => |index_expr| try emit_expr(
                output,
                allocator,
                module,
                index_expr,
                params,
            ),
        }
    }
}

fn emit_variable_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    if (binary.left.* == .ident and binary.right.* != .ident) {
        if (variable_index(module, binary.left.ident)) |index| {
            return try emit_one_sided_variable_comparison(
                output,
                allocator,
                module,
                binary,
                @intCast(index),
                binary.right,
                params,
            );
        }
    }
    if (binary.right.* == .ident and binary.left.* != .ident) {
        if (variable_index(module, binary.right.ident)) |index| {
            return try emit_one_sided_variable_comparison(
                output,
                allocator,
                module,
                binary,
                @intCast(index),
                binary.left,
                params,
            );
        }
    }
    return false;
}

fn emit_one_sided_variable_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    variable: u32,
    other: *ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    const function_name = if (binary.op == .eq)
        "variable_equal_bool"
    else
        "variable_not_equal_bool";
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.{s}(context, {d}, ",
        .{ function_name, variable },
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    try emit_expr(output, allocator, module, other, params);
    try append(output, allocator, ")");
    return true;
}

fn emit_one_sided_path_comparison(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    binary: *const ast.Binary,
    variable: u32,
    path_application: *const ast.Apply,
    other: *ast.Expr,
    params: []const []const u8,
) error{OutOfMemory}!bool {
    const function_name = if (binary.op == .eq)
        "variable_path_equal_bool"
    else
        "variable_path_not_equal_bool";
    const prefix = try std.fmt.allocPrint(
        allocator,
        "try runtime.{s}(context, {d}, &[_]Value{{",
        .{ function_name, variable },
    );
    defer allocator.free(prefix);
    try append(output, allocator, prefix);
    try emit_variable_application_keys(
        output,
        allocator,
        module,
        path_application,
        params,
    );
    try append(output, allocator, "}, ");
    try emit_expr(output, allocator, module, other, params);
    try append(output, allocator, ")");
    return true;
}

fn emit_variable_application_keys(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module: ast.Module,
    application: *const ast.Apply,
    params: []const []const u8,
) error{OutOfMemory}!void {
    if (application.func.* == .apply) {
        try emit_variable_application_keys(
            output,
            allocator,
            module,
            application.func.apply,
            params,
        );
        try append(output, allocator, ", ");
    }
    std.debug.assert(application.args.len == 1);
    try emit_expr(
        output,
        allocator,
        module,
        application.args[0],
        params,
    );
}

fn zig_operator_name(
    allocator: std.mem.Allocator,
    definition_index: usize,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "op_{d}",
        .{definition_index},
    );
}

fn zig_boolean_operator_name(
    allocator: std.mem.Allocator,
    definition_index: usize,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "op_{d}_bool",
        .{definition_index},
    );
}

fn append(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    try output.appendSlice(allocator, bytes);
}

test "emit scalar and direct native operators without fallbacks" {
    const Arena = @import("arena.zig").Arena;
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE Generated ----------------------
        \\Inc(x) == x + 1
        \\Positive(x) == Inc(x) > 0
        \\Unsupported(S) == Cardinality(S)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const result = try emit_module(
        std.testing.allocator,
        module,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), result.generated_count);
    try std.testing.expectEqual(@as(u32, 0), result.fallback_count);
    try std.testing.expectEqual(@as(usize, 0), result.unsupported.len);
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "pub fn op_0") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "try op_0") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "runtime.cardinality(context",
    ) != null);
}

test "configuration roots are emitted with transitive dependencies" {
    const Arena = @import("arena.zig").Arena;
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE GeneratedRoots ----------------------
        \\Init == TRUE
        \\Next == TRUE
        \\Helper(x) == x + 1
        \\ConfiguredInvariant == Helper(0) = 1
        \\Unused == Cardinality({})
        \\===================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const result = try emit_module_with_roots(
        std.testing.allocator,
        module,
        &.{"ConfiguredInvariant"},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), result.generated_count);
    try std.testing.expectEqual(@as(u32, 0), result.fallback_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "pub const module_name = \"GeneratedRoots\";",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "pub const root_names = [_][]const u8{\"ConfiguredInvariant\"};",
    ) != null);
}

test "configuration replacements remove shadowed fallbacks" {
    const Arena = @import("arena.zig").Arena;
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE ConfiguredGeneration ----------------------
        \\Init == Shadow = Shadow /\ Alias = 1
        \\Next == TRUE
        \\Shadow == CHOOSE x : TRUE
        \\Alias == CHOOSE x : TRUE
        \\Target == 1
        \\=========================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    var module = try module_parser.parse_module();
    module.config_replacements = &.{
        .{
            .name = "Shadow",
            .value = "Shadow",
            .kind = .constant,
        },
        .{
            .name = "Alias",
            .value = "Target",
            .kind = .alias,
        },
    };
    const result = try emit_module_with_roots(
        std.testing.allocator,
        module,
        &.{ "Init", "Next" },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), result.generated_count);
    try std.testing.expectEqual(@as(u32, 0), result.fallback_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "runtime.constant(context, \"Shadow\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "try op_4(context",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "pub const config_replacements_hash: u64 = 0x",
    ) != null);
}

test "configured operator replacement wins over direct native lowering" {
    const Arena = @import("arena.zig").Arena;
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE ConfiguredNative ----------------------
        \\LimitedSeq(S) == {<<1>>}
        \\Sequences == Seq({1, 2})
        \\====================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    var module = try module_parser.parse_module();
    module.config_replacements = &.{
        .{
            .name = "Seq",
            .value = "LimitedSeq",
            .kind = .alias,
            .is_substitution = true,
        },
    };
    const result = try emit_module(std.testing.allocator, module);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), result.generated_count);
    try std.testing.expectEqual(@as(u32, 0), result.fallback_count);
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.sequence_set(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "try op_0(context") != null,
    );
}

test "generated Cartesian products use the direct runtime path" {
    const Arena = @import("arena.zig").Arena;
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE CartesianGeneration ----------------------
        \\Product == {1, 2} \X {3, 4}
        \\========================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const result = try emit_module(std.testing.allocator, module);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.generated_count);
    try std.testing.expectEqual(@as(u32, 0), result.fallback_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "runtime.cartesian_product(context",
    ) != null);
}

test "generated binary operators do not use named native dispatch" {
    const Arena = @import("arena.zig").Arena;
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE DirectBinary ----------------------
        \\Concat == <<1>> \o <<2>>
        \\Singleton == "key" :> 1
        \\Override == Singleton @@ ("key" :> 2)
        \\Sequences == Seq({1, 2})
        \\=================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const result = try emit_module(std.testing.allocator, module);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), result.generated_count);
    try std.testing.expectEqual(@as(u32, 0), result.fallback_count);
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.native(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.native_binary(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.sequence_concat(") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.override(") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.record_to(") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.source, "runtime.sequence_set(") != null,
    );
}
