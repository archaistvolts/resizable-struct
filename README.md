# flexible-struct

This library provides types for creating structs with runtime sized array fields.

## Docs

Documentation is hosted on GitHub pages: https://archaistvolts.github.io/flexible-struct/

## Usage

To create a structured slice, add a `pub const flexible_array_capacities` decl to your `Layout`.  You can have multiple
flexible arrays in a struct, and they can be mixed with regular fixed-size
fields wherever you want.

```zig
test {
    const Model = Struct(struct {
        capacity: u8,
        flexible: [*]u8 = undefined,
        computed: [*]u8 = undefined,
        pub const flexible_array_capacities = .{
            .flexible = .capacity,
            .computed = .computedLen,
        };
        pub fn computedLen(_: *const @This()) usize {
            return 68;
        }
    }, .{});
    const Layout = Model.Layout;
    const initlayout = Layout{ .capacity = 42 };
    var buf: Model.Buf(&initlayout) align(Model.ALIGN) = undefined;
    const layout = try Model.initBuffer(&buf, &initlayout);
    try testing.expectEqual(42, layout.slice(.flexible).len);
    try testing.expectEqual(42, layout.value(.capacity));
    try testing.expectEqual(42, layout.asLayout().capacity);
    try testing.expectEqual(42, Model.fromLayout(layout.asLayout()).slice(.flexible).len); // Self <-> Layout
    try testing.expectEqual(68, layout.slice(.computed).len);
}
```

## Acknowledgments
- https://tristanpemble.com/resizable-structs-in-zig
- https://github.com/tristanpemble/resizable-struct
- https://codeberg.org/ziglang/zig/pulls/30823

## License

MIT
