const std = @import("std");
const testing = std.testing;

const ast = @import("./ast.zig");
const Lexer = @import("./lexer.zig").Lexer;
const Token = @import("./token.zig").Token;
const TokenType = @import("./token.zig").TokenType;
const Parser = @import("./parser.zig").Parser;

fn testIntegerLiteral(val: *const ast.ExpressionType, literal_value: i64) !void {
    switch (val.*) {
        .integer_literal => |exp| {
            try testing.expectEqual(literal_value, exp.value);

            var buf: [21]u8 = undefined;
            const expected = try std.fmt.bufPrint(&buf, "{}", .{literal_value});
            const exp_node = ast.ExpNode.implBy(&exp);
            try testing.expectEqualStrings(expected, exp_node.tokenLiteral());
        },
        else => {
            std.debug.print("Expected an integer literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    }
}

fn testBooleanLiteral(val: *const ast.ExpressionType, literal_value: bool) !void {
    switch (val.*) {
        .boolean_literal => |exp| {
            try testing.expectEqual(literal_value, exp.value);
        },
        else => {
            std.debug.print("Expected a boolean literal. Got something else", .{});
            return error.TestUnexpectedResult;
        },
    }
}

fn testStringLiteral(val: *const ast.ExpressionType, literal_value: []const u8) !void {
    switch (val.*) {
        .string_literal => |exp| {
            try testing.expectEqualStrings(literal_value, exp.value);
        },
        else => {
            std.debug.print("Expected a string literal. Got something else", .{});
            return error.TestUnexpectedResult;
        },
    }
}

const ExpectedValue = union(enum) {
    integer: i64,
    string: []const u8,
    boolean: bool,
};

fn testIdentifier(val: *const ast.ExpressionType, literal_value: []const u8) !void {
    switch (val.*) {
        .identifier => |*exp| {
            try testing.expectEqualStrings(literal_value, exp.*.value);
        },
        else => {
            std.debug.print("Expected identifier. Got something else", .{});
            return error.TestUnexpectedResult;
        },
    }
}

fn testLiteralExpression(exp: *const ast.ExpressionType, expected: ExpectedValue) !void {
    switch (expected) {
        .integer => |val| try testIntegerLiteral(exp, val),
        .string => |val| {
            return switch (exp.*) {
                .identifier => |e| try testing.expectEqualStrings(val, e.value),
                .string_literal => |e| try testing.expectEqualStrings(val, e.value),
                else => {
                    std.debug.print("Expected identifier or string literal. Got something else", .{});
                    return error.TestUnexpectedResult;
                },
            };
        },
        .boolean => |val| try testBooleanLiteral(exp, val),
    }
}

fn testInfixExpression(exp: *const ast.ExpressionType, left: ExpectedValue, operator: []const u8, right: ExpectedValue) !void {
    switch (exp.*) {
        .infix_expression => |infix_exp| {
            try testLiteralExpression(&infix_exp.left.expression, left);
            try testing.expectEqualStrings(operator, infix_exp.operator);
            try testLiteralExpression(&infix_exp.right.expression, right);
        },
        else => {
            std.debug.print("Expected infix expression. Got something else", .{});
            return error.TestUnexpectedResult;
        },
    }
}

fn checkParserErrors(parser: *Parser) !void {
    testing.expectEqual(0, parser.allErrors().len) catch |err| {
        const errors = parser.allErrors();
        for (errors) |e| {
            std.debug.print("Found Error: {s}\n", .{e});
        }
        return err;
    };
}

test "print let statement" {
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();

    const statement: ast.StatementType = .{
        .let = .{
            .token = Token.init(.let, "let"),
            .name = ast.Identifier.init(Token.init(.iden, "myVar"), "myVar"),
            .value = .{ .expression = ast.ExpressionType.initIdentifier(Token.init(.iden, "myValue"), "myValue") },
        },
    };

    const let_statement = statement.let;
    const node = ast.Node.implBy(&let_statement);

    try node.toString(&output_writer.writer);

    try testing.expectEqualStrings("let myVar = myValue;", output_writer.written());
}

test "print return statement" {
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();

    const statement: ast.StatementType = .{
        .@"return" = .{
            .token = Token.init(.@"return", "return"),
            .value = .{ .expression = ast.ExpressionType.initIdentifier(Token.init(.iden, "myValue"), "myValue") },
        },
    };

    const return_statement: ast.StatementType.ReturnStatement = statement.@"return";
    const node = ast.Node.implBy(&return_statement);

    try node.toString(&output_writer.writer);

    try testing.expectEqualStrings("return myValue;", output_writer.written());
}

test "print expression statement" {
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();

    const statement: ast.StatementType = .{
        .expression = .{
            .expression = ast.ExpressionType.initIdentifier(Token.init(.iden, "myValue"), "myValue"),
        },
    };

    const expression_statement = statement.expression;
    const node = ast.Node.implBy(&expression_statement);
    try node.toString(&output_writer.writer);

    try testing.expectEqualStrings("myValue", output_writer.written());
}

test "parse return" {
    const input =
        \\return 5;
        \\return 10;
        \\return 838383;
    ;

    const expected_number_of_statements = 3;
    var lexer = Lexer.init(input);
    var parser = Parser.init(testing.allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();

    try testing.expectEqual(expected_number_of_statements, program.statements.items.len);
}

test "parse return statement values" {
    const cases = [_]struct {
        input: []const u8,
        expected_value: ExpectedValue,
    }{
        .{ .input = "return 5;", .expected_value = .{ .integer = 5 } },
        .{ .input = "return true;", .expected_value = .{ .boolean = true } },
        .{ .input = "return foobar;", .expected_value = .{ .string = "foobar" } },
    };

    for (cases) |case| {
        const allocator = std.testing.allocator;
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expectEqual(1, program.statements.items.len);

        const return_stmt = switch (program.statements.items[0]) {
            .@"return" => |val| val,
            else => {
                std.debug.print("Expected a return statement. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        };

        const return_value = return_stmt.value orelse return error.TestUnexpectedResult;
        try testLiteralExpression(&return_value.expression, case.expected_value);
    }
}

test "parse bare return statement" {
    const input = "return;";

    var lexer = Lexer.init(input);
    var parser = Parser.init(testing.allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const return_stmt = switch (program.statements.items[0]) {
        .@"return" => |val| val,
        else => return error.TestUnexpectedResult,
    };

    try testing.expect(return_stmt.value == null);
}

test "parse let error" {
    const input =
        \\let x 5;
        \\let = 10;
        \\let 838383;
    ;

    const expected_errors = [_][]const u8{
        "Expected next token to be .assign, got .int",
        "Expected next token to be .iden, got .assign",
        "No prefix parse fn found for token type .assign",
        "Expected next token to be .iden, got .int",
    };

    var lexer = Lexer.init(input);
    var parser = Parser.init(testing.allocator, &lexer);
    defer parser.deinit();

    _ = try parser.parse();
    const errors = parser.allErrors();

    try testing.expectEqual(4, errors.len);
    for (expected_errors, 0..) |expected_error, i| {
        try testing.expectEqualStrings(expected_error, errors[i]);
    }
}

test "out-of-range integer literals are reported as parse errors" {
    const input =
        \\let x = 99999999999999999999;
        \\1 + 9223372036854775808;
        \\9223372036854775807;
    ;

    var lexer = Lexer.init(input);
    var parser = Parser.init(testing.allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();
    const errors = parser.allErrors();

    // Each failed statement also leaves its `;` behind, which the parser's
    // recovery reports separately; only the literal errors matter here.
    var literal_errors: std.ArrayList([]const u8) = .empty;
    defer literal_errors.deinit(testing.allocator);
    for (errors) |err| {
        if (std.mem.startsWith(u8, err, "could not parse")) try literal_errors.append(testing.allocator, err);
    }

    try testing.expectEqual(2, literal_errors.items.len);
    try testing.expectEqualStrings("could not parse \"99999999999999999999\" as integer", literal_errors.items[0]);
    try testing.expectEqualStrings("could not parse \"9223372036854775808\" as integer", literal_errors.items[1]);

    const last = program.statements.items[program.statements.items.len - 1];
    try testIntegerLiteral(&last.expression.expression, std.math.maxInt(i64));
}

test "parser let" {
    const input =
        \\let x = 5;
        \\let y = 10;
        \\let foobar = 838383;
    ;

    const expected_ast = [_]struct { TokenType, []const u8 }{
        .{ TokenType.let, "x" },
        .{ TokenType.let, "y" },
        .{ TokenType.let, "foobar" },
    };

    const allocator = std.testing.allocator;

    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();

    for (expected_ast, 0..) |expected_output, i| {
        const stmt = program.statements.items[i];
        const expected_token_type, const expected_name = expected_output;
        switch (stmt) {
            .let => |let_stmt| {
                try testing.expectEqualStrings(expected_name, let_stmt.name.value);
                try testing.expectEqual(expected_token_type, let_stmt.token.token_type);
            },
            else => unreachable,
        }
    }
}

test "parse let statement values" {
    const cases = [_]struct {
        input: []const u8,
        expected_identifier: []const u8,
        expected_value: ExpectedValue,
    }{
        .{ .input = "let x = 5;", .expected_identifier = "x", .expected_value = .{ .integer = 5 } },
        .{ .input = "let y = true;", .expected_identifier = "y", .expected_value = .{ .boolean = true } },
        .{ .input = "let foobar = y;", .expected_identifier = "foobar", .expected_value = .{ .string = "y" } },
    };

    for (cases) |case| {
        const allocator = std.testing.allocator;
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expectEqual(1, program.statements.items.len);

        const let_stmt = switch (program.statements.items[0]) {
            .let => |val| val,
            else => {
                std.debug.print("Expected a let statement. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        };

        try testing.expectEqualStrings(case.expected_identifier, let_stmt.name.value);

        try testLiteralExpression(&let_stmt.value.expression, case.expected_value);
    }
}

test "basic identifier parsing" {
    const input = "foobar;";

    const allocator = std.testing.allocator;

    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();

    try testing.expect(program.statements.items.len == 1);

    const expression_statement = switch (program.statements.items[0]) {
        .expression => |value| value,
        else => unreachable,
    };

    try testIdentifier(&expression_statement.expression, "foobar");
}

test "basic int parsing" {
    const input = "5;";

    const allocator = std.testing.allocator;

    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();

    try testing.expect(program.statements.items.len == 1);

    const expression_statement = switch (program.statements.items[0]) {
        .expression => |value| value,
        else => unreachable,
    };

    try testIntegerLiteral(&expression_statement.expression, 5);
}

test "parse string literal expression" {
    const input = "\"hello world\";";

    const allocator = std.testing.allocator;

    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const stmt = switch (program.statements.items[0]) {
        .expression => |value| value,
        else => {
            std.debug.print("Expected an expression statement. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testStringLiteral(&stmt.expression, "hello world");
}

test "basic boolean parsing" {
    const cases = [_]struct {
        input: []const u8,
        expected: bool,
    }{ .{
        .input = "true;",
        .expected = true,
    }, .{
        .input = "false;",
        .expected = false,
    } };

    for (cases) |case| {
        const allocator = std.testing.allocator;

        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();
        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expect(program.statements.items.len == 1);

        const expression_statement = switch (program.statements.items[0]) {
            .expression => |value| value,
            else => unreachable,
        };

        try testBooleanLiteral(&expression_statement.expression, case.expected);
    }
}

test "parse prefix expressions" {
    const cases = [_]struct {
        input: []const u8,
        operator: []const u8,
        value: ExpectedValue,
    }{
        .{
            .input = "!5",
            .operator = "!",
            .value = .{
                .integer = 5,
            },
        },
        .{
            .input = "-15",
            .operator = "-",
            .value = .{
                .integer = 15,
            },
        },
        .{
            .input = "!true;",
            .operator = "!",
            .value = .{
                .boolean = true,
            },
        },
        .{
            .input = "!false;",
            .operator = "!",
            .value = .{
                .boolean = false,
            },
        },
    };

    for (cases) |case| {
        const allocator = std.testing.allocator;
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expectEqual(1, program.*.statements.items.len);

        switch (program.statements.items[0]) {
            .expression => {},
            else => {
                std.debug.print("Expected an expression. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        }

        const parsed_statement = program.statements.items[0].expression;

        switch (parsed_statement.expression) {
            .prefix_expression => {},
            else => {
                std.debug.print("Expected a prefix expression. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        }

        const prefix_expression = parsed_statement.expression.prefix_expression;
        const right_expression = prefix_expression.right.expression;

        try testing.expectEqualStrings(case.operator, prefix_expression.operator);
        try testLiteralExpression(&right_expression, case.value);
    }
}

test "infix operator precedence" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
        expected_items: usize = 1,
    }{
        .{
            .input = "-a * b",
            .expected = "((-a) * b)",
        },
        .{
            .input = "!-a",
            .expected = "(!(-a))",
        },
        .{
            .input = "a + b + c",
            .expected = "((a + b) + c)",
        },
        .{
            .input = "a + b - c",
            .expected = "((a + b) - c)",
        },
        .{
            .input = "a * b * c",
            .expected = "((a * b) * c)",
        },
        .{
            .input = "a * b / c",
            .expected = "((a * b) / c)",
        },
        .{
            .input = "a + b / c",
            .expected = "(a + (b / c))",
        },
        .{
            .input = "a + b * c + d / e - f",
            .expected = "(((a + (b * c)) + (d / e)) - f)",
        },
        .{
            .input = "3 + 4; -5 * 5",
            .expected = "(3 + 4)((-5) * 5)",
            .expected_items = 2,
        },
        .{
            .input = "5 > 4 == 3 < 4",
            .expected = "((5 > 4) == (3 < 4))",
        },
        .{
            .input = "5 < 4 != 3 > 4",
            .expected = "((5 < 4) != (3 > 4))",
        },
        .{
            .input = "3 + 4 * 5 == 3 * 1 + 4 * 5",
            .expected = "((3 + (4 * 5)) == ((3 * 1) + (4 * 5)))",
        },
        .{
            .input = "true",
            .expected = "true",
        },
        .{
            .input = "false",
            .expected = "false",
        },
        .{
            .input = "3 > 5 == false",
            .expected = "((3 > 5) == false)",
        },
        .{
            .input = "3 < 5 == true",
            .expected = "((3 < 5) == true)",
        },
        .{
            .input = "1 + (2 + 3) + 4",
            .expected = "((1 + (2 + 3)) + 4)",
        },
        .{
            .input = "(5 + 5) * 2",
            .expected = "((5 + 5) * 2)",
        },
        .{
            .input = "2 / (5 + 5)",
            .expected = "(2 / (5 + 5))",
        },
        .{
            .input = "-(5 + 5)",
            .expected = "(-(5 + 5))",
        },
        .{
            .input = "!(true == true)",
            .expected = "(!(true == true))",
        },
        .{
            .input = "a + add(b * c) + d",
            .expected = "((a + add((b * c))) + d)",
        },
        .{
            .input = "add(a, b, 1, 2 * 3, 4 + 5, add(6, 7 * 8))",
            .expected = "add(a, b, 1, (2 * 3), (4 + 5), add(6, (7 * 8)))",
        },
        .{
            .input = "add(a + b + c * d / f + g)",
            .expected = "add((((a + b) + ((c * d) / f)) + g))",
        },
        .{
            .input = "a * [1, 2, 3, 4][b * c] * d",
            .expected = "((a * ([1, 2, 3, 4][(b * c)])) * d)",
        },
        .{
            .input = "add(a * b[2], b[1], 2 * [1, 2][1])",
            .expected = "add((a * (b[2])), (b[1]), (2 * ([1, 2][1])))",
        },
    };

    for (cases) |case| {
        const allocator = testing.allocator;

        var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output_writer.deinit();

        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expectEqual(case.expected_items, program.*.statements.items.len);

        switch (program.statements.items[0]) {
            .expression => {},
            else => {
                std.debug.print("Expected an expression. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        }

        try program.toString(&output_writer.writer);

        try testing.expectEqualStrings(case.expected, output_writer.written());
    }
}

test "parse infix expressions" {
    const cases = [_]struct {
        input: []const u8,
        leftValue: ExpectedValue,
        operator: []const u8,
        rightValue: ExpectedValue,
    }{
        .{
            .input = "5 + 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "+",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 - 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "-",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 * 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "*",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 / 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "/",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 > 5;",
            .leftValue = .{ .integer = 5 },
            .operator = ">",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 < 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "<",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 == 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "==",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "5 != 5;",
            .leftValue = .{ .integer = 5 },
            .operator = "!=",
            .rightValue = .{ .integer = 5 },
        },
        .{
            .input = "true == true;",
            .leftValue = .{ .boolean = true },
            .operator = "==",
            .rightValue = .{ .boolean = true },
        },
        .{
            .input = "true != false;",
            .leftValue = .{ .boolean = true },
            .operator = "!=",
            .rightValue = .{ .boolean = false },
        },
        .{
            .input = "false == false;",
            .leftValue = .{ .boolean = false },
            .operator = "==",
            .rightValue = .{ .boolean = false },
        },
    };

    for (cases) |case| {
        const allocator = std.testing.allocator;
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expectEqual(1, program.*.statements.items.len);

        const statement = switch (program.statements.items[0]) {
            .expression => |*val| val,
            else => {
                std.debug.print("Expected an expression. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        };

        try testInfixExpression(&statement.expression, case.leftValue, case.operator, case.rightValue);
    }
}

test "parsing if expression" {
    const input = "if (x < y) { x }";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);

    try testing.expectEqual(1, program.*.statements.items.len);

    const expression = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    const if_expression = switch (expression.expression) {
        .if_expression => |val| val,
        else => {
            std.debug.print("Expected if expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testInfixExpression(&if_expression.condition.expression, .{ .string = "x" }, "<", .{ .string = "y" });

    try testing.expectEqual(1, if_expression.consequence.statements.items.len);

    const consequence_expression = switch (if_expression.consequence.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression in consequence. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testIdentifier(&consequence_expression.expression, "x");

    try testing.expect(null == if_expression.alternative);
}

test "parsing if else expression" {
    const input = "if (x < y) { x } else { y }";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);

    try testing.expectEqual(1, program.*.statements.items.len);

    const expression = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    const if_expression = switch (expression.expression) {
        .if_expression => |val| val,
        else => {
            std.debug.print("Expected if expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testInfixExpression(&if_expression.condition.expression, .{ .string = "x" }, "<", .{ .string = "y" });

    try testing.expectEqual(1, if_expression.consequence.statements.items.len);

    const consequence_expression = switch (if_expression.consequence.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression in consequence. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testIdentifier(&consequence_expression.expression, "x");

    const alternative = if_expression.alternative.?;

    try testing.expectEqual(1, alternative.statements.items.len);

    const alternative_expression = switch (alternative.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression in alternative. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testIdentifier(&alternative_expression.expression, "y");
}

test "paring function literals" {
    const input = "fn(x,y){ x + y; }";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);

    try testing.expectEqual(1, program.*.statements.items.len);

    const expression = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    const fn_expression = switch (expression.expression) {
        .function_literal => |val| val,
        else => {
            std.debug.print("Expected if expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(2, fn_expression.parameters.len);

    try testing.expectEqualStrings("x", fn_expression.parameters[0].value);
    try testing.expectEqualStrings("y", fn_expression.parameters[1].value);

    try testing.expectEqual(1, fn_expression.body.statements.items.len);

    const body_expression = switch (fn_expression.body.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression in function body. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testInfixExpression(&body_expression.expression, .{ .string = "x" }, "+", .{ .string = "y" });
}

test "function parameter parsing" {
    const cases = [_]struct {
        input: []const u8,
        expected_params: []const []const u8,
    }{
        .{ .input = "fn() {};", .expected_params = &.{} },
        .{ .input = "fn(x) {};", .expected_params = &.{"x"} },
        .{ .input = "fn(x, y, z) {};", .expected_params = &.{ "x", "y", "z" } },
    };

    for (cases) |case| {
        const allocator = std.testing.allocator;
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();
        try checkParserErrors(&parser);

        try testing.expectEqual(1, program.statements.items.len);

        const expression = switch (program.statements.items[0]) {
            .expression => |val| val,
            else => return error.TestUnexpectedResult,
        };

        const fn_expression = switch (expression.expression) {
            .function_literal => |val| val,
            else => return error.TestUnexpectedResult,
        };

        try testing.expectEqual(case.expected_params.len, fn_expression.parameters.len);

        for (case.expected_params, 0..) |expected_param, i| {
            try testing.expectEqualStrings(expected_param, fn_expression.parameters[i].value);
        }
    }
}

test "parsing call expression" {
    const input = "add(1, 2 * 3, 4 + 5);";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);

    try testing.expectEqual(1, program.statements.items.len);

    const expression = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    const call_exp = switch (expression.expression) {
        .call_expression => |val| val,
        else => {
            std.debug.print("Expected call expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testIdentifier(&call_exp.function.expression, "add");

    try testing.expectEqual(3, call_exp.arguments.len);

    try testLiteralExpression(&call_exp.arguments[0].expression, .{ .integer = 1 });
    try testInfixExpression(&call_exp.arguments[1].expression, .{ .integer = 2 }, "*", .{ .integer = 3 });
    try testInfixExpression(&call_exp.arguments[2].expression, .{ .integer = 4 }, "+", .{ .integer = 5 });
}

test "parse assign expression" {
    const cases = [_]struct {
        input: []const u8,
        expected_name: []const u8,
        expected_value: ExpectedValue,
    }{
        .{ .input = "x = 5;", .expected_name = "x", .expected_value = .{ .integer = 5 } },
        .{ .input = "y = true;", .expected_name = "y", .expected_value = .{ .boolean = true } },
        .{ .input = "foobar = y;", .expected_name = "foobar", .expected_value = .{ .string = "y" } },
    };

    for (cases) |case| {
        const allocator = std.testing.allocator;
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try testing.expectEqual(1, program.statements.items.len);

        const expr_stmt = switch (program.statements.items[0]) {
            .expression => |val| val,
            else => {
                std.debug.print("Expected an expression statement. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        };

        const assign_exp = switch (expr_stmt.expression) {
            .assign_expression => |val| val,
            else => {
                std.debug.print("Expected assign expression. Got something else.", .{});
                return error.TestUnexpectedResult;
            },
        };

        try testing.expectEqualStrings(case.expected_name, assign_exp.name.value);
        try testLiteralExpression(&assign_exp.value.expression, case.expected_value);
    }
}

test "parse array literal" {
    const input = "[1, 2, 3]";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const arr = switch (expr_stmt.expression) {
        .array_literal => |val| val,
        else => {
            std.debug.print("Expected array literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(3, arr.elements.len);
    try testIntegerLiteral(&arr.elements[0].expression, 1);
    try testIntegerLiteral(&arr.elements[1].expression, 2);
    try testIntegerLiteral(&arr.elements[2].expression, 3);
}

test "parse empty array literal" {
    const input = "[]";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const arr = switch (expr_stmt.expression) {
        .array_literal => |val| val,
        else => {
            std.debug.print("Expected array literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(0, arr.elements.len);
}

test "parse index expression" {
    const input = "myArray[1 + 1]";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const idx = switch (expr_stmt.expression) {
        .index_expression => |val| val,
        else => {
            std.debug.print("Expected index expression. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testIdentifier(&idx.left.expression, "myArray");
    try testInfixExpression(&idx.index.expression, .{ .integer = 1 }, "+", .{ .integer = 1 });
}

test "parse hash literal with string keys" {
    const input =
        \\{"one": 1, "two": 2, "three": 3}
    ;

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const hash = switch (expr_stmt.expression) {
        .hash_literal => |val| val,
        else => {
            std.debug.print("Expected hash literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(3, hash.pairs.len);

    const expected = [_]struct { []const u8, i64 }{
        .{ "one", 1 },
        .{ "two", 2 },
        .{ "three", 3 },
    };

    for (expected, 0..) |exp, i| {
        try testStringLiteral(&hash.pairs[i].key.expression, exp[0]);
        try testIntegerLiteral(&hash.pairs[i].value.expression, exp[1]);
    }
}

test "parse empty hash literal" {
    const input = "{}";

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const hash = switch (expr_stmt.expression) {
        .hash_literal => |val| val,
        else => {
            std.debug.print("Expected hash literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(0, hash.pairs.len);
}

test "parse hash literal with expression values" {
    const input =
        \\{"one": 0 + 1, "two": 10 - 8, "three": 15 / 5}
    ;

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const hash = switch (expr_stmt.expression) {
        .hash_literal => |val| val,
        else => {
            std.debug.print("Expected hash literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(3, hash.pairs.len);

    try testStringLiteral(&hash.pairs[0].key.expression, "one");
    try testInfixExpression(&hash.pairs[0].value.expression, .{ .integer = 0 }, "+", .{ .integer = 1 });

    try testStringLiteral(&hash.pairs[1].key.expression, "two");
    try testInfixExpression(&hash.pairs[1].value.expression, .{ .integer = 10 }, "-", .{ .integer = 8 });

    try testStringLiteral(&hash.pairs[2].key.expression, "three");
    try testInfixExpression(&hash.pairs[2].value.expression, .{ .integer = 15 }, "/", .{ .integer = 5 });
}

test "parse hash literal with mixed key types" {
    const input =
        \\{1: "one", true: "yes", "name": "jimmy"}
    ;

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();

    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const hash = switch (expr_stmt.expression) {
        .hash_literal => |val| val,
        else => {
            std.debug.print("Expected hash literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(3, hash.pairs.len);

    try testIntegerLiteral(&hash.pairs[0].key.expression, 1);
    try testStringLiteral(&hash.pairs[0].value.expression, "one");

    try testBooleanLiteral(&hash.pairs[1].key.expression, true);
    try testStringLiteral(&hash.pairs[1].value.expression, "yes");

    try testStringLiteral(&hash.pairs[2].key.expression, "name");
    try testStringLiteral(&hash.pairs[2].value.expression, "jimmy");
}

test "assign expression precedence" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "x = 5 + 3;",
            .expected = "x = (5 + 3)",
        },
    };

    for (cases) |case| {
        const allocator = testing.allocator;

        var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output_writer.deinit();

        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();

        const program = try parser.parse();

        try checkParserErrors(&parser);

        try program.toString(&output_writer.writer);

        try testing.expectEqualStrings(case.expected, output_writer.written());
    }
}

test "print function literal with name" {
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();

    const body = ast.StatementType.BlockStatement.init(Token.init(.lbrace, "{"), std.testing.allocator);

    const fn_lit = ast.ExpressionType.FunctionLiteral{
        .token = Token.init(.function, "fn"),
        .parameters = &.{},
        .body = body,
        .name = "myFunction",
    };

    try fn_lit.toString(&output_writer.writer);
    try testing.expectEqualStrings("fn myFunction() ", output_writer.written());
}

test "function literal with name" {
    const input = "let myFunction = fn() { };";

    const allocator = std.testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();
    try checkParserErrors(&parser);

    try testing.expectEqual(1, program.statements.items.len);

    const let_stmt = switch (program.statements.items[0]) {
        .let => |val| val,
        else => return error.TestUnexpectedResult,
    };

    const function = switch (let_stmt.value.expression) {
        .function_literal => |val| val,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqualStrings("myFunction", function.name orelse return error.TestUnexpectedResult);
}

fn testFloatLiteral(val: *const ast.ExpressionType, literal_value: f64) !void {
    switch (val.*) {
        .float_literal => |exp| {
            try testing.expectEqual(literal_value, exp.value);
        },
        else => {
            std.debug.print("Expected a float literal. Got something else.", .{});
            return error.TestUnexpectedResult;
        },
    }
}

test "parse float literal" {
    const allocator = testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expected: f64,
    }{
        .{ .input = "3.14;", .expected = 3.14 },
        .{ .input = "10.;", .expected = 10.0 },
        .{ .input = "3.;", .expected = 3.0 },
        .{ .input = "10.5;", .expected = 10.5 },
    };

    for (tests) |case| {
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(allocator, &lexer);
        defer parser.deinit();
        const program = try parser.parse();

        try testing.expectEqual(@as(usize, 1), program.statements.items.len);
        const stmt = program.statements.items[0];
        const exp = switch (stmt) {
            .expression => |e| &e.expression,
            else => return error.TestUnexpectedResult,
        };
        try testFloatLiteral(exp, case.expected);
    }
}

test "parse float in prefix expression" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("-3.14;");
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);
    const stmt = program.statements.items[0];
    const exp = switch (stmt) {
        .expression => |e| &e.expression,
        else => return error.TestUnexpectedResult,
    };
    switch (exp.*) {
        .prefix_expression => |prefix| {
            try testing.expectEqualStrings("-", prefix.operator);
            try testFloatLiteral(&prefix.right.expression, 3.14);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse float in infix expression" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("1.5 + 2.5;");
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    const program = try parser.parse();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);
    const stmt = program.statements.items[0];
    const exp = switch (stmt) {
        .expression => |e| &e.expression,
        else => return error.TestUnexpectedResult,
    };
    switch (exp.*) {
        .infix_expression => |infix| {
            try testFloatLiteral(&infix.left.expression, 1.5);
            try testing.expectEqualStrings("+", infix.operator);
            try testFloatLiteral(&infix.right.expression, 2.5);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn checkLoopCleanup(allocator: std.mem.Allocator, input: []const u8, malformed: bool) !void {
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();
    _ = try parser.parse();
    try testing.expectEqual(malformed, parser.allErrors().len > 0);
}

test "for loops clean up malformed input and allocation failures" {
    const malformed = [_][]const u8{
        "for let i = f(); i < 10;",
        "for let i = f() i < 10; i = i + 1 {}",
        "for let i = f(); i < 10 i = i + 1 {}",
        "for let i = f(); i < 10; i = i + 1",
        "for i in f()",
        "for i in (f() {}",
        "for i in f(1, ) {}",
        "for i in [f(), ] {}",
        "for i in {f(): } {}",
        "for i in a[f() {}",
        "for i in f() + {}",
        "for i in !",
        "for i in f() +",
        "for i in fn(x, y",
        "for i in fn(x) f()",
        "for i in if (f() {}",
        "for i in if (f()) {} else f()",
        "for i in {f()}",
        "for i in {f(): 1 f(): 2} {}",
        "for i, in f() {}",
        "for i f() {}",
        "for i in fn(x) {} { let x = f();",
        "for i in if (f()) { f(); } else {} {",
        "for { let x = f();",
        "for { (a + b) = f(); }",
    };
    for (malformed) |input| {
        try testing.checkAllAllocationFailures(testing.allocator, checkLoopCleanup, .{ input, true });
    }
    const valid = [_][]const u8{
        "for { f(); }",
        "for let i = f(); i < 10; i = i + 1 { f(i); }",
        "for key, value in [f(), 2] { value; }",
        "for i in fn(x) { return x; } {}",
        "for i in if (f()) { [1]; } else { [2]; } {}",
        "for i in {f(): a[1]} {}",
        "for i in -f() {}",
        "for { for i in 0..10 { f(i); } }",
    };
    for (valid) |input| {
        try testing.checkAllAllocationFailures(testing.allocator, checkLoopCleanup, .{ input, false });
    }
}

test "parse infinite for loop" {
    const input = "for {}";

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();
    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const for_stmt = switch (program.statements.items[0]) {
        .@"for" => |val| val,
        else => {
            std.debug.print("Expected a for statement. Got something else.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    switch (for_stmt.kind) {
        .infinite => {},
        else => {
            std.debug.print("Expected infinite for loop.\n", .{});
            return error.TestUnexpectedResult;
        },
    }

    try testing.expectEqual(0, for_stmt.body.statements.items.len);
}

test "parse c-style for loop" {
    const input = "for let i = 0; i < 10; i = i + 1 {}";

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();
    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const for_stmt = switch (program.statements.items[0]) {
        .@"for" => |val| val,
        else => {
            std.debug.print("Expected a for statement. Got something else.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    const cs = switch (for_stmt.kind) {
        .c_style => |val| val,
        else => {
            std.debug.print("Expected c-style for loop.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    // initializer: let i = 0
    try testing.expectEqualStrings("i", cs.initializer.name.value);
    try testLiteralExpression(&cs.initializer.value.expression, .{ .integer = 0 });

    // condition: i < 10
    try testInfixExpression(&cs.condition.expression, .{ .string = "i" }, "<", .{ .integer = 10 });

    // update: i = i + 1
    const assign_exp = switch (cs.update.expression) {
        .assign_expression => |val| val,
        else => {
            std.debug.print("Expected assign expression for update.\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("i", assign_exp.name.value);
    try testInfixExpression(&assign_exp.value.expression, .{ .string = "i" }, "+", .{ .integer = 1 });

    try testing.expectEqual(0, for_stmt.body.statements.items.len);
}

test "parse range for loop" {
    const input = "for i in 0..10 {}";

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();
    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const for_stmt = switch (program.statements.items[0]) {
        .@"for" => |val| val,
        else => {
            std.debug.print("Expected a for statement. Got something else.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    const iter = switch (for_stmt.kind) {
        .iterator => |val| val,
        else => {
            std.debug.print("Expected iterator for loop.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqualStrings("i", iter.ident.value);
    try testing.expect(iter.second_ident == null);

    // iterable: 0..10 (infix expression with ".." operator)
    try testInfixExpression(&iter.iterable.expression, .{ .integer = 0 }, "..", .{ .integer = 10 });

    try testing.expectEqual(0, for_stmt.body.statements.items.len);
}

test "parse for loop with two iteration variables" {
    const input = "for key, value in some_collection {}";

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();
    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const for_stmt = switch (program.statements.items[0]) {
        .@"for" => |val| val,
        else => {
            std.debug.print("Expected a for statement. Got something else.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    const iter = switch (for_stmt.kind) {
        .iterator => |val| val,
        else => {
            std.debug.print("Expected iterator for loop.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqualStrings("key", iter.ident.value);
    const second = iter.second_ident orelse {
        std.debug.print("Expected second iteration variable.\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("value", second.value);

    // iterable: some_collection (identifier)
    try testIdentifier(&iter.iterable.expression, "some_collection");

    try testing.expectEqual(0, for_stmt.body.statements.items.len);
}

test "parse range exclusive expression" {
    const input = "0..10;";

    const allocator = testing.allocator;
    var lexer = Lexer.init(input);
    var parser = Parser.init(allocator, &lexer);
    defer parser.deinit();

    const program = try parser.parse();
    try checkParserErrors(&parser);
    try testing.expectEqual(1, program.statements.items.len);

    const expr_stmt = switch (program.statements.items[0]) {
        .expression => |val| val,
        else => {
            std.debug.print("Expected an expression statement. Got something else.\n", .{});
            return error.TestUnexpectedResult;
        },
    };

    try testInfixExpression(&expr_stmt.expression, .{ .integer = 0 }, "..", .{ .integer = 10 });
}
