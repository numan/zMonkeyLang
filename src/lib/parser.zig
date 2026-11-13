const std = @import("std");
const testing = std.testing;

const ast = @import("./ast.zig");
const Lexer = @import("./lexer.zig").Lexer;
const Token = @import("./token.zig").Token;
const TokenType = @import("./token.zig").TokenType;
const Precedence = @import("./parsing_utils.zig").Precedence;

pub const ParseError = error{OutOfMemory};

const PrefixParseFn = *const fn (*Parser) ParseError!?ast.StatementType.ExpressionStatement;
const InfixParseFn = *const fn (*Parser, *ast.StatementType.ExpressionStatement) ParseError!?ast.StatementType.ExpressionStatement;
const IdentifierListType = std.ArrayList(ast.Identifier);

pub const Parser = struct {
    lexer: *Lexer,
    current_token: Token,
    peek_token: Token,
    program: ?*ast.Program = null,
    errors: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, lexer: *Lexer) Self {
        const token1 = lexer.nextToken();
        const token2 = lexer.nextToken();
        return .{
            .lexer = lexer,
            .current_token = token1,
            .peek_token = token2,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Self) ParseError!*const ast.Program {
        const program = try self.allocator.create(ast.Program);
        program.* = ast.Program.init(self.allocator);
        errdefer {
            program.deinit();
            self.allocator.destroy(program);
        }

        while (self.current_token.token_type != .eof) {
            if (try self.parseStatement()) |stmt| {
                var owned_stmt = stmt;
                errdefer owned_stmt.deinit(self.allocator);
                try program.addStatement(stmt);
            }
            self.nextToken();
        }

        self.program = program;
        return self.program.?;
    }

    fn nextToken(self: *Self) void {
        self.current_token = self.peek_token;
        self.peek_token = self.lexer.nextToken();
    }

    fn parseStatement(self: *Self) ParseError!?ast.StatementType {
        return switch (self.current_token.token_type) {
            TokenType.let => try self.parseLetStatement(),
            TokenType.@"for" => try self.parseForStatement(),
            TokenType.@"return" => try self.parseReturnStatement(),
            else => self.parseExpressionStatement(),
        };
    }

    fn parseForStatement(self: *Self) ParseError!?ast.StatementType {
        var loop = ast.StatementType.ForStatement{
            .token = self.current_token,
            .kind = .infinite,
            .body = ast.StatementType.BlockStatement.init(self.current_token, self.allocator),
        };
        var returned = false;
        defer if (!returned) loop.deinit(self.allocator);

        if (self.peekTokenIs(.let)) {
            self.nextToken();
            var initializer = try self.parseLetStatement() orelse return null;
            var transferred = false;
            defer if (!transferred) initializer.deinit(self.allocator);

            // parseLetStatement consumes the initializer's semicolon.
            if (!self.curTokenIs(.semicolon)) {
                if (!try self.expectPeek(.semicolon)) return null;
            }
            self.nextToken();
            var condition = try self.parseExpression(.lowest) orelse return null;
            defer if (!transferred) condition.deinit(self.allocator);
            if (!try self.expectPeek(.semicolon)) return null;

            self.nextToken();
            const update = try self.parseExpression(.lowest) orelse return null;
            loop.kind = .{ .c_style = .{
                .initializer = initializer.let,
                .condition = condition,
                .update = update,
            } };
            transferred = true;
        } else if (!self.peekTokenIs(.lbrace)) {
            if (!try self.expectPeek(.iden)) return null;
            const ident = ast.Identifier.init(self.current_token, self.current_token.ch);
            var second_ident: ?ast.Identifier = null;
            if (self.peekTokenIs(.comma)) {
                self.nextToken();
                if (!try self.expectPeek(.iden)) return null;
                second_ident = ast.Identifier.init(self.current_token, self.current_token.ch);
            }
            if (!try self.expectPeek(.in)) return null;
            self.nextToken();
            const iterable = try self.parseExpression(.lowest) orelse return null;
            loop.kind = .{ .iterator = .{
                .ident = ident,
                .second_ident = second_ident,
                .iterable = iterable,
            } };
        }

        if (!try self.expectPeek(.lbrace)) return null;
        loop.body = try self.parseBlockStatement() orelse return null;
        returned = true;
        return .{ .@"for" = loop };
    }

    fn parseExpressionStatement(self: *Self) ParseError!?ast.StatementType {
        const expression = try self.parseExpression(.lowest) orelse return null;
        if (self.peek_token.token_type == .semicolon) {
            self.nextToken();
        }

        return ast.StatementType{
            .expression = expression,
        };
    }

    fn parseExpression(self: *Self, precedence: Precedence) ParseError!?ast.StatementType.ExpressionStatement {
        if (self.getPrefixParseFn(self.current_token.token_type)) |prefix_fn| {
            var left = try prefix_fn(self) orelse return null;
            var returned = false;
            defer if (!returned) left.deinit(self.allocator);

            while (self.peek_token.token_type != .semicolon and @backingInt(precedence) < @backingInt(self.peekPrecedence())) {
                const infix_fn = self.getInixParseFn(self.peek_token.token_type) orelse break;

                self.nextToken();

                const left_ptr = try self.allocator.create(ast.StatementType.ExpressionStatement);
                var transferred = false;
                defer if (!transferred) self.allocator.destroy(left_ptr);
                left_ptr.* = left;
                left = try infix_fn(self, left_ptr) orelse return null;
                transferred = true;
            }
            returned = true;
            return left;
        } else {
            try self.noPrefixParseFnError(self.current_token.token_type);
            return null;
        }
    }

    fn parseSubExpression(self: *Self, precedence: Precedence) ParseError!?ast.StatementType.ExpressionStatement {
        return try self.parseExpression(precedence) orelse return null;
    }

    fn parseReturnStatement(self: *Self) ParseError!?ast.StatementType {
        const current_token = self.current_token;

        self.nextToken();

        var val: ?ast.StatementType.ExpressionStatement = null;
        if (self.current_token.token_type != .semicolon) {
            val = try self.parseExpression(.lowest) orelse return null;
        }

        if (self.peek_token.token_type == .semicolon) {
            self.nextToken();
        }

        return ast.StatementType{
            .@"return" = .{
                .token = current_token,
                .value = val,
            },
        };
    }

    fn parseLetStatement(self: *Self) ParseError!?ast.StatementType {
        const current_token = self.current_token;

        if (!try self.expectPeek(TokenType.iden)) {
            return null;
        }

        const iden_token = self.current_token;

        if (!try self.expectPeek(TokenType.assign)) {
            return null;
        }

        self.nextToken();

        var exp_value = try self.parseExpression(.lowest) orelse return null;

        if (exp_value.expression == .function_literal) {
            exp_value.expression.function_literal.name = iden_token.ch;
        }

        if (self.peek_token.token_type == .semicolon) {
            self.nextToken();
        }

        return ast.StatementType{ .let = .{
            .token = current_token,
            .name = ast.Identifier.init(iden_token, iden_token.ch),
            .value = exp_value,
        } };
    }

    fn curTokenIs(self: *Self, tokenType: TokenType) bool {
        return self.current_token.token_type == tokenType;
    }

    fn peekTokenIs(self: *Self, tokenType: TokenType) bool {
        return self.peek_token.token_type == tokenType;
    }

    fn expectPeek(self: *Self, token_type: TokenType) ParseError!bool {
        if (self.peek_token.token_type == token_type) {
            self.nextToken();
            return true;
        }

        try self.peekError(token_type);
        return false;
    }

    fn peekError(self: *Self, token_type: TokenType) ParseError!void {
        const msg = try std.fmt.allocPrint(self.allocator, "Expected next token to be {}, got {}", .{ token_type, self.peek_token.token_type });
        errdefer self.allocator.free(msg);
        try self.errors.append(self.allocator, msg);
    }

    fn noPrefixParseFnError(self: *Self, token_type: TokenType) ParseError!void {
        const msg = try std.fmt.allocPrint(self.allocator, "No prefix parse fn found for token type {}", .{
            token_type,
        });
        errdefer self.allocator.free(msg);
        try self.errors.append(self.allocator, msg);
    }

    fn literalError(self: *Self, kind: []const u8) ParseError!void {
        const msg = try std.fmt.allocPrint(self.allocator, "could not parse \"{s}\" as {s}", .{ self.current_token.ch, kind });
        errdefer self.allocator.free(msg);
        try self.errors.append(self.allocator, msg);
    }

    pub fn allErrors(self: *Self) [][]const u8 {
        return self.errors.items;
    }

    fn parseIdentifier(parser: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        return ast.StatementType.ExpressionStatement.initIdentifierExpression(parser.current_token, parser.current_token.ch);
    }

    fn parseIntegerLiteral(parser: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const val = std.fmt.parseInt(i64, parser.current_token.ch, 10) catch {
            try parser.literalError("integer");
            return null;
        };
        return ast.StatementType.ExpressionStatement.initIntegerLiteralExpression(parser.current_token, val);
    }

    fn parseFloatLiteral(parser: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const val = std.fmt.parseFloat(f64, parser.current_token.ch) catch {
            try parser.literalError("float");
            return null;
        };
        return ast.StatementType.ExpressionStatement.initFloatLiteralExpression(parser.current_token, val);
    }

    fn parseBooleanLiteral(parser: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const val = if (std.mem.eql(u8, parser.current_token.ch, "true")) true else false;
        return ast.StatementType.ExpressionStatement.initBooleanLiteralExpression(parser.current_token, val);
    }

    fn parseNullLiteral(parser: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        return .{ .expression = .{ .null_literal = .{ .token = parser.current_token } } };
    }

    fn parsePrefixOperator(parser: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const cur_token = parser.current_token;
        parser.nextToken();
        var right = try parser.parseSubExpression(.prefix) orelse return null;
        errdefer right.deinit(parser.allocator);
        const right_ptr = try parser.allocator.create(ast.StatementType.ExpressionStatement);
        right_ptr.* = right;
        return ast.StatementType.ExpressionStatement.initPrefixExpression(cur_token, right_ptr);
    }

    fn parseInfixExpression(self: *Self, left: *ast.StatementType.ExpressionStatement) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;
        const precedence = self.curPrecedence();
        self.nextToken();
        var right = try self.parseExpression(precedence) orelse return null;
        errdefer right.deinit(self.allocator);
        const right_ptr = try self.allocator.create(ast.StatementType.ExpressionStatement);
        right_ptr.* = right;

        return ast.StatementType.ExpressionStatement.initInfixExpression(current_token, left, right_ptr);
    }

    fn parseGroupedExpression(self: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        self.nextToken();

        var exp = try self.parseExpression(.lowest) orelse return null;
        var returned = false;
        defer if (!returned) exp.deinit(self.allocator);

        if (!try self.expectPeek(TokenType.rparen)) return null;
        returned = true;
        return exp;
    }

    fn parseIfExpression(self: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;
        if (!try self.expectPeek(.lparen)) return null;

        self.nextToken();

        var returned = false;
        const condition = try self.allocator.create(ast.StatementType.ExpressionStatement);
        defer if (!returned) self.allocator.destroy(condition);
        condition.* = try self.parseExpression(.lowest) orelse return null;
        defer if (!returned) condition.deinit(self.allocator);

        if (!try self.expectPeek(.rparen)) return null;
        if (!try self.expectPeek(.lbrace)) return null;

        var consequence = try self.parseBlockStatement() orelse return null;
        defer if (!returned) consequence.deinit(self.allocator);

        var alternative: ?ast.StatementType.BlockStatement = null;
        if (self.peek_token.token_type == .@"else") {
            self.nextToken();

            if (!try self.expectPeek(.lbrace)) return null;

            alternative = try self.parseBlockStatement() orelse return null;
        }

        returned = true;
        return ast.StatementType.ExpressionStatement.initIfExpression(current_token, condition, consequence, alternative);
    }

    fn parseBlockStatement(self: *Self) ParseError!?ast.StatementType.BlockStatement {
        var block_stmt = ast.StatementType.BlockStatement.init(self.current_token, self.allocator);
        var returned = false;
        defer if (!returned) block_stmt.deinit(self.allocator);
        self.nextToken();

        while (self.current_token.token_type != .rbrace and self.current_token.token_type != .eof) {
            const stmt = try self.parseStatement();
            if (stmt) |val| {
                var owned_stmt = val;
                errdefer owned_stmt.deinit(self.allocator);
                try block_stmt.addStatement(val);
            }
            self.nextToken();
        }
        if (!self.curTokenIs(.rbrace)) {
            try self.peekError(.rbrace);
            return null;
        }
        returned = true;
        return block_stmt;
    }

    fn parseFunctionLiteral(self: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;

        if (!try self.expectPeek(.lparen)) {
            return null;
        }

        const params = try self.parseFunctionParams() orelse return null;
        var returned = false;
        defer if (!returned) self.allocator.free(params);

        if (!try self.expectPeek(.lbrace)) {
            return null;
        }

        const body = try self.parseBlockStatement() orelse return null;

        returned = true;
        return ast.StatementType.ExpressionStatement.initFunctionLiteral(
            current_token,
            params,
            body,
        );
    }

    fn parseFunctionParams(self: *Self) ParseError!?[]ast.Identifier {
        var list: IdentifierListType = .empty;
        defer list.deinit(self.allocator);

        if (self.peek_token.token_type == .rparen) {
            self.nextToken();
            return list.items;
        }

        self.nextToken();

        try list.append(
            self.allocator,
            ast.Identifier.init(self.current_token, self.current_token.ch),
        );

        while (self.peek_token.token_type == .comma) {
            self.nextToken();
            self.nextToken();
            try list.append(
                self.allocator,
                ast.Identifier.init(self.current_token, self.current_token.ch),
            );
        }

        if (!try self.expectPeek(.rparen)) {
            return null;
        }

        return try list.toOwnedSlice(self.allocator);
    }

    fn parseCallExpression(self: *Self, function: *ast.StatementType.ExpressionStatement) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;
        const arguments = try self.parseCallArguments() orelse return null;
        return ast.StatementType.ExpressionStatement.initCallExpression(current_token, function, arguments);
    }

    fn parseCallArguments(self: *Self) ParseError!?[]ast.StatementType.ExpressionStatement {
        return self.parseExpressionList(.rparen);
    }

    fn parseExpressionList(self: *Self, end_token: TokenType) ParseError!?[]ast.StatementType.ExpressionStatement {
        var list = std.ArrayList(ast.StatementType.ExpressionStatement).empty;
        defer {
            for (list.items) |*item| item.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        if (self.peek_token.token_type == end_token) {
            self.nextToken();
            return list.items;
        }

        self.nextToken();

        {
            var first_arg = try self.parseExpression(.lowest) orelse return null;
            errdefer first_arg.deinit(self.allocator);
            try list.append(self.allocator, first_arg);
        }

        while (self.peek_token.token_type == .comma) {
            self.nextToken();
            self.nextToken();
            var arg = try self.parseExpression(.lowest) orelse return null;
            errdefer arg.deinit(self.allocator);
            try list.append(self.allocator, arg);
        }

        if (!try self.expectPeek(end_token)) {
            return null;
        }

        return try list.toOwnedSlice(self.allocator);
    }

    fn parseArrayLiteral(self: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;
        const elements = try self.parseExpressionList(.rbracket) orelse return null;
        return ast.StatementType.ExpressionStatement.initArrayLiteral(current_token, elements);
    }

    fn parseHashLiteral(self: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;
        var list = std.ArrayList(ast.ExpressionType.HashLiteral.HashPair).empty;
        defer {
            for (list.items) |*pair| {
                pair.key.deinit(self.allocator);
                pair.value.deinit(self.allocator);
            }
            list.deinit(self.allocator);
        }

        while (self.peek_token.token_type != .rbrace) {
            self.nextToken();
            var transferred = false;
            var key = try self.parseExpression(.lowest) orelse return null;
            defer if (!transferred) key.deinit(self.allocator);

            if (!try self.expectPeek(.colon)) {
                return null;
            }

            self.nextToken();
            var value = try self.parseExpression(.lowest) orelse return null;
            defer if (!transferred) value.deinit(self.allocator);

            try list.append(self.allocator, .{ .key = key, .value = value });
            transferred = true;

            if (self.peek_token.token_type != .rbrace) {
                if (!try self.expectPeek(.comma)) {
                    return null;
                }
            }
        }

        if (!try self.expectPeek(.rbrace)) {
            return null;
        }

        return ast.StatementType.ExpressionStatement.initHashLiteral(current_token, try list.toOwnedSlice(self.allocator));
    }

    fn parseIndexExpression(self: *Self, left: *ast.StatementType.ExpressionStatement) ParseError!?ast.StatementType.ExpressionStatement {
        const current_token = self.current_token;
        self.nextToken();
        var index = try self.parseExpression(.lowest) orelse return null;
        var returned = false;
        defer if (!returned) index.deinit(self.allocator);

        if (!try self.expectPeek(.rbracket)) return null;
        const index_ptr = try self.allocator.create(ast.StatementType.ExpressionStatement);
        index_ptr.* = index;

        returned = true;
        return ast.StatementType.ExpressionStatement.initIndexExpression(current_token, left, index_ptr);
    }

    fn parseAssignExpression(self: *Self, left: *ast.StatementType.ExpressionStatement) ParseError!?ast.StatementType.ExpressionStatement {
        const assign_token = self.current_token;

        const name = switch (left.expression) {
            .identifier => |ident| ident,
            else => {
                const msg = try std.fmt.allocPrint(self.allocator, "expected identifier on left side of assignment, got {}", .{std.meta.activeTag(left.expression)});
                errdefer self.allocator.free(msg);
                try self.errors.append(self.allocator, msg);
                return null;
            },
        };

        self.nextToken();

        var value = try self.parseExpression(.lowest) orelse return null;
        errdefer value.deinit(self.allocator);
        const value_ptr = try self.allocator.create(ast.StatementType.ExpressionStatement);
        value_ptr.* = value;

        // Free the left pointer since we extracted the identifier by value
        self.allocator.destroy(left);

        return ast.StatementType.ExpressionStatement.initAssignExpression(assign_token, name, value_ptr);
    }

    pub fn parseStringLiteral(self: *Self) ParseError!?ast.StatementType.ExpressionStatement {
        return ast.StatementType.ExpressionStatement.initStringLiteral(self.current_token, self.current_token.ch);
    }

    pub fn getPrecedence(self: *const Self, token_type: TokenType) Precedence {
        _ = self;
        return switch (token_type) {
            .assign => .assign,
            .range_exclusive => .range,
            .eq, .not_eq => .equals,
            .lt, .gt => .less_greater,
            .plus, .minus => .sum,
            .slash, .asterisk => .product,
            .lparen => .call,
            .lbracket => .index,
            else => .lowest,
        };
    }

    pub fn peekPrecedence(self: *const Self) Precedence {
        return self.getPrecedence(self.peek_token.token_type);
    }

    pub fn curPrecedence(self: *const Self) Precedence {
        return self.getPrecedence(self.current_token.token_type);
    }

    inline fn getPrefixParseFn(self: *const Self, token_type: TokenType) ?PrefixParseFn {
        _ = self;
        return switch (token_type) {
            .iden => Self.parseIdentifier,
            .int => Self.parseIntegerLiteral,
            .float => Self.parseFloatLiteral,
            .lparen => Self.parseGroupedExpression,
            .@"if" => Self.parseIfExpression,
            .function => Self.parseFunctionLiteral,
            inline .true, .false => Self.parseBooleanLiteral,
            .null => Self.parseNullLiteral,
            inline .bang, .minus => Self.parsePrefixOperator,
            .string => Self.parseStringLiteral,
            .lbracket => Self.parseArrayLiteral,
            .lbrace => Self.parseHashLiteral,
            else => null,
        };
    }

    inline fn getInixParseFn(self: *const Self, token_type: TokenType) ?InfixParseFn {
        _ = self;
        return switch (token_type) {
            inline .plus, .minus, .slash, .asterisk, .eq, .not_eq, .lt, .gt, .range_exclusive => Self.parseInfixExpression,
            .lparen => Self.parseCallExpression,
            .lbracket => Self.parseIndexExpression,
            .assign => Self.parseAssignExpression,
            else => null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.program) |program| {
            program.*.deinit();
            self.allocator.destroy(program);
        }

        for (self.errors.items) |err_msg| {
            self.allocator.free(err_msg);
        }
        self.errors.deinit(self.allocator);
    }
};
