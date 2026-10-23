# Bit-level reading and writing (https://www.w3.org/TR/exi/#encodingEventCodes and
# https://www.w3.org/TR/exi/#encodingDatatypes).
#
# Both alignment modes live here. The `alignment` option in the header picks one
# (https://www.w3.org/TR/exi/#options):
#
# * bit-packed: values are packed MSB-first (highest bit first) with no padding
#   between them;
# * byte-aligned: every n-bit value takes ceil(n / 8) whole octets, least
#   significant octet first, and booleans take one octet
#   (https://www.w3.org/TR/exi/#encodingBoundedUnsigned).
#
# The raw bit operations (`write_raw_bits!`, `read_raw_bits!`) ignore the
# alignment mode. They exist for the EXI header, whose bits are always packed.

"""
    ceil_log2(m) -> Int

Number of bits needed to tell apart `m` different values: `ceil(log2(m))`, with 0
for `m <= 1`. This is the width of one part of an event code
([EXI 6.2](https://www.w3.org/TR/exi/#encodingEventCodes)) and of a compact
identifier ([EXI 7.3](https://www.w3.org/TR/exi/#stringTable)). It is the bit
length of the largest index `m - 1`.
"""
@inline ceil_log2(m::Integer) = m <= 1 ? 0 : 64 - leading_zeros(UInt64(m - 1))

"""
    bits_to_represent(max) -> Int

Number of bits needed to write the value `max` itself: `ceil(log2(max + 1))`,
with 0 for `max == 0`. Used for n-bit unsigned integers whose range is `0:max`
([EXI 7.1.9](https://www.w3.org/TR/exi/#encodingBoundedUnsigned)).
"""
@inline bits_to_represent(max::Integer) = 64 - leading_zeros(UInt64(max))

@inline low_bits(n::Integer) = n >= 64 ? typemax(UInt64) : (UInt64(1) << n) - UInt64(1)

"""
    BitWriter(; byte_aligned = false)

Writes bits MSB-first (highest bit of each byte first) into a `Vector{UInt8}`.
A partly filled last byte waits in `pending` until later writes fill it, or
until [`align_to_byte!`](@ref) or [`finish!`](@ref) pads it with zero bits.
"""
mutable struct BitWriter
    out::Vector{UInt8}
    # The bits waiting to be written, right-aligned: they sit in the low
    # `pending_len` bits and the oldest bit is the highest of them.
    pending::UInt8
    # How many bits wait in `pending` (0 to 7). A full byte goes out at once.
    pending_len::Int
    byte_aligned::Bool
    bits_written::UInt64
end

BitWriter(out::Vector{UInt8} = UInt8[]; byte_aligned::Bool = false) =
    BitWriter(out, 0x00, 0, byte_aligned, UInt64(0))

is_byte_aligned(w::BitWriter) = w.byte_aligned

"""Total number of bits written so far, padding included."""
bit_position(w::BitWriter) = w.bits_written

"""
    set_byte_aligned!(w, flag)

Switches the alignment mode, after padding to a byte boundary. Used once, after
the header, when the options say byte alignment is on.
"""
function set_byte_aligned!(w::BitWriter, flag::Bool)
    align_to_byte!(w)
    w.byte_aligned = flag
    return w
end

"""
    write_raw_bits!(w, value, n)

Writes the low `n` bits (0 to 64) of `value`, most significant first, ignoring
alignment. The waiting bits and `value` are joined in one word, and every byte
that word completes is copied out.
"""
@inline function write_raw_bits!(w::BitWriter, value::Unsigned, n::Integer)
    0 <= n <= 64 || throw(InternalError("bit width exceeds 64"))
    n == 0 && return w
    v = UInt64(value) & low_bits(n)
    total = w.pending_len + n # at most 71
    w.bits_written += UInt64(n)
    if total < 8
        # No byte completes (most event codes): stay in the pending byte.
        w.pending = ((UInt64(w.pending) << n) | v) % UInt8
        w.pending_len = total
        return w
    end
    full = total >> 3
    rest = total & 7
    if total <= 64 && n < 64
        acc = (UInt64(w.pending) << n) | v
        for i in 1:full
            push!(w.out, (acc >> (total - 8i)) % UInt8)
        end
        w.pending = (acc & low_bits(rest)) % UInt8
    else
        wide = (UInt128(w.pending) << n) | UInt128(v)
        for i in 1:full
            push!(w.out, (wide >> (total - 8i)) % UInt8)
        end
        w.pending = (wide & ((UInt128(1) << rest) - UInt128(1))) % UInt8
    end
    w.pending_len = rest
    return w
