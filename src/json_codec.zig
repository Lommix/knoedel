//! Comptime-generated JSON mapping for component and resource values.
const std = @import("std");

pub const JsonVTable = struct {
    write: *const fn (*const anyopaque, *std.Io.Writer) anyerror!void,
    schema: *const fn (*std.Io.Writer) anyerror!void,
    apply: *const fn (*anyopaque, std.mem.Allocator, std.json.Value) anyerror!void,
    /// writes `defaultValue(T)` into a buffer, so `apply` can run on it;
    /// null when the type is not default constructible (no whole insert).
    init: ?*const fn (*anyopaque) void,
};

/// Returns the codec implementation for T, or null when no field of T is
/// JSON-representable.
pub fn Codec(comptime T: type) ?type {
    if (!isMapped(T)) return null;
    return struct {
        pub fn write(ptr: *const anyopaque, w: *std.Io.Writer) anyerror!void {
            try writeValue(T, w, @as(*const T, @ptrCast(@alignCast(ptr))));
        }

        pub fn schema(w: *std.Io.Writer) anyerror!void {
            try writeSchema(T, w);
        }

        pub fn apply(ptr: *anyopaque, gpa: std.mem.Allocator, value: std.json.Value) anyerror!void {
            try applyValue(T, gpa, @as(*T, @ptrCast(@alignCast(ptr))), value);
        }

        pub fn init(ptr: *anyopaque) void {
            const casted: *T = @ptrCast(@alignCast(ptr));
            casted.* = defaultValue(T);
        }
    };
}

fn isFieldNameAllowed(comptime name: []const u8) bool {
    return name.len == 0 or name[0] != '_';
}

/// Enums without declared tags (`enum(u32) { _ }`) are mapped as integers.
fn isOpaqueEnum(comptime T: type) bool {
    return @typeInfo(T).@"enum".field_names.len == 0;
}

