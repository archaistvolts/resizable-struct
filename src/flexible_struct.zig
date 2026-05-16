/// A `FlexibleStruct` is a data structure where one or more fields are runtime sized arrays.
pub fn Struct(Layout: type) type {
    return struct {
        _: void align(alignment.toByteUnits()),

        const is_auto = switch (@typeInfo(Layout)) {
            .@"struct" => |i| i.layout == .auto,
            else => @compileError("layout must be a struct"),
        };

        const alignment = if (!is_auto) mem.Alignment.of(Layout) else blk: {
            var max: mem.Alignment = .@"1";
            for (@typeInfo(Layout).@"struct".fields) |field| {
                max = max.max(.fromByteUnits(FieldAlignment(field)));
            }
            break :blk max;
        };

        const layout_fields = @typeInfo(Layout).@"struct".fields;

        pub const sorted_fields = blk: {
            if (!is_auto) break :blk layout_fields;
            var fields: [layout_fields.len]StructField = layout_fields[0..layout_fields.len].*;
            mem.sortUnstable(StructField, &fields, {}, struct {
                fn cmp(_: void, a: StructField, b: StructField) bool {
                    return FieldAlignment(a) > FieldAlignment(b);
                }
            }.cmp);
            break :blk fields;
        };

        /// A struct containing only the length fields that determine flexible array sizes.
        pub const Lengths = blk: {
            var names: []const []const u8 = &.{};
            var types: []const type = &.{};
            var attrs: []const StructField.Attributes = &.{};
            for (@typeInfo(Layout).@"struct".fields) |field| {
                if (IsArray(field.type)) {
                    const len_field_name = @tagName(field.type.len_field);
                    const found = for (names) |name| {
                        if (mem.eql(u8, name, len_field_name))
                            break true;
                    } else false;
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
        pub fn Buf(comptime capacity: Lengths) type {
            return [calcSize(capacity)]u8;
        }

        pub const Field = meta.FieldEnum(Layout);

        /// Initializes a flexible struct within an existing buffer. The array member contents remain uninitialized.
        pub fn initBuffer(buf: []u8, lengths: Lengths) *@This() {
            return initBufferAligned(mem.alignInBytes(buf, alignment.toByteUnits()).?, lengths);
        }

        /// Initializes a flexible struct within an existing aligned buffer. The array member contents remain uninitialized.
        pub fn initBufferAligned(buf: []align(alignment.toByteUnits()) u8, lengths: Lengths) *@This() {
            const size = calcSize(lengths);
            const self: *@This() = @ptrCast(buf[0..size].ptr);
            inline for (@typeInfo(Lengths).@"struct".fields) |f| {
                self.ptr(@field(Field, f.name)).* = @field(lengths, f.name);
            }
            return self;
        }

        /// Allocates and initializes a flexible struct on the heap. The array member contents remain uninitialized.
        pub fn create(
            allocator: mem.Allocator,
            lengths: Lengths,
        ) mem.Allocator.Error!*@This() {
            const size = calcSize(lengths);
            const bytes = try allocator.alignedAlloc(u8, alignment, size);

            const self: *@This() = @ptrCast(@alignCast(bytes.ptr));
            inline for (@typeInfo(Lengths).@"struct".fields) |f| {
                self.ptr(@field(Field, f.name)).* = @field(lengths, f.name);
            }
            return self;
        }

        /// Frees a flexible struct previously allocated with `create`. Calling this function on a struct allocated with `initBuffer` is illegal behavior.
        pub fn destroy(self: *@This(), allocator: mem.Allocator) void {
            const size = calcSize(self.calcLens());
            const bytes: [*]align(alignment.toByteUnits()) u8 =
                @ptrCast(@alignCast(self));
            allocator.free(bytes[0..size]);
        }

        /// Returns a slice view of a flexible array field with constness determined by self.
        pub fn slice(self: anytype, comptime field: Field) SliceOf(@TypeOf(self), field) {
            const bytes: [*]u8 = @ptrCast(@alignCast(self));
            const offset = offsetOf(self, field);
            const size = sizeOf(self, field);
            return @ptrCast(@alignCast(bytes[offset..][0..size]));
        }

        /// Returns a pointer to a field with constness determined by self.
        pub fn ptr(self: anytype, comptime field: Field) PtrOf(@TypeOf(self), field) {
            const offset = offsetOf(self, field);
            return @ptrCast(@alignCast(self.asBytes() + offset));
        }

        /// Returns the number of elements in a field.
        pub fn len(self: *const @This(), comptime field: Field) usize {
            const T = @FieldType(Layout, @tagName(field));
            return if (IsArray(T)) lenOf(self, field) else 1;
        }

        pub fn SliceOf(S: type, field: Field) type {
            const T = @FieldType(Layout, @tagName(field));
            const sf = layout_fields[@intFromEnum(field)];
            return if (@typeInfo(S).pointer.is_const)
                []align(FieldAlignment(sf)) const ElementOf(T)
            else
                []align(FieldAlignment(sf)) ElementOf(T);
        }

        pub fn PtrOf(S: type, field: Field) type {
            const T = @FieldType(Layout, @tagName(field));
            const sf = layout_fields[@intFromEnum(field)];
            const is_const = @typeInfo(S).pointer.is_const;
            return if (IsArray(T))
                if (is_const)
                    [*]align(FieldAlignment(sf)) const T.Element
                else
                    [*]align(FieldAlignment(sf)) T.Element
            else if (is_const)
                *const T
            else
                *T;
        }

        pub fn Bytes(S: type) type {
            return if (@typeInfo(S).pointer.is_const)
                [*]align(alignment.toByteUnits()) const u8
            else
                [*]align(alignment.toByteUnits()) u8;
        }

        pub fn LenOf(field: Field) type {
            const T = @FieldType(Layout, @tagName(field));
            return if (IsArray(T))
                @FieldType(Layout, @tagName(T.len_field))
            else
                u8;
        }

        /// returns self as an aligned u8 ptr with constness of self.
        pub fn asBytes(self: anytype) Bytes(@TypeOf(self)) {
            return @ptrCast(self);
        }

        pub fn lenOf(self: *const @This(), comptime field: Field) LenOf(field) {
            const T = @FieldType(Layout, @tagName(field));

            if (!IsArray(T)) return 1;

            const len_field = @FieldType(Layout, @tagName(field)).len_field;
            const offset = self.offsetOf(len_field);
            const size = self.sizeOf(len_field);

            const len_ptr: *const LenOf(field) =
                @ptrCast(@alignCast(self.asBytes()[offset..][0..size]));

            return len_ptr.*;
        }

        pub fn sizeOf(self: *const @This(), comptime field: Field) usize {
            const F = @FieldType(Layout, @tagName(field));
            return if (IsArray(F))
                @sizeOf(F.Element) * lenOf(self, field)
            else
                return @sizeOf(F);
        }

        pub fn offsetOf(head: *const @This(), comptime field: Field) usize {
            var offset: usize = 0;
            inline for (sorted_fields) |f| {
                offset = mem.alignForward(usize, offset, FieldAlignment(f));

                const this_field: Field = @field(Field, f.name);
                if (field == this_field)
                    return offset;
                offset += sizeOf(head, this_field);
            }
            unreachable;
        }

        pub fn calcSize(lengths: Lengths) usize {
            var size: usize = 0;
            inline for (sorted_fields) |f| {
                size = mem.alignForward(usize, size, FieldAlignment(f));
                if (IsArray(f.type)) {
                    const length = @field(lengths, @tagName(f.type.len_field));
                    size += @sizeOf(f.type.Element) * length;
                } else {
                    size += @sizeOf(f.type);
                }
            }
            size = mem.alignForward(usize, size, alignment.toByteUnits());
            return size;
        }

        pub fn calcLens(self: *@This()) Lengths {
            var result: Lengths = undefined;
            inline for (@typeInfo(Lengths).@"struct".fields) |f| {
                @field(result, f.name) = self.ptr(@field(Field, f.name)).*;
            }
            return result;
        }

        /// Copies a field from source to dest. `flexible.Array` fields choose
        /// the shorter of the two lengths, possibly truncating source or
        /// leaving uninitialized memory in dest.
        pub fn copyField(dest: *@This(), source: *const @This(), comptime field: Field) void {
            if (IsArray(@FieldType(Layout, @tagName(field)))) {
                @memcpy(
                    dest.ptr(field)[0..@min(source.len(field), dest.len(field))],
                    source.ptr(field),
                );
            } else {
                dest.ptr(field).* = source.ptr(field).*;
            }
        }

        /// A struct of fields from Layout where flexible arrays are replaced by
        /// `[*]Element` or `[*]const Element` according to caller constness.
        pub const View = blk: {
            var names: []const []const u8 = &.{};
            var types: []const type = &.{};
            var attrs: []const StructField.Attributes = &.{};
            for (sorted_fields) |field| {
                names = names ++ .{field.name};
                types = types ++ .{if (IsArray(field.type)) [*]field.type.Element else field.type};
                attrs = attrs ++ .{StructField.Attributes{
                    .@"align" = field.alignment,
                    .default_value_ptr = field.default_value_ptr,
                    .@"comptime" = field.is_comptime,
                }};
            }
            break :blk @Struct(@typeInfo(Layout).@"struct".layout, null, names, @ptrCast(types.ptr), @ptrCast(attrs.ptr));
        };

        /// a cached view
        pub fn view(self: anytype) View {
            var result: View = undefined;
            inline for (sorted_fields) |f| {
                const fieldptr = self.ptr(@field(Field, f.name));
                @field(result, f.name) = if (IsArray(f.type))
                    fieldptr
                else
                    fieldptr.*;
            }
            return result;
        }

        test Buf {
            const Packet = Struct(struct {
                host_len: usize,
                host: Array(u8, .host_len),
                buf_lens: usize,
                read_buf: Array(u8, .buf_lens),
                write_buf: Array(u8, .buf_lens),
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
///
/// Must be an extern struct to be usable in extern structs.
pub fn Array(comptime T: type, comptime length_field: @EnumLiteral()) type {
    return extern struct {
        const is_flexible_array = IsFlexibleArray{};

        const Element = T;
        const len_field = length_field;
    };
}

const IsFlexibleArray = struct {};

pub inline fn IsArray(T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "is_flexible_array") and
        @TypeOf(T.is_flexible_array) == IsFlexibleArray;
}

pub inline fn ElementOf(T: type) type {
    return if (IsArray(T)) T.Element else T;
}

pub inline fn FieldAlignment(f: StructField) usize {
    return f.alignment orelse @alignOf(ElementOf(f.type));
}

test Struct {
    const Packet = Struct(struct {
        host_len: usize,
        host: Array(u8, .host_len),
        buf_lens: usize,
        read_buf: Array(u8, .buf_lens),
        write_buf: Array(u8, .buf_lens),
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
    const well_defined = Struct(extern struct {
        len: u8,
        arr: Array(u64, .len),
        len2: u8,
    });

    const not_well_defined = Struct(struct {
        len: u8,
        arr: Array(u64, .len),
        len2: u8,
    });

    try testing.expect(well_defined.calcSize(.{ .len = 1 }) >
        not_well_defined.calcSize(.{ .len = 1 }));
}

fn alignFwd(n: usize, a: usize) usize {
    return mem.alignForward(usize, n, a);
}

test "field alignment" {
    const Layout = extern struct {
        len: u32 align(32),
        capacity: u32,
        containers: Array(u64, .capacity) align(32),
        keys: Array(u16, .capacity) align(32),
    };
    const RoaringArray = Struct(Layout);

    try testing.expectEqual(
        160,
        alignFwd(
            4 + 4 +
                alignFwd(8 * 10, 32) +
                alignFwd(2 * 10, 32),
            32,
        ),
    );

    try testing.expectEqual(160, RoaringArray.calcSize(.{ .capacity = 10 }));
    try testing.expectEqual(.@"32", mem.Alignment.of(Layout));
    try testing.expectEqual(.@"32", RoaringArray.alignment);

    var blocks = std.ArrayList(@Vector(32, u8)).empty;
    try blocks.ensureTotalCapacityPrecise(testing.allocator, 10);
    blocks.items.len = 10;
    defer blocks.deinit(testing.allocator);
    const ra = RoaringArray.initBuffer(@ptrCast(blocks.items), .{ .capacity = @intCast(blocks.items.len) });

    try testing.expectEqual(0, ra.offsetOf(.len));
    try testing.expectEqual(4, ra.offsetOf(.capacity));
    try testing.expectEqual(32, ra.offsetOf(.containers));
    try testing.expectEqual(128, alignFwd(4 + 4 + alignFwd(8 * 10, 32), 32));
    try testing.expectEqual(128, ra.offsetOf(.keys));
}

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const StructField = std.builtin.Type.StructField;
const testing = std.testing;
const builtin = @import("builtin");
