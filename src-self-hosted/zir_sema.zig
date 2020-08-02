//! Semantic analysis of ZIR instructions.
//! This file operates on a `Module` instance, transforming untyped ZIR
//! instructions into semantically-analyzed IR instructions. It does type
//! checking, comptime control flow, and safety-check generation. This is the
//! the heart of the Zig compiler.
//! When deciding if something goes into this file or into Module, here is a
//! guiding principle: if it has to do with (untyped) ZIR instructions, it goes
//! here. If the analysis operates on typed IR instructions, it goes in Module.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const assert = std.debug.assert;
const ir = @import("ir.zig");
const zir = @import("zir.zig");
const Module = @import("Module.zig");
const Inst = ir.Inst;
const Body = ir.Body;
const trace = @import("tracy.zig").trace;
const Scope = Module.Scope;
const InnerError = Module.InnerError;
const Decl = Module.Decl;

pub fn analyzeInst(mod: *Module, scope: *Scope, old_inst: *zir.Inst) InnerError!*Inst {
    switch (old_inst.tag) {
        .alloc => return analyzeInstAlloc(mod, scope, old_inst.castTag(.alloc).?),
        .alloc_inferred => return analyzeInstAllocInferred(mod, scope, old_inst.castTag(.alloc_inferred).?),
        .arg => return analyzeInstArg(mod, scope, old_inst.castTag(.arg).?),
        .bitcast_lvalue => return analyzeInstBitCastLValue(mod, scope, old_inst.castTag(.bitcast_lvalue).?),
        .bitcast_result_ptr => return analyzeInstBitCastResultPtr(mod, scope, old_inst.castTag(.bitcast_result_ptr).?),
        .block => return analyzeInstBlock(mod, scope, old_inst.castTag(.block).?),
        .@"break" => return analyzeInstBreak(mod, scope, old_inst.castTag(.@"break").?),
        .breakpoint => return analyzeInstBreakpoint(mod, scope, old_inst.castTag(.breakpoint).?),
        .breakvoid => return analyzeInstBreakVoid(mod, scope, old_inst.castTag(.breakvoid).?),
        .call => return analyzeInstCall(mod, scope, old_inst.castTag(.call).?),
        .coerce_result_block_ptr => return analyzeInstCoerceResultBlockPtr(mod, scope, old_inst.castTag(.coerce_result_block_ptr).?),
        .coerce_result_ptr => return analyzeInstCoerceResultPtr(mod, scope, old_inst.castTag(.coerce_result_ptr).?),
        .coerce_to_ptr_elem => return analyzeInstCoerceToPtrElem(mod, scope, old_inst.castTag(.coerce_to_ptr_elem).?),
        .compileerror => return analyzeInstCompileError(mod, scope, old_inst.castTag(.compileerror).?),
        .@"const" => return analyzeInstConst(mod, scope, old_inst.castTag(.@"const").?),
        .declref => return analyzeInstDeclRef(mod, scope, old_inst.castTag(.declref).?),
        .declref_str => return analyzeInstDeclRefStr(mod, scope, old_inst.castTag(.declref_str).?),
        .declval => return analyzeInstDeclVal(mod, scope, old_inst.castTag(.declval).?),
        .declval_in_module => return analyzeInstDeclValInModule(mod, scope, old_inst.castTag(.declval_in_module).?),
        .ensure_result_used => return analyzeInstEnsureResultUsed(mod, scope, old_inst.castTag(.ensure_result_used).?),
        .ensure_result_non_error => return analyzeInstEnsureResultNonError(mod, scope, old_inst.castTag(.ensure_result_non_error).?),
        .ref => return analyzeInstRef(mod, scope, old_inst.castTag(.ref).?),
        .ret_ptr => return analyzeInstRetPtr(mod, scope, old_inst.castTag(.ret_ptr).?),
        .ret_type => return analyzeInstRetType(mod, scope, old_inst.castTag(.ret_type).?),
        .single_const_ptr_type => return analyzeInstSingleConstPtrType(mod, scope, old_inst.castTag(.single_const_ptr_type).?),
        .single_mut_ptr_type => return analyzeInstSingleMutPtrType(mod, scope, old_inst.castTag(.single_mut_ptr_type).?),
        .store => return analyzeInstStore(mod, scope, old_inst.castTag(.store).?),
        .str => return analyzeInstStr(mod, scope, old_inst.castTag(.str).?),
        .int => {
            const big_int = old_inst.castTag(.int).?.positionals.int;
            return mod.constIntBig(scope, old_inst.src, Type.initTag(.comptime_int), big_int);
        },
        .inttype => return analyzeInstIntType(mod, scope, old_inst.castTag(.inttype).?),
        .param_type => return analyzeInstParamType(mod, scope, old_inst.castTag(.param_type).?),
        .ptrtoint => return analyzeInstPtrToInt(mod, scope, old_inst.castTag(.ptrtoint).?),
        .fieldptr => return analyzeInstFieldPtr(mod, scope, old_inst.castTag(.fieldptr).?),
        .deref => return analyzeInstDeref(mod, scope, old_inst.castTag(.deref).?),
        .as => return analyzeInstAs(mod, scope, old_inst.castTag(.as).?),
        .@"asm" => return analyzeInstAsm(mod, scope, old_inst.castTag(.@"asm").?),
        .@"unreachable" => return analyzeInstUnreachable(mod, scope, old_inst.castTag(.@"unreachable").?),
        .unreach_nocheck => return analyzeInstUnreachNoChk(mod, scope, old_inst.castTag(.unreach_nocheck).?),
        .@"return" => return analyzeInstRet(mod, scope, old_inst.castTag(.@"return").?),
        .returnvoid => return analyzeInstRetVoid(mod, scope, old_inst.castTag(.returnvoid).?),
        .@"fn" => return analyzeInstFn(mod, scope, old_inst.castTag(.@"fn").?),
        .@"export" => return analyzeInstExport(mod, scope, old_inst.castTag(.@"export").?),
        .primitive => return analyzeInstPrimitive(mod, scope, old_inst.castTag(.primitive).?),
        .fntype => return analyzeInstFnType(mod, scope, old_inst.castTag(.fntype).?),
        .intcast => return analyzeInstIntCast(mod, scope, old_inst.castTag(.intcast).?),
        .bitcast => return analyzeInstBitCast(mod, scope, old_inst.castTag(.bitcast).?),
        .floatcast => return analyzeInstFloatCast(mod, scope, old_inst.castTag(.floatcast).?),
        .elemptr => return analyzeInstElemPtr(mod, scope, old_inst.castTag(.elemptr).?),
        .add => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.add).?),
        .addwrap => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.addwrap).?),
        .sub => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.sub).?),
        .subwrap => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.subwrap).?),
        .mul => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.mul).?),
        .mulwrap => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.mulwrap).?),
        .div => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.div).?),
        .mod_rem => return analyzeInstArithmetic(mod, scope, old_inst.castTag(.mod_rem).?),
        .array_cat => return analyzeInstArrayCat(mod, scope, old_inst.castTag(.array_cat).?),
        .array_mul => return analyzeInstArrayMul(mod, scope, old_inst.castTag(.array_mul).?),
        .bitand => return analyzeInstBitwise(mod, scope, old_inst.castTag(.bitand).?),
        .bitor => return analyzeInstBitwise(mod, scope, old_inst.castTag(.bitor).?),
        .xor => return analyzeInstBitwise(mod, scope, old_inst.castTag(.xor).?),
        .shl => return analyzeInstShl(mod, scope, old_inst.castTag(.shl).?),
        .shr => return analyzeInstShr(mod, scope, old_inst.castTag(.shr).?),
        .cmp_lt => return analyzeInstCmp(mod, scope, old_inst.castTag(.cmp_lt).?, .lt),
        .cmp_lte => return analyzeInstCmp(mod, scope, old_inst.castTag(.cmp_lte).?, .lte),
        .cmp_eq => return analyzeInstCmp(mod, scope, old_inst.castTag(.cmp_eq).?, .eq),
        .cmp_gte => return analyzeInstCmp(mod, scope, old_inst.castTag(.cmp_gte).?, .gte),
        .cmp_gt => return analyzeInstCmp(mod, scope, old_inst.castTag(.cmp_gt).?, .gt),
        .cmp_neq => return analyzeInstCmp(mod, scope, old_inst.castTag(.cmp_neq).?, .neq),
        .condbr => return analyzeInstCondBr(mod, scope, old_inst.castTag(.condbr).?),
        .isnull => return analyzeInstIsNonNull(mod, scope, old_inst.castTag(.isnull).?, true),
        .isnonnull => return analyzeInstIsNonNull(mod, scope, old_inst.castTag(.isnonnull).?, false),
        .boolnot => return analyzeInstBoolNot(mod, scope, old_inst.castTag(.boolnot).?),
        .typeof => return analyzeInstTypeOf(mod, scope, old_inst.castTag(.typeof).?),
    }
}

