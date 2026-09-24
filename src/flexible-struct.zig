/// # About
///
/// a zero sized, single pointer layout library for auto layout (normal)
/// structs. struct fields are separated into 2 groups in memory: fixed followed
/// by flexible. each group is sorted by descending alignment. this makes fixed
/// field offsets statically known. and flexible field offsets can be calculated
/// in constant O(1) time with branchless SIMD instructions because there is no
/// padding between flexible fields.
///
/// the main cost of this layout is the extra size of dyn padding when compared
/// with other layouts (such as all fields being sorted by descending
/// alignment). the main benefit is constant time fixed and flexible field
/// access.
///
/// this library is meant to be a high performance and small in binary size. the
/// `*Cached()` API is meant to ensure that offset calculations are done only
/// once.
///
/// # Buffer layout
///```
/// [ fixed fields | dyn padding | dynamic fields | end padding ]
/// ^ ALIGN                      ^ DYN_ALIGN                    ^ ALIGN
///```
///
/// 1. buffer aligned to ALIGN
/// 1. fixed fields sorted by alignment desc
/// 1. optional padding to DYN_ALIGN
/// 1. dynamic fields sorted by alignment desc
/// 1. optional padding to ALIGN
///
///
/// # References
/// * https://tristanpemble.com/resizable-structs-in-zig/
/// * https://github.com/tristanpemble/resizable-struct
/// * https://codeberg.org/ziglang/zig/pulls/30823
///
pub fn Struct(Layout: type, options: struct { Size: type = usize }) type {
    return switch (@typeInfo(Layout)) {
        .@"struct" => extern struct {
            const layout_struct = switch (@typeInfo(Layout)) {
                .@"struct" => |s| switch (s.layout) {
                    .auto => s,
                    .@"packed", .@"extern" => @compileError("Packed and extern layouts are not supported"),
                },
                else => @compileError("Layout must be a struct"),
            };

            const layout_fields = layout_struct.fields;
            pub const NFIELDS = layout_fields.len;
            pub const alignment = max: {
                var max: mem.Alignment = .@"1";
                for (layout_fields) |field|
                    max = max.max(.fromByteUnits(AlignOf(field)));
                break :max max;
            };
            pub const ALIGN = alignment.toByteUnits();

            pub const block_size = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);
            const Block = @Vector(block_size, u8);
            pub const Size = options.Size;
            pub const SizeBlock = @Vector(@divExact(block_size, @sizeOf(Size)), Size);
            const max_fields_len = @typeInfo(SizeBlock).vector.len;

            comptime {
                if (NDYN_FIELDS > max_fields_len)
                    @compileError(std.fmt.comptimePrint(
                        "expected at most {} dynamic field(s).  found {} dynamic fields: {any}",
                        .{ max_fields_len, NDYN_FIELDS, meta.tags(DynField) },
                    ));
            }

            const fixedFieldCount = (struct {
                fn fixedFieldCount(fields: []const StructField) comptime_int {
                    return (for (0..NFIELDS) |i| {
                        if (isFlexibleArray(fields[i].type))
                            break i;
                    } else NFIELDS);
                }
            }).fixedFieldCount;

            const sorted_fields_info = info: {
                if (layout_struct.layout == .@"extern") // keep original field order
                    break :info .{
                        layout_fields[0..layout_fields.len].*,
                        fixedFieldCount(layout_fields),
                        attrs: {
                            var attrs: [layout_fields.len]std.builtin.Type.StructField.Attributes = undefined;
                            for (layout_fields, &attrs) |f, *attr| attr.* = .{
                                .@"comptime" = f.is_comptime,
                                .@"align" = f.alignment,
                                .default_value_ptr = f.default_value_ptr,
                            };
                            break :attrs attrs;
                        },
                    };

                var fields = layout_fields[0..layout_fields.len].*;
                const Sort = struct {
                    fn lessThanFlexible(_: void, lhs: StructField, rhs: StructField) bool {
                        return @intFromBool(isFlexibleArray(lhs.type)) <
                            @intFromBool(isFlexibleArray(rhs.type));
                    }
                    fn lessThanAlign(_: void, lhs: StructField, rhs: StructField) bool {
                        return AlignOf(lhs) > AlignOf(rhs);
                    }
                };
                mem.sort(StructField, &fields, {}, Sort.lessThanFlexible);

                const nfixed_fields = fixedFieldCount(&fields);
                mem.sort(StructField, fields[0..nfixed_fields], {}, Sort.lessThanAlign);
                mem.sort(StructField, fields[nfixed_fields..], {}, Sort.lessThanAlign);

                var fields_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
                for (fields, &fields_attrs) |f, *attr| attr.* = .{
                    .@"comptime" = f.is_comptime,
                    .@"align" = f.alignment,
                    .default_value_ptr = f.default_value_ptr,
                };
                break :info .{ fields, nfixed_fields, fields_attrs };
            };
            const sorted_fields = sorted_fields_info[0];
            const sorted_field_attrs = sorted_fields_info[2];
            pub const NFIXED_FIELDS = sorted_fields_info[1];
            pub const NDYN_FIELDS = NFIELDS - NFIXED_FIELDS;

            const field_infos = infos: {
                var dynsizes: Adyn = undefined;
                var dynaligns: Adyn = undefined;
                for (0..NDYN_FIELDS) |i| {
                    const f = sorted_fields[i + NFIXED_FIELDS];
                    dynaligns[i] = AlignOf(f);
                    dynsizes[i] = @sizeOf(ElementOf(@field(Field, f.name)));
                }

                var cur: Size = 0;
                var fixed_offs: [NFIXED_FIELDS]Size = undefined;
                for (0..fixed_offs.len) |i| {
                    cur += @sizeOf(ElementOf(@enumFromInt(i)));
                    cur = mem.alignForward(Size, cur, if (i < NFIELDS - 1)
                        AlignOf(sorted_fields[i + 1])
                    else
                        ALIGN);
                    fixed_offs[i] = cur;
                }
                break :infos .{ dynsizes, dynaligns, fixed_offs };
            };
            const dyn_field_sizes = field_infos[0];
            const dyn_field_aligns = field_infos[1];
            const fixed_offsets = field_infos[2];

            /// a struct with fields from Layout in 2 groups (fixed and
            /// flexible) each sorted by alignment descending.
            pub const Sorted = @Struct(
                .auto,
                null,
                selectFields(StructField, .name, &sorted_fields)[0..NFIELDS],
                selectFields(StructField, .type, &sorted_fields)[0..NFIELDS],
                &sorted_field_attrs,
            );
            pub const Field = meta.FieldEnum(Sorted);

            /// a struct with fields from Layout which are length fields in a
            /// flexible field in sorted_fields order.
            pub const Lengths = blk: {
                var names: []const []const u8 = &.{};
                for (sorted_fields) |field| {
                    if (isFlexibleArray(field.type) and !for (names) |name| {
                        if (mem.eql(u8, name, @tagName(field.type.length_field)))
                            break true;
                    } else false)
                        names = names ++ &[1][]const u8{@tagName(field.type.length_field)};
                }
                break :blk @Struct(.@"extern", null, names, &@splat(Size), &@splat(.{}));
            };
            pub const LengthField = meta.FieldEnum(Lengths);

            const fixed_fields = sorted_fields[0..NFIXED_FIELDS];
            /// a struct with leading fields from Sorted which are at fixed, static offsets.
            pub const Fixed = @Struct(
                .@"extern",
                null,
                selectFields(StructField, .name, fixed_fields)[0..NFIXED_FIELDS],
                selectFields(StructField, .type, fixed_fields)[0..NFIXED_FIELDS],
                sorted_field_attrs[0..NFIXED_FIELDS],
            );
            pub const FixedField = meta.FieldEnum(Fixed);

            const dyn_fields = sorted_fields[NFIXED_FIELDS..];
            /// a struct with trailing fields from Sorted which are at dynamic
            /// offsets determined by a length_field.
            pub const Dyn = @Struct(
                .@"extern",
                null,
                selectFields(StructField, .name, dyn_fields)[0..NDYN_FIELDS],
                selectFields(StructField, .type, dyn_fields)[0..NDYN_FIELDS],
                sorted_field_attrs[NFIXED_FIELDS..],
            );
            pub const DynField = meta.FieldEnum(Dyn);
            const DYN_ALIGN = AlignOf(dyn_fields[0]);

            const masks_misc = blk: {
                var lenfieldsmask: Mask = 0;
                var flexfieldsmask: Mask = 0;
                for (sorted_fields, 0..) |f, i| {
                    lenfieldsmask |= @as(Mask, @intFromBool(@hasField(Lengths, f.name))) << i;
                    flexfieldsmask |= @as(Mask, @intFromBool(isFlexibleArray(f.type))) << i;
                }
                break :blk .{ lenfieldsmask, flexfieldsmask };
            };
            const length_fields_mask = masks_misc[0];
            const flexible_fields_mask = masks_misc[1];

            const dyn_alignmasks = dyn_field_aligns - @as(Vdyn, @splat(1));
            pub const flexible_field_ids = ids: {
                var ids: []const FieldIdx = &.{};
                for (0..NFIELDS) |i| {
                    if (isFlexible(i)) ids = ids ++ .{i};
                }
                break :ids ids;
            };
            pub const length_field_ids = ids: {
                var ids: []const FieldIdx = &.{};
                for (0..NFIELDS) |i| {
                    if (isLenField(i)) ids = ids ++ .{i};
                }
                break :ids ids;
            };
            const offsets_init: A = fixed_offsets ++ @as(Adyn, undefined);

            // const Self = @This();

            const V = @Vector(NFIELDS, Size);
            const A = [NFIELDS]Size;
            const Mask = @Int(.unsigned, NFIELDS);
            const L = @Vector(length_field_ids.len, Size);
            pub const FieldIdx = @typeInfo(Field).@"enum".tag_type;
            const Constness = enum { constant, mutable };
            const Vdyn = @Vector(NDYN_FIELDS, Size);
            const Adyn = [NDYN_FIELDS]Size;

            fn dynCountsFromLengths(lengths: Lengths) Adyn {
                var counts: Adyn = @splat(1);
                const lens: L = @bitCast(lengths);
                inline for (flexible_field_ids) |i| {
                    const length_field = @field(LengthField, @tagName(sorted_fields[i].type.length_field));
                    counts[i - NFIXED_FIELDS] = lens[@intFromEnum(length_field)];
                }
                return counts;
            }

            /// returns an array of field offsets. first item is offset of
            /// second field. last is total size (aligned to ALIGN).
            fn calcOffsets(lengths: Lengths) A {
                const dyncounts: Vdyn = dynCountsFromLengths(lengths);
                const dynsizes = dyncounts * dyn_field_sizes;
                const dynasizesaligned = (dynsizes + dyn_alignmasks) & ~dyn_alignmasks;
                const dynbase: Vdyn = @splat(fixed_offsets[fixed_offsets.len - 1]);
                const dynoffs: Adyn = dynbase + simd.prefixScan(.Add, 1, dynasizesaligned);
                var offsets = offsets_init;
                @memcpy(offsets[NFIXED_FIELDS..], &dynoffs);
                offsets[NFIELDS - 1] = mem.alignForward(Size, offsets[NFIELDS - 1], ALIGN);

                if (!@inComptime())
                    std.debug.print(
                        \\
                        \\fields           {any}
                        \\dyn_field_sizes  {any}
                        \\dyn_field_aligns {any}
                        \\fixed_offsets    {any}
                        \\lengths          {any}
                        \\dyncounts        {any}
                        \\dynsizes         {any}
                        \\dynsizesa        {any}
                        \\dynoffs          {any}
                        \\offsets          {any}
                        \\
                    ,
                        .{ comptime meta.tags(Field), dyn_field_sizes, dyn_field_aligns, fixed_offsets, lengths, dyncounts, dynsizes, dynasizesaligned, dynoffs, offsets },
                    );

                return offsets;
            }

            inline fn offsetOfCached(field_idx: FieldIdx, offsets: anytype) Size {
                // this seems strange but codegen is better on zig 0.16 with than
                // `return if (field_idx == 0) 0 else offsets[field_idx -% 1]`.
                //
                // this version is smaller and branchless (no jumps).
                // note: wrapping subtraction omits unnecessary safe build panic code.
                const zero: Size = 0;
                return (if (field_idx == 0) &zero else &offsets[field_idx -% 1]).*;
            }

            pub fn fixedOffset(field: Field) Size {
                const field_idx = @intFromEnum(field);
                assert(field_idx < NFIXED_FIELDS);
                return offsetOfCached(field_idx, &fixed_offsets);
            }

            // TODO measure if it reduces code to remove 'comptime' from params such as
            // length_field and replace with length_field->layout_field lookup table.
            fn getLengthCached(self: *align(ALIGN) const @This(), comptime length_field: LengthField, offsets: *const A) Size {
                const field = @field(Field, @tagName(length_field));
                const Len = @FieldType(Layout, @tagName(length_field));
                const len: *const Len = @ptrCast(@alignCast(self.asBytes() + offsetOfCached(@intFromEnum(field), offsets)));
                return @intCast(len.*);
            }

            pub inline fn asBytes(self: *align(ALIGN) const @This()) [*]align(ALIGN) const u8 {
                return @ptrCast(self);
            }

            pub inline fn asBytesMut(self: *align(ALIGN) @This()) [*]align(ALIGN) u8 {
                return @ptrCast(self);
            }

            pub fn getLengthsCached(self: *align(ALIGN) const @This(), offsets: *const A) L {
                var result: L = undefined;
                inline for (length_field_ids, 0..) |i, j| {
                    const length_field: Field = @enumFromInt(i);
                    result[j] = self.getLength(@field(LengthField, @tagName(length_field)), offsets);
                }
                return result;
            }

            /// a constant single item pointer to the given field with cached offsets
            pub fn ptrCached(self: *align(ALIGN) const @This(), comptime field: Field, offsets: *const A) FieldPtr(field, .constant) {
                const field_idx = @intFromEnum(field);
                return @ptrCast(@alignCast(self.asBytes() + offsetOfCached(field_idx, offsets)));
            }

            pub fn ptrMutCached(self: *align(ALIGN) @This(), comptime field: Field, offsets: *const A) FieldPtr(field, .mutable) {
                return @constCast(self.ptrCached(field, offsets));
            }

            pub fn sliceCached(self: *align(ALIGN) const @This(), comptime field: Field, offsets: *const A) FieldSlice(field, .constant) {
                const len = self.getLengthCached(sorted_fields[@intFromEnum(field)].type.length_field, offsets);
                return self.ptrCached(field, offsets)[0..len];
            }

            pub fn sliceMutCached(self: *align(ALIGN) @This(), comptime field: Field, offsets: *const A) FieldSlice(field, .mutable) {
                return @constCast(self.sliceCached(field, offsets));
            }

            pub fn setLenFieldsCached(self: *align(ALIGN) @This(), lengths: Lengths, offsets: *const A) void {
                const ls: [length_field_ids.len]Size = @bitCast(lengths);
                inline for (length_field_ids, ls) |i, len| {
                    const length_field: Field = @enumFromInt(i);
                    self.ptrMutCached(length_field, offsets).* = @intCast(len);
                }
            }

            pub fn Buf(comptime capacity: Lengths) type {
                return [calcOffsets(capacity)[NFIELDS - 1]]u8;
            }

            pub fn initBufferAlignedCached(buf: []align(ALIGN) u8, lengths: Lengths, offsets: *const A) *align(ALIGN) @This() {
                assert(buf.len >= offsets[NFIELDS - 1]);
                const self: *align(ALIGN) @This() = @ptrCast(@alignCast(buf.ptr));
                self.setLenFieldsCached(lengths, offsets);
                return self;
            }

            pub fn createCached(allocator: mem.Allocator, lengths: Lengths, offsets: *const A) !*align(ALIGN) @This() {
                const bytes = try allocator.alignedAlloc(u8, alignment, offsets[NFIELDS - 1]);
                return initBufferAlignedCached(bytes, lengths, offsets);
            }

            pub fn destroyCached(self: *align(ALIGN) @This(), allocator: mem.Allocator, offsets: *const A) void {
                const bytes: [*]align(ALIGN) u8 = @ptrCast(@alignCast(self));
                allocator.free(bytes[0..offsets[NFIELDS - 1]]);
            }

            pub fn isFlexible(field_idx: FieldIdx) bool {
                return flexible_fields_mask & @as(Mask, 1) << @intCast(field_idx) != 0;
            }

            pub fn isLenField(field_idx: FieldIdx) bool {
                return length_fields_mask & @as(Mask, 1) << @intCast(field_idx) != 0;
            }

            fn AlignOf(field: StructField) comptime_int {
                const T = field.type;
                const field_ptr_align = if (isFlexibleArray(T))
                    @typeInfo(T.Pointer).pointer.alignment orelse
                        @alignOf(meta.Elem(T.Pointer))
                else
                    @alignOf(T);

                return if (field.alignment) |field_align|
                    @max(field_ptr_align, field_align)
                else
                    field_ptr_align;
            }

            fn ElementOf(comptime field: Field) type {
                const T = @FieldType(Layout, @tagName(field));
                return if (isFlexibleArray(T)) meta.Elem(T.Pointer) else T;
            }

            /// a Layout.<field> pointer type with given constness
            fn FieldPtr(comptime field: Field, comptime constness: Constness) type {
                const T = @FieldType(Sorted, @tagName(field));
                return if (isFlexibleArray(T)) ptr: {
                    const p = @typeInfo(T.Pointer).pointer;
                    break :ptr @Pointer(p.size, .{
                        .@"addrspace" = p.address_space,
                        .@"align" = p.alignment,
                        .@"allowzero" = p.is_allowzero,
                        .@"const" = constness == .constant,
                        .@"volatile" = p.is_volatile,
                    }, p.child, p.sentinel());
                } else if (constness == .constant)
                    *const T
                else
                    *T;
            }

            /// a Layout.<field> slice type with given constness
            fn FieldSlice(comptime field: Field, comptime constness: Constness) type {
                const F = @FieldType(Sorted, @tagName(field)).Pointer;
                const pinfo = @typeInfo(F).pointer;
                return @Pointer(.slice, .{
                    .@"addrspace" = pinfo.address_space,
                    .@"align" = pinfo.alignment,
                    .@"allowzero" = pinfo.is_allowzero,
                    .@"const" = constness == .constant,
                    .@"volatile" = pinfo.is_volatile,
                }, ElementOf(field), pinfo.sentinel());
            }
        },
        inline else => |_, t| comptime @panic("unsupported layout: " ++ @tagName(t)),
    };
}

