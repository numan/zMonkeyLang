const std = @import("std");
const testing = std.testing;

const Object = @import("./object.zig").Object;
const Evaluator = @import("./evaluator.zig").Evaluator;
const Environment = @import("./environment.zig").Environment;
const Gc = @import("./gc.zig").Gc;
const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("./parser.zig").Parser;

fn testNullObject(obj: Object) !void {
    switch (obj) {
        .null => {},
        else => {
            std.debug.print("Expected null. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    }
}

fn testIntegerObjectEqual(obj: Object, expected: i64) !void {
    const integer = switch (obj) {
        .int => |value| value,
        else => {
            std.debug.print("Expected an int. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(expected, integer.value);
}

fn testFloatObjectEqual(obj: Object, expected: f64) !void {
    const float = switch (obj) {
        .float => |value| value,
        else => {
            std.debug.print("Expected a float. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(expected, float.value);
}

fn testBooleanObjectEqual(obj: Object, expected: bool) !void {
    const boolean = switch (obj) {
        .bool => |value| value,
        else => {
            std.debug.print("Expected an bool. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(expected, boolean.value);
}

fn testStringObjectEqual(obj: Object, expected: []const u8) !void {
    const str = switch (obj) {
        .string => |value| value,
        else => {
            std.debug.print("Expected a string. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqualStrings(expected, str.value);
}

fn testErrorObjectMessageEqual(obj: Object, expected: []const u8) !void {
    switch (obj) {
        .err => |err_obj| {
            try testing.expectEqualStrings(expected, err_obj.msg);
        },
        else => {
            std.debug.print(
                "Expected error object for input, got tag {s} instead.\n",
                .{obj.typeName()},
            );
            return error.TestUnexpectedResult;
        },
    }
}

fn testEval(input: []const u8, allocator: std.mem.Allocator, evaluator: *Evaluator) !Object {
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);

    defer parser.deinit();
    const program = try parser.parse();
    try testing.expectEqual(0, parser.allErrors().len);

    return evaluator.eval(program);
}

test "infinite and c-style loops execute with local scope and control flow" {
    const cases = [_]struct { input: []const u8, expected: i64 }{
        .{ .input = "let n = 0; for let i = 0; i < 3; i = i + 1 { n = n * 10 + i; } n;", .expected = 12 },
        .{ .input = "let n = 0; for let i = 0; false; i = i + 1 { n = 1; } n;", .expected = 0 },
        .{ .input = "let f = fn() { for { return 7; } }; f();", .expected = 7 },
        .{ .input = "let n = 0; let f = fn() { for let i = 0; true; n = n + 1 { return 7; } }; f() + n;", .expected = 7 },
        .{ .input = "let i = 99; for let i = 0; i < 2; i = i + 1 { let hidden = i; } i;", .expected = 99 },
        .{ .input = "let n = 0; for let i = 0; i < 2; i = i + 1 { for let j = 0; j < 3; j = j + 1 { n = n + 1; } } n;", .expected = 6 },
        .{ .input = "let saved = fn() { 0; }; for let i = 0; i < 3; i = i + 1 { saved = fn() { i; }; } saved();", .expected = 3 },
    };
    for (cases) |case| {
        var collector = Gc.init(testing.allocator);
        defer collector.deinit();
        const env = try collector.allocEnvironment(null);
        var writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &writer.writer);
        defer evaluator.deinit();
        try testIntegerObjectEqual(try testEval(case.input, testing.allocator, &evaluator), case.expected);
        try testing.expect(evaluator.environment == env);
        try testing.expect(env.get("hidden") == null);
    }
}

test "closures share captured variables with their enclosing function" {
    const cases = [_]struct { input: []const u8, expected: i64 }{
        .{ .input = "let f = fn() { let x = 1; let g = fn() { x }; x = 2; g() }; f();", .expected = 2 },
        .{ .input = "let f = fn() { let x = 1; let g = fn() { x = 5; }; g(); x }; f();", .expected = 5 },
        .{ .input = "let newCounter = fn() { let n = 0; fn() { n = n + 1; n } }; let c = newCounter(); c(); c(); c();", .expected = 3 },
        .{ .input = "let pair = fn() { let n = 0; [fn() { n = n + 1; }, fn() { n }] }; let p = pair(); p[0](); p[0](); p[1]();", .expected = 2 },
        .{ .input = "let newCounter = fn() { let n = 0; fn() { n = n + 1; n } }; let a = newCounter(); let b = newCounter(); a(); a(); b();", .expected = 1 },
        .{ .input = "let f = fn() { let x = 1; let g = fn() { fn() { x = x + 1; } }; let h = g(); h(); h(); x }; f();", .expected = 3 },
        .{ .input = "let f = fn() { let saved = fn() { 0; }; for let i = 0; i < 3; i = i + 1 { saved = fn() { i; }; } saved() }; f();", .expected = 3 },
        .{ .input = "let f = fn() { let saved = fn() { 0; }; for i in [1, 2, 3] { saved = fn() { i; }; } saved() }; f();", .expected = 3 },
        .{ .input = "let wrapper = fn() { let countDown = fn(x) { if (x == 0) { 0 } else { let next = fn() { countDown(x - 1) }; next() } }; countDown(2) }; wrapper();", .expected = 0 },
        .{ .input = "let sum = fn(x) { if (x == 0) { 0 } else { fn() { fn() { x + sum(x - 1) } }()() } }; sum(3);", .expected = 6 },
        // Recursive calls use the function name's current binding.
        .{ .input = "let f = fn(n) { if (n == 0) { 0 } else { f(n - 1) } }; let g = f; f = fn(n) { 99 }; g(1);", .expected = 99 },
        .{ .input = "let wrapper = fn() { let f = fn(n) { if (n == 0) { 0 } else { f(n - 1) } }; let g = f; f = fn(n) { 99 }; g(1) }; wrapper();", .expected = 99 },
        .{ .input = "let f = fn(n) { if (n == 0) { 0 } else { let next = fn() { f(n - 1) }; next() } }; let g = f; f = fn(n) { 99 }; g(1);", .expected = 99 },
        .{ .input = "let make = fn() { let countDown = fn(x) { if (x == 0) { 0 } else { countDown(x - 1) } }; countDown }; let c = make(); c(3);", .expected = 0 },
    };
    for (cases) |case| {
        var collector = Gc.init(testing.allocator);
        defer collector.deinit();
        const env = try collector.allocEnvironment(null);
        var writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &writer.writer);
        defer evaluator.deinit();
        try testIntegerObjectEqual(try testEval(case.input, testing.allocator, &evaluator), case.expected);
    }
}

test "iterator loops evaluate once and bind ranges arrays hashes and string characters" {
    const cases = [_]struct { input: []const u8, expected: i64 }{
        .{ .input = "let n = 0; for i in 0..4 { n = n + i; } n;", .expected = 6 },
        .{ .input = "let n = 0; let r = -2..2; for i in r { n = n + i; } n;", .expected = -2 },
        .{ .input = "let n = 0; for i in 2..2 { n = 1; } for i in 3..1 { n = 2; } n;", .expected = 0 },
        .{ .input = "let n = 0; for index, value in 5..8 { n = n + index + value; } n;", .expected = 21 },
        .{ .input = "let n = 0; for value in [2, 3, 4] { n = n + value; } n;", .expected = 9 },
        .{ .input = "let n = 0; for index, value in [2, 3, 4] { n = n + index * value; } n;", .expected = 11 },
        .{ .input = "let n = 0; for key in {2: 10, 3: 20} { n = n + key; } n;", .expected = 5 },
        .{ .input = "let n = 0; for key, value in {2: 10, 3: 20} { n = n + key + value; } n;", .expected = 35 },
        .{ .input = "let n = 0; for c in \"banana\" { if (c == \"a\") { n = n + 1; } } n;", .expected = 3 },
        .{ .input = "let n = 0; for index, c in \"héy\" { n = n + index; } n;", .expected = 3 },
        .{ .input = "let n = 0; for v in [] { n = 1; } for k in {} { n = 2; } for b in \"\" { n = 3; } n;", .expected = 0 },
        .{ .input = "let calls = 0; let values = fn() { calls = calls + 1; [1, 2, 3]; }; for i in values() {} calls;", .expected = 1 },
        .{ .input = "let values = [1, 2, 3]; let n = 0; for i in values { values = []; n = n + i; } n;", .expected = 6 },
        .{ .input = "let i = 99; for i in [1, 2] {} i;", .expected = 99 },
        .{ .input = "let f = fn() { for i in [7, 8] { return i; } }; f();", .expected = 7 },
        .{ .input = "let saved = fn() { 0; }; for i in [1, 2, 3] { saved = fn() { i; }; } saved();", .expected = 3 },
        .{ .input = "let n = 0; for i in 9223372036854775806..9223372036854775807 { n = i; } n;", .expected = 9223372036854775806 },
    };
    for (cases) |case| {
        var collector = Gc.init(testing.allocator);
        defer collector.deinit();
        const env = try collector.allocEnvironment(null);
        var writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &writer.writer);
        defer evaluator.deinit();
        try testIntegerObjectEqual(try testEval(case.input, testing.allocator, &evaluator), case.expected);
        try testing.expect(evaluator.environment == env);
    }
}

test "iterating a string binds each UTF-8 character as a string" {
    var collector = Gc.init(testing.allocator);
    defer collector.deinit();
    const env = try collector.allocEnvironment(null);
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &writer.writer);
    defer evaluator.deinit();
    try testStringObjectEqual(
        try testEval("let s = \"\"; for c in \"héllo\" { s = s + c + \"-\"; } s;", testing.allocator, &evaluator),
        "h-é-l-l-o-",
    );
}

test "loop errors stop execution and restore the environment" {
    const cases = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "for let i = missing; true; i = 1 {}", .message = "identifier not found: missing" },
        .{ .input = "for let i = 0; missing; i = 1 {}", .message = "identifier not found: missing" },
        .{ .input = "for let i = 0; true; i = missing {}", .message = "identifier not found: missing" },
        .{ .input = "for { missing; }", .message = "identifier not found: missing" },
        .{ .input = "for i in missing {}", .message = "identifier not found: missing" },
        .{ .input = "for i in [1, 2] { missing; }", .message = "identifier not found: missing" },
        .{ .input = "for i in 1 {}", .message = "not iterable: int" },
        .{ .input = "for i in 1..true {}", .message = "range bounds must be integers: int .. bool" },
        .{ .input = "for i in 1.5..3 {}", .message = "range bounds must be integers: float .. int" },
        .{ .input = "for i in missing..3 {}", .message = "identifier not found: missing" },
        .{ .input = "for let i = 0; false; i = 1 {} i;", .message = "identifier not found: i" },
    };
    for (cases) |case| {
        var collector = Gc.init(testing.allocator);
        defer collector.deinit();
        const env = try collector.allocEnvironment(null);
        var writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &writer.writer);
        defer evaluator.deinit();
        try testErrorObjectMessageEqual(try testEval(case.input, testing.allocator, &evaluator), case.message);
        try testing.expect(evaluator.environment == env);
        try testing.expect(env.get("i") == null);
        try testIntegerObjectEqual(try testEval("42;", testing.allocator, &evaluator), 42);
    }
}

test "completed loops return null and ranges inspect without materializing elements" {
    var collector = Gc.init(testing.allocator);
    defer collector.deinit();
    const env = try collector.allocEnvironment(null);
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &writer.writer);
    defer evaluator.deinit();

    try testNullObject(try testEval("for let i = 0; i < 2; i = i + 1 { 42; }", testing.allocator, &evaluator));
    try testNullObject(try testEval("for i in [1, 2] { 42; }", testing.allocator, &evaluator));
    collector.collect(env);
    const range = try testEval("-2..9223372036854775807;", testing.allocator, &evaluator);
    try testing.expectEqualStrings("range", range.typeName());
    try range.inspect(&writer.writer);
    try testing.expectEqualStrings("-2..9223372036854775807", writer.written());
    try testing.expectEqual(0, collector.arrays.items.len);
}

test "gc preserves shared loop closure bindings then reclaims their cycle" {
    var collector = Gc.init(testing.allocator);
    defer collector.deinit();
    const env = try collector.allocEnvironment(null);
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &writer.writer);
    defer evaluator.deinit();

    _ = try testEval(
        \\let first = 0;
        \\let last = 0;
        \\for index, value in ["a", "b"] {
        \\    let capture = fn() { value; };
        \\    if (index == 0) { first = capture; }
        \\    last = capture;
        \\}
    , testing.allocator, &evaluator);
    collector.collect(env);
    try testing.expectEqual(2, collector.trackedEnvironmentCount());
    try testing.expectEqual(2, collector.trackedFunctionCount());
    try testing.expectEqual(1, collector.trackedStringCount());
    try testStringObjectEqual(try testEval("first() + last();", testing.allocator, &evaluator), "bb");

    _ = try testEval("first = 0; last = 0;", testing.allocator, &evaluator);
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedEnvironmentCount());
    try testing.expectEqual(0, collector.trackedFunctionCount());
    try testing.expectEqual(0, collector.trackedStringCount());
    try testing.expectEqual(0, collector.arrays.items.len);
}

test "gc reclaims transient loop values without releasing shared globals" {
    var collector = Gc.init(testing.allocator);
    defer collector.deinit();
    const env = try collector.allocEnvironment(null);
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &writer.writer);
    defer evaluator.deinit();

    try testIntegerObjectEqual(try testEval(
        \\let keep = "keep";
        \\let source = [keep, keep, ["nested"], {"k": "v"}];
        \\let count = 0;
        \\for item in source { source = []; count = count + 1; }
        \\for key, value in {"a": keep, "b": keep} {}
        \\for c in "é" {}
        \\count;
    , testing.allocator, &evaluator), 4);
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedEnvironmentCount());
    try testing.expectEqual(1, collector.trackedStringCount());
    try testing.expectEqual(1, collector.arrays.items.len);
    try testing.expectEqual(0, collector.hashes.items.len);
    const keep = env.get("keep").?;
    try testStringObjectEqual(keep, "keep");
    try testing.expectEqual(1, collector.refCount(keep));
}

test "gc keeps a managed value returned through a loop and function" {
    var collector = Gc.init(testing.allocator);
    defer collector.deinit();
    const env = try collector.allocEnvironment(null);
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &writer.writer);
    defer evaluator.deinit();

    _ = try testEval("let saved = fn() { for value in [[\"alive\"]] { return fn() { value; }; } }();", testing.allocator, &evaluator);
    collector.collect(env);
    try testStringObjectEqual(try testEval("saved()[0];", testing.allocator, &evaluator), "alive");
    _ = try testEval("saved = 0;", testing.allocator, &evaluator);
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedEnvironmentCount());
    try testing.expectEqual(0, collector.trackedFunctionCount());
    try testing.expectEqual(0, collector.trackedStringCount());
    try testing.expectEqual(0, collector.arrays.items.len);
}

