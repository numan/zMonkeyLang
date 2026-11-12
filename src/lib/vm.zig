const std = @import("std");
const code = @import("code.zig");
const compiler = @import("compiler.zig");
const object = @import("object.zig");
const frame = @import("frame.zig");
const builtins_mod = @import("builtins.zig");

const Object = object.Object;
const Bytecode = compiler.Bytecode;
const Frame = frame.Frame;

const True = Object{ .bool = Object.Boolean.init(true) };
const False = Object{ .bool = Object.Boolean.init(false) };
const Null = Object{ .null = Object.Null.init() };

const stack_size = 2048;
pub const globals_size = 65536;
const max_frames = 1024;

const Errors = error{
    TypeMismatch,
    HashNotHashable,
    UncallableObject,
    WrongArgumentCount,
    NotIterable,
} || std.Io.Writer.Error;

pub const Vm = struct {
    constants: []Object,
    stack: [stack_size]Object,
    sp: usize, // stack pointer — always points to next free slot
    globals: *[globals_size]Object,
    allocator: std.mem.Allocator,
    frames: [max_frames]Frame = undefined,
    frame_index: usize,
    writer: *std.Io.Writer,
    /// Upvalues that still point at stack slots, ordered by descending slot.
    open_upvalues: ?*Object.Upvalue = null,

    pub fn init(bytecode: Bytecode, globals: *[globals_size]Object, allocator: std.mem.Allocator, writer: *std.Io.Writer) !Vm {
        const main_fn = try allocator.create(Object.CompiledFunction);
        main_fn.* = .{ .instructions = bytecode.instructions, .num_locals = 0, .num_parameters = 0 };
        const main_closure = try allocator.create(Object.Closure);
        main_closure.* = Object.Closure.init(main_fn, &.{});

        var vm = Vm{
            .constants = bytecode.constants,
            .stack = undefined,
            .sp = 0,
            .globals = globals,
            .allocator = allocator,
            .frames = undefined,
            .frame_index = 1,
            .writer = writer,
        };

        vm.frames[0] = Frame.init(main_closure, 0);
        return vm;
    }

    pub fn currentFrame(self: *Vm) *Frame {
        return &self.frames[self.frame_index - 1];
    }

    pub fn pushFrame(self: *Vm, f: Frame) void {
        self.frames[self.frame_index] = f;
        self.frame_index += 1;
    }

    pub fn popFrame(self: *Vm) *Frame {
        self.frame_index -= 1;
        return &self.frames[self.frame_index];
    }

    pub fn stackTop(self: *const Vm) ?Object {
        if (self.sp == 0) return null;
        return self.stack[self.sp - 1];
    }

    pub fn lastPoppedStackElem(self: *const Vm) ?Object {
        if (self.sp == stack_size) return null;
        return self.stack[self.sp];
    }

    pub fn run(self: *Vm) !void {
        // Closures created before an error may outlive this VM's stack.
        errdefer self.closeUpvalues(0);

        var ip = self.currentFrame().ip;
        var ins = self.currentFrame().ins;
        var base_pointer = self.currentFrame().base_pointer;

        while (ip < ins.len) {
            const op: code.Opcode = @fromBackingInt(@intCast(ins[ip]));
            ip += 1;
            switch (op) {
                .constant => {
                    const const_index = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    self.push(self.constants[const_index]);
                },
                .add, .sub, .mul, .div => {
                    const right = self.pop();
                    const left = self.pop();
                    try self.executeBinaryOp(op, left, right);
                },
                .op_true => {
                    self.push(True);
                },
                .op_false => {
                    self.push(False);
                },
                .equal, .not_equal, .greater_than => {
                    const right = self.pop();
                    const left = self.pop();
                    try self.executeComparison(op, left, right);
                },
                .jump => {
                    ip = std.mem.readInt(u16, ins[ip..][0..2], .big);
                },
                .jump_not_truthy => {
                    const pos = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    const condition = self.pop();
                    if (!isTruthy(condition)) {
                        ip = pos;
                    }
                },
                .array => {
                    const len = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    const array = try self.buildArray(self.sp - len, self.sp);
                    self.sp -= len;
                    self.push(.{ .array = array });
                },
                .hash => {
                    const num_elements = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    const hash = try self.buildHash(self.sp - num_elements, self.sp);
                    self.sp -= num_elements;
                    self.push(.{ .hash = hash });
                },
                .index => {
                    const index_val = self.pop();
                    const left = self.pop();
                    try self.executeIndexExpression(left, index_val);
                },
                .op_null => {
                    self.push(Null);
                },
                .minus => {
                    const operand = self.pop();
                    switch (operand) {
                        .int => |v| self.push(.{ .int = Object.Integer.init(-v.value) }),
                        .float => |v| self.push(.{ .float = Object.Float.init(-v.value) }),
                        else => return Errors.TypeMismatch,
                    }
                },
                .bang => {
                    const operand = self.pop();
                    const result = switch (operand) {
                        .bool => |b| if (b.value) False else True,
                        .null => True,
                        else => False,
                    };
                    self.push(result);
                },
                .set_global => {
                    const global_index = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    self.globals[global_index] = self.pop();
                },
                .get_global => {
                    const global_index = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    self.push(self.globals[global_index]);
                },
                .set_local => {
                    const local_index = ins[ip];
                    ip += 1;
                    self.stack[base_pointer + local_index] = self.pop();
                },
                .get_local => {
                    const local_index = ins[ip];
                    ip += 1;
                    self.push(self.stack[base_pointer + local_index]);
                },
                .get_free => {
                    const free_index = ins[ip];
                    ip += 1;
                    const closure = self.currentFrame().closure;
                    self.push(closure.upvalues[free_index].location.*);
                },
                .set_free => {
                    const free_index = ins[ip];
                    ip += 1;
                    const closure = self.currentFrame().closure;
                    closure.upvalues[free_index].location.* = self.pop();
                },
                .pop => {
                    _ = self.pop();
                },
                .get_builtin => {
                    const builtin_index = ins[ip];
                    ip += 1;
                    const b: builtins_mod.Builtin = @fromBackingInt(@intCast(builtin_index));
                    self.push(builtins_mod.getObject(b));
                },
                .closure => {
                    const const_index = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;

                    const compiled_fn = self.constants[const_index].compiled_function;
                    const upvalues = try self.allocator.alloc(*Object.Upvalue, compiled_fn.captures.len);
                    const enclosing = self.currentFrame().closure;
                    for (compiled_fn.captures, upvalues) |capture, *upvalue| {
                        upvalue.* = switch (capture.source) {
                            .local => try self.captureUpvalue(base_pointer + capture.index),
                            .upvalue => enclosing.upvalues[capture.index],
                        };
                    }

                    const closure = try self.allocator.create(Object.Closure);
                    closure.* = Object.Closure.init(compiled_fn, upvalues);
                    self.push(.{ .closure = closure });
                },
                .call => {
                    const num_args = ins[ip];
                    ip += 1;

                    const top_obj = self.stack[self.sp - 1 - num_args];
                    switch (top_obj) {
                        .closure => |closure| {
                            if (num_args != closure.function.*.num_parameters) {
                                return error.WrongArgumentCount;
                            }
                            // Save ip back to current frame before switching
                            self.currentFrame().ip = ip;
                            const fn_frame = Frame.init(closure, self.sp - num_args);
                            self.sp = fn_frame.base_pointer + closure.function.*.num_locals;
                            self.pushFrame(fn_frame);
                            // Reload locals from new frame
                            ip = fn_frame.ip;
                            ins = fn_frame.ins;
                            base_pointer = fn_frame.base_pointer;
                        },
                        .builtin => |builtin| {
                            const args = self.stack[self.sp - num_args .. self.sp];
                            const result = switch (builtin) {
                                .function => |func| try func(self.allocator, args),
                                .writer_function => |func| try func(self.allocator, args, self.writer),
                            };
                            self.sp = self.sp - num_args - 1;
                            self.push(result);
                        },
                        else => return error.UncallableObject,
                    }
                },
                .return_value => {
                    const return_val = self.pop();
                    // A top-level return halts the program, leaving its value as
                    // the last popped element.
                    if (self.frame_index == 1) return;
                    const f = self.popFrame();
                    self.closeUpvalues(f.base_pointer);
                    self.sp = f.base_pointer - 1;
                    self.push(return_val);
                    // Reload locals from the restored frame
                    const current = self.currentFrame();
                    ip = current.ip;
                    ins = current.ins;
                    base_pointer = current.base_pointer;
                },
                .op_return => {
                    const f = self.popFrame();
                    self.closeUpvalues(f.base_pointer);
                    self.sp = f.base_pointer - 1;
                    self.push(Null);
                    // Reload locals from the restored frame
                    const current = self.currentFrame();
                    ip = current.ip;
                    ins = current.ins;
                    base_pointer = current.base_pointer;
                },
                .range => {
                    const end = self.pop();
                    const start = self.pop();
                    if (start != .int or end != .int) return Errors.TypeMismatch;
                    self.push(.{ .range = .{ .start = start.int.value, .end = end.int.value } });
                },
                .iter_init => {
                    const name_count = ins[ip];
                    ip += 1;
                    const iterator = try self.allocator.create(Object.Iterator);
                    iterator.* = Object.Iterator.init(self.pop(), name_count == 2) orelse return Errors.NotIterable;
                    self.push(.{ .iterator = iterator });
                },
                .iter_next => {
                    const exit_pos = std.mem.readInt(u16, ins[ip..][0..2], .big);
                    ip += 2;
                    // The iterator stays on the stack until the loop exits.
                    if (self.stack[self.sp - 1].iterator.next()) |bindings| {
                        self.push(bindings.first);
                        if (bindings.second) |second| self.push(second);
                    } else {
                        ip = exit_pos;
                    }
                },
            }
        }
    }

    /// Returns the open upvalue for `slot`, creating it if needed, so every
    /// closure that captures the same variable shares one upvalue.
    fn captureUpvalue(self: *Vm, slot: usize) !*Object.Upvalue {
        var previous: ?*Object.Upvalue = null;
        var current = self.open_upvalues;
        while (current) |upvalue| {
            if (upvalue.state.open.slot <= slot) break;
            previous = upvalue;
            current = upvalue.state.open.next;
        }
        if (current) |upvalue| {
            if (upvalue.state.open.slot == slot) return upvalue;
        }

        const created = try self.allocator.create(Object.Upvalue);
        created.* = .{
            .location = &self.stack[slot],
            .state = .{ .open = .{ .slot = slot, .next = current } },
        };
        if (previous) |p| {
            p.state.open.next = created;
        } else {
            self.open_upvalues = created;
        }
        return created;
    }

    /// Moves the values of open upvalues at or above stack index `first_slot`
    /// off the stack.
    fn closeUpvalues(self: *Vm, first_slot: usize) void {
        while (self.open_upvalues) |upvalue| {
            const open = upvalue.state.open;
            if (open.slot < first_slot) break;
            self.open_upvalues = open.next;
            upvalue.state = .{ .closed = upvalue.location.* };
            upvalue.location = &upvalue.state.closed;
        }
    }

    fn executeComparison(self: *Vm, op: code.Opcode, left: Object, right: Object) !void {
        if (left == .int and right == .int) {
            return self.executeIntegerComparison(op, left.int.value, right.int.value);
        }
        if (left == .float and right == .float) {
            return self.executeFloatComparison(op, left.float.value, right.float.value);
        }
        if (left == .int and right == .float) {
            return self.executeFloatComparison(op, @floatFromInt(left.int.value), right.float.value);
        }
        if (left == .float and right == .int) {
            return self.executeFloatComparison(op, left.float.value, @floatFromInt(right.int.value));
        }
        if (left == .string and right == .string) {
            return self.executeStringComparison(op, left.string.value, right.string.value);
        }

        const result = switch (op) {
            .equal => std.meta.eql(left, right),
            .not_equal => !std.meta.eql(left, right),
            else => return Errors.TypeMismatch,
        };

        self.push(nativeBoolToBooleanObject(result));
    }

    fn executeStringComparison(self: *Vm, op: code.Opcode, left: []const u8, right: []const u8) !void {
        const result = switch (op) {
            .equal => std.mem.eql(u8, left, right),
            .not_equal => !std.mem.eql(u8, left, right),
            else => return Errors.TypeMismatch,
        };
        self.push(nativeBoolToBooleanObject(result));
    }

    fn executeFloatComparison(self: *Vm, op: code.Opcode, left: f64, right: f64) !void {
        const result = switch (op) {
            .equal => left == right,
            .not_equal => left != right,
            .greater_than => left > right,
            else => return Errors.TypeMismatch,
        };
        self.push(nativeBoolToBooleanObject(result));
    }

    fn executeIntegerComparison(self: *Vm, op: code.Opcode, left: i64, right: i64) !void {
        const result = switch (op) {
            .equal => left == right,
            .not_equal => left != right,
            .greater_than => left > right,
            else => return Errors.TypeMismatch,
        };

        self.push(nativeBoolToBooleanObject(result));
    }

    fn executeBinaryOp(self: *Vm, op: code.Opcode, left: Object, right: Object) !void {
        if (left == .int and right == .int) {
            return self.executeBinaryIntegerOp(op, left.int.value, right.int.value);
        }
        if (left == .float and right == .float) {
            return self.executeBinaryFloatOp(op, left.float.value, right.float.value);
        }
        if (left == .int and right == .float) {
            return self.executeBinaryFloatOp(op, @floatFromInt(left.int.value), right.float.value);
        }
        if (left == .float and right == .int) {
            return self.executeBinaryFloatOp(op, left.float.value, @floatFromInt(right.int.value));
        }
        if (op == .add and left == .string and right == .string) {
            return self.executeStringConcatenation(left.string.value, right.string.value);
        }
        return Errors.TypeMismatch;
    }

    fn executeBinaryIntegerOp(self: *Vm, op: code.Opcode, left: i64, right: i64) !void {
        const result = switch (op) {
            .add => left + right,
            .sub => left - right,
            .mul => left * right,
            .div => @divTrunc(left, right),
            else => unreachable,
        };
        self.push(.{ .int = Object.Integer.init(result) });
    }

    fn executeBinaryFloatOp(self: *Vm, op: code.Opcode, left: f64, right: f64) !void {
        const result = switch (op) {
            .add => left + right,
            .sub => left - right,
            .mul => left * right,
            .div => left / right,
            else => unreachable,
        };
        self.push(.{ .float = Object.Float.init(result) });
    }

    fn executeStringConcatenation(self: *Vm, left: []const u8, right: []const u8) !void {
        const concat = try std.mem.concat(self.allocator, u8, &.{ left, right });
        const str = try self.allocator.create(Object.String);
        str.* = Object.String.init(concat);
        self.push(.{ .string = str });
    }

    fn buildArray(self: *Vm, start_index: usize, end_index: usize) !*Object.Array {
        const elements = try self.allocator.dupe(Object, self.stack[start_index..end_index]);
        const array = try self.allocator.create(Object.Array);
        array.* = Object.Array.init(elements);
        return array;
    }

    fn buildHash(self: *Vm, start_index: usize, end_index: usize) !*Object.Hash {
        var pairs = std.AutoHashMap(Object.HashKey, Object.HashPair).init(self.allocator);
        var i = start_index;
        while (i < end_index) : (i += 2) {
            const key = self.stack[i];
            const value = self.stack[i + 1];
            const hash_key = key.hashKey() orelse return Errors.HashNotHashable;
            try pairs.put(hash_key, .{ .key = key, .value = value });
        }
        const hash = try self.allocator.create(Object.Hash);
        hash.* = .{ .pairs = pairs };
        return hash;
    }

    fn nativeBoolToBooleanObject(value: bool) Object {
        return if (value) True else False;
    }

    fn isTruthy(obj: Object) bool {
        return switch (obj) {
            .bool => |b| b.value,
            .null => false,
            else => true,
        };
    }

    fn executeIndexExpression(self: *Vm, left: Object, index_val: Object) !void {
        if (left == .array and index_val == .int) {
            self.executeArrayIndex(left.array, index_val.int.value);
            return;
        }
        if (left == .hash) {
            return self.executeHashIndex(left.hash, index_val);
        }
        return Errors.TypeMismatch;
    }

    fn executeArrayIndex(self: *Vm, array: *Object.Array, index: i64) void {
        if (index < 0 or index >= @as(i64, @intCast(array.elements.len))) {
            return self.push(Null);
        }
        return self.push(array.elements[@intCast(index)]);
    }

    fn executeHashIndex(self: *Vm, hash: *Object.Hash, index_val: Object) !void {
        const hash_key = index_val.hashKey() orelse return Errors.HashNotHashable;
        const pair = hash.pairs.get(hash_key);
        if (pair) |p| {
            self.push(p.value);
        } else {
            self.push(Null);
        }
    }

    inline fn pop(self: *Vm) Object {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    inline fn push(self: *Vm, obj: Object) void {
        self.stack[self.sp] = obj;
        self.sp += 1;
    }
};
