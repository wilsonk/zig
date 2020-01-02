const std = @import("std");
const debug = std.debug;
const warn = debug.warn;
const build = std.build;
pub const Target = build.Target;
pub const CrossTarget = build.CrossTarget;
const Buffer = std.Buffer;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");
const Mode = builtin.Mode;
const LibExeObjStep = build.LibExeObjStep;

const compare_output = @import("compare_output.zig");
const standalone = @import("standalone.zig");
const stack_traces = @import("stack_traces.zig");
const compile_errors = @import("compile_errors.zig");
const assemble_and_link = @import("assemble_and_link.zig");
const runtime_safety = @import("runtime_safety.zig");
const translate_c = @import("translate_c.zig");
const gen_h = @import("gen_h.zig");

const TestTarget = struct {
    target: Target = .Native,
    mode: builtin.Mode = .Debug,
    link_libc: bool = false,
    single_threaded: bool = false,
    disable_native: bool = false,
};

const test_targets = [_]TestTarget{
    TestTarget{},
    TestTarget{
        .link_libc = true,
    },
    TestTarget{
        .single_threaded = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .x86_64,
                .abi = .none,
            },
        },
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .x86_64,
                .abi = .gnu,
            },
        },
        .link_libc = true,
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .x86_64,
                .abi = .musl,
            },
        },
        .link_libc = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .i386,
                .abi = .none,
            },
        },
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .i386,
                .abi = .musl,
            },
        },
        .link_libc = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = builtin.Arch{ .aarch64 = builtin.Arch.Arm64.v8_5a },
                .abi = .none,
            },
        },
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = builtin.Arch{ .aarch64 = builtin.Arch.Arm64.v8_5a },
                .abi = .musl,
            },
        },
        .link_libc = true,
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = builtin.Arch{ .aarch64 = builtin.Arch.Arm64.v8_5a },
                .abi = .gnu,
            },
        },
        .link_libc = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = builtin.Arch{ .arm = builtin.Arch.Arm32.v8_5a },
                .abi = .none,
            },
        },
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = builtin.Arch{ .arm = builtin.Arch.Arm32.v8_5a },
                .abi = .musleabihf,
            },
        },
        .link_libc = true,
    },
    // TODO https://github.com/ziglang/zig/issues/3287
    //TestTarget{
    //    .target = Target{
    //        .Cross = CrossTarget{
    //            .os = .linux,
    //            .arch = builtin.Arch{ .arm = builtin.Arch.Arm32.v8_5a },
    //            .abi = .gnueabihf,
    //        },
    //    },
    //    .link_libc = true,
    //},

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .mipsel,
                .abi = .none,
            },
        },
    },
    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .linux,
                .arch = .mipsel,
                .abi = .musl,
            },
        },
        .link_libc = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .macosx,
                .arch = .x86_64,
                .abi = .gnu,
            },
        },
        // TODO https://github.com/ziglang/zig/issues/3295
        .disable_native = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .windows,
                .arch = .i386,
                .abi = .msvc,
            },
        },
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .windows,
                .arch = .x86_64,
                .abi = .msvc,
            },
        },
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .windows,
                .arch = .i386,
                .abi = .gnu,
            },
        },
        .link_libc = true,
    },

    TestTarget{
        .target = Target{
            .Cross = CrossTarget{
                .os = .windows,
                .arch = .x86_64,
                .abi = .gnu,
            },
        },
        .link_libc = true,
    },

    // Do the release tests last because they take a long time
    TestTarget{
        .mode = .ReleaseFast,
    },
    TestTarget{
        .link_libc = true,
        .mode = .ReleaseFast,
    },
    TestTarget{
        .mode = .ReleaseFast,
        .single_threaded = true,
    },

    TestTarget{
        .mode = .ReleaseSafe,
    },
    TestTarget{
        .link_libc = true,
        .mode = .ReleaseSafe,
    },
    TestTarget{
        .mode = .ReleaseSafe,
        .single_threaded = true,
    },

    TestTarget{
        .mode = .ReleaseSmall,
    },
    TestTarget{
        .link_libc = true,
        .mode = .ReleaseSmall,
    },
    TestTarget{
        .mode = .ReleaseSmall,
        .single_threaded = true,
    },
};

const max_stdout_size = 1 * 1024 * 1024; // 1 MB

pub fn addCompareOutputTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const cases = b.allocator.create(CompareOutputContext) catch unreachable;
    cases.* = CompareOutputContext{
        .b = b,
        .step = b.step("test-compare-output", "Run the compare output tests"),
        .test_index = 0,
        .test_filter = test_filter,
        .modes = modes,
    };

    compare_output.addCases(cases);

    return cases.step;
}

pub fn addStackTraceTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const cases = b.allocator.create(StackTracesContext) catch unreachable;
    cases.* = StackTracesContext{
        .b = b,
        .step = b.step("test-stack-traces", "Run the stack trace tests"),
        .test_index = 0,
        .test_filter = test_filter,
        .modes = modes,
    };

    stack_traces.addCases(cases);

    return cases.step;
}

pub fn addRuntimeSafetyTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const cases = b.allocator.create(CompareOutputContext) catch unreachable;
    cases.* = CompareOutputContext{
        .b = b,
        .step = b.step("test-runtime-safety", "Run the runtime safety tests"),
        .test_index = 0,
        .test_filter = test_filter,
        .modes = modes,
    };

    runtime_safety.addCases(cases);

    return cases.step;
}

pub fn addCompileErrorTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const cases = b.allocator.create(CompileErrorContext) catch unreachable;
    cases.* = CompileErrorContext{
        .b = b,
        .step = b.step("test-compile-errors", "Run the compile error tests"),
        .test_index = 0,
        .test_filter = test_filter,
        .modes = modes,
    };

    compile_errors.addCases(cases);

    return cases.step;
}

pub fn addStandaloneTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const cases = b.allocator.create(StandaloneContext) catch unreachable;
    cases.* = StandaloneContext{
        .b = b,
        .step = b.step("test-standalone", "Run the standalone tests"),
        .test_index = 0,
        .test_filter = test_filter,
        .modes = modes,
    };

    standalone.addCases(cases);

    return cases.step;
}

