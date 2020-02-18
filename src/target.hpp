/*
 * Copyright (c) 2016 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#ifndef ZIG_TARGET_HPP
#define ZIG_TARGET_HPP

#include "stage2.h"

struct Buf;

// Synchronize with target.cpp::subarch_list_list
enum SubArchList {
    SubArchListNone,
    SubArchListArm32,
    SubArchListArm64,
    SubArchListKalimba,
    SubArchListMips,
};

enum TargetSubsystem {
    TargetSubsystemConsole,
    TargetSubsystemWindows,
    TargetSubsystemPosix,
    TargetSubsystemNative,
    TargetSubsystemEfiApplication,
    TargetSubsystemEfiBootServiceDriver,
    TargetSubsystemEfiRom,
    TargetSubsystemEfiRuntimeDriver,

    // This means Zig should infer the subsystem.
    // It's last so that the indexes of other items can line up
    // with the enum in builtin.zig.
    TargetSubsystemAuto
};

enum CIntType {
    CIntTypeShort,
    CIntTypeUShort,
    CIntTypeInt,
    CIntTypeUInt,
    CIntTypeLong,
    CIntTypeULong,
    CIntTypeLongLong,
    CIntTypeULongLong,

    CIntTypeCount,
};

Error target_parse_triple(ZigTarget *target, const char *triple);
Error target_parse_archsub(ZigLLVM_ArchType *arch, ZigLLVM_SubArchType *sub,
        const char *archsub_ptr, size_t archsub_len);
Error target_parse_os(Os *os, const char *os_ptr, size_t os_len);
Error target_parse_abi(ZigLLVM_EnvironmentType *abi, const char *abi_ptr, size_t abi_len);

Error target_parse_glibc_version(ZigGLibCVersion *out, const char *text);
void target_init_default_glibc_version(ZigTarget *target);

size_t target_arch_count(void);
ZigLLVM_ArchType target_arch_enum(size_t index);
const char *target_arch_name(ZigLLVM_ArchType arch);

SubArchList target_subarch_list(ZigLLVM_ArchType arch);
size_t target_subarch_count(SubArchList sub_arch_list);
ZigLLVM_SubArchType target_subarch_enum(SubArchList subarch_list, size_t index);
const char *target_subarch_name(ZigLLVM_SubArchType subarch);

size_t target_subarch_list_count(void);
SubArchList target_subarch_list_enum(size_t index);
const char *target_subarch_list_name(SubArchList sub_arch_list);

const char *arch_stack_pointer_register_name(ZigLLVM_ArchType arch);

size_t target_vendor_count(void);
ZigLLVM_VendorType target_vendor_enum(size_t index);

size_t target_os_count(void);
Os target_os_enum(size_t index);
const char *target_os_name(Os os_type);

size_t target_abi_count(void);
ZigLLVM_EnvironmentType target_abi_enum(size_t index);
const char *target_abi_name(ZigLLVM_EnvironmentType abi);
ZigLLVM_EnvironmentType target_default_abi(ZigLLVM_ArchType arch, Os os);


size_t target_oformat_count(void);
ZigLLVM_ObjectFormatType target_oformat_enum(size_t index);
const char *target_oformat_name(ZigLLVM_ObjectFormatType oformat);
ZigLLVM_ObjectFormatType target_object_format(const ZigTarget *target);

void get_native_target(ZigTarget *target);
void target_triple_llvm(Buf *triple, const ZigTarget *target);
void target_triple_zig(Buf *triple, const ZigTarget *target);

void init_all_targets(void);

void resolve_target_object_format(ZigTarget *target);

uint32_t target_c_type_size_in_bits(const ZigTarget *target, CIntType id);

const char *target_o_file_ext(const ZigTarget *target);
const char *target_asm_file_ext(const ZigTarget *target);
const char *target_llvm_ir_file_ext(const ZigTarget *target);
const char *target_exe_file_ext(const ZigTarget *target);
const char *target_lib_file_prefix(const ZigTarget *target);
const char *target_lib_file_ext(const ZigTarget *target, bool is_static,
        size_t version_major, size_t version_minor, size_t version_patch);

bool target_can_exec(const ZigTarget *host_target, const ZigTarget *guest_target);
ZigLLVM_OSType get_llvm_os_type(Os os_type);

bool target_is_arm(const ZigTarget *target);
bool target_is_mips(const ZigTarget *target);
bool target_allows_addr_zero(const ZigTarget *target);
bool target_has_valgrind_support(const ZigTarget *target);
bool target_os_is_darwin(Os os);
bool target_os_requires_libc(Os os);
bool target_can_build_libc(const ZigTarget *target);
const char *target_libc_generic_name(const ZigTarget *target);
bool target_is_libc_lib_name(const ZigTarget *target, const char *name);
bool target_supports_fpic(const ZigTarget *target);
bool target_supports_clang_march_native(const ZigTarget *target);
bool target_requires_pic(const ZigTarget *target, bool linking_libc);
bool target_requires_pie(const ZigTarget *target);
bool target_abi_is_gnu(ZigLLVM_EnvironmentType abi);
bool target_abi_is_musl(ZigLLVM_EnvironmentType abi);
bool target_is_glibc(const ZigTarget *target);
bool target_is_musl(const ZigTarget *target);
bool target_is_wasm(const ZigTarget *target);
bool target_is_riscv(const ZigTarget *target);
bool target_is_android(const ZigTarget *target);
bool target_is_single_threaded(const ZigTarget *target);
bool target_supports_stack_probing(const ZigTarget *target);
bool target_supports_sanitize_c(const ZigTarget *target);
bool target_has_debug_info(const ZigTarget *target);
const char *target_arch_musl_name(ZigLLVM_ArchType arch);
bool target_supports_libunwind(const ZigTarget *target);

uint32_t target_arch_pointer_bit_width(ZigLLVM_ArchType arch);
uint32_t target_arch_largest_atomic_bits(ZigLLVM_ArchType arch);

size_t target_libc_count(void);
void target_libc_enum(size_t index, ZigTarget *out_target);
bool target_libc_needs_crti_crtn(const ZigTarget *target);

unsigned target_fn_align(const ZigTarget *target);

#endif
