const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const Module = @import("Module.zig");
const fs = std.fs;
const elf = std.elf;
const codegen = @import("codegen.zig");
const c_codegen = @import("codegen/c.zig");
const log = std.log;
const DW = std.dwarf;
const trace = @import("tracy.zig").trace;
const leb128 = std.debug.leb;
const Package = @import("Package.zig");
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const build_options = @import("build_options");

const producer_string = if (std.builtin.is_test) "zig test" else "zig " ++ build_options.version;

// TODO Turn back on zig fmt when https://github.com/ziglang/zig/issues/5948 is implemented.
// zig fmt: off

const default_entry_addr = 0x8000000;

pub const Options = struct {
    target: std.Target,
    output_mode: std.builtin.OutputMode,
    link_mode: std.builtin.LinkMode,
    object_format: std.builtin.ObjectFormat,
    optimize_mode: std.builtin.Mode,
    root_name: []const u8,
    root_pkg: *const Package,
    /// Used for calculating how much space to reserve for symbols in case the binary file
    /// does not already have a symbol table.
    symbol_count_hint: u64 = 32,
    /// Used for calculating how much space to reserve for executable program code in case
    /// the binary file deos not already have such a section.
    program_code_size_hint: u64 = 256 * 1024,
};


pub const File = struct {
    pub const LinkBlock = union {
        elf: Elf.TextBlock,
        c: void,
    };

    pub const LinkFn = union {
        elf: Elf.SrcFn,
        c: void,
    };

    tag: Tag,
    options: Options,
    file: ?fs.File,
    allocator: *Allocator,

    /// Attempts incremental linking, if the file already exists. If
    /// incremental linking fails, falls back to truncating the file and
    /// rewriting it. A malicious file is detected as incremental link failure
    /// and does not cause Illegal Behavior. This operation is not atomic.
    pub fn openPath(allocator: *Allocator, dir: fs.Dir, sub_path: []const u8, options: Options)  !*File {
        switch (options.object_format) {
            .unknown => unreachable,
            .coff => return error.TODOImplementCoff,
            .elf => return Elf.openPath(allocator, dir, sub_path, options),
            .macho => return error.TODOImplementMacho,
            .wasm => return error.TODOImplementWasm,
            .c => return C.openPath(allocator, dir, sub_path, options),
            .hex => return error.TODOImplementHex,
            .raw => return error.TODOImplementRaw,
        }
    }

    pub fn cast(base: *File, comptime T: type) ?*T {
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    pub fn makeWritable(base: *File, dir: fs.Dir, sub_path: []const u8) !void {
        switch (base.tag) {
            .elf => {
                if (base.file != null) return;
                base.file = try dir.createFile(sub_path, .{
                    .truncate = false,
                    .read = true,
                    .mode = determineMode(base.options),
                });
            },
            .c => {},
        }
    }

    pub fn makeExecutable(base: *File) !void {
        std.debug.assert(base.tag != .c);
        if (base.file) |f| {
            f.close();
            base.file = null;
        }
    }

    pub fn updateDecl(base: *File, module: *Module, decl: *Module.Decl) !void {
        switch (base.tag) {
            .elf => return @fieldParentPtr(Elf, "base", base).updateDecl(module, decl),
            .c => return @fieldParentPtr(C, "base", base).updateDecl(module, decl),
        }
    }

    pub fn updateDeclLineNumber(base: *File, module: *Module, decl: *Module.Decl) !void {
        switch (base.tag) {
            .elf => return @fieldParentPtr(Elf, "base", base).updateDeclLineNumber(module, decl),
            .c => {},
        }
    }

    pub fn allocateDeclIndexes(base: *File, decl: *Module.Decl) !void {
        switch (base.tag) {
            .elf => return @fieldParentPtr(Elf, "base", base).allocateDeclIndexes(decl),
            .c => {},
        }
    }

    pub fn deinit(base: *File) void {
        if (base.file) |f| f.close();
        switch (base.tag) {
            .elf => @fieldParentPtr(Elf, "base", base).deinit(),
            .c => @fieldParentPtr(C, "base", base).deinit(),
        }
    }

    pub fn destroy(base: *File) void {
        switch (base.tag) {
            .elf => {
                const parent = @fieldParentPtr(Elf, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .c => {
                const parent = @fieldParentPtr(C, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
        }
    }

    pub fn flush(base: *File) !void {
        const tracy = trace(@src());
        defer tracy.end();

        try switch (base.tag) {
            .elf => @fieldParentPtr(Elf, "base", base).flush(),
            .c => @fieldParentPtr(C, "base", base).flush(),
        };
    }

    pub fn freeDecl(base: *File, decl: *Module.Decl) void {
        switch (base.tag) {
            .elf => @fieldParentPtr(Elf, "base", base).freeDecl(decl),
            .c => unreachable,
        }
    }

    pub fn errorFlags(base: *File) ErrorFlags {
        return switch (base.tag) {
            .elf => @fieldParentPtr(Elf, "base", base).error_flags,
            .c => return .{ .no_entry_point_found = false },
        };
    }

    /// Must be called only after a successful call to `updateDecl`.
    pub fn updateDeclExports(
        base: *File,
        module: *Module,
        decl: *const Module.Decl,
        exports: []const *Module.Export,
    ) !void {
        switch (base.tag) {
            .elf => return @fieldParentPtr(Elf, "base", base).updateDeclExports(module, decl, exports),
            .c => return {},
        }
    }

    pub const Tag = enum {
        elf,
        c,
    };

    pub const ErrorFlags = struct {
        no_entry_point_found: bool = false,
    };

    pub const C = struct {
        pub const base_tag: Tag = .c;

        base: File,

        header: std.ArrayList(u8),
        constants: std.ArrayList(u8),
        main: std.ArrayList(u8),

        called: std.StringHashMap(void),
        need_stddef: bool = false,
        need_stdint: bool = false,
        error_msg: *Module.ErrorMsg = undefined,

        pub fn openPath(allocator: *Allocator, dir: fs.Dir, sub_path: []const u8, options: Options) !*File {
            assert(options.object_format == .c);

            const file = try dir.createFile(sub_path, .{ .truncate = true, .read = true, .mode = determineMode(options) });
            errdefer file.close();

            var c_file = try allocator.create(C);
            errdefer allocator.destroy(c_file);

            c_file.* = File.C{
                .base = .{
                    .tag = .c,
                    .options = options,
                    .file = file,
                    .allocator = allocator,
                },
                .main = std.ArrayList(u8).init(allocator),
                .header = std.ArrayList(u8).init(allocator),
                .constants = std.ArrayList(u8).init(allocator),
                .called = std.StringHashMap(void).init(allocator),
            };

            return &c_file.base;
        }

        pub fn fail(self: *C, src: usize, comptime format: []const u8, args: anytype) error{AnalysisFail, OutOfMemory} {
            self.error_msg = try Module.ErrorMsg.create(self.base.allocator, src, format, args);
            return error.AnalysisFail;
        }

        pub fn deinit(self: *File.C) void {
            self.main.deinit();
            self.header.deinit();
            self.constants.deinit();
            self.called.deinit();
        }

        pub fn updateDecl(self: *File.C, module: *Module, decl: *Module.Decl) !void {
            c_codegen.generate(self, decl) catch |err| {
                if (err == error.AnalysisFail) {
                    try module.failed_decls.put(module.gpa, decl, self.error_msg);
                }
                return err;
            };
        }

        pub fn flush(self: *File.C) !void {
            const writer = self.base.file.?.writer();
            try writer.writeAll(@embedFile("cbe.h"));
            var includes = false;
            if (self.need_stddef) {
                try writer.writeAll("#include <stddef.h>\n");
                includes = true;
            }
            if (self.need_stdint) {
                try writer.writeAll("#include <stdint.h>\n");
                includes = true;
            }
            if (includes) {
                try writer.writeByte('\n');
            }
            if (self.header.items.len > 0) {
                try writer.print("{}\n", .{self.header.items});
            }
            if (self.constants.items.len > 0) {
                try writer.print("{}\n", .{self.constants.items});
            }
            if (self.main.items.len > 1) {
                const last_two = self.main.items[self.main.items.len - 2 ..];
                if (std.mem.eql(u8, last_two, "\n\n")) {
                    self.main.items.len -= 1;
                }
            }
            try writer.writeAll(self.main.items);
            self.base.file.?.close();
            self.base.file = null;
        }
    };

    pub const Elf = struct {
        pub const base_tag: Tag = .elf;

        base: File,

        ptr_width: enum { p32, p64 },

        /// Stored in native-endian format, depending on target endianness needs to be bswapped on read/write.
        /// Same order as in the file.
        sections: std.ArrayListUnmanaged(elf.Elf64_Shdr) = std.ArrayListUnmanaged(elf.Elf64_Shdr){},
        shdr_table_offset: ?u64 = null,

        /// Stored in native-endian format, depending on target endianness needs to be bswapped on read/write.
        /// Same order as in the file.
        program_headers: std.ArrayListUnmanaged(elf.Elf64_Phdr) = std.ArrayListUnmanaged(elf.Elf64_Phdr){},
        phdr_table_offset: ?u64 = null,
        /// The index into the program headers of a PT_LOAD program header with Read and Execute flags
        phdr_load_re_index: ?u16 = null,
        /// The index into the program headers of the global offset table.
        /// It needs PT_LOAD and Read flags.
        phdr_got_index: ?u16 = null,
        entry_addr: ?u64 = null,

        debug_strtab: std.ArrayListUnmanaged(u8) = std.ArrayListUnmanaged(u8){},
        shstrtab: std.ArrayListUnmanaged(u8) = std.ArrayListUnmanaged(u8){},
        shstrtab_index: ?u16 = null,

        text_section_index: ?u16 = null,
        symtab_section_index: ?u16 = null,
        got_section_index: ?u16 = null,
        debug_info_section_index: ?u16 = null,
        debug_abbrev_section_index: ?u16 = null,
        debug_str_section_index: ?u16 = null,
        debug_aranges_section_index: ?u16 = null,
        debug_line_section_index: ?u16 = null,

        debug_abbrev_table_offset: ?u64 = null,

        /// The same order as in the file. ELF requires global symbols to all be after the
        /// local symbols, they cannot be mixed. So we must buffer all the global symbols and
        /// write them at the end. These are only the local symbols. The length of this array
        /// is the value used for sh_info in the .symtab section.
        local_symbols: std.ArrayListUnmanaged(elf.Elf64_Sym) = .{},
        global_symbols: std.ArrayListUnmanaged(elf.Elf64_Sym) = .{},

        local_symbol_free_list: std.ArrayListUnmanaged(u32) = .{},
        global_symbol_free_list: std.ArrayListUnmanaged(u32) = .{},
        offset_table_free_list: std.ArrayListUnmanaged(u32) = .{},

        /// Same order as in the file. The value is the absolute vaddr value.
        /// If the vaddr of the executable program header changes, the entire
        /// offset table needs to be rewritten.
        offset_table: std.ArrayListUnmanaged(u64) = .{},

        phdr_table_dirty: bool = false,
        shdr_table_dirty: bool = false,
        shstrtab_dirty: bool = false,
        debug_strtab_dirty: bool = false,
        offset_table_count_dirty: bool = false,
        debug_abbrev_section_dirty: bool = false,
        debug_aranges_section_dirty: bool = false,

        debug_info_header_dirty: bool = false,
        debug_line_header_dirty: bool = false,

        error_flags: ErrorFlags = ErrorFlags{},

        /// A list of text blocks that have surplus capacity. This list can have false
        /// positives, as functions grow and shrink over time, only sometimes being added
        /// or removed from the freelist.
        ///
        /// A text block has surplus capacity when its overcapacity value is greater than
        /// minimum_text_block_size * alloc_num / alloc_den. That is, when it has so
        /// much extra capacity, that we could fit a small new symbol in it, itself with
        /// ideal_capacity or more.
        ///
        /// Ideal capacity is defined by size * alloc_num / alloc_den.
        ///
        /// Overcapacity is measured by actual_capacity - ideal_capacity. Note that
        /// overcapacity can be negative. A simple way to have negative overcapacity is to
        /// allocate a fresh text block, which will have ideal capacity, and then grow it
        /// by 1 byte. It will then have -1 overcapacity.
        text_block_free_list: std.ArrayListUnmanaged(*TextBlock) = .{},
        last_text_block: ?*TextBlock = null,

        /// A list of `SrcFn` whose Line Number Programs have surplus capacity.
        /// This is the same concept as `text_block_free_list`; see those doc comments.
        dbg_line_fn_free_list: std.AutoHashMapUnmanaged(*SrcFn, void) = .{},
        dbg_line_fn_first: ?*SrcFn = null,
        dbg_line_fn_last: ?*SrcFn = null,

        /// A list of `TextBlock` whose corresponding .debug_info tags have surplus capacity.
        /// This is the same concept as `text_block_free_list`; see those doc comments.
        dbg_info_decl_free_list: std.AutoHashMapUnmanaged(*TextBlock, void) = .{},
        dbg_info_decl_first: ?*TextBlock = null,
        dbg_info_decl_last: ?*TextBlock = null,

        /// `alloc_num / alloc_den` is the factor of padding when allocating.
        const alloc_num = 4;
        const alloc_den = 3;

        /// In order for a slice of bytes to be considered eligible to keep metadata pointing at
        /// it as a possible place to put new symbols, it must have enough room for this many bytes
        /// (plus extra for reserved capacity).
        const minimum_text_block_size = 64;
        const min_text_capacity = minimum_text_block_size * alloc_num / alloc_den;

        pub const DbgInfoTypeRelocsTable = std.HashMapUnmanaged(Type, DbgInfoTypeReloc, Type.hash, Type.eql, true);

        const DbgInfoTypeReloc = struct {
            /// Offset from `TextBlock.dbg_info_off` (the buffer that is local to a Decl).
            /// This is where the .debug_info tag for the type is.
            off: u32,
            /// Offset from `TextBlock.dbg_info_off` (the buffer that is local to a Decl).
            /// List of DW.AT_type / DW.FORM_ref4 that points to the type.
            relocs: std.ArrayListUnmanaged(u32),
        };

        pub const TextBlock = struct {
            /// Each decl always gets a local symbol with the fully qualified name.
            /// The vaddr and size are found here directly.
            /// The file offset is found by computing the vaddr offset from the section vaddr
            /// the symbol references, and adding that to the file offset of the section.
            /// If this field is 0, it means the codegen size = 0 and there is no symbol or
            /// offset table entry.
            local_sym_index: u32,
            /// This field is undefined for symbols with size = 0.
            offset_table_index: u32,
            /// Points to the previous and next neighbors, based on the `text_offset`.
            /// This can be used to find, for example, the capacity of this `TextBlock`.
            prev: ?*TextBlock,
            next: ?*TextBlock,

            /// Previous/next linked list pointers. This value is `next ^ prev`.
            /// This is the linked list node for this Decl's corresponding .debug_info tag.
            dbg_info_prev: ?*TextBlock,
            dbg_info_next: ?*TextBlock,
            /// Offset into .debug_info pointing to the tag for this Decl.
            dbg_info_off: u32,
            /// Size of the .debug_info tag for this Decl, not including padding.
            dbg_info_len: u32,

            pub const empty = TextBlock{
                .local_sym_index = 0,
                .offset_table_index = undefined,
                .prev = null,
                .next = null,
                .dbg_info_prev = null,
                .dbg_info_next = null,
                .dbg_info_off = undefined,
                .dbg_info_len = undefined,
            };

            /// Returns how much room there is to grow in virtual address space.
            /// File offset relocation happens transparently, so it is not included in
            /// this calculation.
            fn capacity(self: TextBlock, elf_file: Elf) u64 {
                const self_sym = elf_file.local_symbols.items[self.local_sym_index];
                if (self.next) |next| {
                    const next_sym = elf_file.local_symbols.items[next.local_sym_index];
                    return next_sym.st_value - self_sym.st_value;
                } else {
                    // We are the last block. The capacity is limited only by virtual address space.
                    return std.math.maxInt(u32) - self_sym.st_value;
                }
            }

            fn freeListEligible(self: TextBlock, elf_file: Elf) bool {
                // No need to keep a free list node for the last block.
                const next = self.next orelse return false;
                const self_sym = elf_file.local_symbols.items[self.local_sym_index];
                const next_sym = elf_file.local_symbols.items[next.local_sym_index];
                const cap = next_sym.st_value - self_sym.st_value;
                const ideal_cap = self_sym.st_size * alloc_num / alloc_den;
                if (cap <= ideal_cap) return false;
                const surplus = cap - ideal_cap;
                return surplus >= min_text_capacity;
            }
        };

        pub const Export = struct {
            sym_index: ?u32 = null,
        };

        pub const SrcFn = struct {
            /// Offset from the beginning of the Debug Line Program header that contains this function.
            off: u32,
            /// Size of the line number program component belonging to this function, not
            /// including padding.
            len: u32,

            /// Points to the previous and next neighbors, based on the offset from .debug_line.
            /// This can be used to find, for example, the capacity of this `SrcFn`.
            prev: ?*SrcFn,
            next: ?*SrcFn,

            pub const empty: SrcFn = .{
                .off = 0,
                .len = 0,
                .prev = null,
                .next = null,
            };
        };

        pub fn openPath(allocator: *Allocator, dir: fs.Dir, sub_path: []const u8, options: Options) !*File {
            assert(options.object_format == .elf);

            const file = try dir.createFile(sub_path, .{ .truncate = false, .read = true, .mode = determineMode(options) });
            errdefer file.close();

            var elf_file = try allocator.create(Elf);
            errdefer allocator.destroy(elf_file);

            elf_file.* = openFile(allocator, file, options) catch |err| switch (err) {
                error.IncrFailed => try createFile(allocator, file, options),
                else => |e| return e,
            };

            return &elf_file.base;
        }

        /// Returns error.IncrFailed if incremental update could not be performed.
        fn openFile(allocator: *Allocator, file: fs.File, options: Options) !Elf {
            switch (options.output_mode) {
                .Exe => {},
                .Obj => {},
                .Lib => return error.IncrFailed,
            }
            var self: Elf = .{
                .base = .{
                    .file = file,
                    .tag = .elf,
                    .options = options,
                    .allocator = allocator,
                },
                .ptr_width = switch (options.target.cpu.arch.ptrBitWidth()) {
                    32 => .p32,
                    64 => .p64,
                    else => return error.UnsupportedELFArchitecture,
                },
            };
            errdefer self.deinit();

            // TODO implement reading the elf file
            return error.IncrFailed;
            //try self.populateMissingMetadata();
            //return self;
        }

        /// Truncates the existing file contents and overwrites the contents.
        /// Returns an error if `file` is not already open with +read +write +seek abilities.
        fn createFile(allocator: *Allocator, file: fs.File, options: Options) !Elf {
            switch (options.output_mode) {
                .Exe => {},
                .Obj => {},
                .Lib => return error.TODOImplementWritingLibFiles,
            }
            var self: Elf = .{
                .base = .{
                    .tag = .elf,
                    .options = options,
                    .allocator = allocator,
                    .file = file,
                },
                .ptr_width = switch (options.target.cpu.arch.ptrBitWidth()) {
                    32 => .p32,
                    64 => .p64,
                    else => return error.UnsupportedELFArchitecture,
                },
                .shdr_table_dirty = true,
            };
            errdefer self.deinit();

            // Index 0 is always a null symbol.
            try self.local_symbols.append(allocator, .{
                .st_name = 0,
                .st_info = 0,
                .st_other = 0,
                .st_shndx = 0,
                .st_value = 0,
                .st_size = 0,
            });

            // There must always be a null section in index 0
            try self.sections.append(allocator, .{
                .sh_name = 0,
                .sh_type = elf.SHT_NULL,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = 0,
                .sh_size = 0,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0,
                .sh_entsize = 0,
            });

            try self.populateMissingMetadata();

            return self;
        }

        pub fn deinit(self: *Elf) void {
            self.sections.deinit(self.base.allocator);
            self.program_headers.deinit(self.base.allocator);
            self.shstrtab.deinit(self.base.allocator);
            self.debug_strtab.deinit(self.base.allocator);
            self.local_symbols.deinit(self.base.allocator);
            self.global_symbols.deinit(self.base.allocator);
            self.global_symbol_free_list.deinit(self.base.allocator);
            self.local_symbol_free_list.deinit(self.base.allocator);
            self.offset_table_free_list.deinit(self.base.allocator);
            self.text_block_free_list.deinit(self.base.allocator);
            self.dbg_line_fn_free_list.deinit(self.base.allocator);
            self.dbg_info_decl_free_list.deinit(self.base.allocator);
            self.offset_table.deinit(self.base.allocator);
        }

        fn getDebugLineProgramOff(self: Elf) u32 {
            return self.dbg_line_fn_first.?.off;
        }

        fn getDebugLineProgramEnd(self: Elf) u32 {
            return self.dbg_line_fn_last.?.off + self.dbg_line_fn_last.?.len;
        }

        /// Returns end pos of collision, if any.
        fn detectAllocCollision(self: *Elf, start: u64, size: u64) ?u64 {
            const small_ptr = self.base.options.target.cpu.arch.ptrBitWidth() == 32;
            const ehdr_size: u64 = if (small_ptr) @sizeOf(elf.Elf32_Ehdr) else @sizeOf(elf.Elf64_Ehdr);
            if (start < ehdr_size)
                return ehdr_size;

            const end = start + satMul(size, alloc_num) / alloc_den;

            if (self.shdr_table_offset) |off| {
                const shdr_size: u64 = if (small_ptr) @sizeOf(elf.Elf32_Shdr) else @sizeOf(elf.Elf64_Shdr);
                const tight_size = self.sections.items.len * shdr_size;
                const increased_size = satMul(tight_size, alloc_num) / alloc_den;
                const test_end = off + increased_size;
                if (end > off and start < test_end) {
                    return test_end;
                }
            }

            if (self.phdr_table_offset) |off| {
                const phdr_size: u64 = if (small_ptr) @sizeOf(elf.Elf32_Phdr) else @sizeOf(elf.Elf64_Phdr);
                const tight_size = self.sections.items.len * phdr_size;
                const increased_size = satMul(tight_size, alloc_num) / alloc_den;
                const test_end = off + increased_size;
                if (end > off and start < test_end) {
                    return test_end;
                }
            }

            for (self.sections.items) |section| {
                const increased_size = satMul(section.sh_size, alloc_num) / alloc_den;
                const test_end = section.sh_offset + increased_size;
                if (end > section.sh_offset and start < test_end) {
                    return test_end;
                }
            }
            for (self.program_headers.items) |program_header| {
                const increased_size = satMul(program_header.p_filesz, alloc_num) / alloc_den;
                const test_end = program_header.p_offset + increased_size;
                if (end > program_header.p_offset and start < test_end) {
                    return test_end;
                }
            }
            return null;
        }

        fn allocatedSize(self: *Elf, start: u64) u64 {
            if (start == 0)
                return 0;
            var min_pos: u64 = std.math.maxInt(u64);
            if (self.shdr_table_offset) |off| {
                if (off > start and off < min_pos) min_pos = off;
            }
            if (self.phdr_table_offset) |off| {
                if (off > start and off < min_pos) min_pos = off;
            }
            for (self.sections.items) |section| {
                if (section.sh_offset <= start) continue;
                if (section.sh_offset < min_pos) min_pos = section.sh_offset;
            }
            for (self.program_headers.items) |program_header| {
                if (program_header.p_offset <= start) continue;
                if (program_header.p_offset < min_pos) min_pos = program_header.p_offset;
            }
            return min_pos - start;
        }

        fn findFreeSpace(self: *Elf, object_size: u64, min_alignment: u16) u64 {
            var start: u64 = 0;
            while (self.detectAllocCollision(start, object_size)) |item_end| {
                start = mem.alignForwardGeneric(u64, item_end, min_alignment);
            }
            return start;
        }

        /// TODO Improve this to use a table.
        fn makeString(self: *Elf, bytes: []const u8) !u32 {
            try self.shstrtab.ensureCapacity(self.base.allocator, self.shstrtab.items.len + bytes.len + 1);
            const result = self.shstrtab.items.len;
            self.shstrtab.appendSliceAssumeCapacity(bytes);
            self.shstrtab.appendAssumeCapacity(0);
            return @intCast(u32, result);
        }

        /// TODO Improve this to use a table.
        fn makeDebugString(self: *Elf, bytes: []const u8) !u32 {
            try self.debug_strtab.ensureCapacity(self.base.allocator, self.debug_strtab.items.len + bytes.len + 1);
            const result = self.debug_strtab.items.len;
            self.debug_strtab.appendSliceAssumeCapacity(bytes);
            self.debug_strtab.appendAssumeCapacity(0);
            return @intCast(u32, result);
        }

        fn getString(self: *Elf, str_off: u32) []const u8 {
            assert(str_off < self.shstrtab.items.len);
            return mem.spanZ(@ptrCast([*:0]const u8, self.shstrtab.items.ptr + str_off));
        }

        fn updateString(self: *Elf, old_str_off: u32, new_name: []const u8) !u32 {
            const existing_name = self.getString(old_str_off);
            if (mem.eql(u8, existing_name, new_name)) {
                return old_str_off;
            }
            return self.makeString(new_name);
        }

        pub fn populateMissingMetadata(self: *Elf) !void {
            const small_ptr = switch (self.ptr_width) {
                .p32 => true,
                .p64 => false,
            };
            const ptr_size: u8 = self.ptrWidthBytes();
            if (self.phdr_load_re_index == null) {
                self.phdr_load_re_index = @intCast(u16, self.program_headers.items.len);
                const file_size = self.base.options.program_code_size_hint;
                const p_align = 0x1000;
                const off = self.findFreeSpace(file_size, p_align);
                log.debug(.link, "found PT_LOAD free space 0x{x} to 0x{x}\n", .{ off, off + file_size });
                try self.program_headers.append(self.base.allocator, .{
                    .p_type = elf.PT_LOAD,
                    .p_offset = off,
                    .p_filesz = file_size,
                    .p_vaddr = default_entry_addr,
                    .p_paddr = default_entry_addr,
                    .p_memsz = file_size,
                    .p_align = p_align,
                    .p_flags = elf.PF_X | elf.PF_R,
                });
                self.entry_addr = null;
                self.phdr_table_dirty = true;
            }
            if (self.phdr_got_index == null) {
                self.phdr_got_index = @intCast(u16, self.program_headers.items.len);
                const file_size = @as(u64, ptr_size) * self.base.options.symbol_count_hint;
                // We really only need ptr alignment but since we are using PROGBITS, linux requires
                // page align.
                const p_align = if (self.base.options.target.os.tag == .linux) 0x1000 else @as(u16, ptr_size);
                const off = self.findFreeSpace(file_size, p_align);
                log.debug(.link, "found PT_LOAD free space 0x{x} to 0x{x}\n", .{ off, off + file_size });
                // TODO instead of hard coding the vaddr, make a function to find a vaddr to put things at.
                // we'll need to re-use that function anyway, in case the GOT grows and overlaps something
                // else in virtual memory.
                const default_got_addr = if (ptr_size == 2) @as(u32, 0x8000) else 0x4000000;
                try self.program_headers.append(self.base.allocator, .{
                    .p_type = elf.PT_LOAD,
                    .p_offset = off,
                    .p_filesz = file_size,
                    .p_vaddr = default_got_addr,
                    .p_paddr = default_got_addr,
                    .p_memsz = file_size,
                    .p_align = p_align,
                    .p_flags = elf.PF_R,
                });
                self.phdr_table_dirty = true;
            }
            if (self.shstrtab_index == null) {
                self.shstrtab_index = @intCast(u16, self.sections.items.len);
                assert(self.shstrtab.items.len == 0);
                try self.shstrtab.append(self.base.allocator, 0); // need a 0 at position 0
                const off = self.findFreeSpace(self.shstrtab.items.len, 1);
                log.debug(.link, "found shstrtab free space 0x{x} to 0x{x}\n", .{ off, off + self.shstrtab.items.len });
                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".shstrtab"),
                    .sh_type = elf.SHT_STRTAB,
                    .sh_flags = 0,
                    .sh_addr = 0,
                    .sh_offset = off,
                    .sh_size = self.shstrtab.items.len,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = 1,
                    .sh_entsize = 0,
                });
                self.shstrtab_dirty = true;
                self.shdr_table_dirty = true;
            }
            if (self.text_section_index == null) {
                self.text_section_index = @intCast(u16, self.sections.items.len);
                const phdr = &self.program_headers.items[self.phdr_load_re_index.?];

                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".text"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = elf.SHF_ALLOC | elf.SHF_EXECINSTR,
                    .sh_addr = phdr.p_vaddr,
                    .sh_offset = phdr.p_offset,
                    .sh_size = phdr.p_filesz,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = phdr.p_align,
                    .sh_entsize = 0,
                });
                self.shdr_table_dirty = true;
            }
            if (self.got_section_index == null) {
                self.got_section_index = @intCast(u16, self.sections.items.len);
                const phdr = &self.program_headers.items[self.phdr_got_index.?];

                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".got"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = elf.SHF_ALLOC,
                    .sh_addr = phdr.p_vaddr,
                    .sh_offset = phdr.p_offset,
                    .sh_size = phdr.p_filesz,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = phdr.p_align,
                    .sh_entsize = 0,
                });
                self.shdr_table_dirty = true;
            }
            if (self.symtab_section_index == null) {
                self.symtab_section_index = @intCast(u16, self.sections.items.len);
                const min_align: u16 = if (small_ptr) @alignOf(elf.Elf32_Sym) else @alignOf(elf.Elf64_Sym);
                const each_size: u64 = if (small_ptr) @sizeOf(elf.Elf32_Sym) else @sizeOf(elf.Elf64_Sym);
                const file_size = self.base.options.symbol_count_hint * each_size;
                const off = self.findFreeSpace(file_size, min_align);
                log.debug(.link, "found symtab free space 0x{x} to 0x{x}\n", .{ off, off + file_size });

                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".symtab"),
                    .sh_type = elf.SHT_SYMTAB,
                    .sh_flags = 0,
                    .sh_addr = 0,
                    .sh_offset = off,
                    .sh_size = file_size,
                    // The section header index of the associated string table.
                    .sh_link = self.shstrtab_index.?,
                    .sh_info = @intCast(u32, self.local_symbols.items.len),
                    .sh_addralign = min_align,
                    .sh_entsize = each_size,
                });
                self.shdr_table_dirty = true;
                try self.writeSymbol(0);
            }
            if (self.debug_str_section_index == null) {
                self.debug_str_section_index = @intCast(u16, self.sections.items.len);
                assert(self.debug_strtab.items.len == 0);
                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".debug_str"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = elf.SHF_MERGE | elf.SHF_STRINGS,
                    .sh_addr = 0,
                    .sh_offset = 0,
                    .sh_size = self.debug_strtab.items.len,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = 1,
                    .sh_entsize = 1,
                });
                self.debug_strtab_dirty = true;
                self.shdr_table_dirty = true;
            }
            if (self.debug_info_section_index == null) {
                self.debug_info_section_index = @intCast(u16, self.sections.items.len);

                const file_size_hint = 200;
                const p_align = 1;
                const off = self.findFreeSpace(file_size_hint, p_align);
                log.debug(.link, "found .debug_info free space 0x{x} to 0x{x}\n", .{
                    off,
                    off + file_size_hint,
                });
                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".debug_info"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = 0,
                    .sh_addr = 0,
                    .sh_offset = off,
                    .sh_size = file_size_hint,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = p_align,
                    .sh_entsize = 0,
                });
                self.shdr_table_dirty = true;
                self.debug_info_header_dirty = true;
            }
            if (self.debug_abbrev_section_index == null) {
                self.debug_abbrev_section_index = @intCast(u16, self.sections.items.len);

                const file_size_hint = 128;
                const p_align = 1;
                const off = self.findFreeSpace(file_size_hint, p_align);
                log.debug(.link, "found .debug_abbrev free space 0x{x} to 0x{x}\n", .{
                    off,
                    off + file_size_hint,
                });
                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".debug_abbrev"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = 0,
                    .sh_addr = 0,
                    .sh_offset = off,
                    .sh_size = file_size_hint,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = p_align,
                    .sh_entsize = 0,
                });
                self.shdr_table_dirty = true;
                self.debug_abbrev_section_dirty = true;
            }
            if (self.debug_aranges_section_index == null) {
                self.debug_aranges_section_index = @intCast(u16, self.sections.items.len);

                const file_size_hint = 160;
                const p_align = 16;
                const off = self.findFreeSpace(file_size_hint, p_align);
                log.debug(.link, "found .debug_aranges free space 0x{x} to 0x{x}\n", .{
                    off,
                    off + file_size_hint,
                });
                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".debug_aranges"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = 0,
                    .sh_addr = 0,
                    .sh_offset = off,
                    .sh_size = file_size_hint,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = p_align,
                    .sh_entsize = 0,
                });
                self.shdr_table_dirty = true;
                self.debug_aranges_section_dirty = true;
            }
            if (self.debug_line_section_index == null) {
                self.debug_line_section_index = @intCast(u16, self.sections.items.len);

                const file_size_hint = 250;
                const p_align = 1;
                const off = self.findFreeSpace(file_size_hint, p_align);
                log.debug(.link, "found .debug_line free space 0x{x} to 0x{x}\n", .{
                    off,
                    off + file_size_hint,
                });
                try self.sections.append(self.base.allocator, .{
                    .sh_name = try self.makeString(".debug_line"),
                    .sh_type = elf.SHT_PROGBITS,
                    .sh_flags = 0,
                    .sh_addr = 0,
                    .sh_offset = off,
                    .sh_size = file_size_hint,
                    .sh_link = 0,
                    .sh_info = 0,
                    .sh_addralign = p_align,
                    .sh_entsize = 0,
                });
                self.shdr_table_dirty = true;
                self.debug_line_header_dirty = true;
            }
            const shsize: u64 = switch (self.ptr_width) {
                .p32 => @sizeOf(elf.Elf32_Shdr),
                .p64 => @sizeOf(elf.Elf64_Shdr),
            };
            const shalign: u16 = switch (self.ptr_width) {
                .p32 => @alignOf(elf.Elf32_Shdr),
                .p64 => @alignOf(elf.Elf64_Shdr),
            };
            if (self.shdr_table_offset == null) {
                self.shdr_table_offset = self.findFreeSpace(self.sections.items.len * shsize, shalign);
                self.shdr_table_dirty = true;
            }
            const phsize: u64 = switch (self.ptr_width) {
                .p32 => @sizeOf(elf.Elf32_Phdr),
                .p64 => @sizeOf(elf.Elf64_Phdr),
            };
            const phalign: u16 = switch (self.ptr_width) {
                .p32 => @alignOf(elf.Elf32_Phdr),
                .p64 => @alignOf(elf.Elf64_Phdr),
            };
            if (self.phdr_table_offset == null) {
                self.phdr_table_offset = self.findFreeSpace(self.program_headers.items.len * phsize, phalign);
                self.phdr_table_dirty = true;
            }
            {
                // Iterate over symbols, populating free_list and last_text_block.
                if (self.local_symbols.items.len != 1) {
                    @panic("TODO implement setting up free_list and last_text_block from existing ELF file");
                }
                // We are starting with an empty file. The default values are correct, null and empty list.
            }
        }

        pub const abbrev_compile_unit = 1;
        pub const abbrev_subprogram = 2;
        pub const abbrev_subprogram_retvoid = 3;
        pub const abbrev_base_type = 4;
        pub const abbrev_pad1 = 5;
        pub const abbrev_parameter = 6;

        /// Commit pending changes and write headers.
        pub fn flush(self: *Elf) !void {
            const target_endian = self.base.options.target.cpu.arch.endian();
            const foreign_endian = target_endian != std.Target.current.cpu.arch.endian();
            const ptr_width_bytes: u8 = self.ptrWidthBytes();
            const init_len_size: usize = switch (self.ptr_width) {
                .p32 => 4,
                .p64 => 12,
            };

            // Unfortunately these have to be buffered and done at the end because ELF does not allow
            // mixing local and global symbols within a symbol table.
            try self.writeAllGlobalSymbols();

            if (self.debug_abbrev_section_dirty) {
                const debug_abbrev_sect = &self.sections.items[self.debug_abbrev_section_index.?];

                // These are LEB encoded but since the values are all less than 127
                // we can simply append these bytes.
                const abbrev_buf = [_]u8{
                    abbrev_compile_unit, DW.TAG_compile_unit, DW.CHILDREN_yes, // header
                    DW.AT_stmt_list,  DW.FORM_sec_offset,
                    DW.AT_low_pc   ,  DW.FORM_addr,
                    DW.AT_high_pc  ,  DW.FORM_addr,
                    DW.AT_name     ,  DW.FORM_strp,
                    DW.AT_comp_dir ,  DW.FORM_strp,
                    DW.AT_producer ,  DW.FORM_strp,
                    DW.AT_language ,  DW.FORM_data2,
                    0, 0, // table sentinel

                    abbrev_subprogram, DW.TAG_subprogram, DW.CHILDREN_yes, // header
                    DW.AT_low_pc   ,  DW.FORM_addr,
                    DW.AT_high_pc  ,  DW.FORM_data4,
                    DW.AT_type     ,  DW.FORM_ref4,
                    DW.AT_name     ,  DW.FORM_string,
                    0, 0, // table sentinel

                    abbrev_subprogram_retvoid, DW.TAG_subprogram, DW.CHILDREN_yes, // header
                    DW.AT_low_pc   ,  DW.FORM_addr,
                    DW.AT_high_pc  ,  DW.FORM_data4,
                    DW.AT_name     ,  DW.FORM_string,
                    0, 0, // table sentinel

                    abbrev_base_type, DW.TAG_base_type, DW.CHILDREN_no, // header
                    DW.AT_encoding ,  DW.FORM_data1,
                    DW.AT_byte_size,  DW.FORM_data1,
                    DW.AT_name     ,  DW.FORM_string,
                    0, 0, // table sentinel

                    abbrev_pad1, DW.TAG_unspecified_type, DW.CHILDREN_no, // header
                    0, 0, // table sentinel

                    abbrev_parameter, DW.TAG_formal_parameter, DW.CHILDREN_no, // header
                    DW.AT_location ,  DW.FORM_exprloc,
                    DW.AT_type     ,  DW.FORM_ref4,
                    DW.AT_name     ,  DW.FORM_string,
                    0, 0, // table sentinel

                    0, 0, 0, // section sentinel
                };

                const needed_size = abbrev_buf.len;
                const allocated_size = self.allocatedSize(debug_abbrev_sect.sh_offset);
                if (needed_size > allocated_size) {
                    debug_abbrev_sect.sh_size = 0; // free the space
                    debug_abbrev_sect.sh_offset = self.findFreeSpace(needed_size, 1);
                }
                debug_abbrev_sect.sh_size = needed_size;
                log.debug(.link, ".debug_abbrev start=0x{x} end=0x{x}\n", .{
                    debug_abbrev_sect.sh_offset,
                    debug_abbrev_sect.sh_offset + needed_size,
                });

                const abbrev_offset = 0;
                self.debug_abbrev_table_offset = abbrev_offset;
                try self.base.file.?.pwriteAll(&abbrev_buf, debug_abbrev_sect.sh_offset + abbrev_offset);
                if (!self.shdr_table_dirty) {
                    // Then it won't get written with the others and we need to do it.
                    try self.writeSectHeader(self.debug_abbrev_section_index.?);
                }

                self.debug_abbrev_section_dirty = false;
            }

            if (self.debug_info_header_dirty) debug_info: {
                // If this value is null it means there is an error in the module;
                // leave debug_info_header_dirty=true.
                const first_dbg_info_decl = self.dbg_info_decl_first orelse break :debug_info;
                const last_dbg_info_decl = self.dbg_info_decl_last.?;
                const debug_info_sect = &self.sections.items[self.debug_info_section_index.?];

                var di_buf = std.ArrayList(u8).init(self.base.allocator);
                defer di_buf.deinit();

                // We have a function to compute the upper bound size, because it's needed
                // for determining where to put the offset of the first `LinkBlock`.
                try di_buf.ensureCapacity(self.dbgInfoNeededHeaderBytes());

                // initial length - length of the .debug_info contribution for this compilation unit,
                // not including the initial length itself.
                // We have to come back and write it later after we know the size.
                const after_init_len = di_buf.items.len + init_len_size;
                // +1 for the final 0 that ends the compilation unit children.
                const dbg_info_end = last_dbg_info_decl.dbg_info_off + last_dbg_info_decl.dbg_info_len + 1;
                const init_len = dbg_info_end - after_init_len;
                switch (self.ptr_width) {
                    .p32 => {
                        mem.writeInt(u32, di_buf.addManyAsArrayAssumeCapacity(4), @intCast(u32, init_len), target_endian);
                    },
                    .p64 => {
                        di_buf.appendNTimesAssumeCapacity(0xff, 4);
                        mem.writeInt(u64, di_buf.addManyAsArrayAssumeCapacity(8), init_len, target_endian);
                    },
                }
                mem.writeInt(u16, di_buf.addManyAsArrayAssumeCapacity(2), 4, target_endian); // DWARF version
                const abbrev_offset = self.debug_abbrev_table_offset.?;
                switch (self.ptr_width) {
                    .p32 => {
                        mem.writeInt(u32, di_buf.addManyAsArrayAssumeCapacity(4), @intCast(u32, abbrev_offset), target_endian);
                        di_buf.appendAssumeCapacity(4); // address size
                    },
                    .p64 => {
                        mem.writeInt(u64, di_buf.addManyAsArrayAssumeCapacity(8), abbrev_offset, target_endian);
                        di_buf.appendAssumeCapacity(8); // address size
                    },
                }
                // Write the form for the compile unit, which must match the abbrev table above.
                const name_strp = try self.makeDebugString(self.base.options.root_pkg.root_src_path);
                const comp_dir_strp = try self.makeDebugString(self.base.options.root_pkg.root_src_dir_path);
                const producer_strp = try self.makeDebugString(producer_string);
                // Currently only one compilation unit is supported, so the address range is simply
                // identical to the main program header virtual address and memory size.
                const text_phdr = &self.program_headers.items[self.phdr_load_re_index.?];
                const low_pc = text_phdr.p_vaddr;
                const high_pc = text_phdr.p_vaddr + text_phdr.p_memsz;

                di_buf.appendAssumeCapacity(abbrev_compile_unit);
                self.writeDwarfAddrAssumeCapacity(&di_buf, 0); // DW.AT_stmt_list, DW.FORM_sec_offset
                self.writeDwarfAddrAssumeCapacity(&di_buf, low_pc);
                self.writeDwarfAddrAssumeCapacity(&di_buf, high_pc);
                self.writeDwarfAddrAssumeCapacity(&di_buf, name_strp);
                self.writeDwarfAddrAssumeCapacity(&di_buf, comp_dir_strp);
                self.writeDwarfAddrAssumeCapacity(&di_buf, producer_strp);
                // We are still waiting on dwarf-std.org to assign DW_LANG_Zig a number:
                // http://dwarfstd.org/ShowIssue.php?issue=171115.1
                // Until then we say it is C99.
                mem.writeInt(u16, di_buf.addManyAsArrayAssumeCapacity(2), DW.LANG_C99, target_endian);

                if (di_buf.items.len > first_dbg_info_decl.dbg_info_off) {
                    // Move the first N decls to the end to make more padding for the header.
                    @panic("TODO: handle .debug_info header exceeding its padding");
                }
                const jmp_amt = first_dbg_info_decl.dbg_info_off - di_buf.items.len;
                try self.pwriteDbgInfoNops(0, di_buf.items, jmp_amt, false, debug_info_sect.sh_offset);
                self.debug_info_header_dirty = false;
            }

            if (self.debug_aranges_section_dirty) {
                const debug_aranges_sect = &self.sections.items[self.debug_aranges_section_index.?];

                var di_buf = std.ArrayList(u8).init(self.base.allocator);
                defer di_buf.deinit();

                // Enough for all the data without resizing. When support for more compilation units
                // is added, the size of this section will become more variable.
                try di_buf.ensureCapacity(100);

                // initial length - length of the .debug_aranges contribution for this compilation unit,
                // not including the initial length itself.
                // We have to come back and write it later after we know the size.
                const init_len_index = di_buf.items.len;
                di_buf.items.len += init_len_size;
                const after_init_len = di_buf.items.len;
                mem.writeInt(u16, di_buf.addManyAsArrayAssumeCapacity(2), 2, target_endian); // version
                // When more than one compilation unit is supported, this will be the offset to it.
                // For now it is always at offset 0 in .debug_info.
                self.writeDwarfAddrAssumeCapacity(&di_buf, 0); // .debug_info offset
                di_buf.appendAssumeCapacity(ptr_width_bytes); // address_size
                di_buf.appendAssumeCapacity(0); // segment_selector_size

                const end_header_offset = di_buf.items.len;
                const begin_entries_offset = mem.alignForward(end_header_offset, ptr_width_bytes * 2);
                di_buf.appendNTimesAssumeCapacity(0, begin_entries_offset - end_header_offset);

                // Currently only one compilation unit is supported, so the address range is simply
                // identical to the main program header virtual address and memory size.
                const text_phdr = &self.program_headers.items[self.phdr_load_re_index.?];
                self.writeDwarfAddrAssumeCapacity(&di_buf, text_phdr.p_vaddr);
                self.writeDwarfAddrAssumeCapacity(&di_buf, text_phdr.p_memsz);

                // Sentinel.
                self.writeDwarfAddrAssumeCapacity(&di_buf, 0);
                self.writeDwarfAddrAssumeCapacity(&di_buf, 0);

                // Go back and populate the initial length.
                const init_len = di_buf.items.len - after_init_len;
                switch (self.ptr_width) {
                    .p32 => {
                        mem.writeInt(u32, di_buf.items[init_len_index..][0..4], @intCast(u32, init_len), target_endian);
                    },
                    .p64 => {
                        // initial length - length of the .debug_aranges contribution for this compilation unit,
                        // not including the initial length itself.
                        di_buf.items[init_len_index..][0..4].* = [_]u8{ 0xff, 0xff, 0xff, 0xff };
                        mem.writeInt(u64, di_buf.items[init_len_index + 4..][0..8], init_len, target_endian);
                    },
                }

                const needed_size = di_buf.items.len;
                const allocated_size = self.allocatedSize(debug_aranges_sect.sh_offset);
                if (needed_size > allocated_size) {
                    debug_aranges_sect.sh_size = 0; // free the space
                    debug_aranges_sect.sh_offset = self.findFreeSpace(needed_size, 16);
                }
                debug_aranges_sect.sh_size = needed_size;
                log.debug(.link, ".debug_aranges start=0x{x} end=0x{x}\n", .{
                    debug_aranges_sect.sh_offset,
                    debug_aranges_sect.sh_offset + needed_size,
                });

                try self.base.file.?.pwriteAll(di_buf.items, debug_aranges_sect.sh_offset);
                if (!self.shdr_table_dirty) {
                    // Then it won't get written with the others and we need to do it.
                    try self.writeSectHeader(self.debug_aranges_section_index.?);
                }

                self.debug_aranges_section_dirty = false;
            }
            if (self.debug_line_header_dirty) debug_line: {
                if (self.dbg_line_fn_first == null) {
                    break :debug_line; // Error in module; leave debug_line_header_dirty=true.
                }
                const dbg_line_prg_off = self.getDebugLineProgramOff();
                const dbg_line_prg_end = self.getDebugLineProgramEnd();
                assert(dbg_line_prg_end != 0);

                const debug_line_sect = &self.sections.items[self.debug_line_section_index.?];

                var di_buf = std.ArrayList(u8).init(self.base.allocator);
                defer di_buf.deinit();

                // The size of this header is variable, depending on the number of directories,
                // files, and padding. We have a function to compute the upper bound size, however,
                // because it's needed for determining where to put the offset of the first `SrcFn`.
                try di_buf.ensureCapacity(self.dbgLineNeededHeaderBytes());

                // initial length - length of the .debug_line contribution for this compilation unit,
                // not including the initial length itself.
                const after_init_len = di_buf.items.len + init_len_size;
                const init_len = dbg_line_prg_end - after_init_len;
                switch (self.ptr_width) {
                    .p32 => {
                        mem.writeInt(u32, di_buf.addManyAsArrayAssumeCapacity(4), @intCast(u32, init_len), target_endian);
                    },
                    .p64 => {
                        di_buf.appendNTimesAssumeCapacity(0xff, 4);
                        mem.writeInt(u64, di_buf.addManyAsArrayAssumeCapacity(8), init_len, target_endian);
                    },
                }

                mem.writeInt(u16, di_buf.addManyAsArrayAssumeCapacity(2), 4, target_endian); // version

                // Empirically, debug info consumers do not respect this field, or otherwise
                // consider it to be an error when it does not point exactly to the end of the header.
                // Therefore we rely on the NOP jump at the beginning of the Line Number Program for
                // padding rather than this field.
                const before_header_len = di_buf.items.len;
                di_buf.items.len += ptr_width_bytes; // We will come back and write this.
                const after_header_len = di_buf.items.len;

                const opcode_base = DW.LNS_set_isa + 1;
                di_buf.appendSliceAssumeCapacity(&[_]u8{
                    1, // minimum_instruction_length
                    1, // maximum_operations_per_instruction
                    1, // default_is_stmt
                    1, // line_base (signed)
                    1, // line_range
                    opcode_base,

                    // Standard opcode lengths. The number of items here is based on `opcode_base`.
                    // The value is the number of LEB128 operands the instruction takes.
                    0, // `DW.LNS_copy`
                    1, // `DW.LNS_advance_pc`
                    1, // `DW.LNS_advance_line`
                    1, // `DW.LNS_set_file`
                    1, // `DW.LNS_set_column`
                    0, // `DW.LNS_negate_stmt`
                    0, // `DW.LNS_set_basic_block`
                    0, // `DW.LNS_const_add_pc`
                    1, // `DW.LNS_fixed_advance_pc`
                    0, // `DW.LNS_set_prologue_end`
                    0, // `DW.LNS_set_epilogue_begin`
                    1, // `DW.LNS_set_isa`

                    0, // include_directories (none except the compilation unit cwd)
                });
                // file_names[0]
                di_buf.appendSliceAssumeCapacity(self.base.options.root_pkg.root_src_path); // relative path name
                di_buf.appendSliceAssumeCapacity(&[_]u8{
                    0, // null byte for the relative path name
                    0, // directory_index
                    0, // mtime (TODO supply this)
                    0, // file size bytes (TODO supply this)
                    0, // file_names sentinel
                });

                const header_len = di_buf.items.len - after_header_len;
                switch (self.ptr_width) {
                    .p32 => {
                        mem.writeInt(u32, di_buf.items[before_header_len..][0..4], @intCast(u32, header_len), target_endian);
                    },
                    .p64 => {
                        mem.writeInt(u64, di_buf.items[before_header_len..][0..8], header_len, target_endian);
                    },
                }

                // We use NOPs because consumers empirically do not respect the header length field.
                if (di_buf.items.len > dbg_line_prg_off) {
                    // Move the first N files to the end to make more padding for the header.
                    @panic("TODO: handle .debug_line header exceeding its padding");
                }
                const jmp_amt = dbg_line_prg_off - di_buf.items.len;
                try self.pwriteDbgLineNops(0, di_buf.items, jmp_amt, debug_line_sect.sh_offset);
                self.debug_line_header_dirty = false;
            }

            if (self.phdr_table_dirty) {
                const phsize: u64 = switch (self.ptr_width) {
                    .p32 => @sizeOf(elf.Elf32_Phdr),
                    .p64 => @sizeOf(elf.Elf64_Phdr),
                };
                const phalign: u16 = switch (self.ptr_width) {
                    .p32 => @alignOf(elf.Elf32_Phdr),
                    .p64 => @alignOf(elf.Elf64_Phdr),
                };
                const allocated_size = self.allocatedSize(self.phdr_table_offset.?);
                const needed_size = self.program_headers.items.len * phsize;

                if (needed_size > allocated_size) {
                    self.phdr_table_offset = null; // free the space
                    self.phdr_table_offset = self.findFreeSpace(needed_size, phalign);
                }

                switch (self.ptr_width) {
                    .p32 => {
                        const buf = try self.base.allocator.alloc(elf.Elf32_Phdr, self.program_headers.items.len);
                        defer self.base.allocator.free(buf);

                        for (buf) |*phdr, i| {
                            phdr.* = progHeaderTo32(self.program_headers.items[i]);
                            if (foreign_endian) {
                                bswapAllFields(elf.Elf32_Phdr, phdr);
                            }
                        }
                        try self.base.file.?.pwriteAll(mem.sliceAsBytes(buf), self.phdr_table_offset.?);
                    },
                    .p64 => {
                        const buf = try self.base.allocator.alloc(elf.Elf64_Phdr, self.program_headers.items.len);
                        defer self.base.allocator.free(buf);

                        for (buf) |*phdr, i| {
                            phdr.* = self.program_headers.items[i];
                            if (foreign_endian) {
                                bswapAllFields(elf.Elf64_Phdr, phdr);
                            }
                        }
                        try self.base.file.?.pwriteAll(mem.sliceAsBytes(buf), self.phdr_table_offset.?);
                    },
                }
                self.phdr_table_dirty = false;
            }

            {
                const shstrtab_sect = &self.sections.items[self.shstrtab_index.?];
                if (self.shstrtab_dirty or self.shstrtab.items.len != shstrtab_sect.sh_size) {
                    const allocated_size = self.allocatedSize(shstrtab_sect.sh_offset);
                    const needed_size = self.shstrtab.items.len;

                    if (needed_size > allocated_size) {
                        shstrtab_sect.sh_size = 0; // free the space
                        shstrtab_sect.sh_offset = self.findFreeSpace(needed_size, 1);
                    }
                    shstrtab_sect.sh_size = needed_size;
                    log.debug(.link, "writing shstrtab start=0x{x} end=0x{x}\n", .{ shstrtab_sect.sh_offset, shstrtab_sect.sh_offset + needed_size });

                    try self.base.file.?.pwriteAll(self.shstrtab.items, shstrtab_sect.sh_offset);
                    if (!self.shdr_table_dirty) {
                        // Then it won't get written with the others and we need to do it.
                        try self.writeSectHeader(self.shstrtab_index.?);
                    }
                    self.shstrtab_dirty = false;
                }
            }
            {
                const debug_strtab_sect = &self.sections.items[self.debug_str_section_index.?];
                if (self.debug_strtab_dirty or self.debug_strtab.items.len != debug_strtab_sect.sh_size) {
                    const allocated_size = self.allocatedSize(debug_strtab_sect.sh_offset);
                    const needed_size = self.debug_strtab.items.len;

                    if (needed_size > allocated_size) {
                        debug_strtab_sect.sh_size = 0; // free the space
                        debug_strtab_sect.sh_offset = self.findFreeSpace(needed_size, 1);
                    }
                    debug_strtab_sect.sh_size = needed_size;
                    log.debug(.link, "debug_strtab start=0x{x} end=0x{x}\n", .{ debug_strtab_sect.sh_offset, debug_strtab_sect.sh_offset + needed_size });

                    try self.base.file.?.pwriteAll(self.debug_strtab.items, debug_strtab_sect.sh_offset);
                    if (!self.shdr_table_dirty) {
                        // Then it won't get written with the others and we need to do it.
                        try self.writeSectHeader(self.debug_str_section_index.?);
                    }
                    self.debug_strtab_dirty = false;
                }
            }
            if (self.shdr_table_dirty) {
                const shsize: u64 = switch (self.ptr_width) {
                    .p32 => @sizeOf(elf.Elf32_Shdr),
                    .p64 => @sizeOf(elf.Elf64_Shdr),
                };
                const shalign: u16 = switch (self.ptr_width) {
                    .p32 => @alignOf(elf.Elf32_Shdr),
                    .p64 => @alignOf(elf.Elf64_Shdr),
                };
                const allocated_size = self.allocatedSize(self.shdr_table_offset.?);
                const needed_size = self.sections.items.len * shsize;

                if (needed_size > allocated_size) {
                    self.shdr_table_offset = null; // free the space
                    self.shdr_table_offset = self.findFreeSpace(needed_size, shalign);
                }

                switch (self.ptr_width) {
                    .p32 => {
                        const buf = try self.base.allocator.alloc(elf.Elf32_Shdr, self.sections.items.len);
                        defer self.base.allocator.free(buf);

                        for (buf) |*shdr, i| {
                            shdr.* = sectHeaderTo32(self.sections.items[i]);
                            std.log.debug(.link, "writing section {}\n", .{shdr.*});
                            if (foreign_endian) {
                                bswapAllFields(elf.Elf32_Shdr, shdr);
                            }
                        }
                        try self.base.file.?.pwriteAll(mem.sliceAsBytes(buf), self.shdr_table_offset.?);
                    },
                    .p64 => {
                        const buf = try self.base.allocator.alloc(elf.Elf64_Shdr, self.sections.items.len);
                        defer self.base.allocator.free(buf);

                        for (buf) |*shdr, i| {
                            shdr.* = self.sections.items[i];
                            log.debug(.link, "writing section {}\n", .{shdr.*});
                            if (foreign_endian) {
                                bswapAllFields(elf.Elf64_Shdr, shdr);
                            }
                        }
                        try self.base.file.?.pwriteAll(mem.sliceAsBytes(buf), self.shdr_table_offset.?);
                    },
                }
                self.shdr_table_dirty = false;
            }
            if (self.entry_addr == null and self.base.options.output_mode == .Exe) {
                log.debug(.link, "flushing. no_entry_point_found = true\n", .{});
                self.error_flags.no_entry_point_found = true;
            } else {
                log.debug(.link, "flushing. no_entry_point_found = false\n", .{});
                self.error_flags.no_entry_point_found = false;
                try self.writeElfHeader();
            }

            // The point of flush() is to commit changes, so in theory, nothing should
            // be dirty after this. However, it is possible for some things to remain
            // dirty because they fail to be written in the event of compile errors,
            // such as debug_line_header_dirty and debug_info_header_dirty.
            assert(!self.debug_abbrev_section_dirty);
            assert(!self.debug_aranges_section_dirty);
            assert(!self.phdr_table_dirty);
            assert(!self.shdr_table_dirty);
            assert(!self.shstrtab_dirty);
            assert(!self.debug_strtab_dirty);
        }

        fn writeDwarfAddrAssumeCapacity(self: *Elf, buf: *std.ArrayList(u8), addr: u64) void {
            const target_endian = self.base.options.target.cpu.arch.endian();
            switch (self.ptr_width) {
                .p32 => mem.writeInt(u32, buf.addManyAsArrayAssumeCapacity(4), @intCast(u32, addr), target_endian),
                .p64 => mem.writeInt(u64, buf.addManyAsArrayAssumeCapacity(8), addr, target_endian),
            }
        }

        fn writeElfHeader(self: *Elf) !void {
            var hdr_buf: [@sizeOf(elf.Elf64_Ehdr)]u8 = undefined;

            var index: usize = 0;
            hdr_buf[0..4].* = "\x7fELF".*;
            index += 4;

            hdr_buf[index] = switch (self.ptr_width) {
                .p32 => elf.ELFCLASS32,
                .p64 => elf.ELFCLASS64,
            };
            index += 1;

            const endian = self.base.options.target.cpu.arch.endian();
            hdr_buf[index] = switch (endian) {
                .Little => elf.ELFDATA2LSB,
                .Big => elf.ELFDATA2MSB,
            };
            index += 1;

            hdr_buf[index] = 1; // ELF version
            index += 1;

            // OS ABI, often set to 0 regardless of target platform
            // ABI Version, possibly used by glibc but not by static executables
            // padding
            mem.set(u8, hdr_buf[index..][0..9], 0);
            index += 9;

            assert(index == 16);

            const elf_type = switch (self.base.options.output_mode) {
                .Exe => elf.ET.EXEC,
                .Obj => elf.ET.REL,
                .Lib => switch (self.base.options.link_mode) {
                    .Static => elf.ET.REL,
                    .Dynamic => elf.ET.DYN,
                },
            };
            mem.writeInt(u16, hdr_buf[index..][0..2], @enumToInt(elf_type), endian);
            index += 2;

            const machine = self.base.options.target.cpu.arch.toElfMachine();
            mem.writeInt(u16, hdr_buf[index..][0..2], @enumToInt(machine), endian);
            index += 2;

            // ELF Version, again
            mem.writeInt(u32, hdr_buf[index..][0..4], 1, endian);
            index += 4;

            const e_entry = if (elf_type == .REL) 0 else self.entry_addr.?;

            switch (self.ptr_width) {
                .p32 => {
                    mem.writeInt(u32, hdr_buf[index..][0..4], @intCast(u32, e_entry), endian);
                    index += 4;

                    // e_phoff
                    mem.writeInt(u32, hdr_buf[index..][0..4], @intCast(u32, self.phdr_table_offset.?), endian);
                    index += 4;

                    // e_shoff
                    mem.writeInt(u32, hdr_buf[index..][0..4], @intCast(u32, self.shdr_table_offset.?), endian);
                    index += 4;
                },
                .p64 => {
                    // e_entry
                    mem.writeInt(u64, hdr_buf[index..][0..8], e_entry, endian);
                    index += 8;

                    // e_phoff
                    mem.writeInt(u64, hdr_buf[index..][0..8], self.phdr_table_offset.?, endian);
                    index += 8;

                    // e_shoff
                    mem.writeInt(u64, hdr_buf[index..][0..8], self.shdr_table_offset.?, endian);
                    index += 8;
                },
            }

            const e_flags = 0;
            mem.writeInt(u32, hdr_buf[index..][0..4], e_flags, endian);
            index += 4;

            const e_ehsize: u16 = switch (self.ptr_width) {
                .p32 => @sizeOf(elf.Elf32_Ehdr),
                .p64 => @sizeOf(elf.Elf64_Ehdr),
            };
            mem.writeInt(u16, hdr_buf[index..][0..2], e_ehsize, endian);
            index += 2;

            const e_phentsize: u16 = switch (self.ptr_width) {
                .p32 => @sizeOf(elf.Elf32_Phdr),
                .p64 => @sizeOf(elf.Elf64_Phdr),
            };
            mem.writeInt(u16, hdr_buf[index..][0..2], e_phentsize, endian);
            index += 2;

            const e_phnum = @intCast(u16, self.program_headers.items.len);
            mem.writeInt(u16, hdr_buf[index..][0..2], e_phnum, endian);
            index += 2;

            const e_shentsize: u16 = switch (self.ptr_width) {
                .p32 => @sizeOf(elf.Elf32_Shdr),
                .p64 => @sizeOf(elf.Elf64_Shdr),
            };
            mem.writeInt(u16, hdr_buf[index..][0..2], e_shentsize, endian);
            index += 2;

            const e_shnum = @intCast(u16, self.sections.items.len);
            mem.writeInt(u16, hdr_buf[index..][0..2], e_shnum, endian);
            index += 2;

            mem.writeInt(u16, hdr_buf[index..][0..2], self.shstrtab_index.?, endian);
            index += 2;

            assert(index == e_ehsize);

            try self.base.file.?.pwriteAll(hdr_buf[0..index], 0);
        }

        fn freeTextBlock(self: *Elf, text_block: *TextBlock) void {
            var already_have_free_list_node = false;
            {
                var i: usize = 0;
                while (i < self.text_block_free_list.items.len) {
                    if (self.text_block_free_list.items[i] == text_block) {
                        _ = self.text_block_free_list.swapRemove(i);
                        continue;
                    }
                    if (self.text_block_free_list.items[i] == text_block.prev) {
                        already_have_free_list_node = true;
                    }
                    i += 1;
                }
            }

            if (self.last_text_block == text_block) {
                // TODO shrink the .text section size here
                self.last_text_block = text_block.prev;
            }

            if (text_block.prev) |prev| {
                prev.next = text_block.next;

                if (!already_have_free_list_node and prev.freeListEligible(self.*)) {
                    // The free list is heuristics, it doesn't have to be perfect, so we can
                    // ignore the OOM here.
                    self.text_block_free_list.append(self.base.allocator, prev) catch {};
                }
            } else {
                text_block.prev = null;
            }

            if (text_block.next) |next| {
                next.prev = text_block.prev;
            } else {
                text_block.next = null;
            }
        }

        fn shrinkTextBlock(self: *Elf, text_block: *TextBlock, new_block_size: u64) void {
            // TODO check the new capacity, and if it crosses the size threshold into a big enough
            // capacity, insert a free list node for it.
        }

        fn growTextBlock(self: *Elf, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
            const sym = self.local_symbols.items[text_block.local_sym_index];
            const align_ok = mem.alignBackwardGeneric(u64, sym.st_value, alignment) == sym.st_value;
            const need_realloc = !align_ok or new_block_size > text_block.capacity(self.*);
            if (!need_realloc) return sym.st_value;
            return self.allocateTextBlock(text_block, new_block_size, alignment);
        }

        fn allocateTextBlock(self: *Elf, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
            const phdr = &self.program_headers.items[self.phdr_load_re_index.?];
            const shdr = &self.sections.items[self.text_section_index.?];
            const new_block_ideal_capacity = new_block_size * alloc_num / alloc_den;

            // We use these to indicate our intention to update metadata, placing the new block,
            // and possibly removing a free list node.
            // It would be simpler to do it inside the for loop below, but that would cause a
            // problem if an error was returned later in the function. So this action
            // is actually carried out at the end of the function, when errors are no longer possible.
            var block_placement: ?*TextBlock = null;
            var free_list_removal: ?usize = null;

            // First we look for an appropriately sized free list node.
            // The list is unordered. We'll just take the first thing that works.
            const vaddr = blk: {
                var i: usize = 0;
                while (i < self.text_block_free_list.items.len) {
                    const big_block = self.text_block_free_list.items[i];
                    // We now have a pointer to a live text block that has too much capacity.
                    // Is it enough that we could fit this new text block?
                    const sym = self.local_symbols.items[big_block.local_sym_index];
                    const capacity = big_block.capacity(self.*);
                    const ideal_capacity = capacity * alloc_num / alloc_den;
                    const ideal_capacity_end_vaddr = sym.st_value + ideal_capacity;
                    const capacity_end_vaddr = sym.st_value + capacity;
                    const new_start_vaddr_unaligned = capacity_end_vaddr - new_block_ideal_capacity;
                    const new_start_vaddr = mem.alignBackwardGeneric(u64, new_start_vaddr_unaligned, alignment);
                    if (new_start_vaddr < ideal_capacity_end_vaddr) {
                        // Additional bookkeeping here to notice if this free list node
                        // should be deleted because the block that it points to has grown to take up
                        // more of the extra capacity.
                        if (!big_block.freeListEligible(self.*)) {
                            _ = self.text_block_free_list.swapRemove(i);
                        } else {
                            i += 1;
                        }
                        continue;
                    }
                    // At this point we know that we will place the new block here. But the
                    // remaining question is whether there is still yet enough capacity left
                    // over for there to still be a free list node.
                    const remaining_capacity = new_start_vaddr - ideal_capacity_end_vaddr;
                    const keep_free_list_node = remaining_capacity >= min_text_capacity;

                    // Set up the metadata to be updated, after errors are no longer possible.
                    block_placement = big_block;
                    if (!keep_free_list_node) {
                        free_list_removal = i;
                    }
                    break :blk new_start_vaddr;
                } else if (self.last_text_block) |last| {
                    const sym = self.local_symbols.items[last.local_sym_index];
                    const ideal_capacity = sym.st_size * alloc_num / alloc_den;
                    const ideal_capacity_end_vaddr = sym.st_value + ideal_capacity;
                    const new_start_vaddr = mem.alignForwardGeneric(u64, ideal_capacity_end_vaddr, alignment);
                    // Set up the metadata to be updated, after errors are no longer possible.
                    block_placement = last;
                    break :blk new_start_vaddr;
                } else {
                    break :blk phdr.p_vaddr;
                }
            };

            const expand_text_section = block_placement == null or block_placement.?.next == null;
            if (expand_text_section) {
                const text_capacity = self.allocatedSize(shdr.sh_offset);
                const needed_size = (vaddr + new_block_size) - phdr.p_vaddr;
                if (needed_size > text_capacity) {
                    // Must move the entire text section.
                    const new_offset = self.findFreeSpace(needed_size, 0x1000);
                    const text_size = if (self.last_text_block) |last| blk: {
                        const sym = self.local_symbols.items[last.local_sym_index];
                        break :blk (sym.st_value + sym.st_size) - phdr.p_vaddr;
                    } else 0;
                    const amt = try self.base.file.?.copyRangeAll(shdr.sh_offset, self.base.file.?, new_offset, text_size);
                    if (amt != text_size) return error.InputOutput;
                    shdr.sh_offset = new_offset;
                    phdr.p_offset = new_offset;
                }
                self.last_text_block = text_block;

                shdr.sh_size = needed_size;
                phdr.p_memsz = needed_size;
                phdr.p_filesz = needed_size;

                // The .debug_info section has `low_pc` and `high_pc` values which is the virtual address
                // range of the compilation unit. When we expand the text section, this range changes,
                // so the DW_TAG_compile_unit tag of the .debug_info section becomes dirty.
                self.debug_info_header_dirty = true;
                // This becomes dirty for the same reason. We could potentially make this more
                // fine-grained with the addition of support for more compilation units. It is planned to
                // model each package as a different compilation unit.
                self.debug_aranges_section_dirty = true;

                self.phdr_table_dirty = true; // TODO look into making only the one program header dirty
                self.shdr_table_dirty = true; // TODO look into making only the one section dirty
            }

            // This function can also reallocate a text block.
            // In this case we need to "unplug" it from its previous location before
            // plugging it in to its new location.
            if (text_block.prev) |prev| {
                prev.next = text_block.next;
            }
            if (text_block.next) |next| {
                next.prev = text_block.prev;
            }

            if (block_placement) |big_block| {
                text_block.prev = big_block;
                text_block.next = big_block.next;
                big_block.next = text_block;
            } else {
                text_block.prev = null;
                text_block.next = null;
            }
            if (free_list_removal) |i| {
                _ = self.text_block_free_list.swapRemove(i);
            }
            return vaddr;
        }

        pub fn allocateDeclIndexes(self: *Elf, decl: *Module.Decl) !void {
            if (decl.link.elf.local_sym_index != 0) return;

            try self.local_symbols.ensureCapacity(self.base.allocator, self.local_symbols.items.len + 1);
            try self.offset_table.ensureCapacity(self.base.allocator, self.offset_table.items.len + 1);

            if (self.local_symbol_free_list.popOrNull()) |i| {
                log.debug(.link, "reusing symbol index {} for {}\n", .{ i, decl.name });
                decl.link.elf.local_sym_index = i;
            } else {
                log.debug(.link, "allocating symbol index {} for {}\n", .{ self.local_symbols.items.len, decl.name });
                decl.link.elf.local_sym_index = @intCast(u32, self.local_symbols.items.len);
                _ = self.local_symbols.addOneAssumeCapacity();
            }

            if (self.offset_table_free_list.popOrNull()) |i| {
                decl.link.elf.offset_table_index = i;
            } else {
                decl.link.elf.offset_table_index = @intCast(u32, self.offset_table.items.len);
                _ = self.offset_table.addOneAssumeCapacity();
                self.offset_table_count_dirty = true;
            }

            const phdr = &self.program_headers.items[self.phdr_load_re_index.?];

            self.local_symbols.items[decl.link.elf.local_sym_index] = .{
                .st_name = 0,
                .st_info = 0,
                .st_other = 0,
                .st_shndx = 0,
                .st_value = phdr.p_vaddr,
                .st_size = 0,
            };
            self.offset_table.items[decl.link.elf.offset_table_index] = 0;
        }

        pub fn freeDecl(self: *Elf, decl: *Module.Decl) void {
            // Appending to free lists is allowed to fail because the free lists are heuristics based anyway.
            self.freeTextBlock(&decl.link.elf);
            if (decl.link.elf.local_sym_index != 0) {
                self.local_symbol_free_list.append(self.base.allocator, decl.link.elf.local_sym_index) catch {};
                self.offset_table_free_list.append(self.base.allocator, decl.link.elf.offset_table_index) catch {};

                self.local_symbols.items[decl.link.elf.local_sym_index].st_info = 0;

                decl.link.elf.local_sym_index = 0;
            }
            // TODO make this logic match freeTextBlock. Maybe abstract the logic out since the same thing
            // is desired for both.
            _ = self.dbg_line_fn_free_list.remove(&decl.fn_link.elf);
            if (decl.fn_link.elf.prev) |prev| {
                _ = self.dbg_line_fn_free_list.put(self.base.allocator, prev, {}) catch {};
                prev.next = decl.fn_link.elf.next;
                if (decl.fn_link.elf.next) |next| {
                    next.prev = prev;
                } else {
                    self.dbg_line_fn_last = prev;
                }
            } else if (decl.fn_link.elf.next) |next| {
                self.dbg_line_fn_first = next;
                next.prev = null;
            }
            if (self.dbg_line_fn_first == &decl.fn_link.elf) {
                self.dbg_line_fn_first = null;
            }
            if (self.dbg_line_fn_last == &decl.fn_link.elf) {
                self.dbg_line_fn_last = null;
            }
        }

        pub fn updateDecl(self: *Elf, module: *Module, decl: *Module.Decl) !void {
            const tracy = trace(@src());
            defer tracy.end();

            var code_buffer = std.ArrayList(u8).init(self.base.allocator);
            defer code_buffer.deinit();

            var dbg_line_buffer = std.ArrayList(u8).init(self.base.allocator);
            defer dbg_line_buffer.deinit();

            var dbg_info_buffer = std.ArrayList(u8).init(self.base.allocator);
            defer dbg_info_buffer.deinit();

            var dbg_info_type_relocs: DbgInfoTypeRelocsTable = .{};
            defer {
                for (dbg_info_type_relocs.items()) |*entry| {
                    entry.value.relocs.deinit(self.base.allocator);
                }
                dbg_info_type_relocs.deinit(self.base.allocator);
            }

            const typed_value = decl.typed_value.most_recent.typed_value;
            const is_fn: bool = switch (typed_value.ty.zigTypeTag()) {
                .Fn => true,
                else => false,
            };
            if (is_fn) {
                //if (mem.eql(u8, mem.spanZ(decl.name), "add")) {
                //    typed_value.val.cast(Value.Payload.Function).?.func.dump(module.*);
                //}

                // For functions we need to add a prologue to the debug line program.
                try dbg_line_buffer.ensureCapacity(26);

                const line_off: u28 = blk: {
                    if (decl.scope.cast(Module.Scope.File)) |scope_file| {
                        const tree = scope_file.contents.tree;
                        const file_ast_decls = tree.root_node.decls();
                        // TODO Look into improving the performance here by adding a token-index-to-line
                        // lookup table. Currently this involves scanning over the source code for newlines.
                        const fn_proto = file_ast_decls[decl.src_index].castTag(.FnProto).?;
                        const block = fn_proto.body().?.castTag(.Block).?;
                        const line_delta = std.zig.lineDelta(tree.source, 0, tree.token_locs[block.lbrace].start);
                        break :blk @intCast(u28, line_delta);
                    } else if (decl.scope.cast(Module.Scope.ZIRModule)) |zir_module| {
                        const byte_off = zir_module.contents.module.decls[decl.src_index].inst.src;
                        const line_delta = std.zig.lineDelta(zir_module.source.bytes, 0, byte_off);
                        break :blk @intCast(u28, line_delta);
                    } else {
                        unreachable;
                    }
                };

                const ptr_width_bytes = self.ptrWidthBytes();
                dbg_line_buffer.appendSliceAssumeCapacity(&[_]u8{
                    DW.LNS_extended_op,
                    ptr_width_bytes + 1,
                    DW.LNE_set_address,
                });
                // This is the "relocatable" vaddr, corresponding to `code_buffer` index `0`.
                assert(dbg_line_vaddr_reloc_index == dbg_line_buffer.items.len);
                dbg_line_buffer.items.len += ptr_width_bytes;

                dbg_line_buffer.appendAssumeCapacity(DW.LNS_advance_line);
                // This is the "relocatable" relative line offset from the previous function's end curly
                // to this function's begin curly.
                assert(self.getRelocDbgLineOff() == dbg_line_buffer.items.len);
                // Here we use a ULEB128-fixed-4 to make sure this field can be overwritten later.
                leb128.writeUnsignedFixed(4, dbg_line_buffer.addManyAsArrayAssumeCapacity(4), line_off);

                dbg_line_buffer.appendAssumeCapacity(DW.LNS_set_file);
                assert(self.getRelocDbgFileIndex() == dbg_line_buffer.items.len);
                // Once we support more than one source file, this will have the ability to be more
                // than one possible value.
                const file_index = 1;
                leb128.writeUnsignedFixed(4, dbg_line_buffer.addManyAsArrayAssumeCapacity(4), file_index);

                // Emit a line for the begin curly with prologue_end=false. The codegen will
                // do the work of setting prologue_end=true and epilogue_begin=true.
                dbg_line_buffer.appendAssumeCapacity(DW.LNS_copy);

                // .debug_info subprogram
                const decl_name_with_null = decl.name[0..mem.lenZ(decl.name) + 1];
                try dbg_info_buffer.ensureCapacity(dbg_info_buffer.items.len + 25 + decl_name_with_null.len);

                const fn_ret_type = typed_value.ty.fnReturnType();
                const fn_ret_has_bits = fn_ret_type.hasCodeGenBits();
                if (fn_ret_has_bits) {
                    dbg_info_buffer.appendAssumeCapacity(abbrev_subprogram);
                } else {
                    dbg_info_buffer.appendAssumeCapacity(abbrev_subprogram_retvoid);
                }
                // These get overwritten after generating the machine code. These values are
                // "relocations" and have to be in this fixed place so that functions can be
                // moved in virtual address space.
                assert(dbg_info_low_pc_reloc_index == dbg_info_buffer.items.len);
                dbg_info_buffer.items.len += ptr_width_bytes; // DW.AT_low_pc,  DW.FORM_addr
                assert(self.getRelocDbgInfoSubprogramHighPC() == dbg_info_buffer.items.len);
                dbg_info_buffer.items.len += 4; // DW.AT_high_pc,  DW.FORM_data4
                if (fn_ret_has_bits) {
                    const gop = try dbg_info_type_relocs.getOrPut(self.base.allocator, fn_ret_type);
                    if (!gop.found_existing) {
                        gop.entry.value = .{
                            .off = undefined,
                            .relocs = .{},
                        };
                    }
                    try gop.entry.value.relocs.append(self.base.allocator, @intCast(u32, dbg_info_buffer.items.len));
                    dbg_info_buffer.items.len += 4; // DW.AT_type,  DW.FORM_ref4
                }
                dbg_info_buffer.appendSliceAssumeCapacity(decl_name_with_null); // DW.AT_name, DW.FORM_string
            } else {
                // TODO implement .debug_info for global variables
            }
            const res = try codegen.generateSymbol(self, decl.src(), typed_value, &code_buffer, &dbg_line_buffer, &dbg_info_buffer, &dbg_info_type_relocs);
            const code = switch (res) {
                .externally_managed => |x| x,
                .appended => code_buffer.items,
                .fail => |em| {
                    decl.analysis = .codegen_failure;
                    try module.failed_decls.put(module.gpa, decl, em);
                    return;
                },
            };

            const required_alignment = typed_value.ty.abiAlignment(self.base.options.target);

            const stt_bits: u8 = if (is_fn) elf.STT_FUNC else elf.STT_OBJECT;

            assert(decl.link.elf.local_sym_index != 0); // Caller forgot to allocateDeclIndexes()
            const local_sym = &self.local_symbols.items[decl.link.elf.local_sym_index];
            if (local_sym.st_size != 0) {
                const capacity = decl.link.elf.capacity(self.*);
                const need_realloc = code.len > capacity or
                    !mem.isAlignedGeneric(u64, local_sym.st_value, required_alignment);
                if (need_realloc) {
                    const vaddr = try self.growTextBlock(&decl.link.elf, code.len, required_alignment);
                    log.debug(.link, "growing {} from 0x{x} to 0x{x}\n", .{ decl.name, local_sym.st_value, vaddr });
                    if (vaddr != local_sym.st_value) {
                        local_sym.st_value = vaddr;

                        log.debug(.link, "  (writing new offset table entry)\n", .{});
                        self.offset_table.items[decl.link.elf.offset_table_index] = vaddr;
                        try self.writeOffsetTableEntry(decl.link.elf.offset_table_index);
                    }
                } else if (code.len < local_sym.st_size) {
                    self.shrinkTextBlock(&decl.link.elf, code.len);
                }
                local_sym.st_size = code.len;
                local_sym.st_name = try self.updateString(local_sym.st_name, mem.spanZ(decl.name));
                local_sym.st_info = (elf.STB_LOCAL << 4) | stt_bits;
                local_sym.st_other = 0;
                local_sym.st_shndx = self.text_section_index.?;
                // TODO this write could be avoided if no fields of the symbol were changed.
                try self.writeSymbol(decl.link.elf.local_sym_index);
            } else {
                const decl_name = mem.spanZ(decl.name);
                const name_str_index = try self.makeString(decl_name);
                const vaddr = try self.allocateTextBlock(&decl.link.elf, code.len, required_alignment);
                log.debug(.link, "allocated text block for {} at 0x{x}\n", .{ decl_name, vaddr });
                errdefer self.freeTextBlock(&decl.link.elf);

                local_sym.* = .{
                    .st_name = name_str_index,
                    .st_info = (elf.STB_LOCAL << 4) | stt_bits,
                    .st_other = 0,
                    .st_shndx = self.text_section_index.?,
                    .st_value = vaddr,
                    .st_size = code.len,
                };
                self.offset_table.items[decl.link.elf.offset_table_index] = vaddr;

                try self.writeSymbol(decl.link.elf.local_sym_index);
                try self.writeOffsetTableEntry(decl.link.elf.offset_table_index);
            }

            const section_offset = local_sym.st_value - self.program_headers.items[self.phdr_load_re_index.?].p_vaddr;
            const file_offset = self.sections.items[self.text_section_index.?].sh_offset + section_offset;
            try self.base.file.?.pwriteAll(code, file_offset);

            const target_endian = self.base.options.target.cpu.arch.endian();

            const text_block = &decl.link.elf;

            // If the Decl is a function, we need to update the .debug_line program.
            if (is_fn) {
                // Perform the relocations based on vaddr.
                switch (self.ptr_width) {
                    .p32 => {
                        {
                            const ptr = dbg_line_buffer.items[dbg_line_vaddr_reloc_index..][0..4];
                            mem.writeInt(u32, ptr, @intCast(u32, local_sym.st_value), target_endian);
                        }
                        {
                            const ptr = dbg_info_buffer.items[dbg_info_low_pc_reloc_index..][0..4];
                            mem.writeInt(u32, ptr, @intCast(u32, local_sym.st_value), target_endian);
                        }
                    },
                    .p64 => {
                        {
                            const ptr = dbg_line_buffer.items[dbg_line_vaddr_reloc_index..][0..8];
                            mem.writeInt(u64, ptr, local_sym.st_value, target_endian);
                        }
                        {
                            const ptr = dbg_info_buffer.items[dbg_info_low_pc_reloc_index..][0..8];
                            mem.writeInt(u64, ptr, local_sym.st_value, target_endian);
                        }
                    },
                }
                {
                    const ptr = dbg_info_buffer.items[self.getRelocDbgInfoSubprogramHighPC()..][0..4];
                    mem.writeInt(u32, ptr, @intCast(u32, local_sym.st_size), target_endian);
                }

                try dbg_line_buffer.appendSlice(&[_]u8{ DW.LNS_extended_op, 1, DW.LNE_end_sequence });

                // Now we have the full contents and may allocate a region to store it.

                // This logic is nearly identical to the logic below in `updateDeclDebugInfo` for
                // `TextBlock` and the .debug_info. If you are editing this logic, you
                // probably need to edit that logic too.

                const debug_line_sect = &self.sections.items[self.debug_line_section_index.?];
                const src_fn = &decl.fn_link.elf;
                src_fn.len = @intCast(u32, dbg_line_buffer.items.len);
                if (self.dbg_line_fn_last) |last| {
                    if (src_fn.next) |next| {
                        // Update existing function - non-last item.
                        if (src_fn.off + src_fn.len + min_nop_size > next.off) {
                            // It grew too big, so we move it to a new location.
                            if (src_fn.prev) |prev| {
                                _ = self.dbg_line_fn_free_list.put(self.base.allocator, prev, {}) catch {};
                                prev.next = src_fn.next;
                            }
                            next.prev = src_fn.prev;
                            src_fn.next = null;
                            // Populate where it used to be with NOPs.
                            const file_pos = debug_line_sect.sh_offset + src_fn.off;
                            try self.pwriteDbgLineNops(0, &[0]u8{}, src_fn.len, file_pos);
                            // TODO Look at the free list before appending at the end.
                            src_fn.prev = last;
                            last.next = src_fn;
                            self.dbg_line_fn_last = src_fn;

                            src_fn.off = last.off + (last.len * alloc_num / alloc_den);
                        }
                    } else if (src_fn.prev == null) {
                        // Append new function.
                        // TODO Look at the free list before appending at the end.
                        src_fn.prev = last;
                        last.next = src_fn;
                        self.dbg_line_fn_last = src_fn;

                        src_fn.off = last.off + (last.len * alloc_num / alloc_den);
                    }
                } else {
                    // This is the first function of the Line Number Program.
                    self.dbg_line_fn_first = src_fn;
                    self.dbg_line_fn_last = src_fn;

                    src_fn.off = self.dbgLineNeededHeaderBytes() * alloc_num / alloc_den;
                }

                const last_src_fn = self.dbg_line_fn_last.?;
                const needed_size = last_src_fn.off + last_src_fn.len;
                if (needed_size != debug_line_sect.sh_size) {
                    if (needed_size > self.allocatedSize(debug_line_sect.sh_offset)) {
                        const new_offset = self.findFreeSpace(needed_size, 1);
                        const existing_size = last_src_fn.off;
                        log.debug(.link, "moving .debug_line section: {} bytes from 0x{x} to 0x{x}\n", .{
                            existing_size,
                            debug_line_sect.sh_offset,
                            new_offset,
                        });
                        const amt = try self.base.file.?.copyRangeAll(debug_line_sect.sh_offset, self.base.file.?, new_offset, existing_size);
                        if (amt != existing_size) return error.InputOutput;
                        debug_line_sect.sh_offset = new_offset;
                    }
                    debug_line_sect.sh_size = needed_size;
                    self.shdr_table_dirty = true; // TODO look into making only the one section dirty
                    self.debug_line_header_dirty = true;
                }
                const prev_padding_size: u32 = if (src_fn.prev) |prev| src_fn.off - (prev.off + prev.len) else 0;
                const next_padding_size: u32 = if (src_fn.next) |next| next.off - (src_fn.off + src_fn.len) else 0;

                // We only have support for one compilation unit so far, so the offsets are directly
                // from the .debug_line section.
                const file_pos = debug_line_sect.sh_offset + src_fn.off;
                try self.pwriteDbgLineNops(prev_padding_size, dbg_line_buffer.items, next_padding_size, file_pos);

                // .debug_info - End the TAG_subprogram children.
                try dbg_info_buffer.append(0);
            }

            // Now we emit the .debug_info types of the Decl. These will count towards the size of
            // the buffer, so we have to do it before computing the offset, and we can't perform the actual
            // relocations yet.
            for (dbg_info_type_relocs.items()) |*entry| {
                entry.value.off = @intCast(u32, dbg_info_buffer.items.len);
                try self.addDbgInfoType(entry.key, &dbg_info_buffer);
            }

            try self.updateDeclDebugInfoAllocation(text_block, @intCast(u32, dbg_info_buffer.items.len));

            // Now that we have the offset assigned we can finally perform type relocations.
            for (dbg_info_type_relocs.items()) |entry| {
                for (entry.value.relocs.items) |off| {
                    mem.writeInt(
                        u32,
                        dbg_info_buffer.items[off..][0..4],
                        text_block.dbg_info_off + entry.value.off,
                        target_endian,
                    );
                }
            }

            try self.writeDeclDebugInfo(text_block, dbg_info_buffer.items);

            // Since we updated the vaddr and the size, each corresponding export symbol also needs to be updated.
            const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
            return self.updateDeclExports(module, decl, decl_exports);
        }

        /// Asserts the type has codegen bits.
        fn addDbgInfoType(self: *Elf, ty: Type, dbg_info_buffer: *std.ArrayList(u8)) !void {
            switch (ty.zigTypeTag()) {
                .Void => unreachable,
                .NoReturn => unreachable,
                .Bool => {
                    try dbg_info_buffer.appendSlice(&[_]u8{
                        abbrev_base_type,
                        DW.ATE_boolean, // DW.AT_encoding ,  DW.FORM_data1
                        1, // DW.AT_byte_size,  DW.FORM_data1
                        'b', 'o', 'o', 'l', 0, // DW.AT_name,  DW.FORM_string
                    });
                },
                .Int => {
                    const info = ty.intInfo(self.base.options.target);
                    try dbg_info_buffer.ensureCapacity(dbg_info_buffer.items.len + 12);
                    dbg_info_buffer.appendAssumeCapacity(abbrev_base_type);
                    // DW.AT_encoding, DW.FORM_data1
                    dbg_info_buffer.appendAssumeCapacity(if (info.signed) DW.ATE_signed else DW.ATE_unsigned);
                    // DW.AT_byte_size,  DW.FORM_data1
                    dbg_info_buffer.appendAssumeCapacity(@intCast(u8, ty.abiSize(self.base.options.target)));
                    // DW.AT_name,  DW.FORM_string
                    try dbg_info_buffer.writer().print("{}\x00", .{ty});
                },
                else => {
                    log.err(.compiler, "TODO implement .debug_info for type '{}'", .{ty});
                    try dbg_info_buffer.append(abbrev_pad1);
                },
            }
        }

        fn updateDeclDebugInfoAllocation(self: *Elf, text_block: *TextBlock, len: u32) !void {
            const tracy = trace(@src());
            defer tracy.end();

            // This logic is nearly identical to the logic above in `updateDecl` for
            // `SrcFn` and the line number programs. If you are editing this logic, you
            // probably need to edit that logic too.

            const debug_info_sect = &self.sections.items[self.debug_info_section_index.?];
            text_block.dbg_info_len = len;
            if (self.dbg_info_decl_last) |last| {
                if (text_block.dbg_info_next) |next| {
                    // Update existing Decl - non-last item.
                    if (text_block.dbg_info_off + text_block.dbg_info_len + min_nop_size > next.dbg_info_off) {
                        // It grew too big, so we move it to a new location.
                        if (text_block.dbg_info_prev) |prev| {
                            _ = self.dbg_info_decl_free_list.put(self.base.allocator, prev, {}) catch {};
                            prev.dbg_info_next = text_block.dbg_info_next;
                        }
                        next.dbg_info_prev = text_block.dbg_info_prev;
                        text_block.dbg_info_next = null;
                        // Populate where it used to be with NOPs.
                        const file_pos = debug_info_sect.sh_offset + text_block.dbg_info_off;
                        try self.pwriteDbgInfoNops(0, &[0]u8{}, text_block.dbg_info_len, false, file_pos);
                        // TODO Look at the free list before appending at the end.
                        text_block.dbg_info_prev = last;
                        last.dbg_info_next = text_block;
                        self.dbg_info_decl_last = text_block;

                        text_block.dbg_info_off = last.dbg_info_off + (last.dbg_info_len * alloc_num / alloc_den);
                    }
                } else if (text_block.dbg_info_prev == null) {
                    // Append new Decl.
                    // TODO Look at the free list before appending at the end.
                    text_block.dbg_info_prev = last;
                    last.dbg_info_next = text_block;
                    self.dbg_info_decl_last = text_block;

                    text_block.dbg_info_off = last.dbg_info_off + (last.dbg_info_len * alloc_num / alloc_den);
                }
            } else {
                // This is the first Decl of the .debug_info
                self.dbg_info_decl_first = text_block;
                self.dbg_info_decl_last = text_block;

                text_block.dbg_info_off = self.dbgInfoNeededHeaderBytes() * alloc_num / alloc_den;
            }
        }

        fn writeDeclDebugInfo(self: *Elf, text_block: *TextBlock, dbg_info_buf: []const u8) !void {
            const tracy = trace(@src());
            defer tracy.end();

            // This logic is nearly identical to the logic above in `updateDecl` for
            // `SrcFn` and the line number programs. If you are editing this logic, you
            // probably need to edit that logic too.

            const debug_info_sect = &self.sections.items[self.debug_info_section_index.?];

            const last_decl = self.dbg_info_decl_last.?;
            // +1 for a trailing zero to end the children of the decl tag.
            const needed_size = last_decl.dbg_info_off + last_decl.dbg_info_len + 1;
            if (needed_size != debug_info_sect.sh_size) {
                if (needed_size > self.allocatedSize(debug_info_sect.sh_offset)) {
                    const new_offset = self.findFreeSpace(needed_size, 1);
                    const existing_size = last_decl.dbg_info_off;
                    log.debug(.link, "moving .debug_info section: {} bytes from 0x{x} to 0x{x}\n", .{
                        existing_size,
                        debug_info_sect.sh_offset,
                        new_offset,
                    });
                    const amt = try self.base.file.?.copyRangeAll(debug_info_sect.sh_offset, self.base.file.?, new_offset, existing_size);
                    if (amt != existing_size) return error.InputOutput;
                    debug_info_sect.sh_offset = new_offset;
                }
                debug_info_sect.sh_size = needed_size;
                self.shdr_table_dirty = true; // TODO look into making only the one section dirty
                self.debug_info_header_dirty = true;
            }
            const prev_padding_size: u32 = if (text_block.dbg_info_prev) |prev|
                text_block.dbg_info_off - (prev.dbg_info_off + prev.dbg_info_len)
            else
                0;
            const next_padding_size: u32 = if (text_block.dbg_info_next) |next|
                next.dbg_info_off - (text_block.dbg_info_off + text_block.dbg_info_len)
            else
                0;

            // To end the children of the decl tag.
            const trailing_zero = text_block.dbg_info_next == null;

            // We only have support for one compilation unit so far, so the offsets are directly
            // from the .debug_info section.
            const file_pos = debug_info_sect.sh_offset + text_block.dbg_info_off;
            try self.pwriteDbgInfoNops(prev_padding_size, dbg_info_buf, next_padding_size, trailing_zero, file_pos);
        }

        /// Must be called only after a successful call to `updateDecl`.
        pub fn updateDeclExports(
            self: *Elf,
            module: *Module,
            decl: *const Module.Decl,
            exports: []const *Module.Export,
        ) !void {
            const tracy = trace(@src());
            defer tracy.end();

            try self.global_symbols.ensureCapacity(self.base.allocator, self.global_symbols.items.len + exports.len);
            const typed_value = decl.typed_value.most_recent.typed_value;
            if (decl.link.elf.local_sym_index == 0) return;
            const decl_sym = self.local_symbols.items[decl.link.elf.local_sym_index];

            for (exports) |exp| {
                if (exp.options.section) |section_name| {
                    if (!mem.eql(u8, section_name, ".text")) {
                        try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.items().len + 1);
                        module.failed_exports.putAssumeCapacityNoClobber(
                            exp,
                            try Module.ErrorMsg.create(self.base.allocator, 0, "Unimplemented: ExportOptions.section", .{}),
                        );
                        continue;
                    }
                }
                const stb_bits: u8 = switch (exp.options.linkage) {
                    .Internal => elf.STB_LOCAL,
                    .Strong => blk: {
                        if (mem.eql(u8, exp.options.name, "_start")) {
                            self.entry_addr = decl_sym.st_value;
                        }
                        break :blk elf.STB_GLOBAL;
                    },
                    .Weak => elf.STB_WEAK,
                    .LinkOnce => {
                        try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.items().len + 1);
                        module.failed_exports.putAssumeCapacityNoClobber(
                            exp,
                            try Module.ErrorMsg.create(self.base.allocator, 0, "Unimplemented: GlobalLinkage.LinkOnce", .{}),
                        );
                        continue;
                    },
                };
                const stt_bits: u8 = @truncate(u4, decl_sym.st_info);
                if (exp.link.sym_index) |i| {
                    const sym = &self.global_symbols.items[i];
                    sym.* = .{
                        .st_name = try self.updateString(sym.st_name, exp.options.name),
                        .st_info = (stb_bits << 4) | stt_bits,
                        .st_other = 0,
                        .st_shndx = self.text_section_index.?,
                        .st_value = decl_sym.st_value,
                        .st_size = decl_sym.st_size,
                    };
                } else {
                    const name = try self.makeString(exp.options.name);
                    const i = if (self.global_symbol_free_list.popOrNull()) |i| i else blk: {
                        _ = self.global_symbols.addOneAssumeCapacity();
                        break :blk self.global_symbols.items.len - 1;
                    };
                    self.global_symbols.items[i] = .{
                        .st_name = name,
                        .st_info = (stb_bits << 4) | stt_bits,
                        .st_other = 0,
                        .st_shndx = self.text_section_index.?,
                        .st_value = decl_sym.st_value,
                        .st_size = decl_sym.st_size,
                    };

                    exp.link.sym_index = @intCast(u32, i);
                }
            }
        }

        /// Must be called only after a successful call to `updateDecl`.
        pub fn updateDeclLineNumber(self: *Elf, module: *Module, decl: *const Module.Decl) !void {
            const tracy = trace(@src());
            defer tracy.end();

            const scope_file = decl.scope.cast(Module.Scope.File).?;
            const tree = scope_file.contents.tree;
            const file_ast_decls = tree.root_node.decls();
            // TODO Look into improving the performance here by adding a token-index-to-line
            // lookup table. Currently this involves scanning over the source code for newlines.
            const fn_proto = file_ast_decls[decl.src_index].castTag(.FnProto).?;
            const block = fn_proto.body().?.castTag(.Block).?;
            const line_delta = std.zig.lineDelta(tree.source, 0, tree.token_locs[block.lbrace].start);
            const casted_line_off = @intCast(u28, line_delta);

            const shdr = &self.sections.items[self.debug_line_section_index.?];
            const file_pos = shdr.sh_offset + decl.fn_link.elf.off + self.getRelocDbgLineOff();
            var data: [4]u8 = undefined;
            leb128.writeUnsignedFixed(4, &data, casted_line_off);
            try self.base.file.?.pwriteAll(&data, file_pos);
        }

        pub fn deleteExport(self: *Elf, exp: Export) void {
            const sym_index = exp.sym_index orelse return;
            self.global_symbol_free_list.append(self.base.allocator, sym_index) catch {};
            self.global_symbols.items[sym_index].st_info = 0;
        }

        fn writeProgHeader(self: *Elf, index: usize) !void {
            const foreign_endian = self.base.options.target.cpu.arch.endian() != std.Target.current.cpu.arch.endian();
            const offset = self.program_headers.items[index].p_offset;
            switch (self.base.options.target.cpu.arch.ptrBitWidth()) {
                32 => {
                    var phdr = [1]elf.Elf32_Phdr{progHeaderTo32(self.program_headers.items[index])};
                    if (foreign_endian) {
                        bswapAllFields(elf.Elf32_Phdr, &phdr[0]);
                    }
                    return self.base.file.?.pwriteAll(mem.sliceAsBytes(&phdr), offset);
                },
                64 => {
                    var phdr = [1]elf.Elf64_Phdr{self.program_headers.items[index]};
                    if (foreign_endian) {
                        bswapAllFields(elf.Elf64_Phdr, &phdr[0]);
                    }
                    return self.base.file.?.pwriteAll(mem.sliceAsBytes(&phdr), offset);
                },
                else => return error.UnsupportedArchitecture,
            }
        }

        fn writeSectHeader(self: *Elf, index: usize) !void {
            const foreign_endian = self.base.options.target.cpu.arch.endian() != std.Target.current.cpu.arch.endian();
            switch (self.base.options.target.cpu.arch.ptrBitWidth()) {
                32 => {
                    var shdr: [1]elf.Elf32_Shdr = undefined;
                    shdr[0] = sectHeaderTo32(self.sections.items[index]);
                    if (foreign_endian) {
                        bswapAllFields(elf.Elf32_Shdr, &shdr[0]);
                    }
                    const offset = self.shdr_table_offset.? + index * @sizeOf(elf.Elf32_Shdr);
                    return self.base.file.?.pwriteAll(mem.sliceAsBytes(&shdr), offset);
                },
                64 => {
                    var shdr = [1]elf.Elf64_Shdr{self.sections.items[index]};
                    if (foreign_endian) {
                        bswapAllFields(elf.Elf64_Shdr, &shdr[0]);
                    }
                    const offset = self.shdr_table_offset.? + index * @sizeOf(elf.Elf64_Shdr);
                    return self.base.file.?.pwriteAll(mem.sliceAsBytes(&shdr), offset);
                },
                else => return error.UnsupportedArchitecture,
            }
        }

        fn writeOffsetTableEntry(self: *Elf, index: usize) !void {
            const shdr = &self.sections.items[self.got_section_index.?];
            const phdr = &self.program_headers.items[self.phdr_got_index.?];
            const entry_size: u16 = self.ptrWidthBytes();
            if (self.offset_table_count_dirty) {
                // TODO Also detect virtual address collisions.
                const allocated_size = self.allocatedSize(shdr.sh_offset);
                const needed_size = self.local_symbols.items.len * entry_size;
                if (needed_size > allocated_size) {
                    // Must move the entire got section.
                    const new_offset = self.findFreeSpace(needed_size, entry_size);
                    const amt = try self.base.file.?.copyRangeAll(shdr.sh_offset, self.base.file.?, new_offset, shdr.sh_size);
                    if (amt != shdr.sh_size) return error.InputOutput;
                    shdr.sh_offset = new_offset;
                    phdr.p_offset = new_offset;
                }
                shdr.sh_size = needed_size;
                phdr.p_memsz = needed_size;
                phdr.p_filesz = needed_size;

                self.shdr_table_dirty = true; // TODO look into making only the one section dirty
                self.phdr_table_dirty = true; // TODO look into making only the one program header dirty

                self.offset_table_count_dirty = false;
            }
            const endian = self.base.options.target.cpu.arch.endian();
            const off = shdr.sh_offset + @as(u64, entry_size) * index;
            switch (self.ptr_width) {
                .p32 => {
                    var buf: [4]u8 = undefined;
                    mem.writeInt(u32, &buf, @intCast(u32, self.offset_table.items[index]), endian);
                    try self.base.file.?.pwriteAll(&buf, off);
                },
                .p64 => {
                    var buf: [8]u8 = undefined;
                    mem.writeInt(u64, &buf, self.offset_table.items[index], endian);
                    try self.base.file.?.pwriteAll(&buf, off);
                },
            }
        }

        fn writeSymbol(self: *Elf, index: usize) !void {
            const tracy = trace(@src());
            defer tracy.end();

            const syms_sect = &self.sections.items[self.symtab_section_index.?];
            // Make sure we are not pointlessly writing symbol data that will have to get relocated
            // due to running out of space.
            if (self.local_symbols.items.len != syms_sect.sh_info) {
                const sym_size: u64 = switch (self.ptr_width) {
                    .p32 => @sizeOf(elf.Elf32_Sym),
                    .p64 => @sizeOf(elf.Elf64_Sym),
                };
                const sym_align: u16 = switch (self.ptr_width) {
                    .p32 => @alignOf(elf.Elf32_Sym),
                    .p64 => @alignOf(elf.Elf64_Sym),
                };
                const needed_size = (self.local_symbols.items.len + self.global_symbols.items.len) * sym_size;
                if (needed_size > self.allocatedSize(syms_sect.sh_offset)) {
                    // Move all the symbols to a new file location.
                    const new_offset = self.findFreeSpace(needed_size, sym_align);
                    const existing_size = @as(u64, syms_sect.sh_info) * sym_size;
                    const amt = try self.base.file.?.copyRangeAll(syms_sect.sh_offset, self.base.file.?, new_offset, existing_size);
                    if (amt != existing_size) return error.InputOutput;
                    syms_sect.sh_offset = new_offset;
                }
                syms_sect.sh_info = @intCast(u32, self.local_symbols.items.len);
                syms_sect.sh_size = needed_size; // anticipating adding the global symbols later
                self.shdr_table_dirty = true; // TODO look into only writing one section
            }
            const foreign_endian = self.base.options.target.cpu.arch.endian() != std.Target.current.cpu.arch.endian();
            switch (self.ptr_width) {
                .p32 => {
                    var sym = [1]elf.Elf32_Sym{
                        .{
                            .st_name = self.local_symbols.items[index].st_name,
                            .st_value = @intCast(u32, self.local_symbols.items[index].st_value),
                            .st_size = @intCast(u32, self.local_symbols.items[index].st_size),
                            .st_info = self.local_symbols.items[index].st_info,
                            .st_other = self.local_symbols.items[index].st_other,
                            .st_shndx = self.local_symbols.items[index].st_shndx,
                        },
                    };
                    if (foreign_endian) {
                        bswapAllFields(elf.Elf32_Sym, &sym[0]);
                    }
                    const off = syms_sect.sh_offset + @sizeOf(elf.Elf32_Sym) * index;
                    try self.base.file.?.pwriteAll(mem.sliceAsBytes(sym[0..1]), off);
                },
                .p64 => {
                    var sym = [1]elf.Elf64_Sym{self.local_symbols.items[index]};
                    if (foreign_endian) {
                        bswapAllFields(elf.Elf64_Sym, &sym[0]);
                    }
                    const off = syms_sect.sh_offset + @sizeOf(elf.Elf64_Sym) * index;
                    try self.base.file.?.pwriteAll(mem.sliceAsBytes(sym[0..1]), off);
                },
            }
        }

        fn writeAllGlobalSymbols(self: *Elf) !void {
            const syms_sect = &self.sections.items[self.symtab_section_index.?];
            const sym_size: u64 = switch (self.ptr_width) {
                .p32 => @sizeOf(elf.Elf32_Sym),
                .p64 => @sizeOf(elf.Elf64_Sym),
            };
            const foreign_endian = self.base.options.target.cpu.arch.endian() != std.Target.current.cpu.arch.endian();
            const global_syms_off = syms_sect.sh_offset + self.local_symbols.items.len * sym_size;
            switch (self.ptr_width) {
                .p32 => {
                    const buf = try self.base.allocator.alloc(elf.Elf32_Sym, self.global_symbols.items.len);
                    defer self.base.allocator.free(buf);

                    for (buf) |*sym, i| {
                        sym.* = .{
                            .st_name = self.global_symbols.items[i].st_name,
                            .st_value = @intCast(u32, self.global_symbols.items[i].st_value),
                            .st_size = @intCast(u32, self.global_symbols.items[i].st_size),
                            .st_info = self.global_symbols.items[i].st_info,
                            .st_other = self.global_symbols.items[i].st_other,
                            .st_shndx = self.global_symbols.items[i].st_shndx,
                        };
                        if (foreign_endian) {
                            bswapAllFields(elf.Elf32_Sym, sym);
                        }
                    }
                    try self.base.file.?.pwriteAll(mem.sliceAsBytes(buf), global_syms_off);
                },
                .p64 => {
                    const buf = try self.base.allocator.alloc(elf.Elf64_Sym, self.global_symbols.items.len);
                    defer self.base.allocator.free(buf);

                    for (buf) |*sym, i| {
                        sym.* = .{
                            .st_name = self.global_symbols.items[i].st_name,
                            .st_value = self.global_symbols.items[i].st_value,
                            .st_size = self.global_symbols.items[i].st_size,
                            .st_info = self.global_symbols.items[i].st_info,
                            .st_other = self.global_symbols.items[i].st_other,
                            .st_shndx = self.global_symbols.items[i].st_shndx,
                        };
                        if (foreign_endian) {
                            bswapAllFields(elf.Elf64_Sym, sym);
                        }
                    }
                    try self.base.file.?.pwriteAll(mem.sliceAsBytes(buf), global_syms_off);
                },
            }
        }

        fn ptrWidthBytes(self: Elf) u8 {
            return switch (self.ptr_width) {
                .p32 => 4,
                .p64 => 8,
            };
        }

        /// The reloc offset for the virtual address of a function in its Line Number Program.
        /// Size is a virtual address integer.
        const dbg_line_vaddr_reloc_index = 3;
        /// The reloc offset for the virtual address of a function in its .debug_info TAG_subprogram.
        /// Size is a virtual address integer.
        const dbg_info_low_pc_reloc_index = 1;

        /// The reloc offset for the line offset of a function from the previous function's line.
        /// It's a fixed-size 4-byte ULEB128.
        fn getRelocDbgLineOff(self: Elf) usize {
            return dbg_line_vaddr_reloc_index + self.ptrWidthBytes() + 1;
        }

        fn getRelocDbgFileIndex(self: Elf) usize {
            return self.getRelocDbgLineOff() + 5;
        }

        fn getRelocDbgInfoSubprogramHighPC(self: Elf) u32 {
            return dbg_info_low_pc_reloc_index + self.ptrWidthBytes();
        }

        fn dbgLineNeededHeaderBytes(self: Elf) u32 {
            const directory_entry_format_count = 1;
            const file_name_entry_format_count = 1;
            const directory_count = 1;
            const file_name_count = 1;
            return @intCast(u32, 53 + directory_entry_format_count * 2 + file_name_entry_format_count * 2 +
                directory_count * 8 + file_name_count * 8 +
                // These are encoded as DW.FORM_string rather than DW.FORM_strp as we would like
                // because of a workaround for readelf and gdb failing to understand DWARFv5 correctly.
                self.base.options.root_pkg.root_src_dir_path.len +
                self.base.options.root_pkg.root_src_path.len);

        }

        fn dbgInfoNeededHeaderBytes(self: Elf) u32 {
            return 120;
        }

        const min_nop_size = 2;

        /// Writes to the file a buffer, prefixed and suffixed by the specified number of
        /// bytes of NOPs. Asserts each padding size is at least `min_nop_size` and total padding bytes
        /// are less than 126,976 bytes (if this limit is ever reached, this function can be
        /// improved to make more than one pwritev call, or the limit can be raised by a fixed
        /// amount by increasing the length of `vecs`).
        fn pwriteDbgLineNops(
            self: *Elf,
            prev_padding_size: usize,
            buf: []const u8,
            next_padding_size: usize,
            offset: usize,
        ) !void {
            const tracy = trace(@src());
            defer tracy.end();

            const page_of_nops = [1]u8{DW.LNS_negate_stmt} ** 4096;
            const three_byte_nop = [3]u8{DW.LNS_advance_pc, 0b1000_0000, 0};
            var vecs: [32]std.os.iovec_const = undefined;
            var vec_index: usize = 0;
            {
                var padding_left = prev_padding_size;
                if (padding_left % 2 != 0) {
                    vecs[vec_index] = .{
                        .iov_base = &three_byte_nop,
                        .iov_len = three_byte_nop.len,
                    };
                    vec_index += 1;
                    padding_left -= three_byte_nop.len;
                }
                while (padding_left > page_of_nops.len) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = page_of_nops.len,
                    };
                    vec_index += 1;
                    padding_left -= page_of_nops.len;
                }
                if (padding_left > 0) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = padding_left,
                    };
                    vec_index += 1;
                }
            }

            vecs[vec_index] = .{
                .iov_base = buf.ptr,
                .iov_len = buf.len,
            };
            vec_index += 1;

            {
                var padding_left = next_padding_size;
                if (padding_left % 2 != 0) {
                    vecs[vec_index] = .{
                        .iov_base = &three_byte_nop,
                        .iov_len = three_byte_nop.len,
                    };
                    vec_index += 1;
                    padding_left -= three_byte_nop.len;
                }
                while (padding_left > page_of_nops.len) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = page_of_nops.len,
                    };
                    vec_index += 1;
                    padding_left -= page_of_nops.len;
                }
                if (padding_left > 0) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = padding_left,
                    };
                    vec_index += 1;
                }
            }
            try self.base.file.?.pwritevAll(vecs[0..vec_index], offset - prev_padding_size);
        }

        /// Writes to the file a buffer, prefixed and suffixed by the specified number of
        /// bytes of padding.
        fn pwriteDbgInfoNops(
            self: *Elf,
            prev_padding_size: usize,
            buf: []const u8,
            next_padding_size: usize,
            trailing_zero: bool,
            offset: usize,
        ) !void {
            const tracy = trace(@src());
            defer tracy.end();

            const page_of_nops = [1]u8{abbrev_pad1} ** 4096;
            var vecs: [32]std.os.iovec_const = undefined;
            var vec_index: usize = 0;
            {
                var padding_left = prev_padding_size;
                while (padding_left > page_of_nops.len) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = page_of_nops.len,
                    };
                    vec_index += 1;
                    padding_left -= page_of_nops.len;
                }
                if (padding_left > 0) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = padding_left,
                    };
                    vec_index += 1;
                }
            }

            vecs[vec_index] = .{
                .iov_base = buf.ptr,
                .iov_len = buf.len,
            };
            vec_index += 1;

            {
                var padding_left = next_padding_size;
                while (padding_left > page_of_nops.len) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = page_of_nops.len,
                    };
                    vec_index += 1;
                    padding_left -= page_of_nops.len;
                }
                if (padding_left > 0) {
                    vecs[vec_index] = .{
                        .iov_base = &page_of_nops,
                        .iov_len = padding_left,
                    };
                    vec_index += 1;
                }
            }

            if (trailing_zero) {
                var zbuf = [1]u8{0};
                vecs[vec_index] = .{
                    .iov_base = &zbuf,
                    .iov_len = zbuf.len,
                };
                vec_index += 1;
            }

            try self.base.file.?.pwritevAll(vecs[0..vec_index], offset - prev_padding_size);
        }

    };
};