inline fn selectFields(T: type, field: meta.FieldEnum(T), in: []const T) []const @FieldType(T, @tagName(field)) {
    const F = @FieldType(T, @tagName(field));
    var out: []const F = &.{};
    for (in) |i| out = out ++ .{@field(i, @tagName(field))};
    return out;
}

const IsFlexibleArray = struct {};

pub fn Array(
    T: type,
    /// an integer field from the parent Layout which determines as this field's
    /// capacity
    capacity_field: @EnumLiteral(),
) type {
    return extern struct {
        _: void align(@alignOf(T)),
        pub const Pointer = T;
        const length_field = capacity_field;
        const is_flexible_array = IsFlexibleArray{};
    };
}

inline fn isFlexibleArray(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "is_flexible_array") and
        @TypeOf(T.is_flexible_array) == IsFlexibleArray;
}

fn testPacket(Size: type) !void {
    const host = "ziglang.org";
    try testing.expectEqual(11, host.len);
    const buf_lens = 20;

    const PacketLayout = struct {
        buf_lens: u64, //                                   [0,8)
        host_len: u32, //                                   [8,12)
        write_buf: Array([*]u8, .buf_lens) align(32), //    [32,52) | buf_lens=20
        read_buf: Array([*]align(16) u8, .buf_lens), //     [64,84)
        host: Array([*]u8, .host_len), //                   [96,107) | host_len=11
    }; //                                                   128

    const Packet = Struct(PacketLayout, .{ .Size = Size });
    try testing.expectEqualSlices(Packet.Field, meta.tags(Packet.Field), &.{ .buf_lens, .host_len, .write_buf, .read_buf, .host });
    try testing.expectEqualSlices(Packet.FixedField, meta.tags(Packet.FixedField), &.{ .buf_lens, .host_len });
    try testing.expectEqualSlices(Packet.DynField, meta.tags(Packet.DynField), &.{ .write_buf, .read_buf, .host });
    try testing.expectEqualSlices(Packet.FieldIdx, &.{ 0, 1 }, Packet.length_field_ids);
    try testing.expectEqualSlices(Packet.FieldIdx, &.{ 2, 3, 4 }, Packet.flexible_field_ids);
    try testing.expectEqualSlices(Packet.Size, &.{ 1, 1, 1 }, &Packet.dyn_field_sizes);
    try testing.expectEqualSlices(Packet.Size, &.{ 32, 16, 1 }, &Packet.dyn_field_aligns);
    const lens = Packet.Lengths{ .host_len = host.len, .buf_lens = buf_lens };
    const offsets = Packet.calcOffsets(lens);
    try testing.expectEqualSlices(Packet.Size, &.{ 8, 32, 64, 96, 128 }, &offsets);
    try testing.expectEqual(0, Packet.fixedOffset(.buf_lens));
    try testing.expectEqual(8, Packet.fixedOffset(.host_len));
    const packet = try Packet.createCached(testing.allocator, lens, &offsets);
    defer packet.destroyCached(testing.allocator, &offsets);
    try testing.expectEqual(11, packet.ptrMutCached(.host_len, &offsets).*);
    try testing.expectEqual(20, packet.ptrCached(.buf_lens, &offsets).*);
    @memcpy(packet.sliceMutCached(.host, &offsets), host);
    try testing.expectEqualSlices(u8, host, packet.sliceCached(.host, &offsets));
    @memset(packet.sliceMutCached(.write_buf, &offsets), '0');
    @memset(packet.sliceMutCached(.read_buf, &offsets), '1');
    try testing.expectEqual('0', packet.sliceCached(.write_buf, &offsets)[0]);
    try testing.expectEqual('0', packet.sliceCached(.write_buf, &offsets)[buf_lens - 1]);
    try testing.expectEqual('1', packet.sliceCached(.read_buf, &offsets)[0]);
    try testing.expectEqual('1', packet.sliceCached(.read_buf, &offsets)[buf_lens - 1]);
}