test "eval integer expression" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{
            .input = "5",
            .expected = 5,
        },
        .{
            .input = "10",
            .expected = 10,
        },
        .{
            .input = "5; 10;",
            .expected = 10,
        },
        .{
            .input = "-5",
            .expected = -5,
        },
        .{
            .input = "-10",
            .expected = -10,
        },
        .{
            .input = "5 + 5 + 5 + 5 - 10",
            .expected = 10,
        },
        .{
            .input = "2 * 2 * 2 * 2 * 2",
            .expected = 32,
        },
        .{
            .input = "-50 + 100 + -50",
            .expected = 0,
        },
        .{
            .input = "5 * 2 + 10",
            .expected = 20,
        },
        .{
            .input = "5 + 2 * 10",
            .expected = 25,
        },
        .{
            .input = "20 + 2 * -10",
            .expected = 0,
        },
        .{
            .input = "50 / 2 * 2 + 10",
            .expected = 60,
        },
        .{
            .input = "2 * (5 + 10)",
            .expected = 30,
        },
        .{
            .input = "3 * 3 * 3 + 10",
            .expected = 37,
        },
        .{
            .input = "3 * (3 * 3) + 10",
            .expected = 37,
        },
        .{
            .input = "(5 + 10 * 2 + 15 / 3) * 2 + -10",
            .expected = 50,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testIntegerObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input {s}",
                .{case.input},
            );
            return err;
        };
    }
}