pub fn analyzeBody(mod: *Module, scope: *Scope, body: zir.Module.Body) !void {
    for (body.instructions) |src_inst| {
        src_inst.analyzed_inst = try analyzeInst(mod, scope, src_inst);
    }
}

pub fn analyzeBodyValueAsType(mod: *Module, block_scope: *Scope.Block, body: zir.Module.Body) !Type {
    try analyzeBody(mod, &block_scope.base, body);
    for (block_scope.instructions.items) |inst| {
        if (inst.castTag(.ret)) |ret| {
            const val = try mod.resolveConstValue(&block_scope.base, ret.operand);
            return val.toType();
        } else {
            return mod.fail(&block_scope.base, inst.src, "unable to resolve comptime value", .{});
        }
    }
    unreachable;
}

pub fn analyzeZirDecl(mod: *Module, decl: *Decl, src_decl: *zir.Decl) InnerError!bool {
    var decl_scope: Scope.DeclAnalysis = .{
        .decl = decl,
        .arena = std.heap.ArenaAllocator.init(mod.gpa),
    };
    errdefer decl_scope.arena.deinit();

    decl.analysis = .in_progress;

    const typed_value = try analyzeConstInst(mod, &decl_scope.base, src_decl.inst);
    const arena_state = try decl_scope.arena.allocator.create(std.heap.ArenaAllocator.State);

    var prev_type_has_bits = false;
    var type_changed = true;

    if (decl.typedValueManaged()) |tvm| {
        prev_type_has_bits = tvm.typed_value.ty.hasCodeGenBits();
        type_changed = !tvm.typed_value.ty.eql(typed_value.ty);

        tvm.deinit(mod.gpa);
    }

    arena_state.* = decl_scope.arena.state;
    decl.typed_value = .{
        .most_recent = .{
            .typed_value = typed_value,
            .arena = arena_state,
        },
    };
    decl.analysis = .complete;
    decl.generation = mod.generation;
    if (typed_value.ty.hasCodeGenBits()) {
        // We don't fully codegen the decl until later, but we do need to reserve a global
        // offset table index for it. This allows us to codegen decls out of dependency order,
        // increasing how many computations can be done in parallel.
        try mod.bin_file.allocateDeclIndexes(decl);
        try mod.work_queue.writeItem(.{ .codegen_decl = decl });
    } else if (prev_type_has_bits) {
        mod.bin_file.freeDecl(decl);
    }

    return type_changed;
}

pub fn resolveZirDecl(mod: *Module, scope: *Scope, src_decl: *zir.Decl) InnerError!*Decl {
    const zir_module = mod.root_scope.cast(Scope.ZIRModule).?;
    const entry = zir_module.contents.module.findDecl(src_decl.name).?;
    return resolveZirDeclHavingIndex(mod, scope, src_decl, entry.index);
}

fn resolveZirDeclHavingIndex(mod: *Module, scope: *Scope, src_decl: *zir.Decl, src_index: usize) InnerError!*Decl {
    const name_hash = scope.namespace().fullyQualifiedNameHash(src_decl.name);
    const decl = mod.decl_table.get(name_hash).?;
    decl.src_index = src_index;
    try mod.ensureDeclAnalyzed(decl);
    return decl;
}

/// Declares a dependency on the decl.
fn resolveCompleteZirDecl(mod: *Module, scope: *Scope, src_decl: *zir.Decl) InnerError!*Decl {
    const decl = try resolveZirDecl(mod, scope, src_decl);
    switch (decl.analysis) {
        .unreferenced => unreachable,
        .in_progress => unreachable,
        .outdated => unreachable,

        .dependency_failure,
        .sema_failure,
        .sema_failure_retryable,
        .codegen_failure,
        .codegen_failure_retryable,
        => return error.AnalysisFail,

        .complete => {},
    }
    return decl;
}

