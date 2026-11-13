const std = @import("std");
const testing = std.testing;

const compiler = @import("./compiler.zig");
const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("./parser.zig").Parser;
const Object = @import("./object.zig").Object;
const vm_mod = @import("./vm.zig");
const Vm = vm_mod.Vm;
const SymbolTable = @import("./symbol_table.zig").SymbolTable;

const Compiler = compiler.Compiler;

const HashEntry = struct {
    key: Object.HashKey,
    value: i64,
};

const Expected = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    int_array: []const i64,
    int_hash: []const HashEntry,
    err: []const u8,
    null,
};

const VmTestCase = struct {
    input: []const u8,
    expected: Expected,
};

fn parse(allocator: std.mem.Allocator, input: []const u8) !*@import("./ast.zig").Program {
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    return try parser.parse();
}

fn testIntegerObject(expected: i64, obj: Object) !void {
    const integer = switch (obj) {
        .int => |value| value,
        else => {
            std.debug.print("object is not Integer. got={s}\n", .{obj.typeName()});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(expected, integer.value);
}

fn testBooleanObject(expected: bool, obj: Object) !void {
    const boolean = switch (obj) {
        .bool => |value| value,
        else => {
            std.debug.print("object is not Boolean. got={s}\n", .{obj.typeName()});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(expected, boolean.value);
}

fn testNullObject(obj: Object) !void {
    if (obj != .null) {
        std.debug.print("object is not Null. got={s}\n", .{obj.typeName()});
        return error.TestUnexpectedResult;
    }
}

fn testStringObject(expected: []const u8, obj: Object) !void {
    const str = switch (obj) {
        .string => |value| value,
        else => {
            std.debug.print("object is not String. got={s}\n", .{obj.typeName()});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings(expected, str.value);
}

fn testErrorObject(expected_msg: []const u8, obj: Object) !void {
    const err_obj = switch (obj) {
        .err => |e| e,
        else => {
            std.debug.print("object is not Error. got={s}\n", .{obj.typeName()});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings(expected_msg, err_obj.msg);
}

fn testFloatObject(expected: f64, obj: Object) !void {
    const float = switch (obj) {
        .float => |value| value,
        else => {
            std.debug.print("object is not Float. got={s}\n", .{obj.typeName()});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(expected, float.value);
}

fn testExpectedObject(expected: Expected, obj: Object) !void {
    switch (expected) {
        .int => |val| try testIntegerObject(val, obj),
        .float => |val| try testFloatObject(val, obj),
        .boolean => |val| try testBooleanObject(val, obj),
        .string => |val| try testStringObject(val, obj),
        .err => |val| try testErrorObject(val, obj),
        .int_array => |expected_elements| {
            const array = switch (obj) {
                .array => |a| a,
                else => {
                    std.debug.print("object is not Array. got={s}\n", .{obj.typeName()});
                    return error.TestUnexpectedResult;
                },
            };
            try testing.expectEqual(expected_elements.len, array.elements.len);
            for (expected_elements, array.elements) |exp, elem| {
                try testIntegerObject(exp, elem);
            }
        },
        .int_hash => |expected_entries| {
            const hash = switch (obj) {
                .hash => |h| h,
                else => {
                    std.debug.print("object is not Hash. got={s}\n", .{obj.typeName()});
                    return error.TestUnexpectedResult;
                },
            };
            try testing.expectEqual(expected_entries.len, hash.pairs.count());
            for (expected_entries) |entry| {
                const pair = hash.pairs.get(entry.key) orelse {
                    std.debug.print("no pair for given key in hash\n", .{});
                    return error.TestUnexpectedResult;
                };
                try testIntegerObject(entry.value, pair.value);
            }
        },
        .null => try testNullObject(obj),
    }
}

fn runVmTests(tests: []const VmTestCase) !void {
    const allocator = testing.allocator;

    for (tests) |tt| {
        var parser = blk: {
            var lexer = Lexer.init(tt.input);
            break :blk Parser.init(allocator, &lexer);
        };
        defer parser.deinit();
        const program = try parser.parse();

        var symbol_table = SymbolTable.init(allocator, null);
        defer symbol_table.deinit();
        var constants = std.ArrayList(Object).empty;
        defer constants.deinit(allocator);
        var constants_arena = std.heap.ArenaAllocator.init(allocator);
        defer constants_arena.deinit();
        var comp = Compiler.init(allocator, constants_arena.allocator(), &symbol_table, &constants);
        defer comp.deinit();
        try comp.enterScope();
        try comp.compile(program);

        var vm_arena = std.heap.ArenaAllocator.init(allocator);
        defer vm_arena.deinit();
        var globals: [vm_mod.globals_size]Object = undefined;
        var test_writer = std.Io.Writer.Allocating.init(allocator);
        defer test_writer.deinit();
        var vm = try Vm.init(comp.bytecode(), &globals, vm_arena.allocator(), &test_writer.writer);
        try vm.run();

        const stack_elem = vm.lastPoppedStackElem() orelse {
            std.debug.print("stackTop returned null\n", .{});
            return error.TestUnexpectedResult;
        };

        try testExpectedObject(tt.expected, stack_elem);
    }
}

test "integer arithmetic" {
    const tests = [_]VmTestCase{
        .{ .input = "1", .expected = .{ .int = 1 } },
        .{ .input = "2", .expected = .{ .int = 2 } },
        .{ .input = "1 + 2", .expected = .{ .int = 3 } },
        .{ .input = "1 - 2", .expected = .{ .int = -1 } },
        .{ .input = "1 * 2", .expected = .{ .int = 2 } },
        .{ .input = "4 / 2", .expected = .{ .int = 2 } },
        .{ .input = "50 / 2 * 2 + 10 - 5", .expected = .{ .int = 55 } },
        .{ .input = "5 + 5 + 5 + 5 - 10", .expected = .{ .int = 10 } },
        .{ .input = "2 * 2 * 2 * 2 * 2", .expected = .{ .int = 32 } },
        .{ .input = "5 * 2 + 10", .expected = .{ .int = 20 } },
        .{ .input = "5 + 2 * 10", .expected = .{ .int = 25 } },
        .{ .input = "5 * (2 + 10)", .expected = .{ .int = 60 } },
    };

    try runVmTests(&tests);
}

test "boolean expressions" {
    const tests = [_]VmTestCase{
        .{ .input = "true", .expected = .{ .boolean = true } },
        .{ .input = "false", .expected = .{ .boolean = false } },
        .{ .input = "1 < 2", .expected = .{ .boolean = true } },
        .{ .input = "1 > 2", .expected = .{ .boolean = false } },
        .{ .input = "1 < 1", .expected = .{ .boolean = false } },
        .{ .input = "1 > 1", .expected = .{ .boolean = false } },
        .{ .input = "1 == 1", .expected = .{ .boolean = true } },
        .{ .input = "1 != 1", .expected = .{ .boolean = false } },
        .{ .input = "1 == 2", .expected = .{ .boolean = false } },
        .{ .input = "1 != 2", .expected = .{ .boolean = true } },
        .{ .input = "true == true", .expected = .{ .boolean = true } },
        .{ .input = "false == false", .expected = .{ .boolean = true } },
        .{ .input = "true == false", .expected = .{ .boolean = false } },
        .{ .input = "true != false", .expected = .{ .boolean = true } },
        .{ .input = "false != true", .expected = .{ .boolean = true } },
        .{ .input = "(1 < 2) == true", .expected = .{ .boolean = true } },
        .{ .input = "(1 < 2) == false", .expected = .{ .boolean = false } },
        .{ .input = "(1 > 2) == true", .expected = .{ .boolean = false } },
        .{ .input = "(1 > 2) == false", .expected = .{ .boolean = true } },
    };

    try runVmTests(&tests);
}

test "prefix expressions" {
    const tests = [_]VmTestCase{
        .{ .input = "-5", .expected = .{ .int = -5 } },
        .{ .input = "-10", .expected = .{ .int = -10 } },
        .{ .input = "-50 + 100 + -50", .expected = .{ .int = 0 } },
        .{ .input = "!true", .expected = .{ .boolean = false } },
        .{ .input = "!false", .expected = .{ .boolean = true } },
        .{ .input = "!5", .expected = .{ .boolean = false } },
        .{ .input = "!!true", .expected = .{ .boolean = true } },
        .{ .input = "!!false", .expected = .{ .boolean = false } },
        .{ .input = "!!5", .expected = .{ .boolean = true } },
    };

    try runVmTests(&tests);
}

test "null literal" {
    const tests = [_]VmTestCase{
        .{ .input = "null", .expected = .null },
        .{ .input = "null == null", .expected = .{ .boolean = true } },
        .{ .input = "null != null", .expected = .{ .boolean = false } },
        .{ .input = "5 == null", .expected = .{ .boolean = false } },
        .{ .input = "null != \"a\"", .expected = .{ .boolean = true } },
        .{ .input = "[][0] == null", .expected = .{ .boolean = true } },
        .{ .input = "!null", .expected = .{ .boolean = true } },
        .{ .input = "if (null) { 1 } else { 2 }", .expected = .{ .int = 2 } },
        .{ .input = "let x = null; x = 3; x", .expected = .{ .int = 3 } },
    };

    try runVmTests(&tests);
}

test "null literal errors" {
    const tests = [_]VmErrorTestCase{
        .{ .input = "null + 1", .expected_error = error.TypeMismatch },
        .{ .input = "{null: 1}", .expected_error = error.HashNotHashable },
    };

    try runVmErrorTests(&tests);
}

test "conditionals" {
    const tests = [_]VmTestCase{
        .{ .input = "if (true) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (true) { 10 } else { 20 }", .expected = .{ .int = 10 } },
        .{ .input = "if (false) { 10 } else { 20 }", .expected = .{ .int = 20 } },
        .{ .input = "if (1) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 < 2) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 < 2) { 10 } else { 20 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 > 2) { 10 } else { 20 }", .expected = .{ .int = 20 } },
        .{ .input = "if (1 > 2) { 10 }", .expected = .null },
        .{ .input = "if (false) { 10 }", .expected = .null },
        .{ .input = "if ((if (false) { 10 })) { 10 } else { 20 }", .expected = .{ .int = 20 } },
        // Branches that produce no value evaluate to null.
        .{ .input = "if (true) { let a = 1; }", .expected = .null },
        .{ .input = "if (false) { 10 } else { let a = 1; }", .expected = .null },
        .{ .input = "if (true) { }", .expected = .null },
        .{ .input = "if (true) { let a = 1; }; 5", .expected = .{ .int = 5 } },
    };

    try runVmTests(&tests);
}

test "let statements" {
    const tests = [_]VmTestCase{
        .{ .input = "let one = 1; one;", .expected = .{ .int = 1 } },
        .{ .input = "let one = 1; let two = 2; one + two;", .expected = .{ .int = 3 } },
        .{ .input = "let one = 1; let two = one; two;", .expected = .{ .int = 1 } },
        .{ .input = "let x = 5; x;", .expected = .{ .int = 5 } },
        .{ .input = "let x = 5; let y = 10; x + y;", .expected = .{ .int = 15 } },
        // The value is evaluated before the name is bound, so it sees the previous binding.
        .{ .input = "let x = 1; let x = x + 1; x;", .expected = .{ .int = 2 } },
        .{ .input = "let x = 1; let f = fn() { let x = x + 1; x }; f();", .expected = .{ .int = 2 } },
    };

    try runVmTests(&tests);
}

test "string expressions" {
    const tests = [_]VmTestCase{
        .{ .input = "\"monkey\"", .expected = .{ .string = "monkey" } },
        .{ .input = "\"mon\" + \"key\"", .expected = .{ .string = "monkey" } },
        .{ .input = "\"mon\" + \"key\" + \"banana\"", .expected = .{ .string = "monkeybanana" } },
        .{ .input = "\"a\" == \"a\"", .expected = .{ .boolean = true } },
        .{ .input = "\"a\" != \"a\"", .expected = .{ .boolean = false } },
        .{ .input = "\"a\" == \"b\"", .expected = .{ .boolean = false } },
        .{ .input = "\"a\" != \"b\"", .expected = .{ .boolean = true } },
        .{ .input = "\"mon\" + \"key\" == \"monkey\"", .expected = .{ .boolean = true } },
    };

    try runVmTests(&tests);
}

test "array literals" {
    const tests = [_]VmTestCase{
        .{ .input = "[]", .expected = .{ .int_array = &.{} } },
        .{ .input = "[1, 2, 3]", .expected = .{ .int_array = &.{ 1, 2, 3 } } },
        .{ .input = "[1 + 2, 3 * 4, 5 + 6]", .expected = .{ .int_array = &.{ 3, 12, 11 } } },
    };

    try runVmTests(&tests);
}

test "hash literals" {
    const tests = [_]VmTestCase{
        .{ .input = "{}", .expected = .{ .int_hash = &.{} } },
        .{
            .input = "{1: 2, 2: 3}",
            .expected = .{ .int_hash = &.{
                .{ .key = (Object.Integer.init(1)).hashKey(), .value = 2 },
                .{ .key = (Object.Integer.init(2)).hashKey(), .value = 3 },
            } },
        },
        .{
            .input = "{1 + 1: 2 * 2, 3 + 3: 4 * 4}",
            .expected = .{ .int_hash = &.{
                .{ .key = (Object.Integer.init(2)).hashKey(), .value = 4 },
                .{ .key = (Object.Integer.init(6)).hashKey(), .value = 16 },
            } },
        },
    };

    try runVmTests(&tests);
}

test "index expressions" {
    const tests = [_]VmTestCase{
        .{ .input = "[1, 2, 3][1]", .expected = .{ .int = 2 } },
        .{ .input = "[1, 2, 3][0 + 2]", .expected = .{ .int = 3 } },
        .{ .input = "[[1, 1, 1]][0][0]", .expected = .{ .int = 1 } },
        .{ .input = "[][0]", .expected = .null },
        .{ .input = "[1, 2, 3][99]", .expected = .null },
        .{ .input = "[1][-1]", .expected = .null },
        .{ .input = "{1: 1, 2: 2}[1]", .expected = .{ .int = 1 } },
        .{ .input = "{1: 1, 2: 2}[2]", .expected = .{ .int = 2 } },
        .{ .input = "{1: 1}[0]", .expected = .null },
        .{ .input = "{}[0]", .expected = .null },
    };

    try runVmTests(&tests);
}

test "calling functions without arguments" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let fivePlusTen = fn() { 5 + 10; };
            \\fivePlusTen();
            ,
            .expected = .{ .int = 15 },
        },
        .{
            .input =
            \\let one = fn() { 1; };
            \\let two = fn() { 2; };
            \\one() + two();
            ,
            .expected = .{ .int = 3 },
        },
        .{
            .input =
            \\let a = fn() { 1; };
            \\let b = fn() { a() + 1; };
            \\let c = fn() { b() + 1; };
            \\c();
            ,
            .expected = .{ .int = 3 },
        },
    };

    try runVmTests(&tests);
}

test "calling functions with return statement" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let earlyExit = fn() { return 99; 100; };
            \\earlyExit();
            ,
            .expected = .{ .int = 99 },
        },
        .{
            .input =
            \\let earlyExit = fn() { return 99; return 100; };
            \\earlyExit();
            ,
            .expected = .{ .int = 99 },
        },
    };

    try runVmTests(&tests);
}

test "top-level return halts the program with its value" {
    const tests = [_]VmTestCase{
        .{ .input = "return 10;", .expected = .{ .int = 10 } },
        .{ .input = "return 10; 9;", .expected = .{ .int = 10 } },
        .{ .input = "9; return 2 * 5; 9;", .expected = .{ .int = 10 } },
        .{ .input = "if (10 > 1) { if (10 > 1) { return 10; } return 1; }", .expected = .{ .int = 10 } },
        .{ .input = "return;", .expected = .null },
        .{ .input = "if (10 > 1) { return; } 5;", .expected = .null },
        .{ .input = "let f = fn() { let a = 1; return; }; f();", .expected = .null },
    };

    try runVmTests(&tests);
}

test "calling functions without return value" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let noReturn = fn() { };
            \\noReturn();
            ,
            .expected = .null,
        },
        .{
            .input =
            \\let noReturn = fn() { };
            \\let noReturnTwo = fn() { noReturn(); };
            \\noReturn();
            \\noReturnTwo();
            ,
            .expected = .null,
        },
    };

    try runVmTests(&tests);
}

test "calling functions with bindings" {
    const tests = [_]VmTestCase{
        .{
            .input = "let one = fn() { let one = 1; one }; one();",
            .expected = .{ .int = 1 },
        },
        .{
            .input =
            \\let oneAndTwo = fn() { let one = 1; let two = 2; one + two; };
            \\oneAndTwo();
            ,
            .expected = .{ .int = 3 },
        },
        .{
            .input =
            \\let oneAndTwo = fn() { let one = 1; let two = 2; one + two; };
            \\let threeAndFour = fn() { let three = 3; let four = 4; three + four; };
            \\oneAndTwo() + threeAndFour();
            ,
            .expected = .{ .int = 10 },
        },
        .{
            .input =
            \\let firstFoobar = fn() { let foobar = 50; foobar; };
            \\let secondFoobar = fn() { let foobar = 100; foobar; };
            \\firstFoobar() + secondFoobar();
            ,
            .expected = .{ .int = 150 },
        },
        .{
            .input =
            \\let globalSeed = 50;
            \\let minusOne = fn() { let num = 1; globalSeed - num; };
            \\let minusTwo = fn() { let num = 2; globalSeed - num; };
            \\minusOne() + minusTwo();
            ,
            .expected = .{ .int = 97 },
        },
    };

    try runVmTests(&tests);
}

test "first class functions" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let returnsOne = fn() { 1; };
            \\let returnsOneReturner = fn() { returnsOne; };
            \\returnsOneReturner()();
            ,
            .expected = .{ .int = 1 },
        },
        .{
            .input = "let returnsOneReturner = fn() { let returnsOne = fn() { 1; }; returnsOne; }; returnsOneReturner()();",
            .expected = .{ .int = 1 },
        },
    };

    try runVmTests(&tests);
}

