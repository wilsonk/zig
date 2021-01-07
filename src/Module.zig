const Module = @This();
const std = @import("std");
const Compilation = @import("Compilation.zig");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.module);
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Target = std.Target;
const Package = @import("Package.zig");
const link = @import("link.zig");
const ir = @import("ir.zig");
const zir = @import("zir.zig");
const Inst = ir.Inst;
const Body = ir.Body;
const ast = std.zig.ast;
const trace = @import("tracy.zig").trace;
const astgen = @import("astgen.zig");
const zir_sema = @import("zir_sema.zig");

const default_eval_branch_quota = 1000;

/// General-purpose allocator. Used for both temporary and long-term storage.
gpa: *Allocator,
comp: *Compilation,

/// Where our incremental compilation metadata serialization will go.
zig_cache_artifact_directory: Compilation.Directory,
/// Pointer to externally managed resource. `null` if there is no zig file being compiled.
root_pkg: *Package,
/// Module owns this resource.
/// The `Scope` is either a `Scope.ZIRModule` or `Scope.File`.
root_scope: *Scope,
/// It's rare for a decl to be exported, so we save memory by having a sparse map of
/// Decl pointers to details about them being exported.
/// The Export memory is owned by the `export_owners` table; the slice itself is owned by this table.
/// The slice is guaranteed to not be empty.
decl_exports: std.AutoArrayHashMapUnmanaged(*Decl, []*Export) = .{},
/// We track which export is associated with the given symbol name for quick
/// detection of symbol collisions.
symbol_exports: std.StringArrayHashMapUnmanaged(*Export) = .{},
/// This models the Decls that perform exports, so that `decl_exports` can be updated when a Decl
/// is modified. Note that the key of this table is not the Decl being exported, but the Decl that
/// is performing the export of another Decl.
/// This table owns the Export memory.
export_owners: std.AutoArrayHashMapUnmanaged(*Decl, []*Export) = .{},
/// Maps fully qualified namespaced names to the Decl struct for them.
decl_table: std.ArrayHashMapUnmanaged(Scope.NameHash, *Decl, Scope.name_hash_hash, Scope.name_hash_eql, false) = .{},
/// We optimize memory usage for a compilation with no compile errors by storing the
/// error messages and mapping outside of `Decl`.
/// The ErrorMsg memory is owned by the decl, using Module's general purpose allocator.
/// Note that a Decl can succeed but the Fn it represents can fail. In this case,
/// a Decl can have a failed_decls entry but have analysis status of success.
failed_decls: std.AutoArrayHashMapUnmanaged(*Decl, *Compilation.ErrorMsg) = .{},
/// When emit_h is non-null, each Decl gets one more compile error slot for
/// emit-h failing for that Decl. This table is also how we tell if a Decl has
/// failed emit-h or succeeded.
emit_h_failed_decls: std.AutoArrayHashMapUnmanaged(*Decl, *Compilation.ErrorMsg) = .{},
/// A Decl can have multiple compileLogs, but only one error, so we map a Decl to a the src locs of all the compileLogs
compile_log_decls: std.AutoArrayHashMapUnmanaged(*Decl, ArrayListUnmanaged(usize)) = .{},
/// Using a map here for consistency with the other fields here.
/// The ErrorMsg memory is owned by the `Scope`, using Module's general purpose allocator.
failed_files: std.AutoArrayHashMapUnmanaged(*Scope, *Compilation.ErrorMsg) = .{},
/// Using a map here for consistency with the other fields here.
/// The ErrorMsg memory is owned by the `Export`, using Module's general purpose allocator.
failed_exports: std.AutoArrayHashMapUnmanaged(*Export, *Compilation.ErrorMsg) = .{},

next_anon_name_index: usize = 0,

/// Candidates for deletion. After a semantic analysis update completes, this list
/// contains Decls that need to be deleted if they end up having no references to them.
deletion_set: ArrayListUnmanaged(*Decl) = .{},

/// Error tags and their values, tag names are duped with mod.gpa.
global_error_set: std.StringHashMapUnmanaged(u16) = .{},

/// Keys are fully qualified paths
import_table: std.StringArrayHashMapUnmanaged(*Scope.File) = .{},

/// Incrementing integer used to compare against the corresponding Decl
/// field to determine whether a Decl's status applies to an ongoing update, or a
/// previous analysis.
generation: u32 = 0,

/// When populated it means there was an error opening/reading the root source file.
failed_root_src_file: ?anyerror = null,

stage1_flags: packed struct {
    have_winmain: bool = false,
    have_wwinmain: bool = false,
    have_winmain_crt_startup: bool = false,
    have_wwinmain_crt_startup: bool = false,
    have_dllmain_crt_startup: bool = false,
    have_c_main: bool = false,
    reserved: u2 = 0,
} = .{},

emit_h: ?Compilation.EmitLoc,

pub const Export = struct {
    options: std.builtin.ExportOptions,
    /// Byte offset into the file that contains the export directive.
    src: usize,
    /// Represents the position of the export, if any, in the output file.
    link: link.File.Export,
    /// The Decl that performs the export. Note that this is *not* the Decl being exported.
    owner_decl: *Decl,
    /// The Decl being exported. Note this is *not* the Decl performing the export.
    exported_decl: *Decl,
    status: enum {
        in_progress,
        failed,
        /// Indicates that the failure was due to a temporary issue, such as an I/O error
        /// when writing to the output file. Retrying the export may succeed.
        failed_retryable,
        complete,
    },
};

/// When Module emit_h field is non-null, each Decl is allocated via this struct, so that
/// there can be EmitH state attached to each Decl.
pub const DeclPlusEmitH = struct {
    decl: Decl,
    emit_h: EmitH,
};

pub const Decl = struct {
    /// This name is relative to the containing namespace of the decl. It uses a null-termination
    /// to save bytes, since there can be a lot of decls in a compilation. The null byte is not allowed
    /// in symbol names, because executable file formats use null-terminated strings for symbol names.
    /// All Decls have names, even values that are not bound to a zig namespace. This is necessary for
    /// mapping them to an address in the output file.
    /// Memory owned by this decl, using Module's allocator.
    name: [*:0]const u8,
    /// The direct parent container of the Decl. This is either a `Scope.Container` or `Scope.ZIRModule`.
    /// Reference to externally owned memory.
    scope: *Scope,
    /// The AST Node decl index or ZIR Inst index that contains this declaration.
    /// Must be recomputed when the corresponding source file is modified.
    src_index: usize,
    /// The most recent value of the Decl after a successful semantic analysis.
    typed_value: union(enum) {
        never_succeeded: void,
        most_recent: TypedValue.Managed,
    },
    /// Represents the "shallow" analysis status. For example, for decls that are functions,
    /// the function type is analyzed with this set to `in_progress`, however, the semantic
    /// analysis of the function body is performed with this value set to `success`. Functions
    /// have their own analysis status field.
    analysis: enum {
        /// This Decl corresponds to an AST Node that has not been referenced yet, and therefore
        /// because of Zig's lazy declaration analysis, it will remain unanalyzed until referenced.
        unreferenced,
        /// Semantic analysis for this Decl is running right now. This state detects dependency loops.
        in_progress,
        /// This Decl might be OK but it depends on another one which did not successfully complete
        /// semantic analysis.
        dependency_failure,
        /// Semantic analysis failure.
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        sema_failure,
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        /// This indicates the failure was something like running out of disk space,
        /// and attempting semantic analysis again may succeed.
        sema_failure_retryable,
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        codegen_failure,
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        /// This indicates the failure was something like running out of disk space,
        /// and attempting codegen again may succeed.
        codegen_failure_retryable,
        /// Everything is done. During an update, this Decl may be out of date, depending
        /// on its dependencies. The `generation` field can be used to determine if this
        /// completion status occurred before or after a given update.
        complete,
        /// A Module update is in progress, and this Decl has been flagged as being known
        /// to require re-analysis.
        outdated,
    },
    /// This flag is set when this Decl is added to a check_for_deletion set, and cleared
    /// when removed.
    deletion_flag: bool,
    /// Whether the corresponding AST decl has a `pub` keyword.
    is_pub: bool,

    /// An integer that can be checked against the corresponding incrementing
    /// generation field of Module. This is used to determine whether `complete` status
    /// represents pre- or post- re-analysis.
    generation: u32,

    /// Represents the position of the code in the output file.
    /// This is populated regardless of semantic analysis and code generation.
    link: link.File.LinkBlock,

    /// Represents the function in the linked output file, if the `Decl` is a function.
    /// This is stored here and not in `Fn` because `Decl` survives across updates but
    /// `Fn` does not.
    /// TODO Look into making `Fn` a longer lived structure and moving this field there
    /// to save on memory usage.
    fn_link: link.File.LinkFn,

    contents_hash: std.zig.SrcHash,

    /// The shallow set of other decls whose typed_value could possibly change if this Decl's
    /// typed_value is modified.
    dependants: DepsTable = .{},
    /// The shallow set of other decls whose typed_value changing indicates that this Decl's
    /// typed_value may need to be regenerated.
    dependencies: DepsTable = .{},

    /// The reason this is not `std.AutoArrayHashMapUnmanaged` is a workaround for
    /// stage1 compiler giving me: `error: struct 'Module.Decl' depends on itself`
    pub const DepsTable = std.ArrayHashMapUnmanaged(*Decl, void, std.array_hash_map.getAutoHashFn(*Decl), std.array_hash_map.getAutoEqlFn(*Decl), false);

    pub fn destroy(self: *Decl, module: *Module) void {
        const gpa = module.gpa;
        gpa.free(mem.spanZ(self.name));
        if (self.typedValueManaged()) |tvm| {
            tvm.deinit(gpa);
        }
        self.dependants.deinit(gpa);
        self.dependencies.deinit(gpa);
        if (module.emit_h != null) {
            const decl_plus_emit_h = @fieldParentPtr(DeclPlusEmitH, "decl", self);
            decl_plus_emit_h.emit_h.fwd_decl.deinit(gpa);
            gpa.destroy(decl_plus_emit_h);
        } else {
            gpa.destroy(self);
        }
    }

    pub fn src(self: Decl) usize {
        switch (self.scope.tag) {
            .container => {
                const container = @fieldParentPtr(Scope.Container, "base", self.scope);
                const tree = container.file_scope.contents.tree;
                // TODO Container should have its own decls()
                const decl_node = tree.root_node.decls()[self.src_index];
                return tree.token_locs[decl_node.firstToken()].start;
            },
            .zir_module => {
                const zir_module = @fieldParentPtr(Scope.ZIRModule, "base", self.scope);
                const module = zir_module.contents.module;
                const src_decl = module.decls[self.src_index];
                return src_decl.inst.src;
            },
            .file, .block => unreachable,
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .decl => unreachable,
        }
    }

    pub fn fullyQualifiedNameHash(self: Decl) Scope.NameHash {
        return self.scope.fullyQualifiedNameHash(mem.spanZ(self.name));
    }

    pub fn typedValue(self: *Decl) error{AnalysisFail}!TypedValue {
        const tvm = self.typedValueManaged() orelse return error.AnalysisFail;
        return tvm.typed_value;
    }

    pub fn value(self: *Decl) error{AnalysisFail}!Value {
        return (try self.typedValue()).val;
    }

    pub fn dump(self: *Decl) void {
        const loc = std.zig.findLineColumn(self.scope.source.bytes, self.src);
        std.debug.print("{s}:{d}:{d} name={s} status={s}", .{
            self.scope.sub_file_path,
            loc.line + 1,
            loc.column + 1,
            mem.spanZ(self.name),
            @tagName(self.analysis),
        });
        if (self.typedValueManaged()) |tvm| {
            std.debug.print(" ty={} val={}", .{ tvm.typed_value.ty, tvm.typed_value.val });
        }
        std.debug.print("\n", .{});
    }

    pub fn typedValueManaged(self: *Decl) ?*TypedValue.Managed {
        switch (self.typed_value) {
            .most_recent => |*x| return x,
            .never_succeeded => return null,
        }
    }

    /// Asserts that the `Decl` is part of AST and not ZIRModule.
    pub fn getFileScope(self: *Decl) *Scope.File {
        return self.scope.cast(Scope.Container).?.file_scope;
    }

    pub fn getEmitH(decl: *Decl, module: *Module) *EmitH {
        assert(module.emit_h != null);
        const decl_plus_emit_h = @fieldParentPtr(DeclPlusEmitH, "decl", decl);
        return &decl_plus_emit_h.emit_h;
    }

    fn removeDependant(self: *Decl, other: *Decl) void {
        self.dependants.removeAssertDiscard(other);
    }

    fn removeDependency(self: *Decl, other: *Decl) void {
        self.dependencies.removeAssertDiscard(other);
    }
};

/// This state is attached to every Decl when Module emit_h is non-null.
pub const EmitH = struct {
    fwd_decl: std.ArrayListUnmanaged(u8) = .{},
};

/// Fn struct memory is owned by the Decl's TypedValue.Managed arena allocator.
/// Extern functions do not have this data structure; they are represented by
/// the `Decl` only, with a `Value` tag of `extern_fn`.
pub const Fn = struct {
    owner_decl: *Decl,
    /// Contains un-analyzed ZIR instructions generated from Zig source AST.
    /// Even after we finish analysis, the ZIR is kept in memory, so that
    /// comptime and inline function calls can happen.
    zir: zir.Module.Body,
    /// undefined unless analysis state is `success`.
    body: Body,
    state: Analysis,

    pub const Analysis = enum {
        queued,
        /// This function intentionally only has ZIR generated because it is marked
        /// inline, which means no runtime version of the function will be generated.
        inline_only,
        in_progress,
        /// There will be a corresponding ErrorMsg in Module.failed_decls
        sema_failure,
        /// This Fn might be OK but it depends on another Decl which did not
        /// successfully complete semantic analysis.
        dependency_failure,
        success,
    };

    /// For debugging purposes.
    pub fn dump(self: *Fn, mod: Module) void {
        zir.dumpFn(mod, self);
    }
};

pub const Var = struct {
    /// if is_extern == true this is undefined
    init: Value,
    owner_decl: *Decl,

    is_extern: bool,
    is_mutable: bool,
    is_threadlocal: bool,
};

