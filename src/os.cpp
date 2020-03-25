/*
 * Copyright (c) 2015 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#include "os.hpp"
#include "util.hpp"
#include "error.hpp"

#if defined(_WIN32)

#if !defined(NOMINMAX)
#define NOMINMAX
#endif

#if !defined(VC_EXTRALEAN)
#define VC_EXTRALEAN
#endif

#if !defined(WIN32_LEAN_AND_MEAN)
#define WIN32_LEAN_AND_MEAN
#endif

#if !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x600
#endif

#if !defined(NTDDI_VERSION)
#define NTDDI_VERSION 0x06000000
#endif

#include <windows.h>
#include <shlobj.h>
#include <io.h>
#include <fcntl.h>
#include <ntsecapi.h>

typedef SSIZE_T ssize_t;
#else
#define ZIG_OS_POSIX

#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>

#endif

#if defined(ZIG_OS_LINUX) || defined(ZIG_OS_FREEBSD) || defined(ZIG_OS_NETBSD) || defined(ZIG_OS_DRAGONFLY)
#include <link.h>
#endif

#if defined(ZIG_OS_LINUX)
#include <sys/auxv.h>
#endif

#if defined(ZIG_OS_FREEBSD) || defined(ZIG_OS_NETBSD) || defined(ZIG_OS_DRAGONFLY)
#include <sys/sysctl.h>
#endif

#if defined(__MACH__)
#include <mach/clock.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#endif

#if defined(ZIG_OS_WINDOWS)
static uint64_t windows_perf_freq;
#elif defined(__MACH__)
static clock_serv_t macos_calendar_clock;
static clock_serv_t macos_monotonic_clock;
#endif

#include <stdlib.h>
#include <errno.h>
#include <time.h>

#if !defined(environ)
extern char **environ;
#endif

#if defined(ZIG_OS_POSIX)
static void populate_termination(Termination *term, int status) {
    if (WIFEXITED(status)) {
        term->how = TerminationIdClean;
        term->code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        term->how = TerminationIdSignaled;
        term->code = WTERMSIG(status);
    } else if (WIFSTOPPED(status)) {
        term->how = TerminationIdStopped;
        term->code = WSTOPSIG(status);
    } else {
        term->how = TerminationIdUnknown;
        term->code = status;
    }
}

static void os_spawn_process_posix(ZigList<const char *> &args, Termination *term) {
    const char **argv = heap::c_allocator.allocate<const char *>(args.length + 1);
    for (size_t i = 0; i < args.length; i += 1) {
        argv[i] = args.at(i);
    }
    argv[args.length] = nullptr;

    pid_t pid;
    int rc = posix_spawnp(&pid, args.at(0), nullptr, nullptr, const_cast<char *const*>(argv), environ);
    if (rc != 0) {
        zig_panic("unable to spawn %s: %s", args.at(0), strerror(rc));
    }

    int status;
    waitpid(pid, &status, 0);
    populate_termination(term, status);
}
#endif

#if defined(ZIG_OS_WINDOWS)

static void os_windows_create_command_line(Buf *command_line, ZigList<const char *> &args) {
    buf_resize(command_line, 0);
    const char *prefix = "\"";
    for (size_t arg_i = 0; arg_i < args.length; arg_i += 1) {
        const char *arg = args.at(arg_i);
        buf_append_str(command_line, prefix);
        prefix = " \"";
        size_t arg_len = strlen(arg);
        for (size_t c_i = 0; c_i < arg_len; c_i += 1) {
            if (arg[c_i] == '\"') {
                zig_panic("TODO");
            }
            buf_append_char(command_line, arg[c_i]);
        }
        buf_append_char(command_line, '\"');
    }
}

static void os_spawn_process_windows(ZigList<const char *> &args, Termination *term) {
    Buf command_line = BUF_INIT;
    os_windows_create_command_line(&command_line, args);

    PROCESS_INFORMATION piProcInfo = {0};
    STARTUPINFO siStartInfo = {0};
    siStartInfo.cb = sizeof(STARTUPINFO);

    const char *exe = args.at(0);
    BOOL success = CreateProcessA(exe, buf_ptr(&command_line), nullptr, nullptr, TRUE, 0, nullptr, nullptr,
            &siStartInfo, &piProcInfo);

    if (!success) {
        zig_panic("CreateProcess failed. exe: %s command_line: %s", exe, buf_ptr(&command_line));
    }

    WaitForSingleObject(piProcInfo.hProcess, INFINITE);

    DWORD exit_code;
    if (!GetExitCodeProcess(piProcInfo.hProcess, &exit_code)) {
        zig_panic("GetExitCodeProcess failed");
    }
    term->how = TerminationIdClean;
    term->code = exit_code;
}
#endif

void os_spawn_process(ZigList<const char *> &args, Termination *term) {
#if defined(ZIG_OS_WINDOWS)
    os_spawn_process_windows(args, term);
#elif defined(ZIG_OS_POSIX)
    os_spawn_process_posix(args, term);
#else
#error "missing os_spawn_process implementation"
#endif
}

void os_path_dirname(Buf *full_path, Buf *out_dirname) {
    return os_path_split(full_path, out_dirname, nullptr);
}

bool os_is_sep(uint8_t c) {
#if defined(ZIG_OS_WINDOWS)
    return c == '\\' || c == '/';
#else
    return c == '/';
#endif
}

void os_path_split(Buf *full_path, Buf *out_dirname, Buf *out_basename) {
    size_t len = buf_len(full_path);
    if (len != 0) {
        size_t last_index = len - 1;
        char last_char = buf_ptr(full_path)[last_index];
        if (os_is_sep(last_char)) {
            if (last_index == 0) {
                if (out_dirname) buf_init_from_mem(out_dirname, &last_char, 1);
                if (out_basename) buf_init_from_str(out_basename, "");
                return;
            }
            last_index -= 1;
        }
        for (size_t i = last_index;;) {
            uint8_t c = buf_ptr(full_path)[i];
            if (os_is_sep(c)) {
                if (out_dirname) {
                    buf_init_from_mem(out_dirname, buf_ptr(full_path), (i == 0) ? 1 : i);
                }
                if (out_basename) {
                    buf_init_from_mem(out_basename, buf_ptr(full_path) + i + 1, buf_len(full_path) - (i + 1));
                }
                return;
            }
            if (i == 0) break;
            i -= 1;
        }
    }
    if (out_dirname) buf_init_from_mem(out_dirname, ".", 1);
    if (out_basename) buf_init_from_buf(out_basename, full_path);
}

void os_path_extname(Buf *full_path, Buf *out_basename, Buf *out_extname) {
    if (buf_len(full_path) == 0) {
        if (out_basename) buf_init_from_str(out_basename, "");
        if (out_extname) buf_init_from_str(out_extname, "");
        return;
    }
    size_t i = buf_len(full_path) - 1;
    while (true) {
        if (buf_ptr(full_path)[i] == '.') {
            if (out_basename) {
                buf_resize(out_basename, 0);
                buf_append_mem(out_basename, buf_ptr(full_path), i);
            }

            if (out_extname) {
                buf_resize(out_extname, 0);
                buf_append_mem(out_extname, buf_ptr(full_path) + i, buf_len(full_path) - i);
            }
            return;
        }

        if (i == 0) {
            if (out_basename) buf_init_from_buf(out_basename, full_path);
            if (out_extname) buf_init_from_str(out_extname, "");
            return;
        }
        i -= 1;
    }
}

void os_path_join(Buf *dirname, Buf *basename, Buf *out_full_path) {
    if (buf_len(dirname) == 0) {
        buf_init_from_buf(out_full_path, basename);
        return;
    }

    buf_init_from_buf(out_full_path, dirname);
    uint8_t c = *(buf_ptr(out_full_path) + buf_len(out_full_path) - 1);
    if (!os_is_sep(c))
        buf_append_char(out_full_path, ZIG_OS_SEP_CHAR);
    buf_append_buf(out_full_path, basename);
}

Error os_path_real(Buf *rel_path, Buf *out_abs_path) {
#if defined(ZIG_OS_WINDOWS)
    buf_resize(out_abs_path, 4096);
    if (_fullpath(buf_ptr(out_abs_path), buf_ptr(rel_path), buf_len(out_abs_path)) == nullptr) {
        zig_panic("_fullpath failed");
    }
    buf_resize(out_abs_path, strlen(buf_ptr(out_abs_path)));
    return ErrorNone;
#elif defined(ZIG_OS_POSIX)
    buf_resize(out_abs_path, PATH_MAX + 1);
    char *result = realpath(buf_ptr(rel_path), buf_ptr(out_abs_path));
    if (!result) {
        int err = errno;
        if (err == EACCES) {
            return ErrorAccess;
        } else if (err == ENOENT) {
            return ErrorFileNotFound;
        } else if (err == ENOMEM) {
            return ErrorNoMem;
        } else {
            return ErrorFileSystem;
        }
    }
    buf_resize(out_abs_path, strlen(buf_ptr(out_abs_path)));
    return ErrorNone;
#else
#error "missing os_path_real implementation"
#endif
}

#if defined(ZIG_OS_WINDOWS)
// Ported from std/os/path.zig
static bool isAbsoluteWindows(Slice<uint8_t> path) {
    if (path.ptr[0] == '/')
        return true;

    if (path.ptr[0] == '\\') {
        return true;
    }
    if (path.len < 3) {
        return false;
    }
    if (path.ptr[1] == ':') {
        if (path.ptr[2] == '/')
            return true;
        if (path.ptr[2] == '\\')
            return true;
    }
    return false;
}
#endif

bool os_path_is_absolute(Buf *path) {
#if defined(ZIG_OS_WINDOWS)
    return isAbsoluteWindows(buf_to_slice(path));
#elif defined(ZIG_OS_POSIX)
    return buf_ptr(path)[0] == '/';
#else
#error "missing os_path_is_absolute implementation"
#endif
}

#if defined(ZIG_OS_WINDOWS)

enum WindowsPathKind {
    WindowsPathKindNone,
    WindowsPathKindDrive,
    WindowsPathKindNetworkShare,
};

struct WindowsPath {
    Slice<uint8_t> disk_designator;
    WindowsPathKind kind;
    bool is_abs;
};


// Ported from std/os/path.zig
static WindowsPath windowsParsePath(Slice<uint8_t> path) {
    if (path.len >= 2 && path.ptr[1] == ':') {
        return WindowsPath{
            path.slice(0, 2),
            WindowsPathKindDrive,
            isAbsoluteWindows(path),
        };
    }
    if (path.len >= 1 && (path.ptr[0] == '/' || path.ptr[0] == '\\') &&
        (path.len == 1 || (path.ptr[1] != '/' && path.ptr[1] != '\\')))
    {
        return WindowsPath{
            path.slice(0, 0),
            WindowsPathKindNone,
            true,
        };
    }
    WindowsPath relative_path = {
        str(""),
        WindowsPathKindNone,
        false,
    };
    if (path.len < strlen("//a/b")) {
        return relative_path;
    }

    {
        if (memStartsWith(path, str("//"))) {
            if (path.ptr[2] == '/') {
                return relative_path;
            }

            SplitIterator it = memSplit(path, str("/"));
            {
                Optional<Slice<uint8_t>> opt_component = SplitIterator_next(&it);
                if (!opt_component.is_some) return relative_path;
            }
            {
                Optional<Slice<uint8_t>> opt_component = SplitIterator_next(&it);
                if (!opt_component.is_some) return relative_path;
            }
            return WindowsPath{
                path.slice(0, it.index),
                WindowsPathKindNetworkShare,
                isAbsoluteWindows(path),
            };
        }
    }
    {
        if (memStartsWith(path, str("\\\\"))) {
            if (path.ptr[2] == '\\') {
                return relative_path;
            }

            SplitIterator it = memSplit(path, str("\\"));
            {
                Optional<Slice<uint8_t>> opt_component = SplitIterator_next(&it);
                if (!opt_component.is_some) return relative_path;
            }
            {
                Optional<Slice<uint8_t>> opt_component = SplitIterator_next(&it);
                if (!opt_component.is_some) return relative_path;
            }
            return WindowsPath{
                path.slice(0, it.index),
                WindowsPathKindNetworkShare,
                isAbsoluteWindows(path),
            };
        }
    }
    return relative_path;
}

// Ported from std/os/path.zig
static uint8_t asciiUpper(uint8_t byte) {
    if (byte >= 'a' && byte <= 'z') {
        return 'A' + (byte - 'a');
    }
    return byte;
}

// Ported from std/os/path.zig
static bool asciiEqlIgnoreCase(Slice<uint8_t> s1, Slice<uint8_t> s2) {
    if (s1.len != s2.len)
        return false;
    for (size_t i = 0; i < s1.len; i += 1) {
        if (asciiUpper(s1.ptr[i]) != asciiUpper(s2.ptr[i]))
            return false;
    }
    return true;
}

// Ported from std/os/path.zig
static bool compareDiskDesignators(WindowsPathKind kind, Slice<uint8_t> p1, Slice<uint8_t> p2) {
    switch (kind) {
        case WindowsPathKindNone:
            assert(p1.len == 0);
            assert(p2.len == 0);
            return true;
        case WindowsPathKindDrive:
            return asciiUpper(p1.ptr[0]) == asciiUpper(p2.ptr[0]);
        case WindowsPathKindNetworkShare:
            uint8_t sep1 = p1.ptr[0];
            uint8_t sep2 = p2.ptr[0];

            SplitIterator it1 = memSplit(p1, {&sep1, 1});
            SplitIterator it2 = memSplit(p2, {&sep2, 1});

            // TODO ASCII is wrong, we actually need full unicode support to compare paths.
            return asciiEqlIgnoreCase(SplitIterator_next(&it1).value, SplitIterator_next(&it2).value) &&
                asciiEqlIgnoreCase(SplitIterator_next(&it1).value, SplitIterator_next(&it2).value);
    }
    zig_unreachable();
}

// Ported from std/os/path.zig
static Buf os_path_resolve_windows(Buf **paths_ptr, size_t paths_len) {
    if (paths_len == 0) {
        Buf cwd = BUF_INIT;
        int err;
        if ((err = os_get_cwd(&cwd))) {
            zig_panic("get cwd failed");
        }
        return cwd;
    }

    // determine which disk designator we will result with, if any
    char result_drive_buf[3] = {'_', ':', '\0'}; // 0 needed for strlen later
    Slice<uint8_t> result_disk_designator = str("");
    WindowsPathKind have_drive_kind = WindowsPathKindNone;
    bool have_abs_path = false;
    size_t first_index = 0;
    size_t max_size = 0;
    for (size_t i = 0; i < paths_len; i += 1) {
        Slice<uint8_t> p = buf_to_slice(paths_ptr[i]);
        WindowsPath parsed = windowsParsePath(p);
        if (parsed.is_abs) {
            have_abs_path = true;
            first_index = i;
            max_size = result_disk_designator.len;
        }
        switch (parsed.kind) {
            case WindowsPathKindDrive:
                result_drive_buf[0] = asciiUpper(parsed.disk_designator.ptr[0]);
                result_disk_designator = str(result_drive_buf);
                have_drive_kind = WindowsPathKindDrive;
                break;
            case WindowsPathKindNetworkShare:
                result_disk_designator = parsed.disk_designator;
                have_drive_kind = WindowsPathKindNetworkShare;
                break;
            case WindowsPathKindNone:
                break;
        }
        max_size += p.len + 1;
    }

    // if we will result with a disk designator, loop again to determine
    // which is the last time the disk designator is absolutely specified, if any
    // and count up the max bytes for paths related to this disk designator
    if (have_drive_kind != WindowsPathKindNone) {
        have_abs_path = false;
        first_index = 0;
        max_size = result_disk_designator.len;
        bool correct_disk_designator = false;

        for (size_t i = 0; i < paths_len; i += 1) {
            Slice<uint8_t> p = buf_to_slice(paths_ptr[i]);
            WindowsPath parsed = windowsParsePath(p);
            if (parsed.kind != WindowsPathKindNone) {
                if (parsed.kind == have_drive_kind) {
                    correct_disk_designator = compareDiskDesignators(have_drive_kind, result_disk_designator, parsed.disk_designator);
                } else {
                    continue;
                }
            }
            if (!correct_disk_designator) {
                continue;
            }
            if (parsed.is_abs) {
                first_index = i;
                max_size = result_disk_designator.len;
                have_abs_path = true;
            }
            max_size += p.len + 1;
        }
    }

    // Allocate result and fill in the disk designator, calling getCwd if we have to.
    Slice<uint8_t> result;
    size_t result_index = 0;

    if (have_abs_path) {
        switch (have_drive_kind) {
            case WindowsPathKindDrive: {
                result = Slice<uint8_t>::alloc(max_size);

                memCopy(result, result_disk_designator);
                result_index += result_disk_designator.len;
                break;
            }
            case WindowsPathKindNetworkShare: {
                result = Slice<uint8_t>::alloc(max_size);
                SplitIterator it = memSplit(buf_to_slice(paths_ptr[first_index]), str("/\\"));
                Slice<uint8_t> server_name = SplitIterator_next(&it).value;
                Slice<uint8_t> other_name = SplitIterator_next(&it).value;

                result.ptr[result_index] = '\\';
                result_index += 1;
                result.ptr[result_index] = '\\';
                result_index += 1;
                memCopy(result.sliceFrom(result_index), server_name);
                result_index += server_name.len;
                result.ptr[result_index] = '\\';
                result_index += 1;
                memCopy(result.sliceFrom(result_index), other_name);
                result_index += other_name.len;

                result_disk_designator = result.slice(0, result_index);
                break;
            }
            case WindowsPathKindNone: {
                Buf cwd = BUF_INIT;
                int err;
                if ((err = os_get_cwd(&cwd))) {
                    zig_panic("get cwd failed");
                }
                WindowsPath parsed_cwd = windowsParsePath(buf_to_slice(&cwd));
                result = Slice<uint8_t>::alloc(max_size + parsed_cwd.disk_designator.len + 1);
                memCopy(result, parsed_cwd.disk_designator);
                result_index += parsed_cwd.disk_designator.len;
                result_disk_designator = result.slice(0, parsed_cwd.disk_designator.len);
                if (parsed_cwd.kind == WindowsPathKindDrive) {
                    result.ptr[0] = asciiUpper(result.ptr[0]);
                }
                have_drive_kind = parsed_cwd.kind;
                break;
            }
        }
    } else {
        // TODO call get cwd for the result_disk_designator instead of the global one
        Buf cwd = BUF_INIT;
        int err;
        if ((err = os_get_cwd(&cwd))) {
            zig_panic("get cwd failed");
        }
        result = Slice<uint8_t>::alloc(max_size + buf_len(&cwd) + 1);

        memCopy(result, buf_to_slice(&cwd));
        result_index += buf_len(&cwd);
        WindowsPath parsed_cwd = windowsParsePath(result.slice(0, result_index));
        result_disk_designator = parsed_cwd.disk_designator;
        if (parsed_cwd.kind == WindowsPathKindDrive) {
            result.ptr[0] = asciiUpper(result.ptr[0]);
        }
        have_drive_kind = parsed_cwd.kind;
    }

    // Now we know the disk designator to use, if any, and what kind it is. And our result
    // is big enough to append all the paths to.
    bool correct_disk_designator = true;
    for (size_t i = 0; i < paths_len; i += 1) {
        Slice<uint8_t> p = buf_to_slice(paths_ptr[i]);
        WindowsPath parsed = windowsParsePath(p);

        if (parsed.kind != WindowsPathKindNone) {
            if (parsed.kind == have_drive_kind) {
                correct_disk_designator = compareDiskDesignators(have_drive_kind, result_disk_designator, parsed.disk_designator);
            } else {
                continue;
            }
        }
        if (!correct_disk_designator) {
            continue;
        }
        SplitIterator it = memSplit(p.sliceFrom(parsed.disk_designator.len), str("/\\"));
        while (true) {
            Optional<Slice<uint8_t>> opt_component = SplitIterator_next(&it);
            if (!opt_component.is_some) break;
            Slice<uint8_t> component = opt_component.value;
            if (memEql(component, str("."))) {
                continue;
            } else if (memEql(component, str(".."))) {
                while (true) {
                    if (result_index == 0 || result_index == result_disk_designator.len)
                        break;
                    result_index -= 1;
                    if (result.ptr[result_index] == '\\' || result.ptr[result_index] == '/')
                        break;
                }
            } else {
                result.ptr[result_index] = '\\';
                result_index += 1;
                memCopy(result.sliceFrom(result_index), component);
                result_index += component.len;
            }
        }
    }

    if (result_index == result_disk_designator.len) {
        result.ptr[result_index] = '\\';
        result_index += 1;
    }

    Buf return_value = BUF_INIT;
    buf_init_from_mem(&return_value, (char *)result.ptr, result_index);
    return return_value;
}
#endif

#if defined(ZIG_OS_POSIX)
// Ported from std/os/path.zig
static Buf os_path_resolve_posix(Buf **paths_ptr, size_t paths_len) {
    if (paths_len == 0) {
        Buf cwd = BUF_INIT;
        int err;
        if ((err = os_get_cwd(&cwd))) {
            zig_panic("get cwd failed");
        }
        return cwd;
    }

    size_t first_index = 0;
    bool have_abs = false;
    size_t max_size = 0;
    for (size_t i = 0; i < paths_len; i += 1) {
        Buf *p = paths_ptr[i];
        if (os_path_is_absolute(p)) {
            first_index = i;
            have_abs = true;
            max_size = 0;
        }
        max_size += buf_len(p) + 1;
    }

    uint8_t *result_ptr;
    size_t result_len;
    size_t result_index = 0;

    if (have_abs) {
        result_len = max_size;
        result_ptr = heap::c_allocator.allocate_nonzero<uint8_t>(result_len);
    } else {
        Buf cwd = BUF_INIT;
        int err;
        if ((err = os_get_cwd(&cwd))) {
            zig_panic("get cwd failed");
        }
        result_len = max_size + buf_len(&cwd) + 1;
        result_ptr = heap::c_allocator.allocate_nonzero<uint8_t>(result_len);
        memcpy(result_ptr, buf_ptr(&cwd), buf_len(&cwd));
        result_index += buf_len(&cwd);
    }

    for (size_t i = first_index; i < paths_len; i += 1) {
        Buf *p = paths_ptr[i];
        SplitIterator it = memSplit(buf_to_slice(p), str("/"));
        while (true) {
            Optional<Slice<uint8_t>> opt_component = SplitIterator_next(&it);
            if (!opt_component.is_some) break;
            Slice<uint8_t> component = opt_component.value;

            if (memEql<uint8_t>(component, str("."))) {
                continue;
            } else if (memEql<uint8_t>(component, str(".."))) {
                while (true) {
                    if (result_index == 0)
                        break;
                    result_index -= 1;
                    if (result_ptr[result_index] == '/')
                        break;
                }
            } else {
                result_ptr[result_index] = '/';
                result_index += 1;
                memcpy(result_ptr + result_index, component.ptr, component.len);
                result_index += component.len;
            }
        }
    }

    if (result_index == 0) {
        result_ptr[0] = '/';
        result_index += 1;
    }

    Buf return_value = BUF_INIT;
    buf_init_from_mem(&return_value, (char *)result_ptr, result_index);
    return return_value;
}
#endif

// Ported from std/os/path.zig
Buf os_path_resolve(Buf **paths_ptr, size_t paths_len) {
#if defined(ZIG_OS_WINDOWS)
    return os_path_resolve_windows(paths_ptr, paths_len);
#elif defined(ZIG_OS_POSIX)
    return os_path_resolve_posix(paths_ptr, paths_len);
#else
#error "missing os_path_resolve implementation"
#endif
}

Error os_fetch_file(FILE *f, Buf *out_buf) {
    static const ssize_t buf_size = 0x2000;
    buf_resize(out_buf, buf_size);
    ssize_t actual_buf_len = 0;

    for (;;) {
        size_t amt_read = fread(buf_ptr(out_buf) + actual_buf_len, 1, buf_size, f);
        actual_buf_len += amt_read;

        if (amt_read != buf_size) {
            if (feof(f)) {
                buf_resize(out_buf, actual_buf_len);
                return ErrorNone;
            } else {
                return ErrorFileSystem;
            }
        }

        buf_resize(out_buf, actual_buf_len + buf_size);
    }
    zig_unreachable();
}

Error os_file_exists(Buf *full_path, bool *result) {
#if defined(ZIG_OS_WINDOWS)
    *result = GetFileAttributes(buf_ptr(full_path)) != INVALID_FILE_ATTRIBUTES;
    return ErrorNone;
#else
    *result = access(buf_ptr(full_path), F_OK) != -1;
    return ErrorNone;
#endif
}

#if defined(ZIG_OS_POSIX)
static Error os_exec_process_posix(ZigList<const char *> &args,
        Termination *term, Buf *out_stderr, Buf *out_stdout)
{
    int stdin_pipe[2];
    int stdout_pipe[2];
    int stderr_pipe[2];
    int err_pipe[2];

    int err;
    if ((err = pipe(stdin_pipe)))
        zig_panic("pipe failed");
    if ((err = pipe(stdout_pipe)))
        zig_panic("pipe failed");
    if ((err = pipe(stderr_pipe)))
        zig_panic("pipe failed");
    if ((err = pipe(err_pipe)))
        zig_panic("pipe failed");

    pid_t pid = fork();
    if (pid == -1)
        zig_panic("fork failed: %s", strerror(errno));
    if (pid == 0) {
        // child
        if (dup2(stdin_pipe[0], STDIN_FILENO) == -1)
            zig_panic("dup2 failed");

        if (dup2(stdout_pipe[1], STDOUT_FILENO) == -1)
            zig_panic("dup2 failed");

        if (dup2(stderr_pipe[1], STDERR_FILENO) == -1)
            zig_panic("dup2 failed");

        const char **argv = heap::c_allocator.allocate<const char *>(args.length + 1);
        argv[args.length] = nullptr;
        for (size_t i = 0; i < args.length; i += 1) {
            argv[i] = args.at(i);
        }
        execvp(argv[0], const_cast<char * const *>(argv));
        Error report_err = ErrorUnexpected;
        if (errno == ENOENT) {
            report_err = ErrorFileNotFound;
        }
        if (write(err_pipe[1], &report_err, sizeof(Error)) == -1) {
            zig_panic("write failed");
        }
        exit(1);
    } else {
        // parent
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        int status;
        waitpid(pid, &status, 0);
        populate_termination(term, status);

        FILE *stdout_f = fdopen(stdout_pipe[0], "rb");
        FILE *stderr_f = fdopen(stderr_pipe[0], "rb");
        Error err1 = os_fetch_file(stdout_f, out_stdout);
        Error err2 = os_fetch_file(stderr_f, out_stderr);

        fclose(stdout_f);
        fclose(stderr_f);

        if (err1) return err1;
        if (err2) return err2;

        Error child_err = ErrorNone;
        if (write(err_pipe[1], &child_err, sizeof(Error)) == -1) {
            zig_panic("write failed");
        }
        close(err_pipe[1]);
        if (read(err_pipe[0], &child_err, sizeof(Error)) == -1) {
            zig_panic("write failed");
        }
        close(err_pipe[0]);
        return child_err;
    }
}
#endif

#if defined(ZIG_OS_WINDOWS)

//static void win32_panic(const char *str) {
//    DWORD err = GetLastError();
//    LPSTR messageBuffer = nullptr;
//    FormatMessageA(
//        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
//        NULL, err, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&messageBuffer, 0, NULL);
//    zig_panic(str, messageBuffer);
//    LocalFree(messageBuffer);
//}

static Error os_exec_process_windows(ZigList<const char *> &args,
        Termination *term, Buf *out_stderr, Buf *out_stdout)
{
    Buf command_line = BUF_INIT;
    os_windows_create_command_line(&command_line, args);

    HANDLE g_hChildStd_IN_Rd = NULL;
    HANDLE g_hChildStd_IN_Wr = NULL;
    HANDLE g_hChildStd_OUT_Rd = NULL;
    HANDLE g_hChildStd_OUT_Wr = NULL;
    HANDLE g_hChildStd_ERR_Rd = NULL;
    HANDLE g_hChildStd_ERR_Wr = NULL;

    SECURITY_ATTRIBUTES saAttr;
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES);
    saAttr.bInheritHandle = TRUE;
    saAttr.lpSecurityDescriptor = NULL;

    if (!CreatePipe(&g_hChildStd_OUT_Rd, &g_hChildStd_OUT_Wr, &saAttr, 0)) {
        zig_panic("StdoutRd CreatePipe");
    }

    if (!SetHandleInformation(g_hChildStd_OUT_Rd, HANDLE_FLAG_INHERIT, 0)) {
        zig_panic("Stdout SetHandleInformation");
    }

    if (!CreatePipe(&g_hChildStd_ERR_Rd, &g_hChildStd_ERR_Wr, &saAttr, 0)) {
        zig_panic("stderr CreatePipe");
    }

    if (!SetHandleInformation(g_hChildStd_ERR_Rd, HANDLE_FLAG_INHERIT, 0)) {
        zig_panic("stderr SetHandleInformation");
    }

    if (!CreatePipe(&g_hChildStd_IN_Rd, &g_hChildStd_IN_Wr, &saAttr, 0)) {
        zig_panic("Stdin CreatePipe");
    }

    if (!SetHandleInformation(g_hChildStd_IN_Wr, HANDLE_FLAG_INHERIT, 0)) {
        zig_panic("Stdin SetHandleInformation");
    }


    PROCESS_INFORMATION piProcInfo = {0};
    STARTUPINFO siStartInfo = {0};
    siStartInfo.cb = sizeof(STARTUPINFO);
    siStartInfo.hStdError = g_hChildStd_ERR_Wr;
    siStartInfo.hStdOutput = g_hChildStd_OUT_Wr;
    siStartInfo.hStdInput = g_hChildStd_IN_Rd;
    siStartInfo.dwFlags |= STARTF_USESTDHANDLES;

    const char *exe = args.at(0);
    BOOL success = CreateProcess(exe, buf_ptr(&command_line), nullptr, nullptr, TRUE, 0, nullptr, nullptr,
            &siStartInfo, &piProcInfo);

    if (!success) {
        if (GetLastError() == ERROR_FILE_NOT_FOUND) {
            CloseHandle(piProcInfo.hProcess);
            CloseHandle(piProcInfo.hThread);
            return ErrorFileNotFound;
        }
        zig_panic("CreateProcess failed. exe: %s command_line: %s", exe, buf_ptr(&command_line));
    }

    if (!CloseHandle(g_hChildStd_IN_Wr)) {
        zig_panic("stdinwr closehandle");
    }

    CloseHandle(g_hChildStd_IN_Rd);
    CloseHandle(g_hChildStd_ERR_Wr);
    CloseHandle(g_hChildStd_OUT_Wr);

    static const size_t BUF_SIZE = 4 * 1024;
    {
        DWORD dwRead;
        char chBuf[BUF_SIZE];

        buf_resize(out_stdout, 0);
        for (;;) {
            success = ReadFile( g_hChildStd_OUT_Rd, chBuf, BUF_SIZE, &dwRead, NULL);
            if (!success || dwRead == 0) break;

            buf_append_mem(out_stdout, chBuf, dwRead);
        }
        CloseHandle(g_hChildStd_OUT_Rd);
    }
    {
        DWORD dwRead;
        char chBuf[BUF_SIZE];

        buf_resize(out_stderr, 0);
        for (;;) {
            success = ReadFile( g_hChildStd_ERR_Rd, chBuf, BUF_SIZE, &dwRead, NULL);
            if (!success || dwRead == 0) break;

            buf_append_mem(out_stderr, chBuf, dwRead);
        }
        CloseHandle(g_hChildStd_ERR_Rd);
    }

    WaitForSingleObject(piProcInfo.hProcess, INFINITE);

    DWORD exit_code;
    if (!GetExitCodeProcess(piProcInfo.hProcess, &exit_code)) {
        zig_panic("GetExitCodeProcess failed");
    }
    term->how = TerminationIdClean;
    term->code = exit_code;

    CloseHandle(piProcInfo.hProcess);
    CloseHandle(piProcInfo.hThread);

    return ErrorNone;
}
#endif

Error os_execv(const char *exe, const char **argv) {
#if defined(ZIG_OS_WINDOWS)
    return ErrorUnsupportedOperatingSystem;
#else
    execv(exe, (char *const *)argv);
    switch (errno) {
        case ENOMEM:
            return ErrorSystemResources;
        case EIO:
            return ErrorFileSystem;
        default:
            return ErrorUnexpected;
    }
#endif
}

Error os_exec_process(ZigList<const char *> &args,
        Termination *term, Buf *out_stderr, Buf *out_stdout)
{
#if defined(ZIG_OS_WINDOWS)
    return os_exec_process_windows(args, term, out_stderr, out_stdout);
#elif defined(ZIG_OS_POSIX)
    return os_exec_process_posix(args, term, out_stderr, out_stdout);
#else
#error "missing os_exec_process implementation"
#endif
}

Error os_write_file(Buf *full_path, Buf *contents) {
    FILE *f = fopen(buf_ptr(full_path), "wb");
    if (!f) {
        zig_panic("os_write_file failed for %s", buf_ptr(full_path));
    }
    size_t amt_written = fwrite(buf_ptr(contents), 1, buf_len(contents), f);
    if (amt_written != (size_t)buf_len(contents))
        zig_panic("write failed: %s", strerror(errno));
    if (fclose(f))
        zig_panic("close failed");
    return ErrorNone;
}

static Error copy_open_files(FILE *src_f, FILE *dest_f) {
    static const size_t buf_size = 2048;
    char buf[buf_size];
    for (;;) {
        size_t amt_read = fread(buf, 1, buf_size, src_f);
        if (amt_read != buf_size) {
            if (ferror(src_f)) {
                return ErrorFileSystem;
            }
        }
        size_t amt_written = fwrite(buf, 1, amt_read, dest_f);
        if (amt_written != amt_read) {
            return ErrorFileSystem;
        }
        if (feof(src_f)) {
            return ErrorNone;
        }
    }
}

Error os_dump_file(Buf *src_path, FILE *dest_file) {
    Error err;

    FILE *src_f = fopen(buf_ptr(src_path), "rb");
    if (!src_f) {
        int err = errno;
        if (err == ENOENT) {
            return ErrorFileNotFound;
        } else if (err == EACCES || err == EPERM) {
            return ErrorAccess;
        } else {
            return ErrorFileSystem;
        }
    }
    copy_open_files(src_f, dest_file);
    if ((err = copy_open_files(src_f, dest_file))) {
        fclose(src_f);
        return err;
    }

    fclose(src_f);
    return ErrorNone;
}

#if defined(ZIG_OS_WINDOWS)
static void windows_filetime_to_os_timestamp(FILETIME *ft, OsTimeStamp *mtime) {
    mtime->sec = (((ULONGLONG) ft->dwHighDateTime) << 32) + ft->dwLowDateTime;
    mtime->nsec = 0;
}
static FILETIME windows_os_timestamp_to_filetime(OsTimeStamp mtime) {
    FILETIME result;
    result.dwHighDateTime = mtime.sec >> 32;
    result.dwLowDateTime = mtime.sec;
    return result;
}
#endif

static Error set_file_times(OsFile file, OsTimeStamp ts) {
#if defined(ZIG_OS_WINDOWS)
    FILETIME ft = windows_os_timestamp_to_filetime(ts);
    if (SetFileTime(file, nullptr, &ft, &ft) == 0) {
        return ErrorUnexpected;
    }
    return ErrorNone;
#else
    struct timespec times[2] = {
        { (time_t)ts.sec, (time_t)ts.nsec },
        { (time_t)ts.sec, (time_t)ts.nsec },
    };
    if (futimens(file, times) == -1) {
        switch (errno) {
            case EBADF:
                zig_panic("futimens EBADF");
            default:
                return ErrorUnexpected;
        }
    }
    return ErrorNone;
#endif
}

Error os_update_file(Buf *src_path, Buf *dst_path) {
    Error err;

    OsFile src_file;
    OsFileAttr src_attr;
    if ((err = os_file_open_r(src_path, &src_file, &src_attr))) {
        return err;
    }

    OsFile dst_file;
    OsFileAttr dst_attr;
    if ((err = os_file_open_w(dst_path, &dst_file, &dst_attr, src_attr.mode))) {
        os_file_close(&src_file);
        return err;
    }

    if (src_attr.size == dst_attr.size &&
        src_attr.mode == dst_attr.mode &&
        src_attr.mtime.sec == dst_attr.mtime.sec &&
        src_attr.mtime.nsec == dst_attr.mtime.nsec)
    {
        os_file_close(&src_file);
        os_file_close(&dst_file);
        return ErrorNone;
    }
#if defined(ZIG_OS_WINDOWS)
    if (SetEndOfFile(dst_file) == 0) {
        return ErrorUnexpected;
    }
#else
    if (ftruncate(dst_file, 0) == -1) {
        return ErrorUnexpected;
    }
#endif
#if defined(ZIG_OS_WINDOWS)
    FILE *src_libc_file = _fdopen(_open_osfhandle((intptr_t)src_file, _O_RDONLY), "rb");
    FILE *dst_libc_file = _fdopen(_open_osfhandle((intptr_t)dst_file, 0), "wb");
#else
    FILE *src_libc_file = fdopen(src_file, "rb");
    FILE *dst_libc_file = fdopen(dst_file, "wb");
#endif
    assert(src_libc_file);
    assert(dst_libc_file);

    if ((err = copy_open_files(src_libc_file, dst_libc_file))) {
        fclose(src_libc_file);
        fclose(dst_libc_file);
        return err;
    }
    if (fflush(src_libc_file) == -1) {
        return ErrorUnexpected;
    }
    if (fflush(dst_libc_file) == -1) {
        return ErrorUnexpected;
    }
    err = set_file_times(dst_file, src_attr.mtime);
    fclose(src_libc_file);
    fclose(dst_libc_file);
    return err;
}

Error os_copy_file(Buf *src_path, Buf *dest_path) {
    FILE *src_f = fopen(buf_ptr(src_path), "rb");
    if (!src_f) {
        int err = errno;
        if (err == ENOENT) {
            return ErrorFileNotFound;
        } else if (err == EACCES || err == EPERM) {
            return ErrorAccess;
        } else {
            return ErrorFileSystem;
        }
    }
    FILE *dest_f = fopen(buf_ptr(dest_path), "wb");
    if (!dest_f) {
        int err = errno;
        if (err == ENOENT) {
            fclose(src_f);
            return ErrorFileNotFound;
        } else if (err == EACCES || err == EPERM) {
            fclose(src_f);
            return ErrorAccess;
        } else {
            fclose(src_f);
            return ErrorFileSystem;
        }
    }
    Error err = copy_open_files(src_f, dest_f);
    fclose(src_f);
    fclose(dest_f);
    return err;
}

Error os_fetch_file_path(Buf *full_path, Buf *out_contents) {
    FILE *f = fopen(buf_ptr(full_path), "rb");
    if (!f) {
        switch (errno) {
            case EACCES:
                return ErrorAccess;
            case EINTR:
                return ErrorInterrupted;
            case EINVAL:
                return ErrorInvalidFilename;
            case ENFILE:
            case ENOMEM:
                return ErrorSystemResources;
            case ENOENT:
                return ErrorFileNotFound;
            default:
                return ErrorFileSystem;
        }
    }
    Error result = os_fetch_file(f, out_contents);
    fclose(f);
    return result;
}

Error os_get_cwd(Buf *out_cwd) {
#if defined(ZIG_OS_WINDOWS)
    char buf[4096];
    if (GetCurrentDirectory(4096, buf) == 0) {
        zig_panic("GetCurrentDirectory failed");
    }
    buf_init_from_str(out_cwd, buf);
    return ErrorNone;
#elif defined(ZIG_OS_POSIX)
    char buf[PATH_MAX];
    char *res = getcwd(buf, PATH_MAX);
    if (res == nullptr) {
        zig_panic("unable to get cwd: %s", strerror(errno));
    }
    buf_init_from_str(out_cwd, res);
    return ErrorNone;
#else
#error "missing os_get_cwd implementation"
#endif
}

#if defined(ZIG_OS_WINDOWS)
#define is_wprefix(s, prefix) \
    (wcsncmp((s), (prefix), sizeof(prefix) / sizeof(WCHAR) - 1) == 0)
static bool is_stderr_cyg_pty(void) {
    HANDLE stderr_handle = GetStdHandle(STD_ERROR_HANDLE);
    if (stderr_handle == INVALID_HANDLE_VALUE)
        return false;

    const int size = sizeof(FILE_NAME_INFO) + sizeof(WCHAR) * MAX_PATH;
    FILE_NAME_INFO *nameinfo;
    WCHAR *p = NULL;

    // Cygwin/msys's pty is a pipe.
    if (GetFileType(stderr_handle) != FILE_TYPE_PIPE) {
        return 0;
    }
    nameinfo = reinterpret_cast<FILE_NAME_INFO *>(heap::c_allocator.allocate<char>(size));
    if (nameinfo == NULL) {
        return 0;
    }
    // Check the name of the pipe:
    // '\{cygwin,msys}-XXXXXXXXXXXXXXXX-ptyN-{from,to}-master'
    if (GetFileInformationByHandleEx(stderr_handle, FileNameInfo, nameinfo, size)) {
        nameinfo->FileName[nameinfo->FileNameLength / sizeof(WCHAR)] = L'\0';
        p = nameinfo->FileName;
        if (is_wprefix(p, L"\\cygwin-")) {      /* Cygwin */
            p += 8;
        } else if (is_wprefix(p, L"\\msys-")) { /* MSYS and MSYS2 */
            p += 6;
        } else {
            p = NULL;
        }
        if (p != NULL) {
            while (*p && isxdigit(*p))  /* Skip 16-digit hexadecimal. */
                ++p;
            if (is_wprefix(p, L"-pty")) {
                p += 4;
            } else {
                p = NULL;
            }
        }
        if (p != NULL) {
            while (*p && isdigit(*p))   /* Skip pty number. */
                ++p;
            if (is_wprefix(p, L"-from-master")) {
                //p += 12;
            } else if (is_wprefix(p, L"-to-master")) {
                //p += 10;
            } else {
                p = NULL;
            }
        }
    }
    heap::c_allocator.deallocate(reinterpret_cast<char *>(nameinfo), size);
    return (p != NULL);
}
#endif

