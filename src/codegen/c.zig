const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.c);
const Writer = std.ArrayList(u8).Writer;

const link = @import("../link.zig");
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const Inst = @import("../ir.zig").Inst;
const Value = @import("../value.zig").Value;
const Type = @import("../type.zig").Type;
const TypedValue = @import("../TypedValue.zig");
const C = link.File.C;
const Decl = Module.Decl;
const trace = @import("../tracy.zig").trace;

const Mutability = enum { Const, Mut };

pub const CValue = union(enum) {
    none: void,
    /// Index into local_names
    local: usize,
    /// Index into local_names, but take the address.
    local_ref: usize,
    /// A constant instruction, to be rendered inline.
    constant: *Inst,
    /// Index into the parameters
    arg: usize,
    /// By-value
    decl: *Decl,
};

pub const CValueMap = std.AutoHashMap(*Inst, CValue);

/// This data is available when outputting .c code for a Module.
/// It is not available when generating .h file.
pub const Object = struct {
    dg: DeclGen,
    gpa: *mem.Allocator,
    code: std.ArrayList(u8),
    value_map: CValueMap,
    next_arg_index: usize = 0,
    next_local_index: usize = 0,

    fn resolveInst(o: *Object, inst: *Inst) !CValue {
        if (inst.value()) |_| {
            return CValue{ .constant = inst };
        }
        return o.value_map.get(inst).?; // Instruction does not dominate all uses!
    }

    fn allocLocalValue(o: *Object) CValue {
        const result = o.next_local_index;
        o.next_local_index += 1;
        return .{ .local = result };
    }

    fn allocLocal(o: *Object, ty: Type, mutability: Mutability) !CValue {
        const local_value = o.allocLocalValue();
        try o.renderTypeAndName(o.code.writer(), ty, local_value, mutability);
        return local_value;
    }

    fn indent(o: *Object) !void {
        const indent_size = 4;
        const indent_level = 1;
        const indent_amt = indent_size * indent_level;
        try o.code.writer().writeByteNTimes(' ', indent_amt);
    }

    fn writeCValue(o: *Object, writer: Writer, c_value: CValue) !void {
        switch (c_value) {
            .none => unreachable,
            .local => |i| return writer.print("t{d}", .{i}),
            .local_ref => |i| return writer.print("&t{d}", .{i}),
            .constant => |inst| return o.dg.renderValue(writer, inst.ty, inst.value().?),
            .arg => |i| return writer.print("a{d}", .{i}),
            .decl => |decl| return writer.writeAll(mem.span(decl.name)),
        }
    }

    fn renderTypeAndName(
        o: *Object,
        writer: Writer,
        ty: Type,
        name: CValue,
        mutability: Mutability,
    ) error{ OutOfMemory, AnalysisFail }!void {
        var suffix = std.ArrayList(u8).init(o.gpa);
        defer suffix.deinit();

        var render_ty = ty;
        while (render_ty.zigTypeTag() == .Array) {
            const sentinel_bit = @boolToInt(render_ty.sentinel() != null);
            const c_len = render_ty.arrayLen() + sentinel_bit;
            try suffix.writer().print("[{d}]", .{c_len});
            render_ty = render_ty.elemType();
        }

        try o.dg.renderType(writer, render_ty);

        const const_prefix = switch (mutability) {
            .Const => "const ",
            .Mut => "",
        };
        try writer.print(" {s}", .{const_prefix});
        try o.writeCValue(writer, name);
        try writer.writeAll(suffix.items);
    }
};