test Struct {
    try testPacket(usize);
    try testPacket(u32);
    try testPacket(u16);
    try testPacket(u8);
}

test "misc layouts" {
    {
        const L = struct {
            len: u32 align(32), //          [0,4)
            stuff: Array([*]u8, .len), //   [4,15) | len=11
        }; //                               32
        const S = Struct(L, .{});
        const offsets = S.calcOffsets(.{ .len = 11 });
        try testing.expectEqualSlices(S.Size, &.{ 4, 32 }, &offsets);
    }

    {
        const L = struct {
            b: u64, //                  //  [0,8)
            a: u8, //                   //  [8,9)
            data: Array([*]u8, .a), //      [9,20)
        }; //                               24
        const S = Struct(L, .{});
        try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .a, .data });
        const offsets = S.calcOffsets(.{ .a = 11 });
        try testing.expectEqualSlices(S.Size, &.{ 8, 9, 24 }, &offsets);
    }
}

test "enum_len" {
    const L = struct { enum_len: enum(u8) { _ }, b: u64, data: Array([*]u8, .enum_len) };
    const S = Struct(L, .{});
    try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .enum_len, .data });
    const offsets = S.calcOffsets(.{ .enum_len = 11 });
    try testing.expectEqualSlices(S.Size, &.{ 8, 9, 24 }, &offsets);
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const meta = std.meta;
const simd = std.simd;
const math = std.math;
const assert = std.debug.assert;
const StructField = std.builtin.Type.StructField;
const builtin = @import("builtin");
const trace = @import("misc.zig").trace;