bool os_stderr_tty(void) {
#if defined(ZIG_OS_WINDOWS)
    return _isatty(_fileno(stderr)) != 0 || is_stderr_cyg_pty();
#elif defined(ZIG_OS_POSIX)
    return isatty(STDERR_FILENO) != 0;
#else
#error "missing os_stderr_tty implementation"
#endif
}

Error os_delete_file(Buf *path) {
    if (remove(buf_ptr(path))) {
        return ErrorFileSystem;
    } else {
        return ErrorNone;
    }
}

Error os_rename(Buf *src_path, Buf *dest_path) {
    if (buf_eql_buf(src_path, dest_path)) {
        return ErrorNone;
    }
#if defined(ZIG_OS_WINDOWS)
    if (!MoveFileExA(buf_ptr(src_path), buf_ptr(dest_path), MOVEFILE_REPLACE_EXISTING)) {
        return ErrorFileSystem;
    }
#else
    if (rename(buf_ptr(src_path), buf_ptr(dest_path)) == -1) {
        return ErrorFileSystem;
    }
#endif
    return ErrorNone;
}

OsTimeStamp os_timestamp_calendar(void) {
    OsTimeStamp result;
#if defined(ZIG_OS_WINDOWS)
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    windows_filetime_to_os_timestamp(&ft, &result);
#elif defined(__MACH__)
    mach_timespec_t mts;

    kern_return_t err = clock_get_time(macos_calendar_clock, &mts);
    assert(!err);

    result.sec = mts.tv_sec;
    result.nsec = mts.tv_nsec;
#else
    struct timespec tms;
    clock_gettime(CLOCK_REALTIME, &tms);

    result.sec = tms.tv_sec;
    result.nsec = tms.tv_nsec;
#endif
    return result;
}

