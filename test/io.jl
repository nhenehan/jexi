# Bit I/O, ported from rexi-core/src/io/{bits,bit_writer,bit_reader}.rs.
using JExi:
    ceil_log2, bits_to_represent, BitWriter, BitReader, write_raw_bits!,
    write_nbit_unsigned!, write_bool!, write_byte!, write_bytes!, align_to_byte!,
    set_byte_aligned!, finish!, bit_position, read_raw_bits!, read_nbit_unsigned!,
    read_bool!, read_byte!, read_bytes!, TruncatedError, InternalError

# A writer that adds one bit at a time: slow, but plainly correct. The real
# writer must give the same bytes and positions (rexi's bit_writer_reference.rs).
mutable struct RefWriter
    bits::Vector{Bool}
    byte_aligned::Bool
end
RefWriter(aligned) = RefWriter(Bool[], aligned)
ref_raw!(w, v, n) = (for i in (n - 1):-1:0
    push!(w.bits, (UInt64(v) >> i) & 1 == 1)
end)
ref_align!(w) = (while length(w.bits) % 8 != 0
    push!(w.bits, false)
end)
function ref_nbit!(w, v, n)
    n == 0 && return
    if w.byte_aligned
        for i in 0:(cld(n, 8) - 1)
            ref_raw!(w, (UInt64(v) >> (8i)) & 0xff, 8)
        end
    else
        ref_raw!(w, v, n)
    end
end
function ref_bytes(w)
    bits = copy(w.bits)
    while length(bits) % 8 != 0
        push!(bits, false)
    end
    [foldl((a, b) -> (a << 1) | UInt8(b), bits[i:(i + 7)]; init = 0x00) for i in 1:8:length(bits)]
end
complete_bytes(w::RefWriter) = ref_bytes(RefWriter(w.bits[1:(8 * (length(w.bits) ÷ 8))], false))

function xorshift(state::Ref{UInt64})
    s = state[]
    s ⊻= s << 13
    s ⊻= s >> 7
    s ⊻= s << 17
    state[] = s
end