pub fn addCliTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const step = b.step("test-cli", "Test the command line interface");

    const exe = b.addExecutable("test-cli", "test/cli.zig");
    const run_cmd = exe.run();
    run_cmd.addArgs(&[_][]const u8{
        fs.realpathAlloc(b.allocator, b.zig_exe) catch unreachable,
        b.pathFromRoot(b.cache_root),
    });

    step.dependOn(&run_cmd.step);
    return step;
}

pub fn addAssembleAndLinkTests(b: *build.Builder, test_filter: ?[]const u8, modes: []const Mode) *build.Step {
    const cases = b.allocator.create(CompareOutputContext) catch unreachable;
    cases.* = CompareOutputContext{
        .b = b,
        .step = b.step("test-asm-link", "Run the assemble and link tests"),
        .test_index = 0,
        .test_filter = test_filter,
        .modes = modes,
    };

    assemble_and_link.addCases(cases);

    return cases.step;
}

pub fn addTranslateCTests(b: *build.Builder, test_filter: ?[]const u8) *build.Step {
    const cases = b.allocator.create(TranslateCContext) catch unreachable;
    cases.* = TranslateCContext{
        .b = b,
        .step = b.step("test-translate-c", "Run the C transation tests"),
        .test_index = 0,
        .test_filter = test_filter,
    };

    translate_c.addCases(cases);

    return cases.step;
}

pub fn addGenHTests(b: *build.Builder, test_filter: ?[]const u8) *build.Step {
    const cases = b.allocator.create(GenHContext) catch unreachable;
    cases.* = GenHContext{
        .b = b,
        .step = b.step("test-gen-h", "Run the C header file generation tests"),
        .test_index = 0,
        .test_filter = test_filter,
    };

    gen_h.addCases(cases);

    return cases.step;
}

pub fn addPkgTests(
    b: *build.Builder,
    test_filter: ?[]const u8,
    root_src: []const u8,
    name: []const u8,
    desc: []const u8,
    modes: []const Mode,
    skip_single_threaded: bool,
    skip_non_native: bool,
    skip_libc: bool,
    is_wine_enabled: bool,
    is_qemu_enabled: bool,
    glibc_dir: ?[]const u8,
) *build.Step {
    const step = b.step(b.fmt("test-{}", .{name}), desc);

    for (test_targets) |test_target| {
        if (skip_non_native and test_target.target != .Native)
            continue;

        if (skip_libc and test_target.link_libc)
            continue;

        if (test_target.link_libc and test_target.target.osRequiresLibC()) {
            // This would be a redundant test.
            continue;
        }

        if (skip_single_threaded and test_target.single_threaded)
            continue;

        const ArchTag = @TagType(builtin.Arch);
        if (test_target.disable_native and
            test_target.target.getOs() == builtin.os and
            @as(ArchTag, test_target.target.getArch()) == @as(ArchTag, builtin.arch))
        {
            continue;
        }

        const want_this_mode = for (modes) |m| {
            if (m == test_target.mode) break true;
        } else false;
        if (!want_this_mode) continue;

        const libc_prefix = if (test_target.target.osRequiresLibC())
            ""
        else if (test_target.link_libc)
            "c"
        else
            "bare";

        const triple_prefix = if (test_target.target == .Native)
            @as([]const u8, "native")
        else
            test_target.target.zigTripleNoSubArch(b.allocator) catch unreachable;

        const these_tests = b.addTest(root_src);
        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        these_tests.setNamePrefix(b.fmt("{}-{}-{}-{}-{} ", .{
            name,
            triple_prefix,
            @tagName(test_target.mode),
            libc_prefix,
            single_threaded_txt,
        }));
        these_tests.single_threaded = test_target.single_threaded;
        these_tests.setFilter(test_filter);
        these_tests.setBuildMode(test_target.mode);
        these_tests.setTheTarget(test_target.target);
        if (test_target.link_libc) {
            these_tests.linkSystemLibrary("c");
        }
        these_tests.overrideZigLibDir("lib");
        these_tests.enable_wine = is_wine_enabled;
        these_tests.enable_qemu = is_qemu_enabled;
        these_tests.glibc_multi_install_dir = glibc_dir;

        step.dependOn(&these_tests.step);
    }
    return step;
}