/// TODO Look into removing this function. The body is only needed for .zir files, not .zig files.
pub fn resolveInst(mod: *Module, scope: *Scope, old_inst: *zir.Inst) InnerError!*Inst {
    if (old_inst.analyzed_inst) |inst| return inst;

    // If this assert trips, the instruction that was referenced did not get properly
    // analyzed before it was referenced.
    const zir_module = scope.namespace().cast(Scope.ZIRModule).?;
    const entry = if (old_inst.cast(zir.Inst.DeclVal)) |declval| blk: {
        const decl_name = declval.positionals.name;
        const entry = zir_module.contents.module.findDecl(decl_name) orelse
            return mod.fail(scope, old_inst.src, "decl '{}' not found", .{decl_name});
        break :blk entry;
    } else blk: {
        // If this assert trips, the instruction that was referenced did not get
        // properly analyzed by a previous instruction analysis before it was
        // referenced by the current one.
        break :blk zir_module.contents.module.findInstDecl(old_inst).?;
    };
    const decl = try resolveCompleteZirDecl(mod, scope, entry.decl);
    const decl_ref = try mod.analyzeDeclRef(scope, old_inst.src, decl);
    // Note: it would be tempting here to store the result into old_inst.analyzed_inst field,
    // but this would prevent the analyzeDeclRef from happening, which is needed to properly
    // detect Decl dependencies and dependency failures on updates.
    return mod.analyzeDeref(scope, old_inst.src, decl_ref, old_inst.src);
}

fn resolveConstString(mod: *Module, scope: *Scope, old_inst: *zir.Inst) ![]u8 {
    const new_inst = try resolveInst(mod, scope, old_inst);
    const wanted_type = Type.initTag(.const_slice_u8);
    const coerced_inst = try mod.coerce(scope, wanted_type, new_inst);
    const val = try mod.resolveConstValue(scope, coerced_inst);
    return val.toAllocatedBytes(scope.arena());
}

fn resolveType(mod: *Module, scope: *Scope, old_inst: *zir.Inst) !Type {
    const new_inst = try resolveInst(mod, scope, old_inst);
    const wanted_type = Type.initTag(.@"type");
    const coerced_inst = try mod.coerce(scope, wanted_type, new_inst);
    const val = try mod.resolveConstValue(scope, coerced_inst);
    return val.toType();
}

pub fn resolveInstConst(mod: *Module, scope: *Scope, old_inst: *zir.Inst) InnerError!TypedValue {
    const new_inst = try resolveInst(mod, scope, old_inst);
    const val = try mod.resolveConstValue(scope, new_inst);
    return TypedValue{
        .ty = new_inst.ty,
        .val = val,
    };
}

fn analyzeInstConst(mod: *Module, scope: *Scope, const_inst: *zir.Inst.Const) InnerError!*Inst {
    // Move the TypedValue from old memory to new memory. This allows freeing the ZIR instructions
    // after analysis.
    const typed_value_copy = try const_inst.positionals.typed_value.copy(scope.arena());
    return mod.constInst(scope, const_inst.base.src, typed_value_copy);
}

fn analyzeConstInst(mod: *Module, scope: *Scope, old_inst: *zir.Inst) InnerError!TypedValue {
    const new_inst = try analyzeInst(mod, scope, old_inst);
    return TypedValue{
        .ty = new_inst.ty,
        .val = try mod.resolveConstValue(scope, new_inst),
    };
}

fn analyzeInstCoerceResultBlockPtr(
    mod: *Module,
    scope: *Scope,
    inst: *zir.Inst.CoerceResultBlockPtr,
) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstCoerceResultBlockPtr", .{});
}

fn analyzeInstBitCastLValue(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstBitCastLValue", .{});
}

fn analyzeInstBitCastResultPtr(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstBitCastResultPtr", .{});
}

fn analyzeInstCoerceResultPtr(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstCoerceResultPtr", .{});
}

/// Equivalent to `as(ptr_child_type(typeof(ptr)), value)`.
fn analyzeInstCoerceToPtrElem(mod: *Module, scope: *Scope, inst: *zir.Inst.CoerceToPtrElem) InnerError!*Inst {
    const ptr = try resolveInst(mod, scope, inst.positionals.ptr);
    const operand = try resolveInst(mod, scope, inst.positionals.value);
    return mod.coerce(scope, ptr.ty.elemType(), operand);
}

fn analyzeInstRetPtr(mod: *Module, scope: *Scope, inst: *zir.Inst.NoOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstRetPtr", .{});
}

fn analyzeInstRef(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    const ptr_type = try mod.singleConstPtrType(scope, inst.base.src, operand.ty);
    return mod.addUnOp(b, inst.base.src, ptr_type, .ref, operand);
}

fn analyzeInstRetType(mod: *Module, scope: *Scope, inst: *zir.Inst.NoOp) InnerError!*Inst {
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    const fn_ty = b.func.?.owner_decl.typed_value.most_recent.typed_value.ty;
    const ret_type = fn_ty.fnReturnType();
    return mod.constType(scope, inst.base.src, ret_type);
}

fn analyzeInstEnsureResultUsed(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    switch (operand.ty.zigTypeTag()) {
        .Void, .NoReturn => return mod.constVoid(scope, operand.src),
        else => return mod.fail(scope, operand.src, "expression value is ignored", .{}),
    }
}

fn analyzeInstEnsureResultNonError(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    switch (operand.ty.zigTypeTag()) {
        .ErrorSet, .ErrorUnion => return mod.fail(scope, operand.src, "error is discarded", .{}),
        else => return mod.constVoid(scope, operand.src),
    }
}

fn analyzeInstAlloc(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const var_type = try resolveType(mod, scope, inst.positionals.operand);
    const ptr_type = try mod.singleMutPtrType(scope, inst.base.src, var_type);
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    return mod.addNoOp(b, inst.base.src, ptr_type, .alloc);
}

fn analyzeInstAllocInferred(mod: *Module, scope: *Scope, inst: *zir.Inst.NoOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstAllocInferred", .{});
}

fn analyzeInstStore(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    const ptr = try resolveInst(mod, scope, inst.positionals.lhs);
    const value = try resolveInst(mod, scope, inst.positionals.rhs);
    return mod.storePtr(scope, inst.base.src, ptr, value);
}

fn analyzeInstParamType(mod: *Module, scope: *Scope, inst: *zir.Inst.ParamType) InnerError!*Inst {
    const fn_inst = try resolveInst(mod, scope, inst.positionals.func);
    const arg_index = inst.positionals.arg_index;

    const fn_ty: Type = switch (fn_inst.ty.zigTypeTag()) {
        .Fn => fn_inst.ty,
        .BoundFn => {
            return mod.fail(scope, fn_inst.src, "TODO implement analyzeInstParamType for method call syntax", .{});
        },
        else => {
            return mod.fail(scope, fn_inst.src, "expected function, found '{}'", .{fn_inst.ty});
        },
    };

    // TODO support C-style var args
    const param_count = fn_ty.fnParamLen();
    if (arg_index >= param_count) {
        return mod.fail(scope, inst.base.src, "arg index {} out of bounds; '{}' has {} arguments", .{
            arg_index,
            fn_ty,
            param_count,
        });
    }

    // TODO support generic functions
    const param_type = fn_ty.fnParamType(arg_index);
    return mod.constType(scope, inst.base.src, param_type);
}