end

"""
    write_nbit_unsigned!(w, value, n)

Writes an n-bit unsigned integer, following the alignment mode
([EXI 7.1.9](https://www.w3.org/TR/exi/#encodingBoundedUnsigned)). Bit-packed:
exactly `n` bits. Byte-aligned: `ceil(n / 8)` whole bytes, least significant
byte first. Fails if `value` does not fit in `n` bits; `n == 0` writes nothing.
"""
@inline function write_nbit_unsigned!(w::BitWriter, value::Unsigned, n::Integer)
    n == 0 && return w
    v = UInt64(value)
    if n < 64 && (v >> n) != 0
        throw(InternalError("n-bit unsigned integer value exceeds width"))
    end
    if w.byte_aligned
        # ceil(n / 8) octets, least significant first.
        for i in 0:(cld(n, 8) - 1)
            write_byte!(w, (v >> (8i)) % UInt8)
        end
        return w
    end
    return write_raw_bits!(w, v, n)
end

"""
Writes a boolean ([EXI 7.1.2](https://www.w3.org/TR/exi/#encodingBoolean)): one
bit, or one octet when byte-aligned.
"""
write_bool!(w::BitWriter, b::Bool) = write_nbit_unsigned!(w, UInt64(b), 1)

"""Writes one octet, ignoring alignment. Bit-packed, it may cross a byte boundary."""
@inline function write_byte!(w::BitWriter, b::UInt8)
    if w.pending_len == 0
        push!(w.out, b)
        w.bits_written += UInt64(8)
        return w
    end
    return write_raw_bits!(w, b, 8)
end

"""
    write_bytes!(w, bytes)

Writes all of `bytes`, ignoring alignment. On a byte boundary it appends them in
one go. Off a boundary every byte must be shifted, so it packs up to eight bytes
into one word at a time.
"""
function write_bytes!(w::BitWriter, bytes::AbstractVector{UInt8})
    if w.pending_len == 0
        append!(w.out, bytes)
        w.bits_written += UInt64(8 * length(bytes))
        return w
    end
    i = firstindex(bytes)
    last = lastindex(bytes)
    while i <= last
        k = min(8, last - i + 1)
        word = UInt64(0)
        for j in i:(i + k - 1)
            word = (word << 8) | UInt64(bytes[j])
        end
        write_raw_bits!(w, word, 8k)
        i += k
    end
    return w
end

"""Pads with zero bits up to the next byte boundary (nothing when already on one)."""
function align_to_byte!(w::BitWriter)
    w.pending_len > 0 && write_raw_bits!(w, UInt64(0), 8 - w.pending_len)
    return w
end

"""
    finish!(w) -> Vector{UInt8}

Pads the last byte with zeros and returns the bytes written.
"""
function finish!(w::BitWriter)
    align_to_byte!(w)
    return w.out
end

"""The complete bytes written so far (without the partly filled byte)."""
written_bytes(w::BitWriter) = w.out

"""
    BitReader(bytes; byte_aligned = false)

Reads bits MSB-first from a byte vector (a `Vector`, a view or an mmap). Reading
past the end throws [`TruncatedError`](@ref).
"""
mutable struct BitReader{V<:AbstractVector{UInt8}}
    data::V
    # Index of the next byte to load into `pending`.
    next::Int
    # The unread bits of the current byte, right-aligned: they sit in the low
    # `pending_len` bits and the next bit to read is the highest of them.
    pending::UInt8
    # How many unread bits are left in `pending` (0 to 8).
    pending_len::Int
    byte_aligned::Bool
    bits_read::UInt64
end

BitReader(data::AbstractVector{UInt8}; byte_aligned::Bool = false) =
    BitReader(data, firstindex(data), 0x00, 0, byte_aligned, UInt64(0))

is_byte_aligned(r::BitReader) = r.byte_aligned

"""Number of bits used up so far, skipped padding included."""
bit_position(r::BitReader) = r.bits_read

"""
Switches the alignment mode after the header. It skips to the next byte boundary
first, throwing away any unread bits of the current byte.
"""
function set_byte_aligned!(r::BitReader, flag::Bool)
    align_to_byte!(r)
    r.byte_aligned = flag
    return r
end

@inline function load_byte!(r::BitReader)
    r.next > lastindex(r.data) && throw(TruncatedError())
    @inbounds r.pending = r.data[r.next]
    r.next += 1
    r.pending_len = 8
    return nothing