test "eval boolean" {
    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{
            .input = "true",
            .expected = true,
        },
        .{
            .input = "false",
            .expected = false,
        },
        .{
            .input = "1 < 2",
            .expected = true,
        },
        .{
            .input = "1 > 2",
            .expected = false,
        },
        .{
            .input = "1 < 1",
            .expected = false,
        },
        .{
            .input = "1 > 1",
            .expected = false,
        },
        .{
            .input = "1 == 1",
            .expected = true,
        },
        .{
            .input = "1 != 1",
            .expected = false,
        },
        .{
            .input = "1 == 2",
            .expected = false,
        },
        .{
            .input = "1 != 2",
            .expected = true,
        },
        .{
            .input = "true == true",
            .expected = true,
        },
        .{
            .input = "false == false",
            .expected = true,
        },
        .{
            .input = "true == false",
            .expected = false,
        },
        .{
            .input = "true != false",
            .expected = true,
        },
        .{
            .input = "false != true",
            .expected = true,
        },
        .{
            .input = "(1 < 2) == true",
            .expected = true,
        },
        .{
            .input = "(1 < 2) == false",
            .expected = false,
        },
        .{
            .input = "(1 > 2) == true",
            .expected = false,
        },
        .{
            .input = "(1 > 2) == false",
            .expected = true,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        try testBooleanObjectEqual(evaluated, case.expected);
    }
}