fn analyzeInstStr(mod: *Module, scope: *Scope, str_inst: *zir.Inst.Str) InnerError!*Inst {
    // The bytes references memory inside the ZIR module, which can get deallocated
    // after semantic analysis is complete. We need the memory to be in the new anonymous Decl's arena.
    var new_decl_arena = std.heap.ArenaAllocator.init(mod.gpa);
    const arena_bytes = try new_decl_arena.allocator.dupe(u8, str_inst.positionals.bytes);

    const ty_payload = try scope.arena().create(Type.Payload.Array_u8_Sentinel0);
    ty_payload.* = .{ .len = arena_bytes.len };

    const bytes_payload = try scope.arena().create(Value.Payload.Bytes);
    bytes_payload.* = .{ .data = arena_bytes };

    const new_decl = try mod.createAnonymousDecl(scope, &new_decl_arena, .{
        .ty = Type.initPayload(&ty_payload.base),
        .val = Value.initPayload(&bytes_payload.base),
    });
    return mod.analyzeDeclRef(scope, str_inst.base.src, new_decl);
}

fn analyzeInstExport(mod: *Module, scope: *Scope, export_inst: *zir.Inst.Export) InnerError!*Inst {
    const symbol_name = try resolveConstString(mod, scope, export_inst.positionals.symbol_name);
    const exported_decl = mod.lookupDeclName(scope, export_inst.positionals.decl_name) orelse
        return mod.fail(scope, export_inst.base.src, "decl '{}' not found", .{export_inst.positionals.decl_name});
    try mod.analyzeExport(scope, export_inst.base.src, symbol_name, exported_decl);
    return mod.constVoid(scope, export_inst.base.src);
}

fn analyzeInstCompileError(mod: *Module, scope: *Scope, inst: *zir.Inst.CompileError) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "{}", .{inst.positionals.msg});
}

fn analyzeInstArg(mod: *Module, scope: *Scope, inst: *zir.Inst.NoOp) InnerError!*Inst {
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    const fn_ty = b.func.?.owner_decl.typed_value.most_recent.typed_value.ty;
    const param_index = b.instructions.items.len;
    const param_count = fn_ty.fnParamLen();
    if (param_index >= param_count) {
        return mod.fail(scope, inst.base.src, "parameter index {} outside list of length {}", .{
            param_index,
            param_count,
        });
    }
    const param_type = fn_ty.fnParamType(param_index);
    return mod.addNoOp(b, inst.base.src, param_type, .arg);
}

fn analyzeInstBlock(mod: *Module, scope: *Scope, inst: *zir.Inst.Block) InnerError!*Inst {
    const parent_block = scope.cast(Scope.Block).?;

    // Reserve space for a Block instruction so that generated Break instructions can
    // point to it, even if it doesn't end up getting used because the code ends up being
    // comptime evaluated.
    const block_inst = try parent_block.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = undefined, // Set after analysis.
            .src = inst.base.src,
        },
        .body = undefined,
    };

    var child_block: Scope.Block = .{
        .parent = parent_block,
        .func = parent_block.func,
        .decl = parent_block.decl,
        .instructions = .{},
        .arena = parent_block.arena,
        // TODO @as here is working around a miscompilation compiler bug :(
        .label = @as(?Scope.Block.Label, Scope.Block.Label{
            .zir_block = inst,
            .results = .{},
            .block_inst = block_inst,
        }),
    };
    const label = &child_block.label.?;

    defer child_block.instructions.deinit(mod.gpa);
    defer label.results.deinit(mod.gpa);

    try analyzeBody(mod, &child_block.base, inst.positionals.body);

    // Blocks must terminate with noreturn instruction.
    assert(child_block.instructions.items.len != 0);
    assert(child_block.instructions.items[child_block.instructions.items.len - 1].ty.isNoReturn());

    // Need to set the type and emit the Block instruction. This allows machine code generation
    // to emit a jump instruction to after the block when it encounters the break.
    try parent_block.instructions.append(mod.gpa, &block_inst.base);
    block_inst.base.ty = try mod.resolvePeerTypes(scope, label.results.items);
    block_inst.body = .{ .instructions = try parent_block.arena.dupe(*Inst, child_block.instructions.items) };
    return &block_inst.base;
}

fn analyzeInstBreakpoint(mod: *Module, scope: *Scope, inst: *zir.Inst.NoOp) InnerError!*Inst {
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    return mod.addNoOp(b, inst.base.src, Type.initTag(.void), .breakpoint);
}

fn analyzeInstBreak(mod: *Module, scope: *Scope, inst: *zir.Inst.Break) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    const block = inst.positionals.block;
    return analyzeBreak(mod, scope, inst.base.src, block, operand);
}

fn analyzeInstBreakVoid(mod: *Module, scope: *Scope, inst: *zir.Inst.BreakVoid) InnerError!*Inst {
    const block = inst.positionals.block;
    const void_inst = try mod.constVoid(scope, inst.base.src);
    return analyzeBreak(mod, scope, inst.base.src, block, void_inst);
}

fn analyzeInstDeclRefStr(mod: *Module, scope: *Scope, inst: *zir.Inst.DeclRefStr) InnerError!*Inst {
    const decl_name = try resolveConstString(mod, scope, inst.positionals.name);
    return mod.analyzeDeclRefByName(scope, inst.base.src, decl_name);
}

fn analyzeInstDeclRef(mod: *Module, scope: *Scope, inst: *zir.Inst.DeclRef) InnerError!*Inst {
    return mod.analyzeDeclRefByName(scope, inst.base.src, inst.positionals.name);
}

fn analyzeInstDeclVal(mod: *Module, scope: *Scope, inst: *zir.Inst.DeclVal) InnerError!*Inst {
    const decl = try analyzeDeclVal(mod, scope, inst);
    const ptr = try mod.analyzeDeclRef(scope, inst.base.src, decl);
    return mod.analyzeDeref(scope, inst.base.src, ptr, inst.base.src);
}

fn analyzeInstDeclValInModule(mod: *Module, scope: *Scope, inst: *zir.Inst.DeclValInModule) InnerError!*Inst {
    const decl = inst.positionals.decl;
    const ptr = try mod.analyzeDeclRef(scope, inst.base.src, decl);
    return mod.analyzeDeref(scope, inst.base.src, ptr, inst.base.src);
}