pub const Scope = struct {
    tag: Tag,

    pub const NameHash = [16]u8;

    pub fn cast(base: *Scope, comptime T: type) ?*T {
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    /// Asserts the scope has a parent which is a DeclAnalysis and
    /// returns the arena Allocator.
    pub fn arena(self: *Scope) *Allocator {
        switch (self.tag) {
            .block => return self.cast(Block).?.arena,
            .decl => return &self.cast(DeclAnalysis).?.arena.allocator,
            .gen_zir => return self.cast(GenZIR).?.arena,
            .local_val => return self.cast(LocalVal).?.gen_zir.arena,
            .local_ptr => return self.cast(LocalPtr).?.gen_zir.arena,
            .zir_module => return &self.cast(ZIRModule).?.contents.module.arena.allocator,
            .file => unreachable,
            .container => unreachable,
        }
    }

    /// If the scope has a parent which is a `DeclAnalysis`,
    /// returns the `Decl`, otherwise returns `null`.
    pub fn decl(self: *Scope) ?*Decl {
        return switch (self.tag) {
            .block => self.cast(Block).?.decl,
            .gen_zir => self.cast(GenZIR).?.decl,
            .local_val => self.cast(LocalVal).?.gen_zir.decl,
            .local_ptr => self.cast(LocalPtr).?.gen_zir.decl,
            .decl => self.cast(DeclAnalysis).?.decl,
            .zir_module => null,
            .file => null,
            .container => null,
        };
    }

    /// Asserts the scope has a parent which is a ZIRModule or Container and
    /// returns it.
    pub fn namespace(self: *Scope) *Scope {
        switch (self.tag) {
            .block => return self.cast(Block).?.decl.scope,
            .gen_zir => return self.cast(GenZIR).?.decl.scope,
            .local_val => return self.cast(LocalVal).?.gen_zir.decl.scope,
            .local_ptr => return self.cast(LocalPtr).?.gen_zir.decl.scope,
            .decl => return self.cast(DeclAnalysis).?.decl.scope,
            .file => return &self.cast(File).?.root_container.base,
            .zir_module, .container => return self,
        }
    }

    /// Must generate unique bytes with no collisions with other decls.
    /// The point of hashing here is only to limit the number of bytes of
    /// the unique identifier to a fixed size (16 bytes).
    pub fn fullyQualifiedNameHash(self: *Scope, name: []const u8) NameHash {
        switch (self.tag) {
            .block => unreachable,
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .decl => unreachable,
            .file => unreachable,
            .zir_module => return self.cast(ZIRModule).?.fullyQualifiedNameHash(name),
            .container => return self.cast(Container).?.fullyQualifiedNameHash(name),
        }
    }

    /// Asserts the scope is a child of a File and has an AST tree and returns the tree.
    pub fn tree(self: *Scope) *ast.Tree {
        switch (self.tag) {
            .file => return self.cast(File).?.contents.tree,
            .zir_module => unreachable,
            .decl => return self.cast(DeclAnalysis).?.decl.scope.cast(Container).?.file_scope.contents.tree,
            .block => return self.cast(Block).?.decl.scope.cast(Container).?.file_scope.contents.tree,
            .gen_zir => return self.cast(GenZIR).?.decl.scope.cast(Container).?.file_scope.contents.tree,
            .local_val => return self.cast(LocalVal).?.gen_zir.decl.scope.cast(Container).?.file_scope.contents.tree,
            .local_ptr => return self.cast(LocalPtr).?.gen_zir.decl.scope.cast(Container).?.file_scope.contents.tree,
            .container => return self.cast(Container).?.file_scope.contents.tree,
        }
    }

    /// Asserts the scope is a child of a `GenZIR` and returns it.
    pub fn getGenZIR(self: *Scope) *GenZIR {
        return switch (self.tag) {
            .block => unreachable,
            .gen_zir => self.cast(GenZIR).?,
            .local_val => return self.cast(LocalVal).?.gen_zir,
            .local_ptr => return self.cast(LocalPtr).?.gen_zir,
            .decl => unreachable,
            .zir_module => unreachable,
            .file => unreachable,
            .container => unreachable,
        };
    }

    /// Asserts the scope has a parent which is a ZIRModule, Contaienr or File and
    /// returns the sub_file_path field.
    pub fn subFilePath(base: *Scope) []const u8 {
        switch (base.tag) {
            .container => return @fieldParentPtr(Container, "base", base).file_scope.sub_file_path,
            .file => return @fieldParentPtr(File, "base", base).sub_file_path,
            .zir_module => return @fieldParentPtr(ZIRModule, "base", base).sub_file_path,
            .block => unreachable,
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .decl => unreachable,
        }
    }

    pub fn unload(base: *Scope, gpa: *Allocator) void {
        switch (base.tag) {
            .file => return @fieldParentPtr(File, "base", base).unload(gpa),
            .zir_module => return @fieldParentPtr(ZIRModule, "base", base).unload(gpa),
            .block => unreachable,
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .decl => unreachable,
            .container => unreachable,
        }
    }

    pub fn getSource(base: *Scope, module: *Module) ![:0]const u8 {
        switch (base.tag) {
            .container => return @fieldParentPtr(Container, "base", base).file_scope.getSource(module),
            .file => return @fieldParentPtr(File, "base", base).getSource(module),
            .zir_module => return @fieldParentPtr(ZIRModule, "base", base).getSource(module),
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .block => unreachable,
            .decl => unreachable,
        }
    }

    pub fn getOwnerPkg(base: *Scope) *Package {
        var cur = base;
        while (true) {
            cur = switch (cur.tag) {
                .container => return @fieldParentPtr(Container, "base", cur).file_scope.pkg,
                .file => return @fieldParentPtr(File, "base", cur).pkg,
                .zir_module => unreachable, // TODO are zir modules allowed to import packages?
                .gen_zir => @fieldParentPtr(GenZIR, "base", cur).parent,
                .local_val => @fieldParentPtr(LocalVal, "base", cur).parent,
                .local_ptr => @fieldParentPtr(LocalPtr, "base", cur).parent,
                .block => @fieldParentPtr(Block, "base", cur).decl.scope,
                .decl => @fieldParentPtr(DeclAnalysis, "base", cur).decl.scope,
            };
        }
    }

    /// Asserts the scope is a namespace Scope and removes the Decl from the namespace.
    pub fn removeDecl(base: *Scope, child: *Decl) void {
        switch (base.tag) {
            .container => return @fieldParentPtr(Container, "base", base).removeDecl(child),
            .zir_module => return @fieldParentPtr(ZIRModule, "base", base).removeDecl(child),
            .file => unreachable,
            .block => unreachable,
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .decl => unreachable,
        }
    }

    /// Asserts the scope is a File or ZIRModule and deinitializes it, then deallocates it.
    pub fn destroy(base: *Scope, gpa: *Allocator) void {
        switch (base.tag) {
            .file => {
                const scope_file = @fieldParentPtr(File, "base", base);
                scope_file.deinit(gpa);
                gpa.destroy(scope_file);
            },
            .zir_module => {
                const scope_zir_module = @fieldParentPtr(ZIRModule, "base", base);
                scope_zir_module.deinit(gpa);
                gpa.destroy(scope_zir_module);
            },
            .block => unreachable,
            .gen_zir => unreachable,
            .local_val => unreachable,
            .local_ptr => unreachable,
            .decl => unreachable,
            .container => unreachable,
        }
    }

    fn name_hash_hash(x: NameHash) u32 {
        return @truncate(u32, @bitCast(u128, x));
    }

    fn name_hash_eql(a: NameHash, b: NameHash) bool {
        return @bitCast(u128, a) == @bitCast(u128, b);
    }

    pub const Tag = enum {
        /// .zir source code.
        zir_module,
        /// .zig source code.
        file,
        /// struct, enum or union, every .file contains one of these.
        container,
        block,
        decl,
        gen_zir,
        local_val,
        local_ptr,
    };

    pub const Container = struct {
        pub const base_tag: Tag = .container;
        base: Scope = Scope{ .tag = base_tag },

        file_scope: *Scope.File,

        /// Direct children of the file.
        decls: std.AutoArrayHashMapUnmanaged(*Decl, void),
        ty: Type,

        pub fn deinit(self: *Container, gpa: *Allocator) void {
            self.decls.deinit(gpa);
            // TODO either Container of File should have an arena for sub_file_path and ty
            gpa.destroy(self.ty.castTag(.empty_struct).?);
            gpa.free(self.file_scope.sub_file_path);
            self.* = undefined;
        }

        pub fn removeDecl(self: *Container, child: *Decl) void {
            _ = self.decls.swapRemove(child);
        }

        pub fn fullyQualifiedNameHash(self: *Container, name: []const u8) NameHash {
            // TODO container scope qualified names.
            return std.zig.hashSrc(name);
        }
    };

    pub const File = struct {
        pub const base_tag: Tag = .file;
        base: Scope = Scope{ .tag = base_tag },

        /// Relative to the owning package's root_src_dir.
        /// Reference to external memory, not owned by File.
        sub_file_path: []const u8,
        source: union(enum) {
            unloaded: void,
            bytes: [:0]const u8,
        },
        contents: union {
            not_available: void,
            tree: *ast.Tree,
        },
        status: enum {
            never_loaded,
            unloaded_success,
            unloaded_parse_failure,
            loaded_success,
        },
        /// Package that this file is a part of, managed externally.
        pkg: *Package,

        root_container: Container,

        pub fn unload(self: *File, gpa: *Allocator) void {
            switch (self.status) {
                .never_loaded,
                .unloaded_parse_failure,
                .unloaded_success,
                => {},

                .loaded_success => {
                    self.contents.tree.deinit();
                    self.status = .unloaded_success;
                },
            }
            switch (self.source) {
                .bytes => |bytes| {
                    gpa.free(bytes);
                    self.source = .{ .unloaded = {} };
                },
                .unloaded => {},
            }
        }

        pub fn deinit(self: *File, gpa: *Allocator) void {
            self.root_container.deinit(gpa);
            self.unload(gpa);
            self.* = undefined;
        }

        pub fn dumpSrc(self: *File, src: usize) void {
            const loc = std.zig.findLineColumn(self.source.bytes, src);
            std.debug.print("{s}:{d}:{d}\n", .{ self.sub_file_path, loc.line + 1, loc.column + 1 });
        }

        pub fn getSource(self: *File, module: *Module) ![:0]const u8 {
            switch (self.source) {
                .unloaded => {
                    const source = try self.pkg.root_src_directory.handle.readFileAllocOptions(
                        module.gpa,
                        self.sub_file_path,
                        std.math.maxInt(u32),
                        null,
                        1,
                        0,
                    );
                    self.source = .{ .bytes = source };
                    return source;
                },
                .bytes => |bytes| return bytes,
            }
        }
    };

    pub const ZIRModule = struct {
        pub const base_tag: Tag = .zir_module;
        base: Scope = Scope{ .tag = base_tag },
        /// Relative to the owning package's root_src_dir.
        /// Reference to external memory, not owned by ZIRModule.
        sub_file_path: []const u8,
        source: union(enum) {
            unloaded: void,
            bytes: [:0]const u8,
        },
        contents: union {
            not_available: void,
            module: *zir.Module,
        },
        status: enum {
            never_loaded,
            unloaded_success,
            unloaded_parse_failure,
            unloaded_sema_failure,

            loaded_sema_failure,
            loaded_success,
        },

        /// Even though .zir files only have 1 module, this set is still needed
        /// because of anonymous Decls, which can exist in the global set, but
        /// not this one.
        decls: ArrayListUnmanaged(*Decl),

        pub fn unload(self: *ZIRModule, gpa: *Allocator) void {
            switch (self.status) {
                .never_loaded,
                .unloaded_parse_failure,
                .unloaded_sema_failure,
                .unloaded_success,
                => {},

                .loaded_success => {
                    self.contents.module.deinit(gpa);
                    gpa.destroy(self.contents.module);
                    self.contents = .{ .not_available = {} };
                    self.status = .unloaded_success;
                },
                .loaded_sema_failure => {
                    self.contents.module.deinit(gpa);
                    gpa.destroy(self.contents.module);
                    self.contents = .{ .not_available = {} };
                    self.status = .unloaded_sema_failure;
                },
            }
            switch (self.source) {
                .bytes => |bytes| {
                    gpa.free(bytes);
                    self.source = .{ .unloaded = {} };
                },
                .unloaded => {},
            }
        }

        pub fn deinit(self: *ZIRModule, gpa: *Allocator) void {
            self.decls.deinit(gpa);
            self.unload(gpa);
            self.* = undefined;
        }

        pub fn removeDecl(self: *ZIRModule, child: *Decl) void {
            for (self.decls.items) |item, i| {
                if (item == child) {
                    _ = self.decls.swapRemove(i);
                    return;
                }
            }
        }

        pub fn dumpSrc(self: *ZIRModule, src: usize) void {
            const loc = std.zig.findLineColumn(self.source.bytes, src);
            std.debug.print("{s}:{d}:{d}\n", .{ self.sub_file_path, loc.line + 1, loc.column + 1 });
        }

        pub fn getSource(self: *ZIRModule, module: *Module) ![:0]const u8 {
            switch (self.source) {
                .unloaded => {
                    const source = try module.root_pkg.root_src_directory.handle.readFileAllocOptions(
                        module.gpa,
                        self.sub_file_path,
                        std.math.maxInt(u32),
                        null,
                        1,
                        0,
                    );
                    self.source = .{ .bytes = source };
                    return source;
                },
                .bytes => |bytes| return bytes,
            }
        }

        pub fn fullyQualifiedNameHash(self: *ZIRModule, name: []const u8) NameHash {
            // ZIR modules only have 1 file with all decls global in the same namespace.
            return std.zig.hashSrc(name);
        }
    };

    /// This is a temporary structure, references to it are valid only
    /// during semantic analysis of the block.
    pub const Block = struct {
        pub const base_tag: Tag = .block;

        base: Scope = Scope{ .tag = base_tag },
        parent: ?*Block,
        /// Maps ZIR to TZIR. Shared to sub-blocks.
        inst_table: *InstTable,
        func: ?*Fn,
        decl: *Decl,
        instructions: ArrayListUnmanaged(*Inst),
        /// Points to the arena allocator of DeclAnalysis
        arena: *Allocator,
        label: ?Label = null,
        inlining: ?*Inlining,
        is_comptime: bool,
        /// Shared to sub-blocks.
        branch_quota: *u32,

        pub const InstTable = std.AutoHashMap(*zir.Inst, *Inst);

        /// This `Block` maps a block ZIR instruction to the corresponding
        /// TZIR instruction for break instruction analysis.
        pub const Label = struct {
            zir_block: *zir.Inst.Block,
            merges: Merges,
        };

        /// This `Block` indicates that an inline function call is happening
        /// and return instructions should be analyzed as a break instruction
        /// to this TZIR block instruction.
        /// It is shared among all the blocks in an inline or comptime called
        /// function.
        pub const Inlining = struct {
            /// Shared state among the entire inline/comptime call stack.
            shared: *Shared,
            /// We use this to count from 0 so that arg instructions know
            /// which parameter index they are, without having to store
            /// a parameter index with each arg instruction.
            param_index: usize,
            casted_args: []*Inst,
            merges: Merges,

            pub const Shared = struct {
                caller: ?*Fn,
                branch_count: u32,
            };
        };

        pub const Merges = struct {
            results: ArrayListUnmanaged(*Inst),
            block_inst: *Inst.Block,
        };

        /// For debugging purposes.
        pub fn dump(self: *Block, mod: Module) void {
            zir.dumpBlock(mod, self);
        }
    };

    /// This is a temporary structure, references to it are valid only
    /// during semantic analysis of the decl.
    pub const DeclAnalysis = struct {
        pub const base_tag: Tag = .decl;
        base: Scope = Scope{ .tag = base_tag },
        decl: *Decl,
        arena: std.heap.ArenaAllocator,
    };

    /// This is a temporary structure, references to it are valid only
    /// during semantic analysis of the decl.
    pub const GenZIR = struct {
        pub const base_tag: Tag = .gen_zir;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `GenZIR`, `ZIRModule`, `File`
        parent: *Scope,
        decl: *Decl,
        arena: *Allocator,
        /// The first N instructions in a function body ZIR are arg instructions.
        instructions: std.ArrayListUnmanaged(*zir.Inst) = .{},
        label: ?Label = null,
        break_block: ?*zir.Inst.Block = null,
        continue_block: ?*zir.Inst.Block = null,
        /// only valid if label != null or (continue_block and break_block) != null
        break_result_loc: astgen.ResultLoc = undefined,

        pub const Label = struct {
            token: ast.TokenIndex,
            block_inst: *zir.Inst.Block,
            used: bool = false,
        };
    };

    /// This is always a `const` local and importantly the `inst` is a value type, not a pointer.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    pub const LocalVal = struct {
        pub const base_tag: Tag = .local_val;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZIR`.
        parent: *Scope,
        gen_zir: *GenZIR,
        name: []const u8,
        inst: *zir.Inst,
    };

    /// This could be a `const` or `var` local. It has a pointer instead of a value.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    pub const LocalPtr = struct {
        pub const base_tag: Tag = .local_ptr;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZIR`.
        parent: *Scope,
        gen_zir: *GenZIR,
        name: []const u8,
        ptr: *zir.Inst,
    };
};

pub const InnerError = error{ OutOfMemory, AnalysisFail };

pub fn deinit(self: *Module) void {
    const gpa = self.gpa;

    self.zig_cache_artifact_directory.handle.close();

    self.deletion_set.deinit(gpa);

    for (self.decl_table.items()) |entry| {
        entry.value.destroy(self);
    }
    self.decl_table.deinit(gpa);

    for (self.failed_decls.items()) |entry| {
        entry.value.destroy(gpa);
    }
    self.failed_decls.deinit(gpa);

    for (self.emit_h_failed_decls.items()) |entry| {
        entry.value.destroy(gpa);
    }
    self.emit_h_failed_decls.deinit(gpa);

    for (self.failed_files.items()) |entry| {
        entry.value.destroy(gpa);
    }
    self.failed_files.deinit(gpa);

    for (self.failed_exports.items()) |entry| {
        entry.value.destroy(gpa);
    }
    self.failed_exports.deinit(gpa);

    for (self.compile_log_decls.items()) |*entry| {
        entry.value.deinit(gpa);
    }
    self.compile_log_decls.deinit(gpa);

    for (self.decl_exports.items()) |entry| {
        const export_list = entry.value;
        gpa.free(export_list);
    }
    self.decl_exports.deinit(gpa);

    for (self.export_owners.items()) |entry| {
        freeExportList(gpa, entry.value);
    }
    self.export_owners.deinit(gpa);

    self.symbol_exports.deinit(gpa);
    self.root_scope.destroy(gpa);

    var it = self.global_error_set.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key);
    }
    self.global_error_set.deinit(gpa);

    for (self.import_table.items()) |entry| {
        entry.value.base.destroy(gpa);
    }
    self.import_table.deinit(gpa);
}