OsTimeStamp os_timestamp_monotonic(void) {
    OsTimeStamp result;
#if defined(ZIG_OS_WINDOWS)
    uint64_t counts;
    QueryPerformanceCounter((LARGE_INTEGER*)&counts);
    result.sec = counts / windows_perf_freq;
    result.nsec = (counts % windows_perf_freq) * 1000000000u / windows_perf_freq;
#elif defined(__MACH__)
    mach_timespec_t mts;

    kern_return_t err = clock_get_time(macos_monotonic_clock, &mts);
    assert(!err);

    result.sec = mts.tv_sec;
    result.nsec = mts.tv_nsec;
#else
    struct timespec tms;
    clock_gettime(CLOCK_MONOTONIC, &tms);

    result.sec = tms.tv_sec;
    result.nsec = tms.tv_nsec;
#endif
    return result;
}

Error os_make_path(Buf *path) {
    Buf resolved_path = os_path_resolve(&path, 1);

    size_t end_index = buf_len(&resolved_path);
    Error err;
    while (true) {
        if ((err = os_make_dir(buf_slice(&resolved_path, 0, end_index)))) {
            if (err == ErrorPathAlreadyExists) {
                if (end_index == buf_len(&resolved_path))
                    return ErrorNone;
            } else if (err == ErrorFileNotFound) {
                // march end_index backward until next path component
                while (true) {
                    end_index -= 1;
                    if (os_is_sep(buf_ptr(&resolved_path)[end_index]))
                        break;
                }
                continue;
            } else {
                return err;
            }
        }
        if (end_index == buf_len(&resolved_path))
            return ErrorNone;
        // march end_index forward until next path component
        while (true) {
            end_index += 1;
            if (end_index == buf_len(&resolved_path) || os_is_sep(buf_ptr(&resolved_path)[end_index]))
                break;
        }
    }
    return ErrorNone;
}