/// This data is available both when outputting .c code and when outputting an .h file.
pub const DeclGen = struct {
    module: *Module,
    decl: *Decl,
    fwd_decl: std.ArrayList(u8),
    error_msg: ?*Compilation.ErrorMsg,

    fn fail(dg: *DeclGen, src: usize, comptime format: []const u8, args: anytype) error{ AnalysisFail, OutOfMemory } {
        dg.error_msg = try Compilation.ErrorMsg.create(dg.module.gpa, src, format, args);
        return error.AnalysisFail;
    }

    fn renderValue(
        dg: *DeclGen,
        writer: Writer,
        t: Type,
        val: Value,
    ) error{ OutOfMemory, AnalysisFail }!void {
        switch (t.zigTypeTag()) {
            .Int => {
                if (t.isSignedInt())
                    return writer.print("{d}", .{val.toSignedInt()});
                return writer.print("{d}", .{val.toUnsignedInt()});
            },
            .Pointer => switch (val.tag()) {
                .undef, .zero => try writer.writeAll("0"),
                .one => try writer.writeAll("1"),
                .decl_ref => {
                    const decl = val.castTag(.decl_ref).?.data;

                    // Determine if we must pointer cast.
                    const decl_tv = decl.typed_value.most_recent.typed_value;
                    if (t.eql(decl_tv.ty)) {
                        try writer.print("&{s}", .{decl.name});
                    } else {
                        try writer.writeAll("(");
                        try dg.renderType(writer, t);
                        try writer.print(")&{s}", .{decl.name});
                    }
                },
                .function => {
                    const func = val.castTag(.function).?.data;
                    try writer.print("{s}", .{func.owner_decl.name});
                },
                .extern_fn => {
                    const decl = val.castTag(.extern_fn).?.data;
                    try writer.print("{s}", .{decl.name});
                },
                else => |e| return dg.fail(
                    dg.decl.src(),
                    "TODO: C backend: implement Pointer value {s}",
                    .{@tagName(e)},
                ),
            },
            .Array => {
                // First try specific tag representations for more efficiency.
                switch (val.tag()) {
                    .undef, .empty_struct_value, .empty_array => try writer.writeAll("{}"),
                    .bytes => {
                        const bytes = val.castTag(.bytes).?.data;
                        // TODO: make our own C string escape instead of using {Z}
                        try writer.print("\"{Z}\"", .{bytes});
                    },
                    else => {
                        // Fall back to generic implementation.
                        var arena = std.heap.ArenaAllocator.init(dg.module.gpa);
                        defer arena.deinit();

                        try writer.writeAll("{");
                        var index: usize = 0;
                        const len = t.arrayLen();
                        const elem_ty = t.elemType();
                        while (index < len) : (index += 1) {
                            if (index != 0) try writer.writeAll(",");
                            const elem_val = try val.elemValue(&arena.allocator, index);
                            try dg.renderValue(writer, elem_ty, elem_val);
                        }
                        if (t.sentinel()) |sentinel_val| {
                            if (index != 0) try writer.writeAll(",");
                            try dg.renderValue(writer, elem_ty, sentinel_val);
                        }
                        try writer.writeAll("}");
                    },
                }
            },
            else => |e| return dg.fail(dg.decl.src(), "TODO: C backend: implement value {s}", .{
                @tagName(e),
            }),
        }
    }

    fn renderFunctionSignature(dg: *DeclGen, w: Writer, is_global: bool) !void {
        if (!is_global) {
            try w.writeAll("static ");
        }
        const tv = dg.decl.typed_value.most_recent.typed_value;
        try dg.renderType(w, tv.ty.fnReturnType());
        const decl_name = mem.span(dg.decl.name);
        try w.print(" {s}(", .{decl_name});
        var param_len = tv.ty.fnParamLen();
        if (param_len == 0)
            try w.writeAll("void")
        else {
            var index: usize = 0;
            while (index < param_len) : (index += 1) {
                if (index > 0) {
                    try w.writeAll(", ");
                }
                try dg.renderType(w, tv.ty.fnParamType(index));
                try w.print(" a{d}", .{index});
            }
        }
        try w.writeByte(')');
    }

    fn renderType(dg: *DeclGen, w: Writer, t: Type) error{ OutOfMemory, AnalysisFail }!void {
        switch (t.zigTypeTag()) {
            .NoReturn => {
                try w.writeAll("zig_noreturn void");
            },
            .Void => try w.writeAll("void"),
            .Bool => try w.writeAll("bool"),
            .Int => {
                switch (t.tag()) {
                    .u8 => try w.writeAll("uint8_t"),
                    .i8 => try w.writeAll("int8_t"),
                    .u16 => try w.writeAll("uint16_t"),
                    .i16 => try w.writeAll("int16_t"),
                    .u32 => try w.writeAll("uint32_t"),
                    .i32 => try w.writeAll("int32_t"),
                    .u64 => try w.writeAll("uint64_t"),
                    .i64 => try w.writeAll("int64_t"),
                    .usize => try w.writeAll("uintptr_t"),
                    .isize => try w.writeAll("intptr_t"),
                    .c_short => try w.writeAll("short"),
                    .c_ushort => try w.writeAll("unsigned short"),
                    .c_int => try w.writeAll("int"),
                    .c_uint => try w.writeAll("unsigned int"),
                    .c_long => try w.writeAll("long"),
                    .c_ulong => try w.writeAll("unsigned long"),
                    .c_longlong => try w.writeAll("long long"),
                    .c_ulonglong => try w.writeAll("unsigned long long"),
                    .int_signed, .int_unsigned => {
                        const info = t.intInfo(dg.module.getTarget());
                        const sign_prefix = switch (info.signedness) {
                            .signed => "i",
                            .unsigned => "",
                        };
                        inline for (.{ 8, 16, 32, 64, 128 }) |nbits| {
                            if (info.bits <= nbits) {
                                try w.print("{s}int{d}_t", .{ sign_prefix, nbits });
                                break;
                            }
                        } else {
                            return dg.fail(dg.decl.src(), "TODO: C backend: implement integer types larger than 128 bits", .{});
                        }
                    },
                    else => unreachable,
                }
            },
            .Pointer => {
                if (t.isSlice()) {
                    return dg.fail(dg.decl.src(), "TODO: C backend: implement slices", .{});
                } else {
                    try dg.renderType(w, t.elemType());
                    try w.writeAll(" *");
                    if (t.isConstPtr()) {
                        try w.writeAll("const ");
                    }
                    if (t.isVolatilePtr()) {
                        try w.writeAll("volatile ");
                    }
                }
            },
            .Array => {
                try dg.renderType(w, t.elemType());
                try w.writeAll(" *");
            },
            else => |e| return dg.fail(dg.decl.src(), "TODO: C backend: implement type {s}", .{
                @tagName(e),
            }),
        }
    }

    fn functionIsGlobal(dg: *DeclGen, tv: TypedValue) bool {
        switch (tv.val.tag()) {
            .extern_fn => return true,
            .function => {
                const func = tv.val.castTag(.function).?.data;
                return dg.module.decl_exports.contains(func.owner_decl);
            },
            else => unreachable,
        }
    }
};