fn freeExportList(gpa: *Allocator, export_list: []*Export) void {
    for (export_list) |exp| {
        gpa.free(exp.options.name);
        gpa.destroy(exp);
    }
    gpa.free(export_list);
}

pub fn ensureDeclAnalyzed(self: *Module, decl: *Decl) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const subsequent_analysis = switch (decl.analysis) {
        .in_progress => unreachable,

        .sema_failure,
        .sema_failure_retryable,
        .codegen_failure,
        .dependency_failure,
        .codegen_failure_retryable,
        => return error.AnalysisFail,

        .complete => return,

        .outdated => blk: {
            log.debug("re-analyzing {s}\n", .{decl.name});

            // The exports this Decl performs will be re-discovered, so we remove them here
            // prior to re-analysis.
            self.deleteDeclExports(decl);
            // Dependencies will be re-discovered, so we remove them here prior to re-analysis.
            for (decl.dependencies.items()) |entry| {
                const dep = entry.key;
                dep.removeDependant(decl);
                if (dep.dependants.items().len == 0 and !dep.deletion_flag) {
                    // We don't perform a deletion here, because this Decl or another one
                    // may end up referencing it before the update is complete.
                    dep.deletion_flag = true;
                    try self.deletion_set.append(self.gpa, dep);
                }
            }
            decl.dependencies.clearRetainingCapacity();

            break :blk true;
        },

        .unreferenced => false,
    };

    const type_changed = if (self.root_scope.cast(Scope.ZIRModule)) |zir_module|
        try zir_sema.analyzeZirDecl(self, decl, zir_module.contents.module.decls[decl.src_index])
    else
        self.astGenAndAnalyzeDecl(decl) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisFail => return error.AnalysisFail,
            else => {
                try self.failed_decls.ensureCapacity(self.gpa, self.failed_decls.items().len + 1);
                self.failed_decls.putAssumeCapacityNoClobber(decl, try Compilation.ErrorMsg.create(
                    self.gpa,
                    decl.src(),
                    "unable to analyze: {s}",
                    .{@errorName(err)},
                ));
                decl.analysis = .sema_failure_retryable;
                return error.AnalysisFail;
            },
        };

    if (subsequent_analysis) {
        // We may need to chase the dependants and re-analyze them.
        // However, if the decl is a function, and the type is the same, we do not need to.
        if (type_changed or decl.typed_value.most_recent.typed_value.val.tag() != .function) {
            for (decl.dependants.items()) |entry| {
                const dep = entry.key;
                switch (dep.analysis) {
                    .unreferenced => unreachable,
                    .in_progress => unreachable,
                    .outdated => continue, // already queued for update

                    .dependency_failure,
                    .sema_failure,
                    .sema_failure_retryable,
                    .codegen_failure,
                    .codegen_failure_retryable,
                    .complete,
                    => if (dep.generation != self.generation) {
                        try self.markOutdatedDecl(dep);
                    },
                }
            }
        }
    }
}

fn astGenAndAnalyzeDecl(self: *Module, decl: *Decl) !bool {
    const tracy = trace(@src());
    defer tracy.end();

    const container_scope = decl.scope.cast(Scope.Container).?;
    const tree = try self.getAstTree(container_scope.file_scope);
    const ast_node = tree.root_node.decls()[decl.src_index];
    switch (ast_node.tag) {
        .FnProto => {
            const fn_proto = ast_node.castTag(.FnProto).?;

            decl.analysis = .in_progress;

            // This arena allocator's memory is discarded at the end of this function. It is used
            // to determine the type of the function, and hence the type of the decl, which is needed
            // to complete the Decl analysis.
            var fn_type_scope_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer fn_type_scope_arena.deinit();
            var fn_type_scope: Scope.GenZIR = .{
                .decl = decl,
                .arena = &fn_type_scope_arena.allocator,
                .parent = decl.scope,
            };
            defer fn_type_scope.instructions.deinit(self.gpa);

            decl.is_pub = fn_proto.getVisibToken() != null;

            const param_decls = fn_proto.params();
            const param_types = try fn_type_scope.arena.alloc(*zir.Inst, param_decls.len);

            const fn_src = tree.token_locs[fn_proto.fn_token].start;
            const type_type = try astgen.addZIRInstConst(self, &fn_type_scope.base, fn_src, .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.type_type),
            });
            const type_type_rl: astgen.ResultLoc = .{ .ty = type_type };
            for (param_decls) |param_decl, i| {
                const param_type_node = switch (param_decl.param_type) {
                    .any_type => |node| return self.failNode(&fn_type_scope.base, node, "TODO implement anytype parameter", .{}),
                    .type_expr => |node| node,
                };
                param_types[i] = try astgen.expr(self, &fn_type_scope.base, type_type_rl, param_type_node);
            }
            if (fn_proto.getVarArgsToken()) |var_args_token| {
                return self.failTok(&fn_type_scope.base, var_args_token, "TODO implement var args", .{});
            }
            if (fn_proto.getLibName()) |lib_name| {
                return self.failNode(&fn_type_scope.base, lib_name, "TODO implement function library name", .{});
            }
            if (fn_proto.getAlignExpr()) |align_expr| {
                return self.failNode(&fn_type_scope.base, align_expr, "TODO implement function align expression", .{});
            }
            if (fn_proto.getSectionExpr()) |sect_expr| {
                return self.failNode(&fn_type_scope.base, sect_expr, "TODO implement function section expression", .{});
            }
            if (fn_proto.getCallconvExpr()) |callconv_expr| {
                return self.failNode(
                    &fn_type_scope.base,
                    callconv_expr,
                    "TODO implement function calling convention expression",
                    .{},
                );
            }
            const return_type_expr = switch (fn_proto.return_type) {
                .Explicit => |node| node,
                .InferErrorSet => |node| return self.failNode(&fn_type_scope.base, node, "TODO implement inferred error sets", .{}),
                .Invalid => |tok| return self.failTok(&fn_type_scope.base, tok, "unable to parse return type", .{}),
            };

            const return_type_inst = try astgen.expr(self, &fn_type_scope.base, type_type_rl, return_type_expr);
            const fn_type_inst = try astgen.addZIRInst(self, &fn_type_scope.base, fn_src, zir.Inst.FnType, .{
                .return_type = return_type_inst,
                .param_types = param_types,
            }, .{});

            if (std.builtin.mode == .Debug and self.comp.verbose_ir) {
                zir.dumpZir(self.gpa, "fn_type", decl.name, fn_type_scope.instructions.items) catch {};
            }

            // We need the memory for the Type to go into the arena for the Decl
            var decl_arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer decl_arena.deinit();
            const decl_arena_state = try decl_arena.allocator.create(std.heap.ArenaAllocator.State);

            var inst_table = Scope.Block.InstTable.init(self.gpa);
            defer inst_table.deinit();

            var branch_quota: u32 = default_eval_branch_quota;

            var block_scope: Scope.Block = .{
                .parent = null,
                .inst_table = &inst_table,
                .func = null,
                .decl = decl,
                .instructions = .{},
                .arena = &decl_arena.allocator,
                .inlining = null,
                .is_comptime = false,
                .branch_quota = &branch_quota,
            };
            defer block_scope.instructions.deinit(self.gpa);

            const fn_type = try zir_sema.analyzeBodyValueAsType(self, &block_scope, fn_type_inst, .{
                .instructions = fn_type_scope.instructions.items,
            });
            const body_node = fn_proto.getBodyNode() orelse {
                // Extern function.
                var type_changed = true;
                if (decl.typedValueManaged()) |tvm| {
                    type_changed = !tvm.typed_value.ty.eql(fn_type);

                    tvm.deinit(self.gpa);
                }
                const fn_val = try Value.Tag.extern_fn.create(&decl_arena.allocator, decl);

                decl_arena_state.* = decl_arena.state;
                decl.typed_value = .{
                    .most_recent = .{
                        .typed_value = .{ .ty = fn_type, .val = fn_val },
                        .arena = decl_arena_state,
                    },
                };
                decl.analysis = .complete;
                decl.generation = self.generation;

                try self.comp.bin_file.allocateDeclIndexes(decl);
                try self.comp.work_queue.writeItem(.{ .codegen_decl = decl });

                if (type_changed and self.emit_h != null) {
                    try self.comp.work_queue.writeItem(.{ .emit_h_decl = decl });
                }

                return type_changed;
            };

            const new_func = try decl_arena.allocator.create(Fn);
            const fn_payload = try decl_arena.allocator.create(Value.Payload.Function);

            const fn_zir: zir.Module.Body = blk: {
                // We put the ZIR inside the Decl arena.
                var gen_scope: Scope.GenZIR = .{
                    .decl = decl,
                    .arena = &decl_arena.allocator,
                    .parent = decl.scope,
                };
                defer gen_scope.instructions.deinit(self.gpa);

                // We need an instruction for each parameter, and they must be first in the body.
                try gen_scope.instructions.resize(self.gpa, fn_proto.params_len);
                var params_scope = &gen_scope.base;
                for (fn_proto.params()) |param, i| {
                    const name_token = param.name_token.?;
                    const src = tree.token_locs[name_token].start;
                    const param_name = try self.identifierTokenString(&gen_scope.base, name_token);
                    const arg = try decl_arena.allocator.create(zir.Inst.Arg);
                    arg.* = .{
                        .base = .{
                            .tag = .arg,
                            .src = src,
                        },
                        .positionals = .{
                            .name = param_name,
                        },
                        .kw_args = .{},
                    };
                    gen_scope.instructions.items[i] = &arg.base;
                    const sub_scope = try decl_arena.allocator.create(Scope.LocalVal);
                    sub_scope.* = .{
                        .parent = params_scope,
                        .gen_zir = &gen_scope,
                        .name = param_name,
                        .inst = &arg.base,
                    };
                    params_scope = &sub_scope.base;
                }

                const body_block = body_node.cast(ast.Node.Block).?;

                try astgen.blockExpr(self, params_scope, body_block);

                if (gen_scope.instructions.items.len == 0 or
                    !gen_scope.instructions.items[gen_scope.instructions.items.len - 1].tag.isNoReturn())
                {
                    const src = tree.token_locs[body_block.rbrace].start;
                    _ = try astgen.addZIRNoOp(self, &gen_scope.base, src, .returnvoid);
                }

                if (std.builtin.mode == .Debug and self.comp.verbose_ir) {
                    zir.dumpZir(self.gpa, "fn_body", decl.name, gen_scope.instructions.items) catch {};
                }

                break :blk .{
                    .instructions = try gen_scope.arena.dupe(*zir.Inst, gen_scope.instructions.items),
                };
            };

            const is_inline = blk: {
                if (fn_proto.getExternExportInlineToken()) |maybe_inline_token| {
                    if (tree.token_ids[maybe_inline_token] == .Keyword_inline) {
                        break :blk true;
                    }
                }
                break :blk false;
            };
            const anal_state = ([2]Fn.Analysis{ .queued, .inline_only })[@boolToInt(is_inline)];

            new_func.* = .{
                .state = anal_state,
                .zir = fn_zir,
                .body = undefined,
                .owner_decl = decl,
            };
            fn_payload.* = .{
                .base = .{ .tag = .function },
                .data = new_func,
            };

            var prev_type_has_bits = false;
            var prev_is_inline = false;
            var type_changed = true;

            if (decl.typedValueManaged()) |tvm| {
                prev_type_has_bits = tvm.typed_value.ty.hasCodeGenBits();
                type_changed = !tvm.typed_value.ty.eql(fn_type);
                if (tvm.typed_value.val.castTag(.function)) |payload| {
                    const prev_func = payload.data;
                    prev_is_inline = prev_func.state == .inline_only;
                }

                tvm.deinit(self.gpa);
            }

            decl_arena_state.* = decl_arena.state;
            decl.typed_value = .{
                .most_recent = .{
                    .typed_value = .{
                        .ty = fn_type,
                        .val = Value.initPayload(&fn_payload.base),
                    },
                    .arena = decl_arena_state,
                },
            };
            decl.analysis = .complete;
            decl.generation = self.generation;

            if (!is_inline and fn_type.hasCodeGenBits()) {
                // We don't fully codegen the decl until later, but we do need to reserve a global
                // offset table index for it. This allows us to codegen decls out of dependency order,
                // increasing how many computations can be done in parallel.
                try self.comp.bin_file.allocateDeclIndexes(decl);
                try self.comp.work_queue.writeItem(.{ .codegen_decl = decl });
                if (type_changed and self.emit_h != null) {
                    try self.comp.work_queue.writeItem(.{ .emit_h_decl = decl });
                }
            } else if (!prev_is_inline and prev_type_has_bits) {
                self.comp.bin_file.freeDecl(decl);
            }

            if (fn_proto.getExternExportInlineToken()) |maybe_export_token| {
                if (tree.token_ids[maybe_export_token] == .Keyword_export) {
                    if (is_inline) {
                        return self.failTok(
                            &block_scope.base,
                            maybe_export_token,
                            "export of inline function",
                            .{},
                        );
                    }
                    const export_src = tree.token_locs[maybe_export_token].start;
                    const name_loc = tree.token_locs[fn_proto.getNameToken().?];
                    const name = tree.tokenSliceLoc(name_loc);
                    // The scope needs to have the decl in it.
                    try self.analyzeExport(&block_scope.base, export_src, name, decl);
                }
            }
            return type_changed or is_inline != prev_is_inline;
        },
        .VarDecl => {
            const var_decl = @fieldParentPtr(ast.Node.VarDecl, "base", ast_node);

            decl.analysis = .in_progress;

            // We need the memory for the Type to go into the arena for the Decl
            var decl_arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer decl_arena.deinit();
            const decl_arena_state = try decl_arena.allocator.create(std.heap.ArenaAllocator.State);

            var decl_inst_table = Scope.Block.InstTable.init(self.gpa);
            defer decl_inst_table.deinit();

            var branch_quota: u32 = default_eval_branch_quota;

            var block_scope: Scope.Block = .{
                .parent = null,
                .inst_table = &decl_inst_table,
                .func = null,
                .decl = decl,
                .instructions = .{},
                .arena = &decl_arena.allocator,
                .inlining = null,
                .is_comptime = true,
                .branch_quota = &branch_quota,
            };
            defer block_scope.instructions.deinit(self.gpa);

            decl.is_pub = var_decl.getVisibToken() != null;
            const is_extern = blk: {
                const maybe_extern_token = var_decl.getExternExportToken() orelse
                    break :blk false;
                if (tree.token_ids[maybe_extern_token] != .Keyword_extern) break :blk false;
                if (var_decl.getInitNode()) |some| {
                    return self.failNode(&block_scope.base, some, "extern variables have no initializers", .{});
                }
                break :blk true;
            };
            if (var_decl.getLibName()) |lib_name| {
                assert(is_extern);
                return self.failNode(&block_scope.base, lib_name, "TODO implement function library name", .{});
            }
            const is_mutable = tree.token_ids[var_decl.mut_token] == .Keyword_var;
            const is_threadlocal = if (var_decl.getThreadLocalToken()) |some| blk: {
                if (!is_mutable) {
                    return self.failTok(&block_scope.base, some, "threadlocal variable cannot be constant", .{});
                }
                break :blk true;
            } else false;
            assert(var_decl.getComptimeToken() == null);
            if (var_decl.getAlignNode()) |align_expr| {
                return self.failNode(&block_scope.base, align_expr, "TODO implement function align expression", .{});
            }
            if (var_decl.getSectionNode()) |sect_expr| {
                return self.failNode(&block_scope.base, sect_expr, "TODO implement function section expression", .{});
            }

            const var_info: struct { ty: Type, val: ?Value } = if (var_decl.getInitNode()) |init_node| vi: {
                var gen_scope_arena = std.heap.ArenaAllocator.init(self.gpa);
                defer gen_scope_arena.deinit();
                var gen_scope: Scope.GenZIR = .{
                    .decl = decl,
                    .arena = &gen_scope_arena.allocator,
                    .parent = decl.scope,
                };
                defer gen_scope.instructions.deinit(self.gpa);

                const init_result_loc: astgen.ResultLoc = if (var_decl.getTypeNode()) |type_node| rl: {
                    const src = tree.token_locs[type_node.firstToken()].start;
                    const type_type = try astgen.addZIRInstConst(self, &gen_scope.base, src, .{
                        .ty = Type.initTag(.type),
                        .val = Value.initTag(.type_type),
                    });
                    const var_type = try astgen.expr(self, &gen_scope.base, .{ .ty = type_type }, type_node);
                    break :rl .{ .ty = var_type };
                } else .none;

                const src = tree.token_locs[init_node.firstToken()].start;
                const init_inst = try astgen.expr(self, &gen_scope.base, init_result_loc, init_node);
                if (std.builtin.mode == .Debug and self.comp.verbose_ir) {
                    zir.dumpZir(self.gpa, "var_init", decl.name, gen_scope.instructions.items) catch {};
                }

                var var_inst_table = Scope.Block.InstTable.init(self.gpa);
                defer var_inst_table.deinit();

                var branch_quota_vi: u32 = default_eval_branch_quota;
                var inner_block: Scope.Block = .{
                    .parent = null,
                    .inst_table = &var_inst_table,
                    .func = null,
                    .decl = decl,
                    .instructions = .{},
                    .arena = &gen_scope_arena.allocator,
                    .inlining = null,
                    .is_comptime = true,
                    .branch_quota = &branch_quota_vi,
                };
                defer inner_block.instructions.deinit(self.gpa);
                try zir_sema.analyzeBody(self, &inner_block, .{
                    .instructions = gen_scope.instructions.items,
                });

                // The result location guarantees the type coercion.
                const analyzed_init_inst = var_inst_table.get(init_inst).?;
                // The is_comptime in the Scope.Block guarantees the result is comptime-known.
                const val = analyzed_init_inst.value().?;

                const ty = try analyzed_init_inst.ty.copy(block_scope.arena);
                break :vi .{
                    .ty = ty,
                    .val = try val.copy(block_scope.arena),
                };
            } else if (!is_extern) {
                return self.failTok(&block_scope.base, var_decl.firstToken(), "variables must be initialized", .{});
            } else if (var_decl.getTypeNode()) |type_node| vi: {
                // Temporary arena for the zir instructions.
                var type_scope_arena = std.heap.ArenaAllocator.init(self.gpa);
                defer type_scope_arena.deinit();
                var type_scope: Scope.GenZIR = .{
                    .decl = decl,
                    .arena = &type_scope_arena.allocator,
                    .parent = decl.scope,
                };
                defer type_scope.instructions.deinit(self.gpa);

                const src = tree.token_locs[type_node.firstToken()].start;
                const type_type = try astgen.addZIRInstConst(self, &type_scope.base, src, .{
                    .ty = Type.initTag(.type),
                    .val = Value.initTag(.type_type),
                });
                const var_type = try astgen.expr(self, &type_scope.base, .{ .ty = type_type }, type_node);
                if (std.builtin.mode == .Debug and self.comp.verbose_ir) {
                    zir.dumpZir(self.gpa, "var_type", decl.name, type_scope.instructions.items) catch {};
                }

                const ty = try zir_sema.analyzeBodyValueAsType(self, &block_scope, var_type, .{
                    .instructions = type_scope.instructions.items,
                });
                break :vi .{
                    .ty = ty,
                    .val = null,
                };
            } else {
                return self.failTok(&block_scope.base, var_decl.firstToken(), "unable to infer variable type", .{});
            };

            if (is_mutable and !var_info.ty.isValidVarType(is_extern)) {
                return self.failTok(&block_scope.base, var_decl.firstToken(), "variable of type '{}' must be const", .{var_info.ty});
            }

            var type_changed = true;
            if (decl.typedValueManaged()) |tvm| {
                type_changed = !tvm.typed_value.ty.eql(var_info.ty);

                tvm.deinit(self.gpa);
            }

            const new_variable = try decl_arena.allocator.create(Var);
            new_variable.* = .{
                .owner_decl = decl,
                .init = var_info.val orelse undefined,
                .is_extern = is_extern,
                .is_mutable = is_mutable,
                .is_threadlocal = is_threadlocal,
            };
            const var_val = try Value.Tag.variable.create(&decl_arena.allocator, new_variable);

            decl_arena_state.* = decl_arena.state;
            decl.typed_value = .{
                .most_recent = .{
                    .typed_value = .{
                        .ty = var_info.ty,
                        .val = var_val,
                    },
                    .arena = decl_arena_state,
                },
            };
            decl.analysis = .complete;
            decl.generation = self.generation;

            if (var_decl.getExternExportToken()) |maybe_export_token| {
                if (tree.token_ids[maybe_export_token] == .Keyword_export) {
                    const export_src = tree.token_locs[maybe_export_token].start;
                    const name_loc = tree.token_locs[var_decl.name_token];
                    const name = tree.tokenSliceLoc(name_loc);
                    // The scope needs to have the decl in it.
                    try self.analyzeExport(&block_scope.base, export_src, name, decl);
                }
            }
            return type_changed;
        },
        .Comptime => {
            const comptime_decl = @fieldParentPtr(ast.Node.Comptime, "base", ast_node);

            decl.analysis = .in_progress;

            // A comptime decl does not store any value so we can just deinit this arena after analysis is done.
            var analysis_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer analysis_arena.deinit();
            var gen_scope: Scope.GenZIR = .{
                .decl = decl,
                .arena = &analysis_arena.allocator,
                .parent = decl.scope,
            };
            defer gen_scope.instructions.deinit(self.gpa);

            _ = try astgen.comptimeExpr(self, &gen_scope.base, .none, comptime_decl.expr);
            if (std.builtin.mode == .Debug and self.comp.verbose_ir) {
                zir.dumpZir(self.gpa, "comptime_block", decl.name, gen_scope.instructions.items) catch {};
            }

            var inst_table = Scope.Block.InstTable.init(self.gpa);
            defer inst_table.deinit();

            var branch_quota: u32 = default_eval_branch_quota;

            var block_scope: Scope.Block = .{
                .parent = null,
                .inst_table = &inst_table,
                .func = null,
                .decl = decl,
                .instructions = .{},
                .arena = &analysis_arena.allocator,
                .inlining = null,
                .is_comptime = true,
                .branch_quota = &branch_quota,
            };
            defer block_scope.instructions.deinit(self.gpa);

            _ = try zir_sema.analyzeBody(self, &block_scope, .{
                .instructions = gen_scope.instructions.items,
            });

            decl.analysis = .complete;
            decl.generation = self.generation;
            return true;
        },
        .Use => @panic("TODO usingnamespace decl"),
        else => unreachable,
    }
}