test "null literal" {
    const Expected = union(enum) { null, boolean: bool, int: i64, err: []const u8 };
    const cases = [_]struct { input: []const u8, expected: Expected }{
        .{ .input = "null", .expected = .null },
        .{ .input = "null == null", .expected = .{ .boolean = true } },
        .{ .input = "null != null", .expected = .{ .boolean = false } },
        .{ .input = "5 == null", .expected = .{ .boolean = false } },
        .{ .input = "null != \"a\"", .expected = .{ .boolean = true } },
        .{ .input = "[][0] == null", .expected = .{ .boolean = true } },
        .{ .input = "!null", .expected = .{ .boolean = true } },
        .{ .input = "if (null) { 1 } else { 2 }", .expected = .{ .int = 2 } },
        .{ .input = "let x = null; x = 3; x", .expected = .{ .int = 3 } },
        .{ .input = "let f = fn() { null }; f() == null", .expected = .{ .boolean = true } },
        .{ .input = "null + 1", .expected = .{ .err = "type mismatch: null + int" } },
        .{ .input = "null < null", .expected = .{ .err = "unknown operator null < null" } },
        .{ .input = "{null: 1}", .expected = .{ .err = "unusable as hash key: null" } },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var collector = Gc.init(testing.allocator);
        defer collector.deinit();
        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        switch (case.expected) {
            .null => try testNullObject(evaluated),
            .boolean => |expected| try testBooleanObjectEqual(evaluated, expected),
            .int => |expected| try testIntegerObjectEqual(evaluated, expected),
            .err => |expected| try testErrorObjectMessageEqual(evaluated, expected),
        }
    }
}

test "bang operator" {
    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{
            .input = "!true",
            .expected = false,
        },
        .{
            .input = "!false",
            .expected = true,
        },
        .{
            .input = "!!true",
            .expected = true,
        },
        .{
            .input = "!!false",
            .expected = false,
        },
        .{
            .input = "!5",
            .expected = false,
        },
        .{
            .input = "!!5",
            .expected = true,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        try testBooleanObjectEqual(evaluated, case.expected);
    }
}

test "if else expressions" {
    const tests = [_]struct {
        input: []const u8,
        expected: ?i64,
    }{
        .{
            .input = "if (true) { 10 }",
            .expected = 10,
        },
        .{
            .input = "if (false) { 10 }",
            .expected = null,
        },
        .{
            .input = "if (1) { 10 }",
            .expected = 10,
        },
        .{
            .input = "if (1 < 2) { 10 }",
            .expected = 10,
        },
        .{
            .input = "if (1 > 2) { 10 }",
            .expected = null,
        },
        .{
            .input = "if (1 > 2) { 10 } else { 20 }",
            .expected = 20,
        },
        .{
            .input = "if (1 < 2) { 10 } else { 20 }",
            .expected = 10,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        if (case.expected) |expected| {
            try testIntegerObjectEqual(evaluated, expected);
        } else {
            try testNullObject(evaluated);
        }
    }
}

test "return statements" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "return 10;", .expected = 10 },
        .{ .input = "return 10; 9;", .expected = 10 },
        .{ .input = "return 2 * 5; 9;", .expected = 10 },
        .{ .input = "9; return 2 * 5; 9;", .expected = 10 },
        .{
            .input =
            \\if (10 > 1) {
            \\  if (10 > 1) {
            \\    return 10;
            \\  }
            \\
            \\  return 1;
            \\}
            ,
            .expected = 10,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        try testIntegerObjectEqual(evaluated, case.expected);
    }
}

test "bare return statements" {
    const tests = [_][]const u8{
        "return;",
        "if (10 > 1) { return; }",
        "if (10 > 1) { if (10 > 1) { return; } return 1; }",
    };

    for (tests) |input| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(input, arena.allocator(), &evaluator);
        try testNullObject(evaluated);
    }
}