test "calling functions with arguments and bindings" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let identity = fn(a) { a; };
            \\identity(4);
            ,
            .expected = .{ .int = 4 },
        },
        .{
            .input =
            \\let sum = fn(a, b) { a + b; };
            \\sum(1, 2);
            ,
            .expected = .{ .int = 3 },
        },
        .{
            .input =
            \\let sum = fn(a, b) {
            \\    let c = a + b;
            \\    c;
            \\};
            \\sum(1, 2);
            ,
            .expected = .{ .int = 3 },
        },
        .{
            .input =
            \\let sum = fn(a, b) {
            \\    let c = a + b;
            \\    c;
            \\};
            \\sum(1, 2) + sum(3, 4);
            ,
            .expected = .{ .int = 10 },
        },
        .{
            .input =
            \\let sum = fn(a, b) {
            \\    let c = a + b;
            \\    c;
            \\};
            \\let outer = fn() {
            \\    sum(1, 2) + sum(3, 4);
            \\};
            \\outer();
            ,
            .expected = .{ .int = 10 },
        },
        .{
            .input =
            \\let globalNum = 10;
            \\let sum = fn(a, b) {
            \\    let c = a + b;
            \\    c + globalNum;
            \\};
            \\let outer = fn() {
            \\    sum(1, 2) + sum(3, 4) + globalNum;
            \\};
            \\outer() + globalNum;
            ,
            .expected = .{ .int = 50 },
        },
    };

    try runVmTests(&tests);
}