fn declareDeclDependency(self: *Module, depender: *Decl, dependee: *Decl) !void {
    try depender.dependencies.ensureCapacity(self.gpa, depender.dependencies.items().len + 1);
    try dependee.dependants.ensureCapacity(self.gpa, dependee.dependants.items().len + 1);

    depender.dependencies.putAssumeCapacity(dependee, {});
    dependee.dependants.putAssumeCapacity(depender, {});
}

fn getSrcModule(self: *Module, root_scope: *Scope.ZIRModule) !*zir.Module {
    switch (root_scope.status) {
        .never_loaded, .unloaded_success => {
            try self.failed_files.ensureCapacity(self.gpa, self.failed_files.items().len + 1);

            const source = try root_scope.getSource(self);

            var keep_zir_module = false;
            const zir_module = try self.gpa.create(zir.Module);
            defer if (!keep_zir_module) self.gpa.destroy(zir_module);

            zir_module.* = try zir.parse(self.gpa, source);
            defer if (!keep_zir_module) zir_module.deinit(self.gpa);

            if (zir_module.error_msg) |src_err_msg| {
                self.failed_files.putAssumeCapacityNoClobber(
                    &root_scope.base,
                    try Compilation.ErrorMsg.create(self.gpa, src_err_msg.byte_offset, "{s}", .{src_err_msg.msg}),
                );
                root_scope.status = .unloaded_parse_failure;
                return error.AnalysisFail;
            }

            root_scope.status = .loaded_success;
            root_scope.contents = .{ .module = zir_module };
            keep_zir_module = true;

            return zir_module;
        },

        .unloaded_parse_failure,
        .unloaded_sema_failure,
        => return error.AnalysisFail,

        .loaded_success, .loaded_sema_failure => return root_scope.contents.module,
    }
}

pub fn getAstTree(self: *Module, root_scope: *Scope.File) !*ast.Tree {
    const tracy = trace(@src());
    defer tracy.end();

    switch (root_scope.status) {
        .never_loaded, .unloaded_success => {
            try self.failed_files.ensureCapacity(self.gpa, self.failed_files.items().len + 1);

            const source = try root_scope.getSource(self);

            var keep_tree = false;
            const tree = try std.zig.parse(self.gpa, source);
            defer if (!keep_tree) tree.deinit();

            if (tree.errors.len != 0) {
                const parse_err = tree.errors[0];

                var msg = std.ArrayList(u8).init(self.gpa);
                defer msg.deinit();

                try parse_err.render(tree.token_ids, msg.outStream());
                const err_msg = try self.gpa.create(Compilation.ErrorMsg);
                err_msg.* = .{
                    .msg = msg.toOwnedSlice(),
                    .byte_offset = tree.token_locs[parse_err.loc()].start,
                };

                self.failed_files.putAssumeCapacityNoClobber(&root_scope.base, err_msg);
                root_scope.status = .unloaded_parse_failure;
                return error.AnalysisFail;
            }

            root_scope.status = .loaded_success;
            root_scope.contents = .{ .tree = tree };
            keep_tree = true;

            return tree;
        },

        .unloaded_parse_failure => return error.AnalysisFail,

        .loaded_success => return root_scope.contents.tree,
    }
}

pub fn analyzeContainer(self: *Module, container_scope: *Scope.Container) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // We may be analyzing it for the first time, or this may be
    // an incremental update. This code handles both cases.
    const tree = try self.getAstTree(container_scope.file_scope);
    const decls = tree.root_node.decls();

    try self.comp.work_queue.ensureUnusedCapacity(decls.len);
    try container_scope.decls.ensureCapacity(self.gpa, decls.len);

    // Keep track of the decls that we expect to see in this file so that
    // we know which ones have been deleted.
    var deleted_decls = std.AutoArrayHashMap(*Decl, void).init(self.gpa);
    defer deleted_decls.deinit();
    try deleted_decls.ensureCapacity(container_scope.decls.items().len);
    for (container_scope.decls.items()) |entry| {
        deleted_decls.putAssumeCapacityNoClobber(entry.key, {});
    }

    for (decls) |src_decl, decl_i| {
        if (src_decl.cast(ast.Node.FnProto)) |fn_proto| {
            // We will create a Decl for it regardless of analysis status.
            const name_tok = fn_proto.getNameToken() orelse {
                @panic("TODO missing function name");
            };

            const name_loc = tree.token_locs[name_tok];
            const name = tree.tokenSliceLoc(name_loc);
            const name_hash = container_scope.fullyQualifiedNameHash(name);
            const contents_hash = std.zig.hashSrc(tree.getNodeSource(src_decl));
            if (self.decl_table.get(name_hash)) |decl| {
                // Update the AST Node index of the decl, even if its contents are unchanged, it may
                // have been re-ordered.
                decl.src_index = decl_i;
                if (deleted_decls.swapRemove(decl) == null) {
                    decl.analysis = .sema_failure;
                    const err_msg = try Compilation.ErrorMsg.create(self.gpa, tree.token_locs[name_tok].start, "redefinition of '{s}'", .{decl.name});
                    errdefer err_msg.destroy(self.gpa);
                    try self.failed_decls.putNoClobber(self.gpa, decl, err_msg);
                } else {
                    if (!srcHashEql(decl.contents_hash, contents_hash)) {
                        try self.markOutdatedDecl(decl);
                        decl.contents_hash = contents_hash;
                    } else switch (self.comp.bin_file.tag) {
                        .coff => {
                            // TODO Implement for COFF
                        },
                        .elf => if (decl.fn_link.elf.len != 0) {
                            // TODO Look into detecting when this would be unnecessary by storing enough state
                            // in `Decl` to notice that the line number did not change.
                            self.comp.work_queue.writeItemAssumeCapacity(.{ .update_line_number = decl });
                        },
                        .macho => {
                            // TODO Implement for MachO
                        },
                        .c, .wasm => {},
                    }
                }
            } else {
                const new_decl = try self.createNewDecl(&container_scope.base, name, decl_i, name_hash, contents_hash);
                container_scope.decls.putAssumeCapacity(new_decl, {});
                if (fn_proto.getExternExportInlineToken()) |maybe_export_token| {
                    if (tree.token_ids[maybe_export_token] == .Keyword_export) {
                        self.comp.work_queue.writeItemAssumeCapacity(.{ .analyze_decl = new_decl });
                    }
                }
            }
        } else if (src_decl.castTag(.VarDecl)) |var_decl| {
            const name_loc = tree.token_locs[var_decl.name_token];
            const name = tree.tokenSliceLoc(name_loc);
            const name_hash = container_scope.fullyQualifiedNameHash(name);
            const contents_hash = std.zig.hashSrc(tree.getNodeSource(src_decl));
            if (self.decl_table.get(name_hash)) |decl| {
                // Update the AST Node index of the decl, even if its contents are unchanged, it may
                // have been re-ordered.
                decl.src_index = decl_i;
                if (deleted_decls.swapRemove(decl) == null) {
                    decl.analysis = .sema_failure;
                    const err_msg = try Compilation.ErrorMsg.create(self.gpa, name_loc.start, "redefinition of '{s}'", .{decl.name});
                    errdefer err_msg.destroy(self.gpa);
                    try self.failed_decls.putNoClobber(self.gpa, decl, err_msg);
                } else if (!srcHashEql(decl.contents_hash, contents_hash)) {
                    try self.markOutdatedDecl(decl);
                    decl.contents_hash = contents_hash;
                }
            } else {
                const new_decl = try self.createNewDecl(&container_scope.base, name, decl_i, name_hash, contents_hash);
                container_scope.decls.putAssumeCapacity(new_decl, {});
                if (var_decl.getExternExportToken()) |maybe_export_token| {
                    if (tree.token_ids[maybe_export_token] == .Keyword_export) {
                        self.comp.work_queue.writeItemAssumeCapacity(.{ .analyze_decl = new_decl });
                    }
                }
            }
        } else if (src_decl.castTag(.Comptime)) |comptime_node| {
            const name_index = self.getNextAnonNameIndex();
            const name = try std.fmt.allocPrint(self.gpa, "__comptime_{d}", .{name_index});
            defer self.gpa.free(name);

            const name_hash = container_scope.fullyQualifiedNameHash(name);
            const contents_hash = std.zig.hashSrc(tree.getNodeSource(src_decl));

            const new_decl = try self.createNewDecl(&container_scope.base, name, decl_i, name_hash, contents_hash);
            container_scope.decls.putAssumeCapacity(new_decl, {});
            self.comp.work_queue.writeItemAssumeCapacity(.{ .analyze_decl = new_decl });
        } else if (src_decl.castTag(.ContainerField)) |container_field| {
            log.err("TODO: analyze container field", .{});
        } else if (src_decl.castTag(.TestDecl)) |test_decl| {
            log.err("TODO: analyze test decl", .{});
        } else if (src_decl.castTag(.Use)) |use_decl| {
            log.err("TODO: analyze usingnamespace decl", .{});
        } else {
            unreachable;
        }
    }
    // Handle explicitly deleted decls from the source code. Not to be confused
    // with when we delete decls because they are no longer referenced.
    for (deleted_decls.items()) |entry| {
        log.debug("noticed '{s}' deleted from source\n", .{entry.key.name});
        try self.deleteDecl(entry.key);
    }
}