test "error handling" {
    const tests = [_]struct {
        input: []const u8,
        expected_message: []const u8,
    }{
        .{
            .input = "5 + true;",
            .expected_message = "type mismatch: int + bool",
        },
        .{
            .input = "5 + true; 5;",
            .expected_message = "type mismatch: int + bool",
        },
        .{
            .input = "-true",
            .expected_message = "unknown operator: -bool",
        },
        .{
            .input = "true + false;",
            .expected_message = "unknown operator bool + bool",
        },
        .{
            .input = "5; true + false; 5",
            .expected_message = "unknown operator bool + bool",
        },
        .{
            .input = "if (10 > 1) { true + false; }",
            .expected_message = "unknown operator bool + bool",
        },
        .{
            .input =
            \\if (10 > 1) {
            \\  if (10 > 1) {
            \\    return true + false;
            \\  }
            \\
            \\  return 1;
            \\}
            ,
            .expected_message = "unknown operator bool + bool",
        },
        .{
            .input = "\"foo\" - \"bar\"",
            .expected_message = "unknown operator STRING - STRING",
        },
        .{
            .input = "\"foo\" * \"bar\"",
            .expected_message = "unknown operator STRING * STRING",
        },
        .{
            .input = "\"foo\" + 1",
            .expected_message = "type mismatch: string + int",
        },
        .{
            .input = "1 + \"foo\"",
            .expected_message = "type mismatch: int + string",
        },
        .{
            .input = "foobar",
            .expected_message = "identifier not found: foobar",
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testErrorObjectMessageEqual(evaluated, case.expected_message) catch |err| {
            std.debug.print(
                "Got wrong error object for input:\n{s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "let statements" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let a = 5; a;", .expected = 5 },
        .{ .input = "let a = 5 * 5; a;", .expected = 25 },
        .{ .input = "let a = 5; let b = a; b;", .expected = 5 },
        .{ .input = "let a = 5; let b = a; let c = a + b + 5; c;", .expected = 15 },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        try testIntegerObjectEqual(evaluated, case.expected);
    }
}

test "function object" {
    const input = "fn(x) { x + 2; };";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);

    const function = switch (evaluated) {
        .function => |function_obj| function_obj,
        else => {
            std.debug.print(
                "object is not Function. got={s}\n",
                .{evaluated.typeName()},
            );
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(@as(usize, 1), function.parameters.len);

    var parameter_alloc_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer parameter_alloc_writer.deinit();
    const parameter_writer = &parameter_alloc_writer.writer;
    try function.parameters[0].toString(parameter_writer);
    try testing.expectEqualStrings("x", parameter_alloc_writer.written());

    var body_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer body_writer.deinit();
    try function.body.toString(&body_writer.writer);
    try testing.expectEqualStrings("(x + 2)", body_writer.written());
}

test "function application" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let identity = fn(x) { x; }; identity(5);", .expected = 5 },
        .{ .input = "let identity = fn(x) { return x; }; identity(5);", .expected = 5 },
        .{ .input = "let double = fn(x) { x * 2; }; double(5);", .expected = 10 },
        .{ .input = "let add = fn(x, y) { x + y; }; add(5, 5);", .expected = 10 },
        .{ .input = "let add = fn(x, y) { x + y; }; add(5 + 5, add(5, 5));", .expected = 20 },
        .{ .input = "fn(x) { x; }(5)", .expected = 5 },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testIntegerObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input:\n{s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "closures" {
    const input =
        \\let newAdder = fn(x) {
        \\  fn(y) { x + y };
        \\};
        \\
        \\let addTwo = newAdder(2);
        \\addTwo(2);
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);
    try testIntegerObjectEqual(evaluated, 4);
}

test "function as argument" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{
            .input =
            \\let add = fn(a, b) { a + b };
            \\let sub = fn(a, b) { a - b };
            \\let applyFunc = fn(a, b, func) { func(a, b) };
            \\applyFunc(2, 2, add);
            ,
            .expected = 4,
        },
        .{
            .input =
            \\let add = fn(a, b) { a + b };
            \\let sub = fn(a, b) { a - b };
            \\let applyFunc = fn(a, b, func) { func(a, b) };
            \\applyFunc(10, 2, sub);
            ,
            .expected = 8,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testIntegerObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input:\n{s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "string literal" {
    const input = "\"Hello World!\"";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);
    try testStringObjectEqual(evaluated, "Hello World!");
}

test "variable reassignment" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let x = 5; x = 10; x;", .expected = 10 },
        .{ .input = "let x = 1; let y = 2; x = y; x;", .expected = 2 },
        .{
            .input =
            \\let x = 1;
            \\let f = fn() { x = 2; };
            \\f();
            \\x;
            ,
            .expected = 2,
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testIntegerObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input:\n{s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "reassignment of undeclared variable" {
    const input = "x = 5;";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);
    try testErrorObjectMessageEqual(evaluated, "identifier not found: x");
}

test "string concatenation" {
    const tests = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "\"Hello\" + \" \" + \"World!\"", .expected = "Hello World!" },
        .{ .input = "\"foo\" + \"bar\"", .expected = "foobar" },
        .{ .input = "\"\" + \"hello\"", .expected = "hello" },
        .{ .input = "\"hello\" + \"\"", .expected = "hello" },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testStringObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input: {s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "string equality" {
    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "\"foo\" == \"foo\"", .expected = true },
        .{ .input = "\"foo\" != \"bar\"", .expected = true },
        .{ .input = "\"foo\" == \"bar\"", .expected = false },
        .{ .input = "\"foo\" != \"foo\"", .expected = false },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testBooleanObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input: {s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "string concatenation gc" {
    const input =
        \\let x = "hello";
        \\x = x + " world";
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);
    try testStringObjectEqual(evaluated, "hello world");

    // Only "hello world" should survive — "hello" ref_count dropped on reassignment,
    // " world" literal has ref_count 0; both swept by collect()
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedStringCount());

    // Verify x holds the concatenated string
    const x_val = env.get("x").?;
    try testStringObjectEqual(x_val, "hello world");
}

test "chained string concatenation gc" {
    const input =
        \\let x = "a" + "b" + "c";
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    _ = try testEval(input, arena.allocator(), &evaluator);

    // Verify x holds the concatenated string
    const x_val = env.get("x").?;
    try testStringObjectEqual(x_val, "abc");

    // After collect(), only "abc" survives (ref_count 1 from env).
    // "a", "b", "ab", "c" all have ref_count 0 and are swept.
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedStringCount());
}

test "concat of variables gc frees originals when unreferenced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    // a="foo", b="bar", c=a+b="foobar", then overwrite a and b with ints
    _ = try testEval(
        \\let a = "foo";
        \\let b = "bar";
        \\let c = a + b;
        \\a = 0;
        \\b = 0;
    , arena.allocator(), &evaluator);

    // "foo" and "bar" ref_counts dropped on reassignment; collect() sweeps them
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedStringCount());

    const c_val = env.get("c").?;
    try testStringObjectEqual(c_val, "foobar");
}

test "multiple concat results some collected some retained" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    // a = "xy" (from "x"+"y"), b = "12" (from "1"+"2"), then overwrite a
    _ = try testEval(
        \\let a = "x" + "y";
        \\let b = "1" + "2";
        \\a = 0;
    , arena.allocator(), &evaluator);

    // "xy" ref_count dropped on reassignment; temporaries "x","y","1","2" all swept by collect()
    collector.collect(env);
    try testing.expectEqual(1, collector.trackedStringCount());

    const b_val = env.get("b").?;
    try testStringObjectEqual(b_val, "12");
}

test "reassignment with string gc" {
    // Reassigning a variable that held a string to an int.
    // The string should be properly released via GC ref counting.
    const input =
        \\let x = "foo";
        \\let y = x;
        \\x = 10;
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);
    try testIntegerObjectEqual(evaluated, 10);

    // The string "foo" should still be tracked (y still references it)
    try testing.expectEqual(1, collector.trackedStringCount());

    // x should now be 10
    const x_val = env.get("x").?;
    try testing.expectEqual(10, x_val.int.value);

    // y should still be "foo"
    const y_val = env.get("y").?;
    try testStringObjectEqual(y_val, "foo");
}

