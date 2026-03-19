const std = @import("std");
const testing = std.testing;

const Lexer = @import("./lexer.zig").Lexer;
const TokenType = @import("./token.zig").TokenType;

test "read tokens" {
    const input =
        \\let five = 5;
        \\ let ten = 10;
        \\ let add = fn(x, y) {
        \\     x + y;
        \\ };
        \\ let result = add(five, ten);
        \\ !-/*5;
        \\ 5 < 10 > 5;
        \\ if (5 < 10) {
        \\     return true;
        \\ } else {
        \\     return false;
        \\ }
        \\ 10 == 10;
        \\ 10 != 9;
        \\ "foo bar"
        \\ "foobar"
        \\ [1, 2]
        \\ {"foo": "bar"}
        \\12;
        \\10.;
        \\10.3;
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ TokenType.let, "let" },
        .{ TokenType.iden, "five" },
        .{ TokenType.assign, "=" },
        .{ TokenType.int, "5" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.let, "let" },
        .{ TokenType.iden, "ten" },
        .{ TokenType.assign, "=" },
        .{ TokenType.int, "10" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.let, "let" },
        .{ TokenType.iden, "add" },
        .{ TokenType.assign, "=" },
        .{ TokenType.function, "fn" },
        .{ TokenType.lparen, "(" },
        .{ TokenType.iden, "x" },
        .{ TokenType.comma, "," },
        .{ TokenType.iden, "y" },
        .{ TokenType.rparen, ")" },
        .{ TokenType.lbrace, "{" },
        .{ TokenType.iden, "x" },
        .{ TokenType.plus, "+" },
        .{ TokenType.iden, "y" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.rbrace, "}" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.let, "let" },
        .{ TokenType.iden, "result" },
        .{ TokenType.assign, "=" },
        .{ TokenType.iden, "add" },
        .{ TokenType.lparen, "(" },
        .{ TokenType.iden, "five" },
        .{ TokenType.comma, "," },
        .{ TokenType.iden, "ten" },
        .{ TokenType.rparen, ")" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.bang, "!" },
        .{ TokenType.minus, "-" },
        .{ TokenType.slash, "/" },
        .{ TokenType.asterisk, "*" },
        .{ TokenType.int, "5" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.int, "5" },
        .{ TokenType.lt, "<" },
        .{ TokenType.int, "10" },
        .{ TokenType.gt, ">" },
        .{ TokenType.int, "5" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.@"if", "if" },
        .{ TokenType.lparen, "(" },
        .{ TokenType.int, "5" },
        .{ TokenType.lt, "<" },
        .{ TokenType.int, "10" },
        .{ TokenType.rparen, ")" },
        .{ TokenType.lbrace, "{" },
        .{ TokenType.@"return", "return" },
        .{ TokenType.true, "true" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.rbrace, "}" },
        .{ TokenType.@"else", "else" },
        .{ TokenType.lbrace, "{" },
        .{ TokenType.@"return", "return" },
        .{ TokenType.false, "false" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.rbrace, "}" },
        .{ TokenType.int, "10" },
        .{ TokenType.eq, "==" },
        .{ TokenType.int, "10" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.int, "10" },
        .{ TokenType.not_eq, "!=" },
        .{ TokenType.int, "9" },
        .{ TokenType.semicolon, ";" },
        .{ TokenType.string, "foo bar" },
        .{ TokenType.string, "foobar" },
        .{ TokenType.lbracket, "[" },
        .{ TokenType.int, "1" },
        .{ TokenType.comma, "," },
        .{ TokenType.int, "2" },
        .{ TokenType.rbracket, "]" },
        .{ TokenType.lbrace, "{" },
        .{ TokenType.string, "foo" },
        .{ TokenType.colon, ":" },
        .{ TokenType.string, "bar" },
        .{ TokenType.rbrace, "}" },
        .{ .int, "12" },
        .{ .semicolon, ";" },
        .{ .float, "10." },
        .{ .semicolon, ";" },
        .{ .float, "10.3" },
        .{ .semicolon, ";" },
        .{ TokenType.eof, "eof" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}

test "read escaped string tokens" {
    const input =
        \\ "hello \"world\""
        \\ "hello\n world"
        \\ "hello\t\t\tworld"
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ TokenType.string, "hello \\\"world\\\"" },
        .{ TokenType.string, "hello\\n world" },
        .{ TokenType.string, "hello\\t\\t\\tworld" },
        .{ TokenType.eof, "eof" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}

test "read basic for loop" {
    const input =
        \\ for {}
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ .@"for", "for" },
        .{ .lbrace, "{" },
        .{ .rbrace, "}" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}

test "loop over range old style" {
    const input =
        \\for let i = 0; i < 10; i = i + 1 {}
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ .@"for", "for" },
        .{ .let, "let" },
        .{ .iden, "i" },
        .{ .assign, "=" },
        .{ .int, "0" },
        .{ .semicolon, ";" },
        .{ .iden, "i" },
        .{ .lt, "<" },
        .{ .int, "10" },
        .{ .semicolon, ";" },
        .{ .iden, "i" },
        .{ .assign, "=" },
        .{ .iden, "i" },
        .{ .plus, "+" },
        .{ .int, "1" },
        .{ .lbrace, "{" },
        .{ .rbrace, "}" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}

test "loop over range new style" {
    const input =
        \\for i in 0..10 {}
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ .@"for", "for" },
        .{ .iden, "i" },
        .{ .in, "in" },
        .{ .int, "0" },
        .{ .range_exclusive, ".." },
        .{ .int, "10" },
        .{ .lbrace, "{" },
        .{ .rbrace, "}" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}

test "bare period is illegal" {
    const input =
        \\.
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ .illegal, "." },
        .{ .eof, "eof" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}

test "for loop with two iteration variables" {
    const input =
        \\for key, value in some_collection {}
    ;

    const tests = [_]struct { TokenType, []const u8 }{
        .{ .@"for", "for" },
        .{ .iden, "key" },
        .{ .comma, "," },
        .{ .iden, "value" },
        .{ .in, "in" },
        .{ .iden, "some_collection" },
        .{ .lbrace, "{" },
        .{ .rbrace, "}" },
        .{ .eof, "eof" },
    };

    var lexer = Lexer.init(input);

    for (tests) |expected_output| {
        const tkn = lexer.nextToken();
        try testing.expectEqual(expected_output[0], tkn.token_type);
        try testing.expectEqualStrings(expected_output[1], tkn.ch);
    }
}