pub const CompareOutputContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,
    modes: []const Mode,

    const Special = enum {
        None,
        Asm,
        RuntimeSafety,
    };

    const TestCase = struct {
        name: []const u8,
        sources: ArrayList(SourceFile),
        expected_output: []const u8,
        link_libc: bool,
        special: Special,
        cli_args: []const []const u8,

        const SourceFile = struct {
            filename: []const u8,
            source: []const u8,
        };

        pub fn addSourceFile(self: *TestCase, filename: []const u8, source: []const u8) void {
            self.sources.append(SourceFile{
                .filename = filename,
                .source = source,
            }) catch unreachable;
        }

        pub fn setCommandLineArgs(self: *TestCase, args: []const []const u8) void {
            self.cli_args = args;
        }
    };

    const RunCompareOutputStep = struct {
        step: build.Step,
        context: *CompareOutputContext,
        exe: *LibExeObjStep,
        name: []const u8,
        expected_output: []const u8,
        test_index: usize,
        cli_args: []const []const u8,

        pub fn create(
            context: *CompareOutputContext,
            exe: *LibExeObjStep,
            name: []const u8,
            expected_output: []const u8,
            cli_args: []const []const u8,
        ) *RunCompareOutputStep {
            const allocator = context.b.allocator;
            const ptr = allocator.create(RunCompareOutputStep) catch unreachable;
            ptr.* = RunCompareOutputStep{
                .context = context,
                .exe = exe,
                .name = name,
                .expected_output = expected_output,
                .test_index = context.test_index,
                .step = build.Step.init("RunCompareOutput", allocator, make),
                .cli_args = cli_args,
            };
            ptr.step.dependOn(&exe.step);
            context.test_index += 1;
            return ptr;
        }

        fn make(step: *build.Step) !void {
            const self = @fieldParentPtr(RunCompareOutputStep, "step", step);
            const b = self.context.b;

            const full_exe_path = self.exe.getOutputPath();
            var args = ArrayList([]const u8).init(b.allocator);
            defer args.deinit();

            args.append(full_exe_path) catch unreachable;
            for (self.cli_args) |arg| {
                args.append(arg) catch unreachable;
            }

            warn("Test {}/{} {}...", .{ self.test_index + 1, self.context.test_index, self.name });

            const child = std.ChildProcess.init(args.toSliceConst(), b.allocator) catch unreachable;
            defer child.deinit();

            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.env_map = b.env_map;

            child.spawn() catch |err| debug.panic("Unable to spawn {}: {}\n", .{ full_exe_path, @errorName(err) });

            var stdout = Buffer.initNull(b.allocator);
            var stderr = Buffer.initNull(b.allocator);

            var stdout_file_in_stream = child.stdout.?.inStream();
            var stderr_file_in_stream = child.stderr.?.inStream();

            stdout_file_in_stream.stream.readAllBuffer(&stdout, max_stdout_size) catch unreachable;
            stderr_file_in_stream.stream.readAllBuffer(&stderr, max_stdout_size) catch unreachable;

            const term = child.wait() catch |err| {
                debug.panic("Unable to spawn {}: {}\n", .{ full_exe_path, @errorName(err) });
            };
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        warn("Process {} exited with error code {}\n", .{ full_exe_path, code });
                        printInvocation(args.toSliceConst());
                        return error.TestFailed;
                    }
                },
                else => {
                    warn("Process {} terminated unexpectedly\n", .{full_exe_path});
                    printInvocation(args.toSliceConst());
                    return error.TestFailed;
                },
            }

            if (!mem.eql(u8, self.expected_output, stdout.toSliceConst())) {
                warn(
                    \\
                    \\========= Expected this output: =========
                    \\{}
                    \\========= But found: ====================
                    \\{}
                    \\
                , .{ self.expected_output, stdout.toSliceConst() });
                return error.TestFailed;
            }
            warn("OK\n", .{});
        }
    };

    const RuntimeSafetyRunStep = struct {
        step: build.Step,
        context: *CompareOutputContext,
        exe: *LibExeObjStep,
        name: []const u8,
        test_index: usize,

        pub fn create(context: *CompareOutputContext, exe: *LibExeObjStep, name: []const u8) *RuntimeSafetyRunStep {
            const allocator = context.b.allocator;
            const ptr = allocator.create(RuntimeSafetyRunStep) catch unreachable;
            ptr.* = RuntimeSafetyRunStep{
                .context = context,
                .exe = exe,
                .name = name,
                .test_index = context.test_index,
                .step = build.Step.init("RuntimeSafetyRun", allocator, make),
            };
            ptr.step.dependOn(&exe.step);
            context.test_index += 1;
            return ptr;
        }

        fn make(step: *build.Step) !void {
            const self = @fieldParentPtr(RuntimeSafetyRunStep, "step", step);
            const b = self.context.b;

            const full_exe_path = self.exe.getOutputPath();

            warn("Test {}/{} {}...", .{ self.test_index + 1, self.context.test_index, self.name });

            const child = std.ChildProcess.init(&[_][]const u8{full_exe_path}, b.allocator) catch unreachable;
            defer child.deinit();

            child.env_map = b.env_map;
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            const term = child.spawnAndWait() catch |err| {
                debug.panic("Unable to spawn {}: {}\n", .{ full_exe_path, @errorName(err) });
            };

            const expected_exit_code: u32 = 126;
            switch (term) {
                .Exited => |code| {
                    if (code != expected_exit_code) {
                        warn("\nProgram expected to exit with code {} but exited with code {}\n", .{
                            expected_exit_code, code,
                        });
                        return error.TestFailed;
                    }
                },
                .Signal => |sig| {
                    warn("\nProgram expected to exit with code {} but instead signaled {}\n", .{
                        expected_exit_code, sig,
                    });
                    return error.TestFailed;
                },
                else => {
                    warn("\nProgram expected to exit with code {} but exited in an unexpected way\n", .{
                        expected_exit_code,
                    });
                    return error.TestFailed;
                },
            }

            warn("OK\n", .{});
        }
    };

    pub fn createExtra(self: *CompareOutputContext, name: []const u8, source: []const u8, expected_output: []const u8, special: Special) TestCase {
        var tc = TestCase{
            .name = name,
            .sources = ArrayList(TestCase.SourceFile).init(self.b.allocator),
            .expected_output = expected_output,
            .link_libc = false,
            .special = special,
            .cli_args = &[_][]const u8{},
        };
        const root_src_name = if (special == Special.Asm) "source.s" else "source.zig";
        tc.addSourceFile(root_src_name, source);
        return tc;
    }

    pub fn create(self: *CompareOutputContext, name: []const u8, source: []const u8, expected_output: []const u8) TestCase {
        return createExtra(self, name, source, expected_output, Special.None);
    }

    pub fn addC(self: *CompareOutputContext, name: []const u8, source: []const u8, expected_output: []const u8) void {
        var tc = self.create(name, source, expected_output);
        tc.link_libc = true;
        self.addCase(tc);
    }

    pub fn add(self: *CompareOutputContext, name: []const u8, source: []const u8, expected_output: []const u8) void {
        const tc = self.create(name, source, expected_output);
        self.addCase(tc);
    }

    pub fn addAsm(self: *CompareOutputContext, name: []const u8, source: []const u8, expected_output: []const u8) void {
        const tc = self.createExtra(name, source, expected_output, Special.Asm);
        self.addCase(tc);
    }

    pub fn addRuntimeSafety(self: *CompareOutputContext, name: []const u8, source: []const u8) void {
        const tc = self.createExtra(name, source, undefined, Special.RuntimeSafety);
        self.addCase(tc);
    }

    pub fn addCase(self: *CompareOutputContext, case: TestCase) void {
        const b = self.b;

        const root_src = fs.path.join(
            b.allocator,
            &[_][]const u8{ b.cache_root, case.sources.items[0].filename },
        ) catch unreachable;

        switch (case.special) {
            Special.Asm => {
                const annotated_case_name = fmt.allocPrint(self.b.allocator, "assemble-and-link {}", .{
                    case.name,
                }) catch unreachable;
                if (self.test_filter) |filter| {
                    if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
                }

                const exe = b.addExecutable("test", null);
                exe.addAssemblyFile(root_src);

                for (case.sources.toSliceConst()) |src_file| {
                    const expanded_src_path = fs.path.join(
                        b.allocator,
                        &[_][]const u8{ b.cache_root, src_file.filename },
                    ) catch unreachable;
                    const write_src = b.addWriteFile(expanded_src_path, src_file.source);
                    exe.step.dependOn(&write_src.step);
                }

                const run_and_cmp_output = RunCompareOutputStep.create(
                    self,
                    exe,
                    annotated_case_name,
                    case.expected_output,
                    case.cli_args,
                );

                self.step.dependOn(&run_and_cmp_output.step);
            },
            Special.None => {
                for (self.modes) |mode| {
                    const annotated_case_name = fmt.allocPrint(self.b.allocator, "{} {} ({})", .{
                        "compare-output",
                        case.name,
                        @tagName(mode),
                    }) catch unreachable;
                    if (self.test_filter) |filter| {
                        if (mem.indexOf(u8, annotated_case_name, filter) == null) continue;
                    }

                    const exe = b.addExecutable("test", root_src);
                    exe.setBuildMode(mode);
                    if (case.link_libc) {
                        exe.linkSystemLibrary("c");
                    }

                    for (case.sources.toSliceConst()) |src_file| {
                        const expanded_src_path = fs.path.join(
                            b.allocator,
                            &[_][]const u8{ b.cache_root, src_file.filename },
                        ) catch unreachable;
                        const write_src = b.addWriteFile(expanded_src_path, src_file.source);
                        exe.step.dependOn(&write_src.step);
                    }

                    const run_and_cmp_output = RunCompareOutputStep.create(
                        self,
                        exe,
                        annotated_case_name,
                        case.expected_output,
                        case.cli_args,
                    );

                    self.step.dependOn(&run_and_cmp_output.step);
                }
            },
            Special.RuntimeSafety => {
                const annotated_case_name = fmt.allocPrint(self.b.allocator, "safety {}", .{case.name}) catch unreachable;
                if (self.test_filter) |filter| {
                    if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
                }

                const exe = b.addExecutable("test", root_src);
                if (case.link_libc) {
                    exe.linkSystemLibrary("c");
                }

                for (case.sources.toSliceConst()) |src_file| {
                    const expanded_src_path = fs.path.join(
                        b.allocator,
                        &[_][]const u8{ b.cache_root, src_file.filename },
                    ) catch unreachable;
                    const write_src = b.addWriteFile(expanded_src_path, src_file.source);
                    exe.step.dependOn(&write_src.step);
                }

                const run_and_cmp_output = RuntimeSafetyRunStep.create(self, exe, annotated_case_name);

                self.step.dependOn(&run_and_cmp_output.step);
            },
        }
    }
};