Error os_make_dir(Buf *path) {
#if defined(ZIG_OS_WINDOWS)
    if (!CreateDirectory(buf_ptr(path), NULL)) {
        if (GetLastError() == ERROR_ALREADY_EXISTS)
            return ErrorPathAlreadyExists;
        if (GetLastError() == ERROR_PATH_NOT_FOUND)
            return ErrorFileNotFound;
        if (GetLastError() == ERROR_ACCESS_DENIED)
            return ErrorAccess;
        return ErrorUnexpected;
    }
    return ErrorNone;
#else
    if (mkdir(buf_ptr(path), 0755) == -1) {
        if (errno == EEXIST)
            return ErrorPathAlreadyExists;
        if (errno == ENOENT)
            return ErrorFileNotFound;
        if (errno == EACCES)
            return ErrorAccess;
        return ErrorUnexpected;
    }
    return ErrorNone;
#endif
}

static void init_rand() {
#if defined(ZIG_OS_WINDOWS)
    char bytes[sizeof(unsigned)];
    unsigned seed;
    RtlGenRandom(bytes, sizeof(unsigned));
    memcpy(&seed, bytes, sizeof(unsigned));
    srand(seed);
#elif defined(ZIG_OS_LINUX)
    srand(*((unsigned*)getauxval(AT_RANDOM)));
#else
    int fd = open("/dev/urandom", O_RDONLY|O_CLOEXEC);
    if (fd == -1) {
        zig_panic("unable to open /dev/urandom");
    }
    char bytes[sizeof(unsigned)];
    ssize_t amt_read;
    while ((amt_read = read(fd, bytes, sizeof(unsigned))) == -1) {
        if (errno == EINTR) continue;
        zig_panic("unable to read /dev/urandom");
    }
    if (amt_read != sizeof(unsigned)) {
        zig_panic("unable to read enough bytes from /dev/urandom");
    }
    close(fd);
    unsigned seed;
    memcpy(&seed, bytes, sizeof(unsigned));
    srand(seed);
#endif
}