const VmErrorTestCase = struct {
    input: []const u8,
    expected_error: anyerror,
};

fn runVmErrorTests(tests: []const VmErrorTestCase) !void {
    const allocator = testing.allocator;

    for (tests) |tt| {
        var parser = blk: {
            var lexer = Lexer.init(tt.input);
            break :blk Parser.init(allocator, &lexer);
        };
        defer parser.deinit();
        const program = try parser.parse();

        var symbol_table = SymbolTable.init(allocator, null);
        defer symbol_table.deinit();
        var constants = std.ArrayList(Object).empty;
        defer constants.deinit(allocator);
        var constants_arena = std.heap.ArenaAllocator.init(allocator);
        defer constants_arena.deinit();
        var comp = Compiler.init(allocator, constants_arena.allocator(), &symbol_table, &constants);
        defer comp.deinit();
        try comp.enterScope();
        try comp.compile(program);

        var vm_arena = std.heap.ArenaAllocator.init(allocator);
        defer vm_arena.deinit();
        var globals: [vm_mod.globals_size]Object = undefined;
        var test_writer = std.Io.Writer.Allocating.init(allocator);
        defer test_writer.deinit();
        var vm = try Vm.init(comp.bytecode(), &globals, vm_arena.allocator(), &test_writer.writer);
        try testing.expectError(tt.expected_error, vm.run());
    }
}

