const tests = @import("tests.zig");

pub fn addCases(cases: *tests.CompareOutputContext) void {
    cases.addRuntimeSafety("slice sentinel mismatch - optional pointers",
        \\const std = @import("std");
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (std.mem.eql(u8, message, "sentinel mismatch")) {
        \\        std.process.exit(126); // good
        \\    }
        \\    std.process.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    var buf: [4]?*i32 = undefined;
        \\    const slice = buf[0..3 :null];
        \\}
    );

    cases.addRuntimeSafety("slice sentinel mismatch - floats",
        \\const std = @import("std");
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (std.mem.eql(u8, message, "sentinel mismatch")) {
        \\        std.process.exit(126); // good
        \\    }
        \\    std.process.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    var buf: [4]f32 = undefined;
        \\    const slice = buf[0..3 :1.2];
        \\}
    );

    cases.addRuntimeSafety("pointer slice sentinel mismatch",
        \\const std = @import("std");
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (std.mem.eql(u8, message, "sentinel mismatch")) {
        \\        std.process.exit(126); // good
        \\    }
        \\    std.process.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    var buf: [4]u8 = undefined;
        \\    const ptr = buf[0..].ptr;
        \\    const slice = ptr[0..3 :0];
        \\}
    );

    cases.addRuntimeSafety("slice slice sentinel mismatch",
        \\const std = @import("std");
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (std.mem.eql(u8, message, "sentinel mismatch")) {
        \\        std.process.exit(126); // good
        \\    }
        \\    std.process.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    var buf: [4]u8 = undefined;
        \\    const slice = buf[0..];
        \\    const slice2 = slice[0..3 :0];
        \\}
    );

    cases.addRuntimeSafety("array slice sentinel mismatch",
        \\const std = @import("std");
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (std.mem.eql(u8, message, "sentinel mismatch")) {
        \\        std.process.exit(126); // good
        \\    }
        \\    std.process.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    var buf: [4]u8 = undefined;
        \\    const slice = buf[0..3 :0];
        \\}
    );

    cases.addRuntimeSafety("intToPtr with misaligned address",
        \\const std = @import("std");
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (std.mem.eql(u8, message, "incorrect alignment")) {
        \\        std.os.exit(126); // good
        \\    }
        \\    std.os.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    var x: usize = 5;
        \\    var y = @intToPtr([*]align(4) u8, x);
        \\}
    );

    cases.addRuntimeSafety("resuming a non-suspended function which never been suspended",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\fn foo() void {
        \\    var f = async bar(@frame());
        \\    @import("std").os.exit(0);
        \\}
        \\
        \\fn bar(frame: anyframe) void {
        \\    suspend {
        \\        resume frame;
        \\    }
        \\    @import("std").os.exit(0);
        \\}
        \\
        \\pub fn main() void {
        \\    _ = async foo();
        \\}
    );

    cases.addRuntimeSafety("resuming a non-suspended function which has been suspended and resumed",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\fn foo() void {
        \\    suspend {
        \\        global_frame = @frame();
        \\    }
        \\    var f = async bar(@frame());
        \\    @import("std").os.exit(0);
        \\}
        \\
        \\fn bar(frame: anyframe) void {
        \\    suspend {
        \\        resume frame;
        \\    }
        \\    @import("std").os.exit(0);
        \\}
        \\
        \\var global_frame: anyframe = undefined;
        \\pub fn main() void {
        \\    _ = async foo();
        \\    resume global_frame;
        \\    @import("std").os.exit(0);
        \\}
    );

    cases.addRuntimeSafety("noasync function call, callee suspends",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    _ = noasync add(101, 100);
        \\}
        \\fn add(a: i32, b: i32) i32 {
        \\    if (a > 100) {
        \\        suspend;
        \\    }
        \\    return a + b;
        \\}
    );

    cases.addRuntimeSafety("awaiting twice",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\var frame: anyframe = undefined;
        \\
        \\pub fn main() void {
        \\    _ = async amain();
        \\    resume frame;
        \\}
        \\
        \\fn amain() void {
        \\    var f = async func();
        \\    await f;
        \\    await f;
        \\}
        \\
        \\fn func() void {
        \\    suspend {
        \\        frame = @frame();
        \\    }
        \\}
    );

    cases.addRuntimeSafety("@asyncCall with too small a frame",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var bytes: [1]u8 align(16) = undefined;
        \\    var ptr = other;
        \\    var frame = @asyncCall(&bytes, {}, ptr);
        \\}
        \\async fn other() void {
        \\    suspend;
        \\}
    );

    cases.addRuntimeSafety("resuming a function which is awaiting a frame",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var frame = async first();
        \\    resume frame;
        \\}
        \\fn first() void {
        \\    var frame = async other();
        \\    await frame;
        \\}
        \\fn other() void {
        \\    suspend;
        \\}
    );

    cases.addRuntimeSafety("resuming a function which is awaiting a call",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var frame = async first();
        \\    resume frame;
        \\}
        \\fn first() void {
        \\    other();
        \\}
        \\fn other() void {
        \\    suspend;
        \\}
    );

    cases.addRuntimeSafety("invalid resume of async function",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var p = async suspendOnce();
        \\    resume p; //ok
        \\    resume p; //bad
        \\}
        \\fn suspendOnce() void {
        \\    suspend;
        \\}
    );

    cases.addRuntimeSafety(".? operator on null pointer",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var ptr: ?*i32 = null;
        \\    var b = ptr.?;
        \\}
    );

    cases.addRuntimeSafety(".? operator on C pointer",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var ptr: [*c]i32 = null;
        \\    var b = ptr.?;
        \\}
    );

    cases.addRuntimeSafety("@ptrToInt address zero to non-optional pointer",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var zero: usize = 0;
        \\    var b = @intToPtr(*i32, zero);
        \\}
    );

    cases.addRuntimeSafety("pointer casting null to non-optional pointer",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var c_ptr: [*c]u8 = 0;
        \\    var zig_ptr: *u8 = c_ptr;
        \\}
    );

    cases.addRuntimeSafety("@intToEnum - no matching tag value",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\const Foo = enum {
        \\    A,
        \\    B,
        \\    C,
        \\};
        \\pub fn main() void {
        \\    baz(bar(3));
        \\}
        \\fn bar(a: u2) Foo {
        \\    return @intToEnum(Foo, a);
        \\}
        \\fn baz(a: Foo) void {}
    );

    cases.addRuntimeSafety("@floatToInt cannot fit - negative to unsigned",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    baz(bar(-1.1));
        \\}
        \\fn bar(a: f32) u8 {
        \\    return @floatToInt(u8, a);
        \\}
        \\fn baz(a: u8) void { }
    );

    cases.addRuntimeSafety("@floatToInt cannot fit - negative out of range",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    baz(bar(-129.1));
        \\}
        \\fn bar(a: f32) i8 {
        \\    return @floatToInt(i8, a);
        \\}
        \\fn baz(a: i8) void { }
    );

    cases.addRuntimeSafety("@floatToInt cannot fit - positive out of range",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    baz(bar(256.2));
        \\}
        \\fn bar(a: f32) u8 {
        \\    return @floatToInt(u8, a);
        \\}
        \\fn baz(a: u8) void { }
    );

    cases.addRuntimeSafety("calling panic",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    @panic("oh no");
        \\}
    );

    cases.addRuntimeSafety("out of bounds slice access",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    const a = [_]i32{1, 2, 3, 4};
        \\    baz(bar(&a));
        \\}
        \\fn bar(a: []const i32) i32 {
        \\    return a[4];
        \\}
        \\fn baz(a: i32) void { }
    );

    cases.addRuntimeSafety("integer addition overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = add(65530, 10);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn add(a: u16, b: u16) u16 {
        \\    return a + b;
        \\}
    );

    cases.addRuntimeSafety("vector integer addition overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var a: @Vector(4, i32) = [_]i32{ 1, 2, 2147483643, 4 };
        \\    var b: @Vector(4, i32) = [_]i32{ 5, 6, 7, 8 };
        \\    const x = add(a, b);
        \\}
        \\fn add(a: @Vector(4, i32), b: @Vector(4, i32)) @Vector(4, i32) {
        \\    return a + b;
        \\}
    );

    cases.addRuntimeSafety("vector integer subtraction overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var a: @Vector(4, u32) = [_]u32{ 1, 2, 8, 4 };
        \\    var b: @Vector(4, u32) = [_]u32{ 5, 6, 7, 8 };
        \\    const x = sub(b, a);
        \\}
        \\fn sub(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
        \\    return a - b;
        \\}
    );

    cases.addRuntimeSafety("vector integer multiplication overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var a: @Vector(4, u8) = [_]u8{ 1, 2, 200, 4 };
        \\    var b: @Vector(4, u8) = [_]u8{ 5, 6, 2, 8 };
        \\    const x = mul(b, a);
        \\}
        \\fn mul(a: @Vector(4, u8), b: @Vector(4, u8)) @Vector(4, u8) {
        \\    return a * b;
        \\}
    );

    cases.addRuntimeSafety("vector integer negation overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var a: @Vector(4, i16) = [_]i16{ 1, -32768, 200, 4 };
        \\    const x = neg(a);
        \\}
        \\fn neg(a: @Vector(4, i16)) @Vector(4, i16) {
        \\    return -a;
        \\}
    );

    cases.addRuntimeSafety("integer subtraction overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = sub(10, 20);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn sub(a: u16, b: u16) u16 {
        \\    return a - b;
        \\}
    );

    cases.addRuntimeSafety("integer multiplication overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = mul(300, 6000);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn mul(a: u16, b: u16) u16 {
        \\    return a * b;
        \\}
    );

    cases.addRuntimeSafety("integer negation overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = neg(-32768);
        \\    if (x == 32767) return error.Whatever;
        \\}
        \\fn neg(a: i16) i16 {
        \\    return -a;
        \\}
    );

    cases.addRuntimeSafety("signed integer division overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = div(-32768, -1);
        \\    if (x == 32767) return error.Whatever;
        \\}
        \\fn div(a: i16, b: i16) i16 {
        \\    return @divTrunc(a, b);
        \\}
    );

    cases.addRuntimeSafety("signed shift left overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = shl(-16385, 1);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn shl(a: i16, b: u4) i16 {
        \\    return @shlExact(a, b);
        \\}
    );

    cases.addRuntimeSafety("unsigned shift left overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = shl(0b0010111111111111, 3);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn shl(a: u16, b: u4) u16 {
        \\    return @shlExact(a, b);
        \\}
    );

    cases.addRuntimeSafety("signed shift right overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = shr(-16385, 1);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn shr(a: i16, b: u4) i16 {
        \\    return @shrExact(a, b);
        \\}
    );

    cases.addRuntimeSafety("unsigned shift right overflow",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = shr(0b0010111111111111, 3);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn shr(a: u16, b: u4) u16 {
        \\    return @shrExact(a, b);
        \\}
    );

    cases.addRuntimeSafety("integer division by zero",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    const x = div0(999, 0);
        \\}
        \\fn div0(a: i32, b: i32) i32 {
        \\    return @divTrunc(a, b);
        \\}
    );

    cases.addRuntimeSafety("exact division failure",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = divExact(10, 3);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn divExact(a: i32, b: i32) i32 {
        \\    return @divExact(a, b);
        \\}
    );

    cases.addRuntimeSafety("cast []u8 to bigger slice of wrong size",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = widenSlice(&[_]u8{1, 2, 3, 4, 5});
        \\    if (x.len == 0) return error.Whatever;
        \\}
        \\fn widenSlice(slice: []align(1) const u8) []align(1) const i32 {
        \\    return @bytesToSlice(i32, slice);
        \\}
    );

    cases.addRuntimeSafety("value does not fit in shortening cast",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = shorten_cast(200);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn shorten_cast(x: i32) i8 {
        \\    return @intCast(i8, x);
        \\}
    );

    cases.addRuntimeSafety("value does not fit in shortening cast - u0",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = shorten_cast(1);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn shorten_cast(x: u8) u0 {
        \\    return @intCast(u0, x);
        \\}
    );

    cases.addRuntimeSafety("signed integer not fitting in cast to unsigned integer",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    const x = unsigned_cast(-10);
        \\    if (x == 0) return error.Whatever;
        \\}
        \\fn unsigned_cast(x: i32) u32 {
        \\    return @intCast(u32, x);
        \\}
    );

    cases.addRuntimeSafety("signed integer not fitting in cast to unsigned integer - widening",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    var value: c_short = -1;
        \\    var casted = @intCast(u32, value);
        \\}
    );

    cases.addRuntimeSafety("unwrap error",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    if (@import("std").mem.eql(u8, message, "attempt to unwrap error: Whatever")) {
        \\        @import("std").os.exit(126); // good
        \\    }
        \\    @import("std").os.exit(0); // test failed
        \\}
        \\pub fn main() void {
        \\    bar() catch unreachable;
        \\}
        \\fn bar() !void {
        \\    return error.Whatever;
        \\}
    );

    cases.addRuntimeSafety("cast integer to global error and no code matches",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() void {
        \\    bar(9999) catch {};
        \\}
        \\fn bar(x: u16) anyerror {
        \\    return @intToError(x);
        \\}
    );

    cases.addRuntimeSafety("@errSetCast error not present in destination",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\const Set1 = error{A, B};
        \\const Set2 = error{A, C};
        \\pub fn main() void {
        \\    foo(Set1.B) catch {};
        \\}
        \\fn foo(set1: Set1) Set2 {
        \\    return @errSetCast(Set2, set1);
        \\}
    );

    cases.addRuntimeSafety("@alignCast misaligned",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\pub fn main() !void {
        \\    var array align(4) = [_]u32{0x11111111, 0x11111111};
        \\    const bytes = @sliceToBytes(array[0..]);
        \\    if (foo(bytes) != 0x11111111) return error.Wrong;
        \\}
        \\fn foo(bytes: []u8) u32 {
        \\    const slice4 = bytes[1..5];
        \\    const int_slice = @bytesToSlice(u32, @alignCast(4, slice4));
        \\    return int_slice[0];
        \\}
    );

    cases.addRuntimeSafety("bad union field access",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\
        \\const Foo = union {
        \\    float: f32,
        \\    int: u32,
        \\};
        \\
        \\pub fn main() void {
        \\    var f = Foo { .int = 42 };
        \\    bar(&f);
        \\}
        \\
        \\fn bar(f: *Foo) void {
        \\    f.float = 12.34;
        \\}
    );

    // @intCast a runtime integer to u0 actually results in a comptime-known value,
    // but we still emit a safety check to ensure the integer was 0 and thus
    // did not truncate information.
    cases.addRuntimeSafety("@intCast to u0",
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    @import("std").os.exit(126);
        \\}
        \\
        \\pub fn main() void {
        \\    bar(1, 1);
        \\}
        \\
        \\fn bar(one: u1, not_zero: i32) void {
        \\    var x = one << @intCast(u0, not_zero);
        \\}
    );

    // This case makes sure that the code compiles and runs. There is not actually a special
    // runtime safety check having to do specifically with error return traces across suspend points.
    cases.addRuntimeSafety("error return trace across suspend points",
        \\const std = @import("std");
        \\
        \\pub fn panic(message: []const u8, stack_trace: ?*@import("builtin").StackTrace) noreturn {
        \\    std.os.exit(126);
        \\}
        \\
        \\var failing_frame: @Frame(failing) = undefined;
        \\
        \\pub fn main() void {
        \\    const p = nonFailing();
        \\    resume p;
        \\    const p2 = async printTrace(p);
        \\}
        \\
        \\fn nonFailing() anyframe->anyerror!void {
        \\    failing_frame = async failing();
        \\    return &failing_frame;
        \\}
        \\
        \\async fn failing() anyerror!void {
        \\    suspend;
        \\    return second();
        \\}
        \\
        \\async fn second() anyerror!void {
        \\    return error.Fail;
        \\}
        \\
        \\async fn printTrace(p: anyframe->anyerror!void) void {
        \\    (await p) catch unreachable;
        \\}
    );
}