pub fn analyzeRootZIRModule(self: *Module, root_scope: *Scope.ZIRModule) !void {
    // We may be analyzing it for the first time, or this may be
    // an incremental update. This code handles both cases.
    const src_module = try self.getSrcModule(root_scope);

    try self.comp.work_queue.ensureUnusedCapacity(src_module.decls.len);
    try root_scope.decls.ensureCapacity(self.gpa, src_module.decls.len);

    var exports_to_resolve = std.ArrayList(*zir.Decl).init(self.gpa);
    defer exports_to_resolve.deinit();

    // Keep track of the decls that we expect to see in this file so that
    // we know which ones have been deleted.
    var deleted_decls = std.AutoArrayHashMap(*Decl, void).init(self.gpa);
    defer deleted_decls.deinit();
    try deleted_decls.ensureCapacity(self.decl_table.items().len);
    for (self.decl_table.items()) |entry| {
        deleted_decls.putAssumeCapacityNoClobber(entry.value, {});
    }

    for (src_module.decls) |src_decl, decl_i| {
        const name_hash = root_scope.fullyQualifiedNameHash(src_decl.name);
        if (self.decl_table.get(name_hash)) |decl| {
            deleted_decls.removeAssertDiscard(decl);
            if (!srcHashEql(src_decl.contents_hash, decl.contents_hash)) {
                try self.markOutdatedDecl(decl);
                decl.contents_hash = src_decl.contents_hash;
            }
        } else {
            const new_decl = try self.createNewDecl(
                &root_scope.base,
                src_decl.name,
                decl_i,
                name_hash,
                src_decl.contents_hash,
            );
            root_scope.decls.appendAssumeCapacity(new_decl);
            if (src_decl.inst.cast(zir.Inst.Export)) |export_inst| {
                try exports_to_resolve.append(src_decl);
            }
        }
    }
    for (exports_to_resolve.items) |export_decl| {
        _ = try zir_sema.resolveZirDecl(self, &root_scope.base, export_decl);
    }
    // Handle explicitly deleted decls from the source code. Not to be confused
    // with when we delete decls because they are no longer referenced.
    for (deleted_decls.items()) |entry| {
        log.debug("noticed '{s}' deleted from source\n", .{entry.key.name});
        try self.deleteDecl(entry.key);
    }
}

pub fn deleteDecl(self: *Module, decl: *Decl) !void {
    try self.deletion_set.ensureCapacity(self.gpa, self.deletion_set.items.len + decl.dependencies.items().len);

    // Remove from the namespace it resides in. In the case of an anonymous Decl it will
    // not be present in the set, and this does nothing.
    decl.scope.removeDecl(decl);

    log.debug("deleting decl '{s}'\n", .{decl.name});
    const name_hash = decl.fullyQualifiedNameHash();
    self.decl_table.removeAssertDiscard(name_hash);
    // Remove itself from its dependencies, because we are about to destroy the decl pointer.
    for (decl.dependencies.items()) |entry| {
        const dep = entry.key;
        dep.removeDependant(decl);
        if (dep.dependants.items().len == 0 and !dep.deletion_flag) {
            // We don't recursively perform a deletion here, because during the update,
            // another reference to it may turn up.
            dep.deletion_flag = true;
            self.deletion_set.appendAssumeCapacity(dep);
        }
    }
    // Anything that depends on this deleted decl certainly needs to be re-analyzed.
    for (decl.dependants.items()) |entry| {
        const dep = entry.key;
        dep.removeDependency(decl);
        if (dep.analysis != .outdated) {
            // TODO Move this failure possibility to the top of the function.
            try self.markOutdatedDecl(dep);
        }
    }
    if (self.failed_decls.swapRemove(decl)) |entry| {
        entry.value.destroy(self.gpa);
    }
    if (self.emit_h_failed_decls.swapRemove(decl)) |entry| {
        entry.value.destroy(self.gpa);
    }
    if (self.compile_log_decls.swapRemove(decl)) |*entry| {
        entry.value.deinit(self.gpa);
    }
    self.deleteDeclExports(decl);
    self.comp.bin_file.freeDecl(decl);

    decl.destroy(self);
}

/// Delete all the Export objects that are caused by this Decl. Re-analysis of
/// this Decl will cause them to be re-created (or not).
fn deleteDeclExports(self: *Module, decl: *Decl) void {
    const kv = self.export_owners.swapRemove(decl) orelse return;

    for (kv.value) |exp| {
        if (self.decl_exports.getEntry(exp.exported_decl)) |decl_exports_kv| {
            // Remove exports with owner_decl matching the regenerating decl.
            const list = decl_exports_kv.value;
            var i: usize = 0;
            var new_len = list.len;
            while (i < new_len) {
                if (list[i].owner_decl == decl) {
                    mem.copyBackwards(*Export, list[i..], list[i + 1 .. new_len]);
                    new_len -= 1;
                } else {
                    i += 1;
                }
            }
            decl_exports_kv.value = self.gpa.shrink(list, new_len);
            if (new_len == 0) {
                self.decl_exports.removeAssertDiscard(exp.exported_decl);
            }
        }
        if (self.comp.bin_file.cast(link.File.Elf)) |elf| {
            elf.deleteExport(exp.link.elf);
        }
        if (self.comp.bin_file.cast(link.File.MachO)) |macho| {
            macho.deleteExport(exp.link.macho);
        }
        if (self.failed_exports.swapRemove(exp)) |entry| {
            entry.value.destroy(self.gpa);
        }
        _ = self.symbol_exports.swapRemove(exp.options.name);
        self.gpa.free(exp.options.name);
        self.gpa.destroy(exp);
    }
    self.gpa.free(kv.value);
}

pub fn analyzeFnBody(self: *Module, decl: *Decl, func: *Fn) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Use the Decl's arena for function memory.
    var arena = decl.typed_value.most_recent.arena.?.promote(self.gpa);
    defer decl.typed_value.most_recent.arena.?.* = arena.state;
    var inst_table = Scope.Block.InstTable.init(self.gpa);
    defer inst_table.deinit();
    var branch_quota: u32 = default_eval_branch_quota;

    var inner_block: Scope.Block = .{
        .parent = null,
        .inst_table = &inst_table,
        .func = func,
        .decl = decl,
        .instructions = .{},
        .arena = &arena.allocator,
        .inlining = null,
        .is_comptime = false,
        .branch_quota = &branch_quota,
    };
    defer inner_block.instructions.deinit(self.gpa);

    func.state = .in_progress;
    log.debug("set {s} to in_progress\n", .{decl.name});

    try zir_sema.analyzeBody(self, &inner_block, func.zir);

    const instructions = try arena.allocator.dupe(*Inst, inner_block.instructions.items);
    func.state = .success;
    func.body = .{ .instructions = instructions };
    log.debug("set {s} to success\n", .{decl.name});
}

fn markOutdatedDecl(self: *Module, decl: *Decl) !void {
    log.debug("mark {s} outdated\n", .{decl.name});
    try self.comp.work_queue.writeItem(.{ .analyze_decl = decl });
    if (self.failed_decls.swapRemove(decl)) |entry| {
        entry.value.destroy(self.gpa);
    }
    if (self.emit_h_failed_decls.swapRemove(decl)) |entry| {
        entry.value.destroy(self.gpa);
    }
    if (self.compile_log_decls.swapRemove(decl)) |*entry| {
        entry.value.deinit(self.gpa);
    }
    decl.analysis = .outdated;
}

fn allocateNewDecl(
    mod: *Module,
    scope: *Scope,
    src_index: usize,
    contents_hash: std.zig.SrcHash,
) !*Decl {
    // If we have emit-h then we must allocate a bigger structure to store the emit-h state.
    const new_decl: *Decl = if (mod.emit_h != null) blk: {
        const parent_struct = try mod.gpa.create(DeclPlusEmitH);
        parent_struct.* = .{
            .emit_h = .{},
            .decl = undefined,
        };
        break :blk &parent_struct.decl;
    } else try mod.gpa.create(Decl);

    new_decl.* = .{
        .name = "",
        .scope = scope.namespace(),
        .src_index = src_index,
        .typed_value = .{ .never_succeeded = {} },
        .analysis = .unreferenced,
        .deletion_flag = false,
        .contents_hash = contents_hash,
        .link = switch (mod.comp.bin_file.tag) {
            .coff => .{ .coff = link.File.Coff.TextBlock.empty },
            .elf => .{ .elf = link.File.Elf.TextBlock.empty },
            .macho => .{ .macho = link.File.MachO.TextBlock.empty },
            .c => .{ .c = link.File.C.DeclBlock.empty },
            .wasm => .{ .wasm = {} },
        },
        .fn_link = switch (mod.comp.bin_file.tag) {
            .coff => .{ .coff = {} },
            .elf => .{ .elf = link.File.Elf.SrcFn.empty },
            .macho => .{ .macho = link.File.MachO.SrcFn.empty },
            .c => .{ .c = link.File.C.FnBlock.empty },
            .wasm => .{ .wasm = null },
        },
        .generation = 0,
        .is_pub = false,
    };
    return new_decl;
}

fn createNewDecl(
    self: *Module,
    scope: *Scope,
    decl_name: []const u8,
    src_index: usize,
    name_hash: Scope.NameHash,
    contents_hash: std.zig.SrcHash,
) !*Decl {
    try self.decl_table.ensureCapacity(self.gpa, self.decl_table.items().len + 1);
    const new_decl = try self.allocateNewDecl(scope, src_index, contents_hash);
    errdefer self.gpa.destroy(new_decl);
    new_decl.name = try mem.dupeZ(self.gpa, u8, decl_name);
    self.decl_table.putAssumeCapacityNoClobber(name_hash, new_decl);
    return new_decl;
}

/// Get error value for error tag `name`.
pub fn getErrorValue(self: *Module, name: []const u8) !std.StringHashMapUnmanaged(u16).Entry {
    const gop = try self.global_error_set.getOrPut(self.gpa, name);
    if (gop.found_existing)
        return gop.entry.*;
    errdefer self.global_error_set.removeAssertDiscard(name);

    gop.entry.key = try self.gpa.dupe(u8, name);
    gop.entry.value = @intCast(u16, self.global_error_set.count() - 1);
    return gop.entry.*;
}

pub fn requireFunctionBlock(self: *Module, scope: *Scope, src: usize) !*Scope.Block {
    return scope.cast(Scope.Block) orelse
        return self.fail(scope, src, "instruction illegal outside function body", .{});
}

pub fn requireRuntimeBlock(self: *Module, scope: *Scope, src: usize) !*Scope.Block {
    const block = try self.requireFunctionBlock(scope, src);
    if (block.is_comptime) {
        return self.fail(scope, src, "unable to resolve comptime value", .{});
    }
    return block;
}

pub fn resolveConstValue(self: *Module, scope: *Scope, base: *Inst) !Value {
    return (try self.resolveDefinedValue(scope, base)) orelse
        return self.fail(scope, base.src, "unable to resolve comptime value", .{});
}

pub fn resolveDefinedValue(self: *Module, scope: *Scope, base: *Inst) !?Value {
    if (base.value()) |val| {
        if (val.isUndef()) {
            return self.fail(scope, base.src, "use of undefined value here causes undefined behavior", .{});
        }
        return val;
    }
    return null;
}

pub fn analyzeExport(
    self: *Module,
    scope: *Scope,
    src: usize,
    borrowed_symbol_name: []const u8,
    exported_decl: *Decl,
) !void {
    try self.ensureDeclAnalyzed(exported_decl);
    const typed_value = exported_decl.typed_value.most_recent.typed_value;
    switch (typed_value.ty.zigTypeTag()) {
        .Fn => {},
        else => return self.fail(scope, src, "unable to export type '{}'", .{typed_value.ty}),
    }

    try self.decl_exports.ensureCapacity(self.gpa, self.decl_exports.items().len + 1);
    try self.export_owners.ensureCapacity(self.gpa, self.export_owners.items().len + 1);

    const new_export = try self.gpa.create(Export);
    errdefer self.gpa.destroy(new_export);

    const symbol_name = try self.gpa.dupe(u8, borrowed_symbol_name);
    errdefer self.gpa.free(symbol_name);

    const owner_decl = scope.decl().?;

    new_export.* = .{
        .options = .{ .name = symbol_name },
        .src = src,
        .link = switch (self.comp.bin_file.tag) {
            .coff => .{ .coff = {} },
            .elf => .{ .elf = link.File.Elf.Export{} },
            .macho => .{ .macho = link.File.MachO.Export{} },
            .c => .{ .c = {} },
            .wasm => .{ .wasm = {} },
        },
        .owner_decl = owner_decl,
        .exported_decl = exported_decl,
        .status = .in_progress,
    };

    // Add to export_owners table.
    const eo_gop = self.export_owners.getOrPutAssumeCapacity(owner_decl);
    if (!eo_gop.found_existing) {
        eo_gop.entry.value = &[0]*Export{};
    }
    eo_gop.entry.value = try self.gpa.realloc(eo_gop.entry.value, eo_gop.entry.value.len + 1);
    eo_gop.entry.value[eo_gop.entry.value.len - 1] = new_export;
    errdefer eo_gop.entry.value = self.gpa.shrink(eo_gop.entry.value, eo_gop.entry.value.len - 1);

    // Add to exported_decl table.
    const de_gop = self.decl_exports.getOrPutAssumeCapacity(exported_decl);
    if (!de_gop.found_existing) {
        de_gop.entry.value = &[0]*Export{};
    }
    de_gop.entry.value = try self.gpa.realloc(de_gop.entry.value, de_gop.entry.value.len + 1);
    de_gop.entry.value[de_gop.entry.value.len - 1] = new_export;
    errdefer de_gop.entry.value = self.gpa.shrink(de_gop.entry.value, de_gop.entry.value.len - 1);

    if (self.symbol_exports.get(symbol_name)) |_| {
        try self.failed_exports.ensureCapacity(self.gpa, self.failed_exports.items().len + 1);
        self.failed_exports.putAssumeCapacityNoClobber(new_export, try Compilation.ErrorMsg.create(
            self.gpa,
            src,
            "exported symbol collision: {s}",
            .{symbol_name},
        ));
        // TODO: add a note
        new_export.status = .failed;
        return;
    }

    try self.symbol_exports.putNoClobber(self.gpa, symbol_name, new_export);
    self.comp.bin_file.updateDeclExports(self, exported_decl, de_gop.entry.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try self.failed_exports.ensureCapacity(self.gpa, self.failed_exports.items().len + 1);
            self.failed_exports.putAssumeCapacityNoClobber(new_export, try Compilation.ErrorMsg.create(
                self.gpa,
                src,
                "unable to export: {s}",
                .{@errorName(err)},
            ));
            new_export.status = .failed_retryable;
        },
    };
}