test "calling functions with wrong arguments" {
    const tests = [_]VmErrorTestCase{
        .{ .input = "fn() { 1; }(1);", .expected_error = error.WrongArgumentCount },
        .{ .input = "fn(a) { a; }();", .expected_error = error.WrongArgumentCount },
        .{ .input = "fn(a, b) { a + b; }(1);", .expected_error = error.WrongArgumentCount },
    };
    try runVmErrorTests(&tests);
}

test "builtin functions" {
    const tests = [_]VmTestCase{
        .{ .input = "len(\"\")", .expected = .{ .int = 0 } },
        .{ .input = "len(\"four\")", .expected = .{ .int = 4 } },
        .{ .input = "len(\"hello world\")", .expected = .{ .int = 11 } },
        .{ .input = "len(1)", .expected = .{ .err = "argument to `len` not supported, got int" } },
        .{ .input = "len(\"one\", \"two\")", .expected = .{ .err = "wrong number of arguments. got=2, want=1" } },
        .{ .input = "len([1, 2, 3])", .expected = .{ .int = 3 } },
        .{ .input = "len([])", .expected = .{ .int = 0 } },
        .{ .input = "puts(\"hello\", \"world!\")", .expected = .null },
        .{ .input = "first([1, 2, 3])", .expected = .{ .int = 1 } },
        .{ .input = "first([])", .expected = .null },
        .{ .input = "first(1)", .expected = .{ .err = "argument to `first` must be ARRAY, got int" } },
        .{ .input = "last([1, 2, 3])", .expected = .{ .int = 3 } },
        .{ .input = "last([])", .expected = .null },
        .{ .input = "last(1)", .expected = .{ .err = "argument to `last` must be ARRAY, got int" } },
        .{ .input = "rest([1, 2, 3])", .expected = .{ .int_array = &.{ 2, 3 } } },
        .{ .input = "rest([])", .expected = .null },
        .{ .input = "push([], 1)", .expected = .{ .int_array = &.{1} } },
        .{ .input = "push(1, 1)", .expected = .{ .err = "argument to `push` must be ARRAY, got int" } },
    };

    try runVmTests(&tests);
}