pub const StackTracesContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,
    modes: []const Mode,

    const Expect = [@typeInfo(Mode).Enum.fields.len][]const u8;

    pub fn addCase(
        self: *StackTracesContext,
        name: []const u8,
        source: []const u8,
        expect: Expect,
    ) void {
        const b = self.b;

        const source_pathname = fs.path.join(
            b.allocator,
            &[_][]const u8{ b.cache_root, "source.zig" },
        ) catch unreachable;

        for (self.modes) |mode| {
            const expect_for_mode = expect[@enumToInt(mode)];
            if (expect_for_mode.len == 0) continue;

            const annotated_case_name = fmt.allocPrint(self.b.allocator, "{} {} ({})", .{
                "stack-trace",
                name,
                @tagName(mode),
            }) catch unreachable;
            if (self.test_filter) |filter| {
                if (mem.indexOf(u8, annotated_case_name, filter) == null) continue;
            }

            const exe = b.addExecutable("test", source_pathname);
            exe.setBuildMode(mode);

            const write_source = b.addWriteFile(source_pathname, source);
            exe.step.dependOn(&write_source.step);

            const run_and_compare = RunAndCompareStep.create(
                self,
                exe,
                annotated_case_name,
                mode,
                expect_for_mode,
            );

            self.step.dependOn(&run_and_compare.step);
        }
    }

    const RunAndCompareStep = struct {
        step: build.Step,
        context: *StackTracesContext,
        exe: *LibExeObjStep,
        name: []const u8,
        mode: Mode,
        expect_output: []const u8,
        test_index: usize,

        pub fn create(
            context: *StackTracesContext,
            exe: *LibExeObjStep,
            name: []const u8,
            mode: Mode,
            expect_output: []const u8,
        ) *RunAndCompareStep {
            const allocator = context.b.allocator;
            const ptr = allocator.create(RunAndCompareStep) catch unreachable;
            ptr.* = RunAndCompareStep{
                .step = build.Step.init("StackTraceCompareOutputStep", allocator, make),
                .context = context,
                .exe = exe,
                .name = name,
                .mode = mode,
                .expect_output = expect_output,
                .test_index = context.test_index,
            };
            ptr.step.dependOn(&exe.step);
            context.test_index += 1;
            return ptr;
        }

        fn make(step: *build.Step) !void {
            const self = @fieldParentPtr(RunAndCompareStep, "step", step);
            const b = self.context.b;

            const full_exe_path = self.exe.getOutputPath();
            var args = ArrayList([]const u8).init(b.allocator);
            defer args.deinit();
            args.append(full_exe_path) catch unreachable;

            warn("Test {}/{} {}...", .{ self.test_index + 1, self.context.test_index, self.name });

            const child = std.ChildProcess.init(args.toSliceConst(), b.allocator) catch unreachable;
            defer child.deinit();

            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.env_map = b.env_map;

            child.spawn() catch |err| debug.panic("Unable to spawn {}: {}\n", .{ full_exe_path, @errorName(err) });

            var stdout = Buffer.initNull(b.allocator);
            var stderr = Buffer.initNull(b.allocator);

            var stdout_file_in_stream = child.stdout.?.inStream();
            var stderr_file_in_stream = child.stderr.?.inStream();

            stdout_file_in_stream.stream.readAllBuffer(&stdout, max_stdout_size) catch unreachable;
            stderr_file_in_stream.stream.readAllBuffer(&stderr, max_stdout_size) catch unreachable;

            const term = child.wait() catch |err| {
                debug.panic("Unable to spawn {}: {}\n", .{ full_exe_path, @errorName(err) });
            };

            switch (term) {
                .Exited => |code| {
                    const expect_code: u32 = 1;
                    if (code != expect_code) {
                        warn("Process {} exited with error code {} but expected code {}\n", .{
                            full_exe_path,
                            code,
                            expect_code,
                        });
                        printInvocation(args.toSliceConst());
                        return error.TestFailed;
                    }
                },
                .Signal => |signum| {
                    warn("Process {} terminated on signal {}\n", .{ full_exe_path, signum });
                    printInvocation(args.toSliceConst());
                    return error.TestFailed;
                },
                .Stopped => |signum| {
                    warn("Process {} stopped on signal {}\n", .{ full_exe_path, signum });
                    printInvocation(args.toSliceConst());
                    return error.TestFailed;
                },
                .Unknown => |code| {
                    warn("Process {} terminated unexpectedly with error code {}\n", .{ full_exe_path, code });
                    printInvocation(args.toSliceConst());
                    return error.TestFailed;
                },
            }

            // process result
            // - keep only basename of source file path
            // - replace address with symbolic string
            // - skip empty lines
            const got: []const u8 = got_result: {
                var buf = try Buffer.initSize(b.allocator, 0);
                defer buf.deinit();
                var bytes = stderr.toSliceConst();
                if (bytes.len != 0 and bytes[bytes.len - 1] == '\n') bytes = bytes[0 .. bytes.len - 1];
                var it = mem.separate(bytes, "\n");
                process_lines: while (it.next()) |line| {
                    if (line.len == 0) continue;
                    const delims = [_][]const u8{ ":", ":", ":", " in " };
                    var marks = [_]usize{0} ** 4;
                    // offset search past `[drive]:` on windows
                    var pos: usize = if (builtin.os == .windows) 2 else 0;
                    for (delims) |delim, i| {
                        marks[i] = mem.indexOfPos(u8, line, pos, delim) orelse {
                            try buf.append(line);
                            try buf.append("\n");
                            continue :process_lines;
                        };
                        pos = marks[i] + delim.len;
                    }
                    pos = mem.lastIndexOfScalar(u8, line[0..marks[0]], fs.path.sep) orelse {
                        try buf.append(line);
                        try buf.append("\n");
                        continue :process_lines;
                    };
                    try buf.append(line[pos + 1 .. marks[2] + delims[2].len]);
                    try buf.append(" [address]");
                    try buf.append(line[marks[3]..]);
                    try buf.append("\n");
                }
                break :got_result buf.toOwnedSlice();
            };

            if (!mem.eql(u8, self.expect_output, got)) {
                warn(
                    \\
                    \\========= Expected this output: =========
                    \\{}
                    \\================================================
                    \\{}
                    \\
                , .{ self.expect_output, got });
                return error.TestFailed;
            }
            warn("OK\n", .{});
        }
    };
};