test "builtin len function" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "len(\"hello\")", .expected = 5 },
        .{ .input = "len(\"\")", .expected = 0 },
        .{ .input = "len(\"hello world\")", .expected = 11 },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testIntegerObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print(
                "Got wrong value for input: {s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "builtin len errors" {
    const tests = [_]struct {
        input: []const u8,
        expected_message: []const u8,
    }{
        .{
            .input = "len(1)",
            .expected_message = "argument to `len` not supported, got int",
        },
        .{
            .input = "len(\"one\", \"two\")",
            .expected_message = "wrong number of arguments. got=2, want=1",
        },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testErrorObjectMessageEqual(evaluated, case.expected_message) catch |err| {
            std.debug.print(
                "Got wrong error for input: {s}\n",
                .{case.input},
            );
            return err;
        };
    }
}

test "error survives gc collect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    // Eval an undefined identifier — produces one error
    _ = try testEval("foobar", arena.allocator(), &evaluator);
    try testing.expect(evaluator.last_error != null);

    // GC collect should NOT free the error — evaluator owns it
    collector.collect(env);
    try testing.expect(evaluator.last_error != null);
    try testing.expectEqualStrings("identifier not found: foobar", evaluator.last_error.?.msg);
}

test "evaluator deinit frees error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);

    // Produce an error
    _ = try testEval("foobar", arena.allocator(), &evaluator);
    try testing.expect(evaluator.last_error != null);

    // Explicit deinit — testing.allocator validates no leaks
    evaluator.deinit();
    evaluator.last_error = null;
}

test "new eval replaces previous error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    // First error
    _ = try testEval("foobar", arena.allocator(), &evaluator);
    try testing.expect(evaluator.last_error != null);
    try testing.expectEqualStrings("identifier not found: foobar", evaluator.last_error.?.msg);

    // Second error replaces the first (first is freed)
    _ = try testEval("len(1)", arena.allocator(), &evaluator);
    try testing.expect(evaluator.last_error != null);
    try testing.expectEqualStrings("argument to `len` not supported, got int", evaluator.last_error.?.msg);
}