test "closures" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let newClosure = fn(a) {
            \\    fn() { a; };
            \\};
            \\let closure = newClosure(99);
            \\closure();
            ,
            .expected = .{ .int = 99 },
        },
        .{
            .input =
            \\let newAdder = fn(a, b) {
            \\    fn(c) { a + b + c };
            \\};
            \\let adder = newAdder(1, 2);
            \\adder(8);
            ,
            .expected = .{ .int = 11 },
        },
        .{
            .input =
            \\let newAdder = fn(a, b) {
            \\    let c = a + b;
            \\    fn(d) { c + d };
            \\};
            \\let adder = newAdder(1, 2);
            \\adder(8);
            ,
            .expected = .{ .int = 11 },
        },
        .{
            .input =
            \\let newAdderOuter = fn(a, b) {
            \\    let c = a + b;
            \\    fn(d) {
            \\        let e = d + c;
            \\        fn(f) { e + f; };
            \\    };
            \\};
            \\let newAdderInner = newAdderOuter(1, 2);
            \\let adder = newAdderInner(3);
            \\adder(8);
            ,
            .expected = .{ .int = 14 },
        },
        .{
            .input =
            \\let a = 1;
            \\let newAdderOuter = fn(b) {
            \\    fn(c) {
            \\        fn(d) { a + b + c + d };
            \\    };
            \\};
            \\let newAdderInner = newAdderOuter(2);
            \\let adder = newAdderInner(3);
            \\adder(8);
            ,
            .expected = .{ .int = 14 },
        },
        .{
            .input =
            \\let newClosure = fn(a, b) {
            \\    let one = fn() { a; };
            \\    let two = fn() { b; };
            \\    fn() { one() + two(); };
            \\};
            \\let closure = newClosure(9, 90);
            \\closure();
            ,
            .expected = .{ .int = 99 },
        },
    };

    try runVmTests(&tests);
}