int os_init(void) {
    init_rand();
#if defined(ZIG_OS_WINDOWS)
    _setmode(fileno(stdout), _O_BINARY);
    _setmode(fileno(stderr), _O_BINARY);
    if (!QueryPerformanceFrequency((LARGE_INTEGER*)&windows_perf_freq)) {
        return ErrorSystemResources;
    }
#elif defined(__MACH__)
    host_get_clock_service(mach_host_self(), SYSTEM_CLOCK, &macos_monotonic_clock);
    host_get_clock_service(mach_host_self(), CALENDAR_CLOCK, &macos_calendar_clock);
#endif
#if defined(ZIG_OS_POSIX)
    // Raise the open file descriptor limit.
    // Code lifted from node.js
    struct rlimit lim;
    if (getrlimit(RLIMIT_NOFILE, &lim) == 0 && lim.rlim_cur != lim.rlim_max) {
        // Do a binary search for the limit.
        rlim_t min = lim.rlim_cur;
        rlim_t max = 1 << 20;
        // But if there's a defined upper bound, don't search, just set it.
        if (lim.rlim_max != RLIM_INFINITY) {
            min = lim.rlim_max;
            max = lim.rlim_max;
        }
        do {
            lim.rlim_cur = min + (max - min) / 2;
            if (setrlimit(RLIMIT_NOFILE, &lim)) {
                max = lim.rlim_cur;
            } else {
                min = lim.rlim_cur;
            }
        } while (min + 1 < max);
    }
#endif
    return 0;
}