test "eval array literals" {
    const input = "[1, 2 * 2, 3 + 3]";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);

    const array = switch (evaluated) {
        .array => |a| a,
        else => {
            std.debug.print("Expected array. Got {s}.\n", .{evaluated.typeName()});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(@as(usize, 3), array.elements.len);
    try testIntegerObjectEqual(array.elements[0], 1);
    try testIntegerObjectEqual(array.elements[1], 4);
    try testIntegerObjectEqual(array.elements[2], 6);
}

test "eval index expressions" {
    const tests = [_]struct {
        input: []const u8,
        expected: ?i64,
    }{
        .{ .input = "[1,2,3][0]", .expected = 1 },
        .{ .input = "[1,2,3][1]", .expected = 2 },
        .{ .input = "[1,2,3][2]", .expected = 3 },
        .{ .input = "let i = 0; [1][i];", .expected = 1 },
        .{ .input = "[1,2,3][1+1];", .expected = 3 },
        .{ .input = "let myArray = [1,2,3]; myArray[2];", .expected = 3 },
        .{ .input = "let myArray = [1,2,3]; myArray[0] + myArray[1] + myArray[2];", .expected = 6 },
        .{ .input = "let myArray = [1,2,3]; let i = myArray[0]; myArray[i]", .expected = 2 },
        .{ .input = "[1,2,3][3]", .expected = null },
        .{ .input = "[1,2,3][-1]", .expected = null },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        if (case.expected) |expected| {
            testIntegerObjectEqual(evaluated, expected) catch |err| {
                std.debug.print("Got wrong value for input: {s}\n", .{case.input});
                return err;
            };
        } else {
            testNullObject(evaluated) catch |err| {
                std.debug.print("Expected null for input: {s}\n", .{case.input});
                return err;
            };
        }
    }
}

test "eval empty array" {
    const input = "[]";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);

    const array = switch (evaluated) {
        .array => |a| a,
        else => {
            std.debug.print("Expected array. Got {s}.\n", .{evaluated.typeName()});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(@as(usize, 0), array.elements.len);
}

test "builtin len on arrays" {
    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "len([1,2,3])", .expected = 3 },
        .{ .input = "len([])", .expected = 0 },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testIntegerObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print("Got wrong value for input: {s}\n", .{case.input});
            return err;
        };
    }
}

test "eval hash literal" {
    const input =
        \\{"one": 10 - 9, "two": 10 - 8, "thr" + "ee": 6 / 2}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);

    const hash = switch (evaluated) {
        .hash => |h| h,
        else => {
            std.debug.print("Expected hash. Got {s}.\n", .{evaluated.typeName()});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(@as(u32, 3), hash.pairs.count());

    // Check via integer values: iterate and collect
    var found_one = false;
    var found_two = false;
    var found_three = false;
    var iterator = hash.pairs.iterator();
    while (iterator.next()) |entry| {
        const val = switch (entry.value_ptr.value) {
            .int => |i| i.value,
            else => continue,
        };
        if (val == 1) found_one = true;
        if (val == 2) found_two = true;
        if (val == 3) found_three = true;
    }
    try testing.expect(found_one);
    try testing.expect(found_two);
    try testing.expect(found_three);
}

test "eval empty hash literal" {
    const input = "{}";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);

    const hash = switch (evaluated) {
        .hash => |h| h,
        else => {
            std.debug.print("Expected hash. Got {s}.\n", .{evaluated.typeName()});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(@as(u32, 0), hash.pairs.count());
}

test "eval hash index expressions" {
    const ExpectedValue = union(enum) {
        int: i64,
        null_val: void,
    };

    const tests = [_]struct {
        input: []const u8,
        expected: ExpectedValue,
    }{
        .{ .input = "{\"foo\": 5}[\"foo\"]", .expected = .{ .int = 5 } },
        .{ .input = "{\"foo\": 5}[\"bar\"]", .expected = .{ .null_val = {} } },
        .{ .input = "let key = \"foo\"; {\"foo\": 5}[key]", .expected = .{ .int = 5 } },
        .{ .input = "{}[\"foo\"]", .expected = .{ .null_val = {} } },
        .{ .input = "{5: 5}[5]", .expected = .{ .int = 5 } },
        .{ .input = "{true: 5}[true]", .expected = .{ .int = 5 } },
        .{ .input = "{false: 5}[false]", .expected = .{ .int = 5 } },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        switch (case.expected) {
            .int => |expected_int| {
                testIntegerObjectEqual(evaluated, expected_int) catch |err| {
                    std.debug.print("Got wrong value for input: {s}\n", .{case.input});
                    return err;
                };
            },
            .null_val => {
                testNullObject(evaluated) catch |err| {
                    std.debug.print("Expected null for input: {s}\n", .{case.input});
                    return err;
                };
            },
        }
    }
}

test "unusable hash key error" {
    const input = "{fn(x){x}: 1}";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval(input, arena.allocator(), &evaluator);
    try testErrorObjectMessageEqual(evaluated, "unusable as hash key: function");
}

test "index expression errors" {
    const tests = [_]struct {
        input: []const u8,
        expected_message: []const u8,
    }{
        .{ .input = "true[0]", .expected_message = "index operator not supported: bool" },
        .{ .input = "[1,2][true]", .expected_message = "index operator not supported: bool" },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testErrorObjectMessageEqual(evaluated, case.expected_message) catch |err| {
            std.debug.print("Got wrong error for input: {s}\n", .{case.input});
            return err;
        };
    }
}

test "builtin first" {
    const TestExpected = union(enum) { int: i64, null_val: void };
    const tests = [_]struct {
        input: []const u8,
        expected: TestExpected,
    }{
        .{ .input = "first([1, 2, 3])", .expected = .{ .int = 1 } },
        .{ .input = "first([])", .expected = .{ .null_val = {} } },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        switch (case.expected) {
            .int => |expected| try testIntegerObjectEqual(evaluated, expected),
            .null_val => try testNullObject(evaluated),
        }
    }
}

test "builtin last" {
    const TestExpected = union(enum) { int: i64, null_val: void };
    const tests = [_]struct {
        input: []const u8,
        expected: TestExpected,
    }{
        .{ .input = "last([1, 2, 3])", .expected = .{ .int = 3 } },
        .{ .input = "last([])", .expected = .{ .null_val = {} } },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        switch (case.expected) {
            .int => |expected| try testIntegerObjectEqual(evaluated, expected),
            .null_val => try testNullObject(evaluated),
        }
    }
}

test "builtin first and last return nested arrays intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const input = "let a = [[1, 2], [3]]; let f = first(a); let l = last(a); len(f) * 10 + len(l);";
    try testIntegerObjectEqual(try testEval(input, arena.allocator(), &evaluator), 21);

    collector.collect(env);
    try testIntegerObjectEqual(try testEval("f[1] + l[0] + len(a);", arena.allocator(), &evaluator), 7);
}

test "builtin rest" {
    {
        // rest([1, 2, 3]) -> [2, 3]
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval("rest([1, 2, 3])", arena.allocator(), &evaluator);
        const array = switch (evaluated) {
            .array => |a| a,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(@as(usize, 2), array.elements.len);
        try testIntegerObjectEqual(array.elements[0], 2);
        try testIntegerObjectEqual(array.elements[1], 3);
    }
    {
        // rest([]) -> null
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval("rest([])", arena.allocator(), &evaluator);
        try testNullObject(evaluated);
    }
}

test "builtin push" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval("push([1, 2], 3)", arena.allocator(), &evaluator);
    const array = switch (evaluated) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 3), array.elements.len);
    try testIntegerObjectEqual(array.elements[0], 1);
    try testIntegerObjectEqual(array.elements[1], 2);
    try testIntegerObjectEqual(array.elements[2], 3);
}

