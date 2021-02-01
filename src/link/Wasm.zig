const Wasm = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fs = std.fs;
const leb = std.leb;
const log = std.log.scoped(.link);
const wasm = std.wasm;

const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const codegen = @import("../codegen/wasm.zig");
const link = @import("../link.zig");
const trace = @import("../tracy.zig").trace;
const build_options = @import("build_options");
const Cache = @import("../Cache.zig");

pub const base_tag = link.File.Tag.wasm;

pub const FnData = struct {
    /// Generated code for the type of the function
    functype: std.ArrayListUnmanaged(u8) = .{},
    /// Generated code for the body of the function
    code: std.ArrayListUnmanaged(u8) = .{},
    /// Locations in the generated code where function indexes must be filled in.
    /// This must be kept ordered by offset.
    idx_refs: std.ArrayListUnmanaged(struct { offset: u32, decl: *Module.Decl }) = .{},
};

base: link.File,

/// List of all function Decls to be written to the output file. The index of
/// each Decl in this list at the time of writing the binary is used as the
/// function index.
/// TODO: can/should we access some data structure in Module directly?
funcs: std.ArrayListUnmanaged(*Module.Decl) = .{},

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*Wasm {
    assert(options.object_format == .wasm);

    if (options.use_llvm) return error.LLVM_BackendIsTODO_ForWasm; // TODO
    if (options.use_lld) return error.LLD_LinkingIsTODO_ForWasm; // TODO

    // TODO: read the file and keep vaild parts instead of truncating
    const file = try options.emit.?.directory.handle.createFile(sub_path, .{ .truncate = true, .read = true });
    errdefer file.close();

    const wasm_bin = try createEmpty(allocator, options);
    errdefer wasm_bin.base.destroy();

    wasm_bin.base.file = file;

    try file.writeAll(&(wasm.magic ++ wasm.version));

    return wasm_bin;
}

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*Wasm {
    const wasm_bin = try gpa.create(Wasm);
    wasm_bin.* = .{
        .base = .{
            .tag = .wasm,
            .options = options,
            .file = null,
            .allocator = gpa,
        },
    };
    return wasm_bin;
}

pub fn deinit(self: *Wasm) void {
    for (self.funcs.items) |decl| {
        decl.fn_link.wasm.?.functype.deinit(self.base.allocator);
        decl.fn_link.wasm.?.code.deinit(self.base.allocator);
        decl.fn_link.wasm.?.idx_refs.deinit(self.base.allocator);
    }
    self.funcs.deinit(self.base.allocator);
}

// Generate code for the Decl, storing it in memory to be later written to
// the file on flush().
pub fn updateDecl(self: *Wasm, module: *Module, decl: *Module.Decl) !void {
    const typed_value = decl.typed_value.most_recent.typed_value;
    if (typed_value.ty.zigTypeTag() != .Fn)
        return error.TODOImplementNonFnDeclsForWasm;
    if (typed_value.val.tag() == .extern_fn)
        return error.TODOImplementExternFnDeclsForWasm;

    if (decl.fn_link.wasm) |*fn_data| {
        fn_data.functype.items.len = 0;
        fn_data.code.items.len = 0;
        fn_data.idx_refs.items.len = 0;
    } else {
        decl.fn_link.wasm = .{};
        try self.funcs.append(self.base.allocator, decl);
    }
    const fn_data = &decl.fn_link.wasm.?;

    var managed_functype = fn_data.functype.toManaged(self.base.allocator);
    var managed_code = fn_data.code.toManaged(self.base.allocator);

    var context = codegen.Context{
        .gpa = self.base.allocator,
        .values = .{},
        .code = managed_code,
        .func_type_data = managed_functype,
        .decl = decl,
        .err_msg = undefined,
        .locals = .{},
    };
    defer context.deinit();

    // generate the 'code' section for the function declaration
    context.gen() catch |err| switch (err) {
        error.CodegenFail => {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, context.err_msg);
            return;
        },
        else => |e| return err,
    };

    // as locals are patched afterwards, the offsets of funcidx's are off,
    // here we update them to correct them
    for (decl.fn_link.wasm.?.idx_refs.items) |*func| {
        // For each local, add 6 bytes (count + type)
        func.offset += @intCast(u32, context.locals.items.len * 6);
    }

    fn_data.functype = context.func_type_data.toUnmanaged();
    fn_data.code = context.code.toUnmanaged();
}