Error os_self_exe_path(Buf *out_path) {
#if defined(ZIG_OS_WINDOWS)
    buf_resize(out_path, 256);
    for (;;) {
        DWORD copied_amt = GetModuleFileName(nullptr, buf_ptr(out_path), buf_len(out_path));
        if (copied_amt <= 0) {
            return ErrorFileNotFound;
        }
        if (copied_amt < buf_len(out_path)) {
            buf_resize(out_path, copied_amt);
            return ErrorNone;
        }
        buf_resize(out_path, buf_len(out_path) * 2);
    }

#elif defined(ZIG_OS_DARWIN)
    // How long is the executable's path?
    uint32_t u32_len = 0;
    int ret1 = _NSGetExecutablePath(nullptr, &u32_len);
    assert(ret1 != 0);

    Buf *tmp = buf_alloc_fixed(u32_len);

    // Fill the executable path.
    int ret2 = _NSGetExecutablePath(buf_ptr(tmp), &u32_len);
    assert(ret2 == 0);

    // According to libuv project, PATH_MAX*2 works around a libc bug where
    // the resolved path is sometimes bigger than PATH_MAX.
    buf_resize(out_path, PATH_MAX*2);
    char *real_path = realpath(buf_ptr(tmp), buf_ptr(out_path));
    if (!real_path) {
        buf_init_from_buf(out_path, tmp);
        return ErrorNone;
    }

    // Resize out_path for the correct length.
    buf_resize(out_path, strlen(buf_ptr(out_path)));

    return ErrorNone;
#elif defined(ZIG_OS_LINUX)
    buf_resize(out_path, PATH_MAX);
    ssize_t amt = readlink("/proc/self/exe", buf_ptr(out_path), buf_len(out_path));
    if (amt == -1) {
        return ErrorUnexpected;
    }
    buf_resize(out_path, amt);
    return ErrorNone;
#elif defined(ZIG_OS_FREEBSD) || defined(ZIG_OS_DRAGONFLY)
    buf_resize(out_path, PATH_MAX);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t cb = PATH_MAX;
    if (sysctl(mib, 4, buf_ptr(out_path), &cb, nullptr, 0) != 0) {
        return ErrorUnexpected;
    }
    buf_resize(out_path, cb - 1);
    return ErrorNone;
#elif defined(ZIG_OS_NETBSD)
    buf_resize(out_path, PATH_MAX);
    int mib[4] = { CTL_KERN, KERN_PROC_ARGS, -1, KERN_PROC_PATHNAME };
    size_t cb = PATH_MAX;
    if (sysctl(mib, 4, buf_ptr(out_path), &cb, nullptr, 0) != 0) {
        return ErrorUnexpected;
    }
    buf_resize(out_path, cb - 1);
    return ErrorNone;
#endif
    return ErrorFileNotFound;
}

#define VT_RED "\x1b[31;1m"
#define VT_GREEN "\x1b[32;1m"
#define VT_CYAN "\x1b[36;1m"
#define VT_WHITE "\x1b[37;1m"
#define VT_BOLD "\x1b[0;1m"
#define VT_RESET "\x1b[0m"

static void set_color_posix(TermColor color) {
    switch (color) {
        case TermColorRed:
            fprintf(stderr, VT_RED);
            break;
        case TermColorGreen:
            fprintf(stderr, VT_GREEN);
            break;
        case TermColorCyan:
            fprintf(stderr, VT_CYAN);
            break;
        case TermColorWhite:
            fprintf(stderr, VT_WHITE);
            break;
        case TermColorBold:
            fprintf(stderr, VT_BOLD);
            break;
        case TermColorReset:
            fprintf(stderr, VT_RESET);
            break;
    }
}


#if defined(ZIG_OS_WINDOWS)
bool got_orig_console_attrs = false;
WORD original_console_attributes = FOREGROUND_RED|FOREGROUND_GREEN|FOREGROUND_BLUE;
#endif