end

"""
    read_raw_bits!(r, n) -> UInt64

Reads `n` bits (0 to 64), most significant first, ignoring alignment. Each pass
takes as many bits as it can from the current byte, then loads the next one.
"""
@inline function read_raw_bits!(r::BitReader, n::Integer)
    0 <= n <= 64 || throw(InternalError("bit width exceeds 64"))
    # Most reads (event codes, flags) fit in the bits already loaded.
    pl = r.pending_len
    if n <= pl
        rest = pl - Int(n)
        value = UInt64(r.pending >> rest) & low_bits(n)
        r.pending &= rest == 0 ? 0x00 : ((0x01 << rest) - 0x01)
        r.pending_len = rest
        r.bits_read += UInt64(n)
        return value
    end
    value = UInt64(0)
    remaining = Int(n)
    while remaining > 0
        r.pending_len == 0 && load_byte!(r)
        take = min(remaining, r.pending_len)
        shift = r.pending_len - take
        # The `take` highest unread bits of `pending`.
        chunk = (UInt64(r.pending) >> shift) & low_bits(take)
        value = take == 64 ? chunk : (value << take) | chunk
        r.pending_len -= take
        # Clear the bits just read so only unread bits stay in `pending`.
        r.pending &= r.pending_len == 0 ? 0x00 : ((0x01 << r.pending_len) - 0x01)
        remaining -= take
    end
    r.bits_read += UInt64(n)
    return value
end

"""
    read_nbit_unsigned!(r, n) -> UInt64

Reads an n-bit unsigned integer, following the alignment mode
([EXI 7.1.9](https://www.w3.org/TR/exi/#encodingBoundedUnsigned)). Byte-aligned,
it reads `ceil(n / 8)` bytes, least significant first, and masks off any extra
high bits. `n == 0` reads nothing and returns 0.
"""
@inline function read_nbit_unsigned!(r::BitReader, n::Integer)
    n == 0 && return UInt64(0)
    r.byte_aligned || return read_raw_bits!(r, n)
    value = UInt64(0)
    for i in 0:(cld(n, 8) - 1)
        value |= read_raw_bits!(r, 8) << (8i)
    end
    return value & low_bits(n)
end

"""
Reads a boolean ([EXI 7.1.2](https://www.w3.org/TR/exi/#encodingBoolean)): one
bit, or one byte when byte-aligned (only its lowest bit counts).
"""
read_bool!(r::BitReader) = read_nbit_unsigned!(r, 1) != 0

"""Reads 8 bits as one byte, ignoring alignment."""
@inline function read_byte!(r::BitReader)
    # A whole byte is the low `pending_len` bits of `pending` and the top
    # `8 - pending_len` bits of the next input byte.
    i = r.next
    i > lastindex(r.data) && return read_raw_bits!(r, 8) % UInt8
    @inbounds next = r.data[i]
    r.next = i + 1
    r.bits_read += UInt64(8)
    pl = r.pending_len
    pl == 0 && return next
    b = (r.pending << (8 - pl)) | (next >> pl)
    r.pending = next & ((0x01 << pl) - 0x01)
    return b
end

"""
    read_bytes!(r, out)

Fills `out` with bytes, ignoring alignment. On a byte boundary it copies
straight from the input.
"""
function read_bytes!(r::BitReader, out::AbstractVector{UInt8})
    n = length(out)
    if r.pending_len == 0
        r.next + n - 1 > lastindex(r.data) && throw(TruncatedError())
        copyto!(out, firstindex(out), r.data, r.next, n)
        r.next += n
        r.bits_read += UInt64(8n)
        return out
    end
    # Off a byte boundary: each output byte is the pending bits and the top of
    # the next input byte (positions in locals, as in `read_chars_string!`).
    pl = r.pending_len
    i = r.next
    n > lastindex(r.data) - i + 1 && throw(TruncatedError())
    pend = r.pending
    mask = (0x01 << pl) - 0x01
    data = r.data
    @inbounds for k in eachindex(out)
        b = data[i]
        i += 1
        out[k] = (pend << (8 - pl)) | (b >> pl)
        pend = b & mask
    end
    r.next = i
    r.pending = pend
    r.bits_read += UInt64(8n)
    return out
end

"""Throws away the unread bits of the current byte; they still count as read."""
function align_to_byte!(r::BitReader)
    r.bits_read += UInt64(r.pending_len)
    r.pending_len = 0
    r.pending = 0x00
    return r
end