pub const CompileErrorContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,
    modes: []const Mode,

    const TestCase = struct {
        name: []const u8,
        sources: ArrayList(SourceFile),
        expected_errors: ArrayList([]const u8),
        expect_exact: bool,
        link_libc: bool,
        is_exe: bool,
        is_test: bool,
        target: Target = .Native,

        const SourceFile = struct {
            filename: []const u8,
            source: []const u8,
        };

        pub fn addSourceFile(self: *TestCase, filename: []const u8, source: []const u8) void {
            self.sources.append(SourceFile{
                .filename = filename,
                .source = source,
            }) catch unreachable;
        }

        pub fn addExpectedError(self: *TestCase, text: []const u8) void {
            self.expected_errors.append(text) catch unreachable;
        }
    };

    const CompileCmpOutputStep = struct {
        step: build.Step,
        context: *CompileErrorContext,
        name: []const u8,
        test_index: usize,
        case: *const TestCase,
        build_mode: Mode,

        const ErrLineIter = struct {
            lines: mem.SplitIterator,

            const source_file = "tmp.zig";

            fn init(input: []const u8) ErrLineIter {
                return ErrLineIter{ .lines = mem.separate(input, "\n") };
            }

            fn next(self: *ErrLineIter) ?[]const u8 {
                while (self.lines.next()) |line| {
                    if (mem.indexOf(u8, line, source_file) != null)
                        return line;
                }
                return null;
            }
        };

        pub fn create(context: *CompileErrorContext, name: []const u8, case: *const TestCase, build_mode: Mode) *CompileCmpOutputStep {
            const allocator = context.b.allocator;
            const ptr = allocator.create(CompileCmpOutputStep) catch unreachable;
            ptr.* = CompileCmpOutputStep{
                .step = build.Step.init("CompileCmpOutput", allocator, make),
                .context = context,
                .name = name,
                .test_index = context.test_index,
                .case = case,
                .build_mode = build_mode,
            };

            context.test_index += 1;
            return ptr;
        }

        fn make(step: *build.Step) !void {
            const self = @fieldParentPtr(CompileCmpOutputStep, "step", step);
            const b = self.context.b;

            const root_src = fs.path.join(
                b.allocator,
                &[_][]const u8{ b.cache_root, self.case.sources.items[0].filename },
            ) catch unreachable;

            var zig_args = ArrayList([]const u8).init(b.allocator);
            zig_args.append(b.zig_exe) catch unreachable;

            if (self.case.is_exe) {
                try zig_args.append("build-exe");
            } else if (self.case.is_test) {
                try zig_args.append("test");
            } else {
                try zig_args.append("build-obj");
            }
            zig_args.append(b.pathFromRoot(root_src)) catch unreachable;

            zig_args.append("--name") catch unreachable;
            zig_args.append("test") catch unreachable;

            zig_args.append("--output-dir") catch unreachable;
            zig_args.append(b.pathFromRoot(b.cache_root)) catch unreachable;

            switch (self.case.target) {
                .Native => {},
                .Cross => {
                    try zig_args.append("-target");
                    try zig_args.append(try self.case.target.zigTriple(b.allocator));
                },
            }

            switch (self.build_mode) {
                Mode.Debug => {},
                Mode.ReleaseSafe => zig_args.append("--release-safe") catch unreachable,
                Mode.ReleaseFast => zig_args.append("--release-fast") catch unreachable,
                Mode.ReleaseSmall => zig_args.append("--release-small") catch unreachable,
            }

            warn("Test {}/{} {}...", .{ self.test_index + 1, self.context.test_index, self.name });

            if (b.verbose) {
                printInvocation(zig_args.toSliceConst());
            }

            const child = std.ChildProcess.init(zig_args.toSliceConst(), b.allocator) catch unreachable;
            defer child.deinit();

            child.env_map = b.env_map;
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            child.spawn() catch |err| debug.panic("Unable to spawn {}: {}\n", .{ zig_args.items[0], @errorName(err) });

            var stdout_buf = Buffer.initNull(b.allocator);
            var stderr_buf = Buffer.initNull(b.allocator);

            var stdout_file_in_stream = child.stdout.?.inStream();
            var stderr_file_in_stream = child.stderr.?.inStream();

            stdout_file_in_stream.stream.readAllBuffer(&stdout_buf, max_stdout_size) catch unreachable;
            stderr_file_in_stream.stream.readAllBuffer(&stderr_buf, max_stdout_size) catch unreachable;

            const term = child.wait() catch |err| {
                debug.panic("Unable to spawn {}: {}\n", .{ zig_args.items[0], @errorName(err) });
            };
            switch (term) {
                .Exited => |code| {
                    if (code == 0) {
                        printInvocation(zig_args.toSliceConst());
                        return error.CompilationIncorrectlySucceeded;
                    }
                },
                else => {
                    warn("Process {} terminated unexpectedly\n", .{b.zig_exe});
                    printInvocation(zig_args.toSliceConst());
                    return error.TestFailed;
                },
            }

            const stdout = stdout_buf.toSliceConst();
            const stderr = stderr_buf.toSliceConst();

            if (stdout.len != 0) {
                warn(
                    \\
                    \\Expected empty stdout, instead found:
                    \\================================================
                    \\{}
                    \\================================================
                    \\
                , .{stdout});
                return error.TestFailed;
            }

            var ok = true;
            if (self.case.expect_exact) {
                var err_iter = ErrLineIter.init(stderr);
                var i: usize = 0;
                ok = while (err_iter.next()) |line| : (i += 1) {
                    if (i >= self.case.expected_errors.len) break false;
                    const expected = self.case.expected_errors.at(i);
                    if (mem.indexOf(u8, line, expected) == null) break false;
                    continue;
                } else true;

                ok = ok and i == self.case.expected_errors.len;

                if (!ok) {
                    warn("\n======== Expected these compile errors: ========\n", .{});
                    for (self.case.expected_errors.toSliceConst()) |expected| {
                        warn("{}\n", .{expected});
                    }
                }
            } else {
                for (self.case.expected_errors.toSliceConst()) |expected| {
                    if (mem.indexOf(u8, stderr, expected) == null) {
                        warn(
                            \\
                            \\=========== Expected compile error: ============
                            \\{}
                            \\
                        , .{expected});
                        ok = false;
                        break;
                    }
                }
            }

            if (!ok) {
                warn(
                    \\================= Full output: =================
                    \\{}
                    \\
                , .{stderr});
                return error.TestFailed;
            }

            warn("OK\n", .{});
        }
    };

    pub fn create(
        self: *CompileErrorContext,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) *TestCase {
        const tc = self.b.allocator.create(TestCase) catch unreachable;
        tc.* = TestCase{
            .name = name,
            .sources = ArrayList(TestCase.SourceFile).init(self.b.allocator),
            .expected_errors = ArrayList([]const u8).init(self.b.allocator),
            .expect_exact = false,
            .link_libc = false,
            .is_exe = false,
            .is_test = false,
        };

        tc.addSourceFile("tmp.zig", source);
        var arg_i: usize = 0;
        while (arg_i < expected_lines.len) : (arg_i += 1) {
            tc.addExpectedError(expected_lines[arg_i]);
        }
        return tc;
    }

    pub fn addC(self: *CompileErrorContext, name: []const u8, source: []const u8, expected_lines: []const []const u8) void {
        var tc = self.create(name, source, expected_lines);
        tc.link_libc = true;
        self.addCase(tc);
    }

    pub fn addExe(
        self: *CompileErrorContext,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) void {
        var tc = self.create(name, source, expected_lines);
        tc.is_exe = true;
        self.addCase(tc);
    }

    pub fn add(
        self: *CompileErrorContext,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) void {
        const tc = self.create(name, source, expected_lines);
        self.addCase(tc);
    }

    pub fn addTest(
        self: *CompileErrorContext,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) void {
        const tc = self.create(name, source, expected_lines);
        tc.is_test = true;
        self.addCase(tc);
    }

    pub fn addCase(self: *CompileErrorContext, case: *const TestCase) void {
        const b = self.b;

        const annotated_case_name = fmt.allocPrint(self.b.allocator, "compile-error {}", .{
            case.name,
        }) catch unreachable;
        if (self.test_filter) |filter| {
            if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
        }

        const compile_and_cmp_errors = CompileCmpOutputStep.create(self, annotated_case_name, case, .Debug);
        self.step.dependOn(&compile_and_cmp_errors.step);

        for (case.sources.toSliceConst()) |src_file| {
            const expanded_src_path = fs.path.join(
                b.allocator,
                &[_][]const u8{ b.cache_root, src_file.filename },
            ) catch unreachable;
            const write_src = b.addWriteFile(expanded_src_path, src_file.source);
            compile_and_cmp_errors.step.dependOn(&write_src.step);
        }
    }
};