void os_stderr_set_color(TermColor color) {
#if defined(ZIG_OS_WINDOWS)
    if (is_stderr_cyg_pty()) {
        set_color_posix(color);
        return;
    }
    HANDLE stderr_handle = GetStdHandle(STD_ERROR_HANDLE);
    if (stderr_handle == INVALID_HANDLE_VALUE)
        zig_panic("unable to get stderr handle");
    fflush(stderr);

    if (!got_orig_console_attrs) {
        got_orig_console_attrs = true;
        CONSOLE_SCREEN_BUFFER_INFO info;
        if (GetConsoleScreenBufferInfo(stderr_handle, &info)) {
            original_console_attributes = info.wAttributes;
        }
    }

    switch (color) {
        case TermColorRed:
            SetConsoleTextAttribute(stderr_handle, FOREGROUND_RED|FOREGROUND_INTENSITY);
            break;
        case TermColorGreen:
            SetConsoleTextAttribute(stderr_handle, FOREGROUND_GREEN|FOREGROUND_INTENSITY);
            break;
        case TermColorCyan:
            SetConsoleTextAttribute(stderr_handle, FOREGROUND_GREEN|FOREGROUND_BLUE|FOREGROUND_INTENSITY);
            break;
        case TermColorWhite:
        case TermColorBold:
            SetConsoleTextAttribute(stderr_handle,
                FOREGROUND_RED|FOREGROUND_GREEN|FOREGROUND_BLUE|FOREGROUND_INTENSITY);
            break;
        case TermColorReset:
            SetConsoleTextAttribute(stderr_handle, original_console_attributes);
            break;
    }
#else
    set_color_posix(color);
#endif
}

#if defined(ZIG_OS_WINDOWS)
// Ported from std/unicode.zig
struct Utf16LeIterator {
    uint8_t *bytes;
    size_t i;
};

// Ported from std/unicode.zig
static Utf16LeIterator Utf16LeIterator_init(WCHAR *ptr) {
    return {(uint8_t*)ptr, 0};
}

// Ported from std/unicode.zig
static Optional<uint32_t> Utf16LeIterator_nextCodepoint(Utf16LeIterator *it) {
    if (it->bytes[it->i] == 0 && it->bytes[it->i + 1] == 0)
        return {};
    uint32_t c0 = ((uint32_t)it->bytes[it->i]) | (((uint32_t)it->bytes[it->i + 1]) << 8);
    if ((c0 & ~((uint32_t)0x03ff)) == 0xd800) {
        // surrogate pair
        it->i += 2;
        assert(it->bytes[it->i] != 0 || it->bytes[it->i + 1] != 0);
        uint32_t c1 = ((uint32_t)it->bytes[it->i]) | (((uint32_t)it->bytes[it->i + 1]) << 8);
        assert((c1 & ~((uint32_t)0x03ff)) == 0xdc00);
        it->i += 2;
        return Optional<uint32_t>::some(0x10000 + (((c0 & 0x03ff) << 10) | (c1 & 0x03ff)));
    } else {
        assert((c0 & ~((uint32_t)0x03ff)) != 0xdc00);
        it->i += 2;
        return Optional<uint32_t>::some(c0);
    }
}

// Ported from std/unicode.zig
static uint8_t utf8CodepointSequenceLength(uint32_t c) {
    if (c < 0x80) return 1;
    if (c < 0x800) return 2;
    if (c < 0x10000) return 3;
    if (c < 0x110000) return 4;
    zig_unreachable();
}

// Ported from std/unicode.zig
static size_t utf8Encode(uint32_t c, Slice<uint8_t> out) {
    size_t length = utf8CodepointSequenceLength(c);
    assert(out.len >= length);
    switch (length) {
        // The pattern for each is the same
        // - Increasing the initial shift by 6 each time
        // - Each time after the first shorten the shifted
        //   value to a max of 0b111111 (63)
        case 1:
            out.ptr[0] = c; // Can just do 0 + codepoint for initial range
            break;
        case 2:
            out.ptr[0] = 0b11000000 | (c >> 6);
            out.ptr[1] = 0b10000000 | (c & 0b111111);
            break;
        case 3:
            assert(!(0xd800 <= c && c <= 0xdfff));
            out.ptr[0] = 0b11100000 | (c >> 12);
            out.ptr[1] = 0b10000000 | ((c >> 6) & 0b111111);
            out.ptr[2] = 0b10000000 | (c & 0b111111);
            break;
        case 4:
            out.ptr[0] = 0b11110000 | (c >> 18);
            out.ptr[1] = 0b10000000 | ((c >> 12) & 0b111111);
            out.ptr[2] = 0b10000000 | ((c >> 6) & 0b111111);
            out.ptr[3] = 0b10000000 | (c & 0b111111);
            break;
        default:
            zig_unreachable();
    }
    return length;
}

// Ported from std.unicode.utf16leToUtf8Alloc
static void utf16le_ptr_to_utf8(Buf *out, WCHAR *utf16le) {
    // optimistically guess that it will all be ascii.
    buf_resize(out, 0);
    size_t out_index = 0;
    Utf16LeIterator it = Utf16LeIterator_init(utf16le);
    for (;;) {
        Optional<uint32_t> opt_codepoint = Utf16LeIterator_nextCodepoint(&it);
        if (!opt_codepoint.is_some) break;
        uint32_t codepoint = opt_codepoint.value;

        size_t utf8_len = utf8CodepointSequenceLength(codepoint);
        buf_resize(out, buf_len(out) + utf8_len);
        utf8Encode(codepoint, {(uint8_t*)buf_ptr(out)+out_index, buf_len(out)-out_index});
        out_index += utf8_len;
    }
}
#endif

// Ported from std.os.getAppDataDir
Error os_get_app_data_dir(Buf *out_path, const char *appname) {
#if defined(ZIG_OS_WINDOWS)
    WCHAR *dir_path_ptr;
    switch (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &dir_path_ptr)) {
        case S_OK:
            // defer os.windows.CoTaskMemFree(@ptrCast(*c_void, dir_path_ptr));
            utf16le_ptr_to_utf8(out_path, dir_path_ptr);
            CoTaskMemFree(dir_path_ptr);
            buf_appendf(out_path, "\\%s", appname);
            return ErrorNone;
        case E_OUTOFMEMORY:
            return ErrorNoMem;
        default:
            return ErrorUnexpected;
    }
    zig_unreachable();
#elif defined(ZIG_OS_DARWIN)
    const char *home_dir = getenv("HOME");
    if (home_dir == nullptr) {
        // TODO use /etc/passwd
        return ErrorFileNotFound;
    }
    buf_resize(out_path, 0);
    buf_appendf(out_path, "%s/Library/Application Support/%s", home_dir, appname);
    return ErrorNone;
#elif defined(ZIG_OS_POSIX)
    const char *cache_dir = getenv("XDG_CACHE_HOME");
    if (cache_dir == nullptr) {
        cache_dir = getenv("HOME");
        if (cache_dir == nullptr) {
            // TODO use /etc/passwd
            return ErrorFileNotFound;
        }
        if (cache_dir[0] == 0) {
            return ErrorFileNotFound;
        }
        buf_init_from_str(out_path, cache_dir);
        if (buf_ptr(out_path)[buf_len(out_path) - 1] != '/') {
            buf_append_char(out_path, '/');
        }
        buf_appendf(out_path, ".cache/%s", appname);
    } else {
        if (cache_dir[0] == 0) {
            return ErrorFileNotFound;
        }
        buf_init_from_str(out_path, cache_dir);
        if (buf_ptr(out_path)[buf_len(out_path) - 1] != '/') {
            buf_append_char(out_path, '/');
        }
        buf_appendf(out_path, "%s", appname);
    }
    return ErrorNone;
#endif
}

#if defined(ZIG_OS_LINUX) || defined(ZIG_OS_FREEBSD) || defined(ZIG_OS_NETBSD) || defined(ZIG_OS_DRAGONFLY)
static int self_exe_shared_libs_callback(struct dl_phdr_info *info, size_t size, void *data) {
    ZigList<Buf *> *libs = reinterpret_cast< ZigList<Buf *> *>(data);
    if (info->dlpi_name[0] == '/') {
        libs->append(buf_create_from_str(info->dlpi_name));
    }
    return 0;
}
#endif

Error os_self_exe_shared_libs(ZigList<Buf *> &paths) {
#if defined(ZIG_OS_LINUX) || defined(ZIG_OS_FREEBSD) || defined(ZIG_OS_NETBSD) || defined(ZIG_OS_DRAGONFLY)
    paths.resize(0);
    dl_iterate_phdr(self_exe_shared_libs_callback, &paths);
    return ErrorNone;
#elif defined(ZIG_OS_DARWIN)
    paths.resize(0);
    uint32_t img_count = _dyld_image_count();
    for (uint32_t i = 0; i != img_count; i += 1) {
        const char *name = _dyld_get_image_name(i);
        paths.append(buf_create_from_str(name));
    }
    return ErrorNone;
#elif defined(ZIG_OS_WINDOWS)
    // zig is built statically on windows, so we can return an empty list
    paths.resize(0);
    return ErrorNone;
#else
#error unimplemented
#endif
}

