#include "cache_hash.hpp"
#include "os.hpp"
#include "compiler.hpp"

#include <stdio.h>

Buf *get_self_libc_path(void) {
    static Buf saved_libc_path = BUF_INIT;
    static bool searched_for_libc = false;

    for (;;) {
        if (saved_libc_path.list.length != 0) {
            return &saved_libc_path;
        }
        if (searched_for_libc)
            return nullptr;
        ZigList<Buf *> lib_paths = {};
        Error err;
        if ((err = os_self_exe_shared_libs(lib_paths)))
            return nullptr;
        for (size_t i = 0; i < lib_paths.length; i += 1) {
            Buf *lib_path = lib_paths.at(i);
            if (buf_ends_with_str(lib_path, "libc.so.6")) {
                buf_init_from_buf(&saved_libc_path, lib_path);
                return &saved_libc_path;
            }
        }
        searched_for_libc = true;
    }
}

Error get_compiler_id(Buf **result) {
    static Buf saved_compiler_id = BUF_INIT;

    if (saved_compiler_id.list.length != 0) {
        *result = &saved_compiler_id;
        return ErrorNone;
    }

    Error err;
    Buf *manifest_dir = buf_alloc();
    os_path_join(get_global_cache_dir(), buf_create_from_str("exe"), manifest_dir);

    CacheHash cache_hash;
    CacheHash *ch = &cache_hash;
    cache_init(ch, manifest_dir);
    Buf self_exe_path = BUF_INIT;
    if ((err = os_self_exe_path(&self_exe_path)))
        return err;

    cache_file(ch, &self_exe_path);

    buf_resize(&saved_compiler_id, 0);
    if ((err = cache_hit(ch, &saved_compiler_id))) {
        if (err != ErrorInvalidFormat)
            return err;
    }
    if (buf_len(&saved_compiler_id) != 0) {
        cache_release(ch);
        *result = &saved_compiler_id;
        return ErrorNone;
    }
    ZigList<Buf *> lib_paths = {};
    if ((err = os_self_exe_shared_libs(lib_paths)))
        return err;
    for (size_t i = 0; i < lib_paths.length; i += 1) {
        Buf *lib_path = lib_paths.at(i);
        if ((err = cache_add_file(ch, lib_path)))
            return err;
    }
    if ((err = cache_final(ch, &saved_compiler_id)))
        return err;

    cache_release(ch);

    *result = &saved_compiler_id;
    return ErrorNone;
}

static bool test_zig_install_prefix(Buf *test_path, Buf *out_zig_lib_dir) {
    {
        Buf *test_zig_dir = buf_sprintf("%s" OS_SEP "lib" OS_SEP "zig", buf_ptr(test_path));
        Buf *test_index_file = buf_sprintf("%s" OS_SEP "std" OS_SEP "std.zig", buf_ptr(test_zig_dir));
        int err;
        bool exists;
        if ((err = os_file_exists(test_index_file, &exists))) {
            exists = false;
        }
        if (exists) {
            buf_init_from_buf(out_zig_lib_dir, test_zig_dir);
            return true;
        }
    }

    // Also try without "zig"
    {
        Buf *test_zig_dir = buf_sprintf("%s" OS_SEP "lib", buf_ptr(test_path));
        Buf *test_index_file = buf_sprintf("%s" OS_SEP "std" OS_SEP "std.zig", buf_ptr(test_zig_dir));
        int err;
        bool exists;
        if ((err = os_file_exists(test_index_file, &exists))) {
            exists = false;
        }
        if (exists) {
            buf_init_from_buf(out_zig_lib_dir, test_zig_dir);
            return true;
        }
    }

    return false;
}

static int find_zig_lib_dir(Buf *out_path) {
    int err;

    Buf self_exe_path = BUF_INIT;
    buf_resize(&self_exe_path, 0);
    if (!(err = os_self_exe_path(&self_exe_path))) {
        Buf *cur_path = &self_exe_path;

        for (;;) {
            Buf *test_dir = buf_alloc();
            os_path_dirname(cur_path, test_dir);

            if (buf_eql_buf(test_dir, cur_path)) {
                break;
            }

            if (test_zig_install_prefix(test_dir, out_path)) {
                return 0;
            }

            cur_path = test_dir;
        }
    }

    return ErrorFileNotFound;
}

Buf *get_zig_lib_dir(void) {
    static Buf saved_lib_dir = BUF_INIT;
    if (saved_lib_dir.list.length != 0)
        return &saved_lib_dir;
    buf_resize(&saved_lib_dir, 0);

    int err;
    if ((err = find_zig_lib_dir(&saved_lib_dir))) {
        fprintf(stderr, "Unable to find zig lib directory\n");
        exit(EXIT_FAILURE);
    }
    return &saved_lib_dir;
}

Buf *get_zig_std_dir(Buf *zig_lib_dir) {
    static Buf saved_std_dir = BUF_INIT;
    if (saved_std_dir.list.length != 0)
        return &saved_std_dir;
    buf_resize(&saved_std_dir, 0);

    os_path_join(zig_lib_dir, buf_create_from_str("std"), &saved_std_dir);

    return &saved_std_dir;
}

Buf *get_zig_special_dir(Buf *zig_lib_dir) {
    static Buf saved_special_dir = BUF_INIT;
    if (saved_special_dir.list.length != 0)
        return &saved_special_dir;
    buf_resize(&saved_special_dir, 0);

    os_path_join(get_zig_std_dir(zig_lib_dir), buf_sprintf("special"), &saved_special_dir);

    return &saved_special_dir;
}

Buf *get_global_cache_dir(void) {
    static Buf saved_global_cache_dir = BUF_INIT;
    if (saved_global_cache_dir.list.length != 0)
        return &saved_global_cache_dir;
    buf_resize(&saved_global_cache_dir, 0);

    Buf app_data_dir = BUF_INIT;
    Error err;
    if ((err = os_get_app_data_dir(&app_data_dir, "zig"))) {
        fprintf(stderr, "Unable to get application data dir: %s\n", err_str(err));
        exit(1);
    }
    os_path_join(&app_data_dir, buf_create_from_str("stage1"), &saved_global_cache_dir);
    buf_deinit(&app_data_dir);
    return &saved_global_cache_dir;
}
