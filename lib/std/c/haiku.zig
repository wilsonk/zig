// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

//
const std = @import("../std.zig");
const builtin = std.builtin;

usingnamespace std.c;

extern "c" fn _errnop() *c_int;

pub const _errno = _errnop;

pub extern "c" fn find_directory(which: c_int, volume: i32, createIt: bool, path_ptr: [*]u8, length: i32) u64;

pub extern "c" fn find_thread(thread_name: ?*c_void) i32;

pub extern "c" fn get_system_info(system_info: *system_info) usize;

// TODO revisit if abi changes or better option becomes apparent
pub extern "c" fn _get_next_image_info(team: c_int, cookie: *i32, image_info: *image_info) usize;

pub extern "c" fn _kern_read_dir(fd: c_int, buf_ptr: [*]u8, nbytes: usize, maxcount: u32) usize;

pub extern "c" fn _kern_read_stat(fd: c_int, path_ptr: [*]u8, traverse_link: bool, libc_stat: *libc_stat, stat_size: i32) usize;

pub extern "c" fn _kern_get_current_team() i32;

pub const sem_t = extern struct {
    _magic: u32,
    _kern: extern struct {
        _count: u32,
        _flags: u32,
    },
    _padding: u32,
};

pub const pthread_attr_t = extern struct {
    __detach_state: i32,
    __sched_priority: i32,
    __stack_size: i32,
    __guard_size: i32,
    __stack_address: ?*c_void,
};

pub const pthread_mutex_t = extern struct {
    flags: u32 = 0,
    lock: i32 = 0,
    unused: i32 = -42,
    owner: i32 = -1,
    owner_count: i32 = 0,
};
pub const pthread_cond_t = extern struct {
    flags: u32 = 0,
    unused: i32 = -42,
    mutex: ?*c_void = null,
    waiter_count: i32 = 0,
    lock: i32 = 0,
};
pub const pthread_rwlock_t = extern struct {
    flags: u32 = 0,
    owner: i32 = -1,
    lock_sem: i32 = 0,
    lock_count: i32 = 0,
    reader_count: i32 = 0,
    writer_count: i32 = 0,
    waiters: [2]?*c_void = [_]?*c_void{ null, null },
};