pub fn updateDeclExports(
    self: *Wasm,
    module: *Module,
    decl: *const Module.Decl,
    exports: []const *Module.Export,
) !void {}

pub fn freeDecl(self: *Wasm, decl: *Module.Decl) void {
    // TODO: remove this assert when non-function Decls are implemented
    assert(decl.typed_value.most_recent.typed_value.ty.zigTypeTag() == .Fn);
    _ = self.funcs.swapRemove(self.getFuncidx(decl).?);
    decl.fn_link.wasm.?.functype.deinit(self.base.allocator);
    decl.fn_link.wasm.?.code.deinit(self.base.allocator);
    decl.fn_link.wasm.?.idx_refs.deinit(self.base.allocator);
    decl.fn_link.wasm = null;
}

pub fn flush(self: *Wasm, comp: *Compilation) !void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return self.linkWithLLD(comp);
    } else {
        return self.flushModule(comp);
    }
}

pub fn flushModule(self: *Wasm, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const file = self.base.file.?;
    const header_size = 5 + 1;

    // No need to rewrite the magic/version header
    try file.setEndPos(@sizeOf(@TypeOf(wasm.magic ++ wasm.version)));
    try file.seekTo(@sizeOf(@TypeOf(wasm.magic ++ wasm.version)));

    // Type section
    {
        const header_offset = try reserveVecSectionHeader(file);
        for (self.funcs.items) |decl| {
            try file.writeAll(decl.fn_link.wasm.?.functype.items);
        }
        try writeVecSectionHeader(
            file,
            header_offset,
            .type,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.funcs.items.len),
        );
    }

    // Function section
    {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        for (self.funcs.items) |_, typeidx| try leb.writeULEB128(writer, @intCast(u32, typeidx));
        try writeVecSectionHeader(
            file,
            header_offset,
            .function,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.funcs.items.len),
        );
    }

    // Export section
    if (self.base.options.module) |module| {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        var count: u32 = 0;
        for (module.decl_exports.entries.items) |entry| {
            for (entry.value) |exprt| {
                // Export name length + name
                try leb.writeULEB128(writer, @intCast(u32, exprt.options.name.len));
                try writer.writeAll(exprt.options.name);

                switch (exprt.exported_decl.typed_value.most_recent.typed_value.ty.zigTypeTag()) {
                    .Fn => {
                        // Type of the export
                        try writer.writeByte(0x00);
                        // Exported function index
                        try leb.writeULEB128(writer, self.getFuncidx(exprt.exported_decl).?);
                    },
                    else => return error.TODOImplementNonFnDeclsForWasm,
                }

                count += 1;
            }
        }
        try writeVecSectionHeader(
            file,
            header_offset,
            .@"export",
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            count,
        );
    }

    // Code section
    {
        const header_offset = try reserveVecSectionHeader(file);
        const writer = file.writer();
        for (self.funcs.items) |decl| {
            const fn_data = &decl.fn_link.wasm.?;

            // Write the already generated code to the file, inserting
            // function indexes where required.
            var current: u32 = 0;
            for (fn_data.idx_refs.items) |idx_ref| {
                try writer.writeAll(fn_data.code.items[current..idx_ref.offset]);
                current = idx_ref.offset;
                // Use a fixed width here to make calculating the code size
                // in codegen.wasm.gen() simpler.
                var buf: [5]u8 = undefined;
                leb.writeUnsignedFixed(5, &buf, self.getFuncidx(idx_ref.decl).?);
                try writer.writeAll(&buf);
            }

            try writer.writeAll(fn_data.code.items[current..]);
        }
        try writeVecSectionHeader(
            file,
            header_offset,
            .code,
            @intCast(u32, (try file.getPos()) - header_offset - header_size),
            @intCast(u32, self.funcs.items.len),
        );
    }
}