test "closures share captured variables with their enclosing function" {
    const tests = [_]VmTestCase{
        // The closure sees assignments made after it was created.
        .{ .input = "let f = fn() { let x = 1; let g = fn() { x }; x = 2; g() }; f();", .expected = .{ .int = 2 } },
        // The enclosing function sees assignments made by the closure.
        .{ .input = "let f = fn() { let x = 1; let g = fn() { x = 5; }; g(); x }; f();", .expected = .{ .int = 5 } },
        // A captured variable outlives the call that created it.
        .{ .input = "let newCounter = fn() { let n = 0; fn() { n = n + 1; n } }; let c = newCounter(); c(); c(); c();", .expected = .{ .int = 3 } },
        // Closures from the same call share one variable, even after it returns.
        .{ .input = "let pair = fn() { let n = 0; [fn() { n = n + 1; }, fn() { n }] }; let p = pair(); p[0](); p[0](); p[1]();", .expected = .{ .int = 2 } },
        // Each call gets its own variables.
        .{ .input = "let newCounter = fn() { let n = 0; fn() { n = n + 1; n } }; let a = newCounter(); let b = newCounter(); a(); a(); b();", .expected = .{ .int = 1 } },
        // A closure nested two levels deep updates the outermost variable.
        .{ .input = "let f = fn() { let x = 1; let g = fn() { fn() { x = x + 1; } }; let h = g(); h(); h(); x }; f();", .expected = .{ .int = 3 } },
    };

    try runVmTests(&tests);
}

test "recursive functions" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let countDown = fn(x) {
            \\    if (x == 0) {
            \\        return 0;
            \\    } else {
            \\        countDown(x - 1);
            \\    }
            \\};
            \\countDown(1);
            ,
            .expected = .{ .int = 0 },
        },
        .{
            .input =
            \\let countDown = fn(x) {
            \\    if (x == 0) {
            \\        return 0;
            \\    } else {
            \\        countDown(x - 1);
            \\    }
            \\};
            \\let wrapper = fn() {
            \\    countDown(1);
            \\};
            \\wrapper();
            ,
            .expected = .{ .int = 0 },
        },
        .{
            .input =
            \\let wrapper = fn() {
            \\    let countDown = fn(x) {
            \\        if (x == 0) {
            \\            return 0;
            \\        } else {
            \\            countDown(x - 1);
            \\        }
            \\    };
            \\    countDown(1);
            \\};
            \\wrapper();
            ,
            .expected = .{ .int = 0 },
        },
        // A closure nested in a named function calls that function, not itself.
        .{ .input = "let countDown = fn(x) { if (x == 0) { 0 } else { let next = fn() { countDown(x - 1) }; next() } }; countDown(2);", .expected = .{ .int = 0 } },
        .{ .input = "let wrapper = fn() { let countDown = fn(x) { if (x == 0) { 0 } else { let next = fn() { countDown(x - 1) }; next() } }; countDown(2) }; wrapper();", .expected = .{ .int = 0 } },
        .{ .input = "let sum = fn(x) { if (x == 0) { 0 } else { fn() { fn() { x + sum(x - 1) } }()() } }; sum(3);", .expected = .{ .int = 6 } },
    };

    try runVmTests(&tests);
}