pub fn genDecl(o: *Object) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const tv = o.dg.decl.typed_value.most_recent.typed_value;

    if (tv.val.castTag(.function)) |func_payload| {
        const is_global = o.dg.functionIsGlobal(tv);
        const fwd_decl_writer = o.dg.fwd_decl.writer();
        if (is_global) {
            try fwd_decl_writer.writeAll("ZIG_EXTERN_C ");
        }
        try o.dg.renderFunctionSignature(fwd_decl_writer, is_global);
        try fwd_decl_writer.writeAll(";\n");

        const func: *Module.Fn = func_payload.data;
        const instructions = func.body.instructions;
        const writer = o.code.writer();
        try writer.writeAll("\n");
        try o.dg.renderFunctionSignature(writer, is_global);
        if (instructions.len == 0) {
            try writer.writeAll(" {}\n");
            return;
        }

        try writer.writeAll(" {");

        try writer.writeAll("\n");
        for (instructions) |inst| {
            const result_value = switch (inst.tag) {
                .add => try genBinOp(o, inst.castTag(.add).?, " + "),
                .alloc => try genAlloc(o, inst.castTag(.alloc).?),
                .arg => genArg(o),
                .assembly => try genAsm(o, inst.castTag(.assembly).?),
                .block => try genBlock(o, inst.castTag(.block).?),
                .bitcast => try genBitcast(o, inst.castTag(.bitcast).?),
                .breakpoint => try genBreakpoint(o, inst.castTag(.breakpoint).?),
                .call => try genCall(o, inst.castTag(.call).?),
                .cmp_eq => try genBinOp(o, inst.castTag(.cmp_eq).?, " == "),
                .cmp_gt => try genBinOp(o, inst.castTag(.cmp_gt).?, " > "),
                .cmp_gte => try genBinOp(o, inst.castTag(.cmp_gte).?, " >= "),
                .cmp_lt => try genBinOp(o, inst.castTag(.cmp_lt).?, " < "),
                .cmp_lte => try genBinOp(o, inst.castTag(.cmp_lte).?, " <= "),
                .cmp_neq => try genBinOp(o, inst.castTag(.cmp_neq).?, " != "),
                .dbg_stmt => try genDbgStmt(o, inst.castTag(.dbg_stmt).?),
                .intcast => try genIntCast(o, inst.castTag(.intcast).?),
                .load => try genLoad(o, inst.castTag(.load).?),
                .ret => try genRet(o, inst.castTag(.ret).?),
                .retvoid => try genRetVoid(o),
                .store => try genStore(o, inst.castTag(.store).?),
                .sub => try genBinOp(o, inst.castTag(.sub).?, " - "),
                .unreach => try genUnreach(o, inst.castTag(.unreach).?),
                else => |e| return o.dg.fail(o.dg.decl.src(), "TODO: C backend: implement codegen for {}", .{e}),
            };
            switch (result_value) {
                .none => {},
                else => try o.value_map.putNoClobber(inst, result_value),
            }
        }

        try writer.writeAll("}\n");
    } else if (tv.val.tag() == .extern_fn) {
        const writer = o.code.writer();
        try writer.writeAll("ZIG_EXTERN_C ");
        try o.dg.renderFunctionSignature(writer, true);
        try writer.writeAll(";\n");
    } else {
        const writer = o.code.writer();
        try writer.writeAll("static ");

        // TODO ask the Decl if it is const
        // https://github.com/ziglang/zig/issues/7582

        const decl_c_value: CValue = .{ .decl = o.dg.decl };
        try o.renderTypeAndName(writer, tv.ty, decl_c_value, .Mut);

        try writer.writeAll(" = ");
        try o.dg.renderValue(writer, tv.ty, tv.val);
        try writer.writeAll(";\n");
    }
}