Error os_file_open_rw(Buf *full_path, OsFile *out_file, OsFileAttr *attr, bool need_write, uint32_t mode) {
#if defined(ZIG_OS_WINDOWS)
    // TODO use CreateFileW
    HANDLE result = CreateFileA(buf_ptr(full_path),
            need_write ? (GENERIC_READ|GENERIC_WRITE) : GENERIC_READ,
            need_write ? 0 : FILE_SHARE_READ,
            nullptr,
            need_write ? OPEN_ALWAYS : OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, nullptr);

    if (result == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        switch (err) {
            case ERROR_SHARING_VIOLATION:
                return ErrorSharingViolation;
            case ERROR_ALREADY_EXISTS:
                return ErrorPathAlreadyExists;
            case ERROR_FILE_EXISTS:
                return ErrorPathAlreadyExists;
            case ERROR_FILE_NOT_FOUND:
                return ErrorFileNotFound;
            case ERROR_PATH_NOT_FOUND:
                return ErrorFileNotFound;
            case ERROR_ACCESS_DENIED:
                return ErrorAccess;
            case ERROR_PIPE_BUSY:
                return ErrorPipeBusy;
            default:
                return ErrorUnexpected;
        }
    }
    *out_file = result;

    if (attr != nullptr) {
        BY_HANDLE_FILE_INFORMATION file_info;
        if (!GetFileInformationByHandle(result, &file_info)) {
            CloseHandle(result);
            return ErrorUnexpected;
        }
        windows_filetime_to_os_timestamp(&file_info.ftLastWriteTime, &attr->mtime);
        attr->inode = (((uint64_t)file_info.nFileIndexHigh) << 32) | file_info.nFileIndexLow;
        attr->mode = 0;
        attr->size = (((uint64_t)file_info.nFileSizeHigh) << 32) | file_info.nFileSizeLow;
    }

    return ErrorNone;
#else
    for (;;) {
        int fd = open(buf_ptr(full_path),
                need_write ? (O_RDWR|O_CLOEXEC|O_CREAT) : (O_RDONLY|O_CLOEXEC), mode);
        if (fd == -1) {
            switch (errno) {
                case EINTR:
                    continue;
                case EINVAL:
                    zig_unreachable();
                case EFAULT:
                    zig_unreachable();
                case EACCES:
                case EPERM:
                    return ErrorAccess;
                case EISDIR:
                    return ErrorIsDir;
                case ENOENT:
                    return ErrorFileNotFound;
                default:
                    return ErrorFileSystem;
            }
        }
        struct stat statbuf;
        if (fstat(fd, &statbuf) == -1) {
            close(fd);
            return ErrorFileSystem;
        }
        if (S_ISDIR(statbuf.st_mode)) {
            close(fd);
            return ErrorIsDir;
        }
        *out_file = fd;

        if (attr != nullptr) {
            attr->inode = statbuf.st_ino;
#if defined(ZIG_OS_DARWIN)
            attr->mtime.sec = statbuf.st_mtimespec.tv_sec;
            attr->mtime.nsec = statbuf.st_mtimespec.tv_nsec;
#else
            attr->mtime.sec = statbuf.st_mtim.tv_sec;
            attr->mtime.nsec = statbuf.st_mtim.tv_nsec;
#endif
            attr->mode = statbuf.st_mode;
            attr->size = statbuf.st_size;
        }
        return ErrorNone;
    }
#endif
}

Error os_file_open_r(Buf *full_path, OsFile *out_file, OsFileAttr *attr) {
    return os_file_open_rw(full_path, out_file, attr, false, 0);
}

Error os_file_open_w(Buf *full_path, OsFile *out_file, OsFileAttr *attr, uint32_t mode) {
    return os_file_open_rw(full_path, out_file, attr, true, mode);
}

Error os_file_open_lock_rw(Buf *full_path, OsFile *out_file) {
#if defined(ZIG_OS_WINDOWS)
    for (;;) {
        HANDLE result = CreateFileA(buf_ptr(full_path), GENERIC_READ | GENERIC_WRITE,
            0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

        if (result == INVALID_HANDLE_VALUE) {
            DWORD err = GetLastError();
            switch (err) {
                case ERROR_SHARING_VIOLATION:
                    // TODO wait for the lock instead of sleeping
                    Sleep(10);
                    continue;
                case ERROR_ALREADY_EXISTS:
                    return ErrorPathAlreadyExists;
                case ERROR_FILE_EXISTS:
                    return ErrorPathAlreadyExists;
                case ERROR_FILE_NOT_FOUND:
                    return ErrorFileNotFound;
                case ERROR_PATH_NOT_FOUND:
                    return ErrorFileNotFound;
                case ERROR_ACCESS_DENIED:
                    return ErrorAccess;
                case ERROR_PIPE_BUSY:
                    return ErrorPipeBusy;
                default:
                    return ErrorUnexpected;
            }
        }
        *out_file = result;
        return ErrorNone;
    }
#else
    int fd;
    for (;;) {
        fd = open(buf_ptr(full_path), O_RDWR|O_CLOEXEC|O_CREAT, 0666);
        if (fd == -1) {
            switch (errno) {
                case EINTR:
                    continue;
                case EINVAL:
                    zig_unreachable();
                case EFAULT:
                    zig_unreachable();
                case EACCES:
                case EPERM:
                    return ErrorAccess;
                case EISDIR:
                    return ErrorIsDir;
                case ENOENT:
                    return ErrorFileNotFound;
                case ENOTDIR:
                    return ErrorNotDir;
                default:
                    return ErrorFileSystem;
            }
        }
        break;
    }
    for (;;) {
        struct flock lock;
        lock.l_type = F_WRLCK;
        lock.l_whence = SEEK_SET;
        lock.l_start = 0;
        lock.l_len = 0;
        if (fcntl(fd, F_SETLKW, &lock) == -1) {
            switch (errno) {
                case EINTR:
                    continue;
                case EBADF:
                    zig_unreachable();
                case EFAULT:
                    zig_unreachable();
                case EINVAL:
                    zig_unreachable();
                default:
                    close(fd);
                    return ErrorFileSystem;
            }
        }
        break;
    }
    *out_file = fd;
    return ErrorNone;
#endif
}

Error os_file_read(OsFile file, void *ptr, size_t *len) {
#if defined(ZIG_OS_WINDOWS)
    DWORD amt_read;
    if (ReadFile(file, ptr, *len, &amt_read, nullptr) == 0)
        return ErrorUnexpected;
    *len = amt_read;
    return ErrorNone;
#else
    for (;;) {
        ssize_t rc = read(file, ptr, *len);
        if (rc == -1) {
            switch (errno) {
                case EINTR:
                    continue;
                case EBADF:
                    zig_unreachable();
                case EFAULT:
                    zig_unreachable();
                case EISDIR:
                    return ErrorIsDir;
                default:
                    return ErrorFileSystem;
            }
        }
        *len = rc;
        return ErrorNone;
    }
#endif
}

Error os_file_read_all(OsFile file, Buf *contents) {
    Error err;
    size_t index = 0;
    for (;;) {
        size_t amt = buf_len(contents) - index;

        if (amt < 4096) {
            buf_resize(contents, buf_len(contents) + (4096 - amt));
            amt = buf_len(contents) - index;
        }

        if ((err = os_file_read(file, buf_ptr(contents) + index, &amt)))
            return err;

        if (amt == 0) {
            buf_resize(contents, index);
            return ErrorNone;
        }

        index += amt;
    }
}

Error os_file_overwrite(OsFile file, Buf *contents) {
#if defined(ZIG_OS_WINDOWS)
    if (SetFilePointer(file, 0, nullptr, FILE_BEGIN) == INVALID_SET_FILE_POINTER)
        return ErrorFileSystem;
    if (!SetEndOfFile(file))
        return ErrorFileSystem;
    DWORD bytes_written;
    if (!WriteFile(file, buf_ptr(contents), buf_len(contents), &bytes_written, nullptr))
        return ErrorFileSystem;
    return ErrorNone;
#else
    if (lseek(file, 0, SEEK_SET) == -1)
        return ErrorUnexpectedSeekFailure;
    if (ftruncate(file, 0) == -1)
        return ErrorUnexpectedFileTruncationFailure;
    for (;;) {
        if (write(file, buf_ptr(contents), buf_len(contents)) == -1) {
            switch (errno) {
                case EINTR:
                    continue;
                case EINVAL:
                    zig_unreachable();
                case EBADF:
                    zig_unreachable();
                case EFAULT:
                    zig_unreachable();
                case EDQUOT:
                    return ErrorDiskQuota;
                case ENOSPC:
                    return ErrorDiskSpace;
                case EFBIG:
                    return ErrorFileTooBig;
                case EIO:
                    return ErrorFileSystem;
                case EPERM:
                    return ErrorAccess;
                default:
                    return ErrorUnexpectedWriteFailure;
            }
        }
        return ErrorNone;
    }
#endif
}

void os_file_close(OsFile *file) {
#if defined(ZIG_OS_WINDOWS)
    CloseHandle(*file);
    *file = NULL;
#else
    close(*file);
    *file = -1;
#endif
}
