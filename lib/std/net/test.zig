const std = @import("../std.zig");
const builtin = std.builtin;
const net = std.net;
const mem = std.mem;
const testing = std.testing;

test "parse and render IPv6 addresses" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var buffer: [100]u8 = undefined;
    const ips = [_][]const u8{
        "FF01:0:0:0:0:0:0:FB",
        "FF01::Fb",
        "::1",
        "::",
        "2001:db8::",
        "::1234:5678",
        "2001:db8::1234:5678",
        "FF01::FB%1234",
        "::ffff:123.5.123.5",
    };
    const printed = [_][]const u8{
        "ff01::fb",
        "ff01::fb",
        "::1",
        "::",
        "2001:db8::",
        "::1234:5678",
        "2001:db8::1234:5678",
        "ff01::fb",
        "::ffff:123.5.123.5",
    };
    for (ips) |ip, i| {
        var addr = net.Address.parseIp6(ip, 0) catch unreachable;
        var newIp = std.fmt.bufPrint(buffer[0..], "{}", .{addr}) catch unreachable;
        std.testing.expect(std.mem.eql(u8, printed[i], newIp[1 .. newIp.len - 3]));
    }

    testing.expectError(error.InvalidCharacter, net.Address.parseIp6(":::", 0));
    testing.expectError(error.Overflow, net.Address.parseIp6("FF001::FB", 0));
    testing.expectError(error.InvalidCharacter, net.Address.parseIp6("FF01::Fb:zig", 0));
    testing.expectError(error.InvalidEnd, net.Address.parseIp6("FF01:0:0:0:0:0:0:FB:", 0));
    testing.expectError(error.Incomplete, net.Address.parseIp6("FF01:", 0));
    testing.expectError(error.InvalidIpv4Mapping, net.Address.parseIp6("::123.123.123.123", 0));
}

test "parse and render IPv4 addresses" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var buffer: [18]u8 = undefined;
    for ([_][]const u8{
        "0.0.0.0",
        "255.255.255.255",
        "1.2.3.4",
        "123.255.0.91",
        "127.0.0.1",
    }) |ip| {
        var addr = net.Address.parseIp4(ip, 0) catch unreachable;
        var newIp = std.fmt.bufPrint(buffer[0..], "{}", .{addr}) catch unreachable;
        std.testing.expect(std.mem.eql(u8, ip, newIp[0 .. newIp.len - 2]));
    }

    testing.expectError(error.Overflow, net.Address.parseIp4("256.0.0.1", 0));
    testing.expectError(error.InvalidCharacter, net.Address.parseIp4("x.0.0.1", 0));
    testing.expectError(error.InvalidEnd, net.Address.parseIp4("127.0.0.1.1", 0));
    testing.expectError(error.Incomplete, net.Address.parseIp4("127.0.0.", 0));
    testing.expectError(error.InvalidCharacter, net.Address.parseIp4("100..0.1", 0));
}

test "resolve DNS" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // DNS resolution not implemented on Windows yet.
        return error.SkipZigTest;
    }

    const address_list = net.getAddressList(testing.allocator, "example.com", 80) catch |err| switch (err) {
        // The tests are required to work even when there is no Internet connection,
        // so some of these errors we must accept and skip the test.
        error.UnknownHostName => return error.SkipZigTest,
        error.TemporaryNameServerFailure => return error.SkipZigTest,
        else => return err,
    };
    address_list.deinit();
}

test "listen on a port, send bytes, receive bytes" {
    if (!std.io.is_async) return error.SkipZigTest;

    if (std.builtin.os.tag != .linux and !std.builtin.os.tag.isDarwin()) {
        // TODO build abstractions for other operating systems
        return error.SkipZigTest;
    }

    // TODO doing this at comptime crashed the compiler
    const localhost = try net.Address.parseIp("127.0.0.1", 0);

    var server = net.StreamServer.init(net.StreamServer.Options{});
    defer server.deinit();
    try server.listen(localhost);

    var server_frame = async testServer(&server);
    var client_frame = async testClient(server.listen_address);

    try await server_frame;
    try await client_frame;
}

fn testClient(addr: net.Address) anyerror!void {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const socket_file = try net.tcpConnectToAddress(addr);
    defer socket_file.close();

    var buf: [100]u8 = undefined;
    const len = try socket_file.read(&buf);
    const msg = buf[0..len];
    testing.expect(mem.eql(u8, msg, "hello from server\n"));
}

fn testServer(server: *net.StreamServer) anyerror!void {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var client = try server.accept();

    const stream = client.file.outStream();
    try stream.print("hello from server\n", .{});
}
