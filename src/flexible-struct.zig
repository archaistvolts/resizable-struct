pub const Options = struct {
    Size: type = usize,
    Mixin: type = void,
};

/// # About
///
/// a zero sized, single pointer layout library for auto layout (normal)
/// structs. struct fields are separated into 2 groups in memory: fixed followed
/// by flexible. each group is sorted by descending alignment. this makes fixed
/// field offsets statically known. and flexible field offsets can be calculated
/// in constant O(1) time with branchless SIMD instructions because there is no
/// padding between flexible fields.
///
/// the main cost of this layout is the extra padding before dynamic fields
/// compared with the resizable-struct layout where all fields are ordered with
/// descending alignment. the main benefit is constant time fixed and flexible
/// field access.
///
/// # Goals
///
/// high performance and small in binary size. the `*At()` API is meant
/// to steer users toward reusing cached offsets everywhere.
///
/// # Buffer layout
///```
/// [ fixed fields | fixed padding | dynamic fields | dyn padding ]
/// ^ ALIGN                        ^ DYN_ALIGN                    ^ ALIGN
///```
///
/// 1. buffer aligned to ALIGN
/// 1. fixed fields sorted by alignment desc
/// 1. padding to DYN_ALIGN
/// 1. dynamic fields sorted by alignment desc
/// 1. padding to ALIGN
///
///
/// # References
/// * https://tristanpemble.com/resizable-structs-in-zig/
/// * https://github.com/tristanpemble/resizable-struct
/// * https://codeberg.org/ziglang/zig/pulls/30823
///
pub fn Struct(Layout: type, options: Options) type {
    const layout_info = @typeInfo(Layout);
    if (layout_info != .@"struct")
        @compileError("Layout must be a struct");
    if (layout_info.@"struct".layout != .auto)
        @compileError("Packed and extern layouts are not supported");

    return struct {
        _: void align(ALIGN),
        m: options.Mixin,

        const layout_struct = switch (layout_info) {
            .@"struct" => |s| switch (s.layout) {
                .auto => s,
                .@"packed", .@"extern" => @compileError("Packed and extern layouts are not supported"),
            },
            else => @compileError("Layout must be a struct"),
        };

        const layout_fields = layout_struct.fields;
        pub const NFIELDS = layout_fields.len;
        pub const layout_infos = infos: {
            var max: mem.Alignment = .@"1";
            var types: [layout_fields.len]type = undefined;

            for (layout_fields, 0..) |field, i| {
                max = max.max(.fromByteUnits(AlignOf(field)));
                types[i] = if (isFlexibleArray(field.type))
                    field.type.Pointer
                else
                    field.type;
            }

            break :infos .{ max, @Struct(
                .auto,
                null,
                selectFields(StructField, .name, &sorted_fields)[0..NFIELDS],
                &types,
                sorted_field_attrs,
            ) };
        };
        /// Layout but with flexible array fields replaced by their Pointer types
        const alignment = layout_infos[0];
        pub const ALIGN = alignment.toByteUnits();

        pub const BLOCK_SIZE = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);
        pub const Size = options.Size;
        pub const SizeBlock = @Vector(@divExact(BLOCK_SIZE, @sizeOf(Size)), Size);
        const SIZE_BLOCK_LEN = @typeInfo(SizeBlock).vector.len;

        comptime {
            if (NDYN_FIELDS > SIZE_BLOCK_LEN)
                @compileError(std.fmt.comptimePrint( // TODO support multiple blocks
                    "expected at most {} dynamic field(s).  found {} dynamic fields: {any}",
                    .{ SIZE_BLOCK_LEN, NDYN_FIELDS, meta.tags(DynField) },
                ));
        }
        const fieldAttrs = (struct {
            fn fieldAttrs(comptime fields: []const StructField) [fields.len]StructField.Attributes {
                var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
                for (fields, &attrs) |f, *attr| attr.* = .{
                    .@"comptime" = f.is_comptime,
                    .@"align" = AlignOf(f),
                    .default_value_ptr = f.default_value_ptr,
                };
                return attrs;
            }
        }).fieldAttrs;

        const sorted_fields_info = info: {
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

            const nfixed_fields = for (0..NFIELDS) |i| {
                if (isFlexibleArray(fields[i].type))
                    break i;
            } else NFIELDS;
            mem.sort(StructField, fields[0..nfixed_fields], {}, Sort.lessThanAlign);
            mem.sort(StructField, fields[nfixed_fields..], {}, Sort.lessThanAlign);

            break :info .{ fields, nfixed_fields };
        };
        const sorted_fields = sorted_fields_info[0];
        const sorted_field_attrs = &fieldAttrs(&sorted_fields);
        pub const NFIXED_FIELDS = sorted_fields_info[1];
        pub const NDYN_FIELDS = NFIELDS - NFIXED_FIELDS;

        const field_infos = infos: {
            var dynsizes: DynSizes = undefined;
            var dynaligns: DynSizes = undefined;
            for (0..NDYN_FIELDS) |i| {
                const f = sorted_fields[i + NFIXED_FIELDS];
                dynaligns[i] = AlignOf(f);
                dynsizes[i] = @sizeOf(ElementOf(@field(Field, f.name)));
            }

            var cur: Size = 0;
            var fixedoffs: [NFIXED_FIELDS + 1]Size = undefined;
            fixedoffs[0] = 0;
            for (0..fixedoffs.len - 1) |fieldidx| {
                cur += @sizeOf(ElementOf(@enumFromInt(fieldidx)));
                cur = mem.alignForward(Size, cur, AlignOf(sorted_fields[fieldidx + 1])); // next field alignment
                fixedoffs[fieldidx + 1] = cur;
            }
            break :infos .{ dynsizes, dynaligns, fixedoffs };
        };
        const dyn_field_sizes = field_infos[0];
        const dyn_field_aligns = field_infos[1];
        const fixed_offsets = field_infos[2];

        /// a struct with fields from Layout in 2 groups (fixed and flexible)
        /// with each group sorted by alignment descending.
        pub const Sorted = @Struct(
            .auto,
            null,
            selectFields(StructField, .name, &sorted_fields)[0..NFIELDS],
            selectFields(StructField, .type, &sorted_fields)[0..NFIELDS],
            sorted_field_attrs,
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
        /// a struct of fixed fields from Sorted at statically knows offsets and
        /// previous to the first flexible field.
        pub const Fixed = @Struct(
            .@"extern",
            null,
            selectFields(StructField, .name, fixed_fields)[0..NFIXED_FIELDS],
            selectFields(StructField, .type, fixed_fields)[0..NFIXED_FIELDS],
            sorted_field_attrs[0..NFIXED_FIELDS],
        );
        pub const FixedField = meta.FieldEnum(Fixed);

        const dyn_fields = sorted_fields[NFIXED_FIELDS..];
        /// a struct of flexible fields from Sorted at dynamic offsets following
        /// fixed fields.
        pub const Dyn = @Struct(
            .auto,
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

        const dyn_alignmasks = dyn_field_aligns - @as(DynSizesV, @splat(1));
        pub const flexible_field_ids = ids: {
            var ids: []const Field = &.{};
            for (0..NFIELDS) |i| {
                if (isFlexible(@enumFromInt(i))) ids = ids ++ .{@as(Field, @enumFromInt(i))};
            }
            break :ids ids;
        };
        pub const length_field_ids = ids: {
            var ids: []const Field = &.{};
            for (0..NFIELDS) |i| {
                if (isLength(@enumFromInt(i))) ids = ids ++ .{@as(Field, @enumFromInt(i))};
            }
            break :ids ids;
        };
        pub const fixed_field_ids = ids: {
            var ids: []const Field = &.{};
            for (0..NFIELDS) |i| {
                if (!isFlexible(@enumFromInt(i))) ids = ids ++ .{@as(Field, @enumFromInt(i))};
            }
            break :ids ids;
        };

        const Self = @This();
        const Mask = @Int(.unsigned, NFIELDS);
        const LenSizes = [length_field_ids.len]Size;
        const DynSizesV = @Vector(NDYN_FIELDS, Size);
        const DynSizes = [NDYN_FIELDS]Size;

        pub fn isFlexible(field: Field) bool {
            return flexible_fields_mask & @as(Mask, 1) << @intCast(@intFromEnum(field)) != 0;
        }

        pub fn isLength(field: Field) bool {
            return length_fields_mask & @as(Mask, 1) << @intCast(@intFromEnum(field)) != 0;
        }

        fn dynCounts(lengths: Lengths) DynSizes {
            var counts: DynSizes = @splat(1);
            const lens: LenSizes = @bitCast(lengths);
            inline for (flexible_field_ids) |field| {
                const i = @intFromEnum(field);
                const j: LengthField = sorted_fields[i].type.length_field;
                counts[i - NFIXED_FIELDS] = lens[@intFromEnum(j)];
            }
            return counts;
        }

        /// an array of flexible field offsets plus total size aligned to ALIGN
        /// (without leading fixed offsets). the first offset is the offset of
        /// the _second_ flexible field. the first flexible offset is excluded
        /// because it is statically known.
        pub fn calcOffsets(lengths: Lengths) DynSizes {
            const dyncounts: DynSizesV = dynCounts(lengths);
            const dynsizes = dyncounts * dyn_field_sizes;
            const dynasizesaligned = (dynsizes + dyn_alignmasks) & ~dyn_alignmasks;
            const dynbase: DynSizesV = @splat(fixed_offsets[fixed_offsets.len - 1]);
            var offsets: DynSizes = dynbase + simd.prefixScan(.Add, 1, dynasizesaligned);
            offsets[NDYN_FIELDS - 1] = mem.alignForward(Size, offsets[NDYN_FIELDS - 1], ALIGN);

            if (false and !@inComptime())
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
                    .{ comptime meta.tags(Field), dyn_field_sizes, dyn_field_aligns, fixed_offsets, lengths, dyncounts, dynsizes, dynasizesaligned, offsets, offsets },
                );

            return offsets;
        }

        pub fn fixedOffset(field: Field) Size {
            const field_idx = @intFromEnum(field);
            assert(field_idx < NFIXED_FIELDS);
            return fixed_offsets[field_idx];
        }

        pub fn initFixedAt(self: *align(ALIGN) Self, fixed: Fixed, offsets: *const DynSizes) void {
            inline for (0..NFIXED_FIELDS) |i| {
                const field: Field = @enumFromInt(i);
                self.ptrMutAt(field, offsets).* = @field(fixed, @tagName(field));
            }
        }

        pub fn loadLength(self: *align(ALIGN) const Self, comptime field: Field) Size {
            const Len = @FieldType(Layout, @tagName(field));
            const len: *const Len = @ptrCast(@alignCast(self.asBytes() + fixedOffset(field)));
            return switch (@typeInfo(Len)) {
                .int => @intCast(len.*),
                .@"enum" => @intCast(@intFromEnum(len.*)),
                else => |tag| @compileError("TODO: support length type with tag '" ++ @tagName(tag) ++ "'"),
            };
        }

        pub fn sizeInBytesAt(offsets: *const DynSizes) Size {
            return offsets[NDYN_FIELDS - 1];
        }

        pub inline fn asBytes(self: *align(ALIGN) const Self) [*]align(ALIGN) const u8 {
            return @ptrCast(self);
        }

        pub inline fn asBytesMut(self: *align(ALIGN) Self) [*]align(ALIGN) u8 {
            return @ptrCast(self);
        }

        pub fn loadLengths(self: *align(ALIGN) const Self) Lengths {
            var lengths: LenSizes = undefined;
            inline for (length_field_ids, 0..) |i, j| {
                lengths[j] = self.loadLength(@enumFromInt(i));
            }
            return @bitCast(lengths);
        }

        pub fn loadOffsets(self: *align(ALIGN) const Self) DynSizes {
            return calcOffsets(self.loadLengths());
        }

        /// a constant single item pointer to the given fixed field.
        pub fn ptr(self: *align(ALIGN) const Self, comptime field: Field) FieldPtr(field, .constant) {
            return @ptrCast(@alignCast(@constCast(self.asBytes() + fixedOffset(field))));
        }

        /// a mutable single item pointer to the given fixed field
        pub fn ptrMut(self: *align(ALIGN) Self, comptime field: Field) FieldPtr(field, .mutable) {
            return @constCast(self.ptr(field));
        }

        /// a constant single item pointer to the given field with cached offsets
        pub fn ptrAt(self: *align(ALIGN) const Self, comptime field: Field, offsets: *const DynSizes) FieldPtr(field, .constant) {
            const field_idx = @intFromEnum(field);
            return @ptrCast(@alignCast(@constCast(self.asBytes() + if (field_idx < NFIXED_FIELDS)
                fixedOffset(field)
            else
                offsets[field_idx - NFIXED_FIELDS])));
        }

        /// a mutable single item pointer to the given field with cached offsets
        pub fn ptrMutAt(self: *align(ALIGN) Self, comptime field: Field, offsets: *const DynSizes) FieldPtr(field, .mutable) {
            return @constCast(self.ptrAt(field, offsets));
        }

        /// a slice of the given field and given length field with cached offsets
        pub fn sliceAt(self: *align(ALIGN) const Self, comptime field: Field, offsets: *const DynSizes) FieldSlice(field) {
            comptime assert(isFlexible(field));
            return self.sliceLenAt(field, sorted_fields[@intFromEnum(field)].type.length_field, offsets);
        }

        pub fn sliceLenAt(
            self: *align(ALIGN) const Self,
            comptime field: Field,
            comptime lenfield: Field,
            offsets: *const DynSizes,
        ) FieldSlice(field) {
            const len = self.loadLength(lenfield);
            return @ptrCast(self.ptrAt(field, offsets)[0..len]);
        }

        pub fn setLenFieldsAt(self: *align(ALIGN) Self, lengths: Lengths, offsets: *const DynSizes) void {
            const ls: [length_field_ids.len]Size = @bitCast(lengths);
            inline for (length_field_ids, ls) |length_field, len| {
                const Len = @FieldType(Layout, @tagName(length_field));
                self.ptrMutAt(length_field, offsets).* = switch (@typeInfo(Len)) {
                    .int => @intCast(len),
                    .@"enum" => @enumFromInt(len),
                    else => unreachable,
                };
            }
        }

        pub fn Buf(comptime capacity: Lengths) type {
            return [calcOffsets(capacity)[NDYN_FIELDS - 1]]u8;
        }

        pub fn initBufferAlignedAt(buf: []align(ALIGN) u8, lengths: Lengths, offsets: *const DynSizes) *align(ALIGN) Self {
            assert(buf.len >= offsets[NDYN_FIELDS - 1]);
            const self: *align(ALIGN) Self = @ptrCast(@alignCast(buf.ptr));
            self.setLenFieldsAt(lengths, offsets);
            return self;
        }

        pub fn createAt(allocator: mem.Allocator, lengths: Lengths, offsets: *const DynSizes) !*align(ALIGN) Self {
            const bytes = try allocator.alignedAlloc(u8, alignment, offsets[NDYN_FIELDS - 1]);
            return initBufferAlignedAt(bytes, lengths, offsets);
        }

        pub fn destroyAt(self: *align(ALIGN) Self, allocator: mem.Allocator, offsets: *const DynSizes) void {
            const bytes: [*]align(ALIGN) u8 = @ptrCast(@alignCast(self));
            allocator.free(bytes[0..offsets[NDYN_FIELDS - 1]]);
        }

        pub const CachedLayout = layout_infos[1];

        /// an array of flexible field offsets for a CachedLayout plus total
        /// size aligned to ALIGN (without leading fixed offsets). the first
        /// offset is the offset of the _second_ flexible field. the first
        /// flexible offset is excluded because it is statically known.
        pub fn calcCachedOffsets(lengths: Lengths) DynSizes {
            var all_offs: [NFIELDS]Size = undefined;
            var offs: DynSizes = undefined;
            var cur: [*]Size = &offs;
            inline for (meta.fields(CachedLayout), 0..) |cf, i| {
                const field = @field(Field, cf.name);
                const fieldi = @intFromEnum(field);
                const sf = sorted_fields[fieldi];
                const next_align = if (fieldi < NFIELDS - 1) AlignOf(sorted_fields[fieldi + 1]) else ALIGN;
                const zero: Size = 0;
                // encodes to cmov with no jmp or panic code on x86 with zig 0.16
                const prevoffs = (if (i == 0) &zero else &all_offs[i -% 1]).*;
                const size = @sizeOf(ElementOf(field));
                const len = if (comptime isFlexible(field))
                    @field(lengths, @tagName(sf.type.length_field)) * size
                else
                    1;
                all_offs[i] = mem.alignForward(Size, prevoffs + size * len, next_align);
                if (comptime isFlexible(field)) {
                    cur[0] = all_offs[i];
                    cur += 1;
                }
            }
            return offs;
        }

        /// build cached backed by buf from lengths and with cached offsets
        pub fn initCachedBufferAt(c: *CachedLayout, lengths: Lengths, buf: []align(ALIGN) u8, cachedoffs: *const DynSizes) void {
            assert(@as([*]u8, @ptrCast(c)) == buf.ptr - @sizeOf(CachedLayout));
            inline for (fixed_field_ids) |field| {
                const fieldname = @tagName(field);
                @field(c, fieldname) = if (comptime isLength(field))
                    @intCast(@field(lengths, fieldname))
                else switch (@typeInfo(@FieldType(CachedLayout, fieldname))) {
                    else => undefined,
                };
            }
            inline for (flexible_field_ids) |field| {
                const fieldname = @tagName(field);
                const fptr = buf.ptr + cachedoffs[@intFromEnum(field) - NFIXED_FIELDS];
                assert(mem.isAligned(@intFromPtr(fptr), AlignOf(sorted_fields[@intFromEnum(field)])));
                @field(c, fieldname) = @ptrCast(fptr);
            }
        }

        pub fn initCachedBuffer(buf: []align(ALIGN) u8, lengths: Lengths) *CachedLayout {
            const cachedoffs = calcCachedOffsets(lengths);
            const cached: *CachedLayout = mem.bytesAsValue(CachedLayout, buf);
            initCachedBufferAt(cached, lengths, buf[@sizeOf(CachedLayout)..], &cachedoffs);
            return cached;
        }

        pub fn createCached(allocator: mem.Allocator, lengths: Lengths) !*CachedLayout {
            const offs = calcCachedOffsets(lengths);
            const buf = try allocator.alignedAlloc(u8, alignment, offs[offs.len - 1]);
            const c = mem.bytesAsValue(CachedLayout, buf);
            initCachedBufferAt(c, lengths, buf[@sizeOf(CachedLayout)..], &offs);
            return c;
        }

        pub fn loadCachedLengths(c: *const CachedLayout) Lengths {
            var lengths: LenSizes = undefined;
            inline for (length_field_ids, 0..) |i, j| {
                lengths[j] = @field(c, @tagName(i));
            }
            return @bitCast(lengths);
        }

        pub fn destroyCached(c: *const CachedLayout, allocator: mem.Allocator) void {
            const lengths = loadCachedLengths(c);
            const offs = calcCachedOffsets(lengths);
            const bytes: [*]const u8 = @ptrCast(c);
            allocator.free(bytes[0..offs[offs.len - 1]]);
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

        const Constness = enum { constant, mutable };

        /// a Layout.<field> pointer type with given constness
        fn FieldPtr(comptime field: Field, comptime constness: Constness) type {
            const T = @FieldType(Sorted, @tagName(field));
            return if (isFlexibleArray(T)) ptr: {
                const p = @typeInfo(T.Pointer).pointer;
                break :ptr @Pointer(p.size, .{
                    .@"addrspace" = p.address_space,
                    .@"align" = AlignOf(sorted_fields[@intFromEnum(field)]),
                    .@"allowzero" = p.is_allowzero,
                    .@"const" = p.is_const,
                    .@"volatile" = p.is_volatile,
                }, p.child, p.sentinel());
            } else if (constness == .constant)
                *const T
            else
                *T;
        }

        /// a Layout.<field> slice type
        fn FieldSlice(comptime field: Field) type {
            const F = @FieldType(Sorted, @tagName(field)).Pointer;
            const pinfo = @typeInfo(F).pointer;
            return @Pointer(.slice, .{
                .@"addrspace" = pinfo.address_space,
                .@"align" = pinfo.alignment,
                .@"allowzero" = pinfo.is_allowzero,
                .@"const" = pinfo.is_const,
                .@"volatile" = pinfo.is_volatile,
            }, ElementOf(field), pinfo.sentinel());
        }
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
    return struct {
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

fn smokeTestLayout(
    L: type,
    comptime options: Options,
    comptime lens: Struct(L, options).Lengths,
    expected_offsets: *const Struct(L, options).DynSizes,
) !void {
    const S = Struct(L, options);
    const offsets = S.calcOffsets(lens);
    try testing.expectEqualSlices(S.Size, expected_offsets, &offsets);
    var buf: S.Buf(lens) align(S.ALIGN) = undefined;
    const s = S.initBufferAlignedAt(&buf, lens, &offsets);
    inline for (S.flexible_field_ids) |flexiblefield| {
        @memset(s.sliceAt(flexiblefield, &offsets), @intFromEnum(flexiblefield));
    }
    inline for (S.flexible_field_ids) |flexiblefield| {
        const slice = s.sliceAt(flexiblefield, &offsets);
        try testing.expectEqual(@intFromEnum(flexiblefield), slice[0]);
        try testing.expectEqual(@intFromEnum(flexiblefield), slice[slice.len - 1]);
    }
    const lensv: S.LenSizes = @bitCast(lens);
    inline for (S.length_field_ids, 0..) |lenfield, i| {
        try testing.expectEqual(lensv[i], s.loadLength(lenfield));
    }
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
    try testing.expectEqualSlices(Packet.Field, &.{ .buf_lens, .host_len }, Packet.length_field_ids);
    try testing.expectEqualSlices(Packet.Field, &.{ .write_buf, .read_buf, .host }, Packet.flexible_field_ids);
    try testing.expectEqualSlices(Packet.Size, &.{ 1, 1, 1 }, &Packet.dyn_field_sizes);
    try testing.expectEqualSlices(Packet.Size, &.{ 32, 16, 1 }, &Packet.dyn_field_aligns);
    const lens = Packet.Lengths{ .host_len = host.len, .buf_lens = buf_lens };
    try smokeTestLayout(PacketLayout, .{ .Size = Size }, lens, &.{ 64, 96, 128 });
    const offsets = Packet.calcOffsets(lens);
    try testing.expectEqual(0, Packet.fixedOffset(.buf_lens));
    try testing.expectEqual(8, Packet.fixedOffset(.host_len));
    const packet = try Packet.createAt(testing.allocator, lens, &offsets);
    defer packet.destroyAt(testing.allocator, &offsets);
    try testing.expectEqual(11, packet.ptrMutAt(.host_len, &offsets).*);
    try testing.expectEqual(20, packet.ptrAt(.buf_lens, &offsets).*);
    @memcpy(packet.sliceAt(.host, &offsets), host);
    try testing.expectEqualSlices(u8, host, packet.sliceAt(.host, &offsets));
    @memset(packet.sliceAt(.write_buf, &offsets), '0');
    @memset(packet.sliceAt(.read_buf, &offsets), '1');
    try testing.expectEqual('0', packet.sliceAt(.write_buf, &offsets)[0]);
    try testing.expectEqual('0', packet.sliceAt(.write_buf, &offsets)[buf_lens - 1]);
    try testing.expectEqual('1', packet.sliceAt(.read_buf, &offsets)[0]);
    try testing.expectEqual('1', packet.sliceAt(.read_buf, &offsets)[buf_lens - 1]);
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
        try smokeTestLayout(L, .{}, .{ .len = 11 }, &.{32});
    }
    {
        const L = struct {
            b: u64, //                  //  [0,8)
            a: u8, //                   //  [8,9)
            data: Array([*]u8, .a), //      [9,20)
        }; //                               24
        try smokeTestLayout(L, .{}, .{ .a = 11 }, &.{24});
        const S = Struct(L, .{});
        try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .a, .data });
    }
}

test "enum len" {
    const E = enum(u8) { _ };
    const L = struct { enum_len: E, b: u64, data: Array([*]u8, .enum_len) };
    const S = Struct(L, .{});
    try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .enum_len, .data });
    const lens: S.Lengths = .{ .enum_len = 11 };
    const offsets = comptime S.calcOffsets(lens);
    var buf: [offsets[offsets.len - 1]]u8 align(S.ALIGN) = undefined;
    const s = S.initBufferAlignedAt(&buf, lens, &offsets);
    try testing.expectEqual(@as(E, @enumFromInt(11)), s.ptrMutAt(.enum_len, &offsets).*);
    try smokeTestLayout(L, .{}, lens, &.{24});
}

