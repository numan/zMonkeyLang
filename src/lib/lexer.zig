const std = @import("std");

const token = @import("token.zig");
const Token = token.Token;

pub const Lexer = struct {
    input: []const u8,
    position: usize = 0,
    read_position: usize = 0,
    ch: ?u8 = null,

    pub fn init(input: []const u8) Lexer {
        var lexer = Lexer{ .input = input };
        if (input.len > 0) {
            lexer.ch = input[0];
            lexer.read_position = 1;
        }
        return lexer;
    }

    fn readCharacter(self: *Lexer) void {
        if (self.read_position >= self.input.len) {
            self.ch = null;
        } else {
            self.ch = self.input[self.read_position];
        }

        self.position = self.read_position;
        self.read_position += 1;
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.position;

        while (self.ch) |ch| {
            if (!isLetter(ch) and !std.ascii.isDigit(ch)) break;
            self.readCharacter();
        }

        const slice = self.input[start..self.position];
        return Token.fromString(slice) orelse Token.init(.iden, slice);
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.position;

        while (self.ch) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.readCharacter();
        }

        // Read a float
        if (self.ch) |next_character| {
            if (next_character == '.' and self.peek() != '.') {
                self.readCharacter();
                while (self.ch) |c| {
                    if (!std.ascii.isDigit(c)) break;
                    self.readCharacter();
                }
                return .init(.float, self.input[start..self.position]);
            }
        }
        return .init(.int, self.input[start..self.position]);
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.ch) |ch| {
            if (!std.ascii.isWhitespace(ch)) break;
            self.readCharacter();
        }
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.read_position >= self.input.len) return null;
        return self.input[self.read_position];
    }

    fn isLetter(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn readString(self: *Lexer) Token {
        self.readCharacter(); // Skip the opening quote
        const start = self.position;
        var escaped = false;

        while (self.ch) |ch| {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                const value = self.input[start..self.position];
                self.readCharacter(); // Skip the closing quote
                return Token.init(.string, value);
            }

            self.readCharacter();
        }

        return Token.init(.illegal, "Unterminated string literal");
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();

        const ch = self.ch orelse return Token.init(.eof, "eof");

        if (ch == '"') {
            return self.readString();
        } else if (isLetter(ch)) {
            return self.readIdentifier();
        } else if (std.ascii.isDigit(ch)) {
            return self.readNumber();
        } else {
            // Handle two-character operators
            if (ch == '=' or ch == '!' or ch == '.') {
                if (self.peek() == '=') {
                    const operator_slice = self.input[self.position .. self.position + 2];
                    self.readCharacter();
                    self.readCharacter();
                    return Token.fromString(operator_slice) orelse Token.init(.illegal, operator_slice);
                }

                if (self.peek() == '.') {
                    const operator_slice = self.input[self.position .. self.position + 2];
                    self.readCharacter();
                    self.readCharacter();
                    return Token.fromString(operator_slice) orelse Token.init(.illegal, operator_slice);
                }
            }

            // Handle single-character tokens
            const ch_slice = self.input[self.position .. self.position + 1];
            if (Token.fromString(ch_slice)) |match| {
                self.readCharacter();
                return match;
            }

            // Illegal character
            self.readCharacter();
            return Token.init(.illegal, ch_slice);
        }
    }
};
