const std = @import("std");
const compiler_mod = @import("compiler.zig");
const Compiler = compiler_mod.Compiler;
const Bytecode = compiler_mod.Bytecode;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Object = @import("object.zig").Object;
const SymbolTable = @import("symbol_table.zig").SymbolTable;
const Program = @import("ast.zig").Program;

pub const VmState = struct {
    allocator: std.mem.Allocator,
    vm_arena: std.heap.ArenaAllocator,
    constants_arena: std.heap.ArenaAllocator,
    symbol_table: SymbolTable,
    constants: std.ArrayList(Object),
    /// Starts as null, so a name whose `let` failed at run time reads as null.
    globals: [vm_mod.globals_size]Object,

    pub fn init(allocator: std.mem.Allocator) VmState {
        return .{
            .allocator = allocator,
            .vm_arena = std.heap.ArenaAllocator.init(allocator),
            .constants_arena = std.heap.ArenaAllocator.init(allocator),
            .symbol_table = SymbolTable.init(allocator, null),
            .constants = .empty,
            .globals = @splat(.{ .null = Object.Null.init() }),
        };
    }

    pub fn deinit(self: *VmState) void {
        self.constants.deinit(self.allocator);
        self.symbol_table.deinit();
        self.vm_arena.deinit();
        self.constants_arena.deinit();
    }

    pub fn newCompiler(self: *VmState) !Compiler {
        var comp = Compiler.init(self.allocator, self.constants_arena.allocator(), &self.symbol_table, &self.constants);
        try comp.enterScope();
        return comp;
    }

    /// Compiles one line with `comp`. If compilation fails, the names the line
    /// defined are forgotten, because the line never stores their values.
    pub fn compile(self: *VmState, comp: *Compiler, program: *const Program) !void {
        var saved = try self.symbol_table.snapshot();
        comp.compile(program) catch |err| {
            self.symbol_table.restore(saved);
            return err;
        };
        saved.deinit();
    }

    pub fn newVm(self: *VmState, bytecode: Bytecode, writer: *std.Io.Writer) !Vm {
        return Vm.init(bytecode, &self.globals, self.vm_arena.allocator(), writer);
    }
};