test "sentinel ptr" {
    const L = struct { len: u8, data: Array([*:0]u8, .len) };
    const S = Struct(L, .{});
    const lens = S.Lengths{ .len = 11 };
    const s = try S.createCached(testing.allocator, lens);
    defer S.destroyCached(s, testing.allocator);
    try testing.expectEqual([*:0]u8, @TypeOf(s.data));
    const slice = s.data[0..s.len :0];
    try testing.expectEqual(11, s.len);
    @memset(slice, 'z');
    try testing.expectEqual('z', slice[0]);
    try testing.expectEqual('z', slice[10]);
    try testing.expectEqual([:0]u8, @TypeOf(slice));
    try testing.expectEqual(0, slice[11]);
    try smokeTestLayout(L, .{}, lens, &.{12});
}

test "Cached" {
    const L = struct { len: u8, fixed1: u8, data: Array([*]u8, .len) };
    const S = Struct(L, .{});
    const lens: S.Lengths = .{ .len = 11 };
    var buf: S.Buf(lens) align(S.ALIGN) = undefined;
    var s = S.initCachedBuffer(&buf, lens);
    try testing.expectEqual(11, s.len);
    const slice = s.data[0..s.len];
    @memset(slice, 'z');
    try testing.expectEqual('z', slice[0]);
    try testing.expectEqual('z', slice[10]);
    s.fixed1 = 10;
    try testing.expectEqual(10, s.fixed1);
    try smokeTestLayout(L, .{}, lens, &.{13});
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