pub const StandaloneContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,
    modes: []const Mode,

    pub fn addC(self: *StandaloneContext, root_src: []const u8) void {
        self.addAllArgs(root_src, true);
    }

    pub fn add(self: *StandaloneContext, root_src: []const u8) void {
        self.addAllArgs(root_src, false);
    }

    pub fn addBuildFile(self: *StandaloneContext, build_file: []const u8) void {
        const b = self.b;

        const annotated_case_name = b.fmt("build {} (Debug)", .{build_file});
        if (self.test_filter) |filter| {
            if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
        }

        var zig_args = ArrayList([]const u8).init(b.allocator);
        const rel_zig_exe = fs.path.relative(b.allocator, b.build_root, b.zig_exe) catch unreachable;
        zig_args.append(rel_zig_exe) catch unreachable;
        zig_args.append("build") catch unreachable;

        zig_args.append("--build-file") catch unreachable;
        zig_args.append(b.pathFromRoot(build_file)) catch unreachable;

        zig_args.append("test") catch unreachable;

        if (b.verbose) {
            zig_args.append("--verbose") catch unreachable;
        }

        const run_cmd = b.addSystemCommand(zig_args.toSliceConst());

        const log_step = b.addLog("PASS {}\n", .{annotated_case_name});
        log_step.step.dependOn(&run_cmd.step);

        self.step.dependOn(&log_step.step);
    }

    pub fn addAllArgs(self: *StandaloneContext, root_src: []const u8, link_libc: bool) void {
        const b = self.b;

        for (self.modes) |mode| {
            const annotated_case_name = fmt.allocPrint(self.b.allocator, "build {} ({})", .{
                root_src,
                @tagName(mode),
            }) catch unreachable;
            if (self.test_filter) |filter| {
                if (mem.indexOf(u8, annotated_case_name, filter) == null) continue;
            }

            const exe = b.addExecutable("test", root_src);
            exe.setBuildMode(mode);
            if (link_libc) {
                exe.linkSystemLibrary("c");
            }

            const log_step = b.addLog("PASS {}\n", .{annotated_case_name});
            log_step.step.dependOn(&exe.step);

            self.step.dependOn(&log_step.step);
        }
    }
};

