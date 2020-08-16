const std = @import("std.zig");
const builtin = std.builtin;
const root = @import("root");

//! std.log is a standardized interface for logging which allows for the logging
//! of programs and libraries using this interface to be formatted and filtered
//! by the implementer of the root.log function.
//!
//! The scope parameter should be used to give context to the logging. For
//! example, a library called 'libfoo' might use .libfoo as its scope.
//! This parameter can either be passed explicitly to the logging functions
//! provided here, or a scoped logging namespace can be created
//! using the `log.scoped` function. If logging scopes are not relevant for
//! your use case, the `log.default` scope namespace can be used.
//!
//! An example root.log might look something like this:
//!
//! ```
//! const std = @import("std");
//!
//! // Set the log level to warning
//! pub const log_level: std.log.Level = .warn;
//!
//! // Define root.log to override the std implementation
//! pub fn log(
//!     comptime level: std.log.Level,
//!     comptime scope: @TypeOf(.EnumLiteral),
//!     comptime format: []const u8,
//!     args: anytype,
//! ) void {
//!     // Ignore all non-critical logging from sources other than
//!     // .my_project and .nice_library
//!     const scope_prefix = "(" ++ switch (scope) {
//!         .my_project, .nice_library => @tagName(scope),
//!         else => if (@enumToInt(level) <= @enumToInt(std.log.Level.crit))
//!             @tagName(scope)
//!         else
//!             return,
//!     } ++ "): ";
//!
//!     const prefix = "[" ++ @tagName(level) ++ "] " ++ scope_prefix;
//!
//!     // Print the message to stderr, silently ignoring any errors
//!     const held = std.debug.getStderrMutex().acquire();
//!     defer held.release();
//!     const stderr = std.io.getStdErr().writer();
//!     nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
//! }
//!
//! pub fn main() void {
//!     // Using explicit scopes:
//!     // Won't be printed as log_level is .warn
//!     std.log.info(.my_project, "Starting up.", .{});
//!     std.log.err(.nice_library, "Something went very wrong, sorry.", .{});
//!     // Won't be printed as it gets filtered out by our log function
//!     std.log.err(.lib_that_logs_too_much, "Added 1 + 1", .{});
//!
//!     // Using a scoped logging namespace:
//!     const scoped_log = std.log.scoped(.my_project);
//!     scoped_log.alert("The scope for this message is implicitly .my_project", .{});
//!
//!     // Using the default namespace:
//!     // Won't be printed as log_level is .warn
//!     std.log.default.info("I don't care about my namespace", .{});
//! }
//! ```
//! Which produces the following output:
//! ```
//! [err] (nice_library): Something went very wrong, sorry.
//! [alert] (my_project): The scope for this message is implicitly .my_project
//! ```

pub const Level = enum {
    /// Emergency: a condition that cannot be handled, usually followed by a
    /// panic.
    emerg,
    /// Alert: a condition that should be corrected immediately (e.g. database
    /// corruption).
    alert,
    /// Critical: A bug has been detected or something has gone wrong and it
    /// will have an effect on the operation of the program.
    crit,
    /// Error: A bug has been detected or something has gone wrong but it is
    /// recoverable.
    err,
    /// Warning: it is uncertain if something has gone wrong or not, but the
    /// circumstances would be worth investigating.
    warn,
    /// Notice: non-error but significant conditions.
    notice,
    /// Informational: general messages about the state of the program.
    info,
    /// Debug: messages only useful for debugging.
    debug,
};

/// The default log level is based on build mode. Note that in ReleaseSmall
/// builds the default level is emerg but no messages will be stored/logged
/// by the default logger to save space.
pub const default_level: Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .notice,
    .ReleaseFast => .err,
    .ReleaseSmall => .emerg,
};

/// The current log level. This is set to root.log_level if present, otherwise
/// log.default_level.
pub const level: Level = if (@hasDecl(root, "log_level"))
    root.log_level
else
    default_level;

fn log(
    comptime message_level: Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) <= @enumToInt(level)) {
        if (@hasDecl(root, "log")) {
            root.log(message_level, scope, format, args);
        } else if (builtin.mode != .ReleaseSmall) {
            const held = std.debug.getStderrMutex().acquire();
            defer held.release();
            const stderr = std.io.getStdErr().writer();
            nosuspend stderr.print(format ++ "\n", args) catch return;
        }
    }
}

/// Log an emergency message. This log level is intended to be used
/// for conditions that cannot be handled and is usually followed by a panic.
pub fn emerg(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.emerg, scope, format, args);
}

/// Log an alert message. This log level is intended to be used for
/// conditions that should be corrected immediately (e.g. database corruption).
pub fn alert(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.alert, scope, format, args);
}

/// Log a critical message. This log level is intended to be used
/// when a bug has been detected or something has gone wrong and it will have
/// an effect on the operation of the program.
pub fn crit(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.crit, scope, format, args);
}

/// Log an error message. This log level is intended to be used when
/// a bug has been detected or something has gone wrong but it is recoverable.
pub fn err(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.err, scope, format, args);
}

/// Log a warning message. This log level is intended to be used if
/// it is uncertain whether something has gone wrong or not, but the
/// circumstances would be worth investigating.
pub fn warn(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.warn, scope, format, args);
}

/// Log a notice message. This log level is intended to be used for
/// non-error but significant conditions.
pub fn notice(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.notice, scope, format, args);
}

/// Log an info message. This log level is intended to be used for
/// general messages about the state of the program.
pub fn info(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.info, scope, format, args);
}

/// Log a debug message. This log level is intended to be used for
/// messages which are only useful for debugging.
pub fn debug(
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log(.debug, scope, format, args);
}

/// Returns a scoped logging namespace that logs all messages using the scope
/// provided here.
pub fn scoped(comptime scope: @Type(.EnumLiteral)) type {
    return struct {
        /// Log an emergency message. This log level is intended to be used
        /// for conditions that cannot be handled and is usually followed by a panic.
        pub fn emerg(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.emerg, scope, format, args);
        }

        /// Log an alert message. This log level is intended to be used for
        /// conditions that should be corrected immediately (e.g. database corruption).
        pub fn alert(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.alert, scope, format, args);
        }

        /// Log a critical message. This log level is intended to be used
        /// when a bug has been detected or something has gone wrong and it will have
        /// an effect on the operation of the program.
        pub fn crit(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.crit, scope, format, args);
        }

        /// Log an error message. This log level is intended to be used when
        /// a bug has been detected or something has gone wrong but it is recoverable.
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @setCold(true);
            log(.err, scope, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.warn, scope, format, args);
        }

        /// Log a notice message. This log level is intended to be used for
        /// non-error but significant conditions.
        pub fn notice(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.notice, scope, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.info, scope, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.debug, scope, format, args);
        }
    };
}

/// The default scoped logging namespace.
pub const default = scoped(.default);