pub fn genHeader(dg: *DeclGen) error{ AnalysisFail, OutOfMemory }!void {
    const tracy = trace(@src());
    defer tracy.end();

    const tv = dg.decl.typed_value.most_recent.typed_value;
    const writer = dg.fwd_decl.writer();

    switch (tv.ty.zigTypeTag()) {
        .Fn => {
            const is_global = dg.functionIsGlobal(tv);
            if (is_global) {
                try writer.writeAll("ZIG_EXTERN_C ");
            }
            try dg.renderFunctionSignature(writer, is_global);
            try dg.fwd_decl.appendSlice(";\n");
        },
        else => {},
    }
}

fn genAlloc(o: *Object, alloc: *Inst.NoOp) !CValue {
    const writer = o.code.writer();

    // First line: the variable used as data storage.
    try o.indent();
    const elem_type = alloc.base.ty.elemType();
    const mutability: Mutability = if (alloc.base.ty.isConstPtr()) .Const else .Mut;
    const local = try o.allocLocal(elem_type, mutability);
    try writer.writeAll(";\n");

    return CValue{ .local_ref = local.local };
}

fn genArg(o: *Object) CValue {
    const i = o.next_arg_index;
    o.next_arg_index += 1;
    return .{ .arg = i };
}

fn genRetVoid(o: *Object) !CValue {
    try o.indent();
    try o.code.writer().print("return;\n", .{});
    return CValue.none;
}

