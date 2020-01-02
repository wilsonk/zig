/*
 * Copyright (c) 2015 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#include "ast_render.hpp"
#include "buffer.hpp"
#include "codegen.hpp"
#include "compiler.hpp"
#include "config.h"
#include "error.hpp"
#include "os.hpp"
#include "target.hpp"
#include "libc_installation.hpp"
#include "userland.h"
#include "glibc.hpp"
#include "dump_analysis.hpp"

#include <stdio.h>

static int print_error_usage(const char *arg0) {
    fprintf(stderr, "See `%s --help` for detailed usage information\n", arg0);
    return EXIT_FAILURE;
}

static int print_full_usage(const char *arg0, FILE *file, int return_code) {
    fprintf(file,
        "Usage: %s [command] [options]\n"
        "\n"
        "Commands:\n"
        "  build                        build project from build.zig\n"
        "  build-exe [source]           create executable from source or object files\n"
        "  build-lib [source]           create library from source or object files\n"
        "  build-obj [source]           create object from source or assembly\n"
        "  builtin                      show the source code of @import(\"builtin\")\n"
        "  cc                           C compiler\n"
        "  fmt                          parse files and render in canonical zig format\n"
        "  id                           print the base64-encoded compiler id\n"
        "  init-exe                     initialize a `zig build` application in the cwd\n"
        "  init-lib                     initialize a `zig build` library in the cwd\n"
        "  libc [paths_file]            Display native libc paths file or validate one\n"
        "  run [source] [-- [args]]     create executable and run immediately\n"
        "  translate-c [source]         convert c code to zig code\n"
        "  translate-c-2 [source]       experimental self-hosted translate-c\n"
        "  targets                      list available compilation targets\n"
        "  test [source]                create and run a test build\n"
        "  version                      print version number and exit\n"
        "  zen                          print zen of zig and exit\n"
        "\n"
        "Compile Options:\n"
        "  --c-source [options] [file]  compile C source code\n"
        "  --cache-dir [path]           override the local cache directory\n"
        "  --cache [auto|off|on]        build in cache, print output path to stdout\n"
        "  --color [auto|off|on]        enable or disable colored error messages\n"
        "  --disable-gen-h              do not generate a C header file (.h)\n"
        "  --disable-valgrind           omit valgrind client requests in debug builds\n"
        "  --enable-valgrind            include valgrind client requests release builds\n"
        "  -fstack-check                enable stack probing in unsafe builds\n"
        "  -fno-stack-check             disable stack probing in safe builds\n"
        "  -fsanitize-c                 enable C undefined behavior detection in unsafe builds\n"
        "  -fno-sanitize-c              disable C undefined behavior detection in safe builds\n"
        "  --emit [asm|bin|llvm-ir]     emit a specific file format as compilation output\n"
        "  -fPIC                        enable Position Independent Code\n"
        "  -fno-PIC                     disable Position Independent Code\n"
        "  -ftime-report                print timing diagnostics\n"
        "  -fstack-report               print stack size diagnostics\n"
#ifdef ZIG_ENABLE_MEM_PROFILE
        "  -fmem-report                 print memory usage diagnostics\n"
#endif
        "  -fdump-analysis              write analysis.json file with type information\n"
        "  -femit-docs                  create a docs/ dir with html documentation\n"
        "  -fno-emit-bin                skip emitting machine code\n"
        "  --libc [file]                Provide a file which specifies libc paths\n"
        "  --name [name]                override output name\n"
        "  --output-dir [dir]           override output directory (defaults to cwd)\n"
        "  --pkg-begin [name] [path]    make pkg available to import and push current pkg\n"
        "  --pkg-end                    pop current pkg\n"
        "  --main-pkg-path              set the directory of the root package\n"
        "  --release-fast               build with optimizations on and safety off\n"
        "  --release-safe               build with optimizations on and safety on\n"
        "  --release-small              build with size optimizations on and safety off\n"
        "  --single-threaded            source may assume it is only used single-threaded\n"
        "  -dynamic                     create a shared library (.so; .dll; .dylib)\n"
        "  --strip                      exclude debug symbols\n"
        "  -target [name]               <arch><sub>-<os>-<abi> see the targets command\n"
        "  -target-glibc [version]      target a specific glibc version (default: 2.17)\n"
        "  --verbose-tokenize           enable compiler debug output for tokenization\n"
        "  --verbose-ast                enable compiler debug output for AST parsing\n"
        "  --verbose-link               enable compiler debug output for linking\n"
        "  --verbose-ir                 enable compiler debug output for Zig IR\n"
        "  --verbose-llvm-ir            enable compiler debug output for LLVM IR\n"
        "  --verbose-cimport            enable compiler debug output for C imports\n"
        "  --verbose-cc                 enable compiler debug output for C compilation\n"
        "  -dirafter [dir]              add directory to AFTER include search path\n"
        "  -isystem [dir]               add directory to SYSTEM include search path\n"
        "  -I[dir]                      add directory to include search path\n"
        "  -mllvm [arg]                 (unsupported) forward an arg to LLVM's option processing\n"
        "  --override-lib-dir [arg]     override path to Zig lib directory\n"
        "  -ffunction-sections          places each function in a separate section\n"
        "  -D[macro]=[value]            define C [macro] to [value] (1 if [value] omitted)\n"
        "\n"
        "Link Options:\n"
        "  --bundle-compiler-rt         for static libraries, include compiler-rt symbols\n"
        "  --dynamic-linker [path]      set the path to ld.so\n"
        "  --each-lib-rpath             add rpath for each used dynamic library\n"
        "  --library [lib]              link against lib\n"
        "  --forbid-library [lib]       make it an error to link against lib\n"
        "  --library-path [dir]         add a directory to the library search path\n"
        "  --linker-script [path]       use a custom linker script\n"
        "  --version-script [path]      provide a version .map file\n"
        "  --object [obj]               add object file to build\n"
        "  -L[dir]                      alias for --library-path\n"
        "  -l[lib]                      alias for --library\n"
        "  -rdynamic                    add all symbols to the dynamic symbol table\n"
        "  -rpath [path]                add directory to the runtime library search path\n"
        "  --subsystem [subsystem]      (windows) /SUBSYSTEM:<subsystem> to the linker\n"
        "  -F[dir]                      (darwin) add search path for frameworks\n"
        "  -framework [name]            (darwin) link against framework\n"
        "  -mios-version-min [ver]      (darwin) set iOS deployment target\n"
        "  -mmacosx-version-min [ver]   (darwin) set Mac OS X deployment target\n"
        "  --ver-major [ver]            dynamic library semver major version\n"
        "  --ver-minor [ver]            dynamic library semver minor version\n"
        "  --ver-patch [ver]            dynamic library semver patch version\n"
        "\n"
        "Test Options:\n"
        "  --test-filter [text]         skip tests that do not match filter\n"
        "  --test-name-prefix [text]    add prefix to all tests\n"
        "  --test-cmd [arg]             specify test execution command one arg at a time\n"
        "  --test-cmd-bin               appends test binary path to test cmd args\n"
    , arg0);
    return return_code;
}

static int print_libc_usage(const char *arg0, FILE *file, int return_code) {
    fprintf(file,
        "Usage: %s libc\n"
        "\n"
        "Detect the native libc installation and print the resulting paths to stdout.\n"
        "You can save this into a file and then edit the paths to create a cross\n"
        "compilation libc kit. Then you can pass `--libc [file]` for Zig to use it.\n"
        "\n"
        "When compiling natively and no `--libc` argument provided, Zig automatically\n"
        "creates zig-cache/native_libc.txt so that it does not have to detect libc\n"
        "on every invocation. You can remove this file to have Zig re-detect the\n"
        "native libc.\n"
        "\n\n"
        "Usage: %s libc [file]\n"
        "\n"
        "Parse a libc installation text file and validate it.\n"
    , arg0, arg0);
    return return_code;
}

static bool arch_available_in_llvm(ZigLLVM_ArchType arch) {
    LLVMTargetRef target_ref;
    char *err_msg = nullptr;
    char triple_string[128];
    sprintf(triple_string, "%s-unknown-unknown-unknown", ZigLLVMGetArchTypeName(arch));
    return !LLVMGetTargetFromTriple(triple_string, &target_ref, &err_msg);
}

static int print_target_list(FILE *f) {
    ZigTarget native;
    get_native_target(&native);

    fprintf(f, "Architectures:\n");
    size_t arch_count = target_arch_count();
    for (size_t arch_i = 0; arch_i < arch_count; arch_i += 1) {
        ZigLLVM_ArchType arch = target_arch_enum(arch_i);
        if (!arch_available_in_llvm(arch))
            continue;
        const char *arch_name = target_arch_name(arch);
        SubArchList sub_arch_list = target_subarch_list(arch);
        size_t sub_count = target_subarch_count(sub_arch_list);
        const char *arch_native_str = (native.arch == arch) ? " (native)" : "";
        fprintf(f, "  %s%s\n", arch_name, arch_native_str);
        for (size_t sub_i = 0; sub_i < sub_count; sub_i += 1) {
            ZigLLVM_SubArchType sub = target_subarch_enum(sub_arch_list, sub_i);
            const char *sub_name = target_subarch_name(sub);
            const char *sub_native_str = (native.arch == arch && native.sub_arch == sub) ? " (native)" : "";
            fprintf(f, "    %s%s\n", sub_name, sub_native_str);
        }
    }

    fprintf(f, "\nOperating Systems:\n");
    size_t os_count = target_os_count();
    for (size_t i = 0; i < os_count; i += 1) {
        Os os_type = target_os_enum(i);
        const char *native_str = (native.os == os_type) ? " (native)" : "";
        fprintf(f, "  %s%s\n", target_os_name(os_type), native_str);
    }

    fprintf(f, "\nC ABIs:\n");
    size_t abi_count = target_abi_count();
    for (size_t i = 0; i < abi_count; i += 1) {
        ZigLLVM_EnvironmentType abi = target_abi_enum(i);
        const char *native_str = (native.abi == abi) ? " (native)" : "";
        fprintf(f, "  %s%s\n", target_abi_name(abi), native_str);
    }

    fprintf(f, "\nAvailable libcs:\n");
    size_t libc_count = target_libc_count();
    for (size_t i = 0; i < libc_count; i += 1) {
        ZigTarget libc_target;
        target_libc_enum(i, &libc_target);
        bool is_native = native.arch == libc_target.arch &&
            native.os == libc_target.os &&
            native.abi == libc_target.abi;
        const char *native_str = is_native ? " (native)" : "";
        fprintf(f, "  %s-%s-%s%s\n", target_arch_name(libc_target.arch),
                target_os_name(libc_target.os), target_abi_name(libc_target.abi), native_str);
    }

    fprintf(f, "\nAvailable glibc versions:\n");
    ZigGLibCAbi *glibc_abi;
    Error err;
    if ((err = glibc_load_metadata(&glibc_abi, get_zig_lib_dir(), true))) {
        return EXIT_FAILURE;
    }
    for (size_t i = 0; i < glibc_abi->all_versions.length; i += 1) {
        ZigGLibCVersion *this_ver = &glibc_abi->all_versions.at(i);
        bool is_native = native.glibc_version != nullptr &&
            native.glibc_version->major == this_ver->major &&
            native.glibc_version->minor == this_ver->minor &&
            native.glibc_version->patch == this_ver->patch;
        const char *native_str = is_native ? " (native)" : "";
        if (this_ver->patch == 0) {
            fprintf(f, "  %d.%d%s\n", this_ver->major, this_ver->minor, native_str);
        } else {
            fprintf(f, "  %d.%d.%d%s\n", this_ver->major, this_ver->minor, this_ver->patch, native_str);
        }
    }
    return EXIT_SUCCESS;
}

enum Cmd {
    CmdNone,
    CmdBuild,
    CmdBuiltin,
    CmdRun,
    CmdTargets,
    CmdTest,
    CmdTranslateC,
    CmdVersion,
    CmdZen,
    CmdLibC,
};

static const char *default_zig_cache_name = "zig-cache";

struct CliPkg {
    const char *name;
    const char *path;
    ZigList<CliPkg *> children;
    CliPkg *parent;
};

static void add_package(CodeGen *g, CliPkg *cli_pkg, ZigPackage *pkg) {
    for (size_t i = 0; i < cli_pkg->children.length; i += 1) {
        CliPkg *child_cli_pkg = cli_pkg->children.at(i);

        Buf *dirname = buf_alloc();
        Buf *basename = buf_alloc();
        os_path_split(buf_create_from_str(child_cli_pkg->path), dirname, basename);

        ZigPackage *child_pkg = codegen_create_package(g, buf_ptr(dirname), buf_ptr(basename),
                buf_ptr(buf_sprintf("%s.%s", buf_ptr(&pkg->pkg_path), child_cli_pkg->name)));
        auto entry = pkg->package_table.put_unique(buf_create_from_str(child_cli_pkg->name), child_pkg);
        if (entry) {
            ZigPackage *existing_pkg = entry->value;
            Buf *full_path = buf_alloc();
            os_path_join(&existing_pkg->root_src_dir, &existing_pkg->root_src_path, full_path);
            fprintf(stderr, "Unable to add package '%s'->'%s': already exists as '%s'\n",
                    child_cli_pkg->name, child_cli_pkg->path, buf_ptr(full_path));
            exit(EXIT_FAILURE);
        }

        add_package(g, child_cli_pkg, child_pkg);
    }
}

enum CacheOpt {
    CacheOptAuto,
    CacheOptOn,
    CacheOptOff,
};

static bool get_cache_opt(CacheOpt opt, bool default_value) {
    switch (opt) {
        case CacheOptAuto:
            return default_value;
        case CacheOptOn:
            return true;
        case CacheOptOff:
            return false;
    }
    zig_unreachable();
}

static int zig_error_no_build_file(void) {
    fprintf(stderr,
        "No 'build.zig' file found, in the current directory or any parent directories.\n"
        "Initialize a 'build.zig' template file with `zig init-lib` or `zig init-exe`,\n"
        "or see `zig --help` for more options.\n"
    );
    return EXIT_FAILURE;
}

extern "C" int ZigClang_main(int argc, char **argv);

#ifdef ZIG_ENABLE_MEM_PROFILE
bool mem_report = false;
#endif

int main_exit(Stage2ProgressNode *root_progress_node, int exit_code) {
    if (root_progress_node != nullptr) {
        stage2_progress_end(root_progress_node);
    }
#ifdef ZIG_ENABLE_MEM_PROFILE
    if (mem_report) {
        memprof_dump_stats(stderr);
    }
#endif
    return exit_code;
}

int main(int argc, char **argv) {
    stage2_attach_segfault_handler();

#ifdef ZIG_ENABLE_MEM_PROFILE
    memprof_init();
#endif

    char *arg0 = argv[0];
    Error err;

    if (argc == 2 && strcmp(argv[1], "BUILD_INFO") == 0) {
        printf("%s\n%s\n%s\n%s\n%s\n%s\n",
                ZIG_CMAKE_BINARY_DIR,
                ZIG_CXX_COMPILER,
                ZIG_LLVM_CONFIG_EXE,
                ZIG_LLD_INCLUDE_PATH,
                ZIG_LLD_LIBRARIES,
                ZIG_DIA_GUIDS_LIB);
        return 0;
    }

    if (argc >= 2 && (strcmp(argv[1], "cc") == 0 ||
            strcmp(argv[1], "-cc1") == 0 || strcmp(argv[1], "-cc1as") == 0))
    {
        return ZigClang_main(argc, argv);
    }

    // Must be before all os.hpp function calls.
    os_init();

    if (argc == 2 && strcmp(argv[1], "id") == 0) {
        Buf *compiler_id;
        if ((err = get_compiler_id(&compiler_id))) {
            fprintf(stderr, "Unable to determine compiler id: %s\n", err_str(err));
            return EXIT_FAILURE;
        }
        printf("%s\n", buf_ptr(compiler_id));
        return EXIT_SUCCESS;
    }

    enum InitKind {
        InitKindNone,
        InitKindExe,
        InitKindLib,
    };
    InitKind init_kind = InitKindNone;
    if (argc >= 2) {
        const char *init_cmd = argv[1];
        if (strcmp(init_cmd, "init-exe") == 0) {
            init_kind = InitKindExe;
        } else if (strcmp(init_cmd, "init-lib") == 0) {
            init_kind = InitKindLib;
        }
        if (init_kind != InitKindNone) {
            if (argc >= 3) {
                fprintf(stderr, "Unexpected extra argument: %s\n", argv[2]);
                return print_error_usage(arg0);
            }
            Buf *cmd_template_path = buf_alloc();
            os_path_join(get_zig_special_dir(get_zig_lib_dir()), buf_create_from_str(init_cmd), cmd_template_path);
            Buf *build_zig_path = buf_alloc();
            os_path_join(cmd_template_path, buf_create_from_str("build.zig"), build_zig_path);
            Buf *src_dir_path = buf_alloc();
            os_path_join(cmd_template_path, buf_create_from_str("src"), src_dir_path);
            Buf *main_zig_path = buf_alloc();
            os_path_join(src_dir_path, buf_create_from_str("main.zig"), main_zig_path);

            Buf *cwd = buf_alloc();
            if ((err = os_get_cwd(cwd))) {
                fprintf(stderr, "Unable to get cwd: %s\n", err_str(err));
                return EXIT_FAILURE;
            }
            Buf *cwd_basename = buf_alloc();
            os_path_split(cwd, nullptr, cwd_basename);

            Buf *build_zig_contents = buf_alloc();
            if ((err = os_fetch_file_path(build_zig_path, build_zig_contents))) {
                fprintf(stderr, "Unable to read %s: %s\n", buf_ptr(build_zig_path), err_str(err));
                return EXIT_FAILURE;
            }
            Buf *modified_build_zig_contents = buf_alloc();
            for (size_t i = 0; i < buf_len(build_zig_contents); i += 1) {
                char c = buf_ptr(build_zig_contents)[i];
                if (c == '$') {
                    buf_append_buf(modified_build_zig_contents, cwd_basename);
                } else {
                    buf_append_char(modified_build_zig_contents, c);
                }
            }

            Buf *main_zig_contents = buf_alloc();
            if ((err = os_fetch_file_path(main_zig_path, main_zig_contents))) {
                fprintf(stderr, "Unable to read %s: %s\n", buf_ptr(main_zig_path), err_str(err));
                return EXIT_FAILURE;
            }

            Buf *out_build_zig_path = buf_create_from_str("build.zig");
            Buf *out_src_dir_path = buf_create_from_str("src");
            Buf *out_main_zig_path = buf_alloc();
            os_path_join(out_src_dir_path, buf_create_from_str("main.zig"), out_main_zig_path);

            bool already_exists;
            if ((err = os_file_exists(out_build_zig_path, &already_exists))) {
                fprintf(stderr, "Unable test existence of %s: %s\n", buf_ptr(out_build_zig_path), err_str(err));
                return EXIT_FAILURE;
            }
            if (already_exists) {
                fprintf(stderr, "This file would be overwritten: %s\n", buf_ptr(out_build_zig_path));
                return EXIT_FAILURE;
            }

            if ((err = os_make_dir(out_src_dir_path))) {
                fprintf(stderr, "Unable to make directory: %s: %s\n", buf_ptr(out_src_dir_path), err_str(err));
                return EXIT_FAILURE;
            }
            if ((err = os_write_file(out_build_zig_path, modified_build_zig_contents))) {
                fprintf(stderr, "Unable to write file: %s: %s\n", buf_ptr(out_build_zig_path), err_str(err));
                return EXIT_FAILURE;
            }
            if ((err = os_write_file(out_main_zig_path, main_zig_contents))) {
                fprintf(stderr, "Unable to write file: %s: %s\n", buf_ptr(out_main_zig_path), err_str(err));
                return EXIT_FAILURE;
            }
            fprintf(stderr, "Created %s\n", buf_ptr(out_build_zig_path));
            fprintf(stderr, "Created %s\n", buf_ptr(out_main_zig_path));
            if (init_kind == InitKindExe) {
                fprintf(stderr, "\nNext, try `zig build --help` or `zig build run`\n");
            } else if (init_kind == InitKindLib) {
                fprintf(stderr, "\nNext, try `zig build --help` or `zig build test`\n");
            } else {
                zig_unreachable();
            }

            return EXIT_SUCCESS;
        }
    }

    Cmd cmd = CmdNone;
    EmitFileType emit_file_type = EmitFileTypeBinary;
    const char *in_file = nullptr;
    Buf *output_dir = nullptr;
    bool strip = false;
    bool is_dynamic = false;
    OutType out_type = OutTypeUnknown;
    const char *out_name = nullptr;
    bool verbose_tokenize = false;
    bool verbose_ast = false;
    bool verbose_link = false;
    bool verbose_ir = false;
    bool verbose_llvm_ir = false;
    bool verbose_cimport = false;
    bool verbose_cc = false;
    ErrColor color = ErrColorAuto;
    CacheOpt enable_cache = CacheOptAuto;
    Buf *dynamic_linker = nullptr;
    const char *libc_txt = nullptr;
    ZigList<const char *> clang_argv = {0};
    ZigList<const char *> lib_dirs = {0};
    ZigList<const char *> link_libs = {0};
    ZigList<const char *> forbidden_link_libs = {0};
    ZigList<const char *> framework_dirs = {0};
    ZigList<const char *> frameworks = {0};
    bool have_libc = false;
    const char *target_string = nullptr;
    bool rdynamic = false;
    const char *mmacosx_version_min = nullptr;
    const char *mios_version_min = nullptr;
    const char *linker_script = nullptr;
    Buf *version_script = nullptr;
    const char *target_glibc = nullptr;
    ZigList<const char *> rpath_list = {0};
    bool each_lib_rpath = false;
    ZigList<const char *> objects = {0};
    ZigList<CFile *> c_source_files = {0};
    const char *test_filter = nullptr;
    const char *test_name_prefix = nullptr;
    size_t ver_major = 0;
    size_t ver_minor = 0;
    size_t ver_patch = 0;
    bool timing_info = false;
    bool stack_report = false;
    bool enable_dump_analysis = false;
    bool enable_doc_generation = false;
    bool disable_bin_generation = false;
    const char *cache_dir = nullptr;
    CliPkg *cur_pkg = allocate<CliPkg>(1);
    BuildMode build_mode = BuildModeDebug;
    ZigList<const char *> test_exec_args = {0};
    int runtime_args_start = -1;
    bool system_linker_hack = false;
    TargetSubsystem subsystem = TargetSubsystemAuto;
    bool want_single_threaded = false;
    bool disable_gen_h = false;
    bool bundle_compiler_rt = false;
    Buf *override_lib_dir = nullptr;
    Buf *main_pkg_path = nullptr;
    ValgrindSupport valgrind_support = ValgrindSupportAuto;
    WantPIC want_pic = WantPICAuto;
    WantStackCheck want_stack_check = WantStackCheckAuto;
    WantCSanitize want_sanitize_c = WantCSanitizeAuto;
    bool function_sections = false;

    ZigList<const char *> llvm_argv = {0};
    llvm_argv.append("zig (LLVM option parsing)");

    if (argc >= 2 && strcmp(argv[1], "build") == 0) {
        Buf zig_exe_path_buf = BUF_INIT;
        if ((err = os_self_exe_path(&zig_exe_path_buf))) {
            fprintf(stderr, "Unable to determine path to zig's own executable\n");
            return EXIT_FAILURE;
        }
        const char *zig_exe_path = buf_ptr(&zig_exe_path_buf);
        const char *build_file = nullptr;

        init_all_targets();

        ZigList<const char *> args = {0};
        args.append(NULL); // placeholder
        args.append(zig_exe_path);
        args.append(NULL); // placeholder
        args.append(NULL); // placeholder
        for (int i = 2; i < argc; i += 1) {
            if (strcmp(argv[i], "--help") == 0) {
                args.append(argv[i]);
            } else if (i + 1 < argc && strcmp(argv[i], "--build-file") == 0) {
                build_file = argv[i + 1];
                i += 1;
            } else if (i + 1 < argc && strcmp(argv[i], "--cache-dir") == 0) {
                cache_dir = argv[i + 1];
                i += 1;
            } else if (i + 1 < argc && strcmp(argv[i], "--override-lib-dir") == 0) {
                override_lib_dir = buf_create_from_str(argv[i + 1]);
                i += 1;

                args.append("--override-lib-dir");
                args.append(buf_ptr(override_lib_dir));
            } else {
                args.append(argv[i]);
            }
        }

        Buf *zig_lib_dir = (override_lib_dir == nullptr) ? get_zig_lib_dir() : override_lib_dir;

        Buf *build_runner_path = buf_alloc();
        os_path_join(get_zig_special_dir(zig_lib_dir), buf_create_from_str("build_runner.zig"), build_runner_path);

        ZigTarget target;
        get_native_target(&target);

        Buf *build_file_buf = buf_create_from_str((build_file != nullptr) ? build_file : "build.zig");
        Buf build_file_abs = os_path_resolve(&build_file_buf, 1);
        Buf build_file_basename = BUF_INIT;
        Buf build_file_dirname = BUF_INIT;
        os_path_split(&build_file_abs, &build_file_dirname, &build_file_basename);

        for (;;) {
            bool build_file_exists;
            if ((err = os_file_exists(&build_file_abs, &build_file_exists))) {
                fprintf(stderr, "unable to check existence of '%s': %s\n", buf_ptr(&build_file_abs), err_str(err));
                return 1;
            }
            if (build_file_exists)
                break;

            if (build_file != nullptr) {
                // they asked for a specific build file path. only look for that one
                return zig_error_no_build_file();
            }

            Buf *next_dir = buf_alloc();
            os_path_dirname(&build_file_dirname, next_dir);
            if (buf_eql_buf(&build_file_dirname, next_dir)) {
                // no more parent directories to search, give up
                return zig_error_no_build_file();
            }
            os_path_join(next_dir, &build_file_basename, &build_file_abs);
            buf_init_from_buf(&build_file_dirname, next_dir);
        }

        Buf full_cache_dir = BUF_INIT;
        if (cache_dir == nullptr) {
            os_path_join(&build_file_dirname, buf_create_from_str(default_zig_cache_name), &full_cache_dir);
        } else {
            Buf *cache_dir_buf = buf_create_from_str(cache_dir);
            full_cache_dir = os_path_resolve(&cache_dir_buf, 1);
        }
        Stage2ProgressNode *root_progress_node = stage2_progress_start_root(stage2_progress_create(), "", 0, 0);

        CodeGen *g = codegen_create(main_pkg_path, build_runner_path, &target, OutTypeExe,
                BuildModeDebug, override_lib_dir, nullptr, &full_cache_dir, false, root_progress_node);
        g->valgrind_support = valgrind_support;
        g->enable_time_report = timing_info;
        codegen_set_out_name(g, buf_create_from_str("build"));

        args.items[2] = buf_ptr(&build_file_dirname);
        args.items[3] = buf_ptr(&full_cache_dir);

        ZigPackage *build_pkg = codegen_create_package(g, buf_ptr(&build_file_dirname),
                buf_ptr(&build_file_basename), "std.special");
        g->main_pkg->package_table.put(buf_create_from_str("@build"), build_pkg);
        g->enable_cache = get_cache_opt(enable_cache, true);
        codegen_build_and_link(g);
        if (root_progress_node != nullptr) {
            stage2_progress_end(root_progress_node);
            root_progress_node = nullptr;
        }

        Termination term;
        args.items[0] = buf_ptr(&g->output_file_path);
        os_spawn_process(args, &term);
        if (term.how != TerminationIdClean || term.code != 0) {
            fprintf(stderr, "\nBuild failed. The following command failed:\n");
            const char *prefix = "";
            for (size_t i = 0; i < args.length; i += 1) {
                fprintf(stderr, "%s%s", prefix, args.at(i));
                prefix = " ";
            }
            fprintf(stderr, "\n");
        }
        return (term.how == TerminationIdClean) ? term.code : -1;
    } else if (argc >= 2 && strcmp(argv[1], "fmt") == 0) {
        return stage2_fmt(argc, argv);
    }

    for (int i = 1; i < argc; i += 1) {
        char *arg = argv[i];

        if (arg[0] == '-') {
            if (strcmp(arg, "--") == 0) {
                if (cmd == CmdRun) {
                    runtime_args_start = i + 1;
                    break; // rest of the args are for the program
                } else {
                    fprintf(stderr, "Unexpected end-of-parameter mark: %s\n", arg);
                }
            } else if (strcmp(arg, "--release-fast") == 0) {
                build_mode = BuildModeFastRelease;
            } else if (strcmp(arg, "--release-safe") == 0) {
                build_mode = BuildModeSafeRelease;
            } else if (strcmp(arg, "--release-small") == 0) {
                build_mode = BuildModeSmallRelease;
            } else if (strcmp(arg, "--help") == 0) {
                if (cmd == CmdLibC) {
                    return print_libc_usage(arg0, stdout, EXIT_SUCCESS);
                } else {
                    return print_full_usage(arg0, stdout, EXIT_SUCCESS);
                }
            } else if (strcmp(arg, "--strip") == 0) {
                strip = true;
            } else if (strcmp(arg, "-dynamic") == 0) {
                is_dynamic = true;
            } else if (strcmp(arg, "--verbose-tokenize") == 0) {
                verbose_tokenize = true;
            } else if (strcmp(arg, "--verbose-ast") == 0) {
                verbose_ast = true;
            } else if (strcmp(arg, "--verbose-link") == 0) {
                verbose_link = true;
            } else if (strcmp(arg, "--verbose-ir") == 0) {
                verbose_ir = true;
            } else if (strcmp(arg, "--verbose-llvm-ir") == 0) {
                verbose_llvm_ir = true;
            } else if (strcmp(arg, "--verbose-cimport") == 0) {
                verbose_cimport = true;
            } else if (strcmp(arg, "--verbose-cc") == 0) {
                verbose_cc = true;
            } else if (strcmp(arg, "-rdynamic") == 0) {
                rdynamic = true;
            } else if (strcmp(arg, "--each-lib-rpath") == 0) {
                each_lib_rpath = true;
            } else if (strcmp(arg, "-ftime-report") == 0) {
                timing_info = true;
            } else if (strcmp(arg, "-fstack-report") == 0) {
                stack_report = true;
            } else if (strcmp(arg, "-fmem-report") == 0) {
#ifdef ZIG_ENABLE_MEM_PROFILE
                mem_report = true;
#else
                fprintf(stderr, "-fmem-report requires configuring with -DZIG_ENABLE_MEM_PROFILE=ON\n");
                return print_error_usage(arg0);
#endif
            } else if (strcmp(arg, "-fdump-analysis") == 0) {
                enable_dump_analysis = true;
            } else if (strcmp(arg, "-femit-docs") == 0) {
                enable_doc_generation = true;
            } else if (strcmp(arg, "-fno-emit-bin") == 0) {
                disable_bin_generation = true;
            } else if (strcmp(arg, "--enable-valgrind") == 0) {
                valgrind_support = ValgrindSupportEnabled;
            } else if (strcmp(arg, "--disable-valgrind") == 0) {
                valgrind_support = ValgrindSupportDisabled;
            } else if (strcmp(arg, "-fPIC") == 0) {
                want_pic = WantPICEnabled;
            } else if (strcmp(arg, "-fno-PIC") == 0) {
                want_pic = WantPICDisabled;
            } else if (strcmp(arg, "-fstack-check") == 0) {
                want_stack_check = WantStackCheckEnabled;
            } else if (strcmp(arg, "-fno-stack-check") == 0) {
                want_stack_check = WantStackCheckDisabled;
            } else if (strcmp(arg, "-fsanitize-c") == 0) {
                want_sanitize_c = WantCSanitizeEnabled;
            } else if (strcmp(arg, "-fno-sanitize-c") == 0) {
                want_sanitize_c = WantCSanitizeDisabled;
            } else if (strcmp(arg, "--system-linker-hack") == 0) {
                system_linker_hack = true;
            } else if (strcmp(arg, "--single-threaded") == 0) {
                want_single_threaded = true;
            } else if (strcmp(arg, "--disable-gen-h") == 0) {
                disable_gen_h = true;
            } else if (strcmp(arg, "--bundle-compiler-rt") == 0) {
                bundle_compiler_rt = true;
            } else if (strcmp(arg, "--test-cmd-bin") == 0) {
                test_exec_args.append(nullptr);
            } else if (arg[1] == 'D' && arg[2] != 0) {
                clang_argv.append("-D");
                clang_argv.append(&arg[2]);
            } else if (arg[1] == 'L' && arg[2] != 0) {
                // alias for --library-path
                lib_dirs.append(&arg[2]);
            } else if (arg[1] == 'l' && arg[2] != 0) {
                // alias for --library
                const char *l = &arg[2];
                if (strcmp(l, "c") == 0)
                    have_libc = true;
                link_libs.append(l);
            } else if (arg[1] == 'I' && arg[2] != 0) {
                clang_argv.append("-I");
                clang_argv.append(&arg[2]);
            } else if (arg[1] == 'F' && arg[2] != 0) {
                framework_dirs.append(&arg[2]);
            } else if (strcmp(arg, "--pkg-begin") == 0) {
                if (i + 2 >= argc) {
                    fprintf(stderr, "Expected 2 arguments after --pkg-begin\n");
                    return print_error_usage(arg0);
                }
                CliPkg *new_cur_pkg = allocate<CliPkg>(1);
                i += 1;
                new_cur_pkg->name = argv[i];
                i += 1;
                new_cur_pkg->path = argv[i];
                new_cur_pkg->parent = cur_pkg;
                cur_pkg->children.append(new_cur_pkg);
                cur_pkg = new_cur_pkg;
            } else if (strcmp(arg, "--pkg-end") == 0) {
                if (cur_pkg->parent == nullptr) {
                    fprintf(stderr, "Encountered --pkg-end with no matching --pkg-begin\n");
                    return EXIT_FAILURE;
                }
                cur_pkg = cur_pkg->parent;
            } else if (strcmp(arg, "-ffunction-sections") == 0) {
                function_sections = true;
            } else if (i + 1 >= argc) {
                fprintf(stderr, "Expected another argument after %s\n", arg);
                return print_error_usage(arg0);
            } else {
                i += 1;
                if (strcmp(arg, "--output-dir") == 0) {
                    output_dir = buf_create_from_str(argv[i]);
                } else if (strcmp(arg, "--color") == 0) {
                    if (strcmp(argv[i], "auto") == 0) {
                        color = ErrColorAuto;
                    } else if (strcmp(argv[i], "on") == 0) {
                        color = ErrColorOn;
                    } else if (strcmp(argv[i], "off") == 0) {
                        color = ErrColorOff;
                    } else {
                        fprintf(stderr, "--color options are 'auto', 'on', or 'off'\n");
                        return print_error_usage(arg0);
                    }
                } else if (strcmp(arg, "--cache") == 0) {
                    if (strcmp(argv[i], "auto") == 0) {
                        enable_cache = CacheOptAuto;
                    } else if (strcmp(argv[i], "on") == 0) {
                        enable_cache = CacheOptOn;
                    } else if (strcmp(argv[i], "off") == 0) {
                        enable_cache = CacheOptOff;
                    } else {
                        fprintf(stderr, "--cache options are 'auto', 'on', or 'off'\n");
                        return print_error_usage(arg0);
                    }
                } else if (strcmp(arg, "--emit") == 0) {
                    if (strcmp(argv[i], "asm") == 0) {
                        emit_file_type = EmitFileTypeAssembly;
                    } else if (strcmp(argv[i], "bin") == 0) {
                        emit_file_type = EmitFileTypeBinary;
                    } else if (strcmp(argv[i], "llvm-ir") == 0) {
                        emit_file_type = EmitFileTypeLLVMIr;
                    } else {
                        fprintf(stderr, "--emit options are 'asm', 'bin', or 'llvm-ir'\n");
                        return print_error_usage(arg0);
                    }
                } else if (strcmp(arg, "--name") == 0) {
                    out_name = argv[i];
                } else if (strcmp(arg, "--dynamic-linker") == 0) {
                    dynamic_linker = buf_create_from_str(argv[i]);
                } else if (strcmp(arg, "--libc") == 0) {
                    libc_txt = argv[i];
                } else if (strcmp(arg, "-D") == 0) {
                    clang_argv.append("-D");
                    clang_argv.append(argv[i]);
                } else if (strcmp(arg, "-isystem") == 0) {
                    clang_argv.append("-isystem");
                    clang_argv.append(argv[i]);
                } else if (strcmp(arg, "-I") == 0) {
                    clang_argv.append("-I");
                    clang_argv.append(argv[i]);
                } else if (strcmp(arg, "-dirafter") == 0) {
                    clang_argv.append("-dirafter");
                    clang_argv.append(argv[i]);
                } else if (strcmp(arg, "-mllvm") == 0) {
                    clang_argv.append("-mllvm");
                    clang_argv.append(argv[i]);

                    llvm_argv.append(argv[i]);
                } else if (strcmp(arg, "--override-lib-dir") == 0) {
                    override_lib_dir = buf_create_from_str(argv[i]);
                } else if (strcmp(arg, "--main-pkg-path") == 0) {
                    main_pkg_path = buf_create_from_str(argv[i]);
                } else if (strcmp(arg, "--library-path") == 0 || strcmp(arg, "-L") == 0) {
                    lib_dirs.append(argv[i]);
                } else if (strcmp(arg, "-F") == 0) {
                    framework_dirs.append(argv[i]);
                } else if (strcmp(arg, "--library") == 0 || strcmp(arg, "-l") == 0) {
                    if (strcmp(argv[i], "c") == 0)
                        have_libc = true;
                    link_libs.append(argv[i]);
                } else if (strcmp(arg, "--forbid-library") == 0) {
                    forbidden_link_libs.append(argv[i]);
                } else if (strcmp(arg, "--object") == 0) {
                    objects.append(argv[i]);
                } else if (strcmp(arg, "--c-source") == 0) {
                    CFile *c_file = allocate<CFile>(1);
                    for (;;) {
                        if (argv[i][0] == '-') {
                            c_file->args.append(argv[i]);
                            i += 1;
                            if (i < argc) {
                                continue;
                            }

                            break;
                        } else {
                            c_file->source_path = argv[i];
                            c_source_files.append(c_file);
                            break;
                        }
                    }
                } else if (strcmp(arg, "--cache-dir") == 0) {
                    cache_dir = argv[i];
                } else if (strcmp(arg, "-target") == 0) {
                    target_string = argv[i];
                } else if (strcmp(arg, "-mmacosx-version-min") == 0) {
                    mmacosx_version_min = argv[i];
                } else if (strcmp(arg, "-mios-version-min") == 0) {
                    mios_version_min = argv[i];
                } else if (strcmp(arg, "-framework") == 0) {
                    frameworks.append(argv[i]);
                } else if (strcmp(arg, "--linker-script") == 0) {
                    linker_script = argv[i];
                } else if (strcmp(arg, "--version-script") == 0) {
                    version_script = buf_create_from_str(argv[i]); 
                } else if (strcmp(arg, "-target-glibc") == 0) {
                    target_glibc = argv[i];
                } else if (strcmp(arg, "-rpath") == 0) {
                    rpath_list.append(argv[i]);
                } else if (strcmp(arg, "--test-filter") == 0) {
                    test_filter = argv[i];
                } else if (strcmp(arg, "--test-name-prefix") == 0) {
                    test_name_prefix = argv[i];
                } else if (strcmp(arg, "--ver-major") == 0) {
                    ver_major = atoi(argv[i]);
                } else if (strcmp(arg, "--ver-minor") == 0) {
                    ver_minor = atoi(argv[i]);
                } else if (strcmp(arg, "--ver-patch") == 0) {
                    ver_patch = atoi(argv[i]);
                } else if (strcmp(arg, "--test-cmd") == 0) {
                    test_exec_args.append(argv[i]);
                } else if (strcmp(arg, "--subsystem") == 0) {
                    if (strcmp(argv[i], "console") == 0) {
                        subsystem = TargetSubsystemConsole;
                    } else if (strcmp(argv[i], "windows") == 0) {
                        subsystem = TargetSubsystemWindows;
                    } else if (strcmp(argv[i], "posix") == 0) {
                        subsystem = TargetSubsystemPosix;
                    } else if (strcmp(argv[i], "native") == 0) {
                        subsystem = TargetSubsystemNative;
                    } else if (strcmp(argv[i], "efi_application") == 0) {
                        subsystem = TargetSubsystemEfiApplication;
                    } else if (strcmp(argv[i], "efi_boot_service_driver") == 0) {
                        subsystem = TargetSubsystemEfiBootServiceDriver;
                    } else if (strcmp(argv[i], "efi_rom") == 0) {
                        subsystem = TargetSubsystemEfiRom;
                    } else if (strcmp(argv[i], "efi_runtime_driver") == 0) {
                        subsystem = TargetSubsystemEfiRuntimeDriver;
                    } else {
                        fprintf(stderr, "invalid: --subsystem %s\n"
                                "Options are:\n"
                                "  console\n"
                                "  windows\n"
                                "  posix\n"
                                "  native\n"
                                "  efi_application\n"
                                "  efi_boot_service_driver\n"
                                "  efi_rom\n"
                                "  efi_runtime_driver\n"
                            , argv[i]);
                        return EXIT_FAILURE;
                    }
                } else {
                    fprintf(stderr, "Invalid argument: %s\n", arg);
                    return print_error_usage(arg0);
                }
            }
        } else if (cmd == CmdNone) {
            if (strcmp(arg, "build-exe") == 0) {
                cmd = CmdBuild;
                out_type = OutTypeExe;
            } else if (strcmp(arg, "build-obj") == 0) {
                cmd = CmdBuild;
                out_type = OutTypeObj;
            } else if (strcmp(arg, "build-lib") == 0) {
                cmd = CmdBuild;
                out_type = OutTypeLib;
            } else if (strcmp(arg, "run") == 0) {
                cmd = CmdRun;
                out_type = OutTypeExe;
            } else if (strcmp(arg, "version") == 0) {
                cmd = CmdVersion;
            } else if (strcmp(arg, "zen") == 0) {
                cmd = CmdZen;
            } else if (strcmp(arg, "libc") == 0) {
                cmd = CmdLibC;
            } else if (strcmp(arg, "translate-c") == 0) {
                cmd = CmdTranslateC;
            } else if (strcmp(arg, "test") == 0) {
                cmd = CmdTest;
                out_type = OutTypeExe;
            } else if (strcmp(arg, "targets") == 0) {
                cmd = CmdTargets;
            } else if (strcmp(arg, "builtin") == 0) {
                cmd = CmdBuiltin;
            } else {
                fprintf(stderr, "Unrecognized command: %s\n", arg);
                return print_error_usage(arg0);
            }
        } else {
            switch (cmd) {
                case CmdBuild:
                case CmdRun:
                case CmdTranslateC:
                case CmdTest:
                case CmdLibC:
                    if (!in_file) {
                        in_file = arg;
                    } else {
                        fprintf(stderr, "Unexpected extra parameter: %s\n", arg);
                        return print_error_usage(arg0);
                    }
                    break;
                case CmdBuiltin:
                case CmdVersion:
                case CmdZen:
                case CmdTargets:
                    fprintf(stderr, "Unexpected extra parameter: %s\n", arg);
                    return print_error_usage(arg0);
                case CmdNone:
                    zig_unreachable();
            }
        }
    }

    if (cur_pkg->parent != nullptr) {
        fprintf(stderr, "Unmatched --pkg-begin\n");
        return EXIT_FAILURE;
    }

    Stage2Progress *progress = stage2_progress_create();
    Stage2ProgressNode *root_progress_node = stage2_progress_start_root(progress, "", 0, 0);
    if (color == ErrColorOff) stage2_progress_disable_tty(progress);

    init_all_targets();

    ZigTarget target;
    if (target_string == nullptr) {
        get_native_target(&target);
        if (target_glibc != nullptr) {
            fprintf(stderr, "-target-glibc provided but no -target parameter\n");
            return print_error_usage(arg0);
        }
    } else {
        if ((err = target_parse_triple(&target, target_string))) {
            if (err == ErrorUnknownArchitecture && target.arch != ZigLLVM_UnknownArch) {
                fprintf(stderr, "'%s' requires a sub-architecture. Try one of these:\n",
                        target_arch_name(target.arch));
                SubArchList sub_arch_list = target_subarch_list(target.arch);
                size_t subarch_count = target_subarch_count(sub_arch_list);
                for (size_t sub_i = 0; sub_i < subarch_count; sub_i += 1) {
                    ZigLLVM_SubArchType sub = target_subarch_enum(sub_arch_list, sub_i);
                    fprintf(stderr, "  %s%s\n", target_arch_name(target.arch), target_subarch_name(sub));
                }
                return print_error_usage(arg0);
            } else {
                fprintf(stderr, "invalid target: %s\n", err_str(err));
                return print_error_usage(arg0);
            }
        }
        if (target_is_glibc(&target)) {
            target.glibc_version = allocate<ZigGLibCVersion>(1);

            if (target_glibc != nullptr) {
                if ((err = target_parse_glibc_version(target.glibc_version, target_glibc))) {
                    fprintf(stderr, "invalid glibc version '%s': %s\n", target_glibc, err_str(err));
                    return print_error_usage(arg0);
                }
            } else {
                target_init_default_glibc_version(&target);
            }
        } else if (target_glibc != nullptr) {
            fprintf(stderr, "'%s' is not a glibc-compatible target", target_string);
            return print_error_usage(arg0);
        }
    }

    if (output_dir != nullptr && enable_cache == CacheOptOn) {
        fprintf(stderr, "`--output-dir` is incompatible with --cache on.\n");
        return print_error_usage(arg0);
    }

    if (target_requires_pic(&target, have_libc) && want_pic == WantPICDisabled) {
        Buf triple_buf = BUF_INIT;
        target_triple_zig(&triple_buf, &target);
        fprintf(stderr, "`--disable-pic` is incompatible with target '%s'\n", buf_ptr(&triple_buf));
        return print_error_usage(arg0);
    }

    if (emit_file_type != EmitFileTypeBinary && in_file == nullptr) {
        fprintf(stderr, "A root source file is required when using `--emit asm` or `--emit llvm-ir`\n");
        return print_error_usage(arg0);
    }

    if (llvm_argv.length > 1) {
        llvm_argv.append(nullptr);
        ZigLLVMParseCommandLineOptions(llvm_argv.length - 1, llvm_argv.items);
    }

    switch (cmd) {
    case CmdLibC: {
        if (in_file) {
            ZigLibCInstallation libc;
            if ((err = zig_libc_parse(&libc, buf_create_from_str(in_file), &target, true)))
                return main_exit(root_progress_node, EXIT_FAILURE);
            return main_exit(root_progress_node, EXIT_SUCCESS);
        }
        ZigLibCInstallation libc;
        if ((err = zig_libc_find_native(&libc, true)))
            return main_exit(root_progress_node, EXIT_FAILURE);
        zig_libc_render(&libc, stdout);
        return main_exit(root_progress_node, EXIT_SUCCESS);
    }
    case CmdBuiltin: {
        CodeGen *g = codegen_create(main_pkg_path, nullptr, &target,
                out_type, build_mode, override_lib_dir, nullptr, nullptr, false, root_progress_node);
        codegen_set_strip(g, strip);
        for (size_t i = 0; i < link_libs.length; i += 1) {
            LinkLib *link_lib = codegen_add_link_lib(g, buf_create_from_str(link_libs.at(i)));
            link_lib->provided_explicitly = true;
        }
        g->subsystem = subsystem;
        g->valgrind_support = valgrind_support;
        g->want_pic = want_pic;
        g->want_stack_check = want_stack_check;
        g->want_sanitize_c = want_sanitize_c;
        g->want_single_threaded = want_single_threaded;
        Buf *builtin_source = codegen_generate_builtin_source(g);
        if (fwrite(buf_ptr(builtin_source), 1, buf_len(builtin_source), stdout) != buf_len(builtin_source)) {
            fprintf(stderr, "unable to write to stdout: %s\n", strerror(ferror(stdout)));
            return main_exit(root_progress_node, EXIT_FAILURE);
        }
        return main_exit(root_progress_node, EXIT_SUCCESS);
    }
    case CmdRun:
    case CmdBuild:
    case CmdTranslateC:
    case CmdTest:
        {
            if (cmd == CmdBuild && !in_file && objects.length == 0 &&
                    c_source_files.length == 0)
            {
                fprintf(stderr,
                    "Expected at least one of these things:\n"
                    " * Zig root source file argument\n"
                    " * --object argument\n"
                    " * --c-source argument\n");
                return print_error_usage(arg0);
            } else if ((cmd == CmdTranslateC ||
                        cmd == CmdTest || cmd == CmdRun) && !in_file)
            {
                fprintf(stderr, "Expected source file argument.\n");
                return print_error_usage(arg0);
            } else if (cmd == CmdRun && emit_file_type != EmitFileTypeBinary) {
                fprintf(stderr, "Cannot run non-executable file.\n");
                return print_error_usage(arg0);
            }

            assert(cmd != CmdBuild || out_type != OutTypeUnknown);

            bool need_name = (cmd == CmdBuild || cmd == CmdTranslateC);

            if (cmd == CmdRun) {
                out_name = "run";
            }

            Buf *in_file_buf = nullptr;

            Buf *buf_out_name = (cmd == CmdTest) ? buf_create_from_str("test") :
                (out_name == nullptr) ? nullptr : buf_create_from_str(out_name);

            if (in_file) {
                in_file_buf = buf_create_from_str(in_file);

                if (need_name && buf_out_name == nullptr) {
                    Buf basename = BUF_INIT;
                    os_path_split(in_file_buf, nullptr, &basename);
                    buf_out_name = buf_alloc();
                    os_path_extname(&basename, buf_out_name, nullptr);
                }
            }

            if (need_name && buf_out_name == nullptr && c_source_files.length == 1) {
                Buf basename = BUF_INIT;
                os_path_split(buf_create_from_str(c_source_files.at(0)->source_path), nullptr, &basename);
                buf_out_name = buf_alloc();
                os_path_extname(&basename, buf_out_name, nullptr);
            }

            if (need_name && buf_out_name == nullptr) {
                fprintf(stderr, "--name [name] not provided and unable to infer\n\n");
                return print_error_usage(arg0);
            }

            Buf *zig_root_source_file = cmd == CmdTranslateC ? nullptr : in_file_buf;

            if (cmd == CmdRun && buf_out_name == nullptr) {
                buf_out_name = buf_create_from_str("run");
            }
            ZigLibCInstallation *libc = nullptr;
            if (libc_txt != nullptr) {
                libc = allocate<ZigLibCInstallation>(1);
                if ((err = zig_libc_parse(libc, buf_create_from_str(libc_txt), &target, true))) {
                    fprintf(stderr, "Unable to parse --libc text file: %s\n", err_str(err));
                    return main_exit(root_progress_node, EXIT_FAILURE);
                }
            }
            Buf *cache_dir_buf;
            if (cache_dir == nullptr) {
                if (cmd == CmdRun) {
                    cache_dir_buf = get_stage1_cache_path();
                } else {
                    cache_dir_buf = buf_create_from_str(default_zig_cache_name);
                }
            } else {
                cache_dir_buf = buf_create_from_str(cache_dir);
            }
            CodeGen *g = codegen_create(main_pkg_path, zig_root_source_file, &target, out_type, build_mode,
                    override_lib_dir, libc, cache_dir_buf, cmd == CmdTest, root_progress_node);
            if (llvm_argv.length >= 2) codegen_set_llvm_argv(g, llvm_argv.items + 1, llvm_argv.length - 2);
            g->valgrind_support = valgrind_support;
            g->want_pic = want_pic;
            g->want_stack_check = want_stack_check;
            g->want_sanitize_c = want_sanitize_c;
            g->subsystem = subsystem;

            g->enable_time_report = timing_info;
            g->enable_stack_report = stack_report;
            g->enable_dump_analysis = enable_dump_analysis;
            g->enable_doc_generation = enable_doc_generation;
            g->disable_bin_generation = disable_bin_generation;
            codegen_set_out_name(g, buf_out_name);
            codegen_set_lib_version(g, ver_major, ver_minor, ver_patch);
            g->want_single_threaded = want_single_threaded;
            codegen_set_linker_script(g, linker_script);
            g->version_script_path = version_script; 
            if (each_lib_rpath)
                codegen_set_each_lib_rpath(g, each_lib_rpath);

            codegen_set_clang_argv(g, clang_argv.items, clang_argv.length);

            codegen_set_strip(g, strip);
            g->is_dynamic = is_dynamic;
            g->dynamic_linker_path = dynamic_linker;
            g->verbose_tokenize = verbose_tokenize;
            g->verbose_ast = verbose_ast;
            g->verbose_link = verbose_link;
            g->verbose_ir = verbose_ir;
            g->verbose_llvm_ir = verbose_llvm_ir;
            g->verbose_cimport = verbose_cimport;
            g->verbose_cc = verbose_cc;
            g->output_dir = output_dir;
            g->disable_gen_h = disable_gen_h;
            g->bundle_compiler_rt = bundle_compiler_rt;
            codegen_set_errmsg_color(g, color);
            g->system_linker_hack = system_linker_hack;
            g->function_sections = function_sections;

            for (size_t i = 0; i < lib_dirs.length; i += 1) {
                codegen_add_lib_dir(g, lib_dirs.at(i));
            }
            for (size_t i = 0; i < framework_dirs.length; i += 1) {
                g->framework_dirs.append(framework_dirs.at(i));
            }
            for (size_t i = 0; i < link_libs.length; i += 1) {
                LinkLib *link_lib = codegen_add_link_lib(g, buf_create_from_str(link_libs.at(i)));
                link_lib->provided_explicitly = true;
            }
            for (size_t i = 0; i < forbidden_link_libs.length; i += 1) {
                Buf *forbidden_link_lib = buf_create_from_str(forbidden_link_libs.at(i));
                codegen_add_forbidden_lib(g, forbidden_link_lib);
            }
            for (size_t i = 0; i < frameworks.length; i += 1) {
                codegen_add_framework(g, frameworks.at(i));
            }
            for (size_t i = 0; i < rpath_list.length; i += 1) {
                codegen_add_rpath(g, rpath_list.at(i));
            }

            codegen_set_rdynamic(g, rdynamic);
            if (mmacosx_version_min && mios_version_min) {
                fprintf(stderr, "-mmacosx-version-min and -mios-version-min options not allowed together\n");
                return main_exit(root_progress_node, EXIT_FAILURE);
            }

            if (mmacosx_version_min) {
                codegen_set_mmacosx_version_min(g, buf_create_from_str(mmacosx_version_min));
            }

            if (mios_version_min) {
                codegen_set_mios_version_min(g, buf_create_from_str(mios_version_min));
            }

            if (test_filter) {
                codegen_set_test_filter(g, buf_create_from_str(test_filter));
            }

            if (test_name_prefix) {
                codegen_set_test_name_prefix(g, buf_create_from_str(test_name_prefix));
            }

            add_package(g, cur_pkg, g->main_pkg);

            if (cmd == CmdBuild || cmd == CmdRun || cmd == CmdTest) {
                g->c_source_files = c_source_files;
                for (size_t i = 0; i < objects.length; i += 1) {
                    codegen_add_object(g, buf_create_from_str(objects.at(i)));
                }
            }


            if (cmd == CmdBuild || cmd == CmdRun) {
                codegen_set_emit_file_type(g, emit_file_type);

                g->enable_cache = get_cache_opt(enable_cache, cmd == CmdRun);
                codegen_build_and_link(g);
                if (root_progress_node != nullptr) {
                    stage2_progress_end(root_progress_node);
                    root_progress_node = nullptr;
                }
                if (timing_info)
                    codegen_print_timing_report(g, stdout);
                if (stack_report)
                    zig_print_stack_report(g, stdout);

                if (cmd == CmdRun) {
#ifdef ZIG_ENABLE_MEM_PROFILE
                    memprof_dump_stats(stderr);
#endif

                    const char *exec_path = buf_ptr(&g->output_file_path);
                    ZigList<const char*> args = {0};

                    args.append(exec_path);
                    if (runtime_args_start != -1) {
                        for (int i = runtime_args_start; i < argc; ++i) {
                            args.append(argv[i]);
                        }
                    }
                    args.append(nullptr);

                    os_execv(exec_path, args.items);

                    args.pop();
                    Termination term;
                    os_spawn_process(args, &term);
                    return term.code;
                } else if (cmd == CmdBuild) {
                    if (g->enable_cache) {
#if defined(ZIG_OS_WINDOWS)
                        buf_replace(&g->output_file_path, '/', '\\');
#endif
                        if (printf("%s\n", buf_ptr(&g->output_file_path)) < 0)
                            return main_exit(root_progress_node, EXIT_FAILURE);
                    }
                    return main_exit(root_progress_node, EXIT_SUCCESS);
                } else {
                    zig_unreachable();
                }
            } else if (cmd == CmdTranslateC) {
                codegen_translate_c(g, in_file_buf, stdout);
                if (timing_info)
                    codegen_print_timing_report(g, stderr);
                return main_exit(root_progress_node, EXIT_SUCCESS);
            } else if (cmd == CmdTest) {
                codegen_set_emit_file_type(g, emit_file_type);

                ZigTarget native;
                get_native_target(&native);

                g->enable_cache = get_cache_opt(enable_cache, output_dir == nullptr);
                codegen_build_and_link(g);
                if (root_progress_node != nullptr) {
                    stage2_progress_end(root_progress_node);
                    root_progress_node = nullptr;
                }

                if (timing_info) {
                    codegen_print_timing_report(g, stdout);
                }

                if (stack_report) {
                    zig_print_stack_report(g, stdout);
                }

                if (g->disable_bin_generation) {
                    fprintf(stderr, "Semantic analysis complete. No binary produced due to -fno-emit-bin.\n");
                    return main_exit(root_progress_node, EXIT_SUCCESS);
                }

                Buf *test_exe_path_unresolved = &g->output_file_path;
                Buf *test_exe_path = buf_alloc();
                *test_exe_path = os_path_resolve(&test_exe_path_unresolved, 1);

                if (emit_file_type != EmitFileTypeBinary) {
                    fprintf(stderr, "Created %s but skipping execution because it is non executable.\n",
                            buf_ptr(test_exe_path));
                    return main_exit(root_progress_node, EXIT_SUCCESS);
                }

                for (size_t i = 0; i < test_exec_args.length; i += 1) {
                    if (test_exec_args.items[i] == nullptr) {
                        test_exec_args.items[i] = buf_ptr(test_exe_path);
                    }
                }

                if (!target_can_exec(&native, &target) && test_exec_args.length == 0) {
                    fprintf(stderr, "Created %s but skipping execution because it is non-native.\n",
                            buf_ptr(test_exe_path));
                    return main_exit(root_progress_node, EXIT_SUCCESS);
                }

                Termination term;
                if (test_exec_args.length == 0) {
                    test_exec_args.append(buf_ptr(test_exe_path));
                }
                os_spawn_process(test_exec_args, &term);
                if (term.how != TerminationIdClean || term.code != 0) {
                    fprintf(stderr, "\nTests failed. Use the following command to reproduce the failure:\n");
                    fprintf(stderr, "%s\n", buf_ptr(test_exe_path));
                }
                return main_exit(root_progress_node, (term.how == TerminationIdClean) ? term.code : -1);
            } else {
                zig_unreachable();
            }
        }
    case CmdVersion:
        printf("%s\n", ZIG_VERSION_STRING);
        return main_exit(root_progress_node, EXIT_SUCCESS);
    case CmdZen: {
        const char *ptr;
        size_t len;
        stage2_zen(&ptr, &len);
        fwrite(ptr, len, 1, stdout);
        return main_exit(root_progress_node, EXIT_SUCCESS);
    }
    case CmdTargets:
        return print_target_list(stdout);
    case CmdNone:
        return print_full_usage(arg0, stderr, EXIT_FAILURE);
    }
}
