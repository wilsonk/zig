/*
 * Copyright (c) 2015 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */


#ifndef ZIG_PARSEC_HPP
#define ZIG_PARSEC_HPP

#include "all_types.hpp"

enum TranslateMode {
    TranslateModeImport,
    TranslateModeTranslate,
};

Error parse_h_file(CodeGen *codegen, AstNode **out_root_node,
        Stage2ErrorMsg **errors_ptr, size_t *errors_len,
        const char **args_begin, const char **args_end,
        TranslateMode mode, const char *resources_path);

#endif