fn analyzeInstCall(mod: *Module, scope: *Scope, inst: *zir.Inst.Call) InnerError!*Inst {
    const func = try resolveInst(mod, scope, inst.positionals.func);
    if (func.ty.zigTypeTag() != .Fn)
        return mod.fail(scope, inst.positionals.func.src, "type '{}' not a function", .{func.ty});

    const cc = func.ty.fnCallingConvention();
    if (cc == .Naked) {
        // TODO add error note: declared here
        return mod.fail(
            scope,
            inst.positionals.func.src,
            "unable to call function with naked calling convention",
            .{},
        );
    }
    const call_params_len = inst.positionals.args.len;
    const fn_params_len = func.ty.fnParamLen();
    if (func.ty.fnIsVarArgs()) {
        if (call_params_len < fn_params_len) {
            // TODO add error note: declared here
            return mod.fail(
                scope,
                inst.positionals.func.src,
                "expected at least {} arguments, found {}",
                .{ fn_params_len, call_params_len },
            );
        }
        return mod.fail(scope, inst.base.src, "TODO implement support for calling var args functions", .{});
    } else if (fn_params_len != call_params_len) {
        // TODO add error note: declared here
        return mod.fail(
            scope,
            inst.positionals.func.src,
            "expected {} arguments, found {}",
            .{ fn_params_len, call_params_len },
        );
    }

    if (inst.kw_args.modifier == .compile_time) {
        return mod.fail(scope, inst.base.src, "TODO implement comptime function calls", .{});
    }
    if (inst.kw_args.modifier != .auto) {
        return mod.fail(scope, inst.base.src, "TODO implement call with modifier {}", .{inst.kw_args.modifier});
    }

    // TODO handle function calls of generic functions

    const fn_param_types = try mod.gpa.alloc(Type, fn_params_len);
    defer mod.gpa.free(fn_param_types);
    func.ty.fnParamTypes(fn_param_types);

    const casted_args = try scope.arena().alloc(*Inst, fn_params_len);
    for (inst.positionals.args) |src_arg, i| {
        const uncasted_arg = try resolveInst(mod, scope, src_arg);
        casted_args[i] = try mod.coerce(scope, fn_param_types[i], uncasted_arg);
    }

    const ret_type = func.ty.fnReturnType();

    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    return mod.addCall(b, inst.base.src, ret_type, func, casted_args);
}

fn analyzeInstFn(mod: *Module, scope: *Scope, fn_inst: *zir.Inst.Fn) InnerError!*Inst {
    const fn_type = try resolveType(mod, scope, fn_inst.positionals.fn_type);
    const fn_zir = blk: {
        var fn_arena = std.heap.ArenaAllocator.init(mod.gpa);
        errdefer fn_arena.deinit();

        const fn_zir = try scope.arena().create(Module.Fn.ZIR);
        fn_zir.* = .{
            .body = .{
                .instructions = fn_inst.positionals.body.instructions,
            },
            .arena = fn_arena.state,
        };
        break :blk fn_zir;
    };
    const new_func = try scope.arena().create(Module.Fn);
    new_func.* = .{
        .analysis = .{ .queued = fn_zir },
        .owner_decl = scope.decl().?,
    };
    const fn_payload = try scope.arena().create(Value.Payload.Function);
    fn_payload.* = .{ .func = new_func };
    return mod.constInst(scope, fn_inst.base.src, .{
        .ty = fn_type,
        .val = Value.initPayload(&fn_payload.base),
    });
}

fn analyzeInstIntType(mod: *Module, scope: *Scope, inttype: *zir.Inst.IntType) InnerError!*Inst {
    return mod.fail(scope, inttype.base.src, "TODO implement inttype", .{});
}

fn analyzeInstFnType(mod: *Module, scope: *Scope, fntype: *zir.Inst.FnType) InnerError!*Inst {
    const return_type = try resolveType(mod, scope, fntype.positionals.return_type);

    // Hot path for some common function types.
    if (fntype.positionals.param_types.len == 0) {
        if (return_type.zigTypeTag() == .NoReturn and fntype.kw_args.cc == .Unspecified) {
            return mod.constType(scope, fntype.base.src, Type.initTag(.fn_noreturn_no_args));
        }

        if (return_type.zigTypeTag() == .Void and fntype.kw_args.cc == .Unspecified) {
            return mod.constType(scope, fntype.base.src, Type.initTag(.fn_void_no_args));
        }

        if (return_type.zigTypeTag() == .NoReturn and fntype.kw_args.cc == .Naked) {
            return mod.constType(scope, fntype.base.src, Type.initTag(.fn_naked_noreturn_no_args));
        }

        if (return_type.zigTypeTag() == .Void and fntype.kw_args.cc == .C) {
            return mod.constType(scope, fntype.base.src, Type.initTag(.fn_ccc_void_no_args));
        }
    }

    const arena = scope.arena();
    const param_types = try arena.alloc(Type, fntype.positionals.param_types.len);
    for (fntype.positionals.param_types) |param_type, i| {
        param_types[i] = try resolveType(mod, scope, param_type);
    }

    const payload = try arena.create(Type.Payload.Function);
    payload.* = .{
        .cc = fntype.kw_args.cc,
        .return_type = return_type,
        .param_types = param_types,
    };
    return mod.constType(scope, fntype.base.src, Type.initPayload(&payload.base));
}

fn analyzeInstPrimitive(mod: *Module, scope: *Scope, primitive: *zir.Inst.Primitive) InnerError!*Inst {
    return mod.constInst(scope, primitive.base.src, primitive.positionals.tag.toTypedValue());
}

fn analyzeInstAs(mod: *Module, scope: *Scope, as: *zir.Inst.BinOp) InnerError!*Inst {
    const dest_type = try resolveType(mod, scope, as.positionals.lhs);
    const new_inst = try resolveInst(mod, scope, as.positionals.rhs);
    return mod.coerce(scope, dest_type, new_inst);
}

fn analyzeInstPtrToInt(mod: *Module, scope: *Scope, ptrtoint: *zir.Inst.UnOp) InnerError!*Inst {
    const ptr = try resolveInst(mod, scope, ptrtoint.positionals.operand);
    if (ptr.ty.zigTypeTag() != .Pointer) {
        return mod.fail(scope, ptrtoint.positionals.operand.src, "expected pointer, found '{}'", .{ptr.ty});
    }
    // TODO handle known-pointer-address
    const b = try mod.requireRuntimeBlock(scope, ptrtoint.base.src);
    const ty = Type.initTag(.usize);
    return mod.addUnOp(b, ptrtoint.base.src, ty, .ptrtoint, ptr);
}