fn linkWithLLD(self: *Wasm, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(self.base.allocator);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const directory = self.base.options.emit.?.directory; // Just an alias to make it shorter to type.

    // If there is no Zig code to compile, then we should skip flushing the output file because it
    // will not be part of the linker line anyway.
    const module_obj_path: ?[]const u8 = if (self.base.options.module) |module| blk: {
        const use_stage1 = build_options.is_stage1 and self.base.options.use_llvm;
        if (use_stage1) {
            const obj_basename = try std.zig.binNameAlloc(arena, .{
                .root_name = self.base.options.root_name,
                .target = self.base.options.target,
                .output_mode = .Obj,
            });
            const o_directory = self.base.options.module.?.zig_cache_artifact_directory;
            const full_obj_path = try o_directory.join(arena, &[_][]const u8{obj_basename});
            break :blk full_obj_path;
        }

        try self.flushModule(comp);
        const obj_basename = self.base.intermediary_basename.?;
        const full_obj_path = try directory.join(arena, &[_][]const u8{obj_basename});
        break :blk full_obj_path;
    } else null;

    const compiler_rt_path: ?[]const u8 = if (self.base.options.include_compiler_rt)
        comp.compiler_rt_static_lib.?.full_object_path
    else
        null;

    const target = self.base.options.target;

    const id_symlink_basename = "lld.id";

    var man: Cache.Manifest = undefined;
    defer if (!self.base.options.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!self.base.options.disable_lld_caching) {
        man = comp.cache_parent.obtain();

        // We are about to obtain this lock, so here we give other processes a chance first.
        self.base.releaseLock();

        try man.addListOfFiles(self.base.options.objects);
        for (comp.c_object_table.items()) |entry| {
            _ = try man.addFile(entry.key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        try man.addOptionalFile(compiler_rt_path);
        man.hash.addOptional(self.base.options.stack_size_override);
        man.hash.addListOfBytes(self.base.options.extra_lld_args);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("WASM LLD new_digest={} error: {s}", .{ digest, @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("WASM LLD digest={} match - skipping invocation", .{digest});
            // Hot diggity dog! The output binary is already there.
            self.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("WASM LLD prev_digest={} new_digest={}", .{ prev_digest, digest });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const full_out_path = try directory.join(arena, &[_][]const u8{self.base.options.emit.?.sub_path});

    if (self.base.options.output_mode == .Obj) {
        // LLD's WASM driver does not support the equvialent of `-r` so we do a simple file copy
        // here. TODO: think carefully about how we can avoid this redundant operation when doing
        // build-obj. See also the corresponding TODO in linkAsArchive.
        const the_object_path = blk: {
            if (self.base.options.objects.len != 0)
                break :blk self.base.options.objects[0];

            if (comp.c_object_table.count() != 0)
                break :blk comp.c_object_table.items()[0].key.status.success.object_path;

            if (module_obj_path) |p|
                break :blk p;

            // TODO I think this is unreachable. Audit this situation when solving the above TODO
            // regarding eliding redundant object -> object transformations.
            return error.NoObjectsToLink;
        };
        // This can happen when using --enable-cache and using the stage1 backend. In this case
        // we can skip the file copy.
        if (!mem.eql(u8, the_object_path, full_out_path)) {
            try fs.cwd().copyFile(the_object_path, fs.cwd(), full_out_path, .{});
        }
    } else {
        const is_obj = self.base.options.output_mode == .Obj;

        // Create an LLD command line and invoke it.
        var argv = std.ArrayList([]const u8).init(self.base.allocator);
        defer argv.deinit();
        // We will invoke ourselves as a child process to gain access to LLD.
        // This is necessary because LLD does not behave properly as a library -
        // it calls exit() and does not reset all global data between invocations.
        try argv.appendSlice(&[_][]const u8{ comp.self_exe_path.?, "wasm-ld" });
        if (is_obj) {
            try argv.append("-r");
        }

        try argv.append("-error-limit=0");

        if (self.base.options.lto) {
            switch (self.base.options.optimize_mode) {
                .Debug => {},
                .ReleaseSmall => try argv.append("-O2"),
                .ReleaseFast, .ReleaseSafe => try argv.append("-O3"),
            }
        }

        if (self.base.options.output_mode == .Exe) {
            // Increase the default stack size to a more reasonable value of 1MB instead of
            // the default of 1 Wasm page being 64KB, unless overriden by the user.
            try argv.append("-z");
            const stack_size = self.base.options.stack_size_override orelse 1048576;
            const arg = try std.fmt.allocPrint(arena, "stack-size={d}", .{stack_size});
            try argv.append(arg);

            // Put stack before globals so that stack overflow results in segfault immediately
            // before corrupting globals. See https://github.com/ziglang/zig/issues/4496
            try argv.append("--stack-first");
        } else {
            try argv.append("--no-entry"); // So lld doesn't look for _start.
            try argv.append("--export-all");
        }
        try argv.appendSlice(&[_][]const u8{
            "--allow-undefined",
            "-o",
            full_out_path,
        });

        // Positional arguments to the linker such as object files.
        try argv.appendSlice(self.base.options.objects);

        for (comp.c_object_table.items()) |entry| {
            try argv.append(entry.key.status.success.object_path);
        }
        if (module_obj_path) |p| {
            try argv.append(p);
        }

        if (self.base.options.output_mode != .Obj and
            !self.base.options.skip_linker_dependencies and
            !self.base.options.link_libc)
        {
            try argv.append(comp.libc_static_lib.?.full_object_path);
        }

        if (compiler_rt_path) |p| {
            try argv.append(p);
        }

        if (self.base.options.verbose_link) {
            // Skip over our own name so that the LLD linker name is the first argv item.
            Compilation.dump_argv(argv.items[1..]);
        }

        // Sadly, we must run LLD as a child process because it does not behave
        // properly as a library.
        const child = try std.ChildProcess.init(argv.items, arena);
        defer child.deinit();

        if (comp.clang_passthrough_mode) {
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = child.spawnAndWait() catch |err| {
                log.err("unable to spawn {s}: {s}", .{ argv.items[0], @errorName(err) });
                return error.UnableToSpawnSelf;
            };
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        // TODO https://github.com/ziglang/zig/issues/6342
                        std.process.exit(1);
                    }
                },
                else => std.process.abort(),
            }
        } else {
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Pipe;

            try child.spawn();

            const stderr = try child.stderr.?.reader().readAllAlloc(arena, 10 * 1024 * 1024);

            const term = child.wait() catch |err| {
                log.err("unable to spawn {s}: {s}", .{ argv.items[0], @errorName(err) });
                return error.UnableToSpawnSelf;
            };

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        // TODO parse this output and surface with the Compilation API rather than
                        // directly outputting to stderr here.
                        std.debug.print("{s}", .{stderr});
                        return error.LLDReportedFailure;
                    }
                },
                else => {
                    log.err("{s} terminated with stderr:\n{s}", .{ argv.items[0], stderr });
                    return error.LLDCrashed;
                },
            }

            if (stderr.len != 0) {
                log.warn("unexpected LLD stderr:\n{s}", .{stderr});
            }
        }
    }

    if (!self.base.options.disable_lld_caching) {
        // Update the file with the digest. If it fails we can continue; it only
        // means that the next invocation will have an unnecessary cache miss.
        Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
            log.warn("failed to save linking hash digest symlink: {s}", .{@errorName(err)});
        };
        // Again failure here only means an unnecessary cache miss.
        man.writeManifest() catch |err| {
            log.warn("failed to write cache manifest when linking: {s}", .{@errorName(err)});
        };
        // We hang on to this lock so that the output file path can be used without
        // other processes clobbering it.
        self.base.lock = man.toOwnedLock();
    }
}

/// Get the current index of a given Decl in the function list
/// TODO: we could maintain a hash map to potentially make this
fn getFuncidx(self: Wasm, decl: *Module.Decl) ?u32 {
    return for (self.funcs.items) |func, idx| {
        if (func == decl) break @intCast(u32, idx);
    } else null;
}

fn reserveVecSectionHeader(file: fs.File) !u64 {
    // section id + fixed leb contents size + fixed leb vector length
    const header_size = 1 + 5 + 5;
    // TODO: this should be a single lseek(2) call, but fs.File does not
    // currently provide a way to do this.
    try file.seekBy(header_size);
    return (try file.getPos()) - header_size;
}

fn writeVecSectionHeader(file: fs.File, offset: u64, section: wasm.Section, size: u32, items: u32) !void {
    var buf: [1 + 5 + 5]u8 = undefined;
    buf[0] = @enumToInt(section);
    leb.writeUnsignedFixed(5, buf[1..6], size);
    leb.writeUnsignedFixed(5, buf[6..], items);
    try file.pwriteAll(&buf, offset);
}
