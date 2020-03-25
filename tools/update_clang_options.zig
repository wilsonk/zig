//! To get started, run this tool with no args and read the help message.
//!
//! Clang has a file "options.td" which describes all of its command line parameter options.
//! When using `zig cc`, Zig acts as a proxy between the user and Clang. It does not need
//! to understand all the parameters, but it does need to understand some of them, such as
//! the target. This means that Zig must understand when a C command line parameter expects
//! to "consume" the next parameter on the command line.
//!
//! For example, `-z -target` would mean to pass `-target` to the linker, whereas `-E -target`
//! would mean that the next parameter specifies the target.

const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const json = std.json;

const KnownOpt = struct {
    name: []const u8,

    /// Corresponds to stage.zig ClangArgIterator.Kind
    ident: []const u8,
};

const known_options = [_]KnownOpt{
    .{
        .name = "target",
        .ident = "target",
    },
    .{
        .name = "o",
        .ident = "o",
    },
    .{
        .name = "c",
        .ident = "c",
    },
    .{
        .name = "l",
        .ident = "l",
    },
    .{
        .name = "pipe",
        .ident = "ignore",
    },
    .{
        .name = "help",
        .ident = "driver_punt",
    },
    .{
        .name = "fPIC",
        .ident = "pic",
    },
    .{
        .name = "fno-PIC",
        .ident = "no_pic",
    },
    .{
        .name = "nostdlib",
        .ident = "nostdlib",
    },
    .{
        .name = "no-standard-libraries",
        .ident = "nostdlib",
    },
    .{
        .name = "shared",
        .ident = "shared",
    },
    .{
        .name = "rdynamic",
        .ident = "rdynamic",
    },
    .{
        .name = "Wl,",
        .ident = "wl",
    },
    .{
        .name = "E",
        .ident = "preprocess",
    },
    .{
        .name = "preprocess",
        .ident = "preprocess",
    },
    .{
        .name = "S",
        .ident = "driver_punt",
    },
    .{
        .name = "assemble",
        .ident = "driver_punt",
    },
    .{
        .name = "O1",
        .ident = "optimize",
    },
    .{
        .name = "O2",
        .ident = "optimize",
    },
    .{
        .name = "Og",
        .ident = "optimize",
    },
    .{
        .name = "O",
        .ident = "optimize",
    },
    .{
        .name = "Ofast",
        .ident = "optimize",
    },
    .{
        .name = "optimize",
        .ident = "optimize",
    },
    .{
        .name = "g",
        .ident = "debug",
    },
    .{
        .name = "debug",
        .ident = "debug",
    },
    .{
        .name = "g-dwarf",
        .ident = "debug",
    },
    .{
        .name = "g-dwarf-2",
        .ident = "debug",
    },
    .{
        .name = "g-dwarf-3",
        .ident = "debug",
    },
    .{
        .name = "g-dwarf-4",
        .ident = "debug",
    },
    .{
        .name = "g-dwarf-5",
        .ident = "debug",
    },
    .{
        .name = "fsanitize",
        .ident = "sanitize",
    },
};

const blacklisted_options = [_][]const u8{};

