extern var internal_integer: usize = 2;
extern var obj2_integer: usize = 422;

comptime {
    @export(internal_integer, .{ .name = "internal_integer", .linkage = .Internal });
    @export(obj2_integer, .{ .name = "obj2_integer", .linkage = .Strong });
}