fn analyzeInstFieldPtr(mod: *Module, scope: *Scope, fieldptr: *zir.Inst.FieldPtr) InnerError!*Inst {
    const object_ptr = try resolveInst(mod, scope, fieldptr.positionals.object_ptr);
    const field_name = try resolveConstString(mod, scope, fieldptr.positionals.field_name);

    const elem_ty = switch (object_ptr.ty.zigTypeTag()) {
        .Pointer => object_ptr.ty.elemType(),
        else => return mod.fail(scope, fieldptr.positionals.object_ptr.src, "expected pointer, found '{}'", .{object_ptr.ty}),
    };
    switch (elem_ty.zigTypeTag()) {
        .Array => {
            if (mem.eql(u8, field_name, "len")) {
                const len_payload = try scope.arena().create(Value.Payload.Int_u64);
                len_payload.* = .{ .int = elem_ty.arrayLen() };

                const ref_payload = try scope.arena().create(Value.Payload.RefVal);
                ref_payload.* = .{ .val = Value.initPayload(&len_payload.base) };

                return mod.constInst(scope, fieldptr.base.src, .{
                    .ty = Type.initTag(.single_const_pointer_to_comptime_int),
                    .val = Value.initPayload(&ref_payload.base),
                });
            } else {
                return mod.fail(
                    scope,
                    fieldptr.positionals.field_name.src,
                    "no member named '{}' in '{}'",
                    .{ field_name, elem_ty },
                );
            }
        },
        else => return mod.fail(scope, fieldptr.base.src, "type '{}' does not support field access", .{elem_ty}),
    }
}

fn analyzeInstIntCast(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    const dest_type = try resolveType(mod, scope, inst.positionals.lhs);
    const operand = try resolveInst(mod, scope, inst.positionals.rhs);

    const dest_is_comptime_int = switch (dest_type.zigTypeTag()) {
        .ComptimeInt => true,
        .Int => false,
        else => return mod.fail(
            scope,
            inst.positionals.lhs.src,
            "expected integer type, found '{}'",
            .{
                dest_type,
            },
        ),
    };

    switch (operand.ty.zigTypeTag()) {
        .ComptimeInt, .Int => {},
        else => return mod.fail(
            scope,
            inst.positionals.rhs.src,
            "expected integer type, found '{}'",
            .{operand.ty},
        ),
    }

    if (operand.value() != null) {
        return mod.coerce(scope, dest_type, operand);
    } else if (dest_is_comptime_int) {
        return mod.fail(scope, inst.base.src, "unable to cast runtime value to 'comptime_int'", .{});
    }

    return mod.fail(scope, inst.base.src, "TODO implement analyze widen or shorten int", .{});
}

fn analyzeInstBitCast(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    const dest_type = try resolveType(mod, scope, inst.positionals.lhs);
    const operand = try resolveInst(mod, scope, inst.positionals.rhs);
    return mod.bitcast(scope, dest_type, operand);
}

fn analyzeInstFloatCast(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    const dest_type = try resolveType(mod, scope, inst.positionals.lhs);
    const operand = try resolveInst(mod, scope, inst.positionals.rhs);

    const dest_is_comptime_float = switch (dest_type.zigTypeTag()) {
        .ComptimeFloat => true,
        .Float => false,
        else => return mod.fail(
            scope,
            inst.positionals.lhs.src,
            "expected float type, found '{}'",
            .{
                dest_type,
            },
        ),
    };

    switch (operand.ty.zigTypeTag()) {
        .ComptimeFloat, .Float, .ComptimeInt => {},
        else => return mod.fail(
            scope,
            inst.positionals.rhs.src,
            "expected float type, found '{}'",
            .{operand.ty},
        ),
    }

    if (operand.value() != null) {
        return mod.coerce(scope, dest_type, operand);
    } else if (dest_is_comptime_float) {
        return mod.fail(scope, inst.base.src, "unable to cast runtime value to 'comptime_float'", .{});
    }

    return mod.fail(scope, inst.base.src, "TODO implement analyze widen or shorten float", .{});
}

fn analyzeInstElemPtr(mod: *Module, scope: *Scope, inst: *zir.Inst.ElemPtr) InnerError!*Inst {
    const array_ptr = try resolveInst(mod, scope, inst.positionals.array_ptr);
    const uncasted_index = try resolveInst(mod, scope, inst.positionals.index);
    const elem_index = try mod.coerce(scope, Type.initTag(.usize), uncasted_index);

    if (array_ptr.ty.isSinglePointer() and array_ptr.ty.elemType().zigTypeTag() == .Array) {
        if (array_ptr.value()) |array_ptr_val| {
            if (elem_index.value()) |index_val| {
                // Both array pointer and index are compile-time known.
                const index_u64 = index_val.toUnsignedInt();
                // @intCast here because it would have been impossible to construct a value that
                // required a larger index.
                const elem_ptr = try array_ptr_val.elemPtr(scope.arena(), @intCast(usize, index_u64));

                const type_payload = try scope.arena().create(Type.Payload.SingleConstPointer);
                type_payload.* = .{ .pointee_type = array_ptr.ty.elemType().elemType() };

                return mod.constInst(scope, inst.base.src, .{
                    .ty = Type.initPayload(&type_payload.base),
                    .val = elem_ptr,
                });
            }
        }
    }

    return mod.fail(scope, inst.base.src, "TODO implement more analyze elemptr", .{});
}

fn analyzeInstShl(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstShl", .{});
}

fn analyzeInstShr(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstShr", .{});
}

fn analyzeInstBitwise(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstBitwise", .{});
}

fn analyzeInstArrayCat(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstArrayCat", .{});
}

fn analyzeInstArrayMul(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    return mod.fail(scope, inst.base.src, "TODO implement analyzeInstArrayMul", .{});
}