/// true when T can be produced from defaults (ints 0, enums first tag,
/// strings "", optionals null, empty arrays, recursive struct defaults).
pub fn defaultable(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => return true,
        .pointer => |ptr| return ptr.size == .slice and ptr.attrs.@"const" and ptr.child == u8,
        .optional => return true,
        .array => |arr| return defaultable(arr.child),
        .vector => |vec| return defaultable(vec.child),
        .@"union" => |un| {
            if (un.tag_type == null) return false;
            const first_type = un.field_types[0];
            return first_type == void or defaultable(first_type);
        },
        .@"struct" => |str| {
            inline for (str.field_types) |f_type| {
                if (!comptime defaultable(f_type)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Only call when `defaultable(T)` is true.
/// Builds the default value for T: each struct field uses its Zig field
/// default when present, else recurses into `defaultValue` of its type.
pub fn defaultValue(comptime T: type) T {
    switch (@typeInfo(T)) {
        .bool => return false,
        .int, .float => return 0,
        .@"enum" => |en| {
            if (en.field_names.len == 0) return @enumFromInt(0);
            return @enumFromInt(en.field_values[0]);
        },
        .pointer => return "",
        .optional => return null,
        .array => |arr| return @splat(defaultValue(arr.child)),
        .vector => |vec| return @splat(defaultValue(vec.child)),
        .@"union" => |un| {
            const first_name = un.field_names[0];
            const first_type = un.field_types[0];
            if (first_type == void) return @unionInit(T, first_name, {});
            return @unionInit(T, first_name, defaultValue(first_type));
        },
        .@"struct" => |str| {
            var out: T = undefined;
            inline for (str.field_names, str.field_types, str.field_attrs) |f_name, f_type, f_attrs| {
                @field(out, f_name) = if (comptime f_attrs.defaultValue(f_type)) |dv|
                    dv
                else
                    defaultValue(f_type);
            }
            return out;
        },
        else => comptime unreachable,
    }
}

pub fn isMapped(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => return true,
        .pointer => |ptr| return ptr.size == .slice and ptr.attrs.@"const" and ptr.child == u8,
        .optional => |opt| return comptime (defaultable(opt.child) and isMapped(opt.child)),
        .array => |arr| return isMapped(arr.child),
        .vector => |vec| return isMapped(vec.child),
        .@"union" => |un| {
            if (un.tag_type == null) return false;
            inline for (un.field_types) |f_type| {
                if (comptime (f_type == void or isMapped(f_type))) return true;
            }
            return false;
        },
        .@"struct" => |str| {
            if (str.is_tuple) {
                if (str.field_names.len == 0) return false;
                inline for (str.field_types) |f_type| {
                    if (!comptime isMapped(f_type)) return false;
                }
                return true;
            }
            inline for (str.field_names, str.field_types) |f_name, f_type| {
                if (comptime (isFieldNameAllowed(f_name) and isMapped(f_type))) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn writeJsonStr(w: *std.Io.Writer, s: []const u8) anyerror!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn writeValue(comptime T: type, w: *std.Io.Writer, ptr: anytype) anyerror!void {
    switch (comptime @typeInfo(T)) {
        .bool => try w.print("{}", .{ptr.*}),
        .int => try w.print("{d}", .{ptr.*}),
        .float => {
            if (std.math.isFinite(ptr.*)) {
                try w.print("{d}", .{ptr.*});
            } else {
                try w.writeAll("null");
            }
        },
        .@"enum" => {
            if (comptime isOpaqueEnum(T)) {
                try w.print("{d}", .{@intFromEnum(ptr.*)});
            } else {
                // Runtime values can be outside the declared tags (raw casts
                // in game code); never let @tagName panic.
                const raw = @intFromEnum(ptr.*);
                const name = std.enums.tagName(T, ptr.*);
                if (name) |n| try writeJsonStr(w, n) else try w.print("{d}", .{raw});
            }
        },
        .pointer => try writeJsonStr(w, ptr.*),
        .optional => if (ptr.*) |*inner| {
            try writeValue(@TypeOf(inner.*), w, inner);
        } else {
            try w.writeAll("null");
        },
        .array => |arr| {
            try w.writeAll("[");
            for (0..arr.len) |i| {
                if (i != 0) try w.writeAll(",");
                try writeValue(arr.child, w, &ptr.*[i]);
            }
            try w.writeAll("]");
        },
        .vector => |vec| {
            const buf: [vec.len]vec.child = ptr.*;
            try writeValue(@TypeOf(buf), w, &buf);
        },
        .@"struct" => |str| {
            try w.writeAll("{");
            var first = true;
            inline for (str.field_names, str.field_types) |f_name, f_type| {
                const writable = comptime (isFieldNameAllowed(f_name) and isMapped(f_type));
                if (writable) {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeJsonStr(w, f_name);
                    try w.writeAll(":");
                    try writeValue(f_type, w, &@field(ptr.*, f_name));
                }
            }
            try w.writeAll("}");
        },
        .@"union" => {
            try w.writeAll("{");
            switch (ptr.*) {
                inline else => |payload, tag| {
                    const P = @TypeOf(payload);
                    try writeJsonStr(w, @tagName(tag));
                    if (comptime P == void) {
                        try w.writeAll(":null");
                    } else if (comptime isMapped(P)) {
                        var tmp: P = payload;
                        try w.writeAll(":");
                        try writeValue(P, w, &tmp);
                    } else {
                        try w.writeAll(":null");
                    }
                },
            }
            try w.writeAll("}");
        },
        else => comptime unreachable,
    }
}

fn writeSchema(comptime T: type, w: *std.Io.Writer) anyerror!void {
    try w.writeAll("[");
    var first = true;
    switch (comptime @typeInfo(T)) {
        .@"struct" => |str| {
            if (!str.is_tuple) {
                inline for (str.field_names, str.field_types) |f_name, f_type| {
                    const writable = comptime (isFieldNameAllowed(f_name) and isMapped(f_type));
                    if (writable) {
                        if (!first) try w.writeAll(",");
                        first = false;
                        try w.writeAll("{\"name\":");
                        try writeJsonStr(w, f_name);
                        try w.writeAll(",\"type\":");
                        try writeJsonStr(w, @typeName(f_type));
                        try w.writeAll("}");
                    }
                }
            }
        },
        else => {},
    }
    try w.writeAll("]");
}

fn applyValue(comptime T: type, gpa: std.mem.Allocator, dst: anytype, value: std.json.Value) anyerror!void {
    switch (comptime @typeInfo(T)) {
        .bool => dst.* = switch (value) {
            .bool => |b| b,
            else => return error.ExpectedBool,
        },
        .int => dst.* = switch (value) {
            .integer => |i| std.math.cast(T, i) orelse return error.IntOutOfRange,
            .float => |f| blk: {
                if (!std.math.isFinite(f)) return error.IntOutOfRange;
                if (@trunc(f) != f) return error.NotAnInteger;
                if (f > @as(f64, @floatFromInt(std.math.maxInt(T)))) return error.IntOutOfRange;
                if (f < @as(f64, @floatFromInt(std.math.minInt(T)))) return error.IntOutOfRange;
                break :blk @intFromFloat(f);
            },
            else => return error.ExpectedNumber,
        },
        .float => dst.* = switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => return error.ExpectedNumber,
        },
        .@"enum" => {
            if (comptime isOpaqueEnum(T)) {
                const raw = switch (value) {
                    .integer => |i| std.math.cast(@typeInfo(T).@"enum".tag_type, i) orelse return error.IntOutOfRange,
                    else => return error.ExpectedNumber,
                };
                dst.* = @enumFromInt(raw);
            } else {
                dst.* = switch (value) {
                    .string => |s| std.meta.stringToEnum(T, s) orelse return error.UnknownEnumTag,
                    else => return error.ExpectedEnumTag,
                };
            }
        },
        .pointer => dst.* = switch (value) {
            .string => |s| try gpa.dupe(u8, s),
            else => return error.ExpectedString,
        },
        .optional => |opt| {
            if (value == .null) {
                dst.* = null;
                return;
            }
            var tmp = defaultValue(opt.child);
            try applyValue(opt.child, gpa, &tmp, value);
            dst.* = tmp;
        },
        .array => |arr| {
            const items = switch (value) {
                .array => |a| a.items,
                else => return error.ExpectedArray,
            };
            if (items.len != arr.len) return error.ArrayLengthMismatch;
            for (items, 0..) |item, i| try applyValue(arr.child, gpa, &dst.*[i], item);
        },
        .vector => |vec| {
            const items = switch (value) {
                .array => |a| a.items,
                else => return error.ExpectedArray,
            };
            if (items.len != vec.len) return error.ArrayLengthMismatch;
            var buf: [vec.len]vec.child = undefined;
            for (items, 0..) |item, i| {
                var tmp = defaultValue(vec.child);
                try applyValue(vec.child, gpa, &tmp, item);
                buf[i] = tmp;
            }
            dst.* = @bitCast(buf);
        },
        .@"union" => |un| {
            const obj = switch (value) {
                .object => |o| o,
                else => return error.ExpectedObject,
            };
            if (obj.count() != 1) return error.ExpectedSingleTagObject;
            var it = obj.iterator();
            const entry = it.next().?;
            const key = entry.key_ptr.*;
            var matched = false;
            inline for (un.field_names, un.field_types) |f_name, f_type| {
                const settable = comptime (f_type == void or isMapped(f_type));
                if (settable and !matched and std.mem.eql(u8, key, f_name)) {
                    matched = true;
                    if (comptime f_type == void) {
                        dst.* = @unionInit(T, f_name, {});
                    } else {
                        var tmp = defaultValue(f_type);
                        try applyValue(f_type, gpa, &tmp, entry.value_ptr.*);
                        dst.* = @unionInit(T, f_name, tmp);
                    }
                }
            }
            if (!matched) return error.UnknownUnionTag;
        },
        .@"struct" => |str| {
            if (str.is_tuple) {
                const items = switch (value) {
                    .array => |a| a.items,
                    else => return error.ExpectedArray,
                };
                if (items.len != str.field_names.len) return error.ArrayLengthMismatch;
                inline for (str.field_names, str.field_types, items) |f_name, f_type, item| {
                    try applyValue(f_type, gpa, &@field(dst.*, f_name), item);
                }
                return;
            }
            const obj = switch (value) {
                .object => |o| o,
                else => return error.ExpectedObject,
            };
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                var matched = false;
                inline for (str.field_names, str.field_types) |f_name, f_type| {
                    const settable = comptime (isFieldNameAllowed(f_name) and isMapped(f_type));
                    if (settable and !matched and std.mem.eql(u8, key, f_name)) {
                        matched = true;
                        try applyValue(f_type, gpa, &@field(dst.*, f_name), entry.value_ptr.*);
                    }
                }
                if (!matched) return error.UnknownField;
            }
        },
        else => comptime unreachable,
    }
}