pub const TranslateCContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,

    const TestCase = struct {
        name: []const u8,
        sources: ArrayList(SourceFile),
        expected_lines: ArrayList([]const u8),
        allow_warnings: bool,

        const SourceFile = struct {
            filename: []const u8,
            source: []const u8,
        };

        pub fn addSourceFile(self: *TestCase, filename: []const u8, source: []const u8) void {
            self.sources.append(SourceFile{
                .filename = filename,
                .source = source,
            }) catch unreachable;
        }

        pub fn addExpectedLine(self: *TestCase, text: []const u8) void {
            self.expected_lines.append(text) catch unreachable;
        }
    };

    const TranslateCCmpOutputStep = struct {
        step: build.Step,
        context: *TranslateCContext,
        name: []const u8,
        test_index: usize,
        case: *const TestCase,

        pub fn create(context: *TranslateCContext, name: []const u8, case: *const TestCase) *TranslateCCmpOutputStep {
            const allocator = context.b.allocator;
            const ptr = allocator.create(TranslateCCmpOutputStep) catch unreachable;
            ptr.* = TranslateCCmpOutputStep{
                .step = build.Step.init("ParseCCmpOutput", allocator, make),
                .context = context,
                .name = name,
                .test_index = context.test_index,
                .case = case,
            };

            context.test_index += 1;
            return ptr;
        }

        fn make(step: *build.Step) !void {
            const self = @fieldParentPtr(TranslateCCmpOutputStep, "step", step);
            const b = self.context.b;

            const root_src = fs.path.join(
                b.allocator,
                &[_][]const u8{ b.cache_root, self.case.sources.items[0].filename },
            ) catch unreachable;

            var zig_args = ArrayList([]const u8).init(b.allocator);
            zig_args.append(b.zig_exe) catch unreachable;

            const translate_c_cmd = "translate-c";
            zig_args.append(translate_c_cmd) catch unreachable;
            zig_args.append(b.pathFromRoot(root_src)) catch unreachable;

            warn("Test {}/{} {}...", .{ self.test_index + 1, self.context.test_index, self.name });

            if (b.verbose) {
                printInvocation(zig_args.toSliceConst());
            }

            const child = std.ChildProcess.init(zig_args.toSliceConst(), b.allocator) catch unreachable;
            defer child.deinit();

            child.env_map = b.env_map;
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            child.spawn() catch |err| debug.panic("Unable to spawn {}: {}\n", .{
                zig_args.toSliceConst()[0],
                @errorName(err),
            });

            var stdout_buf = Buffer.initNull(b.allocator);
            var stderr_buf = Buffer.initNull(b.allocator);

            var stdout_file_in_stream = child.stdout.?.inStream();
            var stderr_file_in_stream = child.stderr.?.inStream();

            stdout_file_in_stream.stream.readAllBuffer(&stdout_buf, max_stdout_size) catch unreachable;
            stderr_file_in_stream.stream.readAllBuffer(&stderr_buf, max_stdout_size) catch unreachable;

            const term = child.wait() catch |err| {
                debug.panic("Unable to spawn {}: {}\n", .{ zig_args.toSliceConst()[0], @errorName(err) });
            };
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        warn("Compilation failed with exit code {}\n", .{code});
                        printInvocation(zig_args.toSliceConst());
                        return error.TestFailed;
                    }
                },
                .Signal => |code| {
                    warn("Compilation failed with signal {}\n", .{code});
                    printInvocation(zig_args.toSliceConst());
                    return error.TestFailed;
                },
                else => {
                    warn("Compilation terminated unexpectedly\n", .{});
                    printInvocation(zig_args.toSliceConst());
                    return error.TestFailed;
                },
            }

            const stdout = stdout_buf.toSliceConst();
            const stderr = stderr_buf.toSliceConst();

            if (stderr.len != 0 and !self.case.allow_warnings) {
                warn(
                    \\====== translate-c emitted warnings: =======
                    \\{}
                    \\============================================
                    \\
                , .{stderr});
                printInvocation(zig_args.toSliceConst());
                return error.TestFailed;
            }

            for (self.case.expected_lines.toSliceConst()) |expected_line| {
                if (mem.indexOf(u8, stdout, expected_line) == null) {
                    warn(
                        \\
                        \\========= Expected this output: ================
                        \\{}
                        \\========= But found: ===========================
                        \\{}
                        \\
                    , .{ expected_line, stdout });
                    printInvocation(zig_args.toSliceConst());
                    return error.TestFailed;
                }
            }
            warn("OK\n", .{});
        }
    };

    fn printInvocation(args: []const []const u8) void {
        for (args) |arg| {
            warn("{} ", .{arg});
        }
        warn("\n", .{});
    }

    pub fn create(
        self: *TranslateCContext,
        allow_warnings: bool,
        filename: []const u8,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) *TestCase {
        const tc = self.b.allocator.create(TestCase) catch unreachable;
        tc.* = TestCase{
            .name = name,
            .sources = ArrayList(TestCase.SourceFile).init(self.b.allocator),
            .expected_lines = ArrayList([]const u8).init(self.b.allocator),
            .allow_warnings = allow_warnings,
        };

        tc.addSourceFile(filename, source);
        var arg_i: usize = 0;
        while (arg_i < expected_lines.len) : (arg_i += 1) {
            tc.addExpectedLine(expected_lines[arg_i]);
        }
        return tc;
    }

    pub fn add(
        self: *TranslateCContext,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) void {
        const tc = self.create(false, "source.h", name, source, expected_lines);
        self.addCase(tc);
    }

    pub fn addAllowWarnings(
        self: *TranslateCContext,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) void {
        const tc = self.create(true, "source.h", name, source, expected_lines);
        self.addCase(tc);
    }

    pub fn addCase(self: *TranslateCContext, case: *const TestCase) void {
        const b = self.b;

        const translate_c_cmd = "translate-c";
        const annotated_case_name = fmt.allocPrint(self.b.allocator, "{} {}", .{ translate_c_cmd, case.name }) catch unreachable;
        if (self.test_filter) |filter| {
            if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
        }

        const translate_c_and_cmp = TranslateCCmpOutputStep.create(self, annotated_case_name, case);
        self.step.dependOn(&translate_c_and_cmp.step);

        for (case.sources.toSliceConst()) |src_file| {
            const expanded_src_path = fs.path.join(
                b.allocator,
                &[_][]const u8{ b.cache_root, src_file.filename },
            ) catch unreachable;
            const write_src = b.addWriteFile(expanded_src_path, src_file.source);
            translate_c_and_cmp.step.dependOn(&write_src.step);
        }
    }
};