@testset "io" begin
    @testset "ceil_log2 matches the spec table" begin
        for (m, w) in ((0, 0), (1, 0), (2, 1), (3, 2), (4, 2), (5, 3), (8, 3), (9, 4),
            (4096, 12), (4097, 13))
            @test ceil_log2(m) == w
        end
    end

    @testset "bits_to_represent" begin
        for (m, w) in ((0, 0), (1, 1), (2, 2), (255, 8), (256, 9), (4095, 12),
            (typemax(UInt64), 64))
            @test bits_to_represent(m) == w
        end
    end

    packed(f) = (w = BitWriter(); f(w); finish!(w))

    @testset "writes MSB first across boundaries" begin
        bytes = packed() do w
            write_raw_bits!(w, 0b101 % UInt64, 3)
            write_raw_bits!(w, 0b11_0000_1111 % UInt64, 10)
        end
        @test bytes == [0b1011_1000, 0b0111_1000]
    end

    @testset "exip test_writeNBits vector" begin
        bytes = packed() do w
            write_raw_bits!(w, UInt64(19), 7)
            write_raw_bits!(w, UInt64(9), 5)
        end
        @test bytes[1] & 0x01 == 0
        @test (bytes[2] & 0xf0) >> 4 == 9
    end

    @testset "412 in 9 bits matches exip" begin
        bytes = packed(w -> write_nbit_unsigned!(w, UInt64(412), 9))
        @test bytes[1] == 206
        @test bytes[2] >> 7 == 0
    end

    @testset "all widths round trip" begin
        for width in 1:64
            value = width == 64 ? typemax(UInt64) : (UInt64(1) << width) - 1
            bytes = packed() do w
                write_raw_bits!(w, UInt64(1), 1)
                write_raw_bits!(w, value, width)
            end
            r = BitReader(bytes)
            @test read_raw_bits!(r, 1) == 1
            @test read_raw_bits!(r, width) == value
        end
    end

    @testset "byte-aligned n-bit is little-endian octets" begin
        w = BitWriter(; byte_aligned = true)
        write_nbit_unsigned!(w, UInt64(0x0123), 12)
        write_bool!(w, true)
        write_nbit_unsigned!(w, UInt64(0), 0)
        @test finish!(w) == [0x23, 0x01, 0x01]
    end

    @testset "finish pads with zeros" begin
        @test packed(w -> write_raw_bits!(w, UInt64(1), 1)) == [0x80]
    end

    @testset "rejects a value wider than n" begin
        @test_throws InternalError write_nbit_unsigned!(BitWriter(), UInt64(8), 3)
    end

    @testset "same output as the bit-by-bit writer" begin
        state = Ref(0x5eed_1234_abcd_ef01)
        next() = xorshift(state)
        for _ in 1:2000
            aligned = next() % 2 == 0
            a = BitWriter(; byte_aligned = aligned)
            b = RefWriter(aligned)
            for _ in 1:(next() % 40)
                r = next()
                v = next()
                op = r % 7
                if op == 0
                    n = Int((r >> 8) % 65)
                    write_raw_bits!(a, v, n)
                    ref_raw!(b, v, n)
                elseif op == 1
                    n = Int((r >> 8) % 65)
                    x = n == 64 ? v : n == 0 ? UInt64(0) : v & ((UInt64(1) << n) - 1)
                    write_nbit_unsigned!(a, x, n)
                    ref_nbit!(b, x, n)
                elseif op == 2
                    write_bool!(a, v % 2 == 1)
                    ref_nbit!(b, v % 2, 1)
                elseif op == 3
                    write_byte!(a, v % UInt8)
                    ref_raw!(b, v % UInt8, 8)
                elseif op == 4
                    bytes = UInt8[(v >> (i % 8)) % UInt8 for i in 0:(Int(v % 20) - 1)]
                    write_bytes!(a, bytes)
                    for x in bytes
                        ref_raw!(b, x, 8)
                    end
                elseif op == 5
                    align_to_byte!(a)
                    ref_align!(b)
                else
                    flag = v % 2 == 0
                    set_byte_aligned!(a, flag)
                    ref_align!(b)
                    b.byte_aligned = flag
                end
                @test bit_position(a) == length(b.bits)
                @test a.out == complete_bytes(b)
            end
            @test finish!(a) == ref_bytes(b)
        end
    end

    @testset "exip test_readBits vector" begin
        r = BitReader(UInt8[0xd4, 0x60])
        @test read_raw_bits!(r, 4) == 13
        @test bit_position(r) == 4
        @test read_raw_bits!(r, 3) == 0b010
        @test read_raw_bits!(r, 5) == 6
        @test bit_position(r) == 12
    end

    @testset "exip n-bit 6 from D4 60" begin
        @test read_nbit_unsigned!(BitReader(UInt8[0xd4, 0x60]), 6) == 53
    end

    @testset "truncated read" begin
        r = BitReader(UInt8[0xa0])
        @test read_raw_bits!(r, 3) == 0b101
        @test_throws TruncatedError read_raw_bits!(r, 6)
    end

    @testset "byte-aligned reads little-endian" begin
        r = BitReader(UInt8[0x23, 0x01, 0x01]; byte_aligned = true)
        @test read_nbit_unsigned!(r, 12) == 0x0123
        @test read_bool!(r)
    end

    @testset "align skips padding" begin
        r = BitReader(UInt8[0b1010_0000, 0x42])
        @test read_raw_bits!(r, 3) == 0b101
        align_to_byte!(r)
        @test read_byte!(r) == 0x42
        @test bit_position(r) == 16
    end

    @testset "read_bytes on and off a boundary" begin
        r = BitReader(UInt8[0x12, 0x34, 0x56])
        @test read_bytes!(r, zeros(UInt8, 2)) == [0x12, 0x34]
        r = BitReader(UInt8[0x81, 0x22, 0x80])
        @test read_raw_bits!(r, 1) == 1
        @test read_bytes!(r, zeros(UInt8, 2)) == [0x02, 0x45]
        @test_throws TruncatedError read_bytes!(BitReader(UInt8[0x01]), zeros(UInt8, 2))
    end
end