pub fn addNoOp(
    self: *Module,
    block: *Scope.Block,
    src: usize,
    ty: Type,
    comptime tag: Inst.Tag,
) !*Inst {
    const inst = try block.arena.create(tag.Type());
    inst.* = .{
        .base = .{
            .tag = tag,
            .ty = ty,
            .src = src,
        },
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addUnOp(
    self: *Module,
    block: *Scope.Block,
    src: usize,
    ty: Type,
    tag: Inst.Tag,
    operand: *Inst,
) !*Inst {
    const inst = try block.arena.create(Inst.UnOp);
    inst.* = .{
        .base = .{
            .tag = tag,
            .ty = ty,
            .src = src,
        },
        .operand = operand,
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addBinOp(
    self: *Module,
    block: *Scope.Block,
    src: usize,
    ty: Type,
    tag: Inst.Tag,
    lhs: *Inst,
    rhs: *Inst,
) !*Inst {
    const inst = try block.arena.create(Inst.BinOp);
    inst.* = .{
        .base = .{
            .tag = tag,
            .ty = ty,
            .src = src,
        },
        .lhs = lhs,
        .rhs = rhs,
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addArg(self: *Module, block: *Scope.Block, src: usize, ty: Type, name: [*:0]const u8) !*Inst {
    const inst = try block.arena.create(Inst.Arg);
    inst.* = .{
        .base = .{
            .tag = .arg,
            .ty = ty,
            .src = src,
        },
        .name = name,
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addBr(
    self: *Module,
    scope_block: *Scope.Block,
    src: usize,
    target_block: *Inst.Block,
    operand: *Inst,
) !*Inst {
    const inst = try scope_block.arena.create(Inst.Br);
    inst.* = .{
        .base = .{
            .tag = .br,
            .ty = Type.initTag(.noreturn),
            .src = src,
        },
        .operand = operand,
        .block = target_block,
    };
    try scope_block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addCondBr(
    self: *Module,
    block: *Scope.Block,
    src: usize,
    condition: *Inst,
    then_body: ir.Body,
    else_body: ir.Body,
) !*Inst {
    const inst = try block.arena.create(Inst.CondBr);
    inst.* = .{
        .base = .{
            .tag = .condbr,
            .ty = Type.initTag(.noreturn),
            .src = src,
        },
        .condition = condition,
        .then_body = then_body,
        .else_body = else_body,
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addCall(
    self: *Module,
    block: *Scope.Block,
    src: usize,
    ty: Type,
    func: *Inst,
    args: []const *Inst,
) !*Inst {
    const inst = try block.arena.create(Inst.Call);
    inst.* = .{
        .base = .{
            .tag = .call,
            .ty = ty,
            .src = src,
        },
        .func = func,
        .args = args,
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn addSwitchBr(
    self: *Module,
    block: *Scope.Block,
    src: usize,
    target_ptr: *Inst,
    cases: []Inst.SwitchBr.Case,
    else_body: ir.Body,
) !*Inst {
    const inst = try block.arena.create(Inst.SwitchBr);
    inst.* = .{
        .base = .{
            .tag = .switchbr,
            .ty = Type.initTag(.noreturn),
            .src = src,
        },
        .target_ptr = target_ptr,
        .cases = cases,
        .else_body = else_body,
    };
    try block.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn constInst(self: *Module, scope: *Scope, src: usize, typed_value: TypedValue) !*Inst {
    const const_inst = try scope.arena().create(Inst.Constant);
    const_inst.* = .{
        .base = .{
            .tag = Inst.Constant.base_tag,
            .ty = typed_value.ty,
            .src = src,
        },
        .val = typed_value.val,
    };
    return &const_inst.base;
}

pub fn constType(self: *Module, scope: *Scope, src: usize, ty: Type) !*Inst {
    return self.constInst(scope, src, .{
        .ty = Type.initTag(.type),
        .val = try ty.toValue(scope.arena()),
    });
}

pub fn constVoid(self: *Module, scope: *Scope, src: usize) !*Inst {
    return self.constInst(scope, src, .{
        .ty = Type.initTag(.void),
        .val = Value.initTag(.void_value),
    });
}

pub fn constNoReturn(self: *Module, scope: *Scope, src: usize) !*Inst {
    return self.constInst(scope, src, .{
        .ty = Type.initTag(.noreturn),
        .val = Value.initTag(.unreachable_value),
    });
}

pub fn constUndef(self: *Module, scope: *Scope, src: usize, ty: Type) !*Inst {
    return self.constInst(scope, src, .{
        .ty = ty,
        .val = Value.initTag(.undef),
    });
}

pub fn constBool(self: *Module, scope: *Scope, src: usize, v: bool) !*Inst {
    return self.constInst(scope, src, .{
        .ty = Type.initTag(.bool),
        .val = ([2]Value{ Value.initTag(.bool_false), Value.initTag(.bool_true) })[@boolToInt(v)],
    });
}

pub fn constIntUnsigned(self: *Module, scope: *Scope, src: usize, ty: Type, int: u64) !*Inst {
    return self.constInst(scope, src, .{
        .ty = ty,
        .val = try Value.Tag.int_u64.create(scope.arena(), int),
    });
}

pub fn constIntSigned(self: *Module, scope: *Scope, src: usize, ty: Type, int: i64) !*Inst {
    return self.constInst(scope, src, .{
        .ty = ty,
        .val = try Value.Tag.int_i64.create(scope.arena(), int),
    });
}

pub fn constIntBig(self: *Module, scope: *Scope, src: usize, ty: Type, big_int: BigIntConst) !*Inst {
    if (big_int.positive) {
        if (big_int.to(u64)) |x| {
            return self.constIntUnsigned(scope, src, ty, x);
        } else |err| switch (err) {
            error.NegativeIntoUnsigned => unreachable,
            error.TargetTooSmall => {}, // handled below
        }
        return self.constInst(scope, src, .{
            .ty = ty,
            .val = try Value.Tag.int_big_positive.create(scope.arena(), big_int.limbs),
        });
    } else {
        if (big_int.to(i64)) |x| {
            return self.constIntSigned(scope, src, ty, x);
        } else |err| switch (err) {
            error.NegativeIntoUnsigned => unreachable,
            error.TargetTooSmall => {}, // handled below
        }
        return self.constInst(scope, src, .{
            .ty = ty,
            .val = try Value.Tag.int_big_negative.create(scope.arena(), big_int.limbs),
        });
    }
}

pub fn createAnonymousDecl(
    self: *Module,
    scope: *Scope,
    decl_arena: *std.heap.ArenaAllocator,
    typed_value: TypedValue,
) !*Decl {
    const name_index = self.getNextAnonNameIndex();
    const scope_decl = scope.decl().?;
    const name = try std.fmt.allocPrint(self.gpa, "{s}__anon_{d}", .{ scope_decl.name, name_index });
    defer self.gpa.free(name);
    const name_hash = scope.namespace().fullyQualifiedNameHash(name);
    const src_hash: std.zig.SrcHash = undefined;
    const new_decl = try self.createNewDecl(scope, name, scope_decl.src_index, name_hash, src_hash);
    const decl_arena_state = try decl_arena.allocator.create(std.heap.ArenaAllocator.State);

    decl_arena_state.* = decl_arena.state;
    new_decl.typed_value = .{
        .most_recent = .{
            .typed_value = typed_value,
            .arena = decl_arena_state,
        },
    };
    new_decl.analysis = .complete;
    new_decl.generation = self.generation;

    // TODO: This generates the Decl into the machine code file if it is of a type that is non-zero size.
    // We should be able to further improve the compiler to not omit Decls which are only referenced at
    // compile-time and not runtime.
    if (typed_value.ty.hasCodeGenBits()) {
        try self.comp.bin_file.allocateDeclIndexes(new_decl);
        try self.comp.work_queue.writeItem(.{ .codegen_decl = new_decl });
    }

    return new_decl;
}

fn getNextAnonNameIndex(self: *Module) usize {
    return @atomicRmw(usize, &self.next_anon_name_index, .Add, 1, .Monotonic);
}

pub fn lookupDeclName(self: *Module, scope: *Scope, ident_name: []const u8) ?*Decl {
    const namespace = scope.namespace();
    const name_hash = namespace.fullyQualifiedNameHash(ident_name);
    return self.decl_table.get(name_hash);
}

pub fn analyzeDeclRef(self: *Module, scope: *Scope, src: usize, decl: *Decl) InnerError!*Inst {
    const scope_decl = scope.decl().?;
    try self.declareDeclDependency(scope_decl, decl);
    self.ensureDeclAnalyzed(decl) catch |err| {
        if (scope.cast(Scope.Block)) |block| {
            if (block.func) |func| {
                func.state = .dependency_failure;
            } else {
                block.decl.analysis = .dependency_failure;
            }
        } else {
            scope_decl.analysis = .dependency_failure;
        }
        return err;
    };

    const decl_tv = try decl.typedValue();
    if (decl_tv.val.tag() == .variable) {
        return self.analyzeVarRef(scope, src, decl_tv);
    }
    return self.constInst(scope, src, .{
        .ty = try self.simplePtrType(scope, src, decl_tv.ty, false, .One),
        .val = try Value.Tag.decl_ref.create(scope.arena(), decl),
    });
}

fn analyzeVarRef(self: *Module, scope: *Scope, src: usize, tv: TypedValue) InnerError!*Inst {
    const variable = tv.val.castTag(.variable).?.data;

    const ty = try self.simplePtrType(scope, src, tv.ty, variable.is_mutable, .One);
    if (!variable.is_mutable and !variable.is_extern) {
        return self.constInst(scope, src, .{
            .ty = ty,
            .val = try Value.Tag.ref_val.create(scope.arena(), variable.init),
        });
    }

    const b = try self.requireRuntimeBlock(scope, src);
    const inst = try b.arena.create(Inst.VarPtr);
    inst.* = .{
        .base = .{
            .tag = .varptr,
            .ty = ty,
            .src = src,
        },
        .variable = variable,
    };
    try b.instructions.append(self.gpa, &inst.base);
    return &inst.base;
}

pub fn analyzeDeref(self: *Module, scope: *Scope, src: usize, ptr: *Inst, ptr_src: usize) InnerError!*Inst {
    const elem_ty = switch (ptr.ty.zigTypeTag()) {
        .Pointer => ptr.ty.elemType(),
        else => return self.fail(scope, ptr_src, "expected pointer, found '{}'", .{ptr.ty}),
    };
    if (ptr.value()) |val| {
        return self.constInst(scope, src, .{
            .ty = elem_ty,
            .val = try val.pointerDeref(scope.arena()),
        });
    }

    const b = try self.requireRuntimeBlock(scope, src);
    return self.addUnOp(b, src, elem_ty, .load, ptr);
}

pub fn analyzeDeclRefByName(self: *Module, scope: *Scope, src: usize, decl_name: []const u8) InnerError!*Inst {
    const decl = self.lookupDeclName(scope, decl_name) orelse
        return self.fail(scope, src, "decl '{s}' not found", .{decl_name});
    return self.analyzeDeclRef(scope, src, decl);
}

pub fn wantSafety(self: *Module, scope: *Scope) bool {
    // TODO take into account scope's safety overrides
    return switch (self.optimizeMode()) {
        .Debug => true,
        .ReleaseSafe => true,
        .ReleaseFast => false,
        .ReleaseSmall => false,
    };
}

pub fn analyzeIsNull(
    self: *Module,
    scope: *Scope,
    src: usize,
    operand: *Inst,
    invert_logic: bool,
) InnerError!*Inst {
    if (operand.value()) |opt_val| {
        const is_null = opt_val.isNull();
        const bool_value = if (invert_logic) !is_null else is_null;
        return self.constBool(scope, src, bool_value);
    }
    const b = try self.requireRuntimeBlock(scope, src);
    const inst_tag: Inst.Tag = if (invert_logic) .isnonnull else .isnull;
    return self.addUnOp(b, src, Type.initTag(.bool), inst_tag, operand);
}

pub fn analyzeIsErr(self: *Module, scope: *Scope, src: usize, operand: *Inst) InnerError!*Inst {
    return self.fail(scope, src, "TODO implement analysis of iserr", .{});
}

pub fn analyzeSlice(self: *Module, scope: *Scope, src: usize, array_ptr: *Inst, start: *Inst, end_opt: ?*Inst, sentinel_opt: ?*Inst) InnerError!*Inst {
    const ptr_child = switch (array_ptr.ty.zigTypeTag()) {
        .Pointer => array_ptr.ty.elemType(),
        else => return self.fail(scope, src, "expected pointer, found '{}'", .{array_ptr.ty}),
    };

    var array_type = ptr_child;
    const elem_type = switch (ptr_child.zigTypeTag()) {
        .Array => ptr_child.elemType(),
        .Pointer => blk: {
            if (ptr_child.isSinglePointer()) {
                if (ptr_child.elemType().zigTypeTag() == .Array) {
                    array_type = ptr_child.elemType();
                    break :blk ptr_child.elemType().elemType();
                }

                return self.fail(scope, src, "slice of single-item pointer", .{});
            }
            break :blk ptr_child.elemType();
        },
        else => return self.fail(scope, src, "slice of non-array type '{}'", .{ptr_child}),
    };

    const slice_sentinel = if (sentinel_opt) |sentinel| blk: {
        const casted = try self.coerce(scope, elem_type, sentinel);
        break :blk try self.resolveConstValue(scope, casted);
    } else null;

    var return_ptr_size: std.builtin.TypeInfo.Pointer.Size = .Slice;
    var return_elem_type = elem_type;
    if (end_opt) |end| {
        if (end.value()) |end_val| {
            if (start.value()) |start_val| {
                const start_u64 = start_val.toUnsignedInt();
                const end_u64 = end_val.toUnsignedInt();
                if (start_u64 > end_u64) {
                    return self.fail(scope, src, "out of bounds slice", .{});
                }

                const len = end_u64 - start_u64;
                const array_sentinel = if (array_type.zigTypeTag() == .Array and end_u64 == array_type.arrayLen())
                    array_type.sentinel()
                else
                    slice_sentinel;
                return_elem_type = try self.arrayType(scope, len, array_sentinel, elem_type);
                return_ptr_size = .One;
            }
        }
    }
    const return_type = try self.ptrType(
        scope,
        src,
        return_elem_type,
        if (end_opt == null) slice_sentinel else null,
        0, // TODO alignment
        0,
        0,
        !ptr_child.isConstPtr(),
        ptr_child.isAllowzeroPtr(),
        ptr_child.isVolatilePtr(),
        return_ptr_size,
    );

    return self.fail(scope, src, "TODO implement analysis of slice", .{});
}

pub fn analyzeImport(self: *Module, scope: *Scope, src: usize, target_string: []const u8) !*Scope.File {
    const cur_pkg = scope.getOwnerPkg();
    const cur_pkg_dir_path = cur_pkg.root_src_directory.path orelse ".";
    const found_pkg = cur_pkg.table.get(target_string);

    const resolved_path = if (found_pkg) |pkg|
        try std.fs.path.resolve(self.gpa, &[_][]const u8{ pkg.root_src_directory.path orelse ".", pkg.root_src_path })
    else
        try std.fs.path.resolve(self.gpa, &[_][]const u8{ cur_pkg_dir_path, target_string });
    errdefer self.gpa.free(resolved_path);

    if (self.import_table.get(resolved_path)) |some| {
        self.gpa.free(resolved_path);
        return some;
    }

    if (found_pkg == null) {
        const resolved_root_path = try std.fs.path.resolve(self.gpa, &[_][]const u8{cur_pkg_dir_path});
        defer self.gpa.free(resolved_root_path);

        if (!mem.startsWith(u8, resolved_path, resolved_root_path)) {
            return error.ImportOutsidePkgPath;
        }
    }

    // TODO Scope.Container arena for ty and sub_file_path
    const file_scope = try self.gpa.create(Scope.File);
    errdefer self.gpa.destroy(file_scope);
    const struct_ty = try Type.Tag.empty_struct.create(self.gpa, &file_scope.root_container);
    errdefer self.gpa.destroy(struct_ty.castTag(.empty_struct).?);

    file_scope.* = .{
        .sub_file_path = resolved_path,
        .source = .{ .unloaded = {} },
        .contents = .{ .not_available = {} },
        .status = .never_loaded,
        .pkg = found_pkg orelse cur_pkg,
        .root_container = .{
            .file_scope = file_scope,
            .decls = .{},
            .ty = struct_ty,
        },
    };
    self.analyzeContainer(&file_scope.root_container) catch |err| switch (err) {
        error.AnalysisFail => {
            assert(self.comp.totalErrorCount() != 0);
        },
        else => |e| return e,
    };
    try self.import_table.put(self.gpa, file_scope.sub_file_path, file_scope);
    return file_scope;
}

/// Asserts that lhs and rhs types are both numeric.
pub fn cmpNumeric(
    self: *Module,
    scope: *Scope,
    src: usize,
    lhs: *Inst,
    rhs: *Inst,
    op: std.math.CompareOperator,
) InnerError!*Inst {
    assert(lhs.ty.isNumeric());
    assert(rhs.ty.isNumeric());

    const lhs_ty_tag = lhs.ty.zigTypeTag();
    const rhs_ty_tag = rhs.ty.zigTypeTag();

    if (lhs_ty_tag == .Vector and rhs_ty_tag == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return self.fail(scope, src, "vector length mismatch: {d} and {d}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return self.fail(scope, src, "TODO implement support for vectors in cmpNumeric", .{});
    } else if (lhs_ty_tag == .Vector or rhs_ty_tag == .Vector) {
        return self.fail(scope, src, "mixed scalar and vector operands to comparison operator: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    if (lhs.value()) |lhs_val| {
        if (rhs.value()) |rhs_val| {
            return self.constBool(scope, src, Value.compare(lhs_val, op, rhs_val));
        }
    }

    // TODO handle comparisons against lazy zero values
    // Some values can be compared against zero without being runtime known or without forcing
    // a full resolution of their value, for example `@sizeOf(@Frame(function))` is known to
    // always be nonzero, and we benefit from not forcing the full evaluation and stack frame layout
    // of this function if we don't need to.

    // It must be a runtime comparison.
    const b = try self.requireRuntimeBlock(scope, src);
    // For floats, emit a float comparison instruction.
    const lhs_is_float = switch (lhs_ty_tag) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
    const rhs_is_float = switch (rhs_ty_tag) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
    if (lhs_is_float and rhs_is_float) {
        // Implicit cast the smaller one to the larger one.
        const dest_type = x: {
            if (lhs_ty_tag == .ComptimeFloat) {
                break :x rhs.ty;
            } else if (rhs_ty_tag == .ComptimeFloat) {
                break :x lhs.ty;
            }
            if (lhs.ty.floatBits(self.getTarget()) >= rhs.ty.floatBits(self.getTarget())) {
                break :x lhs.ty;
            } else {
                break :x rhs.ty;
            }
        };
        const casted_lhs = try self.coerce(scope, dest_type, lhs);
        const casted_rhs = try self.coerce(scope, dest_type, rhs);
        return self.addBinOp(b, src, dest_type, Inst.Tag.fromCmpOp(op), casted_lhs, casted_rhs);
    }
    // For mixed unsigned integer sizes, implicit cast both operands to the larger integer.
    // For mixed signed and unsigned integers, implicit cast both operands to a signed
    // integer with + 1 bit.
    // For mixed floats and integers, extract the integer part from the float, cast that to
    // a signed integer with mantissa bits + 1, and if there was any non-integral part of the float,
    // add/subtract 1.
    const lhs_is_signed = if (lhs.value()) |lhs_val|
        lhs_val.compareWithZero(.lt)
    else
        (lhs.ty.isFloat() or lhs.ty.isSignedInt());
    const rhs_is_signed = if (rhs.value()) |rhs_val|
        rhs_val.compareWithZero(.lt)
    else
        (rhs.ty.isFloat() or rhs.ty.isSignedInt());
    const dest_int_is_signed = lhs_is_signed or rhs_is_signed;

    var dest_float_type: ?Type = null;

    var lhs_bits: usize = undefined;
    if (lhs.value()) |lhs_val| {
        if (lhs_val.isUndef())
            return self.constUndef(scope, src, Type.initTag(.bool));
        const is_unsigned = if (lhs_is_float) x: {
            var bigint_space: Value.BigIntSpace = undefined;
            var bigint = try lhs_val.toBigInt(&bigint_space).toManaged(self.gpa);
            defer bigint.deinit();
            const zcmp = lhs_val.orderAgainstZero();
            if (lhs_val.floatHasFraction()) {
                switch (op) {
                    .eq => return self.constBool(scope, src, false),
                    .neq => return self.constBool(scope, src, true),
                    else => {},
                }
                if (zcmp == .lt) {
                    try bigint.addScalar(bigint.toConst(), -1);
                } else {
                    try bigint.addScalar(bigint.toConst(), 1);
                }
            }
            lhs_bits = bigint.toConst().bitCountTwosComp();
            break :x (zcmp != .lt);
        } else x: {
            lhs_bits = lhs_val.intBitCountTwosComp();
            break :x (lhs_val.orderAgainstZero() != .lt);
        };
        lhs_bits += @boolToInt(is_unsigned and dest_int_is_signed);
    } else if (lhs_is_float) {
        dest_float_type = lhs.ty;
    } else {
        const int_info = lhs.ty.intInfo(self.getTarget());
        lhs_bits = int_info.bits + @boolToInt(int_info.signedness == .unsigned and dest_int_is_signed);
    }

    var rhs_bits: usize = undefined;
    if (rhs.value()) |rhs_val| {
        if (rhs_val.isUndef())
            return self.constUndef(scope, src, Type.initTag(.bool));
        const is_unsigned = if (rhs_is_float) x: {
            var bigint_space: Value.BigIntSpace = undefined;
            var bigint = try rhs_val.toBigInt(&bigint_space).toManaged(self.gpa);
            defer bigint.deinit();
            const zcmp = rhs_val.orderAgainstZero();
            if (rhs_val.floatHasFraction()) {
                switch (op) {
                    .eq => return self.constBool(scope, src, false),
                    .neq => return self.constBool(scope, src, true),
                    else => {},
                }
                if (zcmp == .lt) {
                    try bigint.addScalar(bigint.toConst(), -1);
                } else {
                    try bigint.addScalar(bigint.toConst(), 1);
                }
            }
            rhs_bits = bigint.toConst().bitCountTwosComp();
            break :x (zcmp != .lt);
        } else x: {
            rhs_bits = rhs_val.intBitCountTwosComp();
            break :x (rhs_val.orderAgainstZero() != .lt);
        };
        rhs_bits += @boolToInt(is_unsigned and dest_int_is_signed);
    } else if (rhs_is_float) {
        dest_float_type = rhs.ty;
    } else {
        const int_info = rhs.ty.intInfo(self.getTarget());
        rhs_bits = int_info.bits + @boolToInt(int_info.signedness == .unsigned and dest_int_is_signed);
    }

    const dest_type = if (dest_float_type) |ft| ft else blk: {
        const max_bits = std.math.max(lhs_bits, rhs_bits);
        const casted_bits = std.math.cast(u16, max_bits) catch |err| switch (err) {
            error.Overflow => return self.fail(scope, src, "{d} exceeds maximum integer bit count", .{max_bits}),
        };
        break :blk try self.makeIntType(scope, dest_int_is_signed, casted_bits);
    };
    const casted_lhs = try self.coerce(scope, dest_type, lhs);
    const casted_rhs = try self.coerce(scope, dest_type, rhs);

    return self.addBinOp(b, src, Type.initTag(.bool), Inst.Tag.fromCmpOp(op), casted_lhs, casted_rhs);
}

fn wrapOptional(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }

    const b = try self.requireRuntimeBlock(scope, inst.src);
    return self.addUnOp(b, inst.src, dest_type, .wrap_optional, inst);
}

fn makeIntType(self: *Module, scope: *Scope, signed: bool, bits: u16) !Type {
    const int_payload = try scope.arena().create(Type.Payload.Bits);
    int_payload.* = .{
        .base = .{
            .tag = if (signed) .int_signed else .int_unsigned,
        },
        .data = bits,
    };
    return Type.initPayload(&int_payload.base);
}

pub fn resolvePeerTypes(self: *Module, scope: *Scope, instructions: []*Inst) !Type {
    if (instructions.len == 0)
        return Type.initTag(.noreturn);

    if (instructions.len == 1)
        return instructions[0].ty;

    var chosen = instructions[0];
    for (instructions[1..]) |candidate| {
        if (candidate.ty.eql(chosen.ty))
            continue;
        if (candidate.ty.zigTypeTag() == .NoReturn)
            continue;
        if (chosen.ty.zigTypeTag() == .NoReturn) {
            chosen = candidate;
            continue;
        }
        if (candidate.ty.zigTypeTag() == .Undefined)
            continue;
        if (chosen.ty.zigTypeTag() == .Undefined) {
            chosen = candidate;
            continue;
        }
        if (chosen.ty.isInt() and
            candidate.ty.isInt() and
            chosen.ty.isSignedInt() == candidate.ty.isSignedInt())
        {
            if (chosen.ty.intInfo(self.getTarget()).bits < candidate.ty.intInfo(self.getTarget()).bits) {
                chosen = candidate;
            }
            continue;
        }
        if (chosen.ty.isFloat() and candidate.ty.isFloat()) {
            if (chosen.ty.floatBits(self.getTarget()) < candidate.ty.floatBits(self.getTarget())) {
                chosen = candidate;
            }
            continue;
        }

        if (chosen.ty.zigTypeTag() == .ComptimeInt and candidate.ty.isInt()) {
            chosen = candidate;
            continue;
        }

        if (chosen.ty.isInt() and candidate.ty.zigTypeTag() == .ComptimeInt) {
            continue;
        }

        // TODO error notes pointing out each type
        return self.fail(scope, candidate.src, "incompatible types: '{}' and '{}'", .{ chosen.ty, candidate.ty });
    }

    return chosen.ty;
}

pub fn coerce(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
    // If the types are the same, we can return the operand.
    if (dest_type.eql(inst.ty))
        return inst;

    const in_memory_result = coerceInMemoryAllowed(dest_type, inst.ty);
    if (in_memory_result == .ok) {
        return self.bitcast(scope, dest_type, inst);
    }

    // undefined to anything
    if (inst.value()) |val| {
        if (val.isUndef() or inst.ty.zigTypeTag() == .Undefined) {
            return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
        }
    }
    assert(inst.ty.zigTypeTag() != .Undefined);

    // null to ?T
    if (dest_type.zigTypeTag() == .Optional and inst.ty.zigTypeTag() == .Null) {
        return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = Value.initTag(.null_value) });
    }

    // T to ?T
    if (dest_type.zigTypeTag() == .Optional) {
        var buf: Type.Payload.ElemType = undefined;
        const child_type = dest_type.optionalChild(&buf);
        if (child_type.eql(inst.ty)) {
            return self.wrapOptional(scope, dest_type, inst);
        } else if (try self.coerceNum(scope, child_type, inst)) |some| {
            return self.wrapOptional(scope, dest_type, some);
        }
    }

    // Coercions where the source is a single pointer to an array.
    src_array_ptr: {
        if (!inst.ty.isSinglePointer()) break :src_array_ptr;
        const array_type = inst.ty.elemType();
        if (array_type.zigTypeTag() != .Array) break :src_array_ptr;
        const array_elem_type = array_type.elemType();
        if (inst.ty.isConstPtr() and !dest_type.isConstPtr()) break :src_array_ptr;
        if (inst.ty.isVolatilePtr() and !dest_type.isVolatilePtr()) break :src_array_ptr;

        const dst_elem_type = dest_type.elemType();
        switch (coerceInMemoryAllowed(dst_elem_type, array_elem_type)) {
            .ok => {},
            .no_match => break :src_array_ptr,
        }

        switch (dest_type.ptrSize()) {
            .Slice => {
                // *[N]T to []T
                return self.coerceArrayPtrToSlice(scope, dest_type, inst);
            },
            .C => {
                // *[N]T to [*c]T
                return self.coerceArrayPtrToMany(scope, dest_type, inst);
            },
            .Many => {
                // *[N]T to [*]T
                // *[N:s]T to [*:s]T
                const src_sentinel = array_type.sentinel();
                const dst_sentinel = dest_type.sentinel();
                if (src_sentinel == null and dst_sentinel == null)
                    return self.coerceArrayPtrToMany(scope, dest_type, inst);

                if (src_sentinel) |src_s| {
                    if (dst_sentinel) |dst_s| {
                        if (src_s.eql(dst_s)) {
                            return self.coerceArrayPtrToMany(scope, dest_type, inst);
                        }
                    }
                }
            },
            .One => {},
        }
    }

    // comptime known number to other number
    if (try self.coerceNum(scope, dest_type, inst)) |some|
        return some;

    // integer widening
    if (inst.ty.zigTypeTag() == .Int and dest_type.zigTypeTag() == .Int) {
        assert(inst.value() == null); // handled above

        const src_info = inst.ty.intInfo(self.getTarget());
        const dst_info = dest_type.intInfo(self.getTarget());
        if ((src_info.signedness == dst_info.signedness and dst_info.bits >= src_info.bits) or
            // small enough unsigned ints can get casted to large enough signed ints
            (src_info.signedness == .signed and dst_info.signedness == .unsigned and dst_info.bits > src_info.bits))
        {
            const b = try self.requireRuntimeBlock(scope, inst.src);
            return self.addUnOp(b, inst.src, dest_type, .intcast, inst);
        }
    }

    // float widening
    if (inst.ty.zigTypeTag() == .Float and dest_type.zigTypeTag() == .Float) {
        assert(inst.value() == null); // handled above

        const src_bits = inst.ty.floatBits(self.getTarget());
        const dst_bits = dest_type.floatBits(self.getTarget());
        if (dst_bits >= src_bits) {
            const b = try self.requireRuntimeBlock(scope, inst.src);
            return self.addUnOp(b, inst.src, dest_type, .floatcast, inst);
        }
    }

    return self.fail(scope, inst.src, "expected {}, found {}", .{ dest_type, inst.ty });
}

pub fn coerceNum(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !?*Inst {
    const val = inst.value() orelse return null;
    const src_zig_tag = inst.ty.zigTypeTag();
    const dst_zig_tag = dest_type.zigTypeTag();

    if (dst_zig_tag == .ComptimeInt or dst_zig_tag == .Int) {
        if (src_zig_tag == .Float or src_zig_tag == .ComptimeFloat) {
            if (val.floatHasFraction()) {
                return self.fail(scope, inst.src, "fractional component prevents float value {} from being casted to type '{}'", .{ val, inst.ty });
            }
            return self.fail(scope, inst.src, "TODO float to int", .{});
        } else if (src_zig_tag == .Int or src_zig_tag == .ComptimeInt) {
            if (!val.intFitsInType(dest_type, self.getTarget())) {
                return self.fail(scope, inst.src, "type {} cannot represent integer value {}", .{ inst.ty, val });
            }
            return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
        }
    } else if (dst_zig_tag == .ComptimeFloat or dst_zig_tag == .Float) {
        if (src_zig_tag == .Float or src_zig_tag == .ComptimeFloat) {
            const res = val.floatCast(scope.arena(), dest_type, self.getTarget()) catch |err| switch (err) {
                error.Overflow => return self.fail(
                    scope,
                    inst.src,
                    "cast of value {} to type '{}' loses information",
                    .{ val, dest_type },
                ),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = res });
        } else if (src_zig_tag == .Int or src_zig_tag == .ComptimeInt) {
            return self.fail(scope, inst.src, "TODO int to float", .{});
        }
    }
    return null;
}

pub fn storePtr(self: *Module, scope: *Scope, src: usize, ptr: *Inst, uncasted_value: *Inst) !*Inst {
    if (ptr.ty.isConstPtr())
        return self.fail(scope, src, "cannot assign to constant", .{});

    const elem_ty = ptr.ty.elemType();
    const value = try self.coerce(scope, elem_ty, uncasted_value);
    if (elem_ty.onePossibleValue() != null)
        return self.constVoid(scope, src);

    // TODO handle comptime pointer writes
    // TODO handle if the element type requires comptime

    const b = try self.requireRuntimeBlock(scope, src);
    return self.addBinOp(b, src, Type.initTag(.void), .store, ptr, value);
}

pub fn bitcast(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // Keep the comptime Value representation; take the new type.
        return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }
    // TODO validate the type size and other compile errors
    const b = try self.requireRuntimeBlock(scope, inst.src);
    return self.addUnOp(b, inst.src, dest_type, .bitcast, inst);
}

fn coerceArrayPtrToSlice(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // The comptime Value representation is compatible with both types.
        return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }
    return self.fail(scope, inst.src, "TODO implement coerceArrayPtrToSlice runtime instruction", .{});
}

fn coerceArrayPtrToMany(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // The comptime Value representation is compatible with both types.
        return self.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }
    return self.fail(scope, inst.src, "TODO implement coerceArrayPtrToMany runtime instruction", .{});
}

pub fn fail(self: *Module, scope: *Scope, src: usize, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    const err_msg = try Compilation.ErrorMsg.create(self.gpa, src, format, args);
    return self.failWithOwnedErrorMsg(scope, src, err_msg);
}

pub fn failTok(
    self: *Module,
    scope: *Scope,
    token_index: ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    @setCold(true);
    const src = scope.tree().token_locs[token_index].start;
    return self.fail(scope, src, format, args);
}

pub fn failNode(
    self: *Module,
    scope: *Scope,
    ast_node: *ast.Node,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    @setCold(true);
    const src = scope.tree().token_locs[ast_node.firstToken()].start;
    return self.fail(scope, src, format, args);
}

fn addCompileLog(self: *Module, decl: *Decl, src: usize) error{OutOfMemory}!void {
    const entry = try self.compile_log_decls.getOrPutValue(self.gpa, decl, .{});
    try entry.value.append(self.gpa, src);
}

pub fn failCompileLog(
    self: *Module,
    scope: *Scope,
    src: usize,
) InnerError!void {
    switch (scope.tag) {
        .decl => {
            const decl = scope.cast(Scope.DeclAnalysis).?.decl;
            try self.addCompileLog(decl, src);
        },
        .block => {
            const block = scope.cast(Scope.Block).?;
            try self.addCompileLog(block.decl, src);
        },
        .gen_zir => {
            const gen_zir = scope.cast(Scope.GenZIR).?;
            try self.addCompileLog(gen_zir.decl, src);
        },
        .local_val => {
            const gen_zir = scope.cast(Scope.LocalVal).?.gen_zir;
            try self.addCompileLog(gen_zir.decl, src);
        },
        .local_ptr => {
            const gen_zir = scope.cast(Scope.LocalPtr).?.gen_zir;
            try self.addCompileLog(gen_zir.decl, src);
        },
        .zir_module,
        .file,
        .container,
        => unreachable,
    }
}

fn failWithOwnedErrorMsg(self: *Module, scope: *Scope, src: usize, err_msg: *Compilation.ErrorMsg) InnerError {
    {
        errdefer err_msg.destroy(self.gpa);
        try self.failed_decls.ensureCapacity(self.gpa, self.failed_decls.items().len + 1);
        try self.failed_files.ensureCapacity(self.gpa, self.failed_files.items().len + 1);
    }
    switch (scope.tag) {
        .decl => {
            const decl = scope.cast(Scope.DeclAnalysis).?.decl;
            decl.analysis = .sema_failure;
            decl.generation = self.generation;
            self.failed_decls.putAssumeCapacityNoClobber(decl, err_msg);
        },
        .block => {
            const block = scope.cast(Scope.Block).?;
            if (block.inlining) |inlining| {
                if (inlining.shared.caller) |func| {
                    func.state = .sema_failure;
                } else {
                    block.decl.analysis = .sema_failure;
                    block.decl.generation = self.generation;
                }
            } else {
                if (block.func) |func| {
                    func.state = .sema_failure;
                } else {
                    block.decl.analysis = .sema_failure;
                    block.decl.generation = self.generation;
                }
            }
            self.failed_decls.putAssumeCapacityNoClobber(block.decl, err_msg);
        },
        .gen_zir => {
            const gen_zir = scope.cast(Scope.GenZIR).?;
            gen_zir.decl.analysis = .sema_failure;
            gen_zir.decl.generation = self.generation;
            self.failed_decls.putAssumeCapacityNoClobber(gen_zir.decl, err_msg);
        },
        .local_val => {
            const gen_zir = scope.cast(Scope.LocalVal).?.gen_zir;
            gen_zir.decl.analysis = .sema_failure;
            gen_zir.decl.generation = self.generation;
            self.failed_decls.putAssumeCapacityNoClobber(gen_zir.decl, err_msg);
        },
        .local_ptr => {
            const gen_zir = scope.cast(Scope.LocalPtr).?.gen_zir;
            gen_zir.decl.analysis = .sema_failure;
            gen_zir.decl.generation = self.generation;
            self.failed_decls.putAssumeCapacityNoClobber(gen_zir.decl, err_msg);
        },
        .zir_module => {
            const zir_module = scope.cast(Scope.ZIRModule).?;
            zir_module.status = .loaded_sema_failure;
            self.failed_files.putAssumeCapacityNoClobber(scope, err_msg);
        },
        .file => unreachable,
        .container => unreachable,
    }
    return error.AnalysisFail;
}

const InMemoryCoercionResult = enum {
    ok,
    no_match,
};

fn coerceInMemoryAllowed(dest_type: Type, src_type: Type) InMemoryCoercionResult {
    if (dest_type.eql(src_type))
        return .ok;

    // TODO: implement more of this function

    return .no_match;
}

fn srcHashEql(a: std.zig.SrcHash, b: std.zig.SrcHash) bool {
    return @bitCast(u128, a) == @bitCast(u128, b);
}

pub fn intAdd(allocator: *Allocator, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space);
    const rhs_bigint = rhs.toBigInt(&rhs_space);
    const limbs = try allocator.alloc(
        std.math.big.Limb,
        std.math.max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
    );
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.add(lhs_bigint, rhs_bigint);
    const result_limbs = result_bigint.limbs[0..result_bigint.len];

    if (result_bigint.positive) {
        return Value.Tag.int_big_positive.create(allocator, result_limbs);
    } else {
        return Value.Tag.int_big_negative.create(allocator, result_limbs);
    }
}

pub fn intSub(allocator: *Allocator, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space);
    const rhs_bigint = rhs.toBigInt(&rhs_space);
    const limbs = try allocator.alloc(
        std.math.big.Limb,
        std.math.max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
    );
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.sub(lhs_bigint, rhs_bigint);
    const result_limbs = result_bigint.limbs[0..result_bigint.len];

    if (result_bigint.positive) {
        return Value.Tag.int_big_positive.create(allocator, result_limbs);
    } else {
        return Value.Tag.int_big_negative.create(allocator, result_limbs);
    }
}

pub fn floatAdd(
    self: *Module,
    scope: *Scope,
    float_type: Type,
    src: usize,
    lhs: Value,
    rhs: Value,
) !Value {
    const arena = scope.arena();
    switch (float_type.tag()) {
        .f16 => {
            @panic("TODO add __trunctfhf2 to compiler-rt");
            //const lhs_val = lhs.toFloat(f16);
            //const rhs_val = rhs.toFloat(f16);
            //return Value.Tag.float_16.create(arena, lhs_val + rhs_val);
        },
        .f32 => {
            const lhs_val = lhs.toFloat(f32);
            const rhs_val = rhs.toFloat(f32);
            return Value.Tag.float_32.create(arena, lhs_val + rhs_val);
        },
        .f64 => {
            const lhs_val = lhs.toFloat(f64);
            const rhs_val = rhs.toFloat(f64);
            return Value.Tag.float_64.create(arena, lhs_val + rhs_val);
        },
        .f128, .comptime_float, .c_longdouble => {
            const lhs_val = lhs.toFloat(f128);
            const rhs_val = rhs.toFloat(f128);
            return Value.Tag.float_128.create(arena, lhs_val + rhs_val);
        },
        else => unreachable,
    }
}

pub fn floatSub(
    self: *Module,
    scope: *Scope,
    float_type: Type,
    src: usize,
    lhs: Value,
    rhs: Value,
) !Value {
    const arena = scope.arena();
    switch (float_type.tag()) {
        .f16 => {
            @panic("TODO add __trunctfhf2 to compiler-rt");
            //const lhs_val = lhs.toFloat(f16);
            //const rhs_val = rhs.toFloat(f16);
            //return Value.Tag.float_16.create(arena, lhs_val - rhs_val);
        },
        .f32 => {
            const lhs_val = lhs.toFloat(f32);
            const rhs_val = rhs.toFloat(f32);
            return Value.Tag.float_32.create(arena, lhs_val - rhs_val);
        },
        .f64 => {
            const lhs_val = lhs.toFloat(f64);
            const rhs_val = rhs.toFloat(f64);
            return Value.Tag.float_64.create(arena, lhs_val - rhs_val);
        },
        .f128, .comptime_float, .c_longdouble => {
            const lhs_val = lhs.toFloat(f128);
            const rhs_val = rhs.toFloat(f128);
            return Value.Tag.float_128.create(arena, lhs_val - rhs_val);
        },
        else => unreachable,
    }
}

pub fn simplePtrType(
    self: *Module,
    scope: *Scope,
    src: usize,
    elem_ty: Type,
    mutable: bool,
    size: std.builtin.TypeInfo.Pointer.Size,
) Allocator.Error!Type {
    if (!mutable and size == .Slice and elem_ty.eql(Type.initTag(.u8))) {
        return Type.initTag(.const_slice_u8);
    }
    // TODO stage1 type inference bug
    const T = Type.Tag;

    const type_payload = try scope.arena().create(Type.Payload.ElemType);
    type_payload.* = .{
        .base = .{
            .tag = switch (size) {
                .One => if (mutable) T.single_mut_pointer else T.single_const_pointer,
                .Many => if (mutable) T.many_mut_pointer else T.many_const_pointer,
                .C => if (mutable) T.c_mut_pointer else T.c_const_pointer,
                .Slice => if (mutable) T.mut_slice else T.const_slice,
            },
        },
        .data = elem_ty,
    };
    return Type.initPayload(&type_payload.base);
}

pub fn ptrType(
    self: *Module,
    scope: *Scope,
    src: usize,
    elem_ty: Type,
    sentinel: ?Value,
    @"align": u32,
    bit_offset: u16,
    host_size: u16,
    mutable: bool,
    @"allowzero": bool,
    @"volatile": bool,
    size: std.builtin.TypeInfo.Pointer.Size,
) Allocator.Error!Type {
    assert(host_size == 0 or bit_offset < host_size * 8);

    // TODO check if type can be represented by simplePtrType
    return Type.Tag.pointer.create(scope.arena(), .{
        .pointee_type = elem_ty,
        .sentinel = sentinel,
        .@"align" = @"align",
        .bit_offset = bit_offset,
        .host_size = host_size,
        .@"allowzero" = @"allowzero",
        .mutable = mutable,
        .@"volatile" = @"volatile",
        .size = size,
    });
}

pub fn optionalType(self: *Module, scope: *Scope, child_type: Type) Allocator.Error!Type {
    switch (child_type.tag()) {
        .single_const_pointer => return Type.Tag.optional_single_const_pointer.create(
            scope.arena(),
            child_type.elemType(),
        ),
        .single_mut_pointer => return Type.Tag.optional_single_mut_pointer.create(
            scope.arena(),
            child_type.elemType(),
        ),
        else => return Type.Tag.optional.create(scope.arena(), child_type),
    }
}

pub fn arrayType(
    self: *Module,
    scope: *Scope,
    len: u64,
    sentinel: ?Value,
    elem_type: Type,
) Allocator.Error!Type {
    if (elem_type.eql(Type.initTag(.u8))) {
        if (sentinel) |some| {
            if (some.eql(Value.initTag(.zero))) {
                return Type.Tag.array_u8_sentinel_0.create(scope.arena(), len);
            }
        } else {
            return Type.Tag.array_u8.create(scope.arena(), len);
        }
    }

    if (sentinel) |some| {
        return Type.Tag.array_sentinel.create(scope.arena(), .{
            .len = len,
            .sentinel = some,
            .elem_type = elem_type,
        });
    }

    return Type.Tag.array.create(scope.arena(), .{
        .len = len,
        .elem_type = elem_type,
    });
}

pub fn errorUnionType(
    self: *Module,
    scope: *Scope,
    error_set: Type,
    payload: Type,
) Allocator.Error!Type {
    assert(error_set.zigTypeTag() == .ErrorSet);
    if (error_set.eql(Type.initTag(.anyerror)) and payload.eql(Type.initTag(.void))) {
        return Type.initTag(.anyerror_void_error_union);
    }

    return Type.Tag.error_union.create(scope.arena(), .{
        .error_set = error_set,
        .payload = payload,
    });
}

pub fn anyframeType(self: *Module, scope: *Scope, return_type: Type) Allocator.Error!Type {
    return Type.Tag.anyframe_T.create(scope.arena(), return_type);
}

pub fn dumpInst(self: *Module, scope: *Scope, inst: *Inst) void {
    const zir_module = scope.namespace();
    const source = zir_module.getSource(self) catch @panic("dumpInst failed to get source");
    const loc = std.zig.findLineColumn(source, inst.src);
    if (inst.tag == .constant) {
        std.debug.print("constant ty={} val={} src={s}:{d}:{d}\n", .{
            inst.ty,
            inst.castTag(.constant).?.val,
            zir_module.subFilePath(),
            loc.line + 1,
            loc.column + 1,
        });
    } else if (inst.deaths == 0) {
        std.debug.print("{s} ty={} src={s}:{d}:{d}\n", .{
            @tagName(inst.tag),
            inst.ty,
            zir_module.subFilePath(),
            loc.line + 1,
            loc.column + 1,
        });
    } else {
        std.debug.print("{s} ty={} deaths={b} src={s}:{d}:{d}\n", .{
            @tagName(inst.tag),
            inst.ty,
            inst.deaths,
            zir_module.subFilePath(),
            loc.line + 1,
            loc.column + 1,
        });
    }
}

pub const PanicId = enum {
    unreach,
    unwrap_null,
};

pub fn addSafetyCheck(mod: *Module, parent_block: *Scope.Block, ok: *Inst, panic_id: PanicId) !void {
    const block_inst = try parent_block.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = Type.initTag(.void),
            .src = ok.src,
        },
        .body = .{
            .instructions = try parent_block.arena.alloc(*Inst, 1), // Only need space for the condbr.
        },
    };

    const ok_body: ir.Body = .{
        .instructions = try parent_block.arena.alloc(*Inst, 1), // Only need space for the brvoid.
    };
    const brvoid = try parent_block.arena.create(Inst.BrVoid);
    brvoid.* = .{
        .base = .{
            .tag = .brvoid,
            .ty = Type.initTag(.noreturn),
            .src = ok.src,
        },
        .block = block_inst,
    };
    ok_body.instructions[0] = &brvoid.base;

    var fail_block: Scope.Block = .{
        .parent = parent_block,
        .inst_table = parent_block.inst_table,
        .func = parent_block.func,
        .decl = parent_block.decl,
        .instructions = .{},
        .arena = parent_block.arena,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };

    defer fail_block.instructions.deinit(mod.gpa);

    _ = try mod.safetyPanic(&fail_block, ok.src, panic_id);

    const fail_body: ir.Body = .{ .instructions = try parent_block.arena.dupe(*Inst, fail_block.instructions.items) };

    const condbr = try parent_block.arena.create(Inst.CondBr);
    condbr.* = .{
        .base = .{
            .tag = .condbr,
            .ty = Type.initTag(.noreturn),
            .src = ok.src,
        },
        .condition = ok,
        .then_body = ok_body,
        .else_body = fail_body,
    };
    block_inst.body.instructions[0] = &condbr.base;

    try parent_block.instructions.append(mod.gpa, &block_inst.base);
}

pub fn safetyPanic(mod: *Module, block: *Scope.Block, src: usize, panic_id: PanicId) !*Inst {
    // TODO Once we have a panic function to call, call it here instead of breakpoint.
    _ = try mod.addNoOp(block, src, Type.initTag(.void), .breakpoint);
    return mod.addNoOp(block, src, Type.initTag(.noreturn), .unreach);
}

pub fn getTarget(self: Module) Target {
    return self.comp.bin_file.options.target;
}

pub fn optimizeMode(self: Module) std.builtin.Mode {
    return self.comp.bin_file.options.optimize_mode;
}

pub fn validateVarType(mod: *Module, scope: *Scope, src: usize, ty: Type) !void {
    if (!ty.isValidVarType(false)) {
        return mod.fail(scope, src, "variable of type '{}' must be const or comptime", .{ty});
    }
}

/// Identifier token -> String (allocated in scope.arena())
pub fn identifierTokenString(mod: *Module, scope: *Scope, token: ast.TokenIndex) InnerError![]const u8 {
    const tree = scope.tree();

    const ident_name = tree.tokenSlice(token);
    if (mem.startsWith(u8, ident_name, "@")) {
        const raw_string = ident_name[1..];
        var bad_index: usize = undefined;
        return std.zig.parseStringLiteral(scope.arena(), raw_string, &bad_index) catch |err| switch (err) {
            error.InvalidCharacter => {
                const bad_byte = raw_string[bad_index];
                const src = tree.token_locs[token].start;
                return mod.fail(scope, src + 1 + bad_index, "invalid string literal character: '{c}'\n", .{bad_byte});
            },
            else => |e| return e,
        };
    }
    return ident_name;
}

pub fn emitBackwardBranch(mod: *Module, block: *Scope.Block, src: usize) !void {
    const shared = block.inlining.?.shared;
    shared.branch_count += 1;
    if (shared.branch_count > block.branch_quota.*) {
        // TODO show the "called from here" stack
        return mod.fail(&block.base, src, "evaluation exceeded {d} backwards branches", .{
            block.branch_quota.*,
        });
    }
}
