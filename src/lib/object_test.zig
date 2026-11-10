const std = @import("std");
const object = @import("object.zig");
const Object = object.Object;

test "same int values produce same hash key" {
    const a = Object{ .int = Object.Integer.init(42) };
    const b = Object{ .int = Object.Integer.init(42) };
    try std.testing.expectEqual(a.hashKey().?, b.hashKey().?);
}

test "different int values produce different hash keys" {
    const a = Object{ .int = Object.Integer.init(1) };
    const b = Object{ .int = Object.Integer.init(2) };
    try std.testing.expect(!std.meta.eql(a.hashKey().?, b.hashKey().?));
}

test "same bool values produce same hash key" {
    const a = Object{ .bool = Object.Boolean.init(true) };
    const b = Object{ .bool = Object.Boolean.init(true) };
    try std.testing.expectEqual(a.hashKey().?, b.hashKey().?);
}

test "different bool values produce different hash keys" {
    const a = Object{ .bool = Object.Boolean.init(true) };
    const b = Object{ .bool = Object.Boolean.init(false) };
    try std.testing.expect(!std.meta.eql(a.hashKey().?, b.hashKey().?));
}

test "same string content produces same hash key" {
    var s1 = Object.String.init("hello");
    var s2 = Object.String.init("hello");
    const a = Object{ .string = &s1 };
    const b = Object{ .string = &s2 };
    try std.testing.expectEqual(a.hashKey().?, b.hashKey().?);
}

test "different string content produces different hash keys" {
    var s1 = Object.String.init("hello");
    var s2 = Object.String.init("world");
    const a = Object{ .string = &s1 };
    const b = Object{ .string = &s2 };
    try std.testing.expect(!std.meta.eql(a.hashKey().?, b.hashKey().?));
}

test "int(1) and bool(true) produce different hash keys (cross-type)" {
    const a = Object{ .int = Object.Integer.init(1) };
    const b = Object{ .bool = Object.Boolean.init(true) };
    try std.testing.expect(!std.meta.eql(a.hashKey().?, b.hashKey().?));
}

test "non-hashable types return null" {
    const null_obj = Object{ .null = Object.Null.init() };
    const err_obj = Object{ .err = Object.Error.init("some error") };
    try std.testing.expectEqual(null, null_obj.hashKey());
    try std.testing.expectEqual(null, err_obj.hashKey());
}

fn expectInt(expected: i64, actual: Object) !void {
    try std.testing.expectEqual(expected, actual.int.value);
}

fn expectNext(iterator: *Object.Iterator, first: i64, second: ?i64) !void {
    const bindings = iterator.next() orelse return error.TestUnexpectedResult;
    try expectInt(first, bindings.first);
    if (second) |expected| {
        try expectInt(expected, bindings.second orelse return error.TestUnexpectedResult);
    } else {
        try std.testing.expectEqual(null, bindings.second);
    }
}

test "range iterator yields values, or indexes and values" {
    const range = Object{ .range = .{ .start = 5, .end = 7 } };

    var values = Object.Iterator.init(range, false) orelse return error.TestUnexpectedResult;
    try expectNext(&values, 5, null);
    try expectNext(&values, 6, null);
    try std.testing.expectEqual(null, values.next());

    var pairs = Object.Iterator.init(range, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 0, 5);
    try expectNext(&pairs, 1, 6);
    try std.testing.expectEqual(null, pairs.next());
}

test "range iterator handles empty ranges and the integer limit" {
    var empty = Object.Iterator.init(.{ .range = .{ .start = 3, .end = 1 } }, false) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(null, empty.next());

    const max = std.math.maxInt(i64);
    var at_limit = Object.Iterator.init(.{ .range = .{ .start = max - 1, .end = max } }, false) orelse return error.TestUnexpectedResult;
    try expectNext(&at_limit, max - 1, null);
    try std.testing.expectEqual(null, at_limit.next());
}

test "array iterator yields items, or indexes and items" {
    var elements = [_]Object{ .{ .int = Object.Integer.init(2) }, .{ .int = Object.Integer.init(3) } };
    var array = Object.Array.init(&elements);
    const iterable = Object{ .array = &array };

    var values = Object.Iterator.init(iterable, false) orelse return error.TestUnexpectedResult;
    try expectNext(&values, 2, null);
    try expectNext(&values, 3, null);
    try std.testing.expectEqual(null, values.next());

    var pairs = Object.Iterator.init(iterable, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 0, 2);
    try expectNext(&pairs, 1, 3);
    try std.testing.expectEqual(null, pairs.next());
}

test "string iterator yields bytes, or indexes and bytes" {
    var string = Object.String.init("ab");
    const iterable = Object{ .string = &string };

    var values = Object.Iterator.init(iterable, false) orelse return error.TestUnexpectedResult;
    try expectNext(&values, 'a', null);
    try expectNext(&values, 'b', null);
    try std.testing.expectEqual(null, values.next());

    var pairs = Object.Iterator.init(iterable, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 0, 'a');
    try expectNext(&pairs, 1, 'b');
    try std.testing.expectEqual(null, pairs.next());
}

test "hash iterator yields keys, or keys and values" {
    var hash = Object.Hash{ .pairs = .init(std.testing.allocator) };
    defer hash.pairs.deinit();
    const key = Object{ .int = Object.Integer.init(2) };
    try hash.pairs.put(key.hashKey().?, .{ .key = key, .value = .{ .int = Object.Integer.init(10) } });
    const iterable = Object{ .hash = &hash };

    var keys = Object.Iterator.init(iterable, false) orelse return error.TestUnexpectedResult;
    try expectNext(&keys, 2, null);
    try std.testing.expectEqual(null, keys.next());

    var pairs = Object.Iterator.init(iterable, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 2, 10);
    try std.testing.expectEqual(null, pairs.next());
}

test "non-iterable objects have no iterator" {
    try std.testing.expectEqual(null, Object.Iterator.init(.{ .int = Object.Integer.init(1) }, false));
}