fn knownOption(name: []const u8) ?[]const u8 {
    const chopped_name = if (std.mem.endsWith(u8, name, "=")) name[0 .. name.len - 1] else name;
    for (known_options) |item| {
        if (std.mem.eql(u8, chopped_name, item.name)) {
            return item.ident;
        }
    }
    return null;
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;
    const args = try std.process.argsAlloc(allocator);

    if (args.len <= 1) {
        usageAndExit(std.io.getStdErr(), args[0], 1);
    }
    if (std.mem.eql(u8, args[1], "--help")) {
        usageAndExit(std.io.getStdOut(), args[0], 0);
    }
    if (args.len < 3) {
        usageAndExit(std.io.getStdErr(), args[0], 1);
    }

    const llvm_tblgen_exe = args[1];
    if (std.mem.startsWith(u8, llvm_tblgen_exe, "-")) {
        usageAndExit(std.io.getStdErr(), args[0], 1);
    }

    const llvm_src_root = args[2];
    if (std.mem.startsWith(u8, llvm_src_root, "-")) {
        usageAndExit(std.io.getStdErr(), args[0], 1);
    }

    const child_args = [_][]const u8{
        llvm_tblgen_exe,
        "--dump-json",
        try std.fmt.allocPrint(allocator, "{}/clang/include/clang/Driver/Options.td", .{llvm_src_root}),
        try std.fmt.allocPrint(allocator, "-I={}/llvm/include", .{llvm_src_root}),
        try std.fmt.allocPrint(allocator, "-I={}/clang/include/clang/Driver", .{llvm_src_root}),
    };

    const child_result = try std.ChildProcess.exec2(.{
        .allocator = allocator,
        .argv = &child_args,
        .max_output_bytes = 100 * 1024 * 1024,
    });

    std.debug.warn("{}\n", .{child_result.stderr});

    const json_text = switch (child_result.term) {
        .Exited => |code| if (code == 0) child_result.stdout else {
            std.debug.warn("llvm-tblgen exited with code {}\n", .{code});
            std.process.exit(1);
        },
        else => {
            std.debug.warn("llvm-tblgen crashed\n", .{});
            std.process.exit(1);
        },
    };

    var parser = json.Parser.init(allocator, false);
    const tree = try parser.parse(json_text);
    const root_map = &tree.root.Object;

    var all_objects = std.ArrayList(*json.ObjectMap).init(allocator);
    {
        var it = root_map.iterator();
        it_map: while (it.next()) |kv| {
            if (kv.key.len == 0) continue;
            if (kv.key[0] == '!') continue;
            if (kv.value != .Object) continue;
            if (!kv.value.Object.contains("NumArgs")) continue;
            if (!kv.value.Object.contains("Name")) continue;
            for (blacklisted_options) |blacklisted_key| {
                if (std.mem.eql(u8, blacklisted_key, kv.key)) continue :it_map;
            }
            if (kv.value.Object.get("Name").?.value.String.len == 0) continue;
            try all_objects.append(&kv.value.Object);
        }
    }
    // Some options have multiple matches. As an example, "-Wl,foo" matches both
    // "W" and "Wl,". So we sort this list in order of descending priority.
    std.sort.sort(*json.ObjectMap, all_objects.span(), objectLessThan);

    var stdout_bos = std.io.bufferedOutStream(std.io.getStdOut().outStream());
    const stdout = stdout_bos.outStream();
    try stdout.writeAll(
        \\// This file is generated by tools/update_clang_options.zig.
        \\// zig fmt: off
        \\usingnamespace @import("clang_options.zig");
        \\pub const data = blk: { @setEvalBranchQuota(6000); break :blk &[_]CliArg{
        \\
    );

    for (all_objects.span()) |obj| {
        const name = obj.get("Name").?.value.String;
        var pd1 = false;
        var pd2 = false;
        var pslash = false;
        for (obj.get("Prefixes").?.value.Array.span()) |prefix_json| {
            const prefix = prefix_json.String;
            if (std.mem.eql(u8, prefix, "-")) {
                pd1 = true;
            } else if (std.mem.eql(u8, prefix, "--")) {
                pd2 = true;
            } else if (std.mem.eql(u8, prefix, "/")) {
                pslash = true;
            } else {
                std.debug.warn("{} has unrecognized prefix '{}'\n", .{ name, prefix });
                std.process.exit(1);
            }
        }
        const syntax = objSyntax(obj);

        if (knownOption(name)) |ident| {
            try stdout.print(
                \\.{{
                \\    .name = "{}",
                \\    .syntax = {},
                \\    .zig_equivalent = .{},
                \\    .pd1 = {},
                \\    .pd2 = {},
                \\    .psl = {},
                \\}},
                \\
            , .{ name, syntax, ident, pd1, pd2, pslash });
        } else if (pd1 and !pd2 and !pslash and syntax == .flag) {
            try stdout.print("flagpd1(\"{}\"),\n", .{name});
        } else if (pd1 and !pd2 and !pslash and syntax == .joined) {
            try stdout.print("joinpd1(\"{}\"),\n", .{name});
        } else if (pd1 and !pd2 and !pslash and syntax == .joined_or_separate) {
            try stdout.print("jspd1(\"{}\"),\n", .{name});
        } else if (pd1 and !pd2 and !pslash and syntax == .separate) {
            try stdout.print("sepd1(\"{}\"),\n", .{name});
        } else {
            try stdout.print(
                \\.{{
                \\    .name = "{}",
                \\    .syntax = {},
                \\    .zig_equivalent = .other,
                \\    .pd1 = {},
                \\    .pd2 = {},
                \\    .psl = {},
                \\}},
                \\
            , .{ name, syntax, pd1, pd2, pslash });
        }
    }

    try stdout.writeAll(
        \\};};
        \\
    );

    try stdout_bos.flush();
}

// TODO we should be able to import clang_options.zig but currently this is problematic because it will
// import stage2.zig and that causes a bunch of stuff to get exported
const Syntax = union(enum) {
    /// A flag with no values.
    flag,

    /// An option which prefixes its (single) value.
    joined,

    /// An option which is followed by its value.
    separate,

    /// An option which is either joined to its (non-empty) value, or followed by its value.
    joined_or_separate,

    /// An option which is both joined to its (first) value, and followed by its (second) value.
    joined_and_separate,

    /// An option followed by its values, which are separated by commas.
    comma_joined,

    /// An option which consumes an optional joined argument and any other remaining arguments.
    remaining_args_joined,

    /// An option which is which takes multiple (separate) arguments.
    multi_arg: u8,

    pub fn format(
        self: Syntax,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: var,
    ) !void {
        switch (self) {
            .multi_arg => |n| return out_stream.print(".{{.{}={}}}", .{ @tagName(self), n }),
            else => return out_stream.print(".{}", .{@tagName(self)}),
        }
    }
};

