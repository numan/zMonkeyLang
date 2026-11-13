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
    const bindings = try iterator.next(std.testing.allocator) orelse return error.TestUnexpectedResult;
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
    try std.testing.expectEqual(null, try values.next(std.testing.allocator));

    var pairs = Object.Iterator.init(range, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 0, 5);
    try expectNext(&pairs, 1, 6);
    try std.testing.expectEqual(null, try pairs.next(std.testing.allocator));
}

test "range iterator handles empty ranges and the integer limit" {
    var empty = Object.Iterator.init(.{ .range = .{ .start = 3, .end = 1 } }, false) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(null, try empty.next(std.testing.allocator));

    const max = std.math.maxInt(i64);
    var at_limit = Object.Iterator.init(.{ .range = .{ .start = max - 1, .end = max } }, false) orelse return error.TestUnexpectedResult;
    try expectNext(&at_limit, max - 1, null);
    try std.testing.expectEqual(null, try at_limit.next(std.testing.allocator));
}

test "array iterator yields items, or indexes and items" {
    var elements = [_]Object{ .{ .int = Object.Integer.init(2) }, .{ .int = Object.Integer.init(3) } };
    var array = Object.Array.init(&elements);
    const iterable = Object{ .array = &array };

    var values = Object.Iterator.init(iterable, false) orelse return error.TestUnexpectedResult;
    try expectNext(&values, 2, null);
    try expectNext(&values, 3, null);
    try std.testing.expectEqual(null, try values.next(std.testing.allocator));

    var pairs = Object.Iterator.init(iterable, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 0, 2);
    try expectNext(&pairs, 1, 3);
    try std.testing.expectEqual(null, try pairs.next(std.testing.allocator));
}

fn expectNextString(iterator: *Object.Iterator, allocator: std.mem.Allocator, index: ?i64, expected: []const u8) !void {
    const bindings = try iterator.next(allocator) orelse return error.TestUnexpectedResult;
    if (index) |expected_index| {
        try expectInt(expected_index, bindings.first);
        const item = bindings.second orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected, item.string.value);
    } else {
        try std.testing.expectEqualStrings(expected, bindings.first.string.value);
        try std.testing.expectEqual(null, bindings.second);
    }
}

test "string iterator yields UTF-8 characters, or character indexes and characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var string = Object.String.init("aéb");
    const iterable = Object{ .string = &string };

    var values = Object.Iterator.init(iterable, false) orelse return error.TestUnexpectedResult;
    try expectNextString(&values, allocator, null, "a");
    try expectNextString(&values, allocator, null, "é");
    try expectNextString(&values, allocator, null, "b");
    try std.testing.expectEqual(null, try values.next(allocator));

    var pairs = Object.Iterator.init(iterable, true) orelse return error.TestUnexpectedResult;
    try expectNextString(&pairs, allocator, 0, "a");
    try expectNextString(&pairs, allocator, 1, "é");
    try expectNextString(&pairs, allocator, 2, "b");
    try std.testing.expectEqual(null, try pairs.next(allocator));
}

test "charLen measures one UTF-8 code point, or one byte where the bytes are not valid UTF-8" {
    const cases = [_]struct { bytes: []const u8, expected: usize }{
        .{ .bytes = "ab", .expected = 1 },
        .{ .bytes = "éa", .expected = 2 },
        .{ .bytes = "€", .expected = 3 },
        .{ .bytes = "🐒", .expected = 4 },
        .{ .bytes = "\xffa", .expected = 1 }, // not a start byte
        .{ .bytes = "\xc3a", .expected = 1 }, // start byte without its continuation byte
        .{ .bytes = "\xe2\x82", .expected = 1 }, // cut off by the end of the string
        .{ .bytes = "\xc0\xaf", .expected = 1 }, // overlong encoding
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, Object.String.charLen(case.bytes));
    }
}

test "charCount counts UTF-8 code points, and each byte that is not valid UTF-8" {
    const cases = [_]struct { value: []const u8, expected: usize }{
        .{ .value = "", .expected = 0 },
        .{ .value = "hello", .expected = 5 },
        .{ .value = "héllo", .expected = 5 },
        .{ .value = "zig⚡🐒", .expected = 5 },
        .{ .value = "\xffa\xc3", .expected = 3 },
    };
    for (cases) |case| {
        const string = Object.String.init(case.value);
        try std.testing.expectEqual(case.expected, string.charCount());
    }
}

test "hash iterator yields keys, or keys and values" {
    var hash = Object.Hash{ .pairs = .init(std.testing.allocator) };
    defer hash.pairs.deinit();
    const key = Object{ .int = Object.Integer.init(2) };
    try hash.pairs.put(key.hashKey().?, .{ .key = key, .value = .{ .int = Object.Integer.init(10) } });
    const iterable = Object{ .hash = &hash };

    var keys = Object.Iterator.init(iterable, false) orelse return error.TestUnexpectedResult;
    try expectNext(&keys, 2, null);
    try std.testing.expectEqual(null, try keys.next(std.testing.allocator));

    var pairs = Object.Iterator.init(iterable, true) orelse return error.TestUnexpectedResult;
    try expectNext(&pairs, 2, 10);
    try std.testing.expectEqual(null, try pairs.next(std.testing.allocator));
}

test "non-iterable objects have no iterator" {
    try std.testing.expectEqual(null, Object.Iterator.init(.{ .int = Object.Integer.init(1) }, false));
}
