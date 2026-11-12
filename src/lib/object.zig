const std = @import("std");
const ast = @import("ast.zig");
const environment = @import("environment.zig");

pub const BuiltinFnType = *const fn (std.mem.Allocator, []const Object) std.mem.Allocator.Error!Object;
pub const BuiltinWriterFnType = *const fn (std.mem.Allocator, []const Object, *std.Io.Writer) BuiltinError!Object;
pub const BuiltinError = std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Object = union(enum) {
    int: Integer,
    range: Range,
    float: Float,
    bool: Boolean,
    null: Null,
    err: Error,
    closure: *const Closure,
    compiled_function: *CompiledFunction,
    function: *Function,
    string: *String,
    array: *Array,
    hash: *Hash,
    builtin: Builtin,
    iterator: *Iterator,

    const Self = @This();

    pub const HashKey = struct {
        obj_type: enum { int, bool, string },
        value: u64,
    };

    pub const Builtin = union(enum) {
        function: BuiltinFnType,
        writer_function: BuiltinWriterFnType,

        pub fn inspect(self: *const Builtin, writer: *std.Io.Writer) !void {
            _ = self;
            try writer.writeAll("builtin function");
            try writer.flush();
        }
    };

    pub const Error = struct {
        msg: []const u8,

        pub fn init(m: []const u8) Error {
            return .{ .msg = m };
        }

        pub fn inspect(self: *const Object.Error, writer: *std.Io.Writer) !void {
            try writer.writeAll("ERROR: ");
            try writer.writeAll(self.msg);
            try writer.flush();
        }
    };

    pub const String = struct {
        value: []const u8,

        pub fn init(value: []const u8) String {
            return .{ .value = value };
        }

        pub fn hashKey(self: *const String) HashKey {
            return .{ .obj_type = .string, .value = std.hash.Fnv1a_64.hash(self.value) };
        }

        pub fn inspect(self: *const Object.String, writer: *std.Io.Writer) !void {
            try writer.writeAll(self.value);
            try writer.flush();
        }
    };

    pub const Integer = struct {
        value: i64,

        pub fn init(value: i64) Integer {
            return Integer{
                .value = value,
            };
        }

        pub fn hashKey(self: *const Integer) HashKey {
            return .{ .obj_type = .int, .value = @bitCast(self.value) };
        }

        pub fn inspect(self: *const Object.Integer, writer: *std.Io.Writer) !void {
            try writer.print("{d}", .{self.value});
            try writer.flush();
        }
    };

    /// Ascending integer range with an exclusive end; no heap ownership.
    pub const Range = struct {
        start: i64,
        end: i64,

        pub fn inspect(self: *const Range, writer: *std.Io.Writer) !void {
            try writer.print("{d}..{d}", .{ self.start, self.end });
            try writer.flush();
        }
    };

    pub const Float = struct {
        value: f64,

        pub fn init(value: f64) Float {
            return Float{ .value = value };
        }

        pub fn inspect(self: *const Object.Float, writer: *std.Io.Writer) !void {
            try writer.print("{d}", .{self.value});
            try writer.flush();
        }
    };

    pub const Boolean = struct {
        value: bool,

        pub fn init(value: bool) Boolean {
            return Boolean{
                .value = value,
            };
        }

        pub fn hashKey(self: *const Boolean) HashKey {
            return .{ .obj_type = .bool, .value = if (self.value) 1 else 0 };
        }

        pub fn inspect(self: *const Object.Boolean, writer: *std.Io.Writer) !void {
            try writer.print("{}", .{self.value});
            try writer.flush();
        }
    };

    pub const Null = struct {
        const empty = .{};

        pub fn init() Null {
            return Null{};
        }
        pub fn inspect(self: *const Object.Null, writer: *std.Io.Writer) !void {
            _ = self;
            try writer.writeAll("null");
            try writer.flush();
        }
    };

    /// A variable captured by a closure. While the declaring function runs,
    /// `location` points at its stack slot; when that function returns, the
    /// value moves into `closed` so the closure can keep using it.
    pub const Upvalue = struct {
        /// The stack slot while open, or `&state.closed` once closed.
        location: *Object,
        state: union(enum) {
            open: struct {
                /// The stack slot `location` points at.
                slot: usize,
                /// Next open upvalue in the VM's list, ordered by descending stack slot.
                next: ?*Upvalue,
            },
            closed: Object,
        },
    };

    pub const Closure = struct {
        function: *CompiledFunction,
        upvalues: []const *Upvalue,

        pub fn init(function: *CompiledFunction, upvalues: []const *Upvalue) Closure {
            return Closure{
                .function = function,
                .upvalues = upvalues,
            };
        }

        pub fn inspect(self: *const Object.Closure, writer: *std.Io.Writer) !void {
            try writer.writeAll("Closure[");
            try writer.print("0x{x}]", .{@intFromPtr(self)});
            try writer.flush();
        }
    };

    pub const CompiledFunction = struct {
        instructions: []const u8,
        num_locals: usize,
        num_parameters: usize,
        /// Where each of the closure's upvalues comes from, in upvalue order.
        captures: []const Capture = &.{},

        pub const Capture = struct {
            source: enum {
                /// A local of the enclosing function, at `index`.
                local,
                /// The enclosing closure's upvalue at `index`.
                upvalue,
            },
            index: u8 = 0,
        };

        pub fn init(instructions: []const u8, num_locals: usize, num_parameters: usize, captures: []const Capture) CompiledFunction {
            return .{ .instructions = instructions, .num_locals = num_locals, .num_parameters = num_parameters, .captures = captures };
        }

        pub fn inspect(self: *const Object.CompiledFunction, writer: *std.Io.Writer) !void {
            _ = self;
            try writer.writeAll("CompiledFunction");
            try writer.flush();
        }
    };

    pub const Function = struct {
        parameters: []const ast.Identifier,
        body: *const ast.StatementType.BlockStatement,
        environment: *environment.Environment,
        arena: std.heap.ArenaAllocator,

        pub fn init(
            parameters: []const ast.Identifier,
            body: *const ast.StatementType.BlockStatement,
            env: *environment.Environment,
            arena: std.heap.ArenaAllocator,
        ) Function {
            return .{
                .parameters = parameters,
                .body = body,
                .environment = env,
                .arena = arena,
            };
        }

        pub fn deinit(self: *Function) void {
            self.arena.deinit();
        }

        pub fn inspect(self: *const Object.Function, writer: *std.Io.Writer) !void {
            try writer.writeAll("fn(");
            for (self.parameters, 0..) |parameter, i| {
                try parameter.toString(writer);
                if (i < self.parameters.len - 1) {
                    try writer.writeAll(", ");
                }
            }

            try writer.writeAll(") {");
            try self.body.toString(writer);
            try writer.writeAll("}");
            try writer.flush();
        }
    };

    pub const Array = struct {
        elements: []Object,

        pub fn init(elements: []Object) Array {
            return .{ .elements = elements };
        }

        pub fn inspect(self: *const Object.Array, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("[");
            for (self.elements, 0..) |*elem, i| {
                try elem.inspect(writer);
                if (i < self.elements.len - 1) try writer.writeAll(", ");
            }
            try writer.writeAll("]");
            try writer.flush();
        }
    };

    pub const HashPair = struct {
        key: Object,
        value: Object,
    };

    pub const Hash = struct {
        pairs: std.AutoHashMap(HashKey, HashPair),

        pub fn inspect(self: *const Object.Hash, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("{");
            var iterator = self.pairs.iterator();
            var i: usize = 0;
            while (iterator.next()) |entry| {
                try entry.value_ptr.key.inspect(writer);
                try writer.writeAll(": ");
                try entry.value_ptr.value.inspect(writer);
                if (i < self.pairs.count() - 1) try writer.writeAll(", ");
                i += 1;
            }
            try writer.writeAll("}");
            try writer.flush();
        }
    };

    /// Loop cursor over a range, array, string, or hash, used by the VM's iterator opcodes.
    pub const Iterator = struct {
        source: Source,
        index: usize = 0,
        /// Whether the loop binds two names, as in `for k, v in ...`.
        binds_pair: bool,

        const Source = union(enum) {
            range: Range,
            array: *Array,
            string: *String,
            hash: std.AutoHashMap(HashKey, HashPair).Iterator,
        };

        /// One name binds the item, or the key for hashes. Two names bind the
        /// index (or key) and then the item (or value).
        pub const Bindings = struct {
            first: Object,
            second: ?Object,
        };

        /// Returns null when `iterable` can't be iterated.
        pub fn init(iterable: Object, binds_pair: bool) ?Iterator {
            const source: Source = switch (iterable) {
                .range => |range| .{ .range = range },
                .array => |array| .{ .array = array },
                .string => |string| .{ .string = string },
                .hash => |hash| .{ .hash = hash.pairs.iterator() },
                else => return null,
            };
            return .{ .source = source, .binds_pair = binds_pair };
        }

        pub fn next(self: *Iterator) ?Bindings {
            const key: Object, const item: Object = switch (self.source) {
                .range => |range| blk: {
                    const value = @as(i128, range.start) + self.index;
                    if (value >= range.end) return null;
                    break :blk .{ intObject(self.index), .{ .int = Integer.init(@intCast(value)) } };
                },
                .array => |array| blk: {
                    if (self.index >= array.elements.len) return null;
                    break :blk .{ intObject(self.index), array.elements[self.index] };
                },
                .string => |string| blk: {
                    if (self.index >= string.value.len) return null;
                    break :blk .{ intObject(self.index), .{ .int = Integer.init(string.value[self.index]) } };
                },
                .hash => |*entries| blk: {
                    const entry = entries.next() orelse return null;
                    break :blk .{ entry.value_ptr.key, entry.value_ptr.value };
                },
            };
            self.index += 1;
            if (self.binds_pair) return .{ .first = key, .second = item };
            return .{ .first = if (self.source == .hash) key else item, .second = null };
        }

        fn intObject(value: usize) Object {
            return .{ .int = Integer.init(@intCast(value)) };
        }

        pub fn inspect(self: *const Iterator, writer: *std.Io.Writer) !void {
            _ = self;
            try writer.writeAll("iterator");
            try writer.flush();
        }
    };

    pub fn hashKey(self: *const Self) ?HashKey {
        return switch (self.*) {
            .int => |obj| obj.hashKey(),
            .bool => |obj| obj.hashKey(),
            .string => |obj| obj.hashKey(),
            else => null,
        };
    }

    pub fn typeName(self: *const Self) []const u8 {
        return @tagName(self.*);
    }

    pub fn inspect(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.*) {
            inline else => |obj| {
                try obj.inspect(writer);
            },
        }
    }
};
