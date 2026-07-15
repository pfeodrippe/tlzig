const std = @import("std");
const ast = @import("ast.zig");

pub const BoundedSequenceMap = struct {
    lengths: *const ast.Expr,
    element_set: *const ast.Expr,
};

/// Matches a bounded set of functions over `1..n` without depending on the
/// name of the enclosing operator. Keeping this structural makes the same
/// optimization available to every specification.
pub fn bounded_sequence_map(
    map_value: *const ast.SetMap,
) ?BoundedSequenceMap {
    if (map_value.vars.len != 1 or
        map_value.value.* != .set_of_functions)
    {
        return null;
    }
    const bound = map_value.vars[0];
    const function_set = map_value.value.set_of_functions;
    if (function_set.domain.* != .binary or
        function_set.domain.binary.op != .range)
    {
        return null;
    }
    const domain = function_set.domain.binary;
    if (domain.left.* != .int_literal or domain.left.int_literal != 1 or
        domain.right.* != .ident or
        !std.mem.eql(u8, domain.right.ident, bound.name) or
        function_set.codomain.* != .ident or
        std.mem.eql(u8, function_set.codomain.ident, bound.name))
    {
        return null;
    }
    return .{
        .lengths = bound.domain,
        .element_set = function_set.codomain,
    };
}

pub fn bounded_sequence_union(
    expression: *const ast.Expr,
) ?BoundedSequenceMap {
    if (expression.* != .unary or expression.unary.op != .union_all or
        expression.unary.operand.* != .set_map)
    {
        return null;
    }
    return bounded_sequence_map(expression.unary.operand.set_map);
}

pub fn bounded_sequence_definition(
    definition: ast.Definition,
) ?BoundedSequenceMap {
    if (definition.params.len != 1) return null;
    const shape = bounded_sequence_union(definition.body) orelse return null;
    if (!std.mem.eql(
        u8,
        shape.element_set.ident,
        definition.params[0],
    )) return null;
    return shape;
}

pub fn is_sorted_sequence_predicate(
    expression: *const ast.Expr,
    sequence_name: []const u8,
) bool {
    if (expression.* != .quantifier) return false;
    const quantifier = expression.quantifier;
    if (quantifier.kind != .forall or quantifier.vars.len != 2) return false;
    const left_index = quantifier.vars[0].name;
    const right_index = quantifier.vars[1].name;
    if (!is_one_to_len_range(
        quantifier.vars[0].domain,
        sequence_name,
    ) or !is_one_to_len_range(
        quantifier.vars[1].domain,
        sequence_name,
    )) return false;
    if (quantifier.body.* != .binary or
        quantifier.body.binary.op != .implies)
    {
        return false;
    }
    const implication = quantifier.body.binary;
    return is_binary_ident_ident(
        implication.left,
        .lt,
        left_index,
        right_index,
    ) and is_sequence_index_order(
        implication.right,
        .le,
        sequence_name,
        left_index,
        right_index,
    );
}

fn is_one_to_len_range(
    expression: *const ast.Expr,
    sequence_name: []const u8,
) bool {
    if (expression.* != .binary or expression.binary.op != .range) {
        return false;
    }
    const range = expression.binary;
    if (range.left.* != .int_literal or range.left.int_literal != 1 or
        range.right.* != .apply)
    {
        return false;
    }
    const application = range.right.apply;
    return application.func.* == .ident and
        std.mem.eql(u8, application.func.ident, "Len") and
        application.args.len == 1 and
        is_ident(application.args[0], sequence_name);
}

fn is_binary_ident_ident(
    expression: *const ast.Expr,
    operation: ast.BinaryOp,
    left_name: []const u8,
    right_name: []const u8,
) bool {
    if (expression.* != .binary) return false;
    const binary = expression.binary;
    return binary.op == operation and
        is_ident(binary.left, left_name) and
        is_ident(binary.right, right_name);
}

fn is_sequence_index_order(
    expression: *const ast.Expr,
    operation: ast.BinaryOp,
    sequence_name: []const u8,
    left_index: []const u8,
    right_index: []const u8,
) bool {
    if (expression.* != .binary) return false;
    const binary = expression.binary;
    return binary.op == operation and
        is_sequence_index(binary.left, sequence_name, left_index) and
        is_sequence_index(binary.right, sequence_name, right_index);
}

fn is_sequence_index(
    expression: *const ast.Expr,
    sequence_name: []const u8,
    index_name: []const u8,
) bool {
    if (expression.* != .apply) return false;
    const application = expression.apply;
    return is_ident(application.func, sequence_name) and
        application.args.len == 1 and
        is_ident(application.args[0], index_name);
}

fn is_ident(expression: *const ast.Expr, name: []const u8) bool {
    return expression.* == .ident and
        std.mem.eql(u8, expression.ident, name);
}