fn genLoad(o: *Object, inst: *Inst.UnOp) !CValue {
    const operand = try o.resolveInst(inst.operand);
    const writer = o.code.writer();
    try o.indent();
    const local = try o.allocLocal(inst.base.ty, .Const);
    switch (operand) {
        .local_ref => |i| {
            const wrapped: CValue = .{ .local = i };
            try writer.writeAll(" = ");
            try o.writeCValue(writer, wrapped);
            try writer.writeAll(";\n");
        },
        else => {
            try writer.writeAll(" = *");
            try o.writeCValue(writer, operand);
            try writer.writeAll(";\n");
        },
    }
    return local;
}

fn genRet(o: *Object, inst: *Inst.UnOp) !CValue {
    const operand = try o.resolveInst(inst.operand);
    try o.indent();
    const writer = o.code.writer();
    try writer.writeAll("return ");
    try o.writeCValue(writer, operand);
    try writer.writeAll(";\n");
    return CValue.none;
}

fn genIntCast(o: *Object, inst: *Inst.UnOp) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const from = try o.resolveInst(inst.operand);

    try o.indent();
    const writer = o.code.writer();
    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = (");
    try o.dg.renderType(writer, inst.base.ty);
    try writer.writeAll(")");
    try o.writeCValue(writer, from);
    try writer.writeAll(";\n");
    return local;
}

fn genStore(o: *Object, inst: *Inst.BinOp) !CValue {
    // *a = b;
    const dest_ptr = try o.resolveInst(inst.lhs);
    const src_val = try o.resolveInst(inst.rhs);

    try o.indent();
    const writer = o.code.writer();
    switch (dest_ptr) {
        .local_ref => |i| {
            const dest: CValue = .{ .local = i };
            try o.writeCValue(writer, dest);
            try writer.writeAll(" = ");
            try o.writeCValue(writer, src_val);
            try writer.writeAll(";\n");
        },
        else => {
            try writer.writeAll("*");
            try o.writeCValue(writer, dest_ptr);
            try writer.writeAll(" = ");
            try o.writeCValue(writer, src_val);
            try writer.writeAll(";\n");
        },
    }
    return CValue.none;
}

fn genBinOp(o: *Object, inst: *Inst.BinOp, operator: []const u8) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const lhs = try o.resolveInst(inst.lhs);
    const rhs = try o.resolveInst(inst.rhs);

    try o.indent();
    const writer = o.code.writer();
    const local = try o.allocLocal(inst.base.ty, .Const);

    try writer.writeAll(" = ");
    try o.writeCValue(writer, lhs);
    try writer.writeAll(operator);
    try o.writeCValue(writer, rhs);
    try writer.writeAll(";\n");

    return local;
}

fn genCall(o: *Object, inst: *Inst.Call) !CValue {
    if (inst.func.castTag(.constant)) |func_inst| {
        const fn_decl = if (func_inst.val.castTag(.extern_fn)) |extern_fn|
            extern_fn.data
        else if (func_inst.val.castTag(.function)) |func_payload|
            func_payload.data.owner_decl
        else
            unreachable;

        const fn_ty = fn_decl.typed_value.most_recent.typed_value.ty;
        const ret_ty = fn_ty.fnReturnType();
        const unused_result = inst.base.isUnused();
        var result_local: CValue = .none;

        try o.indent();
        const writer = o.code.writer();
        if (unused_result) {
            if (ret_ty.hasCodeGenBits()) {
                try writer.print("(void)", .{});
            }
        } else {
            result_local = try o.allocLocal(ret_ty, .Const);
            try writer.writeAll(" = ");
        }
        const fn_name = mem.spanZ(fn_decl.name);
        try writer.print("{s}(", .{fn_name});
        if (inst.args.len != 0) {
            for (inst.args) |arg, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                if (arg.value()) |val| {
                    try o.dg.renderValue(writer, arg.ty, val);
                } else {
                    const val = try o.resolveInst(arg);
                    try o.writeCValue(writer, val);
                }
            }
        }
        try writer.writeAll(");\n");
        return result_local;
    } else {
        return o.dg.fail(o.dg.decl.src(), "TODO: C backend: implement function pointers", .{});
    }
}