fn analyzeInstArithmetic(mod: *Module, scope: *Scope, inst: *zir.Inst.BinOp) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const lhs = try resolveInst(mod, scope, inst.positionals.lhs);
    const rhs = try resolveInst(mod, scope, inst.positionals.rhs);

    const instructions = &[_]*Inst{ lhs, rhs };
    const resolved_type = try mod.resolvePeerTypes(scope, instructions);
    const casted_lhs = try mod.coerce(scope, resolved_type, lhs);
    const casted_rhs = try mod.coerce(scope, resolved_type, rhs);

    const scalar_type = if (resolved_type.zigTypeTag() == .Vector)
        resolved_type.elemType()
    else
        resolved_type;

    const scalar_tag = scalar_type.zigTypeTag();

    if (lhs.ty.zigTypeTag() == .Vector and rhs.ty.zigTypeTag() == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return mod.fail(scope, inst.base.src, "vector length mismatch: {} and {}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return mod.fail(scope, inst.base.src, "TODO implement support for vectors in analyzeInstBinOp", .{});
    } else if (lhs.ty.zigTypeTag() == .Vector or rhs.ty.zigTypeTag() == .Vector) {
        return mod.fail(scope, inst.base.src, "mixed scalar and vector operands to comparison operator: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    const is_int = scalar_tag == .Int or scalar_tag == .ComptimeInt;
    const is_float = scalar_tag == .Float or scalar_tag == .ComptimeFloat;

    if (!is_int and !(is_float and floatOpAllowed(inst.base.tag))) {
        return mod.fail(scope, inst.base.src, "invalid operands to binary expression: '{}' and '{}'", .{ @tagName(lhs.ty.zigTypeTag()), @tagName(rhs.ty.zigTypeTag()) });
    }

    if (casted_lhs.value()) |lhs_val| {
        if (casted_rhs.value()) |rhs_val| {
            return analyzeInstComptimeOp(mod, scope, scalar_type, inst, lhs_val, rhs_val);
        }
    }

    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    const ir_tag = switch (inst.base.tag) {
        .add => Inst.Tag.add,
        .sub => Inst.Tag.sub,
        else => return mod.fail(scope, inst.base.src, "TODO implement arithmetic for operand '{}''", .{@tagName(inst.base.tag)}),
    };

    return mod.addBinOp(b, inst.base.src, scalar_type, ir_tag, casted_lhs, casted_rhs);
}

/// Analyzes operands that are known at comptime
fn analyzeInstComptimeOp(mod: *Module, scope: *Scope, res_type: Type, inst: *zir.Inst.BinOp, lhs_val: Value, rhs_val: Value) InnerError!*Inst {
    // incase rhs is 0, simply return lhs without doing any calculations
    // TODO Once division is implemented we should throw an error when dividing by 0.
    if (rhs_val.compareWithZero(.eq)) {
        return mod.constInst(scope, inst.base.src, .{
            .ty = res_type,
            .val = lhs_val,
        });
    }
    const is_int = res_type.isInt() or res_type.zigTypeTag() == .ComptimeInt;

    const value = try switch (inst.base.tag) {
        .add => blk: {
            const val = if (is_int)
                Module.intAdd(scope.arena(), lhs_val, rhs_val)
            else
                mod.floatAdd(scope, res_type, inst.base.src, lhs_val, rhs_val);
            break :blk val;
        },
        .sub => blk: {
            const val = if (is_int)
                Module.intSub(scope.arena(), lhs_val, rhs_val)
            else
                mod.floatSub(scope, res_type, inst.base.src, lhs_val, rhs_val);
            break :blk val;
        },
        else => return mod.fail(scope, inst.base.src, "TODO Implement arithmetic operand '{}'", .{@tagName(inst.base.tag)}),
    };

    return mod.constInst(scope, inst.base.src, .{
        .ty = res_type,
        .val = value,
    });
}

fn analyzeInstDeref(mod: *Module, scope: *Scope, deref: *zir.Inst.UnOp) InnerError!*Inst {
    const ptr = try resolveInst(mod, scope, deref.positionals.operand);
    return mod.analyzeDeref(scope, deref.base.src, ptr, deref.positionals.operand.src);
}

fn analyzeInstAsm(mod: *Module, scope: *Scope, assembly: *zir.Inst.Asm) InnerError!*Inst {
    const return_type = try resolveType(mod, scope, assembly.positionals.return_type);
    const asm_source = try resolveConstString(mod, scope, assembly.positionals.asm_source);
    const output = if (assembly.kw_args.output) |o| try resolveConstString(mod, scope, o) else null;

    const inputs = try scope.arena().alloc([]const u8, assembly.kw_args.inputs.len);
    const clobbers = try scope.arena().alloc([]const u8, assembly.kw_args.clobbers.len);
    const args = try scope.arena().alloc(*Inst, assembly.kw_args.args.len);

    for (inputs) |*elem, i| {
        elem.* = try resolveConstString(mod, scope, assembly.kw_args.inputs[i]);
    }
    for (clobbers) |*elem, i| {
        elem.* = try resolveConstString(mod, scope, assembly.kw_args.clobbers[i]);
    }
    for (args) |*elem, i| {
        const arg = try resolveInst(mod, scope, assembly.kw_args.args[i]);
        elem.* = try mod.coerce(scope, Type.initTag(.usize), arg);
    }

    const b = try mod.requireRuntimeBlock(scope, assembly.base.src);
    const inst = try b.arena.create(Inst.Assembly);
    inst.* = .{
        .base = .{
            .tag = .assembly,
            .ty = return_type,
            .src = assembly.base.src,
        },
        .asm_source = asm_source,
        .is_volatile = assembly.kw_args.@"volatile",
        .output = output,
        .inputs = inputs,
        .clobbers = clobbers,
        .args = args,
    };
    try b.instructions.append(mod.gpa, &inst.base);
    return &inst.base;
}

fn analyzeInstCmp(
    mod: *Module,
    scope: *Scope,
    inst: *zir.Inst.BinOp,
    op: std.math.CompareOperator,
) InnerError!*Inst {
    const lhs = try resolveInst(mod, scope, inst.positionals.lhs);
    const rhs = try resolveInst(mod, scope, inst.positionals.rhs);

    const is_equality_cmp = switch (op) {
        .eq, .neq => true,
        else => false,
    };
    const lhs_ty_tag = lhs.ty.zigTypeTag();
    const rhs_ty_tag = rhs.ty.zigTypeTag();
    if (is_equality_cmp and lhs_ty_tag == .Null and rhs_ty_tag == .Null) {
        // null == null, null != null
        return mod.constBool(scope, inst.base.src, op == .eq);
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .Null and rhs_ty_tag == .Optional) or
        rhs_ty_tag == .Null and lhs_ty_tag == .Optional))
    {
        // comparing null with optionals
        const opt_operand = if (lhs_ty_tag == .Optional) lhs else rhs;
        if (opt_operand.value()) |opt_val| {
            const is_null = opt_val.isNull();
            return mod.constBool(scope, inst.base.src, if (op == .eq) is_null else !is_null);
        }
        const b = try mod.requireRuntimeBlock(scope, inst.base.src);
        const inst_tag: Inst.Tag = switch (op) {
            .eq => .isnull,
            .neq => .isnonnull,
            else => unreachable,
        };
        return mod.addUnOp(b, inst.base.src, Type.initTag(.bool), inst_tag, opt_operand);
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .Null and rhs.ty.isCPtr()) or (rhs_ty_tag == .Null and lhs.ty.isCPtr())))
    {
        return mod.fail(scope, inst.base.src, "TODO implement C pointer cmp", .{});
    } else if (lhs_ty_tag == .Null or rhs_ty_tag == .Null) {
        const non_null_type = if (lhs_ty_tag == .Null) rhs.ty else lhs.ty;
        return mod.fail(scope, inst.base.src, "comparison of '{}' with null", .{non_null_type});
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .EnumLiteral and rhs_ty_tag == .Union) or
        (rhs_ty_tag == .EnumLiteral and lhs_ty_tag == .Union)))
    {
        return mod.fail(scope, inst.base.src, "TODO implement equality comparison between a union's tag value and an enum literal", .{});
    } else if (lhs_ty_tag == .ErrorSet and rhs_ty_tag == .ErrorSet) {
        if (!is_equality_cmp) {
            return mod.fail(scope, inst.base.src, "{} operator not allowed for errors", .{@tagName(op)});
        }
        return mod.fail(scope, inst.base.src, "TODO implement equality comparison between errors", .{});
    } else if (lhs.ty.isNumeric() and rhs.ty.isNumeric()) {
        // This operation allows any combination of integer and float types, regardless of the
        // signed-ness, comptime-ness, and bit-width. So peer type resolution is incorrect for
        // numeric types.
        return mod.cmpNumeric(scope, inst.base.src, lhs, rhs, op);
    }
    return mod.fail(scope, inst.base.src, "TODO implement more cmp analysis", .{});
}