fn objSyntax(obj: *json.ObjectMap) Syntax {
    const num_args = @intCast(u8, obj.get("NumArgs").?.value.Integer);
    for (obj.get("!superclasses").?.value.Array.span()) |superclass_json| {
        const superclass = superclass_json.String;
        if (std.mem.eql(u8, superclass, "Joined")) {
            return .joined;
        } else if (std.mem.eql(u8, superclass, "CLJoined")) {
            return .joined;
        } else if (std.mem.eql(u8, superclass, "CLIgnoredJoined")) {
            return .joined;
        } else if (std.mem.eql(u8, superclass, "CLCompileJoined")) {
            return .joined;
        } else if (std.mem.eql(u8, superclass, "JoinedOrSeparate")) {
            return .joined_or_separate;
        } else if (std.mem.eql(u8, superclass, "CLJoinedOrSeparate")) {
            return .joined_or_separate;
        } else if (std.mem.eql(u8, superclass, "CLCompileJoinedOrSeparate")) {
            return .joined_or_separate;
        } else if (std.mem.eql(u8, superclass, "Flag")) {
            return .flag;
        } else if (std.mem.eql(u8, superclass, "CLFlag")) {
            return .flag;
        } else if (std.mem.eql(u8, superclass, "CLIgnoredFlag")) {
            return .flag;
        } else if (std.mem.eql(u8, superclass, "Separate")) {
            return .separate;
        } else if (std.mem.eql(u8, superclass, "JoinedAndSeparate")) {
            return .joined_and_separate;
        } else if (std.mem.eql(u8, superclass, "CommaJoined")) {
            return .comma_joined;
        } else if (std.mem.eql(u8, superclass, "CLRemainingArgsJoined")) {
            return .remaining_args_joined;
        } else if (std.mem.eql(u8, superclass, "MultiArg")) {
            return .{ .multi_arg = num_args };
        }
    }
    const name = obj.get("Name").?.value.String;
    if (std.mem.eql(u8, name, "<input>")) {
        return .flag;
    } else if (std.mem.eql(u8, name, "<unknown>")) {
        return .flag;
    }
    const kind_def = obj.get("Kind").?.value.Object.get("def").?.value.String;
    if (std.mem.eql(u8, kind_def, "KIND_FLAG")) {
        return .flag;
    }
    const key = obj.get("!name").?.value.String;
    std.debug.warn("{} (key {}) has unrecognized superclasses:\n", .{ name, key });
    for (obj.get("!superclasses").?.value.Array.span()) |superclass_json| {
        std.debug.warn(" {}\n", .{superclass_json.String});
    }
    std.process.exit(1);
}

fn syntaxMatchesWithEql(syntax: Syntax) bool {
    return switch (syntax) {
        .flag,
        .separate,
        .multi_arg,
        => true,

        .joined,
        .joined_or_separate,
        .joined_and_separate,
        .comma_joined,
        .remaining_args_joined,
        => false,
    };
}

fn objectLessThan(a: *json.ObjectMap, b: *json.ObjectMap) bool {
    // Priority is determined by exact matches first, followed by prefix matches in descending
    // length, with key as a final tiebreaker.
    const a_syntax = objSyntax(a);
    const b_syntax = objSyntax(b);

    const a_match_with_eql = syntaxMatchesWithEql(a_syntax);
    const b_match_with_eql = syntaxMatchesWithEql(b_syntax);

    if (a_match_with_eql and !b_match_with_eql) {
        return true;
    } else if (!a_match_with_eql and b_match_with_eql) {
        return false;
    }

    if (!a_match_with_eql and !b_match_with_eql) {
        const a_name = a.get("Name").?.value.String;
        const b_name = b.get("Name").?.value.String;
        if (a_name.len != b_name.len) {
            return a_name.len > b_name.len;
        }
    }

    const a_key = a.get("!name").?.value.String;
    const b_key = b.get("!name").?.value.String;
    return std.mem.lessThan(u8, a_key, b_key);
}

fn usageAndExit(file: fs.File, arg0: []const u8, code: u8) noreturn {
    file.outStream().print(
        \\Usage: {} /path/to/llvm-tblgen /path/to/git/llvm/llvm-project
        \\
        \\Prints to stdout Zig code which you can use to replace the file src-self-hosted/clang_options_data.zig.
        \\
    , .{arg0}) catch std.process.exit(1);
    std.process.exit(code);
}
