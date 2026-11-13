const std = @import("std");
const testing = std.testing;

const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("./parser.zig").Parser;
const Object = @import("./object.zig").Object;
const VmState = @import("./vm_state.zig").VmState;

/// Compiles and runs one REPL line against `state`. As in the REPL, the
/// source, AST, and compiler are freed before the next line runs.
fn runLine(state: *VmState, line: []const u8) !Object {
    const allocator = testing.allocator;

    const source = try allocator.dupe(u8, line);
    defer {
        @memset(source, 0);
        allocator.free(source);
    }

    var lexer = Lexer.init(source);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();
    try testing.expectEqual(0, parser.allErrors().len);

    var comp = try state.newCompiler();
    defer comp.deinit();
    try state.compile(&comp, program);

    var test_writer = std.Io.Writer.Allocating.init(allocator);
    defer test_writer.deinit();
    var vm = try state.newVm(comp.bytecode(), &test_writer.writer);
    try vm.run();

    return vm.lastPoppedStackElem() orelse error.TestUnexpectedResult;
}

test "functions defined on an earlier line can be called" {
    var state = VmState.init(testing.allocator);
    defer state.deinit();

    _ = try runLine(&state, "let addOne = fn(x) { x + 1 };");
    const result = try runLine(&state, "addOne(2)");

    try testing.expectEqual(@as(i64, 3), result.int.value);
}

test "a line that fails to compile defines none of its names" {
    var state = VmState.init(testing.allocator);
    defer state.deinit();

    _ = try runLine(&state, "let kept = 1;");
    try testing.expectError(error.UndefinedVariable, runLine(&state, "let kept = 2; let broken = fn() { missing };"));

    try testing.expectEqual(@as(i64, 1), (try runLine(&state, "kept")).int.value);
    try testing.expectError(error.UndefinedVariable, runLine(&state, "broken"));
}

test "a name whose value failed at run time is null" {
    var state = VmState.init(testing.allocator);
    defer state.deinit();

    try testing.expectError(error.TypeMismatch, runLine(&state, "let failed = 1 + \"a\";"));

    try testing.expect(try runLine(&state, "failed") == .null);
}

test "strings bound on an earlier line keep their value" {
    var state = VmState.init(testing.allocator);
    defer state.deinit();

    _ = try runLine(&state, "let greeting = \"hello\";");
    const result = try runLine(&state, "greeting");

    try testing.expectEqualStrings("hello", result.string.value);
}