fn genDbgStmt(o: *Object, inst: *Inst.NoOp) !CValue {
    // TODO emit #line directive here with line number and filename
    return CValue.none;
}

fn genBlock(o: *Object, inst: *Inst.Block) !CValue {
    return o.dg.fail(o.dg.decl.src(), "TODO: C backend: implement blocks", .{});
}

fn genBitcast(o: *Object, inst: *Inst.UnOp) !CValue {
    const operand = try o.resolveInst(inst.operand);

    const writer = o.code.writer();
    try o.indent();
    if (inst.base.ty.zigTypeTag() == .Pointer and inst.operand.ty.zigTypeTag() == .Pointer) {
        const local = try o.allocLocal(inst.base.ty, .Const);
        try writer.writeAll(" = (");
        try o.dg.renderType(writer, inst.base.ty);

        try writer.writeAll(")");
        try o.writeCValue(writer, operand);
        try writer.writeAll(";\n");
        return local;
    }

    const local = try o.allocLocal(inst.base.ty, .Mut);
    try writer.writeAll(";\n");
    try o.indent();

    try writer.writeAll("memcpy(&");
    try o.writeCValue(writer, local);
    try writer.writeAll(", &");
    try o.writeCValue(writer, operand);
    try writer.writeAll(", sizeof ");
    try o.writeCValue(writer, local);
    try writer.writeAll(");\n");

    return local;
}

fn genBreakpoint(o: *Object, inst: *Inst.NoOp) !CValue {
    try o.indent();
    try o.code.writer().writeAll("zig_breakpoint();\n");
    return CValue.none;
}

fn genUnreach(o: *Object, inst: *Inst.NoOp) !CValue {
    try o.indent();
    try o.code.writer().writeAll("zig_unreachable();\n");
    return CValue.none;
}

fn genAsm(o: *Object, as: *Inst.Assembly) !CValue {
    if (as.base.isUnused() and !as.is_volatile)
        return CValue.none;

    const writer = o.code.writer();
    for (as.inputs) |i, index| {
        if (i[0] == '{' and i[i.len - 1] == '}') {
            const reg = i[1 .. i.len - 1];
            const arg = as.args[index];
            const arg_c_value = try o.resolveInst(arg);
            try o.indent();
            try writer.writeAll("register ");
            try o.dg.renderType(writer, arg.ty);

            try writer.print(" {s}_constant __asm__(\"{s}\") = ", .{ reg, reg });
            try o.writeCValue(writer, arg_c_value);
            try writer.writeAll(";\n");
        } else {
            return o.dg.fail(o.dg.decl.src(), "TODO non-explicit inline asm regs", .{});
        }
    }
    try o.indent();
    const volatile_string: []const u8 = if (as.is_volatile) "volatile " else "";
    try writer.print("__asm {s}(\"{s}\"", .{ volatile_string, as.asm_source });
    if (as.output) |_| {
        return o.dg.fail(o.dg.decl.src(), "TODO inline asm output", .{});
    }
    if (as.inputs.len > 0) {
        if (as.output == null) {
            try writer.writeAll(" :");
        }
        try writer.writeAll(": ");
        for (as.inputs) |i, index| {
            if (i[0] == '{' and i[i.len - 1] == '}') {
                const reg = i[1 .. i.len - 1];
                const arg = as.args[index];
                if (index > 0) {
                    try writer.writeAll(", ");
                }
                try writer.print("\"r\"({s}_constant)", .{reg});
            } else {
                // This is blocked by the earlier test
                unreachable;
            }
        }
    }
    try writer.writeAll(");\n");

    if (as.base.isUnused())
        return CValue.none;

    return o.dg.fail(o.dg.decl.src(), "TODO: C backend: inline asm expression result used", .{});
}