test "recursive calls use the function name's current binding" {
    const tests = [_]VmTestCase{
        .{ .input = "let f = fn(n) { if (n == 0) { 0 } else { f(n - 1) } }; let g = f; f = fn(n) { 99 }; g(1);", .expected = .{ .int = 99 } },
        .{ .input = "let wrapper = fn() { let f = fn(n) { if (n == 0) { 0 } else { f(n - 1) } }; let g = f; f = fn(n) { 99 }; g(1) }; wrapper();", .expected = .{ .int = 99 } },
        .{ .input = "let f = fn(n) { if (n == 0) { 0 } else { let next = fn() { f(n - 1) }; next() } }; let g = f; f = fn(n) { 99 }; g(1);", .expected = .{ .int = 99 } },
        // A local recursive function keeps working after its defining function returns.
        .{ .input = "let make = fn() { let countDown = fn(x) { if (x == 0) { 0 } else { countDown(x - 1) } }; countDown }; let c = make(); c(3);", .expected = .{ .int = 0 } },
    };

    try runVmTests(&tests);
}

test "recursive fibonacci" {
    const tests = [_]VmTestCase{
        .{
            .input =
            \\let fibonacci = fn(x) {
            \\    if (x == 0) {
            \\        return 0;
            \\    } else {
            \\        if (x == 1) {
            \\            return 1;
            \\        } else {
            \\            fibonacci(x - 1) + fibonacci(x - 2);
            \\        }
            \\    }
            \\};
            \\fibonacci(15);
            ,
            .expected = .{ .int = 610 },
        },
    };

    try runVmTests(&tests);
}

test "float arithmetic" {
    const tests = [_]VmTestCase{
        .{ .input = "1.5", .expected = .{ .float = 1.5 } },
        .{ .input = "10.", .expected = .{ .float = 10.0 } },
        .{ .input = "3.", .expected = .{ .float = 3.0 } },
        .{ .input = "1.5 + 2.5", .expected = .{ .float = 4.0 } },
        .{ .input = "3.0 - 1.0", .expected = .{ .float = 2.0 } },
        .{ .input = "2.0 * 3.0", .expected = .{ .float = 6.0 } },
        .{ .input = "7.0 / 2.0", .expected = .{ .float = 3.5 } },
        .{ .input = "-3.14", .expected = .{ .float = -3.14 } },
    };

    try runVmTests(&tests);
}

test "mixed int/float arithmetic" {
    const tests = [_]VmTestCase{
        .{ .input = "1 + 2.5", .expected = .{ .float = 3.5 } },
        .{ .input = "3.14 * 2", .expected = .{ .float = 6.28 } },
        .{ .input = "10 - 1.5", .expected = .{ .float = 8.5 } },
        .{ .input = "7.0 / 2", .expected = .{ .float = 3.5 } },
        .{ .input = "7 / 2", .expected = .{ .int = 3 } },
    };

    try runVmTests(&tests);
}

test "float comparisons" {
    const tests = [_]VmTestCase{
        .{ .input = "1.5 < 2.5", .expected = .{ .boolean = true } },
        .{ .input = "2.5 < 1.5", .expected = .{ .boolean = false } },
        .{ .input = "3.0 == 3.0", .expected = .{ .boolean = true } },
        .{ .input = "3.0 != 3.0", .expected = .{ .boolean = false } },
        .{ .input = "1.0 != 2.0", .expected = .{ .boolean = true } },
        .{ .input = "1 < 2.5", .expected = .{ .boolean = true } },
        .{ .input = "2.5 == 2.5", .expected = .{ .boolean = true } },
    };

    try runVmTests(&tests);
}

test "infinite and c-style loops" {
    const tests = [_]VmTestCase{
        .{ .input = "let n = 0; for let i = 0; i < 3; i = i + 1 { n = n * 10 + i; } n;", .expected = .{ .int = 12 } },
        .{ .input = "let n = 0; for let i = 0; false; i = i + 1 { n = 1; } n;", .expected = .{ .int = 0 } },
        .{ .input = "let f = fn() { for { return 7; } }; f();", .expected = .{ .int = 7 } },
        .{ .input = "let n = 0; let f = fn() { for let i = 0; true; n = n + 1 { return 7; } }; f() + n;", .expected = .{ .int = 7 } },
        .{ .input = "let i = 99; for let i = 0; i < 2; i = i + 1 { let hidden = i; } i;", .expected = .{ .int = 99 } },
        .{ .input = "let n = 0; for let i = 0; i < 2; i = i + 1 { for let j = 0; j < 3; j = j + 1 { n = n + 1; } } n;", .expected = .{ .int = 6 } },
        .{ .input = "let f = fn() { let t = 0; for let i = 0; i < 3; i = i + 1 { t = t + 10; } t }; f();", .expected = .{ .int = 30 } },
    };

    try runVmTests(&tests);
}

