/*
 * Copyright (c) 2018 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#ifndef ZIG_COMPILER_HPP
#define ZIG_COMPILER_HPP

#include "all_types.hpp"

Error get_compiler_id(Buf **result);

Buf *get_zig_lib_dir(void);
Buf *get_zig_special_dir(Buf *zig_lib_dir);
Buf *get_zig_std_dir(Buf *zig_lib_dir);

Buf *get_global_cache_dir(void);


FileExt classify_file_ext(const char *filename_ptr, size_t filename_len);

#endif
