const std = @import("std");
const builtins = @import("builtins.zig");

pub const SymbolScope = enum {
    global,
    local,
    builtin,
    free,
};

pub const Symbol = struct {
    name: []const u8,
    scope: SymbolScope,
    index: usize,
};

pub const SymbolTable = struct {
    outer: ?*SymbolTable,
    allocator: std.mem.Allocator,
    store: std.StringHashMap(Symbol),
    num_definitions: usize,
    free_symbols: std.ArrayList(Symbol),
    /// Block scopes (loops) hide their names from enclosing scopes but store
    /// them in the enclosing function's frame, or as globals at the top level.
    is_block: bool = false,

    pub fn initBlock(allocator: std.mem.Allocator, outer: *SymbolTable) SymbolTable {
        var table = init(allocator, outer);
        table.is_block = true;
        return table;
    }

    pub fn init(allocator: std.mem.Allocator, outer: ?*SymbolTable) SymbolTable {
        return .{
            .outer = outer,
            .allocator = allocator,
            .store = std.StringHashMap(Symbol).init(allocator),
            .num_definitions = 0,
            .free_symbols = .empty,
        };
    }

    pub fn define(self: *SymbolTable, name: []const u8) !Symbol {
        const frame = self.frameTable();
        const scope: SymbolScope = if (frame.outer == null) .global else .local;
        const symbol = try self.putSymbol(name, scope, frame.num_definitions);
        frame.num_definitions += 1;
        return symbol;
    }

    /// The table whose frame (or globals) stores this table's definitions.
    fn frameTable(self: *SymbolTable) *SymbolTable {
        var table = self;
        while (table.is_block) table = table.outer.?;
        return table;
    }

    pub fn resolve(self: *SymbolTable, name: []const u8) ?Symbol {
        if (self.store.get(name)) |symbol| {
            return symbol;
        }
        if (self.outer) |outer| {
            const obj = outer.resolve(name) orelse return null;
            if (self.is_block or obj.scope == .global or obj.scope == .builtin) {
                return obj;
            }
            return self.defineFree(obj) catch return null;
        }
        if (builtins.fromName(name)) |b| {
            return Symbol{
                .name = name,
                .scope = .builtin,
                .index = @backingInt(b),
            };
        }
        return null;
    }

    fn defineFree(self: *SymbolTable, original: Symbol) !Symbol {
        try self.free_symbols.append(self.store.allocator, original);
        return self.putSymbol(original.name, .free, self.free_symbols.items.len - 1);
    }

    fn putSymbol(self: *SymbolTable, name: []const u8, scope: SymbolScope, index: usize) !Symbol {
        const gop = try self.store.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.store.allocator.dupe(u8, name);
        }
        const symbol = Symbol{ .name = gop.key_ptr.*, .scope = scope, .index = index };
        gop.value_ptr.* = symbol;
        return symbol;
    }

    pub fn deinit(self: *SymbolTable) void {
        var it = self.store.iterator();
        while (it.next()) |entry| {
            self.store.allocator.free(entry.key_ptr.*);
        }
        self.store.deinit();
        self.free_symbols.deinit(self.allocator);
    }
};