test "iterator loops over ranges, arrays, hashes, and strings" {
    const tests = [_]VmTestCase{
        .{ .input = "let n = 0; for i in 0..4 { n = n + i; } n;", .expected = .{ .int = 6 } },
        .{ .input = "let n = 0; let r = -2..2; for i in r { n = n + i; } n;", .expected = .{ .int = -2 } },
        .{ .input = "let n = 0; for i in 2..2 { n = 1; } for i in 3..1 { n = 2; } n;", .expected = .{ .int = 0 } },
        .{ .input = "let n = 0; for index, value in 5..8 { n = n + index + value; } n;", .expected = .{ .int = 21 } },
        .{ .input = "let n = 0; for value in [2, 3, 4] { n = n + value; } n;", .expected = .{ .int = 9 } },
        .{ .input = "let n = 0; for index, value in [2, 3, 4] { n = n + index * value; } n;", .expected = .{ .int = 11 } },
        .{ .input = "let n = 0; for key in {2: 10, 3: 20} { n = n + key; } n;", .expected = .{ .int = 5 } },
        .{ .input = "let n = 0; for key, value in {2: 10, 3: 20} { n = n + key + value; } n;", .expected = .{ .int = 35 } },
        .{ .input = "let n = 0; for c in \"banana\" { if (c == \"a\") { n = n + 1; } } n;", .expected = .{ .int = 3 } },
        .{ .input = "let s = \"\"; for c in \"héllo\" { s = s + c + \"-\"; } s;", .expected = .{ .string = "h-é-l-l-o-" } },
        .{ .input = "let n = 0; for index, c in \"héy\" { n = n + index; } n;", .expected = .{ .int = 3 } },
        .{ .input = "let n = 0; for v in [] { n = 1; } for k in {} { n = 2; } for b in \"\" { n = 3; } n;", .expected = .{ .int = 0 } },
        .{ .input = "let calls = 0; let values = fn() { calls = calls + 1; [1, 2, 3]; }; for i in values() {} calls;", .expected = .{ .int = 1 } },
        .{ .input = "let values = [1, 2, 3]; let n = 0; for i in values { values = []; n = n + i; } n;", .expected = .{ .int = 6 } },
        .{ .input = "let i = 99; for i in [1, 2] {} i;", .expected = .{ .int = 99 } },
        .{ .input = "let n = 0; for i in 9223372036854775806..9223372036854775807 { n = i; } n;", .expected = .{ .int = 9223372036854775806 } },
        .{ .input = "let f = fn(xs) { let n = 0; for x in xs { for y in xs { n = n + x * y; } } n }; f([1, 2]);", .expected = .{ .int = 9 } },
        .{ .input = "let f = fn() { for i in [7, 8] { return i; } }; f() + f();", .expected = .{ .int = 14 } },
    };

    try runVmTests(&tests);
}

test "loops evaluate to null" {
    const tests = [_]VmTestCase{
        .{ .input = "for let i = 0; i < 2; i = i + 1 { 42; }", .expected = .null },
        .{ .input = "fn() { for i in [1] { 42; } }();", .expected = .null },
        .{ .input = "if (true) { for i in [1] { 42; } }", .expected = .null },
    };

    try runVmTests(&tests);
}

test "closures share one loop variable across iterations" {
    const tests = [_]VmTestCase{
        .{ .input = "let saved = fn() { 0; }; for let i = 0; i < 3; i = i + 1 { saved = fn() { i; }; } saved();", .expected = .{ .int = 3 } },
        .{ .input = "let f = fn() { let saved = fn() { 0; }; for let i = 0; i < 3; i = i + 1 { saved = fn() { i; }; } saved() }; f();", .expected = .{ .int = 3 } },
        .{ .input = "let f = fn() { let saved = fn() { 0; }; for i in [1, 2, 3] { saved = fn() { i; }; } saved() }; f();", .expected = .{ .int = 3 } },
    };

    try runVmTests(&tests);
}

test "loop errors" {
    const tests = [_]VmErrorTestCase{
        .{ .input = "for i in 1 {}", .expected_error = error.NotIterable },
        .{ .input = "for i in 1..true {}", .expected_error = error.TypeMismatch },
        .{ .input = "for i in 1.5..3 {}", .expected_error = error.TypeMismatch },
    };

    try runVmErrorTests(&tests);
}

test "unbounded recursion reports an overflow instead of crashing" {
    const tests = [_]VmErrorTestCase{
        .{ .input = "let f = fn() { f(); }; f();", .expected_error = error.FrameOverflow },
        .{ .input = "let f = fn() { let a = 1; let b = 2; let c = 3; f(); }; f();", .expected_error = error.StackOverflow },
        .{ .input = "let f = fn(n) { 1 + f(n); }; f(0);", .expected_error = error.StackOverflow },
    };

    try runVmErrorTests(&tests);
}
