const std = @import("std");
const ast = @import("ast.zig");

pub const HereditaryPowerSetFilter = struct {
    base: *ast.Expr,
    element_name: []const u8,
    predicate: *ast.Expr,
};

/// Recognizes {outer \in SUBSET base : \A element \in outer : predicate}.
pub fn hereditary_power_set_filter(
    filter: *const ast.SetFilter,
) ?HereditaryPowerSetFilter {
    if (filter.vars.len != 1 or
        filter.vars[0].domain.* != .unary or
        filter.vars[0].domain.unary.op != .subset or
        filter.pred.* != .quantifier)
    {
        return null;
    }
    const outer_name = filter.vars[0].name;
    const predicate = filter.pred.quantifier;
    if (predicate.kind != .forall or
        predicate.vars.len != 1 or
        predicate.vars[0].domain.* != .ident or
        !std.mem.eql(
            u8,
            predicate.vars[0].domain.ident,
            outer_name,
        ))
    {
        return null;
    }
    return .{
        .base = filter.vars[0].domain.unary.operand,
        .element_name = predicate.vars[0].name,
        .predicate = predicate.body,
    };
}
