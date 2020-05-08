const std = @import("../std.zig");
const builtin = std.builtin;
const io = std.io;
const testing = std.testing;
const assert = std.debug.assert;
const trait = std.meta.trait;
const meta = std.meta;
const math = std.math;

/// Creates a stream which allows for writing bit fields to another stream
pub fn BitOutStream(endian: builtin.Endian, comptime OutStreamType: type) type {
    return struct {
        out_stream: OutStreamType,
        bit_buffer: u8,
        bit_count: u4,

        pub const Error = OutStreamType.Error;
        pub const OutStream = io.OutStream(*Self, Error, write);

        const Self = @This();
        const u8_bit_count = comptime meta.bitCount(u8);
        const u4_bit_count = comptime meta.bitCount(u4);

        pub fn init(out_stream: OutStreamType) Self {
            return Self{
                .out_stream = out_stream,
                .bit_buffer = 0,
                .bit_count = 0,
            };
        }

        /// Write the specified number of bits to the stream from the least significant bits of
        ///  the specified unsigned int value. Bits will only be written to the stream when there
        ///  are enough to fill a byte.
        pub fn writeBits(self: *Self, value: var, bits: usize) Error!void {
            if (bits == 0) return;

            const U = @TypeOf(value);
            comptime assert(trait.isUnsignedInt(U));

            //by extending the buffer to a minimum of u8 we can cover a number of edge cases
            // related to shifting and casting.
            const u_bit_count = comptime meta.bitCount(U);
            const buf_bit_count = bc: {
                assert(u_bit_count >= bits);
                break :bc if (u_bit_count <= u8_bit_count) u8_bit_count else u_bit_count;
            };
            const Buf = std.meta.Int(false, buf_bit_count);
            const BufShift = math.Log2Int(Buf);

            const buf_value = @intCast(Buf, value);

            const high_byte_shift = @intCast(BufShift, buf_bit_count - u8_bit_count);
            var in_buffer = switch (endian) {
                .Big => buf_value << @intCast(BufShift, buf_bit_count - bits),
                .Little => buf_value,
            };
            var in_bits = bits;

            if (self.bit_count > 0) {
                const bits_remaining = u8_bit_count - self.bit_count;
                const n = @intCast(u3, if (bits_remaining > bits) bits else bits_remaining);
                switch (endian) {
                    .Big => {
                        const shift = @intCast(BufShift, high_byte_shift + self.bit_count);
                        const v = @intCast(u8, in_buffer >> shift);
                        self.bit_buffer |= v;
                        in_buffer <<= n;
                    },
                    .Little => {
                        const v = @truncate(u8, in_buffer) << @intCast(u3, self.bit_count);
                        self.bit_buffer |= v;
                        in_buffer >>= n;
                    },
                }
                self.bit_count += n;
                in_bits -= n;

                //if we didn't fill the buffer, it's because bits < bits_remaining;
                if (self.bit_count != u8_bit_count) return;
                try self.out_stream.writeByte(self.bit_buffer);
                self.bit_buffer = 0;
                self.bit_count = 0;
            }
            //at this point we know bit_buffer is empty

            //copy bytes until we can't fill one anymore, then leave the rest in bit_buffer
            while (in_bits >= u8_bit_count) {
                switch (endian) {
                    .Big => {
                        const v = @intCast(u8, in_buffer >> high_byte_shift);
                        try self.out_stream.writeByte(v);
                        in_buffer <<= @intCast(u3, u8_bit_count - 1);
                        in_buffer <<= 1;
                    },
                    .Little => {
                        const v = @truncate(u8, in_buffer);
                        try self.out_stream.writeByte(v);
                        in_buffer >>= @intCast(u3, u8_bit_count - 1);
                        in_buffer >>= 1;
                    },
                }
                in_bits -= u8_bit_count;
            }

            if (in_bits > 0) {
                self.bit_count = @intCast(u4, in_bits);
                self.bit_buffer = switch (endian) {
                    .Big => @truncate(u8, in_buffer >> high_byte_shift),
                    .Little => @truncate(u8, in_buffer),
                };
            }
        }

        /// Flush any remaining bits to the stream.
        pub fn flushBits(self: *Self) Error!void {
            if (self.bit_count == 0) return;
            try self.out_stream.writeByte(self.bit_buffer);
            self.bit_buffer = 0;
            self.bit_count = 0;
        }

        pub fn write(self: *Self, buffer: []const u8) Error!usize {
            // TODO: I'm not sure this is a good idea, maybe flushBits should be forced
            if (self.bit_count > 0) {
                for (buffer) |b, i|
                    try self.writeBits(b, u8_bit_count);
                return buffer.len;
            }

            return self.out_stream.write(buffer);
        }

        pub fn outStream(self: *Self) OutStream {
            return .{ .context = self };
        }
    };
}

pub fn bitOutStream(
    comptime endian: builtin.Endian,
    underlying_stream: var,
) BitOutStream(endian, @TypeOf(underlying_stream)) {
    return BitOutStream(endian, @TypeOf(underlying_stream)).init(underlying_stream);
}

test "api coverage" {
    var mem_be = [_]u8{0} ** 2;
    var mem_le = [_]u8{0} ** 2;

    var mem_out_be = io.fixedBufferStream(&mem_be);
    var bit_stream_be = bitOutStream(.Big, mem_out_be.outStream());

    try bit_stream_be.writeBits(@as(u2, 1), 1);
    try bit_stream_be.writeBits(@as(u5, 2), 2);
    try bit_stream_be.writeBits(@as(u128, 3), 3);
    try bit_stream_be.writeBits(@as(u8, 4), 4);
    try bit_stream_be.writeBits(@as(u9, 5), 5);
    try bit_stream_be.writeBits(@as(u1, 1), 1);

    testing.expect(mem_be[0] == 0b11001101 and mem_be[1] == 0b00001011);

    mem_out_be.pos = 0;

    try bit_stream_be.writeBits(@as(u15, 0b110011010000101), 15);
    try bit_stream_be.flushBits();
    testing.expect(mem_be[0] == 0b11001101 and mem_be[1] == 0b00001010);

    mem_out_be.pos = 0;
    try bit_stream_be.writeBits(@as(u32, 0b110011010000101), 16);
    testing.expect(mem_be[0] == 0b01100110 and mem_be[1] == 0b10000101);

    try bit_stream_be.writeBits(@as(u0, 0), 0);

    var mem_out_le = io.fixedBufferStream(&mem_le);
    var bit_stream_le = bitOutStream(.Little, mem_out_le.outStream());

    try bit_stream_le.writeBits(@as(u2, 1), 1);
    try bit_stream_le.writeBits(@as(u5, 2), 2);
    try bit_stream_le.writeBits(@as(u128, 3), 3);
    try bit_stream_le.writeBits(@as(u8, 4), 4);
    try bit_stream_le.writeBits(@as(u9, 5), 5);
    try bit_stream_le.writeBits(@as(u1, 1), 1);

    testing.expect(mem_le[0] == 0b00011101 and mem_le[1] == 0b10010101);

    mem_out_le.pos = 0;
    try bit_stream_le.writeBits(@as(u15, 0b110011010000101), 15);
    try bit_stream_le.flushBits();
    testing.expect(mem_le[0] == 0b10000101 and mem_le[1] == 0b01100110);

    mem_out_le.pos = 0;
    try bit_stream_le.writeBits(@as(u32, 0b1100110100001011), 16);
    testing.expect(mem_le[0] == 0b00001011 and mem_le[1] == 0b11001101);

    try bit_stream_le.writeBits(@as(u0, 0), 0);
}
