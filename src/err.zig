pub const Error = error{
    OutOfMemory,
    SyntaxError,
    UndefinedSymbol,
    TypeError,
    DivisionByZero,
    EmptyChoose,
    IndexOutOfBounds,
    StateSpaceExhausted,
    InvariantViolated,
    Deadlock,
    ConfigError,
    NotImplemented,
    AssertionFailed,
    PropertyViolated,
    IoError,
};

pub const ErrorInfo = struct {
    message: []const u8,
    line: u32,
    column: u32,
};