test "builtin puts returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var collector = Gc.init(testing.allocator);
    defer collector.deinit();

    const env = try collector.allocEnvironment(null);
    var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer test_writer.deinit();
    var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
    defer evaluator.deinit();

    const evaluated = try testEval("puts(\"hello\")", arena.allocator(), &evaluator);
    try testNullObject(evaluated);
}

test "builtin error cases" {
    const tests = [_]struct {
        input: []const u8,
        expected_message: []const u8,
    }{
        .{ .input = "first(1)", .expected_message = "argument to `first` must be ARRAY, got int" },
        .{ .input = "last(1)", .expected_message = "argument to `last` must be ARRAY, got int" },
        .{ .input = "rest(1)", .expected_message = "argument to `rest` must be ARRAY, got int" },
        .{ .input = "push(1, 2)", .expected_message = "argument to `push` must be ARRAY, got int" },
        .{ .input = "first(1, 2)", .expected_message = "wrong number of arguments. got=2, want=1" },
        .{ .input = "last(1, 2)", .expected_message = "wrong number of arguments. got=2, want=1" },
        .{ .input = "rest(1, 2)", .expected_message = "wrong number of arguments. got=2, want=1" },
        .{ .input = "push(1)", .expected_message = "wrong number of arguments. got=1, want=2" },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testErrorObjectMessageEqual(evaluated, case.expected_message) catch |err| {
            std.debug.print("Got wrong error for input: {s}\n", .{case.input});
            return err;
        };
    }
}

test "eval float expression" {
    const tests = [_]struct {
        input: []const u8,
        expected: f64,
    }{
        .{ .input = "3.14", .expected = 3.14 },
        .{ .input = "10.", .expected = 10.0 },
        .{ .input = "3.", .expected = 3.0 },
        .{ .input = "-3.14", .expected = -3.14 },
        .{ .input = "1.5 + 2.5", .expected = 4.0 },
        .{ .input = "3.0 - 1.0", .expected = 2.0 },
        .{ .input = "2.0 * 3.0", .expected = 6.0 },
        .{ .input = "7.0 / 2.0", .expected = 3.5 },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testFloatObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print("Got wrong value for input {s}\n", .{case.input});
            return err;
        };
    }
}

test "eval mixed int/float expression" {
    const tests = [_]struct {
        input: []const u8,
        expected: f64,
    }{
        .{ .input = "1 + 2.5", .expected = 3.5 },
        .{ .input = "3.14 * 2", .expected = 6.28 },
        .{ .input = "10 - 1.5", .expected = 8.5 },
        .{ .input = "7.0 / 2", .expected = 3.5 },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testFloatObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print("Got wrong value for input {s}\n", .{case.input});
            return err;
        };
    }
}

test "eval float comparisons" {
    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "1.5 < 2.5", .expected = true },
        .{ .input = "2.5 < 1.5", .expected = false },
        .{ .input = "3.0 == 3.0", .expected = true },
        .{ .input = "1.0 != 2.0", .expected = true },
        .{ .input = "1 < 2.5", .expected = true },
    };

    for (tests) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var collector = Gc.init(testing.allocator);
        defer collector.deinit();

        const env = try collector.allocEnvironment(null);
        var test_writer = std.Io.Writer.Allocating.init(testing.allocator);
        defer test_writer.deinit();
        var evaluator = Evaluator.init(env, &collector, &test_writer.writer);
        defer evaluator.deinit();

        const evaluated = try testEval(case.input, arena.allocator(), &evaluator);
        testBooleanObjectEqual(evaluated, case.expected) catch |err| {
            std.debug.print("Got wrong value for input {s}\n", .{case.input});
            return err;
        };
    }
}