/// Saturating multiplication
fn satMul(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    return std.math.mul(T, a, b) catch std.math.maxInt(T);
}

fn bswapAllFields(comptime S: type, ptr: *S) void {
    @panic("TODO implement bswapAllFields");
}

fn progHeaderTo32(phdr: elf.Elf64_Phdr) elf.Elf32_Phdr {
    return .{
        .p_type = phdr.p_type,
        .p_flags = phdr.p_flags,
        .p_offset = @intCast(u32, phdr.p_offset),
        .p_vaddr = @intCast(u32, phdr.p_vaddr),
        .p_paddr = @intCast(u32, phdr.p_paddr),
        .p_filesz = @intCast(u32, phdr.p_filesz),
        .p_memsz = @intCast(u32, phdr.p_memsz),
        .p_align = @intCast(u32, phdr.p_align),
    };
}

fn sectHeaderTo32(shdr: elf.Elf64_Shdr) elf.Elf32_Shdr {
    return .{
        .sh_name = shdr.sh_name,
        .sh_type = shdr.sh_type,
        .sh_flags = @intCast(u32, shdr.sh_flags),
        .sh_addr = @intCast(u32, shdr.sh_addr),
        .sh_offset = @intCast(u32, shdr.sh_offset),
        .sh_size = @intCast(u32, shdr.sh_size),
        .sh_link = shdr.sh_link,
        .sh_info = shdr.sh_info,
        .sh_addralign = @intCast(u32, shdr.sh_addralign),
        .sh_entsize = @intCast(u32, shdr.sh_entsize),
    };
}

fn determineMode(options: Options) fs.File.Mode {
    // On common systems with a 0o022 umask, 0o777 will still result in a file created
    // with 0o755 permissions, but it works appropriately if the system is configured
    // more leniently. As another data point, C's fopen seems to open files with the
    // 666 mode.
    const executable_mode = if (std.Target.current.os.tag == .windows) 0 else 0o777;
    switch (options.output_mode) {
        .Lib => return switch (options.link_mode) {
            .Dynamic => executable_mode,
            .Static => fs.File.default_mode,
        },
        .Exe => return executable_mode,
        .Obj => return fs.File.default_mode,
    }
}
