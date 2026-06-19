const Value = @import("value.zig").Value;

pub const Module = struct {
    name: []const u8,
    extends: []const []const u8,
    variables: []const []const u8,
    constants: []const []const u8,
    definitions: []const Definition,
    assumptions: []const *Expr,
    instances: []const Instance,
    namespace_instances: []const NamespaceInstance,
    init_name: []const u8,
    next_name: []const u8,
    invariants: []const []const u8,
};

pub const Instance = struct {
    module_name: []const u8,
    substitutions: []const Substitution,
};

pub const NamespaceInstance = struct {
    alias: []const u8,
    params: []const []const u8,
    module_name: []const u8,
    substitutions: []const Substitution,
};

pub const Substitution = struct {
    local_name: []const u8,
    expr: *Expr,
};

pub const Definition = struct {
    name: []const u8,
    params: []const []const u8,
    body: *Expr,
    is_function: bool = false,
    function_var: []const u8 = "",
    function_vars: []const []const u8 = &.{},
    function_domain: ?*Expr = null,
};

pub const Expr = union(ExprTag) {
    bool_literal: bool,
    int_literal: i64,
    string_literal: []const u8,
    ident: []const u8,
    primed: []const u8,
    primed_expr: *Expr,
    unchanged: []const []const u8,
    unchanged_expr: *Expr,
    binary: *Binary,
    unary: *Unary,
    quantifier: *Quantifier,
    choose: *Choose,
    if_then_else: *IfThenElse,
    apply: *Apply,
    field: *Field,
    tuple: []const *Expr,
    record: []const FieldInit,
    set_enum: []const *Expr,
    set_filter: *SetFilter,
    set_map: *SetMap,
    set_binary: *SetBinary,
    set_of_functions: *SetOfFunctions,
    function_literal: *FunctionLiteral,
    record_set: *RecordSet,
    except: *Except,
    let_in: *LetIn,
    case_expr: *CaseExpr,
    box_action: *BoxAction,
    lambda: *Lambda,
    at,
};

pub const ExprTag = enum(u8) {
    bool_literal,
    int_literal,
    string_literal,
    ident,
    primed,
    primed_expr,
    unchanged,
    unchanged_expr,
    binary,
    unary,
    quantifier,
    choose,
    if_then_else,
    apply,
    field,
    tuple,
    record,
    set_enum,
    set_filter,
    set_map,
    set_binary,
    set_of_functions,
    function_literal,
    record_set,
    except,
    let_in,
    case_expr,
    box_action,
    lambda,
    at,
};

pub const BinaryOp = enum(u8) {
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
    set_union,
    set_intersection,
    set_difference,
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

pub const UnaryOp = enum(u8) {
    not,
    neg,
    subset,
    union_all,
    domain,
    temporal_box,
    temporal_diamond,
    enabled,
};

pub const Binary = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
};

pub const Unary = struct {
    op: UnaryOp,
    operand: *Expr,
};

pub const QuantifierKind = enum(u8) { exists, forall };

pub const Quantifier = struct {
    kind: QuantifierKind,
    vars: []const BoundVar,
    body: *Expr,
};

pub const BoundVar = struct {
    name: []const u8,
    domain: *Expr,
};

pub const Choose = struct {
    var_name: []const u8,
    domain: ?*Expr,
    body: *Expr,
};

pub const IfThenElse = struct {
    cond: *Expr,
    then_branch: *Expr,
    else_branch: *Expr,
};

pub const Apply = struct {
    func: *Expr,
    args: []const *Expr,
};

pub const Field = struct {
    expr: *Expr,
    name: []const u8,
};

pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
};

pub const SetFilter = struct {
    vars: []const BoundVar,
    pred: *Expr,
};

pub const SetMap = struct {
    vars: []const BoundVar,
    value: *Expr,
};

pub const SetBinaryOp = enum(u8) { union_op, intersection_op, difference_op, cartesian_op };

pub const SetBinary = struct {
    op: SetBinaryOp,
    left: *Expr,
    right: *Expr,
};

pub const FunctionLiteral = struct {
    vars: []const BoundVar,
    body: *Expr,
};

pub const AccessStep = union(enum(u8)) {
    field: []const u8,
    index: *Expr,
};

pub const Except = struct {
    func: *Expr,
    steps: []const AccessStep,
    value: *Expr,
};

pub const SetOfFunctions = struct {
    domain: *Expr,
    codomain: *Expr,
};

pub const RecordFieldDomain = struct {
    name: []const u8,
    domain: *Expr,
};

pub const RecordSet = struct {
    fields: []const RecordFieldDomain,
};

pub const LetIn = struct {
    defs: []const Definition,
    body: *Expr,
};

pub const CaseArm = struct {
    cond: *Expr,
    value: *Expr,
};

pub const CaseExpr = struct {
    arms: []const CaseArm,
    otherwise: ?*Expr,
};

pub const BoxAction = struct {
    action: *Expr,
    vars: *Expr,
};

pub const Lambda = struct {
    params: []const []const u8,
    body: *Expr,
};