fn analyzeInstTypeOf(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    return mod.constType(scope, inst.base.src, operand.ty);
}

fn analyzeInstBoolNot(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const uncasted_operand = try resolveInst(mod, scope, inst.positionals.operand);
    const bool_type = Type.initTag(.bool);
    const operand = try mod.coerce(scope, bool_type, uncasted_operand);
    if (try mod.resolveDefinedValue(scope, operand)) |val| {
        return mod.constBool(scope, inst.base.src, !val.toBool());
    }
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    return mod.addUnOp(b, inst.base.src, bool_type, .not, operand);
}

fn analyzeInstIsNonNull(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp, invert_logic: bool) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    return mod.analyzeIsNull(scope, inst.base.src, operand, invert_logic);
}

fn analyzeInstCondBr(mod: *Module, scope: *Scope, inst: *zir.Inst.CondBr) InnerError!*Inst {
    const uncasted_cond = try resolveInst(mod, scope, inst.positionals.condition);
    const cond = try mod.coerce(scope, Type.initTag(.bool), uncasted_cond);

    if (try mod.resolveDefinedValue(scope, cond)) |cond_val| {
        const body = if (cond_val.toBool()) &inst.positionals.then_body else &inst.positionals.else_body;
        try analyzeBody(mod, scope, body.*);
        return mod.constVoid(scope, inst.base.src);
    }

    const parent_block = try mod.requireRuntimeBlock(scope, inst.base.src);

    var true_block: Scope.Block = .{
        .parent = parent_block,
        .func = parent_block.func,
        .decl = parent_block.decl,
        .instructions = .{},
        .arena = parent_block.arena,
    };
    defer true_block.instructions.deinit(mod.gpa);
    try analyzeBody(mod, &true_block.base, inst.positionals.then_body);

    var false_block: Scope.Block = .{
        .parent = parent_block,
        .func = parent_block.func,
        .decl = parent_block.decl,
        .instructions = .{},
        .arena = parent_block.arena,
    };
    defer false_block.instructions.deinit(mod.gpa);
    try analyzeBody(mod, &false_block.base, inst.positionals.else_body);

    const then_body: ir.Body = .{ .instructions = try scope.arena().dupe(*Inst, true_block.instructions.items) };
    const else_body: ir.Body = .{ .instructions = try scope.arena().dupe(*Inst, false_block.instructions.items) };
    return mod.addCondBr(parent_block, inst.base.src, cond, then_body, else_body);
}

fn analyzeInstUnreachNoChk(mod: *Module, scope: *Scope, unreach: *zir.Inst.NoOp) InnerError!*Inst {
    return mod.analyzeUnreach(scope, unreach.base.src);
}

fn analyzeInstUnreachable(mod: *Module, scope: *Scope, unreach: *zir.Inst.NoOp) InnerError!*Inst {
    const b = try mod.requireRuntimeBlock(scope, unreach.base.src);
    // TODO Add compile error for @optimizeFor occurring too late in a scope.
    if (mod.wantSafety(scope)) {
        // TODO Once we have a panic function to call, call it here instead of this.
        _ = try mod.addNoOp(b, unreach.base.src, Type.initTag(.void), .breakpoint);
    }
    return mod.analyzeUnreach(scope, unreach.base.src);
}

fn analyzeInstRet(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const operand = try resolveInst(mod, scope, inst.positionals.operand);
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    return mod.addUnOp(b, inst.base.src, Type.initTag(.noreturn), .ret, operand);
}

fn analyzeInstRetVoid(mod: *Module, scope: *Scope, inst: *zir.Inst.NoOp) InnerError!*Inst {
    const b = try mod.requireRuntimeBlock(scope, inst.base.src);
    return mod.addNoOp(b, inst.base.src, Type.initTag(.noreturn), .retvoid);
}

fn floatOpAllowed(tag: zir.Inst.Tag) bool {
    // extend this swich as additional operators are implemented
    return switch (tag) {
        .add, .sub => true,
        else => false,
    };
}

fn analyzeBreak(
    mod: *Module,
    scope: *Scope,
    src: usize,
    zir_block: *zir.Inst.Block,
    operand: *Inst,
) InnerError!*Inst {
    var opt_block = scope.cast(Scope.Block);
    while (opt_block) |block| {
        if (block.label) |*label| {
            if (label.zir_block == zir_block) {
                try label.results.append(mod.gpa, operand);
                const b = try mod.requireRuntimeBlock(scope, src);
                return mod.addBr(b, src, label.block_inst, operand);
            }
        }
        opt_block = block.parent;
    } else unreachable;
}

fn analyzeDeclVal(mod: *Module, scope: *Scope, inst: *zir.Inst.DeclVal) InnerError!*Decl {
    const decl_name = inst.positionals.name;
    const zir_module = scope.namespace().cast(Scope.ZIRModule).?;
    const src_decl = zir_module.contents.module.findDecl(decl_name) orelse
        return mod.fail(scope, inst.base.src, "use of undeclared identifier '{}'", .{decl_name});

    const decl = try resolveCompleteZirDecl(mod, scope, src_decl.decl);

    return decl;
}

fn analyzeInstSingleConstPtrType(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const elem_type = try resolveType(mod, scope, inst.positionals.operand);
    const ty = try mod.singleConstPtrType(scope, inst.base.src, elem_type);
    return mod.constType(scope, inst.base.src, ty);
}

fn analyzeInstSingleMutPtrType(mod: *Module, scope: *Scope, inst: *zir.Inst.UnOp) InnerError!*Inst {
    const elem_type = try resolveType(mod, scope, inst.positionals.operand);
    const ty = try mod.singleMutPtrType(scope, inst.base.src, elem_type);
    return mod.constType(scope, inst.base.src, ty);
}
