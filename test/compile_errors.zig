const tests = @import("tests.zig");
const builtin = @import("builtin");

pub fn addCases(cases: *tests.CompileErrorContext) void {
    cases.addTest("error in struct initializer doesn't crash the compiler",
        \\pub export fn entry() void {
        \\    const bitfield = struct {
        \\        e: u8,
        \\        e: u8,
        \\    };
        \\    var a = .{@sizeOf(bitfield)};
        \\}
    , &[_][]const u8{
        "tmp.zig:4:9: error: duplicate struct field: 'e'",
    });

    cases.addTest("repeated invalid field access to generic function returning type crashes compiler. #2655",
        \\pub fn A() type {
        \\    return Q;
        \\}
        \\test "1" {
        \\    _ = A().a;
        \\    _ = A().a;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: use of undeclared identifier 'Q'",
    });

    cases.add("bitCast to enum type",
        \\export fn entry() void {
        \\    const y = @bitCast(enum(u32) { a, b }, @as(u32, 3));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:24: error: cannot cast a value of type 'y'",
    });

    cases.add("comparing against undefined produces undefined value",
        \\export fn entry() void {
        \\    if (2 == undefined) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:2:11: error: use of undefined value here causes undefined behavior",
    });

    cases.add("comptime ptrcast of zero-sized type",
        \\fn foo() void {
        \\    const node: struct {} = undefined;
        \\    const vla_ptr = @ptrCast([*]const u8, &node);
        \\}
        \\comptime { foo(); }
    , &[_][]const u8{
        "tmp.zig:3:21: error: '*const struct:2:17' and '[*]const u8' do not have the same in-memory representation",
    });

    cases.add("slice sentinel mismatch",
        \\fn foo() [:0]u8 {
        \\    var x: []u8 = undefined;
        \\    return x;
        \\}
        \\comptime { _ = foo; }
    , &[_][]const u8{
        "tmp.zig:3:12: error: expected type '[:0]u8', found '[]u8'",
        "tmp.zig:3:12: note: destination pointer requires a terminating '0' sentinel",
    });

    cases.add("cmpxchg with float",
        \\export fn entry() void {
        \\    var x: f32 = 0;
        \\    _ = @cmpxchgWeak(f32, &x, 1, 2, .SeqCst, .SeqCst);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:22: error: expected integer, enum or pointer type, found 'f32'",
    });

    cases.add("atomicrmw with float op not .Xchg, .Add or .Sub",
        \\export fn entry() void {
        \\    var x: f32 = 0;
        \\    _ = @atomicRmw(f32, &x, .And, 2, .SeqCst);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:29: error: @atomicRmw with float only works with .Xchg, .Add and .Sub",
    });

    cases.add("intToPtr with misaligned address",
        \\pub fn main() void {
        \\    var y = @intToPtr([*]align(4) u8, 5);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:13: error: pointer type '[*]align(4) u8' requires aligned address",
    });

    cases.add("switch on extern enum missing else prong",
        \\const i = extern enum {
        \\    n = 0,
        \\    o = 2,
        \\    p = 4,
        \\    q = 4,
        \\};
        \\pub fn main() void {
        \\    var x = @intToEnum(i, 52);
        \\    switch (x) {
        \\        .n,
        \\        .o,
        \\        .p => unreachable,
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:9:5: error: switch on an extern enum must have an else prong",
    });

    cases.add("invalid float literal",
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    var bad_float :f32 = 0.0;
        \\    bad_float = bad_float + .20;
        \\    std.debug.assert(bad_float < 1.0);
        \\})
    , &[_][]const u8{
        "tmp.zig:5:29: error: invalid token: '.'",
    });

    cases.add("var args without c calling conv",
        \\fn foo(args: ...) void {}
        \\comptime {
        \\    _ = foo;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:8: error: var args only allowed in functions with C calling convention",
    });

    cases.add("comptime struct field, no init value",
        \\const Foo = struct {
        \\    comptime b: i32,
        \\};
        \\export fn entry() void {
        \\    var f: Foo = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: comptime struct field missing initialization value",
    });

    cases.add("bad usage of @call",
        \\export fn entry1() void {
        \\    @call(.{}, foo, {});
        \\}
        \\export fn entry2() void {
        \\    comptime @call(.{ .modifier = .never_inline }, foo, .{});
        \\}
        \\export fn entry3() void {
        \\    comptime @call(.{ .modifier = .never_tail }, foo, .{});
        \\}
        \\export fn entry4() void {
        \\    @call(.{ .modifier = .never_inline }, bar, .{});
        \\}
        \\export fn entry5(c: bool) void {
        \\    var baz = if (c) baz1 else baz2;
        \\    @call(.{ .modifier = .compile_time }, baz, .{});
        \\}
        \\fn foo() void {}
        \\inline fn bar() void {}
        \\fn baz1() void {}
        \\fn baz2() void {}
    , &[_][]const u8{
        "tmp.zig:2:21: error: expected tuple or struct, found 'void'",
        "tmp.zig:5:14: error: unable to perform 'never_inline' call at compile-time",
        "tmp.zig:8:14: error: unable to perform 'never_tail' call at compile-time",
        "tmp.zig:11:5: error: no-inline call of inline function",
        "tmp.zig:15:43: error: unable to evaluate constant expression",
    });

    cases.add("exported async function",
        \\export async fn foo() void {}
    , &[_][]const u8{
        "tmp.zig:1:1: error: exported function cannot be async",
    });

    cases.addExe("main missing name",
        \\pub fn (main) void {}
    , &[_][]const u8{
        "tmp.zig:1:5: error: missing function name",
    });

    cases.addCase(x: {
        var tc = cases.create("call with new stack on unsupported target",
            \\var buf: [10]u8 align(16) = undefined;
            \\export fn entry() void {
            \\    @call(.{.stack = &buf}, foo, .{});
            \\}
            \\fn foo() void {}
        , &[_][]const u8{
            "tmp.zig:3:5: error: target arch 'wasm32' does not support calling with a new stack",
        });
        tc.target = tests.Target{
            .Cross = tests.CrossTarget{
                .arch = .wasm32,
                .os = .wasi,
                .abi = .none,
            },
        };
        break :x tc;
    });

    // Note: One of the error messages here is backwards. It would be nice to fix, but that's not
    // going to stop me from merging this branch which fixes a bunch of other stuff.
    cases.add("incompatible sentinels",
        \\export fn entry1(ptr: [*:255]u8) [*:0]u8 {
        \\    return ptr;
        \\}
        \\export fn entry2(ptr: [*]u8) [*:0]u8 {
        \\    return ptr;
        \\}
        \\export fn entry3() void {
        \\    var array: [2:0]u8 = [_:255]u8{1, 2};
        \\}
        \\export fn entry4() void {
        \\    var array: [2:0]u8 = [_]u8{1, 2};
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: expected type '[*:0]u8', found '[*:255]u8'",
        "tmp.zig:2:12: note: destination pointer requires a terminating '0' sentinel, but source pointer has a terminating '255' sentinel",
        "tmp.zig:5:12: error: expected type '[*:0]u8', found '[*]u8'",
        "tmp.zig:5:12: note: destination pointer requires a terminating '0' sentinel",

        "tmp.zig:8:35: error: expected type '[2:255]u8', found '[2:0]u8'",
        "tmp.zig:8:35: note: destination array requires a terminating '255' sentinel, but source array has a terminating '0' sentinel",
        "tmp.zig:11:31: error: expected type '[2:0]u8', found '[2]u8'",
        "tmp.zig:11:31: note: destination array requires a terminating '0' sentinel",
    });

    cases.add("empty switch on an integer",
        \\export fn entry() void {
        \\    var x: u32 = 0;
        \\    switch(x) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: switch must handle all possibilities",
    });

    cases.add("incorrect return type",
        \\ pub export fn entry() void{
        \\     _ = foo();
        \\ }
        \\ const A = struct {
        \\     a: u32,
        \\ };
        \\ fn foo() A {
        \\     return bar();
        \\ }
        \\ const B = struct {
        \\     a: u32,
        \\ };
        \\ fn bar() B {
        \\     unreachable;
        \\ }
    , &[_][]const u8{
        "tmp.zig:8:16: error: expected type 'A', found 'B'",
    });

    cases.add("regression test #2980: base type u32 is not type checked properly when assigning a value within a struct",
        \\const Foo = struct {
        \\    ptr: ?*usize,
        \\    uval: u32,
        \\};
        \\fn get_uval(x: u32) !u32 {
        \\    return error.NotFound;
        \\}
        \\export fn entry() void {
        \\    const afoo = Foo{
        \\        .ptr = null,
        \\        .uval = get_uval(42),
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:11:25: error: expected type 'u32', found '@TypeOf(get_uval).ReturnType.ErrorSet!u32'",
    });

    cases.add("asigning to struct or union fields that are not optionals with a function that returns an optional",
        \\fn maybe(is: bool) ?u8 {
        \\    if (is) return @as(u8, 10) else return null;
        \\}
        \\const U = union {
        \\    Ye: u8,
        \\};
        \\const S = struct {
        \\    num: u8,
        \\};
        \\export fn entry() void {
        \\    var u = U{ .Ye = maybe(false) };
        \\    var s = S{ .num = maybe(false) };
        \\}
    , &[_][]const u8{
        "tmp.zig:11:27: error: expected type 'u8', found '?u8'",
    });

    cases.add("missing result type for phi node",
        \\fn foo() !void {
        \\    return anyerror.Foo;
        \\}
        \\export fn entry() void {
        \\    foo() catch 0;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:17: error: integer value 0 cannot be coerced to type 'void'",
    });

    cases.add("atomicrmw with enum op not .Xchg",
        \\export fn entry() void {
        \\    const E = enum(u8) {
        \\        a,
        \\        b,
        \\        c,
        \\        d,
        \\    };
        \\    var x: E = .a;
        \\    _ = @atomicRmw(E, &x, .Add, .b, .SeqCst);
        \\}
    , &[_][]const u8{
        "tmp.zig:9:27: error: @atomicRmw on enum only works with .Xchg",
    });

    cases.add("disallow coercion from non-null-terminated pointer to null-terminated pointer",
        \\extern fn puts(s: [*:0]const u8) c_int;
        \\pub fn main() void {
        \\    const no_zero_array = [_]u8{'h', 'e', 'l', 'l', 'o'};
        \\    const no_zero_ptr: [*]const u8 = &no_zero_array;
        \\    _ = puts(no_zero_ptr);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:14: error: expected type '[*:0]const u8', found '[*]const u8'",
    });

    cases.add("atomic orderings of atomicStore Acquire or AcqRel",
        \\export fn entry() void {
        \\    var x: u32 = 0;
        \\    @atomicStore(u32, &x, 1, .Acquire);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:30: error: @atomicStore atomic ordering must not be Acquire or AcqRel",
    });

    cases.add("missing const in slice with nested array type",
        \\const Geo3DTex2D = struct { vertices: [][2]f32 };
        \\pub fn getGeo3DTex2D() Geo3DTex2D {
        \\    return Geo3DTex2D{
        \\        .vertices = [_][2]f32{
        \\            [_]f32{ -0.5, -0.5},
        \\        },
        \\    };
        \\}
        \\export fn entry() void {
        \\    var geo_data = getGeo3DTex2D();
        \\}
    , &[_][]const u8{
        "tmp.zig:4:30: error: array literal requires address-of operator to coerce to slice type '[][2]f32'",
    });

    cases.add("slicing of global undefined pointer",
        \\var buf: *[1]u8 = undefined;
        \\export fn entry() void {
        \\    _ = buf[0..1];
        \\}
    , &[_][]const u8{
        "tmp.zig:3:12: error: non-zero length slice of undefined pointer",
    });

    cases.add("using invalid types in function call raises an error",
        \\const MenuEffect = enum {};
        \\fn func(effect: MenuEffect) void {}
        \\export fn entry() void {
        \\    func(MenuEffect.ThisDoesNotExist);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:20: error: enums must have 1 or more fields",
        "tmp.zig:4:20: note: referenced here",
    });

    cases.add("store vector pointer with unknown runtime index",
        \\export fn entry() void {
        \\    var v: @Vector(4, i32) = [_]i32{ 1, 5, 3, undefined };
        \\
        \\    var i: u32 = 0;
        \\    storev(&v[i], 42);
        \\}
        \\
        \\fn storev(ptr: var, val: i32) void {
        \\    ptr.* = val;
        \\}
    , &[_][]const u8{
        "tmp.zig:9:8: error: unable to determine vector element index of type '*align(16:0:4:?) i32",
    });

    cases.add("load vector pointer with unknown runtime index",
        \\export fn entry() void {
        \\    var v: @Vector(4, i32) = [_]i32{ 1, 5, 3, undefined };
        \\
        \\    var i: u32 = 0;
        \\    var x = loadv(&v[i]);
        \\}
        \\
        \\fn loadv(ptr: var) i32 {
        \\    return ptr.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:9:12: error: unable to determine vector element index of type '*align(16:0:4:?) i32",
    });

    cases.add("using an unknown len ptr type instead of array",
        \\const resolutions = [*][*]const u8{
        \\    "[320 240  ]",
        \\    null,
        \\};
        \\comptime {
        \\    _ = resolutions;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:21: error: expected array type or [_], found '[*][*]const u8'",
    });

    cases.add("comparison with error union and error value",
        \\export fn entry() void {
        \\    var number_or_error: anyerror!i32 = error.SomethingAwful;
        \\    _ = number_or_error == error.SomethingAwful;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:25: error: operator not allowed for type 'anyerror!i32'",
    });

    cases.add("switch with overlapping case ranges",
        \\export fn entry() void {
        \\    var q: u8 = 0;
        \\    switch (q) {
        \\        1...2 => {},
        \\        0...255 => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:9: error: duplicate switch value",
    });

    cases.add("invalid optional type in extern struct",
        \\const stroo = extern struct {
        \\    moo: ?[*c]u8,
        \\};
        \\export fn testf(fluff: *stroo) void {}
    , &[_][]const u8{
        "tmp.zig:2:5: error: extern structs cannot contain fields of type '?[*c]u8'",
    });

    cases.add("attempt to negate a non-integer, non-float or non-vector type",
        \\fn foo() anyerror!u32 {
        \\    return 1;
        \\}
        \\
        \\export fn entry() void {
        \\    const x = -foo();
        \\}
    , &[_][]const u8{
        "tmp.zig:6:15: error: negation of type 'anyerror!u32'",
    });

    cases.add("attempt to create 17 bit float type",
        \\const builtin = @import("builtin");
        \\comptime {
        \\    _ = @Type(builtin.TypeInfo { .Float = builtin.TypeInfo.Float { .bits = 17 } });
        \\}
    , &[_][]const u8{
        "tmp.zig:3:32: error: 17-bit float unsupported",
    });

    cases.add("wrong type for @Type",
        \\export fn entry() void {
        \\    _ = @Type(0);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected type 'std.builtin.TypeInfo', found 'comptime_int'",
    });

    cases.add("@Type with non-constant expression",
        \\const builtin = @import("builtin");
        \\var globalTypeInfo : builtin.TypeInfo = undefined;
        \\export fn entry() void {
        \\    _ = @Type(globalTypeInfo);
        \\}
    , &[_][]const u8{
        "tmp.zig:4:15: error: unable to evaluate constant expression",
    });

    cases.add("@Type with TypeInfo.Int",
        \\const builtin = @import("builtin");
        \\export fn entry() void {
        \\    _ = @Type(builtin.TypeInfo.Int {
        \\        .is_signed = true,
        \\        .bits = 8,
        \\    });
        \\}
    , &[_][]const u8{
        "tmp.zig:3:36: error: expected type 'std.builtin.TypeInfo', found 'std.builtin.Int'",
    });

    cases.add("Struct unavailable for @Type",
        \\export fn entry() void {
        \\    _ = @Type(@typeInfo(struct { }));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: @Type not availble for 'TypeInfo.Struct'",
    });

    cases.add("wrong type for result ptr to @asyncCall",
        \\export fn entry() void {
        \\    _ = async amain();
        \\}
        \\fn amain() i32 {
        \\    var frame: @Frame(foo) = undefined;
        \\    return await @asyncCall(&frame, false, foo);
        \\}
        \\fn foo() i32 {
        \\    return 1234;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:37: error: expected type '*i32', found 'bool'",
    });

    cases.add("shift amount has to be an integer type",
        \\export fn entry() void {
        \\    const x = 1 << &@as(u8, 10);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:21: error: shift amount has to be an integer type, but found '*u8'",
        "tmp.zig:2:17: note: referenced here",
    });

    cases.add("bit shifting only works on integer types",
        \\export fn entry() void {
        \\    const x = &@as(u8, 1) << 10;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:16: error: bit shifting operation expected integer type, found '*u8'",
        "tmp.zig:2:27: note: referenced here",
    });

    cases.add("struct depends on itself via optional field",
        \\const LhsExpr = struct {
        \\    rhsExpr: ?AstObject,
        \\};
        \\const AstObject = union {
        \\    lhsExpr: LhsExpr,
        \\};
        \\export fn entry() void {
        \\    const lhsExpr = LhsExpr{ .rhsExpr = null };
        \\    const obj = AstObject{ .lhsExpr = lhsExpr };
        \\}
    , &[_][]const u8{
        "tmp.zig:1:17: error: struct 'LhsExpr' depends on itself",
        "tmp.zig:5:5: note: while checking this field",
        "tmp.zig:2:5: note: while checking this field",
    });

    cases.add("alignment of enum field specified",
        \\const Number = enum {
        \\    a,
        \\    b align(i32),
        \\};
        \\export fn entry1() void {
        \\    var x: Number = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:13: error: structs and unions, not enums, support field alignment",
        "tmp.zig:1:16: note: consider 'union(enum)' here",
    });

    cases.add("bad alignment type",
        \\export fn entry1() void {
        \\    var x: []align(true) i32 = undefined;
        \\}
        \\export fn entry2() void {
        \\    var x: *align(@as(f64, 12.34)) i32 = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:20: error: expected type 'u29', found 'bool'",
        "tmp.zig:5:19: error: fractional component prevents float value 12.340000 from being casted to type 'u29'",
    });

    cases.addCase(x: {
        var tc = cases.create("variable in inline assembly template cannot be found",
            \\export fn entry() void {
            \\    var sp = asm volatile (
            \\        "mov %[foo], sp"
            \\        : [bar] "=r" (-> usize)
            \\    );
            \\}
        , &[_][]const u8{
            "tmp.zig:2:14: error: could not find 'foo' in the inputs or outputs",
        });
        tc.target = tests.Target{
            .Cross = tests.CrossTarget{
                .arch = .x86_64,
                .os = .linux,
                .abi = .gnu,
            },
        };
        break :x tc;
    });

    cases.add("indirect recursion of async functions detected",
        \\var frame: ?anyframe = null;
        \\
        \\export fn a() void {
        \\    _ = async rangeSum(10);
        \\    while (frame) |f| resume f;
        \\}
        \\
        \\fn rangeSum(x: i32) i32 {
        \\    suspend {
        \\        frame = @frame();
        \\    }
        \\    frame = null;
        \\
        \\    if (x == 0) return 0;
        \\    var child = rangeSumIndirect(x - 1);
        \\    return child + 1;
        \\}
        \\
        \\fn rangeSumIndirect(x: i32) i32 {
        \\    suspend {
        \\        frame = @frame();
        \\    }
        \\    frame = null;
        \\
        \\    if (x == 0) return 0;
        \\    var child = rangeSum(x - 1);
        \\    return child + 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:8:1: error: '@Frame(rangeSum)' depends on itself",
        "tmp.zig:15:33: note: when analyzing type '@Frame(rangeSum)' here",
        "tmp.zig:26:25: note: when analyzing type '@Frame(rangeSumIndirect)' here",
    });

    cases.add("non-async function pointer eventually is inferred to become async",
        \\export fn a() void {
        \\    var non_async_fn: fn () void = undefined;
        \\    non_async_fn = func;
        \\}
        \\fn func() void {
        \\    suspend;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:1: error: 'func' cannot be async",
        "tmp.zig:3:20: note: required to be non-async here",
        "tmp.zig:6:5: note: suspends here",
    });

    cases.add("bad alignment in @asyncCall",
        \\export fn entry() void {
        \\    var ptr: async fn () void = func;
        \\    var bytes: [64]u8 = undefined;
        \\    _ = @asyncCall(&bytes, {}, ptr);
        \\}
        \\async fn func() void {}
    , &[_][]const u8{
        "tmp.zig:4:21: error: expected type '[]align(16) u8', found '*[64]u8'",
    });

    cases.add("atomic orderings of fence Acquire or stricter",
        \\export fn entry() void {
        \\    @fence(.Monotonic);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: atomic ordering must be Acquire or stricter",
    });

    cases.add("bad alignment in implicit cast from array pointer to slice",
        \\export fn a() void {
        \\    var x: [10]u8 = undefined;
        \\    var y: []align(16) u8 = &x;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:30: error: expected type '[]align(16) u8', found '*[10]u8'",
    });

    cases.add("result location incompatibility mismatching handle_is_ptr (generic call)",
        \\export fn entry() void {
        \\    var damn = Container{
        \\        .not_optional = getOptional(i32),
        \\    };
        \\}
        \\pub fn getOptional(comptime T: type) ?T {
        \\    return 0;
        \\}
        \\pub const Container = struct {
        \\    not_optional: i32,
        \\};
    , &[_][]const u8{
        "tmp.zig:3:36: error: expected type 'i32', found '?i32'",
    });

    cases.add("result location incompatibility mismatching handle_is_ptr",
        \\export fn entry() void {
        \\    var damn = Container{
        \\        .not_optional = getOptional(),
        \\    };
        \\}
        \\pub fn getOptional() ?i32 {
        \\    return 0;
        \\}
        \\pub const Container = struct {
        \\    not_optional: i32,
        \\};
    , &[_][]const u8{
        "tmp.zig:3:36: error: expected type 'i32', found '?i32'",
    });

    cases.add("const frame cast to anyframe",
        \\export fn a() void {
        \\    const f = async func();
        \\    resume f;
        \\}
        \\export fn b() void {
        \\    const f = async func();
        \\    var x: anyframe = &f;
        \\}
        \\fn func() void {
        \\    suspend;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:12: error: expected type 'anyframe', found '*const @Frame(func)'",
        "tmp.zig:7:24: error: expected type 'anyframe', found '*const @Frame(func)'",
    });

    cases.add("prevent bad implicit casting of anyframe types",
        \\export fn a() void {
        \\    var x: anyframe = undefined;
        \\    var y: anyframe->i32 = x;
        \\}
        \\export fn b() void {
        \\    var x: i32 = undefined;
        \\    var y: anyframe->i32 = x;
        \\}
        \\export fn c() void {
        \\    var x: @Frame(func) = undefined;
        \\    var y: anyframe->i32 = &x;
        \\}
        \\fn func() void {}
    , &[_][]const u8{
        "tmp.zig:3:28: error: expected type 'anyframe->i32', found 'anyframe'",
        "tmp.zig:7:28: error: expected type 'anyframe->i32', found 'i32'",
        "tmp.zig:11:29: error: expected type 'anyframe->i32', found '*@Frame(func)'",
    });

    cases.add("wrong frame type used for async call",
        \\export fn entry() void {
        \\    var frame: @Frame(foo) = undefined;
        \\    frame = async bar();
        \\}
        \\fn foo() void {
        \\    suspend;
        \\}
        \\fn bar() void {
        \\    suspend;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: expected type '*@Frame(bar)', found '*@Frame(foo)'",
    });

    cases.add("@Frame() of generic function",
        \\export fn entry() void {
        \\    var frame: @Frame(func) = undefined;
        \\}
        \\fn func(comptime T: type) void {
        \\    var x: T = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:16: error: @Frame() of generic function",
    });

    cases.add("@frame() causes function to be async",
        \\export fn entry() void {
        \\    func();
        \\}
        \\fn func() void {
        \\    _ = @frame();
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: function with calling convention 'C' cannot be async",
        "tmp.zig:5:9: note: @frame() causes function to be async",
    });

    cases.add("invalid suspend in exported function",
        \\export fn entry() void {
        \\    var frame = async func();
        \\    var result = await frame;
        \\}
        \\fn func() void {
        \\    suspend;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: function with calling convention 'C' cannot be async",
        "tmp.zig:3:18: note: await here is a suspend point",
    });

    cases.add("async function indirectly depends on its own frame",
        \\export fn entry() void {
        \\    _ = async amain();
        \\}
        \\async fn amain() void {
        \\    other();
        \\}
        \\fn other() void {
        \\    var x: [@sizeOf(@Frame(amain))]u8 = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:1: error: unable to determine async function frame of 'amain'",
        "tmp.zig:5:10: note: analysis of function 'other' depends on the frame",
        "tmp.zig:8:13: note: referenced here",
    });

    cases.add("async function depends on its own frame",
        \\export fn entry() void {
        \\    _ = async amain();
        \\}
        \\async fn amain() void {
        \\    var x: [@sizeOf(@Frame(amain))]u8 = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:1: error: cannot resolve '@Frame(amain)': function not fully analyzed yet",
        "tmp.zig:5:13: note: referenced here",
    });

    cases.add("non async function pointer passed to @asyncCall",
        \\export fn entry() void {
        \\    var ptr = afunc;
        \\    var bytes: [100]u8 align(16) = undefined;
        \\    _ = @asyncCall(&bytes, {}, ptr);
        \\}
        \\fn afunc() void { }
    , &[_][]const u8{
        "tmp.zig:4:32: error: expected async function, found 'fn() void'",
    });

    cases.add("runtime-known async function called",
        \\export fn entry() void {
        \\    _ = async amain();
        \\}
        \\fn amain() void {
        \\    var ptr = afunc;
        \\    _ = ptr();
        \\}
        \\async fn afunc() void {}
    , &[_][]const u8{
        "tmp.zig:6:12: error: function is not comptime-known; @asyncCall required",
    });

    cases.add("runtime-known function called with async keyword",
        \\export fn entry() void {
        \\    var ptr = afunc;
        \\    _ = async ptr();
        \\}
        \\
        \\async fn afunc() void { }
    , &[_][]const u8{
        "tmp.zig:3:15: error: function is not comptime-known; @asyncCall required",
    });

    cases.add("function with ccc indirectly calling async function",
        \\export fn entry() void {
        \\    foo();
        \\}
        \\fn foo() void {
        \\    bar();
        \\}
        \\fn bar() void {
        \\    suspend;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: function with calling convention 'C' cannot be async",
        "tmp.zig:2:8: note: async function call here",
        "tmp.zig:5:8: note: async function call here",
        "tmp.zig:8:5: note: suspends here",
    });

    cases.add("capture group on switch prong with incompatible payload types",
        \\const Union = union(enum) {
        \\    A: usize,
        \\    B: isize,
        \\};
        \\comptime {
        \\    var u = Union{ .A = 8 };
        \\    switch (u) {
        \\        .A, .B => |e| unreachable,
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:8:20: error: capture group with incompatible types",
        "tmp.zig:8:9: note: type 'usize' here",
        "tmp.zig:8:13: note: type 'isize' here",
    });

    cases.add("wrong type to @hasField",
        \\export fn entry() bool {
        \\    return @hasField(i32, "hi");
        \\}
    , &[_][]const u8{
        "tmp.zig:2:22: error: type 'i32' does not support @hasField",
    });

    cases.add("slice passed as array init type with elems",
        \\export fn entry() void {
        \\    const x = []u8{1, 2};
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: array literal requires address-of operator to coerce to slice type '[]u8'",
    });

    cases.add("slice passed as array init type",
        \\export fn entry() void {
        \\    const x = []u8{};
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: array literal requires address-of operator to coerce to slice type '[]u8'",
    });

    cases.add("inferred array size invalid here",
        \\export fn entry() void {
        \\    const x = [_]u8;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: inferred array size invalid here",
    });

    cases.add("initializing array with struct syntax",
        \\export fn entry() void {
        \\    const x = [_]u8{ .y = 2 };
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: initializing array with struct syntax",
    });

    cases.add("compile error in struct init expression",
        \\const Foo = struct {
        \\    a: i32 = crap,
        \\    b: i32,
        \\};
        \\export fn entry() void {
        \\    var x = Foo{
        \\        .b = 5,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:2:14: error: use of undeclared identifier 'crap'",
    });

    cases.add("undefined as field type is rejected",
        \\const Foo = struct {
        \\    a: undefined,
        \\};
        \\export fn entry1() void {
        \\    const foo: Foo = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:8: error: use of undefined value here causes undefined behavior",
    });

    cases.add("@hasDecl with non-container",
        \\export fn entry() void {
        \\    _ = @hasDecl(i32, "hi");
        \\}
    , &[_][]const u8{
        "tmp.zig:2:18: error: expected struct, enum, or union; found 'i32'",
    });

    cases.add("field access of slices",
        \\export fn entry() void {
        \\    var slice: []i32 = undefined;
        \\    const info = @TypeOf(slice).unknown;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:32: error: type '[]i32' does not support field access",
    });

    cases.add("peer cast then implicit cast const pointer to mutable C pointer",
        \\export fn func() void {
        \\    var strValue: [*c]u8 = undefined;
        \\    strValue = strValue orelse "";
        \\}
    , &[_][]const u8{
        "tmp.zig:3:32: error: expected type '[*c]u8', found '*const [0:0]u8'",
        "tmp.zig:3:32: note: cast discards const qualifier",
    });

    cases.add("overflow in enum value allocation",
        \\const Moo = enum(u8) {
        \\    Last = 255,
        \\    Over,
        \\};
        \\pub fn main() void {
        \\  var y = Moo.Last;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: enumeration value 256 too large for type 'u8'",
    });

    cases.add("attempt to cast enum literal to error",
        \\export fn entry() void {
        \\    switch (error.Hi) {
        \\        .Hi => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: expected type 'error{Hi}', found '(enum literal)'",
    });

    cases.add("@sizeOf bad type",
        \\export fn entry() usize {
        \\    return @sizeOf(@TypeOf(null));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:20: error: no size available for type '(null)'",
    });

    cases.add("generic function where return type is self-referenced",
        \\fn Foo(comptime T: type) Foo(T) {
        \\    return struct{ x: T };
        \\}
        \\export fn entry() void {
        \\    const t = Foo(u32) {
        \\      .x = 1
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:1:29: error: evaluation exceeded 1000 backwards branches",
        "tmp.zig:5:18: note: referenced here",
    });

    cases.add("@ptrToInt 0 to non optional pointer",
        \\export fn entry() void {
        \\    var b = @intToPtr(*i32, 0);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:13: error: pointer type '*i32' does not allow address zero",
    });

    cases.add("cast enum literal to enum but it doesn't match",
        \\const Foo = enum {
        \\    a,
        \\    b,
        \\};
        \\export fn entry() void {
        \\    const x: Foo = .c;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:20: error: enum 'Foo' has no field named 'c'",
        "tmp.zig:1:13: note: 'Foo' declared here",
    });

    cases.add("discarding error value",
        \\export fn entry() void {
        \\    _ = foo();
        \\}
        \\fn foo() !void {
        \\    return error.OutOfMemory;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: error is discarded",
    });

    cases.add("volatile on global assembly",
        \\comptime {
        \\    asm volatile ("");
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: volatile is meaningless on global assembly",
    });

    cases.add("invalid multiple dereferences",
        \\export fn a() void {
        \\    var box = Box{ .field = 0 };
        \\    box.*.field = 1;
        \\}
        \\export fn b() void {
        \\    var box = Box{ .field = 0 };
        \\    var boxPtr = &box;
        \\    boxPtr.*.*.field = 1;
        \\}
        \\pub const Box = struct {
        \\    field: i32,
        \\};
    , &[_][]const u8{
        "tmp.zig:3:8: error: attempt to dereference non-pointer type 'Box'",
        "tmp.zig:8:13: error: attempt to dereference non-pointer type 'Box'",
    });

    cases.add("usingnamespace with wrong type",
        \\usingnamespace void;
    , &[_][]const u8{
        "tmp.zig:1:1: error: expected struct, enum, or union; found 'void'",
    });

    cases.add("ignored expression in while continuation",
        \\export fn a() void {
        \\    while (true) : (bad()) {}
        \\}
        \\export fn b() void {
        \\    var x: anyerror!i32 = 1234;
        \\    while (x) |_| : (bad()) {} else |_| {}
        \\}
        \\export fn c() void {
        \\    var x: ?i32 = 1234;
        \\    while (x) |_| : (bad()) {}
        \\}
        \\fn bad() anyerror!void {
        \\    return error.Bad;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:24: error: expression value is ignored",
        "tmp.zig:6:25: error: expression value is ignored",
        "tmp.zig:10:25: error: expression value is ignored",
    });

    cases.add("empty while loop body",
        \\export fn a() void {
        \\    while(true);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:16: error: expected loop body, found ';'",
    });

    cases.add("empty for loop body",
        \\export fn a() void {
        \\    for(undefined) |x|;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:23: error: expected loop body, found ';'",
    });

    cases.add("empty if body",
        \\export fn a() void {
        \\    if(true);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:13: error: expected if body, found ';'",
    });

    cases.add("import outside package path",
        \\comptime{
        \\    _ = @import("../a.zig");
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: import of file outside package path: '../a.zig'",
    });

    cases.add("bogus compile var",
        \\const x = @import("builtin").bogus;
        \\export fn entry() usize { return @sizeOf(@TypeOf(x)); }
    , &[_][]const u8{
        "tmp.zig:1:29: error: container 'builtin' has no member called 'bogus'",
    });

    cases.add("wrong panic signature, runtime function",
        \\test "" {}
        \\
        \\pub fn panic() void {}
        \\
    , &[_][]const u8{
        "error: expected type 'fn([]const u8, ?*std.builtin.StackTrace) noreturn', found 'fn() void'",
    });

    cases.add("wrong panic signature, generic function",
        \\pub fn panic(comptime msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
        \\    while (true) {}
        \\}
    , &[_][]const u8{
        "error: expected type 'fn([]const u8, ?*std.builtin.StackTrace) noreturn', found 'fn([]const u8,var) var'",
        "note: only one of the functions is generic",
    });

    cases.add("direct struct loop",
        \\const A = struct { a : A, };
        \\export fn entry() usize { return @sizeOf(A); }
    , &[_][]const u8{
        "tmp.zig:1:11: error: struct 'A' depends on itself",
    });

    cases.add("indirect struct loop",
        \\const A = struct { b : B, };
        \\const B = struct { c : C, };
        \\const C = struct { a : A, };
        \\export fn entry() usize { return @sizeOf(A); }
    , &[_][]const u8{
        "tmp.zig:1:11: error: struct 'A' depends on itself",
    });

    cases.add("instantiating an undefined value for an invalid struct that contains itself",
        \\const Foo = struct {
        \\    x: Foo,
        \\};
        \\
        \\var foo: Foo = undefined;
        \\
        \\export fn entry() usize {
        \\    return @sizeOf(@TypeOf(foo.x));
        \\}
    , &[_][]const u8{
        "tmp.zig:1:13: error: struct 'Foo' depends on itself",
        "tmp.zig:8:28: note: referenced here",
    });

    cases.add("@typeInfo causing depend on itself compile error",
        \\const start = struct {
        \\    fn crash() bug() {
        \\        return bug;
        \\    }
        \\};
        \\fn bug() void {
        \\    _ = @typeInfo(start).Struct;
        \\}
        \\export fn entry() void {
        \\    var boom = start.crash();
        \\}
    , &[_][]const u8{
        "tmp.zig:7:9: error: dependency loop detected",
        "tmp.zig:2:19: note: referenced here",
        "tmp.zig:10:21: note: referenced here",
    });

    cases.add("enum field value references enum",
        \\pub const Foo = extern enum {
        \\    A = Foo.B,
        \\    C = D,
        \\};
        \\export fn entry() void {
        \\    var s: Foo = Foo.E;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:17: error: enum 'Foo' depends on itself",
    });

    cases.add("top level decl dependency loop",
        \\const a : @TypeOf(b) = 0;
        \\const b : @TypeOf(a) = 0;
        \\export fn entry() void {
        \\    const c = a + b;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:19: error: dependency loop detected",
        "tmp.zig:1:19: note: referenced here",
        "tmp.zig:4:15: note: referenced here",
    });

    cases.addTest("not an enum type",
        \\export fn entry() void {
        \\    var self: Error = undefined;
        \\    switch (self) {
        \\        InvalidToken => |x| return x.token,
        \\        ExpectedVarDeclOrFn => |x| return x.token,
        \\    }
        \\}
        \\const Error = union(enum) {
        \\    A: InvalidToken,
        \\    B: ExpectedVarDeclOrFn,
        \\};
        \\const InvalidToken = struct {};
        \\const ExpectedVarDeclOrFn = struct {};
    , &[_][]const u8{
        "tmp.zig:4:9: error: expected type '@TagType(Error)', found 'type'",
    });

    cases.addTest("binary OR operator on error sets",
        \\pub const A = error.A;
        \\pub const AB = A | error.B;
        \\export fn entry() void {
        \\    var x: AB = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:18: error: invalid operands to binary expression: 'error{A}' and 'error{B}'",
    });

    if (builtin.os == builtin.Os.linux) {
        cases.addTest("implicit dependency on libc",
            \\extern "c" fn exit(u8) void;
            \\export fn entry() void {
            \\    exit(0);
            \\}
        , &[_][]const u8{
            "tmp.zig:3:5: error: dependency on library c must be explicitly specified in the build command",
        });

        cases.addTest("libc headers note",
            \\const c = @cImport(@cInclude("stdio.h"));
            \\export fn entry() void {
            \\    _ = c.printf("hello, world!\n");
            \\}
        , &[_][]const u8{
            "tmp.zig:1:11: error: C import failed",
            "tmp.zig:1:11: note: libc headers not available; compilation does not link against libc",
        });
    }

    cases.addTest("comptime vector overflow shows the index",
        \\comptime {
        \\    var a: @Vector(4, u8) = [_]u8{ 1, 2, 255, 4 };
        \\    var b: @Vector(4, u8) = [_]u8{ 5, 6, 1, 8 };
        \\    var x = a + b;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:15: error: operation caused overflow",
        "tmp.zig:4:15: note: when computing vector element at index 2",
    });

    cases.addTest("packed struct with fields of not allowed types",
        \\const A = packed struct {
        \\    x: anyerror,
        \\};
        \\const B = packed struct {
        \\    x: [2]u24,
        \\};
        \\const C = packed struct {
        \\    x: [1]anyerror,
        \\};
        \\const D = packed struct {
        \\    x: [1]S,
        \\};
        \\const E = packed struct {
        \\    x: [1]U,
        \\};
        \\const F = packed struct {
        \\    x: ?anyerror,
        \\};
        \\const G = packed struct {
        \\    x: Enum,
        \\};
        \\export fn entry1() void {
        \\    var a: A = undefined;
        \\}
        \\export fn entry2() void {
        \\    var b: B = undefined;
        \\}
        \\export fn entry3() void {
        \\    var r: C = undefined;
        \\}
        \\export fn entry4() void {
        \\    var d: D = undefined;
        \\}
        \\export fn entry5() void {
        \\    var e: E = undefined;
        \\}
        \\export fn entry6() void {
        \\    var f: F = undefined;
        \\}
        \\export fn entry7() void {
        \\    var g: G = undefined;
        \\}
        \\const S = struct {
        \\    x: i32,
        \\};
        \\const U = struct {
        \\    A: i32,
        \\    B: u32,
        \\};
        \\const Enum = enum {
        \\    A,
        \\    B,
        \\};
    , &[_][]const u8{
        "tmp.zig:2:5: error: type 'anyerror' not allowed in packed struct; no guaranteed in-memory representation",
        "tmp.zig:5:5: error: array of 'u24' not allowed in packed struct due to padding bits",
        "tmp.zig:8:5: error: type 'anyerror' not allowed in packed struct; no guaranteed in-memory representation",
        "tmp.zig:11:5: error: non-packed, non-extern struct 'S' not allowed in packed struct; no guaranteed in-memory representation",
        "tmp.zig:14:5: error: non-packed, non-extern struct 'U' not allowed in packed struct; no guaranteed in-memory representation",
        "tmp.zig:17:5: error: type '?anyerror' not allowed in packed struct; no guaranteed in-memory representation",
        "tmp.zig:20:5: error: type 'Enum' not allowed in packed struct; no guaranteed in-memory representation",
        "tmp.zig:50:14: note: enum declaration does not specify an integer tag type",
    });

    cases.addCase(x: {
        var tc = cases.create("deduplicate undeclared identifier",
            \\export fn a() void {
            \\    x += 1;
            \\}
            \\export fn b() void {
            \\    x += 1;
            \\}
        , &[_][]const u8{
            "tmp.zig:2:5: error: use of undeclared identifier 'x'",
        });
        tc.expect_exact = true;
        break :x tc;
    });

    cases.add("export generic function",
        \\export fn foo(num: var) i32 {
        \\    return 0;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:15: error: parameter of type 'var' not allowed in function with calling convention 'C'",
    });

    cases.add("C pointer to c_void",
        \\export fn a() void {
        \\    var x: *c_void = undefined;
        \\    var y: [*c]c_void = x;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:16: error: C pointers cannot point opaque types",
    });

    cases.add("directly embedding opaque type in struct and union",
        \\const O = @OpaqueType();
        \\const Foo = struct {
        \\    o: O,
        \\};
        \\const Bar = union {
        \\    One: i32,
        \\    Two: O,
        \\};
        \\export fn a() void {
        \\    var foo: Foo = undefined;
        \\}
        \\export fn b() void {
        \\    var bar: Bar = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:8: error: opaque types have unknown size and therefore cannot be directly embedded in structs",
        "tmp.zig:7:10: error: opaque types have unknown size and therefore cannot be directly embedded in unions",
    });

    cases.add("implicit cast between C pointer and Zig pointer - bad const/align/child",
        \\export fn a() void {
        \\    var x: [*c]u8 = undefined;
        \\    var y: *align(4) u8 = x;
        \\}
        \\export fn b() void {
        \\    var x: [*c]const u8 = undefined;
        \\    var y: *u8 = x;
        \\}
        \\export fn c() void {
        \\    var x: [*c]u8 = undefined;
        \\    var y: *u32 = x;
        \\}
        \\export fn d() void {
        \\    var y: *align(1) u32 = undefined;
        \\    var x: [*c]u32 = y;
        \\}
        \\export fn e() void {
        \\    var y: *const u8 = undefined;
        \\    var x: [*c]u8 = y;
        \\}
        \\export fn f() void {
        \\    var y: *u8 = undefined;
        \\    var x: [*c]u32 = y;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:27: error: cast increases pointer alignment",
        "tmp.zig:7:18: error: cast discards const qualifier",
        "tmp.zig:11:19: error: expected type '*u32', found '[*c]u8'",
        "tmp.zig:11:19: note: pointer type child 'u8' cannot cast into pointer type child 'u32'",
        "tmp.zig:15:22: error: cast increases pointer alignment",
        "tmp.zig:19:21: error: cast discards const qualifier",
        "tmp.zig:23:22: error: expected type '[*c]u32', found '*u8'",
    });

    cases.add("implicit casting null c pointer to zig pointer",
        \\comptime {
        \\    var c_ptr: [*c]u8 = 0;
        \\    var zig_ptr: *u8 = c_ptr;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:24: error: null pointer casted to type '*u8'",
    });

    cases.add("implicit casting undefined c pointer to zig pointer",
        \\comptime {
        \\    var c_ptr: [*c]u8 = undefined;
        \\    var zig_ptr: *u8 = c_ptr;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:24: error: use of undefined value here causes undefined behavior",
    });

    cases.add("implicit casting C pointers which would mess up null semantics",
        \\export fn entry() void {
        \\    var slice: []const u8 = "aoeu";
        \\    const opt_many_ptr: [*]const u8 = slice.ptr;
        \\    var ptr_opt_many_ptr = &opt_many_ptr;
        \\    var c_ptr: [*c]const [*c]const u8 = ptr_opt_many_ptr;
        \\    ptr_opt_many_ptr = c_ptr;
        \\}
        \\export fn entry2() void {
        \\    var buf: [4]u8 = "aoeu".*;
        \\    var slice: []u8 = &buf;
        \\    var opt_many_ptr: [*]u8 = slice.ptr;
        \\    var ptr_opt_many_ptr = &opt_many_ptr;
        \\    var c_ptr: [*c][*c]const u8 = ptr_opt_many_ptr;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:24: error: expected type '*const [*]const u8', found '[*c]const [*c]const u8'",
        "tmp.zig:6:24: note: pointer type child '[*c]const u8' cannot cast into pointer type child '[*]const u8'",
        "tmp.zig:6:24: note: '[*c]const u8' could have null values which are illegal in type '[*]const u8'",
        "tmp.zig:13:35: error: expected type '[*c][*c]const u8', found '*[*]u8'",
        "tmp.zig:13:35: note: pointer type child '[*]u8' cannot cast into pointer type child '[*c]const u8'",
        "tmp.zig:13:35: note: mutable '[*c]const u8' allows illegal null values stored to type '[*]u8'",
    });

    cases.add("implicit casting too big integers to C pointers",
        \\export fn a() void {
        \\    var ptr: [*c]u8 = (1 << 64) + 1;
        \\}
        \\export fn b() void {
        \\    var x: @IntType(false, 65) = 0x1234;
        \\    var ptr: [*c]u8 = x;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:33: error: integer value 18446744073709551617 cannot be coerced to type 'usize'",
        "tmp.zig:6:23: error: integer type 'u65' too big for implicit @intToPtr to type '[*c]u8'",
    });

    cases.add("C pointer pointing to non C ABI compatible type or has align attr",
        \\const Foo = struct {};
        \\export fn a() void {
        \\    const T = [*c]Foo;
        \\    var t: T = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:19: error: C pointers cannot point to non-C-ABI-compatible type 'Foo'",
    });

    cases.addCase(x: {
        var tc = cases.create("compile log statement warning deduplication in generic fn",
            \\export fn entry() void {
            \\    inner(1);
            \\    inner(2);
            \\}
            \\fn inner(comptime n: usize) void {
            \\    comptime var i = 0;
            \\    inline while (i < n) : (i += 1) { @compileLog("!@#$"); }
            \\}
        , &[_][]const u8{
            "tmp.zig:7:39: error: found compile log statement",
        });
        tc.expect_exact = true;
        break :x tc;
    });

    cases.add("assign to invalid dereference",
        \\export fn entry() void {
        \\    'a'.* = 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:8: error: attempt to dereference non-pointer type 'comptime_int'",
    });

    cases.add("take slice of invalid dereference",
        \\export fn entry() void {
        \\    const x = 'a'.*[0..];
        \\}
    , &[_][]const u8{
        "tmp.zig:2:18: error: attempt to dereference non-pointer type 'comptime_int'",
    });

    cases.add("@truncate undefined value",
        \\export fn entry() void {
        \\    var z = @truncate(u8, @as(u16, undefined));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:27: error: use of undefined value here causes undefined behavior",
    });

    cases.addTest("return invalid type from test",
        \\test "example" { return 1; }
    , &[_][]const u8{
        "tmp.zig:1:25: error: integer value 1 cannot be coerced to type 'void'",
    });

    cases.add("threadlocal qualifier on const",
        \\threadlocal const x: i32 = 1234;
        \\export fn entry() i32 {
        \\    return x;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:13: error: threadlocal variable cannot be constant",
    });

    cases.add("@bitCast same size but bit count mismatch",
        \\export fn entry(byte: u8) void {
        \\    var oops = @bitCast(u7, byte);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:25: error: destination type 'u7' has 7 bits but source type 'u8' has 8 bits",
    });

    cases.add("@bitCast with different sizes inside an expression",
        \\export fn entry() void {
        \\    var foo = (@bitCast(u8, @as(f32, 1.0)) == 0xf);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:25: error: destination type 'u8' has size 1 but source type 'f32' has size 4",
    });

    cases.add("attempted `&&`",
        \\export fn entry(a: bool, b: bool) i32 {
        \\    if (a && b) {
        \\        return 1234;
        \\    }
        \\    return 5678;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: `&&` is invalid. Note that `and` is boolean AND",
    });

    cases.add("attempted `||` on boolean values",
        \\export fn entry(a: bool, b: bool) i32 {
        \\    if (a || b) {
        \\        return 1234;
        \\    }
        \\    return 5678;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: expected error set type, found 'bool'",
        "tmp.zig:2:11: note: `||` merges error sets; `or` performs boolean OR",
    });

    cases.add("compile log a pointer to an opaque value",
        \\export fn entry() void {
        \\    @compileLog(@ptrCast(*const c_void, &entry));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: found compile log statement",
    });

    cases.add("duplicate boolean switch value",
        \\comptime {
        \\    const x = switch (true) {
        \\        true => false,
        \\        false => true,
        \\        true => false,
        \\    };
        \\}
        \\comptime {
        \\    const x = switch (true) {
        \\        false => true,
        \\        true => false,
        \\        false => true,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:5:9: error: duplicate switch value",
        "tmp.zig:12:9: error: duplicate switch value",
    });

    cases.add("missing boolean switch value",
        \\comptime {
        \\    const x = switch (true) {
        \\        true => false,
        \\    };
        \\}
        \\comptime {
        \\    const x = switch (true) {
        \\        false => true,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: switch must handle all possibilities",
        "tmp.zig:7:15: error: switch must handle all possibilities",
    });

    cases.add("reading past end of pointer casted array",
        \\comptime {
        \\    const array: [4]u8 = "aoeu".*;
        \\    const slice = array[1..];
        \\    const int_ptr = @ptrCast(*const u24, slice.ptr);
        \\    const deref = int_ptr.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:26: error: attempt to read 4 bytes from [4]u8 at index 1 which is 3 bytes",
    });

    cases.add("error note for function parameter incompatibility",
        \\fn do_the_thing(func: fn (arg: i32) void) void {}
        \\fn bar(arg: bool) void {}
        \\export fn entry() void {
        \\    do_the_thing(bar);
        \\}
    , &[_][]const u8{
        "tmp.zig:4:18: error: expected type 'fn(i32) void', found 'fn(bool) void",
        "tmp.zig:4:18: note: parameter 0: 'bool' cannot cast into 'i32'",
    });

    cases.add("cast negative value to unsigned integer",
        \\comptime {
        \\    const value: i32 = -1;
        \\    const unsigned = @intCast(u32, value);
        \\}
        \\export fn entry1() void {
        \\    const value: i32 = -1;
        \\    const unsigned: u32 = value;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:36: error: cannot cast negative value -1 to unsigned integer type 'u32'",
        "tmp.zig:7:27: error: cannot cast negative value -1 to unsigned integer type 'u32'",
    });

    cases.add("integer cast truncates bits",
        \\export fn entry1() void {
        \\    const spartan_count: u16 = 300;
        \\    const byte = @intCast(u8, spartan_count);
        \\}
        \\export fn entry2() void {
        \\    const spartan_count: u16 = 300;
        \\    const byte: u8 = spartan_count;
        \\}
        \\export fn entry3() void {
        \\    var spartan_count: u16 = 300;
        \\    var byte: u8 = spartan_count;
        \\}
        \\export fn entry4() void {
        \\    var signed: i8 = -1;
        \\    var unsigned: u64 = signed;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:31: error: integer value 300 cannot be coerced to type 'u8'",
        "tmp.zig:7:22: error: integer value 300 cannot be coerced to type 'u8'",
        "tmp.zig:11:20: error: expected type 'u8', found 'u16'",
        "tmp.zig:11:20: note: unsigned 8-bit int cannot represent all possible unsigned 16-bit values",
        "tmp.zig:15:25: error: expected type 'u64', found 'i8'",
        "tmp.zig:15:25: note: unsigned 64-bit int cannot represent all possible signed 8-bit values",
    });

    cases.add("comptime implicit cast f64 to f32",
        \\export fn entry() void {
        \\    const x: f64 = 16777217;
        \\    const y: f32 = x;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:20: error: cast of value 16777217.000000 to type 'f32' loses information",
    });

    cases.add("implicit cast from f64 to f32",
        \\var x: f64 = 1.0;
        \\var y: f32 = x;
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(y)); }
    , &[_][]const u8{
        "tmp.zig:2:14: error: expected type 'f32', found 'f64'",
    });

    cases.add("exceeded maximum bit width of integer",
        \\export fn entry1() void {
        \\    const T = @IntType(false, 65536);
        \\}
        \\export fn entry2() void {
        \\    var x: i65536 = 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:31: error: integer value 65536 cannot be coerced to type 'u16'",
        "tmp.zig:5:12: error: primitive integer type 'i65536' exceeds maximum bit width of 65535",
    });

    cases.add("compile error when evaluating return type of inferred error set",
        \\const Car = struct {
        \\    foo: *SymbolThatDoesNotExist,
        \\    pub fn init() !Car {}
        \\};
        \\export fn entry() void {
        \\    const car = Car.init();
        \\}
    , &[_][]const u8{
        "tmp.zig:2:11: error: use of undeclared identifier 'SymbolThatDoesNotExist'",
    });

    cases.add("don't implicit cast double pointer to *c_void",
        \\export fn entry() void {
        \\    var a: u32 = 1;
        \\    var ptr: *c_void = &a;
        \\    var b: *u32 = @ptrCast(*u32, ptr);
        \\    var ptr2: *c_void = &b;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:26: error: expected type '*c_void', found '**u32'",
    });

    cases.add("runtime index into comptime type slice",
        \\const Struct = struct {
        \\    a: u32,
        \\};
        \\fn getIndex() usize {
        \\    return 2;
        \\}
        \\export fn entry() void {
        \\    const index = getIndex();
        \\    const field = @typeInfo(Struct).Struct.fields[index];
        \\}
    , &[_][]const u8{
        "tmp.zig:9:51: error: values of type 'std.builtin.StructField' must be comptime known, but index value is runtime known",
    });

    cases.add("compile log statement inside function which must be comptime evaluated",
        \\fn Foo(comptime T: type) type {
        \\    @compileLog(@typeName(T));
        \\    return T;
        \\}
        \\export fn entry() void {
        \\    _ = Foo(i32);
        \\    _ = @typeName(Foo(i32));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: found compile log statement",
    });

    cases.add("comptime slice of an undefined slice",
        \\comptime {
        \\    var a: []u8 = undefined;
        \\    var b = a[0..10];
        \\}
    , &[_][]const u8{
        "tmp.zig:3:14: error: slice of undefined",
    });

    cases.add("implicit cast const array to mutable slice",
        \\export fn entry() void {
        \\    const buffer: [1]u8 = [_]u8{8};
        \\    const sliceA: []u8 = &buffer;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:27: error: expected type '[]u8', found '*const [1]u8'",
    });

    cases.add("deref slice and get len field",
        \\export fn entry() void {
        \\    var a: []u8 = undefined;
        \\    _ = a.*.len;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:10: error: attempt to dereference non-pointer type '[]u8'",
    });

    cases.add("@ptrCast a 0 bit type to a non- 0 bit type",
        \\export fn entry() bool {
        \\    var x: u0 = 0;
        \\    const p = @ptrCast(?*u0, &x);
        \\    return p == null;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:15: error: '*u0' and '?*u0' do not have the same in-memory representation",
        "tmp.zig:3:31: note: '*u0' has no in-memory bits",
        "tmp.zig:3:24: note: '?*u0' has in-memory bits",
    });

    cases.add("comparing a non-optional pointer against null",
        \\export fn entry() void {
        \\    var x: i32 = 1;
        \\    _ = &x == null;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:12: error: comparison of '*i32' with null",
    });

    cases.add("non error sets used in merge error sets operator",
        \\export fn foo() void {
        \\    const Errors = u8 || u16;
        \\}
        \\export fn bar() void {
        \\    const Errors = error{} || u16;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:20: error: expected error set type, found type 'u8'",
        "tmp.zig:2:23: note: `||` merges error sets; `or` performs boolean OR",
        "tmp.zig:5:31: error: expected error set type, found type 'u16'",
        "tmp.zig:5:28: note: `||` merges error sets; `or` performs boolean OR",
    });

    cases.add("variable initialization compile error then referenced",
        \\fn Undeclared() type {
        \\    return T;
        \\}
        \\fn Gen() type {
        \\    const X = Undeclared();
        \\    return struct {
        \\        x: X,
        \\    };
        \\}
        \\export fn entry() void {
        \\    const S = Gen();
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: use of undeclared identifier 'T'",
    });

    cases.add("refer to the type of a generic function",
        \\export fn entry() void {
        \\    const Func = fn (type) void;
        \\    const f: Func = undefined;
        \\    f(i32);
        \\}
    , &[_][]const u8{
        "tmp.zig:4:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("accessing runtime parameter from outer function",
        \\fn outer(y: u32) fn (u32) u32 {
        \\    const st = struct {
        \\        fn get(z: u32) u32 {
        \\            return z + y;
        \\        }
        \\    };
        \\    return st.get;
        \\}
        \\export fn entry() void {
        \\    var func = outer(10);
        \\    var x = func(3);
        \\}
    , &[_][]const u8{
        "tmp.zig:4:24: error: 'y' not accessible from inner function",
        "tmp.zig:3:28: note: crossed function definition here",
        "tmp.zig:1:10: note: declared here",
    });

    cases.add("non int passed to @intToFloat",
        \\export fn entry() void {
        \\    const x = @intToFloat(f32, 1.1);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:32: error: expected int type, found 'comptime_float'",
    });

    cases.add("non float passed to @floatToInt",
        \\export fn entry() void {
        \\    const x = @floatToInt(i32, @as(i32, 54));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:32: error: expected float type, found 'i32'",
    });

    cases.add("out of range comptime_int passed to @floatToInt",
        \\export fn entry() void {
        \\    const x = @floatToInt(i8, 200);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:31: error: integer value 200 cannot be coerced to type 'i8'",
    });

    cases.add("load too many bytes from comptime reinterpreted pointer",
        \\export fn entry() void {
        \\    const float: f32 = 5.99999999999994648725e-01;
        \\    const float_ptr = &float;
        \\    const int_ptr = @ptrCast(*const i64, float_ptr);
        \\    const int_val = int_ptr.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:28: error: attempt to read 8 bytes from pointer to f32 which is 4 bytes",
    });

    cases.add("invalid type used in array type",
        \\const Item = struct {
        \\    field: SomeNonexistentType,
        \\};
        \\var items: [100]Item = undefined;
        \\export fn entry() void {
        \\    const a = items[0];
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: use of undeclared identifier 'SomeNonexistentType'",
    });

    cases.add("comptime continue inside runtime catch",
        \\export fn entry(c: bool) void {
        \\    const ints = [_]u8{ 1, 2 };
        \\    inline for (ints) |_| {
        \\        bad() catch |_| continue;
        \\    }
        \\}
        \\fn bad() !void {
        \\    return error.Bad;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:25: error: comptime control flow inside runtime block",
        "tmp.zig:4:15: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime switch",
        \\export fn entry() void {
        \\    var p: i32 = undefined;
        \\    comptime var q = true;
        \\    inline while (q) {
        \\        switch (p) {
        \\            11 => continue,
        \\            else => {},
        \\        }
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:6:19: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime while error",
        \\export fn entry() void {
        \\    var p: anyerror!usize = undefined;
        \\    comptime var q = true;
        \\    outer: inline while (q) {
        \\        while (p) |_| {
        \\            continue :outer;
        \\        } else |_| {}
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:6:13: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime while optional",
        \\export fn entry() void {
        \\    var p: ?usize = undefined;
        \\    comptime var q = true;
        \\    outer: inline while (q) {
        \\        while (p) |_| continue :outer;
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:23: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime while bool",
        \\export fn entry() void {
        \\    var p: usize = undefined;
        \\    comptime var q = true;
        \\    outer: inline while (q) {
        \\        while (p == 11) continue :outer;
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:25: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime if error",
        \\export fn entry() void {
        \\    var p: anyerror!i32 = undefined;
        \\    comptime var q = true;
        \\    inline while (q) {
        \\        if (p) |_| continue else |_| {}
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:20: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime if optional",
        \\export fn entry() void {
        \\    var p: ?i32 = undefined;
        \\    comptime var q = true;
        \\    inline while (q) {
        \\        if (p) |_| continue;
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:20: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("comptime continue inside runtime if bool",
        \\export fn entry() void {
        \\    var p: usize = undefined;
        \\    comptime var q = true;
        \\    inline while (q) {
        \\        if (p == 11) continue;
        \\        q = false;
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:22: error: comptime control flow inside runtime block",
        "tmp.zig:5:9: note: runtime block created here",
    });

    cases.add("switch with invalid expression parameter",
        \\export fn entry() void {
        \\    Test(i32);
        \\}
        \\fn Test(comptime T: type) void {
        \\    const x = switch (T) {
        \\        []u8 => |x| 123,
        \\        i32 => |x| 456,
        \\        else => unreachable,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:7:17: error: switch on type 'type' provides no expression parameter",
    });

    cases.add("function protoype with no body",
        \\fn foo() void;
        \\export fn entry() void {
        \\    foo();
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: non-extern function has no body",
    });

    cases.add("@frame() called outside of function definition",
        \\var handle_undef: anyframe = undefined;
        \\var handle_dummy: anyframe = @frame();
        \\export fn entry() bool {
        \\    return handle_undef == handle_dummy;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:30: error: @frame() called outside of function definition",
    });

    cases.add("`_` is not a declarable symbol",
        \\export fn f1() usize {
        \\    var _: usize = 2;
        \\    return _;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: `_` is not a declarable symbol",
    });

    cases.add("`_` should not be usable inside for",
        \\export fn returns() void {
        \\    for ([_]void{}) |_, i| {
        \\        for ([_]void{}) |_, j| {
        \\            return _;
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:4:20: error: `_` may only be used to assign things to",
    });

    cases.add("`_` should not be usable inside while",
        \\export fn returns() void {
        \\    while (optionalReturn()) |_| {
        \\        while (optionalReturn()) |_| {
        \\            return _;
        \\        }
        \\    }
        \\}
        \\fn optionalReturn() ?u32 {
        \\    return 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:20: error: `_` may only be used to assign things to",
    });

    cases.add("`_` should not be usable inside while else",
        \\export fn returns() void {
        \\    while (optionalReturnError()) |_| {
        \\        while (optionalReturnError()) |_| {
        \\            return;
        \\        } else |_| {
        \\            if (_ == error.optionalReturnError) return;
        \\        }
        \\    }
        \\}
        \\fn optionalReturnError() !?u32 {
        \\    return error.optionalReturnError;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:17: error: `_` may only be used to assign things to",
    });

    cases.add("while loop body expression ignored",
        \\fn returns() usize {
        \\    return 2;
        \\}
        \\export fn f1() void {
        \\    while (true) returns();
        \\}
        \\export fn f2() void {
        \\    var x: ?i32 = null;
        \\    while (x) |_| returns();
        \\}
        \\export fn f3() void {
        \\    var x: anyerror!i32 = error.Bad;
        \\    while (x) |_| returns() else |_| unreachable;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:25: error: expression value is ignored",
        "tmp.zig:9:26: error: expression value is ignored",
        "tmp.zig:13:26: error: expression value is ignored",
    });

    cases.add("missing parameter name of generic function",
        \\fn dump(var) void {}
        \\export fn entry() void {
        \\    var a: u8 = 9;
        \\    dump(a);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:9: error: missing parameter name",
    });

    cases.add("non-inline for loop on a type that requires comptime",
        \\const Foo = struct {
        \\    name: []const u8,
        \\    T: type,
        \\};
        \\export fn entry() void {
        \\    const xx: [2]Foo = undefined;
        \\    for (xx) |f| {}
        \\}
    , &[_][]const u8{
        "tmp.zig:7:5: error: values of type 'Foo' must be comptime known, but index value is runtime known",
    });

    cases.add("generic fn as parameter without comptime keyword",
        \\fn f(_: fn (var) void) void {}
        \\fn g(_: var) void {}
        \\export fn entry() void {
        \\    f(g);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:9: error: parameter of type 'fn(var) var' must be declared comptime",
    });

    cases.add("optional pointer to void in extern struct",
        \\const Foo = extern struct {
        \\    x: ?*const void,
        \\};
        \\const Bar = extern struct {
        \\    foo: Foo,
        \\    y: i32,
        \\};
        \\export fn entry(bar: *Bar) void {}
    , &[_][]const u8{
        "tmp.zig:2:5: error: extern structs cannot contain fields of type '?*const void'",
    });

    cases.add("use of comptime-known undefined function value",
        \\const Cmd = struct {
        \\    exec: fn () void,
        \\};
        \\export fn entry() void {
        \\    const command = Cmd{ .exec = undefined };
        \\    command.exec();
        \\}
    , &[_][]const u8{
        "tmp.zig:6:12: error: use of undefined value here causes undefined behavior",
    });

    cases.add("use of comptime-known undefined function value",
        \\const Cmd = struct {
        \\    exec: fn () void,
        \\};
        \\export fn entry() void {
        \\    const command = Cmd{ .exec = undefined };
        \\    command.exec();
        \\}
    , &[_][]const u8{
        "tmp.zig:6:12: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bad @alignCast at comptime",
        \\comptime {
        \\    const ptr = @intToPtr(*align(1) i32, 0x1);
        \\    const aligned = @alignCast(4, ptr);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:35: error: pointer address 0x1 is not aligned to 4 bytes",
    });

    cases.add("@ptrToInt on *void",
        \\export fn entry() bool {
        \\    return @ptrToInt(&{}) == @ptrToInt(&{});
        \\}
    , &[_][]const u8{
        "tmp.zig:2:23: error: pointer to size 0 type has no address",
    });

    cases.add("@popCount - non-integer",
        \\export fn entry(x: f32) u32 {
        \\    return @popCount(f32, x);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:22: error: expected integer type, found 'f32'",
    });

    cases.addCase(x: {
        const tc = cases.create("wrong same named struct",
            \\const a = @import("a.zig");
            \\const b = @import("b.zig");
            \\
            \\export fn entry() void {
            \\    var a1: a.Foo = undefined;
            \\    bar(&a1);
            \\}
            \\
            \\fn bar(x: *b.Foo) void {}
        , &[_][]const u8{
            "tmp.zig:6:10: error: expected type '*b.Foo', found '*a.Foo'",
            "tmp.zig:6:10: note: pointer type child 'a.Foo' cannot cast into pointer type child 'b.Foo'",
            "a.zig:1:17: note: a.Foo declared here",
            "b.zig:1:17: note: b.Foo declared here",
        });

        tc.addSourceFile("a.zig",
            \\pub const Foo = struct {
            \\    x: i32,
            \\};
        );

        tc.addSourceFile("b.zig",
            \\pub const Foo = struct {
            \\    z: f64,
            \\};
        );

        break :x tc;
    });

    cases.add("@floatToInt comptime safety",
        \\comptime {
        \\    _ = @floatToInt(i8, @as(f32, -129.1));
        \\}
        \\comptime {
        \\    _ = @floatToInt(u8, @as(f32, -1.1));
        \\}
        \\comptime {
        \\    _ = @floatToInt(u8, @as(f32, 256.1));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: integer value '-129' cannot be stored in type 'i8'",
        "tmp.zig:5:9: error: integer value '-1' cannot be stored in type 'u8'",
        "tmp.zig:8:9: error: integer value '256' cannot be stored in type 'u8'",
    });

    cases.add("use c_void as return type of fn ptr",
        \\export fn entry() void {
        \\    const a: fn () c_void = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:20: error: return type cannot be opaque",
    });

    cases.add("use implicit casts to assign null to non-nullable pointer",
        \\export fn entry() void {
        \\    var x: i32 = 1234;
        \\    var p: *i32 = &x;
        \\    var pp: *?*i32 = &p;
        \\    pp.* = null;
        \\    var y = p.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:23: error: expected type '*?*i32', found '**i32'",
    });

    cases.add("attempted implicit cast from T to [*]const T",
        \\export fn entry() void {
        \\    const x: [*]const bool = true;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:30: error: expected type '[*]const bool', found 'bool'",
    });

    cases.add("dereference unknown length pointer",
        \\export fn entry(x: [*]i32) i32 {
        \\    return x.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:13: error: index syntax required for unknown-length pointer type '[*]i32'",
    });

    cases.add("field access of unknown length pointer",
        \\const Foo = extern struct {
        \\    a: i32,
        \\};
        \\
        \\export fn entry(foo: [*]Foo) void {
        \\    foo.a += 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:8: error: type '[*]Foo' does not support field access",
    });

    cases.add("unknown length pointer to opaque",
        \\export const T = [*]@OpaqueType();
    , &[_][]const u8{
        "tmp.zig:1:21: error: unknown-length pointer to opaque",
    });

    cases.add("error when evaluating return type",
        \\const Foo = struct {
        \\    map: @as(i32, i32),
        \\
        \\    fn init() Foo {
        \\        return undefined;
        \\    }
        \\};
        \\export fn entry() void {
        \\    var rule_set = try Foo.init();
        \\}
    , &[_][]const u8{
        "tmp.zig:2:10: error: expected type 'i32', found 'type'",
    });

    cases.add("slicing single-item pointer",
        \\export fn entry(ptr: *i32) void {
        \\    const slice = ptr[0..2];
        \\}
    , &[_][]const u8{
        "tmp.zig:2:22: error: slice of single-item pointer",
    });

    cases.add("indexing single-item pointer",
        \\export fn entry(ptr: *i32) i32 {
        \\    return ptr[1];
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: index of single-item pointer",
    });

    cases.add("nested error set mismatch",
        \\const NextError = error{NextError};
        \\const OtherError = error{OutOfMemory};
        \\
        \\export fn entry() void {
        \\    const a: ?NextError!i32 = foo();
        \\}
        \\
        \\fn foo() ?OtherError!i32 {
        \\    return null;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:34: error: expected type '?NextError!i32', found '?OtherError!i32'",
        "tmp.zig:5:34: note: optional type child 'OtherError!i32' cannot cast into optional type child 'NextError!i32'",
        "tmp.zig:5:34: note: error set 'OtherError' cannot cast into error set 'NextError'",
        "tmp.zig:2:26: note: 'error.OutOfMemory' not a member of destination error set",
    });

    cases.add("invalid deref on switch target",
        \\comptime {
        \\    var tile = Tile.Empty;
        \\    switch (tile.*) {
        \\        Tile.Empty => {},
        \\        Tile.Filled => {},
        \\    }
        \\}
        \\const Tile = enum {
        \\    Empty,
        \\    Filled,
        \\};
    , &[_][]const u8{
        "tmp.zig:3:17: error: attempt to dereference non-pointer type 'Tile'",
    });

    cases.add("invalid field access in comptime",
        \\comptime { var x = doesnt_exist.whatever; }
    , &[_][]const u8{
        "tmp.zig:1:20: error: use of undeclared identifier 'doesnt_exist'",
    });

    cases.add("suspend inside suspend block",
        \\export fn entry() void {
        \\    _ = async foo();
        \\}
        \\async fn foo() void {
        \\    suspend {
        \\        suspend {
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:6:9: error: cannot suspend inside suspend block",
        "tmp.zig:5:5: note: other suspend block here",
    });

    cases.add("assign inline fn to non-comptime var",
        \\export fn entry() void {
        \\    var a = b;
        \\}
        \\inline fn b() void { }
    , &[_][]const u8{
        "tmp.zig:2:5: error: functions marked inline must be stored in const or comptime var",
        "tmp.zig:4:1: note: declared here",
    });

    cases.add("wrong type passed to @panic",
        \\export fn entry() void {
        \\    var e = error.Foo;
        \\    @panic(e);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:12: error: expected type '[]const u8', found 'error{Foo}'",
    });

    cases.add("@tagName used on union with no associated enum tag",
        \\const FloatInt = extern union {
        \\    Float: f32,
        \\    Int: i32,
        \\};
        \\export fn entry() void {
        \\    var fi = FloatInt{.Float = 123.45};
        \\    var tagName = @tagName(fi);
        \\}
    , &[_][]const u8{
        "tmp.zig:7:19: error: union has no associated enum",
        "tmp.zig:1:18: note: declared here",
    });

    cases.add("returning error from void async function",
        \\export fn entry() void {
        \\    _ = async amain();
        \\}
        \\async fn amain() void {
        \\    return error.ShouldBeCompileError;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:17: error: expected type 'void', found 'error{ShouldBeCompileError}'",
    });

    cases.add("var makes structs required to be comptime known",
        \\export fn entry() void {
        \\   const S = struct{v: var};
        \\   var s = S{.v=@as(i32, 10)};
        \\}
    , &[_][]const u8{
        "tmp.zig:3:4: error: variable of type 'S' must be const or comptime",
    });

    cases.add("@ptrCast discards const qualifier",
        \\export fn entry() void {
        \\    const x: i32 = 1234;
        \\    const y = @ptrCast(*i32, &x);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:15: error: cast discards const qualifier",
    });

    cases.add("comptime slice of undefined pointer non-zero len",
        \\export fn entry() void {
        \\    const slice = @as([*]i32, undefined)[0..1];
        \\}
    , &[_][]const u8{
        "tmp.zig:2:41: error: non-zero length slice of undefined pointer",
    });

    cases.add("type checking function pointers",
        \\fn a(b: fn (*const u8) void) void {
        \\    b('a');
        \\}
        \\fn c(d: u8) void {}
        \\export fn entry() void {
        \\    a(c);
        \\}
    , &[_][]const u8{
        "tmp.zig:6:7: error: expected type 'fn(*const u8) void', found 'fn(u8) void'",
    });

    cases.add("no else prong on switch on global error set",
        \\export fn entry() void {
        \\    foo(error.A);
        \\}
        \\fn foo(a: anyerror) void {
        \\    switch (a) {
        \\        error.A => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: else prong required when switching on type 'anyerror'",
    });

    cases.add("inferred error set with no returned error",
        \\export fn entry() void {
        \\    foo() catch unreachable;
        \\}
        \\fn foo() !void {
        \\}
    , &[_][]const u8{
        "tmp.zig:4:11: error: function with inferred error set must return at least one possible error",
    });

    cases.add("error not handled in switch",
        \\export fn entry() void {
        \\    foo(452) catch |err| switch (err) {
        \\        error.Foo => {},
        \\    };
        \\}
        \\fn foo(x: i32) !void {
        \\    switch (x) {
        \\        0 ... 10 => return error.Foo,
        \\        11 ... 20 => return error.Bar,
        \\        21 ... 30 => return error.Baz,
        \\        else => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:2:26: error: error.Baz not handled in switch",
        "tmp.zig:2:26: error: error.Bar not handled in switch",
    });

    cases.add("duplicate error in switch",
        \\export fn entry() void {
        \\    foo(452) catch |err| switch (err) {
        \\        error.Foo => {},
        \\        error.Bar => {},
        \\        error.Foo => {},
        \\        else => {},
        \\    };
        \\}
        \\fn foo(x: i32) !void {
        \\    switch (x) {
        \\        0 ... 10 => return error.Foo,
        \\        11 ... 20 => return error.Bar,
        \\        else => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:14: error: duplicate switch value: '@TypeOf(foo).ReturnType.ErrorSet.Foo'",
        "tmp.zig:3:14: note: other value is here",
    });

    cases.add("invalid cast from integral type to enum",
        \\const E = enum(usize) { One, Two };
        \\
        \\export fn entry() void {
        \\    foo(1);
        \\}
        \\
        \\fn foo(x: usize) void {
        \\    switch (x) {
        \\        E.One => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:9:10: error: expected type 'usize', found 'E'",
    });

    cases.add("range operator in switch used on error set",
        \\export fn entry() void {
        \\    try foo(452) catch |err| switch (err) {
        \\        error.A ... error.B => {},
        \\        else => {},
        \\    };
        \\}
        \\fn foo(x: i32) !void {
        \\    switch (x) {
        \\        0 ... 10 => return error.Foo,
        \\        11 ... 20 => return error.Bar,
        \\        else => {},
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:3:17: error: operator not allowed for errors",
    });

    cases.add("inferring error set of function pointer",
        \\comptime {
        \\    const z: ?fn()!void = null;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: inferring error set of return type valid only for function definitions",
    });

    cases.add("access non-existent member of error set",
        \\const Foo = error{A};
        \\comptime {
        \\    const z = Foo.Bar;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:18: error: no error named 'Bar' in 'Foo'",
    });

    cases.add("error union operator with non error set LHS",
        \\comptime {
        \\    const z = i32!i32;
        \\    var x: z = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected error set type, found type 'i32'",
    });

    cases.add("error equality but sets have no common members",
        \\const Set1 = error{A, C};
        \\const Set2 = error{B, D};
        \\export fn entry() void {
        \\    foo(Set1.A);
        \\}
        \\fn foo(x: Set1) void {
        \\    if (x == Set2.B) {
        \\
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:7:11: error: error sets 'Set1' and 'Set2' have no common errors",
    });

    cases.add("only equality binary operator allowed for error sets",
        \\comptime {
        \\    const z = error.A > error.B;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:23: error: operator not allowed for errors",
    });

    cases.add("explicit error set cast known at comptime violates error sets",
        \\const Set1 = error {A, B};
        \\const Set2 = error {A, C};
        \\comptime {
        \\    var x = Set1.B;
        \\    var y = @errSetCast(Set2, x);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:13: error: error.B not a member of error set 'Set2'",
    });

    cases.add("cast error union of global error set to error union of smaller error set",
        \\const SmallErrorSet = error{A};
        \\export fn entry() void {
        \\    var x: SmallErrorSet!i32 = foo();
        \\}
        \\fn foo() anyerror!i32 {
        \\    return error.B;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:35: error: expected type 'SmallErrorSet!i32', found 'anyerror!i32'",
        "tmp.zig:3:35: note: error set 'anyerror' cannot cast into error set 'SmallErrorSet'",
        "tmp.zig:3:35: note: cannot cast global error set into smaller set",
    });

    cases.add("cast global error set to error set",
        \\const SmallErrorSet = error{A};
        \\export fn entry() void {
        \\    var x: SmallErrorSet = foo();
        \\}
        \\fn foo() anyerror {
        \\    return error.B;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:31: error: expected type 'SmallErrorSet', found 'anyerror'",
        "tmp.zig:3:31: note: cannot cast global error set into smaller set",
    });
    cases.add("recursive inferred error set",
        \\export fn entry() void {
        \\    foo() catch unreachable;
        \\}
        \\fn foo() !void {
        \\    try foo();
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: cannot resolve inferred error set '@TypeOf(foo).ReturnType.ErrorSet': function 'foo' not fully analyzed yet",
    });

    cases.add("implicit cast of error set not a subset",
        \\const Set1 = error{A, B};
        \\const Set2 = error{A, C};
        \\export fn entry() void {
        \\    foo(Set1.B);
        \\}
        \\fn foo(set1: Set1) void {
        \\    var x: Set2 = set1;
        \\}
    , &[_][]const u8{
        "tmp.zig:7:19: error: expected type 'Set2', found 'Set1'",
        "tmp.zig:1:23: note: 'error.B' not a member of destination error set",
    });

    cases.add("int to err global invalid number",
        \\const Set1 = error{
        \\    A,
        \\    B,
        \\};
        \\comptime {
        \\    var x: u16 = 3;
        \\    var y = @intToError(x);
        \\}
    , &[_][]const u8{
        "tmp.zig:7:13: error: integer value 3 represents no error",
    });

    cases.add("int to err non global invalid number",
        \\const Set1 = error{
        \\    A,
        \\    B,
        \\};
        \\const Set2 = error{
        \\    A,
        \\    C,
        \\};
        \\comptime {
        \\    var x = @errorToInt(Set1.B);
        \\    var y = @errSetCast(Set2, @intToError(x));
        \\}
    , &[_][]const u8{
        "tmp.zig:11:13: error: error.B not a member of error set 'Set2'",
    });

    cases.add("@memberCount of error",
        \\comptime {
        \\    _ = @memberCount(anyerror);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: global error set member count not available at comptime",
    });

    cases.add("duplicate error value in error set",
        \\const Foo = error {
        \\    Bar,
        \\    Bar,
        \\};
        \\export fn entry() void {
        \\    const a: Foo = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: duplicate error: 'Bar'",
        "tmp.zig:2:5: note: other error here",
    });

    cases.add("cast negative integer literal to usize",
        \\export fn entry() void {
        \\    const x = @as(usize, -10);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:26: error: cannot cast negative value -10 to unsigned integer type 'usize'",
    });

    cases.add("use invalid number literal as array index",
        \\var v = 25;
        \\export fn entry() void {
        \\    var arr: [v]u8 = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: unable to infer variable type",
    });

    cases.add("duplicate struct field",
        \\const Foo = struct {
        \\    Bar: i32,
        \\    Bar: usize,
        \\};
        \\export fn entry() void {
        \\    const a: Foo = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: duplicate struct field: 'Bar'",
        "tmp.zig:2:5: note: other field here",
    });

    cases.add("duplicate union field",
        \\const Foo = union {
        \\    Bar: i32,
        \\    Bar: usize,
        \\};
        \\export fn entry() void {
        \\    const a: Foo = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: duplicate union field: 'Bar'",
        "tmp.zig:2:5: note: other field here",
    });

    cases.add("duplicate enum field",
        \\const Foo = enum {
        \\    Bar,
        \\    Bar,
        \\};
        \\
        \\export fn entry() void {
        \\    const a: Foo = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: duplicate enum field: 'Bar'",
        "tmp.zig:2:5: note: other field here",
    });

    cases.add("calling function with naked calling convention",
        \\export fn entry() void {
        \\    foo();
        \\}
        \\fn foo() callconv(.Naked) void { }
    , &[_][]const u8{
        "tmp.zig:2:5: error: unable to call function with naked calling convention",
        "tmp.zig:4:1: note: declared here",
    });

    cases.add("function with invalid return type",
        \\export fn foo() boid {}
    , &[_][]const u8{
        "tmp.zig:1:17: error: use of undeclared identifier 'boid'",
    });

    cases.add("function with non-extern non-packed enum parameter",
        \\const Foo = enum { A, B, C };
        \\export fn entry(foo: Foo) void { }
    , &[_][]const u8{
        "tmp.zig:2:22: error: parameter of type 'Foo' not allowed in function with calling convention 'C'",
    });

    cases.add("function with non-extern non-packed struct parameter",
        \\const Foo = struct {
        \\    A: i32,
        \\    B: f32,
        \\    C: bool,
        \\};
        \\export fn entry(foo: Foo) void { }
    , &[_][]const u8{
        "tmp.zig:6:22: error: parameter of type 'Foo' not allowed in function with calling convention 'C'",
    });

    cases.add("function with non-extern non-packed union parameter",
        \\const Foo = union {
        \\    A: i32,
        \\    B: f32,
        \\    C: bool,
        \\};
        \\export fn entry(foo: Foo) void { }
    , &[_][]const u8{
        "tmp.zig:6:22: error: parameter of type 'Foo' not allowed in function with calling convention 'C'",
    });

    cases.add("switch on enum with 1 field with no prongs",
        \\const Foo = enum { M };
        \\
        \\export fn entry() void {
        \\    var f = Foo.M;
        \\    switch (f) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: enumeration value 'Foo.M' not handled in switch",
    });

    cases.add("shift by negative comptime integer",
        \\comptime {
        \\    var a = 1 >> -1;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:18: error: shift by negative value -1",
    });

    cases.add("@panic called at compile time",
        \\export fn entry() void {
        \\    comptime {
        \\        @panic("aoeu",);
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: encountered @panic at compile-time",
    });

    cases.add("wrong return type for main",
        \\pub fn main() f32 { }
    , &[_][]const u8{
        "error: expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'",
    });

    cases.add("double ?? on main return value",
        \\pub fn main() ??void {
        \\}
    , &[_][]const u8{
        "error: expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'",
    });

    cases.add("bad identifier in function with struct defined inside function which references local const",
        \\export fn entry() void {
        \\    const BlockKind = u32;
        \\
        \\    const Block = struct {
        \\        kind: BlockKind,
        \\    };
        \\
        \\    bogus;
        \\}
    , &[_][]const u8{
        "tmp.zig:8:5: error: use of undeclared identifier 'bogus'",
    });

    cases.add("labeled break not found",
        \\export fn entry() void {
        \\    blah: while (true) {
        \\        while (true) {
        \\            break :outer;
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:4:13: error: label not found: 'outer'",
    });

    cases.add("labeled continue not found",
        \\export fn entry() void {
        \\    var i: usize = 0;
        \\    blah: while (i < 10) : (i += 1) {
        \\        while (true) {
        \\            continue :outer;
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:5:13: error: labeled loop not found: 'outer'",
    });

    cases.add("attempt to use 0 bit type in extern fn",
        \\extern fn foo(ptr: extern fn(*void) void) void;
        \\
        \\export fn entry() void {
        \\    foo(bar);
        \\}
        \\
        \\fn bar(x: *void) callconv(.C) void { }
        \\export fn entry2() void {
        \\    bar(&{});
        \\}
    , &[_][]const u8{
        "tmp.zig:1:30: error: parameter of type '*void' has 0 bits; not allowed in function with calling convention 'C'",
        "tmp.zig:7:11: error: parameter of type '*void' has 0 bits; not allowed in function with calling convention 'C'",
    });

    cases.add("implicit semicolon - block statement",
        \\export fn entry() void {
        \\    {}
        \\    var good = {};
        \\    ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - block expr",
        \\export fn entry() void {
        \\    _ = {};
        \\    var good = {};
        \\    _ = {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - comptime statement",
        \\export fn entry() void {
        \\    comptime {}
        \\    var good = {};
        \\    comptime ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - comptime expression",
        \\export fn entry() void {
        \\    _ = comptime {};
        \\    var good = {};
        \\    _ = comptime {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - defer",
        \\export fn entry() void {
        \\    defer {}
        \\    var good = {};
        \\    defer ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if statement",
        \\export fn entry() void {
        \\    if(true) {}
        \\    var good = {};
        \\    if(true) ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if expression",
        \\export fn entry() void {
        \\    _ = if(true) {};
        \\    var good = {};
        \\    _ = if(true) {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if-else statement",
        \\export fn entry() void {
        \\    if(true) {} else {}
        \\    var good = {};
        \\    if(true) ({}) else ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if-else expression",
        \\export fn entry() void {
        \\    _ = if(true) {} else {};
        \\    var good = {};
        \\    _ = if(true) {} else {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if-else-if statement",
        \\export fn entry() void {
        \\    if(true) {} else if(true) {}
        \\    var good = {};
        \\    if(true) ({}) else if(true) ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if-else-if expression",
        \\export fn entry() void {
        \\    _ = if(true) {} else if(true) {};
        \\    var good = {};
        \\    _ = if(true) {} else if(true) {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if-else-if-else statement",
        \\export fn entry() void {
        \\    if(true) {} else if(true) {} else {}
        \\    var good = {};
        \\    if(true) ({}) else if(true) ({}) else ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - if-else-if-else expression",
        \\export fn entry() void {
        \\    _ = if(true) {} else if(true) {} else {};
        \\    var good = {};
        \\    _ = if(true) {} else if(true) {} else {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - test statement",
        \\export fn entry() void {
        \\    if (foo()) |_| {}
        \\    var good = {};
        \\    if (foo()) |_| ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - test expression",
        \\export fn entry() void {
        \\    _ = if (foo()) |_| {};
        \\    var good = {};
        \\    _ = if (foo()) |_| {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - while statement",
        \\export fn entry() void {
        \\    while(true) {}
        \\    var good = {};
        \\    while(true) ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - while expression",
        \\export fn entry() void {
        \\    _ = while(true) {};
        \\    var good = {};
        \\    _ = while(true) {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - while-continue statement",
        \\export fn entry() void {
        \\    while(true):({}) {}
        \\    var good = {};
        \\    while(true):({}) ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - while-continue expression",
        \\export fn entry() void {
        \\    _ = while(true):({}) {};
        \\    var good = {};
        \\    _ = while(true):({}) {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - for statement",
        \\export fn entry() void {
        \\    for(foo()) |_| {}
        \\    var good = {};
        \\    for(foo()) |_| ({})
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("implicit semicolon - for expression",
        \\export fn entry() void {
        \\    _ = for(foo()) |_| {};
        \\    var good = {};
        \\    _ = for(foo()) |_| {}
        \\    var bad = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: expected token ';', found 'var'",
    });

    cases.add("multiple function definitions",
        \\fn a() void {}
        \\fn a() void {}
        \\export fn entry() void { a(); }
    , &[_][]const u8{
        "tmp.zig:2:1: error: redefinition of 'a'",
    });

    cases.add("unreachable with return",
        \\fn a() noreturn {return;}
        \\export fn entry() void { a(); }
    , &[_][]const u8{
        "tmp.zig:1:18: error: expected type 'noreturn', found 'void'",
    });

    cases.add("control reaches end of non-void function",
        \\fn a() i32 {}
        \\export fn entry() void { _ = a(); }
    , &[_][]const u8{
        "tmp.zig:1:12: error: expected type 'i32', found 'void'",
    });

    cases.add("undefined function call",
        \\export fn a() void {
        \\    b();
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: use of undeclared identifier 'b'",
    });

    cases.add("wrong number of arguments",
        \\export fn a() void {
        \\    b(1);
        \\}
        \\fn b(a: i32, b: i32, c: i32) void { }
    , &[_][]const u8{
        "tmp.zig:2:6: error: expected 3 arguments, found 1",
    });

    cases.add("invalid type",
        \\fn a() bogus {}
        \\export fn entry() void { _ = a(); }
    , &[_][]const u8{
        "tmp.zig:1:8: error: use of undeclared identifier 'bogus'",
    });

    cases.add("pointer to noreturn",
        \\fn a() *noreturn {}
        \\export fn entry() void { _ = a(); }
    , &[_][]const u8{
        "tmp.zig:1:9: error: pointer to noreturn not allowed",
    });

    cases.add("unreachable code",
        \\export fn a() void {
        \\    return;
        \\    b();
        \\}
        \\
        \\fn b() void {}
    , &[_][]const u8{
        "tmp.zig:3:6: error: unreachable code",
    });

    cases.add("bad import",
        \\const bogus = @import("bogus-does-not-exist.zig",);
        \\export fn entry() void { bogus.bogo(); }
    , &[_][]const u8{
        "tmp.zig:1:15: error: unable to find 'bogus-does-not-exist.zig'",
    });

    cases.add("undeclared identifier",
        \\export fn a() void {
        \\    return
        \\    b +
        \\    c;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undeclared identifier 'b'",
    });

    cases.add("parameter redeclaration",
        \\fn f(a : i32, a : i32) void {
        \\}
        \\export fn entry() void { f(1, 2); }
    , &[_][]const u8{
        "tmp.zig:1:15: error: redeclaration of variable 'a'",
    });

    cases.add("local variable redeclaration",
        \\export fn f() void {
        \\    const a : i32 = 0;
        \\    const a = 0;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: redeclaration of variable 'a'",
    });

    cases.add("local variable redeclares parameter",
        \\fn f(a : i32) void {
        \\    const a = 0;
        \\}
        \\export fn entry() void { f(1); }
    , &[_][]const u8{
        "tmp.zig:2:5: error: redeclaration of variable 'a'",
    });

    cases.add("variable has wrong type",
        \\export fn f() i32 {
        \\    const a = "a";
        \\    return a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:12: error: expected type 'i32', found '*const [1:0]u8'",
    });

    cases.add("if condition is bool, not int",
        \\export fn f() void {
        \\    if (0) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: expected type 'bool', found 'comptime_int'",
    });

    cases.add("assign unreachable",
        \\export fn f() void {
        \\    const a = return;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: unreachable code",
    });

    cases.add("unreachable variable",
        \\export fn f() void {
        \\    const a: noreturn = {};
        \\}
    , &[_][]const u8{
        "tmp.zig:2:25: error: expected type 'noreturn', found 'void'",
    });

    cases.add("unreachable parameter",
        \\fn f(a: noreturn) void {}
        \\export fn entry() void { f(); }
    , &[_][]const u8{
        "tmp.zig:1:9: error: parameter of type 'noreturn' not allowed",
    });

    cases.add("bad assignment target",
        \\export fn f() void {
        \\    3 = 3;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: cannot assign to constant",
    });

    cases.add("assign to constant variable",
        \\export fn f() void {
        \\    const a = 3;
        \\    a = 4;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: cannot assign to constant",
    });

    cases.add("use of undeclared identifier",
        \\export fn f() void {
        \\    b = 3;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: use of undeclared identifier 'b'",
    });

    cases.add("const is a statement, not an expression",
        \\export fn f() void {
        \\    (const a = 0);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:6: error: invalid token: 'const'",
    });

    cases.add("array access of undeclared identifier",
        \\export fn f() void {
        \\    i[i] = i[i];
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: use of undeclared identifier 'i'",
    });

    cases.add("array access of non array",
        \\export fn f() void {
        \\    var bad : bool = undefined;
        \\    bad[bad] = bad[bad];
        \\}
        \\export fn g() void {
        \\    var bad : bool = undefined;
        \\    _ = bad[bad];
        \\}
    , &[_][]const u8{
        "tmp.zig:3:8: error: array access of non-array type 'bool'",
        "tmp.zig:7:12: error: array access of non-array type 'bool'",
    });

    cases.add("array access with non integer index",
        \\export fn f() void {
        \\    var array = "aoeu";
        \\    var bad = false;
        \\    array[bad] = array[bad];
        \\}
        \\export fn g() void {
        \\    var array = "aoeu";
        \\    var bad = false;
        \\    _ = array[bad];
        \\}
    , &[_][]const u8{
        "tmp.zig:4:11: error: expected type 'usize', found 'bool'",
        "tmp.zig:9:15: error: expected type 'usize', found 'bool'",
    });

    cases.add("write to const global variable",
        \\const x : i32 = 99;
        \\fn f() void {
        \\    x = 1;
        \\}
        \\export fn entry() void { f(); }
    , &[_][]const u8{
        "tmp.zig:3:9: error: cannot assign to constant",
    });

    cases.add("missing else clause",
        \\fn f(b: bool) void {
        \\    const x : i32 = if (b) h: { break :h 1; };
        \\}
        \\fn g(b: bool) void {
        \\    const y = if (b) h: { break :h @as(i32, 1); };
        \\}
        \\export fn entry() void { f(true); g(true); }
    , &[_][]const u8{
        "tmp.zig:2:21: error: expected type 'i32', found 'void'",
        "tmp.zig:5:15: error: incompatible types: 'i32' and 'void'",
    });

    cases.add("invalid struct field",
        \\const A = struct { x : i32, };
        \\export fn f() void {
        \\    var a : A = undefined;
        \\    a.foo = 1;
        \\    const y = a.bar;
        \\}
        \\export fn g() void {
        \\    var a : A = undefined;
        \\    const y = a.bar;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:6: error: no member named 'foo' in struct 'A'",
        "tmp.zig:9:16: error: no member named 'bar' in struct 'A'",
    });

    cases.add("redefinition of struct",
        \\const A = struct { x : i32, };
        \\const A = struct { y : i32, };
    , &[_][]const u8{
        "tmp.zig:2:1: error: redefinition of 'A'",
    });

    cases.add("redefinition of enums",
        \\const A = enum {};
        \\const A = enum {};
    , &[_][]const u8{
        "tmp.zig:2:1: error: redefinition of 'A'",
    });

    cases.add("redefinition of global variables",
        \\var a : i32 = 1;
        \\var a : i32 = 2;
    , &[_][]const u8{
        "tmp.zig:2:1: error: redefinition of 'a'",
        "tmp.zig:1:1: note: previous definition is here",
    });

    cases.add("duplicate field in struct value expression",
        \\const A = struct {
        \\    x : i32,
        \\    y : i32,
        \\    z : i32,
        \\};
        \\export fn f() void {
        \\    const a = A {
        \\        .z = 1,
        \\        .y = 2,
        \\        .x = 3,
        \\        .z = 4,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:11:9: error: duplicate field",
    });

    cases.add("missing field in struct value expression",
        \\const A = struct {
        \\    x : i32,
        \\    y : i32,
        \\    z : i32,
        \\};
        \\export fn f() void {
        \\    // we want the error on the '{' not the 'A' because
        \\    // the A could be a complicated expression
        \\    const a = A {
        \\        .z = 4,
        \\        .y = 2,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:9:17: error: missing field: 'x'",
    });

    cases.add("invalid field in struct value expression",
        \\const A = struct {
        \\    x : i32,
        \\    y : i32,
        \\    z : i32,
        \\};
        \\export fn f() void {
        \\    const a = A {
        \\        .z = 4,
        \\        .y = 2,
        \\        .foo = 42,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:10:9: error: no member named 'foo' in struct 'A'",
    });

    cases.add("invalid break expression",
        \\export fn f() void {
        \\    break;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: break expression outside loop",
    });

    cases.add("invalid continue expression",
        \\export fn f() void {
        \\    continue;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: continue expression outside loop",
    });

    cases.add("invalid maybe type",
        \\export fn f() void {
        \\    if (true) |x| { }
        \\}
    , &[_][]const u8{
        "tmp.zig:2:9: error: expected optional type, found 'bool'",
    });

    cases.add("cast unreachable",
        \\fn f() i32 {
        \\    return @as(i32, return 1);
        \\}
        \\export fn entry() void { _ = f(); }
    , &[_][]const u8{
        "tmp.zig:2:12: error: unreachable code",
    });

    cases.add("invalid builtin fn",
        \\fn f() @bogus(foo) {
        \\}
        \\export fn entry() void { _ = f(); }
    , &[_][]const u8{
        "tmp.zig:1:8: error: invalid builtin function: 'bogus'",
    });

    cases.add("noalias on non pointer param",
        \\fn f(noalias x: i32) void {}
        \\export fn entry() void { f(1234); }
    , &[_][]const u8{
        "tmp.zig:1:6: error: noalias on non-pointer parameter",
    });

    cases.add("struct init syntax for array",
        \\const foo = [3]u16{ .x = 1024 };
        \\comptime {
        \\    _ = foo;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:21: error: type '[3]u16' does not support struct initialization syntax",
    });

    cases.add("type variables must be constant",
        \\var foo = u8;
        \\export fn entry() foo {
        \\    return 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: variable of type 'type' must be constant",
    });

    cases.add("variables shadowing types",
        \\const Foo = struct {};
        \\const Bar = struct {};
        \\
        \\fn f(Foo: i32) void {
        \\    var Bar : i32 = undefined;
        \\}
        \\
        \\export fn entry() void {
        \\    f(1234);
        \\}
    , &[_][]const u8{
        "tmp.zig:4:6: error: redefinition of 'Foo'",
        "tmp.zig:1:1: note: previous definition is here",
        "tmp.zig:5:5: error: redefinition of 'Bar'",
        "tmp.zig:2:1: note: previous definition is here",
    });

    cases.add("switch expression - missing enumeration prong",
        \\const Number = enum {
        \\    One,
        \\    Two,
        \\    Three,
        \\    Four,
        \\};
        \\fn f(n: Number) i32 {
        \\    switch (n) {
        \\        Number.One => 1,
        \\        Number.Two => 2,
        \\        Number.Three => @as(i32, 3),
        \\    }
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:8:5: error: enumeration value 'Number.Four' not handled in switch",
    });

    cases.add("switch expression - duplicate enumeration prong",
        \\const Number = enum {
        \\    One,
        \\    Two,
        \\    Three,
        \\    Four,
        \\};
        \\fn f(n: Number) i32 {
        \\    switch (n) {
        \\        Number.One => 1,
        \\        Number.Two => 2,
        \\        Number.Three => @as(i32, 3),
        \\        Number.Four => 4,
        \\        Number.Two => 2,
        \\    }
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:13:15: error: duplicate switch value",
        "tmp.zig:10:15: note: other value is here",
    });

    cases.add("switch expression - duplicate enumeration prong when else present",
        \\const Number = enum {
        \\    One,
        \\    Two,
        \\    Three,
        \\    Four,
        \\};
        \\fn f(n: Number) i32 {
        \\    switch (n) {
        \\        Number.One => 1,
        \\        Number.Two => 2,
        \\        Number.Three => @as(i32, 3),
        \\        Number.Four => 4,
        \\        Number.Two => 2,
        \\        else => 10,
        \\    }
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:13:15: error: duplicate switch value",
        "tmp.zig:10:15: note: other value is here",
    });

    cases.add("switch expression - multiple else prongs",
        \\fn f(x: u32) void {
        \\    const value: bool = switch (x) {
        \\        1234 => false,
        \\        else => true,
        \\        else => true,
        \\    };
        \\}
        \\export fn entry() void {
        \\    f(1234);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:9: error: multiple else prongs in switch expression",
    });

    cases.add("switch expression - non exhaustive integer prongs",
        \\fn foo(x: u8) void {
        \\    switch (x) {
        \\        0 => {},
        \\    }
        \\}
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:2:5: error: switch must handle all possibilities",
    });

    cases.add("switch expression - duplicate or overlapping integer value",
        \\fn foo(x: u8) u8 {
        \\    return switch (x) {
        \\        0 ... 100 => @as(u8, 0),
        \\        101 ... 200 => 1,
        \\        201, 203 ... 207 => 2,
        \\        206 ... 255 => 3,
        \\    };
        \\}
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:6:9: error: duplicate switch value",
        "tmp.zig:5:14: note: previous value is here",
    });

    cases.add("switch expression - switch on pointer type with no else",
        \\fn foo(x: *u8) void {
        \\    switch (x) {
        \\        &y => {},
        \\    }
        \\}
        \\const y: u8 = 100;
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:2:5: error: else prong required when switching on type '*u8'",
    });

    cases.add("global variable initializer must be constant expression",
        \\extern fn foo() i32;
        \\const x = foo();
        \\export fn entry() i32 { return x; }
    , &[_][]const u8{
        "tmp.zig:2:11: error: unable to evaluate constant expression",
    });

    cases.add("array concatenation with wrong type",
        \\const src = "aoeu";
        \\const derp: usize = 1234;
        \\const a = derp ++ "foo";
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(a)); }
    , &[_][]const u8{
        "tmp.zig:3:11: error: expected array, found 'usize'",
    });

    cases.add("non compile time array concatenation",
        \\fn f() []u8 {
        \\    return s ++ "foo";
        \\}
        \\var s: [10]u8 = undefined;
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:2:12: error: unable to evaluate constant expression",
    });

    cases.add("@cImport with bogus include",
        \\const c = @cImport(@cInclude("bogus.h"));
        \\export fn entry() usize { return @sizeOf(@TypeOf(c.bogo)); }
    , &[_][]const u8{
        "tmp.zig:1:11: error: C import failed",
        ".h:1:10: note: 'bogus.h' file not found",
    });

    cases.add("address of number literal",
        \\const x = 3;
        \\const y = &x;
        \\fn foo() *const i32 { return y; }
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:3:30: error: expected type '*const i32', found '*const comptime_int'",
    });

    cases.add("integer overflow error",
        \\const x : u8 = 300;
        \\export fn entry() usize { return @sizeOf(@TypeOf(x)); }
    , &[_][]const u8{
        "tmp.zig:1:16: error: integer value 300 cannot be coerced to type 'u8'",
    });

    cases.add("invalid shift amount error",
        \\const x : u8 = 2;
        \\fn f() u16 {
        \\    return x << 8;
        \\}
        \\export fn entry() u16 { return f(); }
    , &[_][]const u8{
        "tmp.zig:3:14: error: RHS of shift is too large for LHS type",
        "tmp.zig:3:17: note: value 8 cannot fit into type u3",
    });

    cases.add("missing function call param",
        \\const Foo = struct {
        \\    a: i32,
        \\    b: i32,
        \\
        \\    fn member_a(foo: *const Foo) i32 {
        \\        return foo.a;
        \\    }
        \\    fn member_b(foo: *const Foo) i32 {
        \\        return foo.b;
        \\    }
        \\};
        \\
        \\const member_fn_type = @TypeOf(Foo.member_a);
        \\const members = [_]member_fn_type {
        \\    Foo.member_a,
        \\    Foo.member_b,
        \\};
        \\
        \\fn f(foo: *const Foo, index: usize) void {
        \\    const result = members[index]();
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:20:34: error: expected 1 arguments, found 0",
    });

    cases.add("missing function name",
        \\fn () void {}
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:1:1: error: missing function name",
    });

    cases.add("missing param name",
        \\fn f(i32) void {}
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:1:6: error: missing parameter name",
    });

    cases.add("wrong function type",
        \\const fns = [_]fn() void { a, b, c };
        \\fn a() i32 {return 0;}
        \\fn b() i32 {return 1;}
        \\fn c() i32 {return 2;}
        \\export fn entry() usize { return @sizeOf(@TypeOf(fns)); }
    , &[_][]const u8{
        "tmp.zig:1:28: error: expected type 'fn() void', found 'fn() i32'",
    });

    cases.add("extern function pointer mismatch",
        \\const fns = [_](fn(i32)i32) { a, b, c };
        \\pub fn a(x: i32) i32 {return x + 0;}
        \\pub fn b(x: i32) i32 {return x + 1;}
        \\export fn c(x: i32) i32 {return x + 2;}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(fns)); }
    , &[_][]const u8{
        "tmp.zig:1:37: error: expected type 'fn(i32) i32', found 'fn(i32) callconv(.C) i32'",
    });

    cases.add("colliding invalid top level functions",
        \\fn func() bogus {}
        \\fn func() bogus {}
        \\export fn entry() usize { return @sizeOf(@TypeOf(func)); }
    , &[_][]const u8{
        "tmp.zig:2:1: error: redefinition of 'func'",
    });

    cases.add("non constant expression in array size",
        \\const Foo = struct {
        \\    y: [get()]u8,
        \\};
        \\var global_var: usize = 1;
        \\fn get() usize { return global_var; }
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(Foo)); }
    , &[_][]const u8{
        "tmp.zig:5:25: error: unable to evaluate constant expression",
        "tmp.zig:2:12: note: referenced here",
    });

    cases.add("addition with non numbers",
        \\const Foo = struct {
        \\    field: i32,
        \\};
        \\const x = Foo {.field = 1} + Foo {.field = 2};
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(x)); }
    , &[_][]const u8{
        "tmp.zig:4:28: error: invalid operands to binary expression: 'Foo' and 'Foo'",
    });

    cases.add("division by zero",
        \\const lit_int_x = 1 / 0;
        \\const lit_float_x = 1.0 / 0.0;
        \\const int_x = @as(u32, 1) / @as(u32, 0);
        \\const float_x = @as(f32, 1.0) / @as(f32, 0.0);
        \\
        \\export fn entry1() usize { return @sizeOf(@TypeOf(lit_int_x)); }
        \\export fn entry2() usize { return @sizeOf(@TypeOf(lit_float_x)); }
        \\export fn entry3() usize { return @sizeOf(@TypeOf(int_x)); }
        \\export fn entry4() usize { return @sizeOf(@TypeOf(float_x)); }
    , &[_][]const u8{
        "tmp.zig:1:21: error: division by zero",
        "tmp.zig:2:25: error: division by zero",
        "tmp.zig:3:27: error: division by zero",
        "tmp.zig:4:31: error: division by zero",
    });

    cases.add("normal string with newline",
        \\const foo = "a
        \\b";
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:1:15: error: newline not allowed in string literal",
    });

    cases.add("invalid comparison for function pointers",
        \\fn foo() void {}
        \\const invalid = foo > foo;
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(invalid)); }
    , &[_][]const u8{
        "tmp.zig:2:21: error: operator not allowed for type 'fn() void'",
    });

    cases.add("generic function instance with non-constant expression",
        \\fn foo(comptime x: i32, y: i32) i32 { return x + y; }
        \\fn test1(a: i32, b: i32) i32 {
        \\    return foo(a, b);
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(test1)); }
    , &[_][]const u8{
        "tmp.zig:3:16: error: unable to evaluate constant expression",
    });

    cases.add("assign null to non-optional pointer",
        \\const a: *u8 = null;
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(a)); }
    , &[_][]const u8{
        "tmp.zig:1:16: error: expected type '*u8', found '(null)'",
    });

    cases.add("indexing an array of size zero",
        \\const array = [_]u8{};
        \\export fn foo() void {
        \\    const pointer = &array[0];
        \\}
    , &[_][]const u8{
        "tmp.zig:3:27: error: index 0 outside array of size 0",
    });

    cases.add("compile time division by zero",
        \\const y = foo(0);
        \\fn foo(x: u32) u32 {
        \\    return 1 / x;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(y)); }
    , &[_][]const u8{
        "tmp.zig:3:14: error: division by zero",
        "tmp.zig:1:14: note: referenced here",
    });

    cases.add("branch on undefined value",
        \\const x = if (undefined) true else false;
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(x)); }
    , &[_][]const u8{
        "tmp.zig:1:15: error: use of undefined value here causes undefined behavior",
    });

    cases.add("div on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a / a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("div assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a /= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("mod on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a % a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("mod assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a %= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("add on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a + a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("add assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a += a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("add wrap on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a +% a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("add wrap assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a +%= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("sub on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a - a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("sub assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a -= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("sub wrap on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a -% a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("sub wrap assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a -%= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("mult on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a * a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("mult assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a *= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("mult wrap on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a *% a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("mult wrap assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a *%= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("shift left on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a << 2;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("shift left assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a <<= 2;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("shift right on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a >> 2;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("shift left assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a >>= 2;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin and on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a & a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin and assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a &= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin or on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a | a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin or assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a |= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin xor on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = a ^ a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin xor assign on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    a ^= a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: use of undefined value here causes undefined behavior",
    });

    cases.add("comparison operators with undefined value",
        \\// operator ==
        \\comptime {
        \\    var a: i64 = undefined;
        \\    var x: i32 = 0;
        \\    if (a == a) x += 1;
        \\}
        \\// operator !=
        \\comptime {
        \\    var a: i64 = undefined;
        \\    var x: i32 = 0;
        \\    if (a != a) x += 1;
        \\}
        \\// operator >
        \\comptime {
        \\    var a: i64 = undefined;
        \\    var x: i32 = 0;
        \\    if (a > a) x += 1;
        \\}
        \\// operator <
        \\comptime {
        \\    var a: i64 = undefined;
        \\    var x: i32 = 0;
        \\    if (a < a) x += 1;
        \\}
        \\// operator >=
        \\comptime {
        \\    var a: i64 = undefined;
        \\    var x: i32 = 0;
        \\    if (a >= a) x += 1;
        \\}
        \\// operator <=
        \\comptime {
        \\    var a: i64 = undefined;
        \\    var x: i32 = 0;
        \\    if (a <= a) x += 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:11: error: use of undefined value here causes undefined behavior",
        "tmp.zig:11:11: error: use of undefined value here causes undefined behavior",
        "tmp.zig:17:11: error: use of undefined value here causes undefined behavior",
        "tmp.zig:23:11: error: use of undefined value here causes undefined behavior",
        "tmp.zig:29:11: error: use of undefined value here causes undefined behavior",
        "tmp.zig:35:11: error: use of undefined value here causes undefined behavior",
    });

    cases.add("and on undefined value",
        \\comptime {
        \\    var a: bool = undefined;
        \\    _ = a and a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("or on undefined value",
        \\comptime {
        \\    var a: bool = undefined;
        \\    _ = a or a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: use of undefined value here causes undefined behavior",
    });

    cases.add("negate on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = -a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:10: error: use of undefined value here causes undefined behavior",
    });

    cases.add("negate wrap on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = -%a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:11: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bin not on undefined value",
        \\comptime {
        \\    var a: i64 = undefined;
        \\    _ = ~a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:10: error: use of undefined value here causes undefined behavior",
    });

    cases.add("bool not on undefined value",
        \\comptime {
        \\    var a: bool = undefined;
        \\    _ = !a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:10: error: use of undefined value here causes undefined behavior",
    });

    cases.add("orelse on undefined value",
        \\comptime {
        \\    var a: ?bool = undefined;
        \\    _ = a orelse false;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:11: error: use of undefined value here causes undefined behavior",
    });

    cases.add("catch on undefined value",
        \\comptime {
        \\    var a: anyerror!bool = undefined;
        \\    _ = a catch |err| false;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:11: error: use of undefined value here causes undefined behavior",
    });

    cases.add("deref on undefined value",
        \\comptime {
        \\    var a: *u8 = undefined;
        \\    _ = a.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:9: error: attempt to dereference undefined value",
    });

    cases.add("endless loop in function evaluation",
        \\const seventh_fib_number = fibbonaci(7);
        \\fn fibbonaci(x: i32) i32 {
        \\    return fibbonaci(x - 1) + fibbonaci(x - 2);
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(seventh_fib_number)); }
    , &[_][]const u8{
        "tmp.zig:3:21: error: evaluation exceeded 1000 backwards branches",
        "tmp.zig:1:37: note: referenced here",
        "tmp.zig:6:50: note: referenced here",
    });

    cases.add("@embedFile with bogus file",
        \\const resource = @embedFile("bogus.txt",);
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(resource)); }
    , &[_][]const u8{
        "tmp.zig:1:29: error: unable to find '",
        "bogus.txt'",
    });

    cases.add("non-const expression in struct literal outside function",
        \\const Foo = struct {
        \\    x: i32,
        \\};
        \\const a = Foo {.x = get_it()};
        \\extern fn get_it() i32;
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(a)); }
    , &[_][]const u8{
        "tmp.zig:4:21: error: unable to evaluate constant expression",
    });

    cases.add("non-const expression function call with struct return value outside function",
        \\const Foo = struct {
        \\    x: i32,
        \\};
        \\const a = get_it();
        \\fn get_it() Foo {
        \\    global_side_effect = true;
        \\    return Foo {.x = 13};
        \\}
        \\var global_side_effect = false;
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(a)); }
    , &[_][]const u8{
        "tmp.zig:6:26: error: unable to evaluate constant expression",
        "tmp.zig:4:17: note: referenced here",
    });

    cases.add("undeclared identifier error should mark fn as impure",
        \\export fn foo() void {
        \\    test_a_thing();
        \\}
        \\fn test_a_thing() void {
        \\    bad_fn_call();
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: use of undeclared identifier 'bad_fn_call'",
    });

    cases.add("illegal comparison of types",
        \\fn bad_eql_1(a: []u8, b: []u8) bool {
        \\    return a == b;
        \\}
        \\const EnumWithData = union(enum) {
        \\    One: void,
        \\    Two: i32,
        \\};
        \\fn bad_eql_2(a: *const EnumWithData, b: *const EnumWithData) bool {
        \\    return a.* == b.*;
        \\}
        \\
        \\export fn entry1() usize { return @sizeOf(@TypeOf(bad_eql_1)); }
        \\export fn entry2() usize { return @sizeOf(@TypeOf(bad_eql_2)); }
    , &[_][]const u8{
        "tmp.zig:2:14: error: operator not allowed for type '[]u8'",
        "tmp.zig:9:16: error: operator not allowed for type 'EnumWithData'",
    });

    cases.add("non-const switch number literal",
        \\export fn foo() void {
        \\    const x = switch (bar()) {
        \\        1, 2 => 1,
        \\        3, 4 => 2,
        \\        else => 3,
        \\    };
        \\}
        \\fn bar() i32 {
        \\    return 2;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:17: error: cannot store runtime value in type 'comptime_int'",
    });

    cases.add("atomic orderings of cmpxchg - failure stricter than success",
        \\const AtomicOrder = @import("builtin").AtomicOrder;
        \\export fn f() void {
        \\    var x: i32 = 1234;
        \\    while (!@cmpxchgWeak(i32, &x, 1234, 5678, AtomicOrder.Monotonic, AtomicOrder.SeqCst)) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:4:81: error: failure atomic ordering must be no stricter than success",
    });

    cases.add("atomic orderings of cmpxchg - success Monotonic or stricter",
        \\const AtomicOrder = @import("builtin").AtomicOrder;
        \\export fn f() void {
        \\    var x: i32 = 1234;
        \\    while (!@cmpxchgWeak(i32, &x, 1234, 5678, AtomicOrder.Unordered, AtomicOrder.Unordered)) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:4:58: error: success atomic ordering must be Monotonic or stricter",
    });

    cases.add("negation overflow in function evaluation",
        \\const y = neg(-128);
        \\fn neg(x: i8) i8 {
        \\    return -x;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(y)); }
    , &[_][]const u8{
        "tmp.zig:3:12: error: negation caused overflow",
        "tmp.zig:1:14: note: referenced here",
    });

    cases.add("add overflow in function evaluation",
        \\const y = add(65530, 10);
        \\fn add(a: u16, b: u16) u16 {
        \\    return a + b;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(y)); }
    , &[_][]const u8{
        "tmp.zig:3:14: error: operation caused overflow",
        "tmp.zig:1:14: note: referenced here",
    });

    cases.add("sub overflow in function evaluation",
        \\const y = sub(10, 20);
        \\fn sub(a: u16, b: u16) u16 {
        \\    return a - b;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(y)); }
    , &[_][]const u8{
        "tmp.zig:3:14: error: operation caused overflow",
        "tmp.zig:1:14: note: referenced here",
    });

    cases.add("mul overflow in function evaluation",
        \\const y = mul(300, 6000);
        \\fn mul(a: u16, b: u16) u16 {
        \\    return a * b;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(y)); }
    , &[_][]const u8{
        "tmp.zig:3:14: error: operation caused overflow",
        "tmp.zig:1:14: note: referenced here",
    });

    cases.add("truncate sign mismatch",
        \\fn f() i8 {
        \\    var x: u32 = 10;
        \\    return @truncate(i8, x);
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:3:26: error: expected signed integer type, found 'u32'",
    });

    cases.add("try in function with non error return type",
        \\export fn f() void {
        \\    try something();
        \\}
        \\fn something() anyerror!void { }
    , &[_][]const u8{
        "tmp.zig:2:5: error: expected type 'void', found 'anyerror'",
        "tmp.zig:1:15: note: return type declared here",
    });

    cases.add("invalid pointer for var type",
        \\extern fn ext() usize;
        \\var bytes: [ext()]u8 = undefined;
        \\export fn f() void {
        \\    for (bytes) |*b, i| {
        \\        b.* = @as(u8, i);
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:2:13: error: unable to evaluate constant expression",
    });

    cases.add("export function with comptime parameter",
        \\export fn foo(comptime x: i32, y: i32) i32{
        \\    return x + y;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:15: error: comptime parameter not allowed in function with calling convention 'C'",
    });

    cases.add("extern function with comptime parameter",
        \\extern fn foo(comptime x: i32, y: i32) i32;
        \\fn f() i32 {
        \\    return foo(1, 2);
        \\}
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:1:15: error: comptime parameter not allowed in function with calling convention 'C'",
    });

    cases.add("convert fixed size array to slice with invalid size",
        \\export fn f() void {
        \\    var array: [5]u8 = undefined;
        \\    var foo = @bytesToSlice(u32, &array)[0];
        \\}
    , &[_][]const u8{
        "tmp.zig:3:15: error: unable to convert [5]u8 to []align(1) u32: size mismatch",
        "tmp.zig:3:29: note: u32 has size 4; remaining bytes: 1",
    });

    cases.add("non-pure function returns type",
        \\var a: u32 = 0;
        \\pub fn List(comptime T: type) type {
        \\    a += 1;
        \\    return SmallList(T, 8);
        \\}
        \\
        \\pub fn SmallList(comptime T: type, comptime STATIC_SIZE: usize) type {
        \\    return struct {
        \\        items: []T,
        \\        length: usize,
        \\        prealloc_items: [STATIC_SIZE]T,
        \\    };
        \\}
        \\
        \\export fn function_with_return_type_type() void {
        \\    var list: List(i32) = undefined;
        \\    list.length = 10;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:7: error: unable to evaluate constant expression",
        "tmp.zig:16:19: note: referenced here",
    });

    cases.add("bogus method call on slice",
        \\var self = "aoeu";
        \\fn f(m: []const u8) void {
        \\    m.copy(u8, self[0..], m);
        \\}
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:3:6: error: no member named 'copy' in '[]const u8'",
    });

    cases.add("wrong number of arguments for method fn call",
        \\const Foo = struct {
        \\    fn method(self: *const Foo, a: i32) void {}
        \\};
        \\fn f(foo: *const Foo) void {
        \\
        \\    foo.method(1, 2);
        \\}
        \\export fn entry() usize { return @sizeOf(@TypeOf(f)); }
    , &[_][]const u8{
        "tmp.zig:6:15: error: expected 2 arguments, found 3",
    });

    cases.add("assign through constant pointer",
        \\export fn f() void {
        \\  var cstr = "Hat";
        \\  cstr[0] = 'W';
        \\}
    , &[_][]const u8{
        "tmp.zig:3:13: error: cannot assign to constant",
    });

    cases.add("assign through constant slice",
        \\export fn f() void {
        \\  var cstr: []const u8 = "Hat";
        \\  cstr[0] = 'W';
        \\}
    , &[_][]const u8{
        "tmp.zig:3:13: error: cannot assign to constant",
    });

    cases.add("main function with bogus args type",
        \\pub fn main(args: [][]bogus) !void {}
    , &[_][]const u8{
        "tmp.zig:1:23: error: use of undeclared identifier 'bogus'",
    });

    cases.add("misspelled type with pointer only reference",
        \\const JasonHM = u8;
        \\const JasonList = *JsonNode;
        \\
        \\const JsonOA = union(enum) {
        \\    JSONArray: JsonList,
        \\    JSONObject: JasonHM,
        \\};
        \\
        \\const JsonType = union(enum) {
        \\    JSONNull: void,
        \\    JSONInteger: isize,
        \\    JSONDouble: f64,
        \\    JSONBool: bool,
        \\    JSONString: []u8,
        \\    JSONArray: void,
        \\    JSONObject: void,
        \\};
        \\
        \\pub const JsonNode = struct {
        \\    kind: JsonType,
        \\    jobject: ?JsonOA,
        \\};
        \\
        \\fn foo() void {
        \\    var jll: JasonList = undefined;
        \\    jll.init(1234);
        \\    var jd = JsonNode {.kind = JsonType.JSONArray , .jobject = JsonOA.JSONArray {jll} };
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:5:16: error: use of undeclared identifier 'JsonList'",
    });

    cases.add("method call with first arg type primitive",
        \\const Foo = struct {
        \\    x: i32,
        \\
        \\    fn init(x: i32) Foo {
        \\        return Foo {
        \\            .x = x,
        \\        };
        \\    }
        \\};
        \\
        \\export fn f() void {
        \\    const derp = Foo.init(3);
        \\
        \\    derp.init();
        \\}
    , &[_][]const u8{
        "tmp.zig:14:5: error: expected type 'i32', found 'Foo'",
    });

    cases.add("method call with first arg type wrong container",
        \\pub const List = struct {
        \\    len: usize,
        \\    allocator: *Allocator,
        \\
        \\    pub fn init(allocator: *Allocator) List {
        \\        return List {
        \\            .len = 0,
        \\            .allocator = allocator,
        \\        };
        \\    }
        \\};
        \\
        \\pub var global_allocator = Allocator {
        \\    .field = 1234,
        \\};
        \\
        \\pub const Allocator = struct {
        \\    field: i32,
        \\};
        \\
        \\export fn foo() void {
        \\    var x = List.init(&global_allocator);
        \\    x.init();
        \\}
    , &[_][]const u8{
        "tmp.zig:23:5: error: expected type '*Allocator', found '*List'",
    });

    cases.add("binary not on number literal",
        \\const TINY_QUANTUM_SHIFT = 4;
        \\const TINY_QUANTUM_SIZE = 1 << TINY_QUANTUM_SHIFT;
        \\var block_aligned_stuff: usize = (4 + TINY_QUANTUM_SIZE) & ~(TINY_QUANTUM_SIZE - 1);
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(block_aligned_stuff)); }
    , &[_][]const u8{
        "tmp.zig:3:60: error: unable to perform binary not operation on type 'comptime_int'",
    });

    cases.addCase(x: {
        const tc = cases.create("multiple files with private function error",
            \\const foo = @import("foo.zig",);
            \\
            \\export fn callPrivFunction() void {
            \\    foo.privateFunction();
            \\}
        , &[_][]const u8{
            "tmp.zig:4:8: error: 'privateFunction' is private",
            "foo.zig:1:1: note: declared here",
        });

        tc.addSourceFile("foo.zig",
            \\fn privateFunction() void { }
        );

        break :x tc;
    });

    cases.add("container init with non-type",
        \\const zero: i32 = 0;
        \\const a = zero{1};
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(a)); }
    , &[_][]const u8{
        "tmp.zig:2:11: error: expected type 'type', found 'i32'",
    });

    cases.add("assign to constant field",
        \\const Foo = struct {
        \\    field: i32,
        \\};
        \\export fn derp() void {
        \\    const f = Foo {.field = 1234,};
        \\    f.field = 0;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:15: error: cannot assign to constant",
    });

    cases.add("return from defer expression",
        \\pub fn testTrickyDefer() !void {
        \\    defer canFail() catch {};
        \\
        \\    defer try canFail();
        \\
        \\    const a = maybeInt() orelse return;
        \\}
        \\
        \\fn canFail() anyerror!void { }
        \\
        \\pub fn maybeInt() ?i32 {
        \\    return 0;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(testTrickyDefer)); }
    , &[_][]const u8{
        "tmp.zig:4:11: error: cannot return from defer expression",
    });

    cases.add("assign too big number to u16",
        \\export fn foo() void {
        \\    var vga_mem: u16 = 0xB8000;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:24: error: integer value 753664 cannot be coerced to type 'u16'",
    });

    cases.add("global variable alignment non power of 2",
        \\const some_data: [100]u8 align(3) = undefined;
        \\export fn entry() usize { return @sizeOf(@TypeOf(some_data)); }
    , &[_][]const u8{
        "tmp.zig:1:32: error: alignment value 3 is not a power of 2",
    });

    cases.add("function alignment non power of 2",
        \\extern fn foo() align(3) void;
        \\export fn entry() void { return foo(); }
    , &[_][]const u8{
        "tmp.zig:1:23: error: alignment value 3 is not a power of 2",
    });

    cases.add("compile log",
        \\export fn foo() void {
        \\    comptime bar(12, "hi",);
        \\}
        \\fn bar(a: i32, b: []const u8) void {
        \\    @compileLog("begin",);
        \\    @compileLog("a", a, "b", b);
        \\    @compileLog("end",);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: found compile log statement",
        "tmp.zig:6:5: error: found compile log statement",
        "tmp.zig:7:5: error: found compile log statement",
    });

    cases.add("casting bit offset pointer to regular pointer",
        \\const BitField = packed struct {
        \\    a: u3,
        \\    b: u3,
        \\    c: u2,
        \\};
        \\
        \\fn foo(bit_field: *const BitField) u3 {
        \\    return bar(&bit_field.b);
        \\}
        \\
        \\fn bar(x: *const u3) u3 {
        \\    return x.*;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:8:26: error: expected type '*const u3', found '*align(:3:1) const u3'",
    });

    cases.add("referring to a struct that is invalid",
        \\const UsbDeviceRequest = struct {
        \\    Type: u8,
        \\};
        \\
        \\export fn foo() void {
        \\    comptime assert(@sizeOf(UsbDeviceRequest) == 0x8);
        \\}
        \\
        \\fn assert(ok: bool) void {
        \\    if (!ok) unreachable;
        \\}
    , &[_][]const u8{
        "tmp.zig:10:14: error: unable to evaluate constant expression",
        "tmp.zig:6:20: note: referenced here",
    });

    cases.add("control flow uses comptime var at runtime",
        \\export fn foo() void {
        \\    comptime var i = 0;
        \\    while (i < 5) : (i += 1) {
        \\        bar();
        \\    }
        \\}
        \\
        \\fn bar() void { }
    , &[_][]const u8{
        "tmp.zig:3:5: error: control flow attempts to use compile-time variable at runtime",
        "tmp.zig:3:24: note: compile-time variable assigned here",
    });

    cases.add("ignored return value",
        \\export fn foo() void {
        \\    bar();
        \\}
        \\fn bar() i32 { return 0; }
    , &[_][]const u8{
        "tmp.zig:2:8: error: expression value is ignored",
    });

    cases.add("ignored assert-err-ok return value",
        \\export fn foo() void {
        \\    bar() catch unreachable;
        \\}
        \\fn bar() anyerror!i32 { return 0; }
    , &[_][]const u8{
        "tmp.zig:2:11: error: expression value is ignored",
    });

    cases.add("ignored statement value",
        \\export fn foo() void {
        \\    1;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: expression value is ignored",
    });

    cases.add("ignored comptime statement value",
        \\export fn foo() void {
        \\    comptime {1;}
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: expression value is ignored",
    });

    cases.add("ignored comptime value",
        \\export fn foo() void {
        \\    comptime 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: expression value is ignored",
    });

    cases.add("ignored defered statement value",
        \\export fn foo() void {
        \\    defer {1;}
        \\}
    , &[_][]const u8{
        "tmp.zig:2:12: error: expression value is ignored",
    });

    cases.add("ignored defered function call",
        \\export fn foo() void {
        \\    defer bar();
        \\}
        \\fn bar() anyerror!i32 { return 0; }
    , &[_][]const u8{
        "tmp.zig:2:14: error: expression value is ignored",
    });

    cases.add("dereference an array",
        \\var s_buffer: [10]u8 = undefined;
        \\pub fn pass(in: []u8) []u8 {
        \\    var out = &s_buffer;
        \\    out.*.* = in[0];
        \\    return out.*[0..1];
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(pass)); }
    , &[_][]const u8{
        "tmp.zig:4:10: error: attempt to dereference non-pointer type '[10]u8'",
    });

    cases.add("pass const ptr to mutable ptr fn",
        \\fn foo() bool {
        \\    const a = @as([]const u8, "a",);
        \\    const b = &a;
        \\    return ptrEql(b, b);
        \\}
        \\fn ptrEql(a: *[]const u8, b: *[]const u8) bool {
        \\    return true;
        \\}
        \\
        \\export fn entry() usize { return @sizeOf(@TypeOf(foo)); }
    , &[_][]const u8{
        "tmp.zig:4:19: error: expected type '*[]const u8', found '*const []const u8'",
    });

    cases.addCase(x: {
        const tc = cases.create("export collision",
            \\const foo = @import("foo.zig",);
            \\
            \\export fn bar() usize {
            \\    return foo.baz;
            \\}
        , &[_][]const u8{
            "foo.zig:1:1: error: exported symbol collision: 'bar'",
            "tmp.zig:3:1: note: other symbol here",
        });

        tc.addSourceFile("foo.zig",
            \\export fn bar() void {}
            \\pub const baz = 1234;
        );

        break :x tc;
    });

    cases.add("implicit cast from array to mutable slice",
        \\var global_array: [10]i32 = undefined;
        \\fn foo(param: []i32) void {}
        \\export fn entry() void {
        \\    foo(global_array);
        \\}
    , &[_][]const u8{
        "tmp.zig:4:9: error: expected type '[]i32', found '[10]i32'",
    });

    cases.add("ptrcast to non-pointer",
        \\export fn entry(a: *i32) usize {
        \\    return @ptrCast(usize, a);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:21: error: expected pointer, found 'usize'",
    });

    cases.add("asm at compile time",
        \\comptime {
        \\    doSomeAsm();
        \\}
        \\
        \\fn doSomeAsm() void {
        \\    asm volatile (
        \\        \\.globl aoeu;
        \\        \\.type aoeu, @function;
        \\        \\.set aoeu, derp;
        \\    );
        \\}
    , &[_][]const u8{
        "tmp.zig:6:5: error: unable to evaluate constant expression",
    });

    cases.add("invalid member of builtin enum",
        \\const builtin = @import("builtin",);
        \\export fn entry() void {
        \\    const foo = builtin.Arch.x86;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:29: error: container 'std.target.Arch' has no member called 'x86'",
    });

    cases.add("int to ptr of 0 bits",
        \\export fn foo() void {
        \\    var x: usize = 0x1000;
        \\    var y: *void = @intToPtr(*void, x);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:30: error: type '*void' has 0 bits and cannot store information",
    });

    cases.add("@fieldParentPtr - non struct",
        \\const Foo = i32;
        \\export fn foo(a: *i32) *Foo {
        \\    return @fieldParentPtr(Foo, "a", a);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:28: error: expected struct type, found 'i32'",
    });

    cases.add("@fieldParentPtr - bad field name",
        \\const Foo = extern struct {
        \\    derp: i32,
        \\};
        \\export fn foo(a: *i32) *Foo {
        \\    return @fieldParentPtr(Foo, "a", a);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:33: error: struct 'Foo' has no field 'a'",
    });

    cases.add("@fieldParentPtr - field pointer is not pointer",
        \\const Foo = extern struct {
        \\    a: i32,
        \\};
        \\export fn foo(a: i32) *Foo {
        \\    return @fieldParentPtr(Foo, "a", a);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:38: error: expected pointer, found 'i32'",
    });

    cases.add("@fieldParentPtr - comptime field ptr not based on struct",
        \\const Foo = struct {
        \\    a: i32,
        \\    b: i32,
        \\};
        \\const foo = Foo { .a = 1, .b = 2, };
        \\
        \\comptime {
        \\    const field_ptr = @intToPtr(*i32, 0x1234);
        \\    const another_foo_ptr = @fieldParentPtr(Foo, "b", field_ptr);
        \\}
    , &[_][]const u8{
        "tmp.zig:9:55: error: pointer value not based on parent struct",
    });

    cases.add("@fieldParentPtr - comptime wrong field index",
        \\const Foo = struct {
        \\    a: i32,
        \\    b: i32,
        \\};
        \\const foo = Foo { .a = 1, .b = 2, };
        \\
        \\comptime {
        \\    const another_foo_ptr = @fieldParentPtr(Foo, "b", &foo.a);
        \\}
    , &[_][]const u8{
        "tmp.zig:8:29: error: field 'b' has index 1 but pointer value is index 0 of struct 'Foo'",
    });

    cases.add("@byteOffsetOf - non struct",
        \\const Foo = i32;
        \\export fn foo() usize {
        \\    return @byteOffsetOf(Foo, "a",);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:26: error: expected struct type, found 'i32'",
    });

    cases.add("@byteOffsetOf - bad field name",
        \\const Foo = struct {
        \\    derp: i32,
        \\};
        \\export fn foo() usize {
        \\    return @byteOffsetOf(Foo, "a",);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:31: error: struct 'Foo' has no field 'a'",
    });

    cases.addExe("missing main fn in executable",
        \\
    , &[_][]const u8{
        "error: root source file has no member called 'main'",
    });

    cases.addExe("private main fn",
        \\fn main() void {}
    , &[_][]const u8{
        "error: 'main' is private",
        "tmp.zig:1:1: note: declared here",
    });

    cases.add("setting a section on a local variable",
        \\export fn entry() i32 {
        \\    var foo: i32 linksection(".text2") = 1234;
        \\    return foo;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:30: error: cannot set section of local variable 'foo'",
    });

    cases.add("returning address of local variable - simple",
        \\export fn foo() *i32 {
        \\    var a: i32 = undefined;
        \\    return &a;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:13: error: function returns address of local variable",
    });

    cases.add("returning address of local variable - phi",
        \\export fn foo(c: bool) *i32 {
        \\    var a: i32 = undefined;
        \\    var b: i32 = undefined;
        \\    return if (c) &a else &b;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:12: error: function returns address of local variable",
    });

    cases.add("inner struct member shadowing outer struct member",
        \\fn A() type {
        \\    return struct {
        \\        b: B(),
        \\
        \\        const Self = @This();
        \\
        \\        fn B() type {
        \\            return struct {
        \\                const Self = @This();
        \\            };
        \\        }
        \\    };
        \\}
        \\comptime {
        \\    assert(A().B().Self != A().Self);
        \\}
        \\fn assert(ok: bool) void {
        \\    if (!ok) unreachable;
        \\}
    , &[_][]const u8{
        "tmp.zig:9:17: error: redefinition of 'Self'",
        "tmp.zig:5:9: note: previous definition is here",
    });

    cases.add("while expected bool, got optional",
        \\export fn foo() void {
        \\    while (bar()) {}
        \\}
        \\fn bar() ?i32 { return 1; }
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected type 'bool', found '?i32'",
    });

    cases.add("while expected bool, got error union",
        \\export fn foo() void {
        \\    while (bar()) {}
        \\}
        \\fn bar() anyerror!i32 { return 1; }
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected type 'bool', found 'anyerror!i32'",
    });

    cases.add("while expected optional, got bool",
        \\export fn foo() void {
        \\    while (bar()) |x| {}
        \\}
        \\fn bar() bool { return true; }
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected optional type, found 'bool'",
    });

    cases.add("while expected optional, got error union",
        \\export fn foo() void {
        \\    while (bar()) |x| {}
        \\}
        \\fn bar() anyerror!i32 { return 1; }
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected optional type, found 'anyerror!i32'",
    });

    cases.add("while expected error union, got bool",
        \\export fn foo() void {
        \\    while (bar()) |x| {} else |err| {}
        \\}
        \\fn bar() bool { return true; }
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected error union type, found 'bool'",
    });

    cases.add("while expected error union, got optional",
        \\export fn foo() void {
        \\    while (bar()) |x| {} else |err| {}
        \\}
        \\fn bar() ?i32 { return 1; }
    , &[_][]const u8{
        "tmp.zig:2:15: error: expected error union type, found '?i32'",
    });

    cases.add("inline fn calls itself indirectly",
        \\export fn foo() void {
        \\    bar();
        \\}
        \\inline fn bar() void {
        \\    baz();
        \\    quux();
        \\}
        \\inline fn baz() void {
        \\    bar();
        \\    quux();
        \\}
        \\extern fn quux() void;
    , &[_][]const u8{
        "tmp.zig:4:1: error: unable to inline function",
    });

    cases.add("save reference to inline function",
        \\export fn foo() void {
        \\    quux(@ptrToInt(bar));
        \\}
        \\inline fn bar() void { }
        \\extern fn quux(usize) void;
    , &[_][]const u8{
        "tmp.zig:4:1: error: unable to inline function",
    });

    cases.add("signed integer division",
        \\export fn foo(a: i32, b: i32) i32 {
        \\    return a / b;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:14: error: division with 'i32' and 'i32': signed integers must use @divTrunc, @divFloor, or @divExact",
    });

    cases.add("signed integer remainder division",
        \\export fn foo(a: i32, b: i32) i32 {
        \\    return a % b;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:14: error: remainder division with 'i32' and 'i32': signed integers and floats must use @rem or @mod",
    });

    cases.add("compile-time division by zero",
        \\comptime {
        \\    const a: i32 = 1;
        \\    const b: i32 = 0;
        \\    const c = a / b;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:17: error: division by zero",
    });

    cases.add("compile-time remainder division by zero",
        \\comptime {
        \\    const a: i32 = 1;
        \\    const b: i32 = 0;
        \\    const c = a % b;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:17: error: division by zero",
    });

    cases.add("@setRuntimeSafety twice for same scope",
        \\export fn foo() void {
        \\    @setRuntimeSafety(false);
        \\    @setRuntimeSafety(false);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: runtime safety set twice for same scope",
        "tmp.zig:2:5: note: first set here",
    });

    cases.add("@setFloatMode twice for same scope",
        \\export fn foo() void {
        \\    @setFloatMode(@import("builtin").FloatMode.Optimized);
        \\    @setFloatMode(@import("builtin").FloatMode.Optimized);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: float mode set twice for same scope",
        "tmp.zig:2:5: note: first set here",
    });

    cases.add("array access of type",
        \\export fn foo() void {
        \\    var b: u8[40] = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:14: error: array access of non-array type 'type'",
    });

    cases.add("cannot break out of defer expression",
        \\export fn foo() void {
        \\    while (true) {
        \\        defer {
        \\            break;
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:4:13: error: cannot break out of defer expression",
    });

    cases.add("cannot continue out of defer expression",
        \\export fn foo() void {
        \\    while (true) {
        \\        defer {
        \\            continue;
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:4:13: error: cannot continue out of defer expression",
    });

    cases.add("calling a generic function only known at runtime",
        \\var foos = [_]fn(var) void { foo1, foo2 };
        \\
        \\fn foo1(arg: var) void {}
        \\fn foo2(arg: var) void {}
        \\
        \\pub fn main() !void {
        \\    foos[0](true);
        \\}
    , &[_][]const u8{
        "tmp.zig:7:9: error: calling a generic function requires compile-time known function value",
    });

    cases.add("@compileError shows traceback of references that caused it",
        \\const foo = @compileError("aoeu",);
        \\
        \\const bar = baz + foo;
        \\const baz = 1;
        \\
        \\export fn entry() i32 {
        \\    return bar;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:13: error: aoeu",
        "tmp.zig:3:19: note: referenced here",
        "tmp.zig:7:12: note: referenced here",
    });

    cases.add("float literal too large error",
        \\comptime {
        \\    const a = 0x1.0p18495;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: float literal out of range of any type",
    });

    cases.add("float literal too small error (denormal)",
        \\comptime {
        \\    const a = 0x1.0p-19000;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: float literal out of range of any type",
    });

    cases.add("explicit cast float literal to integer when there is a fraction component",
        \\export fn entry() i32 {
        \\    return @as(i32, 12.34);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:21: error: fractional component prevents float value 12.340000 from being casted to type 'i32'",
    });

    cases.add("non pointer given to @ptrToInt",
        \\export fn entry(x: i32) usize {
        \\    return @ptrToInt(x);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:22: error: expected pointer, found 'i32'",
    });

    cases.add("@shlExact shifts out 1 bits",
        \\comptime {
        \\    const x = @shlExact(@as(u8, 0b01010101), 2);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: operation caused overflow",
    });

    cases.add("@shrExact shifts out 1 bits",
        \\comptime {
        \\    const x = @shrExact(@as(u8, 0b10101010), 2);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:15: error: exact shift shifted out 1 bits",
    });

    cases.add("shifting without int type or comptime known",
        \\export fn entry(x: u8) u8 {
        \\    return 0x11 << x;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:17: error: LHS of shift must be an integer type, or RHS must be compile-time known",
    });

    cases.add("shifting RHS is log2 of LHS int bit width",
        \\export fn entry(x: u8, y: u8) u8 {
        \\    return x << y;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:17: error: expected type 'u3', found 'u8'",
    });

    cases.add("globally shadowing a primitive type",
        \\const u16 = @intType(false, 8);
        \\export fn entry() void {
        \\    const a: u16 = 300;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: declaration shadows primitive type 'u16'",
    });

    cases.add("implicitly increasing pointer alignment",
        \\const Foo = packed struct {
        \\    a: u8,
        \\    b: u32,
        \\};
        \\
        \\export fn entry() void {
        \\    var foo = Foo { .a = 1, .b = 10 };
        \\    bar(&foo.b);
        \\}
        \\
        \\fn bar(x: *u32) void {
        \\    x.* += 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:8:13: error: expected type '*u32', found '*align(1) u32'",
    });

    cases.add("implicitly increasing slice alignment",
        \\const Foo = packed struct {
        \\    a: u8,
        \\    b: u32,
        \\};
        \\
        \\export fn entry() void {
        \\    var foo = Foo { .a = 1, .b = 10 };
        \\    foo.b += 1;
        \\    bar(@as(*[1]u32, &foo.b)[0..]);
        \\}
        \\
        \\fn bar(x: []u32) void {
        \\    x[0] += 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:9:26: error: cast increases pointer alignment",
        "tmp.zig:9:26: note: '*align(1) u32' has alignment 1",
        "tmp.zig:9:26: note: '*[1]u32' has alignment 4",
    });

    cases.add("increase pointer alignment in @ptrCast",
        \\export fn entry() u32 {
        \\    var bytes: [4]u8 = [_]u8{0x01, 0x02, 0x03, 0x04};
        \\    const ptr = @ptrCast(*u32, &bytes[0]);
        \\    return ptr.*;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:17: error: cast increases pointer alignment",
        "tmp.zig:3:38: note: '*u8' has alignment 1",
        "tmp.zig:3:26: note: '*u32' has alignment 4",
    });

    cases.add("@alignCast expects pointer or slice",
        \\export fn entry() void {
        \\    @alignCast(4, @as(u32, 3));
        \\}
    , &[_][]const u8{
        "tmp.zig:2:19: error: expected pointer or slice, found 'u32'",
    });

    cases.add("passing an under-aligned function pointer",
        \\export fn entry() void {
        \\    testImplicitlyDecreaseFnAlign(alignedSmall, 1234);
        \\}
        \\fn testImplicitlyDecreaseFnAlign(ptr: fn () align(8) i32, answer: i32) void {
        \\    if (ptr() != answer) unreachable;
        \\}
        \\fn alignedSmall() align(4) i32 { return 1234; }
    , &[_][]const u8{
        "tmp.zig:2:35: error: expected type 'fn() align(8) i32', found 'fn() align(4) i32'",
    });

    cases.add("passing a not-aligned-enough pointer to cmpxchg",
        \\const AtomicOrder = @import("builtin").AtomicOrder;
        \\export fn entry() bool {
        \\    var x: i32 align(1) = 1234;
        \\    while (!@cmpxchgWeak(i32, &x, 1234, 5678, AtomicOrder.SeqCst, AtomicOrder.SeqCst)) {}
        \\    return x == 5678;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:32: error: expected type '*i32', found '*align(1) i32'",
    });

    cases.add("wrong size to an array literal",
        \\comptime {
        \\    const array = [2]u8{1, 2, 3};
        \\}
    , &[_][]const u8{
        "tmp.zig:2:31: error: index 2 outside array of size 2",
    });

    cases.add("wrong pointer coerced to pointer to @OpaqueType()",
        \\const Derp = @OpaqueType();
        \\extern fn bar(d: *Derp) void;
        \\export fn foo() void {
        \\    var x = @as(u8, 1);
        \\    bar(@ptrCast(*c_void, &x));
        \\}
    , &[_][]const u8{
        "tmp.zig:5:9: error: expected type '*Derp', found '*c_void'",
    });

    cases.add("non-const variables of things that require const variables",
        \\export fn entry1() void {
        \\   var m2 = &2;
        \\}
        \\export fn entry2() void {
        \\   var a = undefined;
        \\}
        \\export fn entry3() void {
        \\   var b = 1;
        \\}
        \\export fn entry4() void {
        \\   var c = 1.0;
        \\}
        \\export fn entry5() void {
        \\   var d = null;
        \\}
        \\export fn entry6(opaque: *Opaque) void {
        \\   var e = opaque.*;
        \\}
        \\export fn entry7() void {
        \\   var f = i32;
        \\}
        \\export fn entry8() void {
        \\   var h = (Foo {}).bar;
        \\}
        \\export fn entry9() void {
        \\   var z: noreturn = return;
        \\}
        \\const Opaque = @OpaqueType();
        \\const Foo = struct {
        \\    fn bar(self: *const Foo) void {}
        \\};
    , &[_][]const u8{
        "tmp.zig:2:4: error: variable of type '*comptime_int' must be const or comptime",
        "tmp.zig:5:4: error: variable of type '(undefined)' must be const or comptime",
        "tmp.zig:8:4: error: variable of type 'comptime_int' must be const or comptime",
        "tmp.zig:11:4: error: variable of type 'comptime_float' must be const or comptime",
        "tmp.zig:14:4: error: variable of type '(null)' must be const or comptime",
        "tmp.zig:17:4: error: variable of type 'Opaque' not allowed",
        "tmp.zig:20:4: error: variable of type 'type' must be const or comptime",
        "tmp.zig:23:4: error: variable of type '(bound fn(*const Foo) void)' must be const or comptime",
        "tmp.zig:26:22: error: unreachable code",
    });

    cases.add("wrong types given to atomic order args in cmpxchg",
        \\export fn entry() void {
        \\    var x: i32 = 1234;
        \\    while (!@cmpxchgWeak(i32, &x, 1234, 5678, @as(u32, 1234), @as(u32, 1234))) {}
        \\}
    , &[_][]const u8{
        "tmp.zig:3:47: error: expected type 'std.builtin.AtomicOrder', found 'u32'",
    });

    cases.add("wrong types given to @export",
        \\fn entry() callconv(.C) void { }
        \\comptime {
        \\    @export("entry", entry, @as(u32, 1234));
        \\}
    , &[_][]const u8{
        "tmp.zig:3:29: error: expected type 'std.builtin.GlobalLinkage', found 'u32'",
    });

    cases.add("struct with invalid field",
        \\const std = @import("std",);
        \\const Allocator = std.mem.Allocator;
        \\const ArrayList = std.ArrayList;
        \\
        \\const HeaderWeight = enum {
        \\    H1, H2, H3, H4, H5, H6,
        \\};
        \\
        \\const MdText = ArrayList(u8);
        \\
        \\const MdNode = union(enum) {
        \\    Header: struct {
        \\        text: MdText,
        \\        weight: HeaderValue,
        \\    },
        \\};
        \\
        \\export fn entry() void {
        \\    const a = MdNode.Header {
        \\        .text = MdText.init(&std.debug.global_allocator),
        \\        .weight = HeaderWeight.H1,
        \\    };
        \\}
    , &[_][]const u8{
        "tmp.zig:14:17: error: use of undeclared identifier 'HeaderValue'",
    });

    cases.add("@setAlignStack outside function",
        \\comptime {
        \\    @setAlignStack(16);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: @setAlignStack outside function",
    });

    cases.add("@setAlignStack in naked function",
        \\export fn entry() callconv(.Naked) void {
        \\    @setAlignStack(16);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: @setAlignStack in naked function",
    });

    cases.add("@setAlignStack in inline function",
        \\export fn entry() void {
        \\    foo();
        \\}
        \\inline fn foo() void {
        \\    @setAlignStack(16);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:5: error: @setAlignStack in inline function",
    });

    cases.add("@setAlignStack set twice",
        \\export fn entry() void {
        \\    @setAlignStack(16);
        \\    @setAlignStack(16);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: alignstack set twice",
        "tmp.zig:2:5: note: first set here",
    });

    cases.add("@setAlignStack too big",
        \\export fn entry() void {
        \\    @setAlignStack(511 + 1);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: attempt to @setAlignStack(512); maximum is 256",
    });

    cases.add("storing runtime value in compile time variable then using it",
        \\const Mode = @import("builtin").Mode;
        \\
        \\fn Free(comptime filename: []const u8) TestCase {
        \\    return TestCase {
        \\        .filename = filename,
        \\        .problem_type = ProblemType.Free,
        \\    };
        \\}
        \\
        \\fn LibC(comptime filename: []const u8) TestCase {
        \\    return TestCase {
        \\        .filename = filename,
        \\        .problem_type = ProblemType.LinkLibC,
        \\    };
        \\}
        \\
        \\const TestCase = struct {
        \\    filename: []const u8,
        \\    problem_type: ProblemType,
        \\};
        \\
        \\const ProblemType = enum {
        \\    Free,
        \\    LinkLibC,
        \\};
        \\
        \\export fn entry() void {
        \\    const tests = [_]TestCase {
        \\        Free("001"),
        \\        Free("002"),
        \\        LibC("078"),
        \\        Free("116"),
        \\        Free("117"),
        \\    };
        \\
        \\    for ([_]Mode { Mode.Debug, Mode.ReleaseSafe, Mode.ReleaseFast }) |mode| {
        \\        inline for (tests) |test_case| {
        \\            const foo = test_case.filename ++ ".zig";
        \\        }
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:37:29: error: cannot store runtime value in compile time variable",
    });

    cases.add("field access of opaque type",
        \\const MyType = @OpaqueType();
        \\
        \\export fn entry() bool {
        \\    var x: i32 = 1;
        \\    return bar(@ptrCast(*MyType, &x));
        \\}
        \\
        \\fn bar(x: *MyType) bool {
        \\    return x.blah;
        \\}
    , &[_][]const u8{
        "tmp.zig:9:13: error: type '*MyType' does not support field access",
    });

    cases.add("carriage return special case", "fn test() bool {\r\n" ++
        "   true\r\n" ++
        "}\r\n", &[_][]const u8{
        "tmp.zig:1:17: error: invalid carriage return, only '\\n' line endings are supported",
    });

    cases.add("invalid legacy unicode escape",
        \\export fn entry() void {
        \\    const a = '\U1234';
        \\}
    , &[_][]const u8{
        "tmp.zig:2:17: error: invalid character: 'U'",
    });

    cases.add("invalid empty unicode escape",
        \\export fn entry() void {
        \\    const a = '\u{}';
        \\}
    , &[_][]const u8{
        "tmp.zig:2:19: error: empty unicode escape sequence",
    });

    cases.add("non-printable invalid character", "\xff\xfe" ++
        \\fn test() bool {\r
        \\    true\r
        \\}
    , &[_][]const u8{
        "tmp.zig:1:1: error: invalid character: '\\xff'",
    });

    cases.add("non-printable invalid character with escape alternative", "fn test() bool {\n" ++
        "\ttrue\n" ++
        "}\n", &[_][]const u8{
        "tmp.zig:2:1: error: invalid character: '\\t'",
    });

    cases.add("@ArgType given non function parameter",
        \\comptime {
        \\    _ = @ArgType(i32, 3);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:18: error: expected function, found 'i32'",
    });

    cases.add("@ArgType arg index out of bounds",
        \\comptime {
        \\    _ = @ArgType(@TypeOf(add), 2);
        \\}
        \\fn add(a: i32, b: i32) i32 { return a + b; }
    , &[_][]const u8{
        "tmp.zig:2:32: error: arg index 2 out of bounds; 'fn(i32, i32) i32' has 2 arguments",
    });

    cases.add("@memberType on unsupported type",
        \\comptime {
        \\    _ = @memberType(i32, 0);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:21: error: type 'i32' does not support @memberType",
    });

    cases.add("@memberType on enum",
        \\comptime {
        \\    _ = @memberType(Foo, 0);
        \\}
        \\const Foo = enum {A,};
    , &[_][]const u8{
        "tmp.zig:2:21: error: type 'Foo' does not support @memberType",
    });

    cases.add("@memberType struct out of bounds",
        \\comptime {
        \\    _ = @memberType(Foo, 0);
        \\}
        \\const Foo = struct {};
    , &[_][]const u8{
        "tmp.zig:2:26: error: member index 0 out of bounds; 'Foo' has 0 members",
    });

    cases.add("@memberType union out of bounds",
        \\comptime {
        \\    _ = @memberType(Foo, 1);
        \\}
        \\const Foo = union {A: void,};
    , &[_][]const u8{
        "tmp.zig:2:26: error: member index 1 out of bounds; 'Foo' has 1 members",
    });

    cases.add("@memberName on unsupported type",
        \\comptime {
        \\    _ = @memberName(i32, 0);
        \\}
    , &[_][]const u8{
        "tmp.zig:2:21: error: type 'i32' does not support @memberName",
    });

    cases.add("@memberName struct out of bounds",
        \\comptime {
        \\    _ = @memberName(Foo, 0);
        \\}
        \\const Foo = struct {};
    , &[_][]const u8{
        "tmp.zig:2:26: error: member index 0 out of bounds; 'Foo' has 0 members",
    });

    cases.add("@memberName enum out of bounds",
        \\comptime {
        \\    _ = @memberName(Foo, 1);
        \\}
        \\const Foo = enum {A,};
    , &[_][]const u8{
        "tmp.zig:2:26: error: member index 1 out of bounds; 'Foo' has 1 members",
    });

    cases.add("@memberName union out of bounds",
        \\comptime {
        \\    _ = @memberName(Foo, 1);
        \\}
        \\const Foo = union {A:i32,};
    , &[_][]const u8{
        "tmp.zig:2:26: error: member index 1 out of bounds; 'Foo' has 1 members",
    });

    cases.add("calling var args extern function, passing array instead of pointer",
        \\export fn entry() void {
        \\    foo("hello".*,);
        \\}
        \\pub extern fn foo(format: *const u8, ...) void;
    , &[_][]const u8{
        "tmp.zig:2:16: error: expected type '*const u8', found '[5:0]u8'",
    });

    cases.add("constant inside comptime function has compile error",
        \\const ContextAllocator = MemoryPool(usize);
        \\
        \\pub fn MemoryPool(comptime T: type) type {
        \\    const free_list_t = @compileError("aoeu",);
        \\
        \\    return struct {
        \\        free_list: free_list_t,
        \\    };
        \\}
        \\
        \\export fn entry() void {
        \\    var allocator: ContextAllocator = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:25: error: aoeu",
        "tmp.zig:1:36: note: referenced here",
        "tmp.zig:12:20: note: referenced here",
    });

    cases.add("specify enum tag type that is too small",
        \\const Small = enum (u2) {
        \\    One,
        \\    Two,
        \\    Three,
        \\    Four,
        \\    Five,
        \\};
        \\
        \\export fn entry() void {
        \\    var x = Small.One;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:5: error: enumeration value 4 too large for type 'u2'",
    });

    cases.add("specify non-integer enum tag type",
        \\const Small = enum (f32) {
        \\    One,
        \\    Two,
        \\    Three,
        \\};
        \\
        \\export fn entry() void {
        \\    var x = Small.One;
        \\}
    , &[_][]const u8{
        "tmp.zig:1:21: error: expected integer, found 'f32'",
    });

    cases.add("implicitly casting enum to tag type",
        \\const Small = enum(u2) {
        \\    One,
        \\    Two,
        \\    Three,
        \\    Four,
        \\};
        \\
        \\export fn entry() void {
        \\    var x: u2 = Small.Two;
        \\}
    , &[_][]const u8{
        "tmp.zig:9:22: error: expected type 'u2', found 'Small'",
    });

    cases.add("explicitly casting non tag type to enum",
        \\const Small = enum(u2) {
        \\    One,
        \\    Two,
        \\    Three,
        \\    Four,
        \\};
        \\
        \\export fn entry() void {
        \\    var y = @as(u3, 3);
        \\    var x = @intToEnum(Small, y);
        \\}
    , &[_][]const u8{
        "tmp.zig:10:31: error: expected type 'u2', found 'u3'",
    });

    cases.add("union fields with value assignments",
        \\const MultipleChoice = union {
        \\    A: i32 = 20,
        \\};
        \\export fn entry() void {
        \\    var x: MultipleChoice = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:14: error: untagged union field assignment",
        "tmp.zig:1:24: note: consider 'union(enum)' here",
    });

    cases.add("enum with 0 fields",
        \\const Foo = enum {};
        \\export fn entry() usize {
        \\    return @sizeOf(Foo);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:13: error: enums must have 1 or more fields",
    });

    cases.add("union with 0 fields",
        \\const Foo = union {};
        \\export fn entry() usize {
        \\    return @sizeOf(Foo);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:13: error: unions must have 1 or more fields",
    });

    cases.add("enum value already taken",
        \\const MultipleChoice = enum(u32) {
        \\    A = 20,
        \\    B = 40,
        \\    C = 60,
        \\    D = 1000,
        \\    E = 60,
        \\};
        \\export fn entry() void {
        \\    var x = MultipleChoice.C;
        \\}
    , &[_][]const u8{
        "tmp.zig:6:5: error: enum tag value 60 already taken",
        "tmp.zig:4:5: note: other occurrence here",
    });

    cases.add("union with specified enum omits field",
        \\const Letter = enum {
        \\    A,
        \\    B,
        \\    C,
        \\};
        \\const Payload = union(Letter) {
        \\    A: i32,
        \\    B: f64,
        \\};
        \\export fn entry() usize {
        \\    return @sizeOf(Payload);
        \\}
    , &[_][]const u8{
        "tmp.zig:6:17: error: enum field missing: 'C'",
        "tmp.zig:4:5: note: declared here",
    });

    cases.add("@TagType when union has no attached enum",
        \\const Foo = union {
        \\    A: i32,
        \\};
        \\export fn entry() void {
        \\    const x = @TagType(Foo);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:24: error: union 'Foo' has no tag",
        "tmp.zig:1:13: note: consider 'union(enum)' here",
    });

    cases.add("non-integer tag type to automatic union enum",
        \\const Foo = union(enum(f32)) {
        \\    A: i32,
        \\};
        \\export fn entry() void {
        \\    const x = @TagType(Foo);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:24: error: expected integer tag type, found 'f32'",
    });

    cases.add("non-enum tag type passed to union",
        \\const Foo = union(u32) {
        \\    A: i32,
        \\};
        \\export fn entry() void {
        \\    const x = @TagType(Foo);
        \\}
    , &[_][]const u8{
        "tmp.zig:1:19: error: expected enum tag type, found 'u32'",
    });

    cases.add("union auto-enum value already taken",
        \\const MultipleChoice = union(enum(u32)) {
        \\    A = 20,
        \\    B = 40,
        \\    C = 60,
        \\    D = 1000,
        \\    E = 60,
        \\};
        \\export fn entry() void {
        \\    var x = MultipleChoice { .C = {} };
        \\}
    , &[_][]const u8{
        "tmp.zig:6:9: error: enum tag value 60 already taken",
        "tmp.zig:4:9: note: other occurrence here",
    });

    cases.add("union enum field does not match enum",
        \\const Letter = enum {
        \\    A,
        \\    B,
        \\    C,
        \\};
        \\const Payload = union(Letter) {
        \\    A: i32,
        \\    B: f64,
        \\    C: bool,
        \\    D: bool,
        \\};
        \\export fn entry() void {
        \\    var a = Payload {.A = 1234};
        \\}
    , &[_][]const u8{
        "tmp.zig:10:5: error: enum field not found: 'D'",
        "tmp.zig:1:16: note: enum declared here",
    });

    cases.add("field type supplied in an enum",
        \\const Letter = enum {
        \\    A: void,
        \\    B,
        \\    C,
        \\};
        \\export fn entry() void {
        \\    var b = Letter.B;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:8: error: structs and unions, not enums, support field types",
        "tmp.zig:1:16: note: consider 'union(enum)' here",
    });

    cases.add("struct field missing type",
        \\const Letter = struct {
        \\    A,
        \\};
        \\export fn entry() void {
        \\    var a = Letter { .A = {} };
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: struct field missing type",
    });

    cases.add("extern union field missing type",
        \\const Letter = extern union {
        \\    A,
        \\};
        \\export fn entry() void {
        \\    var a = Letter { .A = {} };
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: union field missing type",
    });

    cases.add("extern union given enum tag type",
        \\const Letter = enum {
        \\    A,
        \\    B,
        \\    C,
        \\};
        \\const Payload = extern union(Letter) {
        \\    A: i32,
        \\    B: f64,
        \\    C: bool,
        \\};
        \\export fn entry() void {
        \\    var a = Payload { .A = 1234 };
        \\}
    , &[_][]const u8{
        "tmp.zig:6:30: error: extern union does not support enum tag type",
    });

    cases.add("packed union given enum tag type",
        \\const Letter = enum {
        \\    A,
        \\    B,
        \\    C,
        \\};
        \\const Payload = packed union(Letter) {
        \\    A: i32,
        \\    B: f64,
        \\    C: bool,
        \\};
        \\export fn entry() void {
        \\    var a = Payload { .A = 1234 };
        \\}
    , &[_][]const u8{
        "tmp.zig:6:30: error: packed union does not support enum tag type",
    });

    cases.add("packed union with automatic layout field",
        \\const Foo = struct {
        \\    a: u32,
        \\    b: f32,
        \\};
        \\const Payload = packed union {
        \\    A: Foo,
        \\    B: bool,
        \\};
        \\export fn entry() void {
        \\    var a = Payload { .B = true };
        \\}
    , &[_][]const u8{
        "tmp.zig:6:5: error: non-packed, non-extern struct 'Foo' not allowed in packed union; no guaranteed in-memory representation",
    });

    cases.add("switch on union with no attached enum",
        \\const Payload = union {
        \\    A: i32,
        \\    B: f64,
        \\    C: bool,
        \\};
        \\export fn entry() void {
        \\    const a = Payload { .A = 1234 };
        \\    foo(a);
        \\}
        \\fn foo(a: *const Payload) void {
        \\    switch (a.*) {
        \\        Payload.A => {},
        \\        else => unreachable,
        \\    }
        \\}
    , &[_][]const u8{
        "tmp.zig:11:14: error: switch on union which has no attached enum",
        "tmp.zig:1:17: note: consider 'union(enum)' here",
    });

    cases.add("enum in field count range but not matching tag",
        \\const Foo = enum(u32) {
        \\    A = 10,
        \\    B = 11,
        \\};
        \\export fn entry() void {
        \\    var x = @intToEnum(Foo, 0);
        \\}
    , &[_][]const u8{
        "tmp.zig:6:13: error: enum 'Foo' has no tag matching integer value 0",
        "tmp.zig:1:13: note: 'Foo' declared here",
    });

    cases.add("comptime cast enum to union but field has payload",
        \\const Letter = enum { A, B, C };
        \\const Value = union(Letter) {
        \\    A: i32,
        \\    B,
        \\    C,
        \\};
        \\export fn entry() void {
        \\    var x: Value = Letter.A;
        \\}
    , &[_][]const u8{
        "tmp.zig:8:26: error: cast to union 'Value' must initialize 'i32' field 'A'",
        "tmp.zig:3:5: note: field 'A' declared here",
    });

    cases.add("runtime cast to union which has non-void fields",
        \\const Letter = enum { A, B, C };
        \\const Value = union(Letter) {
        \\    A: i32,
        \\    B,
        \\    C,
        \\};
        \\export fn entry() void {
        \\    foo(Letter.A);
        \\}
        \\fn foo(l: Letter) void {
        \\    var x: Value = l;
        \\}
    , &[_][]const u8{
        "tmp.zig:11:20: error: runtime cast to union 'Value' which has non-void fields",
        "tmp.zig:3:5: note: field 'A' has type 'i32'",
    });

    cases.add("taking byte offset of void field in struct",
        \\const Empty = struct {
        \\    val: void,
        \\};
        \\export fn foo() void {
        \\    const fieldOffset = @byteOffsetOf(Empty, "val",);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:46: error: zero-bit field 'val' in struct 'Empty' has no offset",
    });

    cases.add("taking bit offset of void field in struct",
        \\const Empty = struct {
        \\    val: void,
        \\};
        \\export fn foo() void {
        \\    const fieldOffset = @bitOffsetOf(Empty, "val",);
        \\}
    , &[_][]const u8{
        "tmp.zig:5:45: error: zero-bit field 'val' in struct 'Empty' has no offset",
    });

    cases.add("invalid union field access in comptime",
        \\const Foo = union {
        \\    Bar: u8,
        \\    Baz: void,
        \\};
        \\comptime {
        \\    var foo = Foo {.Baz = {}};
        \\    const bar_val = foo.Bar;
        \\}
    , &[_][]const u8{
        "tmp.zig:7:24: error: accessing union field 'Bar' while field 'Baz' is set",
    });

    cases.add("getting return type of generic function",
        \\fn generic(a: var) void {}
        \\comptime {
        \\    _ = @TypeOf(generic).ReturnType;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:25: error: ReturnType has not been resolved because 'fn(var) var' is generic",
    });

    cases.add("getting @ArgType of generic function",
        \\fn generic(a: var) void {}
        \\comptime {
        \\    _ = @ArgType(@TypeOf(generic), 0);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:36: error: @ArgType could not resolve the type of arg 0 because 'fn(var) var' is generic",
    });

    cases.add("unsupported modifier at start of asm output constraint",
        \\export fn foo() void {
        \\    var bar: u32 = 3;
        \\    asm volatile ("" : [baz]"+r"(bar) : : "");
        \\}
    , &[_][]const u8{
        "tmp.zig:3:5: error: invalid modifier starting output constraint for 'baz': '+', only '=' is supported. Compiler TODO: see https://github.com/ziglang/zig/issues/215",
    });

    cases.add("comptime_int in asm input",
        \\export fn foo() void {
        \\    asm volatile ("" : : [bar]"r"(3) : "");
        \\}
    , &[_][]const u8{
        "tmp.zig:2:35: error: expected sized integer or sized float, found comptime_int",
    });

    cases.add("comptime_float in asm input",
        \\export fn foo() void {
        \\    asm volatile ("" : : [bar]"r"(3.17) : "");
        \\}
    , &[_][]const u8{
        "tmp.zig:2:35: error: expected sized integer or sized float, found comptime_float",
    });

    cases.add("runtime assignment to comptime struct type",
        \\const Foo = struct {
        \\    Bar: u8,
        \\    Baz: type,
        \\};
        \\export fn f() void {
        \\    var x: u8 = 0;
        \\    const foo = Foo { .Bar = x, .Baz = u8 };
        \\}
    , &[_][]const u8{
        "tmp.zig:7:23: error: unable to evaluate constant expression",
    });

    cases.add("runtime assignment to comptime union type",
        \\const Foo = union {
        \\    Bar: u8,
        \\    Baz: type,
        \\};
        \\export fn f() void {
        \\    var x: u8 = 0;
        \\    const foo = Foo { .Bar = x };
        \\}
    , &[_][]const u8{
        "tmp.zig:7:23: error: unable to evaluate constant expression",
    });

    cases.addTest("@shuffle with selected index past first vector length",
        \\export fn entry() void {
        \\    const v: @Vector(4, u32) = [4]u32{ 10, 11, 12, 13 };
        \\    const x: @Vector(4, u32) = [4]u32{ 14, 15, 16, 17 };
        \\    var z = @shuffle(u32, v, x, [8]i32{ 0, 1, 2, 3, 7, 6, 5, 4 });
        \\}
    , &[_][]const u8{
        "tmp.zig:4:39: error: mask index '4' has out-of-bounds selection",
        "tmp.zig:4:27: note: selected index '7' out of bounds of @Vector(4, u32)",
        "tmp.zig:4:30: note: selections from the second vector are specified with negative numbers",
    });

    cases.addTest("nested vectors",
        \\export fn entry() void {
        \\    const V = @Vector(4, @Vector(4, u8));
        \\    var v: V = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:26: error: vector element type must be integer, float, bool, or pointer; '@Vector(4, u8)' is invalid",
    });

    cases.addTest("bad @splat type",
        \\export fn entry() void {
        \\    const c = 4;
        \\    var v = @splat(4, c);
        \\}
    , &[_][]const u8{
        "tmp.zig:3:23: error: vector element type must be integer, float, bool, or pointer; 'comptime_int' is invalid",
    });

    cases.add("compileLog of tagged enum doesn't crash the compiler",
        \\const Bar = union(enum(u32)) {
        \\    X: i32 = 1
        \\};
        \\
        \\fn testCompileLog(x: Bar) void {
        \\    @compileLog(x);
        \\}
        \\
        \\pub fn main () void {
        \\    comptime testCompileLog(Bar{.X = 123});
        \\}
    , &[_][]const u8{
        "tmp.zig:6:5: error: found compile log statement",
    });

    cases.add("attempted implicit cast from *const T to *[1]T",
        \\export fn entry(byte: u8) void {
        \\    const w: i32 = 1234;
        \\    var x: *const i32 = &w;
        \\    var y: *[1]i32 = x;
        \\    y[0] += 1;
        \\}
    , &[_][]const u8{
        "tmp.zig:4:22: error: expected type '*[1]i32', found '*const i32'",
        "tmp.zig:4:22: note: cast discards const qualifier",
    });

    cases.add("attempted implicit cast from *const T to []T",
        \\export fn entry() void {
        \\    const u: u32 = 42;
        \\    const x: []u32 = &u;
        \\}
    , &[_][]const u8{
        "tmp.zig:3:23: error: expected type '[]u32', found '*const u32'",
    });

    cases.add("for loop body expression ignored",
        \\fn returns() usize {
        \\    return 2;
        \\}
        \\export fn f1() void {
        \\    for ("hello") |_| returns();
        \\}
        \\export fn f2() void {
        \\    var x: anyerror!i32 = error.Bad;
        \\    for ("hello") |_| returns() else unreachable;
        \\}
    , &[_][]const u8{
        "tmp.zig:5:30: error: expression value is ignored",
        "tmp.zig:9:30: error: expression value is ignored",
    });

    cases.add("aligned variable of zero-bit type",
        \\export fn f() void {
        \\    var s: struct {} align(4) = undefined;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:5: error: variable 's' of zero-bit type 'struct:2:12' has no in-memory representation, it cannot be aligned",
    });

    cases.add("function returning opaque type",
        \\const FooType = @OpaqueType();
        \\export fn bar() !FooType {
        \\    return error.InvalidValue;
        \\}
    , &[_][]const u8{
        "tmp.zig:2:18: error: opaque return type 'FooType' not allowed",
        "tmp.zig:1:1: note: declared here",
    });

    cases.add( // fixed bug #2032
        "compile diagnostic string for top level decl type",
        \\export fn entry() void {
        \\    var foo: u32 = @This(){};
        \\}
    , &[_][]const u8{
        "tmp.zig:2:27: error: type 'u32' does not support array initialization",
    });
}
