//! copied with no changes from https://codeberg.org/ziglang/zig/pulls/30823

/// A `FlexibleStruct` is a data structure where one or more fields are runtime sized arrays.
pub fn FlexibleStruct(Layout: type) type {
    return struct {
        const is_auto = switch (@typeInfo(Layout)) {
            .@"struct" => |i| i.layout == .auto,
            else => @compileError("layout must be a struct"),
        };

        const alignment = if (!is_auto) Alignment.of(Layout) else blk: {
            var max: Alignment = .@"1";
            for (@typeInfo(Layout).@"struct".fields) |field| {
                max = max.max(.fromByteUnits(field.alignment));
            }
            break :blk max;
        };

        const sorted_fields = blk: {
            const original = @typeInfo(Layout).@"struct".fields;
            if (!is_auto) break :blk original;
            var fields: [original.len]StructField = original[0..original.len].*;
            std.mem.sortUnstable(StructField, &fields, {}, struct {
                fn cmp(_: void, a: StructField, b: StructField) bool {
                    const a_align = if (isFlexibleArray(a.type)) @alignOf(a.type.Element) else @alignOf(a.type);
                    const b_align = if (isFlexibleArray(b.type)) @alignOf(b.type.Element) else @alignOf(b.type);
                    return a_align > b_align;
                }
            }.cmp);
            break :blk fields;
        };

        /// A struct containing only the length fields that determine flexible array sizes.
        pub const Lens = blk: {
            var names: []const []const u8 = &.{};
            var types: []const type = &.{};
            var attrs: []const StructField.Attributes = &.{};
            for (@typeInfo(Layout).@"struct".fields) |field| {
                if (isFlexibleArray(field.type)) {
                    const len_field_name = @tagName(field.type.len_field);
                    var found = false;
                    for (names) |name| {
                        if (std.mem.eql(u8, name, len_field_name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        names = names ++ .{len_field_name};
                        types = types ++ .{@FieldType(Layout, len_field_name)};
                        attrs = attrs ++ .{StructField.Attributes{}};
                    }
                }
            }
            break :blk @Struct(.auto, null, names, @ptrCast(types.ptr), @ptrCast(attrs.ptr));
        };

        /// Returns a buffer type with compile-time known capacity sufficient to hold a flexible struct with the given lengths.
        pub fn Buf(comptime capacity: Lens) type {
            return [calcSize(capacity)]u8;
        }

        /// Initializes a flexible struct within an existing buffer. The array member contents remain uninitialized.
        pub fn initBuffer(buf: []u8, lengths: Lens) *@This() {
            const size = calcSize(lengths);
            const aligned = std.mem.alignInBytes(buf, alignment.toByteUnits()).?;
            const bytes = aligned[0..size];

            const self: *@This() = @ptrCast(@alignCast(bytes.ptr));
            inline for (@typeInfo(Lens).@"struct".fields) |f| {
                const len_field = comptime stringToEnum(FieldEnum(Layout), f.name).?;
                self.ptr(len_field).* = @field(lengths, f.name);
            }
            return self;
        }

        /// Allocates and initializes a flexible struct on the heap. The array member contents remain uninitialized.
        pub fn create(allocator: Allocator, lengths: Lens) Oom!*@This() {
            const size = calcSize(lengths);
            const bytes = try allocator.alignedAlloc(u8, alignment, size);

            const self: *@This() = @ptrCast(@alignCast(bytes.ptr));
            inline for (@typeInfo(Lens).@"struct".fields) |f| {
                const len_field = comptime stringToEnum(FieldEnum(Layout), f.name).?;
                self.ptr(len_field).* = @field(lengths, f.name);
            }
            return self;
        }

        /// Frees a flexible struct previously allocated with `create`. Calling this function on a struct allocated with `initBuffer` is illegal behavior.
        pub fn destroy(self: *@This(), allocator: Allocator) void {
            const size = calcSize(self.calcLens());
            const bytes: [*]align(alignment.toByteUnits()) u8 = @ptrCast(@alignCast(self));
            allocator.free(bytes[0..size]);
        }

        /// Returns a slice view of a flexible array field.
        pub fn slice(self: *@This(), comptime field: FieldEnum(Layout)) SliceOf(field) {
            const bytes: [*]u8 = @ptrCast(@alignCast(self));
            const offset = offsetOf(self, field);
            const size = sizeOf(self, field);
            return @ptrCast(@alignCast(bytes[offset..][0..size]));
        }

        /// Returns a pointer to a field.
        pub fn ptr(self: *@This(), comptime field: FieldEnum(Layout)) PtrOf(field) {
            const bytes: [*]u8 = @ptrCast(@alignCast(self));
            const offset = offsetOf(self, field);
            return @ptrCast(@alignCast(bytes + offset));
        }

        /// Returns the number of elements in a field.
        pub fn len(self: *const @This(), comptime field: FieldEnum(Layout)) usize {
            const T = @FieldType(Layout, @tagName(field));
            return if (isFlexibleArray(T)) lenOf(self, field) else 1;
        }

        fn SliceOf(comptime field: FieldEnum(Layout)) type {
            return []ElementOf(field);
        }

        fn PtrOf(comptime field: FieldEnum(Layout)) type {
            const T = @FieldType(Layout, @tagName(field));
            return if (isFlexibleArray(T)) [*]T.Element else *T;
        }

        fn LenOf(comptime field: FieldEnum(Layout)) type {
            const T = @FieldType(Layout, @tagName(field));
            return if (isFlexibleArray(T)) @FieldType(Layout, @tagName(lenFieldOf(field))) else usize;
        }

        fn ElementOf(comptime field: FieldEnum(Layout)) type {
            const T = @FieldType(Layout, @tagName(field));
            return if (isFlexibleArray(T)) T.Element else T;
        }

        inline fn lenFieldOf(comptime field: FieldEnum(Layout)) FieldEnum(Layout) {
            const T = @FieldType(Layout, @tagName(field));
            return T.len_field;
        }

        fn lenOf(self: *const @This(), comptime field: FieldEnum(Layout)) LenOf(field) {
            const T = @FieldType(Layout, @tagName(field));

            if (!isFlexibleArray(T)) return 1;

            const len_field = lenFieldOf(field);
            const offset = self.offsetOf(len_field);
            const size = self.sizeOf(len_field);

            const bytes: [*]const u8 = @ptrCast(self);
            const len_ptr: *const LenOf(field) = @ptrCast(@alignCast(bytes[offset..][0..size]));

            return len_ptr.*;
        }

        fn sizeOf(self: *const @This(), comptime field: FieldEnum(Layout)) usize {
            const Field = @FieldType(Layout, @tagName(field));

            if (isFlexibleArray(Field)) {
                const length = lenOf(self, field);

                return @sizeOf(Field.Element) * length;
            } else {
                return @sizeOf(Field);
            }
        }

        fn offsetOf(head: *const @This(), comptime field: FieldEnum(Layout)) usize {
            var offset: usize = 0;
            inline for (sorted_fields) |f| {
                const T = if (isFlexibleArray(f.type)) f.type.Element else f.type;
                offset = std.mem.alignForward(usize, offset, @alignOf(T));
                if (comptime std.mem.eql(u8, f.name, @tagName(field))) {
                    return offset;
                }
                offset += sizeOf(head, stringToEnum(FieldEnum(Layout), f.name).?);
            }
            unreachable;
        }

        fn calcSize(lengths: Lens) usize {
            var size: usize = 0;
            inline for (sorted_fields) |f| {
                const T = if (isFlexibleArray(f.type)) f.type.Element else f.type;
                size = std.mem.alignForward(usize, size, @alignOf(T));
                if (isFlexibleArray(f.type)) {
                    const len_field_name = @tagName(f.type.len_field);
                    const length = @field(lengths, len_field_name);
                    size += @sizeOf(T) * length;
                } else {
                    size += @sizeOf(f.type);
                }
            }
            size = std.mem.alignForward(usize, size, alignment.toByteUnits());
            return size;
        }

        fn calcLens(self: *@This()) Lens {
            var result: Lens = undefined;
            inline for (@typeInfo(Lens).@"struct".fields) |f| {
                const len_field = comptime stringToEnum(FieldEnum(Layout), f.name).?;
                @field(result, f.name) = self.ptr(len_field).*;
            }
            return result;
        }

        test Buf {
            const Packet = FlexibleStruct(struct {
                host_len: usize,
                host: FlexibleArray(u8, .host_len),
                buf_lens: usize,
                read_buf: FlexibleArray(u8, .buf_lens),
                write_buf: FlexibleArray(u8, .buf_lens),
            });

            const host = "ziglang.org";

            var buf: Packet.Buf(.{
                .host_len = 1024,
                .buf_lens = 128,
            }) = undefined;

            const packet: *Packet = .initBuffer(&buf, .{
                .host_len = host.len,
                .buf_lens = 10,
            });

            @memcpy(packet.slice(.host), host);
            @memcpy(packet.slice(.read_buf), "0123456789");
            @memcpy(packet.slice(.write_buf), "abdefghijk");

            try std.testing.expectEqualSlices(u8, host, packet.slice(.host));
            try std.testing.expectEqual(10, packet.len(.read_buf));
            try std.testing.expectEqualSlices(u8, "0123456789", packet.slice(.read_buf));
            try std.testing.expectEqual(10, packet.len(.write_buf));
            try std.testing.expectEqualSlices(u8, "abdefghijk", packet.slice(.write_buf));
        }
    };
}

/// Declares a flexible array field within a `FlexibleStruct` layout.
///
/// The array length is determined at runtime by the value of `length_field`,
/// which must be another field in the same struct.
///
/// Multiple flexible arrays may reference the same length field.
pub fn FlexibleArray(comptime T: type, comptime length_field: @EnumLiteral()) type {
    return struct {
        const is_flexible_array = IsFlexibleArray{};

        const Element = T;
        const len_field = length_field;
    };
}

const IsFlexibleArray = struct {};

inline fn isFlexibleArray(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "is_flexible_array") and
        @TypeOf(T.is_flexible_array) == IsFlexibleArray;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const FieldEnum = std.meta.FieldEnum;
const Oom = Allocator.Error;
const stringToEnum = std.meta.stringToEnum;
const StructField = std.builtin.Type.StructField;
const testing = std.testing;

const builtin = @import("builtin");

test FlexibleStruct {
    const Packet = FlexibleStruct(struct {
        host_len: usize,
        host: FlexibleArray(u8, .host_len),
        buf_lens: usize,
        read_buf: FlexibleArray(u8, .buf_lens),
        write_buf: FlexibleArray(u8, .buf_lens),
    });

    const host = "ziglang.org";

    const packet: *Packet = try .create(testing.allocator, .{
        .host_len = host.len,
        .buf_lens = 10,
    });
    defer packet.destroy(testing.allocator);

    @memcpy(packet.slice(.host), host);
    @memcpy(packet.slice(.read_buf), "0123456789");
    @memcpy(packet.slice(.write_buf), "abdefghijk");

    try std.testing.expectEqualSlices(u8, host, packet.slice(.host));
    try std.testing.expectEqual(10, packet.len(.read_buf));
    try std.testing.expectEqualSlices(u8, "0123456789", packet.slice(.read_buf));
    try std.testing.expectEqual(10, packet.len(.write_buf));
    try std.testing.expectEqualSlices(u8, "abdefghijk", packet.slice(.write_buf));
}

test "layout" {
    const well_defined = FlexibleStruct(extern struct {
        len: u8,
        arr: FlexibleArray(u64, .len),
    });

    const not_well_defined = FlexibleStruct(struct {
        len: u8,
        arr: FlexibleArray(u64, .len),
    });

    try testing.expect(well_defined.calcSize(.{ .len = 1 }) > not_well_defined.calcSize(.{ .len = 1 }));
}