pub const GenHContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,

    const TestCase = struct {
        name: []const u8,
        sources: ArrayList(SourceFile),
        expected_lines: ArrayList([]const u8),

        const SourceFile = struct {
            filename: []const u8,
            source: []const u8,
        };

        pub fn addSourceFile(self: *TestCase, filename: []const u8, source: []const u8) void {
            self.sources.append(SourceFile{
                .filename = filename,
                .source = source,
            }) catch unreachable;
        }

        pub fn addExpectedLine(self: *TestCase, text: []const u8) void {
            self.expected_lines.append(text) catch unreachable;
        }
    };

    const GenHCmpOutputStep = struct {
        step: build.Step,
        context: *GenHContext,
        obj: *LibExeObjStep,
        name: []const u8,
        test_index: usize,
        case: *const TestCase,

        pub fn create(
            context: *GenHContext,
            obj: *LibExeObjStep,
            name: []const u8,
            case: *const TestCase,
        ) *GenHCmpOutputStep {
            const allocator = context.b.allocator;
            const ptr = allocator.create(GenHCmpOutputStep) catch unreachable;
            ptr.* = GenHCmpOutputStep{
                .step = build.Step.init("ParseCCmpOutput", allocator, make),
                .context = context,
                .obj = obj,
                .name = name,
                .test_index = context.test_index,
                .case = case,
            };
            ptr.step.dependOn(&obj.step);
            context.test_index += 1;
            return ptr;
        }

        fn make(step: *build.Step) !void {
            const self = @fieldParentPtr(GenHCmpOutputStep, "step", step);
            const b = self.context.b;

            warn("Test {}/{} {}...", .{ self.test_index + 1, self.context.test_index, self.name });

            const full_h_path = self.obj.getOutputHPath();
            const actual_h = try io.readFileAlloc(b.allocator, full_h_path);

            for (self.case.expected_lines.toSliceConst()) |expected_line| {
                if (mem.indexOf(u8, actual_h, expected_line) == null) {
                    warn(
                        \\
                        \\========= Expected this output: ================
                        \\{}
                        \\========= But found: ===========================
                        \\{}
                        \\
                    , .{ expected_line, actual_h });
                    return error.TestFailed;
                }
            }
            warn("OK\n", .{});
        }
    };

    fn printInvocation(args: []const []const u8) void {
        for (args) |arg| {
            warn("{} ", .{arg});
        }
        warn("\n", .{});
    }

    pub fn create(
        self: *GenHContext,
        filename: []const u8,
        name: []const u8,
        source: []const u8,
        expected_lines: []const []const u8,
    ) *TestCase {
        const tc = self.b.allocator.create(TestCase) catch unreachable;
        tc.* = TestCase{
            .name = name,
            .sources = ArrayList(TestCase.SourceFile).init(self.b.allocator),
            .expected_lines = ArrayList([]const u8).init(self.b.allocator),
        };

        tc.addSourceFile(filename, source);
        var arg_i: usize = 0;
        while (arg_i < expected_lines.len) : (arg_i += 1) {
            tc.addExpectedLine(expected_lines[arg_i]);
        }
        return tc;
    }

    pub fn add(self: *GenHContext, name: []const u8, source: []const u8, expected_lines: []const []const u8) void {
        const tc = self.create("test.zig", name, source, expected_lines);
        self.addCase(tc);
    }

    pub fn addCase(self: *GenHContext, case: *const TestCase) void {
        const b = self.b;
        const root_src = fs.path.join(
            b.allocator,
            &[_][]const u8{ b.cache_root, case.sources.items[0].filename },
        ) catch unreachable;

        const mode = builtin.Mode.Debug;
        const annotated_case_name = fmt.allocPrint(self.b.allocator, "gen-h {} ({})", .{ case.name, @tagName(mode) }) catch unreachable;
        if (self.test_filter) |filter| {
            if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
        }

        const obj = b.addObject("test", root_src);
        obj.setBuildMode(mode);

        for (case.sources.toSliceConst()) |src_file| {
            const expanded_src_path = fs.path.join(
                b.allocator,
                &[_][]const u8{ b.cache_root, src_file.filename },
            ) catch unreachable;
            const write_src = b.addWriteFile(expanded_src_path, src_file.source);
            obj.step.dependOn(&write_src.step);
        }

        const cmp_h = GenHCmpOutputStep.create(self, obj, annotated_case_name, case);

        self.step.dependOn(&cmp_h.step);
    }
};

fn printInvocation(args: []const []const u8) void {
    for (args) |arg| {
        warn("{} ", .{arg});
    }
    warn("\n", .{});
}
